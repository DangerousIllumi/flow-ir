#!/usr/bin/env node
/**
 * eval-flow.js — 设计质量评估集：按需求文本断言 flow.json 的结构
 *
 * 只验结构，不评文案（D6）。两种用法：
 *   node eval-flow.js tests/eval/<name>.cases.json                  # 单个用例文件
 *   node eval-flow.js tests/eval                                   # 目录：跑里面所有 *.cases.json
 *
 * 用例文件里 `flow` 指向被测 flow.json；目录模式下每个用例文件各自带 flow。
 * 退出码：0 全部通过 / 1 有失败 / 2 输入错误
 */

const fs = require("fs");
const path = require("path");

// 节点运行方式的取值集合：自动执行 / 需人工确认 / 只读观察
const RUN_MODES = ["auto", "confirm", "observe"];

// 触发声明（trigger）的取值集合。
// 与 pad-admit 的 TRIGGER 检查共用同一口径：保留值单列，便于给出“支持但未实现”而不是“拼错”的提示。
const TRIGGER_KINDS = ["manual", "schedule", "file"];
const TRIGGER_RESERVED_KINDS = ["mail", "callback"];
const TRIGGER_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];
const TRIGGER_GATES = ["none", "workday", "last-workday"];
// HH:mm，只接受 24 小时制两位写法（9:00 这类一位写法直接判非法，避免注册时再猜）
const TRIGGER_TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

