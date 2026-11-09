#!/usr/bin/env node
/**
 * flow-to-robin.js — deterministic generator: flow.json → Robin script (fill in the blanks from a lookup table)
 *
 * Usage:
 *   node flow-to-robin.js <flow.json> [out.robin] [--kb <kb.json>] [--no-check]
 *
 * Design principles:
 * - The action skeleton comes straight from the KB golden_example's actionId / parameter names / parameter order / output names and is never rewritten
 * - Value precedence: flow node params → handle auto-wired to an upstream Launch → KB default → golden placeholder value (with a warning)
 * - Type formatting: String/FileObject/FolderObject → $'''…''' ; numbers/booleans are bare; enums → Module.EnumType.Value
 * - String escaping: \ doubled, ' → \', a single % → %%
 * - References: {{2.RetrievedEmails}} → upstream output variable; {{config.X}} / {{variables.X}} → bare variable X
 * - Safety gates: unknown action / unknown parameter / needs_ui_selector / dangling reference → error out and refuse to produce anything (exit code 1)
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

// ── CLI arguments ─────────────────────────────────────────────
const args = process.argv.slice(2);
const flowPath = args.shift();
let outPath = null;
let kbPath = null;
let noCheck = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--kb") kbPath = args[++i];
  else if (args[i] === "--no-check") noCheck = true;
  else if (args[i].startsWith("--")) { /* ignore unknown options */ }
  else outPath = args[i];
}

if (!flowPath) {
  console.error("Usage: node flow-to-robin.js <flow.json> [out.robin] [--kb <kb.json>] [--no-check]");
  process.exit(1);
}

