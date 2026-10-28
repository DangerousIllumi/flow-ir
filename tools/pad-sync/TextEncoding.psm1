# TextEncoding.psm1 — 文本文件编码探测与安全写回
#
# 项目里同时存在三类编码来源：
#   1) VBS 用 OpenTextFile(..., True) 写的日志 → UTF-16LE（带 BOM）
#   2) 记事本 / 旧工具 / Excel 保存过的文件 → ANSI（中文 Windows 为代码页 936）
#   3) 仓库内脚本与 PAD 产物 → UTF-8（多数带 BOM）
# 直接按 UTF-8 读 ANSI 会得到乱码，按 ANSI 读 UTF-16 会读到大量 NUL 字符，
# 因此统一「先探测、再解码、写回时保留原编码」。

# 本机 ANSI 代码页对应的编码（中文 Windows 为 936/GBK）
# 不用 [Text.Encoding]::Default：若系统开启了「Beta: 使用 UTF-8 提供全球语言支持」，
# Default 会变成 UTF-8，导致把 GBK 文件读成乱码
function Get-AnsiEncoding {
    $cp = [Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
    if (-not $cp) { return [Text.Encoding]::Default }
    try { return [Text.Encoding]::GetEncoding($cp) } catch { return [Text.Encoding]::Default }
}

# 探测编码：返回 kind（utf-8-bom / utf-16le / utf-16be / utf-8 / ansi）、是否带 BOM、解码用编码对象
function Get-TextEncodingInfo {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    # 1) 有 BOM 时以 BOM 为准
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [ordered]@{ kind = 'utf-8-bom'; bom = $true; encoding = (New-Object Text.UTF8Encoding($true)) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        return [ordered]@{ kind = 'utf-16le'; bom = $true; encoding = (New-Object Text.UnicodeEncoding($false, $true)) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
        return [ordered]@{ kind = 'utf-16be'; bom = $true; encoding = (New-Object Text.UnicodeEncoding($true, $true)) }
    }

    # 2) 无 BOM 的 UTF-16LE：ASCII 文本每隔一个字节就是 0x00，据此识别
    if ($Bytes.Length -ge 4) {
        $zeros = 0
        for ($i = 1; $i -lt $Bytes.Length; $i += 2) { if ($Bytes[$i] -eq 0) { $zeros++ } }
        if ($zeros -ge [int]([Math]::Floor($Bytes.Length / 2) * 0.6)) {
            return [ordered]@{ kind = 'utf-16le'; bom = $false; encoding = (New-Object Text.UnicodeEncoding($false, $false)) }
        }
    }

    # 3) 无 BOM：能严格按 UTF-8 解出来就是 UTF-8，否则视为 ANSI
    try {
        $strict = New-Object Text.UTF8Encoding($false, $true)
        [void]$strict.GetString($Bytes)
        return [ordered]@{ kind = 'utf-8'; bom = $false; encoding = $strict }
    } catch {
        return [ordered]@{ kind = 'ansi'; bom = $false; encoding = (Get-AnsiEncoding) }
    }
}

# 自动识别编码读文件：返回 text / kind / bom
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

# 按指定编码写回：Kind 与 Bom 通常直接取 Read-TextFileAuto 的结果，保证「改了内容不改编码」
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
