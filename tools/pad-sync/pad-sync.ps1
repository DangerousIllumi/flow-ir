<#
pad-sync.ps1 — inject a .robin into the PAD designer, run it, and collect the results

Purpose:
  Get an agent-generated .robin into the PAD canvas for real, run it once, and return the failing
  action (error code and message) as structured data so the agent can analyse and fix it automatically.

  All designer interaction lives in PadDesigner.psm1 and telemetry parsing lives in PadTelemetry.psm1;
  this script only orchestrates: read file → inject → publish (optional) → run → collect results.

Usage:
  # Full closed loop: inject → publish → run → collect (skips saving a draft; the publish button uses the current canvas)
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RobinFile "C:\temp\flow.robin"

  # Run an already published flow and collect the results
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RunOnly

  # Inject and read the canvas back to confirm the paste was complete
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RobinFile "C:\temp\flow.robin" -VerifyCanvas -InjectOnly

Parameters:
  -FlowName        PAD flow name (the matching designer edit window must already be open)
  -RobinFile       Path to the .robin text file; may be omitted with -RunOnly
  -Replace         Clear the actions currently on the canvas before injecting (default is append)
  -VerifyCanvas    After injecting, copy the canvas content back and compare it line by line
                   (normalised) against the source .robin; abort and report the first difference
                   when only part of it was pasted
  -LocalRun        Used during testing: click the designer's Run button to run the current canvas
                   without publishing to the cloud
  -NoPublish       Same as -LocalRun (legacy parameter name kept)
  -InjectOnly      Inject and verify the canvas only; do not publish or run
  -SkipStaticCheck Skip the check.js static validation before injecting (emergency debugging only)
  -AcceptanceFile  Check the artifacts against acceptance criteria after the run (requires -ConfigFile)
  -ConfigFile      Deployment config used to substitute the {{KEY}} placeholders in the acceptance criteria
  -RunId           Custom run id (makes the log directory easier to find; generated automatically by default)
  -RunTimeoutSec   Maximum seconds to wait for the flow to finish (default 300)
  -ManifestPath    Orchestration history file (default business\manifest.jsonl; nothing is written when outside the repo)
  -NoManifest      Do not write a manifest entry for this run (for debugging)

Output:
  The last line on stdout is PAD_SYNC_RESULT=<JSON>, with the fields
  ok / stage / runId / status / actions / failedAction / error / logPath / canvasVerified
  / needsHumanConfirm / dialogTitle
  ok may be null: when neither Actions.log nor Console has evidence for this run the outcome is
  "unknown", not a failure
  Exit codes: 0 success or unknown / 1 failure / 3 stopped at a manual-confirmation dialog / 4 timed out waiting for the lock

Prerequisites:
  1. PAD console is logged in and the target flow is published (a draft that was never published cannot be run by URL)
  2. PAD designer has the edit window for that flow open
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowName,
    [string]$RobinFile,
    [string]$RunId,
    [int]$RunTimeoutSec = 300,
    [switch]$Replace,
    [switch]$NoPublish,
    [switch]$RunOnly,
    [switch]$InjectOnly,
    [switch]$LocalRun,
    # Publish to the cloud only, do not trigger a run (after publishing only the hash is verified; no run status or acceptance checks)
    [switch]$PublishOnly,
    [switch]$AllowProd,
    [switch]$VerifyCanvas,
    # Non-interactive (scheduled task): do not click a manual-confirmation dialog automatically; record needs-human-confirm and exit with code 3
    [switch]$NonInteractive,
    # Force the static check before injecting; -SkipStaticCheck is for emergency debugging only
    [switch]$SkipStaticCheck,
    # Admission gate: enforce = block on failure (default) / report = warn only / off = do not run
    [ValidateSet('report', 'enforce', 'off')][string]$AdmitMode = 'enforce',
    # flow.json; when omitted, derived automatically from the sibling file of -AcceptanceFile
    [string]$FlowFile,
    # When -FlowFile is not given, derive it from -FlowName under business\flows (pad_flow_name first, then file name / name)
    # Off by default: the mechanism is built and verified first and only wired into scheduled tasks after confirmation, so existing tasks do not change behaviour abruptly
    [switch]$DeriveFlow,
    # Check the artifacts against acceptance criteria after the run (requires -ConfigFile)
    [string]$AcceptanceFile,
    [string]$ConfigFile,
    [string]$ManifestPath,
    [switch]$NoManifest,
    # Maximum seconds to wait for PAD to become idle: on timeout exit with code 4 instead of barging in
    # (this stops two scheduled tasks from fighting over the same PAD)
    # Default 90 minutes, sized from the worst-case single lock hold:
    #   AI reconciliation flow: wait up to 60 min for the report mail + ~3 min for reconciliation/SAP ≈ 63 min
    #   Long SAP download: up to ~30 min + ~10–15 min of follow-up processing ≈ 40–45 min
    #   Take the larger value, 63 min, and leave 27 min of headroom for SAP login, restarts, machine stalls
    [int]$LockWaitSec = 5400,
    # Skip the cross-process mutex (only use when you are sure no other task runs concurrently)
    [switch]$NoLock,
    # Central runtime config: only fills in a RunTimeoutSec that was not given explicitly; explicit parameters win
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# Publish-only mode is mutually exclusive with the "do not inject / do not publish" options, otherwise a run that never published would still report Published
if ($PublishOnly -and ($RunOnly -or $LocalRun -or $InjectOnly -or $NoPublish)) {
    throw '-PublishOnly cannot be combined with -RunOnly / -LocalRun / -InjectOnly / -NoPublish'
}

