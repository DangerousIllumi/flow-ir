# pad-release.ps1 — release 流水线：测试摘要 → 用户确认 → 发布 → URL 触发 → 云端历史校验 → manifest
#
# 阶段：
#   1. 测试摘要：pytest（tests\）+ Pester（tests\*.Tests.ps1），任一失败即中止
#   2. 校验 + 变量替换：复用 pad-deploy -DryRun，产物为 .deployed.robin
#   3. 发布前快照：从本地运行历史（Console\Scripts）取流程 GUID 与当前云端版本
#   4. 用户确认弹窗（一次，含测试摘要与副作用说明）
#   5. 正式发布：复用 pad-deploy -SkipConfirm（注入 → 发布 → URL 触发 → 收集运行结果）
#   6. 发布后校验：
#      a) Workspace 里的已发布 script.robin 与 .deployed.robin 规范化哈希一致（验收点）
#      b) 新运行的 RunDefinition.json：startTime 在本次发布之后、状态 Succeeded、记录 flowVersion
#   7. 通过 PublishHistory.psm1 向 business\manifest.jsonl 追加一行（type=release），
#      供 pad-rollback.ps1 回滚与发布清单（PublishHistory.psm1）查询使用
#
# 输出：最后一行 PAD_RELEASE_RESULT=<JSON>；退出码 0 成功 / 1 失败
# -AcceptanceFile：发布触发的运行结束后按判据检查产物；不传时自动找 business\flows\<flow>.acceptance.json
# -DryRun：只跑阶段 1~3（测试 + 校验 + 替换 + 快照），不确认、不发布、不写 manifest
# -NoMain：仅供 Pester dot-source 加载函数，不执行主流程
# 注意：FlowName 不设为 Mandatory，否则 Pester dot-source 时会弹参数提示

[CmdletBinding()]
param(
    # 不传时按 -FlowName 派生为 business\flows\<FlowName>.robin / business\config\<FlowName>.json，派生不到即报错
    [string]$SourceRobin,
    [string]$ConfigFile,
    [string]$FlowName,
    [string]$SchemaFile,
    # 运行后验收判据；不传时自动找同名的 <flow>.acceptance.json
    [string]$AcceptanceFile,
    [string]$PythonExe = 'C:\Program Files\Python313\python.exe',
    # 生产流最坏要轮询 60 分钟 + 处理余量，默认 4200 秒；快速验证可显式传更小值
    [int]$RunTimeoutSec = 4200,
    [switch]$SkipTests,
    [switch]$DryRun,
    # 只发布不运行：发布后只校验哈希，不做运行状态/验收
    [switch]$PublishOnly,
    [switch]$AllowProd,
    [switch]$NoMain
)
$ErrorActionPreference = "Stop"

# $PSScriptRoot = tools\pad-sync，退两级到仓库根
# （从 $MyInvocation.MyCommand.Path 算会带上文件名，退两级只到 tools，少退一级）
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:DeployPath = Join-Path $PSScriptRoot 'pad-deploy.ps1'
$script:ConfirmPath = Join-Path $PSScriptRoot 'confirm-deploy.ps1'

function Log([string]$m) { Write-Host "[release] $m" }

