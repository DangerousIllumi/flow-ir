# pad-fingerprint.ps1 — 流程指纹基线：查看定位结果、播种（-Set）与人工确认
#
# 为什么需要：
#   pad-admit 第 12 项（FINGERPRINT）要拿「当前 .robin / config / acceptance」与一份基线比对。
#   基线只由三个写入侧产生：pad-release 成功、pad-rollback 成功、本脚本 -Set（存量流播种）。
#
# 硬约束：
#   1) 定位精确到修订（修订目录名 = 本次 runId），不「取最新一份」；
#      命中多个候选直接报 AMBIGUOUS 并停下，绝不自动挑一个。
#   2) -Set 只打印定位结果与三个哈希，必须再加 -Confirm 才写；
#      -DryRun 永远不写。禁止在无人确认时静默写基线。
#   3) 基线落在 business\fingerprints\<流程名>.json（业务层，不入库）。
#
# 用法：
#   .\pad-fingerprint.ps1 -FlowName X                        # 只看定位结果，不写
#   .\pad-fingerprint.ps1 -FlowName X -Set                   # 打印后退出码 2，要求加 -Confirm
#   .\pad-fingerprint.ps1 -FlowName X -Set -Confirm          # 人工确认后写入基线
#
# 输出：最后一行 PAD_FINGERPRINT_RESULT=<JSON>；退出码 0 成功 / 1 定位失败 / 2 需要确认或候选不唯一

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowName,
    [string]$RepoRoot,
    # PAD 本地运行历史与 Workspace 根：默认取 LOCALAPPDATA，可用参数覆盖（测试用假根目录）
    [string]$ScriptsRoot,
    [string]$WorkspaceRoot,
    [string]$ConsoleConfigPath,
    [string]$ConfigFile,
    [string]$AcceptanceFile,
    [string]$BaselinePath,
    # 业务流文件；不传时按 -FlowName 的 pad_flow_name 在 business\flows 反查
    [string]$FlowFile,
    [string]$EnvironmentId,
    # 仓库外旧拷贝的绝对路径（PAD 运行目录下的同名文件）；只在播种时写入 external 段
    [string[]]$ExternalPaths,
    [switch]$Set,
    [switch]$DryRun,
    [switch]$Confirm,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
