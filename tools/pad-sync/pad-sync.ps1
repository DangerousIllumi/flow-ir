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
  -ManifestPath    编排层历史文件（默认 business\manifest.jsonl；不在仓库内时默认不写）
  -NoManifest      本次运行不写 manifest（调试时用）

输出：
  标准输出最后打印一行 PAD_SYNC_RESULT=<JSON>，字段含
  ok / stage / runId / status / actions / failedAction / error / logPath / canvasVerified
  / needsHumanConfirm / dialogTitle
  ok 可能是 null：Actions.log 与 Console 都没有本次证据时表示“未知”，不是失败
  退出码：0 成功或未知 / 1 失败 / 3 停在人工确认弹窗 / 4 等锁超时

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
    # 非交互（定时任务）：遇到人工确认弹窗不自动点击，记录 needs-human-confirm 并以退出码 3 收尾
    [switch]$NonInteractive,
    # 注入前强制跑静态校验；-SkipStaticCheck 仅用于紧急排查
    [switch]$SkipStaticCheck,
    # 准入网关：enforce=失败即阻断（默认）/ report=只提示 / off=不跑
    [ValidateSet('report', 'enforce', 'off')][string]$AdmitMode = 'enforce',
    # flow.json；不传时按 -AcceptanceFile 的兄弟文件自动推导
    [string]$FlowFile,
    # 未提供 -FlowFile 时，按 -FlowName 在 business\flows 派生（先 pad_flow_name，再文件名 / name）
    # 默认关闭：机制先做出来并验证，确认后才接到计划任务，避免存量任务行为突变
    [switch]$DeriveFlow,
    # 运行后按验收判据检查产物（需同时提供 -ConfigFile）
    [string]$AcceptanceFile,
    [string]$ConfigFile,
    [string]$ManifestPath,
    [switch]$NoManifest,
    # 等待 PAD 空闲的最长秒数：超时以退出码 4 结束，不硬闯（避免两条定时任务抢同一个 PAD）
    # 默认 90 分钟，按单次持锁最坏时长取：
    #   AI 核对流：等报表邮件最多 60 分钟 + 核对/SAP 约 3 分钟 ≈ 63 分钟
    #   长时间 SAP 下载：最长约 30 分钟 + 后续处理约 10~15 分钟 ≈ 40~45 分钟
    #   取两者较大值 63 分钟，再留 27 分钟余量覆盖 SAP 登录、重启、机器卡顿等抖动
    [int]$LockWaitSec = 5400,
    # 跳过跨进程互斥（只在确认没有其它任务会并发时用）
    [switch]$NoLock,
    # 集中运行时配置：只覆盖未显式给出的 RunTimeoutSec；显式参数优先
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# 只发布模式与“不注入/不发布”的选项互斥，避免出现没发布却报 Published
if ($PublishOnly -and ($RunOnly -or $LocalRun -or $InjectOnly -or $NoPublish)) {
    throw '-PublishOnly cannot be combined with -RunOnly / -LocalRun / -InjectOnly / -NoPublish'
}

# 生产流程安全熔断：默认只允许操作 PAD_SYNC_TEST 测试流程
if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
    throw 'safety fuse: pad-sync only operates on PAD_SYNC_TEST by default. For a production flow, add -AllowProd explicitly.'
}

