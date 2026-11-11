#!/usr/bin/env node
/**
 * eval-flow.js — design-quality evaluation set: asserts the structure of flow.json against the requirement text
 *
 * Structure only, never wording (D6). Two ways to use it:
 *   node eval-flow.js tests/eval/<name>.cases.json                  # a single case file
 *   node eval-flow.js tests/eval                                   # a directory: run every *.cases.json inside
 *
 * In a case file, `flow` points at the flow.json under test; in directory mode each case file carries its own flow.
 * Exit codes: 0 all pass / 1 some failed / 2 input error
 */

const fs = require("fs");
const path = require("path");

// Allowed node run modes: fully automatic / needs human confirmation / read-only observation
const RUN_MODES = ["auto", "confirm", "observe"];

// Allowed values for the trigger declaration.
// Same rules as pad-admit's TRIGGER check: reserved values are listed separately so we can report "supported but not implemented" instead of "typo".
const TRIGGER_KINDS = ["manual", "schedule", "file"];
const TRIGGER_RESERVED_KINDS = ["mail", "callback"];
const TRIGGER_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const TRIGGER_GATES = ["none", "workday", "last-workday"];
// HH:mm — only the two-digit 24-hour form is accepted; single-digit forms like 9:00 are rejected outright so registration never has to guess
const TRIGGER_TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

// Positive-integer check: a string or a decimal in JSON is rejected outright
function isPositiveInt(v) {
  return typeof v === "number" && Number.isFinite(v) && v > 0 && Number.isInteger(v);
}

// Known-irreversible actions: once done they cannot be taken back, so declaring reversible=true is factually wrong and fails the check.
// Sending mail, deleting files/directories, posting scripts (recognized by intent, not by parameter name).
// Exact match only — substring matching was too broad (it flagged migo-precheck, which only reads)
// and too narrow at the other end (it missed clean-attachments, which deletes via RunDOSCommand).
// intent_destructive is the primary signal; this regex is the fallback for legacy flows.
const POSTING_INTENT_RE = /^(sap-migo|posting)$/i;
// Destructive action hints: actions that modify or remove data and cannot be auto-undone.
// Enumerated from pad-robin-action-kb/PAD_Robin_ActionKB.json — every actionId listed here
// is verified to exist in the KB. The old regex ^(File|Folder)\.Delete$ was anchored with $,
// which missed File.Move / File.RenameFiles.* / Folder.Move / Folder.Rename and every
// destructive action outside the File and Folder modules (Excel, FTP, Outlook, PowerPoint, …).
const DESTRUCTIVE_HINT_RE = /^(File\.(Delete|Move|RenameFiles\.)|Folder\.(Delete|Move|Rename$)|Excel\.(DeleteCells\.|DeleteColumn|DeleteRow|DeleteWorksheet\.|RenameWorksheet\.)|FTP\.(DeleteDirectory|DeleteFiles|RenameFile)|Outlook\.ProcessEmailMessages\.(DeleteEmails|MoveEmails)|PowerPoint\.(DeletePowerPointSlide\.|MovePowerPointSlide)|System\.DeleteEnvironmentVariable|XML\.(RemoveElement|RemoveElementAttribute)|Email\.ProcessEmails\.Move|Exchange\.ProcessExchangeMessages\.MoveEmails)/i;
function irreversibleReason(n) {
  const hint = String((n && n.pad_hint) || "");
  if (/^Outlook\.SendEmail/i.test(hint)) return "sending mail cannot be undone; only a corrective resend is possible";
  if (DESTRUCTIVE_HINT_RE.test(hint)) return "deleting/moving/renaming files or directories cannot be undone";
  if (/^Scripting\.(RunDOSCommand|RunVBScript)/i.test(hint) && POSTING_INTENT_RE.test(String((n && n.intent) || ""))) {
    return "re-running a posting script creates duplicate documents; only a reversing entry can correct it";
  }
  return null;
}

