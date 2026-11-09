# pad-schedule.ps1 — scheduled trigger (attended: local Task Scheduler + workday calendar)
#
# Whether it runs is decided by the workday calendar, not by a plain Monday-to-Friday rule:
#   China has statutory holidays and make-up workdays (nothing runs on holidays, and some
#   weekends are worked to compensate), so a Monday-Friday rule would fire during Spring
#   Festival and National Day and would also miss the make-up weekends.
#   The default is therefore "trigger every day at 09:00 -> check the calendar at run time ->
#   exit immediately if today is not a workday".
#   Calendar switch: --is-workday in tools\workday\workday.py (shared component; it uses the
#   same calendar logic as the verification scripts).
#
# Why Task Scheduler instead of cloud Recurrence:
#   attended mode already requires "machine on + user logged in", and cloud Recurrence needs
#   the machine online as well, yet it additionally needs Power Automate Premium (or an RPA
#   attended add-on licence).
#   Task Scheduler needs no extra licence, and it can be scripted, audited and removed with one command.
#
# How to do it with cloud Recurrence (needs Premium; this script does not do it for you):
#   1. make.powerautomate.com -> My flows -> find this desktop flow -> Edit -> Triggers -> add "Schedule";
#   2. Frequency = Day, time zone = China Standard Time, time = 09:00;
#   3. after saving, the target machine must stay online and logged in (attended).
#   Note: cloud Recurrence knows nothing about Chinese holidays; the flow still has to check the calendar.
#
# No log redirection is needed: pad-sync appends every run to business\manifest.jsonl (type=run).
#
# Usage:
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -DryRun        # only print the task that would be registered
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST                # register/update (daily 09:00, gated by the calendar)
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -IgnoreCalendar # ignore the calendar; run Monday through Friday only
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -List          # show the next trigger time and the last result
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -RunNow        # trigger once immediately (has real side effects)
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -Remove        # delete the scheduled task
#
# Output: the last line is PAD_SCHEDULE_RESULT=<JSON>; exit code 0 success / 1 failure

[CmdletBinding()]
param(
    [string]$FlowName = 'PAD_SYNC_TEST',
    # Trigger time (HH:mm); default is 09:00 every day
    [string]$Time = '09:00',
    [string]$TaskName,
    # Script to schedule; defaults to pad-sync.ps1 in the same directory
    [string]$PadSyncPath,
    # Central runtime config (JSON): explicit parameters win; only items not given explicitly come from the config
    [string]$ConfigPath,
    # Workday calendar: must be given explicitly (there is no built-in default path any more); omitting it is an error
    [string]$CalendarPath,
    [string]$PythonExe,
    # Workday check script (shared component; defaults to tools\workday\workday.py and exits with a failure when not found)
    [string]$WorkdayScript,
    # Acceptance criteria and deployment config used after the run (optional; recommended for production schedules)
    [string]$AcceptanceFile,
    [string]$ConfigFile,
    # pad-sync's -RunTimeoutSec: the longest wait, in seconds, for the flow itself to finish
    # The AI flow waits for mail for up to 60 minutes + about 3 minutes of verification/SAP ≈ 63 minutes, so 70 minutes leaves headroom
    [int]$RunTimeoutSec = 4200,
    # pad-sync's -LockWaitSec: the longest wait, in seconds, for the cross-process mutex
    # Covers the "previous flow is still running -> the current flow queues for the lock" case; 90 minutes
    # A long SAP download takes up to ~45 minutes and another kind with mail waiting takes up to ~63 minutes, so take the larger value plus headroom
    [int]$LockWaitSec = 5400,
    # Ignore the calendar and fall back to "run every Monday to Friday" (not recommended: it fires on holidays and misses make-up workdays)
    [switch]$IgnoreCalendar,
    # Run entry point: when Task Scheduler fires, this script checks the calendar first and only then decides whether to call pad-sync
    [switch]$RunIfWorkday,
    # Run entry point: run only on the last workday of this month (month-end scenario)
    [switch]$RunIfLastWorkday,
    # Registration option: build a scheduled-task action that runs only on the last workday of this month
    [switch]$LastWorkday,
    # Must be given explicitly for a production flow, matching the safety-fuse policy of the other deployment scripts
    [switch]$AllowProd,
    [switch]$List,
    [switch]$Remove,
    [switch]$RunNow,
    [switch]$DryRun,
    # Only for Pester dot-sourcing to load the functions
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
# Central config: read only when -ConfigPath is given explicitly; a missing item, a path that does not exist or a wrong type is always a hard failure
Import-Module (Join-Path $here 'PadConfig.psm1') -Force
if ($ConfigPath) {
    $runtime = Get-PadRuntimeConfig -ConfigPath $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('PadSyncPath')) { $PadSyncPath = $runtime.PadSyncPath }
    if (-not $PSBoundParameters.ContainsKey('PythonExe')) { $PythonExe = $runtime.PythonExe }
    if (-not $PSBoundParameters.ContainsKey('CalendarPath')) { $CalendarPath = $runtime.CalendarPath }
    if (-not $PSBoundParameters.ContainsKey('WorkdayScript')) { $WorkdayScript = $runtime.WorkdayScript }
    if (-not $PSBoundParameters.ContainsKey('RunTimeoutSec')) { $RunTimeoutSec = $runtime.RunTimeoutSec }
}
# Hidden-window launcher: the task still runs as Interactive (PAD needs an interactive desktop),
# but wscript.exe wraps powershell so the console window is hidden from creation and never flashes
$script:HiddenLauncher = Join-Path $here 'run-hidden.vbs'

