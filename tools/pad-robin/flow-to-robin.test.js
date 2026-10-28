// flow-to-robin.test.js — 生成器单元测试（node --test）
//
// 覆盖 B2 的四类新能力：deployKey 占位符、guard 守卫、任意层嵌套、output_map 显式绑定。
// 用法：node --test tools/pad-robin/flow-to-robin.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const GEN = path.join(__dirname, "flow-to-robin.js");

// 最小知识库：只需要 actionId / module / 输入输出参数，够生成动作行
const KB = {
  actions: [
    { actionId: "Test.Log", module: "Test", input_params: [{ name: "Message", type: "String" }], output_params: [] },
    {
      actionId: "Test.Show", module: "Display",
      input_params: [{ name: "Message", type: "String" }, { name: "Title", type: "String" }],
      output_params: [{ name: "ButtonPressed", type: "String" }],
    },
  ],
};

/** 在临时目录里跑一次生成，返回退出码、stderr、产物全文 */
function run(flow) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "f2r-"));
  const flowPath = path.join(dir, "flow.json");
  const kbPath = path.join(dir, "kb.json");
  const outPath = path.join(dir, "out.robin");
  fs.writeFileSync(flowPath, JSON.stringify(flow, null, 2), "utf8");
  fs.writeFileSync(kbPath, JSON.stringify(KB), "utf8");
  const r = spawnSync(process.execPath, [GEN, flowPath, outPath, "--kb", kbPath, "--no-check"], { encoding: "utf8" });
  const out = fs.existsSync(outPath) ? fs.readFileSync(outPath, "utf8") : "";
  // 去掉文件末尾换行产生的空元素，保留中间的空行
  const lines = out.split(/\r?\n/);
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return { status: r.status, stderr: r.stderr || "", text: lines.join("\n") };
}

test("deployKey 输出双花括号占位符，派生路径里的 %Var% 不被转义", () => {
  const r = run({
    variables: [
      { name: "PadRoot", type: "string", deployKey: "PAD_ROOT" },
      { name: "WorkDir", type: "string", default: "%PadRoot%\\x" },
      { name: "Pct", type: "string", default: "100% 完成" },
    ],
    nodes: [],
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.text, [
    "SET PadRoot TO $'''{{PAD_ROOT}}'''",
    "SET WorkDir TO $'''%PadRoot%\\\\x'''",
    "SET Pct TO $'''100%% 完成'''",
  ].join("\n"));
});

test("guard 生成 IF/ELSE，body 内可继续嵌套 IF", () => {
  const r = run({
    variables: [{ name: "DryRun", type: "string", deployKey: "DRY_RUN" }],
    nodes: [
      { id: "g", type: "guard", pad_hint: "GUARD", when: "DryRun <> $'''1'''", body: ["a", "i"], elseBody: ["e"] },
      { id: "a", type: "action", pad_hint: "Test.Log", params: { Message: "body" } },
      {
        id: "i", type: "if", pad_hint: "IF", params: { Condition: "X > 1" },
        branch: { trueBody: ["t"], falseBody: ["f"] },
      },
      { id: "t", type: "action", pad_hint: "Test.Log", params: { Message: "t" } },
      { id: "f", type: "action", pad_hint: "Test.Log", params: { Message: "f" } },
      {
        id: "e", type: "action", pad_hint: "Test.Show",
        params: { Message: "skip", Title: "t" }, output_map: { ButtonPressed: "DryRunNoticeButton" },
      },
    ],
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.text, [
    "SET DryRun TO $'''{{DRY_RUN}}'''",
    "",
    "IF DryRun <> $'''1''' THEN",
    "Test.Log Message: $'''body'''",
    "IF X > 1 THEN",
    "Test.Log Message: $'''t'''",
    "ELSE",
    "Test.Log Message: $'''f'''",
    "END",
    "ELSE",
    "Test.Show Message: $'''skip''' Title: $'''t''' ButtonPressed=> DryRunNoticeButton",
    "END",
  ].join("\n"));
});

test("LOOP 体内嵌 guard 再嵌 IF，子节点只输出一次", () => {
  const r = run({
    nodes: [
      { id: "l", type: "loop", pad_hint: "LOOP", loop: { kind: "fromto", index: "I", from: 1, to: 3, step: 1, body: ["g"] } },
      { id: "g", type: "guard", pad_hint: "GUARD", when: "%I% > 1", body: ["i"], elseBody: ["e"] },
      { id: "i", type: "if", pad_hint: "IF", params: { Condition: "Done" }, branch: { trueBody: ["b"], falseBody: [] } },
      { id: "b", type: "break", pad_hint: "EXIT LOOP" },
      { id: "e", type: "action", pad_hint: "Test.Log", params: { Message: "skip" } },
    ],
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.text, [
    "LOOP I FROM 1 TO 3 STEP 1",
    "IF %I% > 1 THEN",
    "IF Done THEN",
    "EXIT LOOP",
    "END",
    "ELSE",
    "Test.Log Message: $'''skip'''",
    "END",
    "END",
  ].join("\n"));
});

test("output_map 显式绑定输出变量，条件里的 {{id.Field}} 解析成该变量", () => {
  const r = run({
    nodes: [
      { id: "1", type: "action", pad_hint: "Test.Show", params: { Message: "x" }, output_map: { ButtonPressed: "ConfirmButton" } },
      {
        id: "2", type: "if", pad_hint: "IF", params: { Condition: "{{1.ButtonPressed}} = $'''OK'''" },
        branch: { trueBody: ["3"], falseBody: [] },
      },
      { id: "3", type: "action", pad_hint: "Test.Log", params: { Message: "yes" } },
    ],
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.text, [
    "Test.Show Message: $'''x''' ButtonPressed=> ConfirmButton",
    "IF ConfirmButton = $'''OK''' THEN",
    "Test.Log Message: $'''yes'''",
    "END",
  ].join("\n"));
});

test("未知动作仍被安全闸门拒绝，且不产出文件", () => {
  const r = run({
    nodes: [{ id: "1", type: "action", pad_hint: "No.Such.Action", params: {} }],
  });
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /未知动作/);
  assert.strictEqual(r.text, "");
});
