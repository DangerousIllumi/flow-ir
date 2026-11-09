# pad-fingerprint.Tests.ps1 — tests for the flow fingerprint module (Pester 3.4, bundled with PowerShell 5.1)
#
# Every test builds synthetic Workspace / Scripts roots under TestDrive: it never hardcodes LOCALAPPDATA,
# registers no scheduled task, starts no PAD and triggers no real flow.
# Covers: identical hashes / content drift / unreadable definition, identity change, missing or corrupt baseline, seeding that needs a human confirmation.

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadFingerprint.psm1'
$script:Script = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-fingerprint.ps1'
Import-Module $script:Module -Force

function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

function Write-RunDef([string]$Path, [string]$FlowGuid, [string]$FlowName, [string]$StartTime) {
    $json = '{"startTime":"' + $StartTime + '","status":"Succeeded","workflow":{"workflowId":"' + $FlowGuid + '","name":"' + $FlowName + '"}}'
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

# Build a minimal Scripts + Workspace pair: the runId directory name is also the revision directory name
function New-FakePad([string]$Work, [string]$FlowName, [string]$FlowGuid, [string]$RunId, [string]$RobinText = "SET A TO 'x'") {
    $scripts = Join-Path $Work 'Scripts'
    $ws = Join-Path $Work 'Workspace'
    Write-RunDef (Join-Path $scripts "$FlowGuid\Runs\$RunId\RunDefinition.json") $FlowGuid $FlowName '2026-11-03T09:00:00Z'
    $revDir = Join-Path $ws "$FlowGuid\$RunId"
    New-Item -ItemType Directory -Path $revDir -Force | Out-Null
    $robin = Join-Path $revDir 'script.robin'
    [IO.File]::WriteAllText($robin, $RobinText, (New-Object Text.UTF8Encoding($false)))
    # The deployment artifact (a copy with placeholders substituted) sits beside the source: the published side of the fingerprint only trusts it
    $deployed = Join-Path $revDir 'script.deployed.robin'
    [IO.File]::WriteAllText($deployed, $RobinText, (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ scripts = $scripts; workspace = $ws; robin = $robin; deployed = $deployed; runId = $RunId }
}

Describe 'PadFingerprint location and identity' {

    It 'parses GUID and runId from an Actions.log path; non-run paths return null' {
        $p = 'C:\Users\x\Console\Scripts\CFD13222-CA5B-447E-B7FF-51FE823BA40B\Runs\d0a4989f-5798-45bb-b6b3-c8658d54fc52\Actions.log'
        $ids = Get-FlowGuidFromLogPath $p
        $ids.flowGuid | Should Be 'cfd13222-ca5b-447e-b7ff-51fe823ba40b'
        $ids.runId | Should Be 'd0a4989f-5798-45bb-b6b3-c8658d54fc52'
        (Get-FlowGuidFromLogPath 'C:\temp\nothing.log') | Should Be $null
    }

    It 'Workspace lookup: exact runId match; other old revisions are excluded' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $runId = '22222222-2222-2222-2222-222222222222'
        $fake = New-FakePad $work 'F' $g $runId
        # Another revision written before this run: outside the time window, so it never becomes a candidate
        $other = Join-Path $fake.workspace "$g\OLD00001"
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        $op = Join-Path $other 'script.robin'
        [IO.File]::WriteAllText($op, "SET B TO 'y'", (New-Object Text.UTF8Encoding($false)))
        (Get-Item $op).LastWriteTime = [datetime]::UtcNow.AddDays(-5)
        (Find-WorkspaceRobin $fake.workspace $g $runId ([datetime]::UtcNow.AddHours(-1))) | Should Be $fake.robin
    }

    It 'Workspace lookup: multiple candidates raise an error instead of silently picking one' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        foreach ($rev in 'AAAA0001', 'BBBB0002') {
            $d = Join-Path $work "Workspace\$g\$rev"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            $p = Join-Path $d 'script.robin'
            [IO.File]::WriteAllText($p, 'x', (New-Object Text.UTF8Encoding($false)))
            (Get-Item $p).LastWriteTime = [datetime]::UtcNow.AddMinutes(-5)
        }
        $ex = $null
        try { $null = Find-WorkspaceRobin (Join-Path $work 'Workspace') $g '' ([datetime]::UtcNow.AddDays(-1)) }
        catch { $ex = $_.Exception }
        $ex.Data['code'] | Should Be 'FINGERPRINT_AMBIGUOUS'
        $ex.Message | Should Match '2 candidate revisions'
    }

    It 'environment ID: reads the first EnvironmentId from a synthetic console.config; null when unreadable' {
        $work = New-Work
        $p = Join-Path $work 'console.config'
        [IO.File]::WriteAllText($p, '{"UserConfigs":{"-1":{"EnvironmentId":"Default-abc"}}}', (New-Object Text.UTF8Encoding($false)))
        (Get-PadEnvironmentId $p) | Should Be 'Default-abc'
        (Get-PadEnvironmentId (Join-Path $work 'missing.config')) | Should Be $null
    }
}

