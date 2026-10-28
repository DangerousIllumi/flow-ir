# AGENTS.md — 给 AI 助手的入口说明

> 你（AI 助手）正在一个 **PAD 工作流工具链** 仓库里。用户会用自然语言描述一个流程，
> 你要把它变成可粘贴进 Power Automate Desktop 的 Robin 脚本。
> 这份文件是你的操作手册：**先读完再动手**。

## 0. 先做一次环境准备

```powershell
.\setup.ps1          # 安装 Node 依赖 + 克隆动作知识库 pad-robin-action-kb/
.\scripts\check-env.ps1
```

- 知识库是**必需**的：生成器靠它精确查表，查不到会拒绝产出。
- `.ps1` / `.psm1` 必须保持 **UTF-8 with BOM**（PowerShell 5.1 对无 BOM 的中文会解析错乱）。
- 仓库里没有 `flows/` 目录时，自己创建。

## 1. 仓库地图

| 路径 | 作用 |
|---|---|
| `tools/flow-drawio/` | `flow.json → .drawio` 画布、`check-flow.js` 边一致性、`example-flow.json` 可跑示例 |
| `tools/pad-robin/` | `flow-to-robin.js` 生成器、`check.js` 静态校验、`compare-robin.js` 比对、`eval-flow.js` 结构评估 |
| `tools/pad-sync/` | `pad-admit.ps1` 只读准入网关、`pad-sync.ps1` 注入/运行、`pad-deploy/-release/-rollback/-schedule` |
| `tools/workday/` | 工作日历判断（通用件） |
| `skills/pad-flow-designer/` | 需求 → `flow.json` 的设计规则 |
| `skills/pad-robin-coder/` | 生成脚本时的红线清单 |
| `docs/nl-to-flow-guide.md` | 一句话 → flow.json → 四项校验的完整示例 |
| `tests/eval/` | 9 个合成样例 + 结构断言，可当模板抄 |

## 2. 三条硬规则（违反会被工具直接拒绝）

1. **动作不许编**：`pad_hint` 必须是 `pad-robin-action-kb/PAD_Robin_ActionKB.json` 里真实存在的三段式 `actionId`。
2. **参数不许造**：`params` 的键必须是该动作 `input_params` 里的真实参数名。
3. **副作用必须可跳过**：发信、过账、删文件放进 `guard` 节点（条件 `DryRun <> $'''1'''`），
   并且 `flow.json` 必须有 `budget`；`Scripting.RunDOSCommand*` / `RunVBScript*` 节点必须有 `intent`。

## 3. 标准工作流（按顺序执行，不要跳步）

```powershell
# 1) 设计：按 skills/pad-flow-designer 把需求写成 flows/<name>.json
# 2) 画布（可选，给人评审）
node tools\flow-drawio\flow-to-drawio.js flows\<name>.json flows\<name>.drawio
# 3) 生成
node tools\pad-robin\flow-to-robin.js flows\<name>.json out.robin
# 4) 静态校验（0 errors 才能继续）
node tools\pad-robin\check.js out.robin
# 5) 准入（只读；0 fail 才能交付）
.\tools\pad-sync\pad-admit.ps1 -FlowFile flows\<name>.json -RobinFile out.robin
# 6) 结构评估（如果为这条需求写了 tests/eval/<name>.cases.json）
node tools\pad-robin\eval-flow.js tests\eval\<name>.cases.json
```

全部通过后，告诉用户：

> 打开 PAD → 新建流程 → 画布 Ctrl+V 粘贴 `out.robin` → 按提示补 UI 元素 → 运行。

## 4. 报错怎么处理

| 现象 | 说明 | 你该做什么 |
|---|---|---|
| `未知动作` / `未知参数` | `flow.json` 写错，不是生成器坏了 | 改 `flow.json`，别改生成器、别手改 `.robin` |
| `变量 X 未定义` | 用了没被 SET 或没被动作产出的变量 | 补变量声明，或修正 `{{节点id.输出}}` 引用 |
| `edges 与 next/branch 不一致` | 画图用的边和生成用的结构漂了 | 按报错补齐 `edges` |
| 准入 `POLICY_DENY` | 命中 `policy.json` 的禁止规则 | 删掉该动作或改条件，不要绕过 |
| 准入 `MISSING_INTENT` / `BUDGET_UNKNOWN` | 缺必填声明 | 补 `intent` / `budget` |
| `模块未找到 PAD_Robin_ActionKB.json` | 没跑 `setup.ps1` | 先跑第 0 步 |

## 5. 明确不做的事

- **不要**替用户录 UI 元素：需要 UI 选择器的动作（部分网页/桌面自动化）必须由人在 PAD 里录制，生成器会拒绝。
- **不要**编造 SAP 脚本：`MB51导出.vbs`、`MIGO201_501.vbs` 这类是录制产物，不在仓库里。
- **不要**替用户发布到生产：`pad-deploy` / `pad-release` 会触发真实运行，必须人来确认。
- **不要**改 `.robin`：它是 `flow.json` 的产物，改了下次生成就被覆盖。

## 6. 完成定义

一条需求算做完，需要同时满足：

1. `flow.json` 通过生成器（0 error）
2. `check.js` 0 errors
3. `pad-admit` 0 fail（warn 可以，但要向用户说明）
4. 产物路径、粘贴步骤、需要人工补的部分（UI 元素 / VBS / 账号）都明确告诉用户

示例见 `docs/nl-to-flow-guide.md`；9 个可抄的样例在 `tests/eval/fixtures/`。
