// lint-robin.js — Robin 脚本的「流程卫生」检查（对应 PAD 设计器右上角流检查器的部分规则）
//
// 三条规则，全部只读、只报 warning，不改变 check.js 的退出码：
//   1) unused-output  动作捕获了输出变量，但后续从未读取
//   2) unused-var     SET 声明了变量，但后续从未读取
//   3) nested-if      IF 嵌套过深（阈值默认 3 层，超过即提示）
//
// 为什么放在离线工具里：设计器里的「应用修复」会直接改画布，使 flow.json 与线上漂移；
// 这里只给警告，修复仍回到 flow.json 做。

const RULE_UNUSED_OUTPUT = "unused-output";
const RULE_UNUSED_VAR = "unused-var";
const RULE_NESTED_IF = "nested-if";

// 默认嵌套阈值：IF 层数 > 3 时提示（与设计器实测口径对齐）
const DEFAULT_MAX_IF_DEPTH = 3;

// 把标识符从“定义位置”上抹掉，剩下的文本里若还能找到该标识符，说明被读过
function stripDefinitions(text, names) {
  let out = text;
  for (const name of names) {
    const esc = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    // 输出捕获：Xxx=> Name
    out = out.replace(new RegExp(`\\w+=>\\s*${esc}\\b`, "g"), "");
    // 变量声明：SET Name TO / SET Name =
    out = out.replace(new RegExp(`^\\s*SET\\s+${esc}\\s+(TO|=)`, "gim"), "");
  }
  return out;
}

function isUsed(text, name) {
  // 变量在表达式中出现：%Name% 或 Name.Property 或裸标识符
  const esc = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9_])${esc}([^A-Za-z0-9_]|$)`, "i").test(text);
}

/**
 * 分析一段 Robin 文本。
 * @param {string} text
 * @param {{maxIfDepth?: number}} [opts]
 * @returns {{warnings: Array<{rule:string,line:number,message:string}>, stats: object}}
 */
function lintRobin(text, opts = {}) {
  const maxIfDepth = Number.isInteger(opts.maxIfDepth) ? opts.maxIfDepth : DEFAULT_MAX_IF_DEPTH;
  const lines = String(text).split(/\r?\n/);
  const codeLines = lines.filter((l) => !/^\s*#/.test(l));
  const code = codeLines.join("\n");

  // ── 收集定义 ──────────────────────────────────────────────
  const outputs = []; // {name, line}
  const declared = []; // {name, line}
  lines.forEach((raw, i) => {
    const line = i + 1;
    if (/^\s*#/.test(raw)) return;
    const outRe = /(\w+)=>\s*([A-Za-z_][A-Za-z0-9_]*)/g;
    let m;
    while ((m = outRe.exec(raw)) !== null) outputs.push({ name: m[2], line });
    const setRe = /^\s*SET\s+([A-Za-z_][A-Za-z0-9_]*)\s+(TO|=)\b/i;
    const sm = setRe.exec(raw);
    if (sm) declared.push({ name: sm[1], line });
  });

  const warnings = [];

  // ── 规则 1：捕获了但没读 ──────────────────────────────────
  const names = [...new Set(outputs.map((o) => o.name))];
  const usageText = stripDefinitions(code, names);
  const seenOutput = new Set();
  for (const o of outputs) {
    if (seenOutput.has(o.name)) continue;
    seenOutput.add(o.name);
    if (!isUsed(usageText, o.name)) {
      warnings.push({
        rule: RULE_UNUSED_OUTPUT,
        line: o.line,
        message: `输出变量 ${o.name} 被捕获但从未使用（不需要就读，可留空）`,
      });
    }
  }

  // ── 规则 2：声明了但没读 ──────────────────────────────────
  const declNames = [...new Set(declared.map((d) => d.name))];
  const declUsage = stripDefinitions(code, declNames);
  const seenDecl = new Set();
  for (const d of declared) {
    if (seenDecl.has(d.name)) continue;
    seenDecl.add(d.name);
    // 只在该变量“最后一次声明”之后仍无引用时才算未用
    if (!isUsed(declUsage, d.name)) {
      warnings.push({
        rule: RULE_UNUSED_VAR,
        line: d.line,
        message: `变量 ${d.name} 声明后从未被引用`,
      });
    }
  }

  // ── 规则 3：IF 嵌套过深 ───────────────────────────────────
  const stack = [];
  let ifDepth = 0;
  const depthHistogram = {};
  lines.forEach((raw, i) => {
    const line = i + 1;
    const t = raw.trim();
    if (!t || t.startsWith("#")) return;
    if (/^IF\b/i.test(t) && /\bTHEN\s*$/i.test(t)) {
      stack.push("IF");
      ifDepth += 1;
      depthHistogram[ifDepth] = (depthHistogram[ifDepth] || 0) + 1;
      if (ifDepth > maxIfDepth) {
        warnings.push({
          rule: RULE_NESTED_IF,
          line,
          message: `IF 嵌套 ${ifDepth} 层（上限 ${maxIfDepth}），建议改为提前退出或合并条件`,
        });
      }
      return;
    }
    if (/^(LOOP|FOR\s+EACH|SWITCH|WHILE|REPEAT)\b/i.test(t)) {
      stack.push("BLOCK");
      return;
    }
    if (/^END\b/i.test(t)) {
      const top = stack.pop();
      if (top === "IF") ifDepth -= 1;
      return;
    }
  });

  return {
    warnings,
    stats: {
      outputs: names.length,
      declared: declNames.length,
      ifDepthHistogram: depthHistogram,
      maxIfDepth,
    },
  };
}

// ── CLI ────────────────────────────────────────────────────
if (require.main === module) {
  const fs = require("fs");
  const file = process.argv[2];
  if (!file) {
    console.error("用法: node lint-robin.js <file.robin> [--max-if-depth N]");
    process.exit(1);
  }
  const idx = process.argv.indexOf("--max-if-depth");
  const opts = idx > 0 ? { maxIfDepth: parseInt(process.argv[idx + 1], 10) } : {};
  const text = fs.readFileSync(file, "utf8");
  const { warnings, stats } = lintRobin(text, opts);
  for (const w of warnings) console.log(`[lint] 第 ${w.line} 行 ${w.rule}: ${w.message}`);
  const byRule = {};
  for (const w of warnings) byRule[w.rule] = (byRule[w.rule] || 0) + 1;
  const summary = Object.entries(byRule).map(([k, v]) => `${k}=${v}`).join(" ") || "无警告";
  console.log(`[lint] ${file}: ${summary}（输出变量 ${stats.outputs} / 声明变量 ${stats.declared}）`);
  process.exit(0);
}

module.exports = { lintRobin, RULE_UNUSED_OUTPUT, RULE_UNUSED_VAR, RULE_NESTED_IF };
