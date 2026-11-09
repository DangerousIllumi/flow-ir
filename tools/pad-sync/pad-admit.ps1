# pad-admit.ps1 — read-only admission gate: decides before deploy/run whether "this flow, this run" is allowed
#
# Mirrors the checks in docs/admission-gate.md. Hard constraints:
#   1) Read-only: no PAD launch, no SAP connection, no email sent, no artifact written
#   2) Reports every problem in one pass instead of exiting at the first failure
#   3) Every failure carries a code + plain-language message + evidence (node id / parameter / file name)
#
# Usage:
#   .\pad-admit.ps1 -FlowFile business\flows\sample-report.json -ConfigFile business\config\sample-report.json
#   .\pad-admit.ps1 -FlowFile ... -Unattended      # scheduled-task scenario: every ask counts as deny
#   .\pad-admit.ps1 -FlowFile ... -TriggerLive     # TRIGGER also runs a read-only scheduled-task registration check
#   .\pad-admit.ps1 -FlowFile ... -Json            # JSON output only
#
# Exit codes: 0 all passed / 1 at least one fail / 2 only ask
# Differences from the doc (more practical in report mode, and recorded):
#   - An undeclared BUDGET is a warn, not a fail (otherwise every existing flow would fail)
#   - Missing INTENT is a warn (the policy can still fall back to paramsMatch)
#   - FINGERPRINT mismatch against the baseline/approval record fails; a missing baseline warns in report mode
#     but stays fail under -Unattended (the release/deploy/schedule paths)
#   - TRIGGER not declared during the observation period is a warn (it becomes fail once existing flows are migrated)

