# pad-fingerprint.ps1 — flow fingerprint baseline: inspect the location result, seed it (-Set) and confirm manually
#
# Why this exists:
#   The FINGERPRINT check in pad-admit compares "current .robin / config / acceptance" against a baseline.
#   The baseline is produced by only three writers: a successful pad-release, a successful pad-rollback,
#   and -Set in this script (seeding an existing flow).
#
# Hard constraints:
#   1) The location is pinned to the revision (the revision directory name is this run's runId); never "take the latest one".
#      Multiple matching candidates are reported as AMBIGUOUS and the script stops; it never picks one automatically.
#   2) -Set only prints the location result and the three hashes; -Confirm is required to write, and -DryRun never writes.
#      Writing a baseline silently without human confirmation is forbidden.
#   3) The baseline lives in business\fingerprints\<flow name>.json (business layer, not committed).
#
# Usage:
#   .\pad-fingerprint.ps1 -FlowName X                        # inspect the location result only, no write
#   .\pad-fingerprint.ps1 -FlowName X -Set                   # print then exit with code 2, asking for -Confirm
#   .\pad-fingerprint.ps1 -FlowName X -Set -Confirm          # write the baseline after human confirmation
#
# Output: the last line is PAD_FINGERPRINT_RESULT=<JSON>; exit codes 0 success / 1 location failed / 2 confirmation needed or candidates not unique

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowName,
    [string]$RepoRoot,
    # PAD local run history and the Workspace root: taken from LOCALAPPDATA by default, overridable (tests use fake roots)
    [string]$ScriptsRoot,
    [string]$WorkspaceRoot,
    [string]$ConsoleConfigPath,
    [string]$ConfigFile,
    [string]$AcceptanceFile,
    [string]$BaselinePath,
    # Business flow file; when omitted, looked up under business\flows by matching -FlowName against pad_flow_name
    [string]$FlowFile,
    [string]$EnvironmentId,
    # Absolute paths of old copies outside the repo (same-name files in the PAD run directory); written into the external section only when seeding
    [string[]]$ExternalPaths,
    # List of scripts inside the repo; when passed explicitly the business-layer config is not read (for tests and special flows)
    [string[]]$ScriptPaths,
    [switch]$Set,
    [switch]$DryRun,
    [switch]$Confirm,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
