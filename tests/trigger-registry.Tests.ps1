# trigger-registry.Tests.ps1 — 触发注册器纯函数与只读性测试（Pester 3.4）
#
# 覆盖：spec 解析、幂等 hash 稳定性、动作构造复用 pad-schedule、
#       任务匹配与回读校验、DryRun/Test 只读、file/未知 kind 拒绝、CLI 退出码。
# 全程不注册、不删除任何真实计划任务。

Import-Module (Join-Path $PSScriptRoot '..\tools\pad-sync\TriggerRegistry.psm1') -Force
$script:TriggerModule = Get-Module TriggerRegistry
$script:TriggerCli = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-trigger.ps1'
# 只用于断言“不存在”的任务名，故意带 do-not-register 前缀
$script:UniqueTask = 'flow-ir-trigger-pester-do-not-register'

# 写入一份最小流程；trigger 用传入的声明，节点只有一条占位
function New-TestFlow {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Trigger,
        [string]$NodeRunMode = 'auto',
        # 追加到占位节点的声明字段（幂等/可逆性用例用）
        [hashtable]$NodeProps = @{},
        # PAD 显示名：与内部 name 不同，用于验证任务名/-FlowName 的派生口径
        [string]$PadFlowName
    )
    $node = [ordered]@{ id = '1'; pad_hint = 'Comment.Comment'; run_mode = $NodeRunMode }
    foreach ($k in $NodeProps.Keys) { $node[$k] = $NodeProps[$k] }
    $obj = [ordered]@{
        name = 'PESTER_TRIGGER'
        trigger = $Trigger
        nodes = @($node)
    }
    if ($PadFlowName) { $obj['pad_flow_name'] = $PadFlowName }
    $path = Join-Path $Dir ($Name + '.json')
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 8),
        (New-Object Text.UTF8Encoding($false)))
    return $path
}

# 运行时配置：路径只需是字符串，DryRun 与 Test 都不会真的执行它们
function New-TestRuntime {
    param([Parameter(Mandatory)][string]$Dir)
    $cfg = [ordered]@{
        PadSyncPath   = 'C:\tmp\pad-sync.ps1'
        PythonExe     = 'python'
        CalendarPath  = 'C:\tmp\workday-calendar.xlsx'
        WorkdayScript = 'C:\tmp\workday.py'
        RunTimeoutSec = 4200
    }
    $path = Join-Path $Dir 'runtime.json'
    [IO.File]::WriteAllText($path, ($cfg | ConvertTo-Json),
        (New-Object Text.UTF8Encoding($false)))
    return $path
}

# 取抛出的结果码；没抛异常返回 NO_ERROR
function Get-TriggerErrorCode {
    param([scriptblock]$Action)
    try {
        & $Action | Out-Null
        return 'NO_ERROR'
    } catch {
        if ($_.Exception.Data.Contains('code')) { return [string]$_.Exception.Data['code'] }
        return 'UNKNOWN'
    }
}

# 本机是否存在该计划任务（只读）
function Test-TaskAbsent([string]$TaskName) {
    return (@(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue).Count -eq 0)
}

