# 准入网关检查清单（草案）

> 目标：在生成、部署、运行之前，用确定性检查器判断“这份流程/这次运行是否被允许”。
> 参考 GraphARC 的 admission gate 思路，但只保留适合 PAD RPA 的部分。

## 1. 不变量

1. **检查期间不执行任何动作**：不启动 PAD、不连 SAP、不发邮件、不写产物。
2. **一次返回全部问题**：所有检查都跑完，不因第一条失败提前退出。
3. **不降级、不截断**：不允许“删掉一半分支先跑”，不允许把被拒的边降级为允许。
4. **每条失败带证据**：`code` + 人话 + 具体节点/参数/行号。
5. **批准绑定指纹**：只有与当前 `robin + config + acceptance` 哈希绑定的批准才有效。
6. **无人值守时 ask = deny**：定时任务没有人工，遇到 `ask` 一律阻断。

## 2. 检查项

| # | 检查 | 输入 | 通过条件 | 失败码 | 现有实现 |
|---|---|---|---|---|---|
| 1 | REGISTRY | `flow.json` 节点的 `pad_hint` | 每个动作都存在于 KB | `UNKNOWN_ACTION` | `flow-to-robin.js` 安全闸门 |
| 2 | ARGS | 节点 `params` | 参数名存在、必填项齐全、类型符合 | `UNKNOWN_PARAM` / `MISSING_PARAM` / `TYPE_MISMATCH` | `flow-to-robin.js` |
| 3 | SELECTOR | 动作元数据 | 需要 UI 选择器的动作必须显式白名单 | `UI_SELECTOR` | `flow-to-robin.js` |
| 4 | STATIC | `.robin` | `check-flows.js` 0 errors | `STATIC_SYNTAX` | `tools/pad-robin/check.js` |
| 5 | EDGE | `flow.json` | `edges` 覆盖 `next/branch` 推导、无悬空/重复 | `EDGE_DRIFT` / `EDGE_DANGLING` / `EDGE_DUPLICATE` | `tools/flow-drawio/check-flow.js` |
| 6 | BOUNDED | `flow.json` | 循环有明确上界，无无界 `LOOP WHILE` | `UNBOUNDED_LOOP` | 部分（人工检查） |
| 7 | POLICY | `business/policy.json` + 运行上下文 | 无 `deny`；`ask` 有有效批准 | `POLICY_DENY` / `POLICY_ASK` | 新增 |
| 8 | BUDGET | 预算声明 + 预检结果 | 最坏情况在预算内；未声明按超限处理 | `BUDGET_EXCEEDED` / `BUDGET_UNKNOWN` | `pad-admit.ps1`（`flow.budget`，未声明即 fail） |
| 9 | ACCEPTANCE | `*.acceptance.json` | JSON 合法、检查类型已知、占位符可解析 | `ACCEPTANCE_INVALID` | `PadAcceptance.psm1` |
| 10 | CONFIG | `business/config/*.json` + schema | schema 校验通过 | `CONFIG_INVALID` | `pad-deploy.ps1` |
| 11 | PREFLIGHT | 机器环境 | PAD/Python/SAP/Outlook/目录齐全 | `PREFLIGHT_MISSING` | `PadPreflight.psm1` |
| 12 | FINGERPRINT | 三个文件的 SHA256 + 基线 | 与批准记录或 `business/fingerprints/<流程名>.json` 一致 | `pass` / `FINGERPRINT_*`（见 2.1） | `PadFingerprint.psm1`（默认 fail，指纹不一致即阻断） |
| 13 | INTENT | 节点 `intent` / `tags` | `RunDOSCommand`、`RunVBScript` 这类通用动作必须有语义标签，策略按标签匹配 | `MISSING_INTENT` | `pad-admit.ps1`（缺 intent 即 fail；策略支持 `when.intent`） |
| 14 | TRIGGER | `flow.json` 的 `trigger` 块 | kind 取值域、必填字段、目录必须走配置引用、无人值守不得要求人工确认 | `TRIGGER_*`（见 2.2） | `pad-admit.ps1`（观察期未声明记 warn） |
| 15 | INPUT | 节点级 `inputs` 声明 + `config` | 目录必须走配置引用；`required` 显式声明；必需文件 0 候选即失败；候选 ≥2 一律判歧义 | `INPUT_*`（见 2.3） | `pad-admit.ps1`（未声明记 warn，向后兼容） |

