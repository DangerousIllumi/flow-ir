# PadPreflight.psm1 — 部署前置探查（机器 / Python / SAP GUI / Outlook）
#
# 只做「只读检查」，不安装、不修改任何环境；每项都返回统一结构：
#   Name   检查项名称
#   Ok     是否通过
#   Detail 检测到的实际情况（版本号、路径、缺失的目录等）
#   Hint   未通过时给用户的可执行建议
#
# 设计要点：所有路径/注册表位置都可以由参数传入，
# 这样单元测试能在任意机器（含没有 SAP/Outlook 的 CI）上验证判定逻辑。

function New-Probe {
    param([string]$Name, [bool]$Ok, [string]$Detail, [string]$Hint = '')
    return [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Hint = $Hint }
}

# PAD 部署根目录：检查关键子目录是否齐全
function Test-PadInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$PadRoot,
        [string[]]$RequiredDirs = @('Scripts', 'Results')
    )
    $missing = @()
    foreach ($d in $RequiredDirs) {
        if (-not (Test-Path (Join-Path $PadRoot $d))) { $missing += $d }
    }
    if ($missing.Count -eq 0) {
        return New-Probe 'PAD 根目录' $true "$PadRoot（子目录齐全）"
    }
    return New-Probe 'PAD 根目录' $false "$PadRoot 缺少：$($missing -join ', ')" `
        "先安装/拷贝 PAD 部署包，或用 -PadRoot 指向正确的根目录"
}

# Python：可执行文件存在 + 能正常输出版本 + 能导入 openpyxl
function Get-PythonProbe {
    param([Parameter(Mandatory = $true)][string]$PythonExe)
    if (-not (Test-Path $PythonExe)) {
        return New-Probe 'Python' $false "找不到 $PythonExe" `
            '安装 Python 3.x，或在 config 里把 PYTHON_EXE 指向 python.exe'
    }
    # 2>&1 把版本号（新版 Python 打到 stdout，旧版可能到 stderr）统一收进来
    $ver = (& $PythonExe --version 2>&1 | Out-String).Trim()
    if (-not $ver) {
        return New-Probe 'Python' $false "$PythonExe 无法输出版本" `
            '确认该路径是可执行的 python.exe（不是快捷方式或损坏文件）'
    }
    $mod = (& $PythonExe -c 'import openpyxl; print(openpyxl.__version__)' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        return New-Probe 'Python' $false "$ver，但缺少 openpyxl" `
            "执行 `"$PythonExe`" -m pip install openpyxl pytest"
    }
    return New-Probe 'Python' $true "$ver，openpyxl $mod"
}

# SAP GUI：SAP Logon 可执行文件是否存在（脚本开关无法从外部可靠读取，只做文件级检查）
function Get-SapGuiProbe {
    param([Parameter(Mandatory = $true)][string]$SapLogonPath)
    if (Test-Path $SapLogonPath) {
        return New-Probe 'SAP GUI' $true $SapLogonPath
    }
    return New-Probe 'SAP GUI' $false "找不到 $SapLogonPath" `
        '安装 SAP GUI；并在 SAP Logon 选项里启用「脚本」后重新登录'
}

