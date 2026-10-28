# pad-rollback.Tests.ps1 — 发布回滚的快照逻辑测试（Pester 3.4，PS 5.1 自带）
#
# 覆盖：快照归档（目录 / 文件名 / 内容）、快照列举（时间升序、排除部署产物）、
#       回滚目标选择（默认上一版、-Back 步数、-To 精确指定、越界与缺失报错）、
#       流程名含非法字符时的目录名处理。
#
# 通过 dot-source -NoMain 只加载函数，绝不触发真实发布。

. (Join-Path $PSScriptRoot '..\tools\pad-sync\pad-rollback.ps1') -NoMain

# 每个用例的独立工作目录（Pester 3.4 的 $TestDrive 整个 Describe 共享）
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# 直接造一个快照文件（绕开 Save-ReleaseSnapshot，便于控制时间戳）
function New-Snap([string]$Root, [string]$Flow, [string]$Stamp, [string]$Sha, [string]$Text = "SET A TO 'x'") {
    $dir = Get-ReleaseSnapshotDir $Root $Flow
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir ($Stamp + '-' + $Sha + '.robin')
    [IO.File]::WriteAllText($p, $Text, (New-Object Text.UTF8Encoding($false)))
    return $p
}

Describe 'pad-rollback 快照测试' {

    It '快照归档：按流程名建目录，文件名 = 时间戳 + sha 前 8 位，内容与成品一致' {
        $work = New-Work
        $src = Join-Path $work 'sample.deployed.robin'
        [IO.File]::WriteAllText($src, "SET A TO 'x'", (New-Object Text.UTF8Encoding($false)))
        $p = Save-ReleaseSnapshot (Join-Path $work 'snapshots') 'PAD_SYNC_TEST' $src 'abcdef1234567890' ([datetime]'2026-10-28 09:05:07')
        $p | Should Be (Join-Path $work 'snapshots\PAD_SYNC_TEST\20261028-090507-abcdef12.robin')
        ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) | Should Be "SET A TO 'x'"
    }

    It '快照列举：按文件名升序（即时间升序），并排除 *.deployed.robin 部署产物' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        # 部署中间产物不能算作版本
        [IO.File]::WriteAllText((Join-Path (Get-ReleaseSnapshotDir $root 'F') '20261028-110000-dddddddd.deployed.robin'), 'x', (New-Object Text.UTF8Encoding($false)))
        $list = @(Get-ReleaseSnapshots $root 'F')
        $list.Count | Should Be 3
        $list[0].Name | Should Be '20261026-100000-aaaaaaaa.robin'
        $list[1].Name | Should Be '20261027-100000-bbbbbbbb.robin'
        $list[2].Name | Should Be '20261028-100000-cccccccc.robin'
    }

    It '快照列举：目录不存在时返回空数组' {
        $work = New-Work
        $list = @(Get-ReleaseSnapshots (Join-Path $work 'snapshots') '不存在的流程')
        $list.Count | Should Be 0
    }

    It '默认回退一个版本：跳过最近一个快照，取倒数第二个' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        $latest = New-Snap $root 'F' '20261028-100000' 'cccccccc'
        $t = Select-RollbackSnapshot $root 'F' -Back 1
        $t.Name | Should Be '20261027-100000-bbbbbbbb.robin'
        $t.FullName | Should Not Be $latest
    }

    It '-Back 2 回退到更早的一版' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        (Select-RollbackSnapshot $root 'F' -Back 2).Name | Should Be '20261026-100000-aaaaaaaa.robin'
    }

    It '版本不足时回退报错，且错误信息给出当前版本数' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -Back 1 } | Should Throw
        try { Select-RollbackSnapshot $root 'F' -Back 1 } catch { $_.Exception.Message | Should Match '只有 1 个版本' }
    }

    It '-Back 小于 1 直接报错' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -Back 0 } | Should Throw
    }

    It '-To 支持完整文件名与 sha 前缀' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261026-100000' 'aaaaaaaa' | Out-Null
        New-Snap $root 'F' '20261027-100000' 'bbbbbbbb' | Out-Null
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        (Select-RollbackSnapshot $root 'F' -To 'aaaaaaaa').Name | Should Be '20261026-100000-aaaaaaaa.robin'
        (Select-RollbackSnapshot $root 'F' -To '20261027-100000-bbbbbbbb.robin').Name | Should Be '20261027-100000-bbbbbbbb.robin'
    }

    It '-To 匹配不到时报错' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        New-Snap $root 'F' '20261028-100000' 'cccccccc' | Out-Null
        { Select-RollbackSnapshot $root 'F' -To 'ffffffff' } | Should Throw
    }

    It '流程无任何快照时报错，并给出快照目录' {
        $work = New-Work
        try { Select-RollbackSnapshot (Join-Path $work 'snapshots') '新流程' } catch {
            $_.Exception.Message | Should Match '没有任何快照'
            $_.Exception.Message | Should Match '新流程'
        }
    }

    It '流程名含路径分隔符等非法字符时，目录名被安全替换' {
        $work = New-Work
        $root = Join-Path $work 'snapshots'
        $dir = Get-ReleaseSnapshotDir $root 'A/B:C*D?E"F<G>H|I'
        (Split-Path -Leaf $dir) | Should Be 'A_B_C_D_E_F_G_H_I'
        # 正常中文流程名保持原样
        (Split-Path -Leaf (Get-ReleaseSnapshotDir $root '示例报表核对')) | Should Be '示例报表核对'
    }

    It '快照保留：超过 20 个时只保留最新 20 个' {
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
