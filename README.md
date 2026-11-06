# flow-ir

引擎无关的流程中间表示（IR）与多引擎适配器工具链。

`flow.json` 是唯一事实源：用引擎无关的结构描述业务流程——节点、分支、守卫（`guard`）、预算（`budget`）、
幂等性与可逆性、触发条件等。工具链读取这份 IR，做设计校验、编译、静态校验与准入审查，
再由适配器把 IR 落地到具体引擎。

> **当前只实现了 PAD（Power Automate Desktop / Robin）一个适配器**：生成 `.robin`、静态校验、准入、
> 注入发布、调度与监控。其他引擎（另一款 RPA、云端流、Python/VBS）属于可扩展方向，**尚未实现**；
> 接入时只需新增一套「读 IR、出本引擎产物」的生成与校验，IR 与门禁不用改。
> 适配器代码目前在 `tools/pad-robin/` 与 `tools/pad-sync/` 下。

链路：IR（`flow.json`）→ 设计校验 → 编译 → 静态校验 → 准入 → 适配器落地（当前：PAD / Robin）→ 调度与监控。

面向两类使用者：想让 AI 帮忙做 RPA 的业务同事，和要接手/扩展这套工具的开发者。

---

## 分层：IR 是事实源，引擎是可替换的后端

| 层 | 承担什么 | 现状 |
|---|---|---|
| IR 层 | `flow.json` 与配套契约（requirements / acceptance / cases）：节点、边、`guard`、`budget`、幂等、可逆性、`trigger` | 稳定；所有校验与生成只读它 |
| IR 校验 | 画布与 `edges` 一致性、需求级结构断言 | 引擎无关，已实现 |
| PAD 适配器 | `.robin` 生成、`.robin` 静态校验、准入、注入、发布、回滚、调度、遥测、验收 | **唯一已实现的适配器**，位于 `tools/pad-robin/`、`tools/pad-sync/` |
| 其他引擎适配器 | 另一款 RPA、云端流、Python/VBS | **未实现**；新适配器不得绕开同一套 IR 校验与硬规则 |

PAD 专属的东西属于适配器，而不是 IR 本身：动作表来自 PAD 动作知识库，`.robin` 语法、UI 选择器、
注入发布等概念只在 PAD 适配器里有意义。需要如实说明的是，当前 `flow.json` 的 `pad_hint`
本身就是给 PAD 适配器查表用的字段；IR 的节点、边、`guard`、`budget` 等结构是引擎无关的，
换引擎时这些结构不动，动作层的提示字段由新适配器按自己的动作表解释。

---

## 工具层与业务层

本仓库强制分离「工具层」与「业务层」：

| 层 | 内容 | 是否入库 |
|---|---|---|
| 工具层 | `tools/`、`docs/`、`tests/`、`skills/`、`AGENTS.md`、`setup.ps1`、`.github/`、`.githooks/` | 入库、可公开 |
| 业务层 | `business/` 下的流程定义、部署配置、准入策略、内部文档、业务脚本、日志、快照、指纹 | **不入库** |

`business/` 被 `.gitignore` **整目录忽略**：`git status` 不会显示其中的文件，提交前的
`pre-commit` 钩子与公开库内容扫描门禁还会硬拦截该目录下的路径（命中即退出码 2）。

本地工作区可以在 `business/` 下放业务流程与内部文档，该目录不入库，**clone 后为空**。
换句话说：仓库分发的是工具链本身，业务流程只存在于使用者自己的机器上，不会随仓库泄漏。

---

## 能做什么，做不到什么

