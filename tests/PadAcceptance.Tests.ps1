# PadAcceptance.Tests.ps1 — V 模型验收判据模块（Pester 3.4）
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\tools\pad-sync\PadAcceptance.psm1') -Force

function New-CaseDir {
    $d = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Spec([string]$dir, $checks) {
    $p = Join-Path $dir 'acceptance.json'
    Write-Utf8NoBom $p (ConvertTo-Json @{ checks = @($checks) } -Depth 8)
    return $p
}

Describe 'PadAcceptance' {

    It 'fileExists 通过 minBytes 与正则校验' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'budat.txt') "01.10.2026`n"
        $spec = New-Spec $d @(@{
            name = 'budat'; type = 'fileExists'; path = '{{ROOT}}\budat.txt'
            minBytes = 10; match = '^\d{2}\.\d{2}\.\d{4}'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $true
        $r.checks[0].ok | Should Be $true
    }

    It 'fileExists 内容不匹配时失败' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'date_filter.txt') 'not-a-date'
        $spec = New-Spec $d @(@{
            name = 'date'; type = 'fileExists'; path = '{{ROOT}}\date_filter.txt'
            match = '^\d{8}$'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $false
        $r.checks[0].detail | Should Match '不匹配'
    }

    It '可选项缺失时记 skipped 且整体通过' {
        $d = New-CaseDir
        $spec = New-Spec $d @(@{
            name = 'optional'; type = 'fileExists'; path = '{{ROOT}}\nope.txt'; optional = $true
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $true
        $r.skipped | Should Be 1
        $r.checks[0].skipped | Should Be $true
    }

    It 'globNewerThan 识别本次运行生成的文件' {
        $d = New-CaseDir
        $exportDir = Join-Path $d 'MB51'
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
        Write-Utf8NoBom (Join-Path $exportDir 'EXPORT_1.XLSX') 'x'
        $spec = New-Spec $d @(@{
            name = 'export'; type = 'globNewerThan'; dir = '{{ROOT}}\MB51'; pattern = 'EXPORT_*.XLSX'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d } -Since (Get-Date).AddMinutes(-1)
        $r.ok | Should Be $true
    }

    It 'globNewerThan 只有旧文件且可选时跳过，必选时失败' {
        $d = New-CaseDir
        $exportDir = Join-Path $d 'MB51'
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
        $old = Join-Path $exportDir 'EXPORT_1.XLSX'
        Write-Utf8NoBom $old 'x'
        (Get-Item $old).LastWriteTime = (Get-Date).AddHours(-3)

        $specOptional = New-Spec $d @(@{
            name = 'export'; type = 'globNewerThan'; dir = '{{ROOT}}\MB51'; pattern = 'EXPORT_*.XLSX'; optional = $true
        })
        $r1 = Test-AcceptanceFile -Path $specOptional -Config @{ ROOT = $d } -Since (Get-Date).AddMinutes(-1)
        $r1.ok | Should Be $true
        $r1.skipped | Should Be 1

        $specRequired = New-Spec $d @(@{
            name = 'export'; type = 'globNewerThan'; dir = '{{ROOT}}\MB51'; pattern = 'EXPORT_*.XLSX'
        })
        $r2 = Test-AcceptanceFile -Path $specRequired -Config @{ ROOT = $d } -Since (Get-Date).AddMinutes(-1)
        $r2.ok | Should Be $false
    }

    It 'pair 只存在一个文件时失败' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'a.txt') 'a'
        $spec = New-Spec $d @(@{
            name = 'pair'; type = 'pair'
            paths = @('{{ROOT}}\a.txt', '{{ROOT}}\b.txt')
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $false
        $r.checks[0].detail | Should Match '只存在 1/2'
    }

    It 'json 校验必需键' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'migo_plan.json') '{"hash":"abc","rows":{}}'
        $spec = New-Spec $d @(@{
            name = 'plan'; type = 'json'; path = '{{ROOT}}\migo_plan.json'
            requiredKeys = @('hash', 'rows')
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $true

        Write-Utf8NoBom (Join-Path $d 'migo_plan.json') '{"hash":"abc"}'
        $r2 = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r2.ok | Should Be $false
        $r2.checks[0].detail | Should Match 'rows'
    }

    It 'jsonl 遇到非法行时失败' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'ledger.jsonl') "{`"a`":1}`noops`n"
        $spec = New-Spec $d @(@{
            name = 'ledger'; type = 'jsonl'; path = '{{ROOT}}\ledger.jsonl'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $false
        $r.checks[0].detail | Should Match '第 2 行'
    }

    It '未知占位符不会被静默替换成空路径' {
        $d = New-CaseDir
        $spec = New-Spec $d @(@{
            name = 'unknown'; type = 'fileExists'; path = '{{MISSING}}\x.txt'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $false
        $r.checks[0].detail | Should Match '\{\{MISSING\}\}'
    }

    It 'logState：MIGO 日志末行为 MIGO_OK 时通过' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'migo_result.txt') "2026/10/28 10:00:00 MIGO_START 201 rows=1`r`n2026/10/28 10:01:00 MIGO_OK 201=1 501=0`r`n"
        $spec = New-Spec $d @(@{
            name = 'migo'; type = 'logState'; path = '{{ROOT}}\migo_result.txt'
            mode = 'lastLine'; pass = 'MIGO_OK'; fail = 'MIGO_FAILED'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $true
    }

    It 'logState：MIGO 日志末行为 MIGO_FAILED 时失败' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'migo_result.txt') "MIGO_START`r`nMIGO_FAILED 201 xxx`r`n"
        $spec = New-Spec $d @(@{
            name = 'migo'; type = 'logState'; path = '{{ROOT}}\migo_result.txt'
            mode = 'lastLine'; pass = 'MIGO_OK'; fail = 'MIGO_FAILED'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $false
        $r.checks[0].detail | Should Match 'MIGO_FAILED'
    }

    It 'logState：MB51 保存日志为 RUNNING 时跳过' {
        $d = New-CaseDir
        Write-Utf8NoBom (Join-Path $d 'saveas_result.txt') 'RUNNING'
        $spec = New-Spec $d @(@{
            name = 'saveas'; type = 'logState'; path = '{{ROOT}}\saveas_result.txt'
            mode = 'firstLine'; pass = '^OK'; fail = '^FAIL'; skip = '^RUNNING$'
        })
        $r = Test-AcceptanceFile -Path $spec -Config @{ ROOT = $d }
        $r.ok | Should Be $true
        $r.skipped | Should Be 1
    }
}
