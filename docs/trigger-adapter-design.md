> 状态：设计基线 v1；trigger 断言、pad-admit 第 15 项、schedule/manual/file 注册器与 file 守望已落地，其余见第 7 节。

# 触发声明（`trigger`）与注册器设计稿（v1）

> 设计基线：`flow.json` 顶层已有 `trigger` 键（见 `docs/agent-prompts.md` 与 `tools/flow-drawio/example-flow.json`）。
> 在设计落地前它是**惰性字段**：生成器、`check.js` 不读取、不校验，`drawio-to-flow.js` 只是原样搬运；
> 现在 `eval-flow.js` 的 trigger 断言与 `pad-admit` 第 15 项会校验它。本设计**复用这个键，不另造第二套配置体系**，把它从“注释”升级为“可校验、可注册的声明”。

## 1. 为什么需要：三个具体问题

| 问题 | 现状证据 | 造成的后果 |
|---|---|---|
| **不可见** | 启动方式只存在于 `pad-schedule.ps1` 的命令行参数、计划任务列表、人的口头记忆 | 换人接手、换机器重建时，只能靠翻历史命令反推 |
| **不可校验** | `eval-flow.js` 只检查节点级 `run_mode`/`idempotent`；`pad-admit` 13 项里没有一项看触发 | “定时每天 09:00 跑”和“节点全 `run_mode=confirm`”可以同时存在而不报错 |
| **不可注册** | 注册逻辑散落在 `tools/pad-sync/pad-schedule.ps1`，只有 `-Daily/-Weekly`、`-LastWorkday` 两条路径，任务名靠 `Get-ScheduleTaskName` 临时推导 | 新增流程要人肉拼参数；重复注册靠 `-Force` 盲覆盖；注册完没有统一的“是否生效”验证 |

**边界**：`trigger` 只声明“怎么启动”，不替代 `budget`、不替代 `guard`、不描述流程步骤。注册是**本机操作系统层**的动作（Windows 计划任务 / 文件守望），**不新增任何 PAD 动作、不改 `.robin`**。

## 2. `flow.json` 的 `trigger` 块

### 2.1 字段

```json
"trigger": {
  "kind": "schedule",
  "task_name": "flow-ir-<计划任务名>",
  "time": "09:00",
  "days": ["mon", "tue", "wed", "thu", "fri"],
  "gate": "workday",
  "timeout_sec": 4200,
  "assisted": true
}
```

| 字段 | 必填 | 取值域 / 默认 | 说明 |
|---|---|---|---|
| `kind` | 是 | `manual` / `schedule` / `file` | 小写；其他值一律拒绝，不猜 |
| `task_name` | 否 | 默认由流程名派生：`flow-ir-` + 非法字符替换为 `_` | 显式给出时必须匹配 `^[A-Za-z0-9._-]{1,64}$`；须全局唯一 |
| `time` | `schedule`/`file` 必填 | `HH:mm`（24 小时制） | `schedule`：触发时刻；`file`：开始守望时刻 |
| `days` | 否 | 默认 `mon`–`fri`；取值 `mon..sun` | 不做节假日推断，节假日交给 `gate` |
| `gate` | 否 | `none` / `workday` / `last-workday`，默认 `none` | `workday`/`last-workday` 复用现有工作日历；日历不可用时硬失败，不猜测 |
| `timeout_sec` | 否 | 默认取运行时配置的 `RunTimeoutSec` | 与 `pad-schedule` 的 `-RunTimeoutSec` 同口径 |
| `assisted` | 否 | 布尔，默认 `false` | 语义：到点自动启动、中途有人确认。只在 `kind=schedule/file` 允许；`kind=manual` 出现即 `TRIGGER_INVALID`。`true` 时必须显式写 `timeout_sec`（否则 `TRIGGER_ASSISTED_NO_TIMEOUT`），没人点确认时靠超时告警兜底 |
| `file.dir` | `file` 必填 | 必须是 `{{config.<KEY>}}` 引用 | 禁止字面绝对路径，注册时用 `-ConfigFile` 解析 |
| `file.pattern` | `file` 必填 | glob，如 `*.xlsx` | 只做文件名匹配，不按修改时间判断新旧 |
| `file.poll_sec` | 否 | 默认 60，最小 15 | 轮询间隔 |
| `file.settle_sec` | 否 | 默认 60 | 连续两次轮询大小不变才认为落盘完成 |
| `file.max_wait_sec` | 否 | 默认 7200 | 守望上限；超时静默退出 0，不算失败 |
| `file.once_per_file` | 否 | 默认 `true` | 以“文件名+大小+最后写入时间”做本次标记，写入状态账本；不参与新旧文件挑选 |

