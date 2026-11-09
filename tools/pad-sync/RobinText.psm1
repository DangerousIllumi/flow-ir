# RobinText.psm1 — .robin text normalization, hashing, and line-by-line comparison
#
# These three functions are shared by two callers:
#   1) pad-release.ps1: after publishing, hash/compare the "published copy" against the "injected content" line by line
#   2) PadDesigner.psm1: with -VerifyCanvas, compare the "canvas read-back content" against the "source .robin" line by line
# They live in a separate module so the two call sites cannot drift apart into two copies of the normalization rules.

# robin normalization: keep only the real action lines
# PAD's written / read-back content differs from the source file in three ways, and all three must be stripped before comparing:
#   1) metadata lines: @@ConnectionString / @@Type / @SENSITIVE and so on (starting with @)
#   2) comment lines: starting with #, which PAD drops entirely on publish
#   3) indentation and trailing whitespace: block structure comes from IF/END keywords, indentation only affects readability
# plus escaping differences: the source writes \"x\" (a single backslash escaping a quote), while PAD re-escapes it to \\"x\\"
# when writing to disk. These are two representations of the same content, so before comparing we collapse
# "one or more backslashes + a quote" into a single quote
function ConvertTo-NormalizedRobin([string]$Text) {
    # Strip the BOM explicitly: PAD occasionally leaves a U+FEFF at the start of the file it writes,
    # and if it is not stripped the first action line gains an invisible character, making identical content compare as two copies
    $text1 = $Text.Replace([string][char]0xFEFF, '')
    $text2 = $text1 -replace '\\+"', '"'
    $lines = $text2 -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -ne '' -and -not $_.StartsWith('#') -and -not $_.StartsWith('@') -and -not $_.StartsWith('IMPORT ') -and
        # Collapsible-region markers are editor aids that PAD may keep or drop when writing to disk; they take no part in the comparison
        -not $_.StartsWith('**REGION') -and -not $_.StartsWith('**ENDREGION')
    }
    return ($lines -join "`n")
}

# SHA256 (lowercase hex) of the normalized text, used as the fingerprint of "canvas content"
function Get-RobinHash([string]$Text) {
    $norm = ConvertTo-NormalizedRobin $Text
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

# Compare two robin texts line by line (after normalization); return whether they match and the first difference position (1-based line number)
# lineA is the first parameter and lineB the second; when one side runs out of lines, that side is reported as "<missing>"
function Compare-RobinText([string]$A, [string]$B) {
    $la = @((ConvertTo-NormalizedRobin $A) -split "`n")
    $lb = @((ConvertTo-NormalizedRobin $B) -split "`n")
    $n = [Math]::Max($la.Count, $lb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = if ($i -lt $la.Count) { $la[$i] } else { '<missing>' }
        $vb = if ($i -lt $lb.Count) { $lb[$i] } else { '<missing>' }
        if ($va -ne $vb) {
            return [ordered]@{ match = $false; diffIndex = ($i + 1); lineA = $va; lineB = $vb }
        }
    }
    return [ordered]@{ match = $true; diffIndex = 0; lineA = ''; lineB = '' }
}

Export-ModuleMember -Function ConvertTo-NormalizedRobin, Get-RobinHash, Compare-RobinText
