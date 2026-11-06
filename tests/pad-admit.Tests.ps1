# pad-admit.Tests.ps1 — 准入网关纯函数与端到端测试（Pester 3.4）
#
# 覆盖：通配符匹配、策略 deny/ask/allow 三层顺序、无人值守 ask=deny、
#       真实流程 14 项检查全部可跑（子进程执行，避免 exit 影响测试会话）。

. (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-admit.ps1') -NoMain

$repo = Split-Path -Parent $PSScriptRoot

function New-FlowWith([string]$Hint, $Params) {
    return [pscustomobject]@{
        nodes = @([pscustomobject]@{ id = '1'; pad_hint = $Hint; params = $Params })
    }
}

function New-Policy([string]$Effect) {
    return [pscustomobject]@{
        defaultEffect = 'deny'
        rules = @([pscustomobject]@{
            id = 'r1'; enabled = $true; resource = 'action'; match = 'Outlook.Close*'
            effect = $Effect; approver = 'operator'; reason = '关闭 Outlook 会连带关掉主窗口'
        })
    }
}

Describe 'pad-admit 策略评估' {

    It '通配符只认 * 与 ?，其余字符按字面量' {
        (Test-GlobMatch 'Outlook.Close*' 'Outlook.CloseOutlook') | Should Be $true
        (Test-GlobMatch 'Outlook.Close?' 'Outlook.CloseX') | Should Be $true
        (Test-GlobMatch 'a.b*' 'aXbY') | Should Be $false
    }

    It 'deny 命中：返回 fail 与 POLICY_DENY' {
        $r = @(Invoke-AdmitPolicy (New-FlowWith 'Outlook.Close' ([pscustomobject]@{})) (New-Policy 'deny') @{ env = 'prod'; dryRun = $false; registered = @{} })
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'POLICY_DENY'
    }

    It 'ask 命中：无人值守时降级为 fail；有人值守时是 ask' {
        $flow = New-FlowWith 'Outlook.Close' ([pscustomobject]@{})
        $pol = New-Policy 'ask'
        $ctx = @{ env = 'prod'; dryRun = $false; registered = @{} }
        $a = @(Invoke-AdmitPolicy $flow $pol $ctx)
        $a[0].status | Should Be 'ask'
        $a[0].code | Should Be 'POLICY_ASK'
        $b = @(Invoke-AdmitPolicy $flow $pol $ctx -Unattended)
        $b[0].status | Should Be 'fail'
        $b[0].code | Should Be 'POLICY_ASK_UNATTENDED'
    }

    It 'paramsMatch 只匹配参数内容，不靠节点 id/label' {
        $flow = New-FlowWith 'Scripting.RunDOSCommand.RunDOSCommand' ([pscustomobject]@{ DOSCommandOrApplication = 'cscript.exe //nologo "%MigoVbsPath%"' })
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'migo'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ paramsMatch = [pscustomobject]@{ DOSCommandOrApplication = '*%MigoVbsPath%*' } }
                effect = 'deny'; reason = 'DRY_RUN 下禁止 MIGO'
            })
        }
        $r = @(Invoke-AdmitPolicy $flow $pol @{ env = 'prod'; dryRun = $true; registered = @{} })
        $r[0].code | Should Be 'POLICY_DENY'

        # 同一条规则，参数里没有 MIGO 时不应命中
        $flow2 = New-FlowWith 'Scripting.RunDOSCommand.RunDOSCommand' ([pscustomobject]@{ DOSCommandOrApplication = 'cscript.exe //nologo "%VbsPath%"' })
        $r2 = @(Invoke-AdmitPolicy $flow2 $pol @{ env = 'prod'; dryRun = $true; registered = @{} })
        $r2[0].status | Should Be 'pass'
    }

    It 'intent 匹配：改掉参数名也拦得住' {
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'migo'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ dryRun = $true; intent = 'sap-migo' }
                effect = 'deny'; reason = 'DRY_RUN 下禁止 MIGO'
            })
        }
        $ctx = @{ env = 'prod'; dryRun = $true; registered = @{} }
        # 参数名随便改，只要 intent 还在就命中
        $flow = [pscustomobject]@{ nodes = @([pscustomobject]@{
            id = '1'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; intent = 'sap-migo'
            params = [pscustomobject]@{ DOSCommandOrApplication = 'whatever.exe' }
        }) }
        (@(Invoke-AdmitPolicy $flow $pol $ctx))[0].code | Should Be 'POLICY_DENY'

        # intent 改名后不再命中
        $flow2 = [pscustomobject]@{ nodes = @([pscustomobject]@{
            id = '1'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; intent = 'other'
            params = [pscustomobject]@{ DOSCommandOrApplication = 'whatever.exe' }
        }) }
        (@(Invoke-AdmitPolicy $flow2 $pol $ctx))[0].status | Should Be 'pass'
    }

    It '被 DRY_RUN 守卫包住的副作用，dryRun 规则不再命中' {
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'migo'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ dryRun = $true; intent = 'sap-migo' }
                effect = 'deny'; reason = 'DRY_RUN 下禁止 MIGO'
            })
        }
        $ctx = @{ env = 'prod'; dryRun = $true; registered = @{} }
        $migo = [pscustomobject]@{
            id = 'm'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; intent = 'sap-migo'
            params = [pscustomobject]@{ DOSCommandOrApplication = 'cscript' }
        }
        # 守卫内：测试模式本来就不会执行，准入放行
        $guarded = [pscustomobject]@{ nodes = @(
            [pscustomobject]@{ id = 'g'; pad_hint = 'GUARD'; when = "DryRun <> $'''1'''"; body = @('m'); elseBody = @() },
            $migo
        ) }
        (@(Invoke-AdmitPolicy $guarded $pol $ctx))[0].status | Should Be 'pass'
        # 守卫外：同样条件就应被拒
        $bare = [pscustomobject]@{ nodes = @($migo) }
        (@(Invoke-AdmitPolicy $bare $pol $ctx))[0].code | Should Be 'POLICY_DENY'
    }

    It '未声明 budget、脚本动作缺 intent 时直接失败' {
        $flow = [pscustomobject]@{ nodes = @([pscustomobject]@{
            id = '1'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'
            params = [pscustomobject]@{ DOSCommandOrApplication = 'x' }
        }) }
        $checks = @(Invoke-AdmitChecks -Flow $flow -FlowName 'demo' -Config $null -Kb $null `
            -RobinPath $null -AcceptancePath $null -RequirementsPath $null -Policy $null `
            -ApprovePath $null -Paths @{ Repo = $repo; FlowFile = 'x'; ConfigFile = $null })
        (@($checks | Where-Object { $_.id -eq 'BUDGET' }))[0].status | Should Be 'fail'
        (@($checks | Where-Object { $_.id -eq 'INTENT' }))[0].status | Should Be 'fail'
    }

    It '通用示例流程：准入端到端可跑通，退出码 0' {
        # 用仓库自带的通用示例流程，不依赖任何具体业务流程文件；
        # 指纹默认 fail 后，没有 .robin/基线的流程会被拦截，
        # 所以先生成临时 .robin 并写一份批准记录，让本用例只验证准入链路本身
        $out = Join-Path $TestDrive ('admit-' + [guid]::NewGuid().ToString('N') + '.txt')
        $tmp = Join-Path $TestDrive ('e2e-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $robin = Join-Path $tmp 'example-flow.robin'
        & node (Join-Path $repo 'tools\pad-robin\flow-to-robin.js') `
            (Join-Path $repo 'tools\flow-drawio\example-flow.json') $robin | Out-Null
        $LASTEXITCODE | Should Be 0
        $approve = Join-Path $tmp 'approve.jsonl'
        $hash = (Get-FileHash -LiteralPath $robin -Algorithm SHA256).Hash.ToLower()
        [IO.File]::WriteAllText($approve, ('{"robin":"' + $hash + '"}'), (New-Object Text.UTF8Encoding($false)))
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\pad-sync\pad-admit.ps1') `
            -FlowFile (Join-Path $repo 'tools\flow-drawio\example-flow.json') `
            -RobinFile $robin -ApproveFile $approve *> $out
        $LASTEXITCODE | Should Be 0
        $line = @([IO.File]::ReadAllLines($out, [Text.Encoding]::UTF8) | Where-Object { $_ -match '^PAD_ADMIT_RESULT=' })
        $line.Count | Should Be 1
        $res = ($line[0].Substring('PAD_ADMIT_RESULT='.Length) | ConvertFrom-Json)
        $res.ok | Should Be $true
        @($res.checks).Count | Should BeGreaterThan 9
        @($res.checks | Where-Object { $_.id -eq 'BUDGET' })[0].status | Should Be 'pass'
    }
}

Describe 'pad-admit TRIGGER 第 14 项（观察期 warn）' {
    It '无 trigger：warn + TRIGGER_MISSING' {
        $f = [pscustomobject]@{ nodes = @() }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].id | Should Be 'TRIGGER'
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_MISSING'
    }

    It '旧 type/config 形状：warn + TRIGGER_LEGACY_SHAPE' {
        $trg = [pscustomobject]@{ type = 'schedule'; config = [pscustomobject]@{ dayOfMonth = 3 } }
        $f = [pscustomobject]@{ nodes = @(); trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_LEGACY_SHAPE'
    }

    It 'kind=mail：fail + TRIGGER_KIND_UNSUPPORTED' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'mail' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_KIND_UNSUPPORTED'
    }

    It 'file.dir 是字面路径：fail + TRIGGER_PATH_LITERAL' {
        $trg = [pscustomobject]@{
            kind = 'file'; time = '08:30'
            file = [pscustomobject]@{ dir = '<附件目录>/inbox'; pattern = '*.xlsx' }
        }
        $f = [pscustomobject]@{ nodes = @(); trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_PATH_LITERAL'
    }

    It 'schedule + run_mode=confirm 节点：fail + TRIGGER_UNATTENDED_CONFIRM' {
        $nodes = @([pscustomobject]@{ id = '9'; pad_hint = 'Display.ShowMessageDialog.ShowMessage'; run_mode = 'confirm'; idempotent = $true })
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_UNATTENDED_CONFIRM'
        ($r[0].evidence -join ' ') | Should Match '节点 9'
    }

    It 'schedule 缺 time：fail + TRIGGER_INVALID' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'schedule' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_INVALID'
    }

    It 'manual 最小声明：pass 且 message 带 kind' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'manual' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'pass'
        $r[0].message | Should Match 'manual'
    }

    It '节点全是 reversible=true：不报可逆性 warn' {
        $nodes = @(
            [pscustomobject]@{ id = '3'; pad_hint = 'Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments'; run_mode = 'auto'; idempotent = $false; reversible = $true },
            [pscustomobject]@{ id = '46'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; run_mode = 'auto'; idempotent = $false; reversible = $true }
        )
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'pass'
        @($r | Where-Object { $_.code -eq 'TRIGGER_UNATTENDED_IRREVERSIBLE' }).Count | Should Be 0
        @($r | Where-Object { $_.code -eq 'TRIGGER_MISSING_REVERSIBILITY' }).Count | Should Be 0
    }

    It '存在 reversible=false：warn + TRIGGER_UNATTENDED_IRREVERSIBLE，证据带节点与说明' {
        $nodes = @(
            [pscustomobject]@{ id = '43'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; run_mode = 'auto'; idempotent = $false
                reversible = $false; reversibility_note = '过账需冲销凭证' }
        )
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_UNATTENDED_IRREVERSIBLE'
        ($r[0].evidence -join ' ') | Should Match '节点 43'
        ($r[0].evidence -join ' ') | Should Match '过账需冲销凭证'
    }

    It 'idempotent=false 缺 reversible：warn + TRIGGER_MISSING_REVERSIBILITY' {
        $nodes = @(
            [pscustomobject]@{ id = '29'; pad_hint = 'Outlook.SendEmailThroughOutlook.SendEmail'; run_mode = 'auto'; idempotent = $false }
        )
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_MISSING_REVERSIBILITY'
        ($r[0].evidence -join ' ') | Should Match '节点 29'
    }

    It 'manual 声明：reversible=false 也不报可逆性 warn' {
        $nodes = @(
            [pscustomobject]@{ id = '43'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; run_mode = 'auto'
                idempotent = $false; reversible = $false }
        )
        $f = [pscustomobject]@{ nodes = $nodes; trigger = [pscustomobject]@{ kind = 'manual' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'pass'
    }
}

Describe 'pad-admit 不再默认到具体业务流程' {
    It '未传 -FlowFile 且按流程名派生不到：非零退出，且不进入准入检查' {
        $out = Join-Path $TestDrive ('admit-' + [guid]::NewGuid().ToString('N') + '.txt')
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-admit.ps1') `
            -FlowName 'NoSuchFlow-XYZ' *> $out
        $LASTEXITCODE | Should Not Be 0
        $text = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
        $text | Should Match '未提供 -FlowFile'
        $text | Should Match '-FlowFile'
        # 必须在读取流程定义之前失败，不能输出 14 项准入检查的汇总
        $text | Should Not Match '"total":14'
        $text | Should Not Match 'POLICY_'
    }
}
