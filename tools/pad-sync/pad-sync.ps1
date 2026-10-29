<#
pad-sync.ps1 — 把 .robin 注入 PAD 设计器并自动运行、收集执行结果

用途：
  让 agent 生成的 .robin 真正进入 PAD 画布，跑一次并把失败动作（错误码、消息）
  结构化返回，供 agent 自动分析修复。

  设计器交互本身全部在 PadDesigner.psm1，遥测解析在 PadTelemetry.psm1；
  本脚本只负责编排：读文件 → 注入 → 发布（可选）→ 运行 → 收集结果。

用法：
  # 完整闭环：注入 → 发布 → 运行 → 收集（跳过保存草稿，发布按钮直接用当前画布）
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RobinFile "C:\temp\flow.robin"

  # 只运行已发布流程并收集结果
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RunOnly

  # 注入并回读画布，确认粘贴完整
  .\pad-sync.ps1 -FlowName "PAD_SYNC_TEST" -RobinFile "C:\temp\flow.robin" -VerifyCanvas -InjectOnly

参数：
  -FlowName        PAD 流程名（必须已在设计器中打开对应的编辑窗口）
  -RobinFile       .robin 文本文件路径；-RunOnly 时可省略
  -Replace         注入前先清空画布上的现有动作（默认追加）
  -VerifyCanvas    注入后把画布内容复制回来，与源 .robin 规范化逐行比对，
                   只粘进去一部分时中止并报第一处差异
  -LocalRun        测试阶段用：点设计器“运行”按钮直接跑当前画布，不发布到云端
  -NoPublish       等同 -LocalRun（保留旧参数名）
  -InjectOnly      只注入并校验画布，不发布不运行
  -SkipStaticCheck 跳过注入前的 check.js 静态校验（仅紧急排查用）
  -AcceptanceFile  运行后按验收判据检查产物（需同时提供 -ConfigFile）
  -ConfigFile      部署配置，用于替换验收判据里的 {{KEY}} 占位符
  -RunId           自定义运行 ID（便于定位日志目录，默认自动生成）
  -RunTimeoutSec   等待流程结束的最长秒数（默认 300）
  -ManifestPath    编排层历史文件（默认仓库根 manifest.jsonl；不在仓库内时默认不写）
  -NoManifest      本次运行不写 manifest（调试时用）

输出：
  标准输出最后打印一行 PAD_SYNC_RESULT=<JSON>，字段含
  ok / stage / runId / status / actions / failedAction / error / logPath / canvasVerified

前置条件：
  1. PAD 控制台已登录，目标流程已发布（未发布的草稿无法通过 URL 运行）
  2. PAD 设计器已打开该流程的编辑窗口
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowName,
    [string]$RobinFile,
    [string]$RunId,
    [int]$RunTimeoutSec = 300,
    [switch]$Replace,
    [switch]$NoPublish,
    [switch]$RunOnly,
    [switch]$InjectOnly,
    [switch]$LocalRun,
    # 只发布到云端，不触发运行（发布后只校验哈希，不做运行状态/验收）
    [switch]$PublishOnly,
    [switch]$AllowProd,
    [switch]$VerifyCanvas,
    # 注入前强制跑静态校验；-SkipStaticCheck 仅用于紧急排查
    [switch]$SkipStaticCheck,
    # 准入网关：enforce=失败即阻断（默认）/ report=只提示 / off=不跑
    [ValidateSet('report', 'enforce', 'off')][string]$AdmitMode = 'enforce',
    # flow.json；不传时按 -AcceptanceFile 的兄弟文件自动推导
    [string]$FlowFile,
    # 运行后按验收判据检查产物（需同时提供 -ConfigFile）
    [string]$AcceptanceFile,
    [string]$ConfigFile,
    [string]$ManifestPath,
    [switch]$NoManifest
)

$ErrorActionPreference = 'Stop'

# 只发布模式与“不注入/不发布”的选项互斥，避免出现没发布却报 Published
if ($PublishOnly -and ($RunOnly -or $LocalRun -or $InjectOnly -or $NoPublish)) {
    throw '-PublishOnly 不能与 -RunOnly / -LocalRun / -InjectOnly / -NoPublish 同时使用'
}

# 生产流程安全熔断：默认只允许操作 PAD_SYNC_TEST 测试流程
if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
    throw '安全熔断：pad-sync 默认只允许操作 PAD_SYNC_TEST。生产流程请显式加 -AllowProd。'
}