[CmdletBinding()]
param(
    [string]$FlowFile,
    [string]$RobinFile,
    [string]$ConfigFile,
    [string]$AcceptanceFile,
    [string]$RequirementsFile,
    [string]$PolicyFile,
    [string]$KbPath,
    [string]$FlowName,
    [string]$ApproveFile,
    # Scheduled / unattended: treat ask as deny
    [switch]$Unattended,
    # TRIGGER live check: off by default so it stays reproducible offline; when on, queries local scheduled tasks read-only
    [switch]$TriggerLive,
    [switch]$Json,
    # Only for Pester dot-sourcing
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Single implementation of the fingerprint mechanism: lookup, hashing, and comparison all live in PadFingerprint.psm1
Import-Module (Join-Path $PSScriptRoot 'PadFingerprint.psm1') -Force
# Severity when the fingerprint does not pass: warn only notifies, fail blocks.
# The baseline has been seeded and verified, so the default is fail: any fingerprint mismatch blocks
$script:FingerprintMode = 'fail'

$CONTROL_HINTS = @('IF', 'LOOP', 'SWITCH', 'GUARD', 'WAIT', 'EXIT LOOP', 'EXIT_LOOP')

# Wildcard match: only * and ? are special, everything else is literal, so regex metacharacters cannot cause false hits
function Test-GlobMatch([string]$Pattern, [string]$Text) {
    if ($null -eq $Pattern) { return $false }
    if ($Pattern -eq '*') { return $true }
    $escaped = [regex]::Escape([string]$Pattern)
    $rx = '^' + $escaped.Replace('\*', '.*').Replace('\?', '.') + '$'
    return ($Text -match $rx)
}

# Derive flow.json from the PAD display name: match the top-level pad_flow_name first, then file name / top-level name.
# More than one hit means ADMIT_AMBIGUOUS_FLOW — never fall back to "take the first one"; zero hits returns $null.
# pad_flow_name is an optional field: the generator / check.js / eval-flow.js accept but never consume it.
function Resolve-FlowFileByName([string]$FlowsDir, [string]$FlowName) {
    if (-not (Test-Path -LiteralPath $FlowsDir)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $FlowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' } |
        ForEach-Object {
            try {
                $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                # Only accept flow definitions: nodes must be non-empty, so companion artifacts / deploy diffs cannot slip into the candidates
                if (($j.PSObject.Properties.Name -contains 'nodes') -and (@($j.nodes).Count -gt 0)) {
                    [pscustomobject]@{ File = $_; Json = $j }
                }
            } catch { }
        })
    $hit = @($items | Where-Object { [string]$_.Json.pad_flow_name -eq $FlowName })
    if ($hit.Count -eq 0) {
        $hit = @($items | Where-Object {
            ($_.File.BaseName -eq $FlowName) -or ([string]$_.Json.name -eq $FlowName)
        })
    }
    if ($hit.Count -eq 1) { return $hit[0].File.FullName }
    if ($hit.Count -gt 1) {
        throw ("ADMIT_AMBIGUOUS_FLOW: '{0}' matched {1} flow.json file(s) ({2}); specify it explicitly with -FlowFile" -f `
            $FlowName, $hit.Count, (($hit | ForEach-Object { $_.File.Name }) -join ', '))
    }
    return $null
}

# Uniform result entry
function New-AdmitCheck([string]$Id, [string]$Status, [string]$Code, [string]$Message, $Evidence) {
    return [ordered]@{
        id = $Id; status = $Status; code = $Code; message = $Message
        evidence = @($Evidence)
    }
}

# Turn a parameter value into text a policy glob can match (objects/arrays become compressed JSON)
function ConvertTo-MatchText($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    return ($Value | ConvertTo-Json -Depth 6 -Compress)
}

# Whether every clause of the rule's when section is satisfied
function Test-RuleWhen($Rule, $Node, [hashtable]$Ctx) {
    $w = $Rule.when
    if (-not $w) { return $true }
    if ($null -ne $w.env) {
        if ([string]$w.env -ne [string]$Ctx.env) { return $false }
    }
    if ($null -ne $w.dryRun) {
        if ([bool]$w.dryRun -ne [bool]$Ctx.dryRun) { return $false }
    }
    if ($null -ne $w.registered) {
        if ([bool]$w.registered -ne [bool]$Ctx.registered.ContainsKey([string]$Node.pad_hint)) { return $false }
    }
    if ($null -ne $w.intent) {
        if (-not $Node) { return $false }
        if ([string]$w.intent -ne [string]$Node.intent) { return $false }
    }
    if ($null -ne $w.paramsMatch) {
        if (-not $Node) { return $false }
        foreach ($p in $w.paramsMatch.PSObject.Properties) {
            $val = $null
            if ($Node.params -and $Node.params.PSObject.Properties.Name -contains $p.Name) {
                $val = $Node.params.($p.Name)
            }
            if (-not (Test-GlobMatch ([string]$p.Value) (ConvertTo-MatchText $val))) { return $false }
        }
    }
    return $true
}

# Collect every downstream node of a set of node ids (including next, branch, loop, switch, and guard body)
# Used to decide "is this side effect already wrapped by a DRY_RUN guard"; the visited set prevents infinite loops on back edges
function Get-DescendantIds($Flow, [string[]]$Ids) {
    $byId = @{}
    foreach ($n in @($Flow.nodes)) { $byId[[string]$n.id] = $n }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($i in $Ids) { if ($i) { $stack.Push([string]$i) } }
    while ($stack.Count -gt 0) {
        $id = $stack.Pop()
        if (-not $seen.Add($id)) { continue }
        $n = $byId[$id]
        if (-not $n) { continue }
        foreach ($x in @($n.next)) { if ($x) { $stack.Push([string]$x) } }
        if ($n.branch) {
            foreach ($x in @($n.branch.trueBody) + @($n.branch.falseBody)) { if ($x) { $stack.Push([string]$x) } }
        }
        if ($n.loop -and $n.loop.body) { foreach ($x in @($n.loop.body)) { if ($x) { $stack.Push([string]$x) } } }
        if ($n.switch) {
            foreach ($c in @($n.switch.cases)) { foreach ($x in @($c.body)) { if ($x) { $stack.Push([string]$x) } } }
            foreach ($x in @($n.switch.default)) { if ($x) { $stack.Push([string]$x) } }
        }
        if ($n.pad_hint -eq 'GUARD') {
            foreach ($x in @($n.body) + @($n.elseBody)) { if ($x) { $stack.Push([string]$x) } }
        }
    }
    return $seen
}

# Policy evaluation: fixed order deny → ask → allow; first matching rule wins within a tier; no match falls back to defaultEffect
# Returns { checks, hits } with at most one POLICY conclusion inside checks
function Invoke-AdmitPolicy($Flow, $Policy, [hashtable]$Ctx, [switch]$Unattended) {
    $results = @()
    $rules = @($Policy.rules | Where-Object { $_.enabled })
    $actionNodes = @($Flow.nodes | Where-Object {
        $_.pad_hint -and $CONTROL_HINTS -notcontains [string]$_.pad_hint
    })

    # The set of nodes wrapped by a DRY_RUN guard: these side effects would not run in test mode anyway,
    # so "dryRun-related deny rules" do not apply to them (otherwise turning on DRY_RUN would be blocked by admission itself)
    $guardRoots = @($Flow.nodes | Where-Object {
        $_.pad_hint -eq 'GUARD' -and ([string]$_.when) -match 'DryRun'
    } | ForEach-Object { @($_.body) + @($_.elseBody) })
    $guarded = @{}
    if ($guardRoots.Count -gt 0) {
        foreach ($id in (Get-DescendantIds $Flow $guardRoots)) { $guarded[$id] = $true }
    }

    $denies = @()
    $asks = @()
    $allows = @()

    foreach ($node in $actionNodes) {
        foreach ($rule in $rules) {
            if ([string]$rule.resource -ne 'action') { continue }
            if (-not (Test-GlobMatch ([string]$rule.match) ([string]$node.pad_hint))) { continue }
            if (-not (Test-RuleWhen $rule $node $Ctx)) { continue }
            # Side effects wrapped by a DRY_RUN guard do not run in test mode, so dryRun-class rules do not apply to them
            if ($rule.when -and $rule.when.dryRun -eq $true -and $guarded.ContainsKey([string]$node.id)) { continue }
            $hit = [ordered]@{ rule = $rule; node = [string]$node.id; hint = [string]$node.pad_hint }
            switch ([string]$rule.effect) {
                'deny' { $denies += $hit }
                'ask' { $asks += $hit }
                'allow' { $allows += $hit }
            }
        }
    }

    if ($denies.Count -gt 0) {
        $ev = @($denies | ForEach-Object { "node $($_.node) $($_.hint) hit $($_.rule.id)" })
        $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_DENY' `
            ('denied by policy: ' + (@($denies | ForEach-Object { $_.rule.reason }) -join '; ')) $ev
        return $results
    }
    if ($asks.Count -gt 0) {
        $ev = @($asks | ForEach-Object { "node $($_.node) $($_.hint) hit $($_.rule.id)" })
        $reason = (@($asks | ForEach-Object { $_.rule.reason }) -join '; ')
        if ($Unattended) {
            $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_ASK_UNATTENDED' `
                "unattended run treats ask as deny: $reason" $ev
        } else {
            $results += New-AdmitCheck 'POLICY' 'ask' 'POLICY_ASK' $reason $ev
        }
        return $results
    }
    if ($allows.Count -gt 0 -or [string]$Policy.defaultEffect -eq 'allow') {
        $results += New-AdmitCheck 'POLICY' 'pass' 'OK' 'no deny/ask matched' @()
        return $results
    }
    $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_DEFAULT_DENY' `
        'no allow rule matched; defaultEffect=deny applies' @()
    return $results
}

# ---------- TRIGGER: trigger declaration ----------
# Observation period: existing flows do not declare a trigger yet, so it defaults to warn; after migration a separate commit makes it fail.
# Same approach as the fingerprint: switching the severity is its own change, never mixed into this feature.
$script:TriggerMode = 'warn'
$script:TriggerKinds = @('manual', 'schedule', 'file')
# Reserved values are listed separately: mail/callback means "supported but not implemented in v1", which is distinct from a typo
$script:TriggerReservedKinds = @('mail', 'callback')
$script:TriggerDays = @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
$script:TriggerGates = @('none', 'workday', 'last-workday')
$script:TriggerDayNames = @{
    mon = 'Mon'; tue = 'Tue'; wed = 'Wed'; thu = 'Thu'; fri = 'Fri'; sat = 'Sat'; sun = 'Sun'
}

# Property existence test: handles both the PSCustomObject produced by JSON and the Hashtable tests build directly
function Test-PropExists($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
    return (@($Obj.PSObject.Properties.Name) -contains $Name)
}

# Positive integer seconds: strings, fractions, 0, and negatives are all rejected so the registrar never has to guess units
function Test-TriggerPositiveInt($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $false }
    $d = [double]$Value
    return ($d -gt 0 -and $d -eq [math]::Floor($d))
}

# Default task name: the same rule as Get-ScheduleTaskName in pad-schedule, so the two derivations cannot drift apart
function Get-TriggerTaskName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|\s]', '_').Trim('_')
    if (-not $safe) { return $null }
    return 'flow-ir-' + $safe
}

# Static task-name collision: scan the effective task names declared by other flows under business\flows; a hit means no overwrite
function Find-TriggerTaskCollision {
    param([string]$Repo, [string]$SelfFile, [string]$TaskName)
    $hits = @()
    if (-not $Repo -or -not $TaskName) { return $hits }
    $dir = Join-Path $Repo 'business\flows'
    if (-not (Test-Path -LiteralPath $dir)) { return $hits }
    $self = $null
    if ($SelfFile -and (Test-Path -LiteralPath $SelfFile)) { $self = (Resolve-Path -LiteralPath $SelfFile).Path }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($self -and $f.FullName -eq $self) { continue }
        try { $j = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not (Test-PropExists $j 'trigger')) { continue }
        $t = $null
        if (Test-PropExists $j.trigger 'task_name') { $t = [string]$j.trigger.task_name }
        elseif ((Test-PropExists $j.trigger 'kind') -and [string]$j.trigger.kind -ne 'manual') {
            $t = Get-TriggerTaskName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
        if ($t -eq $TaskName) { $hits += $f.Name }
    }
    return $hits
}

