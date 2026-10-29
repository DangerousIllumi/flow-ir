// lint-robin.test.js — 流程卫生规则的单元测试（node --test）
//
// 覆盖：未读输出、未用声明、IF 嵌套阈值，以及两条回归基线：
//   - 生产脚本的告警数量必须与 PAD 设计器流检查器一致（30 / 6）
//   - 仓库自带的示例流程不能误报嵌套过深

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { lintRobin } = require("./lint-robin.js");

const rulesOf = (text, rule) => lintRobin(text).warnings.filter((w) => w.rule === rule);

test("捕获了输出但从未读取 → unused-output", () => {
  const text = [
    "Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd''' ExitCode=> Code",
    "IF 1 = 1 THEN",
    "END",
  ].join("\n");
  const w = rulesOf(text, "unused-output");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /Code/);
});

test("输出被 %变量% 引用时不报", () => {
  const text = [
    "Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd''' ExitCode=> Code",
    "Display.ShowMessageDialog.ShowMessage Message: $'''退出码 %Code%'''",
  ].join("\n");
  assert.strictEqual(rulesOf(text, "unused-output").length, 0);
});

test("输出被 变量.属性 引用时不报", () => {
  const text = [
    "Outlook.RetrieveEmailMessages.RetrieveEmails Messages=> Mails",
    "IF Mails.Count > 0 THEN",
    "END",
  ].join("\n");
  assert.strictEqual(rulesOf(text, "unused-output").length, 0);
});

test("SET 声明后从未引用 → unused-var", () => {
  const text = ["SET Unused TO $'''x'''", "SET Used TO $'''y'''", "Display.ShowMessageDialog.ShowMessage Message: $'''%Used%'''"].join("\n");
  const w = rulesOf(text, "unused-var");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /Unused/);
});

test("SET 被引用时不报", () => {
  const text = ["SET Dir TO $'''C:\\x'''", "File.ReadTextFromFile.ReadText File: $'''%Dir%\\a.txt'''"].join("\n");
  assert.strictEqual(rulesOf(text, "unused-var").length, 0);
});

test("IF 嵌套 3 层未超阈值，不报", () => {
  const text = ["IF A = 1 THEN", "IF B = 1 THEN", "IF C = 1 THEN", "END", "END", "END"].join("\n");
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});

test("IF 嵌套 4 层超过阈值，报 1 条", () => {
  const text = ["IF A = 1 THEN", "IF B = 1 THEN", "IF C = 1 THEN", "IF D = 1 THEN", "END", "END", "END", "END"].join("\n");
  const w = rulesOf(text, "nested-if");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /4 层/);
});

test("LOOP 里的 IF 不算 IF 嵌套", () => {
  const text = ["LOOP Idx FROM 1 TO 7 STEP 1", "IF A = 1 THEN", "END", "END"].join("\n");
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});

test("回归：生产脚本的告警数量与设计器流检查器一致（30 / 6）", () => {
  const p = path.join(__dirname, "..", "..", "flows", "basf-sample-report.robin");
  if (!fs.existsSync(p)) {
    // 公开仓库不含业务脚本，跳过
    return;
  }
  const text = fs.readFileSync(p, "utf8");
  assert.strictEqual(rulesOf(text, "unused-output").length, 30);
  assert.strictEqual(rulesOf(text, "nested-if").length, 6);
});

test("示例流程生成后不误报嵌套过深", () => {
  // 公开仓库不含知识库（由 setup.ps1 克隆），缺失时跳过，避免测试硬依赖
  const kb = path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json");
  if (!fs.existsSync(kb)) return;
  const flow = path.join(__dirname, "..", "flow-drawio", "example-flow.json");
  const gen = path.join(__dirname, "flow-to-robin.js");
  const out = path.join(require("os").tmpdir(), `lint-example-${process.pid}.robin`);
  execFileSync(process.execPath, [gen, flow, out], { stdio: "pipe" });
  const text = fs.readFileSync(out, "utf8");
  fs.unlinkSync(out);
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});
