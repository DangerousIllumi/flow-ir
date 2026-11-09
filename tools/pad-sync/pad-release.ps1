# pad-release.ps1 — release pipeline: test summary -> user confirmation -> publish -> URL trigger -> cloud history verification -> manifest
#
# Stages:
#   1. Test summary: pytest (tests\) + Pester (tests\*.Tests.ps1); any failure aborts the release
#   2. Validation + variable substitution: reuse pad-deploy -DryRun; the artefact is .deployed.robin
#   3. Pre-release snapshot: take the flow GUID and the current cloud version from the local run history (Console\Scripts)
#   4. User confirmation dialog (once, showing the test summary and the side effects)
#   5. Real release: reuse pad-deploy -SkipConfirm (inject -> publish -> URL trigger -> collect the run result)
#   6. Post-release verification:
#      a) The published script.robin in Workspace and .deployed.robin have the same normalised hash (the acceptance point)
#      b) The new run's RunDefinition.json: startTime after this release, status Succeeded, flowVersion recorded
#   7. Append one line to business\manifest.jsonl through PublishHistory.psm1 (type=release),
#      used by pad-rollback.ps1 for rollback and by the release inventory (PublishHistory.psm1)
#
# Output: the last line is PAD_RELEASE_RESULT=<JSON>; exit code 0 success / 1 failure
# -AcceptanceFile: after the run triggered by the release ends, check the artefacts against the criteria; when omitted it
#   looks for business\flows\<flow>.acceptance.json automatically
# -DryRun: run stages 1-3 only (tests + validation + substitution + snapshot); no confirmation, no release, no manifest
# -NoMain: only for Pester dot-sourcing to load the functions; the main flow is not executed
# Note: FlowName is not Mandatory, otherwise Pester dot-sourcing would prompt for parameters

[CmdletBinding()]
param(
    # When omitted, derived from -FlowName as business\flows\<FlowName>.robin / business\config\<FlowName>.json; a failed derivation is an error
    [string]$SourceRobin,
    [string]$ConfigFile,
    [string]$FlowName,
    [string]$SchemaFile,
    # Post-run acceptance criteria; when omitted, the same-named <flow>.acceptance.json is looked up automatically
    [string]$AcceptanceFile,
    [string]$PythonExe = 'C:\Program Files\Python313\python.exe',
    # A production flow may poll for up to 60 minutes plus processing headroom; the default is 4200 seconds; pass a smaller value explicitly for a quick verification
    [int]$RunTimeoutSec = 4200,
    [switch]$SkipTests,
    [switch]$DryRun,
    # Publish without running: after publishing only the hash is verified, with no run status or acceptance check
    [switch]$PublishOnly,
    [switch]$AllowProd,
    [switch]$NoMain
)
$ErrorActionPreference = "Stop"

# $PSScriptRoot = tools\pad-sync; two levels up is the repository root
# (computing from $MyInvocation.MyCommand.Path includes the file name, so two levels up would only reach tools)
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:DeployPath = Join-Path $PSScriptRoot 'pad-deploy.ps1'
$script:ConfirmPath = Join-Path $PSScriptRoot 'confirm-deploy.ps1'

function Log([string]$m) { Write-Host "[release] $m" }

