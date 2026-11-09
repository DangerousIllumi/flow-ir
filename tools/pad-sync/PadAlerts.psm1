# PadAlerts.psm1 — 失败告警的唯一实现（business\logs\alerts.jsonl）
#
# 为什么单独成模块：
#   pad-schedule / pad-sync / pad-deploy / pad-release 四条入口都要在失败时落同一种告警；
#   各自复制一份会让字段名与 kind 口径漂移，运维无法统一过滤。
#   本模块只做「分级 + 去重 + 追加一行 JSONL」：不发任何外部消息，也不需要任何凭据，
#   告警通道本身不会影响主流程。
#
# 去重口径：
#   同一 runId + 同一 kind 只写一条（重试、重复调用都不再追加）；
#   没有 runId 的阶段（发布/注入/日历）按「flow + kind + stage + 当天」去重，
#   避免同一天重试刷屏，同时允许第二天再次告警。

# kind 常量集中在这里：调用点只引用常量名，不写散字符串
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

# 每个 kind 的默认文案：必须带一句「下一步怎么办」，供人直接照做
function Get-AlertDefaultNote([string]$Kind) {
    switch ($Kind) {
        'deploy-precheck-failed' { return 'Deploy precheck failed (config/placeholders/paths); nothing was injected. Next step: fix the config or the source .robin, then retry.' }
        'deploy-inject-failed'   { return 'Failed to inject into the canvas; nothing was published. Next step: make sure the designer has the target flow open and the canvas is writable, then retry.' }
        'deploy-publish-failed'  { return 'Publish stage failed (publish timeout or version conflict). Next step: close and reopen the flow, then retry; nothing was retried automatically.' }
        'release-canvas-mismatch' { return 'The published copy does not match the injected content; the publish is treated as failed. Next step: refresh the Workspace and publish again; do not hand-edit the .robin.' }
        default { return 'This failure has been recorded. Next step: check the stage and log path in the alert, fix it, and rerun manually; nothing was retried automatically.' }
    }
}

# 失败告警分级：把退出码与结果标记映射成 kind / reason / note
#
# 单独抽成纯函数，便于 Pester 直接断言分类结果，不必真跑 PAD。
# 分类优先级：人工确认 > 等锁超时 > 日历不可用 > 触发失败 > 运行超时 > 一般运行失败。
# 成功（exit 0 且无失败标记）返回 $null：调用方据此不写告警。
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

# 去重判定：命中已有记录返回 $true（本次不追加）
function Test-AlertDuplicate {
    param([string]$File, [string]$FlowName, [string]$Kind, [string]$RunId, [string]$Stage, [string]$Today)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    foreach ($line in [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        if ([string]$r.flow -ne $FlowName) { continue }
        if ([string]$r.kind -ne $Kind) { continue }
        if ($RunId) {
            # 同一 runId + 同一 kind：重试/重复调用都只留一条
            if ([string]$r.runId -eq $RunId) { return $true }
        } elseif ([string]$r.stage -eq $Stage -and ([string]$r.ts).StartsWith($Today)) {
            # 无 runId 的阶段：同一天同一 stage 只留一条，允许第二天再告警
            return $true
        }
    }
    return $false
}

# 失败告警：追加一行到 alerts.jsonl
#
# 返回 [ordered]@{ skipped; path; record }：
#   skipped=$true 表示没有写（成功、或同键已存在）；调用方据此决定是否打印提示。
function Write-RunAlert {
    param(
        [string]$FlowName,
        [int]$ExitCode,
        [string]$Stage,
        [string]$Status,
        $SyncResult,
        [string]$LogPath,
        [string]$Dir,
        # 日历是否可用：$false 表示本次因日历不可用而未运行，供告警分级使用
        [Nullable[bool]]$CalendarOk,
        # 日历过期：日历能读，但今天不在覆盖范围内；必须单列，不能算「今天休息」
        [switch]$CalendarStale,
        [string]$CalendarRange,
        # 调用方显式指定的 kind（发布/注入类）；不传时由 Get-RunAlertKind 推导
        [string]$Kind,
        # 调用方显式指定的文案；不传时用 kind 对应的默认文案
        [string]$Note,
        # 调用方显式声明的标记：Note 是否已含「下一步」处置建议。
        # 默认 true（现有调用方的 Note 都自带下一步）；传空文案时应显式传 $false。
        [bool]$NoteHasNextStep = $true,
        # 运行标识：有值时按「runId + kind」去重
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
    # 日历过期单独成类：事件名固定 calendar-stale（触发层上线后复用同名，不另造新名）
    if ($CalendarStale) {
        $grade = [ordered]@{
            kind   = 'calendar-stale'
            reason = 'calendar-stale'
            note   = "The calendar does not cover today (covered $CalendarRange); this run did not execute. Next step: update the calendar file and rerun manually."
        }
    }

    $note = [string]$grade.note
    # 兜底：任何一条告警都必须告诉人下一步做什么。
    # 是否已附加处置建议用显式标记判断，不再匹配文案里的中文关键字。
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
    # 触发失败额外带 reason 分类（identity-mismatch / no-evidence / no-robot）
    if ($grade.reason) { $rec['reason'] = $grade.reason }
    if ($CalendarStale) {
        $rec['calendarStale'] = $true
        $rec['calendarRange'] = $CalendarRange
    }
    if ($null -ne $CalendarOk) { $rec['calendarOk'] = [bool]$CalendarOk }
    # 不用 Add-Content：PS 5.1 首次写入会带 BOM，JSONL 逐行解析会失败
    [IO.File]::AppendAllText($file, (($rec | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ skipped = $false; path = $file; record = $rec }
}

Export-ModuleMember -Function Get-AlertKindConstants, Get-AlertDefaultNote, Get-RunAlertKind,
    Test-AlertDuplicate, Write-RunAlert
