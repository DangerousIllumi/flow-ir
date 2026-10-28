# RobinText.psm1 — .robin 文本规范化、哈希与逐行比对
#
# 这三个函数被两处共用：
#   1) pad-release.ps1：发布后拿「已发布副本」与「注入内容」做哈希/逐行校验
#   2) PadDesigner.psm1：-VerifyCanvas 时拿「画布回读内容」与「源 .robin」逐行校验
# 抽成独立模块是为了避免两处各写一份导致规范化规则漂移。

# robin 规范化：只保留真正的动作行
# PAD 落盘/回读的内容与源文件差异有三类，比对前必须剥掉：
#   1) 元数据行：@@ConnectionString / @@Type / @SENSITIVE 等（以 @ 开头）
#   2) 注释行：以 # 开头，发布时 PAD 会整行丢弃
#   3) 缩进与行尾空白：块结构由 IF/END 关键字决定，缩进只影响可读性
# 以及转义差异：源文件写 \"x\"（单反斜杠转义引号），PAD 落盘时会再转义成 \\"x\\"，
# 这是同一内容的不同表示，比对前把「一个或多个反斜杠 + 引号」统一成单个引号
function ConvertTo-NormalizedRobin([string]$Text) {
    $text2 = $Text -replace '\\+"', '"'
    $lines = $text2 -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -ne '' -and -not $_.StartsWith('#') -and -not $_.StartsWith('@') -and -not $_.StartsWith('IMPORT ')
    }
    return ($lines -join "`n")
}

# 规范化后的 SHA256（小写 hex），作为「画布内容」的指纹
function Get-RobinHash([string]$Text) {
    $norm = ConvertTo-NormalizedRobin $Text
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($norm)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

# 逐行比对两段 robin（规范化后），返回是否一致与首个差异位置（1 起始的行号）
# lineA 对应第一个参数，lineB 对应第二个参数；一侧行数不足时该侧记为「缺失」
function Compare-RobinText([string]$A, [string]$B) {
    $la = @((ConvertTo-NormalizedRobin $A) -split "`n")
    $lb = @((ConvertTo-NormalizedRobin $B) -split "`n")
    $n = [Math]::Max($la.Count, $lb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = if ($i -lt $la.Count) { $la[$i] } else { '<缺失>' }
        $vb = if ($i -lt $lb.Count) { $lb[$i] } else { '<缺失>' }
        if ($va -ne $vb) {
            return [ordered]@{ match = $false; diffIndex = ($i + 1); lineA = $va; lineB = $vb }
        }
    }
    return [ordered]@{ match = $true; diffIndex = 0; lineA = ''; lineB = '' }
}

Export-ModuleMember -Function ConvertTo-NormalizedRobin, Get-RobinHash, Compare-RobinText