Describe 'PadFingerprint comparison' {

    It 'identical hashes: baseline and the current triple match -> pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $cfg = Join-Path $work 'config.json'
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $cfg -AcceptancePath $null `
            -ScriptPaths @('tools/workday/workday.py') -ExternalPaths @())
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -ConfigPath $cfg `
            -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It 'content drift: the source .robin changed -> FINGERPRINT_SOURCE_MISMATCH (default fail)' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $null -AcceptancePath $null `
            -ScriptPaths @('tools/workday/workday.py') -ExternalPaths @())
        # Change the definition, then compare again
        [IO.File]::WriteAllText($fake.robin, "SET A TO 'changed'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
        (@($r.evidence).Count) | Should BeGreaterThan 1
    }

    It 'explicit Mode=warn downgrades the same drift to warn (verdict unchanged)' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        # New format (source/deployed split); the source hash is deliberately wrong to prove Mode only changes the level, not the verdict
        Write-FingerprintBaseline $base ([ordered]@{
            version = 2; flow = 'F'; flowGuid = $g; environmentId = $null; machine = $env:COMPUTERNAME
            source = [ordered]@{
                robinPath = $fake.robin; robinSha256 = 'deadbeef'
                robinLogicHash = (Get-RobinLogicHash $fake.robin); configSha256 = $null; acceptanceSha256 = $null
            }
            deployed = [ordered]@{
                robinPath = $fake.robin; robinSha256 = (Get-FileHash $fake.robin -Algorithm SHA256).Hash.ToLower()
                logicHash = (Get-RobinLogicHash $fake.robin); workspaceMtime = $null
            }
            hashes = [ordered]@{ robin = 'deadbeef'; config = $null; acceptance = $null }
            seededAt = '2026-11-03T00:00:00Z'
        })
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base `
            -ScriptsRoot $fake.scripts -Mode 'warn'
        $r.status | Should Be 'warn'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
    }

    It 'unreadable definition -> FINGERPRINT_UNKNOWN' {
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath (Join-Path $TestDrive 'not-exist.robin') `
            -BaselinePath (Join-Path $TestDrive 'no-baseline.json')
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
    }

    It 'no baseline: the default production gate still fails' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath (Join-Path $work 'baseline.json')
        $r.code | Should Be 'FINGERPRINT_NO_BASELINE'
        $r.status | Should Be 'fail'
    }

    It 'no baseline: report mode downgrades to warn and prints the complete seed command' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath (Join-Path $work 'baseline.json') `
            -NoBaselineMode 'warn' -FlowDisplayName 'Smoke Example' `
            -FlowFilePath 'examples\smoke-flow.json' -ConfigPath 'cfg.json' -AcceptancePath 'acc.json'
        $r.code | Should Be 'FINGERPRINT_NO_BASELINE'
        $r.status | Should Be 'warn'
        $r.message | Should Match '\.\\tools\\pad-sync\\pad-fingerprint\.ps1'
        $r.message | Should Match "-FlowName 'Smoke Example'"
        $r.message | Should Match '-FlowFile'
        $r.message | Should Match '-ConfigFile'
        $r.message | Should Match '-AcceptanceFile'
        $r.message | Should Match '-Set -Confirm'
        (@($r.evidence) -join ' ') | Should Match 'fix='
    }

    It 'corrupt baseline -> FINGERPRINT_BASELINE_CORRUPT' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        $base = Join-Path $work 'baseline.json'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($base, '{not json', (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath $base
        $r.code | Should Be 'FINGERPRINT_BASELINE_CORRUPT'
    }

    It 'baseline without a robin hash -> FINGERPRINT_BASELINE_CORRUPT' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        $base = Join-Path $work 'baseline.json'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($base, '{"flow":"F","hashes":{"config":null}}', (New-Object Text.UTF8Encoding($false)))
        (Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath $base).code |
            Should Be 'FINGERPRINT_BASELINE_CORRUPT'
    }

    It 'flow GUID changed -> FINGERPRINT_FLOW_STALE' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid '33333333-3333-3333-3333-333333333333' `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin -ConfigPath $null -AcceptancePath $null `
            -ScriptPaths @('tools/workday/workday.py') -ExternalPaths @())
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.code | Should Be 'FINGERPRINT_FLOW_STALE'
    }

    It 'config drift -> FINGERPRINT_CONFIG_STALE' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $cfg = Join-Path $work 'config.json'
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $cfg -AcceptancePath $null `
            -ScriptPaths @('tools/workday/workday.py') -ExternalPaths @())
        [IO.File]::WriteAllText($cfg, '{"A":"2"}', (New-Object Text.UTF8Encoding($false)))
        (Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -ConfigPath $cfg `
            -BaselinePath $base -ScriptsRoot $fake.scripts).code | Should Be 'FINGERPRINT_CONFIG_STALE'
    }

    It 'matching approval record -> pass; mismatch -> FINGERPRINT_MISMATCH (always fail)' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $parts = Get-FingerprintParts $robin $null $null
        $good = Join-Path $work 'good.jsonl'
        [IO.File]::WriteAllText($good, ('{"robin":"' + $parts.robin + '"}') + "`r`n", (New-Object Text.UTF8Encoding($false)))
        (Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -ApprovePath $good).status | Should Be 'pass'
        $bad = Join-Path $work 'bad.jsonl'
        [IO.File]::WriteAllText($bad, '{"robin":"deadbeef"}' + "`r`n", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -ApprovePath $bad
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_MISMATCH'
    }
}

Describe 'PadFingerprint identity resolution and hash domain split' {

    # Build a new-format baseline: one copy for the source and one for the published artifact, so nothing is ever compared across domains
    function New-BaselineV2([string]$Work, [string]$SourceRobin, [string]$DeployedRobin, [string]$DisplayName, [string]$FlowGuid) {
        $base = Join-Path $Work 'baseline.json'
        $srcParts = Get-FingerprintParts $SourceRobin $null $null
        $depRaw = if ($DeployedRobin -and (Test-Path $DeployedRobin)) {
            (Get-FileHash $DeployedRobin -Algorithm SHA256).Hash.ToLower()
        } else { $null }
        $depLogic = Get-RobinLogicHash $DeployedRobin
        $null = Write-FingerprintBaseline $base ([ordered]@{
            version = 2; flow = $DisplayName; flowGuid = $FlowGuid; environmentId = $null; machine = $env:COMPUTERNAME
            source = [ordered]@{
                robinPath = $SourceRobin; robinSha256 = $srcParts.robin
                robinLogicHash = (Get-RobinLogicHash $SourceRobin); configSha256 = $null; acceptanceSha256 = $null
            }
            deployed = [ordered]@{
                robinPath = $DeployedRobin; robinSha256 = $depRaw
                logicHash = $depLogic; workspaceMtime = $null
            }
            hashes = $srcParts
            seededAt = '2026-11-03T00:00:00Z'
        })
        return $base
    }

    It 'identity resolution: the PAD display name from the baseline matches even when the business name differs' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work '示例流程显示名' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin '示例流程显示名' $g
        # The argument is the business file name, which is completely different from the PAD display name
        $r = Test-FlowFingerprint -FlowName 'demo-flow' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It 'identity resolution: nothing found -> UNKNOWN, with the searched names in the evidence' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin '不存在的显示名' $g
        $r = Test-FlowFingerprint -FlowName 'demo-flow' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
        ($r.evidence -join ' ') | Should Match 'searched=不存在的显示名'
    }

    It 'old baseline without a deployed section -> UNKNOWN (asks for a reseed, never pass)' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $parts = Get-FingerprintParts $robin $null $null
        $base = Join-Path $work 'old.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 1; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            sourceRobin = $robin; workspaceRobin = $robin; workspaceMtime = $null
            hashes = $parts; seededAt = '2026-11-03T00:00:00Z'
        })
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath $base
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
        $r.message | Should Match 'no deployed hash'
        $r.status | Should Be 'fail'
    }

    It 'shape one: source and published copy are identical -> pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin 'F' $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It 'shape two: raw bytes differ but normalized text matches -> still pass, noting the byte difference' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        # PAD appends @@ metadata headers when it writes the file; after normalization it matches the source exactly
        $txt = "SET A TO 'x'"
        $deployedTxt = "@@ConnectionString TO 'x'`r`n" + $txt
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222' -RobinText $deployedTxt
        $src = Join-Path $work 'src.robin'
        [IO.File]::WriteAllText($src, $txt, (New-Object Text.UTF8Encoding($false)))
        $base = New-BaselineV2 $work $src $fake.deployed 'F' $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $src -DeployedRobinPath $fake.deployed `
            -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.message | Should Match 'raw bytes differ'
    }

    It 'shape three: real drift after normalization -> FINGERPRINT_DEPLOYED_MISMATCH (default fail)' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin 'F' $g
        # The published copy was changed into different actions: its logic hash no longer equals the baseline
        $j = [IO.File]::ReadAllText($base, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $j.deployed.logicHash = 'deadbeef'
        [IO.File]::WriteAllText($base, ($j | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_DEPLOYED_MISMATCH'
    }
}

Describe 'PadFingerprint published side compares the deployment artifact' {

    # Seed with the module's own v2 routine: the deployed section comes from the deployment artifact
    function New-BaselineFromDeployed([string]$Work, $Fake, [string]$Guid) {
        $base = Join-Path $Work 'baseline-deployed.json'
        $null = Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $Guid `
            -EnvironmentId $null -SourceRobin $Fake.robin -WorkspaceRobin $Fake.deployed `
            -ConfigPath $null -AcceptancePath $null `
            -ScriptPaths @('tools/workday/workday.py') -ExternalPaths @())
        return $base
    }

    It '1) deployment artifact matches deployed.logicHash -> pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
        # On overall success, say so explicitly: the source is a template, so differing from the deployment artifact is normal
        $r.message | Should Match 'source is a template'
    }

    It '2) tampered deployed.logicHash -> FINGERPRINT_DEPLOYED_MISMATCH' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        $j = [IO.File]::ReadAllText($base, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $j.deployed.logicHash = 'deadbeef'
        [IO.File]::WriteAllText($base, ($j | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_DEPLOYED_MISMATCH'
        $r.message | Should Match 'logically inconsistent with the published copy'
    }

    It '3) deployment artifact deleted -> FINGERPRINT_UNKNOWN (asks to regenerate first, never pass)' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        Remove-Item -LiteralPath $fake.deployed -Force
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
        $r.message | Should Match 'deployment artifact not found'
    }

    It '4) source .robin bytes changed -> still FINGERPRINT_SOURCE_MISMATCH' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        # Change only the source template and leave the deployment artifact alone: the source-to-source comparison must report it first
        [IO.File]::AppendAllText($fake.robin, "`r`nSET B TO 'y'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
    }
}

Describe 'pad-fingerprint baseline naming uses the pad-admit convention' {
    It 'resolves flow.json by pad_flow_name: the baseline lands in <flow file name>.json and admission can read it' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $runId = '22222222-2222-2222-2222-222222222222'
        # The PAD flow name differs from the business flow file name: this is exactly what a real Chinese flow name looks like
        $padName = '示例流程显示名'
        $bizName = 'demo-flow'
        # The published copy must be logically identical to the source, or the split baseline would report DRIFT
        $fake = New-FakePad $work $padName $g $runId -RobinText "SET A TO 'src'"

        $flows = Join-Path $work 'business\flows'
        New-Item -ItemType Directory -Path $flows -Force | Out-Null
        $flowJson = Join-Path $flows "$bizName.json"
        [IO.File]::WriteAllText($flowJson,
            ('{"pad_flow_name":"' + $padName + '","name":"' + $bizName + '"}'),
            (New-Object Text.UTF8Encoding($false)))
        $srcRobin = Join-Path $flows "$bizName.robin"
        [IO.File]::WriteAllText($srcRobin, "SET A TO 'src'", (New-Object Text.UTF8Encoding($false)))
        # Deployment artifact: the published side compares only against it, and a missing one is reported as UNKNOWN
        [IO.File]::WriteAllText((Join-Path $flows "$bizName.deployed.robin"), "SET A TO 'src'",
            (New-Object Text.UTF8Encoding($false)))
        $cfgDir = Join-Path $work 'business\config'
        New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
        $cfg = Join-Path $cfgDir "$bizName.json"
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $acc = Join-Path $flows "$bizName.acceptance.json"
        [IO.File]::WriteAllText($acc, '{"items":[]}', (New-Object Text.UTF8Encoding($false)))

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script -FlowName $padName `
            -RepoRoot $work -ScriptsRoot $fake.scripts -WorkspaceRoot $fake.workspace `
            -ConsoleConfigPath (Join-Path $work 'none.config') -Set -Confirm -ScriptPaths @('tools/workday/workday.py') 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0

        # Key assertion: the baseline uses the flow.json file name, not the PAD flow name
        $baseline = Join-Path $work "business\fingerprints\$bizName.json"
        (Test-Path -LiteralPath $baseline) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $work "business\fingerprints\$padName.json")) | Should Be $false

        # Read it exactly the way pad-admit does (without ScriptsRoot): it must hit and the hashes must match
        $r = Test-FlowFingerprint -FlowName $bizName -RobinPath $srcRobin -ConfigPath $cfg `
            -AcceptancePath $acc -BaselinePath $baseline
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }
}

Describe 'pad-fingerprint seeding requires human confirmation' {
    It '-Set without -Confirm: prints the lookup result, exits with code 2 and writes no baseline; -Confirm writes it' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $work2 = New-Work
        $cfg = Join-Path $work2 'config.json'
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $cc = Join-Path $work2 'console.config'
        [IO.File]::WriteAllText($cc, '{"UserConfigs":{"-1":{"EnvironmentId":"Default-abc"}}}', (New-Object Text.UTF8Encoding($false)))
        $baseline = Join-Path $work2 'fp.json'

        $first = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script -FlowName 'F' `
            -RepoRoot $work2 -ScriptsRoot $fake.scripts -WorkspaceRoot $fake.workspace `
            -ConsoleConfigPath $cc -ConfigFile $cfg -BaselinePath $baseline -Set 2>&1 | Out-String
        $LASTEXITCODE | Should Be 2
        $first | Should Match 'FINGERPRINT_CONFIRM_REQUIRED'
        $first | Should Match '"stage":"need-confirm"'
        $first | Should Match '"written":false'
        (Test-Path -LiteralPath $baseline) | Should Be $false

        $second = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script -FlowName 'F' `
            -RepoRoot $work2 -ScriptsRoot $fake.scripts -WorkspaceRoot $fake.workspace `
            -ConsoleConfigPath $cc -ConfigFile $cfg -BaselinePath $baseline -Set -Confirm -ScriptPaths @('tools/workday/workday.py') 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath $baseline) | Should Be $true
        $j = [IO.File]::ReadAllText($baseline, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $j.flow | Should Be 'F'
        $j.machine | Should Be $env:COMPUTERNAME
    }

    It 'multiple candidate revisions: stops as AMBIGUOUS with exit code 2 and writes no baseline' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        # The runId does not exactly hit a revision directory of the same name; two candidates fall inside the time window
        foreach ($rev in 'AAAA0001', 'BBBB0002') {
            $d = Join-Path $work "Workspace\$g\$rev"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            $p = Join-Path $d 'script.robin'
            [IO.File]::WriteAllText($p, 'x', (New-Object Text.UTF8Encoding($false)))
        }
        $scripts = Join-Path $work 'Scripts'
        Write-RunDef (Join-Path $scripts "$g\Runs\cccccccc-0000-0000-0000-00000000000c\RunDefinition.json") $g 'F' ([datetime]::UtcNow.AddMinutes(-10).ToString('o'))
        $baseline = Join-Path $work 'fp.json'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script -FlowName 'F' `
            -RepoRoot $work -ScriptsRoot $scripts -WorkspaceRoot (Join-Path $work 'Workspace') `
            -ConsoleConfigPath (Join-Path $work 'none.config') -BaselinePath $baseline 2>&1 | Out-String
        $LASTEXITCODE | Should Be 2
        $out | Should Match 'FINGERPRINT_AMBIGUOUS'
        (Test-Path -LiteralPath $baseline) | Should Be $false
    }
}

