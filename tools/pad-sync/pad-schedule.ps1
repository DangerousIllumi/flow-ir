# pad-schedule.ps1 — 定时触发（attended，本地任务计划 + 工作日历）
#
# 是否运行由「工作日历」决定，而不是简单按周一到周五：
#   中国有法定节假日和调休（节假日不上班、周末可能补班），周一到周五的规则
#   会在春节、国庆照常跑，也会漏掉调休上班的周末。
#   因此默认改为「每天 09:00 触发 → 运行时先查日历 → 不是工作日就直接退出」。
#   日历切换点：tools\workday\workday.py 的 --is-workday（通用件，与核对脚本共用同一份日历逻辑）。
#
# 为什么用 Windows 任务计划而不是云端 Recurrence：
#   attended 模式本身要求「机器开机 + 用户已登录」，云端 Recurrence 同样要求机器在线，
#   却额外需要 Power Automate Premium（或 RPA attended 附加许可）。
#   任务计划不依赖额外许可，且可脚本化、可审计、可一键卸载。
#
# 云端 Recurrence 的做法（需要 Premium，本脚本不代劳）：
#   1. make.powerautomate.com → 我的流 → 找到该桌面流 → 编辑 → 触发器 → 添加「计划」；
#   2. 频率=天，时区=中国标准时间，时间=09:00；
#   3. 保存后需保持目标机器在线且已登录（attended）。
#   注意：云端 Recurrence 不会识别中国节假日，仍需在流程内用日历判断。
#
# 运行结果不需要重定向日志：pad-sync 会把每次运行追加到 manifest.jsonl（type=run）。
#
# 用法：
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -DryRun        # 只打印将注册的计划
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST                # 注册/更新（每天 09:00，按日历判断）
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -IgnoreCalendar # 不看日历，只要周一到周五就运行
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -List          # 查看下次触发与上次结果
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -RunNow        # 立即触发一次（有真实副作用）
#   .\pad-schedule.ps1 -FlowName PAD_SYNC_TEST -Remove        # 删除计划
#
# 输出：最后一行 PAD_SCHEDULE_RESULT=<JSON>；退出码 0 成功 / 1 失败

[CmdletBinding()]
param(
    [string]$FlowName = 'PAD_SYNC_TEST',
    # 触发时刻（HH:mm），默认每天 09:00
    [string]$Time = '09:00',
    [string]$TaskName,
    # 被调度的脚本，默认同目录的 pad-sync.ps1
    [string]$PadSyncPath,
    # 工作日历与解释器（默认取 C:\PAD 下的日历、Python313）
    [string]$CalendarPath,
    [string]$PythonExe,
    # 工作日判断脚本（通用件；默认 tools\workday\workday.py，找不到时按周一至周五兜底）
    [string]$WorkdayScript,
    # 运行后验收判据与部署配置（可选；生产定时运行建议带上）
    [string]$AcceptanceFile,
    [string]$ConfigFile,
    # 单次运行超时：最坏 7 次轮询 60 分钟 + 处理余量
    [int]$RunTimeoutSec = 4200,
    # 忽略日历，退化为「周一到周五都跑」（不推荐：节假日会误跑、调休会漏跑）
    [switch]$IgnoreCalendar,
    # 运行入口：任务计划触发时由本脚本先判日历，再决定是否调用 pad-sync
    [switch]$RunIfWorkday,
    # 生产流程必须显式给出，与其它部署脚本的熔断口径一致
    [switch]$AllowProd,
    [switch]$List,
    [switch]$Remove,
    [switch]$RunNow,
    [switch]$DryRun,
    # 仅供 Pester dot-source 加载函数
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)

function Log([string]$m) { Write-Host "[schedule] $m" }

# 任务名：nlg-workflow-<流程名>；流程名里的非法字符与空白统一替换成下划线
function Get-ScheduleTaskName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|\s]', '_').Trim('_')
    if (-not $safe) { throw '流程名为空，无法生成任务名' }
    return 'nlg-workflow-' + $safe
}

# 解析触发时刻，返回合法的 DateTime（只取时分）
function ConvertTo-ScheduleTime([string]$Time) {
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Time, [ref]$t)) {
        throw "触发时刻格式不对：$Time（应为 HH:mm，如 09:00）"
    }
    return $t
}