# Production safety fuse: by default only the PAD_SYNC_TEST flow may be touched
if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
    throw 'safety fuse: pad-sync only operates on PAD_SYNC_TEST by default. For a production flow, add -AllowProd explicitly.'
}

# Single implementation of designer interaction + telemetry parsing
# -DisableNameChecking: the module has non-standard verbs such as Focus-/Click-; suppressing the warning keeps the output the agent parses clean
Import-Module (Join-Path $PSScriptRoot 'PadDesigner.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PadTelemetry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PadAcceptance.psm1') -Force
# Failure alerts: shared with pad-schedule (one single implementation of the kind values and dedup rules)
Import-Module (Join-Path $PSScriptRoot 'PadAlerts.psm1') -Force
# Central config: only read when -ConfigPath is passed explicitly; a missing key, a missing path or a type error is always a hard failure
Import-Module (Join-Path $PSScriptRoot 'PadConfig.psm1') -Force
if ($ConfigPath) {
    $runtime = Get-PadRuntimeConfig -ConfigPath $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('RunTimeoutSec')) { $RunTimeoutSec = $runtime.RunTimeoutSec }
}

# Orchestration history file: when the script sits in tools\pad-sync inside the repo, default to business\manifest.jsonl;
# when it is deployed on its own outside the repo, write nothing so nothing lands at the drive root
if (-not $ManifestPath -and -not $NoManifest) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (Test-Path (Join-Path $repoRoot 'tools')) { $ManifestPath = Join-Path $repoRoot 'business\manifest.jsonl' }
}

$script:Result = [ordered]@{
    ok = $false; stage = 'init'; flow = $FlowName; runId = $null
    status = $null; actions = $null; failedAction = $null; error = $null; logPath = $null
    canvasVerified = $null; warnings = @(); lockWaitSec = 0
    # Set to true when a non-interactive run stops at a manual-confirmation dialog; ok stays $null (unknown ≠ failure)
    needsHumanConfirm = $false; dialogTitle = $null; evidence = $null
    # Trigger-class failures: the URL was called but the flow never started / the flow name does not resolve to a flowId; used by the scheduler for graded alerts
    triggerFailed = $false; triggerReason = $null; runTimeout = $false
}

# ── Cross-process mutex: only one flow may occupy PAD at a time ──────────────────
# Injecting / publishing / running all count as occupying it. Implementation in PadLock.psm1:
# a named Mutex provides the exclusion (it is released automatically when the process is killed, so a stale lock cannot happen),
# and a lock file is written once, only after winning the lock (holder flow / PID / start time), so a waiting run can
# print who is holding PAD; the file takes no part in the mutual exclusion and carries no heartbeat.
Import-Module (Join-Path $PSScriptRoot 'PadLock.psm1') -Force

$script:LockTimedOut = $false

function Write-Log([string]$msg) {
    Write-Host "[pad-sync] $msg"
}

