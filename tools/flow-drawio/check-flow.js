#!/usr/bin/env node
/**
 * check-flow.js — 校验 flow.json 的显式 edges 与旧结构（next/branch/loop/switch）是否一致
 *
 * 背景：flow-to-robin 仍依赖 next/branch 表达 IF/LOOP 的嵌套，画图依赖 edges。
 * 两边各写一份必然漂移，因此生成 PAD 代码前先跑本校验：
 *   - 旧结构能推导出的边，必须在 edges 里存在（缺一条就报错）
 *   - edges 允许包含旧结构表达不了的补充边（如 break、IF 之后的续接）
 *   - edges 不允许悬空或同一 from->to 重复
 *
 * 用法：node check-flow.js <flow.json>
 * 退出码：0 一致 / 1 不一致
 */

const fs = require("fs");

// 按旧结构推导边（与 flow-to-drawio-bfs.js / flow-to-robin.js 的口径一致）
function deriveEdges(flow) {
  const edges = [];
  for (const node of flow.nodes || []) {
    // IF 的 next 表示分支结束后的汇合点，旧规则不画
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
    // guard：body = 守卫成立时执行（正常路径），elseBody = 被跳过时的替代分支
    if (node.pad_hint === "GUARD") {
      const t = (node.body || [])[0];
      const f = (node.elseBody || [])[0];
      if (t) edges.push({ from: node.id, to: t, label: "是" });
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
  return edges;
}

function checkFlowConsistency(flow) {
  const explicit = Array.isArray(flow.edges) ? flow.edges : [];
  const ids = new Set((flow.nodes || []).map((n) => n.id));
  const key = (e) => `${e.from}->${e.to}`;

  const derived = deriveEdges(flow);
  const derivedKeys = new Set(derived.map(key));
  const explicitKeys = new Set(explicit.map(key));

  // 旧结构有、edges 没有 → 漂移（必须补）
  const missing = derived.filter((e) => !explicitKeys.has(key(e)));
  // edges 有、旧结构推导不出 → 允许的补充边（break / IF 续接等）
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
    console.log(`[FAIL] 旧结构有 ${res.missing.length} 条边没写进 edges：`);
    for (const e of res.missing) console.log(`  - ${e.from} -> ${e.to} ${e.label || ""}`.trimEnd());
  }
  if (res.duplicates.length) {
    console.log(`[FAIL] edges 里有 ${res.duplicates.length} 条重复边：`);
    for (const e of res.duplicates) console.log(`  - ${e.from} -> ${e.to}`);
  }
  if (res.dangling.length) {
    console.log(`[FAIL] edges 里有 ${res.dangling.length} 条悬空边：`);
    for (const e of res.dangling) console.log(`  - ${e.from} -> ${e.to}`);
  }
  if (res.extra.length) {
    console.log(`[INFO] edges 中有 ${res.extra.length} 条旧结构表达不了的补充边（允许）：`);
    for (const e of res.extra) console.log(`  - ${e.from} -> ${e.to} ${e.label || ""}`.trimEnd());
  }
  console.log(res.ok ? "[OK] edges 与 next/branch 一致" : "[BAD] edges 与 next/branch 不一致");
}

if (require.main === module) {
  const file = process.argv[2];
  if (!file) {
    console.error("用法: node check-flow.js <flow.json>");
    process.exit(1);
  }
  const flow = JSON.parse(fs.readFileSync(file, "utf8").replace(/^\uFEFF/, ""));
  // 旧流程没有显式 edges：只提示跳过，不阻断（兼容尚未迁移的 flow.json）
  if (!Array.isArray(flow.edges) || flow.edges.length === 0) {
    console.log(`[flow-check] ${file}: 没有显式 edges，跳过`);
    process.exit(0);
  }
  const res = checkFlowConsistency(flow);
  printReport(res, file);
  process.exit(res.ok ? 0 : 1);
}

module.exports = { checkFlowConsistency, deriveEdges };
