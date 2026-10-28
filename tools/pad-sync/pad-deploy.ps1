# pad-deploy.ps1 — 生产部署（变量替换 → 注入 → 用户确认）
#
# 流程：读 .robin + config.json → 替换变量 → 安全检查 → 用户确认弹窗 → 注入生产流程 → 运行验证
#
# 硬约束：默认只能操作 PAD_SYNC_TEST；生产流程必须显式 -AllowProd
# 安全检查：残留 {{VAR}} 占位符 → 硬阻断；疑似硬编码邮箱/密码 → 软警告

[CmdletBinding()]
param(
    # -ValidateOnly / -Configure 模式下可以不传 SourceRobin
    [string]$SourceRobin,
    [string]$ConfigFile,
    [string]$FlowName,
    # config 的 schema：默认取 ConfigFile 同目录的 <同名>.schema.json
    [string]$SchemaFile,
    # 生产流最坏要轮询 60 分钟 + 处理余量，默认 4200 秒
    [int]$RunTimeoutSec = 4200,
    [switch]$AllowProd,
    [switch]$DryRun,
    # 运行后按验收判据检查产物（转发给 pad-sync）
    [string]$AcceptanceFile,
    # 只发布不运行：发布后只校验哈希，不做运行状态/验收
    [switch]$PublishOnly,
    # 只校验 config 是否符合 schema，不触碰 .robin：通过 exit 0，失败 exit 1
    [switch]$ValidateOnly,
    # 跳过生产确认弹窗（由上层编排脚本统一弹过一次确认后使用）
    [switch]$SkipConfirm,
    # 部署向导：转交给 pad-configure.ps1（前置探查 + 生成 config），不注入流程
    [switch]$Configure,
    [string]$PadRoot,
    [string]$PythonExe,
    [string]$AnswersFile,
    [string]$RequirementsFile,
    [switch]$ProbeOnly
)
$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 向导模式：本脚本其余参数都不需要，直接转交并返回它的退出码
if ($Configure) {
    $cfgArgs = @{}
    if ($PadRoot) { $cfgArgs.PadRoot = $PadRoot }
    if ($ConfigFile) { $cfgArgs.ConfigPath = $ConfigFile }
    if ($PythonExe) { $cfgArgs.PythonExe = $PythonExe }
    if ($SchemaFile) { $cfgArgs.SchemaFile = $SchemaFile }
    if ($AnswersFile) { $cfgArgs.AnswersFile = $AnswersFile }
    if ($RequirementsFile) { $cfgArgs.RequirementsFile = $RequirementsFile }
    if ($ProbeOnly) { $cfgArgs.ProbeOnly = $true }
    & (Join-Path $here 'pad-configure.ps1') @cfgArgs
    exit $LASTEXITCODE
}

if (-not $FlowName) { Write-Error "缺少 -FlowName" }
if (-not $ConfigFile) { Write-Error "缺少 -ConfigFile" }

# ValidateOnly 没有任何副作用，不需要生产熔断
if (-not $ValidateOnly -and $FlowName -ne "PAD_SYNC_TEST" -and -not $AllowProd) {
    Write-Error "安全熔断：默认只能操作 PAD_SYNC_TEST。生产部署必须显式 -AllowProd。"
}
if (-not $ValidateOnly) {
    if (-not $SourceRobin) { Write-Error "缺少 -SourceRobin（只有 -ValidateOnly 模式可以不传）" }
    if (-not (Test-Path $SourceRobin)) { Write-Error "找不到 .robin：$SourceRobin" }
}
if (-not (Test-Path $ConfigFile)) { Write-Error "找不到 config.json：$ConfigFile" }
if (-not $SchemaFile) {
    $SchemaFile = [IO.Path]::ChangeExtension($ConfigFile, ".schema.json")
    # 兼容 example 这类双后缀文件名： sample.example.json 退化为 sample.schema.json
    if (-not (Test-Path $SchemaFile)) {
        $stem = [IO.Path]::GetFileNameWithoutExtension([IO.Path]::GetFileNameWithoutExtension($ConfigFile))
        $alt = Join-Path ([IO.Path]::GetDirectoryName($ConfigFile)) ($stem + ".schema.json")
        if (Test-Path $alt) { $SchemaFile = $alt }
    }
}
if (-not (Test-Path $SchemaFile)) { Write-Error "找不到 schema：$SchemaFile" }

$padSync = Join-Path $here "pad-sync.ps1"
$confirm = Join-Path $here "confirm-deploy.ps1"
if (-not (Test-Path $padSync)) { Write-Error "找不到 pad-sync.ps1" }

$result = [ordered]@{
    ok = $false; flow = $FlowName; dryRun = [bool]$DryRun; validateOnly = [bool]$ValidateOnly
    sourceRobin = $SourceRobin; configFile = $ConfigFile; schemaFile = $SchemaFile
    deployedRobinPath = $null; replacedCount = 0
    warnings = @(); errors = @(); diffPath = $null
    runResult = $null
}
function Log([string]$m) { Write-Host "[deploy] $m" }

