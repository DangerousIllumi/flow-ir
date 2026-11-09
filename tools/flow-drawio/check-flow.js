#!/usr/bin/env node
/**
 * check-flow.js — check that the explicit edges in flow.json agree with the legacy shape (next/branch/loop/switch)
 *
 * Background: flow-to-robin still relies on next/branch to express IF/LOOP nesting, while the diagram relies on
 * edges. Keeping two hand-written versions of the same structure always drifts, so run this check before
 * generating PAD code:
 *   - every edge derivable from the legacy shape must be present in edges (one missing edge is an error)
 *   - edges may carry supplementary edges the legacy shape cannot express (break, the continuation after an IF)
 *   - edges must not dangle, and the same from->to pair must not appear twice
 *
 * Usage: node check-flow.js <flow.json>
 * Exit code: 0 consistent / 1 inconsistent
 */

const fs = require("fs");

// Derive edges from the legacy shape (same conventions as flow-to-drawio-bfs.js / flow-to-robin.js)
function deriveEdges(flow) {
  const edges = [];
  for (const node of flow.nodes || []) {
    // For IF, next is the join point after the branch ends; the legacy rule does not draw it
    if (node.pad_hint !== "IF") {
      for (const to of node.next || []) {
        edges.push({ from: node.id, to, label: node.pad_hint === "LOOP" ? "end loop" : "" });
      }
    }
    if (node.branch) {
      const t = (node.branch.trueBody && node.branch.trueBody[0]) ||
        (node.branch.body && node.branch.body[0]) || node.branch.true;
      if (t) edges.push({ from: node.id, to: t, label: "yes" });
      const f = (node.branch.falseBody && node.branch.falseBody[0]) || node.branch.false;
      if (f) edges.push({ from: node.id, to: f, label: "no" });
    }
    // guard: body runs when the guard holds (the normal path), elseBody is the fallback branch taken when skipped
    if (node.pad_hint === "GUARD") {
      const t = (node.body || [])[0];
      const f = (node.elseBody || [])[0];
      if (t) edges.push({ from: node.id, to: t, label: "yes" });
      if (f) edges.push({ from: node.id, to: f, label: "no" });
    }
    if (node.loop && node.loop.body && node.loop.body[0]) {
      edges.push({ from: node.id, to: node.loop.body[0], label: "loop body" });
    }
    if (node.switch) {
      for (const c of node.switch.cases || []) {
        const entry = (c.body || [])[0];
        if (entry) edges.push({ from: node.id, to: entry, label: c.case });
      }
      const d = (node.switch.default || [])[0];
      if (d) edges.push({ from: node.id, to: d, label: "default" });
    }
  }
  return edges;
}

function checkFlowConsistency(flow) {
  const explicit = Array.isArray(flow.edges) ? flow.edges : [];
  const ids = new Set((flow.nodes || []).map((n) => n.id));
  const key = (e) => `${e.from}->${e.to}`;

  const derived = deriveEdges(flow);
  const derivedKeys = new Set(derived.map(key));
  const explicitKeys = new Set(explicit.map(key));

  // Present in the legacy shape but missing from edges -> drift (must be added)
  const missing = derived.filter((e) => !explicitKeys.has(key(e)));
  // Present in edges but not derivable from the legacy shape -> allowed supplementary edge (break / IF continuation, etc.)
  const extra = explicit.filter((e) => !derivedKeys.has(key(e)));
  const dangling = explicit.filter((e) => !ids.has(e.from) || !ids.has(e.to));

  const seen = new Set();
  const duplicates = [];
  for (const e of explicit) {
    const k = key(e);
    if (seen.has(k)) duplicates.push(e);
    else seen.add(k);
  }

  return {
    ok: missing.length === 0 && dangling.length === 0 && duplicates.length === 0,
    derivedCount: derived.length,
    explicitCount: explicit.length,
    missing, extra, duplicates, dangling,
  };
}

function printReport(res, file) {
  console.log(`[flow-check] ${file}: derived=${res.derivedCount} explicit=${res.explicitCount}`);
  if (res.missing.length) {
    console.log(`[FAIL] ${res.missing.length} edge(s) derivable from the legacy shape are missing from edges:`);
    for (const e of res.missing) console.log(`  - ${e.from} -> ${e.to} ${e.label || ""}`.trimEnd());
  }
  if (res.duplicates.length) {
    console.log(`[FAIL] ${res.duplicates.length} duplicate edge(s) in edges:`);
    for (const e of res.duplicates) console.log(`  - ${e.from} -> ${e.to}`);
  }
  if (res.dangling.length) {
    console.log(`[FAIL] ${res.dangling.length} dangling edge(s) in edges:`);
    for (const e of res.dangling) console.log(`  - ${e.from} -> ${e.to}`);
  }
  if (res.extra.length) {
    console.log(`[INFO] ${res.extra.length} extra edge(s) in edges that the legacy shape cannot express (allowed):`);
    for (const e of res.extra) console.log(`  - ${e.from} -> ${e.to} ${e.label || ""}`.trimEnd());
  }
  console.log(res.ok ? "[OK] edges agree with next/branch" : "[BAD] edges disagree with next/branch");
}

if (require.main === module) {
  const file = process.argv[2];
  if (!file) {
    console.error("Usage: node check-flow.js <flow.json>");
    process.exit(1);
  }
  const flow = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  // Legacy flows have no explicit edges: report the skip and do not block (keeps un-migrated flow.json working)
  if (!Array.isArray(flow.edges) || flow.edges.length === 0) {
    console.log(`[flow-check] ${file}: no explicit edges; skipped`);
    process.exit(0);
  }
  const res = checkFlowConsistency(flow);
  printReport(res, file);
  process.exit(res.ok ? 0 : 1);
}

module.exports = { checkFlowConsistency, deriveEdges };
