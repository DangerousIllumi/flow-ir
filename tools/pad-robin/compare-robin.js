#!/usr/bin/env node
/**
 * compare-robin.js — 断言「生成结果」与「仓库里的生产 .robin」等价
 *
 * 背景：flow.json 是唯一设计源，.robin 是可重建产物但仍入库（发布/审计/回滚要用）。
 * 两者一旦漂移，流程图、校验、发布三者就会各说各话，所以在 CI 里逐行比对。
 *
 * 规范化规则与 tools/pad-sync/RobinText.psm1 的 ConvertTo-NormalizedRobin 保持一致：
 *   - 反斜杠转义引号（\"…\" 与 \\"…\\"）统一成单个引号
 *   - 去掉行尾/行首空白与空行
 *   - 去掉 @ 元数据行、# 注释行、IMPORT 行
 *
 * 用法：node compare-robin.js <生成.robin> <生产.robin> [--json]
 * 退出码：0 一致 / 1 不一致 / 2 读取失败
 */

const fs = require("fs");

/** 规范化 robin 文本（与 RobinText.psm1 同一口径） */
function normalizeRobin(text) {
  return String(text)
    .replace(/\\+"/g, '"')
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l !== "" && !l.startsWith("#") && !l.startsWith("@") && !l.startsWith("IMPORT "))
    .join("\n");
}

/** 把行归约成「骨架」，用于判断两行是否只是变量名/字面量不同 */
function skeleton(line) {
  return line
    .replace(/\$'''[\s\S]*?'''/g, "$STR$")
    .replace(/%[A-Za-z_]\w*%/g, "%VAR%")
    .replace(/[A-Za-z_]\w*/g, "W");
}

/** 差异分类：先给修复方向，再给行号 */
function classify(a, b) {
  if (a === "<缺失>" || b === "<缺失>") return "行数不一致";
  if (/\{\{/.test(a) !== /\{\{/.test(b)) return "占位符";
  const kw = /^(IF|ELSE|END|LOOP|SWITCH|CASE|DEFAULT|EXIT LOOP|WAIT|ON ERROR)\b/;
  if (kw.test(a) || kw.test(b)) return "控制流";
  if (a.startsWith(b) || b.startsWith(a)) return "参数缺失/多余";
  if (skeleton(a) === skeleton(b)) return "变量名/字面量";
  return "其他";
}

/** 逐行比对，返回差异列表（最多 limit 条） */
function compareRobin(genText, prodText, limit = 20) {
  const la = normalizeRobin(genText).split("\n");
  const lb = normalizeRobin(prodText).split("\n");
  const diffs = [];
  for (let i = 0; i < Math.max(la.length, lb.length); i++) {
    const a = i < la.length ? la[i] : "<缺失>";
    const b = i < lb.length ? lb[i] : "<缺失>";
    if (a !== b) diffs.push({ index: i + 1, kind: classify(a, b), generated: a, production: b });
    if (diffs.length >= limit) break;
  }
  return { ok: diffs.length === 0, diffs, genLines: la.length, prodLines: lb.length };
}

/** 按分类汇总，便于一次看清漂移集中在哪一类 */
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
    console.error("用法: node compare-robin.js <生成.robin> <生产.robin> [--json]");
    process.exit(2);
  }
  let gen;
  let prod;
  try {
    gen = fs.readFileSync(files[0], "utf8");
    prod = fs.readFileSync(files[1], "utf8");
  } catch (e) {
    console.error(`[错误] 读取失败：${e.message}`);
    process.exit(2);
  }
  const res = compareRobin(gen, prod);
  if (asJson) {
    console.log(JSON.stringify({ ...res, byKind: summarize(res.diffs) }, null, 2));
  } else if (res.ok) {
    console.log(`[compare-robin] 一致（生成 ${res.genLines} 行 / 生产 ${res.prodLines} 行，已忽略注释与空行）`);
  } else {
    console.log(`[compare-robin] 不一致：生成 ${res.genLines} 行 / 生产 ${res.prodLines} 行`);
    console.log(`差异分类：${JSON.stringify(summarize(res.diffs))}`);
    for (const d of res.diffs) {
      console.log(`  第 ${d.index} 行 [${d.kind}]`);
      console.log(`    生成: ${d.generated}`);
      console.log(`    生产: ${d.production}`);
    }
    console.log("修复方向：改 flow.json 后重新生成，不要直接改 .robin");
  }
  process.exit(res.ok ? 0 : 1);
}

module.exports = { compareRobin, normalizeRobin, classify, summarize };
