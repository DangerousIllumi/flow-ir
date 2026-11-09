# AGENTS.md — 给 AI 助手的入口说明

> 你（AI 助手）正在一个 **PAD 工作流工具链** 仓库里。用户会用自然语言描述一个流程，
> 你要把它变成可粘贴进 Power Automate Desktop 的 Robin 脚本。
> 这份文件是你的操作手册：**先读完再动手**。

> **只想了解这个项目？** 读 [`llms.txt`](llms.txt)：引擎无关的 IR 与多引擎适配器定位、
> 分层归属、红线与文档索引。
> **要动手改流程或脚本？** 继续往下读——本文件才是操作手册，不要只看摘要就开工。

## 0. 先做一次环境准备

```powershell
.\setup.ps1          # 安装 Node 依赖 + 克隆动作知识库 pad-robin-action-kb/
.\tools\check-env.ps1
```

- 知识库是**必需**的：生成器靠它精确查表，查不到会拒绝产出。
- `.ps1` / `.psm1` 必须保持 **UTF-8 with BOM**（PowerShell 5.1 对无 BOM 的中文会解析错乱）。
- 仓库里没有 `business/flows/` 目录时，自己创建。

## 1. 仓库地图

| 路径 | 作用 |
|---|---|
| `tools/flow-drawio/` | `flow.json → .drawio` 画布、`check-flow.js` 边一致性、`example-flow.json` 可跑示例 |
| `tools/pad-robin/` | `flow-to-robin.js` 生成器、`check.js` 静态校验、`compare-robin.js` 比对、`eval-flow.js` 结构评估 |
| `tools/pad-sync/` | `pad-admit.ps1` 只读准入网关、`pad-sync.ps1` 注入/运行、`pad-deploy/-release/-rollback/-schedule` |
| `tools/workday/` | 工作日历判断（通用件） |
| `tools/xlsx/` | 只读 Excel 读取层（通用件）：按表头名定位列、宽松日期/数值转换、表头探查入口（`--dump`） |
| `tools/publish/` | 公开层词表扫描 `check-public-safe.ps1`：推送前拦截业务词与内部路径 |
| `skills/pad-flow-designer/` | 需求 → `flow.json` 的设计规则 |
| `skills/pad-robin-coder/` | 生成脚本时的红线清单 |
| `docs/nl-to-flow-guide.md` | 一句话 → flow.json → 四项校验的完整示例 |
| `tests/eval/` | 16 个合成样例（10 个流程 + 6 个 trigger）+ 结构断言，可当模板抄 |

## 1.5 目录约定（工具与业务彻底分离）

| 层 | 目录 | 能否公开 |
|---|---|---|
| 工具/文档/测试/技能 | `tools/`、`docs/`、`tests/`、`skills/`、`docs/prompts/` | 可公开 |
| 业务 | `business/`（`flows/`、`config/`、`docs/`、`policy.json`、`manifest.jsonl`、`logs/`、`snapshots/`、`worklog/`） | **绝不公开**，已被 `.gitignore` 忽略且被推送门禁硬拦截 |
| AI 入口 | 根目录 `AGENTS.md`、`README.md` | 可公开 |

业务文件写进 `business/` 即可；`git status` 不会显示，推送门禁遇到会直接退出码 2。

## 2. 三条硬规则（违反会被工具直接拒绝）

1. **动作不许编**：`pad_hint` 必须是 `pad-robin-action-kb/PAD_Robin_ActionKB.json` 里真实存在的三段式 `actionId`。
2. **参数不许造**：`params` 的键必须是该动作 `input_params` 里的真实参数名。
3. **副作用必须可跳过**：发信、过账、删文件放进 `guard` 节点（条件 `DryRun <> $'''1'''`），
   并且 `flow.json` 必须有 `budget`；`Scripting.RunDOSCommand*` / `RunVBScript*` 节点必须有 `intent`。