# Admission gate (runs before injecting and before running)
#   report  = the explicitly declared "warn only" mode: record warnings on refusal and continue
#   enforce = fail-closed: anything that cannot prove "passed" blocks injection and running (default)
# Scheduled tasks go through -RunOnly, so the gate must live outside that branch; otherwise the nightly run would bypass it
#
# The only basis for allowing a run: pad-admit prints PAD_ADMIT_RESULT and its summary satisfies
#   fail=0 and ask=0 and pass>0 (warn does not block)
# Missing script / non-zero exit / no result line / malformed JSON are all treated as "not allowed to proceed"
# (absence of an error is not a pass)
# A missing flow.json means "admission not enabled"; an explicit warning is recorded so it is not mistaken for a pass
function Invoke-AdmitGate([string]$FlowFileArg, [string]$ConfigFileArg, [string]$AcceptanceFileArg) {
    if ($AdmitMode -eq 'off') {
        Write-Log 'admit gate explicitly disabled (-AdmitMode off); nothing was checked'
        return $true
    }
    $flowPath = $FlowFileArg
    if (-not $flowPath -and $AcceptanceFileArg) {
        $guess = $AcceptanceFileArg -replace '\.acceptance\.json$', '.json'
        if (Test-Path -LiteralPath $guess) { $flowPath = $guess }
    }
    if (-not $flowPath -and -not $DeriveFlow) {
        Write-Log 'no flow.json provided; the admit gate did not apply (nothing was checked)'
        $script:Result.warnings += 'admit gate not applicable: flow.json is missing'
        return $true
    }

    $script:Result.stage = 'admit'
    $admitScript = Join-Path $PSScriptRoot 'pad-admit.ps1'
    if (-not (Test-Path -LiteralPath $admitScript)) {
        throw 'admit gate refused to run: the admit script is missing (pad-admit.ps1)'
    }
    $admitArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        $admitScript, '-Unattended')
    if ($ConfigFileArg) { $admitArgs += @('-ConfigFile', $ConfigFileArg) }
    if ($AcceptanceFileArg) { $admitArgs += @('-AcceptanceFile', $AcceptanceFileArg) }
    if ($flowPath) {
        $admitArgs += @('-FlowFile', $flowPath)
    } else {
        # Derivation was explicitly enabled: the gate matches pad_flow_name → file name / name uniquely; multiple matches raise ADMIT_AMBIGUOUS_FLOW
        $admitArgs += @('-FlowName', $FlowName)
    }
    $admitOut = & powershell @admitArgs *>&1 | Out-String
    $admitExit = $LASTEXITCODE

    $decision = Get-AdmitGateDecision -ExitCode $admitExit -Output $admitOut -ScriptPath $admitScript
    if (-not $decision.allow) {
        $msg = "admit gate refused to run ($($decision.reason)): $($decision.message)"
        if ($AdmitMode -eq 'enforce') { throw "$msg (enforce mode, fail-closed)" }
        Write-Log "$msg (report mode; continuing after this notice)"
        $script:Result.warnings += $msg
        return $true
    }
    Write-Log $decision.message
    if ($decision.summary -and [int]$decision.summary.warn -gt 0) {
        $script:Result.warnings += "admit warnings: $([int]$decision.summary.warn) item(s) (non-blocking)"
    }
    return $true
}

# ── Collection (designer-local run): read the robot telemetry log ──────────────────
# "Run" inside the designer does not write Console\Scripts\<flow>\Runs\<runId>\Actions.log;
# it creates a new timestamped RobinRobot.log (JSON Lines) under DataCollection instead.
# So this run is tied to "the newest file created after the trigger"; parsing is left to PadTelemetry
function Get-DesignerRunResult([datetime]$since, [string]$LogPath) {
    # When the wait phase has already pinned the telemetry log for this run, use it directly,
    # so "newest file after the trigger" cannot accidentally pick up another flow running concurrently on the same machine
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        return (Get-RobinTelemetryFromFile -Path $LogPath)
    }
    $dc = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'
    $log = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        $log = Find-RobinTelemetryLog -DataCollectionDir $dc -Since $since
        if ($log) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $log) { return $null }
    return (Get-RobinTelemetryFromFile -Path $log.FullName)
}