### 2.1 指纹（FINGERPRINT）结果码

机制全部在 `tools/pad-sync/PadFingerprint.psm1`，对所有 `flow.json` 一视同仁；
基线数据只在业务层 `business/fingerprints/<流程名>.json`（含流程名、flowGuid、environmentId、
机器名与真实路径），不入库、不进公开层。

| 结果码 | 含义 | 证据字段 `evidence` |
|---|---|---|
| `pass` | 与批准记录或基线一致 | 命中的批准记录/基线路径 |
| `FINGERPRINT_MISMATCH` | 与批准记录不一致（始终 fail） | `approve=` + 当前三哈希 |
| `FINGERPRINT_UNKNOWN` | 读不到 `.robin`、解析不到流程身份，或环境/机器与基线不符 | `robin=` / `scriptsRoot=` / 身份差异 |
| `FINGERPRINT_NO_BASELINE` | 还没有基线（存量流未播种） | `baseline=` + 当前三哈希 |
| `FINGERPRINT_FLOW_STALE` | 基线对应的 flowGuid 已变化 | 基线与当前 flowGuid |
| `FINGERPRINT_SOURCE_MISMATCH` | 源 `.robin` 与基线不一致 | 基线路径 + 当前/基线哈希前缀 |
| `FINGERPRINT_CONFIG_STALE` | 部署配置与基线不一致 | 同上 |
| `FINGERPRINT_BASELINE_CORRUPT` | 基线 JSON 损坏或缺 `flow`/`hashes.robin` | `baseline=` |
| `AMBIGUOUS` | Workspace 命中多个候选修订，无法确定本次发布对应哪一份 | 候选修订目录名 |

### 2.2 触发声明（TRIGGER）结果码

机制在设计稿 `docs/trigger-adapter-design.md` 中定义；本项只做**静态**校验，不查本机计划任务注册状态。

| 结果码 | 判级 | 含义 |
|---|---|---|
| `TRIGGER_MISSING` | warn（观察期） | 没有 `trigger` 块，启动方式仍靠口头约定 |
| `TRIGGER_LEGACY_SHAPE` | warn（观察期） | 只有旧 `type/config`，没有 `kind` |
| `TRIGGER_UNKNOWN_KIND` | fail | `kind` 不在 `manual/schedule/file` |
| `TRIGGER_KIND_UNSUPPORTED` | fail | `kind` 是保留值（`mail`/`callback`），v1 无注册器 |
| `TRIGGER_INVALID` | fail | 缺必填、`time` 非 `HH:mm`、`days`/`gate` 非法、`file.pattern` 为空、`assisted` 非布尔或 `manual` 声明 `assisted` |
| `TRIGGER_ASSISTED_NO_TIMEOUT` | fail | `assisted=true` 但未显式声明 `timeout_sec` |
| `TRIGGER_PATH_LITERAL` | fail | `file.dir` 写死路径，未用 `{{config.<KEY>}}` 引用 |
| `TRIGGER_UNATTENDED_CONFIRM` | fail | 非 `manual` 触发且存在 `run_mode=confirm` 节点，但未声明 `assisted=true` |
| `TRIGGER_UNATTENDED_IRREVERSIBLE` | warn | 非 `manual` 触发且存在 `reversible=false` 节点（后果不可回退）；证据列节点 id 与 `reversibility_note` |
| `TRIGGER_MISSING_REVERSIBILITY` | warn | 节点 `idempotent=false` 但未声明 `reversible`，要求补声明（不默认填充） |
| `TRIGGER_UNATTENDED_NONIDEMPOTENT` | warn（兼容别名，**已收窄**） | 仅当存量用例/调用方仍引用旧码时保留名称；判定不再由 `idempotent=false` 触发，改由上面两条可逆性规则触发 |
| `TRIGGER_NO_GATE` | warn | `schedule` 未声明 `gate`，节假日会照跑 |
| `TRIGGER_AMBIGUOUS` | fail | 任务名已被 `business/flows` 下其他流程占用 |
| `TRIGGER_NOT_REGISTERED` | warn | 仅 `-TriggerLive`（本次未实现） |
| `TRIGGER_DRIFT` | fail | 仅 `-TriggerLive`（本次未实现） |