# 设计器交互唯一实现 + 遥测解析
# -DisableNameChecking：模块里有 Focus-/Click- 这类非标准动词，关掉提示避免污染 agent 解析的输出
Import-Module (Join-Path $PSScriptRoot 'PadDesigner.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PadTelemetry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PadAcceptance.psm1') -Force

# 编排层历史文件：脚本位于仓库 tools\pad-sync 时默认写仓库根 manifest.jsonl；
# 被单独部署到 C:\PAD\Scripts 这类位置时不写，避免落到盘根
if (-not $ManifestPath -and -not $NoManifest) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (Test-Path (Join-Path $repoRoot 'tools')) { $ManifestPath = Join-Path $repoRoot 'manifest.jsonl' }
}

$script:Result = [ordered]@{
    ok = $false; stage = 'init'; flow = $FlowName; runId = $null
    status = $null; actions = $null; failedAction = $null; error = $null; logPath = $null
    canvasVerified = $null; warnings = @()
}

function Write-Log([string]$msg) { Write-Host "[pad-sync] $msg" }

# 准入网关（注入前 / 运行前都跑）
#   report  = 只把问题记进 warnings，继续
#   enforce = 有 fail 或 ask 就抛错，阻断注入与运行（默认）
# 定时任务走 -RunOnly，所以必须放在分支之外，否则夜间运行会绕过门禁
function Invoke-AdmitGate([string]$FlowFileArg, [string]$ConfigFileArg, [string]$AcceptanceFileArg) {
    if ($AdmitMode -eq 'off') { return $true }
    $flowPath = $FlowFileArg
    if (-not $flowPath -and $AcceptanceFileArg) {
        $guess = $AcceptanceFileArg -replace '\.acceptance\.json$', '.json'
        if (Test-Path -LiteralPath $guess) { $flowPath = $guess }
    }
    if (-not $flowPath) { return $true }

    $script:Result.stage = 'admit'
    $admitArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $PSScriptRoot 'pad-admit.ps1'), '-FlowFile', $flowPath, '-Unattended')
    if ($ConfigFileArg) { $admitArgs += @('-ConfigFile', $ConfigFileArg) }
    if ($AcceptanceFileArg) { $admitArgs += @('-AcceptanceFile', $AcceptanceFileArg) }
    $admitOut = & powershell @admitArgs *>&1 | Out-String
    $hits = @($admitOut -split "`r?`n" | Where-Object { $_ -match '^PAD_ADMIT_RESULT=' })
    $admit = $null
    if ($hits.Count -gt 0) {
        try { $admit = $hits[$hits.Count - 1].Substring('PAD_ADMIT_RESULT='.Length) | ConvertFrom-Json }
        catch { $admit = $null }
    }
    if (-not $admit) {
        $script:Result.warnings += '准入网关未返回可解析结果'
        return $true
    }

    $fails = @($admit.checks | Where-Object { $_.status -eq 'fail' })
    $asks = @($admit.checks | Where-Object { $_.status -eq 'ask' })
    foreach ($f in $fails) { $script:Result.warnings += "准入 $($f.id) $($f.code)：$($f.message)" }
    foreach ($a in $asks) { $script:Result.warnings += "准入 $($a.id) 待批准：$($a.message)" }
    if ($fails.Count -gt 0 -or $asks.Count -gt 0) {
        $msg = "准入网关：失败 $($fails.Count) / 待批 $($asks.Count)"
        if ($AdmitMode -eq 'enforce') { throw "$msg（enforce 模式，已阻断）" }
        Write-Log "$msg（report 模式，继续）"
        return $true
    }
    Write-Log "准入网关通过（$(@($admit.checks).Count) 项）"
    return $true
}

# ── 收集（设计器本地运行）：读机器人遥测日志 ──────────────────
# 设计器内“运行”不写 Console\Scripts\<flow>\Runs\<runId>\Actions.log，
# 而是在 DataCollection 下新建带时间戳的 RobinRobot.log（JSON Lines）。
# 因此用“触发之后的最新文件”关联本次运行；解析交给 PadTelemetry
function Get-DesignerRunResult([datetime]$since, [string]$LogPath) {
    # 等待阶段已经锁定本次运行的遥测日志时直接用它，
    # 避免“取触发之后最新一份”在同机并发跑别的流时误命中别人那一份
    if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
        return (Get-RobinTelemetryFromFile -Path $LogPath)
    }
    $dc = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'
    $log = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60) {
        $log = Find-RobinTelemetryLog -DataCollectionDir $dc -Since $since
        if ($log) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $log) { return $null }
    return (Get-RobinTelemetryFromFile -Path $log.FullName)
}

