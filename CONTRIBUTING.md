# 贡献指南

## 环境

- Windows 10/11，PowerShell 5.1（不要用 PowerShell 7 跑 Pester，测试按 3.4 语法写）
- Node.js ≥ 18
- Python 3.13（核对脚本与 pytest）
- Power Automate Desktop（只有真机联调才需要）

首次准备：

```powershell
.\setup.ps1
```

它会安装 Node 依赖、克隆动作知识库 `pad-robin-action-kb/`，并创建目录结构。知识库是第三方 MIT 项目，**不入库**。

## 本地必跑的检查

```powershell
node --test tools\pad-robin\flow-to-robin.test.js tools\pad-robin\compare-robin.test.js
node tools\flow-drawio\flow-to-drawio.js tools\flow-drawio\example-flow.json <临时>.drawio
node tools\pad-robin\check.js flows
node tools\pad-robin\flow-to-robin.js tools\flow-drawio\example-flow.json <临时>.robin
```

Pester（与 CI 相同的调用方式）：

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force
Get-ChildItem tests\*.Tests.ps1 | ForEach-Object { Invoke-Pester -Script $_.FullName -PassThru }
```

## 核心约定

1. **`flow.json` 是唯一设计源**。不要直接改 `.robin`：改完 `flows/<name>.json` 后重新生成，再跑
   `node tools/pad-robin/compare-robin.js <生成.robin> flows/<name>.robin` 确认一致。CI 里这是硬失败。
2. **`.ps1` / `.psm1` 必须是 UTF-8 with BOM**。PowerShell 5.1 会把无 BOM 的中文按 ANSI 解析，出现莫名的语法错误。
3. **代码注释用中文**，变量名/文件路径用英文。
4. 新增动作直接查 KB 的 `actionId`，不要凭记忆编造；生成器查不到会拒绝产出。
5. 新增验收判据写进 `flow.json` 的 `acceptance` 声明，用
   `tools\pad-sync\build-acceptance.ps1` 生成 `*.acceptance.json`，不要手写第二份。
6. 提交前确认没有把下面这些带进来（都已在 `.gitignore` 里）：`config/*.json`（真实配置）、
   `snapshots/`、`manifest.jsonl`、`logs/`、`*.deployed.robin`、`pad-robin-action-kb/`。

## 提交前检查清单

- [ ] 所有测试命令通过
- [ ] 改了 `flow.json` 的话，`.robin` 已重新生成且 `compare-robin` 一致
- [ ] 改了 `.ps1` 的话，文件仍带 BOM，且 `pad-admit.ps1` 端到端退出码为 0
- [ ] 文档里的数字（轮询次数、时间、开关）与代码一致（`tests/test_docs.py` 会兜底）
- [ ] 没有真实邮箱、工号、内网地址、业务数据