// ── Load the KB ───────────────────────────────────────────────
if (!kbPath) {
  const candidates = [
    path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
    path.join(process.cwd(), "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
  ];
  kbPath = candidates.find((p) => fs.existsSync(p));
}
if (!kbPath || !fs.existsSync(kbPath)) {
  console.error("[error] PAD_Robin_ActionKB.json not found; pass --kb <path>");
  process.exit(1);
}
const kb = JSON.parse(fs.readFileSync(kbPath, "utf8"));
const actionMap = new Map(kb.actions.map((a) => [a.actionId, a]));

// ── Load the flow ─────────────────────────────────────────────
const flow = JSON.parse(fs.readFileSync(flowPath, "utf8"));

// edges consistency gate: flow.json maintains both edges (for the diagram) and next/branch (for code generation),
// so confirm the two sides have not drifted before generating, lest the PAD code and the diagram tell different stories
try {
  const { checkFlowConsistency } = require(path.join(__dirname, "..", "flow-drawio", "check-flow.js"));
  if (Array.isArray(flow.edges) && flow.edges.length) {
    const drift = checkFlowConsistency(flow);
    if (!drift.ok) {
      console.error("[error] edges disagree with next/branch, refusing to generate:");
      if (drift.missing.length) {
        console.error("  missing edges: " + drift.missing.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      if (drift.duplicates.length) {
        console.error("  duplicate edges: " + drift.duplicates.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      if (drift.dangling.length) {
        console.error("  dangling edges: " + drift.dangling.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      process.exit(1);
    }
  }
} catch (e) {
  if (e && e.code === "MODULE_NOT_FOUND") {
    console.error("[warning] check-flow.js not found; skipping the edges consistency check");
  } else {
    throw e;
  }
}

// Handle type → name of the upstream variable that produces it (filled in at runtime)
const handleVars = {}; // { ExcelInstance: "ExcelInstance", OutlookInstance: "OutlookInstance", ... }

// Every defined variable (used for the dangling-reference check)
const definedVars = new Set();

// ── Helper functions ──────────────────────────────────────────
const CONTROL_FLOW = new Set(["IF", "LOOP", "SWITCH", "GUARD"]);

function isHandleType(t) {
  return /Handle$|Instance$/.test(t) || t === "ExcelInstance" || t === "OutlookInstance" || t === "Browser";
}

function handleBaseName(type) {
  // ExcelInstanceHandle → ExcelInstance, OutlookInstance → OutlookInstance
  return type.replace(/Handle$/, "");
}

/** Seconds a WAIT node waits: reads params.Seconds, defaults to 60 seconds */
function waitSeconds(node) {
  const s = node.params && node.params.Seconds != null ? node.params.Seconds : 60;
  return s;
}

/** Format a value according to its type */
function formatValue(raw, paramType, action) {
  if (raw == null) return null;

  // Booleans / numbers are written bare
  if (paramType === "Boolean") {
    if (raw === true || raw === "true" || raw === "True") return "True";
    if (raw === false || raw === "false" || raw === "False") return "False";
    return raw ? "True" : "False";
  }
  if (paramType === "Int32" || paramType === "Int64" || paramType === "Double" || paramType === "Decimal") {
    return String(raw);
  }

  // Enums: fully qualified Module.EnumType.Value
  if (action && action.input_params) {
    const p = action.input_params.find((x) => x.type === paramType);
    if (p && p.enumValues && p.enumValues.includes(raw)) {
      // Drop the Values suffix from the enum type name, e.g. RetrieveMessagesMode
      const enumType = paramType;
      return `${action.module}.${enumType}.${raw}`;
    }
  }

  // Strings / files / folders: $'''…''' plus escaping
  if (["String", "FileObject", "FolderObject", "SecureString"].includes(paramType)) {
    return formatString(raw);
  }

  // Variable reference or expression: written bare
  return String(raw);
}

/**
 * Escape the contents of a string literal (without the surrounding $'''…'''): \ doubled, ' → \', a single % → %%
 * %Var% is a PAD variable reference (e.g. %PadRoot%) and must be preserved verbatim, otherwise it would be escaped as a literal percent sign
 */
function escapeLiteral(s) {
  return String(s)
    .split(/(%[A-Za-z_]\w*%)/)
    .map((seg) => (/^%[A-Za-z_]\w*%$/.test(seg)
      ? seg
      : seg.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/%/g, "%%")))
    .join("");
}

/** String formatting plus escaping */
function formatString(s) {
  return `$'''${escapeLiteral(s)}'''`;
}

/** Resolve a {{ref}} reference and return the bare variable name */
function resolveRef(ref, currentNodeId) {
  // {{2.RetrievedEmails}} → output variable RetrievedEmails of node 2
  const m = ref.match(/^\{\{(\d+)\.(\w+)\}\}$/);
  if (m) {
    const [, srcId, field] = m;
    const srcNode = flow.nodes.find((n) => n.id === srcId);
    if (!srcNode) throw new Error(`node ${currentNodeId} references a non-existent node ${srcId}`);
    // 1. Variable name explicitly given by the node's output_map
    if (srcNode.output_map && srcNode.output_map[field]) return srcNode.output_map[field];
    // 1b. output_map keys may be KB output names (e.g. Content→FileContents), so look them up by KB name
    if (srcNode.output_map) {
      const act0 = actionMap.get(srcNode.pad_hint);
      const ops0 = (act0 && act0.output_params) || [];
      for (const k of Object.keys(srcNode.output_map)) {
        const op0 = ops0.find((o) => o.name === k);
        const kbName = op0 ? (goldenOutputName(act0, k) || op0.defaultVariable || k) : k;
        if (kbName === field) return srcNode.output_map[k];
      }
    }
    // 2. Prefer the bound name in outputs[], otherwise the KB default variable name
    if (srcNode.outputs && srcNode.outputs.includes(field)) return field;
    // 3. Look up defaultVariable of the KB output parameter
    const action = actionMap.get(srcNode.pad_hint);
    if (action && action.output_params) {
      const op = action.output_params.find((o) => o.name === field);
      if (op) return goldenOutputName(action, field) || op.defaultVariable || field;
    }
    return field;
  }
  // {{config.X}} / {{variables.X}} → bare variable X
  const cm = ref.match(/^\{\{(?:config|variables)\.(\w+)\}\}$/);
  if (cm) return cm[1];
  // {{X}} → bare variable X
  const sm = ref.match(/^\{\{(\w+)\}\}$/);
  if (sm) return sm[1];
  return null;
}

/** Handle a parameter value: it may be a literal or contain embedded {{ref}} */
function resolveParamValue(value, paramType, action, nodeId) {
  if (typeof value !== "string") return formatValue(value, paramType, action);

  // The whole value is a single reference
  const fullRef = resolveRef(value, nodeId);
  if (fullRef) return fullRef;

  // {{ref}} inside a string: process it segment by segment — escape literal segments, keep reference segments as bare %Var%,
  // so the % in %Var% is not escaped into %%Var%% as a literal percent sign
  if (value.includes("{{")) {
    const segs = [];
    const refRe = /\{\{\d+\.\w+\}\}|\{\{(?:config|variables)\.\w+\}\}|\{\{\w+\}\}/g;
    let last = 0;
    let m;
    while ((m = refRe.exec(value))) {
      if (m.index > last) segs.push(escapeLiteral(value.slice(last, m.index)));
      const v = resolveRef(m[0], nodeId);
      segs.push(v ? `%${v}%` : escapeLiteral(m[0]));
      last = m.index + m[0].length;
    }
    if (last < value.length) segs.push(escapeLiteral(value.slice(last)));
    return `$'''${segs.join("")}'''`;
  }

  return formatValue(value, paramType, action);
}

/**
 * Reference substitution inside an expression: {{2.Field}} / {{variables.X}} → bare variable name
 * Only reference fragments are replaced; the expression itself (comparison operators, function calls) is left untouched
 */
function resolveExpression(s, nodeId) {
  if (typeof s !== "string") return s;
  return s.replace(/\{\{\d+\.\w+\}\}|\{\{(?:config|variables)\.\w+\}\}|\{\{\w+\}\}/g,
    (m) => resolveRef(m, nodeId) || m);
}

// ── Safety gates ──────────────────────────────────────────────
const errors = [];
const warnings = [];

function gate(node, msg) {
  errors.push(`node ${node.id} "${node.label || node.type}": ${msg}`);
}

// ── Generate variable initializations ─────────────────────────
const lines = [];
if (flow.variables && flow.variables.length) {
  for (const v of flow.variables) {
    if (v.comment) lines.push(`# ${v.comment}`);
    // deployKey: at deploy time pad-deploy replaces {{KEY}} with the config value, so no real account/path lands in the repo
    let val;
    if (v.deployKey) {
      val = formatString(`{{${v.deployKey}}}`);
    } else if (v.default !== undefined && v.default !== null) {
      val = v.type === "number" ? v.default :
            v.type === "boolean" ? (v.default ? "True" : "False") :
            formatString(v.default);
    }
    if (val !== undefined) {
      lines.push(`SET ${v.name} TO ${val}`);
      definedVars.add(v.name);
    } else {
      // No default value: emit a comment as a reminder
      lines.push(`# TODO: variable ${v.name} (${v.type}) has no default value; set it as an input variable in PAD or supply a value`);
      warnings.push(`variable ${v.name} has no default value`);
    }
  }
  if (flow.variables.length) lines.push("");
}

// Child nodes "swallowed" by control-flow nodes (skipped in the main loop so they are not generated twice)
const consumed = new Set();

/**
 * Emit one line of action code.
 * When a node has on_error="continue", generate an empty handler the way PAD's "continue on error → go to next action" does:
 *   <action line>
 *   ON ERROR
 *   END
 */
function pushActionLine(node, parts) {
  const actionLine = parts.join(" ");
  lines.push(actionLine);
  if (node.on_error === "continue") {
    lines.push("ON ERROR");
    lines.push("END");
  }
}

// ── Generate nodes ────────────────────────────────────────────
for (const node of flow.nodes) {
  if (consumed.has(node.id)) continue;  // already generated as the body of some control-flow node

  const padHint = node.pad_hint;

  // Control-flow node
  if (CONTROL_FLOW.has(padHint)) {
    generateControlFlow(node);
    continue;
  }

  // WAIT node: Robin's built-in wait statement (like SET/IF/LOOP, it is not in the KB action table)
  if (node.type === "wait" || padHint === "WAIT") {
    lines.push(`WAIT ${waitSeconds(node)}`);
    continue;
  }

  // Loop-exit node: Robin's built-in EXIT LOOP (only appears inside a LOOP body)
  if (node.type === "break" || padHint === "EXIT LOOP" || padHint === "EXIT_LOOP") {
    lines.push(`EXIT LOOP`);
    continue;
  }

  // Look up the KB
  const action = actionMap.get(padHint);
  if (!action) {
    gate(node, `unknown action pad_hint="${padHint}" (not found in the KB; refusing to generate)`);
    continue;
  }

  // UI selector gate
  if (action.needs_ui_selector) {
    gate(node, `action ${padHint} needs a UI selector (needs_ui_selector=true); it cannot be generated automatically, record the element in PAD first`);
    continue;
  }

  // Check that the keys in params are valid
  const validParamNames = new Set(action.input_params.map((p) => p.name));
  for (const key of Object.keys(node.params || {})) {
    if (!validParamNames.has(key)) {
      gate(node, `unknown parameter "${key}" (valid parameters for ${padHint}: ${[...validParamNames].join(", ")})`);
    }
  }

  // Build the action line
  const parts = [padHint];
  const params = node.params || {};

  for (const p of action.input_params) {
    let rawVal = params[p.name];
    let val;

    if (rawVal !== undefined && rawVal !== null) {
      // 1. Explicitly given by the flow
      val = resolveParamValue(rawVal, p.type, action, node.id);
    } else if (isHandleType(p.type)) {
      // 2. Handle type: auto-wire the variable produced by an upstream Launch
      const base = handleBaseName(p.type);
      const hv = handleVars[base];
      if (hv) {
        val = hv;
      } else if (p.default) {
        val = p.default;
      } else {
        gate(node, `parameter ${p.name} (type ${p.type}) needs a handle variable, but no Launch action in the flow produces that handle`);
        val = base; // placeholder
      }
    } else if (p.default !== undefined) {
      // 3. KB default value
      val = formatValue(p.default, p.type, action);
    } else {
      // 4. Not supplied and no default: omit the parameter entirely (same as the KB golden style, so no placeholder junk gets written)
      continue;
    }

    parts.push(`${p.name}: ${val}`);
  }

  // Output binding
  // output_skip: the node declares "these outputs are not bound to variables" (for cleanup/open actions where only execution matters),
  // same meaning as leaving the output blank in PAD; handle outputs cannot be skipped, otherwise later actions have no handle
  const skipOutputs = new Set(node.output_skip || []);
  for (const op of action.output_params) {
    if (skipOutputs.has(op.name)) {
      if (isHandleType(op.type)) {
        gate(node, `output_skip cannot skip handle output ${op.name} (later actions depend on this handle)`);
      }
      continue;
    }
    // Use the type-derived variable name for handle types (OutlookInstance / ExcelInstance) so they do not all collide as Instance
    const outputName = outputVarName(node, action, op);
    parts.push(`${op.name}=> ${outputName}`);
    definedVars.add(outputName);
    // Record the produced handle
    if (isHandleType(op.type)) {
      handleVars[handleBaseName(op.type)] = outputName;
    }
  }

  pushActionLine(node, parts);
}

// ── Control-flow generation ───────────────────────────────────
function generateControlFlow(node) {
  // Collect every child node id that this control-flow node "swallows"
  const allBody = [];
  let ifTrue = [];
  let ifFalse = [];
  if (node.pad_hint === "IF" && node.branch) {
    // true branch: prefer the trueBody / body array, fall back to the single node in branch.true
    if (Array.isArray(node.branch.trueBody)) ifTrue = node.branch.trueBody.slice();
    else if (Array.isArray(node.branch.body)) ifTrue = node.branch.body.slice();
    else if (node.branch.true != null) ifTrue = [String(node.branch.true)];
    // false branch: prefer the falseBody array; fall back to the single node in branch.false,
    // and only when it is not in next (i.e. it is not the merge point after the IF) does it count as a standalone else branch
    if (Array.isArray(node.branch.falseBody)) ifFalse = node.branch.falseBody.slice();
    else if (node.branch.false != null) {
      const f = String(node.branch.false);
      if (!(node.next || []).includes(f)) ifFalse = [f];
    }
    allBody.push(...ifTrue, ...ifFalse);
  }
  if (node.pad_hint === "LOOP" && node.loop && node.loop.body) {
    allBody.push(...node.loop.body);
  }
  if (node.pad_hint === "SWITCH" && node.switch) {
    for (const c of node.switch.cases || []) allBody.push(...(c.body || []));
    if (node.switch.default) allBody.push(...node.switch.default);
  }
  // guard: side-effect guard (e.g. DRY_RUN), semantically IF + ELSE, but recognizable by type to the admission gate
  if (node.pad_hint === "GUARD") {
    allBody.push(...(node.body || []), ...(node.elseBody || []));
  }
  // Child generation: nodes already swallowed by an "inner control-flow" must be skipped, otherwise the outer one emits them again.
  // That is why consumed is registered after generation: the inner one generates and registers its children first,
  // so when the outer one later walks over them they are skipped.
  const emit = (bid) => {
    if (consumed.has(bid)) return;
    const child = flow.nodes.find((n) => n.id === bid);
    if (child) generateNodeInline(child);
  };

  if (node.pad_hint === "IF") {
    const cond = node.params && node.params.Condition ? resolveExpression(node.params.Condition, node.id) : "True";
    lines.push(`IF ${cond} THEN`);
    // true branch
    for (const bid of ifTrue) emit(bid);
    // false branch: emit ELSE only when a standalone else exists, so the merge point after next is not emitted twice
    if (ifFalse.length) {
      lines.push(`ELSE`);
      for (const bid of ifFalse) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "GUARD") {
    const cond = resolveExpression(node.when || "True", node.id);
    lines.push(`IF ${cond} THEN`);
    for (const bid of node.body || []) emit(bid);
    if ((node.elseBody || []).length) {
      lines.push(`ELSE`);
      for (const bid of node.elseBody) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "LOOP") {
    const lp = node.loop || {};
    if (lp.kind === "foreach") {
      const listVar = resolveRef(lp.list, node.id) || lp.list;
      lines.push(`LOOP FOREACH ${lp.item} IN ${listVar}`);
    } else if (lp.kind === "fromto") {
      lines.push(`LOOP ${lp.index} FROM ${lp.from} TO ${lp.to} STEP ${lp.step || 1}`);
    } else if (lp.kind === "while") {
      lines.push(`LOOP WHILE ${lp.condition}`);
    }
    if (lp.body) {
      for (const bid of lp.body) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "SWITCH") {
    const sw = node.switch || {};
    lines.push(`SWITCH ${resolveExpression(sw.expression, node.id)}`);
    for (const c of sw.cases || []) {
      lines.push(`CASE ${c.case}`);
      for (const bid of c.body || []) emit(bid);
    }
    if (sw.default) {
      lines.push(`DEFAULT`);
      for (const bid of sw.default) emit(bid);
    }
    lines.push(`END`);
  }

  // Register the nodes swallowed at this level so upper levels / the main loop skip them
  for (const bid of allBody) consumed.add(bid);
}

function generateNodeInline(node) {
  // Simplified: inline nodes do not re-enter the main loop and emit one line directly (nested control flow is only supported one level deep for now)
  if (CONTROL_FLOW.has(node.pad_hint)) {
    generateControlFlow(node);
    return;
  }
  // WAIT node: Robin's built-in wait statement
  if (node.type === "wait" || node.pad_hint === "WAIT") {
    lines.push(`WAIT ${waitSeconds(node)}`);
    return;
  }
  // Loop-exit node: Robin's built-in EXIT LOOP
  if (node.type === "break" || node.pad_hint === "EXIT LOOP" || node.pad_hint === "EXIT_LOOP") {
    lines.push(`EXIT LOOP`);
    return;
  }
  const action = actionMap.get(node.pad_hint);
  if (!action) {
    gate(node, `unknown action pad_hint="${node.pad_hint}"`);
    return;
  }
  if (action.needs_ui_selector) {
    gate(node, `action ${node.pad_hint} needs a UI selector`);
    return;
  }
  const parts = [node.pad_hint];
  const params = node.params || {};
  for (const p of action.input_params) {
    let rawVal = params[p.name];
    let val;
    if (rawVal !== undefined && rawVal !== null) {
      val = resolveParamValue(rawVal, p.type, action, node.id);
    } else if (isHandleType(p.type)) {
      const base = handleBaseName(p.type);
      val = handleVars[base] || base;
    } else if (p.default !== undefined) {
      val = formatValue(p.default, p.type, action);
    } else {
      // Not supplied and no default: omit the parameter entirely (same as the KB golden style, so no placeholder junk gets written)
      continue;
    }
    parts.push(`${p.name}: ${val}`);
  }
  // output_skip: same rule as the main loop — skipped outputs are not bound to variables
  const skipOutputs = new Set(node.output_skip || []);
  for (const op of action.output_params) {
    if (skipOutputs.has(op.name)) {
      if (isHandleType(op.type)) {
        gate(node, `output_skip cannot skip handle output ${op.name} (later actions depend on this handle)`);
      }
      continue;
    }
    const outputName = outputVarName(node, action, op);
    parts.push(`${op.name}=> ${outputName}`);
    if (isHandleType(op.type)) handleVars[handleBaseName(op.type)] = outputName;
  }
  pushActionLine(node, parts);
}

/** Read the default variable name of an output parameter from the KB golden_example (e.g. ExitCode=> CommandExitCode) */
function goldenOutputName(action, outName) {
  const golden = action.golden_example || "";
  const m = golden.match(new RegExp(`${outName}\\s*=>\\s*(\\w+)`));
  return m ? m[1] : null;
}

/** Compute the variable name for an output parameter binding: node output_map > KB defaultVariable > golden default name > handle type derivation > parameter name */
function outputVarName(node, action, op) {
  const map = node.output_map || {};
  if (map[op.name]) return map[op.name];
  return op.defaultVariable ||
         goldenOutputName(action, op.name) ||
         (isHandleType(op.type) ? handleBaseName(op.type) : op.name);
}

// ── Dangling reference check ──────────────────────────────────
// (Simplified: check that the node id of every {{ref}} exists and that the field is an output of that node)
for (const node of flow.nodes) {
  if (!node.params) continue;
  for (const [key, val] of Object.entries(node.params)) {
    if (typeof val !== "string") continue;
    const refs = val.match(/\{\{(\d+)\.(\w+)\}\}/g) || [];
    for (const ref of refs) {
      const m = ref.match(/\{\{(\d+)\.(\w+)\}\}/);
      const srcNode = flow.nodes.find((n) => n.id === m[1]);
      if (!srcNode) {
        gate(node, `parameter ${key} references a non-existent node ${m[1]}`);
      }
    }
  }
}

// ── Emit the result ───────────────────────────────────────────
const output = lines.join("\n") + "\n";

if (errors.length) {
  console.error("=== Generator safety gate rejected the flow ===");
  for (const e of errors) console.error("  x " + e);
  console.error(`\n${errors.length} error(s); nothing was generated. Fix flow.json and run again.`);
  process.exit(1);
}

if (warnings.length) {
  console.error("=== Warnings ===");
  for (const w of warnings) console.error("  ! " + w);
}

// Write the file
if (outPath) {
  fs.writeFileSync(outPath, output, "utf8");
  console.error(`Generated: ${outPath} (${flow.nodes.length} nodes)`);
} else {
  process.stdout.write(output);
}

// ── Static self-check ─────────────────────────────────────────
// The single source of truth for the rules is tools/pad-robin/check-flows.js in this repo.
// The KB directory also holds an upstream-cloned copy (marketing/video/tools/check-flows.js);
// that is a historical artifact of an external repo and the two have diverged, so it is never used here — otherwise "self-check passes but check.js fails".
if (!noCheck && outPath) {
  const checkFlows = path.join(__dirname, "check-flows.js");
  if (fs.existsSync(checkFlows)) {
    try {
      execFileSync(process.execPath, [checkFlows, kbPath, outPath], { stdio: "inherit" });
      console.error("Static check: passed");
    } catch (e) {
      console.error("Static check: issues found (see the check-flows output above)");
      process.exit(1);
    }
  } else {
    console.error(`[skipped] check-flows.js not found (expected path: ${checkFlows})`);
  }
}
