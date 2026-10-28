#!/usr/bin/env node
/**
 * flow-to-drawio.js — flow.json → .drawio（确定性布局 + 元数据写入 object 属性）
 *
 * 用法：
 *   node flow-to-drawio.js <flow.json> <out.drawio>
 *
 * 字段映射：
 *   node.id       → <object id="n{id}">
 *   node.label    → <object title="...">（回读时以此为准）
 *   node.type     → nodeType
 *   node.pad_hint → padHint
 *   node.params   → params（JSON 字符串）
 *   node.outputs  → outputs（JSON 数组字符串）
 *   展示用富文本   → <object label="...">（仅显示，回读不依赖）
 *   next/branch   → 边 <object from=".." to=".." label="">
 *   trigger/variables → 不写入画布，始终以 flow.json 为准
 */

const fs = require("fs");

const flowPath = process.argv[2];
const outPath = process.argv[3];
if (!flowPath || !outPath) {
  console.error("用法: node flow-to-drawio.js <flow.json> <out.drawio>");
  process.exit(1);
}

// 读入后剥离 BOM：flow.json 可能被编辑器存成 UTF-8 with BOM，直接 parse 会报错
const flow = JSON.parse(fs.readFileSync(flowPath, "utf8").replace(/^\uFEFF/, ""));
const nodes = flow.nodes || [];

// ── 简单分层布局 ──────────────────────────────────────────────
const level = {};
const byId = new Map(nodes.map((n) => [n.id, n]));

// flow.json 若提供显式 edges，则分层与画线都以它为准；否则退回 next/branch 推导
const explicitEdges = Array.isArray(flow.edges) && flow.edges.length ? flow.edges : null;
const adjacency = new Map();
if (explicitEdges) {
  for (const e of explicitEdges) {
    if (!byId.has(e.from) || !byId.has(e.to)) {
      console.error(`警告：忽略悬空边 ${e.from} -> ${e.to}`);
      continue;
    }
    if (!adjacency.has(e.from)) adjacency.set(e.from, []);
    adjacency.get(e.from).push(e.to);
  }
}

// BFS 从第一个节点开始分层
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
// 未分层的节点放到最后
let maxLevel = Math.max(0, ...Object.values(level));
for (const n of nodes) {
  if (level[n.id] === undefined) {
    maxLevel++;
    level[n.id] = maxLevel;
  }
}

// 按层分组
const layers = {};
for (const n of nodes) {
  const lv = level[n.id];
  if (!layers[lv]) layers[lv] = [];
  layers[lv].push(n);
}

// 节点高度、最小/最大宽度、水平与垂直间距、单行最大宽度
const NODE_H = 72, MIN_W = 200, MAX_W = 400;
const GAP_X = 60, GAP_Y = 52, ROW_GAP = 28, MAX_ROW_W = 1400;

// 文本渲染宽度估算：中文/全角按字号宽，ASCII 按 0.6 字号宽
function textWidth(text, fontSize) {
  let w = 0;
  for (const ch of String(text)) {
    w += /[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]/.test(ch) ? fontSize + 1 : fontSize * 0.6;
  }
  return w;
}

// PAD 动作只显示最后一段，避免把 Scripting.RunDOSCommand.RunDOSCommand 整串塞进方框
function shortAction(padHint) {
  const parts = String(padHint || "").split(".");
  return parts[parts.length - 1] || "";
}

// 按标题与动作名实测宽度，限制在 [MIN_W, MAX_W]
function nodeWidth(node) {
  const title = `${node.id}. ${node.label || node.type || ""}`;
  const action = shortAction(node.pad_hint);
  const need = Math.max(textWidth(title, 11), action ? textWidth("PAD: " + action, 9) : 0);
  return Math.max(MIN_W, Math.min(MAX_W, Math.ceil(need + 24)));
}

// ── 布局：每层按 MAX_ROW_W 折行，超出宽度换行，避免同行方块互相压住 ──
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

// 平移坐标系到正数区域，并按实际内容计算页面尺寸
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

// ── 生成节点 ──────────────────────────────────────────────────
const nodeCells = [];
const edgeCells = [];

for (const node of nodes) {
  const pos = positions.get(node.id);
  const title = `${node.id}. ${node.label || node.type || ""}`;
  const action = shortAction(node.pad_hint);
  // 两行 HTML 标签：标题正常字号，PAD 动作名小字灰色，且节点启用自动换行
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

// ── 生成边 ────────────────────────────────────────────────────
let edgeId = 0;
if (explicitEdges) {
  // 显式 edges 是唯一真源：顺序、标签都按 flow.json，不再从 next/branch 猜
  for (const e of explicitEdges) {
    if (!byId.has(e.from) || !byId.has(e.to)) continue;
    edgeCells.push(makeEdge(`e${edgeId++}`, `n${e.from}`, `n${e.to}`, e.label || ""));
  }
} else {
for (const node of nodes) {
  // 控制流节点里只有 IF 不走普通 next 边（其汇合点通常已由支路内部的 next 链到达，
  // 再画一条会与分支边重复）；LOOP 的 next 表示「结束循环」、SWITCH 的 next 表示「分支结束」
  if (node.pad_hint !== "IF") {
    for (const toId of node.next || []) {
      edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${toId}`, node.pad_hint === "LOOP" ? "结束循环" : ""));
    }
  }
  // 分支边：只画「入口」一条，支路内部的连线由各节点的 next 边表达
  if (node.branch) {
    const tEntry = (node.branch.trueBody && node.branch.trueBody[0]) ||
                   (node.branch.body && node.branch.body[0]) ||
                   node.branch.true;
    if (tEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${tEntry}`, "是"));
    const fEntry = (node.branch.falseBody && node.branch.falseBody[0]) ||
                   node.branch.false;
    if (fEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${fEntry}`, "否"));
  }
  // 循环体边：LOOP → 体首节点（循环体内节点的 next 边照常绘制）
  if (node.loop && node.loop.body && node.loop.body[0]) {
    edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${node.loop.body[0]}`, "循环体"));
  }
  // 分支选择边：SWITCH → 各 CASE 体首节点 / DEFAULT 首节点
  if (node.switch) {
    for (const c of node.switch.cases || []) {
      const entry = (c.body || [])[0];
      if (entry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${entry}`, c.case));
    }
    const dEntry = (node.switch.default || [])[0];
    if (dEntry) edgeCells.push(makeEdge(`e${edgeId++}`, `n${node.id}`, `n${dEntry}`, "默认"));
  }
}
}

function makeEdge(id, from, to, label) {
  // draw.io 只认 mxCell 上的 source/target；object 上的 from/to 仅用于回读（drawio-to-flow.js）
  // 两处都写：mxCell 负责渲染连线，object 属性负责保留原始引用关系
  return `        <object id="${id}" from="${from}" to="${to}" label="${escapeXml(label)}">
          <mxCell edge="1" parent="1" source="${from}" target="${to}"
                  style="edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;fontSize=9;labelBackgroundColor=#FFFFFF;">
            <mxGeometry relative="1" as="geometry"/>
          </mxCell>
        </object>`;
}

// ── 组装 XML ──────────────────────────────────────────────────
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
console.error(`已生成: ${outPath}（${nodes.length} 节点, ${edgeCells.length} 边）`);

function escapeXml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}
