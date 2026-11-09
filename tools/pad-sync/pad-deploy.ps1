# pad-deploy.ps1 — production deployment (variable substitution -> injection -> user confirmation)
#
# Flow: read .robin + config.json -> substitute variables -> safety checks -> user confirmation dialog -> inject into the production flow -> verification run
#
# Hard constraint: by default only PAD_SYNC_TEST may be touched; a production flow requires explicit -AllowProd
# Safety checks: leftover {{VAR}} placeholders -> hard block; suspected hardcoded email/password -> soft warning

[CmdletBinding()]
param(
    # -ValidateOnly / -Configure modes may omit SourceRobin
    [string]$SourceRobin,
    [string]$ConfigFile,
    [string]$FlowName,
    # Config schema: defaults to <same name>.schema.json in ConfigFile's directory
    [string]$SchemaFile,
    # A production flow may poll for up to 60 minutes plus processing headroom; the default is 4200 seconds
    [int]$RunTimeoutSec = 4200,
    [switch]$AllowProd,
    [switch]$DryRun,
    # Check the artefacts against the acceptance criteria after the run (forwarded to pad-sync)
    [string]$AcceptanceFile,
    # Publish without running: after publishing only the hash is verified, with no run status or acceptance check
    [switch]$PublishOnly,
    # Only validate config against the schema and never touch .robin: pass exits 0, failure exits 1
    [switch]$ValidateOnly,
    # Skip the production confirmation dialog (used when an orchestrating script has already asked once)
    [switch]$SkipConfirm,
    # Deployment wizard: delegate to pad-configure.ps1 (preflight probes + config generation); the flow is not injected
    [switch]$Configure,
    [string]$PadRoot,
    [string]$PythonExe,
    [string]$AnswersFile,
    [string]$RequirementsFile,
    [switch]$ProbeOnly
)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# Wizard mode: no other parameter of this script is needed; delegate and return its exit code
if ($Configure) {
    $cfgArgs = @{}
    if ($PadRoot) { $cfgArgs.PadRoot = $PadRoot }
    if ($ConfigFile) { $cfgArgs.ConfigPath = $ConfigFile }
    if ($PythonExe) { $cfgArgs.PythonExe = $PythonExe }
    if ($SchemaFile) { $cfgArgs.SchemaFile = $SchemaFile }
    if ($AnswersFile) { $cfgArgs.AnswersFile = $AnswersFile }
    if ($RequirementsFile) { $cfgArgs.RequirementsFile = $RequirementsFile }
    if ($ProbeOnly) { $cfgArgs.ProbeOnly = $true }
    & (Join-Path $here 'pad-configure.ps1') @cfgArgs
    exit $LASTEXITCODE
}

if (-not $FlowName) { Write-Error "missing -FlowName" }
if (-not $ConfigFile) { Write-Error "missing -ConfigFile" }

# ValidateOnly has no side effects, so it does not need the production safety fuse
if (-not $ValidateOnly -and $FlowName -ne "PAD_SYNC_TEST" -and -not $AllowProd) {
    Write-Error "Safety fuse: only PAD_SYNC_TEST may be deployed by default. Production deployment requires explicit -AllowProd."
}
if (-not $ValidateOnly) {
    if (-not $SourceRobin) { Write-Error "missing -SourceRobin (only -ValidateOnly mode may omit it)" }
    if (-not (Test-Path $SourceRobin)) { Write-Error ".robin not found: $SourceRobin" }
}
if (-not (Test-Path $ConfigFile)) { Write-Error "config.json not found: $ConfigFile" }
if (-not $SchemaFile) {
    $SchemaFile = [IO.Path]::ChangeExtension($ConfigFile, ".schema.json")
    # Handle double-suffix names such as example files: your-flow.example.json degrades to your-flow.schema.json
    if (-not (Test-Path $SchemaFile)) {
        $stem = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ConfigFile))
        $alt = Join-Path ([IO.Path]::GetDirectoryName($ConfigFile)) ($stem + ".schema.json")
        if (Test-Path $alt) { $SchemaFile = $alt }
    }
}
if (-not (Test-Path $SchemaFile)) { Write-Error "schema not found: $SchemaFile" }