Describe 'TriggerRegistry 声明解析' {

    It 'schedule 声明：解析出 kind/time/days/gate/timeout/taskName' {
        $t = [ordered]@{
            kind = 'schedule'; time = '09:00'
            days = @('mon', 'tue', 'wed', 'thu', 'fri')
            gate = 'workday'; timeout_sec = 4200; task_name = $script:UniqueTask
        }
        $f = New-TestFlow -Dir $TestDrive -Name 'schedule-full' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.kind | Should Be 'schedule'
        $spec.time | Should Be '09:00'
        (@($spec.days) -join ',') | Should Be 'mon,tue,wed,thu,fri'
        $spec.gate | Should Be 'workday'
        $spec.timeoutSec | Should Be 4200
        $spec.taskName | Should Be $script:UniqueTask
    }

    It 'schedule 未写 task_name：按 flow-ir-<流程名> 派生' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'PESTER_DERIVE' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.taskName | Should Be 'flow-ir-PESTER_TRIGGER'
    }

    It 'manual 声明：不产生任务名，默认值齐全' {
        $t = [ordered]@{ kind = 'manual' }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.kind | Should Be 'manual'
        ($null -eq $spec.taskName) | Should Be $true
        $spec.timeoutSec | Should Be 4200
    }

    It 'manual 声明 time 被拒：TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'manual'; time = '09:00' }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual-bad' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It 'schedule 缺 time 被拒：TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'schedule'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'schedule-no-time' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It '无人值守声明遇到 run_mode=confirm 节点被拒：TRIGGER_UNATTENDED_CONFIRM' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'schedule-confirm' -Trigger $t -NodeRunMode 'confirm'
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_UNATTENDED_CONFIRM'
    }

    It 'assisted=true 遇到 confirm 节点放行：NO_ERROR' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'
            timeout_sec = 4200; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-ok' -Trigger $t -NodeRunMode 'confirm'
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'NO_ERROR'
    }

    It 'assisted 缺 timeout_sec 被拒：TRIGGER_ASSISTED_NO_TIMEOUT' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-no-timeout' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_ASSISTED_NO_TIMEOUT'
    }

    It 'manual 声明 assisted 被拒：TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'manual'; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual-assisted' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It 'assisted 非布尔被拒：TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'
            timeout_sec = 4200; assisted = 'yes' }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-not-bool' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }
}

Describe 'TriggerRegistry 可逆性交叉校验（收窄后）' {

    It '节点全是 reversible=true：warnings 里没有可逆性提示' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-all-true' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $true }
        $spec = Get-TriggerSpec -FlowFile $f
        @($spec.warnings).Count | Should Be 0
    }

    It '存在 reversible=false：warnings 含 TRIGGER_UNATTENDED_IRREVERSIBLE（带节点与说明）' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-false' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $false; reversibility_note = '邮件已发出不可撤回' }
        $spec = Get-TriggerSpec -FlowFile $f
        $codes = @($spec.warnings | ForEach-Object { $_.code })
        ($codes -join ',') | Should Match 'TRIGGER_UNATTENDED_IRREVERSIBLE'
        (@($spec.warnings | Where-Object { $_.code -eq 'TRIGGER_UNATTENDED_IRREVERSIBLE' })[0].evidence -join ' ') |
            Should Match '邮件已发出不可撤回'
    }

    It 'idempotent=false 缺 reversible：warnings 含 TRIGGER_MISSING_REVERSIBILITY' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-missing' -Trigger $t `
            -NodeProps @{ idempotent = $false }
        $spec = Get-TriggerSpec -FlowFile $f
        $codes = @($spec.warnings | ForEach-Object { $_.code })
        ($codes -join ',') | Should Match 'TRIGGER_MISSING_REVERSIBILITY'
    }

    It 'manual：即使 reversible=false 也不产生可逆性提示' {
        $t = [ordered]@{ kind = 'manual' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-manual' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $false }
        $spec = Get-TriggerSpec -FlowFile $f
        @($spec.warnings).Count | Should Be 0
    }
}

