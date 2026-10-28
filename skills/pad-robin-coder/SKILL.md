# pad-robin-coder（Agent B：代码生成器）

## When To Use
当需要把 `flow.json` 翻译成可粘贴到 Power Automate Desktop 的 Robin 脚本时。
典型触发："生成 PAD 代码"、"翻译成 Robin"、"/generate"、"读取 flow.json 生成代码"。

## 核心原则
你是**模板填空器**，不是代码生成器。
- 动作骨架直接取 KB `golden_example`，绝不改写
- 只换参数值，不增删参数、不改参数顺序
- 查表填空由确定性工具 `flow-to-robin.js` 完成，你不手抄

## 前置参考
- `pad-robin-action-kb/PAD_Robin_ActionKB.json` — 动作库
- `pad-robin-action-kb/PAD_Robin_TypeReference.json` — 44 种类型写法
- `pad-robin-action-kb/PROMPT.md` — 红线清单（出错时对照）

## 工作流程

### 1. 跑生成器（一步到位）
```bash
node tools/pad-robin/flow-to-robin.js flows/<name>.json output.txt
```
生成器会：查 KB → 取 golden_example → 按类型填值 → 解析引用 → 生成 IF/ELSE → 自动跑 check-flows.js 自检。

### 2. 处理生成器输出
- **生成期错误**（unknown action / 未知参数 / 需 UI 选择器 / 悬空引用 / 缺句柄）→ 这是 flow.json 的缺陷，让 Agent A 修正后重跑，**不要手工绕过**
- **警告**（沿用 KB 占位值 / 变量无默认值）→ 如实转达用户，指出需在 PAD 里补什么

### 3. 自检不通过时
按报错行号和 PROMPT.md 红线修正**生成器的输入**（flow.json），而不是改产物。

### 4. 输出
- 写 `output.txt`（纯 Robin，无 markdown、无解释）
- 对话里给预览 + 注意事项
- 提示用户："记事本打开 output.txt → 全选复制 → PAD 画布 Ctrl+V"

## 常用命令
```bash
# 生成 + 自检
node tools/pad-robin/flow-to-robin.js flows/<name>.json output.txt

# 单独跑静态校验
node tools/pad-robin/check.js output.txt

# 跳过自检
node tools/pad-robin/flow-to-robin.js flows/<name>.json output.txt --no-check
```

## 红线（违反即粘贴失败）
- ❌ 不生成 `@@` 文件头、`FUNCTION...END`、`IMPORT`
- ❌ `%Var%` 只能在字符串 `$'''…'''` 内部，字符串外必须裸写
- ❌ 不用 `WHEN...END`，用 `LOOP WHILE (...) ... END`
- ❌ 不凭记忆写动作名，以 KB 为准
- ❌ 不手工增删参数

## 类型格式化速查
| 类型 | 写法 |
|---|---|
| String/File/Folder | `$'''值'''` |
| Boolean | `True` / `False` |
| Number | 裸写 `42` |
| Enum | `Module.EnumType.Value` |
| 变量/表达式 | 裸写 `ExcelInstance` |
| 字符串内引用 | `$'''发票-%Month%'''` |
| UNC 路径 | `$'''\\\\server\share'''` |
| 字面百分号 | `%%` |
