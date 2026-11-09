# PadFingerprint.psm1 — flow fingerprint: Workspace revision lookup, identity resolution, baseline read/write and comparison
#
# Why a separate module:
#   1) The "exact revision, never take the latest" Workspace lookup and identity resolution must have a single implementation;
#      pad-release.ps1 (writes the baseline after release), pad-rollback.ps1 (rewrites it after rollback),
#      pad-fingerprint.ps1 (seeds existing flows), and pad-admit.ps1 (the admission FINGERPRINT check) all take it from here,
#      so a second hashing/lookup implementation never appears.
#   2) It treats every flow.json alike: the module contains no branch that applies "only to one particular flow".
#
# Layer boundary:
#   Mechanism (lookup, hashing, comparison) lives in the public layer;
#   Baseline data is written to business\fingerprints\<flow name>.json (flow name, flowGuid,
#   environmentId, machine name, and real paths), which is business-layer only: not committed, not pushed to the public repo.

# The single implementation of normalization and hashing (RobinText.psm1): this module does not write a second copy of the rules
Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force

# Repository root of this module: it lives in tools\pad-sync, so going up two levels gives the repo root
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# The script fingerprint list is business-layer data (it contains concrete business script paths) and is configured in
# business\config\fingerprint-scripts.json:
#   repoScripts     — scripts inside the repo, relative to the repo root, always with forward slashes;
#   externalScripts — absolute paths of legacy copies outside the repo; seeding can override them with -ExternalPaths (explicit parameters win).
# A missing or unparsable config always fails hard: silently degrading to an empty list would quietly switch off script drift detection.
function Read-FingerprintScriptConfig {
    param(
        [string]$RepoRoot,
        [string]$ConfigPath
    )
    if (-not $RepoRoot) { $RepoRoot = $script:RepoRoot }
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path (Join-Path (Join-Path $RepoRoot 'business') 'config') 'fingerprint-scripts.json'
    }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Missing script fingerprint config: $ConfigPath (script drift detection cannot be skipped when the business-layer config is missing)"
    }
    try {
        $j = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw "Cannot parse script fingerprint config: ${ConfigPath}; $($_.Exception.Message)"
    }
    $repo = @($j.repoScripts | Where-Object { $_ })
    if ($repo.Count -eq 0) {
        throw "repoScripts is empty in the script fingerprint config: $ConfigPath"
    }
    return [ordered]@{
        path            = $ConfigPath
        repoScripts     = $repo
        externalScripts = @($j.externalScripts | Where-Object { $_ })
    }
}

# The external section of fingerprint v3: legacy copies outside the repo (only lockable by absolute path), passed explicitly
# by the caller when seeding. Public code hard-codes no business path; paths only land in the baseline files under business\.
# It is a separate section rather than folded into scripts: these files are not in the repo and their paths are bound to the
# local machine, so mixing them in would suggest every key can be found inside the repo.
# Note: a legacy external copy and a same-named file in business\scripts already hash differently because of path constants
# (PS1_PATH / CLOSE_PS1_PATH / log paths, etc.); that difference is expected. Hashing them only reveals "one side was changed
# on its own"; it cannot tell whether the two sides are semantically equivalent.

# Parse the flow GUID and runId out of an Actions.log path:
#   ...\Console\Scripts\<flowGuid>\Runs\<runId>\Actions.log
function Get-FlowGuidFromLogPath([string]$LogPath) {
    $m = [regex]::Match($LogPath, 'Scripts\\([0-9a-fA-F-]{36})\\Runs\\([0-9a-fA-F-]{36})\\')
    if (-not $m.Success) { return $null }
    return [ordered]@{ flowGuid = $m.Groups[1].Value.ToLower(); runId = $m.Groups[2].Value }
}

