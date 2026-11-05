# TriggerRegistry.psm1 —— 触发声明解析与计划任务注册
#
# 只实现 manual 与 schedule；file 分支留桩（第 4 步再做）。
# 动作构造复用 pad-schedule.ps1（dot-source -NoMain），不复制一份启动方式。
# 失败一律硬失败：抛异常由调用方转成非零退出码，注册/注销失败写 PadAlerts 告警。

$moduleHere = $PSScriptRoot
$moduleRepo = Split-Path -Parent (Split-Path -Parent $moduleHere)

Import-Module (Join-Path $moduleHere 'PadAlerts.psm1') -Force
# -NoMain：只加载函数与变量，不执行注册主流程
. (Join-Path $moduleHere 'pad-schedule.ps1') -NoMain

# 触发声明的取值域，与 pad-admit 第 14 项保持一致
$script:TriggerKinds = @('manual', 'schedule', 'file')
$script:TriggerReservedKinds = @('mail', 'callback')
$script:TriggerDays = @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
$script:TriggerGates = @('none', 'workday', 'last-workday')

function Test-TriggerProp($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
    return (@($Obj.PSObject.Properties.Name) -contains $Name)
}

# 带结果码的异常：CLI 与 pad-admit 靠 Data['code'] 分类，不解析中文消息
function New-TriggerException([string]$Code, [string]$Message) {
    $ex = New-Object System.Exception($Message)
    $ex.Data['code'] = $Code
    return $ex
}

function Test-TriggerPositiveInt($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $false }
    $d = [double]$Value
    return ($d -gt 0 -and $d -eq [math]::Floor($d))
}

# 读取流程文件；FlowFile 缺失/不存在/不是 JSON 一律输入错误
function Read-TriggerFlow([string]$FlowFile) {
    if (-not $FlowFile) { throw (New-TriggerException 'TRIGGER_INPUT_MISSING' '未提供 -FlowFile') }
    if (-not (Test-Path -LiteralPath $FlowFile)) {
        throw (New-TriggerException 'TRIGGER_INPUT_MISSING' "流程文件不存在：$FlowFile")
    }
    try {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FlowFile).Path, [Text.Encoding]::UTF8)
        return ($text | ConvertFrom-Json)
    } catch {
        throw (New-TriggerException 'TRIGGER_INPUT_INVALID' "流程文件不是合法 JSON：$FlowFile（$($_.Exception.Message)）")
    }
}