# ═══ 纯函数（供主流程与 Pester 单测共用） ═══
# 指纹定位与身份解析唯一实现（pad-fingerprint / pad-admit / pad-rollback 共用）
Import-Module (Join-Path $PSScriptRoot 'PadFingerprint.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global
# 子进程末行 RESULT 的解析统一由 PadTelemetry 提供
Import-Module (Join-Path $PSScriptRoot 'PadTelemetry.psm1') -Force -Global
# 失败告警：与 pad-schedule / pad-sync / pad-deploy 共用同一份实现（kind 常量集中在模块里）
Import-Module (Join-Path $PSScriptRoot 'PadAlerts.psm1') -Force -Global
# robin 规范化 / 哈希 / 逐行比对统一放在 RobinText.psm1：
# 发布后校验（本脚本）与 -VerifyCanvas 画布回读（PadDesigner）必须使用同一套规则
# 必须用 -Global：阶段 1 的 Invoke-Pester 会在自己的作用域里跑完再销毁，
# 普通导入的模块函数随后就取不到了（表现为 Get-RobinHash 找不到）。
# 必须放在 PadFingerprint 之后：PadFingerprint 内部会 Import-Module RobinText -Force，
# 先导入 RobinText 会被那次嵌套导入从全局作用域里卸载掉，
# 表现为 dot-source 后 ConvertTo-NormalizedRobin / Get-RobinHash / Compare-RobinText 全部找不到。
Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global


# 已发布流程的本地定义副本定位与身份解析已迁移到 PadFingerprint.psm1（唯一实现）：
#   Get-FlowGuidFromLogPath / Find-LatestFlowRun / Find-WorkspaceRobin 均由模块导入，
#   函数名保持不变，pad-release 只是调用方。

# manifest 追加与版本快照统一由 PublishHistory.psm1 提供（pad-rollback.ps1 共用）
# 阶段 1：测试摘要。pytest 解析 passed/failed 计数；Pester 3.4 用 -PassThru 的结果对象计数
function Get-TestSummary([string]$RepoRoot, [string]$PythonExe) {
    $summary = [ordered]@{ pytestPassed = 0; pytestFailed = 0; pesterPassed = 0; pesterFailed = 0 }
    $testsDir = Join-Path $RepoRoot 'tests'

    Log "running pytest: $testsDir"
    # 不能用 Select-Object -First 截断输出（会提前杀死子进程），Out-String 全量收集
    $out = & $PythonExe -m pytest $testsDir -q 2>&1 | Out-String
    $m = [regex]::Match($out, '(\d+) passed'); if ($m.Success) { $summary.pytestPassed = [int]$m.Groups[1].Value }
    $m = [regex]::Match($out, '(\d+) failed'); if ($m.Success) { $summary.pytestFailed = [int]$m.Groups[1].Value }
    if ($LASTEXITCODE -ne 0 -and $summary.pytestFailed -eq 0) { $summary.pytestFailed = -1 }  # 非断言类失败（如解释器报错）

    foreach ($f in (Get-ChildItem $testsDir -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)) {
        Log "running Pester: $($f.Name)"
        $r = Invoke-Pester -Script $f.FullName -PassThru
        $items = @()
        if ($r -and $r.PSObject.Properties['TestResult'] -and $r.TestResult) { $items = @($r.TestResult) }
        if ($items.Count -gt 0) {
            foreach ($t in $items) {
                if (($t.PSObject.Properties['Passed'] -and $t.Passed) -or ($t.PSObject.Properties['Result'] -and $t.Result -eq 'Passed')) {
                    $summary.pesterPassed++
                } else { $summary.pesterFailed++ }
            }
        } elseif ($r -and $r.PSObject.Properties['PassedCount']) {
            # 兜底：部分 Pester 版本只给计数属性
            $summary.pesterPassed += $r.PassedCount
            $summary.pesterFailed += $r.FailedCount
        }
    }
    return $summary
}

# 调 pad-deploy 子进程并解析 PAD_DEPLOY_RESULT（最后一行）
# 注意：PS 5.1 的 hashtable splat 不能用于 exe，只能显式组参数数组
function Invoke-Deploy([string]$SrcRobin, [string]$CfgFile, [string]$Flow, [string]$Schema,
                       [int]$TimeoutSec, [string]$Acceptance, [switch]$DryRunMode, [switch]$Prod, [switch]$NoConfirm, [switch]$PublishOnlyMode) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DeployPath,
        '-SourceRobin', $SrcRobin, '-ConfigFile', $CfgFile, '-FlowName', $Flow,
        '-RunTimeoutSec', $TimeoutSec)
    if ($Schema) { $argList += @('-SchemaFile', $Schema) }
    if ($Acceptance) { $argList += @('-AcceptanceFile', $Acceptance) }
    if ($PublishOnlyMode) { $argList += '-PublishOnly' }
    if ($DryRunMode) { $argList += '-DryRun' }
    if ($Prod) { $argList += '-AllowProd' }
    if ($NoConfirm) { $argList += '-SkipConfirm' }
    $tmp = Join-Path $env:TEMP ("pad-release-" + [guid]::NewGuid().ToString('N') + ".log")
    & powershell @argList > $tmp 2>&1
    $json = Read-ChildResult -Name 'DEPLOY' `
        -Lines ([IO.File]::ReadAllLines($tmp, [Text.Encoding]::UTF8)) `
        -Logger { param($m) Write-Host "[release] $m" }
    if (-not $json) { throw "pad-deploy produced no PAD_DEPLOY_RESULT output (log: $tmp)" }
    return $json
}

