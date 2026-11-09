# PadTelemetry.psm1 — PAD 设计器本地运行的遥测解析（RobinRobot.log，JSON Lines）
#
# 设计器内点“运行”不会写 Console\Scripts\<flow>\Runs\<runId>\Actions.log，
# 而是在 DataCollection 下新建带时间戳的 RobinRobot.log。本模块负责：
#   1) 定位本次运行对应的日志（触发时间之后的文件里取最新）
#   2) 解析成统一契约：status / totalMs / timedActions / errorCode / error /
#      failedActions / runId / logPath / telemetry
#
# 判定规则：
#   - 成功/失败只看 run 级事件（robin.execution.success / failure），
#     动作级异常（*.actionexecution.exception）只作为附加信息收集，不参与状态判定
#   - 错误码只从 padExceptionInfo 取，不从截图或 UI 猜测

# 解析日志行数组；没有任何合法事件时返回 $null
function ConvertFrom-RobinTelemetryLines {
    param(
        # 不设 Mandatory：PS 5.1 对 Mandatory 数组里的空字符串会直接拒绝绑定
        [string[]]$Lines = @(),
        [string]$LogPath = ''
    )
    $events = @()
    foreach ($line in $Lines) {
        if (-not $line -or -not $line.Trim()) { continue }
        try { $o = $line | ConvertFrom-Json } catch { continue }
        if ($o.event) { $events += $o }
    }
    if ($events.Count -eq 0) { return $null }

    # 本次运行的 runId（取最后一条带 padFlowInfo.runId 的事件）
    $rid = $null
    foreach ($e in $events) {
        if ($e.eventData.padFlowInfo -and $e.eventData.padFlowInfo.runId) { $rid = $e.eventData.padFlowInfo.runId }
    }

    # 动作级异常：sap.actionexecution.exception / outlook.actionexecution.exception 等
    $failures = @()
    foreach ($e in $events) {
        if ($e.event -match '\.(exception|error|failed)$') {
            $info = $e.eventData.robinActionInfo
            $failures += [ordered]@{
                event  = $e.event
                action = if ($info) { $info.action } else { $null }
                module = if ($info) { $info.module } else { $null }
            }
        }
    }

    # 模块动作耗时：只有 Outlook/SAP/UIAutomation 这类会写遥测，
    # SET/IF/LOOP/RunDOSCommand 等内置动作不上报
    $timed = @()
    foreach ($e in $events) {
        if ($e.event -match 'actionexecution\.') {
            $info = $e.eventData.robinActionInfo
            $timed += [ordered]@{
                module = if ($info) { $info.module } else { $null }
                action = if ($info) { $info.action } else { $null }
                ms     = $e.durationInMilliseconds
                event  = $e.event
            }
        }
    }

    $succEvt = $events | Where-Object { $_.event -eq 'robin.execution.success' } | Select-Object -First 1
    $failEvt = $events | Where-Object { $_.event -eq 'robin.execution.failure' } | Select-Object -First 1
    $started = @($events | Where-Object { $_.event -eq 'robin.execution.start' }).Count -gt 0
    $totalMs = if ($succEvt) { $succEvt.durationInMilliseconds } else { $null }
    $status = if ($succEvt) { 'Succeeded' }
              elseif ($failEvt) { 'Failed' }
              elseif ($started) { 'Unknown' }
              else { 'NotStarted' }

    $errObj = $null
    if ($failEvt -and $failEvt.eventData.padExceptionInfo) {
        $errObj = [ordered]@{
            code = $failEvt.eventData.padExceptionInfo.errorCode
            type = $failEvt.eventData.padExceptionInfo.errorType
        }
    }

    $summary = @($events | Group-Object event | Sort-Object Count -Descending |
        ForEach-Object { [ordered]@{ event = $_.Name; count = $_.Count } })

    return [ordered]@{
        status        = $status
        actions       = $events.Count
        failedActions = $failures
        error         = $errObj
        errorCode     = $(if ($errObj) { $errObj.code } else { $null })
        runId         = $rid
        logPath       = $LogPath
        telemetry     = $summary
        timedActions  = $timed
        totalMs       = $totalMs
    }
}

# 共享读文本文件（模块内私有，不导出）
#
# 为什么需要：PAD 的 Console.Host / 机器人在运行期间持续持有日志的写句柄，
# [IO.File]::ReadAllLines 只请求 FileShare.Read，必然抛“文件正由另一进程使用”。
# 统一改用 FileShare.ReadWrite：既让 PAD 继续写，也允许我们同时读。
# 读失败不抛异常，返回 $null，由调用方按“未知”处理（未知不等于失败）。
function Read-LogTextShared {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
}

# 解析一个 RobinRobot.log 文件
function Get-RobinTelemetryFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    # 机器人进程运行期间持有日志写句柄：必须共享读；读不到返回 $null（由调用方判定）
    $text = Read-LogTextShared -Path $Path
    if ($null -eq $text) { return $null }
    $lines = $text -split "`r?`n"
    return (ConvertFrom-RobinTelemetryLines -Lines $lines -LogPath $Path)
}