# Find the definition info of the flow's most recent run in the local run history (newest startTime wins)
# Returns: flowGuid / flowVersion (the cloud version ETag) / startTime / status / path; $null when not found
# Note: this is only for "resolve identity from the flow name", not for locating the definition copy to compare;
#       definition copies always go through the exact-revision rule in Find-WorkspaceRobin.
function Find-LatestFlowRun([string]$ScriptsRoot, [string]$FlowName) {
    if (-not $ScriptsRoot -or -not (Test-Path $ScriptsRoot)) { return $null }
    $best = $null
    $files = Get-ChildItem -LiteralPath $ScriptsRoot -Recurse -Filter 'RunDefinition.json' -ErrorAction SilentlyContinue
    foreach ($rd in $files) {
        try { $j = [IO.File]::ReadAllText($rd.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $j.workflow -or $j.workflow.name -ne $FlowName) { continue }
        if (-not $j.startTime) { continue }
        if (-not $best -or ([string]$j.startTime) -gt ([string]$best.startTime)) {
            $best = [ordered]@{
                flowGuid    = [string]$j.workflow.workflowId
                flowVersion = $(if ($j.diagnosticInfo) { [string]$j.diagnosticInfo.flowVersion } else { $null })
                startTime   = [string]$j.startTime
                status      = [string]$j.status
                path        = $rd.FullName
            }
        }
    }
    return $best
}

# The local definition copy of a published flow: Console\Workspace\<flowGuid>\<revision dir>\script.robin
# It matches the revision of this release/run exactly and never degrades to "take the newest copy" (under concurrency on the
# same machine that would compare against someone else's definition):
#   1) if a revision directory name equals this runId, use it directly (the same rule PadDesigner uses for run directories);
#   2) otherwise accept only revisions written after this release; more than one match means "cannot determine" and raises an error.
function Find-WorkspaceRobin([string]$WorkspaceRoot, [string]$FlowGuid, [string]$RunId, [datetime]$SinceUtc) {
    if (-not $WorkspaceRoot -or -not $FlowGuid) { return $null }
    $dir = Join-Path $WorkspaceRoot $FlowGuid
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $all = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'script.robin' -ErrorAction SilentlyContinue)
    $hit = @($all | Where-Object {
        ($RunId -and $_.Directory.Name -eq $RunId) -or
        ($_.LastWriteTime.ToUniversalTime() -ge $SinceUtc.AddMinutes(-2))
    })
    if ($hit.Count -gt 1) {
        # An exception carrying Data['code']: callers classify by code and never parse the message text
        $msg = "Workspace has $($hit.Count) candidate revisions; cannot determine which one belongs to this release: " +
            (($hit | ForEach-Object { $_.Directory.Name }) -join ', ')
        $ex = [System.Exception]::new($msg)
        $ex.Data['code'] = 'FINGERPRINT_AMBIGUOUS'
        throw $ex
    }
    if ($hit.Count -eq 1) { return $hit[0].FullName }
    return $null
}

# Read the current environment ID from the PAD console config (the first EnvironmentId in console.config's UserConfigs)
# Returns $null when unreadable: the baseline records null, and admission then skips the environment comparison instead of inventing an identity
function Get-PadEnvironmentId([string]$ConsoleConfigPath) {
    if (-not $ConsoleConfigPath) {
        $ConsoleConfigPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\console.config'
    }
    if (-not (Test-Path -LiteralPath $ConsoleConfigPath)) { return $null }
    try {
        $j = [IO.File]::ReadAllText($ConsoleConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.UserConfigs.PSObject.Properties) {
            if ($p.Value -and $p.Value.EnvironmentId) { return [string]$p.Value.EnvironmentId }
        }
    } catch { return $null }
    return $null
}

