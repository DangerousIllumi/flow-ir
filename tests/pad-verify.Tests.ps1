# pad-verify.Tests.ps1 — 验收脚本「不再默认到具体业务流程」的回归测试（Pester 3.4）
#
# 为什么复制脚本到临时目录：flows 目录由脚本自身位置推导，
# 只有在临时目录里才能造出「0 个 / 多个候选」两种失败场景。

Describe 'pad-verify no longer defaults to a concrete business flow' {

    # 把 tools\pad-sync 复制到独立目录，得到一个可控的 business\flows 目录
    function New-VerifySandbox {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $tools = Join-Path $root 'tools\pad-sync'
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..\tools\pad-sync\*') $tools -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $root 'business\flows') -Force | Out-Null
        return [pscustomobject]@{
            Script = Join-Path $tools 'pad-verify.ps1'
            Flows  = Join-Path $root 'business\flows'
        }
    }

    # 配置只用来满足 -ConfigFile 参数：两个用例都在解析 flow 之前就失败，不会读取配置内容
    function New-EmptyConfig {
        $p = Join-Path $TestDrive ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($p, '{}', (New-Object Text.UTF8Encoding($false)))
        return $p
    }

    It 'empty flows directory: non-zero exit demanding an explicit -FlowFile and generating no criteria' {
        $box = New-VerifySandbox
        $cfg = New-EmptyConfig
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $box.Script `
            -BuildFromFlow -ConfigFile $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_FLOW_FILE_REQUIRED'
        $out | Should Match '-FlowFile'
        # 不能进入验收检查阶段（成功路径才输出汇总行与 checks 字段）
        $out | Should Not Match 'VERIFY_SUMMARY'
        $out | Should Not Match '"checks"'
    }

    It 'multiple flow candidates: non-zero exit reporting the candidate count' {
        $box = New-VerifySandbox
        foreach ($n in 'a.json', 'b.json') {
            [IO.File]::WriteAllText((Join-Path $box.Flows $n), '{}', (New-Object Text.UTF8Encoding($false)))
        }
        $cfg = New-EmptyConfig
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $box.Script `
            -BuildFromFlow -ConfigFile $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_FLOW_AMBIGUOUS'
        $out | Should Match 'candidates=2'
        $out | Should Match '-FlowFile'
        $out | Should Not Match 'VERIFY_SUMMARY'
    }
}
