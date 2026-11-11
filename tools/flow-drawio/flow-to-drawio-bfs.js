#!/usr/bin/env node
/**
 * flow-to-drawio.js — flow.json → .drawio (deterministic layout + metadata written into object attributes)
 *
 * Usage:
 *   node flow-to-drawio.js <flow.json> <out.drawio>
 *
 * Field mapping:
 *   node.id       → <object id="n{id}">
 *   node.label    → <object title="..."> (the authoritative value when reading back)
 *   node.type     → nodeType
 *   node.pad_hint → padHint
 *   node.params   → params (JSON string)
 *   node.outputs  → outputs (JSON array string)
 *   display rich text → <object label="..."> (display only; the read-back does not depend on it)
 *   next/branch   → edge <object from=".." to=".." label="">
 *   trigger/variables → not written to the canvas; flow.json is always authoritative
 */

const fs = require("fs");

const flowPath = process.argv[2];
const outPath = process.argv[3];
if (!flowPath || !outPath) {
  console.error("Usage: node flow-to-drawio.js <flow.json> <out.drawio>");
  process.exit(1);
}

// Strip the BOM after reading: an editor may have saved flow.json as UTF-8 with BOM, and parsing it directly fails
const flow = JSON.parse(fs.readFileSync(flowPath, "utf8").replace(/^\uFEFF/, ""));
const nodes = flow.nodes || [];

// ── Simple layered layout ─────────────────────────────────────────
const level = {};
const byId = new Map(nodes.map((n) => [n.id, n]));

// When flow.json provides explicit edges, both layering and edge drawing follow them; otherwise derive from next/branch
const explicitEdges = Array.isArray(flow.edges) && flow.edges.length ? flow.edges : null;
const adjacency = new Map();
if (explicitEdges) {
  for (const e of explicitEdges) {
    if (!byId.has(e.from) || !byId.has(e.to)) {
      console.error(`warning: ignoring dangling edge ${e.from} -> ${e.to}`);
      continue;
    }
    if (!adjacency.has(e.from)) adjacency.set(e.from, []);
    adjacency.get(e.from).push(e.to);
  }
}

// Layer the graph with a BFS starting from the first node
const startNode = nodes[0];
if (startNode) {
  level[startNode.id] = 0;
  const queue = [startNode.id];
  while (queue.length) {
    const cur = queue.shift();
    const node = byId.get(cur);
    const nexts = explicitEdges ? [...(adjacency.get(cur) || [])] : [...(node.next || [])];
    if (!explicitEdges) {
      if (node.branch) {
        if (node.branch.body) nexts.push(...node.branch.body);
        if (node.branch.trueBody) nexts.push(...node.branch.trueBody);
        if (node.branch.falseBody) nexts.push(...node.branch.falseBody);
        if (node.branch.true) nexts.push(node.branch.true);
        if (node.branch.false) nexts.push(node.branch.false);
      }
      if (node.loop && node.loop.body) nexts.push(...node.loop.body);
      if (node.switch) {
        for (const c of node.switch.cases || []) nexts.push(...(c.body || []));
        if (node.switch.default) nexts.push(...node.switch.default);
      }
    }
    for (const nid of nexts) {
      if (level[nid] === undefined) {
        level[nid] = level[cur] + 1;
        queue.push(nid);
      }
    }
  }
}
// Nodes that the BFS never reached go last
let maxLevel = Math.max(0, ...Object.values(level));
for (const n of nodes) {
  if (level[n.id] === undefined) {
    maxLevel++;
    level[n.id] = maxLevel;
  }
}

// Group nodes by layer
const layers = {};
for (const n of nodes) {
  const lv = level[n.id];
  if (!layers[lv]) layers[lv] = [];
  layers[lv].push(n);
}

// Node height, minimum/maximum width, horizontal and vertical gaps, maximum width of a single row
const NODE_H = 72, MIN_W = 200, MAX_W = 400;
const GAP_X = 60, GAP_Y = 52, ROW_GAP = 28, MAX_ROW_W = 1400;

// Estimate the rendered text width: CJK/full-width glyphs count as one font size, ASCII as 0.6 of a font size
function textWidth(text, fontSize) {
  let w = 0;
  for (const ch of String(text)) {
    w += /[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]/.test(ch) ? fontSize + 1 : fontSize * 0.6;
  }
  return w;
}

// Show only the last segment of a PAD action so the whole Scripting.RunDOSCommand.RunDOSCommand string does not blow up the box
function shortAction(padHint) {
  const parts = String(padHint || "").split(".");
  return parts[parts.length - 1] || "";
}

// Measure the title and action name, then clamp the width to [MIN_W, MAX_W]
function nodeWidth(node) {
  const title = `${node.id}. ${node.label || node.type || ""}`;
  const action = shortAction(node.pad_hint);
  const need = Math.max(textWidth(title, 11), action ? textWidth("PAD: " + action, 9) : 0);
  return Math.max(MIN_W, Math.min(MAX_W, Math.ceil(need + 24)));
}

// ── Layout: wrap each layer at MAX_ROW_W so boxes in the same row do not overlap ──
const positions = new Map();
let cursorY = 0;
for (let lv = 0; lv <= maxLevel; lv++) {
  const group = layers[lv] || [];
  if (!group.length) continue;

  const rows = [];
  let row = [], rowW = 0;
  for (const node of group) {
    const w = nodeWidth(node);
    if (row.length && rowW + GAP_X + w > MAX_ROW_W) {
      rows.push(row);
      row = [];
      rowW = 0;
    }
    rowW += row.length ? GAP_X + w : w;
    row.push({ node, w });
  }
  if (row.length) rows.push(row);

  for (const r of rows) {
    const totalW = r.reduce((s, it) => s + it.w, 0) + (r.length - 1) * GAP_X;
    let x = -totalW / 2;
    for (const it of r) {
      positions.set(it.node.id, { x, y: cursorY, w: it.w, h: NODE_H });
      x += it.w + GAP_X;
    }
    cursorY += NODE_H + GAP_Y;
  }
  cursorY += ROW_GAP;
}