function Log([string]$m) { Write-Host "[schedule] $m" }
# Parsing of the child process's last-line PAD_SYNC_RESULT is centralised in PadTelemetry; this script no longer carries its own regex
Import-Module (Join-Path $here 'PadTelemetry.psm1') -Force

# Task name: flow-ir-<flow name>; characters that are invalid in a task name and whitespace are all replaced with underscores
function Get-ScheduleTaskName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|\s]', '_').Trim('_')
    if (-not $safe) { throw 'flow name is empty; cannot build a task name' }
    return 'flow-ir-' + $safe
}

# Parse the trigger time and return a valid DateTime (keeping only the time of day)
function ConvertTo-ScheduleTime([string]$Time) {
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Time, [ref]$t)) {
        throw "invalid trigger time: $Time (expected HH:mm, e.g. 09:00)"
    }
    return $t
}

# Build the task action
#   WorkdayGate: the task calls this script with -RunIfWorkday first; the script checks the calendar
#   and only then decides whether to run pad-sync
#   Otherwise it calls pad-sync -RunOnly directly (runs Monday through Friday)
# Always quote paths and flow names: repository paths often contain spaces, and -File truncates them otherwise
function New-ScheduleActionSpec {
    param(
        [string]$ScriptPath,
        [string]$FlowName,
        [switch]$AllowProd,
        [switch]$WorkdayGate,
        [switch]$LastWorkdayGate,
        [string]$PadSyncPath,
        [string]$PythonExe,
        [string]$CalendarPath,
        [string]$AcceptanceFile,
        [string]$ConfigFile,
        [string]$WorkdayScript,
        [int]$RunTimeoutSec = 4200
    )
    # Only the run timeout is frozen here. -LockWaitSec is deliberately kept out of the task command:
    # pad-schedule takes its own default (currently 5400 seconds) at run time, so the task XML cannot
    # keep a stale value that drifts from the code default
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $ScriptPath + '"'),
        '-FlowName', ('"' + $FlowName + '"'),
        '-RunTimeoutSec', [string]$RunTimeoutSec)
    if ($LastWorkdayGate) {
        $argList += @('-RunIfLastWorkday',
            '-PadSyncPath', ('"' + $PadSyncPath + '"'),
            '-PythonExe', ('"' + $PythonExe + '"'),
            '-CalendarPath', ('"' + $CalendarPath + '"'))
        if ($WorkdayScript) { $argList += @('-WorkdayScript', ('"' + $WorkdayScript + '"')) }
    } elseif ($WorkdayGate) {
        $argList += @('-RunIfWorkday',
            '-PadSyncPath', ('"' + $PadSyncPath + '"'),
            '-PythonExe', ('"' + $PythonExe + '"'),
            '-CalendarPath', ('"' + $CalendarPath + '"'))
        if ($WorkdayScript) { $argList += @('-WorkdayScript', ('"' + $WorkdayScript + '"')) }
    } else {
        $argList += '-RunOnly'
    }
    if ($AcceptanceFile) { $argList += @('-AcceptanceFile', ('"' + $AcceptanceFile + '"')) }
    if ($ConfigFile) { $argList += @('-ConfigFile', ('"' + $ConfigFile + '"')) }
    if ($AllowProd) { $argList += '-AllowProd' }
    # Launched through run-hidden.vbs: the first argument is the executable and the rest are passed
    # through unchanged, so the scheduled task's "last run result" still gets powershell's real exit code
    $vbsArgs = '//nologo "' + $script:HiddenLauncher + '" "powershell.exe" ' + ($argList -join ' ')
    return [ordered]@{ exe = 'wscript.exe'; args = $vbsArgs }
}

