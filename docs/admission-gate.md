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
| 7 | POLICY | `policy.json` + 运行上下文 | 无 `deny`；`ask` 有有效批准 | `POLICY_DENY` / `POLICY_ASK` | 新增 |
| 8 | BUDGET | 预算声明 + 预检结果 | 最坏情况在预算内；未声明按超限处理 | `BUDGET_EXCEEDED` / `BUDGET_UNKNOWN` | `pad-admit.ps1`（`flow.budget`，未声明即 fail） |
| 9 | ACCEPTANCE | `*.acceptance.json` | JSON 合法、检查类型已知、占位符可解析 | `ACCEPTANCE_INVALID` | `PadAcceptance.psm1` |
| 10 | CONFIG | `config/*.json` + schema | schema 校验通过 | `CONFIG_INVALID` | `pad-deploy.ps1` |
| 11 | PREFLIGHT | 机器环境 | PAD/Python/SAP/Outlook/目录齐全 | `PREFLIGHT_MISSING` | `PadPreflight.psm1` |
| 12 | FINGERPRINT | 三个文件的 SHA256 | 与批准记录一致 | `FINGERPRINT_MISMATCH` | 部分（发布后哈希校验） |
| 13 | INTENT | 节点 `intent` / `tags` | `RunDOSCommand`、`RunVBScript` 这类通用动作必须有语义标签，策略按标签匹配 | `MISSING_INTENT` | `pad-admit.ps1`（缺 intent 即 fail；策略支持 `when.intent`） |

## 3. 执行阶段

| 阶段 | 跑哪些检查 | 触发点 |
|---|---|---|
| 离线（生成前） | 1–6、9、10 | `pad-admit` / `flow-to-robin` / CI |
| 运行前 | 7、8、11、12 | `pad-sync` 注入前 |
| 运行后 | 验收判据 | `pad-sync` 运行后（G6） |

## 4. 输出契约

```json
{
  "ok": false,
  "flow": "sample",
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
- 同一层内按 `policy.json` 的书写顺序取第一条命中。
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

1. **只读版**：新增 `pad-admit.ps1`，跑完 13 项只输出报告，不阻断任何现有流程。
2. **接入**：把 `pad-sync` 注入前、`pad-deploy` 部署前改为硬门禁。
3. **披露**：把 `policy.json` 的 deny 规则渲染成清单，放进 Agent A 的设计提示词，减少无效设计。
4. **指纹批准**：确认框显示三个哈希，发布前复核，支持“批准记录”文件。
