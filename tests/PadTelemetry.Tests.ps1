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
