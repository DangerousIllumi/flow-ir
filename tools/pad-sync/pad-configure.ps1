# pad-configure.ps1 — 部署向导：前置探查 → 逐项填写 config → schema 校验 → 写盘
#
# 用法：
#   # 只体检，不生成配置（全部 OK 退出 0，有缺失退出 1）
#   .\pad-configure.ps1 -ProbeOnly
#
#   # 交互式向导（缺前置项会先中止，并给出修复建议）
#   .\pad-configure.ps1
#
#   # 无人值守：用答案文件生成配置（CI/批量部署）
#   .\pad-configure.ps1 -AnswersFile .\answers.json -SkipProbe -Force
#
# 退出码：0 成功 / 1 前置缺失 / 2 schema 校验失败 / 3 用户取消
#
# -NoMain 仅给测试用：dot-source 后只拿函数，不执行向导主流程。

[CmdletBinding()]
param(
    # 为空时按「config 里的 PAD_ROOT → 项目内 pad 目录 → C:\PAD」顺序自动解析
    [string]$PadRoot,
    [string]$PythonExe,
    [string]$ConfigPath,
    [string]$SchemaFile,
    # 工作流需求声明（决定探查哪些项）；默认取 flows\sample.requirements.json
    [string]$RequirementsFile,
    # 非交互答案文件（JSON，键名与 config 相同）；给了就不再逐项提问
    [string]$AnswersFile,
    [switch]$ProbeOnly,
    # 跳过前置探查（离线生成配置时用）
    [switch]$SkipProbe,
    # config 已存在时直接覆盖
    [switch]$Force,
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $repoRoot 'config\sample.json'
}
if (-not $SchemaFile) {
    # 与 pad-deploy 一致的派生规则：同目录下 <stem>.schema.json
    $stem = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ConfigPath))
    $SchemaFile = Join-Path ([IO.Path]::GetDirectoryName($ConfigPath)) ($stem + '.schema.json')
}
$ExamplePath = Join-Path $repoRoot 'config\sample.example.json'

Import-Module (Join-Path $here 'PadPreflight.psm1') -Force

function Write-ProbeTable($checks) {
    Write-Host ''
    Write-Host '[configure] 前置探查'
    foreach ($c in $checks) {
        $flag = if ($c.Ok) { 'OK  ' } else { '缺失' }
        Write-Host ("  [{0}] {1}：{2}" -f $flag, $c.Name, $c.Detail)
        if (-not $c.Ok -and $c.Hint) { Write-Host ("         → " + $c.Hint) }
    }
    Write-Host ''
}

