# build-acceptance.Tests.ps1 — 验收判据生成器测试（Pester 3.4）
#
# build-acceptance.ps1 结尾用 exit 返回状态，直接用 & 调用会连带结束测试会话，
# 因此这里统一起子进程执行，只看退出码与输出。
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $here '..\tools\pad-sync\build-acceptance.ps1'
$flow = Join-Path $here '..\flows\sample.json'
$committed = Join-Path $here '..\flows\sample.acceptance.json'

function Invoke-Build([string]$flowFile, [string]$outFile) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $build -FlowFile $flowFile -OutFile $outFile 2>&1
    return [pscustomobject]@{ code = $LASTEXITCODE; text = ($out -join "`n") }
}

Describe 'build-acceptance' {

    It '未知判据类型被拒绝，且不写文件' {
        $bad = Join-Path $TestDrive 'bad.json'
        $out = Join-Path $TestDrive 'bad-out.json'
        $spec = @{
            name = 'X'
            variables = @(@{ name = 'PadRoot'; type = 'string'; deployKey = 'PAD_ROOT' })
            acceptance = @{ checks = @(@{ name = '奇怪判据'; type = 'noSuchType'; path = 'x' }) }
        }
        [IO.File]::WriteAllText($bad, ($spec | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $r = Invoke-Build $bad $out
        $r.code | Should Be 1
        $r.text | Should Match '不受支持'
        Test-Path $out | Should Be $false
    }

    It '未解析的变量引用被拒绝' {
        $bad = Join-Path $TestDrive 'bad2.json'
        $out = Join-Path $TestDrive 'bad2-out.json'
        $spec = @{
            name = 'X'
            variables = @(@{ name = 'PadRoot'; type = 'string'; deployKey = 'PAD_ROOT' })
            acceptance = @{ checks = @(@{ name = '缺变量'; type = 'fileExists'; path = '{{variables.NoSuchVar}}\x.txt' }) }
        }
        [IO.File]::WriteAllText($bad, ($spec | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
        $r = Invoke-Build $bad $out
        $r.code | Should Be 1
        $r.text | Should Match '未解析的引用'
    }
}
