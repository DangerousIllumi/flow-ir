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

# 解析一个 RobinRobot.log 文件
function Get-RobinTelemetryFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
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

Export-ModuleMember -Function ConvertFrom-RobinTelemetryLines, Get-RobinTelemetryFromFile, Find-RobinTelemetryLog
