# PadPreflight.psm1 — deployment preflight probes (machine / Python / SAP GUI / Outlook)
#
# Read-only checks only: nothing is installed and no environment is modified; every probe returns the same shape:
#   Name   check name
#   Ok     whether it passed
#   Detail what was actually found (versions, paths, missing directories, ...)
#   Hint   actionable advice for the user when the check fails
#
# Design note: every path/registry location can be passed in as a parameter,
# so unit tests can verify the decision logic on any machine (including CI without SAP/Outlook).

function New-Probe {
    param([string]$Name, [bool]$Ok, [string]$Detail, [string]$Hint = '')
    return [pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail; Hint = $Hint }
}

# PAD deployment root: check that all the key subdirectories are present
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
        return New-Probe 'PAD root' $true "$PadRoot (all required subdirectories present)"
    }
    return New-Probe 'PAD root' $false "$PadRoot is missing: $($missing -join ', ')" `
        "Install or copy the PAD deployment package first, or point -PadRoot at the correct root directory"
}

# Python: the executable exists + prints a version normally + can import openpyxl
function Get-PythonProbe {
    param([Parameter(Mandatory = $true)][string]$PythonExe)
    if (-not (Test-Path $PythonExe)) {
        return New-Probe 'Python' $false "cannot find $PythonExe" `
            'Install Python 3.x, or point PYTHON_EXE in the config at python.exe'
    }
    # 2>&1 collects the version string uniformly (newer Python prints it to stdout, older versions may use stderr)
    $ver = (& $PythonExe --version 2>&1 | Out-String).Trim()
    if (-not $ver) {
        return New-Probe 'Python' $false "$PythonExe produced no version output" `
            'Check that the path is an executable python.exe (not a shortcut or a corrupt file)'
    }
    $mod = (& $PythonExe -c 'import openpyxl; print(openpyxl.__version__)' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        return New-Probe 'Python' $false "$ver, but openpyxl is missing" `
            "Run `"$PythonExe`" -m pip install openpyxl pytest"
    }
    return New-Probe 'Python' $true "$ver, openpyxl $mod"
}

# SAP GUI: whether the SAP Logon executable exists (the scripting switch cannot be read reliably from outside, so this is a file-level check only)
function Get-SapGuiProbe {
    param([Parameter(Mandatory = $true)][string]$SapLogonPath)
    if (Test-Path $SapLogonPath) {
        return New-Probe 'SAP GUI' $true $SapLogonPath
    }
    return New-Probe 'SAP GUI' $false "cannot find $SapLogonPath" `
        'Install SAP GUI, enable scripting in the SAP Logon options, then log in again'
}

# Outlook: detect installation through the registry locations of each Office version
function Get-OutlookProbe {
    param([string[]]$OfficeKeys)
    foreach ($k in $OfficeKeys) {
        if (Test-Path $k) { return New-Probe 'Outlook' $true "Office registry key found: $k" }
    }
    return New-Probe 'Outlook' $false 'no Outlook installation detected' `
        'Install Office/Outlook and sign in to the mailbox in Outlook once'
}

# Aggregate probe: return an array; the caller handles printing and the exit code
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

# Build candidate registry keys from the common Office install locations (read-only probe, nothing is written)
function Get-DefaultOfficeKeys {
    $keys = @()
    foreach ($ver in '16.0', '15.0', '14.0') {
        $keys += "HKLM:\SOFTWARE\Microsoft\Office\$ver\Outlook"
        $keys += "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\$ver\Outlook"
    }
    return $keys
}

# Common SAP Logon paths
function Get-DefaultSapLogonPath {
    $cands = @("$env:ProgramFiles\SAP\FrontEnd\SAPgui\saplogon.exe",
               "${env:ProgramFiles(x86)}\SAP\FrontEnd\SAPgui\saplogon.exe")
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    return $cands[0]
}

# Generic probes driven by a "workflow requirements declaration":
# each check in the declaration file (e.g. business/flows/<flow>.requirements.json) names its type,
# so switching workflows or adding/removing dependencies changes only the declaration, not this module.
#   type=dirs      : base (variable name, e.g. PAD_ROOT) + paths (relative subdirectories)
#   type=files     : base (variable name) + paths (relative file paths, each must exist)
#   type=python    : path (variable name, empty = locate python.exe automatically) + modules (modules that must be importable)
#   type=exe       : paths (candidate absolute paths, %ProgramFiles% expansion supported)
#   type=registry  : keys (candidate registry keys)
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
                    $results += New-Probe $name $false "$baseName is not specified" $hint
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
                    $results += New-Probe $name $false "$baseName is not specified" $hint
                    break
                }
                $missing = @()
                foreach ($p in @($c.paths)) {
                    $full = Join-Path $root ([string]$p)
                    if (-not (Test-Path -LiteralPath $full)) { $missing += $full }
                }
                if ($missing.Count -eq 0) {
                    $results += New-Probe $name $true "all files present: $root"
                } else {
                    $results += New-Probe $name $false ('missing files: ' + ($missing -join ' | ')) $hint
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
                        $probe = New-Probe $name $false "$($probe.Detail), missing modules: $($missingMods -join ', ')" `
                            "Run `"$exe`" -m pip install $($missingMods -join ' ')"
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
                else { $results += New-Probe $name $false ('none of the candidate paths exist: ' + (@($c.paths) -join ' | ')) $hint }
                break
            }
            'registry' {
                $found = $null
                foreach ($k in @($c.keys)) { if (Test-Path $k) { $found = $k; break } }
                if ($found) { $results += New-Probe $name $true "registry key found: $found" }
                else { $results += New-Probe $name $false 'no matching registry key found' $hint }
                break
            }
            default {
                $results += New-Probe $name $false "unknown check type: $($c.type)" `
                    'in a requirements declaration, type must be dirs / files / python / exe / registry'
            }
        }
    }
    return $results
}

Export-ModuleMember -Function `
    New-Probe, Test-PadInstalled, Get-PythonProbe, Get-SapGuiProbe, Get-OutlookProbe, `
    Get-PreflightReport, Get-DefaultOfficeKeys, Get-DefaultSapLogonPath, Invoke-PreflightChecks
