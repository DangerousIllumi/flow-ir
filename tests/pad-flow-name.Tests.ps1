# pad-flow-name.Tests.ps1 — derivation of the optional top-level field pad_flow_name and tests for "accepted but ignored" (Pester 3.4)
#
# Covers three things:
#   1) Derive flow.json from the PAD display name: pad_flow_name first, then the file name / name
#   2) Multiple hits must report ADMIT_AMBIGUOUS_FLOW and must not fall back to "take the first"
#   3) The generator / check.js / eval-flow.js accept the field but do not consume it (no unknown-field error, nothing written into .robin)

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'tools\pad-sync\pad-admit.ps1') -NoMain

# Build a minimal flow definition: it only counts as a candidate when nodes is non-empty
function New-FlowFile([string]$Dir, [string]$FileName, [string]$InnerName, [string]$DisplayName) {
    $obj = [ordered]@{ name = $InnerName; nodes = @([ordered]@{ id = 'n1'; pad_hint = 'SET' }) }
    if ($DisplayName) { $obj.Add('pad_flow_name', $DisplayName) }
    $path = Join-Path $Dir $FileName
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    return $path
}

Describe 'pad_flow_name resolution order' {
    It 'unique match by pad_flow_name' {
        $dir = Join-Path $TestDrive 'by-display'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'source.json' '内部名' '显示名-XYZ'
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Be $f
    }

    It 'pad_flow_name wins over a conflicting file name' {
        $dir = Join-Path $TestDrive 'conflict'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $byFile = New-FlowFile $dir '显示名-XYZ.json' '另一个流程' $null
        $byDisplay = New-FlowFile $dir 'source.json' '内部名' '显示名-XYZ'
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Be $byDisplay
        (Resolve-FlowFileByName $dir '显示名-XYZ') | Should Not Be $byFile
    }

    It 'falls back to the file name when pad_flow_name is absent' {
        $dir = Join-Path $TestDrive 'by-file'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'plain-flow.json' '内部名' $null
        (Resolve-FlowFileByName $dir 'plain-flow') | Should Be $f
    }

    It 'falls back to the top-level name when pad_flow_name is absent' {
        $dir = Join-Path $TestDrive 'by-name'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-FlowFile $dir 'other.json' '内部名-XYZ' $null
        (Resolve-FlowFileByName $dir '内部名-XYZ') | Should Be $f
    }

    It 'two files declare the same pad_flow_name: ADMIT_AMBIGUOUS_FLOW' {
        $dir = Join-Path $TestDrive 'ambiguous'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [void](New-FlowFile $dir 'a.json' 'A' '同名-XYZ')
        [void](New-FlowFile $dir 'b.json' 'B' '同名-XYZ')
        $err = $null
        try { Resolve-FlowFileByName $dir '同名-XYZ' } catch { $err = $_.Exception.Message }
        $err | Should Match 'ADMIT_AMBIGUOUS_FLOW'
        # It must not silently return the first one
        $err | Should Match 'a\.json, b\.json'
    }
}

Describe 'pad_flow_name is accepted but not consumed by the generation chain' {
    It 'the generator and check.js accept the field without writing it into .robin' {
        # Progress goes to stdout now; keep EAP relaxed so genuine node stderr warnings are not terminating errors
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

    It 'eval-flow.js can assert the field without raising an unknown-field error' {
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
