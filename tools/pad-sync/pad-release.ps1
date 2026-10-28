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
#   7. 仓库根 manifest.jsonl 追加一行（type=release），供回滚（第 20 项）与统一清单（第 21 项）使用
#
# 输出：最后一行 PAD_RELEASE_RESULT=<JSON>；退出码 0 成功 / 1 失败
# -AcceptanceFile：发布触发的运行结束后按判据检查产物；不传时自动找 flows\<flow>.acceptance.json
# -DryRun：只跑阶段 1~3（测试 + 校验 + 替换 + 快照），不确认、不发布、不写 manifest
# -NoMain：仅供 Pester dot-source 加载函数，不执行主流程
# 注意：FlowName 不设为 Mandatory，否则 Pester dot-source 时会弹参数提示

[CmdletBinding()]
param(
    # 不传时默认取仓库内 flows\sample.robin / config\sample.json
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
# robin 规范化 / 哈希 / 逐行比对统一放在 RobinText.psm1：
# 发布后校验（本脚本）与 -VerifyCanvas 画布回读（PadDesigner）必须使用同一套规则
# 必须用 -Global：阶段 1 的 Invoke-Pester 会在自己的作用域里跑完再销毁，
# 普通导入的模块函数随后就取不到了（表现为 Get-RobinHash 找不到）
Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global


# 从 Actions.log 路径解析流程 GUID 与 runId：
#   ...\Console\Scripts\<flowGuid>\Runs\<runId>\Actions.log
function Get-FlowGuidFromLogPath([string]$LogPath) {
    $m = [regex]::Match($LogPath, 'Scripts\\([0-9a-fA-F-]{36})\\Runs\\([0-9a-fA-F-]{36})\\')
    if (-not $m.Success) { return $null }
    return [ordered]@{ flowGuid = $m.Groups[1].Value.ToLower(); runId = $m.Groups[2].Value }
}

# 在本地运行历史里找该流程最近一次运行的定义信息（按 startTime 取最新）
# 返回：flowGuid / flowVersion（云端版本 ETag）/ startTime / status；找不到返回 $null
function Find-LatestFlowRun([string]$ScriptsRoot, [string]$FlowName) {
    if (-not (Test-Path $ScriptsRoot)) { return $null }
    $best = $null
    $files = Get-ChildItem -LiteralPath $ScriptsRoot -Recurse -Filter 'RunDefinition.json' -ErrorAction SilentlyContinue
    foreach ($rd in $files) {
        try { $j = [IO.File]::ReadAllText($rd.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $j.workflow -or $j.workflow.name -ne $FlowName) { continue }
        if (-not $j.startTime) { continue }
        if (-not $best -or ([string]$j.startTime) -gt ([string]$best.startTime)) {
            $best = [ordered]@{
                flowGuid    = [string]$j.workflow.workflowId
                flowVersion = $(if ($j.diagnosticInfo) { [string]$j.diagnosticInfo.flowVersion } else { $null })
                startTime   = [string]$j.startTime
                status      = [string]$j.status
                path        = $rd.FullName
            }
        }
    }
    return $best
}

# 已发布流程的本地定义副本：Console\Workspace\<flowGuid>\<修订目录>\script.robin，取最新一份
function Find-WorkspaceRobin([string]$WorkspaceRoot, [string]$FlowGuid) {
    $dir = Join-Path $WorkspaceRoot $FlowGuid
    if (-not (Test-Path $dir)) { return $null }
    $f = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'script.robin' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f) { return $f.FullName } else { return $null }
}

# manifest 追加与版本快照统一由 PublishHistory.psm1 提供（pad-rollback.ps1 共用）
# 阶段 1：测试摘要。pytest 解析 passed/failed 计数；Pester 3.4 用 -PassThru 的结果对象计数
function Get-TestSummary([string]$RepoRoot, [string]$PythonExe) {
    $summary = [ordered]@{ pytestPassed = 0; pytestFailed = 0; pesterPassed = 0; pesterFailed = 0 }
    $testsDir = Join-Path $RepoRoot 'tests'

    Log "运行 pytest：$testsDir"
    # 不能用 Select-Object -First 截断输出（会提前杀死子进程），Out-String 全量收集
    $out = & $PythonExe -m pytest $testsDir -q 2>&1 | Out-String
    $m = [regex]::Match($out, '(\d+) passed'); if ($m.Success) { $summary.pytestPassed = [int]$m.Groups[1].Value }
    $m = [regex]::Match($out, '(\d+) failed'); if ($m.Success) { $summary.pytestFailed = [int]$m.Groups[1].Value }
    if ($LASTEXITCODE -ne 0 -and $summary.pytestFailed -eq 0) { $summary.pytestFailed = -1 }  # 非断言类失败（如解释器报错）

    foreach ($f in (Get-ChildItem $testsDir -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)) {
        Log "运行 Pester：$($f.Name)"
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
    $json = $null
    foreach ($line in ([IO.File]::ReadAllLines($tmp, [Text.Encoding]::UTF8))) {
        if ($line -match '^PAD_DEPLOY_RESULT=(.+)$') { $json = $Matches[1] }
    }
    if (-not $json) { throw "pad-deploy 无 PAD_DEPLOY_RESULT 输出（日志：$tmp）" }
    return ($json | ConvertFrom-Json)
}

# 批准指纹：把「这次要发的三样东西」绑成一个可核对的标识
# 确认框展示短哈希，正式发布前重算一次；期间文件被改过就中止
function Get-ApprovalFingerprint([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    $fp = [ordered]@{ robin = $null; config = $null; acceptance = $null }
    foreach ($pair in @(@('robin', $RobinPath), @('config', $ConfigPath), @('acceptance', $AcceptancePath))) {
        if ($pair[1] -and (Test-Path -LiteralPath $pair[1])) {
            $fp[$pair[0]] = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLower()
        }
    }
    return $fp
}

# 只展示每个哈希前 8 位，够人眼核对又不刷屏
function Format-ApprovalFingerprint($Fp) {
    if (-not $Fp) { return '(无)' }
    $parts = @()
    foreach ($k in $Fp.Keys) {
        if ($Fp[$k]) { $parts += ('{0}={1}' -f $k, $Fp[$k].Substring(0, 8)) }
    }
    if ($parts.Count -eq 0) { return '(无)' }
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
        fingerprint = $null
        tests = $null; manifestPath = $null
        warnings = @(); errors = @()
    }
    try {
        if (-not $FlowName) { throw '缺少 -FlowName（不设为 Mandatory 是为了让 Pester 能 dot-source 本脚本）' }
        if (-not (Test-Path $script:DeployPath)) { throw "找不到 pad-deploy.ps1" }
        if (-not $SourceRobin) { $SourceRobin = Join-Path $script:RepoRoot 'flows\sample.robin' }
        if (-not $ConfigFile) { $ConfigFile = Join-Path $script:RepoRoot 'config\sample.json' }
        $result.sourceRobin = $SourceRobin
        if (-not (Test-Path $SourceRobin)) { throw "找不到 .robin：$SourceRobin" }
        # 验收判据默认取同名的 <flow>.acceptance.json（与 flow.json 同目录）
        if (-not $AcceptanceFile) {
            $candidate = [IO.Path]::ChangeExtension($SourceRobin, '.acceptance.json')
            if (Test-Path $candidate) { $AcceptanceFile = $candidate }
        }
        $result.acceptanceFile = $AcceptanceFile
        if ($AcceptanceFile -and -not (Test-Path $AcceptanceFile)) {
            throw "找不到验收判据文件：$AcceptanceFile"
        }
        if ($AcceptanceFile) { $AcceptanceFile = (Resolve-Path -LiteralPath $AcceptanceFile).Path }
        $result.acceptanceFile = $AcceptanceFile
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw '安全熔断：默认只能发布 PAD_SYNC_TEST。发布生产流程必须显式 -AllowProd。'
        }

        # ── 阶段 1：测试摘要 ──
        if ($SkipTests) {
            $result.tests = [ordered]@{ skipped = $true }
            $result.warnings += '已跳过测试摘要（-SkipTests）'
            Log '已跳过测试（-SkipTests）'
        } else {
            $result.stage = 'tests'
            $result.tests = Get-TestSummary $script:RepoRoot $PythonExe
            Log ("测试摘要：pytest {0} 通过/{1} 失败；Pester {2} 通过/{3} 失败" -f `
                $result.tests.pytestPassed, $result.tests.pytestFailed, $result.tests.pesterPassed, $result.tests.pesterFailed)
            if ($result.tests.pytestFailed -ne 0 -or $result.tests.pesterFailed -ne 0) {
                throw '测试未全绿，发布中止'
            }
        }

        # ── 阶段 2：校验 + 变量替换（DryRun，不触碰 PAD） ──
        # Invoke-Pester 跑完会把它加载过的模块一起卸载（含上面的 RobinText），
        # 这里必须重新导入，否则接下来算哈希会报 Get-RobinHash 找不到
        Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global
        Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global
        $result.stage = 'deploy-dryrun'
        $dry = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec -DryRunMode -Prod:$AllowProd
        if (-not $dry.ok) { throw ("校验/替换失败：" + (@($dry.errors) -join '；')) }
        $result.deployedRobin = [string]$dry.deployedRobinPath
        $result.replacedCount = [int]$dry.replacedCount
        $deployedText = [IO.File]::ReadAllText($result.deployedRobin, [Text.Encoding]::UTF8)
        $result.sha256 = Get-RobinHash $deployedText
        Log "替换完成：$($result.replacedCount) 处；内容哈希 $($result.sha256.Substring(0,12))…"

        # ── 阶段 3：发布前快照（流程 GUID + 当前云端版本） ──
        $result.stage = 'snapshot'
        $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
        $workspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
        $before = Find-LatestFlowRun $scriptsRoot $FlowName
        if ($before) {
            $result.flowGuid = $before.flowGuid
            $result.flowVersionBefore = $before.flowVersion
            Log "当前云端版本：$($before.flowVersion)（最近运行 $($before.startTime)，$($before.status)）"
        } else {
            $result.warnings += '本地运行历史里找不到该流程（可能从未运行过），发布前快照为空'
            Log '未找到历史运行记录，发布前快照为空'
        }

        if ($DryRun) {
            # DryRun：到此为止，不确认、不发布、不写 manifest
            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            Log '[DryRun] 测试 + 校验 + 替换 + 快照已完成，未发布'
        } else {
            # ── 阶段 4：用户确认（一次，含测试摘要与副作用说明） ──
            $result.stage = 'confirm'
            $t = $result.tests
            $testText = $(if ($t.skipped) { '已跳过' } else { "pytest $($t.pytestPassed) 通过/$($t.pytestFailed) 失败；Pester $($t.pesterPassed) 通过/$($t.pesterFailed) 失败" })
            $acceptText = $(if ($AcceptanceFile) { "验收判据：$([IO.Path]::GetFileName($AcceptanceFile))`n" } else { '' })
            $runNote = $(if ($PublishOnly) { '本次只发布、不触发运行。' } else { '发布后将立即通过 URL 触发一次真实运行（会收发真实邮件、操作 SAP）。' })
            # 批准绑定指纹：确认框上看到的就是即将发布的三份内容，发布前再复核一次
            $result.fingerprint = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            $fpText = Format-ApprovalFingerprint $result.fingerprint
            $msg = "目标流程：$FlowName`n测试摘要：$testText`n$($acceptText)替换变量：$($result.replacedCount) 处`n内容哈希：$($result.sha256.Substring(0,12))…`n批准指纹：$fpText`n当前云端版本：$($result.flowVersionBefore)`n`n前置条件：该流程已在 PAD 设计器中打开。`n注意：$runNote`n`n确定发布？"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ConfirmPath -Title '发布确认' -Msg $msg
            if ($LASTEXITCODE -ne 0) { throw '用户取消发布' }
            Log '用户已确认发布'
            $fpNow = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            if (($fpNow | ConvertTo-Json -Compress) -ne ($result.fingerprint | ConvertTo-Json -Compress)) {
                throw '确认后 robin/config/acceptance 发生变化，请重新发布并重新确认'
            }

            # ── 阶段 5：正式发布（注入 → 发布 → URL 触发 → 收集） ──
            $result.stage = 'publish'
            $deployStartUtc = [datetime]::UtcNow
            $rel = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec $AcceptanceFile -Prod:$AllowProd -NoConfirm -PublishOnlyMode:$PublishOnly
            if (-not $rel.ok) { throw ("发布或验证运行失败：" + (@($rel.errors) -join '；')) }
            $result.runStatus = [string]$rel.runResult.status
            $result.runId = [string]$rel.runResult.runId
            $result.acceptance = $rel.runResult.acceptance
            if ($PublishOnly) { Log '发布完成（-PublishOnly，未触发运行）' }
            else { Log "发布完成，验证运行状态：$($result.runStatus)" }

            # ── 阶段 6：发布后校验 ──
            $result.stage = 'verify'
            # 6a) 运行历史校验：仅“发布并运行”模式需要；只发布模式跳过
            if (-not $PublishOnly) {
                $ids = Get-FlowGuidFromLogPath ([string]$rel.runResult.logPath)
                if ($ids) { $result.flowGuid = $ids.flowGuid; $result.runId = $ids.runId }
                if (-not $result.flowGuid) { throw '无法确定流程 GUID，发布后校验中止' }
                $runDefPath = Join-Path (Split-Path -Parent ([string]$rel.runResult.logPath)) 'RunDefinition.json'
                if (Test-Path $runDefPath) {
                    $rd = [IO.File]::ReadAllText($runDefPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $result.flowVersionAfter = $(if ($rd.diagnosticInfo) { [string]$rd.diagnosticInfo.flowVersion } else { $null })
                    $runStartUtc = [datetime]::Parse([string]$rd.startTime).ToUniversalTime()
                    # 允许 2 分钟时钟误差，防止本机与云端时钟轻微偏移误判
                    if ($runStartUtc -lt $deployStartUtc.AddMinutes(-2)) {
                        throw "云端历史校验失败：本次运行 startTime=$($rd.startTime) 早于发布时间"
                    }
                    if ([string]$rd.status -ne 'Succeeded') { throw "云端历史校验失败：运行状态 $($rd.status)" }
                    Log "云端历史校验通过：flowVersion=$($result.flowVersionAfter)，startTime=$($rd.startTime)"
                } else {
                    $result.warnings += '找不到本次运行的 RunDefinition.json，跳过 flowVersion 校验'
                }
            }
            if (-not $result.flowGuid) { throw '无法确定流程 GUID，发布后校验中止' }
            # 6b) 已发布版本哈希与画布（注入内容）一致
            # Workspace 是本地缓存，可能滞后于云端；最多等 60 秒再判定
            $wsRobin = Find-WorkspaceRobin $workspaceRoot $result.flowGuid
            if (-not $wsRobin) { throw "找不到 Workspace 里的已发布定义（flowGuid=$($result.flowGuid)）" }
            $swWs = [Diagnostics.Stopwatch]::StartNew()
            while ($swWs.Elapsed.TotalSeconds -lt 60) {
                if ((Test-Path $wsRobin) -and ((Get-Item $wsRobin).LastWriteTime -ge $deployStartUtc.ToLocalTime().AddMinutes(-2))) { break }
                Start-Sleep -Seconds 3
            }
            $wsStale = ((Get-Item $wsRobin).LastWriteTime -lt $deployStartUtc.ToLocalTime().AddMinutes(-2))
            if ($wsStale) {
                if ($PublishOnly) {
                    # 只发布模式：云端 published（控制台 modifiedOn 已更新），本地缓存未刷新时不误判失败
                    $result.warnings += 'Workspace 缓存未刷新，跳过哈希校验（以发布状态为准）'
                    Log '警告：Workspace 缓存未刷新，跳过哈希校验'
                } else {
                    throw "已发布定义副本未更新（$wsRobin 时间早于本次发布），无法确认哈希一致"
                }
            } else {
                $wsText = [IO.File]::ReadAllText($wsRobin, [Text.Encoding]::UTF8)
                $cmp = Compare-RobinText $deployedText $wsText
                $result.hashMatch = $cmp.match
                if (-not $cmp.match) {
                    throw "已发布版本与画布不一致：第 $($cmp.diffIndex) 行`n  画布：$($cmp.lineA)`n  云端：$($cmp.lineB)"
                }
                Log "哈希校验通过：已发布版本与注入内容一致（$($result.sha256.Substring(0,12))…）"
            }

            # ── 快照归档：发布成功即固化一份成品，供 pad-rollback.ps1 重发 ──
            $snapshotsRoot = Join-Path $script:RepoRoot 'snapshots'
            $result.snapshotPath = Save-ReleaseSnapshot $snapshotsRoot $FlowName $result.deployedRobin $result.sha256 ([datetime]::Now)
            Log "快照已归档：$($result.snapshotPath)"
            # 只保留最近 20 个快照，避免无限增长
            $removed = @(Remove-OldReleaseSnapshots (Split-Path -Parent $result.snapshotPath) 20)
            if ($removed.Count -gt 0) { Log "已清理旧快照 $($removed.Count) 个（保留最近 20 个）" }

            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
        }
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "发布流水线失败于 [$($result.stage)]：$($_.Exception.Message)"
    }
    finally {
        # ── 阶段 7：manifest（DryRun 不写；成功失败都记录，供回滚与审计） ──
        if (-not $DryRun -and $result.stage -ne 'init') {
            $manifestPath = Join-Path $script:RepoRoot 'manifest.jsonl'
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
                ok = $result.ok; errors = $result.errors; warnings = @($result.warnings)
            }
            try {
                Add-ManifestEntry $manifestPath $entry
                $result.manifestPath = $manifestPath
                Log "manifest 已追加：$manifestPath"
                # release 记录永久保留，这里只清理过期的 run 记录
                [void](Remove-OldManifestEntries $manifestPath -KeepDays 90)
            }
            catch { $result.warnings += "manifest 写入失败：$($_.Exception.Message)" }
        }
        Write-Output ("PAD_RELEASE_RESULT=" + ($result | ConvertTo-Json -Depth 10 -Compress))
    }
    exit $exitCode
}
