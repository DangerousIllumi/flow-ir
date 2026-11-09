# public-safe-gate.Tests.ps1 — 推送前内容门禁测试（Pester 3.4）
#
# 覆盖：命中业务词（退出码/行号/输出格式）、全部干净、UTF-16LE 与二进制不误判、
#       正则路径规则、默认词表分类、本地覆盖文件合并、清单文件缺失、自洽性检查。

$script:GateScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\publish\check-public-safe.ps1')).Path
. $script:GateScript -NoMain

$script:Repo = Split-Path -Parent $PSScriptRoot

# Pester 3.4 的 $TestDrive 在 Describe 内共享，每个用例用独立子目录
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# 写词表：Categories 是「分类名 → 含 rules 的哈希表」
function New-DenylistFile([string]$Dir, [hashtable]$Categories) {
    $doc = [ordered]@{ version = 1; categories = $Categories }
    $p = Join-Path $Dir 'denylist.json'
    [IO.File]::WriteAllText($p, ($doc | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    return $p
}

# 写文本文件：默认 UTF-8 带 BOM，Kind=utf-16le 时写 UTF-16LE 带 BOM
function New-TextFile([string]$Path, [string[]]$Lines, [string]$Kind = 'utf-8') {
    $text = ($Lines -join "`r`n") + "`r`n"
    if ($Kind -eq 'utf-16le') {
        [IO.File]::WriteAllText($Path, $text, (New-Object Text.UnicodeEncoding($false, $true)))
    } else {
        [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
    }
}

Describe 'Pre-push content gate' {

    It 'Business term hit: exit code 1 and the hit line carries the file and line number' {
        $work = New-Work
        $f = Join-Path $work 'sample.ps1'
        New-TextFile $f @('第一行：无害内容', '第二行：示例业务词')
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo-business'; pattern = '示例业务词'; regex = $false; reason = '占位演示' }) }
        }

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($d)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
        $r.Hits[0].Line | Should Be 2
        $r.Hits[0].Match | Should Be '示例业务词'
        $r.Hits[0].Category | Should Be 'businessName'
    }

    It 'The child process exits with code 1 and the output matches file:line:hit' {
        $work = New-Work
        $f = Join-Path $work 'sample.txt'
        New-TextFile $f @('干净行', 'DEMO_TOKEN_ABC')
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo-token'; pattern = 'DEMO_TOKEN_ABC'; regex = $false }) }
        }

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript -Files $f -DenylistFile $d
        $code = $LASTEXITCODE
        $code | Should Be 1
        (@($out) -join "`n") | Should Match ([regex]::Escape($f) + ':2:DEMO_TOKEN_ABC')
    }

    It 'All clean: exit code 0 and no hits' {
        $work = New-Work
        $f = Join-Path $work 'clean.ps1'
        New-TextFile $f @('第一行：通用说明', '第二行：仍然通用')
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo'; pattern = '示例业务词'; regex = $false }) }
        }

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($d)
        $r.ExitCode | Should Be 0
        @($r.Hits).Count | Should Be 0
    }

    It 'UTF-16LE (with BOM) decodes line by line correctly with no mojibake false positives' {
        $work = New-Work
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo'; pattern = '示例业务词'; regex = $false }) }
        }

        $hitFile = Join-Path $work 'legacy.vbs'
        New-TextFile $hitFile @('第一行：无害', '第二行：示例业务词') 'utf-16le'
        $r = Invoke-PublicSafeScan -Files @($hitFile) -DenylistFile @($d)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
        $r.Hits[0].Line | Should Be 2

        $cleanFile = Join-Path $work 'clean.vbs'
        New-TextFile $cleanFile @('第一行：无害', '第二行：同样无害') 'utf-16le'
        $r2 = Invoke-PublicSafeScan -Files @($cleanFile) -DenylistFile @($d)
        $r2.ExitCode | Should Be 0
        @($r2.Hits).Count | Should Be 0
    }

    It 'Binary files are scanned as Latin1 and produce no false positives from forced UTF-8 reads' {
        $work = New-Work
        $bin = Join-Path $work 'sample.bin'
        # PNG 文件头 + 若干高位字节：按 UTF-8 硬读会解码失败或产生乱码
        $bytes = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0xFF, 0xFE, 0xFD, 0xFC)
        [IO.File]::WriteAllBytes($bin, $bytes)

        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo'; pattern = '示例业务词'; regex = $false }) }
        }
        $r = Invoke-PublicSafeScan -Files @($bin) -DenylistFile @($d)
        $r.ExitCode | Should Be 0
        @($r.Hits).Count | Should Be 0
        ($r.Binary -contains $bin) | Should Be $true
    }

    It 'A regex rule can match path-like patterns' {
        $work = New-Work
        $f = Join-Path $work 'sample.ps1'
        New-TextFile $f @('第一行：无害', '路径：D:\DEMO\scripts\run.ps1')
        $d = New-DenylistFile $work @{
            realPath = @{ rules = @(@{ id = 'demo-path'; pattern = '(?i)[A-Za-z]:[\\]DEMO[\\]'; regex = $true; reason = '占位路径规则' }) }
        }

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($d)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
        $r.Hits[0].Line | Should Be 2
        $r.Hits[0].Match | Should Match 'DEMO'
    }

    It 'Local override files merge automatically: real terms live only in the local file' {
        $work = New-Work
        $cfg = Join-Path $work 'tools\publish'
        New-Item -ItemType Directory -Path $cfg -Force | Out-Null

        # 基础词表（入库版）：只有结构性规则
        $base = New-DenylistFile $cfg @{
            realPath = @{ rules = @(@{ id = 'base'; pattern = '(?i)[A-Za-z]:[\\]DEMO[\\]'; regex = $true }) }
        }
        Rename-Item -LiteralPath $base -NewName 'public-safe.denylist.json'

        # 本地覆盖（不入库）：模拟真实业务词
        $local = Join-Path $cfg 'public-safe.denylist.local.json'
        $json = '{"version":1,"categories":{"businessName":{"rules":[{"id":"local","pattern":"示例业务词","regex":false}]}}}'
        [IO.File]::WriteAllText($local, $json, (New-Object Text.UTF8Encoding($false)))

        $f = Join-Path $work 'sample.txt'
        New-TextFile $f @('示例业务词')

        # 不显式给词表：应自动找到 tools\publish 下的基础词表与本地覆盖
        $r = Invoke-PublicSafeScan -Files @($f) -RepoRoot $work
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
        $r.Hits[0].RuleId | Should Be 'local'
        @($r.Sources).Count | Should Be 2
    }

    It 'A business directory listed for scanning: exit code 2 with an explicit error instead of a silent skip' {
        $work = New-Work
        $business = Join-Path $work 'business\flows'
        New-Item -ItemType Directory -Path $business -Force | Out-Null
        $f = Join-Path $business 'real-flow.json'
        New-TextFile $f @('{"name":"真实业务流程"}')
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo'; pattern = '示例业务词'; regex = $false }) }
        }

        $r = Invoke-PublicSafeScan -Files @('business\flows\real-flow.json') -DenylistFile @($d) -RepoRoot $work
        $r.ExitCode | Should Be 2
        (@($r.Errors) -join "`n") | Should Match 'business files must not be pushed'
        @($r.Hits).Count | Should Be 0
    }

    It 'A listed file that does not exist: exit code 2, no silent skip' {
        $work = New-Work
        $d = New-DenylistFile $work @{
            businessName = @{ rules = @(@{ id = 'demo'; pattern = '示例业务词'; regex = $false }) }
        }
        $r = Invoke-PublicSafeScan -Files @((Join-Path $work 'missing.txt')) -DenylistFile @($d)
        $r.ExitCode | Should Be 2
        @($r.Missing).Count | Should Be 1
    }

    It 'The default denylist covers five categories, and the scanner, denylist and docs do not hit their own rules' {
        $dl = Join-Path $script:Repo 'tools\publish\public-safe.denylist.json'
        (Test-Path -LiteralPath $dl) | Should Be $true

        # 分类齐全（含只放占位示例的 flowName）
        $doc = ConvertFrom-Json ([IO.File]::ReadAllText($dl, [Text.Encoding]::UTF8))
        @($doc.categories.PSObject.Properties).Count | Should Be 5
        foreach ($name in @('businessName', 'realPath', 'flowName', 'accountOrServer', 'privateIdentifier')) {
            ($doc.categories.PSObject.Properties.Name -contains $name) | Should Be $true
        }

        # 自洽性：脚本、词表、文档本身不能命中词表，否则门禁自相矛盾
        $files = @(
            $script:GateScript,
            $dl,
            (Join-Path $script:Repo 'docs\admission-gate.md')
        )
        $r = Invoke-PublicSafeScan -Files $files -DenylistFile @($dl)
        @($r.Hits) | ForEach-Object { Write-Host ("自命中：{0}:{1}:{2}" -f $_.File, $_.Line, $_.Match) }
        $r.ExitCode | Should Be 0
        @($r.Hits).Count | Should Be 0
    }
}

