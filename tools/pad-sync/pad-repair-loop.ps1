# pad-repair-loop.ps1 — 自动分析-修复闭环
#
# 作用：把 .robin 注入测试流程 → 自动运行 → 收集失败动作 → 输出修复建议 → 等待 agent 修改 → 再注入
#
# 安全边界（硬约束）：
#   1) 默认只能操作 PAD_SYNC_TEST 测试流程（-AllowProd 开关只用于紧急绕过）
#   2) 只能读写 %TEMP%\pad-repair-*.robin 临时文件和 C:\PAD\Results\*.txt 日志
#   3) 最多重试 -MaxRound 次（默认 3）
#   4) 任何外部修复产出的 .robin 仍需通过基本静态自检

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SourceRobin,
    [string]$FlowName = 'PAD_SYNC_TEST',
    [int]$MaxRound = 3,
    [int]$RunTimeoutSec = 120,
    [string]$ResultDir,
    [switch]$AllowProd,
    # 测试阶段直接点设计器“运行”，不发布到云端
    [switch]$LocalRun,
    # 只跑一轮：落盘修复上下文后立即退出，等 agent 改完再手动跑下一轮
    [switch]$SingleRound,
    # 可插拔执行器：失败后自动调用它修 .robin，修完直接进下一轮
    [string]$Executor,
    # 执行器最长运行秒数
    [int]$ExecutorTimeoutSec = 600
)
$ErrorActionPreference = 'Stop'

if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
    Write-Error '安全熔断：默认只能操作 PAD_SYNC_TEST 测试流程。操作生产流程请显式加 -AllowProd。'
}
# V 模型红线：生产流程只允许观察或人工修复，不允许自动改代码
if ($FlowName -ne 'PAD_SYNC_TEST' -and $Executor) {
    throw '生产流程禁止自动修复：请只用 -SingleRound 观察，或人工修改 .robin'
}
if (-not (Test-Path $SourceRobin)) { Write-Error "找不到 .robin：$SourceRobin" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$padSync = Join-Path $here 'pad-sync.ps1'
# 日志与 VBS 源码的编码探测统一走 TextEncoding 模块
Import-Module (Join-Path $here 'TextEncoding.psm1') -Force
if (-not (Test-Path $padSync)) { Write-Error "找不到 pad-sync.ps1：$padSync" }

if (-not $ResultDir) { $ResultDir = Join-Path $env:TEMP "pad-repair-$(Get-Date -Format 'HHmmss')" }
New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null

$rootResult = [ordered]@{
    ok = $false; rounds = @(); flow = $FlowName
    sourceRobin = $SourceRobin; finalRobinPath = $null
    lastError = $null; log = @()
}

function Log([string]$m) {
    $script:rootResult.log += $m
    Write-Host "[repair-loop] $m"
}

# 静态自检：非空、行数>=2
function Test-RobinSyntax([string]$path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return $false, '.robin 为空' }
    if ($text.Contains([char]0)) { return $false, '.robin 含空字符' }
    $lines = ($text -split "`r?`n").Where({ $_.Trim() -ne '' })
    if ($lines.Count -lt 2) { return $false, '.robin 动作数太少（需至少 2 行）' }
    return $true, $null
}

# 按 BOM 自动识别编码读取日志（VBS 的 OpenTextFile 第 3 参数为 True 时写 UTF-16LE，PS 写的多为 UTF-8/GBK）
function Read-LogAuto([string]$path, [int]$maxChars = 4000) {
    # 编码探测与解码统一交给 TextEncoding 模块（UTF-16LE / UTF-8-BOM / ANSI 三例有 Pester 覆盖）
    $text = (Read-TextFileAuto $path).text
    # 日志可能很大，只保留尾部（报错信息通常在最后）
    if ($text.Length -gt $maxChars) { $text = '...(已截断)...' + $text.Substring($text.Length - $maxChars) }
    return $text
}

