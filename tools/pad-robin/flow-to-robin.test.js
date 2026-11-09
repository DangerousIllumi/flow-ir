// flow-to-robin.test.js — unit tests for the generator (node --test)
//
// Covers four new capabilities from B2: deployKey placeholders, guard nodes, arbitrary-depth nesting and
// explicit output_map binding, plus output_skip (outputs that are not needed are not bound to a variable).
// Usage: node --test tools/pad-robin/flow-to-robin.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const GEN = path.join(__dirname, "flow-to-robin.js");

// Minimal knowledge base: only actionId / module / input and output params are needed to emit action lines
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

/** Run one generation in a temporary directory and return the exit code, stderr and full output */
function run(flow) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "f2r-"));
  const flowPath = path.join(dir, "flow.json");
  const kbPath = path.join(dir, "kb.json");
  const outPath = path.join(dir, "out.robin");
  fs.writeFileSync(flowPath, JSON.stringify(flow, null, 2), "utf8");
  fs.writeFileSync(kbPath, JSON.stringify(KB), "utf8");
  const r = spawnSync(process.execPath, [GEN, flowPath, outPath, "--kb", kbPath, "--no-check"], { encoding: "utf8" });
  const out = fs.existsSync(outPath) ? fs.readFileSync(outPath, "utf8") : "";
  // Drop the empty element produced by the trailing newline; keep blank lines in the middle
  const lines = out.split(/\r?\n/);
  while (lines.length && lines[lines.length - 1] === "") lines.pop();
  return { status: r.status, stderr: r.stderr || "", text: lines.join("\n") };
}

test("deployKey emits double-brace placeholders and leaves %Var% in derived paths unescaped", () => {
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

test("guard generates IF/ELSE and its body can nest another IF", () => {
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

test("a LOOP body nests a guard that nests an IF, and child nodes are emitted only once", () => {
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

test("output_map binds output variables explicitly, and {{id.Field}} in a condition resolves to that variable", () => {
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

test("outputs declared in output_skip are not bound to variables (same as leaving the output blank in PAD)", () => {
  const r = run({
    nodes: [
      { id: "1", type: "action", pad_hint: "Test.Show", params: { Message: "x" }, output_skip: ["ButtonPressed"] },
    ],
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.strictEqual(r.text, "Test.Show Message: $'''x'''");
});

test("an unknown action is still rejected by the safety gate and no file is produced", () => {
  const r = run({
    nodes: [{ id: "1", type: "action", pad_hint: "No.Such.Action", params: {} }],
  });
  assert.strictEqual(r.status, 1);
  assert.match(r.stderr, /unknown action/);
  assert.strictEqual(r.text, "");
});