# 在 DataCollection 目录里定位日志：修改时间不早于 Since（容忍 20 秒时钟误差），取最新
function Find-RobinTelemetryLog {
    param(
        [Parameter(Mandatory = $true)][string]$DataCollectionDir,
        [datetime]$Since = [datetime]::MinValue
    )
    if (-not (Test-Path $DataCollectionDir)) { return $null }
    return (Get-ChildItem -LiteralPath $DataCollectionDir -Filter '*RobinRobot.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since.AddSeconds(-20) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

# 解析子进程输出里的末行结果：PAD_<Name>_RESULT=<JSON>
#
# 为什么放在本模块：PadTelemetry 的职责就是「把外部进程/日志的文本解析成统一契约」
# （状态、错误码、日志路径）。子进程末行 RESULT 属于同一类工作。PadDesigner 只管
# UI 交互，PadLock 只管跨进程互斥，都不适合承载文本解析器，所以不新建第四个模块。
#
# 行为约定（与原五处各自实现等价）：
#   - 取最后一条以 PAD_<Name>_RESULT= 开头的行（不只看最后一行）
#   - 没有匹配行或 JSON 损坏时返回 $null 并留一条日志，绝不抛异常；
#     是否因此中止由调用方决定，各脚本原有的抛错/降级语义不变
function Read-ChildResult {
    param(
        # 前缀中段：SYNC / DEPLOY / SCHEDULE / ROLLBACK
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Lines = @(),
        # 日志回调；不传时直接写控制台
        [scriptblock]$Logger
    )
    $log = if ($Logger) { $Logger } else { { param($m) Write-Host "[pad-result] $m" } }
    $prefix = 'PAD_{0}_RESULT=' -f $Name
    $payload = $null
    foreach ($line in $Lines) {
        if (-not $line) { continue }
        if ($line.StartsWith($prefix)) { $payload = $line.Substring($prefix.Length) }
    }
    if (-not $payload) {
        & $log "未找到以 $prefix 开头的结果行"
        return $null
    }
    try { return ($payload | ConvertFrom-Json) }
    catch {
        & $log "结果 JSON 解析失败：$($_.Exception.Message)"
        return $null
    }
}

# 解析 PadConsole.log 里指定 runId 的结局（URL 触发运行的权威证据）
#
# 为什么需要：PAD 运行结束后会清理 Actions.log，编排层拿不到逐动作日志。
# 此时不能再用“等待阶段可能为空的 status”判失败，必须回到 Console 遥测取证：
#   Succeeded = agent.service.runcompleted(Run result: Success) / flowrunner.start.success /
#               flow.run.success / rpcprovider.hostprocess.exit(ExitCode=0)
#   Failed    = 任意 *.exception 事件 / runcompleted(Run result: Failure) /
#               hostprocess.exit 非 0
#   没有任何该 runId 的事件 = Unknown（未知不等于失败）
function Get-PadConsoleRunOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [string]$DataCollectionDir,
        # 只扫描这个时间点之后的日志文件（容忍 2 天日志轮转）
        [datetime]$Since = [datetime]::MinValue
    )
    if (-not $DataCollectionDir) {
        $DataCollectionDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'
    }
    if (-not (Test-Path $DataCollectionDir)) { return $null }

    # MinValue 时不做时间过滤（AddDays 会越界）
    $cut = if ($Since -eq [datetime]::MinValue) { [datetime]::MinValue } else { $Since.AddDays(-2) }
    $files = @(Get-ChildItem -LiteralPath $DataCollectionDir -Filter '*PadConsole.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cut } |
        Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $null }

    $successEvent = $null
    $failureEvent = $null
    $failureMessage = $null
    $evidencePath = $null
    # 读不出来的文件名：Console.Host 全程持有当前日志的写句柄，
    # 独占读（ReadAllLines 只共享 Read）必然抛“文件正由另一进程使用”
    $unreadableFile = $null
    foreach ($f in $files) {
        # 必须共享读（ReadWrite）：既让 PAD 继续写，也允许我们同时读
        $text = Read-LogTextShared -Path $f.FullName
        if ($null -eq $text) {
            # 读不到就跳过该文件，最终按 Unknown 处理；未知不等于失败
            if (-not $unreadableFile) { $unreadableFile = $f.Name }
            continue
        }
        foreach ($line in ($text -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            $j = $null
            try { $j = $line | ConvertFrom-Json } catch { continue }
            # runId 有时在顶层，有时在 eventData，两种都认
            $rid = $null
            if ($j.runId) { $rid = [string]$j.runId }
            elseif ($j.eventData -and $j.eventData.runId) { $rid = [string]$j.eventData.runId }
            if (-not $rid -or $rid -ne $RunId) { continue }
            if (-not $evidencePath) { $evidencePath = $f.FullName }
            $ev = [string]$j.event
            $msg = [string]$j.message

            # 显式括号：PowerShell 的 -and/-or 优先级容易把“或”两侧拆错
            if (($ev -match '\.exception$') -or
                ($ev -eq 'agent.service.runcompleted' -and $msg -match 'Failure')) {
                if (-not $failureEvent) { $failureEvent = $ev; $failureMessage = $msg }
                continue
            }
            if (($ev -eq 'flowrunner.start.success') -or ($ev -eq 'flow.run.success') -or
                ($ev -eq 'agent.service.runcompleted' -and $msg -match 'Success')) {
                if (-not $successEvent) { $successEvent = $ev }
                continue
            }
            if ($ev -eq 'rpcprovider.hostprocess.exit') {
                # 退出码写在 message 里的 JSON：{"ExitCode":0,"Exceptions":[]}
                $m = [regex]::Match($msg, '"ExitCode"\s*:\s*(-?\d+)')
                if ($m.Success) {
                    if ([int]$m.Groups[1].Value -eq 0) { if (-not $successEvent) { $successEvent = $ev } }
                    elseif (-not $failureEvent) { $failureEvent = $ev; $failureMessage = $msg }
                }
            }
        }
    }

    $outcome = 'Unknown'
    if ($failureEvent) { $outcome = 'Failed' }
    elseif ($successEvent) { $outcome = 'Succeeded' }
    # 无任何证据且日志读不出来：留一条可读说明，供 pad-sync 写进 warning
    $note = $null
    if ($outcome -eq 'Unknown' -and $unreadableFile) {
        $note = "Console 日志暂不可读（$unreadableFile），本次取证为 Unknown"
    }
    return [ordered]@{
        outcome    = $outcome
        event      = $(if ($failureEvent) { $failureEvent } else { $successEvent })
        message    = $failureMessage
        logPath    = $evidencePath
        unreadable = [bool]$unreadableFile
        note       = $note
    }
}

# 准入网关判定（纯函数，便于单测）
#
# 唯一判定依据：解析出 PAD_ADMIT_RESULT，且 fail=0、ask=0、pass>0。
# 其余情况一律不放行，并区分三种失灵：
#   script-missing   准入脚本不存在
#   execution-failed 准入脚本非零退出（含超时/崩溃/待批）
#   unparsable       没有结果行或 JSON 损坏
# warn 不参与阻断（与 pad-admit 既有语义一致：warn 只提示）
function Get-AdmitGateDecision {
    param(
        [int]$ExitCode = 0,
        [string]$Output = '',
        [string]$ScriptPath
    )
    if ($ScriptPath -and -not (Test-Path -LiteralPath $ScriptPath)) {
        return [ordered]@{
            allow = $false; reason = 'script-missing'
            message = "准入脚本不存在：$ScriptPath"; summary = $null
        }
    }

    $payload = $null
    foreach ($line in ([string]$Output -split "`r?`n")) {
        if ($line.StartsWith('PAD_ADMIT_RESULT=')) { $payload = $line.Substring('PAD_ADMIT_RESULT='.Length) }
    }

    if (-not $payload) {
        if ($ExitCode -ne 0) {
            return [ordered]@{
                allow = $false; reason = 'execution-failed'
                message = "准入脚本执行失败（退出码 $ExitCode），未输出 PAD_ADMIT_RESULT"; summary = $null
            }
        }
        return [ordered]@{
            allow = $false; reason = 'unparsable'
            message = '准入脚本没有输出 PAD_ADMIT_RESULT，无法确认是否通过'; summary = $null
        }
    }

    $admit = $null
    try { $admit = $payload | ConvertFrom-Json } catch { $admit = $null }
    if (-not $admit -or -not $admit.summary) {
        return [ordered]@{
            allow = $false; reason = 'unparsable'
            message = '准入结果 JSON 无法解析或缺少 summary'; summary = $null
        }
    }

    $summary = $admit.summary
    $fail = [int]$summary.fail
    $ask = [int]$summary.ask
    $pass = [int]$summary.pass

    if ($ExitCode -ne 0) {
        return [ordered]@{
            allow = $false; reason = 'execution-failed'
            message = "准入脚本退出码 $ExitCode（fail=$fail / ask=$ask / pass=$pass）"
            summary = $summary
        }
    }
    if ($fail -gt 0 -or $ask -gt 0) {
        return [ordered]@{
            allow = $false; reason = 'checks-failed'
            message = "准入未通过：失败 $fail / 待批 $ask"
            summary = $summary
        }
    }
    if ($pass -le 0) {
        return [ordered]@{
            allow = $false; reason = 'no-pass'
            message = '准入没有任何通过项（pass=0），不能视为放行'
            summary = $summary
        }
    }
    return [ordered]@{
        allow = $true; reason = 'passed'
        message = "准入通过：通过 $pass / 警告 $([int]$summary.warn)"
        summary = $summary
    }
}

Export-ModuleMember -Function ConvertFrom-RobinTelemetryLines, Get-RobinTelemetryFromFile, Find-RobinTelemetryLog, Read-ChildResult, Get-PadConsoleRunOutcome, Get-AdmitGateDecision