# Check the calendar to decide whether today is a workday. Returns [ordered]@{ workday; calendarOk }
# An unreadable calendar or a failing check script is always a hard failure: never guess Monday-Friday and keep running (that would fire on holidays)
function Test-TodayWorkday([string]$PythonExe, [string]$WorkdayScript, [string]$CalendarPath) {
    if (-not $WorkdayScript -or -not (Test-Path $WorkdayScript)) {
        throw "CALENDAR_SCRIPT_FAILED: workday check script failed: script not found $WorkdayScript"
    }
    if (-not $CalendarPath -or -not (Test-Path $CalendarPath)) {
        throw "CALENDAR_UNAVAILABLE: workday calendar file missing or unreadable: $CalendarPath"
    }
    try {
        $out = & $PythonExe $WorkdayScript --is-workday --calendar $CalendarPath 2>&1 | Out-String
    } catch {
        throw "CALENDAR_SCRIPT_FAILED: workday check script failed: $($_.Exception.Message)"
    }
    $m = [regex]::Match($out, 'WORKDAY=(\d)')
    if (-not $m.Success) {
        throw "CALENDAR_SCRIPT_FAILED: workday check script failed: $($out.Trim())"
    }
    # The script ran but returned CALENDAR_OK=0: the calendar opens yet its header cannot be recognised, so again we must not guess
    if ($out -match 'CALENDAR_OK=0') {
        throw "CALENDAR_UNAVAILABLE: workday calendar file unreadable or badly formatted: $CalendarPath"
    }
    # The calendar is readable but does not cover today: we must not treat that as "a day off" and skip silently; it is a hard failure
    if ($out -match 'CALENDAR_STALE=1') {
        $min = [regex]::Match($out, 'CALENDAR_MIN=([^\r\n]*)').Groups[1].Value.Trim()
        $max = [regex]::Match($out, 'CALENDAR_MAX=([^\r\n]*)').Groups[1].Value.Trim()
        # Exception carrying Data['code']: callers classify by code instead of parsing message text
        $msg = "CALENDAR_STALE: calendar does not cover today: today $((Get-Date).ToString('yyyy-MM-dd')) (covered $min ~ $max); treating the calendar as stale; this run did not execute"
        $ex = [System.Exception]::new($msg)
        $ex.Data['code'] = 'CALENDAR_STALE'
        # The covered range travels with the exception, so callers no longer regex it out of the message
        $ex.Data['calendarRange'] = "$min ~ $max"
        throw $ex
    }
    return [ordered]@{ workday = ($m.Groups[1].Value -eq '1'); calendarOk = $true }
}

# Classification of calendar failures: stale (exit 5) and unavailable (exit 1) must stay distinct
function Get-CalendarFailure([System.Exception]$Exception) {
    # Classification relies on the result code carried by the exception, not on matching message text
    if ([string]$Exception.Data['code'] -eq 'CALENDAR_STALE') {
        return [ordered]@{ exitCode = 5; reason = 'calendar-stale'; stale = $true }
    }
    return [ordered]@{ exitCode = 1; reason = 'calendar-unavailable'; stale = $false }
}

# The single implementation of alert classification and writing lives in PadAlerts.psm1:
# the scheduling layer and the direct-call layer (pad-sync / pad-deploy / pad-release) share one
# set of kind definitions and one de-duplication rule; this script keeps no copy.
Import-Module (Join-Path $here 'PadAlerts.psm1') -Force

# Check the calendar to decide whether today is the last workday of this month. Returns [ordered]@{ lastWorkday; calendarOk }
# Same policy as Test-TodayWorkday: any calendar or script problem is a hard failure; never fall back to Monday-Friday guessing
function Test-TodayLastWorkday([string]$PythonExe, [string]$WorkdayScript, [string]$CalendarPath) {
    # Probe calendar readability with --is-workday first: --is-last-workday does not emit CALENDAR_OK,
    # so without the probe a corrupted calendar would be misread as "not the month-end workday" and skipped silently
    Test-TodayWorkday $PythonExe $WorkdayScript $CalendarPath | Out-Null
    try {
        $out = & $PythonExe $WorkdayScript --is-last-workday --calendar $CalendarPath 2>&1 | Out-String
    } catch {
        throw "CALENDAR_SCRIPT_FAILED: workday check script failed: $($_.Exception.Message)"
    }
    $m = [regex]::Match($out, 'LAST_WORKDAY=(\d)')
    if (-not $m.Success) {
        throw "CALENDAR_SCRIPT_FAILED: workday check script failed: $($out.Trim())"
    }
    return [ordered]@{ lastWorkday = ($m.Groups[1].Value -eq '1'); calendarOk = $true }
}

