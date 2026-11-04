# pad-fingerprint.Tests.ps1 — 流程指纹模块测试（Pester 3.4，PS 5.1 自带）
#
# 全部用 TestDrive 造合成 Workspace / Scripts 根目录，不硬编码 LOCALAPPDATA、
# 不注册计划任务、不启动 PAD、不触发任何真实流程。
# 覆盖：哈希一致 / 内容漂移 / 读不到、身份变化、基线缺失或损坏、播种需人工确认。

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

# 造一份最小的 Scripts + Workspace：runId 目录名即修订目录名
function New-FakePad([string]$Work, [string]$FlowName, [string]$FlowGuid, [string]$RunId, [string]$RobinText = "SET A TO 'x'") {
    $scripts = Join-Path $Work 'Scripts'
    $ws = Join-Path $Work 'Workspace'
    Write-RunDef (Join-Path $scripts "$FlowGuid\Runs\$RunId\RunDefinition.json") $FlowGuid $FlowName '2026-11-03T09:00:00Z'
    $revDir = Join-Path $ws "$FlowGuid\$RunId"
    New-Item -ItemType Directory -Path $revDir -Force | Out-Null
    $robin = Join-Path $revDir 'script.robin'
    [IO.File]::WriteAllText($robin, $RobinText, (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ scripts = $scripts; workspace = $ws; robin = $robin; runId = $RunId }
}

Describe 'PadFingerprint 定位与身份' {

    It '从 Actions.log 路径解析 GUID 与 runId；非运行路径返回 null' {
        $p = 'C:\Users\x\Console\Scripts\CFD13222-CA5B-447E-B7FF-51FE823BA40B\Runs\d0a4989f-5798-45bb-b6b3-c8658d54fc52\Actions.log'
        $ids = Get-FlowGuidFromLogPath $p
        $ids.flowGuid | Should Be 'cfd13222-ca5b-447e-b7ff-51fe823ba40b'
        $ids.runId | Should Be 'd0a4989f-5798-45bb-b6b3-c8658d54fc52'
        (Get-FlowGuidFromLogPath 'C:\temp\nothing.log') | Should Be $null
    }

    It 'Workspace 定位：runId 精确命中，其他旧修订不参与' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $runId = '22222222-2222-2222-2222-222222222222'
        $fake = New-FakePad $work 'F' $g $runId
        # 另一个早于本次运行的修订：不在时间窗口内，不会成为候选
        $other = Join-Path $fake.workspace "$g\OLD00001"
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        $op = Join-Path $other 'script.robin'
        [IO.File]::WriteAllText($op, "SET B TO 'y'", (New-Object Text.UTF8Encoding($false)))
        (Get-Item $op).LastWriteTime = [datetime]::UtcNow.AddDays(-5)
        (Find-WorkspaceRobin $fake.workspace $g $runId ([datetime]::UtcNow.AddHours(-1))) | Should Be $fake.robin
    }

    It 'Workspace 定位：多个候选直接报错，不静默挑一个' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        foreach ($rev in 'AAAA0001', 'BBBB0002') {
            $d = Join-Path $work "Workspace\$g\$rev"
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            $p = Join-Path $d 'script.robin'
            [IO.File]::WriteAllText($p, 'x', (New-Object Text.UTF8Encoding($false)))
            (Get-Item $p).LastWriteTime = [datetime]::UtcNow.AddMinutes(-5)
        }
        $msg = $null
        try { $null = Find-WorkspaceRobin (Join-Path $work 'Workspace') $g '' ([datetime]::UtcNow.AddDays(-1)) }
        catch { $msg = $_.Exception.Message }
        $msg | Should Match '2 个候选修订'
    }

    It '环境 ID：从合成 console.config 读取首个 EnvironmentId，读不到返回 null' {
        $work = New-Work
        $p = Join-Path $work 'console.config'
        [IO.File]::WriteAllText($p, '{"UserConfigs":{"-1":{"EnvironmentId":"Default-abc"}}}', (New-Object Text.UTF8Encoding($false)))
        (Get-PadEnvironmentId $p) | Should Be 'Default-abc'
        (Get-PadEnvironmentId (Join-Path $work 'missing.config')) | Should Be $null
    }
}

