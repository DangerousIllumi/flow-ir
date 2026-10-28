// compare-robin.test.js — 「生成 vs 生产」对比器测试（node --test）
// 用法：node --test tools/pad-robin/compare-robin.test.js
const test = require("node:test");
const assert = require("node:assert");
const { compareRobin, normalizeRobin, classify } = require("./compare-robin.js");

test("规范化忽略注释、空行与行尾空白", () => {
  const a = "# 注释\nSET A TO $'''x'''   \n\nSET B TO $'''y'''\n";
  assert.strictEqual(normalizeRobin(a), "SET A TO $'''x'''\nSET B TO $'''y'''");
});

test("只差注释与空行时判定一致", () => {
  const gen = "SET A TO $'''x'''\nTest.Log Message: $'''m'''";
  const prod = "# 部署参数\nSET A TO $'''x'''\n\nTest.Log Message: $'''m'''\n";
  const r = compareRobin(gen, prod);
  assert.strictEqual(r.ok, true);
  assert.deepStrictEqual(r.diffs, []);
});

test("不一致时给出首个差异行号与分类", () => {
  const gen = "SET A TO $'''x'''\nLOOP I FROM 1 TO 10 STEP 1";
  const prod = "SET A TO $'''x'''\nLOOP I FROM 1 TO 7 STEP 1";
  const r = compareRobin(gen, prod);
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.diffs[0].index, 2);
  assert.strictEqual(r.diffs[0].kind, "控制流");
});

test("占位符缺失单独归类", () => {
  assert.strictEqual(classify("SET PadRoot TO $'''{{PAD_ROOT}}'''", "SET PadRoot TO $'''C:\\\\PAD'''"), "占位符");
});

test("一侧行数不足时记为缺失", () => {
  const r = compareRobin("SET A TO $'''x'''", "SET A TO $'''x'''\nTest.Log Message: $'''m'''");
  assert.strictEqual(r.ok, false);
  assert.strictEqual(r.diffs[0].kind, "行数不一致");
});
