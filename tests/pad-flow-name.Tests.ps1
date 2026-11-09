# pad-flow-name.Tests.ps1 — 顶层可选字段 pad_flow_name 的派生与“接受但忽略”测试（Pester 3.4）
#
# 覆盖三件事：
#   1) 按 PAD 显示名派生 flow.json：优先 pad_flow_name，其次文件名 / name
#   2) 多命中必须报 ADMIT_AMBIGUOUS_FLOW，不能退回“取第一个”
#   3) 生成器 / check.js / eval-flow.js 接受该字段但不消费（不报未知字段，不进 .robin）

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\pad-sync\pad-admit.ps1') -NoMain

# 造一个最小流程定义：有非空 nodes 才算候选
function New-FlowFile([string]$Dir, [string]$FileName, [string]$InnerName, [string]$DisplayName) {
    $obj = [ordered]@{ name = $InnerName; nodes = @([ordered]@{ id = 'n1'; pad_hint = 'SET' }) }
    if ($DisplayName) { $obj.Add('pad_flow_name', $DisplayName) }
    $path = Join-Path $Dir $FileName
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    return $path
}

Describe 'pad_flow_name 派生顺序' {
    It '按 pad_flow_name 唯一命中' {
        $dir = Join-Path $TestDrive 'by-display'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'source.json' '内部名' '显示名-XYZ'
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Be $f
    }

    It '与文件名冲突时以 pad_flow_name 为准' {
        $dir = Join-Path $TestDrive 'conflict'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $byFile = New-FlowFile $dir '显示名-XYZ.json' '另一个流程' $null
        $byDisplay = New-FlowFile $dir 'source.json' '内部名' '显示名-XYZ'
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Be $byDisplay
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Not Be $byFile
    }

    It '无 pad_flow_name 时回落到文件名' {
        $dir = Join-Path $TestDrive 'by-file'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'plain-flow.json' '内部名' $null
        (Resolve-FlowFileByName $dir 'plain-flow') | Should Be $f
    }

    It '无 pad_flow_name 时回落到顶层 name' {
        $dir = Join-Path $TestDrive 'by-name'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'other.json' '内部名-XYZ' $null
        (Resolve-FlowFileByName $dir '内部名-XYZ') | Should Be $f
    }

    It '两个文件声明同名 pad_flow_name：报 ADMIT_AMBIGUOUS_FLOW' {
        $dir = Join-Path $TestDrive 'ambiguous'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [void](New-FlowFile $dir 'a.json' 'A' '同名-XYZ')
        [void](New-FlowFile $dir 'b.json' 'B' '同名-XYZ')
        $err = $null
        try { Resolve-FlowFileByName $dir '同名-XYZ' } catch { $err = $_.Exception.Message }
        $err | Should Match 'ADMIT_AMBIGUOUS_FLOW'
        # 不能静默返回第一个
        $err | Should Match 'a\.json、b\.json'
    }
}

Describe 'pad_flow_name 对生成链路只接受不消费' {
    It '生成器与 check.js 接受该字段且不写进 .robin' {
        # pad-admit 被 dot-source 时设了 ErrorAction Stop，node 的 stderr 会被当成终止错误
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $src = Join-Path $repo 'tools\flow-drawio\example-flow.json'
            $obj = [ordered]@{}
            $orig = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($p in $orig.PSObject.Properties) { $obj[$p.Name] = $p.Value }
            $obj['pad_flow_name'] = '示例显示名-XYZ'
            $flowPath = Join-Path $TestDrive 'with-display.json'
            [IO.File]::WriteAllText($flowPath, ($obj | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            $robin = Join-Path $TestDrive 'with-display.robin'

            & node (Join-Path $repo 'tools\pad-robin\flow-to-robin.js') $flowPath $robin 2>$null | Out-Null
            $genExit = $LASTEXITCODE
            & node (Join-Path $repo 'tools\pad-robin\check.js') $robin 2>$null | Out-Null
            $chkExit = $LASTEXITCODE
            $genExit | Should Be 0
            $chkExit | Should Be 0
            $text = [IO.File]::ReadAllText($robin, [Text.Encoding]::UTF8)
            $text | Should Not Match 'pad_flow_name'
            $text | Should Not Match '示例显示名-XYZ'
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    It 'eval-flow.js 可以断言该字段，且不会因未知字段报错' {
        $flowPath = Join-Path $repo 'tools\flow-drawio\example-flow.json'
        $obj = [ordered]@{}
        $orig = [IO.File]::ReadAllText($flowPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $orig.PSObject.Properties) { $obj[$p.Name] = $p.Value }
        $obj['pad_flow_name'] = '示例显示名-XYZ'
        $flowPath2 = Join-Path $TestDrive 'eval-target.json'
        [IO.File]::WriteAllText($flowPath2, ($obj | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
        $casePath = Join-Path $TestDrive 'display.cases.json'
        $case = @{
            flow = $flowPath2
            cases = @(@{
                id = 'display-name-accepted'
                requirement = '顶层 pad_flow_name 被接受且可断言'
                expect = @(@{ op = 'field'; name = 'pad_flow_name'; equals = '示例显示名-XYZ' })
            })
        }
        [IO.File]::WriteAllText($casePath, ($case | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
        & node (Join-Path $repo 'tools\pad-robin\eval-flow.js') $casePath 2>&1 | Out-Null
        $LASTEXITCODE | Should Be 0
    }
}