# 设计器交互唯一实现 + 遥测解析
# -DisableNameChecking：模块里有 Focus-/Click- 这类非标准动词，关掉提示避免污染 agent 解析的输出
Import-Module (Join-Path $PSScriptRoot 'PadDesigner.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PadTelemetry.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PublishHistory.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'PadAcceptance.psm1') -Force
# 失败告警：与 pad-schedule 共用同一份实现（kind 口径与去重规则只有一处）
Import-Module (Join-Path $PSScriptRoot 'PadAlerts.psm1') -Force
# 集中配置：只在显式传 -ConfigPath 时读取；缺项/路径不存在/类型错误一律硬失败
Import-Module (Join-Path $PSScriptRoot 'PadConfig.psm1') -Force
if ($ConfigPath) {
    $runtime = Get-PadRuntimeConfig -ConfigPath $ConfigPath
    if (-not $PSBoundParameters.ContainsKey('RunTimeoutSec')) { $RunTimeoutSec = $runtime.RunTimeoutSec }
}

# 编排层历史文件：脚本位于仓库 tools\pad-sync 时默认写 business\manifest.jsonl；
# 被单独部署到仓库之外的目录时不写，避免落到盘根
if (-not $ManifestPath -and -not $NoManifest) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (Test-Path (Join-Path $repoRoot 'tools')) { $ManifestPath = Join-Path $repoRoot 'business\manifest.jsonl' }
}

$script:Result = [ordered]@{
    ok = $false; stage = 'init'; flow = $FlowName; runId = $null
    status = $null; actions = $null; failedAction = $null; error = $null; logPath = $null
    canvasVerified = $null; warnings = @(); lockWaitSec = 0
    # 非交互运行停在人工确认弹窗时置为 true；ok 保持 $null（未知 ≠ 失败）
    needsHumanConfirm = $false; dialogTitle = $null; evidence = $null
    # 触发类失败：URL 被调用但流程没起来 / 流程名解析不出 flowId；供调度层分级告警
    triggerFailed = $false; triggerReason = $null; runTimeout = $false
}

# ── 跨进程互斥：同一时刻只允许一个流占用 PAD ──────────────────
# 注入 / 发布 / 运行都算占用。实现见 PadLock.psm1：
# 命名 Mutex 负责互斥（进程被强杀时系统自动释放，不存在陈旧锁死等），
# 锁文件只在抢锁成功时写一次（持有流程/PID/开始时间），供等待方打印“谁在占着 PAD”；
# 它不参与互斥判定，也不承担心跳。
Import-Module (Join-Path $PSScriptRoot 'PadLock.psm1') -Force

$script:LockTimedOut = $false

function Write-Log([string]$msg) {
    Write-Host "[pad-sync] $msg"
}

