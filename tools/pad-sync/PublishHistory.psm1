# PublishHistory.psm1 — orchestration-layer history: run records + version snapshots
#
# Used by pad-sync.ps1 (records each run), pad-release.ps1 (writes release snapshots), and
# pad-rollback.ps1 (reads snapshots and appends rollback records).
# It is a module rather than a dot-sourced script because pad-release.ps1 has its own param block:
# dot-sourcing it would also reset the caller's parameters of the same name, which tends to cause silent failures.
#
# Convention: all history goes to business\manifest.jsonl, one JSON per line (JSON Lines),
# with type distinguishing run / release / rollback; no logging action is ever written into the PAD canvas.

# Append one line to manifest.jsonl (UTF-8 without BOM, JSON Lines); the file lives at business\manifest.jsonl
function Add-ManifestEntry([string]$Path, $Entry) {
    $line = ($Entry | ConvertTo-Json -Depth 8 -Compress)
    [IO.File]::AppendAllText($Path, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
}

# Build one run record (a pure function, so it is easy to unit test)
function New-RunManifestEntry {
    param(
        [string]$FlowName, [string]$RunId, [string]$Mode,
        # Not typed [bool]: an unknown result must stay null and must not become false through type coercion (unknown ≠ failure)
        $Ok, [string]$Stage, [string]$Status,
        $Actions, $TotalMs, $ErrorCode, $ErrorMessage,
        [string]$LogPath, $CanvasVerified, $Acceptance,
        $Warnings
    )
    $okValue = $null
    if ($Ok -eq $true) { $okValue = $true }
    elseif ($Ok -eq $false) { $okValue = $false }
    return [ordered]@{
        ts = [datetime]::UtcNow.ToString('o'); type = 'run'
        flow = $FlowName; runId = $RunId; mode = $Mode
        # A [string] parameter turns $null into an empty string; restore it to null so downstream can tell "no value"
        ok = $okValue; stage = $(if ($Stage) { $Stage } else { $null })
        status = $(if ($Status) { $Status } else { $null })
        actions = $Actions; totalMs = $TotalMs
        errorCode = $ErrorCode; errorMessage = $ErrorMessage
        canvasVerified = $CanvasVerified; logPath = $(if ($LogPath) { $LogPath } else { $null })
        acceptance = $Acceptance
        # @($null) yields one element, so test for emptiness explicitly to keep "no warnings" from being recorded as [null]
        warnings = @(if ($null -ne $Warnings) { $Warnings })
    }
}

# Manifest retention: keep run records for only the last N days; release / rollback records are kept forever (rollback and audit need them)
# Lines that fail to parse are always kept: better to keep too much than to silently discard evidence
function Remove-OldManifestEntries([string]$Path, [int]$KeepDays = 90, [datetime]$Now = [datetime]::UtcNow) {
    if ($KeepDays -lt 1) { throw 'KeepDays must be >= 1' }
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

# Snapshot retention: keep only the newest N, deleting the oldest first by file name (timestamp) ascending
# File names are always yyyyMMdd-HHmmss-<sha8>.robin, so lexical order equals chronological order
function Remove-OldReleaseSnapshots([string]$Dir, [int]$Keep = 20) {
    if ($Keep -lt 1) { throw 'Keep must be >= 1' }
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    $files = @(Get-ChildItem -LiteralPath $Dir -File |
        Where-Object { $_.Name -notlike '*.deployed.robin' } |
        Sort-Object Name)
    if ($files.Count -le $Keep) { return @() }
    $remove = @($files | Select-Object -First ($files.Count - $Keep))
    foreach ($f in $remove) { Remove-Item -LiteralPath $f.FullName -Force }
    return $remove
}

# ═══ Version snapshots ═══
# Every successful release stores a copy of "the final .robin with variables substituted" under business\snapshots\<flowName>\,
# with file name = <timestamp>-<first 8 sha chars>.robin.
# PAD's cloud flowVersion is only an ETag and cannot "switch back to the previous version" directly,
# so rollback can only re-send a local snapshot; this is the single source of those snapshots.

# Flow names may contain path separators or other illegal characters; replace them before using the name as a directory name
function Get-SnapshotSafeName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) { throw 'flow name is empty; cannot locate the snapshot dir' }
    return $safe
}

# Snapshot directory for a flow (not guaranteed to exist)
function Get-ReleaseSnapshotDir([string]$SnapshotsRoot, [string]$FlowName) {
    return (Join-Path $SnapshotsRoot (Get-SnapshotSafeName $FlowName))
}

# Archive one snapshot and return its full path after archiving
function Save-ReleaseSnapshot([string]$SnapshotsRoot, [string]$FlowName, [string]$DeployedRobin,
                              [string]$Sha256, [datetime]$Timestamp) {
    $dir = Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $name = $Timestamp.ToString('yyyyMMdd-HHmmss') + '-' + $Sha256.Substring(0, 8) + '.robin'
    $dest = Join-Path $dir $name
    Copy-Item -LiteralPath $DeployedRobin -Destination $dest -Force
    return $dest
}

# List all snapshots of a flow in ascending time order (the file-name prefix is the timestamp, so lexical order equals time order)
# Exclude deployment intermediates like *.deployed.robin so substitution temp files are never mistaken for versions
function Get-ReleaseSnapshots([string]$SnapshotsRoot, [string]$FlowName) {
    $dir = Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.robin' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.deployed.robin' } |
        Sort-Object Name)
}

# Choose the rollback target
#   -To      : specify exactly by full path / file name / sha prefix (8 chars)
#   -Back N  : skip the newest N snapshots; the default 1 = roll back one version
# The newest snapshot is usually the currently active version, so it is skipped by default
function Select-RollbackSnapshot([string]$SnapshotsRoot, [string]$FlowName, [int]$Back = 1, [string]$To) {
    $all = @(Get-ReleaseSnapshots $SnapshotsRoot $FlowName)
    if ($all.Count -eq 0) {
        throw "flow '$FlowName' has no snapshots (snapshot dir: $(Get-ReleaseSnapshotDir $SnapshotsRoot $FlowName))"
    }
    if ($To) {
        $hit = @($all | Where-Object {
            $_.FullName -eq $To -or $_.Name -eq $To -or $_.Name -like ('*-' + $To + '.robin')
        })
        if ($hit.Count -eq 0) { throw "snapshot not found: $To" }
        if ($hit.Count -gt 1) { throw "snapshot id '$To' matched multiple files; write the full file name" }
        return $hit[0]
    }
    if ($Back -lt 1) { throw '-Back must be >= 1 (1 means roll back one version)' }
    $idx = $all.Count - 1 - $Back
    if ($idx -lt 0) { throw "not enough snapshots: only $($all.Count) version(s) exist; cannot go back $Back version(s)" }
    return $all[$idx]
}

Export-ModuleMember -Function Add-ManifestEntry, New-RunManifestEntry, Get-SnapshotSafeName,
    Get-ReleaseSnapshotDir, Save-ReleaseSnapshot, Get-ReleaseSnapshots, Select-RollbackSnapshot,
    Remove-OldReleaseSnapshots, Remove-OldManifestEntries
