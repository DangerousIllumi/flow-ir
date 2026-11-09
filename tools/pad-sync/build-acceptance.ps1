# build-acceptance.ps1 — 由 flow.json 的 acceptance 声明生成验收判据文件
#
# 为什么要生成：验收判据里的路径（Results / 导出目录 / 日历）本来就是 flow 变量的派生结果。
# 手写两份必然漂移——改了 ResultsDir，验收还在查旧目录，就会「运行成功但验收失败」。
#
# 规则：
#   {{variables.X}}  → 变量 X 的值（deployKey 变量输出 {{KEY}}，其余用 default）
#   %X%              → 同上，两种写法都支持，便于和 .robin 里的写法保持一致
#   递归解析，直到文本不再变化（如 %PadRoot%\Results）
#
# 用法：
#   .\build-acceptance.ps1 -FlowFile business\flows\sample-report.json -OutFile <目标路径>
#   .\build-acceptance.ps1 -FlowFile business\flows\sample-report.json -Check   # 只校验并打印
#
# 退出码：0 成功 / 1 声明有问题

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowFile,
    [string]$OutFile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

# PadAcceptance 认识的判据类型，声明里出现别的直接拒绝，避免生成一个永远跑不了的判据
$KNOWN_TYPES = @('fileExists', 'globNewerThan', 'pair', 'json', 'jsonl', 'logState')

function Resolve-FlowExpr([string]$Text, [hashtable]$Map) {
    $cur = [string]$Text
    for ($i = 0; $i -lt 8; $i++) {
        $before = $cur
        foreach ($k in $Map.Keys) {
            $v = [string]$Map[$k]
            $cur = $cur.Replace("{{variables.$k}}", $v)
            $cur = $cur.Replace("{{$k}}", $v)
            $cur = $cur.Replace("%$k%", $v)
        }
        if ($cur -eq $before) { break }
    }
    return $cur
}

# 递归解析：字符串替换，数组逐个处理，对象逐属性处理
function Resolve-Node($Node, [hashtable]$Map) {
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return Resolve-FlowExpr $Node $Map }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        return @($Node | ForEach-Object { Resolve-Node $_ $Map })
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Node.PSObject.Properties) { $o[$p.Name] = Resolve-Node $p.Value $Map }
        return [pscustomobject]$o
    }
    return $Node
}

try {
    $flow = [IO.File]::ReadAllText($FlowFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
} catch {
    Write-Error "failed to read flow.json: $($_.Exception.Message)"
    exit 1
}

if (-not $flow.acceptance -or -not $flow.acceptance.checks) {
    Write-Error "flow.json has no acceptance.checks; cannot build acceptance criteria"
    exit 1
}

# 变量名 → 值：部署参数用 {{KEY}}，派生路径用 default
$vars = @{}
foreach ($v in @($flow.variables)) {
    $name = [string]$v.name
    if (-not $name) { continue }
    if ($v.deployKey) { $vars[$name] = "{{$($v.deployKey)}}" }
    elseif ($null -ne $v.default) { $vars[$name] = [string]$v.default }
}

$checks = @()
$errs = @()
foreach ($c in @($flow.acceptance.checks)) {
    $resolved = Resolve-Node $c $vars
    $type = [string]$resolved.type
    if (-not $resolved.name) { $errs += "one criterion is missing name" }
    if ($KNOWN_TYPES -notcontains $type) {
        $errs += "criterion '$($resolved.name)' has an unsupported type $type (supported: $($KNOWN_TYPES -join ' / '))"
    }
    foreach ($s in @($resolved.path, $resolved.dir) + @($resolved.paths)) {
        # 只允许剩下 {{PAD_ROOT}} 这类部署占位符（由 config 在验收时替换）
        if ($s -and ($s -match '\{\{variables\.' -or $s -match '%[A-Za-z_]\w*%')) {
            $errs += "criterion '$($resolved.name)' has an unresolved reference: $s"
        }
    }
    $checks += $resolved
}

if ($errs.Count -gt 0) {
    foreach ($e in $errs) { Write-Host "[build-acceptance] error: $e" }
    exit 1
}

$spec = [ordered]@{
    version     = 1
    description = if ($flow.acceptance.description) { [string]$flow.acceptance.description } else { [string]$flow.name }
    checks      = $checks
}
$json = $spec | ConvertTo-Json -Depth 12

if ($Check) {
    Write-Host "[build-acceptance] $($checks.Count) criteria passed validation (no file written)"
    Write-Output $json
    exit 0
}

if (-not $OutFile) {
    Write-Error "-OutFile is missing (or use -Check to validate only)"
    exit 1
}
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "[build-acceptance] generated $OutFile ($($checks.Count) criteria)"
exit 0
