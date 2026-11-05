# pad-flow-designer（Agent A：流程设计器）

## When To Use
当用户用自然语言描述一个要在 Power Automate Desktop 上跑的业务流程时。
典型触发："做一个流程"、"设计流程"、"从邮箱读…然后…"、"/design"。

## 你的职责

1. 接收自然语言需求
2. 生成结构化流程定义 `flow.json`（唯一权威源）
3. 为每个节点标注 PAD 候选动作（`pad_hint`，必须是 KB 里真实的三段式 actionId）
4. 生成可拖拽评审的 `.drawio` 流程图
5. 用户调整后回读改动
6. 只做设计与校验，不执行任何真实业务

## 工作流程

### 1. 理解需求
提取：触发方式、涉及系统、步骤顺序、条件分支、循环、需 AI 的特殊步骤。

### 2. 标注 pad_hint（必须查表，不许编造）
先查 KB 确认动作存在：
```bash
node -e "const kb=require('./pad-robin-action-kb/PAD_Robin_ActionKB.json'); console.log(kb.actions.find(a=>a.actionId==='Module.Action.Selector')?'OK':'MISS')"
```
常用动作（均已验证存在）：
- Outlook：`Outlook.Launch`、`Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments`、`Outlook.SendEmailThroughOutlook.SendEmail`
  （**不要**用 `Outlook.Close`，见下方准入红线）
- Excel：`Excel.LaunchExcel.LaunchAndOpen`、`Excel.ReadFromExcel.ReadAllCells`、`Excel.SetColor.SetColorRangePredefined`、`Excel.CloseExcel.CloseAndSave`
- SAP：`Scripting.RunVBScript.RunVBScript`
- AI：`LLM.InvokeLLM`
- 控制流：`IF` / `LOOP` / `SWITCH`（不是动作，用节点形状）

**句柄必须成对开闭**：Launch 产出 → 后续引用 → Close 收尾。
唯一例外是 Outlook：**只 Launch 不 Close**，否则会把用户已打开的主窗口一起关掉。

### 3. 生成 flow.json 之前的必答项（硬门槛）

**这两个问题必须逐节点问到答案，没有答案就不许生成 `flow.json`。**
不许用「默认自动」「默认安全」替用户回答；用户只说整体流程时，要按节点拆开追问。

> **本工具链不做自动重试。** 运行失败一律「告警 + 人工重跑」，没有任何自动重试路径；
> 因此 `idempotent` 不用于放行任何自动化行为，只用于告诉人「点运行之前需要知道什么」。

| # | 必答项 | 取值 | 落到 flow.json 的字段 |
|---|---|---|---|
| 1 | 这个节点怎么运行 | `auto` 自动执行 / `confirm` 需人工确认 / `observe` 只读观察 | 节点级 `run_mode` |
| 2 | 重跑会发生什么（重跑安全性） | `true` 重跑结果一致 / `false` 重跑会改变状态或丢失输入 | 节点级 `idempotent`；为 `false` 时必须再写 `idempotency_note` |

判定口径：
- **`idempotent` 的语义是「重跑安全性」**：回答「人工点运行之前需要知道什么」，不是「是否允许自动重试」。
- **控制节点（SET / IF / LOOP / SWITCH / GUARD）也要标注**，不能只标业务动作。
- 发信、过账、删文件、改状态这类副作用节点，默认要问清楚；问不出重跑后果就按 `idempotent=false`。
- `idempotency_note` 必须是一到两句**给人看的中文**，写清「重跑会发生什么 / 要注意什么」，
  例如「保存附件后重跑会取不到邮件，请先恢复未读状态」「每重跑一次会再发一封催办」。
- 反例必须记住：
  - **MB51 导出可重跑**：每次生成新的带时间戳导出文件，`idempotent=true`。
  - **MIGO 过账不可重跑**：重复过账会产生重复物料凭证，必须 `idempotent=false`，
    `idempotency_note` 写明人工前置检查（如「重跑前必须确认过账账本完整」）。

