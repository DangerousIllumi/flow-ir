# TriggerRegistry.psm1 — trigger declaration parsing and scheduled-task registration
#
# Implements manual and schedule only; the file branch is a stub (part 4).
# Action construction reuses pad-schedule.ps1 (dot-sourced with -NoMain) instead of copying a launcher.
# Failures are always hard failures: throw an exception, let the caller turn it into a non-zero exit code, and write a PadAlerts alert when registration/unregistration fails.

$moduleHere = $PSScriptRoot
$moduleRepo = Split-Path -Parent (Split-Path -Parent $moduleHere)

Import-Module (Join-Path $moduleHere 'PadAlerts.psm1') -Force
# -NoMain: load functions and variables only, do not execute the registration main flow
. (Join-Path $moduleHere 'pad-schedule.ps1') -NoMain

# Value domain of the trigger declaration, kept in sync with the TRIGGER checks in pad-admit
$script:TriggerKinds = @('manual', 'schedule', 'file')
$script:TriggerReservedKinds = @('mail', 'callback')
$script:TriggerDays = @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
$script:TriggerGates = @('none', 'workday', 'last-workday')

function Test-TriggerProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
    return (@($Obj.PSObject.Properties.Name) -contains $Name)
}

# Exception carrying a result code: the CLI and pad-admit classify by Data['code'] and never parse the Chinese message
function New-TriggerException([string]$Code, [string]$Message) {
    $ex = New-Object System.Exception($Message)
    $ex.Data['code'] = $Code
    return $ex
}

function Test-TriggerPositiveInt($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $false }
    $d = [double]$Value
    return ($d -gt 0 -and $d -eq [math]::Floor($d))
}

# Read the flow file; a missing, absent or non-JSON FlowFile is always an input error
function Read-TriggerFlow([string]$FlowFile) {
    if (-not $FlowFile) { throw (New-TriggerException 'TRIGGER_INPUT_MISSING' 'missing -FlowFile') }
    if (-not (Test-Path -LiteralPath $FlowFile)) {
        throw (New-TriggerException 'TRIGGER_INPUT_MISSING' "flow file not found: $FlowFile")
    }
    try {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FlowFile).Path, [Text.Encoding]::UTF8)
        return ($text | ConvertFrom-Json)
    } catch {
        throw (New-TriggerException 'TRIGGER_INPUT_INVALID' "flow file is not valid JSON: $FlowFile ($($_.Exception.Message))")
    }
}

