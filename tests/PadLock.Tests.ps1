# PadLock.Tests.ps1 — cross-process mutual exclusion tests
#
# Covers three real paths:
#   1) While the lock is held, another process queues and times out with failure (no barging in)
#   2) After the holder releases, the queued side acquires the lock immediately
#   3) A leftover lock file never causes a hang (the Mutex is authoritative; the file is display-only)
#
# Verified with real child processes: a Mutex is reentrant inside one process, so concurrency cannot be observed there.

$script:LockMod = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\pad-sync\PadLock.psm1')).Path
Import-Module $script:LockMod -Force

# Grab the lock in a child process and return a single result line
function Invoke-ChildLockAttempt([string]$FlowName, [int]$WaitSec) {
    $code = "Import-Module '$script:LockMod' -Force; " +
        "`$r = Enter-PadRunLock -FlowName '$FlowName' -WaitSec $WaitSec; " +
        "if (`$r.ok) { 'GOT' } else { 'TIMEOUT' }"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $code
    return (($out -join '') -replace '\s', '')
}

# Queue for the lock in a child process and return one line, 'WAITED=<seconds>' (to verify the real wait duration)
function Invoke-ChildLockWaited([string]$FlowName, [int]$WaitSec) {
    $code = "Import-Module '$script:LockMod' -Force; " +
        "`$r = Enter-PadRunLock -FlowName '$FlowName' -WaitSec $WaitSec; " +
        "Write-Output ('WAITED=' + `$r.waitedSec)"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $code
    return (($out -join '') -replace '\s', '')
}

Describe 'PadLock cross-process mutual exclusion' {

    It 'While the lock is held another process queues and times out with failure' {
        (Enter-PadRunLock -FlowName 'HOLDER' -WaitSec 5).ok | Should Be $true
        try {
            (Invoke-ChildLockAttempt 'WAITER' 2) | Should Be 'TIMEOUT'
        } finally {
            Exit-PadRunLock
        }
    }

    It 'After the holder releases, the queued process acquires the lock immediately' {
        $got = Enter-PadRunLock -FlowName 'HOLDER' -WaitSec 5
        $got.ok | Should Be $true
        Exit-PadRunLock
        (Invoke-ChildLockAttempt 'NEXT' 5) | Should Be 'GOT'
    }

    It 'A stale lock file does not cause a hang (the Mutex is authoritative)' {
        $path = Get-PadLockFile
        # Forge a lock file whose "holder" has long gone
        [IO.File]::WriteAllText($path,
            '{"flow":"GONE","pid":999999,"processStart":"2020-01-01T00:00:00","startedAt":"2020-01-01T00:00:00"}',
            (New-Object Text.UTF8Encoding($false)))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $ok = Enter-PadRunLock -FlowName 'AFTER-CRASH' -WaitSec 10
            $ok.ok | Should Be $true
            # Acquired at once, never waiting for the timeout
            $sw.Elapsed.TotalSeconds | Should BeLessThan 3
        } finally {
            Exit-PadRunLock
        }
    }

    It 'While held, the lock file records the holding flow and PID so waiters can identify it' {
        (Enter-PadRunLock -FlowName 'PAD_LOCK_TEST' -WaitSec 5).ok | Should Be $true
        try {
            $info = Get-PadLockInfo
            $info.flow | Should Be 'PAD_LOCK_TEST'
            $info.pid | Should Be $PID
            (Test-LockHolderAlive $info) | Should Be $true
        } finally {
            Exit-PadRunLock
        }
        # The lock file should be removed on release so the next round cannot misread it
        (Get-PadLockInfo) | Should Be $null
    }

    It 'Logging does not rewrite the lock file: it is written once when the lock is acquired' {
        # Static assertion: Write-Log in pad-sync must no longer refresh the lock file, avoiding a whole-file rewrite per log entry
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ([regex]::Matches($src, 'Write-PadLockInfo')).Count | Should Be 0

        (Enter-PadRunLock -FlowName 'STATIC' -WaitSec 5).ok | Should Be $true
        try {
            $info = Get-PadLockInfo
            $info.flow | Should Be 'STATIC'
            # The heartbeat field is gone: the lock file no longer answers "is the holder still alive?"
            ($info.PSObject.Properties.Name -contains 'heartbeatAt') | Should Be $false
        } finally {
            Exit-PadRunLock
        }
    }

    It 'waitedSec is 0 when no waiting occurred' {
        $r = Enter-PadRunLock -FlowName 'NO-WAIT' -WaitSec 5
        $r.ok | Should Be $true
        # The lock is taken immediately with no queueing, so the wait duration must be 0 (and pad-sync's lockWaitSec follows suit)
        $r.waitedSec | Should Be 0
        Exit-PadRunLock
    }

    It 'After waiting, waitedSec reflects the real number of seconds waited' {
        $hold = Enter-PadRunLock -FlowName 'HOLD-FOR-WAIT' -WaitSec 5
        $hold.ok | Should Be $true
        try {
            # The child queues while the parent holds the lock, with a 4-second timeout; it reports how long it actually waited
            $out = Invoke-ChildLockWaited 'WAITER-WAIT' 4
            $m = [regex]::Match($out, 'WAITED=(\d+)')
            $m.Success | Should Be $true
            $w = [int]$m.Groups[1].Value
            # It really queued (> 0) and stayed under the timeout (widened to 6 to absorb process startup and polling overhead)
            $w | Should BeGreaterThan 0
            $w | Should BeLessThan 6
        } finally {
            Exit-PadRunLock
        }
    }

    It 'Get-PadLockState is no longer exported: callers do not need a second export surface' {
        # The export surface is a single entry point: the acquire result and wait duration both travel on Enter-PadRunLock's return
        (Get-Command Get-PadLockState -ErrorAction SilentlyContinue) | Should Be $null
        # pad-sync must not retain any call to it either
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ([regex]::Matches($src, 'Get-PadLockState')).Count | Should Be 0
        # And it really reads waitedSec off the return value now
        ([regex]::Matches($src, '\.waitedSec')).Count | Should BeGreaterThan 0
    }
}
