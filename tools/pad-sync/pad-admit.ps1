# pad-admit.ps1 — 只读准入网关：部署/运行前判断"这份流程、这次运行是否被允许"
#
# 对应 docs/admission-gate.md 的 13 项检查。硬约束：
#   1) 只读：不启动 PAD、不连 SAP、不发邮件、不写产物
#   2) 一次返回全部问题，不因第一条失败提前退出
#   3) 每条失败带 code + 人话 + 证据（节点 id / 参数 / 文件名）
#
# 用法：
#   .\pad-admit.ps1 -FlowFile flows\sample.json -ConfigFile config\sample.json
#   .\pad-admit.ps1 -FlowFile ... -Unattended      # 定时任务场景：ask 一律按 deny
#   .\pad-admit.ps1 -FlowFile ... -Json            # 只输出 JSON
#
# 退出码：0 全部通过 / 1 存在 fail / 2 仅存在 ask
# 与文档的差异（报告模式下更实用，已记录）：
#   - BUDGET 未声明时记 warn 而不是 fail（否则所有存量流程都过不了）
#   - INTENT 缺失记 warn（策略仍可用 paramsMatch 兜底）
#   - 未提供批准记录时 FINGERPRINT 记 warn

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

$CONTROL_HINTS = @('IF', 'LOOP', 'SWITCH', 'GUARD', 'WAIT', 'EXIT LOOP', 'EXIT_LOOP')

# 通配符匹配：只支持 * 与 ?，其余字符按字面量，避免正则元字符误伤
function Test-GlobMatch([string]$Pattern, [string]$Text) {
    if ($null -eq $Pattern) { return $false }
    if ($Pattern -eq '*') { return $true }
    $escaped = [regex]::Escape([string]$Pattern)
    $rx = '^' + $escaped.Replace('\*', '.*').Replace('\?', '.') + '$'
    return ($Text -match $rx)
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

# 策略评估：固定 deny → ask → allow；同层取第一条命中；全部未命中按 defaultEffect
# 返回 { checks, hits }，checks 里最多一条 POLICY 结论
function Invoke-AdmitPolicy($Flow, $Policy, [hashtable]$Ctx, [switch]$Unattended) {
    $results = @()
    $rules = @($Policy.rules | Where-Object { $_.enabled })
    $actionNodes = @($Flow.nodes | Where-Object {
        $_.pad_hint -and $CONTROL_HINTS -notcontains [string]$_.pad_hint
    })

    $denies = @()
    $asks = @()
    $allows = @()

    foreach ($node in $actionNodes) {
        foreach ($rule in $rules) {
            if ([string]$rule.resource -ne 'action') { continue }
            if (-not (Test-GlobMatch ([string]$rule.match) ([string]$node.pad_hint))) { continue }
            if (-not (Test-RuleWhen $rule $node $Ctx)) { continue }
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

# 主体检查：一次跑完 13 项
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
        $argErrs = @()
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
                if ($paramNames -notcontains [string]$p.name) {
                    $argErrs += "节点 $($n.id) 缺少必填参数 $($p.name)"
                }
            }
        }
        if ($argErrs.Count -gt 0) {
            $checks += New-AdmitCheck 'ARGS' 'fail' 'UNKNOWN_PARAM' '参数与 KB 不一致' $argErrs
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
        $checks += New-AdmitCheck 'POLICY' 'warn' 'POLICY_MISSING' '没有 policy.json，跳过策略评估' @()
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
        $checks += New-AdmitCheck 'BUDGET' 'warn' 'BUDGET_UNKNOWN' 'flow.json 未声明 budget，预算未知' @()
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

    # 12 FINGERPRINT
    $fpParts = [ordered]@{ robin = $null; config = $null; acceptance = $null }
    foreach ($pair in @(@('robin', $RobinPath), @('config', $Paths.ConfigFile), @('acceptance', $AcceptancePath))) {
        if ($pair[1] -and (Test-Path -LiteralPath $pair[1])) {
            $fpParts[$pair[0]] = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLower()
        }
    }
    $fpLine = ($fpParts.Keys | Where-Object { $fpParts[$_] } | ForEach-Object { "$_=$($fpParts[$_].Substring(0, 12))" }) -join ' '
    if ($ApprovePath -and (Test-Path -LiteralPath $ApprovePath)) {
        $ok = $false
        foreach ($l in [IO.File]::ReadAllLines($ApprovePath, [Text.Encoding]::UTF8)) {
            if (-not $l.Trim()) { continue }
            $rec = $l | ConvertFrom-Json
            if ([string]$rec.robin -eq [string]$fpParts.robin -and
                [string]$rec.config -eq [string]$fpParts.config -and
                [string]$rec.acceptance -eq [string]$fpParts.acceptance) { $ok = $true; break }
        }
        if ($ok) {
            $checks += New-AdmitCheck 'FINGERPRINT' 'pass' 'OK' "与批准记录一致：$fpLine" @()
        } else {
            $checks += New-AdmitCheck 'FINGERPRINT' 'fail' 'FINGERPRINT_MISMATCH' "与批准记录不一致：$fpLine" @()
        }
    } else {
        $checks += New-AdmitCheck 'FINGERPRINT' 'warn' 'FINGERPRINT_UNVERIFIED' "未提供批准记录：$fpLine" @()
    }

    # 13 INTENT
    $noIntent = @($actionNodes | Where-Object {
        ([string]$_.pad_hint -like 'Scripting.RunDOSCommand*' -or [string]$_.pad_hint -like 'Scripting.RunVBScript*') -and -not $_.intent
    })
    if ($noIntent.Count -gt 0) {
        $checks += New-AdmitCheck 'INTENT' 'warn' 'MISSING_INTENT' '通用脚本动作缺少 intent 标签，策略只能靠参数名识别' `
            @($noIntent | ForEach-Object { "节点 $($_.id) $($_.pad_hint)" })
    } else {
        $checks += New-AdmitCheck 'INTENT' 'pass' 'OK' '通用脚本动作都有 intent' @()
    }

    return $checks
}

if (-not $NoMain) {
    $result = [ordered]@{ ok = $false; flow = $FlowName; fingerprint = $null; checks = @(); summary = $null }
    $exitCode = 1
    try {
        $repo = $script:RepoRoot
        if (-not $FlowFile) { $FlowFile = Join-Path $repo 'tools\flow-drawio\example-flow.json' }
        $FlowFile = (Resolve-Path -LiteralPath $FlowFile).Path
        if (-not $FlowName) { $FlowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile) }
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
        if (-not $PolicyFile) { $PolicyFile = Join-Path $repo 'policy.json' }
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

        $paths = @{ Repo = $repo; FlowFile = $FlowFile; ConfigFile = $ConfigFile }
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