// Full reversibility check: must be a boolean; false requires an explanation; a known-irreversible action may not claim true.
function reversibleProblems(n) {
  const problems = [];
  if (typeof n.reversible !== "boolean") {
    problems.push(`reversible=${JSON.stringify(n.reversible)} (expected true/false)`);
    return problems;
  }
  if (n.reversible === false && !String(n.reversibility_note || "").trim()) {
    problems.push("reversible=false requires reversibility_note (explain how to roll back)");
  }
  const reason = irreversibleReason(n);
  if (reason && n.reversible === true) {
    problems.push(`action ${n.pad_hint} is irreversible (${reason}); reversible must be false`);
  }
  return problems;
}

/**
 * Validate a trigger declaration; returns { errors, warnings } with entries shaped { code, detail }.
 * Contract validation only — the local registration state is checked by pad-trigger / pad-admit -TriggerLive.
 * Result codes match section 4.2 of docs/trigger-adapter-design.md.
 */
function validateTrigger(flow, trg, opts = {}) {
  const errors = [];
  const warnings = [];
  const err = (code, detail) => errors.push({ code, detail });
  const warn = (code, detail) => warnings.push({ code, detail });

  if (trg === undefined || trg === null) {
    return { errors: [{ code: "TRIGGER_MISSING", detail: "missing trigger declaration" }], warnings };
  }
  if (!isPlainObject(trg)) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: "trigger must be an object" }], warnings };
  }
  // Legacy shape: type/config only, no kind — never silently map it
  if (!hasOwn(trg, "kind") && hasOwn(trg, "type")) {
    return { errors: [{ code: "TRIGGER_LEGACY_SHAPE", detail: "legacy type/config shape without kind" }], warnings };
  }
  if (typeof trg.kind !== "string" || !trg.kind) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: `kind=${JSON.stringify(trg.kind)} (must be a string)` }], warnings };
  }
  if (TRIGGER_RESERVED_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_KIND_UNSUPPORTED", detail: `kind=${trg.kind} is a reserved value; v1 has no registrar for it` }], warnings };
  }
  if (!TRIGGER_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_UNKNOWN_KIND", detail: `kind=${trg.kind} is not one of ${TRIGGER_KINDS.join("/")}` }], warnings };
  }
  const kind = trg.kind;

  // Task name: when supplied it must use safe characters, otherwise the scheduled task name cannot be reproduced reliably
  if (hasOwn(trg, "task_name")) {
    const tn = trg.task_name;
    if (typeof tn !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(tn)) {
      err("TRIGGER_INVALID", `task_name=${JSON.stringify(tn)} does not match ^[A-Za-z0-9._-]{1,64}$`);
    }
  }

  if (kind === "manual") {
    for (const key of ["time", "days", "gate", "timeout_sec", "file", "assisted"]) {
      if (hasOwn(trg, key)) err("TRIGGER_INVALID", `manual must not declare ${key} (nothing would execute it)`);
    }
    return { errors, warnings };
  }

  // Shared by schedule / file: time of day, weekday, calendar gate, timeout
  const time = hasOwn(trg, "time") ? trg.time : undefined;
  if (typeof time !== "string" || !TRIGGER_TIME_RE.test(time)) {
    err("TRIGGER_INVALID", `time=${JSON.stringify(time)} (expected HH:mm, e.g. 09:00)`);
  }
  if (hasOwn(trg, "days")) {
    if (!Array.isArray(trg.days) || trg.days.length === 0) {
      err("TRIGGER_INVALID", `days=${JSON.stringify(trg.days)} (expected a non-empty array)`);
    } else if (trg.days.some((d) => !TRIGGER_DAYS.includes(d))) {
      err("TRIGGER_INVALID", `days contains invalid values: ${JSON.stringify(trg.days.filter((d) => !TRIGGER_DAYS.includes(d)))}`);
    }
  }
  if (hasOwn(trg, "gate")) {
    if (!TRIGGER_GATES.includes(trg.gate)) {
      err("TRIGGER_INVALID", `gate=${JSON.stringify(trg.gate)} is not one of ${TRIGGER_GATES.join("/")}`);
    }
  } else if (kind === "schedule") {
    warn("TRIGGER_NO_GATE", "schedule declares no gate, so it will still run on holidays (write gate=none explicitly if that is intended)");
  }
  if (hasOwn(trg, "timeout_sec") && !isPositiveInt(trg.timeout_sec)) {
    err("TRIGGER_INVALID", `timeout_sec=${JSON.stringify(trg.timeout_sec)} (expected a positive integer number of seconds)`);
  }

  // assisted: start automatically at the scheduled time but let a human confirm midway; only meaningful for schedule/file, manual already rejected it above
  let assisted = false;
  if (hasOwn(trg, "assisted")) {
    if (typeof trg.assisted !== "boolean") {
      err("TRIGGER_INVALID", `assisted=${JSON.stringify(trg.assisted)} (expected true/false)`);
    } else {
      assisted = trg.assisted;
    }
    if (assisted && !hasOwn(trg, "timeout_sec")) {
      err("TRIGGER_ASSISTED_NO_TIMEOUT", "assisted=true requires an explicit timeout_sec (the timeout alert is the fallback when nobody confirms)");
    }
  }

  if (kind === "file") {
    if (!hasOwn(trg, "file") || !isPlainObject(trg.file)) {
      err("TRIGGER_INVALID", "file trigger requires a file object");
    } else {
      const f = trg.file;
      const dir = hasOwn(f, "dir") ? f.dir : undefined;
      if (typeof dir !== "string" || !dir) {
        err("TRIGGER_INVALID", "file.dir is required");
      } else if (!/^\{\{config\.\w+\}\}$/.test(dir)) {
        // Only config references are accepted; absolute paths must never be written into flow.json
        err("TRIGGER_PATH_LITERAL", `file.dir=${dir} must be a {{config.<KEY>}} reference, not a literal path`);
      }
      if (typeof f.pattern !== "string" || !f.pattern.trim()) {
        err("TRIGGER_INVALID", "file.pattern is required and must not be empty");
      }
      for (const key of ["poll_sec", "settle_sec", "max_wait_sec"]) {
        if (hasOwn(f, key) && !isPositiveInt(f[key])) {
          err("TRIGGER_INVALID", `file.${key}=${JSON.stringify(f[key])} (expected a positive integer number of seconds)`);
        }
      }
      if (hasOwn(f, "once_per_file") && typeof f.once_per_file !== "boolean") {
        err("TRIGGER_INVALID", `file.once_per_file=${JSON.stringify(f.once_per_file)} (expected true/false)`);
      }
    }
  }

  // Cross-check against node declarations: only applies to a "real flow"; a def passed from an assertion only validates declaration shape and is not paired with flow nodes
  if (!opts.skipCrossCheck) {
    const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];
    const confirmNodes = nodes.filter((n) => n && n.run_mode === "confirm");
    if (confirmNodes.length > 0 && assisted !== true) {
      err("TRIGGER_UNATTENDED_CONFIRM", `unattended trigger but nodes require manual confirmation: ${confirmNodes.map((n) => n.id).join(",")}`);
    }
    // Reversibility is narrowed down: it is orthogonal to idempotency, so idempotent=false no longer stands for consequence risk.
    //   idempotent = whether re-running the same input converges (safe to rerun)
    //   reversible = whether the consequence already produced can be undone (deletions can be rebuilt, mail can be corrected, postings can only be reversed)
    const irreversible = nodes.filter((n) => n && n.reversible === false);
    if (irreversible.length > 0) {
      warn("TRIGGER_UNATTENDED_IRREVERSIBLE",
        `unattended trigger but nodes have irreversible consequences: ${irreversible
          .map((n) => `${n.id}${n.reversibility_note ? `（${n.reversibility_note}）` : ""}`)
          .join("、")}`);
    }
    // Script nodes (RunDOSCommand / RunVBScript) must declare reversible regardless of idempotency:
    // a script can read or write files, and the gate cannot tell from pad_hint alone.
    const scriptMissingRev = nodes.filter(
      (n) => n && /^Scripting\.(RunDOSCommand|RunVBScript)/i.test(String((n && n.pad_hint) || "")) && !hasOwn(n, "reversible"));
    if (scriptMissingRev.length > 0) {
      err("TRIGGER_MISSING_REVERSIBILITY",
        `script nodes (RunDOSCommand/RunVBScript) must declare reversible; the gate cannot tell from pad_hint alone whether it reads or writes: ${scriptMissingRev.map((n) => n.id).join(",")}`);
    }
    // idempotent=false but no reversible declared (non-script nodes): ask for the missing declaration, never fill it in by default
    const missingRev = nodes.filter(
      (n) => n && n.idempotent === false && !hasOwn(n, "reversible") &&
      !/^Scripting\.(RunDOSCommand|RunVBScript)/i.test(String((n && n.pad_hint) || "")));
    if (missingRev.length > 0) {
      warn("TRIGGER_MISSING_REVERSIBILITY",
        `nodes with idempotent=false declare no reversible: ${missingRev.map((n) => n.id).join(",")}`);
    }

    // intent_destructive: the primary signal for script nodes. pad_hint alone cannot tell a read script from a delete script.
    const scriptNodes = nodes.filter(
      (n) => n && /^Scripting\.(RunDOSCommand|RunVBScript)/i.test(String((n && n.pad_hint) || "")) && hasOwn(n, "intent"));
    // 1. Script node with intent but no intent_destructive: ask for the declaration.
    const missingDestructive = scriptNodes.filter((n) => !hasOwn(n, "intent_destructive"));
    if (missingDestructive.length > 0) {
      err("INTENT_DESTRUCTIVE_MISSING",
        `script nodes have intent but no intent_destructive; declare whether the script deletes or overwrites data: ${missingDestructive.map((n) => n.id).join(",")}`);
    }
    // 2. intent_destructive must be a boolean.
    const badDestructive = scriptNodes.filter((n) => hasOwn(n, "intent_destructive") && typeof n.intent_destructive !== "boolean");
    if (badDestructive.length > 0) {
      err("INTENT_DESTRUCTIVE_INVALID",
        `intent_destructive must be a boolean (true/false): ${badDestructive.map((n) => n.id).join(",")}`);
    }
    // 3. intent_destructive=true with no reversibility_note: the script self-declares as destructive, so the rollback
    //    path must be stated in words. reversible may still be true here — a cleanup script whose deletions are
    //    regenerated by a rerun is exactly the legal pattern — so reversible is deliberately not part of this predicate.
    //    The missing note is what fails. Mirrors pad-admit's INTENT_DESTRUCTIVE_NO_NOTE (§2.2b of docs/admission-gate.md).
    const noNote = scriptNodes.filter(
      (n) => hasOwn(n, "intent_destructive") && n.intent_destructive === true &&
        (!hasOwn(n, "reversibility_note") || n.reversibility_note === null || String(n.reversibility_note || "").trim() === ""));
    if (noNote.length > 0) {
      err("INTENT_DESTRUCTIVE_NO_NOTE",
        `intent_destructive=true requires reversibility_note explaining the rollback path: ${noNote.map((n) => n.id).join(",")}`);
    }
    // 4. Same intent value with different intent_destructive across nodes: a factual conflict.
    const byIntent = {};
    for (const n of scriptNodes) {
      if (!hasOwn(n, "intent_destructive")) continue;
      const iv = String(n.intent);
      if (!byIntent[iv]) byIntent[iv] = new Set();
      byIntent[iv].add(n.intent_destructive);
    }
    const intentConflicts = [];
    for (const iv of Object.keys(byIntent)) {
      if (byIntent[iv].size > 1) {
        const nodesWith = scriptNodes
          .filter((n) => String(n.intent) === iv && hasOwn(n, "intent_destructive"))
          .map((n) => `${n.id}=${n.intent_destructive}`)
          .join(", ");
        intentConflicts.push(`${iv}: ${nodesWith}`);
      }
    }
    if (intentConflicts.length > 0) {
      err("INTENT_DESTRUCTIVE_CONFLICT",
        `the same intent value declares different intent_destructive on different nodes: ${intentConflicts.join("; ")}`);
    }
    // 5. Fallback: a known posting intent (migo/posting) must not be self-declared as non-destructive.
    const downgraded = scriptNodes.filter(
      (n) => hasOwn(n, "intent_destructive") && POSTING_INTENT_RE.test(String(n.intent)) && n.intent_destructive !== true);
    if (downgraded.length > 0) {
      err("INTENT_DESTRUCTIVE_DOWNGRADED",
        `a known posting intent (migo/posting) must not declare intent_destructive=false: posting creates documents that can only be reversed by another posting: ${downgraded.map((n) => n.id).join(",")}`);
    }
  }

  return { errors, warnings };
}

