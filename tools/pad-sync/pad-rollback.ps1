# pad-rollback.ps1 — 发布回滚（通用，按流程名定位）
#
# 原理：PAD 云端的 flowVersion 只是 ETag，不能直接「切回上一版」；
#       可行的回滚只有一条路 —— 取本地快照里保存的历史成品 .robin，重新注入并发布。
#
# 快照由 pad-release.ps1 在每次成功发布后写入 snapshots\<flowName>\<时间戳>-<sha前8>.robin，
# 内容已是变量替换后的成品，因此回滚只还原工作流定义，不受当前 config 取值影响。
#
# 用法：
#   .\pad-rollback.ps1 -FlowName PAD_SYNC_TEST -DryRun      # 只看会回退到哪一版，不发布
#   .\pad-rollback.ps1 -FlowName PAD_SYNC_TEST              # 回退一个版本
#   .\pad-rollback.ps1 -FlowName X -Back 2                  # 回退两个版本
#   .\pad-rollback.ps1 -FlowName X -To 20261028-120000-ab12cd34
#
# 边界：只回滚工作流定义，不撤销已过账的 SAP 凭证、已发出的邮件、已改动的报表文件；
#       回滚同样会通过 URL 触发一次真实运行，因此默认要弹确认。
#
# 输出：最后一行 PAD_ROLLBACK_RESULT=<JSON>；退出码 0 成功 / 1 失败

[CmdletBinding()]
param(
    [string]$FlowName,
    # 快照目录与 manifest 默认在仓库根；ConfigFile 默认取 sample，可用参数覆盖
    [string]$SnapshotsRoot,
    [string]$ManifestPath,
    [string]$ConfigFile,
    [string]$SchemaFile,
    # 跳过最近 Back 个快照（1 = 回退到上一个版本）
    [int]$Back = 1,
    # 直接指定目标：完整路径 / 文件名 / sha 前缀
    [string]$To,
    [int]$RunTimeoutSec = 4200,
    [switch]$AllowProd,
    [switch]$DryRun,
    # 只发布不运行：回滚后只保存到云端，不触发运行
    [switch]$PublishOnly,
    # 跳过确认弹窗（由上层编排脚本统一确认后使用）
    [switch]$SkipConfirm,
    # 仅供 Pester dot-source 加载函数，不执行主流程
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
# $PSScriptRoot = tools\pad-sync，退两级到仓库根
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script:DeployPath = Join-Path $here 'pad-deploy.ps1'
$script:ConfirmPath = Join-Path $here 'confirm-deploy.ps1'

# 快照选择与 manifest 追加共用 PublishHistory.psm1
# 不要 dot-source pad-release.ps1：它自带 param 块，会把本脚本的
# FlowName / ConfigFile / DryRun / AllowProd 等同名参数一并重置
Import-Module (Join-Path $here 'PublishHistory.psm1') -Force
Import-Module (Join-Path $here 'RobinText.psm1') -Force

function Log([string]$m) { Write-Host "[rollback] $m" }

# 调 pad-deploy 子进程并解析 PAD_DEPLOY_RESULT（最后一行）
function Invoke-DeployFromSnapshot([string]$RobinPath, [string]$CfgFile, [string]$Flow, [string]$Schema, [int]$TimeoutSec, [switch]$PublishOnly) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DeployPath,
        '-SourceRobin', $RobinPath, '-ConfigFile', $CfgFile, '-FlowName', $Flow,
        '-RunTimeoutSec', $TimeoutSec, '-SkipConfirm')
    if ($Schema) { $argList += @('-SchemaFile', $Schema) }
    if ($PublishOnly) { $argList += '-PublishOnly' }
    # 回滚本质也是一次发布，生产流必须显式 -AllowProd
    if ($AllowProd) { $argList += '-AllowProd' }
    $tmp = Join-Path $env:TEMP ('pad-rollback-' + [guid]::NewGuid().ToString('N') + '.log')
    & powershell @argList > $tmp 2>&1
    $json = $null
    foreach ($line in ([IO.File]::ReadAllLines($tmp, [Text.Encoding]::UTF8))) {
        if ($line -match '^PAD_DEPLOY_RESULT=(.+)$') { $json = $Matches[1] }
    }
    if (-not $json) { throw "pad-deploy 无 PAD_DEPLOY_RESULT 输出（日志：$tmp）" }
    return ($json | ConvertFrom-Json)
}