# 从 VBS 源码提取日志约定，而不是靠"脚本名_result.txt"猜：
#   1) 找 Const RESULT_DIR = "..." 得到日志目录
#   2) 找源码里所有写死的 .txt/.log 文件名（MIGO → migo_result.txt；MB51 → saveas_result.txt/saveas_stop.txt/export_excel.log）
#   3) 只保留磁盘上真实存在的，优先名字含 result 的，其次按修改时间最新
function Get-VbsLogFile([string]$vbsPath) {
    $src = (Read-TextFileAuto $vbsPath).text

    # 候选目录：RESULT_DIR 常量 + 源码里的完整路径字面量 + 脚本自身目录
    $dirs = @()
    if ($src -match 'Const\s+RESULT_DIR\s*=\s*"([^"\r\n]+)"') { $dirs += $Matches[1] }
    foreach ($m in [regex]::Matches($src, '"([A-Za-z]:\\[^"\r\n]+\\[^"\\]+)"')) {
        $d = Split-Path $m.Groups[1].Value -Parent
        if ($d) { $dirs += $d }
    }
    $dirs += (Split-Path $vbsPath -Parent)
    $dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)

    # 源码里出现的日志文件名（可能带反斜杠前缀或完整路径，如 "\migo_result.txt"、"C:\PAD\Results\saveas_result.txt"）
    $names = @([regex]::Matches($src, '"([^"\r\n]*?([A-Za-z0-9_\-\.]+\.(?:txt|log)))"') | ForEach-Object {
        [pscustomobject]@{ Full = $_.Groups[1].Value; Name = $_.Groups[2].Value }
    })
    if (-not $names) { return $null }

    $files = @()
    foreach ($n in $names) {
        if ($n.Full -match '^[A-Za-z]:\\') {
            # 源码里写的是完整路径，直接校验
            if (Test-Path $n.Full) { $files += (Get-Item $n.Full) }
            continue
        }
        foreach ($d in $dirs) {
            $p = Join-Path $d $n.Name
            if (Test-Path $p) { $files += (Get-Item $p) }
        }
    }
    if (-not $files) { return $null }

    # 排序：result 类优先，其次修改时间最新
    return ($files | Sort-Object @{ Expression = { if ($_.Name -match 'result') { 0 } else { 1 } } },
        @{ Expression = { $_.LastWriteTime }; Descending = $true })[0]
}

# RunDOSCommand 失败时的日志 hook：从命令行解析 VBS/Python 脚本路径，读取外部日志
# 项目脚本约定（agent 生成脚本时必须遵循）：
#   VBS    → 退出码非 0；日志文件由 VBS 源码内写死的 .txt/.log 文件名决定（hook 从源码提取）
#   Python → 退出码非 0；stdout 末尾 RECONCILE_RESULT=ERROR
function Get-RunDosExtraLog($failedAction) {
    $extra = [ordered]@{ scriptPath = $null; vbsLogPath = $null; vbsLog = $null; pythonStdout = $null; hookNote = $null }
    $actionName = $failedAction.action
    $sysName = $failedAction.systemActionName
    if (-not ($sysName -match 'RunDOSCommand' -or $actionName -match 'RunDOS')) {
        $extra.hookNote = '不是 RunDOSCommand 动作，跳过 hook'; return $extra
    }
    $cmdLine = $failedAction.inputs.DOSCommandOrApplication
    if (-not $cmdLine) { $extra.hookNote = 'inputs 里无 DOSCommandOrApplication'; return $extra }
    # 正则提取脚本路径：优先 .vbs 后 .py，单引号包裹模式避免双引号转义
    $scriptPath = $null
    if ($cmdLine -match '"([^"]+\.vbs)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match 'cscript[^"]*"([^"]+\.vbs)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match 'python[^"]*"([^"]+\.py)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match '"([^"]+\.py)"') { $scriptPath = $Matches[1] }
    $extra.scriptPath = $scriptPath
    if (-not $scriptPath) { $extra.hookNote = '无法解析脚本路径'; return $extra }
    if ($scriptPath -match '\.vbs$') {
        # 不再猜"脚本名_result.txt"，改为从 VBS 源码提取真实日志文件名与目录
        $logFile = Get-VbsLogFile $scriptPath
        if ($logFile) {
            $extra.vbsLogPath = $logFile.FullName
            $extra.vbsLog = Read-LogAuto $logFile.FullName
            $extra.hookNote = "VBS 日志已读取：$($logFile.FullName)（$($logFile.Length) 字节，修改于 $($logFile.LastWriteTime.ToString('HH:mm:ss'))）"
        } else {
            $extra.hookNote = "VBS 源码声明的日志文件在磁盘上均不存在：$scriptPath"
        }
    } elseif ($scriptPath -match '\.py$') {
        $out = $failedAction.inputs.standardOutput
        if (-not $out) { $out = $failedAction.inputs.standardError }
        if ($out) { $extra.pythonStdout = $out; $extra.hookNote = 'Python stdout 已读取' }
        else { $extra.hookNote = 'Python 但无 standardOutput/standardError' }
    }
    return $extra
}

function Invoke-RunCycle([string]$robinPath, [int]$round) {
    Log "——— 第 $round 轮：注入 + 运行 ———"
    $tmpOut = Join-Path $ResultDir "pad-sync-out_$round.log"
    $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $padSync,
        '-FlowName', $FlowName, '-RobinFile', $robinPath, '-Replace',
        '-RunTimeoutSec', $RunTimeoutSec)
    if ($LocalRun) { $syncArgs += '-LocalRun' }
    & powershell @syncArgs > $tmpOut 2>&1
    $lastLine = Get-Content $tmpOut -Tail 1
    Log "pad-sync 最后一行：$lastLine"
    if ($lastLine -match '^PAD_SYNC_RESULT=(.+)$') {
        try { return ($Matches[1] | ConvertFrom-Json) }
        catch { Log "JSON 解析失败：$($_.Exception.Message)"; return $null }
    }
    Log '未找到 PAD_SYNC_RESULT 前缀'
    return $null
}