# 先导入模块：下面的默认路径计算会用到 Get-FingerprintBaselinePath
Import-Module (Join-Path $here 'PadFingerprint.psm1') -Force

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $here) }
if (-not $ScriptsRoot) {
    $ScriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
}
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
}
# ── 业务流标识：与 pad-admit 同一套解析 ──────────────────────────
# PAD 流程名（中文）用于在本地运行历史里定位流程，
# 但仓库侧产物（.robin / config / acceptance / 基线）一律用 flow.json 文件名命名；
# 两者不是一个名字时若混用，基线会写到准入读不到的位置（永远 NO_BASELINE）。
function Resolve-FlowFileByName([string]$FlowsDir, [string]$Name) {
    if (-not $Name -or -not (Test-Path -LiteralPath $FlowsDir)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $FlowsDir -Filter '*.json' -File | Where-Object {
        $_.Name -notmatch '\.(acceptance|schema)\.json$'
    } | ForEach-Object {
        $j = $null
        try { $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
        [ordered]@{ File = $_.FullName; Json = $j }
    })
    # 先按 pad_flow_name 精确匹配；命中不唯一时不做猜测
    $hit = @($items | Where-Object { [string]$_.Json.pad_flow_name -eq $Name })
    if ($hit.Count -eq 1) { return $hit[0].File }
    return $null
}

if (-not $FlowFile) { $FlowFile = Resolve-FlowFileByName (Join-Path $RepoRoot 'business\flows') $FlowName }
# 反查不到时退回 PAD 流程名（存量流可能还没有 pad_flow_name）
$businessName = if ($FlowFile) {
    [IO.Path]::GetFileNameWithoutExtension($FlowFile)
} else { $FlowName }

if (-not $ConfigFile) {
    $guess = Join-Path $RepoRoot ("business\config\{0}.json" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $ConfigFile = $guess }
}
if (-not $AcceptanceFile) {
    # 与 pad-release 同一口径：业务流目录下同名的 <flow>.acceptance.json
    $guess = Join-Path $RepoRoot ("business\flows\{0}.acceptance.json" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $AcceptanceFile = $guess }
}
if (-not $BaselinePath) { $BaselinePath = Get-FingerprintBaselinePath $RepoRoot $businessName }

function Log([string]$m) { Write-Host "[fingerprint] $m" }
if ($businessName -ne $FlowName) {
    Log "业务流：$businessName（基线/产物按 flow.json 文件名命名，与 pad-admit 一致）"
}

$result = [ordered]@{
    ok = $false; flow = $FlowName; stage = 'locate'
    flowGuid = $null; runId = $null; revisionDir = $null
    workspaceRobin = $null; workspaceMtime = $null
    hashes = $null; baselinePath = $BaselinePath; written = $false
    environmentId = $null; code = $null; message = $null
}
$exitCode = 1

try {
    # ── 定位：流程身份来自本地运行历史，定义副本精确到本次 runId ──
    $run = Find-LatestFlowRun $ScriptsRoot $FlowName
    if (-not $run) {
        $result.code = 'FINGERPRINT_UNKNOWN'
        throw "本地运行历史里找不到流程 $FlowName，无法定位修订（请先正常跑一次该流程）"
    }
    $ids = Get-FlowGuidFromLogPath ([string]$run.path)
    $result.flowGuid = [string]$run.flowGuid
    $result.runId = $(if ($ids) { [string]$ids.runId } else { $null })
    $since = [datetime]::Parse([string]$run.startTime).ToUniversalTime()
    $wsRobin = Find-WorkspaceRobin $WorkspaceRoot $result.flowGuid $result.runId $since
    if (-not $wsRobin) {
        $result.code = 'FINGERPRINT_UNKNOWN'
        throw "Workspace 里找不到本次运行（runId=$($result.runId)）对应的已发布定义（flowGuid=$($result.flowGuid)）；不退回取最新一份"
    }
    $result.workspaceRobin = $wsRobin
    $result.revisionDir = Split-Path -Parent $wsRobin
    $result.workspaceMtime = (Get-Item -LiteralPath $wsRobin).LastWriteTime.ToString('o')
    $result.environmentId = $(if ($EnvironmentId) { $EnvironmentId } else { Get-PadEnvironmentId $ConsoleConfigPath })

    # 源 .robin 取流程产物；找不到时退回已发布副本（由日志显式提示）
    # 源 .robin 与 pad-admit 比对的是同一份文件：按 flow.json 文件名取，取不到才退回已发布副本
    $sourceRobin = $null
    $guess = Join-Path $RepoRoot ("business\flows\{0}.robin" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $sourceRobin = $guess } else { $sourceRobin = $wsRobin }
    $result.hashes = Get-FingerprintParts $sourceRobin $ConfigFile $AcceptanceFile
    $sha = @()
    foreach ($k in @('robin', 'config', 'acceptance')) {
        $v = $result.hashes[$k]
        $sha += ('{0}={1}' -f $k, $(if ($v) { $v } else { '(缺失)' }))
    }

    Log "流程：$FlowName"
    Log "修订目录：$($result.revisionDir)"
    Log "Workspace：$wsRobin"
    Log "修改时间：$($result.workspaceMtime)"
    Log "三个哈希：$($sha -join ' ')"
    Log "基线文件：$BaselinePath"

    # ── 写入：必须 -Set + -Confirm，且 -DryRun 永远不写 ──
    if ($Set -and -not $DryRun) {
        if (-not $Confirm) {
            $result.stage = 'need-confirm'; $result.code = 'FINGERPRINT_CONFIRM_REQUIRED'
            $result.message = '定位结果已打印；确认无误后加 -Confirm 才会写基线'
            Log '未加 -Confirm：不写基线（防止静默播种）'
            $exitCode = 2
        } else {
            $base = New-FingerprintBaseline -FlowName $FlowName -FlowGuid $result.flowGuid `
                -EnvironmentId $result.environmentId -SourceRobin $sourceRobin `
                -WorkspaceRobin $wsRobin -ConfigPath $ConfigFile -AcceptancePath $AcceptanceFile `
                -ExternalPaths $ExternalPaths
            [void](Write-FingerprintBaseline $BaselinePath $base)
            $result.written = $true
            $result.stage = 'done'; $result.ok = $true; $result.code = 'OK'
            $result.message = '基线已写入'
            Log "基线已写入：$BaselinePath"
            $exitCode = 0
        }
    } else {
        $result.stage = 'done'; $result.ok = $true; $result.code = 'OK'
        $result.message = $(if ($DryRun) { 'DryRun：只查看，不写基线' } else { '只查看，不写基线（加 -Set 才播种）' })
        $exitCode = 0
    }
} catch {
    if (-not $result.code) {
        if ($_.Exception.Message -match '个候选修订') { $result.code = 'FINGERPRINT_AMBIGUOUS' }
        else { $result.code = 'FINGERPRINT_UNKNOWN' }
    }
    $result.message = $_.Exception.Message
    Log "失败：$($_.Exception.Message)"
    if ($result.code -eq 'FINGERPRINT_AMBIGUOUS') { $exitCode = 2 }
} finally {
    if (-not $Json) {
        Log ("结果：{0} {1}（written={2}）" -f $result.code, $result.message, $result.written)
    }
    Write-Output ('PAD_FINGERPRINT_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
}
exit $exitCode
