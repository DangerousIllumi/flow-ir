#!/usr/bin/env node
/**
 * compare-robin.js — asserts that the "generated output" and the "production .robin in the repo" are equivalent
 *
 * Background: flow.json is the single design source; the .robin is a rebuildable artifact that still belongs in
 * the repo because release/audit/rollback need it; once they drift, diagram, checks and release disagree, so CI compares line by line.
 *
 * Normalization rules match ConvertTo-NormalizedRobin in tools/pad-sync/RobinText.psm1:
 *   - backslash-escaped quotes (\"…\" and \\"…\\") collapse to a single quote
 *   - trailing/leading whitespace and blank lines are dropped
 *   - @ metadata lines, # comment lines and IMPORT lines are dropped
 *
 * Usage: node compare-robin.js <generated.robin> <production.robin> [--json]
 * Exit codes: 0 match / 1 mismatch / 2 read failure
 */

const fs = require("fs");

/** Normalize robin text (same rules as RobinText.psm1) */
function normalizeRobin(text) {
  return String(text)
    .replace(/\\+"/g, '"')
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("#") && !l.startsWith("@") && !l.startsWith("IMPORT "))
    .join("\n");
}

/** Reduce a line to its "skeleton" so we can tell whether two lines differ only in variable names or literals */
function skeleton(line) {
  return line
    .replace(/\$'''[\s\S]*?'''/g, "$STR$")
    .replace(/%[A-Za-z_]\w*%/g, "%VAR%")
    .replace(/[A-Za-z_]\w*/g, "W");
}

/** Classify a diff: the fix direction comes first, the line number second */
function classify(a, b) {
  if (a === "<missing>" || b === "<missing>") return "line-count-mismatch";
  if (/\{\{/.test(a) !== /\{\{/.test(b)) return "placeholder";
  const kw = /^(IF|ELSE|END|LOOP|SWITCH|CASE|DEFAULT|EXIT LOOP|WAIT|ON ERROR)\b/;
  if (kw.test(a) || kw.test(b)) return "control-flow";
  if (a.startsWith(b) || b.startsWith(a)) return "argument-mismatch";
  if (skeleton(a) === skeleton(b)) return "variable-or-literal";
  return "other";
}

/** Compare line by line and return the list of diffs (at most limit entries) */
function compareRobin(genText, prodText, limit = 20) {
  const la = normalizeRobin(genText).split("\n");
  const lb = normalizeRobin(prodText).split("\n");
  const diffs = [];
  for (let i = 0; i < Math.max(la.length, lb.length); i++) {
    const a = i < la.length ? la[i] : "<missing>";
    const b = i < lb.length ? lb[i] : "<missing>";
    if (a !== b) diffs.push({ index: i + 1, kind: classify(a, b), generated: a, production: b });
    if (diffs.length >= limit) break;
  }
  return { ok: diffs.length === 0, diffs, genLines: la.length, prodLines: lb.length };
}

/** Group diffs by kind so you can see at a glance which category the drift concentrates in */
function summarize(diffs) {
  const byKind = {};
  for (const d of diffs) byKind[d.kind] = (byKind[d.kind] || 0) + 1;
  return byKind;
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const files = args.filter((a) => !a.startsWith("--"));
  if (files.length < 2) {
    console.error("Usage: node compare-robin.js <generated.robin> <production.robin> [--json]");
    process.exit(2);
  }
  let gen;
  let prod;
  try {
    gen = fs.readFileSync(files[0], "utf8");
    prod = fs.readFileSync(files[1], "utf8");
  } catch (e) {
    console.error(`[error] read failed: ${e.message}`);
    process.exit(2);
  }
  const res = compareRobin(gen, prod);
  if (asJson) {
    console.log(JSON.stringify({ ...res, byKind: summarize(res.diffs) }, null, 2));
  } else if (res.ok) {
    console.log(`[compare-robin] match (generated ${res.genLines} lines / production ${res.prodLines} lines; comments and blank lines ignored)`);
  } else {
    console.log(`[compare-robin] mismatch: generated ${res.genLines} lines / production ${res.prodLines} lines`);
    console.log(`Diff kinds: ${JSON.stringify(summarize(res.diffs))}`);
    for (const d of res.diffs) {
      console.log(`  line ${d.index} [${d.kind}]`);
      console.log(`    generated: ${d.generated}`);
      console.log(`    production: ${d.production}`);
    }
    console.log("Fix: change flow.json and regenerate; do not edit .robin directly");
  }
  process.exit(res.ok ? 0 : 1);
}

module.exports = { compareRobin, normalizeRobin, classify, summarize };
