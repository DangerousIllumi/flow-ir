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

Describe 'TriggerRegistry declaration parsing' {

    It 'schedule declaration: resolves kind/time/days/gate/timeout/taskName' {
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

    It 'schedule without task_name: derived as flow-ir-<flow name>' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'PESTER_DERIVE' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.taskName | Should Be 'flow-ir-PESTER_TRIGGER'
    }

    It 'manual declaration: no task name produced and all defaults present' {
        $t = [ordered]@{ kind = 'manual' }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.kind | Should Be 'manual'
        ($null -eq $spec.taskName) | Should Be $true
        $spec.timeoutSec | Should Be 4200
    }

    It 'manual declaration with time is rejected: TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'manual'; time = '09:00' }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual-bad' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It 'schedule without time is rejected: TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'schedule'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'schedule-no-time' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It 'An unattended declaration with a run_mode=confirm node is rejected: TRIGGER_UNATTENDED_CONFIRM' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'schedule-confirm' -Trigger $t -NodeRunMode 'confirm'
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_UNATTENDED_CONFIRM'
    }

    It 'assisted=true with a confirm node passes: NO_ERROR' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'
            timeout_sec = 4200; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-ok' -Trigger $t -NodeRunMode 'confirm'
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'NO_ERROR'
    }

    It 'assisted without timeout_sec is rejected: TRIGGER_ASSISTED_NO_TIMEOUT' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-no-timeout' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_ASSISTED_NO_TIMEOUT'
    }

    It 'manual declaration with assisted is rejected: TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'manual'; assisted = $true }
        $f = New-TestFlow -Dir $TestDrive -Name 'manual-assisted' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }

    It 'A non-boolean assisted is rejected: TRIGGER_INVALID' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'
            timeout_sec = 4200; assisted = 'yes' }
        $f = New-TestFlow -Dir $TestDrive -Name 'assisted-not-bool' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_INVALID'
    }
}