Describe 'UNC path rule boundaries' {

    # 直接用仓库里的默认词表，保证测的是真实规则，而不是测试里另写一份
    $dl = Join-Path $script:Repo 'tools\publish\public-safe.denylist.json'

    It 'A real UNC path still hits (server segment of at least 2 characters, share segment not starting with a dot)' {
        $work = New-Work
        $f = Join-Path $work 'real.txt'
        # 拼接构造，避免测试文件本身出现 UNC 字面量而被门禁扫到
        $sep = [string][char]92
        $unc = ('{0}{0}demo-host{1}share01{1}backup' -f $sep, $sep)
        New-TextFile $f @("备份目录：$unc")

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($dl)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
        $r.Hits[0].RuleId | Should Be 'path-unc'
        $r.Hits[0].Match | Should Match 'demo-host'
    }

    It 'Regex literals and escape sequences no longer produce false hits' {
        $work = New-Work
        $f = Join-Path $work 'regex-literals.ps1'
        # 双反斜杠 + 单字符（x / n / t）不是 UNC 路径，只是正则转义写法
        New-TextFile $f @('$pattern = ''\\x\.json''', '换行转义：''\\n''', '制表转义：''\\t''')

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($dl)
        $r.ExitCode | Should Be 0
        @($r.Hits).Count | Should Be 0
    }
}