`manual` 只允许 `{ "kind": "manual" }`，出现 `time`/`file`/`assisted` 等字段一律非法（避免“声明了但没人执行”）。

**旧形状迁移**：现有 `{ "type": "...", "config": {...} }` 视为遗留形状，报 `TRIGGER_LEGACY_SHAPE`（观察期 warn，迁移完成后改 fail），不做静默映射——`type: "event"` 与 `config.dayOfMonth` 无法可靠映射到 `kind`。

### 2.2 与现有字段的关系

| 现有字段 | 关系 |
|---|---|
| `budget` | 不同维度：`budget` 管循环上界，`trigger` 管启动时刻；不互相推导。`timeout_sec` 只是运行外壳超时，不改变预算判定 |
| `guard` | 无关。注册动作不碰业务数据，不需要 `DryRun` 守卫；`trigger` 块内不允许出现节点 id |
| 节点 `run_mode` | **交叉校验**：`kind != manual` 且存在 `run_mode=confirm` 节点时——`assisted=true` 判 **pass**（到点自动启动、中途有人确认，没人点时靠 `timeout_sec` 超时告警兜底）；`assisted` 缺失或 `false` 判 `TRIGGER_UNATTENDED_CONFIRM`（fail）。完全无人值守的流程等不到人工点确认 |
| 节点 `idempotent` / `reversible` | **交叉校验（可逆性口径）**：这两个字段是两个正交的轴——`idempotent` 管「同一输入重跑是否收敛」，`reversible` 管「已产生的后果能否撤回」。`kind != manual` 且存在 `reversible=false` 节点 → `TRIGGER_UNATTENDED_IRREVERSIBLE`（warn，证据列节点 id 与 `reversibility_note`）；节点 `idempotent=false` 但未声明 `reversible` → `TRIGGER_MISSING_REVERSIBILITY`（warn，要求补声明，不默认填充）。旧码 `TRIGGER_UNATTENDED_NONIDEMPOTENT` 仅作兼容别名保留，**不再由 `idempotent=false` 触发**（已收窄） |
| 自动重试 | `trigger` **不引入重试**：错过时刻不补跑，失败不重触发；与全链路“告警 + 人工重跑”口径一致 |

### 2.3 合法示例

```json
{
  "name": "<流程名>",
  "trigger": {
    "kind": "schedule",
    "task_name": "flow-ir-<计划任务名>",
    "time": "09:00",
    "days": ["mon", "tue", "wed", "thu", "fri"],
    "gate": "workday",
    "timeout_sec": 4200
  },
  "budget": { "maxLoop": 3 },
  "nodes": [ ... ]
}
```

### 2.4 非法示例

**例 A —— 不支持的 kind**

```json
"trigger": { "kind": "mail", "task_name": "flow-ir-<计划任务名>" }
```

违反：`kind` 取值域只有 `manual/schedule/file`。报 `TRIGGER_KIND_UNSUPPORTED`（fail）。v1 没有邮件注册器，写 `mail` 会变成“声明了但永远不注册”，必须当场拒绝。

**例 B —— 字面路径 + 无人值守确认节点**

