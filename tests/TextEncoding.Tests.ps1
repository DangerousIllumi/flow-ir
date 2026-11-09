# TextEncoding.Tests.ps1 — encoding detection and safe write-back tests (Pester 3.4, bundled with PS 5.1)
#
# Three real-world sources are covered:
#   UTF-16LE (VBS OpenTextFile(..., True) logs)
#   ANSI (Chinese Windows code page 936, saved by Notepad or older tools)
#   UTF-8-BOM (repository scripts and PAD artifacts)
# Every case asserts: correct detection, readable text, and write-back byte-identical to the original file.

$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\TextEncoding.psm1'
Import-Module $script:Module -Force

# Pester 3.4 shares $TestDrive across the whole Describe, so each case gets its own subdirectory
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# The ANSI case only matters on a system whose ANSI code page can represent Chinese (cp936 on Chinese Windows);
# on an English Windows cp1252 cannot encode Chinese (it silently becomes ?), so the case is skipped there
$script:AnsiCjk = $false
try {
    $script:AnsiEnc = Get-AnsiEncoding
    $script:AnsiCjk = ($script:AnsiEnc.GetString($script:AnsiEnc.GetBytes('中文')) -eq '中文')
} catch { $script:AnsiCjk = $false }

Describe 'TextEncoding encoding detection and safe write-back' {

    It 'UTF-8-BOM: detected as utf-8-bom, Chinese readable, write-back keeps the BOM' {
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

    It 'ANSI (GBK): detected as ansi, Chinese readable, write-back has no BOM and is byte-identical' {
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

    It 'UTF-16LE (VBS log): detected as utf-16le, write-back stays double-byte with BOM' {
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

    It 'UTF-8 text without BOM: judged as utf-8 and never misjudged as ansi' {
        $work = New-Work
        $p = Join-Path $work 'd.txt'
        [IO.File]::WriteAllText($p, '中文内容', (New-Object Text.UTF8Encoding($false)))

        $r = Read-TextFileAuto $p
        $r.kind | Should Be 'utf-8'
        $r.bom | Should Be $false
        $r.text | Should Be '中文内容'
    }
}