# 解析 trigger 声明，返回规范化对象；这里不做系统查询
function Get-TriggerSpec {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
    $flow = Read-TriggerFlow $FlowFile
    $trg = $null
    if (Test-TriggerProp $flow 'trigger') { $trg = $flow.trigger }
    if ($null -eq $trg) {
        throw (New-TriggerException 'TRIGGER_MISSING' '流程没有 trigger 声明，无法确定启动方式')
    }
    if (-not (Test-TriggerProp $trg 'kind') -and (Test-TriggerProp $trg 'type')) {
        throw (New-TriggerException 'TRIGGER_LEGACY_SHAPE' 'trigger 是 type/config 旧形状，请迁移到 kind')
    }
    if (-not (Test-TriggerProp $trg 'kind') -or -not [string]$trg.kind) {
        throw (New-TriggerException 'TRIGGER_INVALID' 'trigger.kind 缺失或不是字符串')
    }
    $kind = [string]$trg.kind
    if ($script:TriggerReservedKinds -contains $kind) {
        throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' "kind=$kind 是保留值，v1 没有对应注册器")
    }
    if ($script:TriggerKinds -notcontains $kind) {
        throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$kind 不在 manual/schedule/file")
    }

    # 流程名：优先 name 字段，其次文件名；与 pad-schedule 的任务名派生同口径
    $flowName = $null
    if ((Test-TriggerProp $flow 'name') -and [string]$flow.name) { $flowName = [string]$flow.name }
    if (-not $flowName) { $flowName = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path -LiteralPath $FlowFile).Path) }

    $time = $null
    $days = @('mon', 'tue', 'wed', 'thu', 'fri')
    $gate = 'none'
    $timeoutSec = 4200
    $fileDir = $null
    $filePattern = $null

    if ($kind -eq 'manual') {
        foreach ($k in @('time', 'days', 'gate', 'timeout_sec', 'file')) {
            if (Test-TriggerProp $trg $k) {
                throw (New-TriggerException 'TRIGGER_INVALID' "manual 不允许声明 $k（声明了也没人执行）")
            }
        }
    } else {
        if ((Test-TriggerProp $trg 'time')) { $time = [string]$trg.time }
        if (-not $time -or $time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            throw (New-TriggerException 'TRIGGER_INVALID' "time=$time（应为 HH:mm，如 09:00）")
        }
        if ((Test-TriggerProp $trg 'days')) {
            $days = @($trg.days)
            $bad = @($days | Where-Object { $script:TriggerDays -notcontains [string]$_ })
            if ($days.Count -eq 0 -or $bad.Count -gt 0) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'days 必须是非空数组，取值 mon..sun')
            }
        }
        if ((Test-TriggerProp $trg 'gate')) { $gate = [string]$trg.gate }
        if ($script:TriggerGates -notcontains $gate) {
            throw (New-TriggerException 'TRIGGER_INVALID' "gate=$gate 不在 none/workday/last-workday")
        }
        if ((Test-TriggerProp $trg 'timeout_sec')) {
            if (-not (Test-TriggerPositiveInt $trg.timeout_sec)) {
                throw (New-TriggerException 'TRIGGER_INVALID' "timeout_sec=$($trg.timeout_sec)（应为正整数秒）")
            }
            $timeoutSec = [int]$trg.timeout_sec
        }
        if ($kind -eq 'file') {
            # 第 4 步再实现文件落地；这里只把声明读出来，注册时统一拒绝
            if (Test-TriggerProp $trg 'file') {
                $f = $trg.file
                if (Test-TriggerProp $f 'dir') { $fileDir = [string]$f.dir }
                if (Test-TriggerProp $f 'pattern') { $filePattern = [string]$f.pattern }
            }
        }
        # 无人值守触发遇到人工确认节点是硬矛盾，注册前就拦住
        $confirm = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'run_mode') -and [string]$_.run_mode -eq 'confirm'
        })
        if ($confirm.Count -gt 0) {
            throw (New-TriggerException 'TRIGGER_UNATTENDED_CONFIRM' `
                ("无人值守触发但节点需要人工确认：" + (@($confirm | ForEach-Object { $_.id }) -join ',')))
        }
    }

    $taskName = $null
    if ($kind -ne 'manual') {
        if ((Test-TriggerProp $trg 'task_name')) {
            $taskName = [string]$trg.task_name
            if ($taskName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
                throw (New-TriggerException 'TRIGGER_INVALID' "task_name=$taskName 不匹配 ^[A-Za-z0-9._-]{1,64}$")
            }
        }
        if (-not $taskName) { $taskName = Get-ScheduleTaskName $flowName }
    }

    return [ordered]@{
        kind         = $kind
        flowName     = $flowName
        flowFile     = (Resolve-Path -LiteralPath $FlowFile).Path
        configFile   = $ConfigFile
        taskName     = $taskName
        time         = $time
        days         = $days
        gate         = $gate
        timeoutSec   = $timeoutSec
        fileDir      = $fileDir
        filePattern  = $filePattern
        raw          = $trg
    }
}

# 幂等键：显式规范化字段做 SHA256，键序与空白不影响结果
function Get-TriggerFingerprint {
    param([Parameter(Mandatory)]$Spec)
    $canon = [ordered]@{
        kind       = [string]$Spec.kind
        flowName   = [string]$Spec.flowName
        taskName   = [string]$Spec.taskName
        time       = [string]$Spec.time
        days       = @($Spec.days)
        gate       = [string]$Spec.gate
        timeoutSec = [int]$Spec.timeoutSec
    }
    if ([string]$Spec.kind -eq 'file') {
        $canon['fileDir'] = [string]$Spec.fileDir
        $canon['filePattern'] = [string]$Spec.filePattern
    }
    $json = $canon | ConvertTo-Json -Compress -Depth 6
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        return ((($sha.ComputeHash($bytes)) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $sha.Dispose()
    }
}

# 运行时路径：显式 -RuntimeConfigPath 优先；否则只认仓库内唯一的 business\config\runtime.json
function Resolve-TriggerRuntimeConfig {
    param([string]$RuntimeConfigPath)
    $path = $RuntimeConfigPath
    if (-not $path) {
        $candidate = Join-Path $moduleRepo 'business\config\runtime.json'
        if (-not (Test-Path -LiteralPath $candidate)) {
            throw (New-TriggerException 'CONFIG_MISSING' `
                '未提供 -RuntimeConfigPath，且仓库内没有 business\config\runtime.json；请显式指定运行时配置')
        }
        $path = $candidate
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw (New-TriggerException 'CONFIG_MISSING' "运行时配置不存在：$path")
    }
    try {
        $cfg = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'CONFIG_INVALID' "运行时配置不是合法 JSON：$path（$($_.Exception.Message)）")
    }
    foreach ($k in @('PadSyncPath', 'PythonExe', 'CalendarPath', 'WorkdayScript', 'RunTimeoutSec')) {
        if (-not (Test-TriggerProp $cfg $k) -or -not [string]$cfg.$k) {
            throw (New-TriggerException 'CONFIG_MISSING' "运行时配置缺少 $k（$path）")
        }
    }
    return $cfg
}

