# pad-configure.ps1 — deployment wizard: preflight probes -> fill in each config item -> schema validation -> write to disk
#
# Usage:
#   # Health check only, no config generated (all OK exits 0, anything missing exits 1)
#   .\pad-configure.ps1 -ProbeOnly
#
#   # Interactive wizard (aborts first when a prerequisite is missing, with a suggested fix)
#   .\pad-configure.ps1
#
#   # Unattended: generate the config from an answers file (CI/batch deployment)
#   .\pad-configure.ps1 -AnswersFile .\answers.json -SkipProbe -Force
#
# Exit codes: 0 success / 1 missing prerequisite / 2 schema validation failed / 3 user cancelled
#
# -NoMain is for tests only: dot-sourcing yields the functions without running the wizard main flow.

[CmdletBinding()]
param(
    # When empty, resolved in this order: PAD_ROOT from the config -> the project's pad directory -> C:\PAD
    [string]$PadRoot,
    [string]$PythonExe,
    [string]$ConfigPath,
    [string]$SchemaFile,
    # Workflow requirements declaration (decides which items are probed); when omitted, derived from the config name as business\flows\<stem>.requirements.json
    [string]$RequirementsFile,
    # Non-interactive answers file (JSON with the same keys as the config); when given, nothing is asked one by one
    [string]$AnswersFile,
    [switch]$ProbeOnly,
    # Skip the preflight probes (used when generating a config offline)
    [switch]$SkipProbe,
    # Overwrite an existing config directly
    [switch]$Force,
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

# Parameter derivation happens only when the main flow runs: Pester dot-sourcing (-NoMain) only takes the functions and makes no write decisions
if (-not $NoMain) {
    if (-not $ConfigPath) {
        # No longer default to a particular business flow: only configs with a same-named schema count, and the match must be unique
        $cfgCands = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'business\config') -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notmatch '\.(schema|example)\.json$' -and
                (Test-Path -LiteralPath (Join-Path $_.DirectoryName `
                    ([IO.Path]::GetFileNameWithoutExtension($_.Name) + '.schema.json')))
            })
        if ($cfgCands.Count -eq 1) {
            $ConfigPath = $cfgCands[0].FullName
        } elseif ($cfgCands.Count -eq 0) {
            throw "missing -ConfigPath and business\config has no config with a matching schema; pass -ConfigPath"
        } else {
            throw ("missing -ConfigPath; $($cfgCands.Count) candidates found, pass -ConfigPath explicitly: " +
                (($cfgCands | ForEach-Object { $_.Name }) -join ', '))
        }
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ConfigPath))
    if (-not $SchemaFile) {
        # Same derivation rule as pad-deploy: <stem>.schema.json in the same directory
        $SchemaFile = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) ($stem + '.schema.json')
    }
    # Example config derived from the config name (<stem>.example.json); no business flow's file name is hardcoded any more
    $ExamplePath = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) `
        ($stem + '.example.json')
}

Import-Module (Join-Path $here 'PadPreflight.psm1') -Force

function Write-ProbeTable($checks) {
    Write-Host ''
    Write-Host '[configure] preflight probes'
    foreach ($c in $checks) {
        $flag = if ($c.Ok) { 'OK  ' } else { 'MISSING' }
        Write-Host ("  [{0}] {1}: {2}" -f $flag, $c.Name, $c.Detail)
        if (-not $c.Ok -and $c.Hint) { Write-Host ("         -> " + $c.Hint) }
    }
    Write-Host ''
}

# Start from the example defaults, then overlay the probed real paths and the user answers (answers win)
function New-ConfiguredConfig {
    param(
        [Parameter(Mandatory = $true)]$Defaults,
        [hashtable]$Answers = @{},
        [hashtable]$Discovered = @{}
    )
    $cfg = [ordered]@{}
    foreach ($p in $Defaults.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    foreach ($k in $Discovered.Keys) {
        if ($Discovered[$k]) { $cfg[$k] = $Discovered[$k] }
    }
    foreach ($k in $Answers.Keys) {
        if ($null -ne $Answers[$k] -and [string]$Answers[$k] -ne '') { $cfg[$k] = [string]$Answers[$k] }
    }
    return $cfg
}

function Save-ConfigFile {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = $Config | ConvertTo-Json -Depth 5
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

# Reuse pad-deploy's schema validation so there are not two diverging rule sets
function Invoke-ConfigValidation {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigFile,
        [Parameter(Mandatory = $true)][string]$SchemaFile
    )
    $deploy = Join-Path $here 'pad-deploy.ps1'
    # FlowName is mandatory in pad-deploy; validate-only mode never touches a flow, so a placeholder value will do
    & $deploy -ValidateOnly -FlowName 'PAD_SYNC_TEST' -ConfigFile $ConfigFile -SchemaFile $SchemaFile | Out-Host
    return $LASTEXITCODE
}

function Invoke-ConfigureMain {
    param(
        [string]$PadRoot, [string]$PythonExe, [string]$ConfigPath, [string]$SchemaFile,
        [string]$RequirementsFile, [string]$AnswersFile,
        [switch]$ProbeOnly, [switch]$SkipProbe, [switch]$Force
    )

    # The PAD root is not hardcoded to the C drive: prefer the existing config value, then the project's pad directory, and only then fall back to C:\PAD
    if (-not $PadRoot) {
        if (Test-Path $ConfigPath) {
            $existing = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($existing.PAD_ROOT) { $PadRoot = [string]$existing.PAD_ROOT }
        }
        if (-not $PadRoot -and (Test-Path (Join-Path $repoRoot 'pad'))) {
            $PadRoot = Join-Path $repoRoot 'pad'
        }
        if (-not $PadRoot) { $PadRoot = 'C:\PAD' }
        Write-Host "[configure] PAD root resolved to: $PadRoot"
    }

    if (-not $PythonExe) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $PythonExe = $cmd.Source }
    }
    if (-not (Test-Path $ExamplePath)) { throw "E_EXAMPLE_CONFIG_MISSING: example config not found: $ExamplePath" }
    if (-not (Test-Path $SchemaFile)) { throw "E_SCHEMA_MISSING: schema not found: $SchemaFile" }

    $checks = @()
    if ($SkipProbe -and -not $ProbeOnly) {
        Write-Host '[configure] preflight probes skipped (-SkipProbe); generating the config directly'
    } else {
        if (-not $RequirementsFile) {
            # The requirements declaration is derived from the config name (business\flows\<stem>.requirements.json); no business flow is hardcoded any more
            $RequirementsFile = Join-Path $repoRoot ("business\flows\{0}.requirements.json" -f $stem)
        }
        if (-not (Test-Path $RequirementsFile)) { throw "requirements declaration not found: $RequirementsFile" }
        $req = [IO.File]::ReadAllText($RequirementsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $vars = @{ PAD_ROOT = $PadRoot; PYTHON_EXE = $PythonExe }
        $checks = Invoke-PreflightChecks -Requirements $req -Variables $vars
        Write-ProbeTable $checks
    }

    $missing = @($checks | Where-Object { -not $_.Ok })
    if ($ProbeOnly) {
        if ($missing.Count -eq 0) { Write-Host '[configure] all preflight checks passed'; return 0 }
        Write-Host "[configure] $($missing.Count) item(s) missing; fix them as suggested above and rerun"
        return 1
    }
    if ($missing.Count -gt 0 -and -not $SkipProbe) {
        Write-Host '[configure] preflight failures; config generation aborted (add -SkipProbe to fill it in offline)'
        return 1
    }

    $defaults = [IO.File]::ReadAllText($ExamplePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $answers = @{}
    if ($AnswersFile) {
        if (-not (Test-Path $AnswersFile)) { throw "answers file not found: $AnswersFile" }
        $obj = [IO.File]::ReadAllText($AnswersFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $obj.PSObject.Properties | ForEach-Object { $answers[$_.Name] = $_.Value }
    } elseif (-not $ProbeOnly) {
        # Interactive mode: show a default for each item; pressing Enter accepts it
        Write-Host '[configure] INTERACTIVE_CONFIRM confirm each setting (press Enter to accept the value in brackets)'
        foreach ($p in $defaults.PSObject.Properties) {
            $def = [string]$p.Value
            if ($p.Name -eq 'PAD_ROOT' -and $PadRoot) { $def = $PadRoot }
            if ($p.Name -eq 'PYTHON_EXE' -and $PythonExe) { $def = $PythonExe }
            $ans = Read-Host ("  {0} [{1}]" -f $p.Name, $def)
            if ($ans) { $answers[$p.Name] = $ans }
        }
    }

    $discovered = @{}
    if ($PadRoot) { $discovered['PAD_ROOT'] = $PadRoot }
    if ($PythonExe) { $discovered['PYTHON_EXE'] = $PythonExe }
    $cfg = New-ConfiguredConfig -Defaults $defaults -Answers $answers -Discovered $discovered

    if ((Test-Path $ConfigPath) -and -not $Force) {
        $ok = Read-Host "  $ConfigPath already exists; overwrite? (y/N)"
        if ($ok -notmatch '^(?i)y') { Write-Host '[configure] cancelled'; return 3 }
    }

    $tmp = Join-Path $env:TEMP ('cfg_' + [guid]::NewGuid().ToString('N') + '.json')
    Save-ConfigFile -Config $cfg -Path $tmp
    $code = Invoke-ConfigValidation -ConfigFile $tmp -SchemaFile $SchemaFile
    if ($code -ne 0) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host '[configure] the config failed validation and was not written; fix the field problems above and rerun'
        return 2
    }
    Copy-Item $tmp $ConfigPath -Force
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "[configure] CONFIG_WRITTEN config written: $ConfigPath"
    Write-Host '[configure] next: .\pad-deploy.ps1 -DryRun to preview the substitutions'
    return 0
}

if (-not $NoMain) {
    exit (Invoke-ConfigureMain -PadRoot $PadRoot -PythonExe $PythonExe -ConfigPath $ConfigPath `
        -SchemaFile $SchemaFile -RequirementsFile $RequirementsFile -AnswersFile $AnswersFile `
        -ProbeOnly:$ProbeOnly -SkipProbe:$SkipProbe -Force:$Force)
}