function isPlainObject(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function hasOwn(obj, key) {
  return Object.prototype.hasOwnProperty.call(obj, key);
}

// 正整数校验：JSON 里写成字符串或小数一律不认
function isPositiveInt(v) {
  return typeof v === "number" && Number.isFinite(v) && v > 0 && Number.isInteger(v);
}

// 已知不可逆动作：执行后无法撤回，声明 reversible=true 属于事实错误，直接判失败。
// 发信、删除文件/目录、过账脚本（按 intent 识别，不依赖参数名）。
const POSTING_INTENT_RE = /(migo|posting)/i;
function irreversibleReason(n) {
  const hint = String((n && n.pad_hint) || "");
  if (/^Outlook\.SendEmail/i.test(hint)) return "sending mail cannot be undone; only a corrective resend is possible";
  if (/^(File|Folder)\.Delete$/i.test(hint)) return "deleting files/directories cannot be undone";
  if (/^Scripting\.RunDOSCommand/i.test(hint) && POSTING_INTENT_RE.test(String((n && n.intent) || ""))) {
    return "re-running a posting script creates duplicate documents; only a reversing entry can correct it";
  }
  return null;
}

// 可逆性声明的完整校验：必须是布尔；false 必须带说明；已知不可逆动作不允许写 true。
function reversibleProblems(n) {
  const problems = [];
  if (typeof n.reversible !== "boolean") {
    problems.push(`reversible=${JSON.stringify(n.reversible)} (expected true/false)`);
    return problems;
  }
  if (n.reversible === false && !String(n.reversibility_note || "").trim()) {
    problems.push("reversible=false requires reversibility_note (explain how to roll back)");
  }
  const reason = irreversibleReason(n);
  if (reason && n.reversible === true) {
    problems.push(`action ${n.pad_hint} is irreversible (${reason}); reversible must be false`);
  }
  return problems;
}

/**
 * 校验 trigger 声明，返回 { errors, warnings }，条目形如 { code, detail }。
 * 只做静态契约校验，不查本机注册状态（注册验证属于 pad-trigger / pad-admit -TriggerLive）。
 * 结果码与 docs/trigger-adapter-design.md 第 4.2 节一致。
 */
function validateTrigger(flow, trg, opts = {}) {
  const errors = [];
  const warnings = [];
  const err = (code, detail) => errors.push({ code, detail });
  const warn = (code, detail) => warnings.push({ code, detail });

  if (trg === undefined || trg === null) {
    return { errors: [{ code: "TRIGGER_MISSING", detail: "missing trigger declaration" }], warnings };
  }
  if (!isPlainObject(trg)) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: "trigger must be an object" }], warnings };
  }
  // 旧形状：只有 type/config 没有 kind，不做静默映射
  if (!hasOwn(trg, "kind") && hasOwn(trg, "type")) {
    return { errors: [{ code: "TRIGGER_LEGACY_SHAPE", detail: "legacy type/config shape without kind" }], warnings };
  }
  if (typeof trg.kind !== "string" || !trg.kind) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: `kind=${JSON.stringify(trg.kind)} (must be a string)` }], warnings };
  }
  if (TRIGGER_RESERVED_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_KIND_UNSUPPORTED", detail: `kind=${trg.kind} is a reserved value; v1 has no registrar for it` }], warnings };
  }
  if (!TRIGGER_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_UNKNOWN_KIND", detail: `kind=${trg.kind} is not one of ${TRIGGER_KINDS.join("/")}` }], warnings };
  }
  const kind = trg.kind;

  // 任务名：显式给出时必须是安全字符，否则计划任务名无法稳定复现
  if (hasOwn(trg, "task_name")) {
    const tn = trg.task_name;
    if (typeof tn !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(tn)) {
      err("TRIGGER_INVALID", `task_name=${JSON.stringify(tn)} does not match ^[A-Za-z0-9._-]{1,64}$`);
    }
  }

  if (kind === "manual") {
    for (const key of ["time", "days", "gate", "timeout_sec", "file", "assisted"]) {
      if (hasOwn(trg, key)) err("TRIGGER_INVALID", `manual must not declare ${key} (nothing would execute it)`);
    }
    return { errors, warnings };
  }

  // schedule / file 共用：时刻、星期、日历门、超时
  const time = hasOwn(trg, "time") ? trg.time : undefined;
  if (typeof time !== "string" || !TRIGGER_TIME_RE.test(time)) {
    err("TRIGGER_INVALID", `time=${JSON.stringify(time)} (expected HH:mm, e.g. 09:00)`);
  }
  if (hasOwn(trg, "days")) {
    if (!Array.isArray(trg.days) || trg.days.length === 0) {
      err("TRIGGER_INVALID", `days=${JSON.stringify(trg.days)} (expected a non-empty array)`);
    } else if (trg.days.some((d) => !TRIGGER_DAYS.includes(d))) {
      err("TRIGGER_INVALID", `days contains invalid values: ${JSON.stringify(trg.days.filter((d) => !TRIGGER_DAYS.includes(d)))}`);
    }
  }
  if (hasOwn(trg, "gate")) {
    if (!TRIGGER_GATES.includes(trg.gate)) {
      err("TRIGGER_INVALID", `gate=${JSON.stringify(trg.gate)} is not one of ${TRIGGER_GATES.join("/")}`);
    }
  } else if (kind === "schedule") {
    warn("TRIGGER_NO_GATE", "schedule declares no gate, so it will still run on holidays (write gate=none explicitly if that is intended)");
  }
  if (hasOwn(trg, "timeout_sec") && !isPositiveInt(trg.timeout_sec)) {
    err("TRIGGER_INVALID", `timeout_sec=${JSON.stringify(trg.timeout_sec)} (expected a positive integer number of seconds)`);
  }

  // assisted：到点自动启动、中途有人确认；只对 schedule/file 有意义，manual 已在上面拒绝
  let assisted = false;
  if (hasOwn(trg, "assisted")) {
    if (typeof trg.assisted !== "boolean") {
      err("TRIGGER_INVALID", `assisted=${JSON.stringify(trg.assisted)} (expected true/false)`);
    } else {
      assisted = trg.assisted;
    }
    if (assisted && !hasOwn(trg, "timeout_sec")) {
      err("TRIGGER_ASSISTED_NO_TIMEOUT", "assisted=true requires an explicit timeout_sec (the timeout alert is the fallback when nobody confirms)");
    }
  }

  if (kind === "file") {
    if (!hasOwn(trg, "file") || !isPlainObject(trg.file)) {
      err("TRIGGER_INVALID", "file trigger requires a file object");
    } else {
      const f = trg.file;
      const dir = hasOwn(f, "dir") ? f.dir : undefined;
      if (typeof dir !== "string" || !dir) {
        err("TRIGGER_INVALID", "file.dir is required");
      } else if (!/^\{\{config\.\w+\}\}$/.test(dir)) {
        // 只接受配置引用，禁止把绝对路径写进 flow.json
        err("TRIGGER_PATH_LITERAL", `file.dir=${dir} must be a {{config.<KEY>}} reference, not a literal path`);
      }
      if (typeof f.pattern !== "string" || !f.pattern.trim()) {
        err("TRIGGER_INVALID", "file.pattern is required and must not be empty");
      }
      for (const key of ["poll_sec", "settle_sec", "max_wait_sec"]) {
        if (hasOwn(f, key) && !isPositiveInt(f[key])) {
          err("TRIGGER_INVALID", `file.${key}=${JSON.stringify(f[key])} (expected a positive integer number of seconds)`);
        }
      }
      if (hasOwn(f, "once_per_file") && typeof f.once_per_file !== "boolean") {
        err("TRIGGER_INVALID", `file.once_per_file=${JSON.stringify(f.once_per_file)} (expected true/false)`);
      }
    }
  }

  // 与节点声明的交叉校验：只对“真实流程”生效；断言里传入的 def 只验声明形状，不拿流程节点做陪衬
  if (!opts.skipCrossCheck) {
    const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];
    const confirmNodes = nodes.filter((n) => n && n.run_mode === "confirm");
    if (confirmNodes.length > 0 && assisted !== true) {
      err("TRIGGER_UNATTENDED_CONFIRM", `unattended trigger but nodes require manual confirmation: ${confirmNodes.map((n) => n.id).join(",")}`);
    }
    // 可逆性收窄：与幂等性是两个正交的轴，不再用 idempotent=false 代表后果风险。
    //   idempotent = 同一输入重跑是否收敛（重跑安全）
    //   reversible = 已经产生的后果能否撤回（删除可重建、发信可补正、过账只能冲销）
    const irreversible = nodes.filter((n) => n && n.reversible === false);
    if (irreversible.length > 0) {
      warn("TRIGGER_UNATTENDED_IRREVERSIBLE",
        `unattended trigger but nodes have irreversible consequences: ${irreversible
          .map((n) => `${n.id}${n.reversibility_note ? `（${n.reversibility_note}）` : ""}`)
          .join("、")}`);
    }
    // idempotent=false 却没声明 reversible：提示补声明，不默认填充
    const missingRev = nodes.filter(
      (n) => n && n.idempotent === false && !hasOwn(n, "reversible"));
    if (missingRev.length > 0) {
      warn("TRIGGER_MISSING_REVERSIBILITY",
        `nodes with idempotent=false declare no reversible: ${missingRev.map((n) => n.id).join(",")}`);
    }
  }

  return { errors, warnings };
}

