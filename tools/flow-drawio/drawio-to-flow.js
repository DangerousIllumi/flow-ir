#!/usr/bin/env node
/**
 * drawio-to-flow.js — .drawio → flow.json (read-back + change summary + flagging nodes added by hand)
 *
 * Usage:
 *   node drawio-to-flow.js <in.drawio> <orig.flow.json> <out.new.json>
 *
 * Output:
 * - <out.new.json>: the read-back flow.json (nodes/edges come from the canvas; trigger/variables are inherited
 *   from the original file)
 * - console: change summary (added/removed/renamed/edge changes/pad_hint changes + nodes Agent A still has to
 *   complete)
 */

const fs = require("fs");

const drawioPath = process.argv[2];
const origPath = process.argv[3];
const outPath = process.argv[4];
if (!drawioPath || !origPath || !outPath) {
  console.error("Usage: node drawio-to-flow.js <in.drawio> <orig.flow.json> <out.new.json>");
  process.exit(1);
}

const orig = JSON.parse(fs.readFileSync(origPath, "utf8"));
const drawio = fs.readFileSync(drawioPath, "utf8");

// ── Parse the <object> elements in the drawio ────────────────────
const objRe = /<object\s+([^>]*?)>/g;
const objects = [];
let m;
while ((m = objRe.exec(drawio)) !== null) {
  const attrs = parseAttrs(m[1]);
  if (attrs.id && attrs.id.startsWith("n")) {
    objects.push({
      id: attrs.id.slice(1),
      title: attrs.title,
      nodeType: attrs.nodeType,
      padHint: attrs.padHint,
      params: safeJson(attrs.params, {}),
      outputs: safeJson(attrs.outputs, []),
    });
  } else if (attrs.from && attrs.to) {
    objects.push({ edge: true, from: attrs.from, to: attrs.to, label: attrs.label });
  }
}

function parseAttrs(s) {
  const out = {};
  const re = /(\w+)="((?:[^"\\]|\\.)*)"/g;
  let mm;
  while ((mm = re.exec(s)) !== null) {
    out[mm[1]] = mm[2].replace(/&quot;/g, '"').replace(/&apos;/g, "'")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  }
  return out;
}
function safeJson(s, def) {
  try { return s ? JSON.parse(s) : def; } catch { return def; }
}

// ── Rebuild nodes ─────────────────────────────────────────────────
const nodes = objects.filter((o) => !o.edge);
const edges = objects.filter((o) => o.edge);

const byId = new Map(nodes.map((n) => [n.id, n]));
const origById = new Map((orig.nodes || []).map((n) => [n.id, n]));

// Rebuild next: the outgoing edges of each node
const outEdges = {};
for (const e of edges) {
  const from = e.from.replace(/^n/, "");
  const to = e.to.replace(/^n/, "");
  if (!outEdges[from]) outEdges[from] = [];
  outEdges[from].push({ to, label: e.label });
}

const newNodes = nodes.map((n) => {
  const outs = (outEdges[n.id] || []).map((e) => e.to);
  return {
    id: n.id,
    type: n.nodeType || "unknown",
    pad_hint: n.padHint || "",
    label: n.title || "",
    params: n.params,
    outputs: n.outputs,
    next: outs,
  };
});

// ── Change summary ────────────────────────────────────────────────
const origIds = new Set((orig.nodes || []).map((n) => n.id));
const newIds = new Set(newNodes.map((n) => n.id));

const added = newNodes.filter((n) => !origIds.has(n.id));
const removed = (orig.nodes || []).filter((n) => !newIds.has(n.id));

const needAgentA = added.filter((n) => n.type === "unknown" || !n.pad_hint);

const changed = [];
for (const n of newNodes) {
  const o = origById.get(n.id);
  if (!o) continue;
  if (o.label !== n.label) changed.push(`node ${n.id} renamed: ${o.label} -> ${n.label}`);
  if (o.pad_hint !== n.pad_hint) changed.push(`node ${n.id} pad_hint changed: ${o.pad_hint} -> ${n.pad_hint}`);
  const oNext = [...(o.next || [])].sort().join(",");
  const nNext = [...n.next].sort().join(",");
  if (oNext !== nNext) changed.push(`node ${n.id} edges changed: ${oNext} -> ${nNext}`);
}

// ── Assemble the new flow.json ────────────────────────────────────
// Write edges back explicitly so the read-back does not lose explicit control flow (edges such as 5->38 and 8->52
// that next cannot express)
const result = {
  name: orig.name,
  description: orig.description,
  trigger: orig.trigger,
  variables: orig.variables,
  edges: edges.map((e) => {
    const item = { from: e.from.replace(/^n/, ""), to: e.to.replace(/^n/, "") };
    if (e.label) item.label = e.label;
    return item;
  }),
  nodes: newNodes,
};

fs.writeFileSync(outPath, JSON.stringify(result, null, 2), "utf8");

console.log("=== Canvas read-back change summary ===");
console.log(`nodes: ${orig.nodes.length} -> ${newNodes.length}`);
console.log(`added: ${added.length}, removed: ${removed.length}, changed: ${changed.length}`);
if (added.length) console.log("added nodes:", added.map((n) => `${n.id}(${n.label || n.type})`).join(", "));
if (removed.length) console.log("removed nodes:", removed.map((n) => `${n.id}(${n.label})`).join(", "));
if (changed.length) changed.forEach((c) => console.log("  - " + c));
if (needAgentA.length) {
  console.log("\nNodes that need Agent A to complete them (added by hand, type=unknown or no pad_hint):");
  needAgentA.forEach((n) => console.log(`  - node ${n.id} "${n.label}": type=${n.type}, pad_hint=${n.pad_hint}`));
}
console.log(`\nWritten: ${outPath}`);
