#!/usr/bin/env node
/**
 * flow-to-drawio.js — flow.json → .drawio（ELK 分层布局 + 正交折线）
 *
 * 用法：
 *   node flow-to-drawio.js <flow.json> <out.drawio>
 *
 * 行为：
 * - 优先使用 flow.edges（显式控制流）；没有 edges 时退回 next/branch 推导
 * - 布局交给 elkjs 的 layered 算法，边输出 bendPoints，避免穿过节点
 * - 旧的自制 BFS 布局保留在 flow-to-drawio-bfs.js，可作回退
 *
 * 依赖：仓库根执行过 npm install（elkjs）
 */
"use strict";

const fs = require("fs");

let ELK;
try {
  ELK = require("elkjs");
} catch (err) {
  console.error("缺少 elkjs 依赖：请在仓库根目录执行 npm install");
  process.exit(1);
}

const flowPath = process.argv[2];
const outPath = process.argv[3];
if (!flowPath || !outPath) {
  console.error("用法: node flow-to-drawio.js <flow.json> <out.drawio>");
  process.exit(1);
}

const flow = JSON.parse(fs.readFileSync(flowPath, "utf8").replace(/^\uFEFF/, ""));
const nodes = flow.nodes || [];
const byId = new Map(nodes.map((n) => [n.id, n]));

const NODE_H = 72, MIN_W = 200, MAX_W = 400;

// 文本渲染宽度估算：中文/全角按字号宽，ASCII 按 0.6 字号宽
function textWidth(text, fontSize) {
  let w = 0;
  for (const ch of String(text)) {
    w += /[\u3000-\u303f\u4e00-\u9fff\uff00-\uffef]/.test(ch) ? fontSize + 1 : fontSize * 0.6;
  }
  return w;
}

// PAD 动作只显示最后一段，避免整串 actionId 把方框撑爆
function shortAction(hint) {
  const parts = String(hint || "").split(".");
  return parts[parts.length - 1] || "";
}

// 按标题与动作名实测宽度，限制在 [MIN_W, MAX_W]
function nodeWidth(node) {
  const title = `${node.id}. ${node.label || node.type || ""}`;
  const action = shortAction(node.pad_hint);
  const need = Math.max(textWidth(title, 11), action ? textWidth("PAD: " + action, 9) : 0);
  return Math.max(MIN_W, Math.min(MAX_W, Math.ceil(need + 24)));
}