try {
    $currentRobin = Join-Path $ResultDir 'current.robin'
    Copy-Item $SourceRobin $currentRobin -Force
    for ($round = 1; $round -le $MaxRound; $round++) {
        $ok, $msg = Test-RobinSyntax $currentRobin
        if (-not $ok) { throw "第 ${round} 轮 .robin 静态自检失败：$msg" }
        $res = Invoke-RunCycle $currentRobin $round
        if (-not $res) { throw "第 ${round} 轮：pad-sync 没返回有效结果" }
        # 设计器本地运行返回的是动作级异常数组 failedActions（没有单数 failedAction），
        # 取第一个异常并补上 hook 需要的 systemActionName 字段
        $fa = $res.failedAction
        if (-not $fa -and $res.failedActions -and @($res.failedActions).Count -gt 0) {
            $fa = @($res.failedActions)[0]
            if (-not $fa.PSObject.Properties['systemActionName']) {
                $fa | Add-Member -NotePropertyName systemActionName -NotePropertyValue $fa.action -Force
            }
        }
        $roundRec = [ordered]@{
            round = $round; status = $res.status; ok = $res.ok
            actions = $res.actions; failedAction = $fa
            failedActions = $res.failedActions
            timedActions = $res.timedActions; totalMs = $res.totalMs
            error = $res.error; logPath = $res.logPath
        }
        $rootResult.rounds += $roundRec
        if ($res.ok) {
            Log "✅ 第 $round 轮通过！status=$($res.status)"
            if ($res.failedActions -and @($res.failedActions).Count -gt 0) {
                $names = @($res.failedActions | ForEach-Object { "$($_.module).$($_.action)" }) -join ', '
                Log "⚠️ 本轮有被捕获的动作异常（不影响最终结果）：$names"
            }
            $rootResult.ok = $true; break
        }
        $f = $fa
        if (-not $f) { Log '失败但无 Failed 动作，停止'; break }
        Log "第 $round 轮失败：action=$($f.name) error.code=$($f.error.code)"
        $ctxPath = Join-Path $ResultDir "repair_ctx_$round.json"
        $nextPath = Join-Path $ResultDir "round_$($round+1).robin"
        [ordered]@{
            round = $round
            failedAction = $f
            error = $res.error
            actions = $res.actions
            logPath = $res.logPath
            currentRobinPath = $currentRobin
            nextRobinPath = $nextPath
            extraLogs = (Get-RunDosExtraLog $f)
        } | ConvertTo-Json -Depth 10 | Out-File $ctxPath -Encoding UTF8
        Log "修复上下文已落盘：$ctxPath"
        Log "修复指引：读 $ctxPath → 改 current.robin → 输出到 $nextPath"
        # 可插拔执行器：把上下文交给外部程序，修完的 .robin 直接进下一轮
        if ($Executor) {
            if (-not (Test-Path $Executor)) { throw "找不到 executor：$Executor" }
            Log "调用 executor：$Executor"
            $execLog = Join-Path $ResultDir "executor_$round.log"
            $execSw = [Diagnostics.Stopwatch]::StartNew()
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Executor -ContextFile $ctxPath -InputRobin $currentRobin -OutputRobin $nextPath *> $execLog
            $execCode = $LASTEXITCODE
            $execSw.Stop()
            Log "executor 退出码=$execCode，耗时 $([int]$execSw.Elapsed.TotalSeconds) 秒（日志 $execLog）"
            if ($execCode -ne 0) {
                Log 'executor 放弃修复，循环停止'
                $rootResult.executorAborted = $true
                break
            }
            if (-not (Test-Path $nextPath)) {
                Log "executor 未产出 $nextPath，循环停止"
                $rootResult.executorAborted = $true
                break
            }
            $okFix, $msgFix = Test-RobinSyntax $nextPath
            if (-not $okFix) { Log "executor 产物自检失败：$msgFix"; break }
            $currentRobin = $nextPath
            continue
        }
        if ($SingleRound) {
            Log "单轮模式：修复上下文已生成，等 agent 改完 current.robin 后再跑下一轮"
            $rootResult.nextRobinPath = $nextPath
            break
        }
        if ($round -eq $MaxRound) { Log "已达最大轮数 $MaxRound，停止"; break }
        Copy-Item $currentRobin $nextPath -Force
        $currentRobin = $nextPath
    }
    $rootResult.finalRobinPath = $currentRobin
}
catch {
    $rootResult.lastError = $_.Exception.Message
    Log "循环失败：$($_.Exception.Message)"
}
finally {
    Write-Output ('PAD_REPAIR_LOOP_RESULT=' + ($rootResult | ConvertTo-Json -Depth 10 -Compress))
}