# ── 收集：定位 Runs 目录并解析 Actions.log ────────────────────
function Get-PadRunResult([string]$rid, [datetime]$since = [datetime]::MinValue, [string]$RunDir) {
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    # 等待阶段已锁定本次运行目录时直接用它：同机并发跑别的流时，
    # “取触发之后最新的运行目录”会误命中别人那一轮
    $dir = $null
    if ($RunDir -and (Test-Path -LiteralPath $RunDir)) { $dir = Get-Item -LiteralPath $RunDir }
    if (-not $dir) {
        # 先按 runId 精确找；PAD 桌面流程实际用自生成的 GUID 作为目录名（与 URL 里的 runId 不同），
        # 因此退化为"触发之后产生的最新运行目录"
        $dir = Get-ChildItem -LiteralPath $base -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $rid } | Select-Object -First 1
    }
    if (-not $dir) {
        # 本地运行由 PAD 自生成运行目录，可能延迟几秒才落盘，最多等 60 秒
        $swDir = [Diagnostics.Stopwatch]::StartNew()
        while ($swDir.Elapsed.TotalSeconds -lt 60) {
            $dir = Get-ChildItem -LiteralPath $base -Recurse -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -ge $since -and (Test-Path (Join-Path $_.FullName 'Actions.log')) } |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($dir) { break }
            Start-Sleep -Seconds 2
        }
    }
    if (-not $dir) { return $null }

    $logPath = Join-Path $dir.FullName 'Actions.log'
    # 日志可能在流程结束后才落盘，最多等 30 秒
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 30) {
        if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 0) { break }
        Start-Sleep -Milliseconds 700
    }

    $status = $null
    $rdPath = Join-Path $dir.FullName 'RunDefinition.json'
    if (Test-Path $rdPath) {
        # 同样必须按 UTF-8 读，否则中文失败动作名会让 JSON 解析报错
        try {
            $rdText = [IO.File]::ReadAllText($rdPath, [Text.Encoding]::UTF8)
            $status = ($rdText | ConvertFrom-Json).status
        } catch { Write-Log "RunDefinition.json 解析失败：$($_.Exception.Message)" }
    }

    $actions = @()
    $failed = $null
    $summary = $null
    if (Test-Path $logPath) {
        # Actions.log 是 UTF-8；PowerShell 5.1 的 Get-Content 默认按 ANSI 读会乱码并破坏 JSON
        foreach ($line in ([IO.File]::ReadAllLines($logPath, [Text.Encoding]::UTF8))) {
            if (-not $line.Trim()) { continue }
            try { $j = $line | ConvertFrom-Json } catch { continue }
            # 日志最后一行是整次运行的汇总（没有 index），单独保留后跳过
            if ($null -eq $j.index -or -not $j.status) {
                if ($j.workflow -and $j.status) { $summary = $j }
                continue
            }
            $act = [ordered]@{
                index = $j.index; name = $j.name; action = $j.systemActionName
                status = $j.status; functionName = $j.functionName
                inputs = @{}; outputs = @{}
            }
            if ($j.inputs) { foreach ($pr in $j.inputs.PSObject.Properties) { $act.inputs[$pr.Name] = $pr.Value.value } }
            if ($j.outputs) { foreach ($pr in $j.outputs.PSObject.Properties) { $act.outputs[$pr.Name] = $pr.Value.value } }
            if ($j.status -eq 'Failed' -and $j.error) {
                $act.error = [ordered]@{
                    code = $j.error.code
                    message = $j.error.message
                    correlationId = $j.error.correlationId
                }
                if (-not $failed) { $failed = $act }
            }
            $actions += $act
        }
    }
    if (-not $status -and $summary) { $status = $summary.status }
    return [ordered]@{ status = $status; actions = $actions; failed = $failed; logPath = $logPath }
}