# TRIGGER body: static validation + optional live validation.
# -TriggerLive is off by default: it reads the local scheduled tasks and specHash without side effects;
# an unregistered task is TRIGGER_NOT_REGISTERED (warn), and a mismatch between declaration and task is TRIGGER_DRIFT (fail).
function Invoke-TriggerCheck {
    param(
        $Flow, [string]$FlowName, [string]$Repo, [string]$SelfFile,
        [string]$ConfigFile, [switch]$TriggerLive
    )
    $issues = @()

    # Reversibility and idempotency are two orthogonal axes.
    #   idempotent = does rerunning with the same input converge (is a rerun safe)
    #   reversible = can the consequences already produced be undone (a deletion can be recreated, a mail can be corrected,
    #                a posting can only be reversed by another posting)
    # Checked before the trigger shape test: manual flows, flows without a trigger, and legacy-shaped flows must also show
    # "can the consequences be undone", otherwise report mode would never surface this.
    $nodes = @($Flow.nodes)
    $irreversible = @($nodes | Where-Object {
        $_ -and (Test-PropExists $_ 'reversible') -and $_.reversible -eq $false
    })
    if ($irreversible.Count -gt 0) {
        $issues += @{ status = 'warn'; code = 'TRIGGER_UNATTENDED_IRREVERSIBLE'
            message = 'some nodes are irreversible (reversible=false); document how to roll them back'
            evidence = @($irreversible | ForEach-Object {
                $note = $null
                if (Test-PropExists $_ 'reversibility_note') { $note = [string]$_.reversibility_note }
                if ($note) { "node $($_.id) reversible=false: $note" } else { "node $($_.id) reversible=false" }
            }) }
    }
    # idempotent=false without a reversible declaration: ask for the declaration instead of papering over it with a default
    $missingRev = @($nodes | Where-Object {
        $_ -and (Test-PropExists $_ 'idempotent') -and $_.idempotent -eq $false -and
        -not (Test-PropExists $_ 'reversible')
    })
    if ($missingRev.Count -gt 0) {
        $issues += @{ status = 'warn'; code = 'TRIGGER_MISSING_REVERSIBILITY'
            message = 'node idempotent=false but reversible is not declared; declare whether the effect can be rolled back'
            evidence = @($missingRev | ForEach-Object {
                "node $($_.id) idempotent=false, reversible not declared"
            }) }
    }

    # A known-irreversible action declared reversible=true is a factual error, so fail immediately (this is the incident where a reminder email was marked reversible)
    $mislabeled = @($nodes | Where-Object {
        $_ -and (Test-PropExists $_ 'reversible') -and $_.reversible -eq $true -and (
            ($_.pad_hint -match '^Outlook\.SendEmail') -or
            ($_.pad_hint -match '^(File|Folder)\.Delete$') -or
            (($_.pad_hint -match '^Scripting\.RunDOSCommand') -and
             (Test-PropExists $_ 'intent') -and ([string]$_.intent -match '(migo|posting)'))
        )
    })
    if ($mislabeled.Count -gt 0) {
        $issues += @{ status = 'fail'; code = 'REVERSIBLE_MISLABELED'
            message = 'an irreversible action must not declare reversible=true (mail/delete/posting cannot be undone)'
            evidence = @($mislabeled | ForEach-Object { "node $($_.id) $($_.pad_hint) is marked reversible=true" }) }
    }

    $trg = $null
    if (Test-PropExists $Flow 'trigger') { $trg = $Flow.trigger }
    if ($null -eq $trg) {
        return @(New-AdmitCheck 'TRIGGER' $script:TriggerMode 'TRIGGER_MISSING' `
            'trigger is not declared; the launch convention still depends on memory; add a trigger block' @())
    }
    if (-not (Test-PropExists $trg 'kind') -and (Test-PropExists $trg 'type')) {
        return @(New-AdmitCheck 'TRIGGER' $script:TriggerMode 'TRIGGER_LEGACY_SHAPE' `
            'legacy type/config shape without kind; migrate to kind (no silent mapping)' @("trigger.type=$([string]$trg.type)"))
    }
    if (-not (Test-PropExists $trg 'kind') -or -not [string]$trg.kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_INVALID' 'trigger.kind is missing or not a string' @())
    }
    $kind = [string]$trg.kind
    if ($script:TriggerReservedKinds -contains $kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_KIND_UNSUPPORTED' `
            "kind=$kind is a reserved value; v1 has no registrar for it" @("kind=$kind"))
    }
    if ($script:TriggerKinds -notcontains $kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_UNKNOWN_KIND' `
            "kind=$kind is not one of manual/schedule/file" @("kind=$kind"))
    }

    # Task name: an explicit one must be safe; otherwise derive it from the flow name. manual never registers, so it needs none
    if ($kind -ne 'manual') {
        $taskName = $null
        if (Test-PropExists $trg 'task_name') {
            $taskName = [string]$trg.task_name
            if ($taskName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "task_name=$taskName does not match ^[A-Za-z0-9._-]{1,64}$"; evidence = @("task_name=$taskName") }
            }
        }
        if (-not $taskName) { $taskName = Get-TriggerTaskName $FlowName }
        $collisions = @(Find-TriggerTaskCollision -Repo $Repo -SelfFile $SelfFile -TaskName $taskName)
        if ($collisions.Count -gt 0) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_AMBIGUOUS'
                message = "task name $taskName is already used by another flow; registering it would overwrite"
                evidence = @($collisions | ForEach-Object { "task_name=$taskName conflicting file: $_" }) }
        }
    }

    if ($kind -eq 'manual') {
        # A time or directory on a manual declaration would never execute, so reject it outright and prevent "declared but never run"
        foreach ($k in @('time', 'days', 'gate', 'timeout_sec', 'file', 'assisted')) {
            if (Test-PropExists $trg $k) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "manual must not declare $k (nothing would execute it)"; evidence = @("trigger.$k") }
            }
        }
    } else {
        $assisted = $false
        $timeText = $null
        if (Test-PropExists $trg 'time') { $timeText = [string]$trg.time }
        if (-not $timeText -or $timeText -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                message = "time=$timeText (expected HH:mm, e.g. 09:00)"; evidence = @("time=$timeText") }
        }

        if (Test-PropExists $trg 'days') {
            $dayList = @($trg.days)
            $badDays = @($dayList | Where-Object { $script:TriggerDays -notcontains [string]$_ })
            if ($dayList.Count -eq 0 -or $badDays.Count -gt 0) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = 'days must be a non-empty array of mon..sun'
                    evidence = @("days=$(@($dayList) -join ',')") }
            }
        }

        $gate = 'none'
        if (Test-PropExists $trg 'gate') {
            $gate = [string]$trg.gate
            if ($script:TriggerGates -notcontains $gate) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "gate=$gate is not one of none/workday/last-workday"; evidence = @("gate=$gate") }
            }
        } elseif ($kind -eq 'schedule') {
            $issues += @{ status = 'warn'; code = 'TRIGGER_NO_GATE'
                message = 'schedule does not declare gate; it will also run on holidays; write gate=none explicitly if that is intended'
                evidence = @('gate not declared') }
        }

        if ((Test-PropExists $trg 'timeout_sec') -and -not (Test-TriggerPositiveInt $trg.timeout_sec)) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                message = "timeout_sec=$($trg.timeout_sec) (expected a positive integer in seconds)"; evidence = @('timeout_sec') }
        }

        # assisted: starts automatically on schedule but needs a human confirmation partway; timeout_sec must be declared explicitly
        # so that nobody clicking is still caught by the timeout alert
        if (Test-PropExists $trg 'assisted') {
            if (-not ($trg.assisted -is [bool])) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "assisted=$($trg.assisted) (expected true/false)"; evidence = @('assisted') }
            } else {
                $assisted = [bool]$trg.assisted
                if ($assisted -and -not (Test-PropExists $trg 'timeout_sec')) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_ASSISTED_NO_TIMEOUT'
                        message = 'assisted=true requires an explicit timeout_sec (the timeout alert is the fallback when nobody confirms)'
                        evidence = @('timeout_sec missing') }
                }
            }
        }

        $pattern = $null
        if ($kind -eq 'file') {
            if (-not (Test-PropExists $trg 'file')) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = 'file trigger must carry a file object'; evidence = @('file') }
            } else {
                $f = $trg.file
                $dir = $null
                if (Test-PropExists $f 'dir') { $dir = [string]$f.dir }
                if (-not $dir) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.dir is required'; evidence = @('file.dir') }
                } elseif ($dir -notmatch '^\{\{config\.(\w+)\}\}$') {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_PATH_LITERAL'
                        message = 'file.dir must be a {{config.<KEY>}} reference, not a literal path'
                        evidence = @("file.dir=$dir") }
                }
                if (Test-PropExists $f 'pattern') { $pattern = [string]$f.pattern }
                if (-not $pattern -or $pattern.Trim().Length -eq 0) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.pattern is required and must not be empty'; evidence = @('file.pattern') }
                }
                foreach ($k in @('poll_sec', 'settle_sec', 'max_wait_sec')) {
                    if ((Test-PropExists $f $k) -and -not (Test-TriggerPositiveInt $f.$k)) {
                        $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                            message = "file.$k=$($f.$k) (expected a positive integer in seconds)"; evidence = @("file.$k") }
                    }
                }
                if ((Test-PropExists $f 'once_per_file') -and -not ($f.once_per_file -is [bool])) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.once_per_file must be true/false'; evidence = @('file.once_per_file') }
                }
            }
        }

        # Cross-check: an unattended trigger combined with a manual-confirmation node is a hard contradiction;
        # an explicit assisted=true means "starts on schedule and needs a human partway", which is allowed (the timeout_sec alert covers nobody clicking)
        $nodes = @($Flow.nodes)
        $confirm = @($nodes | Where-Object {
            $_ -and (Test-PropExists $_ 'run_mode') -and [string]$_.run_mode -eq 'confirm'
        })
        if ($confirm.Count -gt 0 -and -not $assisted) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_UNATTENDED_CONFIRM'
                message = 'unattended trigger but nodes require manual confirmation'
                evidence = @($confirm | ForEach-Object { "node $($_.id) run_mode=confirm" }) }
        }
    }

    # live validation: only for schedule, and only when static checks produced no fail
    # Test-Trigger is read-only (Get-ScheduledTask / Get-ScheduledTaskInfo): it never registers or triggers anything
    $staticFails = @($issues | Where-Object { $_.status -eq 'fail' })
    if ($staticFails.Count -eq 0 -and $TriggerLive -and $kind -eq 'schedule' -and
        $SelfFile -and (Test-Path -LiteralPath $SelfFile)) {
        try {
            Import-Module (Join-Path $PSScriptRoot 'TriggerRegistry.psm1') -Force
            # Do not pass -ConfigFile: this pass validates only schedule, and that parameter is merely concatenated into the
            # expected action arguments while the registrar does not pass it when creating the task, so passing it here would
            # wrongly turn "consistent" into TRIGGER_DRIFT.
            $live = Test-Trigger -FlowFile $SelfFile
        } catch {
            # A failed query (including missing runtime config) must not be silently ignored; report it as fail with the source
            $liveCode = 'TRIGGER_DRIFT'
            if ($_.Exception.Data -and $_.Exception.Data.Contains('code')) {
                $liveCode = [string]$_.Exception.Data['code']
            }
            $issues += @{ status = 'fail'; code = $liveCode
                message = "failed to query the scheduled task: $($_.Exception.Message)" ; evidence = @("kind=$kind") }
            $live = $null
        }
        if ($null -ne $live) {
            if (-not $live.ok -and [string]$live.code -eq 'TRIGGER_NOT_REGISTERED') {
                $issues += @{ status = 'warn'; code = 'TRIGGER_NOT_REGISTERED'
                    message = "scheduled task is not registered yet: $($live.taskName) (reported only under -TriggerLive, not blocking)"
                    evidence = @("taskName=$($live.taskName)", "specHash=$($live.specHash)") }
            } elseif (-not $live.ok) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_DRIFT'
                    message = [string]$live.message
                    evidence = @("taskName=$($live.taskName)", "specHash=$($live.specHash)") }
            }
        }
    }

    if ($issues.Count -eq 0) {
        $dayText = 'Mon~Fri'
        if (Test-PropExists $trg 'days') {
            $dayText = (@($trg.days) | ForEach-Object { $script:TriggerDayNames[[string]$_] }) -join ', '
        }
        $msg = switch ($kind) {
            'manual' { 'trigger declaration is valid: manual (started manually or by an external link; no registration needed)' }
            'schedule' { "trigger declaration is valid: schedule $timeText ($dayText, gate=$gate)" }
            default { "trigger declaration is valid: file $timeText ($dayText, pattern=$pattern)" }
        }
        return @(New-AdmitCheck 'TRIGGER' 'pass' 'OK' $msg @())
    }
    return @($issues | ForEach-Object {
        New-AdmitCheck 'TRIGGER' $_.status $_.code $_.message $_.evidence
    })
}