// 输入文件声明（节点级 inputs）的目录写法：与 file 触发器同一口径，只接受 {{config.<KEY>}}，
// 禁止把真实路径写进 flow.json（公开层与业务层都按这一条校验）
const INPUT_DIR_RE = /^\{\{config\.\w+\}\}$/;

/**
 * 校验节点级输入文件声明，返回 { errors, warnings }，条目形如 { code, detail }。
 * 只验声明形状，不碰文件系统；“目录可读 / 候选文件计数”属于 pad-admit 的 INPUT 检查。
 * 老 flow.json 不写 inputs 时只给一条 INPUT_UNDECLARED 提示，不判失败（向后兼容）。
 */
function validateInputs(flow, opts = {}) {
  const errors = [];
  const warnings = [];
  const err = (code, detail) => errors.push({ code, detail });
  const warn = (code, detail) => warnings.push({ code, detail });

  const nodes = Array.isArray(flow && flow.nodes) ? flow.nodes : [];
  const targets = opts.node ? nodes.filter((n) => n && n.id === opts.node) : nodes;
  let declared = 0;

  for (const n of targets) {
    if (!hasOwn(n, "inputs")) continue;
    declared++;
    if (!Array.isArray(n.inputs) || n.inputs.length === 0) {
      err("INPUT_INVALID", `node ${n.id}: inputs must be a non-empty array`);
      continue;
    }
    n.inputs.forEach((it, i) => {
      const at = `node ${n.id} inputs[${i}]`;
      if (!isPlainObject(it)) {
        err("INPUT_INVALID", `${at} must be an object`);
        return;
      }
      const dir = it.dir;
      if (typeof dir !== "string" || !dir) {
        err("INPUT_INVALID", `${at}.dir is required`);
      } else if (!INPUT_DIR_RE.test(dir)) {
        err("INPUT_PATH_LITERAL", `${at}.dir=${dir} must be a {{config.<KEY>}} reference, not a literal path`);
      }
      if (typeof it.pattern !== "string" || !it.pattern.trim()) {
        err("INPUT_INVALID", `${at}.pattern is required and must not be empty`);
      }
      // required 必须显式声明，不默认填充（与 run_mode / idempotent 的必答口径一致）
      if (typeof it.required !== "boolean") {
        err("INPUT_INVALID", `${at}.required=${JSON.stringify(it.required)} (expected true/false)`);
      }
    });
  }

  if (declared === 0) {
    warn("INPUT_UNDECLARED", "no node declares inputs, so input files will not be verified before a run; declare them if the flow depends on input files");
  }
  return { errors, warnings };
}