Describe 'PadFingerprint 比对' {

    It '哈希一致：基线与当前三件套相同 → pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $cfg = Join-Path $work 'config.json'
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $cfg -AcceptancePath $null)
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -ConfigPath $cfg `
            -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It '内容漂移：源 .robin 改过 → FINGERPRINT_SOURCE_MISMATCH（默认 warn）' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $null -AcceptancePath $null)
        # 改了定义再比对
        [IO.File]::WriteAllText($fake.robin, "SET A TO 'changed'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'warn'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
        (@($r.evidence).Count) | Should BeGreaterThan 1
    }

    It 'Mode=fail 时同样的漂移直接 fail（切换开关只影响级别，不改判定）' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 1; flow = 'F'; flowGuid = $g; environmentId = $null; machine = $env:COMPUTERNAME
            sourceRobin = $fake.robin; workspaceRobin = $fake.robin; workspaceMtime = $null
            hashes = [ordered]@{ robin = 'deadbeef'; config = $null; acceptance = $null }
            seededAt = '2026-11-03T00:00:00Z'
        })
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base `
            -ScriptsRoot $fake.scripts -Mode 'fail'
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
    }

    It '读不到定义 → FINGERPRINT_UNKNOWN' {
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath (Join-Path $TestDrive 'not-exist.robin') `
            -BaselinePath (Join-Path $TestDrive 'no-baseline.json')
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
    }

    It '没有基线 → FINGERPRINT_NO_BASELINE' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath (Join-Path $work 'baseline.json')
        $r.code | Should Be 'FINGERPRINT_NO_BASELINE'
        $r.status | Should Be 'warn'
    }

    It '基线损坏 → FINGERPRINT_BASELINE_CORRUPT' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        $base = Join-Path $work 'baseline.json'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($base, '{not json', (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath $base
        $r.code | Should Be 'FINGERPRINT_BASELINE_CORRUPT'
    }

    It '基线缺 robin 哈希 → FINGERPRINT_BASELINE_CORRUPT' {
        $work = New-Work
        $robin = Join-Path $work 'x.robin'
        $base = Join-Path $work 'baseline.json'
        [IO.File]::WriteAllText($robin, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($base, '{"flow":"F","hashes":{"config":null}}', (New-Object Text.UTF8Encoding($false)))
        (Test-FlowFingerprint -FlowName 'F' -RobinPath $robin -BaselinePath $base).code |
            Should Be 'FINGERPRINT_BASELINE_CORRUPT'
    }

    It '流程 GUID 变化 → FINGERPRINT_FLOW_STALE' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid '33333333-3333-3333-3333-333333333333' `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin -ConfigPath $null -AcceptancePath $null)
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.code | Should Be 'FINGERPRINT_FLOW_STALE'
    }

    It 'config 漂移 → FINGERPRINT_CONFIG_STALE' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $cfg = Join-Path $work 'config.json'
        [IO.File]::WriteAllText($cfg, '{"A":"1"}', (New-Object Text.UTF8Encoding($false)))
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $g `
            -EnvironmentId $null -SourceRobin $fake.robin -WorkspaceRobin $fake.robin `
            -ConfigPath $cfg -AcceptancePath $null)
        [IO.File]::WriteAllText($cfg, '{"A":"2"}', (New-Object Text.UTF8Encoding($false)))
        (Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -ConfigPath $cfg `
            -BaselinePath $base -ScriptsRoot $fake.scripts).code | Should Be 'FINGERPRINT_CONFIG_STALE'
    }

    It '批准记录一致 → pass；不一致 → FINGERPRINT_MISMATCH（始终 fail）' {
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

Describe 'pad-fingerprint 播种必须人工确认' {
    It '-Set 不加 -Confirm：打印定位结果、退出码 2、不写基线；加 -Confirm 才写' {
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
        $first | Should Match '三个哈希'
        $first | Should Match 'FINGERPRINT_CONFIRM_REQUIRED'
        (Test-Path -LiteralPath $baseline) | Should Be $false

        $second = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Script -FlowName 'F' `
            -RepoRoot $work2 -ScriptsRoot $fake.scripts -WorkspaceRoot $fake.workspace `
            -ConsoleConfigPath $cc -ConfigFile $cfg -BaselinePath $baseline -Set -Confirm 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        (Test-Path -LiteralPath $baseline) | Should Be $true
        $j = [IO.File]::ReadAllText($baseline, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $j.flow | Should Be 'F'
        $j.machine | Should Be $env:COMPUTERNAME
    }

    It '多个候选修订：直接 AMBIGUOUS 停下，退出码 2，不写基线' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        # runId 精确命中不到同名修订目录，时间窗口内两个候选
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
