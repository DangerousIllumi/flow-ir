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
// 与 pad-admit 第 14 项共用同一口径：保留值单列，便于给出“支持但未实现”而不是“拼错”的提示。
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
    return { errors: [{ code: "TRIGGER_MISSING", detail: "缺少 trigger 声明" }], warnings };
  }
  if (!isPlainObject(trg)) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: "trigger 必须是对象" }], warnings };
  }
  // 旧形状：只有 type/config 没有 kind，不做静默映射
  if (!hasOwn(trg, "kind") && hasOwn(trg, "type")) {
    return { errors: [{ code: "TRIGGER_LEGACY_SHAPE", detail: "只有 type/config 旧形状，缺 kind" }], warnings };
  }
  if (typeof trg.kind !== "string" || !trg.kind) {
    return { errors: [{ code: "TRIGGER_INVALID", detail: `kind=${JSON.stringify(trg.kind)}（必须是字符串）` }], warnings };
  }
  if (TRIGGER_RESERVED_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_KIND_UNSUPPORTED", detail: `kind=${trg.kind} 是保留值，v1 没有对应注册器` }], warnings };
  }
  if (!TRIGGER_KINDS.includes(trg.kind)) {
    return { errors: [{ code: "TRIGGER_UNKNOWN_KIND", detail: `kind=${trg.kind} 不在 ${TRIGGER_KINDS.join("/")}` }], warnings };
  }
  const kind = trg.kind;

  // 任务名：显式给出时必须是安全字符，否则计划任务名无法稳定复现
  if (hasOwn(trg, "task_name")) {
    const tn = trg.task_name;
    if (typeof tn !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(tn)) {
      err("TRIGGER_INVALID", `task_name=${JSON.stringify(tn)} 不匹配 ^[A-Za-z0-9._-]{1,64}$`);
    }
  }

  if (kind === "manual") {
    for (const key of ["time", "days", "gate", "timeout_sec", "file"]) {
      if (hasOwn(trg, key)) err("TRIGGER_INVALID", `manual 不允许声明 ${key}（声明了也没人执行）`);
    }
    return { errors, warnings };
  }

  // schedule / file 共用：时刻、星期、日历门、超时
  const time = hasOwn(trg, "time") ? trg.time : undefined;
  if (typeof time !== "string" || !TRIGGER_TIME_RE.test(time)) {
    err("TRIGGER_INVALID", `time=${JSON.stringify(time)}（应为 HH:mm，如 09:00）`);
  }
  if (hasOwn(trg, "days")) {
    if (!Array.isArray(trg.days) || trg.days.length === 0) {
      err("TRIGGER_INVALID", `days=${JSON.stringify(trg.days)}（应是非空数组）`);
    } else if (trg.days.some((d) => !TRIGGER_DAYS.includes(d))) {
      err("TRIGGER_INVALID", `days 含非法值：${JSON.stringify(trg.days.filter((d) => !TRIGGER_DAYS.includes(d)))}`);
    }
  }
  if (hasOwn(trg, "gate")) {
    if (!TRIGGER_GATES.includes(trg.gate)) {
      err("TRIGGER_INVALID", `gate=${JSON.stringify(trg.gate)} 不在 ${TRIGGER_GATES.join("/")}`);
    }
  } else if (kind === "schedule") {
    warn("TRIGGER_NO_GATE", "schedule 未声明 gate，节假日会照跑（如不需要请显式写 gate=none）");
  }
  if (hasOwn(trg, "timeout_sec") && !isPositiveInt(trg.timeout_sec)) {
    err("TRIGGER_INVALID", `timeout_sec=${JSON.stringify(trg.timeout_sec)}（应为正整数秒）`);
  }

  if (kind === "file") {
    if (!hasOwn(trg, "file") || !isPlainObject(trg.file)) {
      err("TRIGGER_INVALID", "file 触发必须带 file 对象");
    } else {
      const f = trg.file;
      const dir = hasOwn(f, "dir") ? f.dir : undefined;
      if (typeof dir !== "string" || !dir) {
        err("TRIGGER_INVALID", "file.dir 必填");
      } else if (!/^\{\{config\.\w+\}\}$/.test(dir)) {
        // 只接受配置引用，禁止把绝对路径写进 flow.json
        err("TRIGGER_PATH_LITERAL", `file.dir=${dir} 必须是 {{config.<KEY>}} 引用，不能是字面路径`);
      }
      if (typeof f.pattern !== "string" || !f.pattern.trim()) {
        err("TRIGGER_INVALID", "file.pattern 必填且不能为空");
      }
      for (const key of ["poll_sec", "settle_sec", "max_wait_sec"]) {
        if (hasOwn(f, key) && !isPositiveInt(f[key])) {
          err("TRIGGER_INVALID", `file.${key}=${JSON.stringify(f[key])}（应为正整数秒）`);
        }
      }
      if (hasOwn(f, "once_per_file") && typeof f.once_per_file !== "boolean") {
        err("TRIGGER_INVALID", `file.once_per_file=${JSON.stringify(f.once_per_file)}（应为 true/false）`);
      }
    }
  }

  // 与节点声明的交叉校验：只对“真实流程”生效；断言里传入的 def 只验声明形状，不拿流程节点做陪衬
  if (!opts.skipCrossCheck) {
    const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];
    const confirmNodes = nodes.filter((n) => n && n.run_mode === "confirm");
    if (confirmNodes.length > 0) {
      err("TRIGGER_UNATTENDED_CONFIRM", `无人值守触发但节点需要人工确认：${confirmNodes.map((n) => n.id).join(",")}`);
    }
    const nonIdem = nodes.filter((n) => n && n.idempotent === false);
    if (nonIdem.length > 0) {
      warn("TRIGGER_UNATTENDED_NONIDEMPOTENT", `无人值守触发但节点重跑不安全：${nonIdem.map((n) => n.id).join(",")}`);
    }
  }

  return { errors, warnings };
}