/** 断言操作表：每个操作返回 { ok, detail } */
const OPS = {
  // 节点总数：用于锁住结构不再漂移
  nodeCount(flow, a) {
    return { ok: flow.nodes.length === a.equals, detail: `${flow.nodes.length} nodes (expected ${a.equals})` };
  },
  // 通用字段断言：不带 id 查 flow 顶层，带 id 查节点；exists 判有无，equals 判值
  field(flow, a) {
    const target = a.id ? flow.nodes.find((x) => x.id === a.id) : flow;
    if (!target) return { ok: false, detail: `node ${a.id} not found` };
    const v = target[a.name];
    let ok;
    if (Object.prototype.hasOwnProperty.call(a, "exists")) {
      ok = a.exists ? v !== undefined : v === undefined;
    } else if (Object.prototype.hasOwnProperty.call(a, "equals")) {
      ok = JSON.stringify(v) === JSON.stringify(a.equals);
    } else {
      ok = v !== undefined;
    }
    return { ok, detail: `${a.id ? a.id + "." : ""}${a.name}=${JSON.stringify(v)}` };
  },
  // 循环：fromto 校验上下界，foreach 校验遍历变量
  loop(flow, a) {
    const n = flow.nodes.find((x) => (a.id ? x.id === a.id : x.pad_hint === "LOOP"));
    if (!n) return { ok: false, detail: "loop node not found" };
    const lp = n.loop || {};
    if (a.kind === "foreach") {
      return { ok: lp.kind === "foreach" && (!a.item || lp.item === a.item), detail: `FOREACH ${lp.item}` };
    }
    const ok = lp.from === a.from && lp.to === a.to && (lp.step || 1) === (a.step || 1);
    return { ok, detail: `LOOP ${lp.index} ${lp.from}->${lp.to} step ${lp.step || 1}` };
  },
  condition(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const c = (n.params && n.params.Condition) || "";
    return { ok: c.includes(a.contains), detail: `condition=${c}` };
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
    return { ok: hit.length === 0, detail: hit.length ? `matched ${hit.map((n) => n.id).join(",")}` : "not present" };
  },
  param(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const v = (n.params || {})[a.name];
    return { ok: JSON.stringify(v) === JSON.stringify(a.equals), detail: `${a.name}=${JSON.stringify(v)}` };
  },
  // 输出绑定（output_map）中某个字段绑到了哪个变量
  outputMapEquals(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const v = (n.output_map || {})[a.name];
    return { ok: v === a.equals, detail: `${a.name}=${v}` };
  },
  outputsUnique(flow, a) {
    const nodes = flow.nodes.filter((n) => n.pad_hint === a.padHint);
    const names = nodes.map((n) => ((n.output_map || {}).ButtonPressed) || null);
    const missing = names.filter((x) => !x);
    const uniq = new Set(names);
    const ok = missing.length === 0 && uniq.size === names.length;
    return { ok, detail: `${names.length} nodes, ${uniq.size} distinct variables` };
  },
  guardContains(flow, a) {
    const g = flow.nodes.find((x) => x.id === a.id && x.pad_hint === "GUARD");
    if (!g) return { ok: false, detail: `guard ${a.id} not found` };
    const body = new Set(g.body || []);
    const missing = a.nodes.filter((x) => !body.has(x));
    return { ok: missing.length === 0, detail: missing.length ? `missing ${missing.join(",")}` : `body=[${g.body.join(",")}]` };
  },
  switchCases(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n || !n.switch) return { ok: false, detail: `node ${a.id} is not a SWITCH` };
    const got = (n.switch.cases || []).map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const want = a.cases.map((c) => `${c.case} ${(c.body || []).join(",")}`);
    const ok = JSON.stringify(got) === JSON.stringify(want) && (n.switch.default || []).length > 0;
    return { ok, detail: got.join(" | ") };
  },
  // 节点级必答项：运行方式（auto / confirm / observe）、幂等性与可逆性（布尔）
  // 设计规则要求「用户没回答就不生成 flow.json」，所以缺字段一律判失败，不做默认填充
  nodeDeclaration(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `node ${a.id} not found` };
    const problems = [];
    if (!RUN_MODES.includes(n.run_mode)) {
      problems.push(`run_mode=${JSON.stringify(n.run_mode)} (expected ${RUN_MODES.join("/")})`);
    }
    if (typeof n.idempotent !== "boolean") {
      problems.push(`idempotent=${JSON.stringify(n.idempotent)} (expected true/false)`);
    } else if (n.idempotent === false && !String(n.idempotency_note || "").trim()) {
      problems.push("idempotent=false requires idempotency_note (an idempotency key or a check-before-write scheme)");
    }
    problems.push(...reversibleProblems(n));
    if (a.runMode && n.run_mode !== a.runMode) problems.push(`run_mode expected ${a.runMode}, got ${n.run_mode}`);
    if (typeof a.idempotent === "boolean" && n.idempotent !== a.idempotent) {
      problems.push(`idempotent expected ${a.idempotent}, got ${n.idempotent}`);
    }
    return { ok: problems.length === 0, detail: problems.length ? problems.join("; ") : `run_mode=${n.run_mode} idempotent=${n.idempotent}` };
  },
  // 全流程必答项完整性：每个节点都必须显式声明三项（run_mode / idempotent / reversible），缺一个即失败
  // reversible 为 false 时还必须有 reversibility_note；已知不可逆动作写 true 属于事实错误，也判失败
  declarationsComplete(flow) {
    const missing = [];
    for (const n of flow.nodes) {
      const problems = [];
      if (!RUN_MODES.includes(n.run_mode)) {
        problems.push(`run_mode=${JSON.stringify(n.run_mode)} (expected ${RUN_MODES.join("/")})`);
      }
      if (typeof n.idempotent !== "boolean") {
        problems.push(`idempotent=${JSON.stringify(n.idempotent)} (expected true/false)`);
      } else if (n.idempotent === false && !String(n.idempotency_note || "").trim()) {
        problems.push("idempotent=false requires idempotency_note (an idempotency key or a check-before-write scheme)");
      }
      problems.push(...reversibleProblems(n));
      if (problems.length) missing.push(`node ${n.id}: ${problems.join("; ")}`);
    }
    return {
      ok: missing.length === 0,
      detail: missing.length ? `${missing.length} node(s) missing declarations: ${missing.slice(0, 12).join(" | ")}${missing.length > 12 ? "..." : ""}` : `all ${flow.nodes.length} nodes are declared`,
    };
  },
  // 触发声明断言：a.def 给了就验该对象（只验声明形状），否则验流程自身的 trigger。
  // a.expect=invalid 时断言“确实不合法且命中 a.code”，避免把反例写成正例。
  trigger(flow, a) {
    const inline = hasOwn(a, "def");
    const trg = inline ? a.def : flow.trigger;
    const { errors, warnings } = validateTrigger(flow, trg, { skipCrossCheck: inline });
    const codes = [...errors, ...warnings].map((x) => x.code);
    if (a.expect === "invalid") {
      const hit = codes.includes(a.code);
      return { ok: hit, detail: `expected ${a.code}, got ${codes.length ? codes.join(",") : "no errors"}` };
    }
    return {
      ok: errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ") : `trigger=${trg.kind} is valid`,
    };
  },
  // 触发已声明：只看流程自身的 trigger，不接受 def 覆盖
  triggerComplete(flow) {
    const trg = flow.trigger;
    const { errors } = validateTrigger(flow, trg);
    const kindOk = isPlainObject(trg) && TRIGGER_KINDS.includes(trg.kind);
    return {
      ok: kindOk && errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ") : `trigger=${trg.kind} is declared`,
    };
  },
  // 输入文件声明断言：
  //   a.def 给了就验该数组（只验声明形状，挂到合成节点 inline）
  //   a.node 给了就只验该节点，默认验全流程
  //   a.expect=invalid 断言“确实不合法且命中 a.code”；a.expect=warning 断言命中某条提示码
  inputs(flow, a) {
    let target = flow;
    let opts = {};
    if (hasOwn(a, "def")) {
      target = { nodes: [{ id: "inline", inputs: a.def }] };
    } else if (a.node) {
      const nodes = Array.isArray(flow && flow.nodes) ? flow.nodes : [];
      if (!nodes.some((n) => n && n.id === a.node)) {
        return { ok: false, detail: `node ${a.node} not found` };
      }
      opts = { node: a.node };
    }
    const { errors, warnings } = validateInputs(target, opts);
    const codes = [...errors, ...warnings].map((x) => x.code);
    if (a.expect === "invalid") {
      return {
        ok: codes.includes(a.code),
        detail: `expected ${a.code}, got ${codes.length ? codes.join(",") : "no problems"}`,
      };
    }
    if (a.expect === "warning") {
      return {
        ok: warnings.some((x) => x.code === a.code),
        detail: `expected notice ${a.code}, got ${warnings.length ? warnings.map((x) => x.code).join(",") : "no notices"}`,
      };
    }
    // 未声明的提示不算失败：老 flow.json 不写 inputs 时 op 仍然通过
    return {
      ok: errors.length === 0,
      detail: errors.length
        ? errors.map((x) => `${x.code}: ${x.detail}`).join("; ")
        : `inputs declarations are well-formed${warnings.length ? ` (${warnings.map((x) => x.code).join(",")})` : ""}`,
    };
  },
};

