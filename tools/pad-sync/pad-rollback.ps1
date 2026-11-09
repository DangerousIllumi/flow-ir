# pad-rollback.ps1 — release rollback (generic; located by flow name)
#
# Principle: PAD's cloud flowVersion is only an ETag, so you cannot simply "switch back to the previous version";
#            the only workable rollback is to take a historical finished .robin from the local snapshots, inject it and publish again.
#
# pad-release.ps1 writes the snapshots after every successful release to business\snapshots\<flowName>\<timestamp>-<first 8 of sha>.robin;
# their content is already the variable-substituted artefact, so a rollback only restores the workflow definition and is unaffected by the current config values.
#
# Usage:
#   .\pad-rollback.ps1 -FlowName PAD_SYNC_TEST -DryRun      # only show which version would be restored; nothing is published
#   .\pad-rollback.ps1 -FlowName PAD_SYNC_TEST              # roll back one version
#   .\pad-rollback.ps1 -FlowName X -Back 2                  # roll back two versions
#   .\pad-rollback.ps1 -FlowName X -To 20261028-120000-ab12cd34
#
# Boundary: only the workflow definition is rolled back; already-posted SAP documents, already-sent emails and already-changed report files are not undone;
#           a rollback also triggers a real run through URL, so it asks for confirmation by default.
#
# Output: the last line is PAD_ROLLBACK_RESULT=<JSON>; exit code 0 success / 1 failure

[CmdletBinding()]
param(
    [string]$FlowName,
    # Snapshots directory and manifest default to the repository root; ConfigFile is derived from the flow name and must be passed explicitly when derivation fails
    [string]$SnapshotsRoot,
    [string]$ManifestPath,
    [string]$ConfigFile,
    [string]$SchemaFile,
    # Skip the most recent Back snapshots (1 = roll back to the previous version)
    [int]$Back = 1,
    # Point at the target directly: full path / file name / sha prefix
    [string]$To,
    [int]$RunTimeoutSec = 4200,
    [switch]$AllowProd,
    [switch]$DryRun,
    # Publish without running: after the rollback only save it to the cloud, without triggering a run
    [switch]$PublishOnly,
    # Skip the confirmation dialog (used when an orchestrating script has already confirmed)
    [switch]$SkipConfirm,
    # Only for Pester dot-sourcing to load the functions; the main flow is not executed
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
# $PSScriptRoot = tools\pad-sync; two levels up is the repository root
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script:DeployPath = Join-Path $here 'pad-deploy.ps1'
$script:ConfirmPath = Join-Path $here 'confirm-deploy.ps1'

# Snapshot selection and manifest appending are shared through PublishHistory.psm1
# Do not dot-source pad-release.ps1: it has its own param block, which would reset this
# script's identically named FlowName / ConfigFile / DryRun / AllowProd parameters
Import-Module (Join-Path $here 'PublishHistory.psm1') -Force
Import-Module (Join-Path $here 'RobinText.psm1') -Force
# Single implementation of fingerprint location/hashing: the baseline is rewritten after a successful rollback
Import-Module (Join-Path $here 'PadFingerprint.psm1') -Force
# Parsing of the child process's last-line RESULT is centralised in PadTelemetry
Import-Module (Join-Path $here 'PadTelemetry.psm1') -Force

function Log([string]$m) { Write-Host "[rollback] $m" }

# Call the pad-deploy child process and parse PAD_DEPLOY_RESULT (the last line)
function Invoke-DeployFromSnapshot([string]$RobinPath, [string]$CfgFile, [string]$Flow, [string]$Schema, [int]$TimeoutSec, [switch]$PublishOnly) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DeployPath,
        '-SourceRobin', $RobinPath, '-ConfigFile', $CfgFile, '-FlowName', $Flow,
        '-RunTimeoutSec', $TimeoutSec, '-SkipConfirm')
    if ($Schema) { $argList += @('-SchemaFile', $Schema) }
    if ($PublishOnly) { $argList += '-PublishOnly' }
    # A rollback is a release too, so a production flow requires explicit -AllowProd
    if ($AllowProd) { $argList += '-AllowProd' }
    $tmp = Join-Path $env:TEMP ('pad-rollback-' + [guid]::NewGuid().ToString('N') + '.log')
    & powershell @argList > $tmp 2>&1
    $json = Read-ChildResult -Name 'DEPLOY' `
        -Lines ([IO.File]::ReadAllLines($tmp, [Text.Encoding]::UTF8)) `
        -Logger { param($m) Write-Host "[rollback] $m" }
    if (-not $json) { throw "pad-deploy produced no PAD_DEPLOY_RESULT output (log: $tmp)" }
    return $json
}

