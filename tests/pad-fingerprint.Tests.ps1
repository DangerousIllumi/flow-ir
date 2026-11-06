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
    # 部署产物（占位符替换后的副本）与源同目录：指纹已发布侧只认它
    $deployed = Join-Path $revDir 'script.deployed.robin'
    [IO.File]::WriteAllText($deployed, $RobinText, (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ scripts = $scripts; workspace = $ws; robin = $robin; deployed = $deployed; runId = $RunId }
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

    It '内容漂移：源 .robin 改过 → FINGERPRINT_SOURCE_MISMATCH（默认 fail）' {
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
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
        (@($r.evidence).Count) | Should BeGreaterThan 1
    }

    It '显式 Mode=warn 时同样的漂移只降级为 warn（不改判定）' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = Join-Path $work 'baseline.json'
        # 新格式（source/deployed 拆分）；源哈希故意写成错的，验证 Mode 只改级别不改判定
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
        $r.status | Should Be 'fail'
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

Describe 'PadFingerprint 身份解析与哈希域拆分' {

    # 造一条新格式基线：源与已发布各自一份，避免任何跨域比较
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

    It '身份解析：用基线里的 PAD 显示名，业务名不同也能命中' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work '示例流程显示名' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin '示例流程显示名' $g
        # 入参是业务文件名，和 PAD 里的显示名完全不同
        $r = Test-FlowFingerprint -FlowName 'demo-flow' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It '身份解析：搜不到 → UNKNOWN，并把搜过的名字写进 evidence' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin '不存在的显示名' $g
        $r = Test-FlowFingerprint -FlowName 'demo-flow' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
        ($r.evidence -join ' ') | Should Match 'searched=不存在的显示名'
    }

    It '旧基线缺 deployed 段 → UNKNOWN（提示重新播种，不许当 pass）' {
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
        $r.message | Should Match '缺少已发布哈希'
        $r.status | Should Be 'fail'
    }

    It '形态一：源与已发布完全一致 → pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin 'F' $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It '形态二：原始字节不同、规范化一致 → 仍 pass，并注明字节差异' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        # PAD 落盘会追加 @@ 元数据头；规范化后与源完全一致
        $txt = "SET A TO 'x'"
        $deployedTxt = "@@ConnectionString TO 'x'`r`n" + $txt
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222' -RobinText $deployedTxt
        $src = Join-Path $work 'src.robin'
        [IO.File]::WriteAllText($src, $txt, (New-Object Text.UTF8Encoding($false)))
        $base = New-BaselineV2 $work $src $fake.deployed 'F' $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $src -DeployedRobinPath $fake.deployed `
            -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.message | Should Match '原始字节不同'
    }

    It '形态三：规范化后真漂移 → FINGERPRINT_DEPLOYED_MISMATCH（默认 fail）' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineV2 $work $fake.robin $fake.robin 'F' $g
        # 已发布副本被改成了别的动作：逻辑哈希不再等于基线
        $j = [IO.File]::ReadAllText($base, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $j.deployed.logicHash = 'deadbeef'
        [IO.File]::WriteAllText($base, ($j | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_DEPLOYED_MISMATCH'
    }
}

Describe 'PadFingerprint 已发布侧改比部署产物' {

    # 用模块自带的 v2 播种：deployed 段取自部署产物
    function New-BaselineFromDeployed([string]$Work, $Fake, [string]$Guid) {
        $base = Join-Path $Work 'baseline-deployed.json'
        $null = Write-FingerprintBaseline $base (New-FingerprintBaseline -FlowName 'F' -FlowGuid $Guid `
            -EnvironmentId $null -SourceRobin $Fake.robin -WorkspaceRobin $Fake.deployed `
            -ConfigPath $null -AcceptancePath $null)
        return $base
    }

    It '① 部署产物与 deployed.logicHash 一致 → pass' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
        # 整体通过时明确说明：源是模板，与部署产物不同属正常
        $r.message | Should Match '源是模板'
    }

    It '② 篡改 deployed.logicHash → FINGERPRINT_DEPLOYED_MISMATCH' {
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
        $r.message | Should Match '部署产物与已发布副本逻辑不一致'
    }

    It '③ 删掉部署产物 → FINGERPRINT_UNKNOWN（提示先生成，不许 pass）' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        Remove-Item -LiteralPath $fake.deployed -Force
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_UNKNOWN'
        $r.message | Should Match '找不到部署产物'
    }

    It '④ 源 .robin 改字节 → 仍 FINGERPRINT_SOURCE_MISMATCH' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $fake = New-FakePad $work 'F' $g '22222222-2222-2222-2222-222222222222'
        $base = New-BaselineFromDeployed $work $fake $g
        # 只改源模板，部署产物不动：源对源比较必须先报出来
        [IO.File]::AppendAllText($fake.robin, "`r`nSET B TO 'y'", (New-Object Text.UTF8Encoding($false)))
        $r = Test-FlowFingerprint -FlowName 'F' -RobinPath $fake.robin -BaselinePath $base -ScriptsRoot $fake.scripts
        $r.status | Should Be 'fail'
        $r.code | Should Be 'FINGERPRINT_SOURCE_MISMATCH'
    }
}

Describe 'pad-fingerprint 基线命名与 pad-admit 同口径' {
    It '按 pad_flow_name 反查 flow.json：基线落在 <flow文件名>.json，准入能读到' {
        $work = New-Work
        $g = '11111111-1111-1111-1111-111111111111'
        $runId = '22222222-2222-2222-2222-222222222222'
        # PAD 流程名与业务流文件名不同：这正是中文流程名的真实形态
        $padName = '示例流程显示名'
        $bizName = 'demo-flow'
        # 已发布副本必须与源同逻辑，否则拆分后的基线会判 DRIFT
        $fake = New-FakePad $work $padName $g $runId -RobinText "SET A TO 'src'"

        $flows = Join-Path $work 'business\flows'
        New-Item -ItemType Directory -Path $flows -Force | Out-Null
        $flowJson = Join-Path $flows "$bizName.json"
        [IO.File]::WriteAllText($flowJson,
            ('{"pad_flow_name":"' + $padName + '","name":"' + $bizName + '"}'),
            (New-Object Text.UTF8Encoding($false)))
        $srcRobin = Join-Path $flows "$bizName.robin"
        [IO.File]::WriteAllText($srcRobin, "SET A TO 'src'", (New-Object Text.UTF8Encoding($false)))
        # 部署产物：已发布侧只跟它比，缺失会被判 UNKNOWN
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
            -ConsoleConfigPath (Join-Path $work 'none.config') -Set -Confirm 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0

        # 关键断言：基线用的是 flow.json 文件名，不是 PAD 流程名
        $baseline = Join-Path $work "business\fingerprints\$bizName.json"
        (Test-Path -LiteralPath $baseline) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $work "business\fingerprints\$padName.json")) | Should Be $false

        # 与 pad-admit 同一口径（不传 ScriptsRoot）读取：应能命中，且哈希一致
        $r = Test-FlowFingerprint -FlowName $bizName -RobinPath $srcRobin -ConfigPath $cfg `
            -AcceptancePath $acc -BaselinePath $baseline
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
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

Describe 'PadFingerprint scripts 段（v3）' {

    # 造一个最小仓库：两个仓库内脚本 + 两个仓库外（绝对路径）旧拷贝
    function New-ScriptRepo([string]$Work) {
        $rels = @('scripts/a.vbs', 'tools/b.py')
        foreach ($rel in $rels) {
            $full = Join-Path $Work $rel
            New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
            [IO.File]::WriteAllText($full, "content of $rel", (New-Object Text.UTF8Encoding($false)))
        }
        $ext = @((Join-Path $Work 'pad\MIGO201_501.vbs'), (Join-Path $Work 'pad\读取msg.vbs'))
        foreach ($p in $ext) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force | Out-Null
            [IO.File]::WriteAllText($p, "content of $p", (New-Object Text.UTF8Encoding($false)))
        }
        return [ordered]@{ repo = $rels; external = $ext }
    }

    It '全部一致 → pass' {
        $work = New-Work
        $paths = New-ScriptRepo $work
        $base = Join-Path $work 'baseline.json'
        Write-FingerprintBaseline $base ([ordered]@{
            version = 3; flow = 'F'; flowGuid = $null; environmentId = $null; machine = $env:COMPUTERNAME
            hashes = [ordered]@{ robin = 'x'; config = $null; acceptance = $null }
            # 用模块自带的计算函数生成两段，避免测试自己写一份哈希规则
            scripts = (Get-ScriptFingerprintParts -RepoRoot $work -Paths $paths.repo)
            external = (Get-ExternalScriptFingerprintParts -Paths $paths.external)
            seededAt = '2026-11-06T00:00:00Z'
        })
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'pass'
        $r.code | Should Be 'OK'
    }

    It '旧基线缺 scripts 段 → warn（不判 fail，向后兼容）' {
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

    It '已有 scripts 段但缺 external 段 → 仍按 legacy warn，不判 fail' {
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

    It '仓库外旧拷贝被改动 → MISMATCH，evidence 点名其绝对路径' {
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
        # 只改仓库外的第二份拷贝，仓库内脚本与另一份外部拷贝保持不动
        [IO.File]::AppendAllText($paths.external[1], "`r`nchanged", (New-Object Text.UTF8Encoding($false)))
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_MISMATCH'
        ($r.evidence -join ' ') | Should Match '读取msg\.vbs'
        ($r.evidence -join ' ') | Should Not Match 'MIGO201_501'
        ($r.evidence -join ' ') | Should Not Match 'scripts/a\.vbs'
    }

    It '单个仓库脚本被改动 → SCRIPT_FINGERPRINT_MISMATCH，evidence 点名该文件' {
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
        # 只改其中一个脚本，另一个保持不动
        [IO.File]::AppendAllText((Join-Path $work 'scripts\a.vbs'), "`r`nchanged", (New-Object Text.UTF8Encoding($false)))
        $r = Test-ScriptFingerprint -BaselinePath $base -RepoRoot $work
        $r.status | Should Be 'warn'
        $r.code | Should Be 'SCRIPT_FINGERPRINT_MISMATCH'
        ($r.evidence -join ' ') | Should Match 'scripts/a.vbs'
        ($r.evidence -join ' ') | Should Not Match 'tools/b.py'
    }
}