# 准入网关（注入前 / 运行前都跑）
#   report  = 显式声明的“只提示”模式：拒绝时记 warnings 后继续
#   enforce = fail-closed：任何不能证明“通过”的情况都阻断注入与运行（默认）
# 定时任务走 -RunOnly，所以必须放在分支之外，否则夜间运行会绕过门禁
#
# 允许运行的唯一判定依据：pad-admit 输出 PAD_ADMIT_RESULT，且 summary 满足
#   fail=0 且 ask=0 且 pass>0（warn 不阻断）
# 缺脚本 / 非零退出 / 无结果行 / JSON 损坏，一律视为不可放行（不是“没报错就放行”）
# 没有 flow.json 属于“准入未启用”，会显式记 warning，避免被误会成已通过
function Invoke-AdmitGate([string]$FlowFileArg, [string]$ConfigFileArg, [string]$AcceptanceFileArg) {
    if ($AdmitMode -eq 'off') {
        Write-Log 'admit gate explicitly disabled (-AdmitMode off); nothing was checked'
        return $true
    }
    $flowPath = $FlowFileArg
    if (-not $flowPath -and $AcceptanceFileArg) {
        $guess = $AcceptanceFileArg -replace '\.acceptance\.json$', '.json'
        if (Test-Path -LiteralPath $guess) { $flowPath = $guess }
    }
    if (-not $flowPath -and -not $DeriveFlow) {
        Write-Log 'no flow.json provided; the admit gate did not apply (nothing was checked)'
        $script:Result.warnings += '准入网关未适用：缺少 flow.json'
        return $true
    }

    $script:Result.stage = 'admit'
    $admitScript = Join-Path $PSScriptRoot 'pad-admit.ps1'
    if (-not (Test-Path -LiteralPath $admitScript)) {
        throw 'admit gate refused to run: the admit script is missing (pad-admit.ps1)'
    }
    $admitArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        $admitScript, '-Unattended')
    if ($ConfigFileArg) { $admitArgs += @('-ConfigFile', $ConfigFileArg) }
    if ($AcceptanceFileArg) { $admitArgs += @('-AcceptanceFile', $AcceptanceFileArg) }
    if ($flowPath) {
        $admitArgs += @('-FlowFile', $flowPath)
    } else {
        # 显式开启派生：由准入网关按 pad_flow_name → 文件名/name 唯一命中；多命中报 ADMIT_AMBIGUOUS_FLOW
        $admitArgs += @('-FlowName', $FlowName)
    }
    $admitOut = & powershell @admitArgs *>&1 | Out-String
    $admitExit = $LASTEXITCODE

    $decision = Get-AdmitGateDecision -ExitCode $admitExit -Output $admitOut -ScriptPath $admitScript
    if (-not $decision.allow) {
        $msg = "admit gate refused to run ($($decision.reason)): $($decision.message)"
        if ($AdmitMode -eq 'enforce') { throw "$msg (enforce mode, fail-closed)" }
        Write-Log "$msg (report mode; continuing after this notice)"
        $script:Result.warnings += $msg
        return $true
    }
    Write-Log $decision.message
    if ($decision.summary -and [int]$decision.summary.warn -gt 0) {
        $script:Result.warnings += "准入警告 $([int]$decision.summary.warn) 项（不阻断）"
    }
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
function Get-PadRunResult([string]$rid, [string]$RunDir) {
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    # 等待阶段已锁定本次运行目录时直接用它
    $dir = $null
    if ($RunDir -and (Test-Path -LiteralPath $RunDir)) { $dir = Get-Item -LiteralPath $RunDir }
    if (-not $dir -and $rid) {
        # 只按本次触发的 runId 精确找：PAD 用 URL 里的 runId 作运行目录名。
        # 复用 PadDesigner 的 Resolve-PadRunDir（与等待阶段同一口径），
        # 绝不退化成“取触发之后最新的目录”——同机并发时那会拿到别人的运行
        $dir = Resolve-PadRunDir -ScriptsRoot $base -RunId $rid
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
        # 同样必须按 UTF-8 读，否则中文失败动作名会让 JSON 解析报错；
        # 用共享模式读，避免流程还在跑时被 PAD 的写句柄挡住
        try {
            $rdText = Read-TextShared $rdPath
            $status = ($rdText | ConvertFrom-Json).status
        } catch { Write-Log "failed to parse RunDefinition.json: $($_.Exception.Message)" }
    }

    $actions = @()
    $failed = $null
    $summary = $null
    if (Test-Path $logPath) {
        # Actions.log 是 UTF-8（PowerShell 5.1 的 Get-Content 默认按 ANSI 读会乱码并破坏 JSON）；
        # PAD 运行期间会独占写句柄，必须共享读，否则 ReadAllLines 直接抛“文件正由另一进程使用”
        $logText = ''
        try { $logText = Read-TextShared $logPath } catch {
            Write-Log "Actions.log is not readable yet: $($_.Exception.Message)"
        }
        foreach ($line in ($logText -split "`r?`n")) {
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

    # 跨进程互斥：同一时刻只允许一个流占用 PAD。
    # 放在最前面（早于准入、注入），后来者在这里排队，而不是两个流同时抢 PAD
    if (-not $NoLock) {
        $script:Result.stage = 'lock'
        # 抢锁结果与等待时长一次带回（ok/waitedSec），不再另调状态查询函数
        $lock = Enter-PadRunLock -FlowName $FlowName -WaitSec $LockWaitSec -Logger { param($m) Write-Log $m }
        $waited = $lock.waitedSec
        $script:Result.lockWaitSec = $waited
        if (-not $lock.ok) {
            $script:LockTimedOut = $true
            $info = Get-PadLockInfo
            $holder = if ($info) { "$($info.flow) (pid $($info.pid))" } else { 'unknown' }
            throw "timed out waiting for PAD to become free (${LockWaitSec}s); current holder: $holder. This run did not execute; retry later."
        }
        if ($waited -gt 0) { Write-Log "PAD is now free (waited $waited s)" }
    }

    # 准入网关：RunOnly（定时任务）也跑，避免夜间运行绕过门禁
    [void](Invoke-AdmitGate $FlowFile $ConfigFile $AcceptanceFile)

    if (-not $RunOnly) {
        if (-not $RobinFile -or -not (Test-Path $RobinFile)) { throw ".robin file not found: $RobinFile" }
        $text = [IO.File]::ReadAllText((Resolve-Path $RobinFile), [Text.Encoding]::UTF8)
        if (-not $text.Trim()) { throw '.robin file is empty' }

        # 准入网关已在主流程开头跑过（RunOnly 也覆盖），这里只做静态校验
        # V 模型 G2：静态校验不通过就不进设计器，避免坏脚本污染画布
        if (-not $SkipStaticCheck) {
            $script:Result.stage = 'static-check'
            $checkJs = Join-Path (Split-Path -Parent $PSScriptRoot) 'pad-robin\check.js'
            if (-not (Test-Path $checkJs)) { throw "static checker not found: $checkJs" }
            $checkOut = & node $checkJs (Resolve-Path $RobinFile).Path 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("static check failed (check.js exit code $LASTEXITCODE): " + (($checkOut | Out-String).Trim()))
            }
            Write-Log 'static check passed (check.js 0 errors)'
        }

        $script:Result.stage = 'find-designer'
        $win = Get-DesignerWindow -FlowName $FlowName
        if (-not $win) { throw "no PAD designer window is open for '$FlowName'; open that flow in PAD first" }

        $script:Result.stage = 'inject'
        $inj = Invoke-PadInject -Window $win -Text $text -Replace:$Replace -VerifyCanvas:$VerifyCanvas
        $afterCount = [int]$inj.actions
        if ($VerifyCanvas) { $script:Result.canvasVerified = [bool]$inj.verified }
        if ($afterCount -le 0) { throw 'canvas is empty after injection; injection failed' }
        Write-Log "injection done: $afterCount actions on the canvas"

        # 只验证注入、不发布不运行：用于确认画布真的被更新
        if (-not $InjectOnly -and -not $NoPublish -and -not $LocalRun) {
            $script:Result.stage = 'publish'
            $win = Get-DesignerWindow -FlowName $FlowName
            # 正常发布不超过 3 分钟；超过即视为异常（版本冲突或服务故障），不能静默等待
            [void](Click-ToolButton $win 'PublishFlowButton')
            $published = Wait-PublishDone $win 300
            if (-not $published) {
                throw 'publish timed out: not finished within 300s. A common cause is a version conflict from the flow being edited elsewhere; close and reopen the flow, then retry.'
            }
            Write-Log 'publish done'
        }
    }

    if ($InjectOnly) {
        Write-Log 'injected; skipping the run (-InjectOnly)'
        $script:Result.ok = $true
        $script:Result.status = 'Injected'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } elseif ($PublishOnly) {
        # 只保存到云端：发布完成后直接结束，不触发 URL 运行
        Write-Log 'published; skipping the run (-PublishOnly)'
        $script:Result.ok = $true
        $script:Result.status = 'Published'
        $script:Result.actions = $afterCount
        $script:Result.stage = 'done'
    } else {
        $script:Result.stage = 'run'
        $runStart = (Get-Date).AddSeconds(-5)
        # 等待阶段按“运行日志落盘”锁定本次运行，返回目录/日志路径与终止状态，
        # 不再用“PAD.RobotV2 进程是否还在”判结束（同机并发时会误判）
        $runHint = $null
        try {
            $runHint = Invoke-PadRun -WorkflowName $FlowName -RunId $RunId -TimeoutSec $RunTimeoutSec `
                -Local:($LocalRun -or $NoPublish) -NonInteractive:$NonInteractive
        } catch {
            # 触发前校验失败（流程名解析不出 flowId）也算触发失败，单独分类后退出码仍是 1
            if ([string]$_.Exception.Data['code'] -eq 'TRIGGER_PREFLIGHT_FAILED') {
                $script:Result.triggerFailed = $true
                $script:Result.triggerReason = 'identity-mismatch'
            }
            throw
        }
        if (-not $runHint -or -not $runHint.evidence) {
            # 没起来：协议处理器没反应、确认框被取消、PAD 报错弹窗阻塞都会落到这里
            $script:Result.triggerFailed = $true
            $script:Result.triggerReason = 'no-evidence'
            $script:Result.error = [ordered]@{
                code = 'TRIGGER_NO_EVIDENCE'
                message = 'no log appeared for this run after triggering (protocol handler did not respond / flow name or flowId mismatch / PAD error)'
            }
            throw $script:Result.error.message
        }

        # 非交互运行停在人工确认弹窗（完成提示 / 人工确认等）：
        # 不自动点击、不杀进程，弹窗留给人工；本次以 needs-human-confirm 收尾，
        # 让调度层立刻告警，而不是无声挂到 180 分钟超时。ok 保持 $null（未知 ≠ 失败）
        if ($runHint.evidence -eq 'human-confirm') {
            $script:Result.stage = 'needs-human-confirm'
            $script:Result.needsHumanConfirm = $true
            $script:Result.dialogTitle = $runHint.dialogTitle
            $script:Result.status = 'NeedsHumanConfirm'
            $script:Result.ok = $null
            $script:Result.evidence = 'human-confirm'
            $script:Result.logPath = $runHint.logPath
            $script:Result.warnings += "非交互运行停在人工确认弹窗「$($runHint.dialogTitle)」，流程保持等待人工点击"
            Write-Log "run stopped at a manual-confirmation dialog `"$($runHint.dialogTitle)`": not clicking automatically; handle it manually and rerun"
        } elseif ($runHint.startupTimedOut -and -not $runHint.status) {
            # 运行目录已出现但机器人始终没启动：以前会落到 Unknown→退出码 0，静默无告警，
            # 现在按 trigger-failed（reason=no-robot）收尾，只告警不重试
            $script:Result.stage = 'trigger'
            $script:Result.status = 'NotStarted'
            $script:Result.ok = $false
            $script:Result.triggerFailed = $true
            $script:Result.triggerReason = 'no-robot'
            $script:Result.logPath = $runHint.logPath
            $script:Result.error = [ordered]@{
                code = 'TRIGGER_NO_ROBOT'
                message = 'the trigger was accepted and a run directory appeared, but the robot did not start within the watch window (it may be stuck on a PAD error dialog or was cancelled)'
            }
        } elseif ($runHint.timedOut -and -not $runHint.status) {
            # 等满 RunTimeoutSec 仍未拿到终止状态：按运行超时告警，不静默按 Unknown 退出
            $script:Result.stage = 'run-timeout'
            $script:Result.status = 'RunTimeout'
            $script:Result.ok = $false
            $script:Result.runTimeout = $true
            $script:Result.logPath = $runHint.logPath
            $script:Result.error = [ordered]@{
                code = 'RUN_TIMEOUT'
                message = "waited more than $RunTimeoutSec s for the run to end and never got a terminal status"
            }
        } else {
        $script:Result.stage = 'collect'
        if ($LocalRun -or $NoPublish) {
            # 设计器内运行：读 DataCollection 下的 RobinRobot.log 遥测
            $res = Get-DesignerRunResult $runStart $runHint.logPath
            if (-not $res) {
                # 日志正被机器人进程写住、读不出来（或确实找不到）：
                # 按 Unknown 收尾，不判失败、不抛异常，与 Console 取证同一口径
                $script:Result.status = 'Unknown'
                $script:Result.ok = $null
                $script:Result.evidence = 'unknown'
                $script:Result.logPath = $runHint.logPath
                $script:Result.warnings += 'RobinRobot.log 暂不可读或不存在，本次取证为 Unknown（不判失败）'
                Write-Log 'RobinRobot.log is unreadable or missing; outcome recorded as Unknown (unknown is not failure)'
            } else {
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
            }
        } else {
            $res = Get-PadRunResult $RunId $runHint.runDir
            # Actions.log 在运行结束后会被 PAD 清理：拿不到或状态为空时，
            # 必须按 runId 回 Console 遥测取证，绝不用可能为空的 runHint.status 判失败。
            # 取证优先级：Actions.log → PadConsole 本次 runId 事件 → Unknown（未知 ≠ 失败）
            if (-not $res -or -not $res.status) {
                $console = Get-PadConsoleRunOutcome -RunId $RunId -Since $runStart
                if ($console -and $console.outcome -eq 'Succeeded') {
                    $res = [ordered]@{ status = 'Succeeded'; actions = @(); failed = $null; logPath = $console.logPath }
                    $script:Result.evidence = 'console'
                    Write-Log 'Actions.log unavailable: PadConsole telemetry says this run succeeded'
                } elseif ($console -and $console.outcome -eq 'Failed') {
                    $res = [ordered]@{
                        status = 'Failed'; actions = @(); logPath = $console.logPath
                        failed = [ordered]@{ name = $null; error = [ordered]@{
                            code = 'CONSOLE_RUN_FAILED'; message = "PadConsole recorded this run as failed ($($console.event))" } }
                    }
                    $script:Result.evidence = 'console'
                    Write-Log 'Actions.log unavailable: PadConsole telemetry says this run failed'
                } else {
                    $script:Result.status = 'Unknown'
                    $script:Result.ok = $null
                    $script:Result.evidence = 'unknown'
                    $script:Result.logPath = $runHint.logPath
                    if ($console -and $console.note) {
                        # 日志正被 PAD 写住、读不出来：仍只记 Unknown，不判失败、不发 run-failed
                        $script:Result.warnings += $console.note
                        Write-Log $console.note
                    } else {
                        $script:Result.warnings += 'Actions.log 与 PadConsole 均无本次运行证据，结果未知（不判失败、不发 run-failed）'
                        Write-Log 'no usable run evidence; outcome recorded as Unknown (unknown is not failure)'
                    }
                    # 必须清空，否则下面 if ($res) 会用 $res.status（可能为 $null）覆盖 'Unknown'
                    $res = $null
                }
            }

            if ($res) {
                $script:Result.status = $res.status
                $script:Result.actions = $res.actions
                $script:Result.logPath = $res.logPath
                if ($res.failed) {
                    $script:Result.failedAction = $res.failed
                    $script:Result.error = $res.failed.error
                    $script:Result.ok = $false
                } elseif ($res.status -eq 'Succeeded') {
                    $script:Result.ok = $true
                } else {
                    $script:Result.ok = $null
                    if (-not $script:Result.evidence) { $script:Result.evidence = 'unknown' }
                }
            }
        }

        # V 模型 G6：运行成功不等于业务正确，按判据检查产物
        if ($AcceptanceFile) {
            $script:Result.stage = 'acceptance'
            if (-not $ConfigFile) { throw '-AcceptanceFile requires -ConfigFile' }
            if (-not (Test-Path $AcceptanceFile)) { throw "acceptance spec not found: $AcceptanceFile" }
            $configMap = Get-AcceptanceConfig -Path $ConfigFile
            $acc = Test-AcceptanceFile -Path $AcceptanceFile -Config $configMap -Since $runStart
            $script:Result.acceptance = $acc
            Write-Log ("acceptance: pass {0} / fail {1} / skip {2}" -f $acc.passed, $acc.failed, $acc.skipped)
            if (-not $acc.ok) {
                $script:Result.ok = $false
                if (-not $script:Result.error) {
                    $script:Result.error = [ordered]@{ code = 'ACCEPTANCE_FAILED'; message = "acceptance failed: $($acc.failed) item(s)" }
                }
            }
        }
        $script:Result.stage = 'done'
        }
    }
}
catch {
    $script:Result.ok = $false
    # 触发类失败在抛出前已写入分类错误码，这里只补消息，不覆盖 code
    $code = $null
    if ($script:Result.error -is [System.Collections.IDictionary]) {
        $code = $script:Result.error['code']
    } elseif ($script:Result.error) {
        $code = $script:Result.error.code
    }
    if ($code) {
        $script:Result.error = [ordered]@{ code = $code; message = $_.Exception.Message }
    } else {
        $script:Result.error = [ordered]@{ message = $_.Exception.Message }
    }
    Write-Log "failed at [$($script:Result.stage)]: $($_.Exception.Message)"
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
            -Ok $script:Result.ok -Stage $script:Result.stage -Status $script:Result.status `
            -Actions $script:Result.actions -TotalMs $script:Result.totalMs `
            -ErrorCode $errCode -ErrorMessage $errMsg `
            -LogPath $script:Result.logPath -CanvasVerified $script:Result.canvasVerified `
            -Acceptance $script:Result.acceptance -Warnings $script:Result.warnings
        Add-ManifestEntry $ManifestPath $entry
        Write-Log "manifest appended: $ManifestPath"
        # run 记录只留 90 天；release / rollback 永久保留。清理失败不影响运行结果
        try {
            $dropped = Remove-OldManifestEntries $ManifestPath -KeepDays 90
            if ($dropped -gt 0) { Write-Log "manifest pruned $dropped run record(s) older than 90 days" }
        } catch { Write-Log "manifest prune failed (does not affect the run result): $($_.Exception.Message)" }
    } catch {
        Write-Log "manifest write failed (does not affect the run result): $($_.Exception.Message)"
    }
}

