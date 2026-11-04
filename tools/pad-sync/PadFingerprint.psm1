# PadFingerprint.psm1 — 流程指纹：Workspace 修订定位、身份解析、基线读写与比对
#
# 为什么单独成模块：
#   1) 「精确到修订、禁止取最新」的 Workspace 定位与身份解析必须是唯一实现；
#      pad-release.ps1（发布后写基线）、pad-rollback.ps1（回滚后重写基线）、
#      pad-fingerprint.ps1（存量流播种）、pad-admit.ps1（准入第 12 项）都从这里取，
#      避免出现第二套哈希/定位实现。
#   2) 对所有 flow.json 一视同仁：本模块不含任何「只对某条流程生效」的分支。
#
# 分层边界：
#   机制（定位、哈希、比对）在公开层；
#   基线数据写在 business\fingerprints\<流程名>.json（含流程名、flowGuid、
#   environmentId、机器名与真实路径），只在业务层，不入库、不推公开库。

# 从 Actions.log 路径解析流程 GUID 与 runId：
#   ...\Console\Scripts\<flowGuid>\Runs\<runId>\Actions.log
function Get-FlowGuidFromLogPath([string]$LogPath) {
    $m = [regex]::Match($LogPath, 'Scripts\\([0-9a-fA-F-]{36})\\Runs\\([0-9a-fA-F-]{36})\\')
    if (-not $m.Success) { return $null }
    return [ordered]@{ flowGuid = $m.Groups[1].Value.ToLower(); runId = $m.Groups[2].Value }
}

# 在本地运行历史里找该流程最近一次运行的定义信息（按 startTime 取最新）
# 返回：flowGuid / flowVersion（云端版本 ETag）/ startTime / status / path；找不到返回 $null
# 注意：这里只用于「按流程名解析身份」，不用于定位要比对的定义副本；
#       定义副本一律走 Find-WorkspaceRobin 的精确修订规则。
function Find-LatestFlowRun([string]$ScriptsRoot, [string]$FlowName) {
    if (-not $ScriptsRoot -or -not (Test-Path $ScriptsRoot)) { return $null }
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

# 已发布流程的本地定义副本：Console\Workspace\<flowGuid>\<修订目录>\script.robin
# 精确匹配本次发布/运行的修订，绝不退化成「取最新一份」（同机并发时会拿别人的定义来比对）：
#   1) 修订目录名等于本次 runId 时直接采用（与 PadDesigner 的运行目录同一口径）；
#   2) 否则只认「本次发布之后写入」的修订；命中多个视为无法确定并报错。
function Find-WorkspaceRobin([string]$WorkspaceRoot, [string]$FlowGuid, [string]$RunId, [datetime]$SinceUtc) {
    if (-not $WorkspaceRoot -or -not $FlowGuid) { return $null }
    $dir = Join-Path $WorkspaceRoot $FlowGuid
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $all = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'script.robin' -ErrorAction SilentlyContinue)
    $hit = @($all | Where-Object {
        ($RunId -and $_.Directory.Name -eq $RunId) -or
        ($_.LastWriteTime.ToUniversalTime() -ge $SinceUtc.AddMinutes(-2))
    })
    if ($hit.Count -gt 1) {
        throw ("Workspace 里有 $($hit.Count) 个候选修订，无法确定本次发布对应哪一份：" +
            (($hit | ForEach-Object { $_.Directory.Name }) -join '、'))
    }
    if ($hit.Count -eq 1) { return $hit[0].FullName }
    return $null
}

# 从 PAD 控制台配置读取当前环境 ID（console.config 的 UserConfigs 里首个 EnvironmentId）
# 读不到返回 $null：基线里记 null，准入时不比较环境，避免臆造身份
function Get-PadEnvironmentId([string]$ConsoleConfigPath) {
    if (-not $ConsoleConfigPath) {
        $ConsoleConfigPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\console.config'
    }
    if (-not (Test-Path -LiteralPath $ConsoleConfigPath)) { return $null }
    try {
        $j = [IO.File]::ReadAllText($ConsoleConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.UserConfigs.PSObject.Properties) {
            if ($p.Value -and $p.Value.EnvironmentId) { return [string]$p.Value.EnvironmentId }
        }
    } catch { return $null }
    return $null
}