切换顺序：先让存量流程补齐 `trigger`，观察期 `$script:TriggerMode` 保持 `warn`，
确认无漏报后再单独提交改为 `fail`。

切换顺序（硬要求）：先上线写入侧（`pad-release` / `pad-rollback`）与
`pad-fingerprint.ps1 -Set`，把存量流基线播种出来，初始级别保持 warn；
等真实运行观察无误后，再单独提交把 `pad-admit.ps1` 里的 `$script:FingerprintMode` 改为 `fail`。
本机已完成播种并切换为 fail。
播种必须人工确认：`-Set` 只打印定位结果（修订目录、Workspace 路径、mtime、三个哈希），
加 `-Confirm` 才写；`-DryRun` 永远不写；多候选直接报 `AMBIGUOUS` 停下。

### 2.3 输入文件声明（INPUT）结果码

节点级 `inputs` 声明回答「第 N 步只检查第 N 步需要的输入文件」，用于**准入与结构校验**。
字段：`dir`（必须是 `{{config.<KEY>}}`）、`pattern`（文件名通配符）、`required`（显式布尔）。
**该能力不改变 `.robin` 生成产物**：`flow-to-robin.js` 不读取 `inputs`，也不会把它写进脚本；
`eval-flow.js` 只校验声明形状，目录可读与候选计数由本项在准入时只读核对。

| 结果码 | 判级 | 含义 |
|---|---|---|
| `INPUT_UNDECLARED` | warn | 没有任何节点声明 `inputs`（存量流程兼容，只提示） |
| `INPUT_INVALID` | fail | `inputs` 不是非空数组、条目不是对象、缺 `dir`/`pattern`、`required` 未显式声明 |
| `INPUT_PATH_LITERAL` | fail | `dir` 写死字面路径，未用 `{{config.<KEY>}}` 引用 |
| `INPUT_CONFIG_UNRESOLVED` | fail | 未提供 config、配置缺键或值为空，目录无法解析（不退回字面路径） |
| `INPUT_DIR_UNREADABLE` | fail | 必需输入的目录不存在或不可读 |
| `INPUT_FILE_MISSING` | fail | 必需输入在目录里 0 个候选 |
| `INPUT_FILE_AMBIGUOUS` | fail | 候选 ≥2，一律判歧义，**绝不「取最新」**；可选输入同样适用 |

判定分级说明：
- 未声明只提示（warn），保住存量 `flow.json` 的向后兼容；
- 一旦声明，形状/配置/文件核对一律 fail-closed：宁可阻断，也不假装核对过；
- `required=false` 只放宽「0 候选」，不放宽「多候选」（多候选仍是歧义）。

## 3. 执行阶段

| 阶段 | 跑哪些检查 | 触发点 |
|---|---|---|
| 离线（生成前） | 1–6、9、10、14 | `pad-admit` / `flow-to-robin` / CI |
| 运行前 | 7、8、11、12、15 | `pad-sync` 注入前 |
| 运行后 | 验收判据 | `pad-sync` 运行后（G6） |

## 4. 输出契约

