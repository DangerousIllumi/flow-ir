<#
.SYNOPSIS
    Check whether the local environment satisfies the flow-ir framework requirements.
.DESCRIPTION
    Checks that Node.js (>=18) and Git are available and prints their versions and status.
    No administrator rights are needed; run it directly.
.NOTES
    How to run: hold Shift and right-click in a blank area of the folder -> "Open PowerShell window here",
    then enter: .\tools\check-env.ps1
#>

$ErrorActionPreference = "Continue"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    [INFO] $msg" -ForegroundColor Gray }

$allOk = $true

Write-Step "Checking Node.js (used by check-flows.js and the flow diagram tools)"
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
    $ver = & node -v
    Write-Ok "Node.js installed: $ver"
    # Extract the major version number
    $major = [int]($ver -replace 'v','' -split '\.')[0]
    if ($major -ge 18) {
        Write-Ok "version meets the requirement (>= 18)"
    } else {
        Write-Fail "version too old ($major < 18); upgrade Node.js"
        $allOk = $false
    }
} else {
    Write-Fail "Node.js not detected"
    Write-Info "Download: https://nodejs.org/ (pick the LTS build and keep clicking Next)"
    $allOk = $false
}

Write-Step "Checking Git (used to clone pad-robin-action-kb)"
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $gitVer = & git --version
    Write-Ok "Git installed: $gitVer"
} else {
    Write-Fail "Git not detected"
    Write-Info "Download: https://git-scm.com/download/win"
    $allOk = $false
}

Write-Step "Checking Power Automate Desktop"
$padFound = $false
$padInfo  = ""

# Method 1: MSIX / Store package (queryable by a normal user, and the most reliable probe)
$pkg = Get-AppxPackage -Name "*PowerAutomateDesktop*" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pkg) {
    $padFound = $true
    $padInfo  = "Store/Appx package $($pkg.Name) version $($pkg.Version)"
}

# Method 2: registry uninstall entries (covers the classic installer)
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
            $padInfo  = "$($item.DisplayName) version $($item.DisplayVersion)"
            break
        }
    }
}

# Method 3: common install / configuration directories
if (-not $padFound) {
    $padDirs = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\Power Automate Desktop"),
        "C:\Program Files\Microsoft Power Automate Desktop",
        "C:\Program Files (x86)\Microsoft Power Automate Desktop"
    )
    foreach ($d in $padDirs) {
        if (Test-Path $d) {
            $padFound = $true
            $padInfo  = "install directory $d"
            break
        }
    }
}

# Method 4: executable inside WindowsApps (best effort; a normal user usually cannot list that directory)
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
    Write-Ok "PAD installed: $padInfo"
} else {
    Write-Fail "Power Automate Desktop not detected"
    Write-Info "If you are sure it is installed, the probe probably missed it because of permissions (listing WindowsApps requires administrator rights); you can ignore this"
    Write-Info "To confirm: run  Get-AppxPackage -Name *PowerAutomate*  in an [administrator] PowerShell"
    Write-Info "If it is really not installed: search 'Power Automate Desktop' in Microsoft Store and install it"
    $allOk = $false
}

Write-Host "`n"
if ($allOk) {
    Write-Host "=== Environment check passed ===" -ForegroundColor Green
    Write-Host "You can now run .\setup.ps1 to install the framework" -ForegroundColor Green
} else {
    Write-Host "=== Environment check failed ===" -ForegroundColor Red
    Write-Host "Install the missing components above, then run this script again" -ForegroundColor Red
    Write-Host "After installing you may need to restart PowerShell so PATH takes effect" -ForegroundColor Yellow
}
Write-Host ""