# ── Collection: locate the Runs directory and parse Actions.log ────────────────────
function Get-PadRunResult([string]$rid, [string]$RunDir) {
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    # Use the run directory pinned by the wait phase, when there is one
    $dir = $null
    if ($RunDir -and (Test-Path -LiteralPath $RunDir)) { $dir = Get-Item -LiteralPath $RunDir }
    if (-not $dir -and $rid) {
        # Look up exactly by the runId used for this trigger: PAD uses the runId from the URL as the run directory name.
        # Reuse PadDesigner's Resolve-PadRunDir (same rule as the wait phase),
        # never degrade to "newest directory after the trigger": with concurrent runs on one machine that belongs to someone else
        $dir = Resolve-PadRunDir -ScriptsRoot $base -RunId $rid
    }
    if (-not $dir) { return $null }

    $logPath = Join-Path $dir.FullName 'Actions.log'
    # The log may only be flushed to disk after the flow ends; wait at most 30 seconds
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 0) { break }
        Start-Sleep -Milliseconds 700
    }

    $status = $null
    $rdPath = Join-Path $dir.FullName 'RunDefinition.json'
    if (Test-Path $rdPath) {
        # This must be read as UTF-8 too, otherwise Chinese failed-action names break JSON parsing;
        # read in shared mode so PAD's write handle cannot block us while the flow is still running
        try {
            $rdText = Read-TextShared $rdPath
            $status = ($rdText | ConvertFrom-Json).status
        } catch { Write-Log "failed to parse RunDefinition.json: $($_.Exception.Message)" }
    }

    $actions = @()
    $failed = $null
    $summary = $null
    if (Test-Path $logPath) {
        # Actions.log is UTF-8 (PowerShell 5.1's Get-Content decodes as ANSI by default, which mangles it and breaks the JSON);
        # PAD holds an exclusive write handle while running, so reads must be shared, otherwise ReadAllLines throws "file is in use by another process"
        $logText = ''
        try { $logText = Read-TextShared $logPath } catch {
            Write-Log "Actions.log is not readable yet: $($_.Exception.Message)"
        }
        foreach ($line in ($logText -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            try { $j = $line | ConvertFrom-Json } catch { continue }
            # The last log line is the summary of the whole run (no index); keep it separately and skip it
            if ($null -eq $j.index -or -not $j.status) {
                if ($j.workflow -and $j.status) { $summary = $j }
                continue
            }
            $act = [ordered]@{
                index = $j.index; name = $j.name; action = $j.systemActionName
                status = $j.status; functionName = $j.functionName
                inputs = @{}; outputs = @{}
            }
            if ($j.inputs) { foreach ($pr in $j.inputs.PSObject.Properties) { $act.inputs[$pr.Name] = $pr.Value.value } }
            if ($j.outputs) { foreach ($pr in $j.outputs.PSObject.Properties) { $act.outputs[$pr.Name] = $pr.Value.value } }
            if ($j.status -eq 'Failed' -and $j.error) {
                $act.error = [ordered]@{
                    code = $j.error.code
                    message = $j.error.message
                    correlationId = $j.error.correlationId
                }
                if (-not $failed) { $failed = $act }
            }
            $actions += $act
        }
    }
    if (-not $status -and $summary) { $status = $summary.status }
    return [ordered]@{ status = $status; actions = $actions; failed = $failed; logPath = $logPath }
}