# 按 schema 校验 config，返回问题清单（每条都点名到字段），空数组 = 通过
# 支持的 schema 子集：required / additionalProperties:false / properties.{type,pattern,minLength,enum,description}
function Test-Config([hashtable]$Cfg, $Schema) {
    $problems = @()
    # 1) 必填字段缺失
    if ($Schema.required) {
        foreach ($req in @($Schema.required)) {
            if (-not $Cfg.ContainsKey([string]$req)) { $problems += "缺少必填字段：$req" }
        }
    }
    # 2) schema 未定义的字段（防止键名打错导致占位符残留到部署产物里）
    if ($Schema.additionalProperties -eq $false) {
        foreach ($k in $Cfg.Keys) {
            if (-not $Schema.properties.PSObject.Properties[$k]) { $problems += "未知字段：$k（schema 里没有定义）" }
        }
    }
    # 3) 逐字段类型与格式
    foreach ($prop in $Schema.properties.PSObject.Properties) {
        $name = $prop.Name; $rule = $prop.Value
        if (-not $Cfg.ContainsKey($name)) { continue }
        $v = $Cfg[$name]
        if ($null -eq $v) { $problems += "${name}: 值不能为 null"; continue }
        if ($rule.type -eq 'string' -and -not ($v -is [string])) {
            $problems += "${name}: 类型应为 string，实际是 $($v.GetType().Name)"; continue
        }
        if ($rule.minLength -and ([string]$v).Length -lt [int]$rule.minLength) {
            $problems += "${name}: 值不能为空（$($rule.description)）"
        }
        if ($rule.enum) {
            $allowed = @($rule.enum | ForEach-Object { [string]$_ })
            if ($allowed -notcontains [string]$v) {
                $problems += "${name}: 值「$v」不在允许范围（$($allowed -join '/')）"
            }
        }
        if ($rule.pattern -and [string]$v -notmatch [string]$rule.pattern) {
            $problems += "${name}: 值「$v」格式不对（$($rule.description)）"
        }
    }
    return $problems
}