Describe 'Reserved domain allowlist' {

    $dl = Join-Path $script:Repo 'tools\publish\public-safe.denylist.json'

    It 'Emails in reserved domains do not hit (example.com / company.com / github.com)' {
        $work = New-Work
        $f = Join-Path $work 'emails.txt'
        New-TextFile $f @('sender@example.com', 'manager@company.com', 'git@github.com')

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($dl)
        $r.ExitCode | Should Be 0
        @($r.Hits).Count | Should Be 0
    }

    It 'Non-reserved domains still hit' {
        $work = New-Work
        $f = Join-Path $work 'emails-real.txt'
        # 假域是占位构造的，不对应任何真实客户；字符串拼接是为了测试文件自身也不带真实域名
        $fake1 = 'someone@' + 'acme-demo-corp.com'
        $fake2 = 'ops@' + 'internal-lab.example.net'
        New-TextFile $f @($fake1, $fake2)

        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($dl)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 2
        (@($r.Hits) | ForEach-Object { $_.RuleId }) -join ',' | Should Be 'email-address,email-address'
    }

    It 'The allowlist can be turned off with enabled:false' {
        $work = New-Work
        $doc = [ordered]@{
            version    = 1
            allowlist  = [ordered]@{ enabled = $false; domains = @('example.com') }
            categories = @{
                privateIdentifier = @{
                    rules = @(@{
                        id      = 'email-address'
                        pattern = '(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.](com|cn|net|org)\b'
                        regex   = $true
                        reason  = '占位：邮箱'
                    })
                }
            }
        }
        $dl2 = Join-Path $work 'denylist-off.json'
        [IO.File]::WriteAllText($dl2, ($doc | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))

        $f = Join-Path $work 'email.txt'
        New-TextFile $f @('sender@example.com')
        $r = Invoke-PublicSafeScan -Files @($f) -DenylistFile @($dl2)
        $r.ExitCode | Should Be 1
        @($r.Hits).Count | Should Be 1
    }
}