// Directory form for input-file declarations (node-level inputs): same rule as the file trigger, only {{config.<KEY>}} is accepted,
// and real paths must never be written into flow.json (both the public layer and the business layer validate this)
const INPUT_DIR_RE = /^\{\{config\.\w+\}\}$/;

/**
 * Validate node-level input-file declarations; returns { errors, warnings } with entries shaped { code, detail }.
 * Declaration shape only — the filesystem is never touched; "directory readable / candidate file count" belongs to pad-admit's INPUT check.
 * An old flow.json without inputs gets a single INPUT_UNDECLARED notice instead of a failure (backward compatible).
 */
function validateInputs(flow, opts = {}) {
  const errors = [];
  const warnings = [];
  const err = (code, detail) => errors.push({ code, detail });
  const warn = (code, detail) => warnings.push({ code, detail });

  const nodes = Array.isArray(flow && flow.nodes) ? flow.nodes : [];
  const targets = opts.node ? nodes.filter((n) => n && n.id === opts.node) : nodes;
  let declared = 0;

  for (const n of targets) {
    if (!hasOwn(n, "inputs")) continue;
    declared++;
    if (!Array.isArray(n.inputs) || n.inputs.length === 0) {
      err("INPUT_INVALID", `node ${n.id}: inputs must be a non-empty array`);
      continue;
    }
    n.inputs.forEach((it, i) => {
      const at = `node ${n.id} inputs[${i}]`;
      if (!isPlainObject(it)) {
        err("INPUT_INVALID", `${at} must be an object`);
        return;
      }
      const dir = it.dir;
      if (typeof dir !== "string" || !dir) {
        err("INPUT_INVALID", `${at}.dir is required`);
      } else if (!INPUT_DIR_RE.test(dir)) {
        err("INPUT_PATH_LITERAL", `${at}.dir=${dir} must be a {{config.<KEY>}} reference, not a literal path`);
      }
      if (typeof it.pattern !== "string" || !it.pattern.trim()) {
        err("INPUT_INVALID", `${at}.pattern is required and must not be empty`);
      }
      // required must be declared explicitly and is never defaulted (same "must answer" rule as run_mode / idempotent)
      if (typeof it.required !== "boolean") {
        err("INPUT_INVALID", `${at}.required=${JSON.stringify(it.required)} (expected true/false)`);
      }
    });
  }

  if (declared === 0) {
    warn("INPUT_UNDECLARED", "no node declares inputs, so input files will not be verified before a run; declare them if the flow depends on input files");
  }
  return { errors, warnings };
}

