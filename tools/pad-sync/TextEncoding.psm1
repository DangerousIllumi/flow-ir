# TextEncoding.psm1 — detect text-file encodings and write them back safely
#
# Three kinds of encoding sources coexist in this project:
#   1) logs written by VBS via OpenTextFile(..., True) → UTF-16LE (with BOM)
#   2) files saved by Notepad / legacy tools / Excel → ANSI (code page 936 on Chinese Windows)
#   3) in-repo scripts and PAD artifacts → UTF-8 (mostly with BOM)
# Reading ANSI as UTF-8 produces mojibake, and reading UTF-16 as ANSI yields a stream of NUL characters,
# so we always "detect first, decode second, and preserve the original encoding on write-back".

# Encoding for the machine's ANSI code page (936/GBK on Chinese Windows)
# Do not use [Text.Encoding]::Default: if the system has "Beta: Use Unicode UTF-8 for worldwide language support" enabled,
# Default becomes UTF-8, which makes GBK files decode as mojibake
function Get-AnsiEncoding {
    $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if (-not $cp) { return [Text.Encoding]::Default }
    try { return [Text.Encoding]::GetEncoding($cp) } catch { return [Text.Encoding]::Default }
}

# Detect the encoding: return kind (utf-8-bom / utf-16le / utf-16be / utf-8 / ansi), whether a BOM is present, and the encoding object used for decoding
function Get-TextEncodingInfo {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    # 1) If a BOM is present, trust the BOM
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [ordered]@{ kind = 'utf-8-bom'; bom = $true; encoding = (New-Object Text.UTF8Encoding($true)) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [ordered]@{ kind = 'utf-16le'; bom = $true; encoding = (New-Object Text.UnicodeEncoding($false, $true)) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [ordered]@{ kind = 'utf-16be'; bom = $true; encoding = (New-Object Text.UnicodeEncoding($true, $true)) }
    }

    # 2) BOM-less UTF-16LE: ASCII text has 0x00 in every other byte, so use that to recognize it
    if ($Bytes.Length -ge 4) {
        $zeros = 0
        for ($i = 1; $i -lt $Bytes.Length; $i += 2) { if ($Bytes[$i] -eq 0) { $zeros++ } }
        if ($zeros -ge [int]([Math]::Floor($Bytes.Length / 2) * 0.6)) {
            return [ordered]@{ kind = 'utf-16le'; bom = $false; encoding = (New-Object Text.UnicodeEncoding($false, $false)) }
        }
    }

    # 3) No BOM: if it decodes strictly as UTF-8 it is UTF-8, otherwise treat it as ANSI
    try {
        $strict = New-Object Text.UTF8Encoding($false, $true)
        [void]$strict.GetString($Bytes)
        return [ordered]@{ kind = 'utf-8'; bom = $false; encoding = $strict }
    } catch {
        return [ordered]@{ kind = 'ansi'; bom = $false; encoding = (Get-AnsiEncoding) }
    }
}

# Read a file with auto-detected encoding: return text / kind / bom
function Read-TextFileAuto {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $info = Get-TextEncodingInfo $bytes
    $offset = 0
    if ($info.kind -eq 'utf-8-bom') { $offset = 3 }
    elseif ($info.bom) { $offset = 2 }
    $text = $info.encoding.GetString($bytes, $offset, $bytes.Length - $offset)
    return [ordered]@{ text = $text; kind = $info.kind; bom = $info.bom }
}

# Write back with the given encoding: Kind and Bom usually come straight from Read-TextFileAuto, so changing content never changes the encoding
function Write-TextFileAs {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Kind = 'utf-8',
        [bool]$Bom = $false
    )
    $enc = switch ($Kind) {
        'utf-16le' { New-Object Text.UnicodeEncoding($false, $Bom) }
        'utf-16be' { New-Object Text.UnicodeEncoding($true, $Bom) }
        'ansi'     { Get-AnsiEncoding }
        default    { New-Object Text.UTF8Encoding($Bom) }
    }
    [IO.File]::WriteAllText($Path, $Text, $enc)
}

Export-ModuleMember -Function Get-AnsiEncoding, Get-TextEncodingInfo, Read-TextFileAuto, Write-TextFileAs