# Parse the trigger declaration and return a normalized object; no system queries happen here
function Get-TriggerSpec {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
    $flow = Read-TriggerFlow $FlowFile
    $trg = $null
    if (Test-TriggerProp $flow 'trigger') { $trg = $flow.trigger }
    if ($null -eq $trg) {
        throw (New-TriggerException 'TRIGGER_MISSING' 'the flow has no trigger declaration; cannot determine how it starts')
    }
    if (-not (Test-TriggerProp $trg 'kind') -and (Test-TriggerProp $trg 'type')) {
        throw (New-TriggerException 'TRIGGER_LEGACY_SHAPE' 'trigger uses the legacy type/config shape; migrate it to kind')
    }
    if (-not (Test-TriggerProp $trg 'kind') -or -not [string]$trg.kind) {
        throw (New-TriggerException 'TRIGGER_INVALID' 'trigger.kind is missing or not a string')
    }
    $kind = [string]$trg.kind
    if ($script:TriggerReservedKinds -contains $kind) {
        throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' "kind=$kind is a reserved value; v1 has no registrar for it")
    }
    if ($script:TriggerKinds -notcontains $kind) {
        throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$kind is not one of manual/schedule/file")
    }

    # Flow name: prefer the PAD display name pad_flow_name, then the internal name, finally the file name.
    # The task name and -FlowName are both derived from here and must share one source: when the internal name differs from the PAD display name,
    # using the internal name derives a wrong task name, and pad-sync also fails to find the flow by its display name.
    $flowName = $null
    if ((Test-TriggerProp $flow 'pad_flow_name') -and [string]$flow.pad_flow_name) {
        $flowName = [string]$flow.pad_flow_name
    }
    if (-not $flowName -and (Test-TriggerProp $flow 'name') -and [string]$flow.name) {
        $flowName = [string]$flow.name
    }
    if (-not $flowName) { $flowName = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path -LiteralPath $FlowFile).Path) }

    $time = $null
    $days = @('mon', 'tue', 'wed', 'thu', 'fri')
    $daysDeclared = $false
    $gate = 'none'
    $timeoutSec = 4200
    $assisted = $false
    $fileDir = $null
    $filePattern = $null
    # Defaults for the file trigger, consistent with design draft 2.1; poll floor of 15 seconds to avoid spinning and hammering the disk
    $filePollSec = 60
    $fileSettleSec = 60
    $fileMaxWaitSec = 7200
    $fileOncePerFile = $true
    # Declaration-level warnings (warn): do not block registration, returned with the spec for the caller to display
    $triggerWarnings = @()

    if ($kind -eq 'manual') {
        foreach ($k in @('time', 'days', 'gate', 'timeout_sec', 'file', 'assisted')) {
            if (Test-TriggerProp $trg $k) {
                throw (New-TriggerException 'TRIGGER_INVALID' "manual must not declare $k (nothing would execute it)")
            }
        }
    } else {
        if ((Test-TriggerProp $trg 'time')) { $time = [string]$trg.time }
        if (-not $time -or $time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            throw (New-TriggerException 'TRIGGER_INVALID' "time=$time (expected HH:mm, e.g. 09:00)")
        }
        if ((Test-TriggerProp $trg 'days')) {
            $daysDeclared = $true
            $days = @($trg.days)
            $bad = @($days | Where-Object { $script:TriggerDays -notcontains [string]$_ })
            if ($days.Count -eq 0 -or $bad.Count -gt 0) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'days must be a non-empty array with values mon..sun')
            }
        }
        if ((Test-TriggerProp $trg 'gate')) { $gate = [string]$trg.gate }
        if ($script:TriggerGates -notcontains $gate) {
            throw (New-TriggerException 'TRIGGER_INVALID' "gate=$gate is not one of none/workday/last-workday")
        }
        if ((Test-TriggerProp $trg 'timeout_sec')) {
            if (-not (Test-TriggerPositiveInt $trg.timeout_sec)) {
                throw (New-TriggerException 'TRIGGER_INVALID' "timeout_sec=$($trg.timeout_sec) (expected a positive integer number of seconds)")
            }
            $timeoutSec = [int]$trg.timeout_sec
        }
        if ($kind -eq 'file') {
            if (-not (Test-TriggerProp $trg 'file')) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file trigger requires a file object')
            }
            $f = $trg.file
            if (Test-TriggerProp $f 'dir') { $fileDir = [string]$f.dir }
            if (-not $fileDir) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file.dir is required')
            }
            # Only config references are accepted: a literal path cannot be reused on another machine and cannot be resolved at registration
            if ($fileDir -notmatch '^\{\{config\.(\w+)\}\}$') {
                throw (New-TriggerException 'TRIGGER_PATH_LITERAL' "file.dir must be a {{config.<KEY>}} reference: $fileDir")
            }
            if (Test-TriggerProp $f 'pattern') { $filePattern = [string]$f.pattern }
            if (-not $filePattern -or $filePattern.Trim().Length -eq 0) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file.pattern is required and must not be empty')
            }
            if (Test-TriggerProp $f 'poll_sec') {
                if (-not (Test-TriggerPositiveInt $f.poll_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.poll_sec=$($f.poll_sec) (expected a positive integer number of seconds)")
                }
                $filePollSec = [int]$f.poll_sec
            }
            if ($filePollSec -lt 15) {
                throw (New-TriggerException 'TRIGGER_INVALID' "file.poll_sec=$filePollSec is below the 15s minimum")
            }
            if (Test-TriggerProp $f 'settle_sec') {
                if (-not (Test-TriggerPositiveInt $f.settle_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.settle_sec=$($f.settle_sec) (expected a positive integer number of seconds)")
                }
                $fileSettleSec = [int]$f.settle_sec
            }
            if (Test-TriggerProp $f 'max_wait_sec') {
                if (-not (Test-TriggerPositiveInt $f.max_wait_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.max_wait_sec=$($f.max_wait_sec) (expected a positive integer number of seconds)")
                }
                $fileMaxWaitSec = [int]$f.max_wait_sec
            }
            if (Test-TriggerProp $f 'once_per_file') {
                if (-not ($f.once_per_file -is [bool])) {
                    throw (New-TriggerException 'TRIGGER_INVALID' 'file.once_per_file must be true/false')
                }
                $fileOncePerFile = [bool]$f.once_per_file
            }
        }
        # assisted: starts automatically at the scheduled time with a human confirming midway; timeout_sec must be declared explicitly because nobody clicking falls back to the timeout alert
        if (Test-TriggerProp $trg 'assisted') {
            if (-not ($trg.assisted -is [bool])) {
                throw (New-TriggerException 'TRIGGER_INVALID' "assisted=$($trg.assisted) (expected true/false)")
            }
            $assisted = [bool]$trg.assisted
            if ($assisted -and -not (Test-TriggerProp $trg 'timeout_sec')) {
                throw (New-TriggerException 'TRIGGER_ASSISTED_NO_TIMEOUT' `
                    'assisted=true requires an explicit timeout_sec (the timeout alert is the fallback when nobody confirms)')
            }
        }
        # An unattended trigger facing manual-confirmation nodes is a hard contradiction; an explicit assisted=true means a human confirms midway and is allowed
        $confirm = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'run_mode') -and [string]$_.run_mode -eq 'confirm'
        })
        if ($confirm.Count -gt 0 -and -not $assisted) {
            throw (New-TriggerException 'TRIGGER_UNATTENDED_CONFIRM' `
                ("unattended trigger but nodes require manual confirmation: " + (@($confirm | ForEach-Object { $_.id }) -join ',')))
        }
        # Reversibility narrowing: an axis orthogonal to idempotency.
        #   idempotent = does re-running the same input converge (safe to re-run)
        #   reversible = can the effects already produced be undone (deletes can be recreated, mail can be corrected, postings can only be reversed)
        # Unattended only warns about "irreversible consequences" and is no longer triggered by idempotent=false.
        $irreversible = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'reversible') -and $_.reversible -eq $false
        })
        foreach ($n in $irreversible) {
            $note = $null
            if (Test-TriggerProp $n 'reversibility_note') { $note = [string]$n.reversibility_note }
            $triggerWarnings += [ordered]@{
                code     = 'TRIGGER_UNATTENDED_IRREVERSIBLE'
                message  = "unattended trigger but node $($n.id) has irreversible consequences (reversible=false)"
                evidence = @("node $($n.id) reversible=false" + $(if ($note) { ": $note" } else { '' }))
            }
        }
        # idempotent=false without a reversible declaration: prompt to add the declaration, never fill it in by default
        $missingRev = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'idempotent') -and $_.idempotent -eq $false -and
            -not (Test-TriggerProp $_ 'reversible')
        })
        foreach ($n in $missingRev) {
            $triggerWarnings += [ordered]@{
                code     = 'TRIGGER_MISSING_REVERSIBILITY'
                message  = "node $($n.id) idempotent=false but reversible is not declared"
                evidence = @("node $($n.id) idempotent=false; reversible not declared")
            }
        }
    }

    # Scheduled-task trigger shape: when days is declared, build a weekly task for those weekdays (no wake-up on weekends, the calendar gate decides on workdays);
    # the file watcher is always weekly; without days and with a calendar gate, keep the old daily behaviour.
    $scheduleKind = $null
    if ($kind -ne 'manual') {
        $scheduleKind = 'daily'
        if ($kind -eq 'file' -or $daysDeclared -or $gate -eq 'none') { $scheduleKind = 'weekly' }
    }

    $taskName = $null
    if ($kind -ne 'manual') {
        if ((Test-TriggerProp $trg 'task_name')) {
            $taskName = [string]$trg.task_name
            if ($taskName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
                throw (New-TriggerException 'TRIGGER_INVALID' "task_name=$taskName does not match ^[A-Za-z0-9._-]{1,64}$")
            }
        }
        if (-not $taskName) { $taskName = Get-ScheduleTaskName $flowName }
    }

    return [ordered]@{
        kind         = $kind
        flowName     = $flowName
        flowFile     = (Resolve-Path -LiteralPath $FlowFile).Path
        configFile   = $ConfigFile
        taskName     = $taskName
        time         = $time
        days         = $days
        daysDeclared = $daysDeclared
        scheduleKind = $scheduleKind
        gate         = $gate
        timeoutSec   = $timeoutSec
        assisted     = $assisted
        fileDir      = $fileDir
        filePattern  = $filePattern
        filePollSec  = $filePollSec
        fileSettleSec = $fileSettleSec
        fileMaxWaitSec = $fileMaxWaitSec
        fileOncePerFile = $fileOncePerFile
        # Declaration-level warn: the caller can display it directly; it does not block registration
        warnings     = @($triggerWarnings)
        raw          = $trg
    }
}

