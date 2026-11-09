# PadTelemetry.Tests.ps1 — 遥测解析固定样本测试（Pester 3.4，PS 5.1 自带）
#
# 样本是合成的 RobinRobot.log（JSON Lines），只保留解析器关心的字段：
#   tests\fixtures\telemetry\robinrobot-success.log / robinrobot-failure.log
# 不提交任何真实运行日志，避免把生产数据带进仓库。

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadTelemetry.psm1'
Import-Module $script:Module -Force
$script:Fixtures = Join-Path $PSScriptRoot 'fixtures\telemetry'

function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

Describe 'PadTelemetry 遥测解析' {

    It '成功样本：Succeeded / 总耗时 / 模块动作耗时 / 无错误码' {
        $r = Get-RobinTelemetryFromFile (Join-Path $script:Fixtures 'robinrobot-success.log')
        $r.status | Should Be 'Succeeded'
        $r.totalMs | Should Be 9000
        @($r.timedActions).Count | Should Be 2
        @($r.failedActions).Count | Should Be 0
        $r.errorCode | Should Be $null
        $r.runId | Should Be 'aaaaaaaa-1111-2222-3333-444444444444'
    }

    It '失败样本：Failed / 错误码取自 padExceptionInfo / 动作级异常被收集' {
        $r = Get-RobinTelemetryFromFile (Join-Path $script:Fixtures 'robinrobot-failure.log')
        $r.status | Should Be 'Failed'
        $r.errorCode | Should Be 'SAP.ElementNotFound'
        $r.error.type | Should Be 'SapGuiScripting'
        @($r.failedActions).Count | Should Be 1
        @($r.failedActions)[0].module | Should Be 'SAP'
        # 没有成功事件时 totalMs 为空
        $r.totalMs | Should Be $null
    }

    It '空行与损坏 JSON 被跳过；没有任何事件时返回 null' {
        $r = ConvertFrom-RobinTelemetryLines -Lines @('', '这不是 JSON', '{"x":1}', '{"event":""}')
        $r | Should Be $null
    }

    It '日志定位：按 Since 过滤并取最新一份' {
        $work = New-Work
        $old = Join-Path $work '20260101T000000-RobinRobot.log'
        $new = Join-Path $work '20260102T000000-RobinRobot.log'
        New-Item -ItemType File -Path $old -Force | Out-Null
        New-Item -ItemType File -Path $new -Force | Out-Null
        (Get-Item $old).LastWriteTime = [datetime]'2026-01-01 08:00:00'
        (Get-Item $new).LastWriteTime = [datetime]'2026-01-02 08:00:00'

        (Find-RobinTelemetryLog $work ([datetime]'2026-01-01 00:00:00')).Name | Should Be $new.Split('\')[-1]
        (Find-RobinTelemetryLog $work ([datetime]'2026-01-02 00:00:00')).Name | Should Be $new.Split('\')[-1]
        # 目录不存在时返回 null
        (Find-RobinTelemetryLog (Join-Path $work 'nope') ([datetime]'2026-01-01')) | Should Be $null
    }
}

Describe 'Get-RobinTelemetryFromFile 共享读（真实文件句柄，不 mock）' {

    # 写一份只含“开始 + 成功”两类 run 级事件的 RobinRobot.log
    function Write-RobotLog {
        param([string]$Dir, [string]$RunId)
        $p = Join-Path $Dir '2026-11-04-03-47-RobinRobot.log'
        $lines = @(
            ('{"event":"robin.execution.start","durationInMilliseconds":0,"eventData":{"padFlowInfo":{"runId":"' + $RunId + '"}}}'),
            ('{"event":"robin.execution.success","durationInMilliseconds":9000,"eventData":{"padFlowInfo":{"runId":"' + $RunId + '"}}}')
        )
        [IO.File]::WriteAllText($p, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        return $p
    }

    It '被 FileShare.ReadWrite 写句柄占用：仍能解析出完成事件' {
        $work = New-Work
        $runId = 'ffffffff-1111-2222-3333-444444444444'
        $log = Write-RobotLog -Dir $work -RunId $runId
        # 模拟机器人进程：持有读写句柄且允许共享读写。
        # 旧实现（ReadAllLines 只请求 FileShare.Read）会抛 IOException，这里应正常读出
        $h = New-Object IO.FileStream($log, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            $r = Get-RobinTelemetryFromFile $log
            $r.status | Should Be 'Succeeded'
            $r.runId | Should Be $runId
            $r.totalMs | Should Be 9000
        } finally { $h.Dispose() }
    }

    It '被 FileShare.None 独占：返回 $null 且不抛异常' {
        $work = New-Work
        $runId = 'abababab-1111-2222-3333-444444444444'
        $log = Write-RobotLog -Dir $work -RunId $runId
        $h = New-Object IO.FileStream($log, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $threw = $false
            $r = $null
            try { $r = Get-RobinTelemetryFromFile $log } catch { $threw = $true }
            $threw | Should Be $false
            # 读不到按未知处理：返回 $null，由调用方判定，绝不写成失败
            $r | Should Be $null
        } finally { $h.Dispose() }
    }

    It '正常可读：结果与改前一致（回归）' {
        $work = New-Work
        $runId = 'cdcdcdcd-1111-2222-3333-444444444444'
        $log = Write-RobotLog -Dir $work -RunId $runId
        $r = Get-RobinTelemetryFromFile $log
        $r.status | Should Be 'Succeeded'
        $r.runId | Should Be $runId
        $r.totalMs | Should Be 9000
        $r.logPath | Should Be $log
        @($r.timedActions).Count | Should Be 0
        @($r.failedActions).Count | Should Be 0
    }
}

Describe 'Read-ChildResult 子进程结果解析' {

    It '正常 JSON：取最后一条 PAD_*_RESULT 行并解析' {
        $lines = @('[pad-sync] 开始运行', 'PAD_SYNC_RESULT={"ok":true,"status":"success","stage":"done"}')
        $r = Read-ChildResult -Name 'SYNC' -Lines $lines
        $r.ok | Should Be $true
        $r.status | Should Be 'success'
        $r.stage | Should Be 'done'
    }

    It '末行是日志不是结果：仍取前面的结果行；完全没有结果行返回 $null' {
        $lines = @('PAD_SYNC_RESULT={"ok":true,"status":"success"}', '[pad-sync] 收尾日志')
        (Read-ChildResult -Name 'SYNC' -Lines $lines -Logger { param($m) }).ok | Should Be $true
        (Read-ChildResult -Name 'SYNC' -Lines @('只有日志，没有结果') -Logger { param($m) }) | Should Be $null
    }

    It 'JSON 损坏：返回 $null 且不抛异常' {
        $threw = $false
        $r = $null
        try {
            $r = Read-ChildResult -Name 'DEPLOY' -Lines @('PAD_DEPLOY_RESULT={bad json') -Logger { param($m) }
        } catch { $threw = $true }
        $threw | Should Be $false
        $r | Should Be $null
    }
}

Describe 'Get-AdmitGateDecision 准入 fail-closed' {

    It '脚本缺失：拒绝，reason=script-missing' {
        $d = Get-AdmitGateDecision -ExitCode 0 -Output '' -ScriptPath (Join-Path $TestDrive 'nope.ps1')
        $d.allow | Should Be $false
        $d.reason | Should Be 'script-missing'
    }

    It '非零退出：拒绝，reason=execution-failed' {
        $d = Get-AdmitGateDecision -ExitCode 2 -Output '[pad-admit] 待批准' -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'execution-failed'
    }

    It '空输出 / 乱码：拒绝，reason=unparsable' {
        $d = Get-AdmitGateDecision -ExitCode 0 -Output 'PAD_ADMIT_RESULT={坏掉的 JSON' -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'unparsable'
        (Get-AdmitGateDecision -ExitCode 0 -Output '' -ScriptPath $PSCommandPath).reason | Should Be 'unparsable'
    }

    It '正常通过（fail=0 / ask=0 / pass>0）：放行' {
        $json = '{"summary":{"pass":5,"warn":0,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $true
        $d.reason | Should Be 'passed'
    }

    It '仅 warn：放行（与既有语义一致）' {
        $json = '{"summary":{"pass":3,"warn":2,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $true
    }

    It '存在 fail 或 ask：拒绝' {
        $fail = '{"summary":{"pass":2,"warn":0,"ask":0,"fail":1}}'
        (Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$fail" -ScriptPath $PSCommandPath).reason | Should Be 'checks-failed'
        $ask = '{"summary":{"pass":2,"warn":0,"ask":1,"fail":0}}'
        (Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$ask" -ScriptPath $PSCommandPath).allow | Should Be $false
    }

    It '没有任何通过项（pass=0）：拒绝，reason=no-pass' {
        $json = '{"summary":{"pass":0,"warn":0,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'no-pass'
    }
}

Describe 'Get-PadConsoleRunOutcome 按 runId 取证' {

    It 'Console 成功事件 → Succeeded' {
        $work = New-Work
        $runId = 'aaaaaaaa-1111-2222-3333-444444444444'
        $lines = @(
            ('{"event":"flowrunner.start.success","runId":"' + $runId + '","message":"Reason: Successful"}'),
            ('{"event":"agent.service.runcompleted","runId":"' + $runId + '","message":"Run result: Success"}'),
            ('{"event":"rpcprovider.hostprocess.exit","runId":"' + $runId + '","message":"{\"ExitCode\":0,\"Exceptions\":[]}"}')
        )
        $log = Join-Path $work '2026-11-04-01-50-PadConsole.log'
        [IO.File]::WriteAllText($log, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
        $r = Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work
        $r.outcome | Should Be 'Succeeded'
        $r.logPath | Should Be $log
    }

    It 'Console 异常事件 → Failed' {
        $work = New-Work
        $runId = 'bbbbbbbb-1111-2222-3333-444444444444'
        $log = Join-Path $work '2026-11-04-01-59-PadConsole.log'
        $line = '{"event":"console.executeflow.run.exception","runId":"' + $runId + '","message":"CommunicationObjectAborted"}'
        [IO.File]::WriteAllText($log, $line, (New-Object Text.UTF8Encoding($false)))
        (Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work).outcome | Should Be 'Failed'
    }

    It '没有该 runId 的任何事件 → Unknown（未知不等于失败）' {
        $work = New-Work
        $log = Join-Path $work '2026-11-04-02-00-PadConsole.log'
        [IO.File]::WriteAllText($log, '{"event":"flow.run.success","runId":"cccccccc-1111-2222-3333-444444444444"}',
            (New-Object Text.UTF8Encoding($false)))
        (Get-PadConsoleRunOutcome -RunId 'dddddddd-1111-2222-3333-444444444444' -DataCollectionDir $work).outcome | Should Be 'Unknown'
    }

    It '目录不存在：返回 $null' {
        (Get-PadConsoleRunOutcome -RunId 'eeeeeeee-1111-2222-3333-444444444444' `
            -DataCollectionDir (Join-Path $TestDrive 'nope')) | Should Be $null
    }
}

Describe 'Get-PadConsoleRunOutcome 共享读（真实文件句柄，不 mock）' {

    It 'Actions.log 与 PadConsole.log 同时被写句柄占用：仍能读到成功事件' {
        $work = New-Work
        $runId = 'ffffffff-1111-2222-3333-444444444444'
        $act = Join-Path $work 'Actions.log'
        [IO.File]::WriteAllText($act, '{}', (New-Object Text.UTF8Encoding($false)))
        $log = Join-Path $work '2026-11-04-03-47-PadConsole.log'
        [IO.File]::WriteAllText($log, ('{"event":"flow.run.success","runId":"' + $runId + '"}'),
            (New-Object Text.UTF8Encoding($false)))
        # 模拟 PAD：持有读写句柄且允许共享读写。
        # 这正是旧实现（ReadAllLines 只请求 FileShare.Read）会撞车、共享读不会的场景
        $holders = @()
        try {
            foreach ($p in @($act, $log)) {
                $holders += (New-Object IO.FileStream($p, [IO.FileMode]::Open,
                    [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite))
            }
            $r = Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work
            $r.outcome | Should Be 'Succeeded'
            $r.unreadable | Should Be $false
        } finally {
            foreach ($h in $holders) { $h.Dispose() }
        }
    }

    It '日志完全读不到：Unknown + 可读 warning，且不抛异常' {
        $work = New-Work
        $runId = 'abababab-1111-2222-3333-444444444444'
        $log = Join-Path $work '2026-11-04-03-47-PadConsole.log'
        [IO.File]::WriteAllText($log, ('{"event":"flow.run.success","runId":"' + $runId + '"}'),
            (New-Object Text.UTF8Encoding($false)))
        # 独占句柄（FileShare.None）：任何读都进不来，只能按 Unknown 收尾
        $h = New-Object IO.FileStream($log, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $r = Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work
            $r.outcome | Should Be 'Unknown'
            $r.unreadable | Should Be $true
            $r.note | Should Match 'Console log is not readable'
        } finally {
            $h.Dispose()
        }
    }

    It '明确失败事件（同样在写句柄下）：仍判 Failed' {
        $work = New-Work
        $runId = 'cdcdcdcd-1111-2222-3333-444444444444'
        $log = Join-Path $work '2026-11-04-03-48-PadConsole.log'
        [IO.File]::WriteAllText($log,
            ('{"event":"console.executeflow.run.exception","runId":"' + $runId + '"}'),
            (New-Object Text.UTF8Encoding($false)))
        $h = New-Object IO.FileStream($log, [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        try {
            (Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work).outcome | Should Be 'Failed'
        } finally {
            $h.Dispose()
        }
    }
}

Describe 'New-RunManifestEntry 结果未知不误报失败' {

    Import-Module (Join-Path $PSScriptRoot '..\tools\pad-sync\PublishHistory.psm1') -Force

    It 'ok=$null（未知）：manifest 保持 null，不写成 false' {
        $e = New-RunManifestEntry -FlowName 'F' -RunId 'r1' -Mode 'run-only' `
            -Ok $null -Stage 'done' -Status 'Unknown'
        $e.ok | Should Be $null
        $e.status | Should Be 'Unknown'
    }

    It 'ok=$true / $false 保持布尔语义' {
        (New-RunManifestEntry -FlowName 'F' -RunId 'r2' -Mode 'run-only' -Ok $true -Stage 'done' -Status 'Succeeded').ok |
            Should Be $true
        (New-RunManifestEntry -FlowName 'F' -RunId 'r3' -Mode 'run-only' -Ok $false -Stage 'done' -Status 'Failed').ok |
            Should Be $false
    }
}
