# pre-commit.ps1 - commit-boundary content gate: scans only the staged snapshot that this commit will record
#
# Called by .githooks\pre-commit; setup.ps1 points core.hooksPath at .githooks.
# Unstaged working-tree edits are not scanned, so we never end up scanning one version and committing another.
#
# Exit codes: 0 allows the commit; non-zero blocks it (a content hit, or the gate itself failing).

param()

$ErrorActionPreference = 'Stop'

function Write-GateInfo {
    param($Message, $Color = 'Gray')
    Write-Host "[pre-commit] $Message" -ForegroundColor $Color
}

# 1) Repo root: the hook's working directory is not reliable, so always take git's answer
$repoRoot = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if (-not $repoRoot) {
    Write-GateInfo 'Not inside a Git repository; skipping the public-content gate'
    exit 0
}
$repoRoot = $repoRoot.Trim()

$gate = Join-Path $repoRoot 'tools\publish\check-public-safe.ps1'
if (-not (Test-Path -LiteralPath $gate)) {
    Write-GateInfo "Scan script not found: $gate" 'Red'
    exit 1
}

# 2) Staged list: ACMR = added/copied/modified/renamed; deleted files have no content left to scan
#    --no-renames degrades a rename into "add + delete", so a rename never leaves half a path unscanned
$staged = @(& git -C $repoRoot -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR --no-renames |
        Where-Object { $_ -and $_.Trim() })
if ($staged.Count -eq 0) {
    Write-GateInfo 'Nothing staged to scan; allowing the commit'
    exit 0
}

# 3) business\ is normally hidden by .gitignore; staging it with git add -f is blocked outright
$forcedBusiness = @($staged | Where-Object { $_ -eq 'business' -or $_ -like 'business/*' -or $_ -like 'business\*' })
if ($forcedBusiness.Count -gt 0) {
    Write-GateInfo 'Files under business\ are staged (that directory must never be committed):' 'Red'
    $forcedBusiness | ForEach-Object { Write-Host "    $_" }
    exit 1
}

# 4) A missing default denylist only prints a notice and leaves the exit code alone (same as CI; otherwise any clone
#    without the list would block every commit)
$defaultList = Join-Path $repoRoot 'tools\publish\public-safe.denylist.json'
if (-not (Test-Path -LiteralPath $defaultList)) {
    Write-GateInfo 'Default denylist tools\publish\public-safe.denylist.json is missing, so the content gate is inactive (notice only, not blocking)' 'Yellow'
    exit 0
}

$localList = Join-Path $repoRoot 'tools\publish\public-safe.denylist.local.json'
if (-not (Test-Path -LiteralPath $localList)) {
    Write-GateInfo 'Local denylist public-safe.denylist.local.json not found: scanning with the default 5 structural rules only (PAD/Robot root paths, UNC paths, internal host suffixes, email addresses, mobile numbers); business names, flow names and ordinary local paths are NOT covered' 'Yellow'
}

# 5) Export the index into a temporary directory snapshot: what gets checked is the bytes about to be committed,
#    not the current working tree
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('pre-commit-public-safe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$exitCode = 0
try {
    $prefix = $tmpRoot.Replace('\', '/') + '/'
    & git -C $repoRoot -c core.quotePath=false checkout-index --prefix="$prefix" -f -- @staged | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git checkout-index failed to export the staged snapshot' }

    # Reuse the scan script's pure-function entry point instead of copying the matching logic; omit -DenylistFile
    # so the local override list is merged automatically
    . $gate -NoMain
    $scanFiles = @($staged | ForEach-Object { Join-Path $tmpRoot $_ })
    $result = Invoke-PublicSafeScan -Files $scanFiles -RepoRoot $repoRoot

    # Hit lines are always "relative path:line:matched word", matching check-public-safe.ps1's format
    foreach ($hit in @($result.Hits)) {
        $rel = $hit.File
        if ($rel.StartsWith($tmpRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($tmpRoot.Length).TrimStart('\', '/')
        }
        Write-Output ('{0}:{1}:{2}' -f $rel, $hit.Line, $hit.Match)
        Write-Host ("    rule {0} ({1}): {2}" -f $hit.RuleId, $hit.Category, $hit.Reason)
    }

    foreach ($e in @($result.Errors)) { Write-GateInfo "Scan error: $e" 'Red' }

    if ([int]$result.ExitCode -ne 0) {
        Write-GateInfo ("Public-content gate failed ({0} hit(s)): rewrite each hit as neutral wording or a placeholder by file:line and stage again; do not delete the rule word, comment out the hit line, or bypass with --no-verify" -f @($result.Hits).Count) 'Red'
        $exitCode = [int]$result.ExitCode
    } else {
        Write-GateInfo ("Public-content gate passed (scanned {0} staged file(s))" -f @($result.Scanned).Count) 'Green'
    }
} catch {
    Write-GateInfo "Gate execution failed: $($_.Exception.Message)" 'Red'
    $exitCode = 1
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