| 能做 | 怎么做到的 |
|---|---|
| 把一段口语化需求写成**可评审的结构化定义**（IR：`flow.json` + 流程图） | AI 助手按 [AGENTS.md](AGENTS.md) 与 [skills/pad-flow-designer](skills/pad-flow-designer/SKILL.md) 产出 |
| 把 IR **确定性地编译**成目标引擎产物（当前适配器产出 `.robin`） | 适配器查动作表填空；动作/参数写错直接拒绝产出 |
| 编译前后**静态校验**：IR 结构（`edges` / 变量引用）、产物语法 | `check.js` / `check-flows.js` / `lint-robin.js` / `check-flow.js`（其中 `.robin` 部分属 PAD 适配器） |
| **准入**：动作是否注册、是否需要 UI 选择器、预算、触发声明、策略 deny/ask/allow | `pad-admit.ps1`（16 项只读检查，属 PAD 适配器） |
| 副作用**可跳过**：发信、过账、删文件包在 `guard` 里，靠 `DRY_RUN` 控制 | IR 结构 + 生成器 + 准入策略多层保证 |
| 注入设计器、发布、回滚、定时、遥测、产物验收（PAD 适配器） | `tools/pad-sync/` |

| 做不到 | 说明 |
|---|---|
| 自己听懂自然语言 | 仓库里没有 NL 解析器；「需求 → `flow.json`」由**你配的 AI 助手**完成，本仓库提供提示词、契约和尺子 |
| 替你录制 UI 元素 | 需要选择器的动作（部分网页/桌面自动化）必须人工在 PAD 里录制，生成器会明确拒绝 |
| 生成 SAP 的 VBS 脚本 | 事务码导出/过账这类 VBS 是录制产物，不随仓库分发 |
| 替你按下生产发布 | `pad-deploy` / `pad-release` 会触发真实运行，必须人来确认 |
| 提供 PAD 之外的现成适配器 | 目前只有 PAD 一个适配器；其他引擎需要新增一套读 IR、出本引擎产物的生成与校验 |

**一句话**：`AI 助手 + 本仓库 + 动作知识库` 三者齐了才是「自然语言 → 可运行流程」的闭环
（当前引擎是 PAD）；缺了 AI，就只能从 `flow.json` 这一步开始。

---

## 环境要求

| 依赖 | 必需 | 用途 |
|---|---|---|
| Node.js ≥ 18 | 是 | 适配器实现、流程图、评估集 |
| Git | 是 | 克隆动作知识库、启用提交前钩子 |
| PowerShell 5.1+ | 是 | 准入 / 部署 / 发布 / 定时（PAD 适配器） |
| Power Automate Desktop（Windows） | 要跑流时必需 | 执行 `.robin`（当前唯一的适配器） |
| Python 3.x + openpyxl | 否 | 工作日历判断、验收里的 Excel 判据 |
| AI 编程助手（任意） | 否 | 把自然语言写成 `flow.json` |

> 运行桌面流本身需要 PAD 的相应许可。编辑器里的「流程图模式」「流检查器」不是单独的付费功能。

---

## 快速开始

```powershell
git clone https://github.com/DangerousIllumi/flow-ir.git flow-ir
cd flow-ir
.\tools\check-env.ps1    # 先确认 Node >= 18、Git、PowerShell 可用
.\setup.ps1              # 安装 Node 依赖、启用提交前门禁、克隆动作知识库

# 验证环境是否可用（不需要 business/、动作知识库或 node_modules，全过返回 0）
.\examples\smoke.ps1
```

`setup.ps1` 做四件事：

1. 检查 Node.js / Git 版本；
2. 安装 Node 依赖（流程图自动布局用）并设置 `core.hooksPath=.githooks`；
3. 克隆 `pad-robin-action-kb`（PAD 适配器用的动作表）并校验关键文件，HTTPS 失败自动回退 SSH；
4. 创建 `business\flows` 目录。

> 部分受限网络或经由代理 / 防火墙访问时会拦截 HTTPS 直连 GitHub
> （典型报错 `Recv failure: Connection was reset`）。
> 这时改用 SSH：`git clone git@github.com:DangerousIllumi/flow-ir.git flow-ir`。
> 只是用的话 clone 即可；想改这套工具本身才需要 fork。
> 若 PowerShell 提示「在此系统上禁止运行脚本」，改用
> `powershell -ExecutionPolicy Bypass -File .\setup.ps1`。

