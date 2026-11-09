# PadAlerts.psm1 — the single implementation of failure alerts (business\logs\alerts.jsonl)
#
# Why a separate module:
#   All four entry points — pad-schedule / pad-sync / pad-deploy / pad-release — must record the same kind of alert on failure;
#   copying the logic into each would let field names and kind semantics drift, and operations could no longer filter uniformly.
#   This module does only "classify + deduplicate + append one JSONL line": it sends no external message and needs no credentials,
#   so the alert channel itself can never affect the main flow.
#
# Deduplication rules:
#   The same runId + the same kind is written once (retries and repeated calls append nothing);
#   stages without a runId (release/inject/calendar) deduplicate on "flow + kind + stage + today",
#   which prevents same-day retry spam while still allowing another alert the next day.

# The kind constants live here: call sites reference the names only and never inline the strings
function Get-AlertKindConstants {
    return [ordered]@{
        TriggerFailed         = 'trigger-failed'
        RunNeedsHumanConfirm  = 'run-needs-human-confirm'
        RunTimeout            = 'run-timeout'
        RunLockTimeout        = 'run-lock-timeout'
        RunFailed             = 'run-failed'
        CalendarUnavailable   = 'calendar-unavailable'
        CalendarStale         = 'calendar-stale'
        DeployPrecheckFailed  = 'deploy-precheck-failed'
        DeployInjectFailed    = 'deploy-inject-failed'
        DeployPublishFailed   = 'deploy-publish-failed'
        ReleaseCanvasMismatch = 'release-canvas-mismatch'
    }
}

# Default note for each kind: it must include a "what to do next" sentence so a person can act on it directly
function Get-AlertDefaultNote([string]$Kind) {
    switch ($Kind) {
        'deploy-precheck-failed' { return 'Deploy precheck failed (config/placeholders/paths); nothing was injected. Next step: fix the config or the source .robin, then retry.' }
        'deploy-inject-failed'   { return 'Failed to inject into the canvas; nothing was published. Next step: make sure the designer has the target flow open and the canvas is writable, then retry.' }
        'deploy-publish-failed'  { return 'Publish stage failed (publish timeout or version conflict). Next step: close and reopen the flow, then retry; nothing was retried automatically.' }
        'release-canvas-mismatch' { return 'The published copy does not match the injected content; the publish is treated as failed. Next step: refresh the Workspace and publish again; do not hand-edit the .robin.' }
        default { return 'This failure has been recorded. Next step: check the stage and log path in the alert, fix it, and rerun manually; nothing was retried automatically.' }
    }
}

# Alert classification: map exit codes and result markers to kind / reason / note
#
# Extracted as a pure function so Pester can assert the classification directly without actually running PAD.
# Priority: manual confirmation > lock wait timeout > calendar unavailable > trigger failure > run timeout > generic run failure.
# Success (exit 0 with no failure marker) returns $null, which tells the caller not to write an alert.
function Get-RunAlertKind {
    param(
        [int]$ExitCode,
        [Nullable[bool]]$CalendarOk,
        $SyncResult
    )
    $isHumanConfirm = ($ExitCode -eq 3 -or ($SyncResult -and $SyncResult.needsHumanConfirm))
    $isLockTimeout = ($ExitCode -eq 4)
    $isCalendarDown = ($CalendarOk -eq $false)
    $isTriggerFailed = ($SyncResult -and $SyncResult.triggerFailed)
    $isRunTimeout = ($SyncResult -and $SyncResult.runTimeout)
    if ($ExitCode -eq 0 -and -not $isHumanConfirm -and -not $isLockTimeout -and
        -not $isCalendarDown -and -not $isTriggerFailed -and -not $isRunTimeout) {
        return $null
    }

    if ($isHumanConfirm) {
        return [ordered]@{ kind = 'run-needs-human-confirm'; reason = $null
            note = "The flow stopped at a manual-confirmation dialog '$($SyncResult.dialogTitle)'; it was not clicked. Next step: confirm it in the PAD console and rerun; nothing was retried automatically." }
    }
    if ($isLockTimeout) {
        return [ordered]@{ kind = 'run-lock-timeout'; reason = $null
            note = 'Timed out waiting for the queue; this run did not execute. Next step: wait for the previous flow to finish and rerun manually; nothing was retried automatically.' }
    }
    if ($isCalendarDown) {
        return [ordered]@{ kind = 'calendar-unavailable'; reason = $null
            note = 'The workday calendar is unavailable; this run did not execute. Next step: fix the calendar file and rerun manually.' }
    }
    if ($isTriggerFailed) {
        $reason = [string]$SyncResult.triggerReason
        if (-not $reason) { $reason = 'unknown' }
        $note = switch ($reason) {
            'identity-mismatch' { 'The flow name did not resolve to a flowId; this run was not triggered. Next step: confirm the flow name in the PAD console and run it successfully at least once; nothing was retried automatically.' }
            'no-evidence' { 'No run log appeared after the trigger (protocol handler did not respond / flowId mismatch / PAD error popup). Next step: check the PAD console manually; nothing was retried automatically.' }
            'no-robot' { 'The trigger was accepted but the robot did not start (PAD error box, or the confirmation dialog was cancelled). Next step: handle it manually and rerun; nothing was retried automatically.' }
            default { 'Trigger failed (reason not classified). Next step: check the PAD console manually; nothing was retried automatically.' }
        }
        return [ordered]@{ kind = 'trigger-failed'; reason = $reason; note = $note }
    }
    if ($isRunTimeout) {
        return [ordered]@{ kind = 'run-timeout'; reason = $null
            note = 'The run exceeded the timeout threshold without reaching a terminal state. Next step: check whether PAD is still stuck, handle it manually, and rerun; nothing was retried automatically.' }
    }
    return [ordered]@{ kind = 'run-failed'; reason = $null; note = $null }
}

