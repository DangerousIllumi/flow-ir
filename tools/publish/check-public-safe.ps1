# check-public-safe.ps1 — pre-push content gate: block business information by content, not by file name
#
# Why: on the last push to the public repo the whitelisted scripts were compliant in themselves, but their
# comments carried business names and real paths, so they leaked into the public repo. This gate therefore scans
# the content of the "files to push" list line by line and fails as a whole on a denylist hit.
#
# Usage:
#   .\check-public-safe.ps1 -Files @('tools\pad-sync\pad-sync.ps1', 'docs\x.md') -Verbose
#   .\check-public-safe.ps1 -Files ... -DenylistFile tools\publish\public-safe.denylist.json
#   .\check-public-safe.ps1 -Files ... -Quiet        # print only the matching lines
#
# Output: one "file:line:matched term" line per hit (via Write-Output, so it pipes cleanly)
# Exit codes: 0 all clean / 1 at least one hit / 2 the gate itself failed (empty list, missing file, a business directory in the list, missing denylist or a denylist with no rules)
#
# Denylist: defaults to tools\publish\public-safe.denylist.json; when
#   tools\publish\public-safe.denylist.local.json exists beside it, the two are merged automatically.
#   Real business terms live only in the local file, which is never pushed (see section 9 of docs\admission-gate.md).
#
# Business directory: business\ never enters the repository. Any business\ file passed in -Files is an
#   immediate error (exit code 2), which removes the silent risk of pushing a business file by accident.
#
# Encoding: reuses the probing in pad-sync\TextEncoding.psm1 (UTF-8 / UTF-16 / ANSI).
#   A NUL-bearing file that is not UTF-16LE is read as binary and decoded losslessly as Latin1, so only ASCII-style rules can match instead of mojibake hits from a forced UTF-8 read.

[CmdletBinding()]
param(
    # The files to push (relative to the repository root, or absolute)
    [Parameter(Position = 0)]
    [string[]]$Files,
    # Denylist paths; several may be given. When omitted, the default denylist plus the local override is used
    [string[]]$DenylistFile,
    # Repository root; defaults to the parent of the directory holding this script
    [string]$RepoRoot,
    # Print only the matching lines, without the summary and the hints
    [switch]$Quiet,
    # For Pester dot-sourcing only: do not run the main flow
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

# Encoding probing is shared with the other tools in this repository, so the rules cannot drift apart
$script:EncodingModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'pad-sync\TextEncoding.psm1'
# -Verbose:$false silences only the module import log; it does not affect this script's own -Verbose output
Import-Module $script:EncodingModule -Force -Verbose:$false

# Read the text to be scanned: returns Text (the body) and Kind (utf-8-bom / utf-16le / ansi / binary / empty)
# Key point: a .vbs file may be UTF-16LE with a BOM, so it must not be force-read as UTF-8; binaries must never be thrown at a UTF-8 guess
function Read-GateText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return [pscustomobject]@{ Text = ''; Kind = 'empty' }
    }

    # 1) When a BOM is present (UTF-8 / UTF-16LE / UTF-16BE), trust it and let the shared probe decode
    $hasBom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $hasBom = $true }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $hasBom = $true }

    if (-not $hasBom) {
        # Sample only the first 8KB, so a large file is not walked end to end
        $sample = [Math]::Min($bytes.Length, 8192)
        $oddZeros = 0
        $evenZeros = 0
        $nulCount = 0
        for ($i = 0; $i -lt $sample; $i++) {
            if ($bytes[$i] -eq 0) {
                $nulCount++
                if ($i % 2 -eq 0) { $evenZeros++ } else { $oddZeros++ }
            }
        }
        $half = [Math]::Max(1, [int]($sample / 2))

        # 2) BOM-less UTF-16LE: plenty of 0x00 bytes at odd offsets, almost none at even offsets
        if ($sample -ge 8 -and ($oddZeros / $half) -gt 0.3 -and ($evenZeros / $half) -lt 0.05) {
            $enc = New-Object Text.UnicodeEncoding($false, $false)
            return [pscustomobject]@{ Text = $enc.GetString($bytes); Kind = 'utf-16le' }
        }

        # 3) Anything else with NUL counts as binary: decoded losslessly as Latin1, so only ASCII-style rules can ever match
        if ($nulCount -gt 0) {
            $latin1 = [Text.Encoding]::GetEncoding(28591)
            return [pscustomobject]@{ Text = $latin1.GetString($bytes); Kind = 'binary' }
        }
    }

    # 4) Plain text: hand it to the shared probe (UTF-8 / ANSI / UTF-16 with a BOM)
    $info = Read-TextFileAuto $Path
    return [pscustomobject]@{ Text = $info.text; Kind = $info.kind }
}