```json
"trigger": {
  "kind": "file",
  "time": "08:30",
  "file": { "dir": "<附件目录>", "pattern": "*.xlsx" }
},
"nodes": [
  { "id": "9", "pad_hint": "Outlook.SendEmailThroughOutlook.SendEmail", "run_mode": "confirm", ... }
]
```

违反两条：
1. `file.dir` 是字面绝对路径，未用 `{{config.<KEY>}}` → `TRIGGER_PATH_LITERAL`（fail）。注册器无法在别的机器上复用，且违反“外部参数从配置读取”。
2. `kind=file` 且未声明 `assisted=true` + 节点 `run_mode=confirm` → `TRIGGER_UNATTENDED_CONFIRM`（fail）。文件落地触发时没有人在旁边点确认；若确实“中途有人确认”，须显式写 `assisted: true` 且给出 `timeout_sec`。

**例 C —— 缺必填项**

```json
"trigger": { "kind": "schedule" }
```

违反：`schedule` 缺 `time` → `TRIGGER_INVALID`（fail）。**不默认 09:00**，因为“默认时间”就是不可见的口头约定。

## 3. 注册器接口（MVP 两个）

### 3.1 `schedule`（Windows 计划任务）

| 项 | 设计 |
|---|---|
| 输入 | `flow.json`（含 `trigger`）+ `-ConfigFile`（解析 `{{config.*}}` 与超时默认值）+ `-AllowProd` |
| 生成动作 | 复用现有 `pad-schedule.ps1` 的动作构造（`run-hidden.vbs` 包装 `powershell`，`-LogonType Interactive`，`-MultipleInstances IgnoreNew`），不新造启动方式 |
| 幂等键 | `task_name` + 规范 JSON 的 SHA256（`specHash`）；写入任务描述前缀 `flow-ir-spec:<specHash>` |
| 重复注册 | 任务存在且 `specHash` 一致 → 返回 `unchanged`，不写系统；不一致 → `Register-ScheduledTask -Force` 后回读校验 |
| 验证生效 | ① `Get-ScheduledTask` 存在；② 回读描述中的 `specHash` 一致；③ 动作参数含正确的 `-FlowName`；④ `Get-ScheduledTaskInfo.NextRunTime` 非空且晚于当前时刻；⑤ `LastTaskResult` 不参与“注册是否生效”判定（它属于运行结果） |
| 失败行为 | **硬失败**（退出码 1），写 `trigger-register-failed` 告警；不做“注册失败但继续部署”的降级 |

### 3.2 `file`（文件落地）

| 项 | 设计 |
|---|---|
| 输入 | 同 `schedule`，另需 `file.dir` 解析结果必须存在且可读（只读探测，不写探针文件） |
| 运行形态 | 注册一个计划任务，到 `time` 启动 `pad-trigger.ps1 -Watch`；守护进程内部按 `poll_sec` 轮询，命中后调用**现有** `pad-sync.ps1 -RunOnly -AllowProd -NonInteractive`。不引入新运行入口 |
| 幂等 | ① 注册层：同上 `specHash`；② 运行层：状态账本 `<状态目录>/<计划任务名>.json` 记录 `fileName|size|lastWriteUtc`，同一文件只触发一次 |
| 验证生效 | ① 任务存在且 `specHash` 一致；② `file.dir` 可读、`pattern` 能匹配到 0 或 1 个候选（多候选按“取最新”属于猜测，v1 不做，直接 `TRIGGER_FILE_AMBIGUOUS` fail）；③ 状态账本目录可写；④ `NextRunTime` 非空 |
| 失败行为 | **硬失败**（退出码 1）+ `trigger-register-failed` |

### 3.3 统一函数签名草案

