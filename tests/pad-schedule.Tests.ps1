# pad-schedule.Tests.ps1 — 定时任务纯函数测试（Pester 3.4，PS 5.1 自带）
#
# 覆盖：任务名生成与非法字符替换、触发时刻解析与格式校验、
#       任务动作命令构造（工作日历门禁 / 忽略日历 / -AllowProd 透传）、
#       工作日判断脚本缺失时的报错。
#
# 只测纯函数，不注册/删除任何真实计划任务。

. (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-schedule.ps1') -NoMain

Describe 'pad-schedule 纯函数测试' {

    It '任务名：默认前缀 + 流程名' {
        (Get-ScheduleTaskName 'PAD_SYNC_TEST') | Should Be 'flow-ir-PAD_SYNC_TEST'
    }

    It '任务名：空白与路径分隔符统一替换成下划线' {
        (Get-ScheduleTaskName '示例流程/核对 每日报表') | Should Be 'flow-ir-示例流程_核对_每日报表'
    }

    It '任务名：空流程名直接报错' {
        { Get-ScheduleTaskName '  ' } | Should Throw
    }

    It '触发时刻：HH:mm 与 H:mm 都能解析' {
        (ConvertTo-ScheduleTime '09:00').ToString('HH:mm') | Should Be '09:00'
        (ConvertTo-ScheduleTime '9:30').ToString('HH:mm') | Should Be '09:30'
    }

    It '触发时刻：非法格式报错并给出正确写法' {
        { ConvertTo-ScheduleTime '二十五点' } | Should Throw
        try { ConvertTo-ScheduleTime 'abc' } catch { $_.Exception.Message | Should Match 'HH:mm' }
    }

    It '动作命令：工作日历模式，任务先调本脚本 -RunIfWorkday 并带上日历参数' {
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

    # 下面几条用子进程跑真实脚本，验证「日历缺省」时的退出码与文案
    $scheduleScript = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-schedule.ps1'

    It '运行入口不传日历：非零退出，并明确提示用 -CalendarPath 指定' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match '未提供工作日日历文件'
        $out | Should Match 'CalendarPath'
        # 绝不能静默退化成「每个工作日都跑」
        $out | Should Not Match '开始运行'
    }

    It '运行入口日历文件不存在：非零退出、不运行，并标记 calendarOk=false' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -CalendarPath (Join-Path $TestDrive 'nope.xlsx') 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match '工作日历文件不存在或读不到'
        # 绝不能静默退化成「每个工作日都跑」
        $out | Should Not Match '开始运行'
        # 告警分级要靠这个标记区分「日历不可用」与「运行失败」
        $r = [regex]::Match($out, 'PAD_SCHEDULE_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.calendarOk | Should Be $false
        $r.reason | Should Be 'calendar-unavailable'
    }

    It '工作日判断脚本执行失败：非零退出、不运行，并标记 calendarOk=false' {
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
            -PythonExe $py -WorkdayScript $probe 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match '工作日判断脚本执行失败'
        $out | Should Not Match '开始运行'
        $r = [regex]::Match($out, 'PAD_SCHEDULE_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.calendarOk | Should Be $false
        $r.reason | Should Be 'calendar-unavailable'
    }

    It '注册模式不传日历：同样非零退出，不静默降级' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match '未提供工作日日历文件'
    }

    It '忽略日历模式不需要 -CalendarPath（显式声明才允许不看日历）' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -DryRun -IgnoreCalendar 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match '忽略日历'
        $out | Should Not Match '未提供工作日日历文件'
    }

    It '传入日历：参数被接受并原样转发给工作日判断脚本（不是工作日则跳过）' {
        $py = (Get-Command python -ErrorAction SilentlyContinue).Source
        if (-not $py) { $py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
        $probe = Join-Path $TestDrive 'probe_calendar.py'
        $probeLog = Join-Path $TestDrive 'probe_args.txt'
        # 假判断脚本：把收到的参数落到文件（便于断言转发），并声明今天不是工作日
        # （走跳过分支，不触发真实流程）
        $logArg = $probeLog.Replace('\', '/')
        [IO.File]::WriteAllText($probe,
            "import sys`nopen(r'$logArg','w',encoding='utf-8').write(' '.join(sys.argv[1:]))`nprint('WORKDAY=0')`nprint('CALENDAR_OK=1')`n",
            (New-Object Text.UTF8Encoding($false))
        )
        # 日历只需存在（本用例的假脚本不解析内容），用占位文件即可
        $calendar = Join-Path $TestDrive 'workday-calendar.xlsx'
        [IO.File]::WriteAllBytes($calendar, [byte[]](1, 2, 3))
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $scheduleScript `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -CalendarPath $calendar `
            -PythonExe $py -WorkdayScript $probe 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match '今天不是工作日'
        # 参数确实原样传到了判断脚本，而不是被替换成内置默认值
        (Test-Path $probeLog) | Should Be $true
        ([IO.File]::ReadAllText($probeLog, [Text.Encoding]::UTF8)) | Should Match 'workday-calendar\.xlsx'
    }

    It '动作命令：忽略日历模式，直接调 pad-sync -RunOnly' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST'
        $s.args | Should Match '-RunOnly'
        $s.args | Should Not Match 'RunIfWorkday'
        $s.args | Should Not Match 'AllowProd'
    }

    It '动作命令：-AllowProd 透传给被调脚本（生产流程）' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName '生产流程' -AllowProd
        $s.args | Should Match 'AllowProd'
        $s.args | Should Match '生产流程'
    }

    It '动作命令：验收判据与配置透传给被调脚本' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\tools\pad-sync\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST' `
            -AcceptanceFile 'C:\repo\business\flows\x.acceptance.json' -ConfigFile 'C:\repo\business\config\x.json'
        $s.args | Should Match '-AcceptanceFile'
        $s.args | Should Match 'x\.acceptance\.json'
        $s.args | Should Match '-ConfigFile'
        $s.args | Should Match 'business\\config\\x\.json'
    }

    It '动作命令：固化 -RunTimeoutSec，但不固化 -LockWaitSec（运行时取默认值）' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\repo\pad-schedule.ps1' -FlowName 'PAD_SYNC_TEST' `
            -RunTimeoutSec 4200
        $s.args | Should Match '-RunTimeoutSec'
        $s.args | Should Match '4200'
        # 锁等待上限不写进任务命令：改了代码默认值后，任务无需重新注册也会跟着变
        $s.args | Should Not Match '-LockWaitSec'

        $s2 = New-ScheduleActionSpec -ScriptPath 'C:\repo\pad-schedule.ps1' -FlowName 'PAD_SYNC_TEST' `
            -RunTimeoutSec 300
        $s2.args | Should Match '300'
        $s2.args | Should Not Match '-LockWaitSec'
    }

    It '路径含空格时自动加引号，避免 -File 被截断' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\flow-ir\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST'
        $s.args | Should Match '"C:\\flow-ir\\pad-sync.ps1"'
    }

    It '工作日判断：日历文件不存在时直接报错，不再按周一至周五兜底' {
        $script = Join-Path $PSScriptRoot '..\tools\workday\workday.py'
        try {
            Test-TodayWorkday 'python' $script (Join-Path $TestDrive 'nope.xlsx')
            throw '预期应当抛错，但没有'
        } catch {
            $_.Exception.Message | Should Match '工作日历文件不存在或读不到'
        }
    }

    It '工作日判断：判断脚本缺失时直接报错，不再按周一至周五兜底' {
        try {
            Test-TodayWorkday 'python' (Join-Path $TestDrive 'nope.py') (Join-Path $TestDrive 'nope.xlsx')
            throw '预期应当抛错，但没有'
        } catch {
            $_.Exception.Message | Should Match '工作日判断脚本执行失败'
        }
    }

    It '解析 PAD_SYNC_RESULT：取最后一行，缺失时返回空' {
        $lines = @(
            '[pad-sync] 开始',
            'PAD_SYNC_RESULT={"ok":true,"stage":"done"}',
            'PAD_SYNC_RESULT={"ok":false,"stage":"run"}'
        )
        (Read-ChildResult -Name 'SYNC' -Lines $lines).stage | Should Be 'run'
        (Read-ChildResult -Name 'SYNC' -Lines @('nothing here')) | Should Be $null
    }

    It '失败告警只写 JSONL：字段完整、不带 BOM、可逐行解析' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = ('{"ok":false,"stage":"run","status":"failed","error":{"code":"E1","message":"boom"},"logPath":"C:\\x\\Actions.log"}' | ConvertFrom-Json)
        $a = Write-RunAlert -FlowName 'PAD_SYNC_TEST' -ExitCode 1 -Stage 'run' `
            -Status 'failed' -SyncResult $sync -LogPath 'C:\x\Actions.log' -Dir $dir
        $a.path | Should Be (Join-Path $dir 'alerts.jsonl')
        # PS 5.1 的 Add-Content 会加 BOM，逐行解析会炸，这里钉死"无 BOM"
        ([IO.File]::ReadAllBytes($a.path))[0] | Should Not Be 0xEF
        $rec = ([IO.File]::ReadAllText($a.path, [Text.Encoding]::UTF8)).Trim() | ConvertFrom-Json
        $rec.kind | Should Be 'run-failed'
        $rec.flow | Should Be 'PAD_SYNC_TEST'
        $rec.exitCode | Should Be 1
        $rec.stage | Should Be 'run'
        $rec.errorCode | Should Be 'E1'
        $rec.error | Should Be 'boom'
    }

    It '告警分级：退出码 4 记 run-lock-timeout（本次未执行），1 仍记 run-failed' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # 4 = 等锁超时：流程根本没跑，告警要能一眼看出来
        Write-RunAlert -FlowName 'F' -ExitCode 4 -Stage 'lock' -Dir $dir | Out-Null
        # 1 = 跑了但失败
        Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir | Out-Null
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir 'alerts.jsonl'), [Text.Encoding]::UTF8) |
            Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        $lock = $lines[0] | ConvertFrom-Json
        $lock.kind | Should Be 'run-lock-timeout'
        $lock.note | Should Match '排队超时未执行'
        $fail = $lines[1] | ConvertFrom-Json
        $fail.kind | Should Be 'run-failed'
        ($fail.note -eq $null) | Should Be $true
    }

    It '告警日志追加写入，不覆盖上一条' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir | Out-Null
        Write-RunAlert -FlowName 'F' -ExitCode 2 -Stage 'acceptance' -Dir $dir | Out-Null
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir 'alerts.jsonl'), [Text.Encoding]::UTF8) |
            Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        ($lines[1] | ConvertFrom-Json).stage | Should Be 'acceptance'
    }

    It '告警分级：退出码 3 记 run-needs-human-confirm 并带弹窗标题' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = [pscustomobject]@{
            needsHumanConfirm = $true
            dialogTitle = '示例业务报表'
        }
        $a = Write-RunAlert -FlowName 'F' -ExitCode 3 -Stage 'needs-human-confirm' `
            -Status 'NeedsHumanConfirm' -SyncResult $sync -Dir $dir
        $a.record.kind | Should Be 'run-needs-human-confirm'
        $a.record.exitCode | Should Be 3
        $a.record.note | Should Match '人工确认'
        $a.record.status | Should Be 'NeedsHumanConfirm'
    }

    It '告警分级：退出码 0 但结果标记 needsHumanConfirm 时仍按人工确认告警' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $sync = [pscustomobject]@{ needsHumanConfirm = $true; dialogTitle = '核对完成' }
        (Write-RunAlert -FlowName 'F' -ExitCode 0 -Stage 'needs-human-confirm' -SyncResult $sync -Dir $dir).record.kind |
            Should Be 'run-needs-human-confirm'
    }
}