# SHA256 (lowercase) of the three files. A missing file records null, which the caller reads as "unreadable"
function Get-FingerprintParts([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    $parts = [ordered]@{ robin = $null; config = $null; acceptance = $null }
    foreach ($pair in @(@('robin', $RobinPath), @('config', $ConfigPath), @('acceptance', $AcceptancePath))) {
        if ($pair[1] -and (Test-Path -LiteralPath $pair[1])) {
            $parts[$pair[0]] = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLower()
        }
    }
    return $parts
}

# The scripts section of fingerprint v3: SHA256 of raw bytes per file, keyed by repo-relative path (forward slashes), valued by the hash.
# A missing file records null and is judged "currently missing" on the comparison side; no exception is thrown here (admission must report everything in one pass).
function Get-ScriptFingerprintParts {
    param(
        [string]$RepoRoot,
        [string[]]$Paths
    )
    if (-not $RepoRoot) { $RepoRoot = $script:RepoRoot }
    $list = @($Paths)
    if ($list.Count -eq 0) {
        # When no list is passed, read the business-layer config; Read-FingerprintScriptConfig fails hard if it is missing
        $list = @((Read-FingerprintScriptConfig -RepoRoot $RepoRoot).repoScripts)
    }
    $parts = [ordered]@{}
    foreach ($rel in $list) {
        if (-not $rel) { continue }
        # Normalize to forward slashes before joining the local path: baseline keys stay platform-independent and readable across machines
        $key = ([string]$rel).Replace('\', '/')
        $full = Join-Path $RepoRoot ($key.Replace('/', '\'))
        if (Test-Path -LiteralPath $full) {
            $parts[$key] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
        } else {
            $parts[$key] = $null
        }
    }
    return $parts
}

# The external section of fingerprint v3: SHA256 of raw bytes per absolute path, keeping the absolute path as the key (forward slashes).
# Missing files also record null and are judged "currently missing" on the comparison side.
function Get-ExternalScriptFingerprintParts {
    param([string[]]$Paths)
    $list = @($Paths)
    $parts = [ordered]@{}
    foreach ($p in $list) {
        if (-not $p) { continue }
        $full = [string]$p
        $key = $full.Replace('\', '/')
        if (Test-Path -LiteralPath $full) {
            $parts[$key] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
        } else {
            $parts[$key] = $null
        }
    }
    return $parts
}

# Compare the scripts section in the baseline against the current script files and return status/code/message/evidence.
# The observation period only warns and never blocks: a pre-v3 baseline without a scripts section means "not seeded yet",
# not tampering, so it always warns (SCRIPT_FINGERPRINT_LEGACY) and never fails just because the section is absent.
function Test-ScriptFingerprint {
    param(
        [string]$BaselinePath,
        [string]$RepoRoot,
        [string[]]$Paths
    )
    if (-not $RepoRoot) { $RepoRoot = $script:RepoRoot }
    $read = Read-FingerprintBaseline $BaselinePath
    if (-not $read.ok) {
        return [ordered]@{
            status = 'warn'; code = $read.code
            message = "$($read.message); cannot check script fingerprints for: $BaselinePath"
            evidence = @("baseline=$BaselinePath")
        }
    }
    $base = $read.data
    $props = @($base.PSObject.Properties.Name)
    $hasScripts = ($props -contains 'scripts') -and $base.scripts
    if (-not $hasScripts) {
        # Backward compatibility: v2 and earlier baselines have no scripts section; warn and ask for a reseed
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_LEGACY'
            message = 'Baseline has no scripts section (pre-v3 baseline); reseed before checking script fingerprints'
            evidence = @("baseline=$BaselinePath")
        }
    }
    $hasExternal = ($props -contains 'external') -and $base.external
    if (-not $hasExternal) {
        # A baseline seeded with v3 but not yet capturing the PAD legacy copies: also reported as legacy and reseeded, never failed
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_LEGACY'
            message = 'Baseline has no external section (PAD legacy copies were not captured); reseed before checking script fingerprints'
            evidence = @("baseline=$BaselinePath")
        }
    }

    $expected = $base.scripts
    $expectedKeys = @($expected.PSObject.Properties.Name)
    $keys = @($Paths)
    if ($keys.Count -eq 0) { $keys = $expectedKeys }
    $keys = @($keys | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/') })
    $now = Get-ScriptFingerprintParts -RepoRoot $RepoRoot -Paths $keys

    # Check the external section item by item using the absolute-path keys from the baseline (ignoring -Paths to avoid mixing with repo-relative paths)
    $expectedExternal = $base.external
    $extKeys = @($expectedExternal.PSObject.Properties.Name)
    $nowExt = Get-ExternalScriptFingerprintParts -Paths $extKeys

    $bad = @()
    foreach ($k in $keys) {
        $was = $null
        if ($expectedKeys -contains $k) { $was = [string]$expected.$k }
        $cur = [string]$now[$k]
        if (-not $was) {
            $bad += "$k not recorded in the baseline"
        } elseif (-not $cur) {
            $bad += "$k missing now (baseline $($was.Substring(0, 12)))"
        } elseif ($cur -ne $was) {
            $bad += "$k baseline $($was.Substring(0, 12)) now $($cur.Substring(0, 12))"
        }
    }
    foreach ($k in $extKeys) {
        $was = [string]$expectedExternal.$k
        $cur = [string]$nowExt[$k]
        if (-not $was) {
            $bad += "$k not recorded in the baseline"
        } elseif (-not $cur) {
            $bad += "$k missing now (baseline $($was.Substring(0, 12)))"
        } elseif ($cur -ne $was) {
            $bad += "$k baseline $($was.Substring(0, 12)) now $($cur.Substring(0, 12))"
        }
    }
    $total = $keys.Count + $extKeys.Count
    if ($bad.Count -gt 0) {
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_MISMATCH'
            message = ("$($bad.Count)/$total script hashes differ from the baseline (observation period only warns, it does not block)")
            evidence = $bad
        }
    }
    return [ordered]@{
        status = 'pass'; code = 'OK'
        message = "$($keys.Count) repo scripts + $($extKeys.Count) PAD legacy copies match the baseline hashes"
        evidence = @("baseline=$BaselinePath")
    }
}

# Normalized hash (logic hash) of a .robin: strip comments/metadata/indentation and escaping differences, then compute SHA256.
# The source file and the published copy always differ in raw bytes (PAD adds @@ headers and IMPORT lines and rewrites escapes),
# so only the logic hash can be compared safely across "on-disk formats".
function Get-RobinLogicHash([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return (Get-RobinHash $text)
}

# Derive the Workspace root from ScriptsRoot: both live under ...\Power Automate Desktop\Console\
function Get-WorkspaceRootFromScriptsRoot([string]$ScriptsRoot) {
    if (-not $ScriptsRoot) { return $null }
    $consoleRoot = Split-Path -Parent $ScriptsRoot
    if (-not $consoleRoot) { return $null }
    $root = Join-Path $consoleRoot 'Workspace'
    if (Test-Path -LiteralPath $root) { return $root }
    return $null
}

# Baseline file location: business\fingerprints\<flow name>.json (business layer, never committed)
function Get-FingerprintBaselinePath([string]$RepoRoot, [string]$FlowName) {
    return (Join-Path (Join-Path (Join-Path $RepoRoot 'business') 'fingerprints') ($FlowName + '.json'))
}

# Read a baseline. It does not throw: it returns ok/code/message and the caller decides whether that means warn or fail
function Read-FingerprintBaseline([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_NO_BASELINE'; message = 'no fingerprint baseline'; data = $null }
    }
    try {
        $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "baseline cannot be parsed: $($_.Exception.Message)"; data = $null }
    }
    foreach ($k in @('flow', 'hashes')) {
        if ($j.PSObject.Properties.Name -notcontains $k) {
            return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "baseline is missing field $k"; data = $null }
        }
    }
    if ($j.hashes.PSObject.Properties.Name -notcontains 'robin' -or -not $j.hashes.robin) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = 'baseline is missing the robin hash'; data = $null }
    }
    return [ordered]@{ ok = $true; code = $null; message = 'baseline is readable'; data = $j }
}