$padSync = Join-Path $here "pad-sync.ps1"
$confirm = Join-Path $here "confirm-deploy.ps1"
if (-not (Test-Path $padSync)) { Write-Error "pad-sync.ps1 not found" }

$result = [ordered]@{
    ok = $false; flow = $FlowName; dryRun = [bool]$DryRun; validateOnly = [bool]$ValidateOnly
    sourceRobin = $SourceRobin; configFile = $ConfigFile; schemaFile = $SchemaFile
    deployedRobinPath = $null; replacedCount = 0
    warnings = @(); errors = @(); diffPath = $null
    runResult = $null
}
function Log([string]$m) { Write-Host "[deploy] $m" }
# Parsing of the child process's last-line PAD_SYNC_RESULT is centralised in PadTelemetry; this script no longer carries its own regex
Import-Module (Join-Path $here 'PadTelemetry.psm1') -Force
# Failure alerts: shares one implementation with pad-schedule / pad-sync (the kind constants live in the module)
Import-Module (Join-Path $here 'PadAlerts.psm1') -Force

# Alert directory: business\logs is written only when the script lives in the repository's tools\pad-sync
$alertDir = $null
$alertRepo = Split-Path -Parent (Split-Path -Parent $here)
if (Test-Path (Join-Path $alertRepo 'tools')) { $alertDir = Join-Path $alertRepo 'business\logs' }

