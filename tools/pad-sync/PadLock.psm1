# PadLock.psm1 — 跨进程互斥：同一时刻只允许一个流占用 PAD
#
# 为什么用命名 Mutex 而不是纯锁文件：
#   锁文件在进程被强杀时会残留，等待方无法区分“真正在跑”和“残留”，
#   只能靠 PID/心跳猜，猜错就死等。命名 Mutex 由系统维护，进程结束即释放，
#   从根本上不存在陈旧锁。
#
# 锁文件（%LOCALAPPDATA%\flow-ir\pad-run.lock.json）只做可观测性：
#   抢锁成功时写一次，记录持有流程、PID、进程启动时间与开始时间，
#   供等待方打印“谁在占着 PAD”。它不参与互斥判定，也不承担心跳，
#   删掉也不会影响正确性。

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

# 写锁文件。只在抢锁成功时调用一次，不做逐条日志刷新（避免每条日志一次整文件重写）
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

# 锁文件描述的持有进程是否还活着（PID 会被复用，所以同时比对启动时间）
function Test-LockHolderAlive {
    param($Info)
    if (-not $Info -or -not $Info.pid) { return $false }
    $p = Get-Process -Id ([int]$Info.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    try { return ([math]::Abs(($p.StartTime - [datetime]$Info.processStart).TotalSeconds) -lt 5) } catch { return $true }
}

# 抢锁：最多等 WaitSec 秒，每秒重试。
# 返回 [pscustomobject]@{ ok; waitedSec }：
#   以前返回裸布尔，调用方想知道“等了多久”还得再调一个 Get-PadLockState，
#   等于为一个字段多开一个导出面。这里把判定与等待时长一次带回，
#   模块只需要导出这一个入口，内部计数器也不必外露。
function Enter-PadRunLock {
    param(
        [Parameter(Mandatory = $true)][string]$FlowName,
        [int]$WaitSec = 1800,
        # 日志回调；不传时直接写控制台
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
            # 上一个持有者异常退出：锁已归本次所有，直接接管而不是当成残留死等
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
