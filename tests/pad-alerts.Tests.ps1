# pad-alerts.Tests.ps1 — 失败告警模块测试（Pester 3.4，PS 5.1 自带）
#
# 全部在 TestDrive 里造告警目录，不写真实 business\logs、不发任何外部消息、不启动 PAD。
# 覆盖：失败写一条且字段齐全 / 同 runId 同 kind 去重 / 成功不写 / 发布类显式 kind。

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadAlerts.psm1'
Import-Module $script:Module -Force

function New-AlertDir {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

function Read-Alerts([string]$Dir) {
    $p = Join-Path $Dir 'alerts.jsonl'
    if (-not (Test-Path $p)) { return @() }
    return @([IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } |
        ForEach-Object { $_ | ConvertFrom-Json })
}

Describe 'PadAlerts 失败告警' {

    It '失败分支写一条，字段齐全且文案带下一步' {
        $dir = New-AlertDir
        # 模拟触发失败：流程名解析不出 flowId
        $sync = [ordered]@{ triggerFailed = $true; triggerReason = 'identity-mismatch'; runId = 'run-001' }
        $r = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'trigger' -Status 'TriggerFailed' `
            -SyncResult $sync -LogPath 'C:\logs\run-001\Actions.log' -Dir $dir -RunId 'run-001'
        $r.skipped | Should Be $false
        $list = Read-Alerts $dir
        @($list).Count | Should Be 1
        $rec = @($list)[0]
        $rec.kind | Should Be 'trigger-failed'
        $rec.reason | Should Be 'identity-mismatch'
        $rec.flow | Should Be '示例流程'
        $rec.runId | Should Be 'run-001'
        $rec.exitCode | Should Be 1
        $rec.stage | Should Be 'trigger'
        $rec.status | Should Be 'TriggerFailed'
        $rec.logPath | Should Match 'Actions\.log'
        $rec.ts | Should Not BeNullOrEmpty
        $rec.note | Should Match '下一步'
    }

    It '同一 runId + 同一 kind 重复调用只写一条' {
        $dir = New-AlertDir
        $sync = [ordered]@{ runTimeout = $true; runId = 'run-002' }
        $null = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'run' -Status 'RunTimeout' `
            -SyncResult $sync -Dir $dir -RunId 'run-002'
        $second = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'run' -Status 'RunTimeout' `
            -SyncResult $sync -Dir $dir -RunId 'run-002'
        $second.skipped | Should Be $true
        @(Read-Alerts $dir).Count | Should Be 1
        @(Read-Alerts $dir)[0].kind | Should Be 'run-timeout'
    }

    It '成功不写：exit 0 且无失败标记时直接跳过' {
        $dir = New-AlertDir
        $r = Write-RunAlert -FlowName '示例流程' -ExitCode 0 -Stage 'done' -Status 'Succeeded' `
            -SyncResult ([ordered]@{ runId = 'run-003' }) -Dir $dir -RunId 'run-003'
        $r.skipped | Should Be $true
        (Test-Path (Join-Path $dir 'alerts.jsonl')) | Should Be $false
    }

    It '发布类失败用显式 kind，不留散字符串' {
        $dir = New-AlertDir
        $ak = Get-AlertKindConstants
        $r = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'inject' -Status 'Failed' `
            -Kind $ak.DeployInjectFailed -Dir $dir
        $r.skipped | Should Be $false
        @(Read-Alerts $dir)[0].kind | Should Be 'deploy-inject-failed'
        @(Read-Alerts $dir)[0].note | Should Match '下一步'
    }

    It '没有 runId 时按 flow + kind + stage + 当天去重' {
        $dir = New-AlertDir
        $ak = Get-AlertKindConstants
        $null = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'publish' -Status 'Failed' `
            -Kind $ak.DeployPublishFailed -Dir $dir
        $second = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'publish' -Status 'Failed' `
            -Kind $ak.DeployPublishFailed -Dir $dir
        $second.skipped | Should Be $true
        @(Read-Alerts $dir).Count | Should Be 1
    }
}
