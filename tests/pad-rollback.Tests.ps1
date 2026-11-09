# pad-rollback.Tests.ps1 — tests for the snapshot logic behind release rollback (Pester 3.4, bundled with PowerShell 5.1)
#
# Covers: snapshot archiving (directory / file name / content), snapshot listing (ascending time, excluding deployment artifacts),
#        rollback target selection (previous version by default, -Back steps, exact -To, out-of-range and missing errors),
#        and directory-name handling when a flow name contains illegal characters.
#
# Dot-source with -NoMain to load only the functions; a real release is never triggered.

. (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-rollback.ps1') -NoMain

# A separate working directory per test ($TestDrive is shared across a whole Describe in Pester 3.4)
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# Create a snapshot file directly (bypassing Save-ReleaseSnapshot so the timestamp is controllable)
function New-Snap([string]$Root, [string]$Flow, [string]$Stamp, [string]$Sha, [string]$Text = "SET A TO 'x'") {
    $dir = Get-ReleaseSnapshotDir $Root $Flow
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir ($Stamp + '-' + $Sha + '.robin')
    [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    return $p
}

Describe 'pad-rollback snapshot tests' {

    It 'snapshot archive: per-flow directory, file name is timestamp plus the first 8 sha characters, content matches the artifact' {
        $work = New-Work
        $src = Join-Path $work 'sample.deployed.robin'
        [IO.File]::WriteAllText($src, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $p = Save-ReleaseSnapshot (Join-Path $work 'snapshots') 'PAD_SYNC_TEST' $src 'abcdef1234567890' ([datetime]'2026-10-28 09:05:07')
        $p | Should Be (Join-Path $work 'snapshots\PAD_SYNC_TEST\20261028-090507-abcdef12.robin')
        ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) | Should Be "SET A TO 'x'"
    }

    It 'snapshot listing: ascending file name order (ascending time), excluding *.deployed.robin artifacts' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        # A deployment intermediate artifact must not count as a version
        [IO.File]::WriteAllText((Join-Path (Get-ReleaseSnapshotDir $root 'F') '20261028-110000-dddddddd.deployed.robin'), 'x', (New-Object Text.UTF8Encoding($false)))
        $list = @(Get-ReleaseSnapshots $root 'F')
        $list.Count | Should Be 3
        $list[0].Name | Should Be '20261026-100000-aaaaaaaa.robin'
        $list[1].Name | Should Be '20261027-100000-bbbbbbbb.robin'
        $list[2].Name | Should Be '20261028-100000-cccccccc.robin'
    }

    It 'snapshot listing: returns an empty array when the directory is missing' {
        $work = New-Work
        $list = @(Get-ReleaseSnapshots (Join-Path $work 'snapshots') '不存在的流程')
        $list.Count | Should Be 0
    }

    It 'default rollback of one version: skip the newest snapshot and take the second newest' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        $latest = New-Snap $root 'F' '20261028-100000' 'cccccccc'
        $t = Select-RollbackSnapshot $root 'F' -Back 1
        $t.Name | Should Be '20261027-100000-bbbbbbbb.robin'
        $t.FullName | Should Not Be $latest
    }

    It '-Back 2 rolls back to an earlier version' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        (Select-RollbackSnapshot $root 'F' -Back 2).Name | Should Be '20261026-100000-aaaaaaaa.robin'
    }

    It 'insufficient versions raise an error with the current version count' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -Back 1 } | Should Throw
        try { Select-RollbackSnapshot $root 'F' -Back 1 } catch { $_.Exception.Message | Should Match 'only 1 version' }
    }

    It '-Back below 1 raises an error' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -Back 0 } | Should Throw
    }

    It '-To accepts a full file name and a sha prefix' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        (Select-RollbackSnapshot $root 'F' -To 'aaaaaaaa').Name | Should Be '20261026-100000-aaaaaaaa.robin'
        (Select-RollbackSnapshot $root 'F' -To '20261027-100000-bbbbbbbb.robin').Name | Should Be '20261027-100000-bbbbbbbb.robin'
    }

    It '-To with no match raises an error' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -To 'ffffffff' } | Should Throw
    }

    It 'a flow without snapshots raises an error naming the snapshot directory' {
        $work = New-Work
        try { Select-RollbackSnapshot (Join-Path $work 'snapshots') '新流程' } catch {
            $_.Exception.Message | Should Match 'has no snapshots'
            $_.Exception.Message | Should Match '新流程'
        }
    }

    It 'illegal characters such as path separators in a flow name are safely replaced in the directory name' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        $dir = Get-ReleaseSnapshotDir $root 'A/B:C*D?E"F<G>H|I'
        (Split-Path -Leaf $dir) | Should Be 'A_B_C_D_E_F_G_H_I'
        # A normal Chinese flow name is kept as-is
        (Split-Path -Leaf (Get-ReleaseSnapshotDir $root '通用示例流程')) | Should Be '通用示例流程'
    }

    It 'snapshot retention: keep only the newest 20 when more than 20 exist' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        for ($i = 1; $i -le 25; $i++) {
            New-Snap $root 'F' ('202601{0:D2}-100000' -f $i) ('{0:x8}' -f $i) | Out-Null
        }
        $dir = Get-ReleaseSnapshotDir $root 'F'
        $removed = @(Remove-OldReleaseSnapshots -Dir $dir -Keep 20)
        @(Get-ChildItem -LiteralPath $dir -File).Count | Should Be 20
        $removed.Count | Should Be 5
    }
}

Describe 'pad-rollback no longer defaults to a concrete business flow' {
    It 'no -ConfigFile and the flow name resolves to nothing: non-zero exit before lookup or publishing' {
        $script = Join-Path $PSScriptRoot '..\tools\pad-sync\pad-rollback.ps1'
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script `
            -FlowName 'NoSuchFlow-XYZ' -DryRun 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_CONFIG_REQUIRED'
        $out | Should Match '-ConfigFile'
        # It must never reach snapshot selection or the rollback publish
        $out | Should Not Match '"stage":"select"'
        $out | Should Not Match '"stage":"done"'
    }
}
