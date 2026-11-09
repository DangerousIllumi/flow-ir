// lint-robin.js — Robin script "flow hygiene" checks (a subset of the rules in the PAD designer's top-right flow checker)
//
// Three rules, all read-only and warning-only; check.js's exit code is never affected:
//   1) unused-output  an action captured an output variable that nothing reads afterwards
//   2) unused-var     SET declared a variable that nothing reads afterwards
//   3) nested-if      IF nesting is too deep (threshold defaults to 3 levels; anything deeper is flagged)
//
// Why this lives in an offline tool: the designer's "Apply fix" edits the canvas directly and makes flow.json drift from the live flow;
// here we only warn, and fixes still go back into flow.json.

const RULE_UNUSED_OUTPUT = "unused-output";
const RULE_UNUSED_VAR = "unused-var";
const RULE_NESTED_IF = "nested-if";

// Default nesting threshold: warn when IF depth exceeds 3 (matches what the designer actually flags)
const DEFAULT_MAX_IF_DEPTH = 3;

// Erase an identifier from its definition sites; if it still shows up in the remaining text, it has been read
function stripDefinitions(text, names) {
  let out = text;
  for (const name of names) {
    const esc = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // Output capture: Xxx=> Name
    out = out.replace(new RegExp(`\\w+=>\\s*${esc}\\b`, "g"), "");
    // Variable declaration: SET Name TO / SET Name =
    out = out.replace(new RegExp(`^\\s*SET\\s+${esc}\\s+(TO|=)`, "gim"), "");
  }
  return out;
}

function isUsed(text, name) {
  // The variable shows up in an expression: %Name%, Name.Property, or a bare identifier
  const esc = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9_])${esc}([^A-Za-z0-9_]|$)`, "i").test(text);
}

/**
 * Analyze a piece of Robin text.
 * @param {string} text
 * @param {{maxIfDepth?: number}} [opts]
 * @returns {{warnings: Array<{rule:string,line:number,message:string}>, stats: object}}
 */
function lintRobin(text, opts = {}) {
  const maxIfDepth = Number.isInteger(opts.maxIfDepth) ? opts.maxIfDepth : DEFAULT_MAX_IF_DEPTH;
  const lines = String(text).split(/\r?\n/);
  const codeLines = lines.filter((l) => !/^\s*#/.test(l));
  const code = codeLines.join("\n");

  // ── Collect definitions ────────────────────────────────────
  const outputs = []; // {name, line}
  const declared = []; // {name, line}
  lines.forEach((raw, i) => {
    const line = i + 1;
    if (/^\s*#/.test(raw)) return;
    const outRe = /(\w+)=>\s*([A-Za-z_][A-Za-z0-9_]*)/g;
    let m;
    while ((m = outRe.exec(raw)) !== null) outputs.push({ name: m[2], line });
    const setRe = /^\s*SET\s+([A-Za-z_][A-Za-z0-9_]*)\s+(TO|=)\b/i;
    const sm = setRe.exec(raw);
    if (sm) declared.push({ name: sm[1], line });
  });

  const warnings = [];

  // ── Rule 1: captured but never read ────────────────────────
  const names = [...new Set(outputs.map((o) => o.name))];
  const usageText = stripDefinitions(code, names);
  const seenOutput = new Set();
  for (const o of outputs) {
    if (seenOutput.has(o.name)) continue;
    seenOutput.add(o.name);
    if (!isUsed(usageText, o.name)) {
      warnings.push({
        rule: RULE_UNUSED_OUTPUT,
        line: o.line,
        message: `output variable ${o.name} is captured but never used (leave it empty if you don't need it)`,
      });
    }
  }

  // ── Rule 2: declared but never read ────────────────────────
  const declNames = [...new Set(declared.map((d) => d.name))];
  const declUsage = stripDefinitions(code, declNames);
  const seenDecl = new Set();
  for (const d of declared) {
    if (seenDecl.has(d.name)) continue;
    seenDecl.add(d.name);
    // Only counts as unused when there is still no reference after the variable's last declaration
    if (!isUsed(declUsage, d.name)) {
      warnings.push({
        rule: RULE_UNUSED_VAR,
        line: d.line,
        message: `variable ${d.name} is declared but never referenced`,
      });
    }
  }

  // ── Rule 3: IF nested too deep ──────────────────────────────
  const stack = [];
  let ifDepth = 0;
  const depthHistogram = {};
  lines.forEach((raw, i) => {
    const line = i + 1;
    const t = raw.trim();
    if (!t || t.startsWith("#")) return;
    if (/^IF\b/i.test(t) && /\bTHEN\s*$/i.test(t)) {
      stack.push("IF");
      ifDepth += 1;
      depthHistogram[ifDepth] = (depthHistogram[ifDepth] || 0) + 1;
      if (ifDepth > maxIfDepth) {
        warnings.push({
          rule: RULE_NESTED_IF,
          line,
          message: `IF nested ${ifDepth} levels (limit ${maxIfDepth}); consider an early exit or merged conditions`,
        });
      }
      return;
    }
    if (/^(LOOP|FOR\s+EACH|SWITCH|WHILE|REPEAT)\b/i.test(t)) {
      stack.push("BLOCK");
      return;
    }
    if (/^END\b/i.test(t)) {
      const top = stack.pop();
      if (top === "IF") ifDepth -= 1;
      return;
    }
  });

  return {
    warnings,
    stats: {
      outputs: names.length,
      declared: declNames.length,
      ifDepthHistogram: depthHistogram,
      maxIfDepth,
    },
  };
}

// ── CLI ────────────────────────────────────────────────────
if (require.main === module) {
  const fs = require("fs");
  const file = process.argv[2];
  if (!file) {
    console.error("Usage: node lint-robin.js <file.robin> [--max-if-depth N]");
    process.exit(1);
  }
  const idx = process.argv.indexOf("--max-if-depth");
  const opts = idx > 0 ? { maxIfDepth: parseInt(process.argv[idx + 1], 10) } : {};
  const text = fs.readFileSync(file, "utf8");
  const { warnings, stats } = lintRobin(text, opts);
  for (const w of warnings) console.log(`[lint] line ${w.line} ${w.rule}: ${w.message}`);
  const byRule = {};
  for (const w of warnings) byRule[w.rule] = (byRule[w.rule] || 0) + 1;
  const summary = Object.entries(byRule).map(([k, v]) => `${k}=${v}`).join(" ") || "no warnings";
  console.log(`[lint] ${file}: ${summary} (output variables ${stats.outputs} / declared variables ${stats.declared})`);
  process.exit(0);
}

module.exports = { lintRobin, RULE_UNUSED_OUTPUT, RULE_UNUSED_VAR, RULE_NESTED_IF };