# ---------- INPUT: node-level input-file declarations ----------
# Same rule as the file trigger: the directory must be referenced through {{config.<KEY>}}; two or more candidates are always
# ambiguous and never resolved by "take the newest". This item is read-only: it only enumerates directories and stats files,
# never opens, moves, or deletes anything.
# The capability serves admission and structural checks only; it does not change the generated .robin (the generator does not know inputs).

# Resolve the {{config.<KEY>}} of inputs.dir: read-only; fail hard when it cannot be resolved, never fall back to a literal path
function Resolve-InputDir {
    param([string]$Token, $Config, [string]$ConfigFile)
    $m = [regex]::Match([string]$Token, '^\{\{config\.(\w+)\}\}$')
    if (-not $m.Success) {
        return @{ dir = $null; code = 'INPUT_PATH_LITERAL'
            message = "inputs.dir must be a {{config.<KEY>}} reference, not a literal path: $Token" }
    }
    $key = $m.Groups[1].Value
    if (-not $Config) {
        return @{ dir = $null; code = 'INPUT_CONFIG_UNRESOLVED'
            message = "no config provided; cannot resolve {{config.$key}}; specify it with -ConfigFile" }
    }
    if (-not (Test-PropExists $Config $key) -or -not [string]$Config.$key) {
        return @{ dir = $null; code = 'INPUT_CONFIG_UNRESOLVED'
            message = "config has no usable key $key ($ConfigFile)" }
    }
    return @{ dir = [string]$Config.$key; code = $null; message = $null }
}