# ── Main flow ────────────────────────────────────────────────────
try {
    if (-not $RunId) { $RunId = [Guid]::NewGuid().ToString() }
    $script:Result.runId = $RunId

    # Cross-process mutex: only one flow may occupy PAD at a time.
    # Done first (before admission and injection) so later arrivals queue here instead of two flows grabbing PAD at once
    if (-not $NoLock) {
        $script:Result.stage = 'lock'
        # The lock result and wait time come back in one call (ok/waitedSec); no separate status query is needed
        $lock = Enter-PadRunLock -FlowName $FlowName -WaitSec $LockWaitSec -Logger { param($m) Write-Log $m }
        $waited = $lock.waitedSec
        $script:Result.lockWaitSec = $waited
        if (-not $lock.ok) {
            $script:LockTimedOut = $true
            $info = Get-PadLockInfo
            $holder = if ($info) { "$($info.flow) (pid $($info.pid))" } else { 'unknown' }
            throw "timed out waiting for PAD to become free (${LockWaitSec}s); current holder: $holder. This run did not execute; retry later."
        }
        if ($waited -gt 0) { Write-Log "PAD is now free (waited $waited s)" }
    }

    # Admission gate: it also runs for RunOnly (scheduled tasks) so the nightly run cannot bypass it
    [void](Invoke-AdmitGate $FlowFile $ConfigFile $AcceptanceFile)

    if (-not $RunOnly) {
        if (-not $RobinFile -or -not (Test-Path $RobinFile)) { throw ".robin file not found: $RobinFile" }
        $text = [IO.File]::ReadAllText((Resolve-Path $RobinFile), [Text.Encoding]::UTF8)
        if (-not $text.Trim()) { throw '.robin file is empty' }

        # The admission gate already ran at the top of the main flow (RunOnly included); here we only do the static check
        # V-model G2: never enter the designer when the static check fails, so a broken script cannot pollute the canvas
        if (-not $SkipStaticCheck) {
            $script:Result.stage = 'static-check'
            $checkJs = Join-Path (Split-Path -Parent $PSScriptRoot) 'pad-robin\check.js'
            if (-not (Test-Path $checkJs)) { throw "static checker not found: $checkJs" }
            $checkOut = & node $checkJs (Resolve-Path $RobinFile).Path 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("static check failed (check.js exit code $LASTEXITCODE): " + (($checkOut | Out-String).Trim()))
            }
            Write-Log 'static check passed (check.js 0 errors)'
        }

        $script:Result.stage = 'find-designer'
        $win = Get-DesignerWindow -FlowName $FlowName
        if (-not $win) { throw "no PAD designer window is open for '$FlowName'; open that flow in PAD first" }

        $script:Result.stage = 'inject'
        $inj = Invoke-PadInject -Window $win -Text $text -Replace:$Replace -VerifyCanvas:$VerifyCanvas
        $afterCount = [int]$inj.actions
        if ($VerifyCanvas) { $script:Result.canvasVerified = [bool]$inj.verified }
        if ($afterCount -le 0) { throw 'canvas is empty after injection; injection failed' }
        Write-Log "injection done: $afterCount actions on the canvas"

        # Inject-only, no publish and no run: used to confirm the canvas really was updated
        if (-not $InjectOnly -and -not $NoPublish -and -not $LocalRun) {
            $script:Result.stage = 'publish'
            $win = Get-DesignerWindow -FlowName $FlowName
            # A normal publish takes under 3 minutes; exceeding that is abnormal (version conflict or service outage), so do not wait silently
            [void](Click-ToolButton $win 'PublishFlowButton')
            $published = Wait-PublishDone $win 300
            if (-not $published) {
                throw 'publish timed out: not finished within 300s. A common cause is a version conflict from the flow being edited elsewhere; close and reopen the flow, then retry.'
            }
            Write-Log 'publish done'
        }
    }

    if ($InjectOnly) {
        Write-Log 'injected; skipping the run (-InjectOnly)'
        $script:Result.ok = $true
        $script:Result.status = 'Injected'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } elseif ($PublishOnly) {
        # Save to the cloud only: stop right after publishing, do not trigger a URL run
        Write-Log 'published; skipping the run (-PublishOnly)'
        $script:Result.ok = $true
        $script:Result.status = 'Published'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } else {
        $script:Result.stage = 'run'
        $runStart = (Get-Date).AddSeconds(-5)
        # The wait phase pins this run by "the run log appearing on disk" and returns the directory / log path and the
        # terminal status; it no longer judges completion by "is the PAD.RobotV2 process still alive" (which misfires with concurrent runs)
        $runHint = $null
        try {
            $runHint = Invoke-PadRun -WorkflowName $FlowName -RunId $RunId -TimeoutSec $RunTimeoutSec `
                -Local:($LocalRun -or $NoPublish) -NonInteractive:$NonInteractive
        } catch {
            # A pre-trigger validation failure (flow name does not resolve to a flowId) counts as a trigger failure too; it gets its own classification but the exit code is still 1
            if ([string]$_.Exception.Data['code'] -eq 'TRIGGER_PREFLIGHT_FAILED') {
                $script:Result.triggerFailed = $true
                $script:Result.triggerReason = 'identity-mismatch'
            }
            throw
        }
        if (-not $runHint -or -not $runHint.evidence) {
            # It never started: an unresponsive protocol handler, a cancelled confirmation box or a blocking PAD error dialog all land here
            $script:Result.triggerFailed = $true
            $script:Result.triggerReason = 'no-evidence'
            $script:Result.error = [ordered]@{
                code = 'TRIGGER_NO_EVIDENCE'
                message = 'no log appeared for this run after triggering (protocol handler did not respond / flow name or flowId mismatch / PAD error)'
            }
            throw $script:Result.error.message
        }

        # A non-interactive run stopped at a manual-confirmation dialog (completion notice / manual confirmation etc.):
        # do not click it and do not kill the process; the dialog is left for a human. This run ends as needs-human-confirm
        # so the scheduler alerts immediately instead of hanging silently until the 180-minute timeout. ok stays $null (unknown ≠ failure)
        if ($runHint.evidence -eq 'human-confirm') {
            $script:Result.stage = 'needs-human-confirm'
            $script:Result.needsHumanConfirm = $true
            $script:Result.dialogTitle = $runHint.dialogTitle
            $script:Result.status = 'NeedsHumanConfirm'
            $script:Result.ok = $null
            $script:Result.evidence = 'human-confirm'
            $script:Result.logPath = $runHint.logPath
            $script:Result.warnings += "non-interactive run stopped at the manual-confirmation dialog '$($runHint.dialogTitle)'; the flow is still waiting for a manual click"
            Write-Log "run stopped at a manual-confirmation dialog `"$($runHint.dialogTitle)`": not clicking automatically; handle it manually and rerun"
        } elseif ($runHint.startupTimedOut -and -not $runHint.status) {
            # The run directory appeared but the robot never started: this used to fall through to Unknown → exit 0,
            # silently and without an alert. It now ends as trigger-failed (reason=no-robot): alert only, no retry
            $script:Result.stage = 'trigger'
            $script:Result.status = 'NotStarted'
            $script:Result.ok = $false
            $script:Result.triggerFailed = $true
            $script:Result.triggerReason = 'no-robot'
            $script:Result.logPath = $runHint.logPath
            $script:Result.error = [ordered]@{
                code = 'TRIGGER_NO_ROBOT'
                message = 'the trigger was accepted and a run directory appeared, but the robot did not start within the watch window (it may be stuck on a PAD error dialog or was cancelled)'
            }
        } elseif ($runHint.timedOut -and -not $runHint.status) {
            # RunTimeoutSec elapsed without a terminal status: alert as a run timeout instead of exiting silently as Unknown
            $script:Result.stage = 'run-timeout'
            $script:Result.status = 'RunTimeout'
            $script:Result.ok = $false
            $script:Result.runTimeout = $true
            $script:Result.logPath = $runHint.logPath
            $script:Result.error = [ordered]@{
                code = 'RUN_TIMEOUT'
                message = "waited more than $RunTimeoutSec s for the run to end and never got a terminal status"
            }
        } else {
        $script:Result.stage = 'collect'
        if ($LocalRun -or $NoPublish) {
            # Designer-local run: read the RobinRobot.log telemetry under DataCollection
            $res = Get-DesignerRunResult $runStart $runHint.logPath
            if (-not $res) {
                # The log is still being written by the robot process and cannot be read (or is genuinely missing):
                # end as Unknown without judging failure or throwing, the same rule used for Console evidence
                $script:Result.status = 'Unknown'
                $script:Result.ok = $null
                $script:Result.evidence = 'unknown'
                $script:Result.logPath = $runHint.logPath
                $script:Result.warnings += 'RobinRobot.log is temporarily unreadable or missing; evidence for this run is Unknown (not treated as a failure)'
                Write-Log 'RobinRobot.log is unreadable or missing; outcome recorded as Unknown (unknown is not failure)'
            } else {
                $script:Result.status = $res.status
                $script:Result.actions = $res.actions
                $script:Result.logPath = $res.logPath
                $script:Result.runId = $res.runId
                $script:Result.failedActions = $res.failedActions
                $script:Result.telemetry = $res.telemetry
                $script:Result.timedActions = $res.timedActions
                $script:Result.totalMs = $res.totalMs
                $script:Result.error = $res.error
                # Built-in actions (SET/IF/File etc.) have no action-level exception when they fail, so build one from the run-level error code
                if ($res.status -eq 'Failed' -and -not $script:Result.failedActions) {
                    $script:Result.failedAction = [ordered]@{ name = $null; error = $res.error }
                }
                $script:Result.ok = ($res.status -eq 'Succeeded')
            }
        } else {
            $res = Get-PadRunResult $RunId $runHint.runDir
            # PAD cleans up Actions.log after a run: when it is unavailable or the status is empty,
            # evidence must come from Console telemetry for this runId; never judge failure from a possibly empty runHint.status.
            # Evidence priority: Actions.log → the PadConsole event for this runId → Unknown (unknown ≠ failure)
            if (-not $res -or -not $res.status) {
                $console = Get-PadConsoleRunOutcome -RunId $RunId -Since $runStart
                if ($console -and $console.outcome -eq 'Succeeded') {
                    $res = [ordered]@{ status = 'Succeeded'; actions = @(); failed = $null; logPath = $console.logPath }
                    $script:Result.evidence = 'console'
                    Write-Log 'Actions.log unavailable: PadConsole telemetry says this run succeeded'
                } elseif ($console -and $console.outcome -eq 'Failed') {
                    $res = [ordered]@{
                        status = 'Failed'; actions = @(); logPath = $console.logPath
                        failed = [ordered]@{ name = $null; error = [ordered]@{
                            code = 'CONSOLE_RUN_FAILED'; message = "PadConsole recorded this run as failed ($($console.event))" } }
                    }
                    $script:Result.evidence = 'console'
                    Write-Log 'Actions.log unavailable: PadConsole telemetry says this run failed'
                } else {
                    $script:Result.status = 'Unknown'
                    $script:Result.ok = $null
                    $script:Result.evidence = 'unknown'
                    $script:Result.logPath = $runHint.logPath
                    if ($console -and $console.note) {
                        # The log is still being written by PAD and cannot be read: still record Unknown only; do not judge failure and do not send run-failed
                        $script:Result.warnings += $console.note
                        Write-Log $console.note
                    } else {
                        $script:Result.warnings += 'neither Actions.log nor PadConsole has evidence for this run; the result is unknown (not treated as a failure and no run-failed alert is sent)'
                        Write-Log 'no usable run evidence; outcome recorded as Unknown (unknown is not failure)'
                    }
                    # Must be cleared, otherwise the if ($res) below would overwrite 'Unknown' with $res.status (which may be $null)
                    $res = $null
                }
            }

            if ($res) {
                $script:Result.status = $res.status
                $script:Result.actions = $res.actions
                $script:Result.logPath = $res.logPath
                if ($res.failed) {
                    $script:Result.failedAction = $res.failed
                    $script:Result.error = $res.failed.error
                    $script:Result.ok = $false
                } elseif ($res.status -eq 'Succeeded') {
                    $script:Result.ok = $true
                } else {
                    $script:Result.ok = $null
                    if (-not $script:Result.evidence) { $script:Result.evidence = 'unknown' }
                }
            }
        }

        # V-model G6: a successful run does not mean the business result is correct; check the artifacts against the criteria
        if ($AcceptanceFile) {
            $script:Result.stage = 'acceptance'
            if (-not $ConfigFile) { throw '-AcceptanceFile requires -ConfigFile' }
            if (-not (Test-Path $AcceptanceFile)) { throw "acceptance spec not found: $AcceptanceFile" }
            $configMap = Get-AcceptanceConfig -Path $ConfigFile
            $acc = Test-AcceptanceFile -Path $AcceptanceFile -Config $configMap -Since $runStart
            $script:Result.acceptance = $acc
            Write-Log ("acceptance: pass {0} / fail {1} / skip {2}" -f $acc.passed, $acc.failed, $acc.skipped)
            if (-not $acc.ok) {
                $script:Result.ok = $false
                if (-not $script:Result.error) {
                    $script:Result.error = [ordered]@{ code = 'ACCEPTANCE_FAILED'; message = "acceptance failed: $($acc.failed) item(s)" }
                }
            }
        }
        $script:Result.stage = 'done'
        }
    }
}
catch {
    $script:Result.ok = $false
    # Trigger-class failures already set their classified error code before being thrown; only fill in the message here, never overwrite code
    $code = $null
    if ($script:Result.error -is [System.Collections.IDictionary]) {
        $code = $script:Result.error['code']
    } elseif ($script:Result.error) {
        $code = $script:Result.error.code
    }
    if ($code) {
        $script:Result.error = [ordered]@{ code = $code; message = $_.Exception.Message }
    } else {
        $script:Result.error = [ordered]@{ message = $_.Exception.Message }
    }
    Write-Log "failed at [$($script:Result.stage)]: $($_.Exception.Message)"
}

