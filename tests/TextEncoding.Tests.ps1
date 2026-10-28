# TextEncoding.Tests.ps1 — 编码探测与安全写回测试（Pester 3.4，PS 5.1 自带）
#
# 覆盖三种真实来源：
#   UTF-16LE（VBS 的 OpenTextFile(..., True) 日志）
#   ANSI（中文 Windows 代码页 936，记事本/旧工具保存）
#   UTF-8-BOM（仓库脚本与 PAD 产物）
# 每个用例断言：探测结果正确、内容可读、写回后编码与原文件一致（字节级）。

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\TextEncoding.psm1'
Import-Module $script:Module -Force

# Pester 3.4 的 $TestDrive 整个 Describe 共享，每个用例用独立子目录
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# ANSI 用例只对「ANSI 代码页能表示中文」的系统有意义（中文 Windows 为 cp936）；
# 英文 Windows 的 cp1252 编不出中文（会静默变成 ?），此时该用例直接跳过
$script:AnsiCjk = $false
try {
    $script:AnsiEnc = Get-AnsiEncoding
    $script:AnsiCjk = ($script:AnsiEnc.GetString($script:AnsiEnc.GetBytes('中文')) -eq '中文')
} catch { $script:AnsiCjk = $false }

Describe 'TextEncoding 编码探测与安全写回' {

    It 'UTF-8-BOM：探测为 utf-8-bom，中文可读，写回保留 BOM' {
        $work = New-Work
        $p = Join-Path $work 'a.txt'
        [IO.File]::WriteAllText($p, "第一行中文`r`nSET A TO 'x'", (New-Object Text.UTF8Encoding($true)))

        $r = Read-TextFileAuto $p
        $r.kind | Should Be 'utf-8-bom'
        $r.bom | Should Be $true
        $r.text | Should Match '第一行中文'

        Write-TextFileAs $p ($r.text + "`r`n追加一行") $r.kind $r.bom
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true
        (Read-TextFileAuto $p).text | Should Match '追加一行'
    }

    It 'ANSI（GBK）：探测为 ansi，中文可读，写回无 BOM 且字节完全不变' {
        if (-not $script:AnsiCjk) { Write-Host '跳过：本机 ANSI 代码页无法表示中文'; return }
        $work = New-Work
        $p = Join-Path $work 'b.log'
        $enc = Get-AnsiEncoding
        $raw = $enc.GetBytes('导出失败：找不到窗口')
        [IO.File]::WriteAllBytes($p, $raw)

        $r = Read-TextFileAuto $p
        $r.kind | Should Be 'ansi'
        $r.bom | Should Be $false
        $r.text | Should Be '导出失败：找不到窗口'

        Write-TextFileAs $p $r.text $r.kind $r.bom
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xEF) | Should Be $false
        ($b[0] -eq 0xFF) | Should Be $false
        ([Convert]::ToBase64String($b)) | Should Be ([Convert]::ToBase64String($raw))
    }

    It 'UTF-16LE（VBS 日志）：探测为 utf-16le，写回仍是双字节带 BOM' {
        $work = New-Work
        $p = Join-Path $work 'c.log'
        [IO.File]::WriteAllText($p, '过账完成 2 行', (New-Object Text.UnicodeEncoding($false, $true)))

        $r = Read-TextFileAuto $p
        $r.kind | Should Be 'utf-16le'
        $r.bom | Should Be $true
        $r.text | Should Be '过账完成 2 行'

        Write-TextFileAs $p ($r.text + '!') $r.kind $r.bom
        $b = [IO.File]::ReadAllBytes($p)
        ($b[0] -eq 0xFF -and $b[1] -eq 0xFE) | Should Be $true
        (Read-TextFileAuto $p).text | Should Be '过账完成 2 行!'
    }

    It '无 BOM 的 UTF-8 文本：判为 utf-8，不能被误判成 ansi' {
        $work = New-Work
        $p = Join-Path $work 'd.txt'
        [IO.File]::WriteAllText($p, '中文内容', (New-Object Text.UTF8Encoding($false)))

        $r = Read-TextFileAuto $p
        $r.kind | Should Be 'utf-8'
        $r.bom | Should Be $false
        $r.text | Should Be '中文内容'
    }
}
