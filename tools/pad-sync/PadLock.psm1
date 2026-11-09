# PadLock.psm1 — cross-process mutual exclusion: only one flow may occupy PAD at a time
#
# Why a named mutex instead of a plain lock file:
#   A lock file survives when the process is killed hard, so the waiter cannot tell "really running" from "leftover",
#   and can only guess from PID/heartbeat; a wrong guess means waiting forever. A named mutex is maintained by the OS
#   and released the moment the process ends, so a stale lock simply cannot exist.
#
# The lock file (%LOCALAPPDATA%\flow-ir\pad-run.lock.json) is only for observability:
#   it is written once when the lock is acquired, recording the owning flow, PID, process start time, and start time,
#   so a waiter can print "who is occupying PAD". It is not part of the mutual-exclusion decision and carries no heartbeat;
#   deleting it does not affect correctness.

$script:Mutex = $null
$script:LockPath = $null
$script:Held = $false
$script:WaitedSec = 0
$script:StartedAt = $null

function Get-PadLockFile {
    $dir = Join-Path $env:LOCALAPPDATA 'flow-ir'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'pad-run.lock.json')
}

# Write the lock file. Called once when the lock is acquired, never refreshed per log line (that would rewrite the whole file for every line)
function Write-PadLockInfo {
    param([string]$FlowName)
    if (-not $script:LockPath) { return }
    $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    $info = [ordered]@{
        flow = $FlowName
        pid = $PID
        processStart = $(if ($proc) { $proc.StartTime.ToString('o') } else { $null })
        holder = "$env:USERDOMAIN\$env:USERNAME"
        startedAt = $script:StartedAt
    }
    try {
        [IO.File]::WriteAllText($script:LockPath, ($info | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-PadLockInfo {
    if (-not $script:LockPath -or -not (Test-Path -LiteralPath $script:LockPath)) { return $null }
    try { return ([IO.File]::ReadAllText($script:LockPath, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Reset-PadLockInfo {
    if ($script:LockPath -and (Test-Path -LiteralPath $script:LockPath)) {
        try { Remove-Item -LiteralPath $script:LockPath -Force } catch { }
    }
}

# Whether the process described by the lock file is still alive (PIDs get reused, so compare the start time too)
function Test-LockHolderAlive {
    param($Info)
    if (-not $Info -or -not $Info.pid) { return $false }
    $p = Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try { return ([math]::Abs(($p.StartTime - [datetime]$Info.processStart).TotalSeconds) -lt 5) } catch { return $true }
}

# Acquire the lock: wait up to WaitSec seconds, retrying once per second.
# Returns [pscustomobject]@{ ok; waitedSec }:
#   It used to return a bare boolean, so a caller that wanted "how long did I wait" had to call Get-PadLockState as well —
#   a whole extra export surface opened up for one field. Now the verdict and the wait duration come back together,
#   so the module needs only this one entry point and the internal counter stays private.
function Enter-PadRunLock {
    param(
        [Parameter(Mandatory = $true)][string]$FlowName,
        [int]$WaitSec = 1800,
        # Logging callback; falls back to writing to the console when not supplied
        [scriptblock]$Logger
    )
    $log = if ($Logger) { $Logger } else { { param($m) Write-Host "[pad-lock] $m" } }

    $script:LockPath = Get-PadLockFile
    $script:Held = $false
    $script:WaitedSec = 0
    if (-not $script:Mutex) {
        $script:Mutex = New-Object System.Threading.Mutex($false, 'flow-ir-pad-run')
    }

    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ($true) {
        try {
            if ($script:Mutex.WaitOne(1000)) { break }
        } catch [System.Threading.AbandonedMutexException] {
            # The previous holder exited abnormally: the lock now belongs to this run, so take it over instead of waiting on it as a leftover
            & $log 'detected an abnormal end of the previous run; lock taken over'
            break
        }
        $script:WaitedSec++
        if ($script:WaitedSec % 15 -eq 0) {
            $info = Get-PadLockInfo
            if ($info) {
                $alive = if (Test-LockHolderAlive $info) { 'still alive' } else { 'already exited (stale lock file)' }
                & $log ("waiting for PAD: {0}s elapsed; held by {1} (pid {2}, {3})" -f `
                    $script:WaitedSec, $info.flow, $info.pid, $alive)
            } else {
                & $log "waiting for PAD: $($script:WaitedSec)s elapsed"
            }
        }
        if ((Get-Date) -ge $deadline) {
            return [pscustomobject]@{ ok = $false; waitedSec = $script:WaitedSec }
        }
    }

    $script:Held = $true
    $script:StartedAt = (Get-Date).ToString('o')
    Write-PadLockInfo $FlowName
    return [pscustomobject]@{ ok = $true; waitedSec = $script:WaitedSec }
}

function Exit-PadRunLock {
    if (-not $script:Held) { return }
    try { $script:Mutex.ReleaseMutex() } catch { }
    $script:Held = $false
    Reset-PadLockInfo
}

Export-ModuleMember -Function Get-PadLockFile, Write-PadLockInfo, Get-PadLockInfo,
    Reset-PadLockInfo, Test-LockHolderAlive, Enter-PadRunLock, Exit-PadRunLock