# 三份文件的 SHA256（小写）。缺失的文件记 null，调用方据此判「读不到」
function Get-FingerprintParts([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    $parts = [ordered]@{ robin = $null; config = $null; acceptance = $null }
    foreach ($pair in @(@('robin', $RobinPath), @('config', $ConfigPath), @('acceptance', $AcceptancePath))) {
        if ($pair[1] -and (Test-Path -LiteralPath $pair[1])) {
            $parts[$pair[0]] = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLower()
        }
    }
    return $parts
}

# 基线文件位置：business\fingerprints\<流程名>.json（业务层，不入库）
function Get-FingerprintBaselinePath([string]$RepoRoot, [string]$FlowName) {
    return (Join-Path (Join-Path (Join-Path $RepoRoot 'business') 'fingerprints') ($FlowName + '.json'))
}

# 读基线。不抛异常：返回 ok/code/message，由调用方决定按 warn 还是 fail
function Read-FingerprintBaseline([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_NO_BASELINE'; message = '没有指纹基线'; data = $null }
    }
    try {
        $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "基线无法解析：$($_.Exception.Message)"; data = $null }
    }
    foreach ($k in @('flow', 'hashes')) {
        if ($j.PSObject.Properties.Name -notcontains $k) {
            return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "基线缺少字段 $k"; data = $null }
        }
    }
    if ($j.hashes.PSObject.Properties.Name -notcontains 'robin' -or -not $j.hashes.robin) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = '基线缺少 robin 哈希'; data = $null }
    }
    return [ordered]@{ ok = $true; code = $null; message = '基线可读'; data = $j }
}

# 写基线：先写临时文件再原子替换，避免半份 JSON
function Write-FingerprintBaseline([string]$Path, $Baseline) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Baseline | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $Path
}

# 构造一份基线记录（哈希与修改时间都在这里算，避免调用方各写一份）
function New-FingerprintBaseline {
    param(
        [string]$FlowName, [string]$FlowGuid, [string]$EnvironmentId,
        [string]$SourceRobin, [string]$WorkspaceRobin,
        [string]$ConfigPath, [string]$AcceptancePath, [string]$Machine
    )
    $parts = Get-FingerprintParts $SourceRobin $ConfigPath $AcceptancePath
    $mtime = $null
    if ($WorkspaceRobin -and (Test-Path -LiteralPath $WorkspaceRobin)) {
        $mtime = (Get-Item -LiteralPath $WorkspaceRobin).LastWriteTime.ToString('o')
    }
    return [ordered]@{
        version       = 1
        flow          = $FlowName
        flowGuid      = $FlowGuid
        environmentId = $EnvironmentId
        machine       = $(if ($Machine) { $Machine } else { $env:COMPUTERNAME })
        sourceRobin   = $SourceRobin
        workspaceRobin = $WorkspaceRobin
        workspaceMtime = $mtime
        hashes        = $parts
        seededAt      = [datetime]::UtcNow.ToString('o')
    }
}

