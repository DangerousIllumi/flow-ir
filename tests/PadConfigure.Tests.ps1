# PadConfigure.Tests.ps1 — 部署向导（Pester 3.4）
#
# 前置探查按参数注入路径判定，所以没有 SAP/Outlook 的 CI 也能跑：
#   - PAD 目录：临时目录造/不造子目录
#   - Python：真实 python.exe 与不存在的路径
#   - SAP GUI / Outlook：临时伪文件、空注册表键列表
# 配置合成与写盘：dot-source pad-configure.ps1 -NoMain，只测函数

$here = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $here 'tools\pad-sync\PadPreflight.psm1'
$cfgScript = Join-Path $here 'tools\pad-sync\pad-configure.ps1'
Import-Module $modulePath -Force
# Pester 3.4 没有 BeforeAll，脚本级 dot-source 只取函数、不跑主流程
. $cfgScript -NoMain

Describe 'PadPreflight preflight probes' {

    It 'PAD root missing subdirectories is reported as missing with a list of what is missing' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $r = Test-PadInstalled -PadRoot $root
        $r.Ok | Should Be $false
        $r.Detail | Should Match 'Scripts'
        $r.Hint | Should Not BeNullOrEmpty
    }

    It 'PAD root with all subdirectories present passes' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($d in 'Scripts', 'Results') {
            New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
        }
        $r = Test-PadInstalled -PadRoot $root
        $r.Ok | Should Be $true
    }

    It 'A nonexistent Python path is reported as missing' {
        $r = Get-PythonProbe -PythonExe (Join-Path $TestDrive 'nope\python.exe')
        $r.Ok | Should Be $false
        $r.Hint | Should Match 'PYTHON_EXE'
    }

    It 'A real Python prints its version and passes the probe' {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { Set-TestInconclusive '本机没有 python.exe'; return }
        $r = Get-PythonProbe -PythonExe $cmd.Source
        $r.Ok | Should Be $true
        $r.Detail | Should Match 'Python 3'
    }

    It 'SAP Logon path presence and absence are judged separately' {
        $fake = Join-Path $TestDrive 'saplogon.exe'
        New-Item -ItemType File -Path $fake -Force | Out-Null
        (Get-SapGuiProbe -SapLogonPath $fake).Ok | Should Be $true
        (Get-SapGuiProbe -SapLogonPath (Join-Path $TestDrive 'no\saplogon.exe')).Ok | Should Be $false
    }

    It 'Outlook with no candidate registry keys is reported as missing' {
        $r = Get-OutlookProbe -OfficeKeys @()
        $r.Ok | Should Be $false
        $r.Hint | Should Match 'Outlook'
    }

    It 'Runs the dirs check from the requirement declaration: missing directories fail, complete ones pass' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $req = [pscustomobject]@{
            checks = @([pscustomobject]@{ name = 'PAD 根目录'; type = 'dirs'; base = 'PAD_ROOT'; paths = @('Scripts', 'Results'); hint = '放对目录' })
        }
        $r1 = Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root }
        $r1[0].Ok | Should Be $false
        foreach ($d in 'Scripts', 'Results') { New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null }
        $r2 = Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root }
        $r2[0].Ok | Should Be $true
    }

    It 'Runs the files check from the requirement declaration: missing files fail, complete ones pass' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $req = [pscustomobject]@{
            checks = @([pscustomobject]@{ name = '工作日日历'; type = 'files'; base = 'PAD_ROOT'; paths = @('日历.xlsx'); hint = '放日历' })
        }
        (Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root })[0].Ok | Should Be $false
        New-Item -ItemType File -Path (Join-Path $root '日历.xlsx') -Force | Out-Null
        (Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root })[0].Ok | Should Be $true
    }

    It 'An unknown check type in the requirement declaration yields a readable hint instead of a crash' {
        $req = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'X'; type = 'bogus' }) }
        $r = Invoke-PreflightChecks -Requirements $req -Variables @{}
        $r[0].Ok | Should Be $false
        $r[0].Hint | Should Match 'registry|dirs'
    }
}

Describe 'pad-configure configuration generation' {

    It 'Answers win over defaults, and probe values win over defaults' {
        $defaults = [pscustomobject]@{ PAD_ROOT = 'D:\RPA\PAD'; PYTHON_EXE = 'C:\py\python.exe'; SAP_CLIENT = '100' }
        $cfg = New-ConfiguredConfig -Defaults $defaults `
            -Answers @{ SAP_CLIENT = '200' } `
            -Discovered @{ PAD_ROOT = 'E:\PIA\PAD' }
        $cfg.PAD_ROOT | Should Be 'E:\PIA\PAD'
        $cfg.SAP_CLIENT | Should Be '200'
        $cfg.PYTHON_EXE | Should Be 'C:\py\python.exe'
    }

    It 'The written JSON can be re-parsed with identical keys and values' {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $cfg = [ordered]@{ PAD_ROOT = 'C:\PAD'; SAP_CLIENT = '100' }
        Save-ConfigFile -Config $cfg -Path $p
        $back = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $back.PAD_ROOT | Should Be 'C:\PAD'
        $back.SAP_CLIENT | Should Be '100'
    }

    It 'A missing answers file throws an explicit error' {
        { Invoke-ConfigureMain -PadRoot $TestDrive -PythonExe 'x' `
            -ConfigPath (Join-Path $TestDrive 'c.json') `
            -SchemaFile (Join-Path $TestDrive 'c.schema.json') `
            -AnswersFile (Join-Path $TestDrive 'nope.json') -ProbeOnly:$false -SkipProbe } |
            Should Throw
    }
}

Describe 'pad-configure no longer defaults to a specific business flow' {
    It 'A config name that derives no example exits non-zero and never enters per-item confirmation or writing' {
        $scriptPath = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-configure.ps1'
        # 指定一个不存在的业务配置名 → 派生出的 <stem>.example.json 也必然不存在
        $cfg = Join-Path $TestDrive 'no-such-flow.json'
        # 子进程未捕获的 throw 会以错误记录形式回到父作用域，用 Start-Process 只取退出码与输出
        $o = Join-Path $TestDrive ('cfg-out-' + [guid]::NewGuid().ToString('N') + '.txt')
        $e = Join-Path $TestDrive ('cfg-err-' + [guid]::NewGuid().ToString('N') + '.txt')
        $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -SkipProbe' -f $scriptPath, $cfg
        $p = Start-Process -FilePath 'powershell' -ArgumentList $argList -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $o -RedirectStandardError $e
        $p.ExitCode | Should Not Be 0
        $out = ([IO.File]::ReadAllText($o, [Text.Encoding]::UTF8) +
            [IO.File]::ReadAllText($e, [Text.Encoding]::UTF8))
        $out | Should Match 'E_EXAMPLE_CONFIG_MISSING'
        $out | Should Match 'no-such-flow\.example\.json'
        # 不能进入逐项确认或写盘
        $out | Should Not Match 'INTERACTIVE_CONFIRM'
        $out | Should Not Match 'CONFIG_WRITTEN'
        (Test-Path $cfg) | Should Be $false
    }
}