# 以 example 为默认值，叠加探查到的实际路径与用户答案（答案优先级最高）
function New-ConfiguredConfig {
    param(
        [Parameter(Mandatory = $true)]$Defaults,
        [hashtable]$Answers = @{},
        [hashtable]$Discovered = @{}
    )
    $cfg = [ordered]@{}
    foreach ($p in $Defaults.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    foreach ($k in $Discovered.Keys) {
        if ($Discovered[$k]) { $cfg[$k] = $Discovered[$k] }
    }
    foreach ($k in $Answers.Keys) {
        if ($null -ne $Answers[$k] -and [string]$Answers[$k] -ne '') { $cfg[$k] = [string]$Answers[$k] }
    }
    return $cfg
}

function Save-ConfigFile {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = $Config | ConvertTo-Json -Depth 5
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

# 复用 pad-deploy 的 schema 校验（避免两套规则不一致）
function Invoke-ConfigValidation {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigFile,
        [Parameter(Mandatory = $true)][string]$SchemaFile
    )
    $deploy = Join-Path $here 'pad-deploy.ps1'
    # FlowName 在 pad-deploy 里是必填参数；校验模式不碰流程，传占位值即可
    & $deploy -ValidateOnly -FlowName 'PAD_SYNC_TEST' -ConfigFile $ConfigFile -SchemaFile $SchemaFile | Out-Host
    return $LASTEXITCODE
}

function Invoke-ConfigureMain {
    param(
        [string]$PadRoot, [string]$PythonExe, [string]$ConfigPath, [string]$SchemaFile,
        [string]$RequirementsFile, [string]$AnswersFile,
        [switch]$ProbeOnly, [switch]$SkipProbe, [switch]$Force
    )

    # PAD 根目录不写死 C 盘：优先用已有 config 的值，其次项目内 pad 目录，最后才回退 C:\PAD
    if (-not $PadRoot) {
        if (Test-Path $ConfigPath) {
            $existing = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($existing.PAD_ROOT) { $PadRoot = [string]$existing.PAD_ROOT }
        }
        if (-not $PadRoot -and (Test-Path (Join-Path $repoRoot 'pad'))) {
            $PadRoot = Join-Path $repoRoot 'pad'
        }
        if (-not $PadRoot) { $PadRoot = 'C:\PAD' }
        Write-Host "[configure] PAD 根目录解析为：$PadRoot"
    }

    if (-not $PythonExe) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $PythonExe = $cmd.Source }
    }
    if (-not (Test-Path $ExamplePath)) { throw "找不到示例配置：$ExamplePath" }
    if (-not (Test-Path $SchemaFile)) { throw "找不到 schema：$SchemaFile" }

    $checks = @()
    if ($SkipProbe -and -not $ProbeOnly) {
        Write-Host '[configure] 已跳过前置探查（-SkipProbe），直接生成配置'
    } else {
        if (-not $RequirementsFile) {
            $RequirementsFile = Join-Path $repoRoot 'flows\sample.requirements.json'
        }
        if (-not (Test-Path $RequirementsFile)) { throw "找不到需求声明：$RequirementsFile" }
        $req = [IO.File]::ReadAllText($RequirementsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $vars = @{ PAD_ROOT = $PadRoot; PYTHON_EXE = $PythonExe }
        $checks = Invoke-PreflightChecks -Requirements $req -Variables $vars
        Write-ProbeTable $checks
    }

    $missing = @($checks | Where-Object { -not $_.Ok })
    if ($ProbeOnly) {
        if ($missing.Count -eq 0) { Write-Host '[configure] 前置检查全部通过'; return 0 }
        Write-Host "[configure] 有 $($missing.Count) 项缺失，按上面的建议修复后重跑"
        return 1
    }
    if ($missing.Count -gt 0 -and -not $SkipProbe) {
        Write-Host '[configure] 前置缺失，已中止生成配置（确认可离线填写时加 -SkipProbe）'
        return 1
    }

    $defaults = [IO.File]::ReadAllText($ExamplePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $answers = @{}
    if ($AnswersFile) {
        if (-not (Test-Path $AnswersFile)) { throw "找不到答案文件：$AnswersFile" }
        $obj = [IO.File]::ReadAllText($AnswersFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $obj.PSObject.Properties | ForEach-Object { $answers[$_.Name] = $_.Value }
    } elseif (-not $ProbeOnly) {
        # 交互模式：逐项给出默认值，回车即采用默认
        Write-Host '[configure] 逐项确认配置（直接回车 = 采用方括号内的默认值）'
        foreach ($p in $defaults.PSObject.Properties) {
            $def = [string]$p.Value
            if ($p.Name -eq 'PAD_ROOT' -and $PadRoot) { $def = $PadRoot }
            if ($p.Name -eq 'PYTHON_EXE' -and $PythonExe) { $def = $PythonExe }
            $ans = Read-Host ("  {0} [{1}]" -f $p.Name, $def)
            if ($ans) { $answers[$p.Name] = $ans }
        }
    }

    $discovered = @{}
    if ($PadRoot) { $discovered['PAD_ROOT'] = $PadRoot }
    if ($PythonExe) { $discovered['PYTHON_EXE'] = $PythonExe }
    $cfg = New-ConfiguredConfig -Defaults $defaults -Answers $answers -Discovered $discovered

    if ((Test-Path $ConfigPath) -and -not $Force) {
        $ok = Read-Host "  $ConfigPath 已存在，覆盖吗？(y/N)"
        if ($ok -notmatch '^(?i)y') { Write-Host '[configure] 已取消'; return 3 }
    }

    $tmp = Join-Path $env:TEMP ('cfg_' + [guid]::NewGuid().ToString('N') + '.json')
    Save-ConfigFile -Config $cfg -Path $tmp
    $code = Invoke-ConfigValidation -ConfigFile $tmp -SchemaFile $SchemaFile
    if ($code -ne 0) {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Write-Host '[configure] 配置未通过校验，未写入；请按上面的字段问题修正后重跑'
        return 2
    }
    Copy-Item $tmp $ConfigPath -Force
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "[configure] 配置已写入：$ConfigPath"
    Write-Host '[configure] 下一步：.\pad-deploy.ps1 -DryRun 预览替换结果'
    return 0
}

if (-not $NoMain) {
    exit (Invoke-ConfigureMain -PadRoot $PadRoot -PythonExe $PythonExe -ConfigPath $ConfigPath `
        -SchemaFile $SchemaFile -RequirementsFile $RequirementsFile -AnswersFile $AnswersFile `
        -ProbeOnly:$ProbeOnly -SkipProbe:$SkipProbe -Force:$Force)
}
