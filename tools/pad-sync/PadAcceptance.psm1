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

    if (-not (Test-Path -LiteralPath $Path)) { throw "config file not found: $Path" }
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
                # 读现成的 VBS 日志：按 firstLine / lastLine 取一行，先看 skip，再看 fail，最后看 pass
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
