# Smoke script: verifies the toolchain on a fresh clone (no business directory, fingerprint baseline or PAD run history needed)
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File examples\smoke.ps1
# Exit codes: 0 all steps passed / 1 any step failed
#
# Steps: canvas -> generate -> check.js -> pad-admit -> eval-flow

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$flow = Join-Path $PSScriptRoot 'smoke-flow.json'
$kb = Join-Path $PSScriptRoot 'smoke-kb.json'
$cases = Join-Path $PSScriptRoot 'smoke.cases.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('flow-ir-smoke-' + [guid]::NewGuid().ToString('N'))
$failed = $false

function Invoke-Step {
    param(
        [string]$Name,
        [string]$WorkingDirectory,
        [string]$Command,
        [string[]]$Arguments
    )
    Write-Host "[smoke] $Name"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Command @Arguments
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) { throw "$Name failed (exit=$code)" }
}

try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    # check.js looks for the knowledge base in the repo root first, then the current directory; putting the minimal
    # action table in the current directory lets a fresh clone without pad-robin-action-kb/ still pass static checks
    $kbDir = Join-Path $work 'pad-robin-action-kb'
    New-Item -ItemType Directory -Path $kbDir -Force | Out-Null
    Copy-Item -LiteralPath $kb -Destination (Join-Path $kbDir 'PAD_Robin_ActionKB.json') -Force

    $drawio = Join-Path $work 'smoke-flow.drawio'
    $robin = Join-Path $work 'smoke-flow.robin'
    $admit = Join-Path $repo 'tools\pad-sync\pad-admit.ps1'

    # A fresh clone may not have run npm install yet; fall back to the repo's deterministic BFS layout so the
    # canvas step never depends on node_modules/elkjs
    $drawioScript = Join-Path $repo 'tools\flow-drawio\flow-to-drawio.js'
    if (-not (Test-Path (Join-Path $repo 'node_modules\elkjs'))) {
        $drawioScript = Join-Path $repo 'tools\flow-drawio\flow-to-drawio-bfs.js'
    }

    Invoke-Step 'canvas' $repo 'node' @($drawioScript, $flow, $drawio)
    Invoke-Step 'generate' $repo 'node' @(
        (Join-Path $repo 'tools\pad-robin\flow-to-robin.js'), $flow, $robin, '--kb', $kb, '--no-check')
    Invoke-Step 'static checks' $work 'node' @(
        (Join-Path $repo 'tools\pad-robin\check.js'), $robin)
    Invoke-Step 'admission' $work 'powershell' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $admit,
        '-FlowFile', $flow, '-RobinFile', $robin, '-KbPath', $kb)
    Invoke-Step 'structural evaluation' $repo 'node' @(
        (Join-Path $repo 'tools\pad-robin\eval-flow.js'), $cases)

    Write-Host '[smoke] passed (exit 0)'
} catch {
    Write-Host "[smoke] failed: $($_.Exception.Message)"
    $failed = $true
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
exit 0