function escapeXml(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

// 显式 edges 优先；没有时按 next/branch/loop/switch 推导（与 BFS 版保持一致）
function collectEdges() {
  if (Array.isArray(flow.edges) && flow.edges.length) {
    return flow.edges
      .filter((e) => {
        if (!byId.has(e.from) || !byId.has(e.to)) {
          console.error(`警告：忽略悬空边 ${e.from} -> ${e.to}`);
          return false;
        }
        return true;
      })
      .map((e) => ({ from: e.from, to: e.to, label: e.label || "" }));
  }

  const edges = [];
  for (const node of nodes) {
    // IF 的 next 在旧规则里不画（表示分支结束后的汇合点），避免与分支边重复
    if (node.pad_hint !== "IF") {
      for (const to of node.next || []) {
        edges.push({ from: node.id, to, label: node.pad_hint === "LOOP" ? "结束循环" : "" });
      }
    }
    if (node.branch) {
      const t = (node.branch.trueBody && node.branch.trueBody[0]) ||
        (node.branch.body && node.branch.body[0]) || node.branch.true;
      if (t) edges.push({ from: node.id, to: t, label: "是" });
      const f = (node.branch.falseBody && node.branch.falseBody[0]) || node.branch.false;
      if (f) edges.push({ from: node.id, to: f, label: "否" });
    }
    if (node.loop && node.loop.body && node.loop.body[0]) {
      edges.push({ from: node.id, to: node.loop.body[0], label: "循环体" });
    }
    if (node.switch) {
      for (const c of node.switch.cases || []) {
        const entry = (c.body || [])[0];
        if (entry) edges.push({ from: node.id, to: entry, label: c.case });
      }
      const d = (node.switch.default || [])[0];
      if (d) edges.push({ from: node.id, to: d, label: "默认" });
    }
  }
  return edges.filter((e) => byId.has(e.from) && byId.has(e.to));
}

const edges = collectEdges();

// ELK 分层布局参数：纵向、正交路由、按模型顺序减少交叉
const graph = {
  id: "root",
  layoutOptions: {
    "elk.algorithm": "layered",
    "elk.direction": "DOWN",
    "elk.edgeRouting": "ORTHOGONAL",
    "elk.spacing.nodeNode": "40",
    "elk.layered.spacing.nodeNodeBetweenLayers": "70",
    "elk.layered.nodePlacement.strategy": "BRANDES_KOEPF",
    "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
    "elk.layered.considerModelOrder.strategy": "NODES_AND_EDGES",
    "elk.padding": "[top=40,left=40,bottom=40,right=40]",
  },
  children: nodes.map((n) => ({ id: n.id, width: nodeWidth(n), height: NODE_H })),
  edges: edges.map((e, i) => ({ id: `e${i}`, sources: [e.from], targets: [e.to] })),
};

new ELK().layout(graph).then((res) => {
  const nodeById = new Map(res.children.map((c) => [c.id, c]));
  const edgeById = new Map((res.edges || []).map((e) => [e.id, e]));
  const nodeCells = [];
  const edgeCells = [];

  for (const n of nodes) {
    const c = nodeById.get(n.id);
    if (!c) continue;
    const title = `${n.id}. ${n.label || n.type || ""}`;
    const action = shortAction(n.pad_hint);
    const display = `<div style="font-size:11px;line-height:15px;">${title}</div>` +
      (action ? `<div style="font-size:9px;line-height:13px;color:#888888;">PAD: ${action}</div>` : "");
    const attrs = [
      `id="n${n.id}"`,
      `title="${escapeXml(n.label || n.type)}"`,
      `nodeType="${escapeXml(n.type || "")}"`,
      `padHint="${escapeXml(n.pad_hint || "")}"`,
      `params="${escapeXml(JSON.stringify(n.params || {}))}"`,
      `outputs="${escapeXml(JSON.stringify(n.outputs || []))}"`,
      `label="${escapeXml(display)}"`,
    ].join(" ");
    nodeCells.push(`        <object ${attrs}>
          <mxCell vertex="1" parent="1" style="rounded=1;whiteSpace=wrap;html=1;fontSize=11;align=left;spacingLeft=8;verticalAlign=middle;">
            <mxGeometry x="${Math.round(c.x)}" y="${Math.round(c.y)}" width="${Math.round(c.width)}" height="${Math.round(c.height)}" as="geometry"/>
          </mxCell>
        </object>`);
  }

  edges.forEach((e, i) => {
    const ec = edgeById.get(`e${i}`);
    const sec = ec && ec.sections && ec.sections[0];
    let points = "";
    if (sec && sec.bendPoints && sec.bendPoints.length) {
      points = `\n            <Array as="points">` +
        sec.bendPoints.map((p) => `\n              <mxPoint x="${Math.round(p.x)}" y="${Math.round(p.y)}"/>`).join("") +
        `\n            </Array>\n          `;
    }
    edgeCells.push(`        <object id="e${i}" from="n${e.from}" to="n${e.to}" label="${escapeXml(e.label)}">
          <mxCell edge="1" parent="1" source="n${e.from}" target="n${e.to}"
                  style="edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;fontSize=9;labelBackgroundColor=#FFFFFF;">
            <mxGeometry relative="1" as="geometry">${points}</mxGeometry>
          </mxCell>
        </object>`);
  });

  const pageW = Math.ceil(Math.max(...res.children.map((c) => c.x + c.width)) + 40);
  const pageH = Math.ceil(Math.max(...res.children.map((c) => c.y + c.height)) + 40);

  const xml = `<mxfile host="flow-to-drawio.js" type="device">
  <diagram id="flow" name="Page-1">
    <mxGraphModel dx="${pageW}" dy="${pageH}" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="${pageW}" pageHeight="${pageH}" math="0" shadow="0">
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
  console.error(`已生成: ${outPath}（${nodes.length} 节点, ${edges.length} 边, 页面 ${pageW}x${pageH}）`);
}).catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