> **新 clone 必须手动重建真实词表**：`tools\publish\public-safe.denylist.local.json` 不在库内
> （被 `.gitignore` 忽略）。缺这个文件时，`check-public-safe.ps1` 只加载
> `public-safe.denylist.json` 的占位规则，拦不住真实业务名、流程名和内部路径。
> 重建方式：照 `public-safe.denylist.json` 的分类结构（`businessName` / `flowName` / `realPath` /
> `accountOrServer` / `privateIdentifier`）新建同结构 JSON，填入自己的真实词，保存在同一路径即可；
> **不要提交该文件**。

**有 AI 助手时的最短路径**：在已打开本目录的 AI 编程助手里，第一句话这样发
（只贴链接、不打开目录，AI 看不到 `AGENTS.md`）：

```text
读 AGENTS.md，按 docs/prompts/nl-to-flow.md 执行：先跑 .\setup.ps1，再把下面的需求写成 business/flows/<name>.json，走完 设计 → 生成 → 静态校验 → 准入。

需求：<在这里写，例如：每天把源目录下的 CSV 复制到归档目录，同名覆盖，结束后弹窗提示数量>
```

之后只需要：

1. AI 自己读 `AGENTS.md` 与 `docs/prompts/nl-to-flow.md`，不需要你转述里面写了什么；
2. 它跑完「生成 → 静态校验 → 准入」后，把 `out.robin` 全选复制，粘进 PAD 新建流程的画布（`Ctrl+V`）
   （这是当前 PAD 适配器的收尾步骤）；
3. 交付标准见 AGENTS.md 第 6 节：生成器 0 error、`check.js` 0 errors、准入 0 fail，
   并明确告诉你哪些部分需要人工补（UI 元素 / 脚本 / 账号）。

---

## 标准工作流（六步）

不依赖 AI 时，从一份已有的 `flow.json` 开始。下面六步是**当前 PAD 适配器**的实现；
IR 层本身只有 `flow.json` 与配套契约，换引擎时替换这一层的命令即可：

```powershell
# 1) 画评审图（可选），并校验 edges 与 next/branch 是否一致（IR 层，引擎无关）
node tools\flow-drawio\flow-to-drawio.js business\flows\<name>.json business\flows\<name>.drawio
node tools\flow-drawio\check-flow.js business\flows\<name>.json

# 2) 生成（当前适配器：IR → .robin）
node tools\pad-robin\flow-to-robin.js business\flows\<name>.json out.robin

# 3) 产物静态校验（0 errors 才能继续；PAD 适配器）
node tools\pad-robin\check.js out.robin

# 4) 流程卫生（未读输出 / 未用变量 / IF 嵌套过深；建议但不阻断；PAD 适配器）
node tools\pad-robin\lint-robin.js out.robin

# 5) 准入（只读，0 fail 才能交付；PAD 适配器）
.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<name>.json -RobinFile out.robin

# 6) 结构评估（需求级断言，只读 IR，引擎无关）
node tools\pad-robin\eval-flow.js business\tests\eval\<name>.cases.json
```

- `flow.json` 的写法见 [docs/agent-prompts.md](docs/agent-prompts.md)；
- 可直接抄的中性样例在 [tests/eval/fixtures](tests/eval/fixtures)：16 个合成样例（10 个流程 + 6 个 trigger），
  对应的 `*.cases.json` 共 11 个，位于 [tests/eval](tests/eval)，可整目录一起跑：`node tools\pad-robin\eval-flow.js tests\eval`；
- 业务用例按 AGENTS.md 的约定放在 `business\tests\eval\`（不入库）。
- `trigger` 只写 `kind`（`manual` / `schedule` / `file`）；旧形状 `{ "type": "...", "config": {...} }`
  会被判 `TRIGGER_LEGACY_SHAPE`，字段表见 [docs/trigger-adapter-design.md](docs/trigger-adapter-design.md)。

### 上线链路（需要 PAD 真机）

```powershell
# 运行时配置（准入 / 预检 / 注入运行都用）：照着仓库里的中性模板填本机真实路径
Copy-Item docs\config.example.json business\config\runtime.json