# Load the denylist: a category key is a rule category; the rule fields are described in tools\publish\public-safe.denylist.json
# Returns Rules (compiled regexes), Errors (denylist problems) and Sources (the denylist files actually used)
function Import-GateDenylist {
    param([string[]]$Paths)

    $rules = @()
    $errors = @()
    $sources = @()
    $allowDomains = @()

    foreach ($dl in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($dl)) { continue }
        if (-not (Test-Path -LiteralPath $dl)) {
            $errors += "denylist not found: $dl"
            continue
        }
        $sources += $dl
        try {
            $doc = ConvertFrom-Json ([IO.File]::ReadAllText($dl, [Text.Encoding]::UTF8))
        } catch {
            $errors += "failed to parse the denylist: $dl ($($_.Exception.Message))"
            continue
        }
        if (-not $doc.categories) {
            $errors += "denylist has no categories: $dl"
            continue
        }

        # Reserved-domain allowlist: a hit containing one of these domains is not a violation; enabled=false turns it off entirely
        if ($doc.PSObject.Properties.Name -contains 'allowlist' -and $null -ne $doc.allowlist) {
            $al = $doc.allowlist
            $alEnabled = $true
            if ($al.PSObject.Properties.Name -contains 'enabled' -and [bool]$al.enabled -eq $false) { $alEnabled = $false }
            if ($alEnabled) {
                $listed = @()
                foreach ($d in @($al.domains)) {
                    $s = ([string]$d).Trim().ToLowerInvariant()
                    if ($s) { $listed += $s }
                }
                if ($listed.Count -eq 0) {
                    $errors += "the allowlist has no domains: $dl"
                } else {
                    $allowDomains += $listed
                }
            }
        }

        foreach ($catProp in $doc.categories.PSObject.Properties) {
            $catName = [string]$catProp.Name
            foreach ($r in @($catProp.Value.rules)) {
                if ($null -eq $r) { continue }
                # enabled defaults to true; a rule with an explicit false is a format example only
                if ($r.PSObject.Properties.Name -contains 'enabled' -and [bool]$r.enabled -eq $false) { continue }

                $pattern = [string]$r.pattern
                if (-not $pattern) {
                    $errors += "denylist rule is missing pattern: $dl / $catName"
                    continue
                }
                $id = [string]$r.id
                if (-not $id) { $id = "$catName-$($rules.Count + 1)" }

                $isRegex = $false
                if ($r.PSObject.Properties.Name -contains 'regex' -and [bool]$r.regex -eq $true) { $isRegex = $true }
                # Literal rules are escaped automatically, so regex metacharacters inside a business term cannot over-match
                $src = if ($isRegex) { $pattern } else { [regex]::Escape($pattern) }

                $opts = [Text.RegularExpressions.RegexOptions]::IgnoreCase
                if ($r.PSObject.Properties.Name -contains 'caseSensitive' -and [bool]$r.caseSensitive -eq $true) {
                    $opts = [Text.RegularExpressions.RegexOptions]::None
                }
                try {
                    $rx = [Text.RegularExpressions.Regex]::new([string]$src, $opts)
                } catch {
                    $errors += "invalid denylist rule regex: $dl / $catName / $id ($($_.Exception.Message))"
                    continue
                }

                $rules += [pscustomobject]@{
                    Id       = $id
                    Category = $catName
                    Reason   = [string]$r.reason
                    Pattern  = $pattern
                    Regex    = $rx
                    Source   = $dl
                }
            }
        }
    }

    return [pscustomobject]@{ Rules = @($rules); Errors = @($errors); Sources = @($sources); AllowDomains = @($allowDomains) }
}