```json
{
  "ok": false,
  "flow": "sample-report",
  "fingerprint": "sha256:...",
  "checks": [
    {
      "id": "EDGE",
      "status": "fail",
      "code": "EDGE_DRIFT",
      "message": "旧结构有 1 条边没写进 edges",
      "evidence": ["34 -> 35"]
    },
    {
      "id": "POLICY",
      "status": "ask",
      "code": "POLICY_ASK",
      "message": "生产部署需要操作员确认",
      "evidence": ["ask-prod-deploy"]
    }
  ]
}
```

退出码：

| 码 | 含义 |
|---|---|
| 0 | 全部通过 |
| 1 | 存在 `fail` |
| 2 | 仅存在 `ask`（等待批准，不等于失败） |

## 5. 策略评估语义

- 评估顺序固定：**deny → ask → allow**。
- 同一层内按 `business/policy.json` 的书写顺序取第一条命中。
- 全部未命中时按 `defaultEffect`（当前为 `deny`）。
- `match` 匹配动作 kind（`pad_hint`）或工具名，**不匹配节点 id/label**，改名不能绕过。
- 通用动作（`Scripting.RunDOSCommand` / `RunVBScript`）建议给节点加 `intent`（如 `sap-migo`），策略按 `intent` 匹配；否则只能靠参数里的变量名（如 `%MigoVbsPath%`）识别，变量改名就失效。
- `when.env`：`PAD_SYNC_TEST` = `test`，其余 = `prod`。
- `when.dryRun`：取 config 的 `DRY_RUN`。
- `when.paramsMatch`：对动作参数做 glob 匹配（如 MIGO 的 `DOSCommandOrApplication`）。
- `ask` 必须带 `approver`；无人值守场景按 `deny` 处理。

## 6. 预算草案（本流程）

| 项 | 上限 | 依据 |
|---|---|---|
| 轮询次数 | 7 | `.robin` 的 `LOOP 1 TO 7` |
| 单次运行时长 | 75 分钟 | 6 次 `WAIT 600`（60 分钟）+ MIGO/MB51/核对约 5–15 分钟 |
| MIGO 过账行数 | `migo_plan.json` 的待过账行数 | 执行前预检 |
| 发送邮件 | 1 封 | 催办分支 |
| 报表附件 | 1 个（按报表文件名匹配） | 签名内联图片不计数 |
| 业务产物修改 | 报表、MB51 导出、过账账本 | 不含附件目录里的签名图片 |

任一预算无法从预检得到时，按 `BUDGET_UNKNOWN` 拒绝，不按“默认安全”放行。

> **超时口径**：已统一为 4200 秒（`pad-schedule`、`pad-release`、`pad-deploy`）；`pad-sync` 的测试默认仍为 300 秒。快速验证时可以显式传更小的 `-RunTimeoutSec`。

## 7. 明确不检查的内容（Limits）

- 静态检查不能证明业务逻辑正确。
- 验收判据只检查产物，不证明 SAP 凭证、金额、批次在业务上正确。
- 策略只约束 PAD 动作与工具入口，**管不到 VBS 内部**的 SAP 操作和文件写入。
- `resource: artifact` 的允许根由网关解析：`{{PAD_ROOT}}`、`{{REPO_ROOT}}`、`{{TEMP}}`；不在这些根下的写入一律拒绝。
- **保存附件动作会把邮件签名里的内联图片一起落盘，数量不可控**；预算与验收不能按“文件个数”判断业务完整性，只能按报表文件名匹配。
- 不做运行时动态重新规划：业务步骤必须固定，模型不能临场加步骤。

## 8. 落地顺序

1. **只读版**：新增 `pad-admit.ps1`，跑完 14 项只输出报告，不阻断任何现有流程。
2. **接入**：把 `pad-sync` 注入前、`pad-deploy` 部署前改为硬门禁。
3. **披露**：把 `business/policy.json` 的 deny 规则渲染成清单，放进 Agent A 的设计提示词，减少无效设计。
4. **指纹批准**：确认框显示三个哈希，发布前复核，支持“批准记录”文件。

