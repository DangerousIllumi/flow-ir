# PadDesigner.Tests.ps1 — 设计器模块（Pester 3.4，PS 5.1 自带）
#
# 设计器交互本身需要真实窗口，无法在 CI/单测里跑；这里覆盖可离线验证的部分：
#   1) 模块可导入且导出编排层依赖的函数
#   2) 窗口越界判定（修复位置逻辑的纯函数部分）
#   3) 画布回读比对（-VerifyCanvas 的核心）：完全一致 / 只粘进去一部分
#   4) pad-sync 已退化为薄封装：不再自带 Win32 声明与 UI 函数

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadDesigner.psm1'
Import-Module $script:Module -Force

Describe 'PadDesigner module extraction and canvas comparison' {

    It 'The module imports and every function the orchestration layer relies on is exported' {
        $names = (Get-Command -Module 'PadDesigner').Name
        foreach ($n in @('Get-DesignerWindow', 'Invoke-PadInject', 'Invoke-PadRun',
                         'Get-CanvasText', 'Test-CanvasMatch', 'Test-WindowOutside',
                         'Get-StatusBarText', 'Wait-PublishDone',
                         'Get-PadRunDirs', 'Get-RunLogStatus', 'Read-TextShared')) {
            ($names -contains $n) | Should Be $true
        }
    }

    It 'A log locked by PAD (read allowed, write denied) can still be read' {
        $f = Join-Path $TestDrive 'locked.log'
        [IO.File]::WriteAllText($f, '{"index":1}', (New-Object Text.UTF8Encoding($false)))
        # 模拟 PAD 运行期间持有的句柄：别人只能读，不能写
        $fs = [IO.File]::Open($f, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
        try {
            # 默认的 ReadAllLines（自己只授予 Read）在这种占用下会失败，正是线上报错的成因
            { [IO.File]::ReadAllLines($f) } | Should Throw
            (Read-TextShared $f) | Should Be '{"index":1}'
        } finally {
            $fs.Dispose()
        }
    }

    It 'Window off-screen detection: on-screen is inside, right overflow and minimized count as outside' {
        (Test-WindowOutside -Left 0 -Top 0 -Right 1200 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $false
        # 实测出现过的越界窗口：L=878 R=2078，超出 1920 屏宽
        (Test-WindowOutside -Left 878 -Top 0 -Right 2078 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $true
        (Test-WindowOutside -Left -10 -Top 0 -Right 1000 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $true
        (Test-WindowOutside -Left 0 -Top 0 -Right 1000 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080 -Minimized) | Should Be $true
    }

    It 'Canvas comparison: comment, @ metadata, indentation and escape differences all count as matching' {
        $src = @"
@@Type = 'PadFlow'
# 这是注释，画布回读时不会有
SET A TO 'C:\\PAD\\Results'
IF A > 0
    SET B TO 1
END
"@
        $canvas = @"
        SET A TO 'C:\\PAD\\Results'
        IF A > 0
        SET B TO 1
END
"@
        (Test-CanvasMatch -CanvasText $canvas -SourceText $src).match | Should Be $true
    }

    It 'Canvas comparison: partially pasted content is a mismatch and reports the first missing line' {
        $src = @"
SET A TO 1
SET B TO 2
SET C TO 3
File.WriteToFile File: F1
"@
        # 模拟粘贴被截断：后两行没进画布
        $canvas = @"
SET A TO 1
SET B TO 2
"@
        $cmp = Test-CanvasMatch -CanvasText $canvas -SourceText $src
        $cmp.match | Should Be $false
        $cmp.diffIndex | Should Be 3
        $cmp.lineA | Should Be 'SET C TO 3'
        $cmp.lineB | Should Be '<missing>'
    }

    It 'Run log verdict: per-action lines do not end the run, only the final summary line returns a terminal status' {
        # 逐动作行带 index；整次运行的汇总行没有 index（PAD 的 Actions.log 约定）
        $log = Join-Path $TestDrive 'Actions.log'
        @(
            '{"index":1,"name":"设置变量","status":"Succeeded"}',
            '{"index":2,"name":"等待","status":"Running"}'
        ) | Set-Content -LiteralPath $log -Encoding UTF8
        (Get-RunLogStatus -LogPath $log) | Should Be $null

        '{"workflow":"x","status":"Succeeded"}' | Add-Content -LiteralPath $log -Encoding UTF8
        (Get-RunLogStatus -LogPath $log) | Should Be 'Succeeded'
    }

    It 'Run log verdict: a missing or empty file returns null' {
        (Get-RunLogStatus -LogPath (Join-Path $TestDrive 'nope.log')) | Should Be $null
        $empty = Join-Path $TestDrive 'empty.log'
        Set-Content -LiteralPath $empty -Value '' -Encoding UTF8
        (Get-RunLogStatus -LogPath $empty) | Should Be $null
    }

    It 'Run directory listing: only directories under <flow>\Runs are collected' {
        $root = Join-Path $TestDrive 'Scripts'
        New-Item -ItemType Directory -Path (Join-Path $root 'flowA\Runs\run1') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'flowA\Runs\run2') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'flowB') -Force | Out-Null
        $dirs = @(Get-PadRunDirs -ScriptsRoot $root)
        $dirs.Count | Should Be 2
        (($dirs | ForEach-Object { $_.Name }) -join ',') | Should Be 'run1,run2'
    }

    It 'Run directory resolution honors this runId only: returns $null when not found and never falls back to the latest' {
        $root = Join-Path $TestDrive 'ResolveRun'
        $rid = 'c7483d18-9667-4ba8-b8ad-ec1dc5d1470b'
        New-Item -ItemType Directory -Path (Join-Path $root "flowA\Runs\$rid") -Force | Out-Null
        # 另一个流的目录更晚创建、且名字与本次 runId 前缀相似，必须不被误选
        Start-Sleep -Milliseconds 30
        New-Item -ItemType Directory -Path (Join-Path $root 'flowB\Runs\1f286090-d61e-488c-8e95-7751d4477b13') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root "flowB\Runs\$rid-x") -Force | Out-Null

        $hit = Resolve-PadRunDir -ScriptsRoot $root -RunId $rid
        $hit.Name | Should Be $rid
        $hit.FullName | Should Match 'flowA'

        # 只存在别人的 runId 时必须返回 $null；若退化成“取最新”，这里会拿到别人的目录而变红
        (Resolve-PadRunDir -ScriptsRoot $root -RunId 'ffffffff-0000-0000-0000-000000000000') | Should Be $null

        # pad-sync 不得再自带第二套目录搜索，必须走同一个函数
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ($src -match 'Resolve-PadRunDir') | Should Be $true
        ($src -match 'Get-ChildItem -LiteralPath \$base -Recurse') | Should Be $false
    }

    It 'pad-sync is now a thin wrapper: it no longer carries Win32 declarations or UI implementations' {
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ($src -match 'DllImport') | Should Be $false
        ($src -match "PadDesigner\.psm1") | Should Be $true
        ($src -match "PadTelemetry\.psm1") | Should Be $true
    }
}

Describe 'Auto-click narrowed: only the external-trigger confirmation dialog qualifies' {

    It 'Real confirmation dialog (Console.Host + Power Automate title + protocol button) is allowed to click' {
        (Test-ExternalTriggerDialog -ProcessName 'PAD.Console.Host' -WindowTitle 'Power Automate' `
            -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton' -ButtonControlType 'Button') | Should Be $true
    }

    It 'Business pop-ups (robot process / completion title) are never clicked, even when the button text is the Chinese "OK" label' {
        (Test-ExternalTriggerDialog -ProcessName 'PAD.RobotV2' -WindowTitle '通用报表·处理完成' `
            -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton' -ButtonControlType 'Button') | Should Be $false
        (Test-ExternalTriggerDialog -ProcessName 'PAD.RobotV2' -WindowTitle '通用报表' `
            -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton' -ButtonControlType 'Button') | Should Be $false
    }

    It 'Titles outside the allowlist (Designer windows carrying the flow name) are not clicked' {
        (Test-ExternalTriggerDialog -ProcessName 'PAD.Console.Host' -WindowTitle 'Power Automate | 通用报表' `
            -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton') | Should Be $false
    }

    It 'A mismatched button AutomationId is not clicked (the decision does not rely on button text)' {
        (Test-ExternalTriggerDialog -ProcessName 'PAD.Console.Host' -WindowTitle 'Power Automate' `
            -ButtonAutomationId 'SomeOtherButton') | Should Be $false
    }

    It 'The BM_CLICK blind spot is gone from the source: robot windows are no longer clicked by button text' {
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\PadDesigner.psm1'), [Text.Encoding]::UTF8)
        ($src -match '0x00F5') | Should Be $false
        ($src -match '\$txt -eq ''确定''') | Should Be $false
    }
}

Describe 'Pre-trigger validation: the flow name must resolve to a flowId' {

    It 'Resolves a unique flow and returns flowId / environmentId' {
        $root = Join-Path $TestDrive 'IdRoot'
        $flowId = 'a40506df-b67b-4523-8f37-bdc3977a3479'
        $runId = '9f8f96ae-8999-457d-ad77-ba02c66ecec5'
        $dir = Join-Path $root "$flowId\Runs\$runId"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $json = @{
            workflow = @{ name = 'PAD_SYNC_TEST'; workflowId = $flowId }
            environmentId = 'Default-ecaa386b-63b6-4dd7-a4b2-15a7900a4cf0'
            startTime = '2026-11-04T01:51:39.5Z'
            diagnosticInfo = @{ runId = $runId }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $dir 'RunDefinition.json'), $json, (New-Object Text.UTF8Encoding($false)))

        $id = Resolve-PadFlowIdentity -WorkflowName 'PAD_SYNC_TEST' -ScriptsRoot $root
        $id.FlowId | Should Be $flowId
        $id.EnvironmentId | Should Be 'Default-ecaa386b-63b6-4dd7-a4b2-15a7900a4cf0'
    }

    It 'Name mismatch returns $null (the caller uses this to refuse before triggering)' {
        $root = Join-Path $TestDrive 'IdRoot2'
        $flowId = 'a40506df-b67b-4523-8f37-bdc3977a3479'
        $runId = '9f8f96ae-8999-457d-ad77-ba02c66ecec5'
        $dir = Join-Path $root "$flowId\Runs\$runId"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $json = @{
            workflow = @{ name = 'PAD_SYNC_TEST'; workflowId = $flowId }
            startTime = '2026-11-04T01:51:39.5Z'
            diagnosticInfo = @{ runId = $runId }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $dir 'RunDefinition.json'), $json, (New-Object Text.UTF8Encoding($false)))

        (Resolve-PadFlowIdentity -WorkflowName '不存在的流程' -ScriptsRoot $root) | Should Be $null
    }

    It 'Missing flow directory returns $null (triggering is refused as well)' {
        $root = Join-Path $TestDrive 'IdRoot3'
        $flowId = 'a40506df-b67b-4523-8f37-bdc3977a3479'
        $runId = '9f8f96ae-8999-457d-ad77-ba02c66ecec5'
        $dir = Join-Path $root "$flowId\Runs\$runId"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $json = @{
            workflow = @{ name = 'PAD_SYNC_TEST'; workflowId = $flowId }
            startTime = '2026-11-04T01:51:39.5Z'
            diagnosticInfo = @{ runId = $runId }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $dir 'RunDefinition.json'), $json, (New-Object Text.UTF8Encoding($false)))
        # 再删掉流程目录，模拟“记录里存在但实际流程已删除”
        Remove-Item -LiteralPath (Join-Path $root $flowId) -Recurse -Force
        (Resolve-PadFlowIdentity -WorkflowName 'PAD_SYNC_TEST' -ScriptsRoot $root) | Should Be $null
    }
}
