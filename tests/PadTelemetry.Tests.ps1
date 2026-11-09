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

Describe 'PadTelemetry telemetry parsing' {

    It 'Success sample: Succeeded / total duration / timed action durations / no error code' {
        $r = Get-RobinTelemetryFromFile (Join-Path $script:Fixtures 'robinrobot-success.log')
        $r.status | Should Be 'Succeeded'
        $r.totalMs | Should Be 9000
        @($r.timedActions).Count | Should Be 2
        @($r.failedActions).Count | Should Be 0
        $r.errorCode | Should Be $null
        $r.runId | Should Be 'aaaaaaaa-1111-2222-3333-444444444444'
    }

    It 'Failure sample: Failed / error code taken from padExceptionInfo / action-level exceptions are collected' {
        $r = Get-RobinTelemetryFromFile (Join-Path $script:Fixtures 'robinrobot-failure.log')
        $r.status | Should Be 'Failed'
        $r.errorCode | Should Be 'SAP.ElementNotFound'
        $r.error.type | Should Be 'SapGuiScripting'
        @($r.failedActions).Count | Should Be 1
        @($r.failedActions)[0].module | Should Be 'SAP'
        # 没有成功事件时 totalMs 为空
        $r.totalMs | Should Be $null
    }

    It 'Blank lines and corrupted JSON are skipped; no events at all returns null' {
        $r = ConvertFrom-RobinTelemetryLines -Lines @('', '这不是 JSON', '{"x":1}', '{"event":""}')
        $r | Should Be $null
    }

    It 'Log location: filters by Since and picks the newest one' {
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

Describe 'Get-RobinTelemetryFromFile shared read (real file handles, no mocks)' {

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

    It 'Held by a FileShare.ReadWrite write handle: the completion event can still be parsed' {
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

    It 'Held exclusively with FileShare.None: returns $null without throwing' {
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

    It 'Normally readable: the result matches the previous behavior (regression)' {
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

Describe 'Read-ChildResult child process result parsing' {

    It 'Normal JSON: takes the last PAD_*_RESULT line and parses it' {
        $lines = @('[pad-sync] 开始运行', 'PAD_SYNC_RESULT={"ok":true,"status":"success","stage":"done"}')
        $r = Read-ChildResult -Name 'SYNC' -Lines $lines
        $r.ok | Should Be $true
        $r.status | Should Be 'success'
        $r.stage | Should Be 'done'
    }

    It 'When the last line is a log line rather than a result: the earlier result line is still used; no result line at all returns $null' {
        $lines = @('PAD_SYNC_RESULT={"ok":true,"status":"success"}', '[pad-sync] 收尾日志')
        (Read-ChildResult -Name 'SYNC' -Lines $lines -Logger { param($m) }).ok | Should Be $true
        (Read-ChildResult -Name 'SYNC' -Lines @('只有日志，没有结果') -Logger { param($m) }) | Should Be $null
    }

    It 'Corrupted JSON: returns $null without throwing' {
        $threw = $false
        $r = $null
        try {
            $r = Read-ChildResult -Name 'DEPLOY' -Lines @('PAD_DEPLOY_RESULT={bad json') -Logger { param($m) }
        } catch { $threw = $true }
        $threw | Should Be $false
        $r | Should Be $null
    }
}

Describe 'Get-AdmitGateDecision admission fail-closed' {

    It 'Missing script: denied, reason=script-missing' {
        $d = Get-AdmitGateDecision -ExitCode 0 -Output '' -ScriptPath (Join-Path $TestDrive 'nope.ps1')
        $d.allow | Should Be $false
        $d.reason | Should Be 'script-missing'
    }

    It 'Non-zero exit: denied, reason=execution-failed' {
        $d = Get-AdmitGateDecision -ExitCode 2 -Output '[pad-admit] 待批准' -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'execution-failed'
    }

    It 'Empty or garbled output: denied, reason=unparsable' {
        $d = Get-AdmitGateDecision -ExitCode 0 -Output 'PAD_ADMIT_RESULT={坏掉的 JSON' -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'unparsable'
        (Get-AdmitGateDecision -ExitCode 0 -Output '' -ScriptPath $PSCommandPath).reason | Should Be 'unparsable'
    }

    It 'Normal pass (fail=0 / ask=0 / pass>0): allowed' {
        $json = '{"summary":{"pass":5,"warn":0,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $true
        $d.reason | Should Be 'passed'
    }

    It 'Warnings only: allowed (consistent with the existing semantics)' {
        $json = '{"summary":{"pass":3,"warn":2,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $true
    }

    It 'Any fail or ask present: denied' {
        $fail = '{"summary":{"pass":2,"warn":0,"ask":0,"fail":1}}'
        (Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$fail" -ScriptPath $PSCommandPath).reason | Should Be 'checks-failed'
        $ask = '{"summary":{"pass":2,"warn":0,"ask":1,"fail":0}}'
        (Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$ask" -ScriptPath $PSCommandPath).allow | Should Be $false
    }

    It 'No passing checks at all (pass=0): denied, reason=no-pass' {
        $json = '{"summary":{"pass":0,"warn":0,"ask":0,"fail":0}}'
        $d = Get-AdmitGateDecision -ExitCode 0 -Output "PAD_ADMIT_RESULT=$json" -ScriptPath $PSCommandPath
        $d.allow | Should Be $false
        $d.reason | Should Be 'no-pass'
    }
}

Describe 'Get-PadConsoleRunOutcome evidence lookup by runId' {

    It 'Console success event → Succeeded' {
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

    It 'Console exception event → Failed' {
        $work = New-Work
        $runId = 'bbbbbbbb-1111-2222-3333-444444444444'
        $log = Join-Path $work '2026-11-04-01-59-PadConsole.log'
        $line = '{"event":"console.executeflow.run.exception","runId":"' + $runId + '","message":"CommunicationObjectAborted"}'
        [IO.File]::WriteAllText($log, $line, (New-Object Text.UTF8Encoding($false)))
        (Get-PadConsoleRunOutcome -RunId $runId -DataCollectionDir $work).outcome | Should Be 'Failed'
    }

    It 'No events at all for that runId → Unknown (unknown is not failure)' {
        $work = New-Work
        $log = Join-Path $work '2026-11-04-02-00-PadConsole.log'
        [IO.File]::WriteAllText($log, '{"event":"flow.run.success","runId":"cccccccc-1111-2222-3333-444444444444"}',
            (New-Object Text.UTF8Encoding($false)))
        (Get-PadConsoleRunOutcome -RunId 'dddddddd-1111-2222-3333-444444444444' -DataCollectionDir $work).outcome | Should Be 'Unknown'
    }

    It 'Missing directory: returns $null' {
        (Get-PadConsoleRunOutcome -RunId 'eeeeeeee-1111-2222-3333-444444444444' `
            -DataCollectionDir (Join-Path $TestDrive 'nope')) | Should Be $null
    }
}

Describe 'Get-PadConsoleRunOutcome shared read (real file handles, no mocks)' {

    It 'Actions.log and PadConsole.log both held by write handles: the success event can still be read' {
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

    It 'A completely unreadable log: Unknown plus a readable warning, and no exception thrown' {
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

    It 'An explicit failure event (also under a write handle) is still judged Failed' {
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

Describe 'New-RunManifestEntry does not misreport an unknown result as failure' {

    Import-Module (Join-Path $PSScriptRoot '..\tools\pad-sync\PublishHistory.psm1') -Force

    It 'ok=$null (unknown): the manifest stays null and is not written as false' {
        $e = New-RunManifestEntry -FlowName 'F' -RunId 'r1' -Mode 'run-only' `
            -Ok $null -Stage 'done' -Status 'Unknown'
        $e.ok | Should Be $null
        $e.status | Should Be 'Unknown'
    }

    It 'ok=$true / $false keep their boolean semantics' {
        (New-RunManifestEntry -FlowName 'F' -RunId 'r2' -Mode 'run-only' -Ok $true -Stage 'done' -Status 'Succeeded').ok |
            Should Be $true
        (New-RunManifestEntry -FlowName 'F' -RunId 'r3' -Mode 'run-only' -Ok $false -Stage 'done' -Status 'Failed').ok |
            Should Be $false
    }
}
