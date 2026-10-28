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

Describe 'PadPreflight 前置探查' {

    It 'PAD 根目录缺子目录时判定为缺失并给出缺失清单' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $r = Test-PadInstalled -PadRoot $root
        $r.Ok | Should Be $false
        $r.Detail | Should Match 'Scripts'
        $r.Hint | Should Not BeNullOrEmpty
    }

    It 'PAD 根目录子目录齐全时判定通过' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($d in 'Scripts', 'Results') {
            New-Item -ItemType Directory -Path (Join-Path $root $d) -Force | Out-Null
        }
        $r = Test-PadInstalled -PadRoot $root
        $r.Ok | Should Be $true
    }

    It 'Python 路径不存在时判定为缺失' {
        $r = Get-PythonProbe -PythonExe (Join-Path $TestDrive 'nope\python.exe')
        $r.Ok | Should Be $false
        $r.Hint | Should Match 'PYTHON_EXE|安装 Python'
    }

    It '真实 Python 能输出版本并通过探测' {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $cmd) { Set-TestInconclusive '本机没有 python.exe'; return }
        $r = Get-PythonProbe -PythonExe $cmd.Source
        $r.Ok | Should Be $true
        $r.Detail | Should Match 'Python 3'
    }

    It 'SAP Logon 路径存在与否分别判定' {
        $fake = Join-Path $TestDrive 'saplogon.exe'
        New-Item -ItemType File -Path $fake -Force | Out-Null
        (Get-SapGuiProbe -SapLogonPath $fake).Ok | Should Be $true
        (Get-SapGuiProbe -SapLogonPath (Join-Path $TestDrive 'no\saplogon.exe')).Ok | Should Be $false
    }

    It 'Outlook 无任何候选注册表键时判定为缺失' {
        $r = Get-OutlookProbe -OfficeKeys @()
        $r.Ok | Should Be $false
        $r.Hint | Should Match 'Outlook'
    }

    It '按需求声明执行 dirs 检查：缺目录失败、齐全通过' {
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

    It '按需求声明执行 files 检查：缺文件失败、齐全通过' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $req = [pscustomobject]@{
            checks = @([pscustomobject]@{ name = '工作日日历'; type = 'files'; base = 'PAD_ROOT'; paths = @('日历.xlsx'); hint = '放日历' })
        }
        (Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root })[0].Ok | Should Be $false
        New-Item -ItemType File -Path (Join-Path $root '日历.xlsx') -Force | Out-Null
        (Invoke-PreflightChecks -Requirements $req -Variables @{ PAD_ROOT = $root })[0].Ok | Should Be $true
    }

    It '需求声明里出现未知类型时给出可读提示而不是崩溃' {
        $req = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'X'; type = 'bogus' }) }
        $r = Invoke-PreflightChecks -Requirements $req -Variables @{}
        $r[0].Ok | Should Be $false
        $r[0].Hint | Should Match 'registry|dirs'
    }
}

Describe 'pad-configure 配置生成' {

    It '答案优先于默认值，探查值优先于默认值' {
        $defaults = [pscustomobject]@{ PAD_ROOT = 'D:\RPA\PAD'; PYTHON_EXE = 'C:\py\python.exe'; SAP_CLIENT = '100' }
        $cfg = New-ConfiguredConfig -Defaults $defaults `
            -Answers @{ SAP_CLIENT = '200' } `
            -Discovered @{ PAD_ROOT = 'E:\PIA\PAD' }
        $cfg.PAD_ROOT | Should Be 'E:\PIA\PAD'
        $cfg.SAP_CLIENT | Should Be '200'
        $cfg.PYTHON_EXE | Should Be 'C:\py\python.exe'
    }

    It '写出的 JSON 可被重新解析且键值一致' {
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        $cfg = [ordered]@{ PAD_ROOT = 'C:\PAD'; SAP_CLIENT = '100' }
        Save-ConfigFile -Config $cfg -Path $p
        $back = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $back.PAD_ROOT | Should Be 'C:\PAD'
        $back.SAP_CLIENT | Should Be '100'
    }

    It '答案文件缺失时抛出明确错误' {
        { Invoke-ConfigureMain -PadRoot $TestDrive -PythonExe 'x' `
            -ConfigPath (Join-Path $TestDrive 'c.json') `
            -SchemaFile (Join-Path $TestDrive 'c.schema.json') `
            -AnswersFile (Join-Path $TestDrive 'nope.json') -ProbeOnly:$false -SkipProbe } |
            Should Throw
    }
}
