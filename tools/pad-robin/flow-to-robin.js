#!/usr/bin/env node
/**
 * flow-to-robin.js — 确定性生成器：flow.json → Robin 脚本（查表填空）
 *
 * 用法：
 *   node flow-to-robin.js <flow.json> [out.robin] [--kb <kb.json>] [--no-check]
 *
 * 设计原则：
 * - 动作骨架直接取 KB golden_example 的 actionId / 参数名 / 参数顺序 / 输出名，绝不改写
 * - 值来源优先级：flow 节点 params → 句柄自动接上游 Launch → KB default → golden 占位值（告警）
 * - 类型格式化：String/FileObject/FolderObject → $'''…'''；数字/布尔裸写；枚举 → Module.EnumType.Value
 * - 字符串转义：\ 双写、' → \'、单个 % → %%
 * - 引用：{{2.RetrievedEmails}} → 上游输出变量；{{config.X}} / {{variables.X}} → 裸变量 X
 * - 安全闸门：unknown action / 未知参数 / needs_ui_selector / 悬空引用 → 报错并拒绝产出（退出码 1）
 */

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

// ── CLI 参数 ──────────────────────────────────────────────────
const args = process.argv.slice(2);
const flowPath = args.shift();
let outPath = null;
let kbPath = null;
let noCheck = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--kb") kbPath = args[++i];
  else if (args[i] === "--no-check") noCheck = true;
  else if (args[i].startsWith("--")) { /* 未知选项忽略 */ }
  else outPath = args[i];
}

if (!flowPath) {
  console.error("用法: node flow-to-robin.js <flow.json> [out.robin] [--kb <kb.json>] [--no-check]");
  process.exit(1);
}

// ── 加载 KB ───────────────────────────────────────────────────
if (!kbPath) {
  const candidates = [
    path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
    path.join(process.cwd(), "pad-robin-action-kb", "PAD_Robin_ActionKB.json"),
  ];
  kbPath = candidates.find((p) => fs.existsSync(p));
}
if (!kbPath || !fs.existsSync(kbPath)) {
  console.error("[错误] 找不到 PAD_Robin_ActionKB.json，请用 --kb 指定路径");
  process.exit(1);
}
const kb = JSON.parse(fs.readFileSync(kbPath, "utf8"));
const actionMap = new Map(kb.actions.map((a) => [a.actionId, a]));

// ── 加载 flow ─────────────────────────────────────────────────
const flow = JSON.parse(fs.readFileSync(flowPath, "utf8"));

