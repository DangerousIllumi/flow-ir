# PadTelemetry.psm1 — telemetry parsing for PAD designer local runs (RobinRobot.log, JSON Lines)
#
# Clicking "Run" inside the designer does not write Console\Scripts\<flow>\Runs\<runId>\Actions.log;
# it creates a timestamped RobinRobot.log under DataCollection instead. This module:
#   1) locates the log that belongs to this run (the newest file among those written after the trigger time)
#   2) parses it into one uniform contract: status / totalMs / timedActions / errorCode / error /
#      failedActions / runId / logPath / telemetry
#
# Decision rules:
#   - success/failure comes only from run-level events (robin.execution.success / failure);
#     action-level exceptions (*.actionexecution.exception) are collected as supplementary information only and never affect the status
#   - error codes are taken only from padExceptionInfo, never guessed from screenshots or the UI

# Parse an array of log lines; return $null when there is no valid event at all
function ConvertFrom-RobinTelemetryLines {
    param(
        # Not Mandatory: PS 5.1 refuses outright to bind an empty string into a Mandatory array parameter
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

    # runId of this run (taken from the last event carrying padFlowInfo.runId)
    $rid = $null
    foreach ($e in $events) {
        if ($e.eventData.padFlowInfo -and $e.eventData.padFlowInfo.runId) { $rid = $e.eventData.padFlowInfo.runId }
    }

    # Action-level exceptions: sap.actionexecution.exception / outlook.actionexecution.exception and so on
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

    # Duration of module actions: only modules such as Outlook/SAP/UIAutomation write telemetry;
    # built-in actions such as SET/IF/LOOP/RunDOSCommand never report
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

# Shared text-file read (module-private, not exported)
#
# Why it is needed: PAD's Console.Host / the robot hold a write handle on the log for the whole run,
# and [IO.File]::ReadAllLines requests FileShare.Read only, so it always throws "the file is being used by another process".
# Switching to FileShare.ReadWrite lets PAD keep writing while we read at the same time.
# A failed read does not throw: it returns $null and the caller treats the result as "unknown" (unknown is not failure).
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

# Parse one RobinRobot.log file
function Get-RobinTelemetryFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    # The robot process holds a write handle on the log while running: reading must be shared; return $null when unreadable (the caller decides)
    $text = Read-LogTextShared -Path $Path
    if ($null -eq $text) { return $null }
    $lines = $text -split "`r?`n"
    return (ConvertFrom-RobinTelemetryLines -Lines $lines -LogPath $Path)
}

# Locate the log in the DataCollection directory: modification time not earlier than Since (tolerating 20 seconds of clock skew), newest first
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

# Parse the last-line result of a child process: PAD_<Name>_RESULT=<JSON>
#
# Why this lives here: PadTelemetry's job is exactly "parse the text of external processes/logs into a uniform contract"
# (status, error code, log path). A child process's last-line RESULT is the same kind of work. PadDesigner only handles
# UI interaction and PadLock only handles cross-process mutual exclusion, so neither can host a text parser; that is why
# no fourth module was created.
#
# Behaviour contract (equivalent to the five previously separate implementations):
#   - take the last line starting with PAD_<Name>_RESULT= (not merely the last line of the output)
#   - with no matching line or corrupt JSON, return $null and leave one log line, never throw;
#     whether to abort because of it is the caller's decision, and each script keeps its original throw/degrade semantics
function Read-ChildResult {
    param(
        # Prefix middle segment: SYNC / DEPLOY / SCHEDULE / ROLLBACK
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Lines = @(),
        # Logging callback; writes straight to the console when omitted
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
        & $log "no result line starting with $prefix found"
        return $null
    }
    try { return ($payload | ConvertFrom-Json) }
    catch {
        & $log "failed to parse the result JSON: $($_.Exception.Message)"
        return $null
    }
}

# Resolve the outcome of a given runId in PadConsole.log (the authoritative evidence for URL-triggered runs)
#
# Why it is needed: PAD cleans up Actions.log after a run, so the orchestration layer cannot obtain the per-action log.
# At that point a possibly empty status from the wait phase must not be used to declare a failure; we must go back to Console telemetry:
#   Succeeded = agent.service.runcompleted(Run result: Success) / flowrunner.start.success /
#               flow.run.success / rpcprovider.hostprocess.exit(ExitCode=0)
#   Failed    = any *.exception event / runcompleted(Run result: Failure) /
#               hostprocess.exit with a non-zero code
#   no event for that runId at all = Unknown (unknown is not failure)
function Get-PadConsoleRunOutcome {
    param(
        [Parameter(Mandatory = $true)][string]$RunId,
        [string]$DataCollectionDir,
        # Scan only log files written after this point (tolerating 2 days of log rotation)
        [datetime]$Since = [datetime]::MinValue
    )
    if (-not $DataCollectionDir) {
        $DataCollectionDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'
    }
    if (-not (Test-Path $DataCollectionDir)) { return $null }

    # With MinValue apply no time filter (AddDays would overflow)
    $cut = if ($Since -eq [datetime]::MinValue) { [datetime]::MinValue } else { $Since.AddDays(-2) }
    $files = @(Get-ChildItem -LiteralPath $DataCollectionDir -Filter '*PadConsole.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cut } |
        Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $null }

    $successEvent = $null
    $failureEvent = $null
    $failureMessage = $null
    $evidencePath = $null
    # Names of files that could not be read: Console.Host holds the write handle of the current log the whole time,
    # so an exclusive read (ReadAllLines shares Read only) always throws "the file is being used by another process"
    $unreadableFile = $null
    foreach ($f in $files) {
        # Reading must be shared (ReadWrite): let PAD keep writing while we read at the same time
        $text = Read-LogTextShared -Path $f.FullName
        if ($null -eq $text) {
            # Skip that file when it cannot be read and end up as Unknown; unknown is not failure
            if (-not $unreadableFile) { $unreadableFile = $f.Name }
            continue
        }
        foreach ($line in ($text -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            $j = $null
            try { $j = $line | ConvertFrom-Json } catch { continue }
            # runId sometimes sits at the top level and sometimes in eventData; accept both
            $rid = $null
            if ($j.runId) { $rid = [string]$j.runId }
            elseif ($j.eventData -and $j.eventData.runId) { $rid = [string]$j.eventData.runId }
            if (-not $rid -or $rid -ne $RunId) { continue }
            if (-not $evidencePath) { $evidencePath = $f.FullName }
            $ev = [string]$j.event
            $msg = [string]$j.message

            # Explicit parentheses: PowerShell's -and/-or precedence easily splits the two sides of an "or" incorrectly
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
                # The exit code is inside a JSON message: {"ExitCode":0,"Exceptions":[]}
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
    # No evidence at all and the log is unreadable: leave a readable note for pad-sync to write into the warning
    $note = $null
    if ($outcome -eq 'Unknown' -and $unreadableFile) {
        $note = "Console log is not readable yet ($unreadableFile); this run is recorded as Unknown"
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

# Admission gate decision (a pure function to ease unit testing)
#
# The only acceptance basis: PAD_ADMIT_RESULT parsed, with fail=0, ask=0 and pass>0.
# Everything else is rejected, distinguishing three kinds of malfunction:
#   script-missing   the admit script does not exist
#   execution-failed the admit script exited non-zero (including timeout/crash/pending approval)
#   unparsable       no result line or corrupt JSON
# warn never blocks (consistent with pad-admit's existing semantics: warn is a hint only)
function Get-AdmitGateDecision {
    param(
        [int]$ExitCode = 0,
        [string]$Output = '',
        [string]$ScriptPath
    )
    if ($ScriptPath -and -not (Test-Path -LiteralPath $ScriptPath)) {
        return [ordered]@{
            allow = $false; reason = 'script-missing'
            message = "admit script not found: $ScriptPath"; summary = $null
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
                message = "admit script failed (exit code $ExitCode) and printed no PAD_ADMIT_RESULT"; summary = $null
            }
        }
        return [ordered]@{
            allow = $false; reason = 'unparsable'
            message = 'the admit script printed no PAD_ADMIT_RESULT; cannot confirm whether it passed'; summary = $null
        }
    }

    $admit = $null
    try { $admit = $payload | ConvertFrom-Json } catch { $admit = $null }
    if (-not $admit -or -not $admit.summary) {
        return [ordered]@{
            allow = $false; reason = 'unparsable'
            message = 'the admit result JSON cannot be parsed or lacks summary'; summary = $null
        }
    }

    $summary = $admit.summary
    $fail = [int]$summary.fail
    $ask = [int]$summary.ask
    $pass = [int]$summary.pass

    if ($ExitCode -ne 0) {
        return [ordered]@{
            allow = $false; reason = 'execution-failed'
            message = "admit script exit code $ExitCode (fail=$fail / ask=$ask / pass=$pass)"
            summary = $summary
        }
    }
    if ($fail -gt 0 -or $ask -gt 0) {
        return [ordered]@{
            allow = $false; reason = 'checks-failed'
            message = "admit check failed: fail $fail / ask $ask"
            summary = $summary
        }
    }
    if ($pass -le 0) {
        return [ordered]@{
            allow = $false; reason = 'no-pass'
            message = 'the admit check has no passing items (pass=0); it cannot be treated as a pass'
            summary = $summary
        }
    }
    return [ordered]@{
        allow = $true; reason = 'passed'
        message = "admit check passed: pass $pass / warn $([int]$summary.warn)"
        summary = $summary
    }
}

Export-ModuleMember -Function ConvertFrom-RobinTelemetryLines, Get-RobinTelemetryFromFile, Find-RobinTelemetryLog, Read-ChildResult, Get-PadConsoleRunOutcome, Get-AdmitGateDecision