# 把 spec 转成计划任务动作；依然调用 pad-schedule 的 New-ScheduleActionSpec
function Get-TriggerActionSpec {
    param($Spec, $Runtime, [switch]$AllowProd)
    $common = @{
        FlowName      = $Spec.flowName
        ConfigFile    = $Spec.configFile
        RunTimeoutSec = [int]$Spec.timeoutSec
    }
    if ($AllowProd) { $common.AllowProd = $true }

    if ($Spec.gate -eq 'workday' -or $Spec.gate -eq 'last-workday') {
        # 门禁分支：任务先调 pad-schedule 判日历，再决定是否跑 pad-sync
        $specArgs = $common.Clone()
        $specArgs.ScriptPath = Join-Path $moduleHere 'pad-schedule.ps1'
        $specArgs.PadSyncPath = [string]$Runtime.PadSyncPath
        $specArgs.PythonExe = [string]$Runtime.PythonExe
        $specArgs.CalendarPath = [string]$Runtime.CalendarPath
        $specArgs.WorkdayScript = [string]$Runtime.WorkdayScript
        if ($Spec.gate -eq 'last-workday') { $specArgs.LastWorkdayGate = $true } else { $specArgs.WorkdayGate = $true }
        return (New-ScheduleActionSpec @specArgs)
    }
    $common.ScriptPath = [string]$Runtime.PadSyncPath
    return (New-ScheduleActionSpec @common)
}

# 任务描述里携带 specHash，用于幂等与回读
function Get-TaskSpecHash([string]$Description) {
    if (-not $Description) { return $null }
    $m = [regex]::Match([string]$Description, 'flow-ir-spec:([0-9a-f]{64})')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# 任务是否与声明一致：描述 hash + 动作可执行文件/参数都要对上
function Test-TriggerTaskMatch {
    param($Task, $ActionSpec, [string]$SpecHash)
    if (-not $Task) { return $false }
    if ((Get-TaskSpecHash ([string]$Task.Description)) -ne $SpecHash) { return $false }
    $action = @($Task.Actions)[0]
    if (-not $action) { return $false }
    return ([string]$action.Execute -eq [string]$ActionSpec.exe -and [string]$action.Arguments -eq [string]$ActionSpec.args)
}

function Assert-TriggerReadback {
    param($Task, $ActionSpec, [string]$SpecHash, [string]$TaskName)
    if (-not $Task) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "注册后回读不到任务：$TaskName")
    }
    if (-not (Test-TriggerTaskMatch $Task $ActionSpec $SpecHash)) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "回读校验失败：任务描述 hash 或动作参数与声明不一致（$TaskName）")
    }
}

function Get-TriggerSummary($Spec) {
    if ($Spec.kind -eq 'manual') { return 'manual（手工或外部链接触发，无需注册）' }
    return "$($Spec.kind) $($Spec.time)（gate=$($Spec.gate)）"
}

# ---- 按 kind 拆分的注册器 ----