# 批准指纹：把「这次要发的三样东西」绑成一个可核对的标识
# 确认框展示短哈希，正式发布前重算一次；期间文件被改过就中止
function Get-ApprovalFingerprint([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    # 哈希算法统一由 PadFingerprint 提供，本脚本不再自行实现一份
    return (Get-FingerprintParts $RobinPath $ConfigPath $AcceptancePath)
}

# 只展示每个哈希前 8 位，够人眼核对又不刷屏
function Format-ApprovalFingerprint($Fp) {
    if (-not $Fp) { return '(none)' }
    $parts = @()
    foreach ($k in $Fp.Keys) {
        if ($Fp[$k]) { $parts += ('{0}={1}' -f $k, $Fp[$k].Substring(0, 8)) }
    }
    if ($parts.Count -eq 0) { return '(none)' }
    return ($parts -join ' ')
}

# ═══ 主流程 ═══
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; stage = 'init'; flow = $FlowName; dryRun = [bool]$DryRun
        sourceRobin = $SourceRobin; deployedRobin = $null; sha256 = $null; replacedCount = 0
        flowGuid = $null; flowVersionBefore = $null; flowVersionAfter = $null
        runId = $null; runStatus = $null; hashMatch = $null; snapshotPath = $null
        acceptanceFile = $null; acceptance = $null
        fingerprint = $null; fingerprintBaseline = $null
        tests = $null; manifestPath = $null
        warnings = @(); errors = @()
    }
    try {
        if (-not $FlowName) { throw 'missing -FlowName (not Mandatory so Pester can dot-source this script)' }
        if (-not (Test-Path $script:DeployPath)) { throw "pad-deploy.ps1 not found" }
        # 不再默认到某个具体业务流程：先按 -FlowName 派生，派生不到就明确要求显式指定
        if (-not $SourceRobin) {
            $guess = Join-Path $script:RepoRoot ("business\flows\{0}.robin" -f $FlowName)
            if (Test-Path -LiteralPath $guess) {
                $SourceRobin = $guess
            } else {
                throw "E_SOURCE_ROBIN_REQUIRED: -SourceRobin not provided and the name-derived path was not found: $guess; specify it with -SourceRobin"
            }
        }
        if (-not $ConfigFile) {
            $guess = Join-Path $script:RepoRoot ("business\config\{0}.json" -f $FlowName)
            if (Test-Path -LiteralPath $guess) {
                $ConfigFile = $guess
            } else {
                throw "E_CONFIG_REQUIRED: -ConfigFile not provided and the name-derived path was not found: $guess; specify it with -ConfigFile"
            }
        }
        $result.sourceRobin = $SourceRobin
        if (-not (Test-Path $SourceRobin)) { throw ".robin not found: $SourceRobin" }
        # 验收判据默认取同名的 <flow>.acceptance.json（与 flow.json 同目录）
        if (-not $AcceptanceFile) {
            $candidate = [IO.Path]::ChangeExtension($SourceRobin, '.acceptance.json')
            if (Test-Path $candidate) { $AcceptanceFile = $candidate }
        }
        $result.acceptanceFile = $AcceptanceFile
        if ($AcceptanceFile -and -not (Test-Path $AcceptanceFile)) {
            throw "acceptance criteria file not found: $AcceptanceFile"
        }
        if ($AcceptanceFile) { $AcceptanceFile = (Resolve-Path -LiteralPath $AcceptanceFile).Path }
        $result.acceptanceFile = $AcceptanceFile
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw 'Safety fuse: only PAD_SYNC_TEST may be released by default. Releasing a production flow requires explicit -AllowProd.'
        }

        # ── 阶段 1：测试摘要 ──
        if ($SkipTests) {
            $result.tests = [ordered]@{ skipped = $true }
            $result.warnings += 'test summary skipped (-SkipTests)'
            Log 'tests skipped (-SkipTests)'
        } else {
            $result.stage = 'tests'
            $result.tests = Get-TestSummary $script:RepoRoot $PythonExe
            Log ("test summary: pytest {0} passed/{1} failed; Pester {2} passed/{3} failed" -f `
                $result.tests.pytestPassed, $result.tests.pytestFailed, $result.tests.pesterPassed, $result.tests.pesterFailed)
            if ($result.tests.pytestFailed -ne 0 -or $result.tests.pesterFailed -ne 0) {
                throw 'tests are not all green; release aborted'
            }
        }

        # ── 阶段 2：校验 + 变量替换（DryRun，不触碰 PAD） ──
        # Invoke-Pester 跑完会把它加载过的模块一起卸载（含上面的 RobinText），
        # 这里必须重新导入，否则接下来算哈希会报 Get-RobinHash 找不到
        Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global
        Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global
        $result.stage = 'deploy-dryrun'
        $dry = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec -DryRunMode -Prod:$AllowProd
        if (-not $dry.ok) { throw ("validation/substitution failed: " + (@($dry.errors) -join '; ')) }
        $result.deployedRobin = [string]$dry.deployedRobinPath
        $result.replacedCount = [int]$dry.replacedCount
        $deployedText = [IO.File]::ReadAllText($result.deployedRobin, [Text.Encoding]::UTF8)
        $result.sha256 = Get-RobinHash $deployedText
        Log "substitution complete: $($result.replacedCount) placeholders; content hash $($result.sha256.Substring(0,12))..."

        # ── 阶段 3：发布前快照（流程 GUID + 当前云端版本） ──
        $result.stage = 'snapshot'
        $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
        $workspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
        $before = Find-LatestFlowRun $scriptsRoot $FlowName
        if ($before) {
            $result.flowGuid = $before.flowGuid
            $result.flowVersionBefore = $before.flowVersion
            Log "current cloud version: $($before.flowVersion) (latest run $($before.startTime), $($before.status))"
        } else {
            $result.warnings += 'flow not found in the local run history (it may never have run); the pre-release snapshot is empty'
            Log 'no historical run record found; the pre-release snapshot is empty'
        }

        if ($DryRun) {
            # DryRun：到此为止，不确认、不发布、不写 manifest
            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            Log '[DryRun] tests + validation + substitution + snapshot completed; nothing was released'
        } else {
            # ── 阶段 4：用户确认（一次，含测试摘要与副作用说明） ──
            $result.stage = 'confirm'
            $t = $result.tests
            $testText = $(if ($t.skipped) { 'skipped' } else { "pytest $($t.pytestPassed) passed/$($t.pytestFailed) failed; Pester $($t.pesterPassed) passed/$($t.pesterFailed) failed" })
            $acceptText = $(if ($AcceptanceFile) { "acceptance criteria: $([IO.Path]::GetFileName($AcceptanceFile))`n" } else { '' })
            $runNote = $(if ($PublishOnly) { 'This release does not trigger a run.' } else { 'After release a real run is triggered immediately via URL (it sends and receives real email and operates SAP).' })
            # 批准绑定指纹：确认框上看到的就是即将发布的三份内容，发布前再复核一次
            $result.fingerprint = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            $fpText = Format-ApprovalFingerprint $result.fingerprint
            $msg = "Target flow: $FlowName`nTest summary: $testText`n$($acceptText)Replaced variables: $($result.replacedCount)`nContent hash: $($result.sha256.Substring(0,12))...`nApproval fingerprint: $fpText`nCurrent cloud version: $($result.flowVersionBefore)`n`nPrerequisite: this flow is already open in the PAD designer.`nNote: $runNote`n`nRelease now?"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ConfirmPath -Title 'Release confirmation' -Msg $msg
            if ($LASTEXITCODE -ne 0) { throw 'user cancelled the release' }
            Log 'user confirmed the release'
            $fpNow = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            if (($fpNow | ConvertTo-Json -Compress) -ne ($result.fingerprint | ConvertTo-Json -Compress)) {
                throw 'robin/config/acceptance changed after confirmation; release again and confirm again'
            }

            # ── 阶段 5：正式发布（注入 → 发布 → URL 触发 → 收集） ──
            $result.stage = 'publish'
            $deployStartUtc = [datetime]::UtcNow
            $rel = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec $AcceptanceFile -Prod:$AllowProd -NoConfirm -PublishOnlyMode:$PublishOnly
            if (-not $rel.ok) { throw ("release or verification run failed: " + (@($rel.errors) -join '; ')) }
            $result.runStatus = [string]$rel.runResult.status
            $result.runId = [string]$rel.runResult.runId
            $result.acceptance = $rel.runResult.acceptance
            if ($PublishOnly) { Log 'release complete (-PublishOnly, no run was triggered)' }
            else { Log "release complete; verification run status: $($result.runStatus)" }

            # ── 阶段 6：发布后校验 ──
            $result.stage = 'verify'
            # 6a) 运行历史校验：仅“发布并运行”模式需要；只发布模式跳过
            if (-not $PublishOnly) {
                $ids = Get-FlowGuidFromLogPath ([string]$rel.runResult.logPath)
                if ($ids) { $result.flowGuid = $ids.flowGuid; $result.runId = $ids.runId }
                if (-not $result.flowGuid) { throw 'cannot determine the flow GUID; post-release verification aborted' }
                $runDefPath = Join-Path (Split-Path -Parent ([string]$rel.runResult.logPath)) 'RunDefinition.json'
                if (Test-Path $runDefPath) {
                    $rd = [IO.File]::ReadAllText($runDefPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $result.flowVersionAfter = $(if ($rd.diagnosticInfo) { [string]$rd.diagnosticInfo.flowVersion } else { $null })
                    $runStartUtc = [datetime]::Parse([string]$rd.startTime).ToUniversalTime()
                    # 允许 2 分钟时钟误差，防止本机与云端时钟轻微偏移误判
                    if ($runStartUtc -lt $deployStartUtc.AddMinutes(-2)) {
                        throw "cloud history check failed: this run has startTime=$($rd.startTime), earlier than the release time"
                    }
                    if ([string]$rd.status -ne 'Succeeded') { throw "cloud history check failed: run status $($rd.status)" }
                    Log "cloud history check passed: flowVersion=$($result.flowVersionAfter), startTime=$($rd.startTime)"
                } else {
                    $result.warnings += 'RunDefinition.json for this run was not found; skipping the flowVersion check'
                }
            }
            if (-not $result.flowGuid) { throw 'cannot determine the flow GUID; post-release verification aborted' }
            # 6b) 已发布版本哈希与画布（注入内容）一致
            # Workspace 是本地缓存，可能滞后于云端；最多等 60 秒让本次修订落盘
            $wsRobin = $null
            $swWs = [Diagnostics.Stopwatch]::StartNew()
            while ($swWs.Elapsed.TotalSeconds -lt 60) {
                $wsRobin = Find-WorkspaceRobin $workspaceRoot $result.flowGuid $result.runId $deployStartUtc
                if ($wsRobin) { break }
                Start-Sleep -Seconds 3
            }
            if (-not $wsRobin) {
                throw "no published definition for this release (runId=$($result.runId)) in Workspace (flowGuid=$($result.flowGuid)); will not fall back to the latest one"
            }
            $wsStale = ((Get-Item $wsRobin).LastWriteTime.ToUniversalTime() -lt $deployStartUtc.AddMinutes(-2))
            if ($wsStale) {
                if ($PublishOnly) {
                    # 只发布模式：云端 published（控制台 modifiedOn 已更新），本地缓存未刷新时不误判失败
                    $result.warnings += 'Workspace cache was not refreshed; skipping hash verification (published state takes precedence)'
                    Log 'warning: Workspace cache was not refreshed; skipping hash verification'
                } else {
                    throw "published definition copy was not updated ($wsRobin is older than this release); cannot confirm the hash matches"
                }
            } else {
                $wsText = [IO.File]::ReadAllText($wsRobin, [Text.Encoding]::UTF8)
                $cmp = Compare-RobinText $deployedText $wsText
                $result.hashMatch = $cmp.match
                if (-not $cmp.match) {
                    # 带 Data['code'] 的异常：告警分类按码判断，不解析中文消息
                    $msg = "published version differs from the canvas: line $($cmp.diffIndex)`n  canvas: $($cmp.lineA)`n  cloud: $($cmp.lineB)"
                    $ex = [System.Exception]::new($msg)
                    $ex.Data['code'] = 'RELEASE_CANVAS_MISMATCH'
                    throw $ex
                }
                Log "hash check passed: published version matches the injected content ($($result.sha256.Substring(0,12))...)"
            }

            # ── 快照归档：发布成功即固化一份成品，供 pad-rollback.ps1 重发 ──
            $snapshotsRoot = Join-Path $script:RepoRoot 'business\snapshots'
            $result.snapshotPath = Save-ReleaseSnapshot $snapshotsRoot $FlowName $result.deployedRobin $result.sha256 ([datetime]::Now)
            Log "snapshot archived: $($result.snapshotPath)"
            # 只保留最近 20 个快照，避免无限增长
            $removed = @(Remove-OldReleaseSnapshots (Split-Path -Parent $result.snapshotPath) 20)
            if ($removed.Count -gt 0) { Log "removed $($removed.Count) old snapshots (keeping the latest 20)" }

            # ── 指纹基线：发布成功后固化「这份定义 + 配置 + 验收」的哈希，供准入比对 ──
            # 写入失败不推翻已经成功的发布，但必须显式告警
            try {
                $fpPath = Get-FingerprintBaselinePath $script:RepoRoot $FlowName
                $fpBase = New-FingerprintBaseline -FlowName $FlowName -FlowGuid $result.flowGuid `
                    -EnvironmentId (Get-PadEnvironmentId) -SourceRobin $result.sourceRobin `
                    -WorkspaceRobin $wsRobin -ConfigPath $ConfigFile -AcceptancePath $AcceptanceFile
                [void](Write-FingerprintBaseline $fpPath $fpBase)
                $result.fingerprintBaseline = $fpPath
                Log "fingerprint baseline updated: $fpPath"
            } catch {
                $result.warnings += "fingerprint baseline write failed: $($_.Exception.Message)"
                Log "warning: fingerprint baseline write failed ($($_.Exception.Message))"
            }

            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
        }
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "release pipeline failed at [$($result.stage)]: $($_.Exception.Message)"
        # DryRun 不触碰 PAD，失败不写告警，避免污染真实运维记录
        if (-not $DryRun) {
            $ak = Get-AlertKindConstants
            $msg = $_.Exception.Message
            $kind = if ([string]$_.Exception.Data['code'] -eq 'RELEASE_CANVAS_MISMATCH') { $ak.ReleaseCanvasMismatch }
                elseif ($result.stage -in @('publish', 'verify')) { $ak.DeployPublishFailed }
                else { $ak.DeployPrecheckFailed }
            if (Test-Path (Join-Path $script:RepoRoot 'tools')) {
                try {
                    $r = Write-RunAlert -FlowName $result.flow -ExitCode 1 -Stage $result.stage `
                        -Status $result.runStatus -Kind $kind -RunId ([string]$result.runId) `
                        -Dir (Join-Path $script:RepoRoot 'business\logs') `
                        -Note "Release pipeline failed at stage=$($result.stage): $msg. Next step: fix it as prompted and release again; nothing was retried automatically."
                    if ($r -and -not $r.skipped) { Log "failure alert written: $($r.path)" }
                } catch { Log "failed to write the alert (does not affect the release result): $($_.Exception.Message)" }
            }
        }
    }
    finally {
        # ── 阶段 7：manifest（DryRun 不写；成功失败都记录，供回滚与审计） ──
        if (-not $DryRun -and $result.stage -ne 'init') {
            $manifestPath = Join-Path $script:RepoRoot 'business\manifest.jsonl'
            $entry = [ordered]@{
                ts = [datetime]::UtcNow.ToString('o'); type = 'release'
                flow = $result.flow; flowGuid = $result.flowGuid
                sourceRobin = $result.sourceRobin; deployedRobin = $result.deployedRobin
                sha256 = $result.sha256; replacedCount = $result.replacedCount
                snapshotPath = $result.snapshotPath
                tests = $result.tests
                flowVersionBefore = $result.flowVersionBefore; flowVersionAfter = $result.flowVersionAfter
                runId = $result.runId; runStatus = $result.runStatus; hashMatch = $result.hashMatch
                fingerprint = $result.fingerprint
                fingerprintBaseline = $result.fingerprintBaseline
                ok = $result.ok; errors = $result.errors; warnings = @($result.warnings)
            }
            try {
                Add-ManifestEntry $manifestPath $entry
                $result.manifestPath = $manifestPath
                Log "manifest appended: $manifestPath"
                # release 记录永久保留，这里只清理过期的 run 记录
                [void](Remove-OldManifestEntries $manifestPath -KeepDays 90)
            }
            catch { $result.warnings += "manifest write failed: $($_.Exception.Message)" }
        }
        Write-Output ("PAD_RELEASE_RESULT=" + ($result | ConvertTo-Json -Depth 10 -Compress))
    }
    exit $exitCode
}