# Deduplication test: returns $true when an existing record matches (nothing is appended this time)
function Test-AlertDuplicate {
    param([string]$File, [string]$FlowName, [string]$Kind, [string]$RunId, [string]$Stage, [string]$Today)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    foreach ($line in [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        if ([string]$r.flow -ne $FlowName) { continue }
        if ([string]$r.kind -ne $Kind) { continue }
        if ($RunId) {
            # Same runId + same kind: retries and repeated calls all leave a single line
            if ([string]$r.runId -eq $RunId) { return $true }
        } elseif ([string]$r.stage -eq $Stage -and ([string]$r.ts).StartsWith($Today)) {
            # Stages without a runId: one line per stage per day; another alert is allowed the next day
            return $true
        }
    }
    return $false
}

# Failure alert: append one line to alerts.jsonl
#
# Returns [ordered]@{ skipped; path; record }:
#   skipped=$true means nothing was written (success, or the same key already exists); the caller uses it to decide whether to print a hint.
function Write-RunAlert {
    param(
        [string]$FlowName,
        [int]$ExitCode,
        [string]$Stage,
        [string]$Status,
        $SyncResult,
        [string]$LogPath,
        [string]$Dir,
        # Calendar availability: $false means this run did not execute because the calendar was unavailable, for alert classification
        [Nullable[bool]]$CalendarOk,
        # Calendar stale: the calendar is readable but does not cover today; this must be a separate case, not "a day off"
        [switch]$CalendarStale,
        [string]$CalendarRange,
        # Kind explicitly given by the caller (release/inject stages); derived by Get-RunAlertKind when omitted
        [string]$Kind,
        # Note explicitly given by the caller; falls back to the kind's default note when omitted
        [string]$Note,
        # Flag the caller declares explicitly: whether Note already contains a "next step" recommendation.
        # Defaults to true (existing callers' notes all include a next step); pass $false explicitly when passing an empty note.
        [bool]$NoteHasNextStep = $true,
        # Run identifier: when present, deduplicate on "runId + kind"
        [string]$RunId
    )
    if (-not $Dir) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $Dir = Join-Path $repoRoot 'business\logs'
    }

    $grade = $null
    if ($Kind) {
        $grade = [ordered]@{ kind = $Kind; reason = $null; note = $(if ($Note) { $Note } else { Get-AlertDefaultNote $Kind }) }
    } else {
        $grade = Get-RunAlertKind -ExitCode $ExitCode -CalendarOk $CalendarOk -SyncResult $SyncResult
        if (-not $grade) { return [ordered]@{ skipped = $true; path = $null; record = $null } }
        if ($Note) { $grade.note = $Note }
    }
    # Stale calendar is its own class: the event name is fixed as calendar-stale (the trigger layer reuses it once online rather than inventing a new name)
    if ($CalendarStale) {
        $grade = [ordered]@{
            kind   = 'calendar-stale'
            reason = 'calendar-stale'
            note   = "The calendar does not cover today (covered $CalendarRange); this run did not execute. Next step: update the calendar file and rerun manually."
        }
    }

    $note = [string]$grade.note
    # Safety net: every alert must tell a person what to do next.
    # Whether a recommendation is already attached is decided by the explicit flag, not by scanning the note for keyword
    # strings (an approach that only worked for notes written in Chinese).
    $hasNextStep = if ($CalendarStale) { $true }
        elseif ($Note) { $NoteHasNextStep }
        elseif ($Kind) { $true }
        elseif ($grade.note) { $true }
        else { $false }
    if (-not $hasNextStep) { $note = "$note Next step: check the logs and the PAD console, then rerun manually." }

    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $file = Join-Path $Dir 'alerts.jsonl'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if (Test-AlertDuplicate -File $file -FlowName $FlowName -Kind $grade.kind -RunId $RunId -Stage $Stage -Today $today) {
        return [ordered]@{ skipped = $true; path = $file; record = $null }
    }

    $errCode = $null
    $errMsg = $null
    $acc = $null
    if ($SyncResult) {
        if ($SyncResult.error) {
            if ($SyncResult.error.code) { $errCode = $SyncResult.error.code }
            if ($SyncResult.error.message) { $errMsg = $SyncResult.error.message }
        }
        $acc = $SyncResult.acceptance
    }

    $rec = [ordered]@{
        ts         = (Get-Date).ToString('o')
        kind       = $grade.kind
        flow       = $FlowName
        exitCode   = $ExitCode
        stage      = $Stage
        status     = $Status
        errorCode  = $errCode
        error      = $errMsg
        logPath    = $LogPath
        acceptance = $acc
        note       = $note
    }
    if ($RunId) { $rec['runId'] = $RunId }
    # Trigger failures additionally carry a reason classification (identity-mismatch / no-evidence / no-robot)
    if ($grade.reason) { $rec['reason'] = $grade.reason }
    if ($CalendarStale) {
        $rec['calendarStale'] = $true
        $rec['calendarRange'] = $CalendarRange
    }
    if ($null -ne $CalendarOk) { $rec['calendarOk'] = [bool]$CalendarOk }
    # Do not use Add-Content: the first write in PS 5.1 adds a BOM, which breaks line-by-line JSONL parsing
    [IO.File]::AppendAllText($file, (($rec | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ skipped = $false; path = $file; record = $rec }
}

Export-ModuleMember -Function Get-AlertKindConstants, Get-AlertDefaultNote, Get-RunAlertKind,
    Test-AlertDuplicate, Write-RunAlert
