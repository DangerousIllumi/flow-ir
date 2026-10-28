<#
.SYNOPSIS
    检查本地环境是否满足 Workflow Graphics Engineering 框架要求
.DESCRIPTION
    检查 Node.js (>=18) 和 Git 是否可用，输出版本与可用性状态。
    不需要管理员权限，可直接运行。
.NOTES
    运行方式：在文件夹空白处按住 Shift 右键 → "在此处打开 PowerShell"，
    然后输入： .\scripts\check-env.ps1
#>

$ErrorActionPreference = "Continue"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    [INFO] $msg" -ForegroundColor Gray }

$allOk = $true

Write-Step "检查 Node.js（用于运行 check-flows.js 和 next-ai-draw-io）"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $ver = & node -v
    Write-Ok "Node.js 已安装：$ver"
    # 解析主版本号
    $major = [int]($ver -replace 'v','' -split '\.')[0]
    if ($major -ge 18) {
        Write-Ok "版本满足要求（>= 18）"
    } else {
        Write-Fail "版本过低（$major < 18），请升级 Node.js"
        $allOk = $false
    }
} else {
    Write-Fail "未检测到 Node.js"
    Write-Info "下载地址：https://nodejs.org/ （选 LTS 版本，一路下一步即可）"
    $allOk = $false
}

Write-Step "检查 Git（用于克隆 pad-robin-action-kb）"
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $gitVer = & git --version
    Write-Ok "Git 已安装：$gitVer"
} else {
    Write-Fail "未检测到 Git"
    Write-Info "下载地址：https://git-scm.com/download/win"
    $allOk = $false
}

Write-Step "检查 Power Automate Desktop"
$padFound = $false
$padInfo  = ""

# 方法1：MSIX / Store 安装包（普通用户即可查询，最可靠）
$pkg = Get-AppxPackage -Name "*PowerAutomateDesktop*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
    $padFound = $true
    $padInfo  = "Store/Appx 包 $($pkg.Name) 版本 $($pkg.Version)"
}

# 方法2：注册表卸载项（覆盖经典安装版）
if (-not $padFound) {
    $regKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($k in $regKeys) {
        $item = Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*Power Automate*Desktop*" } |
                Select-Object -First 1
        if ($item) {
            $padFound = $true
            $padInfo  = "$($item.DisplayName) 版本 $($item.DisplayVersion)"
            break
        }
    }
}

# 方法3：常见安装 / 配置目录
if (-not $padFound) {
    $padDirs = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Power Automate Desktop"),
        "C:\Program Files\Microsoft Power Automate Desktop",
        "C:\Program Files (x86)\Microsoft Power Automate Desktop"
    )
    foreach ($d in $padDirs) {
        if (Test-Path $d) {
            $padFound = $true
            $padInfo  = "安装目录 $d"
            break
        }
    }
}

# 方法4：WindowsApps 内可执行文件（尽力而为；普通用户通常无权列出该目录）
if (-not $padFound) {
    $wa = Join-Path $env:ProgramFiles "WindowsApps"
    if (Test-Path $wa) {
        $padExe = Get-ChildItem $wa -Filter "PAD.Designer.exe" -Recurse -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        if ($padExe) {
            $padFound = $true
            $padInfo  = $padExe.FullName
        }
    }
}

if ($padFound) {
    Write-Ok "PAD 已安装：$padInfo"
} else {
    Write-Fail "未检测到 Power Automate Desktop"
    Write-Info "若你确信装过，很可能是权限限制（WindowsApps 需管理员才能列出）导致漏检，可忽略"
    Write-Info "确认方法：在【管理员】PowerShell 里运行  Get-AppxPackage -Name *PowerAutomate*"
    Write-Info "若确实没装：Microsoft Store 搜索 'Power Automate Desktop' 安装"
    $allOk = $false
}

Write-Host "`n"
if ($allOk) {
    Write-Host "=== 环境检查通过 ===" -ForegroundColor Green
    Write-Host "现在可以运行 .\setup.ps1 进行框架安装" -ForegroundColor Green
} else {
    Write-Host "=== 环境检查未通过 ===" -ForegroundColor Red
    Write-Host "请先安装上述缺失组件，然后重新运行本脚本" -ForegroundColor Red
    Write-Host "安装完成后可能需要重启 PowerShell 让 PATH 生效" -ForegroundColor Yellow
}
Write-Host ""