## 9. 推送前门禁（public-safe）

> 这是「推送公开库」流程的第 0 步，与 `pad-admit` 同级：`pad-admit` 判断流程能不能跑，
> 本门禁判断**这些文件能不能推**。按文件名白名单放行不够——文件本身合规，注释里的业务名、
> 真实路径仍会泄漏，所以这一层拦的是**内容**。

### 9.1 跑法

```powershell
# 在 PowerShell 里直接调用（-Files 是数组，相对仓库根或绝对路径均可）
.\tools\publish\check-public-safe.ps1 -Files @(
  'tools\pad-sync\pad-sync.ps1',
  'docs\admission-gate.md'
) -Verbose

# 需要子进程时用 -Command，数组表达式才会被求值（-File 会把 @(...) 当字面量拆开）
powershell -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\tools\publish\check-public-safe.ps1' -Files @('tools\pad-sync\pad-sync.ps1','docs\admission-gate.md') -Verbose"
```

- 每条命中输出一行 `文件:行号:命中词`（走 `Write-Output`，可直接管道处理）；
- `-Verbose` 打印词表来源、每个文件的编码判定、二进制文件提示；`-Quiet` 只输出命中行；
- 退出码：`0` 全部干净；`1` 有命中；`2` 门禁自身出错（清单为空、文件不存在、词表缺失或没有启用规则）。

### 9.2 词表

| 文件 | 作用 |
|---|---|
| `tools/publish/public-safe.denylist.json` | 入库的结构化规则：UNC 路径、PAD 根目录、内网域名后缀、邮箱/手机号；**只放占位与正则，不含真实业务字样** |
| `tools/publish/public-safe.denylist.local.json` | 本地覆盖：真实业务名、真实流程名、真实路径、账号；已被 `.gitignore` 忽略，脚本自动合并 |

- **敏感信息声明**：词表本身即敏感信息。`public-safe.denylist.local.json` 的真实版本仅存在于本机、不入库，**永远不得推送到公开库**。
- 规则字段：`id`、`pattern`、`regex`（false 为字面量、true 为正则）、`caseSensitive`（默认 false）、`enabled`（默认 true）、`reason`；分类由 `categories` 的键给出（`businessName` / `realPath` / `flowName` / `accountOrServer` / `privateIdentifier`）。
- 路径、主机名、账号这类写不全的模式用正则；具体业务词用字面量（脚本会自动转义，避免正则元字符误伤）。

### 9.3 失败后的处置

1. 按 `文件:行号` 回到源码定位；
2. 业务名改写为通用说法（“示例流程”“长时间 SAP 下载”），真实路径改为占位符（如 `<PAD_ROOT>`）；
3. **不要删词、不要注释掉命中行、不要放宽整条词表**；
4. 确属误报时改结构化规则（例如把匹配范围收窄到具体目录前缀），并在提交说明里写清原因；
5. 重跑到退出码 0，再进入原有推送步骤。

### 9.4 业务目录是「绝不入库」区

`business/` 被 `.gitignore` 整体忽略，`git status --short` 不会显示其中的文件；
推送门禁还会做一道硬拦截：任何被列入 `-Files` 的 `business/` 路径直接判错（退出码 `2`），
不会静默跳过，避免「把业务文件当候选推上去」这类不可见风险。

### 9.5 我是 clone / fork 的用户，业务文件放哪里？

1. **放哪里**：真实流程、配置、内部文档、日志、产物统一放进仓库根的 `business/` 子目录，
   例如 `business/flows/my-flow.json`、`business/config/my-flow.json`。
   生成器、部署脚本的默认路径也都是按 `business/` 约定的。
