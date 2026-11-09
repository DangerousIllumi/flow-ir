# check-public-safe.ps1 — 推送前内容门禁：按内容而不是文件名拦截业务信息
#
# 背景：上一次推送公开库时，白名单内的脚本本身合规，但注释里写了业务名、真实路径，
# 于是泄漏到了公开库。所以本门禁逐行扫描「待推文件清单」的内容，命中词表即整体失败。
#
# 用法：
#   .\check-public-safe.ps1 -Files @('tools\pad-sync\pad-sync.ps1', 'docs\x.md') -Verbose
#   .\check-public-safe.ps1 -Files ... -DenylistFile tools\publish\public-safe.denylist.json
#   .\check-public-safe.ps1 -Files ... -Quiet        # 只输出命中行
#
# 输出：每条命中一行「文件:行号:命中词」（走 Write-Output，可直接管道处理）
# 退出码：0 全部干净 / 1 有命中 / 2 门禁自身出错（清单为空、文件缺失、业务目录被列入、词表缺失或无规则）
#
# 词表：默认 tools\publish\public-safe.denylist.json；若同目录存在
#   tools\publish\public-safe.denylist.local.json 会自动合并。
#   真实业务词只放本地文件，该文件永不推送（见 docs\admission-gate.md 第 9 节）。
#
# 业务目录：business\ 默认绝不入库。任何被列入 -Files 的 business\ 文件直接判错（退出码 2），
#   避免「误把业务文件当候选推上去」这种静默风险。
#
# 编码：复用 pad-sync\TextEncoding.psm1 的探测（UTF-8 / UTF-16 / ANSI）。
#   含 NUL 且不是 UTF-16LE 的文件按二进制处理，用 Latin1 无损解码只扫 ASCII 类规则，
#   避免把二进制当 UTF-8 硬读而产生乱码假阳性。

[CmdletBinding()]
param(
    # 待推文件清单（相对仓库根或绝对路径均可）
    [Parameter(Position = 0)]
    [string[]]$Files,
    # 词表路径，可给多个；不给时用默认词表 + 本地覆盖文件
    [string[]]$DenylistFile,
    # 仓库根；默认取本脚本的上两级目录
    [string]$RepoRoot,
    # 只输出命中行，不打印汇总与提示
    [switch]$Quiet,
    # 仅供 Pester dot-source，不执行主流程
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

# 编码探测与本项目其他工具共用同一套判断，避免各写一份出现口径漂移
$script:EncodingModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'pad-sync\TextEncoding.psm1'
# -Verbose:$false 只压掉模块导入的加载日志，不影响本脚本自己的 -Verbose 输出
Import-Module $script:EncodingModule -Force -Verbose:$false

# 读取待扫描文本：返回 Text（正文）与 Kind（utf-8-bom / utf-16le / ansi / binary / empty）
# 关键点：.vbs 可能是 UTF-16LE 带 BOM，不能按 UTF-8 硬读；二进制不能交给 UTF-8 猜测
function Read-GateText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) {
        return [pscustomobject]@{ Text = ''; Kind = 'empty' }
    }

    # 1) 有 BOM（UTF-8 / UTF-16LE / UTF-16BE）时以 BOM 为准，交给统一探测解码
    $hasBom = $false
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $hasBom = $true }
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) { $hasBom = $true }

    if (-not $hasBom) {
        # 只抽样前 8KB，避免大文件全量遍历
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

        # 2) 无 BOM 的 UTF-16LE：奇数位大量 0x00、偶数位几乎没有
        if ($sample -ge 8 -and ($oddZeros / $half) -gt 0.3 -and ($evenZeros / $half) -lt 0.05) {
            $enc = New-Object Text.UnicodeEncoding($false, $false)
            return [pscustomobject]@{ Text = $enc.GetString($bytes); Kind = 'utf-16le' }
        }

        # 3) 其余含 NUL 的按二进制：Latin1 无损解码，只可能命中 ASCII 类规则
        if ($nulCount -gt 0) {
            $latin1 = [Text.Encoding]::GetEncoding(28591)
            return [pscustomobject]@{ Text = $latin1.GetString($bytes); Kind = 'binary' }
        }
    }

    # 4) 普通文本：交给统一探测（UTF-8 / ANSI / 带 BOM 的 UTF-16）
    $info = Read-TextFileAuto $Path
    return [pscustomobject]@{ Text = $info.text; Kind = $info.kind }
}

# 载入词表：分类键即规则分类，规则字段见 tools\publish\public-safe.denylist.json
# 返回 Rules（已编译正则）、Errors（词表问题）、Sources（实际用到的词表）
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

        # 保留域白名单：命中文里出现这些域名时不算违规；enabled=false 可整体关闭
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
                # enabled 缺省为 true；显式 false 的规则只做格式示例
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
                # 字面量规则自动转义，避免业务词里的正则元字符误伤
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

# 判断命中文本里是否含保留域（按域名边界匹配，避免 example.com.cn 之类被误放行）
function Test-AllowedDomain {
    param([string]$Text, [string[]]$Domains)

    if (-not $Text -or @($Domains).Count -eq 0) { return $false }
    foreach ($d in @($Domains)) {
        $pattern = '(?i)(^|[.@/\\])' + [regex]::Escape($d) + '($|[/?#\s"''])' 
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

# 扫描入口：解析清单、载入词表、逐行匹配，返回统一汇总对象（不打印，便于测试）
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

    # 1) 解析待推清单；相对路径一律按仓库根解释，避免受当前目录影响
    #    业务目录是「绝不入库」区：命中即判错，不静默跳过
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

    # 2) 词表：显式给出的优先；否则默认词表 + 同目录的本地覆盖文件
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
        # 没有规则的门禁会静默放行，比直接失败更危险
        $errors += 'the denylist enables no rules; the gate would be a no-op'
    }

    # 3) 逐文件逐行匹配
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
                    # 保留域（示例/工具域）不算违规；真实域仍然记命中
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

    # 4) 退出码：门禁自身出错优先（说明扫描不完整），其次才是内容命中
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

        # 命中行固定格式，便于人工定位与管道解析
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