Describe 'TriggerRegistry 指纹与幂等' {

    It 'hash 稳定：重复计算一致，且与 trigger 字段书写顺序无关' {
        $t1 = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('mon', 'fri'); gate = 'workday' }
        $t2 = [ordered]@{ time = '09:00'; gate = 'workday'; days = @('mon', 'fri'); kind = 'schedule' }
        $f1 = New-TestFlow -Dir $TestDrive -Name 'hash-a' -Trigger $t1
        $f2 = New-TestFlow -Dir $TestDrive -Name 'hash-b' -Trigger $t2
        $s1 = Get-TriggerSpec -FlowFile $f1
        $s2 = Get-TriggerSpec -FlowFile $f2
        $h1 = Get-TriggerFingerprint -Spec $s1
        (Get-TriggerFingerprint -Spec $s1) | Should Be $h1
        # 流程名由 JSON 的 name 统一给出，字段顺序差异不影响规范哈希
        (Get-TriggerFingerprint -Spec $s2) | Should Be $h1
        $h1.Length | Should Be 64
    }

    It 'hash 随声明变化：改 time 或 gate 都会得到新 hash' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('mon'); gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'hash-c' -Trigger $t
        $base = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f)
        $t2 = [ordered]@{ kind = 'schedule'; time = '10:00'; days = @('mon'); gate = 'none' }
        $f2 = New-TestFlow -Dir $TestDrive -Name 'hash-d' -Trigger $t2
        $s2 = Get-TriggerSpec -FlowFile $f2
        (Get-TriggerFingerprint -Spec $s2) | Should Not Be $base
    }

    It 'assisted 进入 specHash：改它 hash 必变' {
        $t1 = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('mon'); gate = 'none'
            timeout_sec = 4200; assisted = $false }
        $t2 = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('mon'); gate = 'none'
            timeout_sec = 4200; assisted = $true }
        $f1 = New-TestFlow -Dir $TestDrive -Name 'hash-assisted-a' -Trigger $t1
        $f2 = New-TestFlow -Dir $TestDrive -Name 'hash-assisted-b' -Trigger $t2
        $h1 = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f1)
        $h2 = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f2)
        $h1.Length | Should Be 64
        $h2 | Should Not Be $h1
    }

    It '描述前缀能取出 hash，非法描述返回空' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'desc' -Trigger $t
        $hash = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f)
        $got = & $script:TriggerModule {
            param($desc)
            Get-TaskSpecHash $desc
        } ("flow-ir-spec:$hash；flow-ir：说明")
        $got | Should Be $hash
        $empty = & $script:TriggerModule {
            param($desc)
            Get-TaskSpecHash $desc
        } ('没有 spec 前缀')
        ($null -eq $empty) | Should Be $true
    }

    It '动作构造复用 pad-schedule：gate=workday 走 run-hidden.vbs + -RunIfWorkday' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = New-TestFlow -Dir $TestDrive -Name 'action-workday' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $runtime = New-TestRuntime -Dir $TestDrive
        $action = & $script:TriggerModule {
            param($Spec, $RuntimePath)
            $rt = [IO.File]::ReadAllText($RuntimePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Get-TriggerActionSpec -Spec $Spec -Runtime $rt
        } $spec $runtime
        $action.exe | Should Be 'wscript.exe'
        $action.args | Should Match 'run-hidden\.vbs'
        $action.args | Should Match 'powershell\.exe'
        $action.args | Should Match '-RunIfWorkday'
        $action.args | Should Not Match 'RunOnly'
    }

    It '动作构造复用 pad-schedule：gate=none 直接调 pad-sync -RunOnly' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'action-none' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $runtime = New-TestRuntime -Dir $TestDrive
        $action = & $script:TriggerModule {
            param($Spec, $RuntimePath)
            $rt = [IO.File]::ReadAllText($RuntimePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Get-TriggerActionSpec -Spec $Spec -Runtime $rt
        } $spec $runtime
        $action.exe | Should Be 'wscript.exe'
        $action.args | Should Match '-RunOnly'
        $action.args | Should Not Match 'RunIfWorkday'
    }

    It '任务匹配：描述 hash 与动作都一致才算命中' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'match' -Trigger $t
        $hash = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f)
        $actionSpec = [ordered]@{ exe = 'wscript.exe'; args = 'a b c' }
        $task = [pscustomobject]@{
            Description = "flow-ir-spec:$hash；flow-ir：说明"
            Actions     = @([pscustomobject]@{ Execute = 'wscript.exe'; Arguments = 'a b c' })
        }
        $hit = & $script:TriggerModule {
            param($Task, $ActionSpec, $Hash)
            Test-TriggerTaskMatch $Task $ActionSpec $Hash
        } $task $actionSpec $hash
        $hit | Should Be $true

        # 动作被手改：描述 hash 没变也不能判定 unchanged
        $task.Actions[0].Arguments = 'x y z'
        $miss = & $script:TriggerModule {
            param($Task, $ActionSpec, $Hash)
            Test-TriggerTaskMatch $Task $ActionSpec $Hash
        } $task $actionSpec $hash
        $miss | Should Be $false
    }

    It '-Test 忽略 -AllowProd：注册带该开关也不误判 drift，严格比较仍判不一致' {
        $hash = 'f' * 64
        $actionSpec = [ordered]@{ exe = 'wscript.exe'; args = 'flow watch' }
        $task = [pscustomobject]@{
            Description = "flow-ir-spec:$hash；说明"
            Actions     = @([pscustomobject]@{ Execute = 'wscript.exe'; Arguments = 'flow watch -AllowProd' })
        }
        # -Test 口径：忽略注册开关，声明本身一致
        $ignore = & $script:TriggerModule {
            param($Task, $ActionSpec, $Hash)
            Test-TriggerTaskMatch $Task $ActionSpec $Hash -IgnoreAllowProd
        } $task $actionSpec $hash
        $ignore | Should Be $true
        # 注册/回读口径：严格比较，带不带 -AllowProd 都算差异
        $strict = & $script:TriggerModule {
            param($Task, $ActionSpec, $Hash)
            Test-TriggerTaskMatch $Task $ActionSpec $Hash
        } $task $actionSpec $hash
        $strict | Should Be $false
    }

    It '回读校验失败：描述 hash 不一致抛 TRIGGER_DRIFT' {
        $actionSpec = [ordered]@{ exe = 'wscript.exe'; args = 'a b c' }
        $task = [pscustomobject]@{
            Description = 'flow-ir-spec:' + ('0' * 64) + '；说明'
            Actions     = @([pscustomobject]@{ Execute = 'wscript.exe'; Arguments = 'a b c' })
        }
        $code = & $script:TriggerModule {
            param($Task, $ActionSpec, $Hash)
            try {
                Assert-TriggerReadback -Task $Task -ActionSpec $ActionSpec -SpecHash $Hash -TaskName 'demo'
                'NO_ERROR'
            } catch { [string]$_.Exception.Data['code'] }
        } $task $actionSpec ('f' * 64)
        $code | Should Be 'TRIGGER_DRIFT'
    }
}