# 释放互斥锁：正常结束、异常结束都要走这里；进程被强杀时系统会自动释放
Exit-PadRunLock

# ── 失败告警：直调路径（手工点运行 / URL 触发）也要落 alerts.jsonl ──
# 与 pad-schedule 共用 PadAlerts.psm1；成功（exit 0 且无失败标记）不写。
# 同一 runId + 同一 kind 只写一条，重试不会刷屏。
$alertDir = $null
$alertRepo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (Test-Path (Join-Path $alertRepo 'tools')) { $alertDir = Join-Path $alertRepo 'business\logs' }
if ($alertDir) {
    $alertExit = 0
    if ($script:LockTimedOut) { $alertExit = 4 }
    elseif ($script:Result.needsHumanConfirm) { $alertExit = 3 }
    elseif ($script:Result.ok -eq $false) { $alertExit = 1 }
    try {
        $alert = Write-RunAlert -FlowName $FlowName -ExitCode $alertExit -Stage $script:Result.stage `
            -Status $script:Result.status -SyncResult $script:Result -LogPath $script:Result.logPath `
            -RunId ([string]$script:Result.runId) -Dir $alertDir
        if ($alert -and -not $alert.skipped) { Write-Log "failure alert written: $($alert.path)" }
    } catch {
        # 告警写入失败不能影响运行结果与退出码，只提示
        Write-Log "alert write failed (does not affect the run result): $($_.Exception.Message)"
    }
}

# 供 agent 解析的最终结果（最后一行固定前缀）
Write-Output ("PAD_SYNC_RESULT=" + ($script:Result | ConvertTo-Json -Depth 8 -Compress))

# 退出码：0 成功/结果未知 / 1 运行失败 / 3 停在人工确认 / 4 等锁超时
# 结果未知（ok=$null）不按失败处理，避免 Actions.log 被清理后误报
if ($script:LockTimedOut) { exit 4 }
if ($script:Result.needsHumanConfirm) { exit 3 }
if ($script:Result.ok -eq $false) { exit 1 }
exit 0