/** Table of assertion operations: each returns { ok, detail } */
const OPS = {
  // Total node count: pins the structure so it cannot drift again
  nodeCount(flow, a) {
    return { ok: flow.nodes.length === a.equals, detail: `${flow.nodes.length} nodes (expected ${a.equals})` };
  },
  // Generic field assertion: without id it checks the flow top level, with id it checks the node; exists tests presence, equals tests value
  field(flow, a) {
    const target = a.id ? flow.nodes.find((x) => x.id === a.id) : flow;
    if (!target) return { ok: false, detail: `node ${a.id} not found` };
    const v = target[a.name];
    let ok;
    if (Object.prototype.hasOwnProperty.call(a, "exists")) {
      ok = a.exists ? v !== undefined : v === undefined;
    } else if (Object.prototype.hasOwnProperty.call(a, "equals")) {
      ok = JSON.stringify(v) === JSON.stringify(a.equals);
    } else {
      ok = v !== undefined;
    }
    return { ok, detail: `${a.id ? a.id + "." : ""}${a.name}=${JSON.stringify(v)}` };
  },
  // Loops: fromto checks the bounds, foreach checks the iteration variable
  loop(flow, a) {
    const n = flow.nodes.find((x) => (a.id ? x.id === a.id : x.pad_hint === "LOOP"));
    if (!n) return { ok: false, detail: "loop node not found" };
    const lp = n.loop || {};
    if (a.kind === "foreach") {
      return { ok: lp.kind === "foreach" && (!a.item || lp.item === a.item), detail: `FOREACH ${lp.item}` };
    }
    const ok = lp.from === a.from && lp.to === a.to && (lp.step || 1) === (a.step || 1);
    return { ok, detail: `LOOP ${lp.index} ${lp.from}->${lp.to} step ${lp.step || 1}` };
  },
  condition(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const c = (n.params && n.params.Condition) || "";
    return { ok: c.includes(a.contains), detail: `condition=${c}` };
  },
  edge(flow, a) {
    const ok = (flow.edges || []).some((e) => e.from === a.from && e.to === a.to);
    return { ok, detail: `${a.from} -> ${a.to}` };
  },
  // A given action must exist (optionally narrowed to a node id)
  action(flow, a) {
    const n = flow.nodes.find((x) => x.pad_hint === a.padHint && (!a.id || x.id === a.id));
    return { ok: !!n, detail: `${a.padHint}${a.id ? "@" + a.id : ""}` };
  },
  absentMatch(flow, a) {
    const re = new RegExp(a.pattern);
    const hit = flow.nodes.filter((n) => re.test(n.pad_hint || ""));
    return { ok: hit.length === 0, detail: hit.length ? `matched ${hit.map((n) => n.id).join(",")}` : "not present" };
  },
  param(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const v = (n.params || {})[a.name];
    return { ok: JSON.stringify(v) === JSON.stringify(a.equals), detail: `${a.name}=${JSON.stringify(v)}` };
  },
  // Which variable a given field of the output binding (output_map) is bound to
  outputMapEquals(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const v = (n.output_map || {})[a.name];
    return { ok: v === a.equals, detail: `${a.name}=${v}` };
  },
  outputsUnique(flow, a) {
    const nodes = flow.nodes.filter((n) => n.pad_hint === a.padHint);
    const names = nodes.map((n) => ((n.output_map || {}).ButtonPressed) || null);
    const missing = names.filter((x) => !x);
    const uniq = new Set(names);
    const ok = missing.length === 0 && uniq.size === names.length;
    return { ok, detail: `${names.length} nodes, ${uniq.size} distinct variables` };
  },
  guardContains(flow, a) {
    const g = flow.nodes.find((x) => x.id === a.id && x.pad_hint === "GUARD");
    if (!g) return { ok: false, detail: `guard ${a.id} not found` };
    const body = new Set(g.body || []);
    const missing = a.nodes.filter((x) => !body.has(x));
    return { ok: missing.length === 0, detail: missing.length ? `missing ${missing.join(",")}` : `body=[${g.body.join(",")}]` };
  },
  switchCases(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n || !n.switch) return { ok: false, detail: `node ${a.id} is not a SWITCH` };
    const got = (n.switch.cases || []).map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const want = a.cases.map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const ok = JSON.stringify(got) === JSON.stringify(want) && (n.switch.default || []).length > 0;
    return { ok, detail: got.join(" | ") };
  },
  // Node-level must-answers: run mode (auto / confirm / observe) plus idempotency and reversibility (booleans)
  // The design rules say "do not generate flow.json before the user answers", so any missing field fails the check and nothing is defaulted
  nodeDeclaration(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const problems = [];
    if (!RUN_MODES.includes(n.run_mode)) {
      problems.push(`run_mode=${JSON.stringify(n.run_mode)} (expected ${RUN_MODES.join("/")})`);
    }
    if (typeof n.idempotent !== "boolean") {
      problems.push(`idempotent=${JSON.stringify(n.idempotent)} (expected true/false)`);
    } else if (n.idempotent === false && !String(n.idempotency_note || "").trim()) {
      problems.push("idempotent=false requires idempotency_note (an idempotency key or a check-before-write scheme)");
    }
    problems.push(...reversibleProblems(n));
    if (a.runMode && n.run_mode !== a.runMode) problems.push(`run_mode expected ${a.runMode}, got ${n.run_mode}`);
    if (typeof a.idempotent === "boolean" && n.idempotent !== a.idempotent) {
      problems.push(`idempotent expected ${a.idempotent}, got ${n.idempotent}`);
    }
    return { ok: problems.length === 0, detail: problems.length ? problems.join("; ") : `run_mode=${n.run_mode} idempotent=${n.idempotent}` };
  },
  // Whole-flow completeness of must-answers: every node must explicitly declare all three (run_mode / idempotent / reversible); one missing fails
  // reversible=false also requires reversibility_note; claiming true for a known-irreversible action is factually wrong and fails too
  declarationsComplete(flow) {
    const missing = [];
    for (const n of flow.nodes) {
      const problems = [];
      if (!RUN_MODES.includes(n.run_mode)) {
        problems.push(`run_mode=${JSON.stringify(n.run_mode)} (expected ${RUN_MODES.join("/")})`);
      }
      if (typeof n.idempotent !== "boolean") {
        problems.push(`idempotent=${JSON.stringify(n.idempotent)} (expected true/false)`);
      } else if (n.idempotent === false && !String(n.idempotency_note || "").trim()) {
        problems.push("idempotent=false requires idempotency_note (an idempotency key or a check-before-write scheme)");
      }
      problems.push(...reversibleProblems(n));
      if (problems.length) missing.push(`node ${n.id}: ${problems.join("; ")}`);
    }
    return {
      ok: missing.length === 0,
      detail: missing.length ? `${missing.length} node(s) missing declarations: ${missing.slice(0, 12).join(" | ")}${missing.length > 12 ? "..." : ""}` : `all ${flow.nodes.length} nodes are declared`,
    };
  },
  // Trigger assertion: if a.def is given, validate that object (declaration shape only); otherwise validate the flow's own trigger.
  // With a.expect=invalid it asserts "indeed invalid and hitting a.code", so a counter-example cannot be written as a positive case.
  trigger(flow, a) {
    const inline = hasOwn(a, "def");
    const trg = inline ? a.def : flow.trigger;
    const { errors, warnings } = validateTrigger(flow, trg, { skipCrossCheck: inline });
    const codes = [...errors, ...warnings].map((x) => x.code);
    if (a.expect === "invalid") {
      const hit = codes.includes(a.code);
      return { ok: hit, detail: `expected ${a.code}, got ${codes.length ? codes.join(",") : "no errors"}` };
    }
    return {
      ok: errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ") : `trigger=${trg.kind} is valid`,
    };
  },
  // Trigger declared: looks only at the flow's own trigger and does not accept a def override
  triggerComplete(flow) {
    const trg = flow.trigger;
    const { errors } = validateTrigger(flow, trg);
    const kindOk = isPlainObject(trg) && TRIGGER_KINDS.includes(trg.kind);
    return {
      ok: kindOk && errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ") : `trigger=${trg.kind} is declared`,
    };
  },
  // Input-file declaration assertion:
  //   if a.def is given, validate that array (declaration shape only, attached to a synthetic node named inline)
  //   if a.node is given, validate that node only; otherwise the whole flow
  //   a.expect=invalid asserts "indeed invalid and hitting a.code"; a.expect=warning asserts that a given notice code is hit
  inputs(flow, a) {
    let target = flow;
    let opts = {};
    if (hasOwn(a, "def")) {
      target = { nodes: [{ id: "inline", inputs: a.def }] };
    } else if (a.node) {
      const nodes = Array.isArray(flow && flow.nodes) ? flow.nodes : [];
      if (!nodes.some((n) => n && n.id === a.node)) {
        return { ok: false, detail: `node ${a.node} not found` };
      }
      opts = { node: a.node };
    }
    const { errors, warnings } = validateInputs(target, opts);
    const codes = [...errors, ...warnings].map((x) => x.code);
    if (a.expect === "invalid") {
      return {
        ok: codes.includes(a.code),
        detail: `expected ${a.code}, got ${codes.length ? codes.join(",") : "no problems"}`,
      };
    }
    if (a.expect === "warning") {
      return {
        ok: warnings.some((x) => x.code === a.code),
        detail: `expected notice ${a.code}, got ${warnings.length ? warnings.map((x) => x.code).join(",") : "no notices"}`,
      };
    }
    // An undeclared-inputs notice is not a failure: an old flow.json without inputs still passes this op
    return {
      ok: errors.length === 0,
      detail: errors.length
        ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ")
        : `inputs declarations are well-formed${warnings.length ? ` (${warnings.map((x) => x.code).join(",")})` : ""}`,
    };
  },
};

