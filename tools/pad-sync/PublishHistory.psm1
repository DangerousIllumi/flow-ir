# PublishHistory.psm1 — 编排层历史：运行记录 + 版本快照
#
# 被 pad-sync.ps1（记录每次运行）、pad-release.ps1（写发布快照）、
# pad-rollback.ps1（读快照、追加回滚记录）共用。
# 抽成模块而不是 dot-source，是因为 pad-release.ps1 自身带 param 块，
# dot-source 时会把调用脚本的同类参数一并重置，容易出隐蔽故障。
#
# 约定：所有历史都写在仓库根 manifest.jsonl，一行一个 JSON（JSON Lines），
# type 区分 run / release / rollback；PAD 画布内不写任何日志动作。

# manifest.jsonl 追加一行（UTF-8 无 BOM，JSON Lines）
function Add-ManifestEntry([string]$Path, $Entry) {
    $line = ($Entry | ConvertTo-Json -Depth 8 -Compress)
    [IO.File]::AppendAllText($Path, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

# 构造一条运行记录（纯函数，便于单测）
function New-RunManifestEntry {
    param(
        [string]$FlowName, [string]$RunId, [string]$Mode,
        [bool]$Ok, [string]$Stage, [string]$Status,
        $Actions, $TotalMs, $ErrorCode, $ErrorMessage,
        [string]$LogPath, $CanvasVerified, $Acceptance,
        $Warnings
    )
    return [ordered]@{
        ts = [datetime]::UtcNow.ToString('o'); type = 'run'
        flow = $FlowName; runId = $RunId; mode = $Mode
        # [string] 参数会把 $null 转成空串，这里还原成 null，便于下游判断“没有值”
        ok = $Ok; stage = $(if ($Stage) { $Stage } else { $null })
        status = $(if ($Status) { $Status } else { $null })
        actions = $Actions; totalMs = $TotalMs
        errorCode = $ErrorCode; errorMessage = $ErrorMessage
        canvasVerified = $CanvasVerified; logPath = $(if ($LogPath) { $LogPath } else { $null })
        acceptance = $Acceptance
        # @($null) 会得到 1 个元素，显式判空避免“没有警告”被记成 [null]
        warnings = @(if ($null -ne $Warnings) { $Warnings })
    }
}

# manifest 保留策略：run 记录只留最近 N 天；release / rollback 永久保留（回滚与审计要用）
# 解析失败的行一律保留，宁可多留也不静默丢证据
function Remove-OldManifestEntries([string]$Path, [int]$KeepDays = 90, [datetime]$Now = [datetime]::UtcNow) {
    if ($KeepDays -lt 1) { throw 'KeepDays 必须 >= 1' }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $cut = $Now.ToUniversalTime().AddDays(-$KeepDays)
    $keep = New-Object System.Collections.Generic.List[string]
    $removed = 0
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        $rec = $null
        try { $rec = $line | ConvertFrom-Json } catch { $keep.Add($line); continue }
        if ([string]$rec.type -eq 'release' -or [string]$rec.type -eq 'rollback') { $keep.Add($line); continue }
        $ts = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$rec.ts, [ref]$ts)) { $keep.Add($line); continue }
        if ($ts.ToUniversalTime() -ge $cut) { $keep.Add($line) } else { $removed++ }
    }
    if ($removed -gt 0) {
        $tmp = $Path + '.tmp'
        $text = if ($keep.Count -gt 0) { ($keep -join "`r`n") + "`r`n" } else { '' }
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    return $removed
}

# 快照保留：只保留最新 N 个，按文件名（时间戳）升序删除最旧的
# 文件名格式固定为 yyyyMMdd-HHmmss-<sha8>.robin，字符串排序即时间排序
function Remove-OldReleaseSnapshots([string]$Dir, [int]$Keep = 20) {
    if ($Keep -lt 1) { throw 'Keep 必须 >= 1' }
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -File |
        Where-Object { $_.Name -notlike '*.deployed.robin' } |
        Sort-Object Name)
    if ($files.Count -le $Keep) { return @() }
    $remove = @($files | Select-Object -First ($files.Count - $Keep))
    foreach ($f in $remove) { Remove-Item -LiteralPath $f.FullName -Force }
    return $remove
}

# ═══ 版本快照 ═══
# 每次成功发布都把「已替换变量的成品 .robin」存一份到 snapshots\<flowName>\，
# 文件名 = <时间戳>-<sha前8>.robin。
# PAD 云端的 flowVersion 只是 ETag，无法直接「切回上一版」，
# 所以回滚只能靠本地快照重发，这里就是那份快照的唯一来源。

# 流程名可能含路径分隔符等非法字符，落成目录名前统一替换
function Get-SnapshotSafeName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) { throw '流程名为空，无法定位快照目录' }
    return $safe
}

# 某流程的快照目录（不保证已存在）
function Get-ReleaseSnapshotDir([string]$SnapshotsRoot, [string]$FlowName) {
    return (Join-Path $SnapshotsRoot (Get-SnapshotSafeName $FlowName))
}

# 归档一份快照，返回归档后的完整路径
function Save-ReleaseSnapshot([string]$SnapshotsRoot, [string]$FlowName, [string]$DeployedRobin,
                              [string]$Sha256, [datetime]$Timestamp) {
    $dir = Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $name = $Timestamp.ToString('yyyyMMdd-HHmmss') + '-' + $Sha256.Substring(0, 8) + '.robin'
    $dest = Join-Path $dir $name
    Copy-Item -LiteralPath $DeployedRobin -Destination $dest -Force
    return $dest
}

# 列出某流程的全部快照，按时间升序（文件名前缀即时间戳，字典序等于时间序）
# 排除 *.deployed.robin 这类部署中间产物，避免把替换临时文件当成版本
function Get-ReleaseSnapshots([string]$SnapshotsRoot, [string]$FlowName) {
    $dir = Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.robin' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.deployed.robin' } |
        Sort-Object Name)
}

# 选回滚目标
#   -To      ：按完整路径 / 文件名 / sha 前缀（8 位）精确指定
#   -Back N  ：跳过最近 N 个快照，默认 1 = 回退到上一个版本
# 最近一个快照通常就是当前生效版本，所以默认要跳过它
function Select-RollbackSnapshot([string]$SnapshotsRoot, [string]$FlowName, [int]$Back = 1, [string]$To) {
    $all = @(Get-ReleaseSnapshots $SnapshotsRoot $FlowName)
    if ($all.Count -eq 0) {
        throw "流程「$FlowName」没有任何快照（快照目录：$(Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName)）"
    }
    if ($To) {
        $hit = @($all | Where-Object {
            $_.FullName -eq $To -or $_.Name -eq $To -or $_.Name -like ('*-' + $To + '.robin')
        })
        if ($hit.Count -eq 0) { throw "找不到快照：$To" }
        if ($hit.Count -gt 1) { throw "快照标识「$To」匹配到多个文件，请写完整文件名" }
        return $hit[0]
    }
    if ($Back -lt 1) { throw '-Back 必须 ≥ 1（1 表示回退到上一个版本）' }
    $idx = $all.Count - 1 - $Back
    if ($idx -lt 0) { throw "快照不足：当前只有 $($all.Count) 个版本，无法回退 $Back 个版本" }
    return $all[$idx]
}

Export-ModuleMember -Function Add-ManifestEntry, New-RunManifestEntry, Get-SnapshotSafeName,
    Get-ReleaseSnapshotDir, Save-ReleaseSnapshot, Get-ReleaseSnapshots, Select-RollbackSnapshot,
    Remove-OldReleaseSnapshots, Remove-OldManifestEntries