# ═══ Main flow ═══
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; stage = 'init'; flow = $FlowName; dryRun = [bool]$DryRun
        fromSha256 = $null; targetSha256 = $null; targetSnapshot = $null
        deployedRobin = $null; runId = $null; runStatus = $null
        fingerprintBaseline = $null
        manifestPath = $null; warnings = @(); errors = @()
    }
    try {
        if (-not $FlowName) { throw 'missing -FlowName' }
        if (-not $SnapshotsRoot) { $SnapshotsRoot = Join-Path $script:RepoRoot 'business\snapshots' }
        if (-not $ManifestPath) { $ManifestPath = Join-Path $script:RepoRoot 'business\manifest.jsonl' }
        if (-not $ConfigFile) {
            # No longer default to a particular business flow: derive from -FlowName and error when derivation fails
            $guess = Join-Path $script:RepoRoot ("business\config\{0}.json" -f $FlowName)
            if (Test-Path -LiteralPath $guess) {
                $ConfigFile = $guess
            } else {
                throw "E_CONFIG_REQUIRED: -ConfigFile not provided and the name-derived path was not found: $guess; specify it with -ConfigFile"
            }
        }
        if (-not (Test-Path $ConfigFile)) { throw "config.json not found: $ConfigFile" }
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw 'Safety fuse: only PAD_SYNC_TEST may be rolled back by default. Rolling back a production flow requires explicit -AllowProd.'
        }

        # ── Stage 1: locate the target version ──
        $result.stage = 'select'
        $all = @(Get-ReleaseSnapshots $SnapshotsRoot $FlowName)
        $target = Select-RollbackSnapshot $SnapshotsRoot $FlowName -Back $Back -To $To
        $result.targetSnapshot = $target.FullName
        $result.targetSha256 = Get-RobinHash ([IO.File]::ReadAllText($target.FullName, [Text.Encoding]::UTF8))
        # The most recent snapshot is the currently active version
        $current = if ($all.Count -gt 0) { $all[$all.Count - 1] } else { $null }
        if ($current) { $result.fromSha256 = Get-RobinHash ([IO.File]::ReadAllText($current.FullName, [Text.Encoding]::UTF8)) }
        Log "current version snapshot: $(if ($current) { $current.Name } else { 'none' })"
        Log "rollback target snapshot: $($target.Name) (sha $($result.targetSha256.Substring(0, 8))...)"

        if ($DryRun) {
            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            Log '[DryRun] target version located; nothing was published'
        } else {
            # ── Stage 2: user confirmation (a rollback is a real release and runs immediately) ──
            $result.stage = 'confirm'
            if (-not $SkipConfirm) {
                $runNote = $(if ($PublishOnly) { 'This run only publishes and does not trigger a run.' } else { 'After rollback a real run is triggered immediately via URL.' })
                $msg = "Target flow: $FlowName`nCurrent snapshot: $(if ($current) { $current.Name } else { 'none' })`nRoll back to: $($target.Name)`n`nNote: a rollback only restores the flow definition; it does not undo SAP documents already posted, emails already sent, or report files already changed.`n$runNote`n`nRoll back now?"
                & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ConfirmPath -Title 'Rollback confirmation' -Msg $msg
                if ($LASTEXITCODE -ne 0) { throw 'user cancelled the rollback' }
                Log 'user confirmed the rollback'
            }

            # ── Stage 3: publish (reuse pad-deploy's inject / validate / run chain) ──
            # The snapshot is already finished content (no {{VAR}}), so copy it to a temp directory before deploying to keep snapshots clean
            $result.stage = 'publish'
            $tmpDir = Join-Path $env:TEMP ('pad-rollback-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
            try {
                $tmpRobin = Join-Path $tmpDir ((Get-SnapshotSafeName $FlowName) + '.robin')
                Copy-Item -LiteralPath $target.FullName -Destination $tmpRobin -Force
                $dep = Invoke-DeployFromSnapshot $tmpRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec -PublishOnly:$PublishOnly
                $result.deployedRobin = [string]$dep.deployedRobinPath
                if (-not $dep.ok) { throw ('rollback publish failed: ' + (@($dep.errors) -join '; ')) }
                $result.runStatus = [string]$dep.runResult.status
                $result.runId = [string]$dep.runResult.runId
                if ($PublishOnly) { Log 'rollback publish complete (-PublishOnly, no run was triggered)' }
                else { Log "rollback publish complete; verification run status: $($result.runStatus)" }

                # ── Fingerprint baseline: it must be rewritten after a successful rollback, otherwise admission keeps comparing against the old definition ──
                # A failed baseline write does not undo a successful rollback, but it must raise an explicit warning
                try {
                    $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
                    $workspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
                    $run = Find-LatestFlowRun $scriptsRoot $FlowName
                    $flowGuid = $(if ($run) { [string]$run.flowGuid } else { $null })
                    $ids = Get-FlowGuidFromLogPath ([string]$dep.runResult.logPath)
                    $runId = $(if ($ids) { [string]$ids.runId } else { $null })
                    $wsRobin = $null
                    if ($flowGuid) {
                        try { $wsRobin = Find-WorkspaceRobin $workspaceRoot $flowGuid $runId ([datetime]::UtcNow) }
                        catch { $wsRobin = $null }
                    }
                    $fpPath = Get-FingerprintBaselinePath $script:RepoRoot $FlowName
                    $fpBase = New-FingerprintBaseline -FlowName $FlowName -FlowGuid $flowGuid `
                        -EnvironmentId (Get-PadEnvironmentId) -SourceRobin $target.FullName `
                        -WorkspaceRobin $wsRobin -ConfigPath $ConfigFile -AcceptancePath $null
                    [void](Write-FingerprintBaseline $fpPath $fpBase)
                    $result.fingerprintBaseline = $fpPath
                    Log "fingerprint baseline rewritten: $fpPath"
                } catch {
                    $result.warnings += "fingerprint baseline rewrite failed: $($_.Exception.Message)"
                    Log "warning: fingerprint baseline rewrite failed ($($_.Exception.Message))"
                }

                $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            } finally {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "rollback failed at [$($result.stage)]: $($_.Exception.Message)"
    }
    finally {
        # ── Stage 4: manifest (not written for DryRun; both success and failure are recorded for audit) ──
        if (-not $DryRun -and $result.stage -ne 'init') {
            $entry = [ordered]@{
                ts = [datetime]::UtcNow.ToString('o'); type = 'rollback'
                flow = $result.flow
                fromSha256 = $result.fromSha256; targetSha256 = $result.targetSha256
                targetSnapshot = $result.targetSnapshot; deployedRobin = $result.deployedRobin
                runId = $result.runId; runStatus = $result.runStatus
                fingerprintBaseline = $result.fingerprintBaseline
                ok = $result.ok; errors = $result.errors
            }
            try { Add-ManifestEntry $ManifestPath $entry; $result.manifestPath = $ManifestPath; Log "manifest appended: $ManifestPath" }
            catch { $result.warnings += "manifest write failed: $($_.Exception.Message)" }
        }
        Write-Output ('PAD_ROLLBACK_RESULT=' + ($result | ConvertTo-Json -Depth 10 -Compress))
    }
    exit $exitCode
}
