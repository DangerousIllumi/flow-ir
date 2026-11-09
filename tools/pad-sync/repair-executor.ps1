# repair-executor.ps1 — pluggable executor for the repair loop (rule-based)
#
# Protocol (the agent may swap in any program that honours the same interface):
#   Input   : -ContextFile <repair_ctx_N.json>  -InputRobin <current.robin>  -OutputRobin <round_N.robin>
#   Success : produce OutputRobin and exit 0; the loop continues with the next round
#   Give up : exit 1; the loop stops (a .hint.md is written for a human or agent to take over)
#
# The built-in rules only apply fixes that are certainly safe; everything else is given up on, so
# automatic changes never break a flow.
# Rule table:
#   R1 missing file / missing directory → first try the corrected form (trim spaces, strip trailing backslashes), then look for a unique same-name item under -PadRoot
#   R2 missing directory (under -PadRoot) → create it
#   R3 other error codes → give a targeted hint for the error family; never change anything (SAP/UI/Excel/clipboard/script exit codes…)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContextFile,
    [Parameter(Mandatory = $true)][string]$InputRobin,
    [Parameter(Mandatory = $true)][string]$OutputRobin,
    # Search root for path fixes: only look for same-name items and create directories under it. Point it at a temp directory in tests to leave the real environment alone.
    # When omitted it is resolved by the priority below; C:\PAD is no longer hard-coded as the parameter default
    [string]$PadRoot,
    # JSON mapping error codes → repair rules and hint templates: adding an error code only touches it, not this script
    [string]$RulesFile
)
$ErrorActionPreference = 'Stop'

