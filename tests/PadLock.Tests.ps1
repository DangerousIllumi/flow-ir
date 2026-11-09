# PadLock.Tests.ps1 — 跨进程互斥测试
#
# 覆盖三条真实路径：
#   1) 持有锁时，另一个进程排队后超时返回失败（不硬闯）
#   2) 持有者释放后，排队方立即拿到锁
#   3) 残留的锁文件不会造成死等（互斥以 Mutex 为准，锁文件只做展示）
#
# 用真实子进程验证：同进程内 Mutex 可重入，测不出并发行为。

$script:LockMod = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\pad-sync\PadLock.psm1')).Path
Import-Module $script:LockMod -Force

# 在子进程里抢锁，只回一行结果
function Invoke-ChildLockAttempt([string]$FlowName, [int]$WaitSec) {
    $code = "Import-Module '$script:LockMod' -Force; " +
        "`$r = Enter-PadRunLock -FlowName '$FlowName' -WaitSec $WaitSec; " +
        "if (`$r.ok) { 'GOT' } else { 'TIMEOUT' }"
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $code
    return (($out -join '') -replace '\s', '')
}

# 在子进程里排队抢锁，回一行 'WAITED=<秒数>'（用于验证等待时长的真实值）
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
        # 伪造一份“持有者早已不存在”的锁文件
        [IO.File]::WriteAllText($path,
            '{"flow":"GONE","pid":999999,"processStart":"2020-01-01T00:00:00","startedAt":"2020-01-01T00:00:00"}',
            (New-Object Text.UTF8Encoding($false)))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $ok = Enter-PadRunLock -FlowName 'AFTER-CRASH' -WaitSec 10
            $ok.ok | Should Be $true
            # 立刻拿到，不会等到超时
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
        # 释放后锁文件应被清掉，避免下一轮误读
        (Get-PadLockInfo) | Should Be $null
    }

    It 'Logging does not rewrite the lock file: it is written once when the lock is acquired' {
        # 静态断言：pad-sync 的 Write-Log 不得再刷新锁文件，避免每条日志一次整文件重写
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ([regex]::Matches($src, 'Write-PadLockInfo')).Count | Should Be 0

        (Enter-PadRunLock -FlowName 'STATIC' -WaitSec 5).ok | Should Be $true
        try {
            $info = Get-PadLockInfo
            $info.flow | Should Be 'STATIC'
            # 心跳字段已移除：锁文件不承担“持有者还活着吗”的语义
            ($info.PSObject.Properties.Name -contains 'heartbeatAt') | Should Be $false
        } finally {
            Exit-PadRunLock
        }
    }

    It 'waitedSec is 0 when no waiting occurred' {
        $r = Enter-PadRunLock -FlowName 'NO-WAIT' -WaitSec 5
        $r.ok | Should Be $true
        # 直接拿到锁，没有排队，等待时长必须是 0（pad-sync 的 lockWaitSec 也据此为 0）
        $r.waitedSec | Should Be 0
        Exit-PadRunLock
    }

    It 'After waiting, waitedSec reflects the real number of seconds waited' {
        $hold = Enter-PadRunLock -FlowName 'HOLD-FOR-WAIT' -WaitSec 5
        $hold.ok | Should Be $true
        try {
            # 子进程在父进程持锁期间排队，超时上限 4 秒；它回报自己真实等待了多少秒
            $out = Invoke-ChildLockWaited 'WAITER-WAIT' 4
            $m = [regex]::Match($out, 'WAITED=(\d+)')
            $m.Success | Should Be $true
            $w = [int]$m.Groups[1].Value
            # 确实排了队（> 0），且不超过超时上限（放宽到 6 容纳进程启动与轮询开销）
            $w | Should BeGreaterThan 0
            $w | Should BeLessThan 6
        } finally {
            Exit-PadRunLock
        }
    }

    It 'Get-PadLockState is no longer exported: callers do not need a second export surface' {
        # 模块导出面收成一个入口：抢锁结果与等待时长都由 Enter-PadRunLock 带回
        (Get-Command Get-PadLockState -ErrorAction SilentlyContinue) | Should Be $null
        # pad-sync 里也不得再残留对它的调用
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ([regex]::Matches($src, 'Get-PadLockState')).Count | Should Be 0
        # 且确实改为读取返回值上的 waitedSec
        ([regex]::Matches($src, '\.waitedSec')).Count | Should BeGreaterThan 0
    }
}
