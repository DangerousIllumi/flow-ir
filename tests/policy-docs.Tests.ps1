# policy-docs.Tests.ps1 — 防止文档里的策略规则名与 business\policy.json 漂移
#
# business\ 不入库：策略文件不存在时本用例明确输出 SKIP 并视为通过，公开库 CI 不会变红。

$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'skills\pad-flow-designer\SKILL.md'
$prompts = Join-Path $repo 'docs\agent-prompts.md'
$policy = Join-Path $repo 'business\policy.json'

Describe '策略规则文档一致性' {

    It '设计 SKILL 不再抄规则表，只指向策略文件' {
        $text = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $text | Should Match 'business/policy\.json'
        $text | Should Match 'docs/admission-gate\.md'
        # SKILL 里不应再出现「| `deny-xxx` |」这种规则表行，规则名只允许在 policy.json 里定义
        ([regex]::Matches($text, '\| `(deny-[a-z-]+|ask-[a-z-]+)`')).Count | Should Be 0
    }

    It '文档里出现的规则名都存在于 business\policy.json（文件缺失时跳过）' {
        if (-not (Test-Path -LiteralPath $policy)) {
            Write-Host '[skip] business\policy.json 不存在（业务层不入库），跳过规则名比对'
            return
        }
        $policyText = Get-Content -LiteralPath $policy -Raw -Encoding UTF8
        $known = @([regex]::Matches($policyText, '"id"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $docText = Get-Content -LiteralPath $prompts -Raw -Encoding UTF8
        $refs = @([regex]::Matches($docText, '\| `(deny-[a-z-]+|ask-[a-z-]+)`') | ForEach-Object { $_.Groups[1].Value })
        $refs.Count | Should BeGreaterThan 0
        $unknown = @($refs | Where-Object { $known -notcontains $_ })
        ($unknown -join ', ') | Should Be ''
    }
}