# INPUT body: static shape + optional filesystem verification (read-only enumeration)
function Invoke-InputCheck {
    param($Flow, $Config, [string]$ConfigFile)
    $issues = @()
    $passEvidence = @()
    $nodes = @($Flow.nodes | Where-Object { $_ -and (Test-PropExists $_ 'inputs') })
    if ($nodes.Count -eq 0) {
        return @(New-AdmitCheck 'INPUT' 'warn' 'INPUT_UNDECLARED' `
            'no node declares input files (inputs); inputs are not checked before the run; add declarations to flows that depend on input files' @())
    }

    foreach ($n in $nodes) {
        $list = @($n.inputs)
        if ($list.Count -eq 0) {
            $issues += @{ status = 'fail'; code = 'INPUT_INVALID'
                message = "node $($n.id) inputs must be a non-empty array"; evidence = @("node $($n.id)") }
            continue
        }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $it = $list[$i]
            $at = "node $($n.id) inputs[$i]"
            $isObj = ($it -is [System.Management.Automation.PSCustomObject]) -or ($it -is [hashtable])
            if (-not $isObj) {
                $issues += @{ status = 'fail'; code = 'INPUT_INVALID'
                    message = "$at must be an object"; evidence = @($at) }
                continue
            }

            $dirToken = $null
            if ((Test-PropExists $it 'dir') -and ($it.dir -is [string])) { $dirToken = [string]$it.dir }
            if (-not $dirToken) {
                $issues += @{ status = 'fail'; code = 'INPUT_INVALID'
                    message = "$at.dir is required and must be a string"; evidence = @($at) }
                continue
            }
            $res = Resolve-InputDir $dirToken $Config $ConfigFile
            if ($res.code) {
                $issues += @{ status = 'fail'; code = $res.code
                    message = $res.message; evidence = @("$at.dir=$dirToken") }
                continue
            }

            $pattern = $null
            if ((Test-PropExists $it 'pattern') -and ($it.pattern -is [string])) { $pattern = [string]$it.pattern }
            if (-not $pattern -or $pattern.Trim().Length -eq 0) {
                $issues += @{ status = 'fail'; code = 'INPUT_INVALID'
                    message = "$at.pattern is required and must not be empty"; evidence = @($at) }
                continue
            }
            # required must be declared explicitly and is never defaulted (same mandatory-answer rule as run_mode / idempotent)
            if (-not (Test-PropExists $it 'required') -or -not ($it.required -is [bool])) {
                $issues += @{ status = 'fail'; code = 'INPUT_INVALID'
                    message = "$at.required must be true/false (no default filling)"; evidence = @($at) }
                continue
            }
            $required = [bool]$it.required

            # Filesystem verification: when the directory is missing or unreadable, a required entry fails while an optional one counts as "absent"
            $dir = $res.dir
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                if ($required) {
                    $issues += @{ status = 'fail'; code = 'INPUT_DIR_UNREADABLE'
                        message = "required input directory does not exist: $dir"; evidence = @("$at $dir\$pattern") }
                }
                continue
            }
            try {
                $cands = @(Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction Stop)
            } catch {
                if ($required) {
                    $issues += @{ status = 'fail'; code = 'INPUT_DIR_UNREADABLE'
                        message = "input directory is not readable: $dir ($($_.Exception.Message))"; evidence = @("$at") }
                }
                continue
            }
            if ($cands.Count -ge 2) {
                $names = @($cands | ForEach-Object { $_.Name }) -join ', '
                $issues += @{ status = 'fail'; code = 'INPUT_FILE_AMBIGUOUS'
                    message = "$at has $($cands.Count) candidates ($names); no 'take the latest' guessing; clean up the directory first"
                    evidence = @("$at $dir\$pattern", "candidate(s): $names") }
                continue
            }
            if ($cands.Count -eq 0 -and $required) {
                $issues += @{ status = 'fail'; code = 'INPUT_FILE_MISSING'
                    message = "$at required input not found: $dir\$pattern"; evidence = @("$at") }
                continue
            }
            $passEvidence += "$at ${dir}\${pattern}: $($cands.Count) candidate(s)$(if ($required) { ' (required)' } else { ' (optional)' })"
        }
    }

    if ($issues.Count -eq 0) {
        return @(New-AdmitCheck 'INPUT' 'pass' 'OK' "$($nodes.Count) node(s) input declarations checked" $passEvidence)
    }
    return @($issues | ForEach-Object {
        New-AdmitCheck 'INPUT' $_.status $_.code $_.message $_.evidence
    })
}

# Body of checks: runs every check item in one pass (including SCRIPT_FINGERPRINT: the v3 script fingerprint, warn only during the observation period)
function Invoke-AdmitChecks {
    param(
        $Flow, [string]$FlowName, $Config, $Kb,
        [string]$RobinPath, [string]$AcceptancePath, [string]$RequirementsPath,
        $Policy, [string]$ApprovePath, [hashtable]$Paths,
        [string]$FlowDisplayName,
        [ValidateSet('warn', 'fail')][string]$NoBaselineMode = 'fail',
        [bool]$TriggerLive = $false
    )
    $checks = @()
    $nodes = @($Flow.nodes)
    $actionNodes = @($nodes | Where-Object { $_.pad_hint -and $CONTROL_HINTS -notcontains [string]$_.pad_hint })
    $kbMap = @{}
    if ($Kb) { foreach ($a in $Kb.actions) { $kbMap[[string]$a.actionId] = $a } }

    # 1 REGISTRY
    if ($kbMap.Count -eq 0) {
        $checks += New-AdmitCheck 'REGISTRY' 'warn' 'KB_MISSING' 'action knowledge base not found; skipping REGISTRY/ARGS/SELECTOR' @()
    } else {
        $unknown = @($actionNodes | Where-Object { -not $kbMap.ContainsKey([string]$_.pad_hint) })
        if ($unknown.Count -gt 0) {
            $checks += New-AdmitCheck 'REGISTRY' 'fail' 'UNKNOWN_ACTION' 'some actions are missing from the KB' `
                @($unknown | ForEach-Object { "node $($_.id) $($_.pad_hint)" })
        } else {
            $checks += New-AdmitCheck 'REGISTRY' 'pass' 'OK' "$($actionNodes.Count) action(s) all found in the KB" @()
        }

        # 2 ARGS
        # Unknown parameter = hard failure (the generator rejects it too); a missing required one that the KB gives no default for
        # is only a warning: the generator skips that parameter and PAD actually accepts it (the golden example omits it too), so it should not block
        $argErrs = @()
        $argWarns = @()
        foreach ($n in $actionNodes) {
            $act = $kbMap[[string]$n.pad_hint]
            if (-not $act) { continue }
            $valid = @($act.input_params | ForEach-Object { [string]$_.name })
            $paramNames = @()
            if ($n.params) { $paramNames = @($n.params.PSObject.Properties.Name | Where-Object { $_ }) }
            foreach ($k in $paramNames) {
                if ($valid -notcontains $k) { $argErrs += "node $($n.id) unknown parameter $k" }
            }
            foreach ($p in @($act.input_params)) {
                if ($p.required -ne $true) { continue }
                # Handle-type parameters are wired up automatically by the generator from the Launch action, so flow.json never declares them
                if ([string]$p.type -match '(Instance|Handle)$' -or [string]$p.type -eq 'Browser') { continue }
                if ($null -ne $p.default) { continue }
                if ($paramNames -notcontains [string]$p.name) {
                    $argWarns += "node $($n.id) required parameter $($p.name) not written (no default in KB; omitted at generation time)"
                }
            }
        }
        if ($argErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'ARGS' 'fail' 'UNKNOWN_PARAM' 'parameter names do not match the KB' $argErrs
        } elseif ($argWarns.Count -gt 0) {
            $checks += New-AdmitCheck 'ARGS' 'warn' 'MISSING_PARAM' 'some required parameters are not given explicitly (omitted at generation time)' $argWarns
        } else {
            $checks += New-AdmitCheck 'ARGS' 'pass' 'OK' 'parameter names and required fields are complete' @()
        }

        # 3 SELECTOR
        $ui = @($actionNodes | Where-Object { $kbMap[[string]$_.pad_hint].needs_ui_selector -eq $true })
        if ($ui.Count -gt 0) {
            $checks += New-AdmitCheck 'SELECTOR' 'fail' 'UI_SELECTOR' 'these actions need recorded UI elements' `
                @($ui | ForEach-Object { "node $($_.id) $($_.pad_hint)" })
        } else {
            $checks += New-AdmitCheck 'SELECTOR' 'pass' 'OK' 'no action needs a UI selector' @()
        }
    }

    # 4 STATIC (reuse check.js; do not reimplement the syntax rules)
    if ($RobinPath -and (Test-Path -LiteralPath $RobinPath)) {
        $out = & node (Join-Path $Paths.Repo 'tools\pad-robin\check.js') $RobinPath 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $checks += New-AdmitCheck 'STATIC' 'pass' 'OK' 'static check: 0 errors' @()
        } else {
            $checks += New-AdmitCheck 'STATIC' 'fail' 'STATIC_SYNTAX' 'static check found errors' @($out.Trim() -split "`r?`n" | Select-Object -First 10)
        }
    } else {
        $checks += New-AdmitCheck 'STATIC' 'warn' 'ROBIN_MISSING' '.robin not found; skipping the static check' @()
    }

    # 5 EDGE
    if ($Flow.edges -and @($Flow.edges).Count -gt 0) {
        $out = & node (Join-Path $Paths.Repo 'tools\flow-drawio\check-flow.js') $Paths.FlowFile 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $checks += New-AdmitCheck 'EDGE' 'pass' 'OK' 'edges agree with next/branch' @()
        } else {
            $checks += New-AdmitCheck 'EDGE' 'fail' 'EDGE_DRIFT' 'edges disagree with next/branch' @($out.Trim() -split "`r?`n" | Select-Object -First 10)
        }
    } else {
        $checks += New-AdmitCheck 'EDGE' 'warn' 'EDGE_ABSENT' 'flow.json has no explicit edges; skipped' @()
    }

    # 6 BOUNDED
    $unbounded = @()
    foreach ($n in @($nodes | Where-Object { $_.pad_hint -eq 'LOOP' })) {
        $lp = $n.loop
        if (-not $lp) { $unbounded += "node $($n.id) has no loop definition"; continue }
        if ([string]$lp.kind -eq 'while') { $unbounded += "node $($n.id) is an unbounded LOOP WHILE"; continue }
        if ([string]$lp.kind -eq 'fromto' -and [string]::IsNullOrWhiteSpace([string]$lp.to)) {
            $unbounded += "node $($n.id) has no upper bound"
        }
    }
    if ($unbounded.Count -gt 0) {
        $checks += New-AdmitCheck 'BOUNDED' 'fail' 'UNBOUNDED_LOOP' 'some loops are unbounded or have no declared upper bound' $unbounded
    } else {
        $checks += New-AdmitCheck 'BOUNDED' 'pass' 'OK' 'every loop has an explicit upper bound' @()
    }

    # 7 POLICY
    $dryRun = $false
    if ($Config -and $Config.DRY_RUN) { $dryRun = ([string]$Config.DRY_RUN -eq '1') }
    $envName = if ($FlowName -eq 'PAD_SYNC_TEST') { 'test' } else { 'prod' }
    $registered = @{}
    foreach ($k in $kbMap.Keys) { $registered[$k] = $true }
    $ctx = @{ env = $envName; dryRun = $dryRun; registered = $registered }
    if ($Policy) {
        $checks += Invoke-AdmitPolicy $Flow $Policy $ctx -Unattended:$Unattended
    } else {
        $checks += New-AdmitCheck 'POLICY' 'warn' 'POLICY_MISSING' 'business\policy.json not found; skipping policy evaluation' @()
    }

    # 8 BUDGET (undeclared is a warn: report mode must not block existing flows)
    if ($Flow.budget) {
        $b = $Flow.budget
        $ev = @()
        $loops = @($nodes | Where-Object { $_.pad_hint -eq 'LOOP' -and $_.loop -and $_.loop.kind -eq 'fromto' })
        foreach ($n in $loops) {
            if ($b.maxLoop -and ([int]$n.loop.to - [int]$n.loop.from + 1) -gt [int]$b.maxLoop) {
                $ev += "node $($n.id) loops $($n.loop.to - $n.loop.from + 1) times, exceeding budget $($b.maxLoop)"
            }
        }
        if ($ev.Count -gt 0) {
            $checks += New-AdmitCheck 'BUDGET' 'fail' 'BUDGET_EXCEEDED' 'budget declaration exceeded' $ev
        } else {
            $checks += New-AdmitCheck 'BUDGET' 'pass' 'OK' 'within the budget declaration' @()
        }
    } else {
        $checks += New-AdmitCheck 'BUDGET' 'fail' 'BUDGET_UNKNOWN' 'flow.json does not declare budget; budget unknown (unknown is treated as exceeded)' @()
    }

    # 9 ACCEPTANCE
    $knownTypes = @('fileExists', 'globNewerThan', 'pair', 'json', 'jsonl', 'logState')
    if ($AcceptancePath -and (Test-Path -LiteralPath $AcceptancePath)) {
        $accErrs = @()
        try {
            $spec = [IO.File]::ReadAllText($AcceptancePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($c in @($spec.checks)) {
                if ($knownTypes -notcontains [string]$c.type) { $accErrs += "criterion '$($c.name)' has an unsupported type: $($c.type)" }
                foreach ($s in @($c.path, $c.dir) + @($c.paths)) {
                    if ($s -and ([string]$s -match '\{\{variables\.' -or [string]$s -match '%[A-Za-z_]\w*%')) {
                        $accErrs += "criterion '$($c.name)' has an unresolved reference: $s"
                    }
                }
            }
        } catch { $accErrs += "JSON parse failed: $($_.Exception.Message)" }
        if ($accErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'ACCEPTANCE' 'fail' 'ACCEPTANCE_INVALID' 'acceptance criteria are invalid' $accErrs
        } else {
            $checks += New-AdmitCheck 'ACCEPTANCE' 'pass' 'OK' "$(@($spec.checks).Count) criteria valid" @()
        }
    } else {
        $checks += New-AdmitCheck 'ACCEPTANCE' 'warn' 'ACCEPTANCE_MISSING' 'no acceptance criteria file' @()
    }

    # 10 CONFIG
    if ($Config -and $Paths.ConfigFile) {
        $schemaPath = [IO.Path]::ChangeExtension($Paths.ConfigFile, '.schema.json')
        $cfgErrs = @()
        if (Test-Path -LiteralPath $schemaPath) {
            try {
                $schema = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                foreach ($k in @($schema.required)) {
                    if ($Config.PSObject.Properties.Name -notcontains $k) { $cfgErrs += "missing required key $k" }
                }
            } catch { $cfgErrs += "schema parse failed: $($_.Exception.Message)" }
        } else {
            $cfgErrs += "schema not found: $schemaPath"
        }
        if ($cfgErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'CONFIG' 'fail' 'CONFIG_INVALID' 'deployment config is invalid' $cfgErrs
        } else {
            $checks += New-AdmitCheck 'CONFIG' 'pass' 'OK' 'config passes the schema required-field check' @()
        }
    } else {
        $checks += New-AdmitCheck 'CONFIG' 'warn' 'CONFIG_MISSING' 'no config provided; skipped' @()
    }

    # 11 PREFLIGHT
    if ($RequirementsPath -and (Test-Path -LiteralPath $RequirementsPath) -and $Config) {
        try {
            Import-Module (Join-Path $PSScriptRoot 'PadPreflight.psm1') -Force
            $req = [IO.File]::ReadAllText($RequirementsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $vars = @{}
            foreach ($p in $Config.PSObject.Properties) { $vars[$p.Name] = $p.Value }
            $probes = @(Invoke-PreflightChecks -Requirements $req -Variables $vars)
            $bad = @($probes | Where-Object { -not $_.Ok })
            if ($bad.Count -gt 0) {
                $checks += New-AdmitCheck 'PREFLIGHT' 'fail' 'PREFLIGHT_MISSING' 'environment dependencies missing' `
                    @($bad | ForEach-Object { "$($_.Name): $($_.Detail)" })
            } else {
                $checks += New-AdmitCheck 'PREFLIGHT' 'pass' 'OK' "$($probes.Count) environment dependencies are all present" @()
            }
        } catch {
            $checks += New-AdmitCheck 'PREFLIGHT' 'warn' 'PREFLIGHT_ERROR' "environment probe failed: $($_.Exception.Message)" @()
        }
    } else {
        $checks += New-AdmitCheck 'PREFLIGHT' 'warn' 'PREFLIGHT_SKIPPED' 'requirements or config missing; skipped' @()
    }

    # 12 FINGERPRINT (the mechanism and hashing live in PadFingerprint.psm1; this script does not write a second copy)
    # Result codes: pass / FINGERPRINT_MISMATCH / FINGERPRINT_UNKNOWN / FINGERPRINT_NO_BASELINE /
    #               FINGERPRINT_FLOW_STALE / SOURCE_MISMATCH / CONFIG_STALE / BASELINE_CORRUPT / AMBIGUOUS
    $basePath = $null
    if ($Paths.Repo -and $FlowName) { $basePath = Get-FingerprintBaselinePath $Paths.Repo $FlowName }
    $fp = Test-FlowFingerprint -FlowName $FlowName -RobinPath $RobinPath -ConfigPath $Paths.ConfigFile `
        -AcceptancePath $AcceptancePath -BaselinePath $basePath `
        -ScriptsRoot $Paths.ScriptsRoot -EnvironmentId $Paths.EnvironmentId `
        -ApprovePath $ApprovePath -FlowFilePath $Paths.FlowFile `
        -FlowDisplayName $FlowDisplayName -NoBaselineMode $NoBaselineMode -Mode $script:FingerprintMode
    $checks += New-AdmitCheck 'FINGERPRINT' $fp.status $fp.code $fp.message $fp.evidence

    # 13 SCRIPT_FINGERPRINT (v3 observation period: warn only, never blocks)
    # The module returns warn (SCRIPT_FINGERPRINT_LEGACY) when an old baseline has no scripts section and never fails;
    # on a mismatch, evidence names each file and both short hashes
    if ($basePath) {
        $sf = Test-ScriptFingerprint -BaselinePath $basePath -RepoRoot $Paths.Repo
        $checks += New-AdmitCheck 'SCRIPT_FINGERPRINT' $sf.status $sf.code $sf.message $sf.evidence
    }

    # 14 INTENT
    $noIntent = @($actionNodes | Where-Object {
        ([string]$_.pad_hint -like 'Scripting.RunDOSCommand*' -or [string]$_.pad_hint -like 'Scripting.RunVBScript*') -and -not $_.intent
    })
    if ($noIntent.Count -gt 0) {
        $checks += New-AdmitCheck 'INTENT' 'fail' 'MISSING_INTENT' 'generic script actions lack an intent tag; policy can only identify them by parameter name (renaming bypasses it)' `
            @($noIntent | ForEach-Object { "node $($_.id) $($_.pad_hint)" })
    } else {
        $checks += New-AdmitCheck 'INTENT' 'pass' 'OK' 'all generic script actions have an intent' @()
    }

    # 15 TRIGGER (static validation; adds the read-only registration check with -TriggerLive)
    $checks += @(Invoke-TriggerCheck -Flow $Flow -FlowName $FlowName `
        -Repo $Paths.Repo -SelfFile $Paths.FlowFile -ConfigFile $Paths.ConfigFile `
        -TriggerLive:$TriggerLive)

    # 16 INPUT (node-level input-file declarations: read-only enumeration; missing files / multiple candidates are reported before the run)
    $checks += @(Invoke-InputCheck -Flow $Flow -Config $Config -ConfigFile $Paths.ConfigFile)

    return $checks
}

if (-not $NoMain) {
    $result = [ordered]@{ ok = $false; flow = $FlowName; fingerprint = $null; checks = @(); summary = $null }
    $exitCode = 1
    try {
        $repo = $script:RepoRoot
        $nameFromLookup = $false
        if (-not $FlowFile) {
            # No longer defaulting to one particular business flow: derive from the flow name first, otherwise require a unique match
            $flowsDir = Join-Path $repo 'business\flows'
            if ($FlowName) {
                # pad_flow_name first, then file name / name; more than one hit is ADMIT_AMBIGUOUS_FLOW
                $FlowFile = Resolve-FlowFileByName $flowsDir $FlowName
                if (-not $FlowFile) {
                    throw "E_FLOW_FILE_REQUIRED: -FlowFile not provided, and deriving it from the flow name failed: $FlowName (no match on pad_flow_name / file name / name under business\flows); specify it with -FlowFile"
                }
                $nameFromLookup = $true
            } else {
                # Only accept flow definitions: exclude companion json files such as accept/requirements/schema,
                # then use the structural feature "has a non-empty nodes array" to filter out same-directory artifacts like deploy_diff.json
                $cands = @(Get-ChildItem -LiteralPath $flowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' } |
                    Where-Object {
                        try {
                            $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                            ($j.PSObject.Properties.Name -contains 'nodes') -and (@($j.nodes).Count -gt 0)
                        } catch { $false }
                    })
                if ($cands.Count -eq 1) {
                    $FlowFile = $cands[0].FullName
                } elseif ($cands.Count -eq 0) {
                    throw "E_FLOW_FILE_REQUIRED: -FlowFile not provided and the flows directory has no flow definition .json; specify it with -FlowFile"
                } else {
                    throw ("E_FLOW_FILE_AMBIGUOUS(candidates=$($cands.Count)): -FlowFile not provided; found $($cands.Count) candidates; specify one with -FlowFile: " +
                        (($cands | ForEach-Object { $_.Name }) -join ', '))
                }
            }
        }
        $FlowFile = (Resolve-Path -LiteralPath $FlowFile).Path
        # When derived by name, identity always comes from the file name: the display name is only a lookup key and must not
        # serve as the flow identity (it would affect the policy env and the baseline path)
        if ($nameFromLookup) {
            $FlowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile)
        } elseif (-not $FlowName) { $FlowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile) }
        if (-not $RobinFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.robin')
            if (Test-Path -LiteralPath $guess) { $RobinFile = $guess }
        }
        if (-not $AcceptanceFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.acceptance.json')
            if (Test-Path -LiteralPath $guess) { $AcceptanceFile = $guess }
        }
        if (-not $RequirementsFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.requirements.json')
            if (Test-Path -LiteralPath $guess) { $RequirementsFile = $guess }
        }
        if (-not $PolicyFile) { $PolicyFile = Join-Path $repo 'business\policy.json' }
        if (-not $KbPath) {
            $guess = Join-Path $repo 'pad-robin-action-kb\PAD_Robin_ActionKB.json'
            if (Test-Path -LiteralPath $guess) { $KbPath = $guess }
        }

        $flow = [IO.File]::ReadAllText($FlowFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $config = $null
        # A missing config is not fatal: CONFIG / PREFLIGHT / FINGERPRINT each record their own warn
        if ($ConfigFile -and (Test-Path -LiteralPath $ConfigFile)) {
            $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
            $config = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        } else {
            $ConfigFile = $null
        }
        $kb = $null
        if ($KbPath -and (Test-Path -LiteralPath $KbPath)) {
            $kb = [IO.File]::ReadAllText($KbPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        $policy = $null
        if ($PolicyFile -and (Test-Path -LiteralPath $PolicyFile)) {
            $policy = [IO.File]::ReadAllText($PolicyFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }

        # The fingerprint check needs "local run history" and "current environment": read-only, no state is changed
        $paths = @{
            Repo = $repo; FlowFile = $FlowFile; ConfigFile = $ConfigFile
            ScriptsRoot = (Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts')
            EnvironmentId = (Get-PadEnvironmentId)
        }
        $result.flow = $FlowName
        # Report mode allows "unpublished = no baseline" to warn only; -Unattended is the release/deploy/schedule path and must fail
        $noBaselineMode = $(if ($Unattended) { 'fail' } else { 'warn' })
        $result.checks = @(Invoke-AdmitChecks -Flow $flow -FlowName $FlowName -Config $config -Kb $kb `
            -RobinPath $RobinFile -AcceptancePath $AcceptanceFile -RequirementsPath $RequirementsFile `
            -Policy $policy -ApprovePath $ApproveFile -Paths $paths `
            -FlowDisplayName ([string]$flow.pad_flow_name) -NoBaselineMode $noBaselineMode `
            -TriggerLive:([bool]$TriggerLive))

        $fail = @($result.checks | Where-Object { $_.status -eq 'fail' })
        $ask = @($result.checks | Where-Object { $_.status -eq 'ask' })
        $warn = @($result.checks | Where-Object { $_.status -eq 'warn' })
        $result.ok = ($fail.Count -eq 0 -and $ask.Count -eq 0)
        $result.summary = [ordered]@{
            total = @($result.checks).Count; pass = @($result.checks | Where-Object { $_.status -eq 'pass' }).Count
            warn = $warn.Count; ask = $ask.Count; fail = $fail.Count
        }
        $exitCode = if ($fail.Count -gt 0) { 1 } elseif ($ask.Count -gt 0) { 2 } else { 0 }
    } catch {
        $result.checks = @(New-AdmitCheck 'ADMIT' 'fail' 'ADMIT_ERROR' $_.Exception.Message @())
        $result.summary = [ordered]@{ total = 1; pass = 0; warn = 0; ask = 0; fail = 1 }
        $exitCode = 1
    }

    if (-not $Json) {
        foreach ($c in $result.checks) {
            Write-Host ("[{0}] {1} {2}: {3}" -f $c.status.ToUpper(), $c.id, $c.code, $c.message)
            foreach ($e in @($c.evidence)) { if ($e) { Write-Host "        - $e" } }
        }
        Write-Host ("[admit] pass {0} / warn {1} / ask {2} / fail {3}" -f `
            $result.summary.pass, $result.summary.warn, $result.summary.ask, $result.summary.fail)
    }
    Write-Output ('PAD_ADMIT_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
    exit $exitCode
}
