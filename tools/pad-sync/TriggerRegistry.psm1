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

# 触发声明的取值域，与 pad-admit 的 TRIGGER 检查保持一致
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
    if (-not $FlowFile) { throw (New-TriggerException 'TRIGGER_INPUT_MISSING' 'missing -FlowFile') }
    if (-not (Test-Path -LiteralPath $FlowFile)) {
        throw (New-TriggerException 'TRIGGER_INPUT_MISSING' "flow file not found: $FlowFile")
    }
    try {
        $text = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $FlowFile).Path, [Text.Encoding]::UTF8)
        return ($text | ConvertFrom-Json)
    } catch {
        throw (New-TriggerException 'TRIGGER_INPUT_INVALID' "flow file is not valid JSON: $FlowFile ($($_.Exception.Message))")
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
        throw (New-TriggerException 'TRIGGER_MISSING' 'the flow has no trigger declaration; cannot determine how it starts')
    }
    if (-not (Test-TriggerProp $trg 'kind') -and (Test-TriggerProp $trg 'type')) {
        throw (New-TriggerException 'TRIGGER_LEGACY_SHAPE' 'trigger uses the legacy type/config shape; migrate it to kind')
    }
    if (-not (Test-TriggerProp $trg 'kind') -or -not [string]$trg.kind) {
        throw (New-TriggerException 'TRIGGER_INVALID' 'trigger.kind is missing or not a string')
    }
    $kind = [string]$trg.kind
    if ($script:TriggerReservedKinds -contains $kind) {
        throw (New-TriggerException 'TRIGGER_KIND_UNSUPPORTED' "kind=$kind is a reserved value; v1 has no registrar for it")
    }
    if ($script:TriggerKinds -notcontains $kind) {
        throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$kind is not one of manual/schedule/file")
    }

    # 流程名：优先 PAD 显示名 pad_flow_name，其次内部 name，最后文件名。
    # 任务名与 -FlowName 都从这里派生，两处必须同源：内部名与 PAD 显示名不一致时，
    # 用内部名会派生出错的任务名，pad-sync 也按显示名找不到流程。
    $flowName = $null
    if ((Test-TriggerProp $flow 'pad_flow_name') -and [string]$flow.pad_flow_name) {
        $flowName = [string]$flow.pad_flow_name
    }
    if (-not $flowName -and (Test-TriggerProp $flow 'name') -and [string]$flow.name) {
        $flowName = [string]$flow.name
    }
    if (-not $flowName) { $flowName = [IO.Path]::GetFileNameWithoutExtension((Resolve-Path -LiteralPath $FlowFile).Path) }

    $time = $null
    $days = @('mon', 'tue', 'wed', 'thu', 'fri')
    $daysDeclared = $false
    $gate = 'none'
    $timeoutSec = 4200
    $assisted = $false
    $fileDir = $null
    $filePattern = $null
    # file 触发默认值，与设计稿 2.1 一致；poll 下限 15 秒，避免空转打满磁盘
    $filePollSec = 60
    $fileSettleSec = 60
    $fileMaxWaitSec = 7200
    $fileOncePerFile = $true
    # 声明级提示（warn）：不阻断注册，随 spec 返回给调用方展示
    $triggerWarnings = @()

    if ($kind -eq 'manual') {
        foreach ($k in @('time', 'days', 'gate', 'timeout_sec', 'file', 'assisted')) {
            if (Test-TriggerProp $trg $k) {
                throw (New-TriggerException 'TRIGGER_INVALID' "manual must not declare $k (nothing would execute it)")
            }
        }
    } else {
        if ((Test-TriggerProp $trg 'time')) { $time = [string]$trg.time }
        if (-not $time -or $time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            throw (New-TriggerException 'TRIGGER_INVALID' "time=$time (expected HH:mm, e.g. 09:00)")
        }
        if ((Test-TriggerProp $trg 'days')) {
            $daysDeclared = $true
            $days = @($trg.days)
            $bad = @($days | Where-Object { $script:TriggerDays -notcontains [string]$_ })
            if ($days.Count -eq 0 -or $bad.Count -gt 0) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'days must be a non-empty array with values mon..sun')
            }
        }
        if ((Test-TriggerProp $trg 'gate')) { $gate = [string]$trg.gate }
        if ($script:TriggerGates -notcontains $gate) {
            throw (New-TriggerException 'TRIGGER_INVALID' "gate=$gate is not one of none/workday/last-workday")
        }
        if ((Test-TriggerProp $trg 'timeout_sec')) {
            if (-not (Test-TriggerPositiveInt $trg.timeout_sec)) {
                throw (New-TriggerException 'TRIGGER_INVALID' "timeout_sec=$($trg.timeout_sec) (expected a positive integer number of seconds)")
            }
            $timeoutSec = [int]$trg.timeout_sec
        }
        if ($kind -eq 'file') {
            if (-not (Test-TriggerProp $trg 'file')) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file trigger requires a file object')
            }
            $f = $trg.file
            if (Test-TriggerProp $f 'dir') { $fileDir = [string]$f.dir }
            if (-not $fileDir) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file.dir is required')
            }
            # 只接受配置引用：字面路径在别的机器上无法复用，注册时也解析不了
            if ($fileDir -notmatch '^\{\{config\.(\w+)\}\}$') {
                throw (New-TriggerException 'TRIGGER_PATH_LITERAL' "file.dir must be a {{config.<KEY>}} reference: $fileDir")
            }
            if (Test-TriggerProp $f 'pattern') { $filePattern = [string]$f.pattern }
            if (-not $filePattern -or $filePattern.Trim().Length -eq 0) {
                throw (New-TriggerException 'TRIGGER_INVALID' 'file.pattern is required and must not be empty')
            }
            if (Test-TriggerProp $f 'poll_sec') {
                if (-not (Test-TriggerPositiveInt $f.poll_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.poll_sec=$($f.poll_sec) (expected a positive integer number of seconds)")
                }
                $filePollSec = [int]$f.poll_sec
            }
            if ($filePollSec -lt 15) {
                throw (New-TriggerException 'TRIGGER_INVALID' "file.poll_sec=$filePollSec is below the 15s minimum")
            }
            if (Test-TriggerProp $f 'settle_sec') {
                if (-not (Test-TriggerPositiveInt $f.settle_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.settle_sec=$($f.settle_sec) (expected a positive integer number of seconds)")
                }
                $fileSettleSec = [int]$f.settle_sec
            }
            if (Test-TriggerProp $f 'max_wait_sec') {
                if (-not (Test-TriggerPositiveInt $f.max_wait_sec)) {
                    throw (New-TriggerException 'TRIGGER_INVALID' "file.max_wait_sec=$($f.max_wait_sec) (expected a positive integer number of seconds)")
                }
                $fileMaxWaitSec = [int]$f.max_wait_sec
            }
            if (Test-TriggerProp $f 'once_per_file') {
                if (-not ($f.once_per_file -is [bool])) {
                    throw (New-TriggerException 'TRIGGER_INVALID' 'file.once_per_file must be true/false')
                }
                $fileOncePerFile = [bool]$f.once_per_file
            }
        }
        # assisted：到点自动启动、中途有人确认；必须显式声明 timeout_sec，没人点时靠超时告警兜底
        if (Test-TriggerProp $trg 'assisted') {
            if (-not ($trg.assisted -is [bool])) {
                throw (New-TriggerException 'TRIGGER_INVALID' "assisted=$($trg.assisted) (expected true/false)")
            }
            $assisted = [bool]$trg.assisted
            if ($assisted -and -not (Test-TriggerProp $trg 'timeout_sec')) {
                throw (New-TriggerException 'TRIGGER_ASSISTED_NO_TIMEOUT' `
                    'assisted=true requires an explicit timeout_sec (the timeout alert is the fallback when nobody confirms)')
            }
        }
        # 无人值守触发遇到人工确认节点是硬矛盾；显式 assisted=true 表示中途有人确认，放行
        $confirm = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'run_mode') -and [string]$_.run_mode -eq 'confirm'
        })
        if ($confirm.Count -gt 0 -and -not $assisted) {
            throw (New-TriggerException 'TRIGGER_UNATTENDED_CONFIRM' `
                ("unattended trigger but nodes require manual confirmation: " + (@($confirm | ForEach-Object { $_.id }) -join ',')))
        }
        # 可逆性收窄：与幂等性是两个正交的轴。
        #   idempotent = 同一输入重跑是否收敛（重跑安全）
        #   reversible = 已经产生的后果能否撤回（删除可重建、发信可补正、过账只能冲销）
        # 无人值守只对「后果不可回退」提示，不再由 idempotent=false 触发。
        $irreversible = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'reversible') -and $_.reversible -eq $false
        })
        foreach ($n in $irreversible) {
            $note = $null
            if (Test-TriggerProp $n 'reversibility_note') { $note = [string]$n.reversibility_note }
            $triggerWarnings += [ordered]@{
                code     = 'TRIGGER_UNATTENDED_IRREVERSIBLE'
                message  = "unattended trigger but node $($n.id) has irreversible consequences (reversible=false)"
                evidence = @("node $($n.id) reversible=false" + $(if ($note) { ": $note" } else { '' }))
            }
        }
        # idempotent=false 却没声明 reversible：提示补声明，不默认填充
        $missingRev = @($flow.nodes | Where-Object {
            $_ -and (Test-TriggerProp $_ 'idempotent') -and $_.idempotent -eq $false -and
            -not (Test-TriggerProp $_ 'reversible')
        })
        foreach ($n in $missingRev) {
            $triggerWarnings += [ordered]@{
                code     = 'TRIGGER_MISSING_REVERSIBILITY'
                message  = "node $($n.id) idempotent=false but reversible is not declared"
                evidence = @("node $($n.id) idempotent=false; reversible not declared")
            }
        }
    }

    # 计划任务触发器形态：声明了 days 就按对应星期建 weekly（周末不唤醒，工作日再交日历判断）；
    # file 守望固定 weekly；没声明 days 且带日历门禁时保持旧行为 daily。
    $scheduleKind = $null
    if ($kind -ne 'manual') {
        $scheduleKind = 'daily'
        if ($kind -eq 'file' -or $daysDeclared -or $gate -eq 'none') { $scheduleKind = 'weekly' }
    }

    $taskName = $null
    if ($kind -ne 'manual') {
        if ((Test-TriggerProp $trg 'task_name')) {
            $taskName = [string]$trg.task_name
            if ($taskName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
                throw (New-TriggerException 'TRIGGER_INVALID' "task_name=$taskName does not match ^[A-Za-z0-9._-]{1,64}$")
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
        daysDeclared = $daysDeclared
        scheduleKind = $scheduleKind
        gate         = $gate
        timeoutSec   = $timeoutSec
        assisted     = $assisted
        fileDir      = $fileDir
        filePattern  = $filePattern
        filePollSec  = $filePollSec
        fileSettleSec = $fileSettleSec
        fileMaxWaitSec = $fileMaxWaitSec
        fileOncePerFile = $fileOncePerFile
        # 声明级 warn：调用方可直接展示，不阻断注册
        warnings     = @($triggerWarnings)
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
        # 触发器形态进 hash：显式 days 与未声明 days 的行为不同，不能判成未变更
        scheduleKind = [string]$Spec.scheduleKind
        gate       = [string]$Spec.gate
        timeoutSec = [int]$Spec.timeoutSec
        assisted   = [bool]$Spec.assisted
    }
    if ([string]$Spec.kind -eq 'file') {
        $canon['fileDir'] = [string]$Spec.fileDir
        $canon['filePattern'] = [string]$Spec.filePattern
        $canon['filePollSec'] = [string]$Spec.filePollSec
        $canon['fileSettleSec'] = [string]$Spec.fileSettleSec
        $canon['fileMaxWaitSec'] = [string]$Spec.fileMaxWaitSec
        $canon['fileOncePerFile'] = [string]$Spec.fileOncePerFile
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

# 运行时配置路径：显式 -RuntimeConfigPath 优先；否则只认仓库内唯一的 business\config\runtime.json
# 单独抽出来，file 注册要把真实路径写进任务动作，不能只拿配置对象
function Resolve-TriggerRuntimeConfigPath {
    param([string]$RuntimeConfigPath)
    if ($RuntimeConfigPath) {
        if (-not (Test-Path -LiteralPath $RuntimeConfigPath)) {
            throw (New-TriggerException 'CONFIG_MISSING' "runtime config not found: $RuntimeConfigPath")
        }
        return (Resolve-Path -LiteralPath $RuntimeConfigPath).Path
    }
    $candidate = Join-Path $moduleRepo 'business\config\runtime.json'
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw (New-TriggerException 'CONFIG_MISSING' `
            'missing -RuntimeConfigPath and the repository has no business\config\runtime.json; specify the runtime config explicitly')
    }
    return $candidate
}

function Resolve-TriggerRuntimeConfig {
    param([string]$RuntimeConfigPath)
    $path = Resolve-TriggerRuntimeConfigPath -RuntimeConfigPath $RuntimeConfigPath
    try {
        $cfg = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'CONFIG_INVALID' "runtime config is not valid JSON: $path ($($_.Exception.Message))")
    }
    foreach ($k in @('PadSyncPath', 'PythonExe', 'CalendarPath', 'WorkdayScript', 'RunTimeoutSec')) {
        if (-not (Test-TriggerProp $cfg $k) -or -not [string]$cfg.$k) {
            throw (New-TriggerException 'CONFIG_MISSING' "runtime config is missing $k ($path)")
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

# 任务是否与声明一致：描述 hash + 动作可执行文件/参数都要对上。
# -AllowProd 是注册时的调用开关，不在 trigger 的 canonical 指纹里；
# -Test 只核对声明一致性，忽略该 token，否则生产任务永远被判 drift。
# 注册/回读仍严格比较，防止漏掉 -AllowProd 后任务在生产里拒绝运行。
function Test-TriggerTaskMatch {
    param($Task, $ActionSpec, [string]$SpecHash, [switch]$IgnoreAllowProd)
    if (-not $Task) { return $false }
    if ((Get-TaskSpecHash ([string]$Task.Description)) -ne $SpecHash) { return $false }
    $action = @($Task.Actions)[0]
    if (-not $action) { return $false }
    $expected = [string]$ActionSpec.args
    $actual = [string]$action.Arguments
    if ($IgnoreAllowProd) {
        $stripped = { param($s) ([regex]::Replace([string]$s, '\s+-AllowProd(?=\s|$)', '')).Trim() }
        $expected = (& $stripped $expected)
        $actual = (& $stripped $actual)
    }
    return ([string]$action.Execute -eq [string]$ActionSpec.exe -and $actual -eq $expected)
}

function Assert-TriggerReadback {
    param($Task, $ActionSpec, [string]$SpecHash, [string]$TaskName)
    if (-not $Task) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "task not found on readback after registration: $TaskName")
    }
    if (-not (Test-TriggerTaskMatch $Task $ActionSpec $SpecHash)) {
        throw (New-TriggerException 'TRIGGER_DRIFT' "readback check failed: the task description hash or action arguments disagree with the declaration ($TaskName)")
    }
}

function Get-TriggerSummary($Spec) {
    if ($Spec.kind -eq 'manual') { return 'manual (started by hand or an external link; no registration needed)' }
    if ($Spec.kind -eq 'file') {
        return "file $($Spec.fileDir)\$($Spec.filePattern) (watching from $($Spec.time) for $($Spec.fileMaxWaitSec)s)"
    }
    return "$($Spec.kind) $($Spec.time) (gate=$($Spec.gate))"
}

# ---- file 分支的只读配置解析与目录探测 ----

# 解析 {{config.<KEY>}}：只读，不碰 PadConfig 的固定键集与校验口径。
# 允许流程配置里出现任意业务键（PadConfig 管不到的键），解析不了就硬失败，绝不退回字面路径。
function Resolve-TriggerConfigRef {
    param([string]$Token, [string]$ConfigFile)
    if (-not $Token) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' 'file.dir is empty; cannot resolve it')
    }
    $m = [regex]::Match([string]$Token, '^\{\{config\.(\w+)\}\}$')
    if (-not $m.Success) {
        throw (New-TriggerException 'TRIGGER_PATH_LITERAL' "file.dir must be a {{config.<KEY>}} reference: $Token")
    }
    $key = $m.Groups[1].Value
    if (-not $ConfigFile) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "missing -ConfigFile; cannot resolve {{config.$key}}")
    }
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config file not found: $ConfigFile")
    }
    try {
        $cfg = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigFile).Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config file is not valid JSON: $ConfigFile ($($_.Exception.Message))")
    }
    if (-not (Test-TriggerProp $cfg $key) -or -not [string]$cfg.$key) {
        throw (New-TriggerException 'TRIGGER_CONFIG_UNRESOLVED' "config has no usable key $key ($ConfigFile)")
    }
    return [string]$cfg.$key
}

# 列候选：目录/权限问题一律抛 TRIGGER_FILE_DIR_UNREADABLE，不猜
function Get-TriggerFileCandidates {
    param([string]$Dir, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw (New-TriggerException 'TRIGGER_FILE_DIR_UNREADABLE' "watch directory not found: $Dir")
    }
    try {
        return @(Get-ChildItem -LiteralPath $Dir -Filter $Pattern -File -ErrorAction Stop)
    } catch {
        throw (New-TriggerException 'TRIGGER_FILE_DIR_UNREADABLE' "watch directory is unreadable: $Dir ($($_.Exception.Message))")
    }
}

# 状态目录：运行时配置可选 TriggerStateDir；默认 business\state\triggers（业务区，已被 gitignore）
function Resolve-TriggerStateDir($Runtime) {
    if ($Runtime -and (Test-TriggerProp $Runtime 'TriggerStateDir') -and [string]$Runtime.TriggerStateDir) {
        return [string]$Runtime.TriggerStateDir
    }
    return (Join-Path $moduleRepo 'business\state\triggers')
}

# 找到最深的已存在祖先：目录尚未创建时，只探测其父目录是否可写
function Get-TriggerExistingAncestor([string]$Path) {
    $cur = $Path
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
        $parent = Split-Path -Parent $cur
        if (-not $parent -or $parent -eq $cur) { return $null }
        $cur = $parent
    }
    return $cur
}

# 可写性探测：只读 ACL，不写探针文件。按当前用户 SID 及其所属组匹配 Allow 规则
function Test-TriggerDirWritable([string]$Path) {
    $target = Get-TriggerExistingAncestor $Path
    if (-not $target) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $false }
        $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $mySid = $identity.User.Value
        $groupSids = @($identity.Groups | ForEach-Object { $_.Value })
        foreach ($rule in $acl.Access) {
            if ([string]$rule.AccessControlType -ne 'Allow') { continue }
            try { $ruleSid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch { continue }
            if ($ruleSid -ne $mySid -and $groupSids -notcontains $ruleSid) { continue }
            if ([string]$rule.FileSystemRights -match 'Write|Modify|FullControl|CreateFiles') { return $true }
        }
        return $false
    } catch {
        return $false
    }
}

# ---- file 分支的运行层：状态账本与守望 ----

# 账本键：fileName|size|lastWriteUtc，同一文件（含内容未变）只触发一次
function Get-TriggerFileKey($File) {
    return ('{0}|{1}|{2}' -f $File.Name, $File.Length, $File.LastWriteTimeUtc.ToString('o'))
}

function Get-TriggerLedgerPath($Spec, $Runtime) {
    $dir = Resolve-TriggerStateDir $Runtime
    return (Join-Path $dir ($Spec.taskName + '.json'))
}

# 读账本：文件不存在视为空；存在但不是合法 JSON 就硬失败，避免把历史丢失去重
function Read-TriggerLedger([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        throw (New-TriggerException 'TRIGGER_LEDGER_INVALID' "state ledger is not valid JSON: $Path ($($_.Exception.Message))")
    }
    if (-not (Test-TriggerProp $json 'keys')) { return @() }
    return @($json.keys | ForEach-Object { [string]$_ })
}

# 追加键：已在账本里返回 $false（重复投放，不再触发）；新增返回 $true
function Add-TriggerLedgerKey([string]$Path, [string]$Key) {
    $keys = @(Read-TriggerLedger $Path)
    if ($keys -contains $Key) { return $false }
    $keys += $Key
    # 只保留最近 200 条，避免账本无限增长
    if ($keys.Count -gt 200) { $keys = @($keys[($keys.Count - 200)..($keys.Count - 1)]) }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $obj = [ordered]@{ keys = $keys; updatedAt = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 4),
        (New-Object Text.UTF8Encoding($false)))
    return $true
}

# ---- 按 kind 拆分的注册器 ----

# 计划任务设置：显式关闭 StartWhenAvailable，不依赖模板默认值。
# 原因：机器休眠/关机期间错过的触发（例如周末两次 09:00）会在恢复后立刻补跑，
# 日历门禁只判断“今天是否工作日”，识别不出这是遗失实例，导致计划外执行。
# 取舍：9:00 时机器没开着，当天就不跑，宁可漏跑也不早跑。
function New-ScheduleTaskSettings {
    param([int]$ExecutionTimeLimitMinutes)
    return (New-ScheduledTaskSettingsSet -StartWhenAvailable:$false `
        -ExecutionTimeLimit (New-TimeSpan -Minutes $ExecutionTimeLimitMinutes) -MultipleInstances IgnoreNew)
}

# 任务触发器形态：weekly 按声明/默认的星期建；daily 保持每天唤醒、由日历门禁自行跳过
function New-ScheduleTaskTrigger($Spec) {
    if ([string]$Spec.scheduleKind -eq 'weekly') {
        $dayMap = @{
            mon = 'Monday'; tue = 'Tuesday'; wed = 'Wednesday'; thu = 'Thursday'
            fri = 'Friday'; sat = 'Saturday'; sun = 'Sunday'
        }
        $daysOfWeek = @($Spec.days | ForEach-Object { $dayMap[[string]$_] })
        return (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $daysOfWeek -At (ConvertTo-ScheduleTime $Spec.time))
    }
    return (New-ScheduledTaskTrigger -Daily -At (ConvertTo-ScheduleTime $Spec.time))
}

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
            evidence = @('DryRun: scheduled task not written')
        }
    }

    $existing = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (Test-TriggerTaskMatch $existing $actionSpec $hash) {
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = 'unchanged'; dryRun = $false
            evidence = @('already registered with a matching specHash; nothing written')
        }
    }
    $changed = $(if ($existing) { 'updated' } else { 'created' })

    try {
        # 与 pad-schedule 完全同形态：隐藏窗口 + Interactive 身份 + 忽略新实例
        $taskTrigger = New-ScheduleTaskTrigger $Spec
        $settings = New-ScheduleTaskSettings -ExecutionTimeLimitMinutes 180
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $Spec.taskName `
            -Action (New-ScheduledTaskAction -Execute $actionSpec.exe -Argument $actionSpec.args) `
            -Trigger $taskTrigger -Settings $settings -Principal $principal `
            -Force -Description $description | Out-Null

        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction Stop
        Assert-TriggerReadback -Task $task -ActionSpec $actionSpec -SpecHash $hash -TaskName $Spec.taskName
        $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
        if (-not $info.NextRunTime) {
            throw (New-TriggerException 'TRIGGER_DRIFT' "task is registered but has no next run time ($($Spec.taskName))")
        }
        return [ordered]@{
            ok = $true; action = 'register'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = $changed; dryRun = $false
            nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('readback check passed')
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
            code = 'TRIGGER_NOT_REGISTERED'; message = "scheduled task $($Spec.taskName) not found on this machine"
        }
    }
    if (-not (Test-TriggerTaskMatch $task $actionSpec $hash -IgnoreAllowProd)) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "scheduled task disagrees with the declaration ($($Spec.taskName))"
        }
    }
    $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
    if (-not $info.NextRunTime) {
        return [ordered]@{
            ok = $false; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; status = 'drift'
            code = 'TRIGGER_DRIFT'; message = "task has no next run time ($($Spec.taskName))"
        }
    }
    return [ordered]@{
        ok = $true; action = 'test'; kind = $Spec.kind; flow = $Spec.flowName
        taskName = $Spec.taskName; specHash = $hash; status = 'registered'
        nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('description hash and action arguments match')
    }
}

function Unregister-ScheduleTrigger {
    param($Spec, [switch]$DryRun)
    if ($DryRun) {
        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = $(if ($task) { 'planned' } else { 'absent' }); dryRun = $true
            evidence = @('DryRun: scheduled task not deleted')
        }
    }
    $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
    if (-not $task) {
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'absent'; dryRun = $false; evidence = @('the task did not exist')
        }
    }
    try {
        Unregister-ScheduledTask -TaskName $Spec.taskName -Confirm:$false -ErrorAction Stop
        return [ordered]@{
            ok = $true; action = 'unregister'; kind = $Spec.kind; flow = $Spec.flowName
            taskName = $Spec.taskName; changed = 'removed'; dryRun = $false; evidence = @('scheduled task deleted')
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

# file 任务动作：到点调用 pad-trigger.ps1 -Watch，启动方式与 pad-schedule 同形态
function Get-FileWatchActionSpec {
    param($Spec, [string]$PadTriggerPath, [string]$RuntimeConfigPath, [switch]$AllowProd)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $PadTriggerPath + '"'),
        '-Watch',
        '-FlowFile', ('"' + $Spec.flowFile + '"'))
    if ($Spec.configFile) {
        $argList += @('-ConfigFile', ('"' + (Resolve-Path -LiteralPath $Spec.configFile).Path + '"'))
    }
    if ($RuntimeConfigPath) {
        $argList += @('-RuntimeConfigPath', ('"' + $RuntimeConfigPath + '"'))
    }
    if ($AllowProd) { $argList += '-AllowProd' }
    $vbsArgs = '//nologo "' + $script:HiddenLauncher + '" "powershell.exe" ' + ($argList -join ' ')
    return [ordered]@{ exe = 'wscript.exe'; args = $vbsArgs }
}

# 注册 file 触发：注册/测试时就把 {{config.<KEY>}} 解析成真实路径，解析不了直接硬失败
function Register-FileTrigger {
    param($Spec, [string]$RuntimeConfigPath, [switch]$DryRun, [switch]$AllowProd)
    try {
        $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
        $runtimePath = Resolve-TriggerRuntimeConfigPath -RuntimeConfigPath $RuntimeConfigPath
        $dir = Resolve-TriggerConfigRef -Token $Spec.fileDir -ConfigFile $Spec.configFile
        $candidates = @(Get-TriggerFileCandidates -Dir $dir -Pattern $Spec.filePattern)
        if ($candidates.Count -ge 2) {
            $names = (@($candidates | ForEach-Object { $_.Name }) -join ', ')
            throw (New-TriggerException 'TRIGGER_FILE_AMBIGUOUS' `
                "watch directory has $($candidates.Count) candidate files ($names); this will not guess 'latest', clean up the directory first")
        }
        $stateDir = Resolve-TriggerStateDir $runtime
        if (-not (Test-TriggerDirWritable $stateDir)) {
            throw (New-TriggerException 'TRIGGER_STATE_DIR_UNWRITABLE' "state ledger directory is not writable: $stateDir")
        }
        $actionSpec = Get-FileWatchActionSpec -Spec $Spec `
            -PadTriggerPath (Join-Path $moduleHere 'pad-trigger.ps1') `
            -RuntimeConfigPath $runtimePath -AllowProd:$AllowProd
        $hash = Get-TriggerFingerprint -Spec $Spec
        $description = "flow-ir-spec:$hash；flow-ir：file $dir\$($Spec.filePattern) 守望，运行 PAD 流程 $($Spec.flowName)（attended）"

        if ($DryRun) {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
                taskName = $Spec.taskName; specHash = $hash; changed = 'planned'; dryRun = $true
                dir = $dir; pattern = $Spec.filePattern; description = $description
                exe = $actionSpec.exe; args = $actionSpec.args
                stateDir = $stateDir
                evidence = @('DryRun: scheduled task not written, state directory not created')
            }
        }

        # 真实注册前才建状态目录；Test/DryRun 一律不写
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        $existing = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction SilentlyContinue
        if (Test-TriggerTaskMatch $existing $actionSpec $hash) {
            return [ordered]@{
                ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
                taskName = $Spec.taskName; specHash = $hash; changed = 'unchanged'; dryRun = $false
                evidence = @('already registered with a matching specHash; nothing written')
            }
        }
        $changed = $(if ($existing) { 'updated' } else { 'created' })

        # 与 schedule 分支同形态：周几 + 起始时刻；执行上限覆盖整段守望
        $taskTrigger = New-ScheduleTaskTrigger $Spec
        $limitMin = [math]::Max(180, [math]::Ceiling(([double]$Spec.fileMaxWaitSec + 300) / 60))
        $settings = New-ScheduleTaskSettings -ExecutionTimeLimitMinutes $limitMin
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $Spec.taskName `
            -Action (New-ScheduledTaskAction -Execute $actionSpec.exe -Argument $actionSpec.args) `
            -Trigger $taskTrigger -Settings $settings -Principal $principal `
            -Force -Description $description | Out-Null

        $task = Get-ScheduledTask -TaskName $Spec.taskName -ErrorAction Stop
        Assert-TriggerReadback -Task $task -ActionSpec $actionSpec -SpecHash $hash -TaskName $Spec.taskName
        $info = Get-ScheduledTaskInfo -TaskName $Spec.taskName
        if (-not $info.NextRunTime) {
            throw (New-TriggerException 'TRIGGER_DRIFT' "task is registered but has no next run time ($($Spec.taskName))")
        }
        return [ordered]@{
            ok = $true; action = 'register'; kind = 'file'; flow = $Spec.flowName
            taskName = $Spec.taskName; specHash = $hash; changed = $changed; dryRun = $false
            dir = $dir; pattern = $Spec.filePattern; stateDir = $stateDir
            nextRunTime = $info.NextRunTime.ToString('o'); evidence = @('readback check passed')
        }
    } catch {
        if (-not $_.Exception.Data.Contains('code')) {
            $_.Exception.Data['code'] = 'TRIGGER_REGISTER_FAILED'
        }
        Write-RunAlert -FlowName $Spec.flowName -ExitCode 1 -Stage 'register' -Status 'failed' `
            -Kind 'trigger-register-failed' `
            -Note ("file 触发注册失败：$($_.Exception.Message)。下一步：修正监听目录/配置后重新注册。") | Out-Null
        throw
    }
}

# -Test 只读：目录可读、候选 0/1、状态目录可写；≥2 直接判歧义，不做取最新
function Test-FileTrigger {
    param($Spec, [string]$RuntimeConfigPath)
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $dir = Resolve-TriggerConfigRef -Token $Spec.fileDir -ConfigFile $Spec.configFile
    $candidates = @(Get-TriggerFileCandidates -Dir $dir -Pattern $Spec.filePattern)
    $stateDir = Resolve-TriggerStateDir $runtime
    $hash = Get-TriggerFingerprint -Spec $Spec
    $candidateNames = @($candidates | ForEach-Object { $_.Name })
    $base = [ordered]@{
        action = 'test'; kind = 'file'; flow = $Spec.flowName; taskName = $Spec.taskName
        specHash = $hash; dir = $dir; pattern = $Spec.filePattern; stateDir = $stateDir
        candidates = $candidateNames
    }
    if ($candidates.Count -ge 2) {
        $base.ok = $false; $base.status = 'ambiguous'; $base.code = 'TRIGGER_FILE_AMBIGUOUS'
        $base.message = "watch directory has $($candidates.Count) candidate files ($($candidateNames -join ', ')); this will not guess 'latest'"
        return $base
    }
    if (-not (Test-TriggerDirWritable $stateDir)) {
        $base.ok = $false; $base.status = 'state-unwritable'; $base.code = 'TRIGGER_STATE_DIR_UNWRITABLE'
        $base.message = "state ledger directory is not writable: $stateDir"
        return $base
    }
    $base.ok = $true; $base.status = 'ready'
    $base.message = "watch directory is readable with $($candidates.Count) candidate(s); the state ledger directory is writable"
    return $base
}

# 注销只动计划任务；状态账本保留，便于排查历史触发
function Unregister-FileTrigger {
    param($Spec, [switch]$DryRun)
    return (Unregister-ScheduleTrigger -Spec $Spec -DryRun:$DryRun)
}

# 守望：到点轮询候选，落盘稳定后调用现有 pad-sync -RunOnly，不新开运行入口
function Invoke-TriggerWatch {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [string]$RuntimeConfigPath,
        [switch]$AllowProd
    )
    $spec = Get-TriggerSpec -FlowFile $FlowFile -ConfigFile $ConfigFile
    if ($spec.kind -ne 'file') {
        throw (New-TriggerException 'TRIGGER_INVALID' "-Watch only applies to file triggers (current kind=$($spec.kind))")
    }
    $runtime = Resolve-TriggerRuntimeConfig -RuntimeConfigPath $RuntimeConfigPath
    $dir = Resolve-TriggerConfigRef -Token $spec.fileDir -ConfigFile $ConfigFile
    $stateDir = Resolve-TriggerStateDir $runtime
    if (-not (Test-TriggerDirWritable $stateDir)) {
        Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'trigger' -Status 'failed' `
            -Kind 'trigger-failed' `
            -Note ("状态账本目录不可写：$stateDir。下一步：修正目录权限或配置后人工重跑。") | Out-Null
        throw (New-TriggerException 'TRIGGER_STATE_DIR_UNWRITABLE' "state ledger directory is not writable: $stateDir")
    }
    $ledger = Get-TriggerLedgerPath -Spec $spec -Runtime $runtime
    $padSyncPath = [string]$runtime.PadSyncPath

    $base = [ordered]@{
        ok = $false; action = 'watch'; kind = 'file'; flow = $spec.flowName
        taskName = $spec.taskName; dir = $dir; pattern = $spec.filePattern
        status = 'waiting'; triggeredFileName = $null
        pollSec = $spec.filePollSec; settleSec = $spec.fileSettleSec; maxWaitSec = $spec.fileMaxWaitSec
        ledgerPath = $ledger; evidence = @()
    }
    $start = Get-Date
    $candidateKey = $null
    $candidateSince = $null

    while ($true) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        # 到点静默退出 0：没等到文件不算失败
        if ($elapsed -ge $spec.fileMaxWaitSec) {
            $base.ok = $true; $base.status = 'timeout'
            $base.evidence = @("exceeded max_wait_sec=$($spec.fileMaxWaitSec); exiting silently with 0")
            return $base
        }
        $files = @(Get-TriggerFileCandidates -Dir $dir -Pattern $spec.filePattern)
        if ($files.Count -ge 2) {
            $names = (@($files | ForEach-Object { $_.Name }) -join ', ')
            Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'trigger' -Status 'failed' `
                -Kind 'trigger-failed' `
                -Note ("监听目录出现 $($files.Count) 个候选文件（$names），不做取最新猜测，本次未触发。下一步：清理目录后人工重跑。") | Out-Null
            throw (New-TriggerException 'TRIGGER_FILE_AMBIGUOUS' `
                "watch directory has $($files.Count) candidate files ($names); this will not guess 'latest'")
        }

        if ($files.Count -eq 1) {
            $f = $files[0]
            $key = Get-TriggerFileKey $f
            if ($key -eq $candidateKey) {
                # 连续两次轮询键不变且超过 settle_sec：认为落盘完成
                if (((Get-Date) - $candidateSince).TotalSeconds -ge $spec.fileSettleSec) {
                    if ($spec.fileOncePerFile) {
                        $isNew = Add-TriggerLedgerKey -Path $ledger -Key $key
                    } else {
                        $isNew = $true
                    }
                    if ($isNew) {
                        # 复用现有入口：pad-sync -RunOnly -AllowProd -NonInteractive
                        $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', ('"' + $padSyncPath + '"'),
                            '-FlowName', ('"' + $spec.flowName + '"'),
                            '-FlowFile', ('"' + $spec.flowFile + '"'),
                            '-RunOnly', '-NonInteractive')
                        if ($spec.configFile) {
                            $syncArgs += @('-ConfigFile', ('"' + (Resolve-Path -LiteralPath $spec.configFile).Path + '"'))
                        }
                        if ($AllowProd) { $syncArgs += '-AllowProd' }
                        $syncOut = & powershell @syncArgs 2>&1 | Out-String
                        if ($LASTEXITCODE -ne 0) {
                            Write-RunAlert -FlowName $spec.flowName -ExitCode 1 -Stage 'run' -Status 'failed' `
                                -Kind 'trigger-failed' `
                                -Note ("file 触发后 pad-sync 退出码 $LASTEXITCODE。下一步：查看 PAD 控制台与运行日志后人工重跑，未自动重试。") | Out-Null
                            throw (New-TriggerException 'TRIGGER_WATCH_RUN_FAILED' `
                                "pad-sync exit code $LASTEXITCODE (file $($f.Name))")
                        }
                        $base.ok = $true; $base.status = 'triggered'; $base.triggeredFileName = $f.Name
                        $base.evidence = @("triggered: $($f.Name) (size $($f.Length))", "ledger: $ledger")
                        return $base
                    }
                    # 同一文件已触发过：不重复触发，继续等其它文件
                    $note = "this file was already triggered earlier; skipping: $($f.Name)"
                    if ($base.evidence -notcontains $note) { $base.evidence += $note }
                }
            } else {
                # 新候选或大小/时间变了：重新开始稳定计时
                $candidateKey = $key
                $candidateSince = Get-Date
            }
        } else {
            $candidateKey = $null
            $candidateSince = $null
        }

        $remaining = $spec.fileMaxWaitSec - ((Get-Date) - $start).TotalSeconds
        if ($remaining -le 0) { continue }
        $sleepSec = [math]::Min([double]$spec.filePollSec, [math]::Max(1.0, $remaining))
        Start-Sleep -Seconds $sleepSec
    }
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
                evidence = @('manual triggers need no registration')
            }
        }
        'schedule' { return (Register-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd) }
        'file'     { return (Register-FileTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
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
                status = 'manual'; message = 'manual triggers need no registration'
            }
        }
        'schedule' { return (Test-ScheduleTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath) }
        'file'     { return (Test-FileTrigger -Spec $spec -RuntimeConfigPath $RuntimeConfigPath) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
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
                evidence = @('manual triggers need no unregistration')
            }
        }
        'schedule' { return (Unregister-ScheduleTrigger -Spec $spec -DryRun:$DryRun) }
        'file'     { return (Unregister-FileTrigger -Spec $spec -DryRun:$DryRun) }
        default    { throw (New-TriggerException 'TRIGGER_UNKNOWN_KIND' "kind=$($spec.kind) is not one of manual/schedule/file") }
    }
}

Export-ModuleMember -Function Get-TriggerSpec, Get-TriggerFingerprint, Register-Trigger, Test-Trigger, Unregister-Trigger, Invoke-TriggerWatch