缺字段的后果：`eval-flow.js` 的 `declarationsComplete` / `nodeDeclaration` 会直接判失败（退出码 1），
不会降级成警告。自检命令：

```bash
node tools/pad-robin/eval-flow.js business/tests/eval/<name>.cases.json
```

> `check.js` 只看生成后的 `.robin`，看不到 `flow.json` 字段；两项声明的门禁在 `eval-flow.js`。

### 4. 生成 flow.json
严格遵循结构（见 `docs/agent-prompts.md` 完整 schema）。关键点：
- `pad_hint`：KB 真实三段式 actionId
- `params`：键必须是该动作 `input_params` 的真实参数名
- `outputs`：要绑定的输出变量名数组
- `{{2.RetrievedEmails}}` 引用上游节点输出

### 5. 生成流程图
```bash
node tools/flow-drawio/flow-to-drawio.js business/flows/<name>.json business/flows/<name>.drawio
```

### 6. 回读改动
```bash
node tools/flow-drawio/drawio-to-flow.js business/flows/<name>.drawio business/flows/<name>.json business/flows/<name>.new.json
```
复述变更摘要，补齐手画新节点的 type/pad_hint，确认后说"可以交给 Agent B 了"。

## 约束
- pad_hint 必须是 KB 真实 actionId，不编造
- params 键必须是动作真实参数名
- 句柄类流程必须显式 Launch/Close
- 只生成 flow.json + 流程图，不生成 Robin 代码

## 流程卫生（会被 `check.js` / `lint-robin.js` 提示）

这三条与 PAD 设计器右上角「流检查器」同口径，离线就能看到，不必打开设计器：

| 规则 | 含义 | 设计时怎么做 |
|---|---|---|
| `unused-output` | 动作捕获了输出变量，但后续从未读取 | **只捕获要用的输出**；不用的写进节点的 `output_skip`（等同 PAD 里留空），别图省事全接 |
| `unused-var` | `SET` 声明了变量，但从未引用 | 派生路径只声明真正用到的；删掉模板残留 |
| `nested-if` | IF 嵌套超过 3 层 | 改成**守卫式提前退出**：整段包进 `LOOP 1 TO 1` 的一次性执行块，每个失败分支弹窗后直接 `EXIT LOOP`，后续步骤平铺在块内，不再写「IF 失败 ELSE 继续」的层层嵌套 |

> 一次性执行块的**索引变量要复用已有的那个**（例如轮询计数）：PAD 的 For 循环必须给一个变量，
> 另起 `StageIdx` 这类只用一次的变量，设计器的流检查器会报「未使用变量」。

单独检查：`node tools/pad-robin/lint-robin.js out.robin`

> 设计器里那条「应用修复」按钮**不要点**：它直接改画布，`flow.json` 不变，
> 下次生成就被覆盖，线上与仓库立刻漂移。修复一律回 `flow.json` 改，再重新生成。

## 准入红线（来自 business/policy.json，设计阶段就避开）
| 规则 | 禁止 / 条件 |
|---|---|
| `deny-close-outlook` | 任何 `Outlook.Close*` 动作 |
| `deny-email-in-dry-run` | `DRY_RUN=1` 时不得出现发信动作 |
| `deny-migo-in-dry-run` | `DRY_RUN=1` 时不得出现参数含 `%MigoVbsPath%` 的 `RunDOSCommand` |
| `deny-prod-auto-repair` | 生产环境禁止自动改写 `.robin` |
| `deny-write-outside-allowed-roots` | 只允许写 `PAD_ROOT` / 仓库工作区 / `TEMP` |

副作用（发信、过账、删文件）一律放进 `guard` 节点，条件 `DryRun <> $'''1'''`。
提交前跑一遍只读准入检查：
```powershell
.\tools\pad-sync\pad-admit.ps1 -FlowFile business/flows/<name>.json -ConfigFile business/config/<name>.json
```
