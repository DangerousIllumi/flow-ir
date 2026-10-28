# PadDesigner.Tests.ps1 — 设计器模块（Pester 3.4，PS 5.1 自带）
#
# 设计器交互本身需要真实窗口，无法在 CI/单测里跑；这里覆盖可离线验证的部分：
#   1) 模块可导入且导出编排层依赖的函数
#   2) 窗口越界判定（修复位置逻辑的纯函数部分）
#   3) 画布回读比对（-VerifyCanvas 的核心）：完全一致 / 只粘进去一部分
#   4) pad-sync 已退化为薄封装：不再自带 Win32 声明与 UI 函数

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadDesigner.psm1'
Import-Module $script:Module -Force

Describe 'PadDesigner 模块抽取与画布比对' {

    It '模块可导入，编排层依赖的函数都已导出' {
        $names = (Get-Command -Module 'PadDesigner').Name
        foreach ($n in @('Get-DesignerWindow', 'Invoke-PadInject', 'Invoke-PadRun',
                         'Get-CanvasText', 'Test-CanvasMatch', 'Test-WindowOutside',
                         'Get-StatusBarText', 'Wait-PublishDone')) {
            ($names -contains $n) | Should Be $true
        }
    }

    It '窗口越界判定：屏内不算越界，右侧出界与最小化算越界' {
        (Test-WindowOutside -Left 0 -Top 0 -Right 1200 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $false
        # 实测出现过的越界窗口：L=878 R=2078，超出 1920 屏宽
        (Test-WindowOutside -Left 878 -Top 0 -Right 2078 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $true
        (Test-WindowOutside -Left -10 -Top 0 -Right 1000 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080) | Should Be $true
        (Test-WindowOutside -Left 0 -Top 0 -Right 1000 -Bottom 900 -ScreenWidth 1920 -ScreenHeight 1080 -Minimized) | Should Be $true
    }

    It '画布比对：注释 / @ 元数据 / 缩进 / 转义差异都视为一致' {
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

    It '画布比对：只粘进去一部分 → 不一致，且报第一处缺失行' {
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
        $cmp.lineB | Should Be '<缺失>'
    }

    It 'pad-sync 已退化为薄封装：不再自带 Win32 声明与 UI 实现' {
        $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\pad-sync\pad-sync.ps1'), [Text.Encoding]::UTF8)
        ($src -match 'DllImport') | Should Be $false
        ($src -match "PadDesigner\.psm1") | Should Be $true
        ($src -match "PadTelemetry\.psm1") | Should Be $true
    }
}