```powershell
# tools/pad-sync/TriggerRegistry.psm1（新增）

# 读取并规范化 trigger 块；非法时抛出带 Data['code'] 的异常（与 PadConfig 同风格）
function Get-TriggerSpec {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
}

# 规范 JSON（键排序、无空白）的 SHA256，作为幂等键
function Get-TriggerFingerprint {
    param([Parameter(Mandatory)]$Spec)
}

# 统一入口：按 kind 分发；返回 [ordered]@{ ok; kind; taskName; action; specHash; evidence }
function Register-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun,
        [switch]$AllowProd
    )
}

# 只读验证：不写系统、不建目录、不触发运行
function Test-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
}

function Unregister-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun
    )
}

# ---- 内部按 kind 拆分，便于 Pester 单测 ----
function Register-ScheduleTrigger { param($Spec, [switch]$DryRun, [switch]$AllowProd) }
function Test-ScheduleTrigger     { param($Spec) }
function Unregister-ScheduleTrigger { param($Spec, [switch]$DryRun) }
function Register-FileTrigger     { param($Spec, [switch]$DryRun, [switch]$AllowProd) }
function Test-FileTrigger         { param($Spec) }
function Unregister-FileTrigger   { param($Spec, [switch]$DryRun) }
```

CLI 外壳：

```powershell
# tools/pad-sync/pad-trigger.ps1（新增）
# .\pad-trigger.ps1 -FlowFile business\flows\<流程名>.json -ConfigFile business\config\<流程名>.json -Register -AllowProd
# .\pad-trigger.ps1 ... -Test
# .\pad-trigger.ps1 ... -Unregister
# 末行输出 PAD_TRIGGER_RESULT=<JSON>；退出码 0 成功 / 1 失败 / 2 输入错误
```

**任务名冲突**：注册前按 `task_name` 反查现有任务，若描述里的流程标识与本次不同 → `TRIGGER_AMBIGUOUS`（fail），不覆盖。

## 4. 校验落点

### 4.1 `eval-flow.js`

它没有结果码体系，断言失败即整体退出码 1。新增两个断言操作，不改现有 `OPS` 语义：

| 断言 op | 查什么 | 失败表现 |
|---|---|---|
| `trigger` | 按 `kind` 校验必填项、取值域、`time` 格式、`file.dir` 是否为 `{{config.*}}` | 该条用例 fail，退出码 1 |
| `triggerComplete` | `trigger` 存在且 `kind` 合法（等价于“触发已声明”门禁） | 同上 |

`check.js` **不改**：它只看 `.robin`，看不到 `flow.json` 顶层字段，这已是既有共识。

### 4.2 `pad-admit` 第 15 项 `TRIGGER`

静态校验 + 可选的本机只读校验（`-TriggerLive` 开关，默认关闭，保证离线生成阶段结果可复现）。

| 结果码 | 判级 | 触发条件 |
|---|---|---|
| `TRIGGER_MISSING` | warn（观察期，`$script:TriggerMode = 'warn'`；存量流程迁移完成后单独提交改 fail） | 无 `trigger` 块 |
| `TRIGGER_LEGACY_SHAPE` | warn | 只有旧 `type/config`，没有 `kind` |
| `TRIGGER_UNKNOWN_KIND` | **fail** | `kind` 不在 `manual/schedule/file` |
| `TRIGGER_KIND_UNSUPPORTED` | **fail** | `kind` 写 `mail`/`callback` 等保留值 |
| `TRIGGER_INVALID` | **fail** | 缺必填、`time` 非 `HH:mm`、`days` 非法、`pattern` 为空、`assisted` 非布尔、`manual` 声明 `assisted` |
| `TRIGGER_ASSISTED_NO_TIMEOUT` | **fail** | `assisted=true` 但未显式声明 `timeout_sec` |
| `TRIGGER_PATH_LITERAL` | **fail** | `file.dir` 是字面路径，未用 `{{config.<KEY>}}` |
| `TRIGGER_UNATTENDED_CONFIRM` | **fail** | `kind != manual` 且存在 `run_mode=confirm`，且未声明 `assisted=true` |
| `TRIGGER_UNATTENDED_IRREVERSIBLE` | warn | `kind != manual` 且存在 `reversible=false` 节点（后果不可回退） |
| `TRIGGER_MISSING_REVERSIBILITY` | warn | 节点 `idempotent=false` 但未声明 `reversible` |
| `TRIGGER_UNATTENDED_NONIDEMPOTENT` | warn（兼容别名，**已收窄**） | 保留名称供存量用例引用；不再由 `idempotent=false` 触发 |
| `TRIGGER_NO_GATE` | warn | `kind=schedule` 且 `gate=none`（节假日会误跑） |
| `TRIGGER_NOT_REGISTERED` | warn（仅 `-TriggerLive`） | 本机查不到对应计划任务 |
| `TRIGGER_DRIFT` | **fail**（仅 `-TriggerLive`） | 任务存在但 `specHash`/动作参数与声明不一致 |
| `TRIGGER_AMBIGUOUS` | **fail** | `task_name` 已被其他流程占用 |