Describe 'TriggerRegistry 只读与 kind 边界' {

    It 'Register -DryRun 只返回 planned，不写系统' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'dry-run' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
        $r = Register-Trigger -FlowFile $f -RuntimeConfigPath $runtime -DryRun
        $r.ok | Should Be $true
        $r.changed | Should Be 'planned'
        $r.specHash.Length | Should Be 64
        # DryRun 之后任务仍不存在：前后两次只读断言
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'Test 未注册：返回 TRIGGER_NOT_REGISTERED，且仍不写系统' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'test-absent' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        $r = Test-Trigger -FlowFile $f -RuntimeConfigPath $runtime
        $r.ok | Should Be $false
        $r.code | Should Be 'TRIGGER_NOT_REGISTERED'
        $r.status | Should Be 'not-registered'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'Unregister -DryRun 只读，任务本来不存在时返回 absent' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'unreg-dry' -Trigger $t
        $r = Unregister-Trigger -FlowFile $f -DryRun
        $r.ok | Should Be $true
        $r.changed | Should Be 'absent'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'file kind 已支持：缺 -ConfigFile 时无法解析 {{config.KEY}}，硬失败' {
        $t = [ordered]@{ kind = 'file'; time = '09:00'; gate = 'none'; file = @{ dir = '{{config.INBOX}}'; pattern = '*.csv' } }
        $f = New-TestFlow -Dir $TestDrive -Name 'file-kind' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        (Get-TriggerErrorCode { Test-Trigger -FlowFile $f -RuntimeConfigPath $runtime }) |
            Should Be 'TRIGGER_CONFIG_UNRESOLVED'
        # 注销不需要解析配置：任务本来不存在时仍可只读返回 absent
        $u = Unregister-Trigger -FlowFile $f -DryRun
        $u.ok | Should Be $true
        $u.changed | Should Be 'absent'
    }

    It '未知 kind 报 TRIGGER_UNKNOWN_KIND' {
        $t = [ordered]@{ kind = 'smoke' }
        $f = New-TestFlow -Dir $TestDrive -Name 'unknown-kind' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_UNKNOWN_KIND'
    }

    It 'CLI -Register -DryRun：退出码 0，末行 changed=planned，不写系统' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'cli-dry' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:TriggerCli `
            -FlowFile $f -RuntimeConfigPath $runtime -Register -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $r = [regex]::Match($out, 'PAD_TRIGGER_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.ok | Should Be $true
        $r.changed | Should Be 'planned'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'CLI -Test 未注册：退出码 1，code=TRIGGER_NOT_REGISTERED，不写系统' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'cli-test' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:TriggerCli `
            -FlowFile $f -RuntimeConfigPath $runtime -Test 2>&1 | Out-String
        $LASTEXITCODE | Should Be 1
        $r = [regex]::Match($out, 'PAD_TRIGGER_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.code | Should Be 'TRIGGER_NOT_REGISTERED'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }
}

Describe 'TriggerRegistry 流程名派生（pad_flow_name 优先）' {

    It 'pad_flow_name 与 name 不同：任务名与 -FlowName 都用 pad_flow_name' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = New-TestFlow -Dir $TestDrive -Name 'pad-name' -Trigger $t -PadFlowName 'PESTER_DISPLAY'
        $spec = Get-TriggerSpec -FlowFile $f
        # 任务名取显示名，而不是内部 name
        $spec.flowName | Should Be 'PESTER_DISPLAY'
        $spec.taskName | Should Be 'flow-ir-PESTER_DISPLAY'
        $runtime = New-TestRuntime -Dir $TestDrive
        $action = & $script:TriggerModule {
            param($Spec, $RuntimePath)
            $rt = [IO.File]::ReadAllText($RuntimePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Get-TriggerActionSpec -Spec $Spec -Runtime $rt
        } $spec $runtime
        # -FlowName 必须与任务名同源，pad-sync 才能按显示名找到流程
        $action.args | Should Match '-FlowName "PESTER_DISPLAY"'
    }

    It '没有 pad_flow_name 时回退内部 name' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'no-pad-name' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.flowName | Should Be 'PESTER_TRIGGER'
        $spec.taskName | Should Be 'flow-ir-PESTER_TRIGGER'
    }
}