function Register-ScheduleTrigger {
    param($Spec, [string]$RuntimeConfigPath, [switch]$DryRun, [switch]$AllowProd)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $actionSpec = Get-TriggerActionSpec -Spec $Spec -Runtime $runtime -AllowProd:$AllowProd
    $hash = Get-TriggerFingerprint -Spec $Spec
    $description = "flow-ir-spec:$hash；flow-ir：$($Spec.kind) $($Spec.time) 触发，运行 PAD 流程 $($Spec.flowName)（attended）"

    if ($DryRun) {
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = 'planned'; dryRun = $true
            description = $description; exe = $actionSpec.exe; args = $actionSpec.args
            evidence = @('DryRun：未写计划任务')
        }
    }

    $existing = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (Test-TriggerTaskMatch $existing $actionSpec $hash) {
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = 'unchanged'; dryRun = $false
            evidence = @('已注册且 specHash 一致，未写系统')
        }
    }
    $changed = $(if ($existing) { 'updated' } else { 'created' })

    try {
        # 与 pad-schedule 完全同形态：隐藏窗口 + Interactive 身份 + 忽略新实例
        if ($Spec.gate -eq 'none') {
            $daysOfWeek = @($Spec.days | ForEach-Object {
                switch ([string]$_) {
                    'mon' { 'Monday' }; 'tue' { 'Tuesday' }; 'wed' { 'Wednesday' }
                    'thu' { 'Thursday' }; 'fri' { 'Friday' }; 'sat' { 'Saturday' }; 'sun' { 'Sunday' }
                }
            })
            $taskTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $daysOfWeek -At (ConvertTo-ScheduleTime $Spec.time)
        } else {
            $taskTrigger = New-ScheduledTaskTrigger -Daily -At (ConvertTo-ScheduleTime $Spec.time)
        }
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 180) -MultipleInstances IgnoreNew
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $Spec.taskName `
            -Action (New-ScheduledTaskAction -Execute $actionSpec.exe -Argument $actionSpec.args) `
            -Trigger $taskTrigger -Settings $settings -Principal $principal `
            -Force -Description $description | Out-Null

        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction Stop
        Assert-TriggerReadback -Task $task -ActionSpec $actionSpec -SpecHash $hash -TaskName $Spec.taskName
        $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
        if (-not $info.NextRunTime) {
            throw (New-TriggerException 'TRIGGER_DRIFT' "任务已注册但没有下次触发时间（$($Spec.taskName)）")
        }
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = $changed; dryRun = $false
            nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('回读校验通过')
        }
    } catch {
        # 注册/回读失败：硬失败并写告警，不做“继续部署”的降级
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_REGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'register' -Status 'failed' `
            -Kind 'trigger-register-failed' `
            -Note ("触发注册失败：$($_.Exception.Message)。下一步：检查计划任务与运行时配置后重新注册。") | Out-Null
        throw
    }
}

function Test-ScheduleTrigger {
    param($Spec, [string]$RuntimeConfigPath)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $actionSpec = Get-TriggerActionSpec -Spec $Spec -Runtime $runtime
    $hash = Get-TriggerFingerprint -Spec $Spec
    $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'not-registered'
            code = 'TRIGGER_NOT_REGISTERED'; message = "本机找不到计划任务 $($Spec.taskName)"
        }
    }
    if (-not (Test-TriggerTaskMatch $task $actionSpec $hash)) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "计划任务与声明不一致（$($Spec.taskName)）"
        }
    }
    $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
    if (-not $info.NextRunTime) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "任务没有下次触发时间（$($Spec.taskName)）"
        }
    }
    return [ordered]@{
        ok = $true; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
        taskName = $Spec.taskName; specHash = $hash; status = 'registered'
        nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('描述 hash 与动作参数均一致')
    }
}

function Unregister-ScheduleTrigger {
    param($Spec, [switch]$DryRun)
    if ($DryRun) {
        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = $(if ($task) { 'planned' } else { 'absent' }); dryRun = $true
            evidence = @('DryRun：未删除计划任务')
        }
    }
    $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'absent'; dryRun = $false; evidence = @('任务本来就不存在')
        }
    }
    try {
        Unregister-ScheduledTask -TaskName $Spec.taskName -Confirm:$false -ErrorAction Stop
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'removed'; dryRun = $false; evidence = @('已删除计划任务')
        }
    } catch {
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_UNREGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'unregister' -Status 'failed' `
            -Kind 'trigger-unregister-failed' `
            -Note ("触发注销失败：$($_.Exception.Message)。下一步：到任务计划程序手动删除 $($Spec.taskName)。") | Out-Null
        throw
    }
}

# file 分支桩：第 4 步实现文件落地注册器
function Register-FileTrigger {
    param($Spec)
    throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' 'file 触发注册器尚未实现（计划在第 4 步落地）')
}
function Test-FileTrigger {
    param($Spec)
    throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' 'file 触发校验器尚未实现（计划在第 4 步落地）')
}
function Unregister-FileTrigger {
    param($Spec)
    throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' 'file 触发注销器尚未实现（计划在第 4 步落地）')
}

# ---- 对外统一入口 ----

function Register-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath,
        [switch]$DryRun,
        [switch]$AllowProd
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; specHash = (Get-TriggerFingerprint -Spec $spec)
                changed = 'unchanged'; dryRun = [bool]$DryRun
                evidence = @('manual 触发无需注册')
            }
        }
        'schedule' { return (Register-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd) }
        'file'     { return (Register-FileTrigger -Spec $spec) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) 不在 manual/schedule/file") }
    }
}

function Test-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'test'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; specHash = (Get-TriggerFingerprint -Spec $spec)
                status = 'manual'; message = 'manual 触发无需注册'
            }
        }
        'schedule' { return (Test-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath) }
        'file'     { return (Test-FileTrigger -Spec $spec) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) 不在 manual/schedule/file") }
    }
}

function Unregister-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    switch ($spec.kind) {
        'manual' {
            return [ordered]@{
                ok = $true; action = 'unregister'; kind = 'manual'; flow = $spec.flowName
                taskName = $null; changed = 'absent'; dryRun = [bool]$DryRun
                evidence = @('manual 触发无需注销')
            }
        }
        'schedule' { return (Unregister-ScheduleTrigger -Spec $spec -DryRun:$DryRun) }
        'file'     { return (Unregister-FileTrigger -Spec $spec) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) 不在 manual/schedule/file") }
    }
}

Export-ModuleMember -Function Get-TriggerSpec, Get-TriggerFingerprint, Register-Trigger, Test-Trigger, Unregister-Trigger
