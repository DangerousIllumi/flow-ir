# nl2pad

**用一句话生成 Power Automate Desktop 工作流。**

自然语言 → `flow.json`（唯一设计源）→ `.robin`（可直接粘进 PAD 画布）→ 校验 · 准入 · 发布 · 验收。

> 面向两类人：想让 AI 帮忙做 RPA 的业务同事，和要接手/扩展这套工具的开发者。

---

## 它能做到什么，做不到什么

先说边界，避免误解。

| 能做 | 怎么做到的 |
|---|---|
| 把「每月 3 号从邮箱取对账单，和系统核对，不一致的发邮件给经理」写成一版**可评审的结构化定义**（`flow.json` + 流程图） | AI 助手按 [AGENTS.md](AGENTS.md) 与 [skills/pad-flow-designer](skills/pad-flow-designer/SKILL.md) 产出 |
| 把定义**确定性地编译**成 `.robin` 脚本 | `flow-to-robin.js` 查动作知识库填空，动作/参数写错直接拒绝产出 |
| 编译前**静态校验**：语法、变量是否定义、`edges` 与结构是否漂移 | `check.js` / `check-flows.js` / `lint-robin.js` |
| **准入**：动作是否注册、是否需要 UI 选择器、预算、策略 deny/ask/allow | `pad-admit.ps1`（13 项，只读） |
| 副作用**可跳过**：发信、过账、删文件的 `guard` + `DRY_RUN` | 生成器 + 策略双层保证 |
| 注入设计器、发布、回滚、定时、遥测、产物验收 | `tools/pad-sync/` |

| 做不到 | 说明 |
|---|---|
| 自己听懂自然语言 | 仓库里没有 NL 解析器；「需求 → `flow.json`」这一步由**你配的 AI 助手**完成，本仓库提供的是提示词、契约和尺子 |
| 替你录制 UI 元素 | 需要选择器的动作（部分网页/桌面自动化）必须人工在 PAD 里录制，生成器会明确拒绝 |
| 生成 SAP 的 VBS 脚本 | 事务码导出/过账这类 VBS 是录制产物，不随仓库分发 |
| 替你按下生产发布 | `pad-deploy` / `pad-release` 会触发真实运行，必须人来确认 |

**一句话结论**：`AI 助手 + 本仓库 + 动作知识库` 三者齐了，才是「自然语言 → 可运行 PAD 流」的闭环；缺了 AI，就只能从 `flow.json` 这一步开始。

---

## 两个公开库的分工