观察期策略与指纹一致：`pad-admit.ps1` 顶部已有 `$script:FingerprintMode = 'warn'` 的做法，照搬为 `$script:TriggerMode = 'warn'`，不改默认行为、不打断存量流程。

## 5. 与告警收口的关系

告警记录 schema 以 `tools/pad-sync/pad-schedule.ps1` 的 `Write-RunAlert` 为准：`ts / kind / flow / exitCode / stage / status / errorCode / error / logPath / acceptance / note`（可选 `reason`）。

新增 kind 只加两个，运行时触发失败继续复用已有 `trigger-failed`：

| kind | stage | status | 用途 |
|---|---|---|---|
| `trigger-register-failed` | `register` | `failed` | 注册/回读校验失败；`reason` 填结果码（如 `TRIGGER_DRIFT`） |
| `trigger-unregister-failed` | `unregister` | `failed` | 注销失败 |
| `trigger-failed`（已有） | `trigger` | `failed` | 触发后无运行证据；沿用 `reason = identity-mismatch / no-evidence / no-robot` |

新增可选字段：`triggerKind`、`taskName`、`specHash`。

**复用方式**：`pad-trigger.ps1` 不自己实现一套 JSONL 写入。若正在进行的“直调路径告警”改动把告警写入抽成公共函数/模块，`pad-trigger` 直接调用它（`-Stage 'register' -Status 'failed'`）；在该改动落地前，`pad-trigger` 按同一 schema 直写，字段与 kind 完全对齐，避免出现第二套 kind 词表。

## 6. 第一版明确不做

| 不做项 | 理由 | 再进的条件 |
|---|---|---|
| **Outlook 规则触发** | 规则存在客户端邮箱配置里，不在仓库、不可评审；注册/验证要走 Outlook 对象模型和邮箱凭据；规则触发本地协议链接易造成重复触发与漏触发，且无法用 `Test-*` 做“不真跑”的验证 | 存在本机、只读可验证的规则注册接口（能导出规则定义做 diff），且触发入口带幂等令牌，公开层无需出现邮箱地址 |
| **云回调 / callback** | 依赖云端环境、连接凭据与公网可达端点；本仓库工具全部是本机只读工具链，无法离线验证注册是否生效；还涉及重放攻击与幂等设计，超出 MVP | 已有受控的云端连接与回调注册 API，并能提供“注册后只读回查”的验证手段，同时定义重放保护 |
| URL 协议触发单独注册 | `ms-powerautomate` 协议由 `pad-sync` 内部调用，属于执行手段而非启动声明，`manual` 已覆盖 | 需要第三方系统直接拉起时才单列 |
| 错过补跑 / 自动重试 | 与全链路“告警 + 人工重跑”口径冲突 | 不计划引入 |

## 7. 落地顺序（4 步，每步可验收）

