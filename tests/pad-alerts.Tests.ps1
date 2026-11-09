# pad-alerts.Tests.ps1 — tests for the failure alert module (Pester 3.4, bundled with PowerShell 5.1)
#
# Every test creates its alert directory under TestDrive: it never writes the real business\logs, sends no external message and starts no PAD.
# Covers: a failure writes exactly one complete record / same runId + same kind dedupe / success writes nothing / release failures carry an explicit kind.

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

Describe 'PadAlerts failure alerts' {

    It 'failure branch writes one record with all fields and a next-step note' {
        $dir = New-AlertDir
        # Simulate a trigger failure: the flow name cannot be resolved into a flowId
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
        $rec.note | Should Match 'Next step'
    }

    It 'repeated calls with the same runId and kind write only one record' {
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

    It 'success writes nothing: skipped on exit 0 without failure markers' {
        $dir = New-AlertDir
        $r = Write-RunAlert -FlowName '示例流程' -ExitCode 0 -Stage 'done' -Status 'Succeeded' `
            -SyncResult ([ordered]@{ runId = 'run-003' }) -Dir $dir -RunId 'run-003'
        $r.skipped | Should Be $true
        (Test-Path (Join-Path $dir 'alerts.jsonl')) | Should Be $false
    }

    It 'release failures use an explicit kind instead of a loose string' {
        $dir = New-AlertDir
        $ak = Get-AlertKindConstants
        $r = Write-RunAlert -FlowName '示例流程' -ExitCode 1 -Stage 'inject' -Status 'Failed' `
            -Kind $ak.DeployInjectFailed -Dir $dir
        $r.skipped | Should Be $false
        @(Read-Alerts $dir)[0].kind | Should Be 'deploy-inject-failed'
        @(Read-Alerts $dir)[0].note | Should Match 'Next step'
    }

    It 'without a runId, dedupe by flow + kind + stage + day' {
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