try {
    # ═══ 0. 读 config + schema 并校验 ═══
    $cfgRaw = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8)
        # PS 5.1 不支持 -AsHashtable，手动从 PSCustomObject 转 Hashtable
    $cfgObj = $cfgRaw | ConvertFrom-Json
    $cfg = @{}
    $cfgObj.PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
    if (-not $cfg) { throw "config.json 解析失败或为空" }

    $schema = [IO.File]::ReadAllText($SchemaFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $problems = @(Test-Config $cfg $schema)

    # 只校验模式：逐个点名后按结果退出，不写任何文件
    if ($ValidateOnly) {
        if ($problems.Count -eq 0) {
            Log "配置校验通过：$ConfigFile"
            $result.ok = $true
            exit 0
        }
        foreach ($p in $problems) { $result.errors += $p; Log "✗ $p" }
        Log "配置校验失败：共 $($problems.Count) 处问题"
        exit 1
    }
    # 正式部署前同样先校验，有问题逐个点名并阻断
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { $result.errors += $p; Log "✗ $p" }
        throw "配置校验失败（$($problems.Count) 处），请先修正 $ConfigFile"
    }
    Log "配置校验通过（schema：$([IO.Path]::GetFileName($SchemaFile))）"

    # ═══ 1. 读入 + 变量替换 ═══
    $raw = [IO.File]::ReadAllText($SourceRobin, [Text.Encoding]::UTF8)

    $replaced = $raw; $count = 0
    foreach ($key in $cfg.Keys) {
        # 花括号在正则里只单独一个时有特殊含义，连续两个直接写即可
        $pattern = "{{" + [regex]::Escape($key) + "}}"
        $before = ([regex]::Matches($replaced, $pattern)).Count
        if ($before -gt 0) {
                        # 直接使用 config.json 里的实际值（路径必须原样写入，不能截断成文件名）
            $val = [string]$cfg[$key]
            # schema 里标了 x-robin-escape 的字段（Windows 路径）：config 写单反斜杠，
            # 落到 .robin 字面量里要写成双反斜杠转义形式
            $rule = $schema.properties.PSObject.Properties[$key]
            if ($rule -and $rule.Value.'x-robin-escape' -eq $true) { $val = $val.Replace('\', '\\') }
            $replaced = [regex]::Replace($replaced, $pattern, $val)
            $after = ([regex]::Matches($replaced, $pattern)).Count
            $done = $before - $after; $count += $done
            Log "替换 {{$key}} × $done 处"
        }
    }
    $result.replacedCount = $count
    Log "共替换 $count 处变量"

    # ═══ 2. 安全检查 ═══
    # 残留占位符 → 硬阻断
    $leftover = [regex]::Matches($replaced, "{{[^}]+}}")
    if ($leftover.Count -gt 0) {
        foreach ($m in $leftover) { $result.errors += "残留占位符：$($m.Value)" }
        throw "安全检查失败：$($leftover.Count) 个 {{VAR}} 未替换，请在 config.json 补充"
    }
    Log "安全检查通过：无残留占位符"

    # 硬编码邮箱/密码模式 → 软警告（不阻断）
    $warns = @()
    if ($replaced -match "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}") { $warns += "疑似硬编码邮箱地址" }
    # DRY_RUN=1 会跳过 MIGO/MB51/核对/发信；部署到生产时必须显式提示，避免误把生产关掉
    if ($FlowName -ne "PAD_SYNC_TEST" -and $cfg.ContainsKey('DRY_RUN') -and [string]$cfg['DRY_RUN'] -eq '1') {
        $warns += "DRY_RUN=1：本次部署会跳过 MIGO/MB51/核对与发信"
    }
    foreach ($w in $warns) { $result.warnings += $w; Log "⚠️ $w" }

    # 写替换后 .robin
    $deployedPath = [IO.Path]::ChangeExtension($SourceRobin, ".deployed.robin")
    [IO.File]::WriteAllText($deployedPath, $replaced, (New-Object Text.UTF8Encoding($true)))
    $result.deployedRobinPath = $deployedPath
    Log "替换后 .robin → $deployedPath"

    # 写 diff 信息
    $origLines = ($raw -split "`r?`n").Where({ $_.Trim() -ne "" -and $_.Trim() -notmatch "^#" })
    $newLines  = ($replaced -split "`r?`n").Where({ $_.Trim() -ne "" -and $_.Trim() -notmatch "^#" })
    $diffInfo = [ordered]@{ origActionCount = $origLines.Count; newActionCount = $newLines.Count; replacedCount = $count; warnings = $warns }
    $diffPath = Join-Path ([IO.Path]::GetDirectoryName($deployedPath)) "deploy_diff.json"
    $result.diffPath = $diffPath; $diffInfo | ConvertTo-Json -Depth 3 | Out-File $diffPath -Encoding UTF8

    if ($DryRun) { Log "[DryRun] 跳过注入"; $result.ok = $true; return }

    # ═══ 3. 用户确认弹窗（只有生产流程才弹；-SkipConfirm 时由上层脚本统一确认过） ═══
    if ($AllowProd -and $FlowName -ne "PAD_SYNC_TEST" -and -not $SkipConfirm) {
        $warnText = if ($warns.Count -gt 0) { "`n⚠️ $($warns -join "; ")" } else { "" }
        $msg = "目标流程：$FlowName`n替换变量：$count 处`n动作行数：$($origLines.Count) → $($newLines.Count)`n$warnText`n`n确定上线？"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $confirm -Title "生产部署确认" -Msg $msg
        if ($LASTEXITCODE -ne 0) { throw "用户取消上线" }
        Log "用户已确认上线到 $FlowName"
    }

    # ═══ 4. 注入 + 运行验证 ═══
    Log "——— 注入 $FlowName ———"
    $tmpOut = Join-Path $env:TEMP "pad-deploy-sync.log"
    # pad-sync 自己也有生产熔断，必须把 AllowProd 转发下去，否则生产流程会被拦在注入前
    $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $padSync,
        '-FlowName', $FlowName, '-RobinFile', $deployedPath, '-Replace',
        '-RunTimeoutSec', $RunTimeoutSec)
    if ($AllowProd) { $syncArgs += '-AllowProd' }
    # 只发布模式：注入 → 发布 → 停，不触发 URL 运行
    if ($PublishOnly) { $syncArgs += '-PublishOnly' }
    if ($AcceptanceFile) {
        if (-not (Test-Path $AcceptanceFile)) { Write-Error "找不到验收判据文件：$AcceptanceFile" }
        $syncArgs += @('-AcceptanceFile', $AcceptanceFile, '-ConfigFile', $ConfigFile)
    }
    & powershell @syncArgs > $tmpOut 2>&1
    $lastLine = Get-Content $tmpOut -Tail 1
    if ($lastLine -match "^PAD_SYNC_RESULT=(.+)$") {
        $res = $Matches[1] | ConvertFrom-Json; $result.runResult = $res
        if ($res.ok) { Log "✅ 验证通过：$($res.status)"; $result.ok = $true }
        else {
            Log "❌ 验证失败：$($res.status)"
            # 失败原因可能是动作级错误码，也可能是 stage 级异常消息，两者都要带出来
            $reason = if ($res.error -and $res.error.code) { $res.error.code }
                      elseif ($res.error -and $res.error.message) { $res.error.message }
                      else { [string]$res.status }
            $result.errors += "运行失败：$reason"
        }
    } else { throw "pad-sync 无 PAD_SYNC_RESULT" }
}
catch {
    $result.errors += $_.Exception.Message; Log "部署失败：$($_.Exception.Message)"
}
finally { Write-Output ("PAD_DEPLOY_RESULT=" + ($result | ConvertTo-Json -Depth 10 -Compress)) }