Describe 'TriggerRegistry days 生效为 Weekly' {

    It '声明 days：按对应星期建 Weekly（mon..fri = 62），日历门禁参数保留' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'
            days = @('mon', 'tue', 'wed', 'thu', 'fri'); gate = 'workday' }
        $f = New-TestFlow -Dir $TestDrive -Name 'days-weekly' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.scheduleKind | Should Be 'weekly'
        $trigger = & $script:TriggerModule { param($Spec) New-ScheduleTaskTrigger $Spec } $spec
        $trigger.CimClass.CimClassName | Should Be 'MSFT_TaskWeeklyTrigger'
        $trigger.DaysOfWeek | Should Be 62
        # 门禁仍在：周末不唤醒，工作日再判法定节假日与调休
        $runtime = New-TestRuntime -Dir $TestDrive
        $action = & $script:TriggerModule {
            param($Spec, $RuntimePath)
            $rt = [IO.File]::ReadAllText($RuntimePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            Get-TriggerActionSpec -Spec $Spec -Runtime $rt
        } $spec $runtime
        $action.args | Should Match '-RunIfWorkday'
    }

    It '只声明周六周日：Weekly 只含 sat/sun（64 + 1 = 65）' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('sat', 'sun'); gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'days-weekend' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $trigger = & $script:TriggerModule { param($Spec) New-ScheduleTaskTrigger $Spec } $spec
        $trigger.CimClass.CimClassName | Should Be 'MSFT_TaskWeeklyTrigger'
        $trigger.DaysOfWeek | Should Be 65
    }

    It '未声明 days 且带日历门禁：保持 Daily' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = New-TestFlow -Dir $TestDrive -Name 'days-undeclared' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.scheduleKind | Should Be 'daily'
        $trigger = & $script:TriggerModule { param($Spec) New-ScheduleTaskTrigger $Spec } $spec
        $trigger.CimClass.CimClassName | Should Be 'MSFT_TaskDailyTrigger'
    }

    It '显式 days 与未声明 days 的 specHash 不同：不能判成未变更' {
        $t1 = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $t2 = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday'
            days = @('mon', 'tue', 'wed', 'thu', 'fri') }
        $f1 = New-TestFlow -Dir $TestDrive -Name 'days-hash-a' -Trigger $t1
        $f2 = New-TestFlow -Dir $TestDrive -Name 'days-hash-b' -Trigger $t2
        $h1 = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f1)
        $h2 = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f2)
        $h2 | Should Not Be $h1
    }
}