# ═══ Pure functions (shared by the main flow and the Pester unit tests) ═══
# Single implementation of fingerprint location and identity resolution (shared by pad-fingerprint / pad-admit / pad-rollback)
Import-Module (Join-Path $PSScriptRoot 'PadFingerprint.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global
# Parsing of the child process's last-line RESULT is centralised in PadTelemetry
Import-Module (Join-Path $PSScriptRoot 'PadTelemetry.psm1') -Force -Global
# Failure alerts: shares one implementation with pad-schedule / pad-sync / pad-deploy (the kind constants live in the module)
Import-Module (Join-Path $PSScriptRoot 'PadAlerts.psm1') -Force -Global
# robin normalisation / hashing / line-by-line comparison all live in RobinText.psm1:
# post-release verification (this script) and the -VerifyCanvas canvas readback (PadDesigner) must use one rule set
# -Global is required: Invoke-Pester in stage 1 runs in its own scope, which is torn down afterwards,
# so functions from a plain import are no longer reachable (Get-RobinHash would not be found).
# It must come after PadFingerprint: PadFingerprint imports RobinText with -Force internally, and
# if RobinText were imported first that nested import would unload it from the global scope,
# leaving ConvertTo-NormalizedRobin / Get-RobinHash / Compare-RobinText all missing after dot-sourcing.
Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global


# Local definition-copy location and identity resolution for a released flow moved into PadFingerprint.psm1 (single implementation):
#   Get-FlowGuidFromLogPath / Find-LatestFlowRun / Find-WorkspaceRobin all come from the module;
#   their names are unchanged and pad-release is only a caller.

# Manifest appending and version snapshots are provided by PublishHistory.psm1 (shared with pad-rollback.ps1)
# Stage 1: test summary. pytest counts are parsed from passed/failed; Pester 3.4 is counted from the -PassThru result objects
function Get-TestSummary([string]$RepoRoot, [string]$PythonExe) {
    $summary = [ordered]@{ pytestPassed = 0; pytestFailed = 0; pesterPassed = 0; pesterFailed = 0 }
    $testsDir = Join-Path $RepoRoot 'tests'

    Log "running pytest: $testsDir"
    # Do not truncate the output with Select-Object -First (it kills the child process early); Out-String collects it all
    $out = & $PythonExe -m pytest $testsDir -q 2>&1 | Out-String
    $m = [regex]::Match($out, '(\d+) passed'); if ($m.Success) { $summary.pytestPassed = [int]$m.Groups[1].Value }
    $m = [regex]::Match($out, '(\d+) failed'); if ($m.Success) { $summary.pytestFailed = [int]$m.Groups[1].Value }
    if ($LASTEXITCODE -ne 0 -and $summary.pytestFailed -eq 0) { $summary.pytestFailed = -1 }  # A non-assertion failure (e.g. an interpreter error)

    foreach ($f in (Get-ChildItem $testsDir -Filter '*.Tests.ps1' -ErrorAction SilentlyContinue)) {
        Log "running Pester: $($f.Name)"
        $r = Invoke-Pester -Script $f.FullName -PassThru
        $items = @()
        if ($r -and $r.PSObject.Properties['TestResult'] -and $r.TestResult) { $items = @($r.TestResult) }
        if ($items.Count -gt 0) {
            foreach ($t in $items) {
                if (($t.PSObject.Properties['Passed'] -and $t.Passed) -or ($t.PSObject.Properties['Result'] -and $t.Result -eq 'Passed')) {
                    $summary.pesterPassed++
                } else { $summary.pesterFailed++ }
            }
        } elseif ($r -and $r.PSObject.Properties['PassedCount']) {
            # Fallback: some Pester versions only expose count properties
            $summary.pesterPassed += $r.PassedCount
            $summary.pesterFailed += $r.FailedCount
        }
    }
    return $summary
}

# Call the pad-deploy child process and parse PAD_DEPLOY_RESULT (the last line)
# Note: PS 5.1 hashtable splatting does not work for an exe, so the argument array is built explicitly
function Invoke-Deploy([string]$SrcRobin, [string]$CfgFile, [string]$Flow, [string]$Schema,
                       [int]$TimeoutSec, [string]$Acceptance, [switch]$DryRunMode, [switch]$Prod, [switch]$NoConfirm, [switch]$PublishOnlyMode) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:DeployPath,
        '-SourceRobin', $SrcRobin, '-ConfigFile', $CfgFile, '-FlowName', $Flow,
        '-RunTimeoutSec', $TimeoutSec)
    if ($Schema) { $argList += @('-SchemaFile', $Schema) }
    if ($Acceptance) { $argList += @('-AcceptanceFile', $Acceptance) }
    if ($PublishOnlyMode) { $argList += '-PublishOnly' }
    if ($DryRunMode) { $argList += '-DryRun' }
    if ($Prod) { $argList += '-AllowProd' }
    if ($NoConfirm) { $argList += '-SkipConfirm' }
    $tmp = Join-Path $env:TEMP ("pad-release-" + [guid]::NewGuid().ToString('N') + ".log")
    & powershell @argList > $tmp 2>&1
    $json = Read-ChildResult -Name 'DEPLOY' `
        -Lines ([IO.File]::ReadAllLines($tmp, [Text.Encoding]::UTF8)) `
        -Logger { param($m) Write-Host "[release] $m" }
    if (-not $json) { throw "pad-deploy produced no PAD_DEPLOY_RESULT output (log: $tmp)" }
    return $json
}