/** 断言操作表：每个操作返回 { ok, detail } */
const OPS = {
  // 节点总数：用于锁住结构不再漂移
  nodeCount(flow, a) {
    return { ok: flow.nodes.length === a.equals, detail: `${flow.nodes.length} 个节点（期望 ${a.equals}）` };
  },
  // 通用字段断言：不带 id 查 flow 顶层，带 id 查节点；exists 判有无，equals 判值
  field(flow, a) {
    const target = a.id ? flow.nodes.find((x) => x.id === a.id) : flow;
    if (!target) return { ok: false, detail: `节点 ${a.id} 不存在` };
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
  // 输出绑定（output_map）中某个字段绑到了哪个变量
  outputMapEquals(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const v = (n.output_map || {})[a.name];
    return { ok: v === a.equals, detail: `${a.name}=${v}` };
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
  // 节点级必答项：运行方式（auto / confirm / observe）与幂等性（布尔）
  // 设计规则要求「用户没回答就不生成 flow.json」，所以缺字段一律判失败，不做默认填充
  nodeDeclaration(flow, a) {
    const n = flow.nodes.find((x) => x.id === a.id);
    if (!n) return { ok: false, detail: `节点 ${a.id} 不存在` };
    const problems = [];
    if (!RUN_MODES.includes(n.run_mode)) {
      problems.push(`run_mode=${JSON.stringify(n.run_mode)}（应为 ${RUN_MODES.join("/")}）`);
    }
    if (typeof n.idempotent !== "boolean") {
      problems.push(`idempotent=${JSON.stringify(n.idempotent)}（应为 true/false）`);
    } else if (n.idempotent === false && !String(n.idempotency_note || "").trim()) {
      problems.push("idempotent=false 时必须写 idempotency_note（幂等键或先查后写方案）");
    }
    if (a.runMode && n.run_mode !== a.runMode) problems.push(`run_mode 期望 ${a.runMode}，实际 ${n.run_mode}`);
    if (typeof a.idempotent === "boolean" && n.idempotent !== a.idempotent) {
      problems.push(`idempotent 期望 ${a.idempotent}，实际 ${n.idempotent}`);
    }
    return { ok: problems.length === 0, detail: problems.length ? problems.join("；") : `run_mode=${n.run_mode} idempotent=${n.idempotent}` };
  },
  // 全流程必答项完整性：每个节点都必须显式声明两项，缺一个即失败
  declarationsComplete(flow) {
    const missing = flow.nodes.filter((n) => {
      const modeOk = RUN_MODES.includes(n.run_mode);
      const idemOk = typeof n.idempotent === "boolean"
        && (n.idempotent === true || String(n.idempotency_note || "").trim());
      return !modeOk || !idemOk;
    });
    const ids = missing.map((n) => n.id);
    return {
      ok: missing.length === 0,
      detail: missing.length ? `缺声明节点 ${missing.length} 个：${ids.slice(0, 12).join(",")}${ids.length > 12 ? "…" : ""}` : `${flow.nodes.length} 个节点均已声明`,
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
      return { ok: hit, detail: `期望 ${a.code}，实际 ${codes.length ? codes.join(",") : "无错误"}` };
    }
    return {
      ok: errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("；") : `trigger=${trg.kind} 合法`,
    };
  },
  // 触发已声明：只看流程自身的 trigger，不接受 def 覆盖
  triggerComplete(flow) {
    const trg = flow.trigger;
    const { errors } = validateTrigger(flow, trg);
    const kindOk = isPlainObject(trg) && TRIGGER_KINDS.includes(trg.kind);
    return {
      ok: kindOk && errors.length === 0,
      detail: errors.length ? errors.map((x) => `${x.code}: ${x.detail}`).join("；") : `trigger=${trg.kind} 已声明`,
    };
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
    // 允许单条用例用 flow 覆盖被测文件：用于「同一份断言集里放正例和反例」，
    // 例如反例需要一个 run_mode=confirm 的节点，而正例需要一个干净流程。
    const cases = s.cases.map((c) => {
      if (!c.flow) return runCase(flow, c);
      try {
        const own = JSON.parse(fs.readFileSync(c.flow, "utf8"));
        return runCase(own, c);
      } catch (e) {
        return { id: c.id, requirement: c.requirement, ok: false, results: [{ ok: false, detail: `读取用例流程失败：${e.message}` }] };
      }
    });
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