# ═══ 主流程 ═══
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; stage = 'init'; flow = $FlowName; dryRun = [bool]$DryRun
        fromSha256 = $null; targetSha256 = $null; targetSnapshot = $null
        deployedRobin = $null; runId = $null; runStatus = $null
        manifestPath = $null; warnings = @(); errors = @()
    }
    try {
        if (-not $FlowName) { throw '缺少 -FlowName' }
        if (-not $SnapshotsRoot) { $SnapshotsRoot = Join-Path $script:RepoRoot 'snapshots' }
        if (-not $ManifestPath) { $ManifestPath = Join-Path $script:RepoRoot 'manifest.jsonl' }
        if (-not $ConfigFile) { $ConfigFile = Join-Path $script:RepoRoot 'config\sample.json' }
        if (-not (Test-Path $ConfigFile)) { throw "找不到 config.json：$ConfigFile" }
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw '安全熔断：默认只能回滚 PAD_SYNC_TEST。回滚生产流程必须显式 -AllowProd。'
        }

        # ── 阶段 1：定位目标版本 ──
        $result.stage = 'select'
        $all = @(Get-ReleaseSnapshots $SnapshotsRoot $FlowName)
        $target = Select-RollbackSnapshot $SnapshotsRoot $FlowName -Back $Back -To $To
        $result.targetSnapshot = $target.FullName
        $result.targetSha256 = Get-RobinHash ([IO.File]::ReadAllText($target.FullName, [Text.Encoding]::UTF8))
        # 最近一个快照即当前生效版本
        $current = if ($all.Count -gt 0) { $all[$all.Count - 1] } else { $null }
        if ($current) { $result.fromSha256 = Get-RobinHash ([IO.File]::ReadAllText($current.FullName, [Text.Encoding]::UTF8)) }
        Log "当前版本快照：$(if ($current) { $current.Name } else { '无' })"
        Log "回滚目标快照：$($target.Name)（sha $($result.targetSha256.Substring(0, 8))…）"

        if ($DryRun) {
            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            Log '[DryRun] 已定位目标版本，未发布'
        } else {
            # ── 阶段 2：用户确认（回滚也是一次真实发布，会立即跑一次） ──
            $result.stage = 'confirm'
            if (-not $SkipConfirm) {
                $runNote = $(if ($PublishOnly) { '本次只发布、不触发运行。' } else { '回滚后会立即通过 URL 触发一次真实运行。' })
                $msg = "目标流程：$FlowName`n当前快照：$(if ($current) { $current.Name } else { '无' })`n回滚到：$($target.Name)`n`n注意：回滚只还原工作流定义，不会撤销已过账的 SAP 凭证、已发出的邮件或已改动的报表文件。`n$runNote`n`n确定回滚？"
                & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ConfirmPath -Title '回滚确认' -Msg $msg
                if ($LASTEXITCODE -ne 0) { throw '用户取消回滚' }
                Log '用户已确认回滚'
            }

            # ── 阶段 3：发布（复用 pad-deploy 的注入 / 校验 / 运行链路） ──
            # 快照已是成品内容（无 {{VAR}}），复制到临时目录再部署，避免污染 snapshots
            $result.stage = 'publish'
            $tmpDir = Join-Path $env:TEMP ('pad-rollback-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            try {
                $tmpRobin = Join-Path $tmpDir ((Get-SnapshotSafeName $FlowName) + '.robin')
                Copy-Item -LiteralPath $target.FullName -Destination $tmpRobin -Force
                $dep = Invoke-DeployFromSnapshot $tmpRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec -PublishOnly:$PublishOnly
                $result.deployedRobin = [string]$dep.deployedRobinPath
                if (-not $dep.ok) { throw ('回滚发布失败：' + (@($dep.errors) -join '；')) }
                $result.runStatus = [string]$dep.runResult.status
                $result.runId = [string]$dep.runResult.runId
                if ($PublishOnly) { Log '回滚发布完成（-PublishOnly，未触发运行）' }
                else { Log "回滚发布完成，验证运行状态：$($result.runStatus)" }
                $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            } finally {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "回滚失败于 [$($result.stage)]：$($_.Exception.Message)"
    }
    finally {
        # ── 阶段 4：manifest（DryRun 不写；成功失败都记录，供审计） ──
        if (-not $DryRun -and $result.stage -ne 'init') {
            $entry = [ordered]@{
                ts = [datetime]::UtcNow.ToString('o'); type = 'rollback'
                flow = $result.flow
                fromSha256 = $result.fromSha256; targetSha256 = $result.targetSha256
                targetSnapshot = $result.targetSnapshot; deployedRobin = $result.deployedRobin
                runId = $result.runId; runStatus = $result.runStatus
                ok = $result.ok; errors = $result.errors
            }
            try { Add-ManifestEntry $ManifestPath $entry; $result.manifestPath = $ManifestPath; Log "manifest 已追加：$ManifestPath" }
            catch { $result.warnings += "manifest 写入失败：$($_.Exception.Message)" }
        }
        Write-Output ('PAD_ROLLBACK_RESULT=' + ($result | ConvertTo-Json -Depth 10 -Compress))
    }
    exit $exitCode
}
