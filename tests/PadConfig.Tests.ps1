# PadConfig.Tests.ps1 — unit tests for the centralized runtime configuration
#
# Assertions cover error codes and returned fields only; every path lives under the TestDrive temporary
# directory, so no real path or business name leaks into public-layer tests.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '..\tools\pad-sync\PadConfig.psm1') -Force

Describe 'PadConfig loading and validation' {
    BeforeEach {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($f in @('pad-sync.ps1', 'python.exe', 'calendar.xlsx', 'workday.py')) {
            Set-Content -LiteralPath (Join-Path $dir $f) -Value 'x' -Encoding UTF8
        }
        $root = Join-Path $dir 'root'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $script:cfg = [ordered]@{
            PadSyncPath   = Join-Path $dir 'pad-sync.ps1'
            PythonExe     = Join-Path $dir 'python.exe'
            CalendarPath  = Join-Path $dir 'calendar.xlsx'
            WorkdayScript = Join-Path $dir 'workday.py'
            RunTimeoutSec = 123
            PadRoot       = $root
        }
        $script:cfgPath = Join-Path $dir 'runtime.json'
        $script:cfg | ConvertTo-Json | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
    }

    It 'normal load: all fields returned with the correct types' {
        $r = Get-PadRuntimeConfig -ConfigPath $script:cfgPath
        $r.PadSyncPath | Should Be $script:cfg.PadSyncPath
        $r.PythonExe | Should Be $script:cfg.PythonExe
        $r.CalendarPath | Should Be $script:cfg.CalendarPath
        $r.WorkdayScript | Should Be $script:cfg.WorkdayScript
        [int64]$r.RunTimeoutSec | Should Be 123
        $r.PadRoot | Should Be $script:cfg.PadRoot
    }

    It 'missing field: CONFIG_MISSING with no silent default fill-in' {
        $cfg = [ordered]@{} + $script:cfg
        $cfg.Remove('PadRoot')
        $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
        $code = $null
        try { Get-PadRuntimeConfig -ConfigPath $script:cfgPath } catch { $code = $_.Exception.Data['code'] }
        $code | Should Be 'CONFIG_MISSING'
    }

    It 'path not found: CONFIG_PATH_NOT_FOUND' {
        $cfg = [ordered]@{} + $script:cfg
        $cfg.PythonExe = Join-Path $TestDrive 'no-such-python.exe'
        $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
        $code = $null
        try { Get-PadRuntimeConfig -ConfigPath $script:cfgPath } catch { $code = $_.Exception.Data['code'] }
        $code | Should Be 'CONFIG_PATH_NOT_FOUND'
    }

    It 'wrong type: a non-positive integer RunTimeoutSec records CONFIG_INVALID_VALUE' {
        foreach ($bad in @('123', 0, -5)) {
            $cfg = [ordered]@{} + $script:cfg
            $cfg.RunTimeoutSec = $bad
            $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:cfgPath -Encoding UTF8
            $code = $null
            try { Get-PadRuntimeConfig -ConfigPath $script:cfgPath } catch { $code = $_.Exception.Data['code'] }
            $code | Should Be 'CONFIG_INVALID_VALUE'
        }
    }

    It 'config file missing: CONFIG_PATH_NOT_FOUND' {
        $code = $null
        try { Get-PadRuntimeConfig -ConfigPath (Join-Path $TestDrive 'missing.json') } catch { $code = $_.Exception.Data['code'] }
        $code | Should Be 'CONFIG_PATH_NOT_FOUND'
    }
}
