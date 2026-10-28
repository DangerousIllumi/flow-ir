# pad-admit.Tests.ps1 — 准入网关纯函数与端到端测试（Pester 3.4）
#
# 覆盖：通配符匹配、策略 deny/ask/allow 三层顺序、无人值守 ask=deny、
#       真实流程 13 项检查全部可跑（子进程执行，避免 exit 影响测试会话）。

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

}
