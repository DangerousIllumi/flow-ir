#!/usr/bin/env node
/**
 * check.js — project-local wrapper around check-flows.js
 *
 * Usage:
 *   node check.js <out.robin | directory>
 *
 * Locates the KB and check-flows.js automatically, then statically validates a single .robin file or every .robin under a directory.
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const target = process.argv[2];
if (!target) {
  console.error("Usage: node check.js <out.robin | directory>");
  process.exit(1);
}

// Locate the KB
const kbCandidates = [
  path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
  path.join(process.cwd(), "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
];
const kbPath = kbCandidates.find((p) => fs.existsSync(p));
if (!kbPath) {
  console.error("[error] PAD_Robin_ActionKB.json not found");
  process.exit(1);
}

// Locate check-flows.js
// The validator moved here from marketing/video/tools in the KB repo, so this no longer depends on the upstream git layout
const checkFlows = path.join(__dirname, "check-flows.js");
if (!fs.existsSync(checkFlows)) {
  console.error(`[error] check-flows.js not found (expected: ${checkFlows})`);
  process.exit(1);
}

// Collect the files to validate
let files = [];
const stat = fs.statSync(target);
if (stat.isDirectory()) {
  files = fs.readdirSync(target)
    .filter((f) => f.endsWith(".robin") || f.endsWith(".txt"))
    .map((f) => path.join(target, f));
} else {
  files = [target];
}

if (files.length === 0) {
  console.error("[error] no .robin / .txt files found");
  process.exit(1);
}

const { lintRobin } = require("./lint-robin.js");

let bad = false;
let lintTotal = 0;
for (const f of files) {
  try {
    execFileSync(process.execPath, [checkFlows, kbPath, f], { stdio: "inherit" });
  } catch (e) {
    bad = true;
  }
  // Flow-hygiene check: warnings only, never affects the exit code (unused output / unused variable / overly nested IF)
  const { warnings } = lintRobin(fs.readFileSync(f, "utf8"));
  for (const w of warnings) {
    console.log(`[lint] ${path.basename(f)}:${w.line} ${w.rule} ${w.message}`);
  }
  lintTotal += warnings.length;
  if (warnings.length) {
    const byRule = {};
    for (const w of warnings) byRule[w.rule] = (byRule[w.rule] || 0) + 1;
    const summary = Object.entries(byRule).map(([k, v]) => `${k}=${v}`).join(" ");
    console.log(`[lint] ${path.basename(f)}: ${warnings.length} warning(s) (${summary}); does not affect the check result`);
  }
}
if (lintTotal > 0) {
  console.log(`[lint] ${lintTotal} flow-hygiene warning(s) total; fix them in flow.json (do not click "Apply fix" on the canvas)`);
}

process.exit(bad ? 1 : 0);
