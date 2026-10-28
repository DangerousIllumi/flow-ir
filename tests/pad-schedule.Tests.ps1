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
        (Get-ScheduleTaskName 'PAD_SYNC_TEST') | Should Be 'nlg-workflow-PAD_SYNC_TEST'
    }

    It '任务名：空白与路径分隔符统一替换成下划线' {
        (Get-ScheduleTaskName 'AI 生成/核对 每日报表') | Should Be 'nlg-workflow-AI_生成_核对_每日报表'
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
            -PythonExe 'C:\Python313\python.exe' -CalendarPath 'C:\PAD\2026_PAD工作日日历.xlsx'
        $s.exe | Should Be 'powershell.exe'
        $s.args | Should Match '-RunIfWorkday'
        $s.args | Should Match '2026_PAD'
        $s.args | Should Match 'Python313'
        $s.args | Should Not Match 'RunOnly'
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
            -AcceptanceFile 'C:\repo\flows\x.acceptance.json' -ConfigFile 'C:\repo\config\x.json'
        $s.args | Should Match '-AcceptanceFile'
        $s.args | Should Match 'x\.acceptance\.json'
        $s.args | Should Match '-ConfigFile'
        $s.args | Should Match 'config\\x\.json'
    }

    It '路径含空格时自动加引号，避免 -File 被截断' {
        $s = New-ScheduleActionSpec -ScriptPath 'C:\Workflow Graphics Engineering\pad-sync.ps1' -FlowName 'PAD_SYNC_TEST'
        $s.args | Should Match '"C:\\Workflow Graphics Engineering\\pad-sync.ps1"'
    }

    It '工作日判断：脚本缺失时按周一至周五兜底，并标记 fallback' {
        $r = Test-TodayWorkday 'python' 'C:\nope\workday.py' 'C:\nope\cal.xlsx'
        $r.fallback | Should Be $true
        $r.calendarOk | Should Be $false
        # 兜底结果应与"今天是不是周一到周五"一致
        $expect = ((Get-Date).DayOfWeek -ne 'Saturday' -and (Get-Date).DayOfWeek -ne 'Sunday')
        $r.workday | Should Be $expect
    }

    It '解析 PAD_SYNC_RESULT：取最后一行，缺失时返回空' {
        $lines = @(
            '[pad-sync] 开始',
            'PAD_SYNC_RESULT={"ok":true,"stage":"done"}',
            'PAD_SYNC_RESULT={"ok":false,"stage":"run"}'
        )
        (Read-SyncResult $lines).stage | Should Be 'run'
        (Read-SyncResult @('nothing here')) | Should Be $null
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

    It '告警日志追加写入，不覆盖上一条' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Write-RunAlert -FlowName 'F' -ExitCode 1 -Stage 'run' -Dir $dir | Out-Null
        Write-RunAlert -FlowName 'F' -ExitCode 2 -Stage 'acceptance' -Dir $dir | Out-Null
        $lines = @([IO.File]::ReadAllLines((Join-Path $dir 'alerts.jsonl'), [Text.Encoding]::UTF8) |
            Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        ($lines[1] | ConvertFrom-Json).stage | Should Be 'acceptance'
    }
}