function runCase(flow, c) {
  const results = [];
  for (const a of c.expect || []) {
    const fn = OPS[a.op];
    if (!fn) {
      results.push({ ok: false, detail: `unknown assertion ${a.op}` });
      continue;
    }
    try {
      results.push(fn(flow, a));
    } catch (e) {
      results.push({ ok: false, detail: `assertion threw: ${e.message}` });
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
    console.error("Usage: node eval-flow.js <cases.json | directory> [--json]");
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
    console.error(`[error] read failed: ${e.message}`);
    process.exit(2);
  }
  if (specs.length === 0) {
    console.error(`[error] no *.cases.json under ${target}`);
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
    // 允许单条用例用 flow 覆盖被测文件：用于「同一份断言集里放正例和反例」，
    // 例如反例需要一个 run_mode=confirm 的节点，而正例需要一个干净流程。
    // 每个用例文件的被测流程无条件先跑一次必答项完整性，不再依赖 cases 显式写 expect；
    // 单条用例用 flow 覆盖的反例（故意缺字段）不受此限，仍按它自己的断言判。
    const baseDecl = OPS.declarationsComplete(flow);
    const cases = [
      {
        id: "declarations-complete",
        requirement: "every node explicitly declares run_mode / idempotent / reversible",
        ok: baseDecl.ok,
        results: [baseDecl],
      },
      ...s.cases.map((c) => {
        if (!c.flow) return runCase(flow, c);
        try {
          const own = JSON.parse(fs.readFileSync(c.flow, "utf8"));
          return runCase(own, c);
        } catch (e) {
          return { id: c.id, requirement: c.requirement, ok: false, results: [{ ok: false, detail: `failed to read the case flow: ${e.message}` }] };
        }
      }),
    ];
    total += cases.length;
    passed += cases.filter((c) => c.ok).length;
    report.push({ flow: s.flowPath, cases });
  }

  if (asJson) {
    console.log(JSON.stringify({ total, passed, files: report }, null, 2));
  } else {
    for (const f of report) {
      if (f.error) {
        console.log(`FAIL  ${f.flow} (read failed: ${f.error})`);
        continue;
      }
      const okCount = f.cases.filter((c) => c.ok).length;
      console.log(`--- ${f.flow}  ${okCount}/${f.cases.length} ---`);
      for (const c of f.cases) {
        console.log(`${c.ok ? "PASS" : "FAIL"}  ${c.id}  requirement: ${c.requirement}`);
        for (const r of c.results.filter((x) => !x.ok)) console.log(`        assertion failed: ${r.detail}`);
      }
    }
    console.log(`[eval-flow] passed ${passed} / ${total} (${specs.length} flow samples)`);
  }
  process.exit(passed === total && report.every((f) => !f.error) ? 0 : 1);
}

module.exports = { runCase, OPS };