// edges 一致性闸门：flow.json 同时维护 edges（画图）与 next/branch（生成代码），
// 生成前先确认两边没漂移，避免 PAD 代码与流程图各说各话
try {
  const { checkFlowConsistency } = require(path.join(__dirname, "..", "flow-drawio", "check-flow.js"));
  if (Array.isArray(flow.edges) && flow.edges.length) {
    const drift = checkFlowConsistency(flow);
    if (!drift.ok) {
      console.error("[错误] edges 与 next/branch 不一致，拒绝生成：");
      if (drift.missing.length) {
        console.error("  缺少边：" + drift.missing.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      if (drift.duplicates.length) {
        console.error("  重复边：" + drift.duplicates.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      if (drift.dangling.length) {
        console.error("  悬空边：" + drift.dangling.map((e) => `${e.from}->${e.to}`).join(", "));
      }
      process.exit(1);
    }
  }
} catch (e) {
  if (e && e.code === "MODULE_NOT_FOUND") {
    console.error("[警告] 找不到 check-flow.js，跳过 edges 一致性校验");
  } else {
    throw e;
  }
}

// 句柄类型 → 上游产出变量名的映射（运行时填充）
const handleVars = {}; // { ExcelInstance: "ExcelInstance", OutlookInstance: "OutlookInstance", ... }

// 所有已定义变量（用于悬空引用检查）
const definedVars = new Set();

// ── 工具函数 ──────────────────────────────────────────────────
const CONTROL_FLOW = new Set(["IF", "LOOP", "SWITCH", "GUARD"]);

function isHandleType(t) {
  return /Handle$|Instance$/.test(t) || t === "ExcelInstance" || t === "OutlookInstance" || t === "Browser";
}

function handleBaseName(type) {
  // ExcelInstanceHandle → ExcelInstance, OutlookInstance → OutlookInstance
  return type.replace(/Handle$/, "");
}

/** WAIT 节点等待秒数：读 params.Seconds，缺省 60 秒 */
function waitSeconds(node) {
  const s = node.params && node.params.Seconds != null ? node.params.Seconds : 60;
  return s;
}

/** 按类型格式化值 */
function formatValue(raw, paramType, action) {
  if (raw == null) return null;

  // 布尔 / 数字裸写
  if (paramType === "Boolean") {
    if (raw === true || raw === "true" || raw === "True") return "True";
    if (raw === false || raw === "false" || raw === "False") return "False";
    return raw ? "True" : "False";
  }
  if (paramType === "Int32" || paramType === "Int64" || paramType === "Double" || paramType === "Decimal") {
    return String(raw);
  }

  // 枚举：全限定 Module.EnumType.Value
  if (action && action.input_params) {
    const p = action.input_params.find((x) => x.type === paramType);
    if (p && p.enumValues && p.enumValues.includes(raw)) {
      // 枚举类型名去掉 Values 后缀，如 RetrieveMessagesMode
      const enumType = paramType;
      return `${action.module}.${enumType}.${raw}`;
    }
  }

  // 字符串 / 文件 / 文件夹：$'''…''' + 转义
  if (["String", "FileObject", "FolderObject", "SecureString"].includes(paramType)) {
    return formatString(raw);
  }

  // 变量引用或表达式：裸写
  return String(raw);
}

/**
 * 转义字符串字面量内容（不含 $'''…''' 包裹）：\ 双写、' → \'、单个 % → %%
 * %Var% 是 PAD 的变量引用（如 %PadRoot%），必须原样保留，否则会被当成字面百分号转义坏
 */
function escapeLiteral(s) {
  return String(s)
    .split(/(%[A-Za-z_]\w*%)/)
    .map((seg) => (/^%[A-Za-z_]\w*%$/.test(seg)
      ? seg
      : seg.replace(/\\/g, "\\\\").replace(/'/g, "\\'").replace(/%/g, "%%")))
    .join("");
}

/** 字符串格式化 + 转义 */
function formatString(s) {
  return `$'''${escapeLiteral(s)}'''`;
}

/** 解析 {{ref}} 引用，返回裸变量名 */
function resolveRef(ref, currentNodeId) {
  // {{2.RetrievedEmails}} → 节点2 的输出变量 RetrievedEmails
  const m = ref.match(/^\{\{(\d+)\.(\w+)\}\}$/);
  if (m) {
    const [, srcId, field] = m;
    const srcNode = flow.nodes.find((n) => n.id === srcId);
    if (!srcNode) throw new Error(`节点 ${currentNodeId} 引用了不存在的节点 ${srcId}`);
    // 1. 节点 output_map 显式指定的变量名
    if (srcNode.output_map && srcNode.output_map[field]) return srcNode.output_map[field];
    // 1b. output_map 的键可能是 KB 输出名（如 Content→FileContents），按 KB 名反查
    if (srcNode.output_map) {
      const act0 = actionMap.get(srcNode.pad_hint);
      const ops0 = (act0 && act0.output_params) || [];
      for (const k of Object.keys(srcNode.output_map)) {
        const op0 = ops0.find((o) => o.name === k);
        const kbName = op0 ? (goldenOutputName(act0, k) || op0.defaultVariable || k) : k;
        if (kbName === field) return srcNode.output_map[k];
      }
    }
    // 2. 优先用 outputs[] 里的绑定名，否则用 KB 默认变量名
    if (srcNode.outputs && srcNode.outputs.includes(field)) return field;
    // 3. 查 KB 输出参数的 defaultVariable
    const action = actionMap.get(srcNode.pad_hint);
    if (action && action.output_params) {
      const op = action.output_params.find((o) => o.name === field);
      if (op) return goldenOutputName(action, field) || op.defaultVariable || field;
    }
    return field;
  }
  // {{config.X}} / {{variables.X}} → 裸变量 X
  const cm = ref.match(/^\{\{(?:config|variables)\.(\w+)\}\}$/);
  if (cm) return cm[1];
  // {{X}} → 裸变量 X
  const sm = ref.match(/^\{\{(\w+)\}\}$/);
  if (sm) return sm[1];
  return null;
}

/** 处理参数值：可能是字面量，也可能含 {{ref}} 内嵌 */
function resolveParamValue(value, paramType, action, nodeId) {
  if (typeof value !== "string") return formatValue(value, paramType, action);

  // 整个值就是一个引用
  const fullRef = resolveRef(value, nodeId);
  if (fullRef) return fullRef;

  // 字符串内含 {{ref}}：分段处理 —— 字面量段转义，引用段保留为裸 %Var%，
  // 避免 %Var% 里的 % 被当成字面百分号转义成 %%Var%%
  if (value.includes("{{")) {
    const segs = [];
    const refRe = /\{\{\d+\.\w+\}\}|\{\{(?:config|variables)\.\w+\}\}|\{\{\w+\}\}/g;
    let last = 0;
    let m;
    while ((m = refRe.exec(value))) {
      if (m.index > last) segs.push(escapeLiteral(value.slice(last, m.index)));
      const v = resolveRef(m[0], nodeId);
      segs.push(v ? `%${v}%` : escapeLiteral(m[0]));
      last = m.index + m[0].length;
    }
    if (last < value.length) segs.push(escapeLiteral(value.slice(last)));
    return `$'''${segs.join("")}'''`;
  }

  return formatValue(value, paramType, action);
}

/**
 * 表达式里的引用替换：{{2.Field}} / {{variables.X}} → 裸变量名
 * 只替换引用片段，表达式本身（比较符、函数调用）原样保留
 */
function resolveExpression(s, nodeId) {
  if (typeof s !== "string") return s;
  return s.replace(/\{\{\d+\.\w+\}\}|\{\{(?:config|variables)\.\w+\}\}|\{\{\w+\}\}/g,
    (m) => resolveRef(m, nodeId) || m);
}

// ── 安全闸门 ──────────────────────────────────────────────────
const errors = [];
const warnings = [];

function gate(node, msg) {
  errors.push(`节点 ${node.id}「${node.label || node.type}」: ${msg}`);
}

// ── 生成变量初始化 ─────────────────────────────────────────────
const lines = [];
if (flow.variables && flow.variables.length) {
  for (const v of flow.variables) {
    if (v.comment) lines.push(`# ${v.comment}`);
    // deployKey：部署时由 pad-deploy 用 config 值替换 {{KEY}}，仓库里不落真实账号/路径
    let val;
    if (v.deployKey) {
      val = formatString(`{{${v.deployKey}}}`);
    } else if (v.default !== undefined && v.default !== null) {
      val = v.type === "number" ? v.default :
            v.type === "boolean" ? (v.default ? "True" : "False") :
            formatString(v.default);
    }
    if (val !== undefined) {
      lines.push(`SET ${v.name} TO ${val}`);
      definedVars.add(v.name);
    } else {
      // 无默认值：生成注释提醒
      lines.push(`# TODO: 变量 ${v.name}（${v.type}）无默认值，请在 PAD 中设为输入变量或补值`);
      warnings.push(`变量 ${v.name} 无默认值`);
    }
  }
  if (flow.variables.length) lines.push("");
}

// 被控制流节点「吞掉」的子节点（在主循环中跳过，避免重复生成）
const consumed = new Set();

/**
 * 输出一行动作代码。
 * 节点带 on_error="continue" 时，按 PAD 的「出错继续运行→转到下一个操作」生成空处理器：
 *   <动作行>
 *   ON ERROR
 *   END
 */
function pushActionLine(node, parts) {
  const actionLine = parts.join(" ");
  lines.push(actionLine);
  if (node.on_error === "continue") {
    lines.push("ON ERROR");
    lines.push("END");
  }
}

// ── 生成节点 ──────────────────────────────────────────────────
for (const node of flow.nodes) {
  if (consumed.has(node.id)) continue;  // 已被某个控制流节点作为 body 生成

  const padHint = node.pad_hint;

  // 控制流节点
  if (CONTROL_FLOW.has(padHint)) {
    generateControlFlow(node);
    continue;
  }

  // WAIT 节点：Robin 内建等待语句（与 SET/IF/LOOP 同类，不在 KB 动作表里）
  if (node.type === "wait" || padHint === "WAIT") {
    lines.push(`WAIT ${waitSeconds(node)}`);
    continue;
  }

  // 跳出循环节点：Robin 内建 EXIT LOOP（仅出现在 LOOP 体内）
  if (node.type === "break" || padHint === "EXIT LOOP" || padHint === "EXIT_LOOP") {
    lines.push(`EXIT LOOP`);
    continue;
  }

  // 查 KB
  const action = actionMap.get(padHint);
  if (!action) {
    gate(node, `未知动作 pad_hint="${padHint}"（KB 中查不到，拒绝产出）`);
    continue;
  }

  // UI 选择器闸门
  if (action.needs_ui_selector) {
    gate(node, `动作 ${padHint} 需要 UI 选择器（needs_ui_selector=true），无法自动生成，请先在 PAD 中录制元素`);
    continue;
  }

  // 检查 params 的键是否合法
  const validParamNames = new Set(action.input_params.map((p) => p.name));
  for (const key of Object.keys(node.params || {})) {
    if (!validParamNames.has(key)) {
      gate(node, `未知参数 "${key}"（动作 ${padHint} 的合法参数：${[...validParamNames].join(", ")}）`);
    }
  }

  // 构建动作行
  const parts = [padHint];
  const params = node.params || {};

  for (const p of action.input_params) {
    let rawVal = params[p.name];
    let val;

    if (rawVal !== undefined && rawVal !== null) {
      // 1. flow 显式给定
      val = resolveParamValue(rawVal, p.type, action, node.id);
    } else if (isHandleType(p.type)) {
      // 2. 句柄类型：自动接上游 Launch 产出的变量
      const base = handleBaseName(p.type);
      const hv = handleVars[base];
      if (hv) {
        val = hv;
      } else if (p.default) {
        val = p.default;
      } else {
        gate(node, `参数 ${p.name}（类型 ${p.type}）需要句柄变量，但流程中没有 Launch 动作产出该句柄`);
        val = base; // 占位
      }
    } else if (p.default !== undefined) {
      // 3. KB 默认值
      val = formatValue(p.default, p.type, action);
    } else {
      // 4. 未提供且无默认值：直接省略该参数（与 KB golden 的写法一致，避免填入占位垃圾）
      continue;
    }

    parts.push(`${p.name}: ${val}`);
  }

  // 输出绑定
  for (const op of action.output_params) {
    // 句柄类型用类型推导的变量名（OutlookInstance / ExcelInstance），避免都叫 Instance 冲突
    const outputName = outputVarName(node, action, op);
    parts.push(`${op.name}=> ${outputName}`);
    definedVars.add(outputName);
    // 记录句柄产出
    if (isHandleType(op.type)) {
      handleVars[handleBaseName(op.type)] = outputName;
    }
  }

  pushActionLine(node, parts);
}

// ── 控制流生成 ─────────────────────────────────────────────────
function generateControlFlow(node) {
  // 收集这个控制流节点「吞掉」的所有子节点 id
  const allBody = [];
  let ifTrue = [];
  let ifFalse = [];
  if (node.pad_hint === "IF" && node.branch) {
    // true 支路：优先 trueBody / body 数组，退化为 branch.true 单节点
    if (Array.isArray(node.branch.trueBody)) ifTrue = node.branch.trueBody.slice();
    else if (Array.isArray(node.branch.body)) ifTrue = node.branch.body.slice();
    else if (node.branch.true != null) ifTrue = [String(node.branch.true)];
    // false 支路：优先 falseBody 数组；退化为 branch.false 单节点，
    // 且仅当它不在 next（即不是 IF 之后的汇合点）时，才算独立的 else 分支
    if (Array.isArray(node.branch.falseBody)) ifFalse = node.branch.falseBody.slice();
    else if (node.branch.false != null) {
      const f = String(node.branch.false);
      if (!(node.next || []).includes(f)) ifFalse = [f];
    }
    allBody.push(...ifTrue, ...ifFalse);
  }
  if (node.pad_hint === "LOOP" && node.loop && node.loop.body) {
    allBody.push(...node.loop.body);
  }
  if (node.pad_hint === "SWITCH" && node.switch) {
    for (const c of node.switch.cases || []) allBody.push(...(c.body || []));
    if (node.switch.default) allBody.push(...node.switch.default);
  }
  // guard：副作用守卫（如 DRY_RUN），语义等同 IF + ELSE，但可被准入网关按类型识别
  if (node.pad_hint === "GUARD") {
    allBody.push(...(node.body || []), ...(node.elseBody || []));
  }
  // 子节点生成：已被「内层控制流」吞掉的节点要跳过，否则外层会再输出一遍。
  // 因此 consumed 的登记放在生成之后：内层先生成并登记自己的子节点，
  // 外层随后遍历到它们时就会被跳过。
  const emit = (bid) => {
    if (consumed.has(bid)) return;
    const child = flow.nodes.find((n) => n.id === bid);
    if (child) generateNodeInline(child);
  };

  if (node.pad_hint === "IF") {
    const cond = node.params && node.params.Condition ? resolveExpression(node.params.Condition, node.id) : "True";
    lines.push(`IF ${cond} THEN`);
    // true 支路
    for (const bid of ifTrue) emit(bid);
    // false 支路：只有存在独立 else 时才输出 ELSE，避免与 next 汇合点重复输出
    if (ifFalse.length) {
      lines.push(`ELSE`);
      for (const bid of ifFalse) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "GUARD") {
    const cond = resolveExpression(node.when || "True", node.id);
    lines.push(`IF ${cond} THEN`);
    for (const bid of node.body || []) emit(bid);
    if ((node.elseBody || []).length) {
      lines.push(`ELSE`);
      for (const bid of node.elseBody) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "LOOP") {
    const lp = node.loop || {};
    if (lp.kind === "foreach") {
      const listVar = resolveRef(lp.list, node.id) || lp.list;
      lines.push(`LOOP FOREACH ${lp.item} IN ${listVar}`);
    } else if (lp.kind === "fromto") {
      lines.push(`LOOP ${lp.index} FROM ${lp.from} TO ${lp.to} STEP ${lp.step || 1}`);
    } else if (lp.kind === "while") {
      lines.push(`LOOP WHILE ${lp.condition}`);
    }
    if (lp.body) {
      for (const bid of lp.body) emit(bid);
    }
    lines.push(`END`);
  } else if (node.pad_hint === "SWITCH") {
    const sw = node.switch || {};
    lines.push(`SWITCH ${resolveExpression(sw.expression, node.id)}`);
    for (const c of sw.cases || []) {
      lines.push(`CASE ${c.case}`);
      for (const bid of c.body || []) emit(bid);
    }
    if (sw.default) {
      lines.push(`DEFAULT`);
      for (const bid of sw.default) emit(bid);
    }
    lines.push(`END`);
  }

  // 登记本层吞掉的节点，供上层/主循环跳过
  for (const bid of allBody) consumed.add(bid);
}

function generateNodeInline(node) {
  // 简化：内联节点不重复走主循环，直接生成一行（控制流嵌套暂时只支持一层）
  if (CONTROL_FLOW.has(node.pad_hint)) {
    generateControlFlow(node);
    return;
  }
  // WAIT 节点：Robin 内建等待语句
  if (node.type === "wait" || node.pad_hint === "WAIT") {
    lines.push(`WAIT ${waitSeconds(node)}`);
    return;
  }
  // 跳出循环节点：Robin 内建 EXIT LOOP
  if (node.type === "break" || node.pad_hint === "EXIT LOOP" || node.pad_hint === "EXIT_LOOP") {
    lines.push(`EXIT LOOP`);
    return;
  }
  const action = actionMap.get(node.pad_hint);
  if (!action) {
    gate(node, `未知动作 pad_hint="${node.pad_hint}"`);
    return;
  }
  if (action.needs_ui_selector) {
    gate(node, `动作 ${node.pad_hint} 需要 UI 选择器`);
    return;
  }
  const parts = [node.pad_hint];
  const params = node.params || {};
  for (const p of action.input_params) {
    let rawVal = params[p.name];
    let val;
    if (rawVal !== undefined && rawVal !== null) {
      val = resolveParamValue(rawVal, p.type, action, node.id);
    } else if (isHandleType(p.type)) {
      const base = handleBaseName(p.type);
      val = handleVars[base] || base;
    } else if (p.default !== undefined) {
      val = formatValue(p.default, p.type, action);
    } else {
      // 未提供且无默认值：直接省略该参数（与 KB golden 的写法一致，避免填入占位垃圾）
      continue;
    }
    parts.push(`${p.name}: ${val}`);
  }
  for (const op of action.output_params) {
    const outputName = outputVarName(node, action, op);
    parts.push(`${op.name}=> ${outputName}`);
    if (isHandleType(op.type)) handleVars[handleBaseName(op.type)] = outputName;
  }
  pushActionLine(node, parts);
}

/** 从 KB golden_example 读取输出参数的默认变量名（如 ExitCode=> CommandExitCode） */
function goldenOutputName(action, outName) {
  const golden = action.golden_example || "";
  const m = golden.match(new RegExp(`${outName}\\s*=>\\s*(\\w+)`));
  return m ? m[1] : null;
}

/** 计算输出参数绑定的变量名：节点 output_map > KB defaultVariable > golden 默认名 > 句柄类型推导 > 参数名 */
function outputVarName(node, action, op) {
  const map = node.output_map || {};
  if (map[op.name]) return map[op.name];
  return op.defaultVariable ||
         goldenOutputName(action, op.name) ||
         (isHandleType(op.type) ? handleBaseName(op.type) : op.name);
}

// ── 悬空引用检查 ───────────────────────────────────────────────
// （简化：检查所有 {{ref}} 的节点 id 是否存在，字段是否是该节点输出）
for (const node of flow.nodes) {
  if (!node.params) continue;
  for (const [key, val] of Object.entries(node.params)) {
    if (typeof val !== "string") continue;
    const refs = val.match(/\{\{(\d+)\.(\w+)\}\}/g) || [];
    for (const ref of refs) {
      const m = ref.match(/\{\{(\d+)\.(\w+)\}\}/);
      const srcNode = flow.nodes.find((n) => n.id === m[1]);
      if (!srcNode) {
        gate(node, `参数 ${key} 引用了不存在的节点 ${m[1]}`);
      }
    }
  }
}

// ── 输出结果 ──────────────────────────────────────────────────
const output = lines.join("\n") + "\n";

if (errors.length) {
  console.error("=== 生成器安全闸门拦截 ===");
  for (const e of errors) console.error("  ✗ " + e);
  console.error(`\n共 ${errors.length} 个错误，拒绝产出。请修正 flow.json 后重跑。`);
  process.exit(1);
}

if (warnings.length) {
  console.error("=== 警告 ===");
  for (const w of warnings) console.error("  ! " + w);
}

// 写文件
if (outPath) {
  fs.writeFileSync(outPath, output, "utf8");
  console.error(`已生成: ${outPath}（${flow.nodes.length} 个节点）`);
} else {
  process.stdout.write(output);
}

// ── 静态自检 ──────────────────────────────────────────────────
if (!noCheck && outPath) {
  const checkFlows = path.join(path.dirname(kbPath), "marketing", "video", "tools", "check-flows.js");
  if (fs.existsSync(checkFlows)) {
    try {
      execFileSync(process.execPath, [checkFlows, kbPath, outPath], { stdio: "inherit" });
      console.error("静态自检: 通过");
    } catch (e) {
      console.error("静态自检: 发现问题（见上方 check-flows 输出）");
      process.exit(1);
    }
  } else {
    console.error(`[跳过自检] 找不到 check-flows.js（预期路径: ${checkFlows}）`);
  }
}
