# PadAcceptance.psm1 — executor for V-model acceptance criteria
#
# Purpose: after a run finishes, check the artifacts and business postconditions instead of only "PAD reported no error".
# Paths in the criteria file (*.acceptance.json) support {{KEY}} placeholders whose values come from the deployment config.
#
# Supported check types:
#   fileExists    the file exists (optional minBytes / match regex)
#   globNewerThan at least one file matching the pattern in the directory is newer than this run's start time
#   pair          the two files must both exist or both be absent
#   json          the JSON parses and contains the specified top-level keys
#   jsonl         every line is valid JSON
#
# Every check supports optional=true: when unmet it is recorded as skipped, not as a failure.

# VBS logs may be UTF-16LE / ANSI / UTF-8; read them all through the encoding-detection module
Import-Module (Join-Path $PSScriptRoot 'TextEncoding.psm1') -Force

function Get-AcceptanceConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "config file not found: $Path" }
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::UTF8)
    $text = $text -replace "^\uFEFF", ''
    $obj = $text | ConvertFrom-Json

    $map = @{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

# Replace {{KEY}} with the value from config; unknown placeholders are left as-is and reported by the individual check
function Resolve-AcceptancePath {
    param([string]$Text, [hashtable]$Config)

    return [regex]::Replace($Text, '\{\{([A-Za-z0-9_]+)\}\}', {
        param($m)
        $key = $m.Groups[1].Value
        if ($Config.ContainsKey($key)) { return [string]$Config[$key] }
        return $m.Value
    })
}

function Test-AcceptanceFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [datetime]$Since = (Get-Date).AddHours(-6)
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "acceptance spec not found: $Path" }
    $specText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::UTF8)
    $specText = $specText -replace "^\uFEFF", ''
    $spec = $specText | ConvertFrom-Json
    $checks = @()

    foreach ($c in @($spec.checks)) {
        $optional = [bool]$c.optional
        $item = [ordered]@{ name = [string]$c.name; type = [string]$c.type; ok = $false; skipped = $false; detail = '' }

        try {
            if ($c.type -eq 'fileExists') {
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = 'file not found (optional)' }
                    else { $item.detail = "file not found: $p" }
                } else {
                    $file = Get-Item -LiteralPath $p
                    $min = 0
                    if ($null -ne $c.minBytes) { $min = [int]$c.minBytes }
                    if ($file.Length -lt $min) {
                        $item.detail = "file too small: $($file.Length) < $min bytes"
                    } elseif ($c.match) {
                        $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                        if ($text -match [string]$c.match) { $item.ok = $true; $item.detail = "content matches $($c.match)" }
                        else { $item.detail = "content does not match $($c.match)" }
                    } else {
                        $item.ok = $true
                        $item.detail = "present ($($file.Length) bytes)"
                    }
                }
            }
            elseif ($c.type -eq 'globNewerThan') {
                $dir = Resolve-AcceptancePath ([string]$c.dir) $Config
                $files = @()
                if (Test-Path -LiteralPath $dir) {
                    $files = @(Get-ChildItem -LiteralPath $dir -Filter ([string]$c.pattern) -File -ErrorAction SilentlyContinue)
                }
                $fresh = @($files | Where-Object { $_.LastWriteTime -ge $Since })
                if ($fresh.Count -gt 0) {
                    $newest = $fresh | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    $item.ok = $true
                    $item.detail = "newest file: $($newest.Name) at $($newest.LastWriteTime.ToString('HH:mm:ss'))"
                } elseif ($optional) {
                    $item.skipped = $true
                    $item.detail = 'this run produced no such file (optional)'
                } else {
                    $item.detail = "no file newer than $($Since.ToString('HH:mm:ss')): $dir\$($c.pattern)"
                }
            }
            elseif ($c.type -eq 'pair') {
                $paths = @($c.paths | ForEach-Object { Resolve-AcceptancePath ([string]$_) $Config })
                $exists = @($paths | Where-Object { Test-Path -LiteralPath $_ })
                if ($exists.Count -eq $paths.Count) {
                    $item.ok = $true
                    $item.detail = 'both files exist'
                } elseif ($exists.Count -eq 0) {
                    if ($optional) { $item.skipped = $true; $item.detail = 'neither file exists (optional)' }
                    else { $item.detail = 'neither file exists' }
                } else {
                    $item.detail = "only $($exists.Count)/$($paths.Count) files exist"
                }
            }
            elseif ($c.type -eq 'json') {
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = 'file not found (optional)' }
                    else { $item.detail = "file not found: $p" }
                } else {
                    $obj = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $names = @($obj.PSObject.Properties.Name)
                    $missing = @($c.requiredKeys | Where-Object { $names -notcontains $_ })
                    if ($missing.Count -eq 0) { $item.ok = $true; $item.detail = 'valid JSON with all required keys' }
                    else { $item.detail = "missing keys: $($missing -join ', ')" }
                }
            }
            elseif ($c.type -eq 'jsonl') {
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = 'file not found (optional)' }
                    else { $item.detail = "file not found: $p" }
                } else {
                    $badLine = 0
                    $lineNo = 0
                    foreach ($line in [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)) {
                        $lineNo++
                        if (-not $line.Trim()) { continue }
                        try { [void]($line | ConvertFrom-Json) } catch { $badLine = $lineNo; break }
                    }
                    if ($badLine -gt 0) { $item.detail = "line $badLine is not valid JSON" }
                    else { $item.ok = $true; $item.detail = "all $lineNo lines are valid" }
                }
            }
            elseif ($c.type -eq 'logState') {
                # Read an existing VBS log: take a line by firstLine / lastLine, then check skip first, then fail, then pass
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = 'log not found (optional)' }
                    else { $item.detail = "log not found: $p" }
                } else {
                    $text = (Read-TextFileAuto $p).text
                    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
                    if ($lines.Count -eq 0) {
                        $item.detail = 'log is empty'
                    } else {
                        $line = $(if ([string]$c.mode -eq 'lastLine') { $lines[-1] } else { $lines[0] })
                        if ($c.skip -and $line -match [string]$c.skip) {
                            $item.skipped = $true
                            $item.detail = "state is $($c.skip); not applicable"
                        } elseif ($c.fail -and $line -match [string]$c.fail) {
                            $item.detail = "failure marker hit: $line"
                        } elseif ($c.pass -and $line -match [string]$c.pass) {
                            $item.ok = $true
                            $item.detail = "success marker hit: $line"
                        } else {
                            $item.detail = "log line does not match expectations: $line"
                        }
                    }
                }
            }
            else {
                $item.detail = "unknown check type: $($c.type)"
            }
        } catch {
            $item.detail = "check threw: $($_.Exception.Message)"
        }

        $checks += [pscustomobject]$item
    }

    $failed = @($checks | Where-Object { -not $_.ok -and -not $_.skipped })
    return [pscustomobject]([ordered]@{
        ok             = ($failed.Count -eq 0)
        acceptanceFile = (Resolve-Path -LiteralPath $Path).Path
        since          = $Since.ToString('o')
        total          = $checks.Count
        passed         = @($checks | Where-Object { $_.ok }).Count
        failed         = $failed.Count
        skipped        = @($checks | Where-Object { $_.skipped }).Count
        checks         = $checks
    })
}

Export-ModuleMember -Function Get-AcceptanceConfig, Resolve-AcceptancePath, Test-AcceptanceFile