# 构造任务动作
#   WorkdayGate：任务先调本脚本 -RunIfWorkday，由脚本查日历后再决定是否跑 pad-sync
#   否则直接调 pad-sync -RunOnly（周一到周五都跑）
# 路径与流程名一律加双引号：仓库路径常含空格，不加会被 -File 截断
function New-ScheduleActionSpec {
    param(
        [string]$ScriptPath,
        [string]$FlowName,
        [switch]$AllowProd,
        [switch]$WorkdayGate,
        [string]$PadSyncPath,
        [string]$PythonExe,
        [string]$CalendarPath,
        [string]$AcceptanceFile,
        [string]$ConfigFile,
        [string]$WorkdayScript,
        [int]$RunTimeoutSec = 4200
    )
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $ScriptPath + '"'),
        '-FlowName', ('"' + $FlowName + '"'),
        '-RunTimeoutSec', [string]$RunTimeoutSec)
    if ($WorkdayGate) {
        $argList += @('-RunIfWorkday',
            '-PadSyncPath', ('"' + $PadSyncPath + '"'),
            '-PythonExe', ('"' + $PythonExe + '"'),
            '-CalendarPath', ('"' + $CalendarPath + '"'))
        if ($WorkdayScript) { $argList += @('-WorkdayScript', ('"' + $WorkdayScript + '"')) }
    } else {
        $argList += '-RunOnly'
    }
    if ($AcceptanceFile) { $argList += @('-AcceptanceFile', ('"' + $AcceptanceFile + '"')) }
    if ($ConfigFile) { $argList += @('-ConfigFile', ('"' + $ConfigFile + '"')) }
    if ($AllowProd) { $argList += '-AllowProd' }
    return [ordered]@{ exe = 'powershell.exe'; args = ($argList -join ' ') }
}

# 查日历判断今天是否工作日。返回 [ordered]@{ workday; calendarOk; fallback }
# 找不到 workday.py 时不让定时任务直接失败：按周一至周五兜底并在结果里标记 fallback
function Test-TodayWorkday([string]$PythonExe, [string]$WorkdayScript, [string]$CalendarPath) {
    $isWeekday = ((Get-Date).DayOfWeek -ne 'Saturday' -and (Get-Date).DayOfWeek -ne 'Sunday')
    if (-not $WorkdayScript -or -not (Test-Path $WorkdayScript)) {
        Log "警告：找不到工作日脚本（$WorkdayScript），按周一至周五兜底"
        return [ordered]@{ workday = $isWeekday; calendarOk = $false; fallback = $true }
    }
    $out = & $PythonExe $WorkdayScript --is-workday --calendar $CalendarPath 2>&1 | Out-String
    if ($out -notmatch 'WORKDAY=(\d)') {
        Log "警告：工作日判断失败，按周一至周五兜底：$($out.Trim())"
        return [ordered]@{ workday = $isWeekday; calendarOk = $false; fallback = $true }
    }
    return [ordered]@{
        workday = ($Matches[1] -eq '1')
        calendarOk = ($out -notmatch 'CALENDAR_OK=0')
        fallback = $false
    }
}

# 从 pad-sync 的输出里取最后一行 PAD_SYNC_RESULT=<JSON>（取不到就返回 $null）
function Read-SyncResult([string[]]$Lines) {
    $hit = @($Lines | Where-Object { $_ -match '^PAD_SYNC_RESULT=' })
    if ($hit.Count -eq 0) { return $null }
    try {
        return ($hit[$hit.Count - 1].Substring('PAD_SYNC_RESULT='.Length) | ConvertFrom-Json)
    } catch { return $null }
}

