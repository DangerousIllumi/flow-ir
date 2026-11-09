<#
.SYNOPSIS
    flow-ir - local framework installer.
.DESCRIPTION
    1. Check the Node.js / Git environment
    2. Clone pad-robin-action-kb (the action knowledge base)
    3. Verify that check-flows.js works as a self-check
    4. Create the project directory layout
.EXAMPLE
    .\setup.ps1
.NOTES
    Run .\tools\check-env.ps1 first to confirm the environment is ready.
#>

param(
    # Clone URL for the action knowledge base. HTTPS is tried before SSH by default;
    # on restricted networks or behind a proxy/firewall GitHub may be unreachable, so a mirror or a local path can be given.
    [string]$KbRepo = ""
)

$ErrorActionPreference = "Stop"
$WorkDir = $PSScriptRoot
$KBDir = Join-Path $WorkDir "pad-robin-action-kb"
$KBRepoHttps = "https://github.com/JoeG592/pad-robin-action-kb.git"
$KBRepoSsh   = "git@github.com:JoeG592/pad-robin-action-kb.git"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    [INFO] $msg" -ForegroundColor Gray }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# ── 1. Environment preflight ──────────────────────────────────
Write-Step "1/4 Checking the runtime environment"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Fail "Node.js not detected; install it first (https://nodejs.org/)"
    exit 1
}
$nodeVer = & node -v
$major = [int]($nodeVer -replace 'v','' -split '\.')[0]
if ($major -lt 18) {
    Write-Fail "Node.js version too old ($nodeVer < v18); upgrade it"
    exit 1
}
Write-Ok "Node.js $nodeVer"

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Fail "Git not detected; install it first (https://git-scm.com/download/win)"
    exit 1
}
Write-Ok "Git $(& git --version)"

# Enable the in-repo hook (public-content gate before each commit) so a fresh clone needs no manual setup
& git -C $WorkDir config core.hooksPath .githooks
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Git hook directory: .githooks"
} else {
    Write-Warn "core.hooksPath could not be set; the pre-commit content gate will not run automatically"
}

# Install the Node dependencies (ELK layout for flow diagrams)
if (Test-Path (Join-Path $WorkDir "package.json")) {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        Write-Info "Installing Node dependencies (elkjs)"
        Push-Location $WorkDir
        & npm install --no-audit --no-fund
        $npmExit = $LASTEXITCODE
        Pop-Location
        if ($npmExit -eq 0) {
            Write-Ok "Node dependencies installed"
        } else {
            Write-Warn "npm install failed; run npm install manually before generating flow diagrams"
        }
    } else {
        Write-Warn "npm not detected; the ELK layout for flow diagrams is unavailable (everything else still works)"
    }
}

# ── 2. Clone the knowledge base ──────────────────────────────
Write-Step "2/4 Cloning pad-robin-action-kb (the PAD action knowledge base)"

# On restricted networks or behind a proxy/firewall, HTTPS to GitHub may be reset (shown as
# "Recv failure: Connection was reset"), so SSH is tried once after HTTPS fails. When neither works we print
# manual steps instead of only reporting "clone failed".

# Network wait limits: give up on HTTPS after 20 s of low speed; time out the SSH connection after 15 s and
# disable interactive prompts, so git cannot hang silently on a restricted network (progress is printed by Invoke-GitNet below).
$gitNetArgs = @(
    '-c', 'http.lowSpeedLimit=1000',
    '-c', 'http.lowSpeedTime=20',
    '-c', 'core.sshCommand=ssh -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o BatchMode=yes'
)

