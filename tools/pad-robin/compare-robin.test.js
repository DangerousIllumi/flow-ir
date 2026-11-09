// compare-robin.test.js — tests for the "generated vs production" comparer (node --test)
// Usage: node --test tools/pad-robin/compare-robin.test.js
const test = require("node:test");
const assert = require("node:assert");
const { compareRobin, normalizeRobin, classify } = require("./compare-robin.js");

test("normalization ignores comments, blank lines and trailing whitespace", () => {
  const a = "# 注释\nSET A TO $'''x'''   \n\nSET B TO $'''y'''\n";
  assert.strictEqual(normalizeRobin(a), "SET A TO $'''x'''\nSET B TO $'''y'''");
});

test("scripts that differ only in comments and blank lines are reported as identical", () => {
  const gen = "SET A TO $'''x'''\nTest.Log Message: $'''m'''";
  const prod = "# 部署参数\nSET A TO $'''x'''\n\nTest.Log Message: $'''m'''\n";
  const r = compareRobin(gen, prod);
  assert.strictEqual(r.ok, true);
  assert.deepStrictEqual(r.diffs, []);
});

test("on a mismatch it reports the first differing line number and its category", () => {
  const gen = "SET A TO $'''x'''\nLOOP I FROM 1 TO 10 STEP 1";
  const prod = "SET A TO $'''x'''\nLOOP I FROM 1 TO 7 STEP 1";
  const r = compareRobin(gen, prod);
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.diffs[0].index, 2);
  assert.strictEqual(r.diffs[0].kind, "control-flow");
});

test("a missing placeholder is classified on its own", () => {
  assert.strictEqual(classify("SET PadRoot TO $'''{{PAD_ROOT}}'''", "SET PadRoot TO $'''C:\\\\PAD'''"), "placeholder");
});

test("a side with too few lines is recorded as missing lines", () => {
  const r = compareRobin("SET A TO $'''x'''", "SET A TO $'''x'''\nTest.Log Message: $'''m'''");
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.diffs[0].kind, "line-count-mismatch");
});