# Outlook：按 Office 版本的注册表位置判断是否安装
function Get-OutlookProbe {
    param([string[]]$OfficeKeys)
    foreach ($k in $OfficeKeys) {
        if (Test-Path $k) { return New-Probe 'Outlook' $true "检测到 Office 注册表项：$k" }
    }
    return New-Probe 'Outlook' $false '未检测到 Outlook 安装' `
        '安装 Office/Outlook，并先在 Outlook 里登录一次收发件邮箱'
}

# 汇总探查：返回数组，调用方负责打印与退出码
function Get-PreflightReport {
    param(
        [Parameter(Mandatory = $true)][string]$PadRoot,
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [string[]]$RequiredDirs = @('Scripts', 'Results'),
        [string]$SapLogonPath,
        [string[]]$OfficeKeys
    )
    $checks = @()
    $checks += Test-PadInstalled -PadRoot $PadRoot -RequiredDirs $RequiredDirs
    $checks += Get-PythonProbe -PythonExe $PythonExe
    if ($SapLogonPath) { $checks += Get-SapGuiProbe -SapLogonPath $SapLogonPath }
    $checks += Get-OutlookProbe -OfficeKeys $OfficeKeys
    return $checks
}

# 按 Office 常见安装位置生成候选注册表键（只读探测，不写注册表）
function Get-DefaultOfficeKeys {
    $keys = @()
    foreach ($ver in '16.0', '15.0', '14.0') {
        $keys += "HKLM:\SOFTWARE\Microsoft\Office\$ver\Outlook"
        $keys += "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$ver\Outlook"
    }
    return $keys
}

# SAP Logon 常见路径
function Get-DefaultSapLogonPath {
    $cands = @("$env:ProgramFiles\SAP\FrontEnd\SAPgui\saplogon.exe",
               "${env:ProgramFiles(x86)}\SAP\FrontEnd\SAPgui\saplogon.exe")
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $cands[0]
}

# 由「工作流需求声明」驱动的通用探查：
# 声明文件（如 flows/<flow>.requirements.json）里每个 check 指定 type，
# 换工作流或增删依赖只改声明，不改本模块代码。
#   type=dirs      : base（变量名，如 PAD_ROOT）+ paths（相对子目录）
#   type=files     : base（变量名）+ paths（相对文件路径，逐个必须存在）
#   type=python    : path（变量名，可空=自动找 python.exe）+ modules（需能导入的模块）
#   type=exe       : paths（候选绝对路径，支持 %ProgramFiles% 展开）
#   type=registry  : keys（候选注册表键）
function Invoke-PreflightChecks {
    param(
        [Parameter(Mandatory = $true)]$Requirements,
        [hashtable]$Variables = @{}
    )
    $results = @()
    foreach ($c in $Requirements.checks) {
        $name = [string]$c.name
        $hint = if ($c.hint) { [string]$c.hint } else { '' }
        switch ([string]$c.type) {
            'dirs' {
                $root = ''
                $baseName = [string]$c.base
                if ($baseName -and $Variables.ContainsKey($baseName)) { $root = [string]$Variables[$baseName] }
                if (-not $root) {
                    $results += New-Probe $name $false "未指定 $baseName" $hint
                    break
                }
                $results += Test-PadInstalled -PadRoot $root -RequiredDirs @($c.paths)
                break
            }
            'files' {
                $root = ''
                $baseName = [string]$c.base
                if ($baseName -and $Variables.ContainsKey($baseName)) { $root = [string]$Variables[$baseName] }
                if (-not $root) {
                    $results += New-Probe $name $false "未指定 $baseName" $hint
                    break
                }
                $missing = @()
                foreach ($p in @($c.paths)) {
                    $full = Join-Path $root ([string]$p)
                    if (-not (Test-Path -LiteralPath $full)) { $missing += $full }
                }
                if ($missing.Count -eq 0) {
                    $results += New-Probe $name $true "文件齐全：$root"
                } else {
                    $results += New-Probe $name $false ('缺少文件：' + ($missing -join ' | ')) $hint
                }
                break
            }
            'python' {
                $exe = ''
                if ($c.path -and $Variables.ContainsKey([string]$c.path)) { $exe = [string]$Variables[[string]$c.path] }
                if (-not $exe) {
                    $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
                    if ($cmd) { $exe = $cmd.Source }
                }
                $probe = Get-PythonProbe -PythonExe $exe
                if ($probe.Ok -and $c.modules) {
                    $missingMods = @()
                    foreach ($m in @($c.modules)) {
                        & $exe -c "import $m" 2>$null
                        if ($LASTEXITCODE -ne 0) { $missingMods += $m }
                    }
                    if ($missingMods.Count -gt 0) {
                        $probe = New-Probe $name $false "$($probe.Detail)，缺少模块：$($missingMods -join ', ')" `
                            "执行 `"$exe`" -m pip install $($missingMods -join ' ')"
                    }
                }
                $results += $probe
                break
            }
            'exe' {
                $hits = @()
                foreach ($p in @($c.paths)) {
                    $expanded = [Environment]::ExpandEnvironmentVariables([string]$p)
                    if (Test-Path $expanded) { $hits += $expanded }
                }
                if ($hits.Count -gt 0) { $results += New-Probe $name $true $hits[0] }
                else { $results += New-Probe $name $false ('候选路径都不存在：' + (@($c.paths) -join ' | ')) $hint }
                break
            }
            'registry' {
                $found = $null
                foreach ($k in @($c.keys)) { if (Test-Path $k) { $found = $k; break } }
                if ($found) { $results += New-Probe $name $true "检测到注册表项：$found" }
                else { $results += New-Probe $name $false '未检测到对应注册表项' $hint }
                break
            }
            default {
                $results += New-Probe $name $false "未知检查类型：$($c.type)" `
                    'requirements 声明里 type 只能是 dirs / files / python / exe / registry'
            }
        }
    }
    return $results
}

Export-ModuleMember -Function `
    New-Probe, Test-PadInstalled, Get-PythonProbe, Get-SapGuiProbe, Get-OutlookProbe, `
    Get-PreflightReport, Get-DefaultOfficeKeys, Get-DefaultSapLogonPath, Invoke-PreflightChecks
