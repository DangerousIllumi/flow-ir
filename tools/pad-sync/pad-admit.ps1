# pad-admit.ps1 — 只读准入网关：部署/运行前判断"这份流程、这次运行是否被允许"
#
# 对应 docs/admission-gate.md 的 14 项检查。硬约束：
#   1) 只读：不启动 PAD、不连 SAP、不发邮件、不写产物
#   2) 一次返回全部问题，不因第一条失败提前退出
#   3) 每条失败带 code + 人话 + 证据（节点 id / 参数 / 文件名）
#
# 用法：
#   .\pad-admit.ps1 -FlowFile business\flows\sample-report.json -ConfigFile business\config\sample-report.json
#   .\pad-admit.ps1 -FlowFile ... -Unattended      # 定时任务场景：ask 一律按 deny
#   .\pad-admit.ps1 -FlowFile ... -Json            # 只输出 JSON
#
# 退出码：0 全部通过 / 1 存在 fail / 2 仅存在 ask
# 与文档的差异（报告模式下更实用，已记录）：
#   - BUDGET 未声明时记 warn 而不是 fail（否则所有存量流程都过不了）
#   - INTENT 缺失记 warn（策略仍可用 paramsMatch 兜底）
#   - 未提供批准记录时 FINGERPRINT 记 warn
#   - TRIGGER 在观察期未声明记 warn（存量流程迁移完成后改为 fail）

[CmdletBinding()]
param(
    [string]$FlowFile,
    [string]$RobinFile,
    [string]$ConfigFile,
    [string]$AcceptanceFile,
    [string]$RequirementsFile,
    [string]$PolicyFile,
    [string]$KbPath,
    [string]$FlowName,
    [string]$ApproveFile,
    # 定时任务/无人值守：ask 按 deny 处理
    [switch]$Unattended,
    [switch]$Json,
    # 仅供 Pester dot-source
    [switch]$NoMain
)
$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# 指纹机制唯一实现：定位、哈希、比对都在 PadFingerprint.psm1
Import-Module (Join-Path $PSScriptRoot 'PadFingerprint.psm1') -Force
# 指纹未通过时的处置级别：warn 只提醒、fail 阻断。
# 切换顺序是硬要求：先播种基线并保持 warn，等真实运行观察无误后再单独提交改成 fail
$script:FingerprintMode = 'warn'

$CONTROL_HINTS = @('IF', 'LOOP', 'SWITCH', 'GUARD', 'WAIT', 'EXIT LOOP', 'EXIT_LOOP')

# 通配符匹配：只支持 * 与 ?，其余字符按字面量，避免正则元字符误伤
function Test-GlobMatch([string]$Pattern, [string]$Text) {
    if ($null -eq $Pattern) { return $false }
    if ($Pattern -eq '*') { return $true }
    $escaped = [regex]::Escape([string]$Pattern)
    $rx = '^' + $escaped.Replace('\*', '.*').Replace('\?', '.') + '$'
    return ($Text -match $rx)
}