# ── Orchestration record: append one manifest line per run ──────────────────────
# No logging action is placed inside the PAD canvas; the orchestration layer keeps the run history.
# This runs before PAD_SYNC_RESULT and a failure only warns without interrupting, so the agent can always read the run result.
if (-not $NoManifest -and $ManifestPath) {
    $errCode = $null; $errMsg = $null
    $rawErr = $script:Result.error
    if ($rawErr -is [System.Collections.IDictionary]) {
        if ($rawErr.Contains('code')) { $errCode = $rawErr['code'] }
        if ($rawErr.Contains('message')) { $errMsg = $rawErr['message'] }
    } elseif ($rawErr) {
        $errCode = $rawErr.code; $errMsg = $rawErr.message
    }
    $runMode = 'publish'
    if ($RunOnly) { $runMode = 'run-only' }
    elseif ($InjectOnly) { $runMode = 'inject-only' }
    elseif ($LocalRun -or $NoPublish) { $runMode = 'local' }
    try {
        $entry = New-RunManifestEntry -FlowName $FlowName -RunId $script:Result.runId -Mode $runMode `
            -Ok $script:Result.ok -Stage $script:Result.stage -Status $script:Result.status `
            -Actions $script:Result.actions -TotalMs $script:Result.totalMs `
            -ErrorCode $errCode -ErrorMessage $errMsg `
            -LogPath $script:Result.logPath -CanvasVerified $script:Result.canvasVerified `
            -Acceptance $script:Result.acceptance -Warnings $script:Result.warnings
        Add-ManifestEntry $ManifestPath $entry
        Write-Log "manifest appended: $ManifestPath"
        # Run records are kept 90 days; release / rollback entries are kept forever. A failed prune does not affect the run result
        try {
            $dropped = Remove-OldManifestEntries $ManifestPath -KeepDays 90
            if ($dropped -gt 0) { Write-Log "manifest pruned $dropped run record(s) older than 90 days" }
        } catch { Write-Log "manifest prune failed (does not affect the run result): $($_.Exception.Message)" }
    } catch {
        Write-Log "manifest write failed (does not affect the run result): $($_.Exception.Message)"
    }
}

# Release the mutex: both normal and abnormal endings pass through here; when the process is killed the system releases it automatically
Exit-PadRunLock

# ── Failure alerts: directly invoked runs (manual Run click / URL trigger) also write to alerts.jsonl ──
# Shared with pad-schedule through PadAlerts.psm1; nothing is written on success (exit 0 with no failure flag).
# One entry per runId + kind, so retries do not flood the file.
$alertDir = $null
$alertRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (Test-Path (Join-Path $alertRepo 'tools')) { $alertDir = Join-Path $alertRepo 'business\logs' }
if ($alertDir) {
    $alertExit = 0
    if ($script:LockTimedOut) { $alertExit = 4 }
    elseif ($script:Result.needsHumanConfirm) { $alertExit = 3 }
    elseif ($script:Result.ok -eq $false) { $alertExit = 1 }
    try {
        $alert = Write-RunAlert -FlowName $FlowName -ExitCode $alertExit -Stage $script:Result.stage `
            -Status $script:Result.status -SyncResult $script:Result -LogPath $script:Result.logPath `
            -RunId ([string]$script:Result.runId) -Dir $alertDir
        if ($alert -and -not $alert.skipped) { Write-Log "failure alert written: $($alert.path)" }
    } catch {
        # A failed alert write must not affect the run result or the exit code; warn only
        Write-Log "alert write failed (does not affect the run result): $($_.Exception.Message)"
    }
}

# Final result for the agent to parse (fixed prefix on the last line)
Write-Output ("PAD_SYNC_RESULT=" + ($script:Result | ConvertTo-Json -Depth 8 -Compress))

# Exit codes: 0 success / unknown result / 1 run failed / 3 stopped at manual confirmation / 4 timed out waiting for the lock
# An unknown result (ok=$null) is not treated as a failure, so a cleaned-up Actions.log does not cause a false alarm
if ($script:LockTimedOut) { exit 4 }
if ($script:Result.needsHumanConfirm) { exit 3 }
if ($script:Result.ok -eq $false) { exit 1 }
exit 0