# 比对当前文件与基线/批准记录，返回统一结果：
#   status = pass / warn / fail；code + message + evidence
# 默认 Mode=warn：新基线机制先只告警，等真实运行观察无误后再单独提交切 fail
function Test-FlowFingerprint {
    param(
        [string]$FlowName,
        [string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath,
        [string]$BaselinePath,
        [string]$ScriptsRoot,
        [string]$EnvironmentId, [string]$Machine,
        [string]$ApprovePath,
        [ValidateSet('warn', 'fail')][string]$Mode = 'warn'
    )
    if (-not $Machine) { $Machine = $env:COMPUTERNAME }
    $parts = Get-FingerprintParts $RobinPath $ConfigPath $AcceptancePath
    $nonPass = $(if ($Mode -eq 'fail') { 'fail' } else { 'warn' })
    $fpLine = (@('robin', 'config', 'acceptance') | Where-Object { $parts[$_] } |
        ForEach-Object { "$_=$($parts[$_].Substring(0, 12))" }) -join ' '

    # 读不到 robin：连「这份流程是什么」都无法证明
    if (-not $parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = "读不到 .robin，无法计算指纹：$RobinPath"
            evidence = @("robin=$RobinPath")
        }
    }

    # 1) 有批准记录：先按批准记录绑定（这条是硬约束，始终 fail）
    if ($ApprovePath -and (Test-Path -LiteralPath $ApprovePath)) {
        $ok = $false
        foreach ($l in [IO.File]::ReadAllLines($ApprovePath, [Text.Encoding]::UTF8)) {
            if (-not $l.Trim()) { continue }
            try { $rec = $l | ConvertFrom-Json } catch { continue }
            if ([string]$rec.robin -eq [string]$parts.robin -and
                [string]$rec.config -eq [string]$parts.config -and
                [string]$rec.acceptance -eq [string]$parts.acceptance) { $ok = $true; break }
        }
        if ($ok) {
            return [ordered]@{ status = 'pass'; code = 'OK'; message = "与批准记录一致：$fpLine"; evidence = @($ApprovePath) }
        }
        return [ordered]@{
            status = 'fail'; code = 'FINGERPRINT_MISMATCH'
            message = "与批准记录不一致：$fpLine"
            evidence = @("approve=$ApprovePath")
        }
    }

    # 2) 没有基线：存量流还没播种，按 warn（后续单独切 fail）
    $read = Read-FingerprintBaseline $BaselinePath
    if (-not $read.ok) {
        return [ordered]@{
            status = $nonPass; code = $read.code
            message = "$($read.message)：$BaselinePath"
            evidence = @("baseline=$BaselinePath", "now=$fpLine")
        }
    }
    $base = $read.data
    $baseShort = [string]$base.hashes.robin
    if ($baseShort.Length -gt 12) { $baseShort = $baseShort.Substring(0, 12) }
    $ev = @("baseline=$BaselinePath", "now=$fpLine", "baselined=$baseShort")

    # 3) 身份：流程 GUID / 环境 / 机器任一不符，说明基线不是当前这份运行
    if ($ScriptsRoot) {
        $run = Find-LatestFlowRun $ScriptsRoot $FlowName
        if (-not $run) {
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
                message = "本地运行历史里找不到流程 $FlowName，无法解析身份"
                evidence = @("scriptsRoot=$ScriptsRoot")
            }
        }
        if ($base.flowGuid -and [string]$base.flowGuid -ne [string]$run.flowGuid) {
            $ev += "flowGuid 基线=$($base.flowGuid) 当前=$($run.flowGuid)"
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_FLOW_STALE'
                message = '基线对应的流程 GUID 已变化（流程被重建或换了目标）'
                evidence = $ev
            }
        }
    }
    if ($base.environmentId -and $EnvironmentId -and [string]$base.environmentId -ne [string]$EnvironmentId) {
        $ev += "environmentId 基线=$($base.environmentId) 当前=$EnvironmentId"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = '基线与当前 PAD 环境不一致'
            evidence = $ev
        }
    }
    if ($base.machine -and [string]$base.machine -ne [string]$Machine) {
        $ev += "machine 基线=$($base.machine) 当前=$Machine"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = '基线与当前机器不一致'
            evidence = $ev
        }
    }

    # 4) 内容：源 .robin 或 config 漂移
    if ([string]$base.hashes.robin -ne [string]$parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_SOURCE_MISMATCH'
            message = '源 .robin 与基线不一致（流程定义有改动，需要重新发布或重新播种）'
            evidence = $ev
        }
    }
    if ($base.hashes.config -and [string]$base.hashes.config -ne [string]$parts.config) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_CONFIG_STALE'
            message = '部署配置与基线不一致（变量替换结果会变）'
            evidence = $ev
        }
    }
    return [ordered]@{ status = 'pass'; code = 'OK'; message = "与基线一致：$fpLine"; evidence = @($BaselinePath) }
}

Export-ModuleMember -Function Get-FlowGuidFromLogPath, Find-LatestFlowRun, Find-WorkspaceRobin,
    Get-PadEnvironmentId, Get-FingerprintParts, Get-FingerprintBaselinePath,
    Read-FingerprintBaseline, Write-FingerprintBaseline, New-FingerprintBaseline, Test-FlowFingerprint
