# pad-schedule.Tests.ps1 — pure-function tests for the scheduler (Pester 3.4, bundled with PS 5.1)
#
# Covers: task-name generation and illegal-character substitution, trigger-time parsing and
#         format validation, action-command construction (workday calendar gate / ignore calendar /
#         -AllowProd pass-through), and the error raised when the workday check script is missing.
#
# Pure functions only — no real scheduled task is registered or deleted.

. (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-schedule.ps1') -NoMain

Describe 'pad-schedule pure function tests' {

    It 'task name: default prefix plus flow name' {
        (Get-ScheduleTaskName 'PAD_SYNC_TEST') | Should Be 'flow-ir-PAD_SYNC_TEST'
    }

    It 'task name: whitespace and path separators become underscores' {
        (Get-ScheduleTaskName '示例流程/日常 汇总') | Should Be 'flow-ir-示例流程_日常_汇总'
    }

    It 'task name: empty flow name raises an error' {
        { Get-ScheduleTaskName '  ' } | Should Throw
    }

    It 'trigger time: both HH:mm and H:mm parse' {
        (ConvertTo-ScheduleTime '09:00').ToString('HH:mm') | Should Be '09:00'
        (ConvertTo-ScheduleTime '9:30').ToString('HH:mm') | Should Be '09:30'
    }

    It 'trigger time: an invalid format raises an error and shows the correct form' {
        { ConvertTo-ScheduleTime '二十五点' } | Should Throw
        try { ConvertTo-ScheduleTime 'abc' } catch { $_.Exception.Message | Should Match 'HH:mm' }
    }

    It 'action command: workday calendar mode calls this script with -RunIfWorkday and the calendar arguments' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-schedule.ps1' -FlowName 'PAD_SYNC_TEST' `
            -WorkdayGate -PadSyncPath 'C:\repo\tools\pad-sync\pad-sync.ps1' `
            -PythonExe 'C:\Python313\python.exe' -CalendarPath 'C:\cal\workday-calendar.xlsx'
        $s.exe | Should Be 'wscript.exe'
        $s.args | Should Match 'run-hidden\.vbs'
        $s.args | Should Match 'powershell\.exe'
        $s.args | Should Match '-RunIfWorkday'
        $s.args | Should Match 'workday-calendar\.xlsx'
        $s.args | Should Match 'Python313'
        $s.args | Should Not Match 'RunOnly'
    }

    # The cases below run the real script in a child process, checking exit codes and messages when the calendar is omitted
    $scheduleScript = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-schedule.ps1'
    $workdayScript = Join-Path $PSScriptRoot '..\tools\workday\workday.py'

    It 'run entry without a calendar: non-zero exit with an explicit hint to use -CalendarPath' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -PythonExe 'python' `
            -WorkdayScript $workdayScript -PadSyncPath $scheduleScript 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        # ASCII anchor: CONFIG_MISSING plus -CalendarPath together pin down the "missing calendar" error
        $out | Should Match 'CONFIG_MISSING'
        $out | Should Match 'CalendarPath'
        # A silent downgrade to "run on every workday" must never happen
        $out | Should Not Match 'RUN_START'
    }

    It 'run entry with a missing calendar file: non-zero exit, nothing runs and calendarOk=false' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -PythonExe 'python' `
            -WorkdayScript $workdayScript -PadSyncPath $scheduleScript `
            -CalendarPath (Join-Path $TestDrive 'nope.xlsx') 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'CALENDAR_UNAVAILABLE'
        # A silent downgrade to "run on every workday" must never happen
        $out | Should Not Match 'RUN_START'
        # Alert severity relies on this marker to tell "calendar unavailable" from "run failed"
        $r = [regex]::Match($out, 'PAD_SCHEDULE_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.calendarOk | Should Be $false
        $r.reason | Should Be 'calendar-unavailable'
    }

    It 'workday check script failure: non-zero exit, nothing runs and calendarOk=false' {
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
        $calendar = Join-Path $TestDrive 'workday-calendar.xlsx'
        [IO.File]::WriteAllBytes($calendar, [byte[]](1, 2, 3))
        $probe = Join-Path $TestDrive 'probe_fail.py'
        [IO.File]::WriteAllText($probe, "import sys`nsys.exit(3)`n",
            (New-Object Text.UTF8Encoding($false))
        )
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -CalendarPath $calendar `
            -PythonExe $py -WorkdayScript $probe -PadSyncPath $scheduleScript 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'CALENDAR_SCRIPT_FAILED'
        $out | Should Not Match 'RUN_START'
        $r = [regex]::Match($out, 'PAD_SCHEDULE_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.calendarOk | Should Be $false
        $r.reason | Should Be 'calendar-unavailable'
    }

    It 'register mode without a calendar: also a non-zero exit with no silent downgrade' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -DryRun -PythonExe 'python' `
            -WorkdayScript $workdayScript -PadSyncPath $scheduleScript 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'CONFIG_MISSING'
        $out | Should Match '-CalendarPath'
    }

    It 'ignore-calendar mode needs no -CalendarPath (skipping the calendar requires an explicit declaration)' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -DryRun -IgnoreCalendar -PadSyncPath $scheduleScript 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'IGNORE_CALENDAR'
        $out | Should Not Match 'CONFIG_MISSING'
    }

    It 'calendar supplied: the arguments are accepted and forwarded verbatim to the workday check (skip on a non-workday)' {
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
        $probe = Join-Path $TestDrive 'probe_calendar.py'
        $probeLog = Join-Path $TestDrive 'probe_args.txt'
        # Fake workday script: writes the arguments it received to a file (so forwarding can be asserted)
        # and declares that today is not a workday (taking the skip branch, never running the real flow)
        $logArg = $probeLog.Replace('\', '/')
        [IO.File]::WriteAllText($probe,
            "import sys`nopen(r'$logArg','w',encoding='utf-8').write(' '.join(sys.argv[1:]))`nprint('WORKDAY=0')`nprint('CALENDAR_OK=1')`n",
            (New-Object Text.UTF8Encoding($false))
        )
        # The calendar only has to exist (the fake script here never parses it); a placeholder file will do
        $calendar = Join-Path $TestDrive 'workday-calendar.xlsx'
        [IO.File]::WriteAllBytes($calendar, [byte[]](1, 2, 3))
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -CalendarPath $calendar `
            -PythonExe $py -WorkdayScript $probe -PadSyncPath $scheduleScript 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'SKIP_NOT_WORKDAY'
        # The arguments really reached the workday script verbatim instead of being replaced with built-in defaults
        (Test-Path $probeLog) | Should Be $true
        ([IO.File]::ReadAllText($probeLog, [Text.Encoding]::UTF8)) | Should Match 'workday-calendar\.xlsx'
    }

    It 'action command: ignore-calendar mode calls pad-sync -RunOnly directly' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST'
        $s.args | Should Match '-RunOnly'
        $s.args | Should Not Match 'RunIfWorkday'
        $s.args | Should Not Match 'AllowProd'
    }

    It 'action command: -AllowProd is forwarded to the called script (production flow)' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName '生产流程' -AllowProd
        $s.args | Should Match 'AllowProd'
        $s.args | Should Match '生产流程'
    }

    It 'action command: acceptance criteria and config are forwarded to the called script' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST' `
            -AcceptanceFile 'C:\repo\business\flows\x.acceptance.json' -ConfigFile 'C:\repo\business\config\x.json'
        $s.args | Should Match '-AcceptanceFile'
        $s.args | Should Match 'x\.acceptance\.json'
        $s.args | Should Match '-ConfigFile'
        $s.args | Should Match 'business\\config\\x\.json'
    }

    It 'action command: pins -RunTimeoutSec but not -LockWaitSec (runtime default)' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\pad-schedule.ps1' -FlowName 'PAD_SYNC_TEST' `
            -RunTimeoutSec 4200
        $s.args | Should Match '-RunTimeoutSec'
        $s.args | Should Match '4200'
        # The lock-wait cap is not baked into the task command: changing the code default applies without re-registering the task
        $s.args | Should Not Match '-LockWaitSec'

        $s2 = New-ScheduleActionSpec -ScriptPath 'C:\repo\pad-schedule.ps1' -FlowName 'PAD_SYNC_TEST' `
            -RunTimeoutSec 300
        $s2.args | Should Match '300'
        $s2.args | Should Not Match '-LockWaitSec'
    }

    It 'paths with spaces are quoted so -File is not truncated' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\flow-ir\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST'
        $s.args | Should Match '"C:\\flow-ir\\pad-sync.ps1"'
    }

    It 'workday check: a missing calendar file raises an error instead of falling back to Monday through Friday' {
        $script = Join-Path $PSScriptRoot '..\tools\workday\workday.py'
        try {
            Test-TodayWorkday 'python' $script (Join-Path $TestDrive 'nope.xlsx')
            throw '预期应当抛错，但没有'
        } catch {
            $_.Exception.Message | Should Match 'workday calendar file missing or unreadable'
        }
    }

    It 'workday check: a missing check script raises an error instead of falling back to Monday through Friday' {
        try {
            Test-TodayWorkday 'python' (Join-Path $TestDrive 'nope.py') (Join-Path $TestDrive 'nope.xlsx')
            throw '预期应当抛错，但没有'
        } catch {
            $_.Exception.Message | Should Match 'workday check script failed'
        }
    }

    It 'stale calendar: CALENDAR_STALE=1 is a hard failure, not a day off' {
        # Replay workday.py output with a fake python (a cmd shim) so the case does not depend on a real calendar
        $fake = Join-Path $TestDrive 'fake-python.cmd'
        Set-Content -LiteralPath $fake -Encoding ASCII -Value @(
            '@echo off',
            'echo CALENDAR_OK=1',
            'echo WORKDAY=1',
            'echo CALENDAR_STALE=1',
            'echo CALENDAR_MIN=2026-01-01',
            'echo CALENDAR_MAX=2026-10-31'
        )
        $cal = Join-Path $TestDrive 'calendar.xlsx'
        Set-Content -LiteralPath $cal -Value 'x' -Encoding UTF8
        $script = Join-Path $PSScriptRoot '..\tools\workday\workday.py'
        try {
            Test-TodayWorkday $fake $script $cal
            throw '预期应当抛错，但没有'
        } catch {
            $_.Exception.Message | Should Match 'calendar does not cover today'
            $_.Exception.Message | Should Match '\(covered 2026-01-01 ~ 2026-10-31\)'
        }
    }

    It 'calendar failure classification: stale is exit 5 / calendar-stale, unavailable stays exit 1' {
        # Classification now keys off the result code carried on the exception, not the Chinese message text
        $staleEx = [System.Exception]::new('CALENDAR_STALE: calendar does not cover today: today 2026-11-05 (covered 2026-01-01 ~ 2026-10-31); treating the calendar as stale; this run did not execute')
        $staleEx.Data['code'] = 'CALENDAR_STALE'
        $stale = Get-CalendarFailure $staleEx
        $stale.exitCode | Should Be 5
        $stale.reason | Should Be 'calendar-stale'
        $stale.stale | Should Be $true
        $down = Get-CalendarFailure ([System.Exception]::new('CALENDAR_UNAVAILABLE: workday calendar file missing or unreadable: C:\x\cal.xlsx'))
        $down.exitCode | Should Be 1
        $down.reason | Should Be 'calendar-unavailable'
        $down.stale | Should Be $false
    }

    It 'stale calendar alert: kind=calendar-stale with calendarRange and no calendarOk' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $a = Write-RunAlert -FlowName 'F' -ExitCode 5 -Stage 'calendar' -Status 'skipped' `
            -CalendarStale -CalendarRange '2026-01-01 ~ 2026-10-31' -Dir $dir
        $a.record.kind | Should Be 'calendar-stale'
        $a.record.reason | Should Be 'calendar-stale'
        $a.record.exitCode | Should Be 5
        $a.record.calendarStale | Should Be $true
        $a.record.calendarRange | Should Be '2026-01-01 ~ 2026-10-31'
        $a.record.note | Should Match 'Next step: update the calendar file and rerun manually\.'
    }

    It 'parse PAD_SYNC_RESULT: take the last line; null when absent' {
        $lines = @(
            '[pad-sync] 开始',
            'PAD_SYNC_RESULT={"ok":true,"stage":"done"}',
            'PAD_SYNC_RESULT={"ok":false,"stage":"run"}'
        )
        (Read-ChildResult -Name 'SYNC' -Lines $lines).stage | Should Be 'run'
        (Read-ChildResult -Name 'SYNC' -Lines @('nothing here')) | Should Be $null
    }

    It 'failure alerts are JSONL only: complete fields, no BOM, parseable line by line' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = ('{"ok":false,"stage":"run","status":"failed","error":{"code":"E1","message":"boom"},"logPath":"C:\\x\\Actions.log"}' | ConvertFrom-Json)
        $a = Write-RunAlert -FlowName 'PAD_SYNC_TEST' -ExitCode 1 -Stage 'run' `
            -Status 'failed' -SyncResult $sync -LogPath 'C:\x\Actions.log' -Dir $dir
        $a.path | Should Be (Join-Path $dir 'alerts.jsonl')
        # PS 5.1's Add-Content emits a BOM, which breaks line-by-line parsing; this pins "no BOM"
        ([IO.File]::ReadAllBytes($a.path))[0] | Should Not Be 0xEF
        $rec = ([IO.File]::ReadAllText($a.path, [Text.Encoding]::UTF8)).Trim() | ConvertFrom-Json
        $rec.kind | Should Be 'run-failed'
        $rec.flow | Should Be 'PAD_SYNC_TEST'
        $rec.exitCode | Should Be 1
        $rec.stage | Should Be 'run'
        $rec.errorCode | Should Be 'E1'
        $rec.error | Should Be 'boom'
    }

    It 'alert classification: exit 4 records run-lock-timeout (did not execute), 1 still records run-failed' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # 4 = lock wait timeout: the flow never ran, and the alert should make that obvious at a glance
        Write-RunAlert -FlowName 'F' -ExitCode 4 -Stage 'lock' -Dir $dir | Out-Null
        # 1 = ran but failed
        Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir | Out-Null
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir 'alerts.jsonl'), [Text.Encoding]::UTF8) |
            Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        $lock = $lines[0] | ConvertFrom-Json
        $lock.kind | Should Be 'run-lock-timeout'
        $lock.note | Should Match 'Timed out waiting for the queue; this run did not execute\.'
        $fail = $lines[1] | ConvertFrom-Json
        $fail.kind | Should Be 'run-failed'
        $fail.note | Should Match 'Next step: check the logs and the PAD console, then rerun manually\.'
    }

    It 'alert log appends without overwriting the previous entry' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir | Out-Null
        Write-RunAlert -FlowName 'F' -ExitCode 2 -Stage 'acceptance' -Dir $dir | Out-Null
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir 'alerts.jsonl'), [Text.Encoding]::UTF8) |
            Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        ($lines[1] | ConvertFrom-Json).stage | Should Be 'acceptance'
    }

    It 'alert classification: exit 3 records run-needs-human-confirm with the dialog title' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = [pscustomobject]@{
            needsHumanConfirm = $true
            dialogTitle = '示例业务报表'
        }
        $a = Write-RunAlert -FlowName 'F' -ExitCode 3 -Stage 'needs-human-confirm' `
            -Status 'NeedsHumanConfirm' -SyncResult $sync -Dir $dir
        $a.record.kind | Should Be 'run-needs-human-confirm'
        $a.record.exitCode | Should Be 3
        $a.record.note | Should Match 'manual-confirmation'
        $a.record.status | Should Be 'NeedsHumanConfirm'
    }

    It 'alert classification: exit 0 with needsHumanConfirm still alerts as human confirmation' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = [pscustomobject]@{ needsHumanConfirm = $true; dialogTitle = '核对完成' }
        (Write-RunAlert -FlowName 'F' -ExitCode 0 -Stage 'needs-human-confirm' -SyncResult $sync -Dir $dir).record.kind |
            Should Be 'run-needs-human-confirm'
    }

    It 'alert classification: trigger failure records trigger-failed with a reason-specific note' {
        foreach ($reason in @('identity-mismatch', 'no-evidence', 'no-robot')) {
            $sync = [pscustomobject]@{ triggerFailed = $true; triggerReason = $reason }
            $g = Get-RunAlertKind -ExitCode 1 -SyncResult $sync
            $g.kind | Should Be 'trigger-failed'
            $g.reason | Should Be $reason
            $g.note | Should Match 'nothing was retried automatically'
        }
        # Without a reason it falls back to unknown but stays trigger-failed, never degrading to run-failed
        $g2 = Get-RunAlertKind -ExitCode 1 -SyncResult ([pscustomobject]@{ triggerFailed = $true })
        $g2.kind | Should Be 'trigger-failed'
        $g2.reason | Should Be 'unknown'
    }

    It 'alert classification: a run timeout records run-timeout instead of being swallowed by Unknown' {
        $sync = [pscustomobject]@{ runTimeout = $true }
        $g = Get-RunAlertKind -ExitCode 1 -SyncResult $sync
        $g.kind | Should Be 'run-timeout'
        $g.note | Should Match 'without reaching a terminal state'
    }

    It 'a trigger failure writes a reason field to JSONL without disturbing the existing classification' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = [pscustomobject]@{
            triggerFailed = $true; triggerReason = 'no-robot'
            error = [pscustomobject]@{ code = 'TRIGGER_NO_ROBOT'; message = '机器人未启动' }
        }
        $a = Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'trigger' `
            -Status 'NotStarted' -SyncResult $sync -Dir $dir
        $a.record.kind | Should Be 'trigger-failed'
        $a.record.reason | Should Be 'no-robot'
        $a.record.errorCode | Should Be 'TRIGGER_NO_ROBOT'
        $a.record.note | Should Match 'nothing was retried automatically'
        # The three existing alert kinds are still produced and not crowded out by the new classification
        (Write-RunAlert -FlowName 'F' -ExitCode 4 -Stage 'lock' -Dir $dir).record.kind |
            Should Be 'run-lock-timeout'
        (Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir).record.kind |
            Should Be 'run-failed'
    }
}