| 仓库 | 提供什么 | 是否必需 |
|---|---|---|
| **本仓库** | 中间表示（`flow.json`）、编译器、静态校验、准入网关、发布/回滚/定时、提示词与 Skill、评估集 | 是 |
| [pad-robin-action-kb](https://github.com/JoeG592/pad-robin-action-kb) | 1,086 个 PAD 动作的真实 `actionId` / 参数名 / 输出名 / 粘贴样例 | **是**（`setup.ps1` 自动克隆，不入本库） |

知识库是「动作不许编」的唯一依据：生成器只认里面存在的三段式 `actionId` 和真实参数名，查不到就拒绝产出。

---

## 环境要求

| 依赖 | 必需 | 用途 |
|---|---|---|
| Node.js ≥ 18 | 是 | 生成器、静态校验、流程图、评估集 |
| Git | 是 | 克隆动作知识库 |
| PowerShell 5.1+ | 是 | 准入 / 部署 / 发布 / 定时 |
| Power Automate Desktop（Windows） | 要跑流时必需 | 执行 `.robin` |
| Python 3.x + openpyxl | 否 | 工作日历判断、验收里的 Excel 判据 |
| AI 编程助手（任意） | 否 | 把自然语言写成 `flow.json` |

> 许可提示：运行桌面流本身需要 PAD 的相应许可（Premium 或 Windows 11 默认环境的个人版）。
> 编辑器里的「流程图模式」「流检查器」不是单独的付费功能。

---

## 3 步上手（有 AI 助手）

```powershell
git clone https://github.com/DangerousIllumi/nlg-workflow-toolkit.git nl2pad
cd nl2pad
.\setup.ps1            # 安装 Node 依赖 + 克隆动作知识库
```

1. 用任意 AI 编程助手打开这个目录——它会先读到 [AGENTS.md](AGENTS.md)。
2. 把 [prompts/nl-to-flow.md](prompts/nl-to-flow.md) 里那段话整段粘给它，末尾写你的需求。
3. 它跑完 **生成 → 静态校验 → 准入** 后，把 `out.robin` 全选复制，粘进 PAD 新建流程的画布，`Ctrl+V`。

交付标准写在 AGENTS.md 第 6 节：生成器 0 error、`check.js` 0 errors、准入 0 fail，
并且明确告诉你哪些部分需要人工补（UI 元素 / 脚本 / 账号）。

---

## 不用 AI 也能用（从 `flow.json` 开始）

```powershell
# 1) 画评审图（可选）
node tools\flow-drawio\flow-to-drawio.js flows\<name>.json flows\<name>.drawio

# 2) 编译
node tools\pad-robin\flow-to-robin.js flows\<name>.json out.robin

# 3) 静态校验（0 errors 才能继续）
node tools\pad-robin\check.js out.robin

# 4) 流程卫生（未读输出 / 未用变量 / IF 嵌套过深）
node tools\pad-robin\lint-robin.js out.robin

# 5) 准入（只读，0 fail 才能交付）
.\tools\pad-sync\pad-admit.ps1 -FlowFile flows\<name>.json -RobinFile out.robin

# 6) 结构评估（可选：需求级断言）
node tools\pad-robin\eval-flow.js tests\eval\<name>.cases.json
```

`flow.json` 的写法见 [docs/agent-prompts.md](docs/agent-prompts.md)，
可抄的 9 个合成样例在 [tests/eval/fixtures](tests/eval/fixtures)。

### 上线链路（需要 PAD 真机）

```powershell
Copy-Item config\sample.example.json config\<name>.json   # 填自己的账号与路径（示例不含真实凭据）
.\tools\pad-sync\pad-deploy.ps1 -FlowName <PAD 流程名> -SourceRobin flows\<name>.robin -ConfigFile config\<name>.json -AllowProd -SkipConfirm -PublishOnly
```

`pad-deploy` 会替换 `{{KEY}}` 占位符、注入设计器、发布并校验哈希；`pad-release` 在此基础上加
「测试摘要 → 人工确认（三哈希指纹）→ 快照」，`pad-rollback` 可从快照回退。

跑完想单独核对产物（不碰 PAD、只读）：

```powershell
.\tools\pad-sync\pad-verify.ps1 -AcceptanceFile flows\<name>.acceptance.json -ConfigFile config\<name>.json
```

---

## 三条硬规则

违反其中任何一条，工具会直接拒绝，不会产出半成品：

1. **动作不许编**：`pad_hint` 必须是知识库里真实存在的三段式 `actionId`。
2. **参数不许造**：`params` 的键必须是该动作 `input_params` 里的真实参数名。
3. **副作用必须可跳过**：发信、过账、删文件放进 `guard`（条件 `DryRun <> $'''1'''`），
   `flow.json` 必须声明 `budget`；`RunDOSCommand*` / `RunVBScript*` 节点必须带 `intent`。

## 契约文件

| 文件 | 回答的问题 |
|---|---|
| `flows/<name>.json` | 流程长什么样（节点、边、参数、变量） |
| `flows/<name>.requirements.json` | 跑之前环境该有什么（目录、文件、可执行文件） |
| `flows/<name>.acceptance.json` | 跑完了怎么算成功（产物存在/更新/内容匹配） |
| `tests/eval/<name>.cases.json` | 需求里必须成立的结构断言（可当回归测试） |

验收判据支持 `fileExists` / `globNewerThan` / `pair` / `json` / `jsonl` / `logState`，
由 `tools/pad-sync/PadAcceptance.psm1` 执行，不依赖 PAD 自己报没报错。

---

## 目录结构

```
.
├── AGENTS.md                  AI 助手的入口手册（先读这个）
├── prompts/nl-to-flow.md      可整段粘给 AI 的提示词
├── skills/
│   ├── pad-flow-designer/     需求 → flow.json 的设计规则
│   └── pad-robin-coder/       写脚本时的红线清单
├── tools/
│   ├── flow-drawio/           flow.json ↔ .drawio，edges 一致性校验
│   ├── pad-robin/             编译器、静态校验、流程卫生、比对、结构评估
│   ├── pad-sync/              准入、部署、发布、回滚、定时、注入运行、遥测、验收、修复
│   └── workday/               工作日历判断（通用件）
├── config/                    部署配置的 schema 与示例（不含真实凭据）
├── docs/                      设计文档、Robin 语法、准入网关说明
├── tests/                     Pester 套件 + 设计质量评估集 + 遥测样例
└── .github/workflows/ci.yml   Windows 上跑 pytest / Pester / Node / 生成一致性
```

---

## 设计原则

- **唯一设计源**：`flow.json` 是唯一可编辑的源；`.robin` 是产物，改它下次就会被覆盖。
  CI 里有硬断言「重新生成的结果 == 仓库里的脚本」。
- **确定性优先**：编译阶段不调用模型，只查表；模型只出现在「写 `flow.json`」这一步。
- **失败要早**：能在编译前挡住的错误（动作名、参数名、悬空引用、无界循环、策略命中），
  绝不留到 PAD 运行时。
- **副作用可回退**：先 `DRY_RUN` 跑通分支，再走真实运行；上线有快照与回滚。

---

## 常见问题

**粘进画布后一片空白、也没报错？**
多半是语法被 PAD 静默丢弃。跑 `node tools\pad-robin\check.js out.robin`，它会指出第几行、哪个标识符。

**`git clone` 知识库失败？**
到 <https://github.com/JoeG592/pad-robin-action-kb> 下载 ZIP，解压到 `pad-robin-action-kb\` 即可。

**PowerShell 提示「在此系统上禁止运行脚本」？**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**改 `.robin` 后线上就漂了？**
正常：`.robin` 是产物。要改就改 `flow.json` 再重新生成；设计器里的「应用修复」同理，不要点。

**能跑在 Linux/CI 上吗？**
编译、校验、评估集、画布生成都可以；注入 PAD、运行、发布必须 Windows + 已装 PAD。

---

## 许可

MIT，见 [LICENSE](LICENSE)。第三方组件、以及不随本仓库分发的内容（动作知识库等）见 [NOTICE](NOTICE)。
安全问题请按 [SECURITY.md](SECURITY.md) 反馈；贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。
