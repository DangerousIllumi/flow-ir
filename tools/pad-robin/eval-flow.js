#!/usr/bin/env node
/**
 * eval-flow.js — 设计质量评估集：按需求文本断言 flow.json 的结构
 *
 * 只验结构，不评文案（D6）。用例把「需求里必须成立的事实」写成断言，
 * 以后换模型/换生成方式时，用同一套用例算通过率，避免"看起来能跑"就上线。
 *
 * 用法：node eval-flow.js tests/eval/sample.cases.json [--json]
 * 退出码：0 全部通过 / 1 有失败 / 2 输入错误
 */

const fs = require("fs");

/** 断言操作表：每个操作返回 { ok, detail } */
const OPS = {
  // 循环节点的上下限（防止为了"多查几次"把 7 次改成 10 次）
  loop(flow, a) {
    const n = flow.nodes.find((x) => x.type === "loop" && (!a.id || x.id === a.id));
    if (!n) return { ok: false, detail: "找不到循环节点" };
    const lp = n.loop || {};
    const ok = lp.from === a.from && lp.to === a.to && (lp.step || 1) === (a.step || 1);
    return { ok, detail: `LOOP ${lp.index} ${lp.from}->${lp.to} step ${lp.step || 1}` };
  },
  // 条件表达式必须包含指定片段
  condition(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const c = (n.params && n.params.Condition) || "";
    return { ok: c.includes(a.contains), detail: `条件=${c}` };
  },
  // 显式边必须存在
  edge(flow, a) {
    const ok = (flow.edges || []).some((e) => e.from === a.from && e.to === a.to);
    return { ok, detail: `${a.from} -> ${a.to}` };
  },
  // 不允许出现某类动作（如关闭 Outlook 会连带关掉用户主窗口）
  absentMatch(flow, a) {
    const re = new RegExp(a.pattern);
    const hit = flow.nodes.filter((n) => re.test(n.pad_hint || ""));
    return { ok: hit.length === 0, detail: hit.length ? `命中 ${hit.map((n) => n.id).join(",")}` : "未出现" };
  },
  // 动作参数必须等于期望值
  param(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const v = (n.params || {})[a.name];
    return { ok: JSON.stringify(v) === JSON.stringify(a.equals), detail: `${a.name}=${JSON.stringify(v)}` };
  },
  // 同类动作的输出变量必须互不相同（弹窗都叫 ButtonPressed 会互相覆盖）
  outputsUnique(flow, a) {
    const nodes = flow.nodes.filter((n) => n.pad_hint === a.padHint);
    const names = nodes.map((n) => ((n.output_map || {}).ButtonPressed) || null);
    const missing = names.filter((x) => !x);
    const uniq = new Set(names);
    const ok = missing.length === 0 && uniq.size === names.length;
    return { ok, detail: `${names.length} 个节点，${uniq.size} 个不同变量` };
  },
  // 守卫的 body 必须覆盖这些节点（副作用必须被 DRY_RUN 包住）
  guardContains(flow, a) {
    const g = flow.nodes.find((x) => x.id === a.id && x.pad_hint === "GUARD");
    if (!g) return { ok: false, detail: `守卫 ${a.id} 不存在` };
    const body = new Set(g.body || []);
    const missing = a.nodes.filter((x) => !body.has(x));
    return { ok: missing.length === 0, detail: missing.length ? `缺少 ${missing.join(",")}` : `body=[${g.body.join(",")}]` };
  },
  // 分支必须覆盖这些 case，且有默认分支
  switchCases(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n || !n.switch) return { ok: false, detail: `节点 ${a.id} 不是 SWITCH` };
    const got = (n.switch.cases || []).map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const want = a.cases.map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const ok = JSON.stringify(got) === JSON.stringify(want) && (n.switch.default || []).length > 0;
    return { ok, detail: got.join(" | ") };
  },
};

function runCase(flow, c) {
  const results = [];
  for (const a of c.expect || []) {
    const fn = OPS[a.op];
    if (!fn) {
      results.push({ ok: false, detail: `未知断言 ${a.op}` });
      continue;
    }
    try {
      results.push(fn(flow, a));
    } catch (e) {
      results.push({ ok: false, detail: `断言异常：${e.message}` });
    }
  }
  return { id: c.id, requirement: c.requirement, ok: results.every((r) => r.ok), results };
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const specPath = args.find((a) => !a.startsWith("--"));
  if (!specPath) {
    console.error("用法: node eval-flow.js <cases.json> [--json]");
    process.exit(2);
  }
  let spec;
  let flow;
  try {
    spec = JSON.parse(fs.readFileSync(specPath, "utf8"));
    flow = JSON.parse(fs.readFileSync(spec.flow, "utf8"));
  } catch (e) {
    console.error(`[错误] 读取失败：${e.message}`);
    process.exit(2);
  }
  const cases = (spec.cases || []).map((c) => runCase(flow, c));
  const passed = cases.filter((c) => c.ok).length;
  if (asJson) {
    console.log(JSON.stringify({ total: cases.length, passed, cases }, null, 2));
  } else {
    for (const c of cases) {
      console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.id}  需求：${c.requirement}`);
      for (const r of c.results.filter((x) => !x.ok)) console.log(`        断言失败：${r.detail}`);
    }
    console.log(`[eval-flow] 通过 ${passed} / ${cases.length}`);
  }
  process.exit(passed === cases.length ? 0 : 1);
}

module.exports = { runCase, OPS };