# 按 PAD 显示名派生 flow.json：先匹配顶层 pad_flow_name，再匹配文件名 / 顶层 name。
# 命中多条即 ADMIT_AMBIGUOUS_FLOW，绝不退回“取第一个”；命中 0 条返回 $null。
# pad_flow_name 是可选字段，生成器 / check.js / eval-flow.js 只接受不消费。
function Resolve-FlowFileByName([string]$FlowsDir, [string]$FlowName) {
    if (-not (Test-Path -LiteralPath $FlowsDir)) { return $null }
    $items = @(Get-ChildItem -LiteralPath $FlowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' } |
        ForEach-Object {
            try {
                $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                # 只认流程定义：必须有非空 nodes，避免配套产物/部署 diff 混进候选
                if (($j.PSObject.Properties.Name -contains 'nodes') -and (@($j.nodes).Count -gt 0)) {
                    [pscustomobject]@{ File = $_; Json = $j }
                }
            } catch { }
        })
    $hit = @($items | Where-Object { [string]$_.Json.pad_flow_name -eq $FlowName })
    if ($hit.Count -eq 0) {
        $hit = @($items | Where-Object {
            ($_.File.BaseName -eq $FlowName) -or ([string]$_.Json.name -eq $FlowName)
        })
    }
    if ($hit.Count -eq 1) { return $hit[0].File.FullName }
    if ($hit.Count -gt 1) {
        throw ("ADMIT_AMBIGUOUS_FLOW：按 '{0}' 命中 {1} 个 flow.json（{2}）；请用 -FlowFile 明确指定" -f `
            $FlowName, $hit.Count, (($hit | ForEach-Object { $_.File.Name }) -join '、'))
    }
    return $null
}

# 统一的结果条目
function New-AdmitCheck([string]$Id, [string]$Status, [string]$Code, [string]$Message, $Evidence) {
    return [ordered]@{
        id = $Id; status = $Status; code = $Code; message = $Message
        evidence = @($Evidence)
    }
}

# 把参数值转成策略 glob 能匹配的文本（对象/数组按压缩 JSON）
function ConvertTo-MatchText($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool] -or $Value -is [int] -or $Value -is [long] -or $Value -is [double]) { return [string]$Value }
    return ($Value | ConvertTo-Json -Depth 6 -Compress)
}

# 规则 when 段是否全部满足
function Test-RuleWhen($Rule, $Node, [hashtable]$Ctx) {
    $w = $Rule.when
    if (-not $w) { return $true }
    if ($null -ne $w.env) {
        if ([string]$w.env -ne [string]$Ctx.env) { return $false }
    }
    if ($null -ne $w.dryRun) {
        if ([bool]$w.dryRun -ne [bool]$Ctx.dryRun) { return $false }
    }
    if ($null -ne $w.registered) {
        if ([bool]$w.registered -ne [bool]$Ctx.registered.ContainsKey([string]$Node.pad_hint)) { return $false }
    }
    if ($null -ne $w.intent) {
        if (-not $Node) { return $false }
        if ([string]$w.intent -ne [string]$Node.intent) { return $false }
    }
    if ($null -ne $w.paramsMatch) {
        if (-not $Node) { return $false }
        foreach ($p in $w.paramsMatch.PSObject.Properties) {
            $val = $null
            if ($Node.params -and $Node.params.PSObject.Properties.Name -contains $p.Name) {
                $val = $Node.params.($p.Name)
            }
            if (-not (Test-GlobMatch ([string]$p.Value) (ConvertTo-MatchText $val))) { return $false }
        }
    }
    return $true
}

# 收集若干 node id 的全部下游（含 next、branch、loop、switch、guard 的 body）
# 用于判断「某个副作用是否已被 DRY_RUN 守卫包住」；用 visited 防回边死循环
function Get-DescendantIds($Flow, [string[]]$Ids) {
    $byId = @{}
    foreach ($n in @($Flow.nodes)) { $byId[[string]$n.id] = $n }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($i in $Ids) { if ($i) { $stack.Push([string]$i) } }
    while ($stack.Count -gt 0) {
        $id = $stack.Pop()
        if (-not $seen.Add($id)) { continue }
        $n = $byId[$id]
        if (-not $n) { continue }
        foreach ($x in @($n.next)) { if ($x) { $stack.Push([string]$x) } }
        if ($n.branch) {
            foreach ($x in @($n.branch.trueBody) + @($n.branch.falseBody)) { if ($x) { $stack.Push([string]$x) } }
        }
        if ($n.loop -and $n.loop.body) { foreach ($x in @($n.loop.body)) { if ($x) { $stack.Push([string]$x) } } }
        if ($n.switch) {
            foreach ($c in @($n.switch.cases)) { foreach ($x in @($c.body)) { if ($x) { $stack.Push([string]$x) } } }
            foreach ($x in @($n.switch.default)) { if ($x) { $stack.Push([string]$x) } }
        }
        if ($n.pad_hint -eq 'GUARD') {
            foreach ($x in @($n.body) + @($n.elseBody)) { if ($x) { $stack.Push([string]$x) } }
        }
    }
    return $seen
}

# 策略评估：固定 deny → ask → allow；同层取第一条命中；全部未命中按 defaultEffect
# 返回 { checks, hits }，checks 里最多一条 POLICY 结论
function Invoke-AdmitPolicy($Flow, $Policy, [hashtable]$Ctx, [switch]$Unattended) {
    $results = @()
    $rules = @($Policy.rules | Where-Object { $_.enabled })
    $actionNodes = @($Flow.nodes | Where-Object {
        $_.pad_hint -and $CONTROL_HINTS -notcontains [string]$_.pad_hint
    })

    # 被 DRY_RUN 守卫包住的节点集合：这些副作用在测试模式下本来就不会执行，
    # 因此「dryRun 相关的 deny 规则」对它们不成立（否则一开 DRY_RUN 就被准入拦死）
    $guardRoots = @($Flow.nodes | Where-Object {
        $_.pad_hint -eq 'GUARD' -and ([string]$_.when) -match 'DryRun'
    } | ForEach-Object { @($_.body) + @($_.elseBody) })
    $guarded = @{}
    if ($guardRoots.Count -gt 0) {
        foreach ($id in (Get-DescendantIds $Flow $guardRoots)) { $guarded[$id] = $true }
    }

    $denies = @()
    $asks = @()
    $allows = @()

    foreach ($node in $actionNodes) {
        foreach ($rule in $rules) {
            if ([string]$rule.resource -ne 'action') { continue }
            if (-not (Test-GlobMatch ([string]$rule.match) ([string]$node.pad_hint))) { continue }
            if (-not (Test-RuleWhen $rule $node $Ctx)) { continue }
            # 被 DRY_RUN 守卫包住的副作用在测试模式下不会执行，dryRun 类规则对它们不成立
            if ($rule.when -and $rule.when.dryRun -eq $true -and $guarded.ContainsKey([string]$node.id)) { continue }
            $hit = [ordered]@{ rule = $rule; node = [string]$node.id; hint = [string]$node.pad_hint }
            switch ([string]$rule.effect) {
                'deny' { $denies += $hit }
                'ask' { $asks += $hit }
                'allow' { $allows += $hit }
            }
        }
    }

    if ($denies.Count -gt 0) {
        $ev = @($denies | ForEach-Object { "节点 $($_.node) $($_.hint) 命中 $($_.rule.id)" })
        $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_DENY' `
            ('被策略拒绝：' + (@($denies | ForEach-Object { $_.rule.reason }) -join '；')) $ev
        return $results
    }
    if ($asks.Count -gt 0) {
        $ev = @($asks | ForEach-Object { "节点 $($_.node) $($_.hint) 命中 $($_.rule.id)" })
        $reason = (@($asks | ForEach-Object { $_.rule.reason }) -join '；')
        if ($Unattended) {
            $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_ASK_UNATTENDED' `
                "无人值守场景下 ask 按 deny 处理：$reason" $ev
        } else {
            $results += New-AdmitCheck 'POLICY' 'ask' 'POLICY_ASK' $reason $ev
        }
        return $results
    }
    if ($allows.Count -gt 0 -or [string]$Policy.defaultEffect -eq 'allow') {
        $results += New-AdmitCheck 'POLICY' 'pass' 'OK' '未命中 deny/ask' @()
        return $results
    }
    $results += New-AdmitCheck 'POLICY' 'fail' 'POLICY_DEFAULT_DENY' `
        '未命中任何 allow 规则，按 defaultEffect=deny 处理' @()
    return $results
}

# ---------- TRIGGER（第 14 项）：触发声明 ----------
# 观察期：存量流程还没有 trigger，默认记 warn；迁移完成后单独提交改为 fail。
# 与指纹同一做法：切换级别是独立改动，不混在本次功能里。
$script:TriggerMode = 'warn'
$script:TriggerKinds = @('manual', 'schedule', 'file')
# 保留值单列：写 mail/callback 是「支持但 v1 未实现」，与拼错区分开
$script:TriggerReservedKinds = @('mail', 'callback')
$script:TriggerDays = @('mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
$script:TriggerGates = @('none', 'workday', 'last-workday')
$script:TriggerDayNames = @{
    mon = '周一'; tue = '周二'; wed = '周三'; thu = '周四'; fri = '周五'; sat = '周六'; sun = '周日'
}

# 属性存在性判断：兼容 JSON 得到的 PSCustomObject 与测试里直接构造的 Hashtable
function Test-PropExists($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
    return (@($Obj.PSObject.Properties.Name) -contains $Name)
}

# 正整数秒：字符串、小数、0、负数一律不认，避免注册器再猜单位
function Test-TriggerPositiveInt($Value) {
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) { return $false }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $false }
    $d = [double]$Value
    return ($d -gt 0 -and $d -eq [math]::Floor($d))
}

# 默认任务名：与 pad-schedule 的 Get-ScheduleTaskName 同口径，避免两处派生规则漂移
function Get-TriggerTaskName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|\s]', '_').Trim('_')
    if (-not $safe) { return $null }
    return 'flow-ir-' + $safe
}

# 静态任务名冲突：扫 business\flows 下其他流程声明的有效任务名，命中即不覆盖
function Find-TriggerTaskCollision {
    param([string]$Repo, [string]$SelfFile, [string]$TaskName)
    $hits = @()
    if (-not $Repo -or -not $TaskName) { return $hits }
    $dir = Join-Path $Repo 'business\flows'
    if (-not (Test-Path -LiteralPath $dir)) { return $hits }
    $self = $null
    if ($SelfFile -and (Test-Path -LiteralPath $SelfFile)) { $self = (Resolve-Path -LiteralPath $SelfFile).Path }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($self -and $f.FullName -eq $self) { continue }
        try { $j = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not (Test-PropExists $j 'trigger')) { continue }
        $t = $null
        if (Test-PropExists $j.trigger 'task_name') { $t = [string]$j.trigger.task_name }
        elseif ((Test-PropExists $j.trigger 'kind') -and [string]$j.trigger.kind -ne 'manual') {
            $t = Get-TriggerTaskName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
        if ($t -eq $TaskName) { $hits += $f.Name }
    }
    return $hits
}

# 第 14 项主体：只做静态校验。
# 后续接入点（本次不实现）：加 -TriggerLive 后查 Get-ScheduledTask 与 specHash，
# 补 TRIGGER_NOT_REGISTERED（warn）/ TRIGGER_DRIFT（fail）两个 live 结果码。
function Invoke-TriggerCheck {
    param($Flow, [string]$FlowName, [string]$Repo, [string]$SelfFile)
    $issues = @()

    $trg = $null
    if (Test-PropExists $Flow 'trigger') { $trg = $Flow.trigger }
    if ($null -eq $trg) {
        return @(New-AdmitCheck 'TRIGGER' $script:TriggerMode 'TRIGGER_MISSING' `
            '未声明触发方式（trigger），启动约定仍靠口头记忆；请补 trigger 块' @())
    }
    if (-not (Test-PropExists $trg 'kind') -and (Test-PropExists $trg 'type')) {
        return @(New-AdmitCheck 'TRIGGER' $script:TriggerMode 'TRIGGER_LEGACY_SHAPE' `
            '只有 type/config 旧形状，缺 kind；请迁移到 kind（不做静默映射）' @("trigger.type=$([string]$trg.type)"))
    }
    if (-not (Test-PropExists $trg 'kind') -or -not [string]$trg.kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_INVALID' 'trigger.kind 缺失或不是字符串' @())
    }
    $kind = [string]$trg.kind
    if ($script:TriggerReservedKinds -contains $kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_KIND_UNSUPPORTED' `
            "kind=$kind 是保留值，v1 没有对应注册器" @("kind=$kind"))
    }
    if ($script:TriggerKinds -notcontains $kind) {
        return @(New-AdmitCheck 'TRIGGER' 'fail' 'TRIGGER_UNKNOWN_KIND' `
            "kind=$kind 不在 manual/schedule/file" @("kind=$kind"))
    }

    # 任务名：显式给出必须安全；未给出按流程名派生。manual 不注册，不需要任务名
    if ($kind -ne 'manual') {
        $taskName = $null
        if (Test-PropExists $trg 'task_name') {
            $taskName = [string]$trg.task_name
            if ($taskName -notmatch '^[A-Za-z0-9._-]{1,64}$') {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "task_name=$taskName 不匹配 ^[A-Za-z0-9._-]{1,64}$"; evidence = @("task_name=$taskName") }
            }
        }
        if (-not $taskName) { $taskName = Get-TriggerTaskName $FlowName }
        $collisions = @(Find-TriggerTaskCollision -Repo $Repo -SelfFile $SelfFile -TaskName $taskName)
        if ($collisions.Count -gt 0) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_AMBIGUOUS'
                message = "任务名 $taskName 已被其他流程占用，注册会互相覆盖"
                evidence = @($collisions | ForEach-Object { "task_name=$taskName 冲突文件：$_" }) }
        }
    }

    if ($kind -eq 'manual') {
        # manual 声明了时刻/目录也不会执行，直接判非法，避免“写了但没人跑”
        foreach ($k in @('time', 'days', 'gate', 'timeout_sec', 'file')) {
            if (Test-PropExists $trg $k) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "manual 不允许声明 $k（声明了也没人执行）"; evidence = @("trigger.$k") }
            }
        }
    } else {
        $timeText = $null
        if (Test-PropExists $trg 'time') { $timeText = [string]$trg.time }
        if (-not $timeText -or $timeText -notmatch '^([01]\d|2[0-3]):[0-5]\d$') {
            $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                message = "time=$timeText（应为 HH:mm，如 09:00）"; evidence = @("time=$timeText") }
        }

        if (Test-PropExists $trg 'days') {
            $dayList = @($trg.days)
            $badDays = @($dayList | Where-Object { $script:TriggerDays -notcontains [string]$_ })
            if ($dayList.Count -eq 0 -or $badDays.Count -gt 0) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = 'days 必须是非空数组，取值 mon..sun'
                    evidence = @("days=$(@($dayList) -join ',')") }
            }
        }

        $gate = 'none'
        if (Test-PropExists $trg 'gate') {
            $gate = [string]$trg.gate
            if ($script:TriggerGates -notcontains $gate) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = "gate=$gate 不在 none/workday/last-workday"; evidence = @("gate=$gate") }
            }
        } elseif ($kind -eq 'schedule') {
            $issues += @{ status = 'warn'; code = 'TRIGGER_NO_GATE'
                message = 'schedule 未声明 gate，节假日会照跑；如不需要请显式写 gate=none'
                evidence = @('gate 未声明') }
        }

        if ((Test-PropExists $trg 'timeout_sec') -and -not (Test-TriggerPositiveInt $trg.timeout_sec)) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                message = "timeout_sec=$($trg.timeout_sec)（应为正整数秒）"; evidence = @('timeout_sec') }
        }

        $pattern = $null
        if ($kind -eq 'file') {
            if (-not (Test-PropExists $trg 'file')) {
                $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                    message = 'file 触发必须带 file 对象'; evidence = @('file') }
            } else {
                $f = $trg.file
                $dir = $null
                if (Test-PropExists $f 'dir') { $dir = [string]$f.dir }
                if (-not $dir) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.dir 必填'; evidence = @('file.dir') }
                } elseif ($dir -notmatch '^\{\{config\.(\w+)\}\}$') {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_PATH_LITERAL'
                        message = 'file.dir 必须是 {{config.<KEY>}} 引用，不能是字面路径'
                        evidence = @("file.dir=$dir") }
                }
                if (Test-PropExists $f 'pattern') { $pattern = [string]$f.pattern }
                if (-not $pattern -or $pattern.Trim().Length -eq 0) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.pattern 必填且不能为空'; evidence = @('file.pattern') }
                }
                foreach ($k in @('poll_sec', 'settle_sec', 'max_wait_sec')) {
                    if ((Test-PropExists $f $k) -and -not (Test-TriggerPositiveInt $f.$k)) {
                        $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                            message = "file.$k=$($f.$k)（应为正整数秒）"; evidence = @("file.$k") }
                    }
                }
                if ((Test-PropExists $f 'once_per_file') -and -not ($f.once_per_file -is [bool])) {
                    $issues += @{ status = 'fail'; code = 'TRIGGER_INVALID'
                        message = 'file.once_per_file 必须是 true/false'; evidence = @('file.once_per_file') }
                }
            }
        }

        # 交叉校验：无人值守触发遇到人工确认节点是硬矛盾；重跑不安全只提醒
        $nodes = @($Flow.nodes)
        $confirm = @($nodes | Where-Object {
            $_ -and (Test-PropExists $_ 'run_mode') -and [string]$_.run_mode -eq 'confirm'
        })
        if ($confirm.Count -gt 0) {
            $issues += @{ status = 'fail'; code = 'TRIGGER_UNATTENDED_CONFIRM'
                message = '无人值守触发但节点需要人工确认'
                evidence = @($confirm | ForEach-Object { "节点 $($_.id) run_mode=confirm" }) }
        }
        $nonIdem = @($nodes | Where-Object {
            $_ -and (Test-PropExists $_ 'idempotent') -and $_.idempotent -eq $false
        })
        if ($nonIdem.Count -gt 0) {
            $issues += @{ status = 'warn'; code = 'TRIGGER_UNATTENDED_NONIDEMPOTENT'
                message = '无人值守触发但节点重跑不安全（idempotent=false），请确认重跑后果'
                evidence = @($nonIdem | ForEach-Object { "节点 $($_.id) idempotent=false" }) }
        }
    }

    if ($issues.Count -eq 0) {
        $dayText = '周一~周五'
        if (Test-PropExists $trg 'days') {
            $dayText = (@($trg.days) | ForEach-Object { $script:TriggerDayNames[[string]$_] }) -join '、'
        }
        $msg = switch ($kind) {
            'manual' { '触发声明合法：manual（手工或外部链接触发，无需注册）' }
            'schedule' { "触发声明合法：schedule $timeText（$dayText，gate=$gate）" }
            default { "触发声明合法：file $timeText（$dayText，pattern=$pattern）" }
        }
        return @(New-AdmitCheck 'TRIGGER' 'pass' 'OK' $msg @())
    }
    return @($issues | ForEach-Object {
        New-AdmitCheck 'TRIGGER' $_.status $_.code $_.message $_.evidence
    })
}

# 主体检查：一次跑完 14 项
function Invoke-AdmitChecks {
    param(
        $Flow, [string]$FlowName, $Config, $Kb,
        [string]$RobinPath, [string]$AcceptancePath, [string]$RequirementsPath,
        $Policy, [string]$ApprovePath, [hashtable]$Paths
    )
    $checks = @()
    $nodes = @($Flow.nodes)
    $actionNodes = @($nodes | Where-Object { $_.pad_hint -and $CONTROL_HINTS -notcontains [string]$_.pad_hint })
    $kbMap = @{}
    if ($Kb) { foreach ($a in $Kb.actions) { $kbMap[[string]$a.actionId] = $a } }

    # 1 REGISTRY
    if ($kbMap.Count -eq 0) {
        $checks += New-AdmitCheck 'REGISTRY' 'warn' 'KB_MISSING' '找不到动作知识库，跳过 REGISTRY/ARGS/SELECTOR' @()
    } else {
        $unknown = @($actionNodes | Where-Object { -not $kbMap.ContainsKey([string]$_.pad_hint) })
        if ($unknown.Count -gt 0) {
            $checks += New-AdmitCheck 'REGISTRY' 'fail' 'UNKNOWN_ACTION' '存在 KB 里没有的动作' `
                @($unknown | ForEach-Object { "节点 $($_.id) $($_.pad_hint)" })
        } else {
            $checks += New-AdmitCheck 'REGISTRY' 'pass' 'OK' "$($actionNodes.Count) 个动作全部在 KB 中" @()
        }

        # 2 ARGS
        # 未知参数 = 硬失败（生成器也会拒绝）；缺必填但 KB 无默认值只提醒：
        # 生成器会跳过该参数，PAD 实际接受（golden 示例同样省略），不宜阻断
        $argErrs = @()
        $argWarns = @()
        foreach ($n in $actionNodes) {
            $act = $kbMap[[string]$n.pad_hint]
            if (-not $act) { continue }
            $valid = @($act.input_params | ForEach-Object { [string]$_.name })
            $paramNames = @()
            if ($n.params) { $paramNames = @($n.params.PSObject.Properties.Name | Where-Object { $_ }) }
            foreach ($k in $paramNames) {
                if ($valid -notcontains $k) { $argErrs += "节点 $($n.id) 未知参数 $k" }
            }
            foreach ($p in @($act.input_params)) {
                if ($p.required -ne $true) { continue }
                # 句柄类参数由生成器从 Launch 动作自动接上，flow.json 里本来就不写
                if ([string]$p.type -match '(Instance|Handle)$' -or [string]$p.type -eq 'Browser') { continue }
                if ($null -ne $p.default) { continue }
                if ($paramNames -notcontains [string]$p.name) {
                    $argWarns += "节点 $($n.id) 未写必填参数 $($p.name)（KB 无默认值，生成时会省略）"
                }
            }
        }
        if ($argErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'ARGS' 'fail' 'UNKNOWN_PARAM' '参数与 KB 不一致' $argErrs
        } elseif ($argWarns.Count -gt 0) {
            $checks += New-AdmitCheck 'ARGS' 'warn' 'MISSING_PARAM' '部分必填参数未显式给出（生成时省略）' $argWarns
        } else {
            $checks += New-AdmitCheck 'ARGS' 'pass' 'OK' '参数名与必填项齐全' @()
        }

        # 3 SELECTOR
        $ui = @($actionNodes | Where-Object { $kbMap[[string]$_.pad_hint].needs_ui_selector -eq $true })
        if ($ui.Count -gt 0) {
            $checks += New-AdmitCheck 'SELECTOR' 'fail' 'UI_SELECTOR' '这些动作需要已录制的 UI 元素' `
                @($ui | ForEach-Object { "节点 $($_.id) $($_.pad_hint)" })
        } else {
            $checks += New-AdmitCheck 'SELECTOR' 'pass' 'OK' '无需要 UI 选择器的动作' @()
        }
    }

    # 4 STATIC（复用 check.js，不重复实现语法规则）
    if ($RobinPath -and (Test-Path -LiteralPath $RobinPath)) {
        $out = & node (Join-Path $Paths.Repo 'tools\pad-robin\check.js') $RobinPath 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $checks += New-AdmitCheck 'STATIC' 'pass' 'OK' '静态校验 0 错误' @()
        } else {
            $checks += New-AdmitCheck 'STATIC' 'fail' 'STATIC_SYNTAX' '静态校验发现错误' @($out.Trim() -split "`r?`n" | Select-Object -First 10)
        }
    } else {
        $checks += New-AdmitCheck 'STATIC' 'warn' 'ROBIN_MISSING' '没有找到 .robin，跳过静态校验' @()
    }

    # 5 EDGE
    if ($Flow.edges -and @($Flow.edges).Count -gt 0) {
        $out = & node (Join-Path $Paths.Repo 'tools\flow-drawio\check-flow.js') $Paths.FlowFile 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $checks += New-AdmitCheck 'EDGE' 'pass' 'OK' 'edges 与 next/branch 一致' @()
        } else {
            $checks += New-AdmitCheck 'EDGE' 'fail' 'EDGE_DRIFT' 'edges 与 next/branch 不一致' @($out.Trim() -split "`r?`n" | Select-Object -First 10)
        }
    } else {
        $checks += New-AdmitCheck 'EDGE' 'warn' 'EDGE_ABSENT' 'flow.json 没有显式 edges，跳过' @()
    }

    # 6 BOUNDED
    $unbounded = @()
    foreach ($n in @($nodes | Where-Object { $_.pad_hint -eq 'LOOP' })) {
        $lp = $n.loop
        if (-not $lp) { $unbounded += "节点 $($n.id) 缺 loop 定义"; continue }
        if ([string]$lp.kind -eq 'while') { $unbounded += "节点 $($n.id) 是无界 LOOP WHILE"; continue }
        if ([string]$lp.kind -eq 'fromto' -and [string]::IsNullOrWhiteSpace([string]$lp.to)) {
            $unbounded += "节点 $($n.id) 缺上界"
        }
    }
    if ($unbounded.Count -gt 0) {
        $checks += New-AdmitCheck 'BOUNDED' 'fail' 'UNBOUNDED_LOOP' '存在无界或未声明上界的循环' $unbounded
    } else {
        $checks += New-AdmitCheck 'BOUNDED' 'pass' 'OK' '循环都有明确上界' @()
    }

    # 7 POLICY
    $dryRun = $false
    if ($Config -and $Config.DRY_RUN) { $dryRun = ([string]$Config.DRY_RUN -eq '1') }
    $envName = if ($FlowName -eq 'PAD_SYNC_TEST') { 'test' } else { 'prod' }
    $registered = @{}
    foreach ($k in $kbMap.Keys) { $registered[$k] = $true }
    $ctx = @{ env = $envName; dryRun = $dryRun; registered = $registered }
    if ($Policy) {
        $checks += Invoke-AdmitPolicy $Flow $Policy $ctx -Unattended:$Unattended
    } else {
        $checks += New-AdmitCheck 'POLICY' 'warn' 'POLICY_MISSING' '没有 business\policy.json，跳过策略评估' @()
    }

    # 8 BUDGET（未声明即 warn：报告模式下不阻断存量流程）
    if ($Flow.budget) {
        $b = $Flow.budget
        $ev = @()
        $loops = @($nodes | Where-Object { $_.pad_hint -eq 'LOOP' -and $_.loop -and $_.loop.kind -eq 'fromto' })
        foreach ($n in $loops) {
            if ($b.maxLoop -and ([int]$n.loop.to - [int]$n.loop.from + 1) -gt [int]$b.maxLoop) {
                $ev += "节点 $($n.id) 循环 $($n.loop.to - $n.loop.from + 1) 次，超过预算 $($b.maxLoop)"
            }
        }
        if ($ev.Count -gt 0) {
            $checks += New-AdmitCheck 'BUDGET' 'fail' 'BUDGET_EXCEEDED' '超出预算声明' $ev
        } else {
            $checks += New-AdmitCheck 'BUDGET' 'pass' 'OK' '在预算声明内' @()
        }
    } else {
        $checks += New-AdmitCheck 'BUDGET' 'fail' 'BUDGET_UNKNOWN' 'flow.json 未声明 budget，预算未知（未知按超限处理）' @()
    }

    # 9 ACCEPTANCE
    $knownTypes = @('fileExists', 'globNewerThan', 'pair', 'json', 'jsonl', 'logState')
    if ($AcceptancePath -and (Test-Path -LiteralPath $AcceptancePath)) {
        $accErrs = @()
        try {
            $spec = [IO.File]::ReadAllText($AcceptancePath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($c in @($spec.checks)) {
                if ($knownTypes -notcontains [string]$c.type) { $accErrs += "判据「$($c.name)」类型不支持：$($c.type)" }
                foreach ($s in @($c.path, $c.dir) + @($c.paths)) {
                    if ($s -and ([string]$s -match '\{\{variables\.' -or [string]$s -match '%[A-Za-z_]\w*%')) {
                        $accErrs += "判据「$($c.name)」有未解析引用：$s"
                    }
                }
            }
        } catch { $accErrs += "JSON 解析失败：$($_.Exception.Message)" }
        if ($accErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'ACCEPTANCE' 'fail' 'ACCEPTANCE_INVALID' '验收判据不合法' $accErrs
        } else {
            $checks += New-AdmitCheck 'ACCEPTANCE' 'pass' 'OK' "$(@($spec.checks).Count) 条判据合法" @()
        }
    } else {
        $checks += New-AdmitCheck 'ACCEPTANCE' 'warn' 'ACCEPTANCE_MISSING' '没有验收判据文件' @()
    }

    # 10 CONFIG
    if ($Config -and $Paths.ConfigFile) {
        $schemaPath = [IO.Path]::ChangeExtension($Paths.ConfigFile, '.schema.json')
        $cfgErrs = @()
        if (Test-Path -LiteralPath $schemaPath) {
            try {
                $schema = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                foreach ($k in @($schema.required)) {
                    if ($Config.PSObject.Properties.Name -notcontains $k) { $cfgErrs += "缺少必填键 $k" }
                }
            } catch { $cfgErrs += "schema 解析失败：$($_.Exception.Message)" }
        } else {
            $cfgErrs += "找不到 schema：$schemaPath"
        }
        if ($cfgErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'CONFIG' 'fail' 'CONFIG_INVALID' '部署配置不合法' $cfgErrs
        } else {
            $checks += New-AdmitCheck 'CONFIG' 'pass' 'OK' '配置通过 schema 必填项校验' @()
        }
    } else {
        $checks += New-AdmitCheck 'CONFIG' 'warn' 'CONFIG_MISSING' '未提供 config，跳过' @()
    }

    # 11 PREFLIGHT
    if ($RequirementsPath -and (Test-Path -LiteralPath $RequirementsPath) -and $Config) {
        try {
            Import-Module (Join-Path $PSScriptRoot 'PadPreflight.psm1') -Force
            $req = [IO.File]::ReadAllText($RequirementsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $vars = @{}
            foreach ($p in $Config.PSObject.Properties) { $vars[$p.Name] = $p.Value }
            $probes = @(Invoke-PreflightChecks -Requirements $req -Variables $vars)
            $bad = @($probes | Where-Object { -not $_.Ok })
            if ($bad.Count -gt 0) {
                $checks += New-AdmitCheck 'PREFLIGHT' 'fail' 'PREFLIGHT_MISSING' '环境依赖缺失' `
                    @($bad | ForEach-Object { "$($_.Name)：$($_.Detail)" })
            } else {
                $checks += New-AdmitCheck 'PREFLIGHT' 'pass' 'OK' "$($probes.Count) 项环境依赖齐全" @()
            }
        } catch {
            $checks += New-AdmitCheck 'PREFLIGHT' 'warn' 'PREFLIGHT_ERROR' "环境探查失败：$($_.Exception.Message)" @()
        }
    } else {
        $checks += New-AdmitCheck 'PREFLIGHT' 'warn' 'PREFLIGHT_SKIPPED' '缺少 requirements 或 config，跳过' @()
    }

    # 12 FINGERPRINT（机制与哈希在 PadFingerprint.psm1，本脚本不另写一份）
    # 结果码：pass / FINGERPRINT_MISMATCH / FINGERPRINT_UNKNOWN / FINGERPRINT_NO_BASELINE /
    #         FINGERPRINT_FLOW_STALE / SOURCE_MISMATCH / CONFIG_STALE / BASELINE_CORRUPT / AMBIGUOUS
    $basePath = $null
    if ($Paths.Repo -and $FlowName) { $basePath = Get-FingerprintBaselinePath $Paths.Repo $FlowName }
    $fp = Test-FlowFingerprint -FlowName $FlowName -RobinPath $RobinPath -ConfigPath $Paths.ConfigFile `
        -AcceptancePath $AcceptancePath -BaselinePath $basePath `
        -ScriptsRoot $Paths.ScriptsRoot -EnvironmentId $Paths.EnvironmentId `
        -ApprovePath $ApprovePath -Mode $script:FingerprintMode
    $checks += New-AdmitCheck 'FINGERPRINT' $fp.status $fp.code $fp.message $fp.evidence

    # 13 INTENT
    $noIntent = @($actionNodes | Where-Object {
        ([string]$_.pad_hint -like 'Scripting.RunDOSCommand*' -or [string]$_.pad_hint -like 'Scripting.RunVBScript*') -and -not $_.intent
    })
    if ($noIntent.Count -gt 0) {
        $checks += New-AdmitCheck 'INTENT' 'fail' 'MISSING_INTENT' '通用脚本动作缺少 intent 标签，策略只能靠参数名识别（改名即绕过）' `
            @($noIntent | ForEach-Object { "节点 $($_.id) $($_.pad_hint)" })
    } else {
        $checks += New-AdmitCheck 'INTENT' 'pass' 'OK' '通用脚本动作都有 intent' @()
    }

    # 14 TRIGGER（静态校验；live 注册校验留待 -TriggerLive 接入）
    $checks += @(Invoke-TriggerCheck -Flow $Flow -FlowName $FlowName `
        -Repo $Paths.Repo -SelfFile $Paths.FlowFile)

    return $checks
}

if (-not $NoMain) {
    $result = [ordered]@{ ok = $false; flow = $FlowName; fingerprint = $null; checks = @(); summary = $null }
    $exitCode = 1
    try {
        $repo = $script:RepoRoot
        $nameFromLookup = $false
        if (-not $FlowFile) {
            # 不再默认到某个具体业务流程：先按流程名派生，否则要求唯一匹配
            $flowsDir = Join-Path $repo 'business\flows'
            if ($FlowName) {
                # 先 pad_flow_name，再文件名 / name；多命中直接 ADMIT_AMBIGUOUS_FLOW
                $FlowFile = Resolve-FlowFileByName $flowsDir $FlowName
                if (-not $FlowFile) {
                    throw "未提供 -FlowFile，按流程名派生也找不到：$FlowName（business\flows 下无匹配 pad_flow_name / 文件名 / name）；请用 -FlowFile 指定"
                }
                $nameFromLookup = $true
            } else {
                # 只认流程定义：排除 accept/requirements/schema 等配套 json，
                # 再用「有非空 nodes 数组」这一结构特征挡掉 deploy_diff.json 之类同目录产物
                $cands = @(Get-ChildItem -LiteralPath $flowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' } |
                    Where-Object {
                        try {
                            $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                            ($j.PSObject.Properties.Name -contains 'nodes') -and (@($j.nodes).Count -gt 0)
                        } catch { $false }
                    })
                if ($cands.Count -eq 1) {
                    $FlowFile = $cands[0].FullName
                } elseif ($cands.Count -eq 0) {
                    throw "未提供 -FlowFile，flows 目录里也没有流程定义 .json；请用 -FlowFile 指定"
                } else {
                    throw ("未提供 -FlowFile，找到 $($cands.Count) 个候选，请用 -FlowFile 指定：" +
                        (($cands | ForEach-Object { $_.Name }) -join '、'))
                }
            }
        }
        $FlowFile = (Resolve-Path -LiteralPath $FlowFile).Path
        # 按名派生时身份统一取文件名：显示名只是定位键，不能当流程身份（会影响策略 env 与基线路径）
        if ($nameFromLookup) {
            $FlowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile)
        } elseif (-not $FlowName) { $FlowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile) }
        if (-not $RobinFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.robin')
            if (Test-Path -LiteralPath $guess) { $RobinFile = $guess }
        }
        if (-not $AcceptanceFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.acceptance.json')
            if (Test-Path -LiteralPath $guess) { $AcceptanceFile = $guess }
        }
        if (-not $RequirementsFile) {
            $guess = [IO.Path]::ChangeExtension($FlowFile, '.requirements.json')
            if (Test-Path -LiteralPath $guess) { $RequirementsFile = $guess }
        }
        if (-not $PolicyFile) { $PolicyFile = Join-Path $repo 'business\policy.json' }
        if (-not $KbPath) {
            $guess = Join-Path $repo 'pad-robin-action-kb\PAD_Robin_ActionKB.json'
            if (Test-Path -LiteralPath $guess) { $KbPath = $guess }
        }

        $flow = [IO.File]::ReadAllText($FlowFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $config = $null
        # 配置缺失不算致命：CONFIG / PREFLIGHT / FINGERPRINT 会各自记一条 warn
        if ($ConfigFile -and (Test-Path -LiteralPath $ConfigFile)) {
            $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
            $config = [IO.File]::ReadAllText($ConfigFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        } else {
            $ConfigFile = $null
        }
        $kb = $null
        if ($KbPath -and (Test-Path -LiteralPath $KbPath)) {
            $kb = [IO.File]::ReadAllText($KbPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        $policy = $null
        if ($PolicyFile -and (Test-Path -LiteralPath $PolicyFile)) {
            $policy = [IO.File]::ReadAllText($PolicyFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }

        # 指纹检查需要「本地运行历史」与「当前环境」：只读读取，不改任何状态
        $paths = @{
            Repo = $repo; FlowFile = $FlowFile; ConfigFile = $ConfigFile
            ScriptsRoot = (Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts')
            EnvironmentId = (Get-PadEnvironmentId)
        }
        $result.flow = $FlowName
        $result.checks = @(Invoke-AdmitChecks -Flow $flow -FlowName $FlowName -Config $config -Kb $kb `
            -RobinPath $RobinFile -AcceptancePath $AcceptanceFile -RequirementsPath $RequirementsFile `
            -Policy $policy -ApprovePath $ApproveFile -Paths $paths)

        $fail = @($result.checks | Where-Object { $_.status -eq 'fail' })
        $ask = @($result.checks | Where-Object { $_.status -eq 'ask' })
        $warn = @($result.checks | Where-Object { $_.status -eq 'warn' })
        $result.ok = ($fail.Count -eq 0 -and $ask.Count -eq 0)
        $result.summary = [ordered]@{
            total = @($result.checks).Count; pass = @($result.checks | Where-Object { $_.status -eq 'pass' }).Count
            warn = $warn.Count; ask = $ask.Count; fail = $fail.Count
        }
        $exitCode = if ($fail.Count -gt 0) { 1 } elseif ($ask.Count -gt 0) { 2 } else { 0 }
    } catch {
        $result.checks = @(New-AdmitCheck 'ADMIT' 'fail' 'ADMIT_ERROR' $_.Exception.Message @())
        $result.summary = [ordered]@{ total = 1; pass = 0; warn = 0; ask = 0; fail = 1 }
        $exitCode = 1
    }

    if (-not $Json) {
        foreach ($c in $result.checks) {
            Write-Host ("[{0}] {1} {2}：{3}" -f $c.status.ToUpper(), $c.id, $c.code, $c.message)
            foreach ($e in @($c.evidence)) { if ($e) { Write-Host "        - $e" } }
        }
        Write-Host ("[admit] 通过 {0} / 警告 {1} / 待批 {2} / 失败 {3}" -f `
            $result.summary.pass, $result.summary.warn, $result.summary.ask, $result.summary.fail)
    }
    Write-Output ('PAD_ADMIT_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
    exit $exitCode
}