// Shift the coordinate system into positive space and size the page from the actual content
const allPos = [...positions.values()];
const minX = Math.min(...allPos.map((p) => p.x));
const minY = Math.min(...allPos.map((p) => p.y));
const maxX = Math.max(...allPos.map((p) => p.x + p.w));
const maxY = Math.max(...allPos.map((p) => p.y + p.h));
for (const p of allPos) {
  p.x = Math.round(p.x - minX + 40);
  p.y = Math.round(p.y - minY + 40);
}
const PAGE_W = Math.ceil(maxX - minX + 80);
const PAGE_H = Math.ceil(maxY - minY + 80);

// ── Generate nodes ────────────────────────────────────────────────
const nodeCells = [];
const edgeCells = [];

for (const node of nodes) {
  const pos = positions.get(node.id);
  const title = `${node.id}. ${node.label || node.type || ""}`;
  const action = shortAction(node.pad_hint);
  // Two-line HTML label: the title at normal size, the PAD action name smaller and grey; the node wraps its text
  const display = `<div style="font-size:11px;line-height:15px;">${title}</div>` +
    (action ? `<div style="font-size:9px;line-height:13px;color:#888888;">PAD: ${action}</div>` : "");
  const objAttrs = [
    `id="n${node.id}"`,
    `title="${escapeXml(node.label || node.type)}"`,
    `nodeType="${escapeXml(node.type || "")}"`,
    `padHint="${escapeXml(node.pad_hint || "")}"`,
    `params="${escapeXml(JSON.stringify(node.params || {}))}"`,
    `outputs="${escapeXml(JSON.stringify(node.outputs || []))}"`,
    `label="${escapeXml(display)}"`,
  ].join(" ");
  nodeCells.push(
    `        <object ${objAttrs}>
          <mxCell vertex="1" parent="1" style="rounded=1;whiteSpace=wrap;html=1;fontSize=11;align=left;spacingLeft=8;verticalAlign=middle;">
            <mxGeometry x="${pos.x}" y="${pos.y}" width="${pos.w}" height="${pos.h}" as="geometry"/>
          </mxCell>
        </object>`
  );
}

// ── Generate edges ────────────────────────────────────────────────
let edgeId = 0;
if (explicitEdges) {
  // Explicit edges are the single source of truth: order and labels come from flow.json, never guessed from next/branch
  for (const e of explicitEdges) {
    if (!byId.has(e.from) || !byId.has(e.to)) continue;
    edgeCells.push(makeEdge(`e${edgeId++}`, `n${e.from}`, `n${e.to}`, e.label || ""));
  }
} else {
for (const node of nodes) {
  // Among control-flow nodes only IF skips the ordinary next edge (its join point is normally already reached
  // through the next chain inside the branches, so one more edge would duplicate the branch edges); LOOP's next
  // means "end of loop" and SWITCH's next means "end of branch"
  if (node.pad_hint !== "IF") {
    for (const toId of node.next || []) {
      edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${toId}`, node.pad_hint === "LOOP" ? "end loop" : ""));
    }
  }
  // Branch edges: draw only the entry edge; connections inside a branch are expressed by each node's next edge
  if (node.branch) {
    const tEntry = (node.branch.trueBody && node.branch.trueBody[0]) ||
                   (node.branch.body && node.branch.body[0]) ||
                   node.branch.true;
    if (tEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${tEntry}`, "yes"));
    const fEntry = (node.branch.falseBody && node.branch.falseBody[0]) ||
                   node.branch.false;
    if (fEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${fEntry}`, "no"));
  }
  // Loop-body edge: LOOP -> first node of the body (the next edges of nodes inside the body are drawn as usual)
  if (node.loop && node.loop.body && node.loop.body[0]) {
    edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${node.loop.body[0]}`, "loop body"));
  }
  // Switch-case edges: SWITCH -> first node of each CASE body / first DEFAULT node
  if (node.switch) {
    for (const c of node.switch.cases || []) {
      const entry = (c.body || [])[0];
      if (entry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${entry}`, c.case));
    }
    const dEntry = (node.switch.default || [])[0];
    if (dEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${dEntry}`, "default"));
  }
}
}

function makeEdge(id, from, to, label) {
  // draw.io only honours source/target on the mxCell; from/to on the object is used only for read-back (drawio-to-flow.js)
  // Write both: the mxCell renders the edge, the object attributes preserve the original references
  return `        <object id="${id}" from="${from}" to="${to}" label="${escapeXml(label)}">
          <mxCell edge="1" parent="1" source="${from}" target="${to}"
                  style="edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;fontSize=9;labelBackgroundColor=#FFFFFF;">
            <mxGeometry relative="1" as="geometry"/>
          </mxCell>
        </object>`;
}

// ── Assemble the XML ──────────────────────────────────────────────
const xml = `<mxfile host="flow-to-drawio.js" type="device">
  <diagram id="flow" name="Page-1">
    <mxGraphModel dx="${PAGE_W}" dy="${PAGE_H}" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="${PAGE_W}" pageHeight="${PAGE_H}" math="0" shadow="0">
      <root>
        <mxCell id="0"/>
        <mxCell id="1" parent="0"/>
${nodeCells.join("\n")}
${edgeCells.join("\n")}
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>`;

fs.writeFileSync(outPath, xml, "utf8");
console.log(`Generated: ${outPath} (${nodes.length} nodes, ${edgeCells.length} edges)`);

function escapeXml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
