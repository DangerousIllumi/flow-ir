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

### 3. 生成 flow.json
严格遵循结构（见 `docs/agent-prompts.md` 完整 schema）。关键点：
- `pad_hint`：KB 真实三段式 actionId
- `params`：键必须是该动作 `input_params` 的真实参数名
- `outputs`：要绑定的输出变量名数组
- `{{2.RetrievedEmails}}` 引用上游节点输出

### 4. 生成流程图
```bash
node tools/flow-drawio/flow-to-drawio.js flows/<name>.json flows/<name>.drawio
```

### 5. 回读改动
```bash
node tools/flow-drawio/drawio-to-flow.js flows/<name>.drawio flows/<name>.json flows/<name>.new.json
```
复述变更摘要，补齐手画新节点的 type/pad_hint，确认后说"可以交给 Agent B 了"。

## 约束
- pad_hint 必须是 KB 真实 actionId，不编造
- params 键必须是动作真实参数名
- 句柄类流程必须显式 Launch/Close
- 只生成 flow.json + 流程图，不生成 Robin 代码

## 准入红线（来自 policy.json，设计阶段就避开）
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
.\tools\pad-sync\pad-admit.ps1 -FlowFile flows/<name>.json -ConfigFile config/<name>.json
```
