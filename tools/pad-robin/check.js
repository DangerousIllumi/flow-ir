#!/usr/bin/env node
/**
 * check.js — check-flows.js 的项目本地包装器
 *
 * 用法：
 *   node check.js <out.robin | 目录>
 *
 * 自动定位 KB 和 check-flows.js，对单个 .robin 文件或目录下所有 .robin 做静态校验。
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const target = process.argv[2];
if (!target) {
  console.error("Usage: node check.js <out.robin | directory>");
  process.exit(1);
}

// 定位 KB
const kbCandidates = [
  path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
  path.join(process.cwd(), "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
];
const kbPath = kbCandidates.find((p) => fs.existsSync(p));
if (!kbPath) {
  console.error("[error] PAD_Robin_ActionKB.json not found");
  process.exit(1);
}

// 定位 check-flows.js
// 校验器已从 KB 仓库的 marketing/video/tools 迁到本目录（脱离上游 git 结构）
const checkFlows = path.join(__dirname, "check-flows.js");
if (!fs.existsSync(checkFlows)) {
  console.error(`[error] check-flows.js not found (expected: ${checkFlows})`);
  process.exit(1);
}

// 收集要校验的文件
let files = [];
const stat = fs.statSync(target);
if (stat.isDirectory()) {
  files = fs.readdirSync(target)
    .filter((f) => f.endsWith(".robin") || f.endsWith(".txt"))
    .map((f) => path.join(target, f));
} else {
  files = [target];
}

if (files.length === 0) {
  console.error("[error] no .robin / .txt files found");
  process.exit(1);
}

const { lintRobin } = require("./lint-robin.js");

let bad = false;
let lintTotal = 0;
for (const f of files) {
  try {
    execFileSync(process.execPath, [checkFlows, kbPath, f], { stdio: "inherit" });
  } catch (e) {
    bad = true;
  }
  // 流程卫生检查：只报 warning，不影响退出码（未读输出 / 未用变量 / IF 嵌套过深）
  const { warnings } = lintRobin(fs.readFileSync(f, "utf8"));
  for (const w of warnings) {
    console.log(`[lint] ${path.basename(f)}:${w.line} ${w.rule} ${w.message}`);
  }
  lintTotal += warnings.length;
  if (warnings.length) {
    const byRule = {};
    for (const w of warnings) byRule[w.rule] = (byRule[w.rule] || 0) + 1;
    const summary = Object.entries(byRule).map(([k, v]) => `${k}=${v}`).join(" ");
    console.log(`[lint] ${path.basename(f)}: ${warnings.length} warning(s) (${summary}); does not affect the check result`);
  }
}
if (lintTotal > 0) {
  console.log(`[lint] ${lintTotal} flow-hygiene warning(s) total; fix them in flow.json (do not click "Apply fix" on the canvas)`);
}

process.exit(bad ? 1 : 0);