# 失败告警：只追加到 logs\alerts.jsonl，不发送任何外部消息
#
# 为什么放在调度层而不是 PAD 流程里：流程内的发信动作覆盖不到「进程崩溃 / 超时被杀 /
# 09:00 没启动」，而这三类恰恰是调度层唯一能看见的失败。只写日志则不需要任何凭据，
# 也不会因为告警通道本身故障而影响主流程。
function Write-RunAlert {
    param(
        [string]$FlowName,
        [int]$ExitCode,
        [string]$Stage,
        [string]$Status,
        $SyncResult,
        [string]$LogPath,
        [string]$Dir
    )
    if (-not $Dir) { $Dir = Join-Path $script:RepoRoot 'logs' }
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $file = Join-Path $Dir 'alerts.jsonl'

    $errCode = $null
    $errMsg = $null
    $acc = $null
    if ($SyncResult) {
        if ($SyncResult.error) {
            if ($SyncResult.error.code) { $errCode = $SyncResult.error.code }
            if ($SyncResult.error.message) { $errMsg = $SyncResult.error.message }
        }
        $acc = $SyncResult.acceptance
    }

    $rec = [ordered]@{
        ts         = (Get-Date).ToString('o')
        kind       = 'run-failed'
        flow       = $FlowName
        exitCode   = $ExitCode
        stage      = $Stage
        status     = $Status
        errorCode  = $errCode
        error      = $errMsg
        logPath    = $LogPath
        acceptance = $acc
    }
    # 不用 Add-Content：PS 5.1 首次写入会带 BOM，JSONL 逐行解析会失败
    [IO.File]::AppendAllText($file, (($rec | ConvertTo-Json -Depth 8 -Compress) + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ path = $file; record = $rec }
}

# ═══ 主流程 ═══
if (-not $NoMain) {
    $exitCode = 1
    $result = [ordered]@{
        ok = $false; action = 'register'; flow = $FlowName; taskName = $null
        time = $Time; taskPath = $null; nextRunTime = $null; lastRunTime = $null
        lastTaskResult = $null; workdayGate = (-not $IgnoreCalendar)
        skipped = $false; reason = $null; runExitCode = $null
        dryRun = [bool]$DryRun; errors = @()
    }
    try {
        # 计划任务的工作目录不是仓库根，判据/配置必须先转成绝对路径再写进任务动作
        if ($AcceptanceFile) { $AcceptanceFile = (Resolve-Path -LiteralPath $AcceptanceFile).Path }
        if ($ConfigFile) { $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path }
        if (-not $TaskName) { $TaskName = Get-ScheduleTaskName $FlowName }
        $result.taskName = $TaskName
        $result.taskPath = '\' + $TaskName

        # ── 运行入口（任务计划实际调用的分支） ──
        if ($RunIfWorkday) {
            $result.action = 'run-if-workday'
            if (-not $WorkdayScript) { $WorkdayScript = Join-Path $script:RepoRoot 'tools\workday\workday.py' }
            if (-not $PythonExe) { $PythonExe = 'C:\Program Files\Python313\python.exe' }
            if (-not $CalendarPath) { $CalendarPath = 'C:\PAD\2026_PAD工作日日历.xlsx' }
            if (-not $PadSyncPath) { $PadSyncPath = Join-Path $here 'pad-sync.ps1' }

            $wd = Test-TodayWorkday $PythonExe $WorkdayScript $CalendarPath
            if (-not $wd.calendarOk) { Log "警告：工作日历不可用，已按周一至周五兜底（$CalendarPath）" }
            if (-not $wd.workday) {
                Log "今天不是工作日，本次跳过（日历：$CalendarPath）"
                $result.ok = $true; $result.skipped = $true; $result.reason = 'not-workday'
                $exitCode = 0
                return
            }
            if (-not (Test-Path $PadSyncPath)) { throw "找不到 pad-sync.ps1：$PadSyncPath" }
            Log "今天是工作日，开始运行 $FlowName"
            $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PadSyncPath,
                '-FlowName', $FlowName, '-RunOnly', '-RunTimeoutSec', $RunTimeoutSec)
            if ($AllowProd) { $syncArgs += '-AllowProd' }
            if ($AcceptanceFile) {
                if (-not $ConfigFile) { throw '使用 -AcceptanceFile 时必须同时提供 -ConfigFile' }
                $syncArgs += @('-AcceptanceFile', $AcceptanceFile, '-ConfigFile', $ConfigFile)
            }
            # 边跑边打印，同时留存输出以便解析 PAD_SYNC_RESULT（工单/告警要带上 stage）
            $syncLines = @(& powershell @syncArgs 2>&1 | ForEach-Object { Write-Host $_; $_ })
            $result.runExitCode = $LASTEXITCODE
            $result.ok = ($LASTEXITCODE -eq 0)
            $exitCode = $LASTEXITCODE
            # 只在真正失败时记告警：非工作日跳过在更早就 return 了，不会误报
            if ($exitCode -ne 0) {
                $sync = Read-SyncResult $syncLines
                $stage = if ($sync) { [string]$sync.stage } else { 'unknown' }
                $status = if ($sync) { [string]$sync.status } else { $null }
                $logPath = if ($sync) { [string]$sync.logPath } else { $null }
                $alert = Write-RunAlert -FlowName $FlowName -ExitCode $exitCode -Stage $stage `
                    -Status $status -SyncResult $sync -LogPath $logPath
                $result.alertLog = $alert.path
                Log "运行失败（stage=$stage），已写入告警日志：$($alert.path)"
            }
            return
        }

        # ── 查询 ──
        if ($List) {
            $result.action = 'list'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { throw "找不到计划任务：$TaskName（先不带 -List 注册一次）" }
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            $result.nextRunTime = $info.NextRunTime
            $result.lastRunTime = $info.LastRunTime
            $result.lastTaskResult = $info.LastTaskResult
            Log ("下次触发：{0}；上次运行：{1}（结果 {2}）" -f $info.NextRunTime, $info.LastRunTime, $info.LastTaskResult)
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── 删除 ──
        if ($Remove) {
            $result.action = 'remove'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { Log "计划任务不存在，无需删除：$TaskName"; $result.ok = $true; $exitCode = 0; return }
            if ($DryRun) { Log "[DryRun] 将删除计划任务：$TaskName"; $result.ok = $true; $exitCode = 0; return }
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Log "已删除计划任务：$TaskName"
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── 立即触发（验证用，会真实运行一次流程） ──
        if ($RunNow) {
            $result.action = 'run-now'
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if (-not $task) { throw "找不到计划任务：$TaskName" }
            if ($DryRun) { Log "[DryRun] 将立即触发：$TaskName"; $result.ok = $true; $exitCode = 0; return }
            Start-ScheduledTask -TaskName $TaskName
            Log "已触发计划任务：$TaskName（流程运行结果见 manifest.jsonl）"
            $result.ok = $true; $exitCode = 0
            return
        }

        # ── 注册/更新 ──
        if (-not $PadSyncPath) { $PadSyncPath = Join-Path $here 'pad-sync.ps1' }
        if (-not (Test-Path $PadSyncPath)) { throw "找不到 pad-sync.ps1：$PadSyncPath" }
        if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
            throw '安全熔断：默认只能为 PAD_SYNC_TEST 建计划。生产流程请显式加 -AllowProd。'
        }
        if ($AcceptanceFile -and -not $ConfigFile) {
            throw '使用 -AcceptanceFile 时必须同时提供 -ConfigFile'
        }
        $gate = -not $IgnoreCalendar
        if (-not $PythonExe) { $PythonExe = 'C:\Program Files\Python313\python.exe' }
        if (-not $CalendarPath) { $CalendarPath = 'C:\PAD\2026_PAD工作日日历.xlsx' }
        if (-not $WorkdayScript) { $WorkdayScript = Join-Path $script:RepoRoot 'tools\workday\workday.py' }

        $at = ConvertTo-ScheduleTime $Time
        if ($gate) {
            $spec = New-ScheduleActionSpec -ScriptPath $PSCommandPath -FlowName $FlowName `
                -AllowProd:$AllowProd -WorkdayGate `
                -PadSyncPath $PadSyncPath -PythonExe $PythonExe -CalendarPath $CalendarPath `
                -WorkdayScript $WorkdayScript `
                -AcceptanceFile $AcceptanceFile -ConfigFile $ConfigFile -RunTimeoutSec $RunTimeoutSec
            Log ("触发：每天 {0:HH:mm}，运行时按工作日历判断（日历：{1}）" -f $at, $CalendarPath)
        } else {
            $spec = New-ScheduleActionSpec -ScriptPath $PadSyncPath -FlowName $FlowName -AllowProd:$AllowProd `
                -AcceptanceFile $AcceptanceFile -ConfigFile $ConfigFile -RunTimeoutSec $RunTimeoutSec
            Log ("触发：周一至周五 {0:HH:mm}（忽略日历，节假日会误跑、调休会漏跑）" -f $at)
        }
        Log "动作：$($spec.exe) $($spec.args)"

        if ($DryRun) {
            Log "[DryRun] 未注册计划任务"
            $result.ok = $true; $exitCode = 0
            return
        }

        $action = New-ScheduledTaskAction -Execute $spec.exe -Argument $spec.args
        if ($gate) {
            # 每天触发，具体跑不跑交给日历（节假日跳过、调休照跑）
            $trigger = New-ScheduledTaskTrigger -Daily -At $at
        } else {
            $trigger = New-ScheduledTaskTrigger -Weekly `
                -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $at
        }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
        # Interactive = 只有该用户已登录时才运行，正是 attended 的语义
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        $desc = "nlg-workflow：每天 $Time 触发，按工作日历判断后运行 PAD 流程 $FlowName（attended）"

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -Description $desc | Out-Null

        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        $result.nextRunTime = $info.NextRunTime
        Log "已注册计划任务：$TaskName；下次触发：$($info.NextRunTime)"
        $result.ok = $true; $exitCode = 0
    }
    catch {
        $result.errors += $_.Exception.Message
        Log "失败于 [$($result.action)]：$($_.Exception.Message)"
    }
    finally {
        Write-Output ('PAD_SCHEDULE_RESULT=' + ($result | ConvertTo-Json -Depth 6 -Compress))
    }
    exit $exitCode
}