# ── Main flow ─────────────────────────────────────────────────
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; action = 'register'; flow = $FlowName; taskName = $null
        time = $Time; taskPath = $null; nextRunTime = $null; lastRunTime = $null
        lastTaskResult = $null; workdayGate = (-not $IgnoreCalendar)
        calendarOk = $null
        skipped = $false; reason = $null; runExitCode = $null
        dryRun = [bool]$DryRun; errors = @()
    }
    try {
        # The scheduled task's working directory is not the repository root, so criteria/config paths must be turned into absolute paths before they go into the task action
        if ($AcceptanceFile) { $AcceptanceFile = (Resolve-Path -LiteralPath $AcceptanceFile).Path }
        if ($ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
        if (-not $TaskName) { $TaskName = Get-ScheduleTaskName $FlowName }
        $result.taskName = $TaskName
        $result.taskPath = '\' + $TaskName

        # ── Run entry point (the branch Task Scheduler actually calls) ──
        if ($RunIfWorkday -or $RunIfLastWorkday) {
            $result.action = $(if ($RunIfLastWorkday) { 'run-if-last-workday' } else { 'run-if-workday' })
            # Parameters needed by the run entry point must come in explicitly or from -ConfigPath; there is no fallback to any built-in path
            if (-not $WorkdayScript) { throw 'CONFIG_MISSING: WorkdayScript not provided (use -ConfigPath or an explicit parameter)' }
            if (-not $PythonExe) { throw 'CONFIG_MISSING: PythonExe not provided (use -ConfigPath or an explicit parameter)' }
            # The calendar must be supplied explicitly by the task action: when it is missing this is a hard failure and never degrades into "run every workday"
            if (-not $CalendarPath) { throw 'CONFIG_MISSING: workday calendar file not provided (use -ConfigPath or -CalendarPath)' }
            if (-not $PadSyncPath) { throw 'CONFIG_MISSING: PadSyncPath not provided (use -ConfigPath or an explicit parameter)' }

            if ($RunIfLastWorkday) {
                $lw = Test-TodayLastWorkday $PythonExe $WorkdayScript $CalendarPath
                $result.calendarOk = $lw.calendarOk
                if (-not $lw.lastWorkday) {
                    Log "today is not the last workday of this month; skipped (calendar: $CalendarPath)"
                    $result.ok = $true; $result.skipped = $true; $result.reason = 'not-last-workday'
                    $exitCode = 0
                    return
                }
            } else {
                $wd = Test-TodayWorkday $PythonExe $WorkdayScript $CalendarPath
                $result.calendarOk = $wd.calendarOk
                if (-not $wd.workday) {
                    Log "SKIP_NOT_WORKDAY: today is not a workday; skipped (calendar: $CalendarPath)"
                    $result.ok = $true; $result.skipped = $true; $result.reason = 'not-workday'
                    $exitCode = 0
                    return
                }
            }
            if (-not (Test-Path $PadSyncPath)) { throw "pad-sync.ps1 not found: $PadSyncPath" }
            Log "RUN_START: date check passed; starting $FlowName"
            $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PadSyncPath,
                '-FlowName', $FlowName, '-RunOnly', '-RunTimeoutSec', $RunTimeoutSec,
                '-LockWaitSec', $LockWaitSec, '-NonInteractive')
            if ($AllowProd) { $syncArgs += '-AllowProd' }
            if ($AcceptanceFile) {
                if (-not $ConfigFile) { throw '-AcceptanceFile requires -ConfigFile' }
                $syncArgs += @('-AcceptanceFile', $AcceptanceFile, '-ConfigFile', $ConfigFile)
            }
            # Stream the output while keeping it, so PAD_SYNC_RESULT can still be parsed (tickets and alerts need the stage)
            $syncLines = @(& powershell @syncArgs 2>&1 | ForEach-Object { Write-Host $_; $_ })
            $result.runExitCode = $LASTEXITCODE
            $result.ok = ($LASTEXITCODE -eq 0)
            $exitCode = $LASTEXITCODE
            # Write an alert only on a real failure: non-workday skips already returned earlier, so they cannot raise false alarms
            if ($exitCode -ne 0) {
                $sync = Read-ChildResult -Name 'SYNC' -Lines $syncLines
                $stage = if ($sync) { [string]$sync.stage } else { 'unknown' }
                $status = if ($sync) { [string]$sync.status } else { $null }
                $logPath = if ($sync) { [string]$sync.logPath } else { $null }
                $alert = Write-RunAlert -FlowName $FlowName -ExitCode $exitCode -Stage $stage `
                    -Status $status -SyncResult $sync -LogPath $logPath `
                    -RunId $(if ($sync) { [string]$sync.runId } else { $null })
                $result.alertLog = $alert.path
                $tip = if ($exitCode -eq 3) { 'the flow stopped at a manual-confirmation dialog (not auto-clicked); an alert was written' }
                    elseif ($exitCode -eq 4) { 'timed out waiting for the queue; this run did not execute (rerun later)' }
                    else { "run failed (stage=$stage)" }
                Log "$tip; an alert was written to $($alert.path)"
            }
            # Here we must exit, not return: return would skip the trailing exit $exitCode and leave
            # the scheduled task with LastTaskResult=0 while the alert says exitCode=1 (inconsistent)
            exit $exitCode
        }

        # ── Query ──
        if ($List) {
            $result.action = 'list'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { throw "scheduled task not found: $TaskName (register once without -List first)" }
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            $result.nextRunTime = $info.NextRunTime
            $result.lastRunTime = $info.LastRunTime
            $result.lastTaskResult = $info.LastTaskResult
            Log ("next run: {0}; last run: {1} (result {2})" -f $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult)
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── Remove ──
        if ($Remove) {
            $result.action = 'remove'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { Log "scheduled task does not exist; nothing to delete: $TaskName"; $result.ok = $true; $exitCode = 0; return }
            if ($DryRun) { Log "[DryRun] would delete the scheduled task: $TaskName"; $result.ok = $true; $exitCode = 0; return }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Log "deleted the scheduled task: $TaskName"
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── Trigger now (for verification; it really runs the flow once) ──
        if ($RunNow) {
            $result.action = 'run-now'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { throw "scheduled task not found: $TaskName" }
            if ($DryRun) { Log "[DryRun] would trigger now: $TaskName"; $result.ok = $true; $exitCode = 0; return }
            Start-ScheduledTask -TaskName $TaskName
            Log "triggered the scheduled task: $TaskName (see business\manifest.jsonl for the run result)"
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── Register/update ──
        if (-not $PadSyncPath) { throw 'CONFIG_MISSING: PadSyncPath not provided (use -ConfigPath or an explicit parameter)' }
        if (-not (Test-Path $PadSyncPath)) { throw "pad-sync.ps1 not found: $PadSyncPath" }
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw 'safety fuse: only PAD_SYNC_TEST may be scheduled by default. Add -AllowProd explicitly for a production flow.'
        }
        if ($AcceptanceFile -and -not $ConfigFile) {
            throw '-AcceptanceFile requires -ConfigFile'
        }
        $gate = -not $IgnoreCalendar
        # Calendar-dependent modes (calendar gate / last-workday only) must be given the calendar and its
        # dependencies explicitly; there are no built-in default paths any more
        if ($gate -or $LastWorkday) {
            if (-not $CalendarPath) { throw 'CONFIG_MISSING: workday calendar file not provided (use -ConfigPath or -CalendarPath)' }
            if (-not $PythonExe) { throw 'CONFIG_MISSING: PythonExe not provided (use -ConfigPath or an explicit parameter)' }
            if (-not $WorkdayScript) { throw 'CONFIG_MISSING: WorkdayScript not provided (use -ConfigPath or an explicit parameter)' }
        }

        $at = ConvertTo-ScheduleTime $Time
        if ($LastWorkday) {
            $spec = New-ScheduleActionSpec -ScriptPath $PSCommandPath -FlowName $FlowName `
                -AllowProd:$AllowProd -LastWorkdayGate `
                -PadSyncPath $PadSyncPath -PythonExe $PythonExe -CalendarPath $CalendarPath `
                -WorkdayScript $WorkdayScript `
                -AcceptanceFile $AcceptanceFile -ConfigFile $ConfigFile `
                -RunTimeoutSec $RunTimeoutSec
            Log ("trigger: daily at {0:HH:mm}, run only on the last workday of the month (calendar: {1})" -f $at, $CalendarPath)
        } elseif ($gate) {
            $spec = New-ScheduleActionSpec -ScriptPath $PSCommandPath -FlowName $FlowName `
                -AllowProd:$AllowProd -WorkdayGate `
                -PadSyncPath $PadSyncPath -PythonExe $PythonExe -CalendarPath $CalendarPath `
                -WorkdayScript $WorkdayScript `
                -AcceptanceFile $AcceptanceFile -ConfigFile $ConfigFile `
                -RunTimeoutSec $RunTimeoutSec
            Log ("trigger: daily at {0:HH:mm}, gated by the workday calendar at run time (calendar: {1})" -f $at, $CalendarPath)
        } else {
            $spec = New-ScheduleActionSpec -ScriptPath $PadSyncPath -FlowName $FlowName -AllowProd:$AllowProd `
                -AcceptanceFile $AcceptanceFile -ConfigFile $ConfigFile `
                -RunTimeoutSec $RunTimeoutSec
            Log ("trigger: Monday-Friday {0:HH:mm} (IGNORE_CALENDAR: calendar ignored; it will run on holidays and skip make-up workdays)" -f $at)
        }
        Log "action: $($spec.exe) $($spec.args)"

        if ($DryRun) {
            Log "[DryRun] the scheduled task was not registered"
            $result.ok = $true; $exitCode = 0
            return
        }

        $action = New-ScheduledTaskAction -Execute $spec.exe -Argument $spec.args
        if ($gate) {
            # Trigger every day and let the calendar decide whether to actually run (skip holidays, run make-up workdays)
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
        } else {
            $trigger = New-ScheduledTaskTrigger -Weekly `
                -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $at
        }
        # The time limit must cover the worst combination of "queueing for the lock + the flow's own
        # longest path": 90 minutes waiting for the lock + 45 minutes running (including a long SAP
        # download) = 135 minutes. 150 minutes would theoretically suffice but leaves only 15 minutes,
        # which cannot absorb SAP login retries or a slow machine, so we use 180 minutes. The old
        # 30-minute limit would kill the task outright while a flow legitimately waited until 10:00.
        # Catch-up runs are explicitly disabled (StartWhenAvailable=False): triggers missed while the
        # machine sleeps or is off are not replayed on resume; otherwise a weekend instance would be
        # taken by the calendar gate as the current-day task at dawn on a workday, causing an
        # unplanned run.
        # Trade-off: if the machine is off at 9:00, nothing runs that day.
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable:$false `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 180) -MultipleInstances IgnoreNew
        # Interactive = run only while that user is logged in, which is exactly what attended means
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        $desc = "flow-ir: runs daily at $Time after the workday-calendar check, PAD flow $FlowName (attended)"

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -Description $desc | Out-Null

        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $result.nextRunTime = $info.NextRunTime
        Log "registered the scheduled task: $TaskName; next run: $($info.NextRunTime)"
        $result.ok = $true; $exitCode = 0
    }
    catch {
        $msg = $_.Exception.Message
        $result.errors += $msg
        if ($msg -match '^(CALENDAR_UNAVAILABLE|CALENDAR_SCRIPT_FAILED|CALENDAR_STALE)') {
            # Calendar failures come in two kinds: stale (exit 5 / calendar-stale) and unavailable (exit 1)
            $cal = Get-CalendarFailure $_.Exception
            $exitCode = $cal.exitCode
            $result.reason = $cal.reason
            if ($cal.stale) { $result.calendarOk = $null } else { $result.calendarOk = $false }
            $range = [string]$_.Exception.Data['calendarRange']
            if ($cal.stale) {
                $alert = Write-RunAlert -FlowName $FlowName -ExitCode $exitCode -Stage 'calendar' `
                    -Status 'skipped' -CalendarStale -CalendarRange $range
            } else {
                $alert = Write-RunAlert -FlowName $FlowName -ExitCode $exitCode -Stage 'calendar' `
                    -Status 'skipped' -CalendarOk $false
            }
            $result.alertLog = $alert.path
        }
        Log "failed at [$($result.action)]: $msg"
    }
    finally {
        Write-Output ('PAD_SCHEDULE_RESULT=' + ($result | ConvertTo-Json -Depth 6 -Compress))
    }
    exit $exitCode
}