# Write a baseline: write a temp file first, then replace atomically, so a half-written JSON can never exist
function Write-FingerprintBaseline([string]$Path, $Baseline) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Baseline | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $Path
}

# Build one baseline record (hashes and modification time are computed here so callers do not each write their own)
function New-FingerprintBaseline {
    param(
        [string]$FlowName, [string]$FlowGuid, [string]$EnvironmentId,
        [string]$SourceRobin, [string]$WorkspaceRobin,
        [string]$ConfigPath, [string]$AcceptancePath, [string]$Machine,
        # In-repo script list: an explicit argument wins (tests / special flows); read from the business-layer config when omitted
        [string[]]$ScriptPaths,
        # Absolute-path list of legacy copies outside the repo: an explicit argument wins (including an explicit empty array); read from the business-layer config when omitted
        [string[]]$ExternalPaths
    )
    $parts = Get-FingerprintParts $SourceRobin $ConfigPath $AcceptancePath
    # Read the config once when either list needs it; explicit parameters win so semantics never overlap with the config
    $needCfg = (-not $PSBoundParameters.ContainsKey('ScriptPaths')) -or (-not $PSBoundParameters.ContainsKey('ExternalPaths'))
    $cfg = $(if ($needCfg) { Read-FingerprintScriptConfig -RepoRoot $script:RepoRoot } else { $null })
    # New in v3: the script files the flow actually references (repo-relative path + raw-byte SHA256)
    $scriptList = $(if ($PSBoundParameters.ContainsKey('ScriptPaths')) { @($ScriptPaths) } else { @($cfg.repoScripts) })
    $scripts = Get-ScriptFingerprintParts -RepoRoot $script:RepoRoot -Paths $scriptList
    # New in v3: legacy copies outside the repo (absolute path + raw-byte SHA256)
    $extList = $(if ($PSBoundParameters.ContainsKey('ExternalPaths')) { @($ExternalPaths) } else { @($cfg.externalScripts) })
    $external = Get-ExternalScriptFingerprintParts -Paths $extList
    $mtime = $null
    $deployedRaw = $null
    if ($WorkspaceRobin -and (Test-Path -LiteralPath $WorkspaceRobin)) {
        $mtime = (Get-Item -LiteralPath $WorkspaceRobin).LastWriteTime.ToString('o')
        $deployedRaw = (Get-FileHash -LiteralPath $WorkspaceRobin -Algorithm SHA256).Hash.ToLower()
    }
    return [ordered]@{
        version       = 3
        flow          = $FlowName
        flowGuid      = $FlowGuid
        environmentId = $EnvironmentId
        machine       = $(if ($Machine) { $Machine } else { $env:COMPUTERNAME })
        # Source: the .robin in the repo (raw bytes + logic hash); config/acceptance come from the same source
        source        = [ordered]@{
            robinPath      = $SourceRobin
            robinSha256    = $parts.robin
            robinLogicHash = (Get-RobinLogicHash $SourceRobin)
            configSha256   = $parts.config
            acceptanceSha256 = $parts.acceptance
        }
        # Deployed: the Workspace copy (raw bytes + logic hash); it may only be self-compared within this domain
        deployed      = [ordered]@{
            robinPath   = $WorkspaceRobin
            robinSha256 = $deployedRaw
            logicHash   = (Get-RobinLogicHash $WorkspaceRobin)
            workspaceMtime = $mtime
        }
        # For legacy readers: robin still means the raw-byte hash of the source .robin — do not put the deployed hash in here
        hashes        = $parts
        # v3: script list (repo-relative path -> sha256); the observation period only warns and takes no part in the strict .robin comparison
        scripts       = $scripts
        # v3: legacy copies under the PAD run directory (absolute path -> sha256); stored separately from scripts
        external      = $external
        seededAt      = [datetime]::UtcNow.ToString('o')
    }
}

