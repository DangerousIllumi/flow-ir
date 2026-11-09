// lint-robin.test.js — unit tests for the flow hygiene rules (node --test)
//
// Covers: unread outputs, unused declarations, the IF nesting threshold, plus two regression baselines:
//   - production scripts must stay at 0 flow hygiene warnings
//   - the repository's own example flow must not be falsely flagged for nesting too deeply

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");
const { lintRobin } = require("./lint-robin.js");

const rulesOf = (text, rule) => lintRobin(text).warnings.filter((w) => w.rule === rule);

test("a captured but never-read output → unused-output", () => {
  const text = [
    "Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd''' ExitCode=> Code",
    "IF 1 = 1 THEN",
    "END",
  ].join("\n");
  const w = rulesOf(text, "unused-output");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /Code/);
});

test("no warning when the output is referenced as %variable%", () => {
  const text = [
    "Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''cmd''' ExitCode=> Code",
    "Display.ShowMessageDialog.ShowMessage Message: $'''退出码 %Code%'''",
  ].join("\n");
  assert.strictEqual(rulesOf(text, "unused-output").length, 0);
});

test("no warning when the output is referenced as variable.property", () => {
  const text = [
    "Outlook.RetrieveEmailMessages.RetrieveEmails Messages=> Mails",
    "IF Mails.Count > 0 THEN",
    "END",
  ].join("\n");
  assert.strictEqual(rulesOf(text, "unused-output").length, 0);
});

test("a SET declaration that is never referenced → unused-var", () => {
  const text = ["SET Unused TO $'''x'''", "SET Used TO $'''y'''", "Display.ShowMessageDialog.ShowMessage Message: $'''%Used%'''"].join("\n");
  const w = rulesOf(text, "unused-var");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /Unused/);
});

test("no warning when the SET variable is referenced", () => {
  const text = ["SET Dir TO $'''C:\\x'''", "File.ReadTextFromFile.ReadText File: $'''%Dir%\\a.txt'''"].join("\n");
  assert.strictEqual(rulesOf(text, "unused-var").length, 0);
});

test("IF nested 3 levels stays within the threshold and is not reported", () => {
  const text = ["IF A = 1 THEN", "IF B = 1 THEN", "IF C = 1 THEN", "END", "END", "END"].join("\n");
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});

test("IF nested 4 levels exceeds the threshold and reports 1 warning", () => {
  const text = ["IF A = 1 THEN", "IF B = 1 THEN", "IF C = 1 THEN", "IF D = 1 THEN", "END", "END", "END", "END"].join("\n");
  const w = rulesOf(text, "nested-if");
  assert.strictEqual(w.length, 1);
  assert.match(w[0].message, /nested 4 levels/);
});

test("an IF inside a LOOP does not count as IF nesting", () => {
  const text = ["LOOP Idx FROM 1 TO 7 STEP 1", "IF A = 1 THEN", "END", "END"].join("\n");
  assert.strictEqual(rulesOf(text, "nested-if").length, 0);
});

test("regression: a generated production script has 0 flow hygiene warnings", (t) => {
  // The public repository ships no business scripts, so generate from the repository's example flow instead of
  // depending on artifacts under business/. The knowledge base is cloned by setup.ps1; skip with a reason if absent.
  const kb = path.join(__dirname, "..", "..", "pad-robin-action-kb", "PAD_Robin_ActionKB.json");
  if (!fs.existsSync(kb)) {
    t.skip("action knowledge base not found (run setup.ps1 first); skipping the production-script regression");
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