# Decide whether matched text contains a reserved domain (matched on domain boundaries, so example.com.cn is not let through by accident)
function Test-AllowedDomain {
    param([string]$Text, [string[]]$Domains)

    if (-not $Text -or @($Domains).Count -eq 0) { return $false }
    foreach ($d in @($Domains)) {
        $pattern = '(?i)(^|[.@/\\])' + [regex]::Escape($d) + '($|[/?#\s"''])' 
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

# Scan entry point: resolve the list, load the denylist, match line by line, and return one summary object (it prints nothing, which keeps it testable)
function Invoke-PublicSafeScan {
    [CmdletBinding()]
    param(
        [string[]]$Files,
        [string[]]$DenylistFile,
        [string]$RepoRoot
    )

    $root = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
    $errors = @()
    $missing = @()
    $resolved = @()

    if (-not (Test-Path -LiteralPath $root)) {
        $errors += "repository root does not exist: $root"
    }

    # 1) Resolve the list to push; relative paths always resolve against the repository root, so the current directory cannot change the result
    #    The business directory is a "never committed" zone: a hit is an error, never a silent skip
    $businessRoot = [IO.Path]::GetFullPath((Join-Path $root 'business'))
    if (-not $Files -or @($Files).Count -eq 0) {
        $errors += 'the file list to push is empty (-Files)'
    } else {
        foreach ($f in @($Files)) {
            if ([string]::IsNullOrWhiteSpace($f)) { continue }
            $full = if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $root $f }
            $fullPath = [IO.Path]::GetFullPath($full)
            $sep = [IO.Path]::DirectorySeparatorChar
            if ($fullPath.StartsWith($businessRoot + $sep, [StringComparison]::OrdinalIgnoreCase)) {
                $errors += "business files must not be pushed: $f (business\ never goes into the public repo)"
                continue
            }
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $resolved += (Resolve-Path -LiteralPath $full).Path
            } else {
                $missing += $full
            }
        }
        if ($resolved.Count -eq 0 -and $missing.Count -eq 0) {
            $errors += 'the file list to push is empty (-Files)'
        }
    }

    # 2) Denylist: explicit paths win; otherwise the default denylist plus the local override beside it
    $lists = @()
    if ($DenylistFile -and @($DenylistFile).Count -gt 0) {
        foreach ($dl in @($DenylistFile)) {
            if ([string]::IsNullOrWhiteSpace($dl)) { continue }
            $lists += if ([IO.Path]::IsPathRooted($dl)) { $dl } else { Join-Path $root $dl }
        }
    } else {
        $lists += (Join-Path $root 'tools\publish\public-safe.denylist.json')
        $local = Join-Path $root 'tools\publish\public-safe.denylist.local.json'
        if (Test-Path -LiteralPath $local) { $lists += $local }
    }

    $imported = Import-GateDenylist $lists
    $errors += @($imported.Errors)
    $allowedDomains = @($imported.AllowDomains)
    if (@($imported.Rules).Count -eq 0) {
        # A gate with no rules lets everything through silently, which is more dangerous than failing outright
        $errors += 'the denylist enables no rules; the gate would be a no-op'
    }

    # 3) Match file by file, line by line
    $hits = @()
    $scanned = @()
    $binaryFiles = @()
    $decodedKinds = @()
    foreach ($file in $resolved) {
        $decoded = Read-GateText $file
        $decodedKinds += [pscustomobject]@{ File = $file; Kind = $decoded.Kind }
        if ($decoded.Kind -eq 'binary') { $binaryFiles += $file }
        $lines = @($decoded.Text -split "`r?`n")
        for ($n = 0; $n -lt $lines.Count; $n++) {
            $line = $lines[$n]
            if ([string]::IsNullOrEmpty($line)) { continue }
            foreach ($rule in @($imported.Rules)) {
                $m = $rule.Regex.Match($line)
                if ($m.Success) {
                    # A reserved domain (example / tool domain) is not a violation; a real domain is still reported
                    if (Test-AllowedDomain -Text $m.Value -Domains $allowedDomains) { continue }
                    $hits += [pscustomobject]@{
                        File     = $file
                        Line     = $n + 1
                        Match    = $m.Value
                        RuleId   = $rule.Id
                        Category = $rule.Category
                        Reason   = $rule.Reason
                    }
                }
            }
        }
        $scanned += $file
    }

    # 4) Exit codes: the gate failing itself comes first (it means the scan was incomplete), content hits come second
    $exitCode = 0
    if (@($errors).Count -gt 0 -or @($missing).Count -gt 0) {
        $exitCode = 2
    } elseif (@($hits).Count -gt 0) {
        $exitCode = 1
    }

    return [ordered]@{
        ExitCode = $exitCode
        Hits     = @($hits)
        Scanned  = @($scanned)
        Decoded  = @($decodedKinds)
        Binary   = @($binaryFiles)
        Missing  = @($missing)
        Rules    = @($imported.Rules)
        Sources  = @($imported.Sources)
        AllowDomains = @($allowedDomains)
        Errors   = @($errors)
    }
}

if (-not $NoMain) {
    $exitCode = 2
    try {
        $result = Invoke-PublicSafeScan -Files $Files -DenylistFile $DenylistFile -RepoRoot $RepoRoot

        # Hit lines use a fixed format, which makes them easy to locate by eye and to parse in a pipeline
        foreach ($hit in @($result.Hits)) {
            Write-Output ("{0}:{1}:{2}" -f $hit.File, $hit.Line, $hit.Match)
            Write-Verbose ("    rule {0} ({1}): {2}" -f $hit.RuleId, $hit.Category, $hit.Reason)
        }

        if (-not $Quiet) {
            foreach ($d in @($result.Decoded)) { Write-Verbose ("encoding {0}: {1}" -f $d.Kind, $d.File) }
            foreach ($b in @($result.Binary)) { Write-Verbose "binary file (ASCII rules only): $b" }
            foreach ($e in @($result.Errors)) { Write-Host "[publish-gate] error: $e" }
            foreach ($m in @($result.Missing)) { Write-Host "[publish-gate] missing file: $m" }
            Write-Host ("[publish-gate] denylist {0} ({1} rules), scanned {2} files (binary {3}), {4} hit(s)" -f `
                    (@($result.Sources) -join ' + '), @($result.Rules).Count, @($result.Scanned).Count, `
                    @($result.Binary).Count, @($result.Hits).Count)
        }

        $exitCode = [int]$result.ExitCode
    } catch {
        if (-not $Quiet) { Write-Host "[publish-gate] the gate failed to run: $($_.Exception.Message)" }
        $exitCode = 2
    }
    exit $exitCode
}