function runCase(flow, c) {
  const results = [];
  for (const a of c.expect || []) {
    const fn = OPS[a.op];
    if (!fn) {
      results.push({ ok: false, detail: `unknown assertion ${a.op}` });
      continue;
    }
    try {
      results.push(fn(flow, a));
    } catch (e) {
      results.push({ ok: false, detail: `assertion threw: ${e.message}` });
    }
  }
  return { id: c.id, requirement: c.requirement, ok: results.every((r) => r.ok), results };
}

function loadCases(file) {
  const spec = JSON.parse(fs.readFileSync(file, "utf8"));
  return { file, flowPath: spec.flow, cases: spec.cases || [] };
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const target = args.find((a) => !a.startsWith("--"));
  if (!target) {
    console.error("Usage: node eval-flow.js <cases.json | directory> [--json]");
    process.exit(2);
  }

  let specs = [];
  try {
    const st = fs.statSync(target);
    if (st.isDirectory()) {
      for (const f of fs.readdirSync(target).filter((x) => x.endsWith(".cases.json")).sort()) {
        specs.push(loadCases(path.join(target, f)));
      }
    } else {
      specs.push(loadCases(target));
    }
  } catch (e) {
    console.error(`[error] read failed: ${e.message}`);
    process.exit(2);
  }
  if (specs.length === 0) {
    console.error(`[error] no *.cases.json under ${target}`);
    process.exit(2);
  }

  const report = [];
  let total = 0;
  let passed = 0;
  for (const s of specs) {
    let flow;
    try {
      flow = JSON.parse(fs.readFileSync(s.flowPath, "utf8"));
    } catch (e) {
      report.push({ flow: s.flowPath, error: e.message, cases: [] });
      continue;
    }
    // A single case may override the flow under test with its own flow, so one assertion set can hold both a positive and a negative case,
    // e.g. the negative case needs a node with run_mode=confirm while the positive case needs a clean flow.
    // The flow under test in every case file unconditionally runs the must-answer completeness check first, no longer relying on cases listing expect explicitly;
    // negative cases that override the flow (deliberately missing fields) are exempt and are judged by their own assertions.
    const baseDecl = OPS.declarationsComplete(flow);
    const cases = [
      {
        id: "declarations-complete",
        requirement: "every node explicitly declares run_mode / idempotent / reversible",
        ok: baseDecl.ok,
        results: [baseDecl],
      },
      ...s.cases.map((c) => {
        if (!c.flow) return runCase(flow, c);
        try {
          const own = JSON.parse(fs.readFileSync(c.flow, "utf8"));
          return runCase(own, c);
        } catch (e) {
          return { id: c.id, requirement: c.requirement, ok: false, results: [{ ok: false, detail: `failed to read the case flow: ${e.message}` }] };
        }
      }),
    ];
    total += cases.length;
    passed += cases.filter((c) => c.ok).length;
    report.push({ flow: s.flowPath, cases });
  }

  if (asJson) {
    console.log(JSON.stringify({ total, passed, files: report }, null, 2));
  } else {
    for (const f of report) {
      if (f.error) {
        console.log(`FAIL  ${f.flow} (read failed: ${f.error})`);
        continue;
      }
      const okCount = f.cases.filter((c) => c.ok).length;
      console.log(`--- ${f.flow}  ${okCount}/${f.cases.length} ---`);
      for (const c of f.cases) {
        console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.id}  requirement: ${c.requirement}`);
        for (const r of c.results.filter((x) => !x.ok)) console.log(`        assertion failed: ${r.detail}`);
      }
    }
    console.log(`[eval-flow] passed ${passed} / ${total} (${specs.length} flow samples)`);
  }
  process.exit(passed === total && report.every((f) => !f.error) ? 0 : 1);
}

module.exports = { runCase, OPS };