# PAD root resolution priority (R1/R2 only look for same-name items and create directories under it):
#   1) -PadRoot passed explicitly: the caller or a test stated it, highest priority;
#   2) the FLOW_IR_PAD_ROOT environment variable: switches between multiple deployments on one machine;
#   3) the PadRoot field of the local runtime config business\config\runtime.json (that file is not committed);
#   4) fall back to C:\PAD so existing callers (e.g. pad-repair-loop without -PadRoot) behave as before.
# 2) and 3) are only adopted when the directory really exists, so a mistyped variable name cannot silently move the search root to an empty directory.
function Resolve-PadRoot([string]$Explicit) {
    # 1) Explicit parameter: used as given, with no existence check (a test may deliberately point at a directory that does not exist yet)
    if ($Explicit) { return $Explicit }

    # 2) Environment variable
    $envRoot = [string]$env:FLOW_IR_PAD_ROOT
    if ($envRoot) {
        if (Test-Path -LiteralPath $envRoot) { return $envRoot }
        Write-Host "[executor] the directory pointed to by FLOW_IR_PAD_ROOT does not exist; ignored: $envRoot"
    }

    # 3) Local runtime config: read only the PadRoot field, skipping PadConfig's full required-field validation
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $runtimeConfig = Join-Path $repoRoot 'business\config\runtime.json'
    if (Test-Path -LiteralPath $runtimeConfig) {
        try {
            $cfg = [IO.File]::ReadAllText($runtimeConfig, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $cfgRoot = [string]$cfg.PadRoot
            if ($cfgRoot) {
                if (Test-Path -LiteralPath $cfgRoot) { return $cfgRoot }
                Write-Host "[executor] the directory pointed to by the runtime config PadRoot does not exist; ignored: $cfgRoot"
            }
        } catch {
            # A corrupt config must not crash the repair loop: record the reason and keep going to the fallback
            Write-Host "[executor] the runtime config cannot be parsed; ignored: $($_.Exception.Message)"
        }
    }

    # 4) Compatibility fallback
    return 'C:\PAD'
}

$PadRoot = (Resolve-PadRoot $PadRoot).TrimEnd('\')

# The rule table defaults to repair-rules.json in the script's own directory
if (-not $RulesFile) { $RulesFile = Join-Path $PSScriptRoot 'repair-rules.json' }
if (-not (Test-Path $RulesFile)) { Write-Host "[executor] rules file not found: $RulesFile"; exit 1 }
$rules = [IO.File]::ReadAllText($RulesFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

$ctx = [IO.File]::ReadAllText($ContextFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

# Error codes come from two sources: the run-level padExceptionInfo and the action-level Actions.log;
# in a designer-local run a built-in action failure only has the run level and a UI action failure only the action level, hence the two-level fallback
$code = ''
$msg = ''
if ($ctx.error -and $ctx.error.code) { $code = [string]$ctx.error.code }
if ($ctx.error -and $ctx.error.type) { $msg = [string]$ctx.error.type }
$actCode = ''
$actMsg = ''
if ($ctx.failedAction -and $ctx.failedAction.error) {
    $actCode = [string]$ctx.failedAction.error.code
    $actMsg = [string]$ctx.failedAction.error.message
}
if (-not $code) { $code = $actCode }
if (-not $msg) { $msg = $actMsg }
$actName = ''
$sysName = ''
if ($ctx.failedAction) {
    if ($ctx.failedAction.name) { $actName = [string]$ctx.failedAction.name }
    if ($ctx.failedAction.systemActionName) { $sysName = [string]$ctx.failedAction.systemActionName }
}
Write-Host "[executor] round $($ctx.round), error code: $code; action: $sysName / $actName"

$text = [IO.File]::ReadAllText($InputRobin, [Text.Encoding]::UTF8)
$raw = [IO.File]::ReadAllBytes($InputRobin)
$hadBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)

function Save-Robin([string]$content) {
    if ($hadBom) { [IO.File]::WriteAllText($OutputRobin, $content, (New-Object Text.UTF8Encoding($true))) }
    else { [IO.File]::WriteAllText($OutputRobin, $content, (New-Object Text.UTF8Encoding($false))) }
}

# Paths in a .robin use doubled backslashes; match "drive letter + doubled backslash" here
$PathRx = [regex]'[A-Za-z]:\\\\[^\x27\x22\s,;\)]+'

# Decide whether a path is a directory: anything without an extension is treated as a directory
function Is-DirPath([string]$p) {
    return -not ([IO.Path]::GetExtension($p))
}

function Find-UniqueUnderPad([string]$leaf, [bool]$isDir) {
    if ($isDir) {
        return @(Get-ChildItem $PadRoot -Recurse -Directory -Filter $leaf -ErrorAction SilentlyContinue)
    }
    return @(Get-ChildItem $PadRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue)
}

function To-Raw([string]$p) { return $p.Replace('\', '\\') }

function Log-Fix([string]$rule, [string]$detail) { Write-Host "[executor] $rule：$detail" }

# ── R1/R2: path errors (file or directory does not exist) ────────────────────────
# Whether a path may be changed is decided by the fixerRules table: touch a path only when the error code or
# error message confirms "path not found", so an ordinary failure is not misread as a path fix
$fixerRule = @($rules.fixerRules) | Where-Object {
    ($_.codePattern -and $code -match $_.codePattern) -or
    ($_.messagePattern -and $msg -and $msg -match $_.messagePattern)
} | Select-Object -First 1
$isPathErr = [bool]($fixerRule -and $fixerRule.action -eq 'resolve-path')
if ($isPathErr) {
    $missing = @()
    foreach ($m in $PathRx.Matches($text)) {
        $real = $m.Value.Replace('\\', '\')
        if (Test-Path $real) { continue }
        $missing += [pscustomobject]@{ Raw = $m.Value; Real = $real }
    }
    $missing = @($missing | Sort-Object Real -Unique)

    if ($missing.Count -eq 0) {
        Write-Host '[executor] R1: every absolute path in the .robin exists, so the error comes from something other than a path'
    } elseif ($missing.Count -gt 1) {
        Write-Host "[executor] R1: $($missing.Count) path(s) do not exist; cannot tell which one to fix: $(@($missing | ForEach-Object { $_.Real }) -join ' | ')"
    } else {
        $one = $missing[0]
        $isDir = Is-DirPath $one.Real
        $fixed = $null
        $rule = $null

        # 1) Correct the spelling: trim leading/trailing spaces, strip a redundant trailing backslash, collapse repeated backslashes into one
        $trim = $one.Real.Trim().TrimEnd('\')
        $trim = [regex]::Replace($trim, '\\{2,}', '\')
        if ($trim -ne $one.Real -and (Test-Path $trim)) {
            $fixed = $trim; $rule = 'R1'
        }

        # 2) A unique same-name item under $PadRoot (file by file name, directory by directory name)
        if (-not $fixed) {
            $leaf = Split-Path $one.Real -Leaf
            $cand = @(Find-UniqueUnderPad $leaf $isDir)
            if ($cand.Count -eq 1) {
                $fixed = $cand[0].FullName; $rule = 'R1'
                Log-Fix 'R1' "$($one.Real) does not exist; the only same-name entry under $PadRoot was changed to $fixed"
            } elseif ($cand.Count -gt 1) {
                Write-Host "[executor] R1: $PadRoot has $($cand.Count) same-name entries for $leaf; the unique target cannot be determined"
            }
        }

        # 3) A directory located under $PadRoot → create it directly (nothing gets overwritten)
        if (-not $fixed -and $isDir -and $one.Real -like "$PadRoot\*") {
            try {
                New-Item -ItemType Directory -Path $one.Real -Force | Out-Null
                $rule = 'R2'
                Log-Fix 'R2' "created the missing directory $($one.Real)"
            } catch {
                Write-Host "[executor] R2: failed to create the directory: $($_.Exception.Message)"
            }
        }

        # Once the directory exists there is nothing to change in the .robin
        if ($rule -eq 'R2') { Save-Robin $text; exit 0 }
        if ($fixed) {
            $newRaw = To-Raw $fixed
            $text = $text.Replace($one.Raw, $newRaw)
            Save-Robin $text
            exit 0
        }
    }
}

# ── R3: error families that must not be changed automatically — give a targeted hint from the rule table ──
# Matching follows the array order in the JSON: error code first, then the system action name (e.g. RunDOSCommand)
$hintRule = @($rules.hintRules) | Where-Object {
    ($_.codePattern -and $code -match $_.codePattern) -or
    ($_.systemActionPattern -and $sysName -match $_.systemActionPattern)
} | Select-Object -First 1
if ($hintRule) {
    $codeHelp = [string]$hintRule.hint
} elseif ($rules.defaultHint) {
    $codeHelp = [string]$rules.defaultHint
} else {
    $codeHelp = 'Unrecognized error code: look it up by error message in section 4 of docs/script-standards.md.'
}

$extraJson = ''
if ($ctx.extraLogs) { $extraJson = ($ctx.extraLogs | ConvertTo-Json -Depth 6) }

$hint = @"
# Repair hints (round $($ctx.round))

- Error code: $code
- Error message: $msg
- Failed action: $sysName / $actName
- Telemetry log: $($ctx.logPath)
- Current .robin: $($ctx.currentRobinPath)

## Assessment

$codeHelp

## External script logs (extraLogs)

``````json
$extraJson
``````

## Failed action

``````json
$($ctx.failedAction | ConvertTo-Json -Depth 6)
``````

## Next steps

1. Open the .robin above and locate the failed action
2. Follow section 4 of docs/script-standards.md (the error.code fix strategy table)
3. Write the fixed script to: $OutputRobin
4. Run pad-repair-loop again for the next round
"@
$hintPath = [IO.Path]::ChangeExtension($OutputRobin, '.hint.md')
[IO.File]::WriteAllText($hintPath, $hint, (New-Object Text.UTF8Encoding($false)))
Write-Host "[executor] could not repair automatically; repair hints were written to $hintPath"
exit 1