触发声明也只认一种形状：`"trigger": { "kind": "manual" | "schedule" | "file" }`。
`manual` 只允许 `{ "kind": "manual" }`；旧形状 `{ "type": "...", "config": {...} }` 会被判
`TRIGGER_LEGACY_SHAPE`（不做静默映射），完整字段见 `docs/trigger-adapter-design.md`。

补充编码原则：所有 py / vbs / PAD / ps1 代码遵循 `docs/script-standards.md` 的**奥卡姆剃刀**——
只做当前需求，能复用不新建，能删不加；但副作用守卫、幂等、审计、错误处理不在此列。

## 3. 标准工作流（按顺序执行，不要跳步）

```powershell
# 1) 设计：先按 skills/pad-flow-designer「生成 flow.json 之前的必答项（硬门槛）」
#    逐节点问清「运行方式（auto/confirm/observe）」与「幂等性（true/false + 幂等键）」，
#    用户没回答就不生成 business\flows\<name>.json
# 2) 画布（可选，给人评审）
node tools\flow-drawio\flow-to-drawio.js business\flows\<name>.json business\flows\<name>.drawio
# 3) 生成
node tools\pad-robin\flow-to-robin.js business\flows\<name>.json out.robin
# 4) 静态校验（0 errors 才能继续）
node tools\pad-robin\check.js out.robin
# 5) 准入（只读；fail=0 且 ask=0 才能交付，ask 时退出码 2 同样阻断）
.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<name>.json -RobinFile out.robin
# 6) 结构评估（用例放 business\tests\eval\；公开库只放中性样例）
node tools\pad-robin\eval-flow.js business\tests\eval\<name>.cases.json
```

全部通过后，告诉用户：

> 打开 PAD → 新建流程 → 画布 Ctrl+V 粘贴 `out.robin` → 按提示补 UI 元素 → 运行。

## 4. 报错怎么处理

| 现象 | 说明 | 你该做什么 |
|---|---|---|
| `未知动作` / `未知参数` | `flow.json` 写错，不是生成器坏了 | 改 `flow.json`，别改生成器、别手改 `.robin` |
| `变量 X 未定义` | 用了没被 SET 或没被动作产出的变量 | 补变量声明，或修正 `{{节点id.输出}}` 引用 |
| `edges 与 next/branch 不一致` | 画图用的边和生成用的结构漂了 | 按报错补齐 `edges` |
| 准入 `POLICY_DENY` | 命中 `business/policy.json` 的禁止规则 | 删掉该动作或改条件，不要绕过 |
| 准入 `MISSING_INTENT` / `BUDGET_UNKNOWN` | 缺必填声明 | 补 `intent` / `budget` |
| 结构评估 `缺声明节点` / `run_mode=` | 没回答“运行方式 / 幂等性” | 回问用户，补 `run_mode` / `idempotent` / `idempotency_note`，不要默认填充 |
| `模块未找到 PAD_Robin_ActionKB.json` | 没跑 `setup.ps1` | 先跑第 0 步 |

## 5. 明确不做的事

- **不要**替用户录 UI 元素：需要 UI 选择器的动作（部分网页/桌面自动化）必须由人在 PAD 里录制，生成器会拒绝。
- **不要**编造 SAP 脚本：事务码导出/过账这类 VBS 是录制产物，不在仓库里。
- **不要**替用户发布到生产：`pad-deploy` / `pad-release` 会触发真实运行，必须人来确认。
- **不要**改 `.robin`：它是 `flow.json` 的产物，改了下次生成就被覆盖。

## 6. 完成定义

一条需求算做完，需要同时满足：

1. `flow.json` 通过生成器（0 error）
2. `check.js` 0 errors
3. `pad-admit` fail=0 且 ask=0（warn 可以，但要向用户说明；ask 退出码 2，同样阻断交付）
4. 产物路径、粘贴步骤、需要人工补的部分（UI 元素 / VBS / 账号）都明确告诉用户

示例见 `docs/nl-to-flow-guide.md`；16 个可抄的样例在 `tests/eval/fixtures/`（10 个流程 + 6 个 trigger）。