# Idempotency key: SHA256 over explicitly normalized fields; key order and whitespace do not affect the result
function Get-TriggerFingerprint {
    param([Parameter(Mandatory)]$Spec)
    $canon = [ordered]@{
        kind       = [string]$Spec.kind
        flowName   = [string]$Spec.flowName
        taskName   = [string]$Spec.taskName
        time       = [string]$Spec.time
        days       = @($Spec.days)
        # The trigger shape enters the hash: explicit days and omitted days behave differently and must not be judged unchanged
        scheduleKind = [string]$Spec.scheduleKind
        gate       = [string]$Spec.gate
        timeoutSec = [int]$Spec.timeoutSec
        assisted   = [bool]$Spec.assisted
    }
    if ([string]$Spec.kind -eq 'file') {
        $canon['fileDir'] = [string]$Spec.fileDir
        $canon['filePattern'] = [string]$Spec.filePattern
        $canon['filePollSec'] = [string]$Spec.filePollSec
        $canon['fileSettleSec'] = [string]$Spec.fileSettleSec
        $canon['fileMaxWaitSec'] = [string]$Spec.fileMaxWaitSec
        $canon['fileOncePerFile'] = [string]$Spec.fileOncePerFile
    }
    $json = $canon | ConvertTo-Json -Compress -Depth 6
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return ((($sha.ComputeHash($bytes)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

# Runtime config path: an explicit -RuntimeConfigPath wins; otherwise only the single business\config\runtime.json in the repository is accepted
# Extracted separately because file registration must write the real path into the task action, not merely take the config object
function Resolve-TriggerRuntimeConfigPath {
    param([string]$RuntimeConfigPath)
    if ($RuntimeConfigPath) {
        if (-not (Test-Path -LiteralPath $RuntimeConfigPath)) {
            throw (New-TriggerException 'CONFIG_MISSING' "runtime config not found: $RuntimeConfigPath")
        }
        return (Resolve-Path -LiteralPath $RuntimeConfigPath).Path
    }
    $candidate = Join-Path $moduleRepo 'business\config\runtime.json'
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw (New-TriggerException 'CONFIG_MISSING' `
            'missing -RuntimeConfigPath and the repository has no business\config\runtime.json; specify the runtime config explicitly')
    }
    return $candidate
}

function Resolve-TriggerRuntimeConfig {
    param([string]$RuntimeConfigPath)
    $path = Resolve-TriggerRuntimeConfigPath -RuntimeConfigPath $RuntimeConfigPath
    try {
        $cfg = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'CONFIG_INVALID' "runtime config is not valid JSON: $path ($($_.Exception.Message))")
    }
    foreach ($k in @('PadSyncPath', 'PythonExe', 'CalendarPath', 'WorkdayScript', 'RunTimeoutSec')) {
        if (-not (Test-TriggerProp $cfg $k) -or -not [string]$cfg.$k) {
            throw (New-TriggerException 'CONFIG_MISSING' "runtime config is missing $k ($path)")
        }
    }
    return $cfg
}

# Turn the spec into a scheduled-task action; still calls pad-schedule's New-ScheduleActionSpec
function Get-TriggerActionSpec {
    param($Spec, $Runtime, [switch]$AllowProd)
    $common = @{
        FlowName      = $Spec.flowName
        ConfigFile    = $Spec.configFile
        RunTimeoutSec = [int]$Spec.timeoutSec
    }
    if ($AllowProd) { $common.AllowProd = $true }

    if ($Spec.gate -eq 'workday' -or $Spec.gate -eq 'last-workday') {
        # Gate branch: the task first calls pad-schedule to evaluate the calendar, then decides whether to run pad-sync
        $specArgs = $common.Clone()
        $specArgs.ScriptPath = Join-Path $moduleHere 'pad-schedule.ps1'
        $specArgs.PadSyncPath = [string]$Runtime.PadSyncPath
        $specArgs.PythonExe = [string]$Runtime.PythonExe
        $specArgs.CalendarPath = [string]$Runtime.CalendarPath
        $specArgs.WorkdayScript = [string]$Runtime.WorkdayScript
        if ($Spec.gate -eq 'last-workday') { $specArgs.LastWorkdayGate = $true } else { $specArgs.WorkdayGate = $true }
        return (New-ScheduleActionSpec @specArgs)
    }
    $common.ScriptPath = [string]$Runtime.PadSyncPath
    return (New-ScheduleActionSpec @common)
}

# The task description carries specHash, used for idempotency and read-back
function Get-TaskSpecHash([string]$Description) {
    if (-not $Description) { return $null }
    $m = [regex]::Match([string]$Description, 'flow-ir-spec:([0-9a-f]{64})')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Whether the task matches the declaration: description hash + action executable/arguments must all agree.
# -AllowProd is a call switch used at registration and is not part of the trigger's canonical fingerprint;
# -Test only checks declaration consistency and ignores that token, otherwise a production task would always be judged drift.
# Registration/read-back still compare strictly, so a task registered without -AllowProd is caught before it is refused in production.
function Test-TriggerTaskMatch {
    param($Task, $ActionSpec, [string]$SpecHash, [switch]$IgnoreAllowProd)
    if (-not $Task) { return $false }
    if ((Get-TaskSpecHash ([string]$Task.Description)) -ne $SpecHash) { return $false }
    $action = @($Task.Actions)[0]
    if (-not $action) { return $false }
    $expected = [string]$ActionSpec.args
    $actual = [string]$action.Arguments
    if ($IgnoreAllowProd) {
        $stripped = { param($s) ([regex]::Replace([string]$s, '\s+-AllowProd(?=\s|$)', '')).Trim() }
        $expected = (& $stripped $expected)
        $actual = (& $stripped $actual)
    }
    return ([string]$action.Execute -eq [string]$ActionSpec.exe -and $actual -eq $expected)
}

function Assert-TriggerReadback {
    param($Task, $ActionSpec, [string]$SpecHash, [string]$TaskName)
    if (-not $Task) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "task not found on readback after registration: $TaskName")
    }
    if (-not (Test-TriggerTaskMatch $Task $ActionSpec $SpecHash)) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "readback check failed: the task description hash or action arguments disagree with the declaration ($TaskName)")
    }
}

function Get-TriggerSummary($Spec) {
    if ($Spec.kind -eq 'manual') { return 'manual (started by hand or an external link; no registration needed)' }
    if ($Spec.kind -eq 'file') {
        return "file $($Spec.fileDir)\$($Spec.filePattern) (watching from $($Spec.time) for $($Spec.fileMaxWaitSec)s)"
    }
    return "$($Spec.kind) $($Spec.time) (gate=$($Spec.gate))"
}

# ---- read-only config resolution and directory probing for the file branch ----

# Resolve {{config.<KEY>}}: read-only, not touching PadConfig's fixed key set or validation criteria.
# Arbitrary business keys may appear in a flow config (keys PadConfig does not manage); a failed resolution is a hard failure and never falls back to a literal path.
function Resolve-TriggerConfigRef {
    param([string]$Token, [string]$ConfigFile)
    if (-not $Token) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' 'file.dir is empty; cannot resolve it')
    }
    $m = [regex]::Match([string]$Token, '^\{\{config\.(\w+)\}\}$')
    if (-not $m.Success) {
        throw (New-TriggerException 'TRIGGER_PATH_LITERAL' "file.dir must be a {{config.<KEY>}} reference: $Token")
    }
    $key = $m.Groups[1].Value
    if (-not $ConfigFile) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "missing -ConfigFile; cannot resolve {{config.$key}}")
    }
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config file not found: $ConfigFile")
    }
    try {
        $cfg = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigFile).Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config file is not valid JSON: $ConfigFile ($($_.Exception.Message))")
    }
    if (-not (Test-TriggerProp $cfg $key) -or -not [string]$cfg.$key) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config has no usable key $key ($ConfigFile)")
    }
    return [string]$cfg.$key
}

# List candidates: directory/permission problems always throw TRIGGER_FILE_DIR_UNREADABLE, never guess
function Get-TriggerFileCandidates {
    param([string]$Dir, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw (New-TriggerException 'TRIGGER_FILE_DIR_UNREADABLE' "watch directory not found: $Dir")
    }
    try {
        return @(Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction Stop)
    } catch {
        throw (New-TriggerException 'TRIGGER_FILE_DIR_UNREADABLE' "watch directory is unreadable: $Dir ($($_.Exception.Message))")
    }
}

# State directory: the runtime config may set TriggerStateDir; the default is business\state\triggers (business area, already gitignored)
function Resolve-TriggerStateDir($Runtime) {
    if ($Runtime -and (Test-TriggerProp $Runtime 'TriggerStateDir') -and [string]$Runtime.TriggerStateDir) {
        return [string]$Runtime.TriggerStateDir
    }
    return (Join-Path $moduleRepo 'business\state\triggers')
}

# Find the deepest existing ancestor: when the directory has not been created yet, probe only whether its parent is writable
function Get-TriggerExistingAncestor([string]$Path) {
    $cur = $Path
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $cur
}

# Writability probe: read ACLs only, no probe file. Match Allow rules by the current user SID and the groups it belongs to
function Test-TriggerDirWritable([string]$Path) {
    $target = Get-TriggerExistingAncestor $Path
    if (-not $target) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $false }
        $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $mySid = $identity.User.Value
        $groupSids = @($identity.Groups | ForEach-Object { $_.Value })
        foreach ($rule in $acl.Access) {
            if ([string]$rule.AccessControlType -ne 'Allow') { continue }
            try { $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
            if ($ruleSid -ne $mySid -and $groupSids -notcontains $ruleSid) { continue }
            if ([string]$rule.FileSystemRights -match 'Write|Modify|FullControl|CreateFiles') { return $true }
        }
        return $false
    } catch {
        return $false
    }
}

# ---- run layer for the file branch: state ledger and watcher ----

# Ledger key: fileName|size|lastWriteUtc, so the same file (even with unchanged content) triggers only once
function Get-TriggerFileKey($File) {
    return ('{0}|{1}|{2}' -f $File.Name, $File.Length, $File.LastWriteTimeUtc.ToString('o'))
}

function Get-TriggerLedgerPath($Spec, $Runtime) {
    $dir = Resolve-TriggerStateDir $Runtime
    return (Join-Path $dir ($Spec.taskName + '.json'))
}

# Read the ledger: a missing file counts as empty; an existing but invalid JSON is a hard failure, so history de-duplication is not silently lost
function Read-TriggerLedger([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'TRIGGER_LEDGER_INVALID' "state ledger is not valid JSON: $Path ($($_.Exception.Message))")
    }
    if (-not (Test-TriggerProp $json 'keys')) { return @() }
    return @($json.keys | ForEach-Object { [string]$_ })
}

# Append a key: returns $false when already in the ledger (duplicate delivery, do not trigger again); $true when newly added
function Add-TriggerLedgerKey([string]$Path, [string]$Key) {
    $keys = @(Read-TriggerLedger $Path)
    if ($keys -contains $Key) { return $false }
    $keys += $Key
    # Keep only the most recent 200 entries so the ledger cannot grow without bound
    if ($keys.Count -gt 200) { $keys = @($keys[($keys.Count - 200)..($keys.Count - 1)]) }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{ keys = $keys; updatedAt = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding($false)))
    return $true
}

# ---- registrars split by kind ----

# Scheduled-task settings: explicitly disable StartWhenAvailable instead of relying on the template default.
# Reason: triggers missed while the machine is asleep/off (e.g. the two 09:00 runs over a weekend) are made up immediately after resume,
# and the calendar gate only asks "is today a workday", which cannot tell that this is a missed instance, causing unscheduled execution.
# Trade-off: if the machine is not on at 9:00 the flow does not run that day; better to miss a run than to run early.
function New-ScheduleTaskSettings {
    param([int]$ExecutionTimeLimitMinutes)
    return (New-ScheduledTaskSettingsSet -StartWhenAvailable:$false `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionTimeLimitMinutes) -MultipleInstances IgnoreNew)
}

# Task trigger shape: weekly builds on the declared/default weekdays; daily keeps waking every day and lets the calendar gate skip by itself
function New-ScheduleTaskTrigger($Spec) {
    if ([string]$Spec.scheduleKind -eq 'weekly') {
        $dayMap = @{
            mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'
            fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday'
        }
        $daysOfWeek = @($Spec.days | ForEach-Object { $dayMap[[string]$_] })
        return (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $daysOfWeek -At (ConvertTo-ScheduleTime $Spec.time))
    }
    return (New-ScheduledTaskTrigger -Daily -At (ConvertTo-ScheduleTime $Spec.time))
}

function Register-ScheduleTrigger {
    param($Spec, [string]$RuntimeConfigPath, [switch]$DryRun, [switch]$AllowProd)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $actionSpec = Get-TriggerActionSpec -Spec $Spec -Runtime $runtime -AllowProd:$AllowProd
    $hash = Get-TriggerFingerprint -Spec $Spec
    $description = "flow-ir-spec:$hash；flow-ir：$($Spec.kind) $($Spec.time) 触发，运行 PAD 流程 $($Spec.flowName)（attended）"

    if ($DryRun) {
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = 'planned'; dryRun = $true
            description = $description; exe = $actionSpec.exe; args = $actionSpec.args
            evidence = @('DryRun: scheduled task not written')
        }
    }

    $existing = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (Test-TriggerTaskMatch $existing $actionSpec $hash) {
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = 'unchanged'; dryRun = $false
            evidence = @('already registered with a matching specHash; nothing written')
        }
    }
    $changed = $(if ($existing) { 'updated' } else { 'created' })

    try {
        # Exactly the same shape as pad-schedule: hidden window + Interactive identity + ignore new instances
        $taskTrigger = New-ScheduleTaskTrigger $Spec
        $settings = New-ScheduleTaskSettings -ExecutionTimeLimitMinutes 180
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $Spec.taskName `
            -Action (New-ScheduledTaskAction -Execute $actionSpec.exe -Argument $actionSpec.args) `
            -Trigger $taskTrigger -Settings $settings -Principal $principal `
            -Force -Description $description | Out-Null

        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction Stop
        Assert-TriggerReadback -Task $task -ActionSpec $actionSpec -SpecHash $hash -TaskName $Spec.taskName
        $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
        if (-not $info.NextRunTime) {
            throw (New-TriggerException 'TRIGGER_DRIFT' "task is registered but has no next run time ($($Spec.taskName))")
        }
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = $changed; dryRun = $false
            nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('readback check passed')
        }
    } catch {
        # Registration/read-back failed: hard failure plus an alert, no "continue deploying" degradation
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_REGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'register' -Status 'failed' `
            -Kind 'trigger-register-failed' `
            -Note ("触发注册失败：$($_.Exception.Message)。下一步：检查计划任务与运行时配置后重新注册。") | Out-Null
        throw
    }
}

function Test-ScheduleTrigger {
    param($Spec, [string]$RuntimeConfigPath)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $actionSpec = Get-TriggerActionSpec -Spec $Spec -Runtime $runtime
    $hash = Get-TriggerFingerprint -Spec $Spec
    $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'not-registered'
            code = 'TRIGGER_NOT_REGISTERED'; message = "scheduled task $($Spec.taskName) not found on this machine"
        }
    }
    if (-not (Test-TriggerTaskMatch $task $actionSpec $hash -IgnoreAllowProd)) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "scheduled task disagrees with the declaration ($($Spec.taskName))"
        }
    }
    $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
    if (-not $info.NextRunTime) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "task has no next run time ($($Spec.taskName))"
        }
    }
    return [ordered]@{
        ok = $true; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
        taskName = $Spec.taskName; specHash = $hash; status = 'registered'
        nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('description hash and action arguments match')
    }
}

function Unregister-ScheduleTrigger {
    param($Spec, [switch]$DryRun)
    if ($DryRun) {
        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = $(if ($task) { 'planned' } else { 'absent' }); dryRun = $true
            evidence = @('DryRun: scheduled task not deleted')
        }
    }
    $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'absent'; dryRun = $false; evidence = @('the task did not exist')
        }
    }
    try {
        Unregister-ScheduledTask -TaskName $Spec.taskName -Confirm:$false -ErrorAction Stop
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'removed'; dryRun = $false; evidence = @('scheduled task deleted')
        }
    } catch {
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_UNREGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'unregister' -Status 'failed' `
            -Kind 'trigger-unregister-failed' `
            -Note ("触发注销失败：$($_.Exception.Message)。下一步：到任务计划程序手动删除 $($Spec.taskName)。") | Out-Null
        throw
    }
}

# file task action: at the scheduled time call pad-trigger.ps1 -Watch, launched in the same shape as pad-schedule
function Get-FileWatchActionSpec {
    param($Spec, [string]$PadTriggerPath, [string]$RuntimeConfigPath, [switch]$AllowProd)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PadTriggerPath + '"'),
        '-Watch',
        '-FlowFile', ('"' + $Spec.flowFile + '"'))
    if ($Spec.configFile) {
        $argList += @('-ConfigFile', ('"' + (Resolve-Path -LiteralPath $Spec.configFile).Path + '"'))
    }
    if ($RuntimeConfigPath) {
        $argList += @('-RuntimeConfigPath', ('"' + $RuntimeConfigPath + '"'))
    }
    if ($AllowProd) { $argList += '-AllowProd' }
    $vbsArgs = '//nologo "' + $script:HiddenLauncher + '" "powershell.exe" ' + ($argList -join ' ')
    return [ordered]@{ exe = 'wscript.exe'; args = $vbsArgs }
}

# Register a file trigger: resolve {{config.<KEY>}} into a real path at registration/test time; failure to resolve is a hard failure
function Register-FileTrigger {
    param($Spec, [string]$RuntimeConfigPath, [switch]$DryRun, [switch]$AllowProd)
    try {
        $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
        $runtimePath = Resolve-TriggerRuntimeConfigPath -RuntimeConfigPath $RuntimeConfigPath
        $dir = Resolve-TriggerConfigRef -Token $Spec.fileDir -ConfigFile $Spec.configFile
        $candidates = @(Get-TriggerFileCandidates -Dir $dir -Pattern $Spec.filePattern)
        if ($candidates.Count -ge 2) {
            $names = (@($candidates | ForEach-Object { $_.Name }) -join ', ')
            throw (New-TriggerException 'TRIGGER_FILE_AMBIGUOUS' `
                "watch directory has $($candidates.Count) candidate files ($names); this will not guess 'latest', clean up the directory first")
        }
        $stateDir = Resolve-TriggerStateDir $runtime
        if (-not (Test-TriggerDirWritable $stateDir)) {
            throw (New-TriggerException 'TRIGGER_STATE_DIR_UNWRITABLE' "state ledger directory is not writable: $stateDir")
        }
        $actionSpec = Get-FileWatchActionSpec -Spec $Spec `
            -PadTriggerPath (Join-Path $moduleHere 'pad-trigger.ps1') `
            -RuntimeConfigPath $runtimePath -AllowProd:$AllowProd
        $hash = Get-TriggerFingerprint -Spec $Spec
        $description = "flow-ir-spec:$hash；flow-ir：file $dir\$($Spec.filePattern) 守望，运行 PAD 流程 $($Spec.flowName)（attended）"

        if ($DryRun) {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
                taskName = $Spec.taskName; specHash = $hash; changed = 'planned'; dryRun = $true
                dir = $dir; pattern = $Spec.filePattern; description = $description
                exe = $actionSpec.exe; args = $actionSpec.args
                stateDir = $stateDir
                evidence = @('DryRun: scheduled task not written, state directory not created')
            }
        }

        # Create the state directory only before a real registration; Test/DryRun never writes
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        $existing = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
        if (Test-TriggerTaskMatch $existing $actionSpec $hash) {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
                taskName = $Spec.taskName; specHash = $hash; changed = 'unchanged'; dryRun = $false
                evidence = @('already registered with a matching specHash; nothing written')
            }
        }
        $changed = $(if ($existing) { 'updated' } else { 'created' })

        # Same shape as the schedule branch: weekday + start time; the execution limit covers the whole watch window
        $taskTrigger = New-ScheduleTaskTrigger $Spec
        $limitMin = [math]::Max(180, [math]::Ceiling(([double]$Spec.fileMaxWaitSec + 300) / 60))
        $settings = New-ScheduleTaskSettings -ExecutionTimeLimitMinutes $limitMin
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $Spec.taskName `
            -Action (New-ScheduledTaskAction -Execute $actionSpec.exe -Argument $actionSpec.args) `
            -Trigger $taskTrigger -Settings $settings -Principal $principal `
            -Force -Description $description | Out-Null

        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction Stop
        Assert-TriggerReadback -Task $task -ActionSpec $actionSpec -SpecHash $hash -TaskName $Spec.taskName
        $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
        if (-not $info.NextRunTime) {
            throw (New-TriggerException 'TRIGGER_DRIFT' "task is registered but has no next run time ($($Spec.taskName))")
        }
        return [ordered]@{
            ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = $changed; dryRun = $false
            dir = $dir; pattern = $Spec.filePattern; stateDir = $stateDir
            nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('readback check passed')
        }
    } catch {
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_REGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'register' -Status 'failed' `
            -Kind 'trigger-register-failed' `
            -Note ("file 触发注册失败：$($_.Exception.Message)。下一步：修正监听目录/配置后重新注册。") | Out-Null
        throw
    }
}

# -Test is read-only: directory readable, 0 or 1 candidate, state directory writable; 2 or more is judged ambiguous and never takes "latest"
function Test-FileTrigger {
    param($Spec, [string]$RuntimeConfigPath)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $dir = Resolve-TriggerConfigRef -Token $Spec.fileDir -ConfigFile $Spec.configFile
    $candidates = @(Get-TriggerFileCandidates -Dir $dir -Pattern $Spec.filePattern)
    $stateDir = Resolve-TriggerStateDir $runtime
    $hash = Get-TriggerFingerprint -Spec $Spec
    $candidateNames = @($candidates | ForEach-Object { $_.Name })
    $base = [ordered]@{
        action = 'test'; kind = 'file'; flow = $Spec.flowName; taskName = $Spec.taskName
        specHash = $hash; dir = $dir; pattern = $Spec.filePattern; stateDir = $stateDir
        candidates = $candidateNames
    }
    if ($candidates.Count -ge 2) {
        $base.ok = $false; $base.status = 'ambiguous'; $base.code = 'TRIGGER_FILE_AMBIGUOUS'
        $base.message = "watch directory has $($candidates.Count) candidate files ($($candidateNames -join ', ')); this will not guess 'latest'"
        return $base
    }
    if (-not (Test-TriggerDirWritable $stateDir)) {
        $base.ok = $false; $base.status = 'state-unwritable'; $base.code = 'TRIGGER_STATE_DIR_UNWRITABLE'
        $base.message = "state ledger directory is not writable: $stateDir"
        return $base
    }
    $base.ok = $true; $base.status = 'ready'
    $base.message = "watch directory is readable with $($candidates.Count) candidate(s); the state ledger directory is writable"
    return $base
}

# Unregistration touches only the scheduled task; the state ledger is kept for diagnosing past triggers
function Unregister-FileTrigger {
    param($Spec, [switch]$DryRun)
    return (Unregister-ScheduleTrigger -Spec $Spec -DryRun:$DryRun)
}

# Watch: poll candidates at the scheduled time and call the existing pad-sync -RunOnly once the file settles; no new run entry point
function Invoke-TriggerWatch {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath,
        [switch]$AllowProd
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    if ($spec.kind -ne 'file') {
        throw (New-TriggerException 'TRIGGER_INVALID' "-Watch only applies to file triggers (current kind=$($spec.kind))")
    }
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $dir = Resolve-TriggerConfigRef -Token $spec.fileDir -ConfigFile $ConfigFile
    $stateDir = Resolve-TriggerStateDir $runtime
    if (-not (Test-TriggerDirWritable $stateDir)) {
        Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'trigger' -Status 'failed' `
            -Kind 'trigger-failed' `
            -Note ("状态账本目录不可写：$stateDir。下一步：修正目录权限或配置后人工重跑。") | Out-Null
        throw (New-TriggerException 'TRIGGER_STATE_DIR_UNWRITABLE' "state ledger directory is not writable: $stateDir")
    }
    $ledger = Get-TriggerLedgerPath -Spec $spec -Runtime $runtime
    $padSyncPath = [string]$runtime.PadSyncPath

    $base = [ordered]@{
        ok = $false; action = 'watch'; kind = 'file'; flow = $spec.flowName
        taskName = $spec.taskName; dir = $dir; pattern = $spec.filePattern
        status = 'waiting'; triggeredFileName = $null
        pollSec = $spec.filePollSec; settleSec = $spec.fileSettleSec; maxWaitSec = $spec.fileMaxWaitSec
        ledgerPath = $ledger; evidence = @()
    }
    $start = Get-Date
    $candidateKey = $null
    $candidateSince = $null

    while ($true) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        # Exit silently with 0 at the deadline: not receiving a file is not a failure
        if ($elapsed -ge $spec.fileMaxWaitSec) {
            $base.ok = $true; $base.status = 'timeout'
            $base.evidence = @("exceeded max_wait_sec=$($spec.fileMaxWaitSec); exiting silently with 0")
            return $base
        }
        $files = @(Get-TriggerFileCandidates -Dir $dir -Pattern $spec.filePattern)
        if ($files.Count -ge 2) {
            $names = (@($files | ForEach-Object { $_.Name }) -join ', ')
            Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'trigger' -Status 'failed' `
                -Kind 'trigger-failed' `
                -Note ("监听目录出现 $($files.Count) 个候选文件（$names），不做取最新猜测，本次未触发。下一步：清理目录后人工重跑。") | Out-Null
            throw (New-TriggerException 'TRIGGER_FILE_AMBIGUOUS' `
                "watch directory has $($files.Count) candidate files ($names); this will not guess 'latest'")
        }

        if ($files.Count -eq 1) {
            $f = $files[0]
            $key = Get-TriggerFileKey $f
            if ($key -eq $candidateKey) {
                # Key unchanged across two consecutive polls for longer than settle_sec: the file is considered fully written
                if (((Get-Date) - $candidateSince).TotalSeconds -ge $spec.fileSettleSec) {
                    if ($spec.fileOncePerFile) {
                        $isNew = Add-TriggerLedgerKey -Path $ledger -Key $key
                    } else {
                        $isNew = $true
                    }
                    if ($isNew) {
                        # Reuse the existing entry point: pad-sync -RunOnly -AllowProd -NonInteractive
                        $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', ('"' + $padSyncPath + '"'),
                            '-FlowName', ('"' + $spec.flowName + '"'),
                            '-FlowFile', ('"' + $spec.flowFile + '"'),
                            '-RunOnly', '-NonInteractive')
                        if ($spec.configFile) {
                            $syncArgs += @('-ConfigFile', ('"' + (Resolve-Path -LiteralPath $spec.configFile).Path + '"'))
                        }
                        if ($AllowProd) { $syncArgs += '-AllowProd' }
                        $syncOut = & powershell @syncArgs 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'run' -Status 'failed' `
                                -Kind 'trigger-failed' `
                                -Note ("file 触发后 pad-sync 退出码 $LASTEXITCODE。下一步：查看 PAD 控制台与运行日志后人工重跑，未自动重试。") | Out-Null
                            throw (New-TriggerException 'TRIGGER_WATCH_RUN_FAILED' `
                                "pad-sync exit code $LASTEXITCODE (file $($f.Name))")
                        }
                        $base.ok = $true; $base.status = 'triggered'; $base.triggeredFileName = $f.Name
                        $base.evidence = @("triggered: $($f.Name) (size $($f.Length))", "ledger: $ledger")
                        return $base
                    }
                    # This file has triggered already: do not trigger again, keep waiting for other files
                    $note = "this file was already triggered earlier; skipping: $($f.Name)"
                    if ($base.evidence -notcontains $note) { $base.evidence += $note }
                }
            } else {
                # New candidate, or size/time changed: restart the settle timer
                $candidateKey = $key
                $candidateSince = Get-Date
            }
        } else {
            $candidateKey = $null
            $candidateSince = $null
        }

        $remaining = $spec.fileMaxWaitSec - ((Get-Date) - $start).TotalSeconds
        if ($remaining -le 0) { continue }
        $sleepSec = [math]::Min([double]$spec.filePollSec, [math]::Max(1.0, $remaining))
        Start-Sleep -Seconds $sleepSec
    }
}

# ---- unified public entry points ----

function Register-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath,
        [switch]$DryRun,
        [switch]$AllowProd
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; specHash = (Get-TriggerFingerprint -Spec $spec)
                changed = 'unchanged'; dryRun = [bool]$DryRun
                evidence = @('manual triggers need no registration')
            }
        }
        'schedule' { return (Register-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd) }
        'file'     { return (Register-FileTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
    }
}

function Test-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'test'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; specHash = (Get-TriggerFingerprint -Spec $spec)
                status = 'manual'; message = 'manual triggers need no registration'
            }
        }
        'schedule' { return (Test-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath) }
        'file'     { return (Test-FileTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
    }
}

function Unregister-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'unregister'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; changed = 'absent'; dryRun = [bool]$DryRun
                evidence = @('manual triggers need no unregistration')
            }
        }
        'schedule' { return (Unregister-ScheduleTrigger -Spec $spec -DryRun:$DryRun) }
        'file'     { return (Unregister-FileTrigger -Spec $spec -DryRun:$DryRun) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
    }
}

Export-ModuleMember -Function Get-TriggerSpec, Get-TriggerFingerprint, Register-Trigger, Test-Trigger, Unregister-Trigger, Invoke-TriggerWatch