Describe 'TriggerRegistry reversibility cross-checks (after narrowing)' {

    It 'All nodes have reversible=true: no reversibility warnings' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-all-true' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $true }
        $spec = Get-TriggerSpec -FlowFile $f
        @($spec.warnings).Count | Should Be 0
    }

    It 'A reversible=false node: warnings contain TRIGGER_UNATTENDED_IRREVERSIBLE (with node and note)' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-false' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $false; reversibility_note = '邮件已发出不可撤回' }
        $spec = Get-TriggerSpec -FlowFile $f
        $codes = @($spec.warnings | ForEach-Object { $_.code })
        ($codes -join ',') | Should Match 'TRIGGER_UNATTENDED_IRREVERSIBLE'
        (@($spec.warnings | Where-Object { $_.code -eq 'TRIGGER_UNATTENDED_IRREVERSIBLE' })[0].evidence -join ' ') |
            Should Match '邮件已发出不可撤回'
    }

    It 'idempotent=false without reversible: warnings contain TRIGGER_MISSING_REVERSIBILITY' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-missing' -Trigger $t `
            -NodeProps @{ idempotent = $false }
        $spec = Get-TriggerSpec -FlowFile $f
        $codes = @($spec.warnings | ForEach-Object { $_.code })
        ($codes -join ',') | Should Match 'TRIGGER_MISSING_REVERSIBILITY'
    }

    It 'manual: no reversibility warnings even with reversible=false' {
        $t = [ordered]@{ kind = 'manual' }
        $f = New-TestFlow -Dir $TestDrive -Name 'rev-manual' -Trigger $t `
            -NodeProps @{ idempotent = $false; reversible = $false }
        $spec = Get-TriggerSpec -FlowFile $f
        @($spec.warnings).Count | Should Be 0
    }
}

Describe 'TriggerRegistry fingerprint and idempotency' {

    It 'hash is stable: recomputation matches and is independent of the trigger field order' {
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

    It 'hash changes with the declaration: changing time or gate yields a new hash' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('mon'); gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'hash-c' -Trigger $t
        $base = Get-TriggerFingerprint -Spec (Get-TriggerSpec -FlowFile $f)
        $t2 = [ordered]@{ kind = 'schedule'; time = '10:00'; days = @('mon'); gate = 'none' }
        $f2 = New-TestFlow -Dir $TestDrive -Name 'hash-d' -Trigger $t2
        $s2 = Get-TriggerSpec -FlowFile $f2
        (Get-TriggerFingerprint -Spec $s2) | Should Not Be $base
    }

    It 'assisted is part of specHash: changing it always changes the hash' {
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

    It 'The description prefix yields the hash, and an invalid description returns empty' {
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

    It 'Action construction reuses pad-schedule: gate=workday goes through run-hidden.vbs + -RunIfWorkday' {
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

    It 'Action construction reuses pad-schedule: gate=none calls pad-sync -RunOnly directly' {
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

    It 'Task match: a hit requires both the description hash and the actions to match' {
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

    It '-Test ignores -AllowProd: registering with that switch is not misjudged as drift, while the strict comparison still reports a mismatch' {
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

    It 'Readback validation failure: a mismatched description hash throws TRIGGER_DRIFT' {
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

Describe 'TriggerRegistry read-only behavior and kind boundaries' {

    It 'Register -DryRun only returns planned and writes nothing to the system' {
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

    It 'Test on an unregistered task: returns TRIGGER_NOT_REGISTERED and still writes nothing to the system' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'test-absent' -Trigger $t
        $runtime = New-TestRuntime -Dir $TestDrive
        $r = Test-Trigger -FlowFile $f -RuntimeConfigPath $runtime
        $r.ok | Should Be $false
        $r.code | Should Be 'TRIGGER_NOT_REGISTERED'
        $r.status | Should Be 'not-registered'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'Unregister -DryRun is read-only and returns absent when the task never existed' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none'; task_name = $script:UniqueTask }
        $f = New-TestFlow -Dir $TestDrive -Name 'unreg-dry' -Trigger $t
        $r = Unregister-Trigger -FlowFile $f -DryRun
        $r.ok | Should Be $true
        $r.changed | Should Be 'absent'
        (Test-TaskAbsent $script:UniqueTask) | Should Be $true
    }

    It 'The file kind is supported: without -ConfigFile {{config.KEY}} cannot be resolved and the check fails hard' {
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

    It 'An unknown kind reports TRIGGER_UNKNOWN_KIND' {
        $t = [ordered]@{ kind = 'smoke' }
        $f = New-TestFlow -Dir $TestDrive -Name 'unknown-kind' -Trigger $t
        (Get-TriggerErrorCode { Get-TriggerSpec -FlowFile $f }) | Should Be 'TRIGGER_UNKNOWN_KIND'
    }

    It 'CLI -Register -DryRun: exit code 0, a final changed=planned line, and nothing written to the system' {
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

    It 'CLI -Test on an unregistered task: exit code 1, code=TRIGGER_NOT_REGISTERED, and nothing written to the system' {
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

Describe 'TriggerRegistry flow name derivation (pad_flow_name wins)' {

    It 'pad_flow_name differs from name: both the task name and -FlowName use pad_flow_name' {
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

    It 'Without pad_flow_name it falls back to the internal name' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'no-pad-name' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.flowName | Should Be 'PESTER_TRIGGER'
        $spec.taskName | Should Be 'flow-ir-PESTER_TRIGGER'
    }
}

Describe 'TriggerRegistry days take effect as Weekly' {

    It 'days declared: a Weekly trigger is built for those weekdays (mon..fri = 62) and the calendar gate argument is kept' {
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

    It 'Only Saturday and Sunday declared: Weekly contains just sat/sun (64 + 1 = 65)' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; days = @('sat', 'sun'); gate = 'none' }
        $f = New-TestFlow -Dir $TestDrive -Name 'days-weekend' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $trigger = & $script:TriggerModule { param($Spec) New-ScheduleTaskTrigger $Spec } $spec
        $trigger.CimClass.CimClassName | Should Be 'MSFT_TaskWeeklyTrigger'
        $trigger.DaysOfWeek | Should Be 65
    }

    It 'No days declared with a calendar gate: stays Daily' {
        $t = [ordered]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = New-TestFlow -Dir $TestDrive -Name 'days-undeclared' -Trigger $t
        $spec = Get-TriggerSpec -FlowFile $f
        $spec.scheduleKind | Should Be 'daily'
        $trigger = & $script:TriggerModule { param($Spec) New-ScheduleTaskTrigger $Spec } $spec
        $trigger.CimClass.CimClassName | Should Be 'MSFT_TaskDailyTrigger'
    }

    It 'Registration explicitly disables StartWhenAvailable: no catch-up of missed weekend instances after resuming from sleep' {
        $settings = & $script:TriggerModule {
            param($Minutes)
            New-ScheduleTaskSettings -ExecutionTimeLimitMinutes $Minutes
        } 180
        $settings.StartWhenAvailable | Should Be $false
        # 其余设置保持既有形态，不因本项关闭而改变
        $settings.MultipleInstances | Should Be 'IgnoreNew'
    }

    It 'Explicit days and undeclared days give different specHash values and cannot be judged unchanged' {
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
