// lint-robin.test.js — 流程卫生规则的单元测试（node --test）
//
// 覆盖：未读输出、未用声明、IF 嵌套阈值，以及两条回归基线：
//   - 生产脚本必须保持 0 条流程卫生警告
//   - 仓库自带的示例流程不能误报嵌套过深

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const os = require("os");
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
  assert.match(w[0].message, /nested 4 levels/);
});

test("LOOP 里的 IF 不算 IF 嵌套", () => {
  const text = ["LOOP Idx FROM 1 TO 7 STEP 1", "IF A = 1 THEN", "END", "END"].join("\n");
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});

test("回归：生产脚本生成后 0 条流程卫生警告", (t) => {
  // 公开仓库不含业务脚本；改用仓库示例流程生成脚本，避免依赖 business/ 下的产物
  // 知识库由 setup.ps1 克隆，缺失时明确跳过并给出原因
  const kb = path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json");
  if (!fs.existsSync(kb)) {
    t.skip("未找到动作知识库（先执行 setup.ps1），跳过生产脚本回归");
    return;
  }
  const flow = path.join(__dirname, "..", "flow-drawio", "example-flow.json");
  const gen = path.join(__dirname, "flow-to-robin.js");
  const out = path.join(os.tmpdir(), `lint-prod-${process.pid}.robin`);
  execFileSync(process.execPath, [gen, flow, out], { stdio: "pipe" });
  const text = fs.readFileSync(out, "utf8");
  fs.unlinkSync(out);
  assert.strictEqual(rulesOf(text, "unused-output").length, 0);
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});