# 每个流程的部署配置：<流程名>.json，字段由同目录的 <流程名>.schema.json 定义（两者都不入库）
.\tools\pad-sync\pad-deploy.ps1 -FlowName <PAD 流程名> -SourceRobin business\flows\<name>.robin -ConfigFile business\config\<name>.json -AllowProd -SkipConfirm -PublishOnly
```

- `pad-deploy` 会替换 `{{KEY}}` 占位符、注入设计器、发布并校验哈希；
  只校验配置不注入时可加 `-ValidateOnly`；
- `pad-release` 在此基础上加「测试摘要 → 人工确认（三哈希指纹）→ 快照」；
- `pad-rollback` 可从快照回退；`pad-schedule` / `pad-trigger` 负责定时与触发器注册。

跑完想单独核对产物（不碰 PAD、只读）：

```powershell
.\tools\pad-sync\pad-verify.ps1 -AcceptanceFile business\flows\<name>.acceptance.json -ConfigFile business\config\<name>.json
```

---

## 工具目录

| 目录 | 作用 |
|---|---|
| `tools/check-env.ps1` | 环境检查（Node / Git / PowerShell） |
| `tools/flow-drawio/` | IR 层：`flow.json` ↔ `.drawio` 画布；`check-flow.js` 校验边一致性 |
| `tools/pad-robin/` | PAD 适配器：编译（`flow-to-robin.js`）、产物静态校验（`check.js` / `check-flows.js`）、流程卫生（`lint-robin.js`）、生成结果比对（`compare-robin.js`）；同目录还放着只读 IR 的 `eval-flow.js` |
| `tools/pad-sync/` | PAD 适配器：只读准入（`pad-admit.ps1`）、部署（`pad-deploy.ps1`）、发布（`pad-release.ps1`）、回滚（`pad-rollback.ps1`）、定时（`pad-schedule.ps1`）、触发注册（`pad-trigger.ps1`）、注入运行（`pad-sync.ps1`）、指纹（`pad-fingerprint.ps1`）、验收（`pad-verify.ps1`），以及告警 / 预检 / 遥测 / 编码等共享模块 |
| `tools/publish/` | 推送前内容门禁 `check-public-safe.ps1` 与结构化词表（与引擎无关） |
| `tools/workday/` | 工作日历判断（通用件，可单独复用） |
| `skills/` | `pad-flow-designer`（需求 → `flow.json` 的设计规则）、`pad-robin-coder`（写 PAD 脚本时的红线清单） |
| `tests/` | Pester 单元测试、Python 测试、公开评估集与遥测样例 |

归属说明：`tools/flow-drawio/`、`eval-flow.js`、`tools/publish/`、`tools/workday/` 只处理 IR 或与引擎无关的通用任务；
`tools/pad-robin/` 的生成与 `.robin` 校验、以及整个 `tools/pad-sync/` 都属于**当前 PAD 适配器**，换引擎时需要另行实现。

---

## 三条硬规则

违反其中任何一条，工具会直接拒绝，不会产出半成品。这三条由**当前 PAD 适配器**强制执行；
新增其他引擎的适配器时必须复用同一套约束，而不是另立一套：

1. **动作不许编**：`pad_hint` 必须是动作知识库里真实存在的三段式 `actionId`。
2. **参数不许造**：`params` 的键必须是该动作 `input_params` 里的真实参数名。
3. **副作用必须可跳过**：发信、过账、删文件放进 `guard`（条件 `DryRun <> $'''1'''`），
   `flow.json` 必须声明 `budget`；`Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` 节点必须带 `intent`。

---

## 门禁与指纹

两道门禁，各自回答一个问题：

| 门禁 | 回答的问题 | 关键实现 |
|---|---|---|
| 内容扫描 | **这些文件能不能推**（文件合规，注释里的业务名/真实路径仍可能泄漏，所以按内容逐行扫） | `tools/publish/check-public-safe.ps1`：命中词表即失败；`business/` 路径直接判错（退出码 2）。`pre-commit` 钩子扫暂存区，CI 用 `git ls-files` 兜底 |
| 准入网关 | **这份流程/这次运行能不能跑**（16 项只读检查，一次返回全部问题） | `tools/pad-sync/pad-admit.ps1`（PAD 适配器）：退出码 `0` 通过 / `1` 有 fail / `2` 仅存在 ask |

**指纹（PAD 适配器）**：发布后把 `.robin`、部署配置、验收判据三份内容的 SHA256 写进基线
（v3 另收流程实际引用的脚本），准入时与基线比对；不一致默认 `fail`，直接阻断。
基线数据只写在 `business/fingerprints/<流程名>.json`，不入库。其他引擎适配器需要各自定义等价物，
但「先播种基线、运行前比对」这条思路应保持一致。

业务层与公开边界详见 [docs/admission-gate.md](docs/admission-gate.md) 第 9 节。

---

## 契约文件

| 文件 | 回答的问题 |
|---|---|
| `business/flows/<name>.json` | 流程长什么样（节点、边、参数、变量、预算、触发声明） |
| `business/flows/<name>.requirements.json` | 跑之前环境该有什么（目录、文件、可执行文件） |
| `business/flows/<name>.acceptance.json` | 跑完了怎么算成功（产物存在 / 更新 / 内容匹配） |
| `business/config/<name>.json` + `<name>.schema.json` | 部署时占位符填什么，以及配置本身是否合法 |
| `business/tests/eval/<name>.cases.json` | 需求里必须成立的结构断言（可当回归测试） |

验收判据支持 `fileExists` / `globNewerThan` / `pair` / `json` / `jsonl` / `logState`。
契约格式与引擎无关；消费它们的部署/验收执行器（占位符替换、判据求值）目前在 `tools/pad-sync/`，
属于 PAD 适配器。换引擎时可以复用契约格式，执行器需按新引擎重写。

---

## 目录结构

```
.
├── AGENTS.md                  AI 助手的入口手册（先读这个）
├── README.md                  本文件
├── setup.ps1                  一次装好 Node 依赖、钩子与动作知识库
├── tools/                     工具层
│   ├── check-env.ps1          环境检查
│   ├── flow-drawio/           IR 层：flow.json ↔ .drawio，edges 一致性校验
│   ├── pad-robin/             PAD 适配器：编译器、产物校验、流程卫生、比对；另含只读 IR 的 eval-flow.js
│   ├── pad-sync/              PAD 适配器：准入、部署、发布、回滚、定时、触发注册、注入运行、遥测、验收
│   ├── publish/               推送前内容门禁 + 词表（与引擎无关）
│   └── workday/               工作日历判断
├── docs/                      文档层（含提示词与准入/脚本规范）
├── skills/                    设计规则与脚本红线
├── tests/                     Pester / Python 测试 + 公开评估集
├── .githooks/                 pre-commit 内容门禁
├── .github/workflows/ci.yml   Windows 上跑 pytest / Pester / Node / 评估集 / 准入样例
├── pad-robin-action-kb/       动作知识库（不入库，setup.ps1 克隆）
├── node_modules/              Node 依赖（不入库）
└── business/                  业务层：本地工作区，不入库，clone 后为空
    ├── flows/                 流程定义与配套判据
    ├── config/                部署配置与 schema
    ├── policy.json            准入策略（deny / ask / allow）
    ├── docs/                  运行手册与内部记录
    ├── scripts/               流程引用的 VBS / PowerShell 录制产物
    ├── tools/                 业务专属脚本与合成数据生成器
    ├── tests/                 业务回归用例与结构断言
    ├── fingerprints/          发布基线（含机器名与真实路径，绝不入库）
    ├── logs/ snapshots/ worklog/ manifest.jsonl
