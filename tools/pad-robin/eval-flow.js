#!/usr/bin/env node
/**
 * eval-flow.js — 设计质量评估集：按需求文本断言 flow.json 的结构
 *
 * 只验结构，不评文案（D6）。两种用法：
 *   node eval-flow.js tests/eval/sample.cases.json     # 单个用例文件
 *   node eval-flow.js tests/eval                                   # 目录：跑里面所有 *.cases.json
 *
 * 用例文件里 `flow` 指向被测 flow.json；目录模式下每个用例文件各自带 flow。
 * 退出码：0 全部通过 / 1 有失败 / 2 输入错误
 */

const fs = require("fs");
const path = require("path");

/** 断言操作表：每个操作返回 { ok, detail } */
const OPS = {
  // 循环：fromto 校验上下界，foreach 校验遍历变量
  loop(flow, a) {
    const n = flow.nodes.find((x) => (a.id ? x.id === a.id : x.pad_hint === "LOOP"));
    if (!n) return { ok: false, detail: "找不到循环节点" };
    const lp = n.loop || {};
    if (a.kind === "foreach") {
      return { ok: lp.kind === "foreach" && (!a.item || lp.item === a.item), detail: `FOREACH ${lp.item}` };
    }
    const ok = lp.from === a.from && lp.to === a.to && (lp.step || 1) === (a.step || 1);
    return { ok, detail: `LOOP ${lp.index} ${lp.from}->${lp.to} step ${lp.step || 1}` };
  },
  condition(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const c = (n.params && n.params.Condition) || "";
    return { ok: c.includes(a.contains), detail: `条件=${c}` };
  },
  edge(flow, a) {
    const ok = (flow.edges || []).some((e) => e.from === a.from && e.to === a.to);
    return { ok, detail: `${a.from} -> ${a.to}` };
  },
  // 必须有某个动作（可按节点 id 限定）
  action(flow, a) {
    const n = flow.nodes.find((x) => x.pad_hint === a.padHint && (!a.id || x.id === a.id));
    return { ok: !!n, detail: `${a.padHint}${a.id ? "@" + a.id : ""}` };
  },
  absentMatch(flow, a) {
    const re = new RegExp(a.pattern);
    const hit = flow.nodes.filter((n) => re.test(n.pad_hint || ""));
    return { ok: hit.length === 0, detail: hit.length ? `命中 ${hit.map((n) => n.id).join(",")}` : "未出现" };
  },
  param(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const v = (n.params || {})[a.name];
    return { ok: JSON.stringify(v) === JSON.stringify(a.equals), detail: `${a.name}=${JSON.stringify(v)}` };
  },
  outputsUnique(flow, a) {
    const nodes = flow.nodes.filter((n) => n.pad_hint === a.padHint);
    const names = nodes.map((n) => ((n.output_map || {}).ButtonPressed) || null);
    const missing = names.filter((x) => !x);
    const uniq = new Set(names);
    const ok = missing.length === 0 && uniq.size === names.length;
    return { ok, detail: `${names.length} 个节点，${uniq.size} 个不同变量` };
  },
  guardContains(flow, a) {
    const g = flow.nodes.find((x) => x.id === a.id && x.pad_hint === "GUARD");
    if (!g) return { ok: false, detail: `守卫 ${a.id} 不存在` };
    const body = new Set(g.body || []);
    const missing = a.nodes.filter((x) => !body.has(x));
    return { ok: missing.length === 0, detail: missing.length ? `缺少 ${missing.join(",")}` : `body=[${g.body.join(",")}]` };
  },
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

function loadCases(file) {
  const spec = JSON.parse(fs.readFileSync(file, "utf8"));
  return { file, flowPath: spec.flow, cases: spec.cases || [] };
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const asJson = args.includes("--json");
  const target = args.find((a) => !a.startsWith("--"));
  if (!target) {
    console.error("用法: node eval-flow.js <cases.json | 目录> [--json]");
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
    console.error(`[错误] 读取失败：${e.message}`);
    process.exit(2);
  }
  if (specs.length === 0) {
    console.error(`[错误] ${target} 下没有 *.cases.json`);
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
    const cases = s.cases.map((c) => runCase(flow, c));
    total += cases.length;
    passed += cases.filter((c) => c.ok).length;
    report.push({ flow: s.flowPath, cases });
  }

  if (asJson) {
    console.log(JSON.stringify({ total, passed, files: report }, null, 2));
  } else {
    for (const f of report) {
      if (f.error) {
        console.log(`FAIL  ${f.flow}（读取失败：${f.error}）`);
        continue;
      }
      const okCount = f.cases.filter((c) => c.ok).length;
      console.log(`--- ${f.flow}  ${okCount}/${f.cases.length} ---`);
      for (const c of f.cases) {
        console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.id}  需求：${c.requirement}`);
        for (const r of c.results.filter((x) => !x.ok)) console.log(`        断言失败：${r.detail}`);
      }
    }
    console.log(`[eval-flow] 通过 ${passed} / ${total}（${specs.length} 个流程样例）`);
  }
  process.exit(passed === total && report.every((f) => !f.error) ? 0 : 1);
}

module.exports = { runCase, OPS };