# ── 主流程 ────────────────────────────────────────────────────
try {
    if (-not $RunId) { $RunId = [Guid]::NewGuid().ToString() }
    $script:Result.runId = $RunId

    # 准入网关：RunOnly（定时任务）也跑，避免夜间运行绕过门禁
    [void](Invoke-AdmitGate $FlowFile $ConfigFile $AcceptanceFile)

    if (-not $RunOnly) {
        if (-not $RobinFile -or -not (Test-Path $RobinFile)) { throw "找不到 .robin 文件：$RobinFile" }
        $text = [IO.File]::ReadAllText((Resolve-Path $RobinFile), [Text.Encoding]::UTF8)
        if (-not $text.Trim()) { throw '.robin 文件内容为空' }

        # 准入网关已在主流程开头跑过（RunOnly 也覆盖），这里只做静态校验
        # V 模型 G2：静态校验不通过就不进设计器，避免坏脚本污染画布
        if (-not $SkipStaticCheck) {
            $script:Result.stage = 'static-check'
            $checkJs = Join-Path (Split-Path -Parent $PSScriptRoot) 'pad-robin\check.js'
            if (-not (Test-Path $checkJs)) { throw "找不到静态校验器：$checkJs" }
            $checkOut = & node $checkJs (Resolve-Path $RobinFile).Path 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("静态校验未通过（check.js 退出码 $LASTEXITCODE）：" + (($checkOut | Out-String).Trim()))
            }
            Write-Log '静态校验通过（check.js 0 errors）'
        }

        $script:Result.stage = 'find-designer'
        $win = Get-DesignerWindow -FlowName $FlowName
        if (-not $win) { throw "找不到已打开 '$FlowName' 的 PAD 设计器窗口，请先在 PAD 中打开该流程" }

        $script:Result.stage = 'inject'
        $inj = Invoke-PadInject -Window $win -Text $text -Replace:$Replace -VerifyCanvas:$VerifyCanvas
        $afterCount = [int]$inj.actions
        if ($VerifyCanvas) { $script:Result.canvasVerified = [bool]$inj.verified }
        if ($afterCount -le 0) { throw '注入后画布为空，注入失败' }
        Write-Log "注入完成：画布 $afterCount 个动作"

        # 只验证注入、不发布不运行：用于确认画布真的被更新
        if (-not $InjectOnly -and -not $NoPublish -and -not $LocalRun) {
            $script:Result.stage = 'publish'
            $win = Get-DesignerWindow -FlowName $FlowName
            # 正常发布不超过 3 分钟；超过即视为异常（版本冲突或服务故障），不能静默等待
            [void](Click-ToolButton $win 'PublishFlowButton')
            $published = Wait-PublishDone $win 300
            if (-not $published) {
                throw '发布超时：300 秒内未完成。常见原因是该流在别处被修改导致版本冲突，请关闭并重新打开该流后重试。'
            }
            Write-Log '发布完成'
        }
    }

    if ($InjectOnly) {
        Write-Log '已注入，跳过运行（-InjectOnly）'
        $script:Result.ok = $true
        $script:Result.status = 'Injected'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } elseif ($PublishOnly) {
        # 只保存到云端：发布完成后直接结束，不触发 URL 运行
        Write-Log '已发布，跳过运行（-PublishOnly）'
        $script:Result.ok = $true
        $script:Result.status = 'Published'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } else {
        $script:Result.stage = 'run'
        $runStart = (Get-Date).AddSeconds(-5)
        # 等待阶段按“运行日志落盘”锁定本次运行，返回目录/日志路径与终止状态，
        # 不再用“PAD.RobotV2 进程是否还在”判结束（同机并发时会误判）
        $runHint = Invoke-PadRun -WorkflowName $FlowName -RunId $RunId -TimeoutSec $RunTimeoutSec -Local:($LocalRun -or $NoPublish)
        if (-not $runHint -or -not $runHint.evidence) {
            throw '触发后没有出现本次运行的日志（可能被取消或 PAD 未响应），未收集到运行结果'
        }

        $script:Result.stage = 'collect'
        if ($LocalRun -or $NoPublish) {
            # 设计器内运行：读 DataCollection 下的 RobinRobot.log 遥测
            $res = Get-DesignerRunResult $runStart $runHint.logPath
            if (-not $res) { throw '找不到设计器运行的遥测日志（RobinRobot.log）' }
            $script:Result.status = $res.status
            $script:Result.actions = $res.actions
            $script:Result.logPath = $res.logPath
            $script:Result.runId = $res.runId
            $script:Result.failedActions = $res.failedActions
            $script:Result.telemetry = $res.telemetry
            $script:Result.timedActions = $res.timedActions
            $script:Result.totalMs = $res.totalMs
            $script:Result.error = $res.error
            # 内置动作（SET/IF/File 等）失败时没有动作级异常，用 run 级错误码构造一个
            if ($res.status -eq 'Failed' -and -not $script:Result.failedActions) {
                $script:Result.failedAction = [ordered]@{ name = $null; error = $res.error }
            }
            $script:Result.ok = ($res.status -eq 'Succeeded')
        } else {
            $res = Get-PadRunResult $RunId $runStart $runHint.runDir
            if (-not $res -and $runHint.status) {
                # 运行结束后 PAD 会清掉 Actions.log：用等待阶段读到的终止状态兜底
                $res = [ordered]@{ status = $runHint.status; actions = @(); failed = $null; logPath = $runHint.logPath }
            }
            if (-not $res) { throw "找不到本次运行的日志目录（runId=$RunId）" }

            $script:Result.status = $res.status
            $script:Result.actions = $res.actions
            $script:Result.logPath = $res.logPath
            if ($res.failed) {
                $script:Result.failedAction = $res.failed
                $script:Result.error = $res.failed.error
                $script:Result.ok = $false
            } else {
                $script:Result.ok = ($res.status -eq 'Succeeded')
            }
        }

        # V 模型 G6：运行成功不等于业务正确，按判据检查产物
        if ($AcceptanceFile) {
            $script:Result.stage = 'acceptance'
            if (-not $ConfigFile) { throw '使用 -AcceptanceFile 时必须同时提供 -ConfigFile' }
            if (-not (Test-Path $AcceptanceFile)) { throw "找不到验收判据文件：$AcceptanceFile" }
            $configMap = Get-AcceptanceConfig -Path $ConfigFile
            $acc = Test-AcceptanceFile -Path $AcceptanceFile -Config $configMap -Since $runStart
            $script:Result.acceptance = $acc
            Write-Log ("验收：通过 {0} / 失败 {1} / 跳过 {2}" -f $acc.passed, $acc.failed, $acc.skipped)
            if (-not $acc.ok) {
                $script:Result.ok = $false
                if (-not $script:Result.error) {
                    $script:Result.error = [ordered]@{ code = 'ACCEPTANCE_FAILED'; message = "验收未通过：$($acc.failed) 项" }
                }
            }
        }
        $script:Result.stage = 'done'
    }
}
catch {
    $script:Result.ok = $false
    $script:Result.error = [ordered]@{ message = $_.Exception.Message }
    Write-Log "失败于 [$($script:Result.stage)]：$($_.Exception.Message)"
}

