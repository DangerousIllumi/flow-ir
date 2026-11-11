<#
.SYNOPSIS
    Public-layer language gate: Chinese is allowed only in files registered in the allowlist.
.DESCRIPTION
    Scans the given files, skips binaries and everything under business/, and counts CJK characters.
    Three conditions fail the gate: a file with CJK that is not registered, an allowlisted file that no
    longer contains CJK (stale entry), and an allowlisted path that does not exist.

    Usage: .\tools\publish\check-public-lang.ps1 -Files (git ls-files)
    Exit codes: 0 pass, 1 any violation.

    Non-ASCII characters in violation lines are printed as \uXXXX escapes so the whole report stays ASCII;
    a non-UTF-8 console code page would otherwise turn them into question marks.
#>
param(
    [string[]]$Files = @(),
    [string]$AllowlistFile
)

$ErrorActionPreference = 'Stop'

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $AllowlistFile) { $AllowlistFile = Join-Path $PSScriptRoot 'public-lang-allowlist.json' }

function ConvertTo-AsciiEscape {
    param([string]$Text)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 128) { [void]$sb.Append($ch) }
        elseif ($code -eq 0xFEFF) { }
        else { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    }
    return $sb.ToString()
}

function Test-IsBinary {
    param([byte[]]$Bytes)
    $limit = [Math]::Min($Bytes.Length, 8000)
    for ($i = 0; $i -lt $limit; $i++) {
        if ($Bytes[$i] -eq 0) { return $true }
    }
    return $false
}

if (-not (Test-Path -LiteralPath $AllowlistFile)) {
    Write-Output "[public-lang] allowlist not found: $AllowlistFile"
    Write-Output 'PUBLIC_LANG_RESULT=fail'
    exit 1
}

$doc = Get-Content -LiteralPath $AllowlistFile -Raw | ConvertFrom-Json
$allowed = @{}
$duplicates = @()
foreach ($group in $doc.reasons.PSObject.Properties) {
    foreach ($path in @($group.Value)) {
        $key = ([string]$path).Replace('\', '/')
        if ($allowed.ContainsKey($key)) { $duplicates += $key } else { $allowed[$key] = $group.Name }
    }
}

$violations = @()
$stale = @()
$missing = @()
foreach ($key in @($allowed.Keys)) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $key))) { $missing += $key }
}

$scanned = 0
$seen = @{}
$scannedSet = @{}
foreach ($file in $Files) {
    if (-not $file) { continue }
    $rel = ([string]$file).Replace('\', '/')
    if ($rel -eq 'business' -or $rel.StartsWith('business/')) { continue }
    $full = Join-Path $repoRoot $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $bytes = [IO.File]::ReadAllBytes($full)
    if (Test-IsBinary $bytes) { continue }
    $scanned++
    $scannedSet[$rel] = $true
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch '[\u4e00-\u9fff]') { continue }
    $seen[$rel] = $true
    if ($allowed.ContainsKey($rel)) { continue }
    $lines = $text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '[\u4e00-\u9fff]') {
            $violations += ('{0}:{1}: {2}' -f $rel, ($i + 1), (ConvertTo-AsciiEscape $lines[$i].Trim()))
        }
    }
}

foreach ($key in @($allowed.Keys)) {
    if ($scannedSet.ContainsKey($key) -and -not $seen.ContainsKey($key)) { $stale += $key }
}

foreach ($d in $duplicates) { Write-Output "- duplicate allowlist path: $d" }
foreach ($m in $missing) { Write-Output "- missing allowlisted file: $m" }
foreach ($s in $stale) { Write-Output "STALE_ENTRY $s" }
foreach ($v in $violations) { Write-Output $v }

$fail = (($violations.Count + $stale.Count + $missing.Count + $duplicates.Count) -gt 0)
Write-Output ('[public-lang] allowlisted={0} scanned={1} violation(s)={2} stale={3} missing={4}' -f `
        $allowed.Count, $scanned, $violations.Count, $stale.Count, $missing.Count)
Write-Output ('PUBLIC_LANG_RESULT={0}' -f $(if ($fail) { 'fail' } else { 'pass' }))
if ($fail) { exit 1 }
exit 0