```

---

## 设计原则

- **唯一设计源**：`flow.json` 是唯一可编辑的源；`.robin` 是产物，改它下次生成就会被覆盖。
  CI 在检出 `business/` 时会做硬断言「重新生成的结果 == 仓库里的脚本」。
- **引擎可替换**：IR 结构不写死任何引擎的假设；新增引擎 = 新增一套适配器，不改 IR、不改门禁。
- **确定性优先**：编译阶段不调用模型，只查表；模型只出现在「写 `flow.json`」这一步。
- **失败要早**：能在编译前挡住的错误（动作名、参数名、悬空引用、无界循环、策略命中），
  绝不留到运行时。
- **副作用可回退**：先 `DRY_RUN` 跑通分支，再走真实运行；上线有快照与回滚。

---

## 遇到报错怎么办

| 现象 | 说明 | 你该做什么 |
|---|---|---|
| `未知动作` / `未知参数` | `flow.json` 写错，不是生成器坏了 | 改 `flow.json`，别改生成器、别手改 `.robin` |
| `变量 X 未定义` | 用了没被 SET 或没被动作产出的变量 | 补变量声明，或修正 `{{节点id.输出}}` 引用 |
| `edges 与 next/branch 不一致` | 画图用的边和生成用的结构漂了 | 按报错补齐 `edges` |
| 准入 `POLICY_DENY` | 命中 `business/policy.json` 的禁止规则 | 删掉该动作或改条件，不要绕过 |
| 准入 `MISSING_INTENT` / `BUDGET_UNKNOWN` | 缺必填声明 | 补 `intent` / `budget` |
| 结构评估 `缺声明节点` / `run_mode=` | 没回答「运行方式 / 幂等性」 | 补 `run_mode` / `idempotent` / `idempotency_note`，不要默认填充 |
| `模块未找到 PAD_Robin_ActionKB.json` | 没跑 `setup.ps1` | 先跑快速开始里的环境准备 |
| 粘进画布后一片空白、也没报错 | 多半是语法被 PAD 静默丢弃 | 跑 `node tools\pad-robin\check.js out.robin`，它会指出第几行、哪个标识符 |

**`git clone` 知识库失败？** 到 <https://github.com/JoeG592/pad-robin-action-kb> 下载 ZIP，
解压到 `pad-robin-action-kb\` 即可。

**PowerShell 提示「在此系统上禁止运行脚本」？**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**改 `.robin` 后线上就漂了？** 正常：`.robin` 是产物。要改就改 `flow.json` 再重新生成；
设计器里的「应用修复」同理，不要点。

**能跑在 Linux/CI 上吗？** 编译、校验、评估集、画布生成都可以；
注入 PAD、运行、发布必须 Windows + 已装 PAD。

---

## 配套的动作知识库（PAD 适配器）

PAD 适配器的生成器只认知识库里存在的三段式 `actionId` 和真实参数名，查不到就拒绝产出。
IR 层本身不依赖它；换成别的引擎时，需要的是那个引擎自己的动作表。

| 仓库 | 提供什么 | 是否必需 |
|---|---|---|
| **本仓库** | IR（`flow.json`）、IR 校验与评估集、PAD 适配器（生成/准入/发布/回滚/定时）、提示词与 Skill | 是 |
| [pad-robin-action-kb](https://github.com/JoeG592/pad-robin-action-kb) | PAD 适配器的动作表：1,086 个动作的真实 `actionId` / 参数名 / 输出名 / 粘贴样例 | **是**（`setup.ps1` 自动克隆，不入本库） |

---

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件、以及不随本仓库分发的内容（动作知识库等）见 [NOTICE](docs/governance/NOTICE)。
安全问题请按 [SECURITY.md](docs/governance/SECURITY.md) 反馈；贡献流程见 [CONTRIBUTING.md](docs/governance/CONTRIBUTING.md)。