**规模**：新增 4 个文件（`TriggerRegistry.psm1`、`pad-trigger.ps1`、`tests/trigger-registry.Tests.ps1`、`tests/eval/trigger.cases.json`）+ 2 个用例 fixture（`tests/eval/fixtures/trigger-*.json`，测试数据）+ 2 处校验改动（`eval-flow.js`、`pad-admit.ps1`）。守望逻辑并入 `pad-trigger.ps1 -Watch`，不单开第 5 个文件。

| 步骤 | 内容 | 验收命令与判据 |
|---|---|---|
| 1 声明层 | `trigger` 规范 + `eval-flow.js` 两个新 op + 正/反用例 | `node tools\pad-robin\eval-flow.js tests\eval` 退出 0；反例用 `expect=invalid` + `code` 断言命中 `TRIGGER_*`（整套仍绿）；把反例改成默认“期望合法”时退出 1 并打印结果码 |
| 2 准入层 | `pad-admit` 第 15 项 `TRIGGER`，默认 warn | `.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<流程名>.json -Json` 输出含 `"id":"TRIGGER"`；无 `trigger` 的存量流为 warn 且退出码不变；`kind=mail` 的样例退出 1 |
| 3 计划任务注册器 | `TriggerRegistry.psm1` + `pad-trigger.ps1`（schedule） | `-Register -DryRun` 只打印动作不写系统；真注册到 `flow-ir-<计划任务名>-selftest` 后 `-Test` 返回 `ok=true`；`schtasks /Query /TN <计划任务名> /XML` 中时间/星期与声明一致；再注册一次返回 `unchanged`；`-Unregister` 后 `-Test` 返回未注册 |
| 4 文件落地注册器 | `file` 分支 + `-Watch` + 状态账本 | 指向临时 `<附件目录>` 注册；投放一个稳定大小的探针文件 → 出现新 runId；再投放同名同大小文件 → 不重复触发；`-Test` 全程只读（目录 mtime 不变） |

每步结束都跑一次 `node tools\pad-robin\check.js <out.robin>` 与 `pad-admit`，确认没有把既有检查项弄红。

---

## 待验证清单

| # | 待验证项 | 验证方法 | 不确定点 |
|---|---|---|---|
| 1 | 计划任务描述长度是否够放 `flow-ir-spec:<hash>` | 注册后 `schtasks /Query /XML` 回读描述全文 | Task Scheduler 描述上限与截断行为 |
| 2 | `Register-ScheduledTask -Force` 失败时是否保留旧任务 | 故意传非法动作参数注册，比对注册前后任务 XML | 失败是否为原子操作 |
| 3 | `Get-ScheduledTaskInfo.NextRunTime` 对“仅工作日”任务的含义 | 注册后连续两天观察 `NextRunTime` | `-Weekly` 与 `-Daily+gate` 两种形态的显示差异 |
| 4 | 文件守望能否在 PAD 控制台未打开时拉起流程 | 关闭控制台后投放探针文件，观察 `pad-sync` 的 `trigger-failed` 分类 | 协议处理器是否需要控制台常驻 |
| 5 | 状态账本用 `lastWriteUtc` 是否会被复制操作改写 | 复制同一文件两次，观察账本是否误判 | 仅用于“同一文件去重”，不用于新旧挑选 |
| 6 | `{{config.<KEY>}}` 解析是否要扩展 `PadConfig.psm1` 的固定键集 | 用含自定义键的配置跑 `-Register -DryRun` | 现有模块只认 6 个固定键，可能需要只读解析而非改模块 |
| 7 | `-TriggerLive` 查询计划任务在无权限账户下的表现 | 标准用户身份执行 `-Test` | 是否返回空而非报错，需明确降级为 `TRIGGER_UNKNOWN` 还是硬失败 |
| 8 | 旧 `type/config` 形状的实际存量数量 | 只读扫描 `business/flows/*.json` 中 `trigger.type` 出现次数 | 决定 `TRIGGER_LEGACY_SHAPE` 观察期长度 |