2. **为什么传不上去**：`.gitignore` 有一行 `business/`，Git 默认忽略整个目录；
   即使你手动 `git add -f`，推送前的 `check-public-safe.ps1` 也会以退出码 `2` 拒绝。
3. **怎么确认**（在仓库根依次执行，可直接抄）：

```powershell
# ① 造一个假业务文件做验证（验证完删掉）
'{"demo":true}' | Set-Content business\flows\_ignore-probe.json -Encoding UTF8

# ② git status 不应出现它
git status --short

# ③ 忽略规则应命中 business/ 这一行
git check-ignore -v business\flows\_ignore-probe.json

# ④ 推送门禁应直接拒绝（退出码 2，而不是 0/1）
.\tools\publish\check-public-safe.ps1 -Files 'business\flows\_ignore-probe.json'
$LASTEXITCODE   # 期望 2

# ⑤ 清理探针
Remove-Item business\flows\_ignore-probe.json
```

> 退出码说明：`0` = 可以推；`1` = 内容命中真实业务词；`2` = 门禁自身拒绝（含业务目录、清单缺失、词表故障）。
> 只要不是 `0`，就停下来，不要把文件硬加进暂存区。

### 9.6 拦不住的场景

- 运行时才拼接的业务名（字符串分段拼接）或编码后的内容（base64、压缩包、加密载荷）；
- 只在运行时生成、词表里没有登记的路径与账号；
- 词表尚未收录的新业务词——门禁只能拦已知模式，不能推断语义；
- 二进制文件只按 Latin1 扫 ASCII 类规则（`-Verbose` 会标注 `binary`），中文业务词可能漏掉。

结论：本门禁是**降低泄漏概率**的确定性检查，不是内容脱敏的替代品；公开库仍应按最小文件集推送。

### 9.7 自动闸门与覆盖边界

**拦截点**

| 层 | 位置 | 扫描对象 | 命中后果 |
|---|---|---|---|
| 提交边界（唯一真正拦截） | `.githooks/pre-commit` → `.githooks/pre-commit.ps1` | 暂存区快照（`git checkout-index` 导出） | 非零退出，提交被拒绝 |
| CI 兜底 | `.github/workflows/ci.yml` 的 public-safe 步骤 | 仓库已跟踪文件（`git ls-files`） | 构建失败 |

- `setup.ps1` 会自动执行 `git config core.hooksPath .githooks`；存量克隆手动执行一次即可。
- **pre-commit 是唯一能在内容进入历史之前拦住的边界**；CI 只能发现**已经推送**的泄漏，
  此时内容已在公开历史里，需要清理历史或改写提交，成本高得多。所以不要把 CI 当第一道闸门。
- pre-commit 只扫**这次提交会入库的内容**，工作区里未暂存的改动不参与扫描；
  `business/`、`out.robin` 等已被 `.gitignore` 忽略，不会进入暂存区，无需额外豁免逻辑。
- 确需绕过钩子时用 `git commit --no-verify`，但必须在提交说明里写明原因，且 CI 仍会兜底。

**覆盖边界**

现有默认词表（`tools/publish/public-safe.denylist.json`）只剩 **5 条结构化规则**：

1. `PAD` / `Robot` 根路径（`path-pad-root`）
2. UNC 网络共享路径（`path-unc`）
3. 内网主机后缀（`.corp` / `.intra` / `.internal` / `.lan`，`host-internal-suffix`）
4. 邮箱地址（`email-address`）
5. 中国大陆手机号（`mobile-number`）

**拦不到**：业务名、流程名、普通本地路径、账号口令，以及尚未登记进本地词表的新词。
这些只能靠 `public-safe.denylist.local.json` 逐条登记，或靠人工评审。

**缺省词表时的行为**：只有默认词表、没有本地覆盖文件时，钩子与 CI 只打印一条显著提示
（说明当前只有上述 5 条结构化规则），**不改变退出码**——否则公开库 CI 会因为永远没有本地词表而始终失败。
