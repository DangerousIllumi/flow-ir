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
  console.error("用法: node check.js <out.robin | 目录>");
  process.exit(1);
}

// 定位 KB
const kbCandidates = [
  path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
  path.join(process.cwd(), "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
];
const kbPath = kbCandidates.find((p) => fs.existsSync(p));
if (!kbPath) {
  console.error("[错误] 找不到 PAD_Robin_ActionKB.json");
  process.exit(1);
}

// 定位 check-flows.js
// 校验器已从 KB 仓库的 marketing/video/tools 迁到本目录（脱离上游 git 结构）
const checkFlows = path.join(__dirname, "check-flows.js");
if (!fs.existsSync(checkFlows)) {
  console.error(`[错误] 找不到 check-flows.js（预期: ${checkFlows}）`);
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
  console.error("[错误] 没有找到 .robin / .txt 文件");
  process.exit(1);
}

let bad = false;
for (const f of files) {
  try {
    execFileSync(process.execPath, [checkFlows, kbPath, f], { stdio: "inherit" });
  } catch (e) {
    bad = true;
  }
}

process.exit(bad ? 1 : 0);