function Invoke-GitNet {
    # git writes both progress and errors to stderr, while the script-wide ErrorActionPreference is Stop:
    # a plain 2>&1 would be treated as a terminating error, so lower it to Continue here and echo line by line
    param([string]$WorkDir, [string[]]$GitArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $WorkDir
    try {
        & git @GitArgs 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevEap
    }
    return $LASTEXITCODE
}

$candidates = @()
if ($KbRepo) { $candidates += $KbRepo } else { $candidates += $KBRepoHttps, $KBRepoSsh }

# A failed clone leaves an empty directory behind; clear that half-finished state first, otherwise the later git pull fails too
if ((Test-Path $KBDir) -and -not (Test-Path (Join-Path $KBDir "PAD_Robin_ActionKB.json"))) {
    Write-Warn "Existing directory is incomplete (no PAD_Robin_ActionKB.json); removing it and cloning again"
    Remove-Item $KBDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (Test-Path $KBDir) {
    Write-Info "Directory already exists; running git pull to update"
    $pullExit = Invoke-GitNet -WorkDir $KBDir -GitArgs @($gitNetArgs + @('pull', '--ff-only'))
    if ($pullExit -ne 0) { Write-Warn "Update failed (network problem or the remote moved on); continuing with the local copy" }
} else {
    $cloned = $false
    foreach ($repo in $candidates) {
        Write-Info "Cloning $repo (roughly a 20 s network timeout; progress below)"
        $cloneExit = Invoke-GitNet -WorkDir $WorkDir -GitArgs @($gitNetArgs + @('clone', '--depth', '1', '--progress', $repo, $KBDir))
        if ($cloneExit -eq 0 -and (Test-Path (Join-Path $KBDir "PAD_Robin_ActionKB.json"))) { $cloned = $true; break }
        Write-Warn "That URL did not work (the line above is git's raw error); trying the next one"
        if (Test-Path $KBDir) { Remove-Item $KBDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (-not $cloned) {
        Write-Fail "Clone failed: neither HTTPS nor SSH works"
        Write-Info "Manual options (pick one):"
        Write-Info "  1) git clone git@github.com:JoeG592/pad-robin-action-kb.git `"$KBDir`""
        Write-Info "  2) Download the ZIP in a browser and extract it to `"$KBDir`""
        Write-Info "  3) Rerun with another URL: .\setup.ps1 -KbRepo <mirror or local path>"
        exit 1
    }
}

# Verify that the key files are present
$kbFile     = Join-Path $KBDir "PAD_Robin_ActionKB.json"
$typeFile   = Join-Path $KBDir "PAD_Robin_TypeReference.json"
$promptFile = Join-Path $KBDir "PROMPT.md"
$rulesFile  = Join-Path $KBDir "rules\robin-rules.json"
$checkFlows = Join-Path $KBDir "marketing\video\tools\check-flows.js"

foreach ($f in @($kbFile, $typeFile, $promptFile, $rulesFile, $checkFlows)) {
    if (Test-Path $f) {
        $rel = $f.Replace("$KBDir\", "")
        Write-Ok "Fetched: $rel"
    } else {
        Write-Fail "Missing key file: $f"
        exit 1
    }
}

# Print knowledge-base statistics so the user can tell which version this is
$kb = Get-Content $kbFile -Raw | ConvertFrom-Json
# modules is an array in the knowledge base; counting NoteProperty via Get-Member yields 0, so count the array
Write-Info "KB version $($kb.version), PAD build $($kb.pad_build), $(($kb.actions).Count) actions, $(@($kb.modules).Count) modules"
Write-Info "Rules file: $((Get-Content $rulesFile -Raw | ConvertFrom-Json).rules.Count) rules, verified $(Get-Content $rulesFile -Raw | ConvertFrom-Json).date"

# ── 3. Verify check-flows.js ─────────────────────────────────
Write-Step "3/4 Verifying that the check-flows.js self-checker works"

$okFlow   = Join-Path $env:TEMP "wfg-smoke-ok.robin"
$badFlow  = Join-Path $env:TEMP "wfg-smoke-bad.robin"

# Valid script (exit code should be 0)
@'
SET Counter TO 0
LOOP WHILE (Counter) < (3)
    SET Counter TO Counter + 1
END
'@ | Set-Content -Path $okFlow -Encoding UTF8

# Invalid script: uses the reserved keyword Mail.From as a variable name (check-flows should report an error)
@'
SET Mail.From TO "user@example.com"
'@ | Set-Content -Path $badFlow -Encoding UTF8

Push-Location $KBDir
$okOutput  = & node "marketing\video\tools\check-flows.js" PAD_Robin_ActionKB.json $okFlow  2>&1
$okExit    = $LASTEXITCODE
$badOutput = & node "marketing\video\tools\check-flows.js" PAD_Robin_ActionKB.json $badFlow 2>&1
$badExit   = $LASTEXITCODE
Pop-Location

Remove-Item $okFlow, $badFlow -ErrorAction SilentlyContinue

if ($okExit -eq 0 -and $badExit -ne 0) {
    Write-Ok "Both smoke cases behaved as expected"
    Write-Info "Valid script: $okOutput"
    Write-Info "Invalid script: $badOutput"
} else {
    Write-Warn "check-flows.js behaved suspiciously (valid=$okExit / invalid=$badExit), but the installation is unaffected"
    Write-Info "Valid script output: $okOutput"
    Write-Info "Invalid script output: $badOutput"
}

# ── 4. Create the project directory layout ───────────────────
Write-Step "4/4 Creating the project directory layout"

# business\flows\ holds the flow.json files you (or an AI assistant) write; generated .robin files default to the repo root.
# The whole business layer is ignored by .gitignore, so real flows, configuration and output never leak into the public repo.
$dirs = @("business\flows")
foreach ($d in $dirs) {
    $path = Join-Path $WorkDir $d
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        Write-Ok "Created directory: $d"
    } else {
        Write-Info "Directory already exists: $d"
    }
}

# Note: the framework docs under docs\ ship with this package, so the installer does not copy them again;
# that avoids two same-named copies in the root and docs\ (change one, read the other).

# ── Done ─────────────────────────────────────────────────────
Write-Host "`n"
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Framework installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Directory layout:" -ForegroundColor Cyan
Write-Host "  $WorkDir\"
Write-Host "  ├── pad-robin-action-kb\   action knowledge base (1,086 actions + types + checker)"
Write-Host "  ├── AGENTS.md              entry manual for AI assistants"
Write-Host "  ├── docs\                  documentation layer (including prompts\ and skills\)"
Write-Host "  ├── skills\                design rules and script red lines"
Write-Host "  ├── tools\                 compiler / checks / admission / deploy / scheduling"
Write-Host "  └── business\flows\        flow.json files you (or an AI) write (never committed)"
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Open this directory with any AI coding assistant - it reads AGENTS.md first"
Write-Host "  2. Paste the block from docs\prompts\nl-to-flow.md and append your requirement"
Write-Host "  3. Once generate -> static checks -> admission have run, paste out.robin into the PAD canvas"
Write-Host ""
# Earlier steps may have failed degradably (e.g. a git pull update only warns), so do not leak a stale $LASTEXITCODE to the caller
exit 0