# Deployment-stage failure alert: failing to write it does not affect the deployment result or the output
function Write-DeployAlert([string]$Stage, [string]$Kind, [string]$Note, [string]$RunId) {
    if (-not $alertDir) { return }
    try {
        $r = Write-RunAlert -FlowName $FlowName -ExitCode 1 -Stage $Stage -Status $null `
            -Kind $Kind -Note $Note -RunId $RunId -Dir $alertDir
        if ($r -and -not $r.skipped) { Log "failure alert written: $($r.path)" }
    } catch { Log "failed to write the alert (does not affect the deploy result): $($_.Exception.Message)" }
}

# Validate config against the schema and return a list of problems (each one naming the field); an empty array = passed
# Supported schema subset: required / additionalProperties:false / properties.{type,pattern,minLength,enum,description}
function Test-Config([hashtable]$Cfg, $Schema) {
    $problems = @()
    # 1) Missing required fields
    if ($Schema.required) {
        foreach ($req in @($Schema.required)) {
            if (-not $Cfg.ContainsKey([string]$req)) { $problems += "missing required field: $req" }
        }
    }
    # 2) Fields the schema does not define (a mistyped key would leave a placeholder in the deployed artefact)
    if ($Schema.additionalProperties -eq $false) {
        foreach ($k in $Cfg.Keys) {
            if (-not $Schema.properties.PSObject.Properties[$k]) { $problems += "unknown field: $k (not defined in the schema)" }
        }
    }
    # 3) Per-field type and format
    foreach ($prop in $Schema.properties.PSObject.Properties) {
        $name = $prop.Name; $rule = $prop.Value
        if (-not $Cfg.ContainsKey($name)) { continue }
        $v = $Cfg[$name]
        if ($null -eq $v) { $problems += "${name}: value cannot be null"; continue }
        if ($rule.type -eq 'string' -and -not ($v -is [string])) {
            $problems += "${name}: type should be string, actual $($v.GetType().Name)"; continue
        }
        if ($rule.minLength -and ([string]$v).Length -lt [int]$rule.minLength) {
            $problems += "${name}: value cannot be empty ($($rule.description))"
        }
        if ($rule.enum) {
            $allowed = @($rule.enum | ForEach-Object { [string]$_ })
            if ($allowed -notcontains [string]$v) {
                $problems += "${name}: value '$v' is not in the allowed range ($($allowed -join '/'))"
            }
        }
        if ($rule.pattern -and [string]$v -notmatch [string]$rule.pattern) {
            $problems += "${name}: value '$v' has the wrong format ($($rule.description))"
        }
    }
    return $problems
}

try {
    # ═══ 0. Read config + schema and validate them ═══
    $cfgRaw = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8)
        # PS 5.1 has no -AsHashtable, so convert from PSCustomObject to Hashtable by hand
    $cfgObj = $cfgRaw | ConvertFrom-Json
    $cfg = @{}
    $cfgObj.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
    if (-not $cfg) { throw "config.json cannot be parsed or is empty" }

    $schema = [IO.File]::ReadAllText($SchemaFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $problems = @(Test-Config $cfg $schema)

    # Validate-only mode: name every problem and exit accordingly; no file is written
    if ($ValidateOnly) {
        if ($problems.Count -eq 0) {
            Log "config validation passed: $ConfigFile"
            $result.ok = $true
            exit 0
        }
        foreach ($p in $problems) { $result.errors += $p; Log "✗ $p" }
        Log "config validation failed: $($problems.Count) problem(s)"
        exit 1
    }
    # A real deployment validates first too; every problem is named and blocks the deployment
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { $result.errors += $p; Log "✗ $p" }
        throw "config validation failed ($($problems.Count) problem(s)); fix $ConfigFile first"
    }
    Log "config validation passed (schema: $([IO.Path]::GetFileName($SchemaFile)))"

    # ═══ 1. Read + substitute variables ═══
    $raw = [IO.File]::ReadAllText($SourceRobin, [Text.Encoding]::UTF8)

    $replaced = $raw; $count = 0
    foreach ($key in $cfg.Keys) {
        # A single brace is special in a regex; a doubled brace can be written literally
        $pattern = "{{" + [regex]::Escape($key) + "}}"
        $before = ([regex]::Matches($replaced, $pattern)).Count
        if ($before -gt 0) {
                        # Use the actual value from config.json (a path must be written verbatim, never truncated to a file name)
            $val = [string]$cfg[$key]
            # Fields marked x-robin-escape in the schema (Windows paths): config holds a single
            # backslash, but inside a .robin literal it must be written as an escaped double backslash
            $rule = $schema.properties.PSObject.Properties[$key]
            if ($rule -and $rule.Value.'x-robin-escape' -eq $true) { $val = $val.Replace('\', '\\') }
            $replaced = [regex]::Replace($replaced, $pattern, $val)
            $after = ([regex]::Matches($replaced, $pattern)).Count
            $done = $before - $after; $count += $done
            Log "replaced {{$key}} x $done"
        }
    }
    $result.replacedCount = $count
    Log "replaced $count variable occurrences"

    # ═══ 2. Safety checks ═══
    # Leftover placeholders -> hard block
    $leftover = [regex]::Matches($replaced, "{{[^}]+}}")
    if ($leftover.Count -gt 0) {
        foreach ($m in $leftover) { $result.errors += "leftover placeholder: $($m.Value)" }
        throw "safety check failed: $($leftover.Count) {{VAR}} placeholders were not replaced; add them in config.json"
    }
    Log "safety check passed: no leftover placeholders"

    # Hardcoded email/password patterns -> soft warning (does not block)
    $warns = @()
    if ($replaced -match "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}") { $warns += "possible hardcoded email address" }
    # DRY_RUN=1 skips posting/export/verification/mailing; when deploying to production this must be called out, otherwise production could be switched off by mistake
    if ($FlowName -ne "PAD_SYNC_TEST" -and $cfg.ContainsKey('DRY_RUN') -and [string]$cfg['DRY_RUN'] -eq '1') {
        $warns += "DRY_RUN=1: this deployment will skip posting/export/verification and mail sending"
    }
    foreach ($w in $warns) { $result.warnings += $w; Log "⚠️ $w" }

    # Write the substituted .robin
    $deployedPath = [IO.Path]::ChangeExtension($SourceRobin, ".deployed.robin")
    [IO.File]::WriteAllText($deployedPath, $replaced, (New-Object Text.UTF8Encoding($true)))
    $result.deployedRobinPath = $deployedPath
    Log "deployed .robin -> $deployedPath"

    # Write the diff information
    $origLines = ($raw -split "`r?`n").Where({ $_.Trim() -ne "" -and $_.Trim() -notmatch "^#" })
    $newLines  = ($replaced -split "`r?`n").Where({ $_.Trim() -ne "" -and $_.Trim() -notmatch "^#" })
    $diffInfo = [ordered]@{ origActionCount = $origLines.Count; newActionCount = $newLines.Count; replacedCount = $count; warnings = $warns }
    $diffPath = Join-Path ([IO.Path]::GetDirectoryName($deployedPath)) "deploy_diff.json"
    $result.diffPath = $diffPath; $diffInfo | ConvertTo-Json -Depth 3 | Out-File $diffPath -Encoding UTF8

    if ($DryRun) { Log "[DryRun] skip injection"; $result.ok = $true; return }

    # ═══ 3. User confirmation dialog (only for a production flow; with -SkipConfirm an upper layer has already confirmed) ═══
    if ($AllowProd -and $FlowName -ne "PAD_SYNC_TEST" -and -not $SkipConfirm) {
        $warnText = if ($warns.Count -gt 0) { "`n⚠️ $($warns -join "; ")" } else { "" }
        $msg = "Target flow: $FlowName`nReplaced variables: $count`nAction lines: $($origLines.Count) -> $($newLines.Count)`n$warnText`n`nDeploy now?"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $confirm -Title "Production deployment confirmation" -Msg $msg
        if ($LASTEXITCODE -ne 0) {
            # Exception carrying Data['code']: outer layers use it to skip the "cancelled" alert without parsing message text
            $ex = [System.Exception]::new('user cancelled the deployment')
            $ex.Data['code'] = 'DEPLOY_USER_CANCELLED'
            throw $ex
        }
        Log "user confirmed deployment to $FlowName"
    }

    # ═══ 4. Inject + verification run ═══
    Log "--- injecting $FlowName ---"
    $tmpOut = Join-Path $env:TEMP "pad-deploy-sync.log"
    # pad-sync has its own production fuse, so AllowProd must be forwarded; otherwise a production flow is blocked before injection
    $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $padSync,
        '-FlowName', $FlowName, '-RobinFile', $deployedPath, '-Replace',
        '-RunTimeoutSec', $RunTimeoutSec)
    if ($AllowProd) { $syncArgs += '-AllowProd' }
    # Publish-only mode: inject -> publish -> stop, without triggering a URL run
    if ($PublishOnly) { $syncArgs += '-PublishOnly' }
    if ($AcceptanceFile) {
        if (-not (Test-Path $AcceptanceFile)) { Write-Error "acceptance criteria file not found: $AcceptanceFile" }
        $syncArgs += @('-AcceptanceFile', $AcceptanceFile, '-ConfigFile', $ConfigFile)
    }
    & powershell @syncArgs > $tmpOut 2>&1
    $res = Read-ChildResult -Name 'SYNC' -Lines @(Get-Content $tmpOut) -Logger { param($m) Log $m }
    if ($res) {
        $result.runResult = $res
        if ($res.ok) { Log "✅ verification passed: $($res.status)"; $result.ok = $true }
        else {
            Log "❌ verification failed: $($res.status)"
            # The failure reason may be an action-level error code or a stage-level exception message; carry both
            $reason = if ($res.error -and $res.error.code) { $res.error.code }
                      elseif ($res.error -and $res.error.message) { $res.error.message }
                      else { [string]$res.status }
            $result.errors += "run failed: $reason"
            # Classify by the stage where the child flow failed; the kind constants all come from PadAlerts
            $ak = Get-AlertKindConstants
            $st = [string]$res.stage
            $alertKind = if ($st -in @('inject', 'find-designer', 'static-check', 'admit')) { $ak.DeployInjectFailed }
                elseif ($st -eq 'publish') { $ak.DeployPublishFailed }
                else { $ak.RunFailed }
            Write-DeployAlert $st $alertKind "deployment failed at stage=$st`: $reason. Next step: fix it and redeploy; nothing was retried automatically." ([string]$res.runId)
        }
    } else { throw "pad-sync produced no PAD_SYNC_RESULT" }
}
catch {
    $result.errors += $_.Exception.Message; Log "deployment failed: $($_.Exception.Message)"
    # A deliberate user cancel is not a failure alert; the other precheck stages (config/placeholders/confirmation) each write one
    if ([string]$_.Exception.Data['code'] -ne 'DEPLOY_USER_CANCELLED') {
        $ak = Get-AlertKindConstants
        $st = if ($DryRun) { 'dryrun' } else { 'precheck' }
        Write-DeployAlert $st $ak.DeployPrecheckFailed "deployment precheck failed: $($_.Exception.Message). Next step: fix the config or source .robin and redeploy." $null
    }
}
finally { Write-Output ("PAD_DEPLOY_RESULT=" + ($result | ConvertTo-Json -Depth 10 -Compress)) }
