# pad-release.Tests.ps1 — pure-function tests for the release pipeline (Pester 3.4, bundled with PowerShell 5.1)
#
# Covers:
#   normalization (strip @@/IMPORT lines/blank lines/trailing whitespace), hash consistency, line-by-line comparison (locating the first difference)
#   GUID parsing from a run log path, historical run lookup (filter by flow name + take the newest startTime)
#   locating the published Workspace definition, manifest append
#
# Dot-source with -NoMain to load only the functions and never run the main publish flow (a real release must never be triggered here).

$script:Release = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-release.ps1'
. $script:Release -NoMain

# A separate working directory per test ($TestDrive is shared across a whole Describe in Pester 3.4)
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# Write a minimal usable RunDefinition.json
function Write-RunDef([string]$Path, [string]$FlowGuid, [string]$FlowName, [string]$StartTime, [string]$Status = 'Succeeded', [string]$FlowVersion = '') {
    $fv = ''
    if ($FlowVersion) { $fv = ',"diagnosticInfo":{"flowVersion":"' + $FlowVersion.Replace('"', '\"') + '"}' }
    $json = '{"startTime":"' + $StartTime + '","status":"' + $Status + '","workflow":{"workflowId":"' + $FlowGuid + '","name":"' + $FlowName + '"}' + $fv + '}'
    New-Item -ItemType File -Path $Path -Force | Out-Null
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

Describe 'pad-release pure function tests' {

    It 'normalization: strips @@ headers, IMPORT lines, blank lines and trailing whitespace; CRLF becomes LF' {
        $raw = "@@ConnectionString: ''`r`nIMPORT 'a.appmask' AS appmask`r`n`r`nSET A TO 'x'   `r`n  IMPORT 'b.imgrepo' AS imgrepo`r`nSET B TO 'y'"
        $norm = ConvertTo-NormalizedRobin $raw
        $norm | Should Be ("SET A TO 'x'" + "`n" + "SET B TO 'y'")
    }

    It 'hash consistency: deployed (with comments) and workspace (with @ metadata) hash the same after normalization' {
        # The source file carries Chinese comments; PAD drops whole comment lines on publish and appends metadata lines such as @SENSITIVE
        $deployed = "# 这是中文注释，发布后会被丢弃`r`nSET A TO 'x'`r`nSET B TO 'y'"
        $workspace = "@@ConnectionString: ''`r`n@@Type: 'Local'`r`n@SENSITIVE: []`r`nIMPORT 'controlRepo.appmask' AS appmask`r`n`r`nSET A TO 'x'  `r`nSET B TO 'y'`r`n"
        (Get-RobinHash $deployed) | Should Be (Get-RobinHash $workspace)
        (Compare-RobinText $deployed $workspace).match | Should Be $true
    }

    It 'normalization: differing comment lines do not affect the comparison result' {
        $a = "# 旧注释`nSET A TO 'x'"
        $b = "# 新注释`nSET A TO 'x'"
        (Compare-RobinText $a $b).match | Should Be $true
    }

    It 'line-by-line comparison: a difference in the middle reports the first differing line and both sides' {
        $a = "SET A TO 'x'`nSET B TO 'y'`nSET C TO 'z'"
        $b = "SET A TO 'x'`nSET B TO 'CHANGED'`nSET C TO 'z'"
        $cmp = Compare-RobinText $a $b
        $cmp.match | Should Be $false
        $cmp.diffIndex | Should Be 2
        $cmp.lineB | Should Match 'CHANGED'
    }

    It 'line-by-line comparison: differing line counts report a missing line' {
        $a = "SET A TO 'x'`nSET B TO 'y'"
        $b = "SET A TO 'x'"
        $cmp = Compare-RobinText $a $b
        $cmp.match | Should Be $false
        $cmp.diffIndex | Should Be 2
        $cmp.lineB | Should Be '<missing>'
    }

    It 'parses flow GUID and runId from an Actions.log path' {
        $p = 'C:\Users\x\AppData\Local\Microsoft\Power Automate Desktop\Console\Scripts\CFD13222-CA5B-447E-B7FF-51FE823BA40B\Runs\d0a4989f-5798-45bb-b6b3-c8658d54fc52\Actions.log'
        $ids = Get-FlowGuidFromLogPath $p
        $ids.flowGuid | Should Be 'cfd13222-ca5b-447e-b7ff-51fe823ba40b'
        $ids.runId | Should Be 'd0a4989f-5798-45bb-b6b3-c8658d54fc52'
        (Get-FlowGuidFromLogPath 'C:\temp\no-guid.log') | Should Be $null
    }

    It 'historical run lookup: filters by flow name and takes the latest startTime' {
        $work = New-Work
        $root = Join-Path $work 'Scripts'
        $g1 = '11111111-1111-1111-1111-111111111111'
        $g2 = '22222222-2222-2222-2222-222222222222'
        # Two runs of the target flow (older + newer) and a single run of another flow (noise)
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000a\RunDefinition.json") $g1 '目标流程' '2026-10-20T01:00:00Z' 'Succeeded' 'W/"100"'
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000b\RunDefinition.json") $g1 '目标流程' '2026-10-26T01:00:00Z' 'Succeeded' 'W/"200"'
        Write-RunDef (Join-Path $root "$g2\Runs\bbbbbbbb-0000-0000-0000-00000000000c\RunDefinition.json") $g2 '别的流程' '2026-10-27T01:00:00Z' 'Succeeded' 'W/"999"'
        $r = Find-LatestFlowRun $root '目标流程'
        $r.flowGuid | Should Be $g1
        $r.flowVersion | Should Be 'W/"200"'
        $r.startTime | Should Be '2026-10-26T01:00:00Z'
        # An unknown flow name returns null
        (Find-LatestFlowRun $root '不存在的流程') | Should Be $null
    }

    It 'historical run lookup: skips corrupt JSON files' {
        $work = New-Work
        $root = Join-Path $work 'Scripts'
        $g1 = '11111111-1111-1111-1111-111111111111'
        $bad = Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000a\RunDefinition.json"
        New-Item -ItemType File -Path $bad -Force | Out-Null
        [IO.File]::WriteAllText($bad, '{损坏的json', (New-Object Text.UTF8Encoding($false)))
        Write-RunDef (Join-Path $root "$g1\Runs\aaaaaaaa-0000-0000-0000-00000000000b\RunDefinition.json") $g1 '目标流程' '2026-10-26T01:00:00Z'
        (Find-LatestFlowRun $root '目标流程').flowGuid | Should Be $g1
    }

    It 'Workspace definition lookup: exact runId match, not misled by a newer modification time' {
        $work = New-Work
        $g1 = '11111111-1111-1111-1111-111111111111'
        $runId = '22222222-2222-2222-2222-222222222222'
        # Another revision directory has a "newer" modification time; picking the newest would select the wrong one
        $r1 = Join-Path $work "$g1\AAAA0001\script.robin"
        $r2 = Join-Path $work "$g1\$runId\script.robin"
        New-Item -ItemType File -Path $r1 -Force | Out-Null
        New-Item -ItemType File -Path $r2 -Force | Out-Null
        (Get-Item $r1).LastWriteTime = [datetime]'2026-09-30 08:00:00'
        (Get-Item $r2).LastWriteTime = [datetime]'2026-10-20 08:00:00'
        # This release happened on 10-25: r1 predates it (so "take the newest" must not pick it), while r2 is hit exactly by runId
        (Find-WorkspaceRobin $work $g1 $runId ([datetime]'2026-10-25 09:00:00')) | Should Be $r2
        (Find-WorkspaceRobin $work '33333333-3333-3333-3333-333333333333' $runId ([datetime]::UtcNow)) | Should Be $null
    }

    It 'Workspace definition lookup: without a runId only revisions written after this release count; null when none' {
        $work = New-Work
        $g1 = '11111111-1111-1111-1111-111111111111'
        $r1 = Join-Path $work "$g1\AAAA0001\script.robin"
        New-Item -ItemType File -Path $r1 -Force | Out-Null
        (Get-Item $r1).LastWriteTime = [datetime]'2026-10-20 08:00:00'
        # This release happened on 10-26: the old revision must not be selected (the old implementation would "take the newest" and grab it)
        (Find-WorkspaceRobin $work $g1 '' ([datetime]'2026-10-26 09:00:00')) | Should Be $null
        # The release happened on 10-19: this revision is the one written by this release
        (Find-WorkspaceRobin $work $g1 '' ([datetime]'2026-10-19 09:00:00')) | Should Be $r1
    }

    It 'Workspace definition lookup: ambiguous candidates raise an error instead of silently picking one' {
        $work = New-Work
        $g1 = '11111111-1111-1111-1111-111111111111'
        foreach ($rev in 'AAAA0001', 'BBBB0002') {
            $p = Join-Path $work "$g1\$rev\script.robin"
            New-Item -ItemType File -Path $p -Force | Out-Null
            (Get-Item $p).LastWriteTime = [datetime]'2026-10-27 08:00:00'
        }
        $ex = $null
        try { $null = Find-WorkspaceRobin $work $g1 '' ([datetime]'2026-10-26 09:00:00') }
        catch { $ex = $_.Exception }
        $ex.Data['code'] | Should Be 'FINGERPRINT_AMBIGUOUS'
        $ex.Message | Should Match '2 candidate revisions'
    }

    It 'manifest append: one valid JSON per line with all fields; repeated appends do not overwrite' {
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

    It 'run record: type=run with mode, status and error code fields, serializable as one JSON line' {
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

    It 'run record: warnings defaults to an empty array and serializes as an array when supplied' {
        $e = New-RunManifestEntry -FlowName 'F' -Ok $true -Stage 'done'
        (@($e.warnings)).Count | Should Be 0
        $e2 = New-RunManifestEntry -FlowName 'F' -Ok $true -Stage 'done' -Warnings @('缓存未刷新')
        (@($e2.warnings)).Count | Should Be 1
        (@((($e2 | ConvertTo-Json -Depth 6 -Compress) | ConvertFrom-Json).warnings))[0] | Should Be '缓存未刷新'
    }

    It 'manifest retention: run records expire after 90 days; release and rollback are kept forever' {
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

    It 'approval fingerprint: SHA256 for existing files, null when missing, prefixed short format' {
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

Describe 'pad-release no longer defaults to a concrete business flow' {
    It 'no -SourceRobin and the flow name resolves to nothing: non-zero exit before the execution stage' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Release `
            -FlowName 'NoSuchFlow-XYZ' -DryRun -SkipTests 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_SOURCE_ROBIN_REQUIRED'
        $out | Should Match '-SourceRobin'
        # It must fail before running tests or publishing (it must never reach the execution stage)
        $out | Should Not Match 'pytestPassed'
        $out | Should Not Match '"stage":"done"'
    }
}
