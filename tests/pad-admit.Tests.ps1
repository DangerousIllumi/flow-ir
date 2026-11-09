# pad-admit.Tests.ps1 — 准入网关纯函数与端到端测试（Pester 3.4）
#
# 覆盖：通配符匹配、策略 deny/ask/allow 三层顺序、无人值守 ask=deny、
#       真实流程全部检查项可跑（子进程执行，避免 exit 影响测试会话）。

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

Describe 'pad-admit policy evaluation' {

    It 'glob matching honors only * and ?; other characters are literal' {
        (Test-GlobMatch 'Outlook.Close*' 'Outlook.CloseOutlook') | Should Be $true
        (Test-GlobMatch 'Outlook.Close?' 'Outlook.CloseX') | Should Be $true
        (Test-GlobMatch 'a.b*' 'aXbY') | Should Be $false
    }

    It 'deny match: returns fail with POLICY_DENY' {
        $r = @(Invoke-AdmitPolicy (New-FlowWith 'Outlook.Close' ([pscustomobject]@{})) (New-Policy 'deny') @{ env = 'prod'; dryRun = $false; registered = @{} })
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'POLICY_DENY'
    }

    It 'ask match: downgraded to fail when unattended; ask when attended' {
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

    It 'paramsMatch matches parameter content only, not node id or label' {
        $flow = New-FlowWith 'Scripting.RunDOSCommand.RunDOSCommand' ([pscustomobject]@{ DOSCommandOrApplication = 'cscript.exe //nologo "%PostingVbsPath%"' })
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'posting'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ paramsMatch = [pscustomobject]@{ DOSCommandOrApplication = '*%PostingVbsPath%*' } }
                effect = 'deny'; reason = 'DRY_RUN 下禁止过账'
            })
        }
        $r = @(Invoke-AdmitPolicy $flow $pol @{ env = 'prod'; dryRun = $true; registered = @{} })
        $r[0].code | Should Be 'POLICY_DENY'

        # 同一条规则，参数里没有 %PostingVbsPath% 时不应命中
        $flow2 = New-FlowWith 'Scripting.RunDOSCommand.RunDOSCommand' ([pscustomobject]@{ DOSCommandOrApplication = 'cscript.exe //nologo "%VbsPath%"' })
        $r2 = @(Invoke-AdmitPolicy $flow2 $pol @{ env = 'prod'; dryRun = $true; registered = @{} })
        $r2[0].status | Should Be 'pass'
    }

    It 'intent match: still blocked after renaming a parameter' {
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'posting'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ dryRun = $true; intent = 'sap-posting' }
                effect = 'deny'; reason = 'DRY_RUN 下禁止过账'
            })
        }
        $ctx = @{ env = 'prod'; dryRun = $true; registered = @{} }
        # 参数名随便改，只要 intent 还在就命中
        $flow = [pscustomobject]@{ nodes = @([pscustomobject]@{
            id = '1'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; intent = 'sap-posting'
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

    It 'side effect wrapped in a DRY_RUN guard: the dryRun rule no longer matches' {
        $pol = [pscustomobject]@{
            defaultEffect = 'allow'
            rules = @([pscustomobject]@{
                id = 'posting'; enabled = $true; resource = 'action'; match = 'Scripting.RunDOSCommand*'
                when = [pscustomobject]@{ dryRun = $true; intent = 'sap-posting' }
                effect = 'deny'; reason = 'DRY_RUN 下禁止过账'
            })
        }
        $ctx = @{ env = 'prod'; dryRun = $true; registered = @{} }
        $posting = [pscustomobject]@{
            id = 'm'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; intent = 'sap-posting'
            params = [pscustomobject]@{ DOSCommandOrApplication = 'cscript' }
        }
        # 守卫内：测试模式本来就不会执行，准入放行
        $guarded = [pscustomobject]@{ nodes = @(
            [pscustomobject]@{ id = 'g'; pad_hint = 'GUARD'; when = "DryRun <> $'''1'''"; body = @('m'); elseBody = @() },
            $posting
        ) }
        (@(Invoke-AdmitPolicy $guarded $pol $ctx))[0].status | Should Be 'pass'
        # 守卫外：同样条件就应被拒
        $bare = [pscustomobject]@{ nodes = @($posting) }
        (@(Invoke-AdmitPolicy $bare $pol $ctx))[0].code | Should Be 'POLICY_DENY'
    }

    It 'missing budget or script action without intent fails outright' {
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

    It 'general sample flow: admission passes end to end with exit code 0' {
        # 用仓库自带的通用示例流程，不依赖任何具体业务流程文件；
        # 指纹默认 fail 后，没有 .robin/基线的流程会被拦截，
        # 所以先生成临时 .robin 并写一份批准记录，让本用例只验证准入链路本身
        $out = Join-Path $TestDrive ('admit-' + [guid]::NewGuid().ToString('N') + '.txt')
        $tmp = Join-Path $TestDrive ('e2e-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $robin = Join-Path $tmp 'example-flow.robin'
        # 生成器把"已生成"写 stderr；这里临时放宽 EAP，避免被当成终止错误
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & node (Join-Path $repo 'tools\pad-robin\flow-to-robin.js') `
            (Join-Path $repo 'tools\flow-drawio\example-flow.json') $robin 2>$null | Out-Null
        $ErrorActionPreference = $eap
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

    It 'missing baseline: report mode passes with a fix command while -Unattended still fails' {
        # 用 examples 的中性流程，验证「未发布 = 没基线」的分级：
        # 普通准入 exit 0（FINGERPRINT warn），发布/部署口径 -Unattended exit 1（FINGERPRINT fail）
        $tmp = Join-Path $TestDrive ('nobl-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $flowFile = Join-Path $repo 'examples\smoke-flow.json'
        $robin = Join-Path $tmp 'smoke-flow.robin'
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & node (Join-Path $repo 'tools\pad-robin\flow-to-robin.js') $flowFile $robin 2>$null | Out-Null
        $ErrorActionPreference = $eap
        $LASTEXITCODE | Should Be 0

        $reportOut = Join-Path $tmp 'report.txt'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\pad-sync\pad-admit.ps1') `
            -FlowFile $flowFile -RobinFile $robin *> $reportOut
        $LASTEXITCODE | Should Be 0
        $line = @([IO.File]::ReadAllLines($reportOut, [Text.Encoding]::UTF8) | Where-Object { $_ -match '^PAD_ADMIT_RESULT=' })
        $res = ($line[0].Substring('PAD_ADMIT_RESULT='.Length) | ConvertFrom-Json)
        $fp = @($res.checks | Where-Object { $_.id -eq 'FINGERPRINT' })[0]
        $fp.status | Should Be 'warn'
        $fp.code | Should Be 'FINGERPRINT_NO_BASELINE'
        $fp.message | Should Match 'pad-fingerprint\.ps1'
        $fp.message | Should Match '-Set -Confirm'

        $prodOut = Join-Path $tmp 'prod.txt'
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\pad-sync\pad-admit.ps1') `
            -FlowFile $flowFile -RobinFile $robin -Unattended *> $prodOut
        $LASTEXITCODE | Should Be 1
        $line = @([IO.File]::ReadAllLines($prodOut, [Text.Encoding]::UTF8) | Where-Object { $_ -match '^PAD_ADMIT_RESULT=' })
        $res = ($line[0].Substring('PAD_ADMIT_RESULT='.Length) | ConvertFrom-Json)
        $fp = @($res.checks | Where-Object { $_.id -eq 'FINGERPRINT' })[0]
        $fp.status | Should Be 'fail'
        $fp.code | Should Be 'FINGERPRINT_NO_BASELINE'
    }
}

Describe 'pad-admit TRIGGER (observation period warns)' {
    It 'no trigger: warn + TRIGGER_MISSING' {
        $f = [pscustomobject]@{ nodes = @() }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].id | Should Be 'TRIGGER'
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_MISSING'
    }

    It 'legacy type/config shape: warn + TRIGGER_LEGACY_SHAPE' {
        $trg = [pscustomobject]@{ type = 'schedule'; config = [pscustomobject]@{ dayOfMonth = 3 } }
        $f = [pscustomobject]@{ nodes = @(); trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_LEGACY_SHAPE'
    }

    It 'kind=mail: fail + TRIGGER_KIND_UNSUPPORTED' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'mail' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_KIND_UNSUPPORTED'
    }

    It 'file.dir is a literal path: fail + TRIGGER_PATH_LITERAL' {
        $trg = [pscustomobject]@{
            kind = 'file'; time = '08:30'
            file = [pscustomobject]@{ dir = '<附件目录>/inbox'; pattern = '*.xlsx' }
        }
        $f = [pscustomobject]@{ nodes = @(); trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_PATH_LITERAL'
    }

    It 'schedule with a run_mode=confirm node: fail + TRIGGER_UNATTENDED_CONFIRM' {
        $nodes = @([pscustomobject]@{ id = '9'; pad_hint = 'Display.ShowMessageDialog.ShowMessage'; run_mode = 'confirm'; idempotent = $true })
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_UNATTENDED_CONFIRM'
        ($r[0].evidence -join ' ') | Should Match 'node 9'
    }

    It 'schedule without time: fail + TRIGGER_INVALID' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'schedule' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'TRIGGER_INVALID'
    }

    It 'minimal manual declaration: pass with kind in the message' {
        $f = [pscustomobject]@{ nodes = @(); trigger = [pscustomobject]@{ kind = 'manual' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'pass'
        $r[0].message | Should Match 'manual'
    }

    It 'every node has reversible=true: no reversibility warning' {
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

    It 'a reversible=false node: warn + TRIGGER_UNATTENDED_IRREVERSIBLE with node and note in the evidence' {
        $nodes = @(
            [pscustomobject]@{ id = '43'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; run_mode = 'auto'; idempotent = $false
                reversible = $false; reversibility_note = '过账需冲销凭证' }
        )
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_UNATTENDED_IRREVERSIBLE'
        ($r[0].evidence -join ' ') | Should Match 'node 43'
        ($r[0].evidence -join ' ') | Should Match '过账需冲销凭证'
    }

    It 'idempotent=false without reversible: warn + TRIGGER_MISSING_REVERSIBILITY' {
        $nodes = @(
            [pscustomobject]@{ id = '29'; pad_hint = 'Outlook.SendEmailThroughOutlook.SendEmail'; run_mode = 'auto'; idempotent = $false }
        )
        $trg = [pscustomobject]@{ kind = 'schedule'; time = '09:00'; gate = 'workday' }
        $f = [pscustomobject]@{ nodes = $nodes; trigger = $trg }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_MISSING_REVERSIBILITY'
        ($r[0].evidence -join ' ') | Should Match 'node 29'
    }

    It 'irreversible action marked reversible=true: fail + REVERSIBLE_MISLABELED' {
        $f = [pscustomobject]@{
            nodes = @([pscustomobject]@{ id = '44'; pad_hint = 'Outlook.SendEmailThroughOutlook.SendEmail'
                run_mode = 'auto'; idempotent = $false; reversible = $true })
            trigger = [pscustomobject]@{ kind = 'manual' }
        }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $hit = @($r | Where-Object { $_.code -eq 'REVERSIBLE_MISLABELED' })
        $hit.Count | Should Be 1
        $hit[0].status | Should Be 'fail'
        ($hit[0].evidence -join ' ') | Should Match 'node 44'
    }

    It 'manual declaration: reversible=false also warns about reversibility (visible in report mode)' {
        $nodes = @(
            [pscustomobject]@{ id = '43'; pad_hint = 'Scripting.RunDOSCommand.RunDOSCommand'; run_mode = 'auto'
                idempotent = $false; reversible = $false }
        )
        $f = [pscustomobject]@{ nodes = $nodes; trigger = [pscustomobject]@{ kind = 'manual' } }
        $r = @(Invoke-TriggerCheck -Flow $f -FlowName 'demo-flow' -Repo $repo -SelfFile 'x')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'TRIGGER_UNATTENDED_IRREVERSIBLE'
        ($r[0].evidence -join ' ') | Should Match 'node 43'
    }
}

Describe 'pad-admit INPUT (node-level input file declarations)' {

    function New-InputNode($Entries) {
        return [pscustomobject]@{
            id = '1'; pad_hint = 'File.ReadTextFromFile.ReadText'; inputs = @($Entries)
        }
    }

    It 'inputs not declared: warn + INPUT_UNDECLARED, not a failure' {
        $f = [pscustomobject]@{ nodes = @([pscustomobject]@{ id = '1'; pad_hint = 'File.ReadTextFromFile.ReadText' }) }
        $r = @(Invoke-InputCheck -Flow $f -Config $null -ConfigFile $null)
        $r.Count | Should Be 1
        $r[0].id | Should Be 'INPUT'
        $r[0].status | Should Be 'warn'
        $r[0].code | Should Be 'INPUT_UNDECLARED'
    }

    It 'required input missing: fail + INPUT_FILE_MISSING' {
        $dir = Join-Path $TestDrive ('in-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $node = New-InputNode @([pscustomobject]@{ dir = '{{config.InputDir}}'; pattern = '*.csv'; required = $true })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config ([pscustomobject]@{ InputDir = $dir }) -ConfigFile 'demo.json')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'INPUT_FILE_MISSING'
        ($r[0].evidence -join ' ') | Should Match 'node 1'
    }

    It 'multiple candidates: fail + INPUT_FILE_AMBIGUOUS; evidence lists all candidates and never picks the newest' {
        $dir = Join-Path $TestDrive ('in-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'a.csv'), '1', (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText((Join-Path $dir 'b.csv'), '2', (New-Object Text.UTF8Encoding($false)))
        $node = New-InputNode @([pscustomobject]@{ dir = '{{config.InputDir}}'; pattern = '*.csv'; required = $true })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config ([pscustomobject]@{ InputDir = $dir }) -ConfigFile 'demo.json')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'INPUT_FILE_AMBIGUOUS'
        ($r[0].evidence -join ' ') | Should Match 'a.csv'
        ($r[0].evidence -join ' ') | Should Match 'b.csv'
    }

    It 'optional input missing: pass, no error' {
        $dir = Join-Path $TestDrive ('in-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $node = New-InputNode @([pscustomobject]@{ dir = '{{config.InputDir}}'; pattern = '*.csv'; required = $false })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config ([pscustomobject]@{ InputDir = $dir }) -ConfigFile 'demo.json')
        $r.Count | Should Be 1
        $r[0].status | Should Be 'pass'
        $r[0].code | Should Be 'OK'
    }

    It 'directory is a literal path: fail + INPUT_PATH_LITERAL' {
        $node = New-InputNode @([pscustomobject]@{ dir = '<输入目录>/inbox'; pattern = '*.csv'; required = $true })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config ([pscustomobject]@{}) -ConfigFile 'demo.json')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'INPUT_PATH_LITERAL'
    }

    It 'no config supplied: fail + INPUT_CONFIG_UNRESOLVED; no fallback to a literal path' {
        $node = New-InputNode @([pscustomobject]@{ dir = '{{config.InputDir}}'; pattern = '*.csv'; required = $true })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config $null -ConfigFile $null)
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'INPUT_CONFIG_UNRESOLVED'
    }

    It 'required not declared explicitly: fail + INPUT_INVALID (no default fill-in)' {
        $dir = Join-Path $TestDrive ('in-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $node = New-InputNode @([pscustomobject]@{ dir = '{{config.InputDir}}'; pattern = '*.csv' })
        $f = [pscustomobject]@{ nodes = @($node) }
        $r = @(Invoke-InputCheck -Flow $f -Config ([pscustomobject]@{ InputDir = $dir }) -ConfigFile 'demo.json')
        $r[0].status | Should Be 'fail'
        $r[0].code | Should Be 'INPUT_INVALID'
    }
}

Describe 'pad-admit no longer defaults to a concrete business flow' {
    It 'no -FlowFile and the flow name resolves to nothing: non-zero exit before any admission check' {
        $out = Join-Path $TestDrive ('admit-' + [guid]::NewGuid().ToString('N') + '.txt')
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-admit.ps1') `
            -FlowName 'NoSuchFlow-XYZ' *> $out
        $LASTEXITCODE | Should Not Be 0
        $text = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
        $text | Should Match 'ADMIT_ERROR'
        $text | Should Match 'E_FLOW_FILE_REQUIRED'
        $text | Should Match '-FlowFile'
        # 必须在读取流程定义之前失败，不能输出 14 项准入检查的汇总
        $text | Should Not Match '"total":14'
        $text | Should Not Match 'POLICY_'
    }
}