# ── 编排层记录：每次运行追加一行 manifest ──────────────────────
# PAD 画布内不写任何日志动作，运行历史统一由编排层落账。
# 放在 PAD_SYNC_RESULT 之前，且失败只提示不中断，保证 agent 始终能读到运行结果。
if (-not $NoManifest -and $ManifestPath) {
    $errCode = $null; $errMsg = $null
    $rawErr = $script:Result.error
    if ($rawErr -is [System.Collections.IDictionary]) {
        if ($rawErr.Contains('code')) { $errCode = $rawErr['code'] }
        if ($rawErr.Contains('message')) { $errMsg = $rawErr['message'] }
    } elseif ($rawErr) {
        $errCode = $rawErr.code; $errMsg = $rawErr.message
    }
    $runMode = 'publish'
    if ($RunOnly) { $runMode = 'run-only' }
    elseif ($InjectOnly) { $runMode = 'inject-only' }
    elseif ($LocalRun -or $NoPublish) { $runMode = 'local' }
    try {
        $entry = New-RunManifestEntry -FlowName $FlowName -RunId $script:Result.runId -Mode $runMode `
            -Ok ([bool]$script:Result.ok) -Stage $script:Result.stage -Status $script:Result.status `
            -Actions $script:Result.actions -TotalMs $script:Result.totalMs `
            -ErrorCode $errCode -ErrorMessage $errMsg `
            -LogPath $script:Result.logPath -CanvasVerified $script:Result.canvasVerified `
            -Acceptance $script:Result.acceptance -Warnings $script:Result.warnings
        Add-ManifestEntry $ManifestPath $entry
        Write-Log "manifest 已追加：$ManifestPath"
        # run 记录只留 90 天；release / rollback 永久保留。清理失败不影响运行结果
        try {
            $dropped = Remove-OldManifestEntries $ManifestPath -KeepDays 90
            if ($dropped -gt 0) { Write-Log "manifest 已清理 $dropped 条 90 天前的运行记录" }
        } catch { Write-Log "manifest 清理失败（不影响运行结果）：$($_.Exception.Message)" }
    } catch {
        Write-Log "manifest 写入失败（不影响运行结果）：$($_.Exception.Message)"
    }
}

# 供 agent 解析的最终结果（最后一行固定前缀）
Write-Output ("PAD_SYNC_RESULT=" + ($script:Result | ConvertTo-Json -Depth 8 -Compress))
