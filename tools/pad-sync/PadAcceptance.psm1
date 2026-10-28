# PadAcceptance.psm1 — V 模型验收判据执行器
#
# 作用：运行结束后检查产物与业务后置条件，而不是只看「PAD 没报错」。
# 判据文件（*.acceptance.json）里的路径支持 {{KEY}} 占位符，值来自部署 config。
#
# 支持的检查类型：
#   fileExists    文件存在（可选 minBytes / match 正则）
#   globNewerThan 目录下匹配的文件里至少有一个晚于本次运行开始时间
#   pair          两个文件必须同时存在或同时不存在
#   json          JSON 可解析且包含指定顶层键
#   jsonl         每行都是合法 JSON
#
# 所有检查都支持 optional=true：不满足时记为 skipped，不算失败。

# VBS 日志可能是 UTF-16LE / ANSI / UTF-8，统一用编码探测模块读取
Import-Module (Join-Path $PSScriptRoot 'TextEncoding.psm1') -Force

function Get-AcceptanceConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到 config 文件：$Path" }
    $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [Text.Encoding]::UTF8)
    $text = $text -replace "^\uFEFF", ''
    $obj = $text | ConvertFrom-Json

    $map = @{}
    foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
    return $map
}

# 把 {{KEY}} 替换成 config 里的值；未知占位符原样保留，由具体检查报错
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

    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到验收判据文件：$Path" }
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
                    if ($optional) { $item.skipped = $true; $item.detail = '文件不存在（可选项）' }
                    else { $item.detail = "文件不存在：$p" }
                } else {
                    $file = Get-Item -LiteralPath $p
                    $min = 0
                    if ($null -ne $c.minBytes) { $min = [int]$c.minBytes }
                    if ($file.Length -lt $min) {
                        $item.detail = "文件过小：$($file.Length) < $min 字节"
                    } elseif ($c.match) {
                        $text = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
                        if ($text -match [string]$c.match) { $item.ok = $true; $item.detail = "内容匹配 $($c.match)" }
                        else { $item.detail = "内容不匹配 $($c.match)" }
                    } else {
                        $item.ok = $true
                        $item.detail = "存在（$($file.Length) 字节）"
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
                    $item.detail = "最新文件：$($newest.Name)（$($newest.LastWriteTime.ToString('HH:mm:ss'))）"
                } elseif ($optional) {
                    $item.skipped = $true
                    $item.detail = '本次运行未产生该文件（可选项）'
                } else {
                    $item.detail = "没有晚于 $($Since.ToString('HH:mm:ss')) 的文件：$dir\$($c.pattern)"
                }
            }
            elseif ($c.type -eq 'pair') {
                $paths = @($c.paths | ForEach-Object { Resolve-AcceptancePath ([string]$_) $Config })
                $exists = @($paths | Where-Object { Test-Path -LiteralPath $_ })
                if ($exists.Count -eq $paths.Count) {
                    $item.ok = $true
                    $item.detail = '两个文件同时存在'
                } elseif ($exists.Count -eq 0) {
                    if ($optional) { $item.skipped = $true; $item.detail = '两个文件都不存在（可选项）' }
                    else { $item.detail = '两个文件都不存在' }
                } else {
                    $item.detail = "只存在 $($exists.Count)/$($paths.Count) 个文件"
                }
            }
            elseif ($c.type -eq 'json') {
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = '文件不存在（可选项）' }
                    else { $item.detail = "文件不存在：$p" }
                } else {
                    $obj = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
                    $names = @($obj.PSObject.Properties.Name)
                    $missing = @($c.requiredKeys | Where-Object { $names -notcontains $_ })
                    if ($missing.Count -eq 0) { $item.ok = $true; $item.detail = 'JSON 合法且键齐全' }
                    else { $item.detail = "缺少键：$($missing -join ', ')" }
                }
            }
            elseif ($c.type -eq 'jsonl') {
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = '文件不存在（可选项）' }
                    else { $item.detail = "文件不存在：$p" }
                } else {
                    $badLine = 0
                    $lineNo = 0
                    foreach ($line in [IO.File]::ReadAllLines($p, [Text.Encoding]::UTF8)) {
                        $lineNo++
                        if (-not $line.Trim()) { continue }
                        try { [void]($line | ConvertFrom-Json) } catch { $badLine = $lineNo; break }
                    }
                    if ($badLine -gt 0) { $item.detail = "第 $badLine 行不是合法 JSON" }
                    else { $item.ok = $true; $item.detail = "共 $lineNo 行，全部合法" }
                }
            }
            elseif ($c.type -eq 'logState') {
                # 读现成的 VBS 日志：按 firstLine / lastLine 取一行，先看 skip，再看 fail，最后看 pass
                $p = Resolve-AcceptancePath ([string]$c.path) $Config
                if (-not (Test-Path -LiteralPath $p)) {
                    if ($optional) { $item.skipped = $true; $item.detail = '日志不存在（可选项）' }
                    else { $item.detail = "日志不存在：$p" }
                } else {
                    $text = (Read-TextFileAuto $p).text
                    $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
                    if ($lines.Count -eq 0) {
                        $item.detail = '日志为空'
                    } else {
                        $line = $(if ([string]$c.mode -eq 'lastLine') { $lines[-1] } else { $lines[0] })
                        if ($c.skip -and $line -match [string]$c.skip) {
                            $item.skipped = $true
                            $item.detail = "状态为 $($c.skip)，不适用"
                        } elseif ($c.fail -and $line -match [string]$c.fail) {
                            $item.detail = "命中失败标记：$line"
                        } elseif ($c.pass -and $line -match [string]$c.pass) {
                            $item.ok = $true
                            $item.detail = "命中成功标记：$line"
                        } else {
                            $item.detail = "日志行不匹配预期：$line"
                        }
                    }
                }
            }
            else {
                $item.detail = "未知检查类型：$($c.type)"
            }
        } catch {
            $item.detail = "检查异常：$($_.Exception.Message)"
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