# Compare the current files against the baseline / approval record and return a uniform result:
#   status = pass / warn / fail; code + message + evidence
# Mode defaults to fail: the baseline has been seeded and verified, so any fingerprint mismatch is a failure;
# pass -Mode warn explicitly for an observation period or a temporary downgrade.
function Test-FlowFingerprint {
    param(
        [string]$FlowName,
        [string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath,
        [string]$BaselinePath,
        [string]$ScriptsRoot,
        [string]$EnvironmentId, [string]$Machine,
        [string]$ApprovePath,
        # Deployment artifact path (the .robin after placeholder substitution); derived automatically as "source file name.deployed.robin" when omitted
        [string]$DeployedRobinPath,
        # Used only for the "missing baseline" hint: assembles the complete, runnable fix command
        [string]$FlowFilePath,
        [string]$FlowDisplayName,
        [ValidateSet('warn', 'fail')][string]$Mode = 'fail',
        # Severity when the baseline is missing: report mode may downgrade to warn; the production gate (-Unattended) must stay fail
        [ValidateSet('warn', 'fail')][string]$NoBaselineMode = 'fail'
    )
    if (-not $Machine) { $Machine = $env:COMPUTERNAME }
    $parts = Get-FingerprintParts $RobinPath $ConfigPath $AcceptancePath
    $nonPass = $(if ($Mode -eq 'fail') { 'fail' } else { 'warn' })
    $fpLine = (@('robin', 'config', 'acceptance') | Where-Object { $parts[$_] } |
        ForEach-Object { "$_=$($parts[$_].Substring(0, 12))" }) -join ' '

    # Cannot read the robin: we cannot even prove what this flow is
    if (-not $parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = "cannot read .robin; cannot compute the fingerprint: $RobinPath"
            evidence = @("robin=$RobinPath")
        }
    }

    # 1) Approval record present: bind to the approval record first (a hard constraint, always fail)
    if ($ApprovePath -and (Test-Path -LiteralPath $ApprovePath)) {
        $ok = $false
        foreach ($l in [IO.File]::ReadAllLines($ApprovePath, [Text.Encoding]::UTF8)) {
            if (-not $l.Trim()) { continue }
            try { $rec = $l | ConvertFrom-Json } catch { continue }
            if ([string]$rec.robin -eq [string]$parts.robin -and
                [string]$rec.config -eq [string]$parts.config -and
                [string]$rec.acceptance -eq [string]$parts.acceptance) { $ok = $true; break }
        }
        if ($ok) {
            return [ordered]@{ status = 'pass'; code = 'OK'; message = "matches the approval record: $fpLine"; evidence = @($ApprovePath) }
        }
        return [ordered]@{
            status = 'fail'; code = 'FINGERPRINT_MISMATCH'
            message = "does not match the approval record: $fpLine"
            evidence = @("approve=$ApprovePath")
        }
    }

    # 2) No baseline: the normal state of an unpublished flow; report mode may downgrade to warn,
    #    but the production gate must fail — "not seeded yet" must never count as "passed".
    $read = Read-FingerprintBaseline $BaselinePath
    if (-not $read.ok) {
        $status = $nonPass
        $msg = "$($read.message)：$BaselinePath"
        $ev = @("baseline=$BaselinePath", "now=$fpLine")
        if ($read.code -eq 'FINGERPRINT_NO_BASELINE') {
            $status = $(if ($NoBaselineMode -eq 'fail') { 'fail' } else { 'warn' })
            # Put the runnable command straight into the message: after the first release and one real run, the baseline can be seeded
            $hintName = [string]$(if ($FlowDisplayName) { $FlowDisplayName } else { $FlowName })
            $hint = @('.\tools\pad-sync\pad-fingerprint.ps1', "-FlowName '$hintName'")
            if ($FlowFilePath) { $hint += "-FlowFile '$FlowFilePath'" }
            if ($ConfigPath) { $hint += "-ConfigFile '$ConfigPath'" }
            if ($AcceptancePath) { $hint += "-AcceptanceFile '$AcceptancePath'" }
            $hint += @('-Set', '-Confirm')
            $msg += "; normal state for an unpublished flow; after the first release and one real run, execute: $($hint -join ' ')"
            $ev += "fix=$($hint -join ' ')"
        }
        return [ordered]@{
            status = $status; code = $read.code
            message = $msg
            evidence = $ev
        }
    }
    $base = $read.data
    # New baselines split hashes into source / deployed domains; old baselines have only hashes (source hashes) plus the published path.
    $srcBase = $null
    if ($base.PSObject.Properties.Name -contains 'source' -and $base.source) { $srcBase = $base.source }
    $depBase = $null
    if ($base.PSObject.Properties.Name -contains 'deployed' -and $base.deployed) { $depBase = $base.deployed }

    $baseSource = [string]$(if ($srcBase -and $srcBase.robinSha256) { $srcBase.robinSha256 } else { $base.hashes.robin })
    $baseShort = if ($baseSource.Length -gt 12) { $baseSource.Substring(0, 12) } else { $baseSource }
    $ev = @("baseline=$BaselinePath", "now=$fpLine", "baselined=$baseShort")

    # 3) Identity: the local run history must be searched with the PAD display name recorded in the baseline.
    #    The $FlowName argument usually comes from the flow.json file name (e.g. demo-flow), which can differ completely
    #    from the display name registered in PAD; searching by file name would leave every flow UNKNOWN forever.
    $displayName = [string]$base.flow
    if (-not $displayName) { $displayName = $FlowName }
    if ($ScriptsRoot) {
        $run = Find-LatestFlowRun $ScriptsRoot $displayName
        $searched = $displayName
        if (-not $run -and $displayName -ne $FlowName) {
            # Fallback: a few old baselines wrote the business name into the flow field
            $run = Find-LatestFlowRun $ScriptsRoot $FlowName
            $searched = "$displayName (fallback $FlowName)"
        }
        if (-not $run) {
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
                message = "flow $displayName not found in the local run history; cannot resolve its identity"
                evidence = @("scriptsRoot=$ScriptsRoot", "searched=$searched")
            }
        }
        if ($base.flowGuid -and [string]$base.flowGuid -ne [string]$run.flowGuid) {
            $ev += "flowGuid baseline=$($base.flowGuid) current=$($run.flowGuid)"
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_FLOW_STALE'
                message = 'the flow GUID recorded in the baseline has changed (the flow was rebuilt or retargeted)'
                evidence = $ev
            }
        }
    }
    if ($base.environmentId -and $EnvironmentId -and [string]$base.environmentId -ne [string]$EnvironmentId) {
        $ev += "environmentId baseline=$($base.environmentId) current=$EnvironmentId"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = 'baseline does not match the current PAD environment'
            evidence = $ev
        }
    }
    if ($base.machine -and [string]$base.machine -ne [string]$Machine) {
        $ev += "machine baseline=$($base.machine) current=$Machine"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = 'baseline does not match the current machine'
            evidence = $ev
        }
    }

    # 4) Backward compatibility: an old baseline has no deployed section, so the published copy cannot be proven consistent → it must not count as pass
    if (-not $depBase -or -not $depBase.logicHash) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = 'baseline has no deployed hash; reseed (new format after the source/deployed split)'
            evidence = $ev
        }
    }

    # 5) Source against source: the repo .robin is compared only with the source hash in the baseline (raw bytes)
    if ($baseSource -ne [string]$parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_SOURCE_MISMATCH'
            message = 'source .robin differs from the baseline (the flow definition changed; republish or reseed)'
            evidence = $ev
        }
    }
    $baseConfig = [string]$(if ($srcBase -and $srcBase.configSha256) { $srcBase.configSha256 } else { $base.hashes.config })
    if ($baseConfig -and $baseConfig -ne [string]$parts.config) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_CONFIG_STALE'
            message = 'deployment config differs from the baseline (variable substitution results will change)'
            evidence = $ev
        }
    }

    # 6) The deployed side is compared only against the deployment artifact: the source is a template containing {{VAR}} placeholders,
    #    which after normalization can never equal the substituted published copy. So compare against "the deployment artifact",
    #    still only by normalized hash and never by raw bytes across domains.
    if (-not $DeployedRobinPath) {
        # Auto-derivation: <source file name without extension>.deployed.robin next to the source .robin
        $srcLeaf = [IO.Path]::GetFileNameWithoutExtension($RobinPath) + '.deployed.robin'
        $srcDir = [IO.Path]::GetDirectoryName($RobinPath)
        $DeployedRobinPath = Join-Path $srcDir $srcLeaf
    }
    $depLeaf = [IO.Path]::GetFileName($DeployedRobinPath)
    if (-not (Test-Path -LiteralPath $DeployedRobinPath)) {
        $ev += "deployed=$DeployedRobinPath"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = "deployment artifact not found; generate $depLeaf first"
            evidence = $ev
        }
    }
    $nowLogic = Get-RobinLogicHash $DeployedRobinPath
    if ($nowLogic -ne [string]$depBase.logicHash) {
        $ev += "deployed=$DeployedRobinPath"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_DEPLOYED_MISMATCH'
            message = 'deployment artifact is logically inconsistent with the published copy (the published copy is stale or was modified)'
            evidence = $ev
        }
    }

    # Differing raw bytes are normal (the source is a template and PAD appends @@ headers on write); record it but never fail on it
    $note = ' (source is a template with placeholders; its raw bytes differing from the deployment artifact is expected)'
    $ev += "deployed=$DeployedRobinPath"
    $depRaw = (Get-FileHash -LiteralPath $DeployedRobinPath -Algorithm SHA256).Hash.ToLower()
    if ([string]$depBase.robinSha256 -and $depRaw -ne [string]$depBase.robinSha256) {
        $note += ' (deployment artifact raw bytes differ from the published copy; identical after normalization)'
        $ev += "deployedRaw=$($depRaw.Substring(0,12)) workspaceRaw=$([string]$depBase.robinSha256.ToString().Substring(0,12))"
    }
    return [ordered]@{
        status = 'pass'; code = 'OK'
        message = "matches the baseline: $fpLine$note"
        evidence = (@($BaselinePath) + $ev)
    }
}

Export-ModuleMember -Function Get-FlowGuidFromLogPath, Find-LatestFlowRun, Find-WorkspaceRobin,
    Get-PadEnvironmentId, Get-FingerprintParts, Get-FingerprintBaselinePath,
    Get-RobinLogicHash, Get-WorkspaceRootFromScriptsRoot,
    Read-FingerprintScriptConfig,
    Get-ScriptFingerprintParts, Get-ExternalScriptFingerprintParts, Test-ScriptFingerprint,
    Read-FingerprintBaseline, Write-FingerprintBaseline, New-FingerprintBaseline, Test-FlowFingerprint