Describe 'PadFingerprint scripts section (v3)' {

    # Build a minimal repository: two in-repo scripts + two out-of-repo (absolute path) old copies
    function New-ScriptRepo([string]$Work) {
        $rels = @('scripts/a.vbs', 'tools/b.py')
        foreach ($rel in $rels) {
            $full = Join-Path $Work $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [IO.File]::WriteAllText($full, "content of $rel", (New-Object Text.UTF8Encoding($false)))
        }
        $ext = @((Join-Path $Work 'pad\posting.vbs'), (Join-Path $Work 'pad\mail-reader.vbs'))
        foreach ($p in $ext) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
            [IO.File]::WriteAllText($p, "content of $p", (New-Object Text.UTF8Encoding($false)))
        }
        return [ordered]@{ repo = $rels; external = $ext }
    }

    It 'all match -> pass' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 3; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            # Use the module's own calculation functions for both sections, so the test never duplicates the hash rules
            scripts = (Get-ScriptFingerprintParts -RepoRoot $work -Paths $paths.repo)
            external = (Get-ExternalScriptFingerprintParts -Paths $paths.external)
            seededAt = '2026-11-06T00:00:00Z'
        })
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It 'old baseline without a scripts section -> warn (not fail, backward compatible)' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'old-baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 2; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            seededAt = '2026-11-06T00:00:00Z'
        })
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_LEGACY'
        $r.status | Should Not Be 'fail'
    }

    It 'scripts section present but external missing -> still a legacy warn, not fail' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'no-external.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 3; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            scripts = (Get-ScriptFingerprintParts -RepoRoot $work -Paths $paths.repo)
            seededAt = '2026-11-06T00:00:00Z'
        })
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_LEGACY'
        ($r.message) | Should Match 'external'
    }

    It 'an old copy outside the repo changed -> MISMATCH, with its absolute path named in the evidence' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 3; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            scripts = (Get-ScriptFingerprintParts -RepoRoot $work -Paths $paths.repo)
            external = (Get-ExternalScriptFingerprintParts -Paths $paths.external)
            seededAt = '2026-11-06T00:00:00Z'
        })
        # Change only the second out-of-repo copy; the in-repo scripts and the other external copy stay untouched
        [IO.File]::AppendAllText($paths.external[1], "`r`nchanged", (New-Object Text.UTF8Encoding($false)))
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_MISMATCH'
        ($r.evidence -join ' ') | Should Match 'mail-reader\.vbs'
        ($r.evidence -join ' ') | Should Not Match 'posting\.vbs'
        ($r.evidence -join ' ') | Should Not Match 'scripts/a\.vbs'
    }

    It 'one repo script changed -> SCRIPT_FINGERPRINT_MISMATCH, with that file named in the evidence' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 3; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            scripts = (Get-ScriptFingerprintParts -RepoRoot $work -Paths $paths.repo)
            external = (Get-ExternalScriptFingerprintParts -Paths $paths.external)
            seededAt = '2026-11-06T00:00:00Z'
        })
        # Change only one of the scripts and leave the other untouched
        [IO.File]::AppendAllText((Join-Path $work 'scripts\a.vbs'), "`r`nchanged", (New-Object Text.UTF8Encoding($false)))
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_MISMATCH'
        ($r.evidence -join ' ') | Should Match 'scripts/a.vbs'
        ($r.evidence -join ' ') | Should Not Match 'tools/b.py'
    }
}