# Import the module first: the default path calculation below uses Get-FingerprintBaselinePath
Import-Module (Join-Path $here 'PadFingerprint.psm1') -Force

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $here) }
if (-not $ScriptsRoot) {
    $ScriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
}
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
}
# ── Business flow identity: the same resolution pad-admit uses ──────────────────────────
# The PAD flow name (Chinese) is used to locate the flow in the local run history,
# but repo-side artifacts (.robin / config / acceptance / baseline) are always named after the flow.json file name;
# if the two names differ and get mixed up, the baseline is written where admission cannot find it (permanent NO_BASELINE).
function Resolve-FlowFileByName([string]$FlowsDir, [string]$Name) {
    if (-not $Name -or -not (Test-Path -LiteralPath $FlowsDir)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $FlowsDir -Filter '*.json' -File | Where-Object {
        $_.Name -notmatch '\.(acceptance|schema)\.json$'
    } | ForEach-Object {
        $j = $null
        try { $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { }
        [ordered]@{ File = $_.FullName; Json = $j }
    })
    # Match pad_flow_name exactly first; never guess when the match is not unique
    $hit = @($items | Where-Object { [string]$_.Json.pad_flow_name -eq $Name })
    if ($hit.Count -eq 1) { return $hit[0].File }
    return $null
}

if (-not $FlowFile) { $FlowFile = Resolve-FlowFileByName (Join-Path $RepoRoot 'business\flows') $FlowName }
# When the lookup fails, fall back to the PAD flow name (existing flows may not have a pad_flow_name yet)
$businessName = if ($FlowFile) {
    [IO.Path]::GetFileNameWithoutExtension($FlowFile)
} else { $FlowName }

if (-not $ConfigFile) {
    $guess = Join-Path $RepoRoot ("business\config\{0}.json" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $ConfigFile = $guess }
}
if (-not $AcceptanceFile) {
    # Same rule as pad-release: <flow>.acceptance.json with the same name in the business flow directory
    $guess = Join-Path $RepoRoot ("business\flows\{0}.acceptance.json" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $AcceptanceFile = $guess }
}
if (-not $BaselinePath) { $BaselinePath = Get-FingerprintBaselinePath $RepoRoot $businessName }

function Log([string]$m) { Write-Host "[fingerprint] $m" }
if ($businessName -ne $FlowName) {
    Log "business flow: $businessName (baseline/artifacts are named after the flow.json file name, consistent with pad-admit)"
}

$result = [ordered]@{
    ok = $false; flow = $FlowName; stage = 'locate'
    flowGuid = $null; runId = $null; revisionDir = $null
    workspaceRobin = $null; workspaceMtime = $null
    hashes = $null; baselinePath = $BaselinePath; written = $false
    environmentId = $null; code = $null; message = $null
}
$exitCode = 1

try {
    # ── Locate: the flow identity comes from the local run history, the definition copy is pinned to this runId ──
    $run = Find-LatestFlowRun $ScriptsRoot $FlowName
    if (-not $run) {
        $result.code = 'FINGERPRINT_UNKNOWN'
        throw "flow $FlowName not found in the local run history; cannot locate the revision (run the flow once first)"
    }
    $ids = Get-FlowGuidFromLogPath ([string]$run.path)
    $result.flowGuid = [string]$run.flowGuid
    $result.runId = $(if ($ids) { [string]$ids.runId } else { $null })
    $since = [datetime]::Parse([string]$run.startTime).ToUniversalTime()
    $wsRobin = Find-WorkspaceRobin $WorkspaceRoot $result.flowGuid $result.runId $since
    if (-not $wsRobin) {
        $result.code = 'FINGERPRINT_UNKNOWN'
        throw "no published definition for this run (runId=$($result.runId)) in Workspace (flowGuid=$($result.flowGuid)); will not fall back to the latest one"
    }
    $result.workspaceRobin = $wsRobin
    $result.revisionDir = Split-Path -Parent $wsRobin
    $result.workspaceMtime = (Get-Item -LiteralPath $wsRobin).LastWriteTime.ToString('o')
    $result.environmentId = $(if ($EnvironmentId) { $EnvironmentId } else { Get-PadEnvironmentId $ConsoleConfigPath })

    # The source .robin is the flow artifact; when it is missing, fall back to the published copy (stated explicitly in the log)
    # The source .robin compared by pad-admit is the same file: take it by flow.json file name, fall back to the published copy only when absent
    $sourceRobin = $null
    $guess = Join-Path $RepoRoot ("business\flows\{0}.robin" -f $businessName)
    if (Test-Path -LiteralPath $guess) { $sourceRobin = $guess } else { $sourceRobin = $wsRobin }
    $result.hashes = Get-FingerprintParts $sourceRobin $ConfigFile $AcceptanceFile
    $sha = @()
    foreach ($k in @('robin', 'config', 'acceptance')) {
        $v = $result.hashes[$k]
        $sha += ('{0}={1}' -f $k, $(if ($v) { $v } else { '(missing)' }))
    }

    Log "flow: $FlowName"
    Log "revision dir: $($result.revisionDir)"
    Log "Workspace: $wsRobin"
    Log "modified: $($result.workspaceMtime)"
    Log "hashes: $($sha -join ' ')"
    Log "baseline file: $BaselinePath"

    # ── Write: requires -Set + -Confirm, and -DryRun never writes ──
    if ($Set -and -not $DryRun) {
        if (-not $Confirm) {
            $result.stage = 'need-confirm'; $result.code = 'FINGERPRINT_CONFIRM_REQUIRED'
            $result.message = 'location result printed; add -Confirm to write the baseline'
            Log 'no -Confirm: baseline not written (prevents silent seeding)'
            $exitCode = 2
        } else {
            $baseArgs = @{
                FlowName       = $FlowName
                FlowGuid       = $result.flowGuid
                EnvironmentId  = $result.environmentId
                SourceRobin    = $sourceRobin
                WorkspaceRobin = $wsRobin
                ConfigPath     = $ConfigFile
                AcceptancePath = $AcceptanceFile
                ExternalPaths  = $ExternalPaths
            }
            # Only an explicit -ScriptPaths skips the business-layer config, so the default behaviour cannot change silently
            if ($PSBoundParameters.ContainsKey('ScriptPaths')) { $baseArgs['ScriptPaths'] = $ScriptPaths }
            $base = New-FingerprintBaseline @baseArgs
            [void](Write-FingerprintBaseline $BaselinePath $base)
            $result.written = $true
            $result.stage = 'done'; $result.ok = $true; $result.code = 'OK'
            $result.message = 'baseline written'
            Log "baseline written: $BaselinePath"
            $exitCode = 0
        }
    } else {
        $result.stage = 'done'; $result.ok = $true; $result.code = 'OK'
        $result.message = $(if ($DryRun) { 'DryRun: inspect only, baseline not written' } else { 'inspect only, baseline not written (add -Set to seed)' })
        $exitCode = 0
    }
} catch {
    if (-not $result.code) {
        if ([string]$_.Exception.Data['code'] -eq 'FINGERPRINT_AMBIGUOUS') { $result.code = 'FINGERPRINT_AMBIGUOUS' }
        else { $result.code = 'FINGERPRINT_UNKNOWN' }
    }
    $result.message = $_.Exception.Message
    Log "failed: $($_.Exception.Message)"
    if ($result.code -eq 'FINGERPRINT_AMBIGUOUS') { $exitCode = 2 }
} finally {
    if (-not $Json) {
        Log ("result: {0} {1} (written={2})" -f $result.code, $result.message, $result.written)
    }
    Write-Output ('PAD_FINGERPRINT_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
}
exit $exitCode