# Approval fingerprint: bind "the three things being released this time" into one verifiable identifier
# The dialog shows short hashes; they are recomputed right before the real release, and any change in between aborts
function Get-ApprovalFingerprint([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    # The hashing algorithm is provided by PadFingerprint; this script no longer implements its own copy
    return (Get-FingerprintParts $RobinPath $ConfigPath $AcceptancePath)
}

# Show only the first 8 characters of each hash: enough for a human check without flooding the output
function Format-ApprovalFingerprint($Fp) {
    if (-not $Fp) { return '(none)' }
    $parts = @()
    foreach ($k in $Fp.Keys) {
        if ($Fp[$k]) { $parts += ('{0}={1}' -f $k, $Fp[$k].Substring(0, 8)) }
    }
    if ($parts.Count -eq 0) { return '(none)' }
    return ($parts -join ' ')
}

# ═══ Main flow ═══
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; stage = 'init'; flow = $FlowName; dryRun = [bool]$DryRun
        sourceRobin = $SourceRobin; deployedRobin = $null; sha256 = $null; replacedCount = 0
        flowGuid = $null; flowVersionBefore = $null; flowVersionAfter = $null
        runId = $null; runStatus = $null; hashMatch = $null; snapshotPath = $null
        acceptanceFile = $null; acceptance = $null
        fingerprint = $null; fingerprintBaseline = $null
        tests = $null; manifestPath = $null
        warnings = @(); errors = @()
    }
    try {
        if (-not $FlowName) { throw 'missing -FlowName (not Mandatory so Pester can dot-source this script)' }
        if (-not (Test-Path $script:DeployPath)) { throw "pad-deploy.ps1 not found" }
        # No longer default to a particular business flow: derive from -FlowName first and demand an explicit value when derivation fails
        if (-not $SourceRobin) {
            $guess = Join-Path $script:RepoRoot ("business\flows\{0}.robin" -f $FlowName)
            if (Test-Path -LiteralPath $guess) {
                $SourceRobin = $guess
            } else {
                throw "E_SOURCE_ROBIN_REQUIRED: -SourceRobin not provided and the name-derived path was not found: $guess; specify it with -SourceRobin"
            }
        }
        if (-not $ConfigFile) {
            $guess = Join-Path $script:RepoRoot ("business\config\{0}.json" -f $FlowName)
            if (Test-Path -LiteralPath $guess) {
                $ConfigFile = $guess
            } else {
                throw "E_CONFIG_REQUIRED: -ConfigFile not provided and the name-derived path was not found: $guess; specify it with -ConfigFile"
            }
        }
        $result.sourceRobin = $SourceRobin
        if (-not (Test-Path $SourceRobin)) { throw ".robin not found: $SourceRobin" }
        # Acceptance criteria default to the same-named <flow>.acceptance.json (next to flow.json)
        if (-not $AcceptanceFile) {
            $candidate = [IO.Path]::ChangeExtension($SourceRobin, '.acceptance.json')
            if (Test-Path $candidate) { $AcceptanceFile = $candidate }
        }
        $result.acceptanceFile = $AcceptanceFile
        if ($AcceptanceFile -and -not (Test-Path $AcceptanceFile)) {
            throw "acceptance criteria file not found: $AcceptanceFile"
        }
        if ($AcceptanceFile) { $AcceptanceFile = (Resolve-Path -LiteralPath $AcceptanceFile).Path }
        $result.acceptanceFile = $AcceptanceFile
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw 'Safety fuse: only PAD_SYNC_TEST may be released by default. Releasing a production flow requires explicit -AllowProd.'
        }

        # ── Stage 1: test summary ──
        if ($SkipTests) {
            $result.tests = [ordered]@{ skipped = $true }
            $result.warnings += 'test summary skipped (-SkipTests)'
            Log 'tests skipped (-SkipTests)'
        } else {
            $result.stage = 'tests'
            $result.tests = Get-TestSummary $script:RepoRoot $PythonExe
            Log ("test summary: pytest {0} passed/{1} failed; Pester {2} passed/{3} failed" -f `
                $result.tests.pytestPassed, $result.tests.pytestFailed, $result.tests.pesterPassed, $result.tests.pesterFailed)
            if ($result.tests.pytestFailed -ne 0 -or $result.tests.pesterFailed -ne 0) {
                throw 'tests are not all green; release aborted'
            }
        }

        # ── Stage 2: validation + variable substitution (DryRun, never touches PAD) ──
        # Invoke-Pester unloads the modules it loaded when it finishes (including RobinText above),
        # so they must be imported again here; otherwise the hash step reports Get-RobinHash as missing
        Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force -Global
        Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force -Global
        $result.stage = 'deploy-dryrun'
        $dry = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec -DryRunMode -Prod:$AllowProd
        if (-not $dry.ok) { throw ("validation/substitution failed: " + (@($dry.errors) -join '; ')) }
        $result.deployedRobin = [string]$dry.deployedRobinPath
        $result.replacedCount = [int]$dry.replacedCount
        $deployedText = [IO.File]::ReadAllText($result.deployedRobin, [Text.Encoding]::UTF8)
        $result.sha256 = Get-RobinHash $deployedText
        Log "substitution complete: $($result.replacedCount) placeholders; content hash $($result.sha256.Substring(0,12))..."

        # ── Stage 3: pre-release snapshot (flow GUID + current cloud version) ──
        $result.stage = 'snapshot'
        $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
        $workspaceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Workspace'
        $before = Find-LatestFlowRun $scriptsRoot $FlowName
        if ($before) {
            $result.flowGuid = $before.flowGuid
            $result.flowVersionBefore = $before.flowVersion
            Log "current cloud version: $($before.flowVersion) (latest run $($before.startTime), $($before.status))"
        } else {
            $result.warnings += 'flow not found in the local run history (it may never have run); the pre-release snapshot is empty'
            Log 'no historical run record found; the pre-release snapshot is empty'
        }

        if ($DryRun) {
            # DryRun: stop here; no confirmation, no release, no manifest
            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
            Log '[DryRun] tests + validation + substitution + snapshot completed; nothing was released'
        } else {
            # ── Stage 4: user confirmation (once, with the test summary and the side effects) ──
            $result.stage = 'confirm'
            $t = $result.tests
            $testText = $(if ($t.skipped) { 'skipped' } else { "pytest $($t.pytestPassed) passed/$($t.pytestFailed) failed; Pester $($t.pesterPassed) passed/$($t.pesterFailed) failed" })
            $acceptText = $(if ($AcceptanceFile) { "acceptance criteria: $([IO.Path]::GetFileName($AcceptanceFile))`n" } else { '' })
            $runNote = $(if ($PublishOnly) { 'This release does not trigger a run.' } else { 'After release a real run is triggered immediately via URL (it sends and receives real email and operates SAP).' })
            # Approval binding: what the dialog shows is exactly the three items about to be released, rechecked once before releasing
            $result.fingerprint = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            $fpText = Format-ApprovalFingerprint $result.fingerprint
            $msg = "Target flow: $FlowName`nTest summary: $testText`n$($acceptText)Replaced variables: $($result.replacedCount)`nContent hash: $($result.sha256.Substring(0,12))...`nApproval fingerprint: $fpText`nCurrent cloud version: $($result.flowVersionBefore)`n`nPrerequisite: this flow is already open in the PAD designer.`nNote: $runNote`n`nRelease now?"
            & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ConfirmPath -Title 'Release confirmation' -Msg $msg
            if ($LASTEXITCODE -ne 0) { throw 'user cancelled the release' }
            Log 'user confirmed the release'
            $fpNow = Get-ApprovalFingerprint $result.sourceRobin $ConfigFile $result.acceptanceFile
            if (($fpNow | ConvertTo-Json -Compress) -ne ($result.fingerprint | ConvertTo-Json -Compress)) {
                throw 'robin/config/acceptance changed after confirmation; release again and confirm again'
            }

            # ── Stage 5: real release (inject -> publish -> URL trigger -> collect) ──
            $result.stage = 'publish'
            $deployStartUtc = [datetime]::UtcNow
            $rel = Invoke-Deploy $SourceRobin $ConfigFile $FlowName $SchemaFile $RunTimeoutSec $AcceptanceFile -Prod:$AllowProd -NoConfirm -PublishOnlyMode:$PublishOnly
            if (-not $rel.ok) { throw ("release or verification run failed: " + (@($rel.errors) -join '; ')) }
            $result.runStatus = [string]$rel.runResult.status
            $result.runId = [string]$rel.runResult.runId
            $result.acceptance = $rel.runResult.acceptance
            if ($PublishOnly) { Log 'release complete (-PublishOnly, no run was triggered)' }
            else { Log "release complete; verification run status: $($result.runStatus)" }

            # ── Stage 6: post-release verification ──
            $result.stage = 'verify'
            # 6a) Run-history check: only needed in "publish and run" mode; publish-only mode skips it
            if (-not $PublishOnly) {
                $ids = Get-FlowGuidFromLogPath ([string]$rel.runResult.logPath)
                if ($ids) { $result.flowGuid = $ids.flowGuid; $result.runId = $ids.runId }
                if (-not $result.flowGuid) { throw 'cannot determine the flow GUID; post-release verification aborted' }
                $runDefPath = Join-Path (Split-Path -Parent ([string]$rel.runResult.logPath)) 'RunDefinition.json'
                if (Test-Path $runDefPath) {
                    $rd = [IO.File]::ReadAllText($runDefPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $result.flowVersionAfter = $(if ($rd.diagnosticInfo) { [string]$rd.diagnosticInfo.flowVersion } else { $null })
                    $runStartUtc = [datetime]::Parse([string]$rd.startTime).ToUniversalTime()
                    # Allow a 2-minute clock skew so a slight offset between the local and cloud clocks is not misjudged
                    if ($runStartUtc -lt $deployStartUtc.AddMinutes(-2)) {
                        throw "cloud history check failed: this run has startTime=$($rd.startTime), earlier than the release time"
                    }
                    if ([string]$rd.status -ne 'Succeeded') { throw "cloud history check failed: run status $($rd.status)" }
                    Log "cloud history check passed: flowVersion=$($result.flowVersionAfter), startTime=$($rd.startTime)"
                } else {
                    $result.warnings += 'RunDefinition.json for this run was not found; skipping the flowVersion check'
                }
            }
            if (-not $result.flowGuid) { throw 'cannot determine the flow GUID; post-release verification aborted' }
            # 6b) The published version's hash matches the canvas (the injected content)
            # Workspace is a local cache and may lag behind the cloud; wait up to 60 seconds for this revision to land
            $wsRobin = $null
            $swWs = [Diagnostics.Stopwatch]::StartNew()
            while ($swWs.Elapsed.TotalSeconds -lt 60) {
                $wsRobin = Find-WorkspaceRobin $workspaceRoot $result.flowGuid $result.runId $deployStartUtc
                if ($wsRobin) { break }
                Start-Sleep -Seconds 3
            }
            if (-not $wsRobin) {
                throw "no published definition for this release (runId=$($result.runId)) in Workspace (flowGuid=$($result.flowGuid)); will not fall back to the latest one"
            }
            $wsStale = ((Get-Item $wsRobin).LastWriteTime.ToUniversalTime() -lt $deployStartUtc.AddMinutes(-2))
            if ($wsStale) {
                if ($PublishOnly) {
                    # Publish-only mode: the cloud is already published (the console's modifiedOn is updated), so a stale local cache must not be judged a failure
                    $result.warnings += 'Workspace cache was not refreshed; skipping hash verification (published state takes precedence)'
                    Log 'warning: Workspace cache was not refreshed; skipping hash verification'
                } else {
                    throw "published definition copy was not updated ($wsRobin is older than this release); cannot confirm the hash matches"
                }
            } else {
                $wsText = [IO.File]::ReadAllText($wsRobin, [Text.Encoding]::UTF8)
                $cmp = Compare-RobinText $deployedText $wsText
                $result.hashMatch = $cmp.match
                if (-not $cmp.match) {
                    # Exception carrying Data['code']: alerts are classified by code, not by parsing message text
                    $msg = "published version differs from the canvas: line $($cmp.diffIndex)`n  canvas: $($cmp.lineA)`n  cloud: $($cmp.lineB)"
                    $ex = [System.Exception]::new($msg)
                    $ex.Data['code'] = 'RELEASE_CANVAS_MISMATCH'
                    throw $ex
                }
                Log "hash check passed: published version matches the injected content ($($result.sha256.Substring(0,12))...)"
            }

            # ── Snapshot archiving: a successful release freezes one finished copy for pad-rollback.ps1 to re-release ──
            $snapshotsRoot = Join-Path $script:RepoRoot 'business\snapshots'
            $result.snapshotPath = Save-ReleaseSnapshot $snapshotsRoot $FlowName $result.deployedRobin $result.sha256 ([datetime]::Now)
            Log "snapshot archived: $($result.snapshotPath)"
            # Keep only the latest 20 snapshots so they cannot grow without bound
            $removed = @(Remove-OldReleaseSnapshots (Split-Path -Parent $result.snapshotPath) 20)
            if ($removed.Count -gt 0) { Log "removed $($removed.Count) old snapshots (keeping the latest 20)" }

            # ── Fingerprint baseline: on success, freeze the hash of "this definition + config + acceptance" for the admission comparison ──
            # A failed write does not undo a successful release, but it must raise an explicit warning
            try {
                $fpPath = Get-FingerprintBaselinePath $script:RepoRoot $FlowName
                $fpBase = New-FingerprintBaseline -FlowName $FlowName -FlowGuid $result.flowGuid `
                    -EnvironmentId (Get-PadEnvironmentId) -SourceRobin $result.sourceRobin `
                    -WorkspaceRobin $wsRobin -ConfigPath $ConfigFile -AcceptancePath $AcceptanceFile
                [void](Write-FingerprintBaseline $fpPath $fpBase)
                $result.fingerprintBaseline = $fpPath
                Log "fingerprint baseline updated: $fpPath"
            } catch {
                $result.warnings += "fingerprint baseline write failed: $($_.Exception.Message)"
                Log "warning: fingerprint baseline write failed ($($_.Exception.Message))"
            }

            $result.ok = $true; $result.stage = 'done'; $exitCode = 0
        }
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "release pipeline failed at [$($result.stage)]: $($_.Exception.Message)"
        # DryRun never touches PAD, so failures write no alert and do not pollute the real operations records
        if (-not $DryRun) {
            $ak = Get-AlertKindConstants
            $msg = $_.Exception.Message
            $kind = if ([string]$_.Exception.Data['code'] -eq 'RELEASE_CANVAS_MISMATCH') { $ak.ReleaseCanvasMismatch }
                elseif ($result.stage -in @('publish', 'verify')) { $ak.DeployPublishFailed }
                else { $ak.DeployPrecheckFailed }
            if (Test-Path (Join-Path $script:RepoRoot 'tools')) {
                try {
                    $r = Write-RunAlert -FlowName $result.flow -ExitCode 1 -Stage $result.stage `
                        -Status $result.runStatus -Kind $kind -RunId ([string]$result.runId) `
                        -Dir (Join-Path $script:RepoRoot 'business\logs') `
                        -Note "Release pipeline failed at stage=$($result.stage): $msg. Next step: fix it as prompted and release again; nothing was retried automatically."
                    if ($r -and -not $r.skipped) { Log "failure alert written: $($r.path)" }
                } catch { Log "failed to write the alert (does not affect the release result): $($_.Exception.Message)" }
            }
        }
    }
    finally {
        # ── Stage 7: manifest (not written for DryRun; both success and failure are recorded for rollback and audit) ──
        if (-not $DryRun -and $result.stage -ne 'init') {
            $manifestPath = Join-Path $script:RepoRoot 'business\manifest.jsonl'
            $entry = [ordered]@{
                ts = [datetime]::UtcNow.ToString('o'); type = 'release'
                flow = $result.flow; flowGuid = $result.flowGuid
                sourceRobin = $result.sourceRobin; deployedRobin = $result.deployedRobin
                sha256 = $result.sha256; replacedCount = $result.replacedCount
                snapshotPath = $result.snapshotPath
                tests = $result.tests
                flowVersionBefore = $result.flowVersionBefore; flowVersionAfter = $result.flowVersionAfter
                runId = $result.runId; runStatus = $result.runStatus; hashMatch = $result.hashMatch
                fingerprint = $result.fingerprint
                fingerprintBaseline = $result.fingerprintBaseline
                ok = $result.ok; errors = $result.errors; warnings = @($result.warnings)
            }
            try {
                Add-ManifestEntry $manifestPath $entry
                $result.manifestPath = $manifestPath
                Log "manifest appended: $manifestPath"
                # Release records are kept forever; only expired run records are pruned here
                [void](Remove-OldManifestEntries $manifestPath -KeepDays 90)
            }
            catch { $result.warnings += "manifest write failed: $($_.Exception.Message)" }
        }
        Write-Output ("PAD_RELEASE_RESULT=" + ($result | ConvertTo-Json -Depth 10 -Compress))
    }
    exit $exitCode
}
