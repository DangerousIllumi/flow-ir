# pad-release.Tests.ps1 — release 流水线纯函数测试（Pester 3.4，PS 5.1 自带）
#
# 覆盖：
#   规范化（去 @@/IMPORT/空行/行尾空白）、哈希一致性、逐行比对（首个差异定位）
#   运行日志路径 GUID 解析、历史运行查找（按流程名过滤 + startTime 取最新）
#   Workspace 已发布定义定位、manifest 追加
#
# 通过 dot-source -NoMain 只加载函数，不执行发布主流程（绝不能在这触发真实发布）。

$script:Release = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-release.ps1'
. $script:Release -NoMain

# 每个用例的独立工作目录（Pester 3.4 的 $TestDrive 整个 Describe 共享）
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# 写最小可用的 RunDefinition.json
function Write-RunDef([string]$Path, [string]$FlowGuid, [string]$FlowName, [string]$StartTime, [string]$Status = 'Succeeded', [string]$FlowVersion = '') {
    $fv = ''
    if ($FlowVersion) { $fv = ',"diagnosticInfo":{"flowVersion":"' + $FlowVersion.Replace('"', '\"') + '"}' }
    $json = '{"startTime":"' + $StartTime + '","status":"' + $Status + '","workflow":{"workflowId":"' + $FlowGuid + '","name":"' + $FlowName + '"}' + $fv + '}'
    New-Item -ItemType File -Path $Path -Force | Out-Null
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

Describe 'pad-release 纯函数测试' {

    It '规范化：去掉 @@ 头 / IMPORT 行 / 空行 / 行尾空白，CRLF 统一为 LF' {
        $raw = "@@ConnectionString: ''`r`nIMPORT 'a.appmask' AS appmask`r`n`r`nSET A TO 'x'   `r`n  IMPORT 'b.imgrepo' AS imgrepo`r`nSET B TO 'y'"
        $norm = ConvertTo-NormalizedRobin $raw
        $norm | Should Be ("SET A TO 'x'" + "`n" + "SET B TO 'y'")
    }

    It '哈希一致性：deployed（含注释）与 workspace（含 @ 元数据）规范化后哈希相同' {
        # 源文件带中文注释；PAD 发布后注释整行丢弃，并追加 @SENSITIVE 等元数据行
        $deployed = "# 这是中文注释，发布后会被丢弃`r`nSET A TO 'x'`r`nSET B TO 'y'"
        $workspace = "@@ConnectionString: ''`r`n@@Type: 'Local'`r`n@SENSITIVE: []`r`nIMPORT 'controlRepo.appmask' AS appmask`r`n`r`nSET A TO 'x'  `r`nSET B TO 'y'`r`n"
        (Get-RobinHash $deployed) | Should Be (Get-RobinHash $workspace)
        (Compare-RobinText $deployed $workspace).match | Should Be $true
    }

    It '规范化：注释行不同不影响比对结果' {
        $a = "# 旧注释`nSET A TO 'x'"
        $b = "# 新注释`nSET A TO 'x'"
        (Compare-RobinText $a $b).match | Should Be $true
    }

    It '逐行比对：中间一行不同 → 报首个差异行号与两侧内容' {
        $a = "SET A TO 'x'`nSET B TO 'y'`nSET C TO 'z'"
        $b = "SET A TO 'x'`nSET B TO 'CHANGED'`nSET C TO 'z'"
        $cmp = Compare-RobinText $a $b
        $cmp.match | Should Be $false
        $cmp.diffIndex | Should Be 2
        $cmp.lineB | Should Match 'CHANGED'
    }

    It '逐行比对：行数不同 → 差异行报「缺失」' {
        $a = "SET A TO 'x'`nSET B TO 'y'"
        $b = "SET A TO 'x'"
        $cmp = Compare-RobinText $a $b
        $cmp.match | Should Be $false
        $cmp.diffIndex | Should Be 2
        $cmp.lineB | Should Be '<缺失>'
    }

    It '从 Actions.log 路径解析流程 GUID 与 runId' {
        $p = 'C:\Users\x\AppData\Local\Microsoft\Power Automate Desktop\Console\Scripts\CFD13222-CA5B-447E-B7FF-51FE823BA40B\Runs\d0a4989f-5798-45bb-b6b3-c8658d54fc52\Actions.log'
        $ids = Get-FlowGuidFromLogPath $p
        $ids.flowGuid | Should Be 'cfd13222-ca5b-447e-b7ff-51fe823ba40b'
        $ids.runId | Should Be 'd0a4989f-5798-45bb-b6b3-c8658d54fc52'
        (Get-FlowGuidFromLogPath 'C:\temp\no-guid.log') | Should Be $null
    }

    It '历史运行查找：按流程名过滤，按 startTime 取最新' {
        $work = New-Work
        $root = Join-Path $work 'Scripts'
        $g1 = '11111111-1111-1111-1111-111111111111'
        $g2 = '22222222-2222-2222-2222-222222222222'
        # 目标流程两次运行（旧 + 新），另一条流程一次运行（干扰项）
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000a\RunDefinition.json") $g1 '目标流程' '2026-10-20T01:00:00Z' 'Succeeded' 'W/"100"'
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000b\RunDefinition.json") $g1 '目标流程' '2026-10-26T01:00:00Z' 'Succeeded' 'W/"200"'
        Write-RunDef (Join-Path $root "$g2\Runs\bbbbbbbb-0000-0000-0000-00000000000c\RunDefinition.json") $g2 '别的流程' '2026-10-27T01:00:00Z' 'Succeeded' 'W/"999"'
        $r = Find-LatestFlowRun $root '目标流程'
        $r.flowGuid | Should Be $g1
        $r.flowVersion | Should Be 'W/"200"'
        $r.startTime | Should Be '2026-10-26T01:00:00Z'
        # 找不到的流程名返回 null
        (Find-LatestFlowRun $root '不存在的流程') | Should Be $null
    }

    It '历史运行查找：跳过损坏的 JSON 文件' {
        $work = New-Work
        $root = Join-Path $work 'Scripts'
        $g1 = '11111111-1111-1111-1111-111111111111'
        $bad = Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000a\RunDefinition.json"
        New-Item -ItemType File -Path $bad -Force | Out-Null
        [IO.File]::WriteAllText($bad, '{损坏的json', (New-Object Text.UTF8Encoding($false)))
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000b\RunDefinition.json") $g1 '目标流程' '2026-10-26T01:00:00Z'
        (Find-LatestFlowRun $root '目标流程').flowGuid | Should Be $g1
    }

    It 'Workspace 定义定位：取该流程目录下最新的 script.robin' {
        $work = New-Work
        $g1 = '11111111-1111-1111-1111-111111111111'
        $r1 = Join-Path $work "$g1\AAAA0001\script.robin"
        $r2 = Join-Path $work "$g1\BBBB0002\script.robin"
        New-Item -ItemType File -Path $r1 -Force | Out-Null
        New-Item -ItemType File -Path $r2 -Force | Out-Null
        (Get-Item $r1).LastWriteTime = [datetime]'2026-10-20 08:00:00'
        (Get-Item $r2).LastWriteTime = [datetime]'2026-10-26 08:00:00'
        (Find-WorkspaceRobin $work $g1) | Should Be $r2
        (Find-WorkspaceRobin $work '33333333-3333-3333-3333-333333333333') | Should Be $null
    }

    It 'manifest 追加：一行一个合法 JSON，字段齐全，多次追加不覆盖' {
        $work = New-Work
        $mf = Join-Path $work 'manifest.jsonl'
        $entry = [ordered]@{ ts = '2026-10-27T00:00:00Z'; type = 'release'; flow = 'F'; sha256 = 'abc'; ok = $true; errors = @() }
        Add-ManifestEntry $mf $entry
        Add-ManifestEntry $mf $entry
        $lines = @([IO.File]::ReadAllLines($mf, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
        $lines.Count | Should Be 2
        $j = $lines[0] | ConvertFrom-Json
        $j.type | Should Be 'release'
        $j.sha256 | Should Be 'abc'
    }

    It '运行记录：type=run，模式/状态/错误码字段齐全，可直接序列化为一行 JSON' {
        $e = New-RunManifestEntry -FlowName 'PAD_SYNC_TEST' -RunId 'r-1' -Mode 'local' `
            -Ok $true -Stage 'done' -Status 'Succeeded' -Actions 42 -TotalMs 1234 `
            -ErrorCode $null -ErrorMessage $null -LogPath 'C:\log.txt' -CanvasVerified $true
        $e.type | Should Be 'run'
        $e.flow | Should Be 'PAD_SYNC_TEST'
        $e.mode | Should Be 'local'
        $e.ok | Should Be $true
        $e.actions | Should Be 42
        $j = ($e | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json
        $j.errorCode | Should Be $null
        ($j.PSObject.Properties.Name | Where-Object { $_ -eq 'canvasVerified' }) | Should Be 'canvasVerified'
    }

    It '运行记录：warnings 字段默认是空数组，传入时按数组序列化' {
        $e = New-RunManifestEntry -FlowName 'F' -Ok $true -Stage 'done'
        (@($e.warnings)).Count | Should Be 0
        $e2 = New-RunManifestEntry -FlowName 'F' -Ok $true -Stage 'done' -Warnings @('缓存未刷新')
        (@($e2.warnings)).Count | Should Be 1
        (@((($e2 | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json).warnings))[0] | Should Be '缓存未刷新'
    }

    It 'manifest 保留：run 记录按 90 天清理，release/rollback 永久保留' {
        $mf = Join-Path $TestDrive ('manifest-' + [guid]::NewGuid().ToString('N') + '.jsonl')
        $old = [datetime]::UtcNow.AddDays(-120).ToString('o')
        $fresh = [datetime]::UtcNow.AddDays(-1).ToString('o')
        foreach ($line in @(
            ([ordered]@{ ts = $old; type = 'run'; flow = 'F' } | ConvertTo-Json -Compress),
            ([ordered]@{ ts = $old; type = 'release'; flow = 'F' } | ConvertTo-Json -Compress),
            ([ordered]@{ ts = $old; type = 'rollback'; flow = 'F' } | ConvertTo-Json -Compress),
            ([ordered]@{ ts = $fresh; type = 'run'; flow = 'F' } | ConvertTo-Json -Compress)
        )) { [IO.File]::AppendAllText($mf, $line + "`r`n", (New-Object Text.UTF8Encoding($false))) }

        (Remove-OldManifestEntries $mf -KeepDays 90) | Should Be 1
        $left = @([IO.File]::ReadAllLines($mf, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() } | ForEach-Object { ($_ | ConvertFrom-Json).type })
        $left.Count | Should Be 3
        ($left -contains 'release') | Should Be $true
        ($left -contains 'rollback') | Should Be $true
    }

    It '批准指纹：存在的文件取 SHA256，缺失的记 null，短格式带前缀' {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        foreach ($n in 'a.robin', 'b.json', 'c.json') {
            [IO.File]::WriteAllText((Join-Path $d $n), 'x', (New-Object Text.UTF8Encoding($false)))
        }
        $fp = Get-ApprovalFingerprint (Join-Path $d 'a.robin') (Join-Path $d 'b.json') (Join-Path $d 'c.json')
        $fp.robin.Length | Should Be 64
        $fp.robin | Should Be $fp.robin.ToLower()
        (Format-ApprovalFingerprint $fp) | Should Match 'robin=\w{8} config=\w{8} acceptance=\w{8}'

        $fp2 = Get-ApprovalFingerprint (Join-Path $d 'a.robin') $null $null
        $fp2.config | Should Be $null
        (Format-ApprovalFingerprint $fp2) | Should Match '^robin=\w{8}$'
    }
}
