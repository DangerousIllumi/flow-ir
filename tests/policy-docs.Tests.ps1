# policy-docs.Tests.ps1 — keeps the policy rule names quoted in the docs from drifting away from business\policy.json
#
# business\ is never committed: when the policy file is absent the case prints an explicit SKIP and counts as a pass, so public CI never turns red.

$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'skills\pad-flow-designer\SKILL.md'
$prompts = Join-Path $repo 'docs\agent-prompts.md'
$policy = Join-Path $repo 'business\policy.json'

Describe 'Policy rule documentation consistency' {

    It 'The design SKILL no longer copies the rule table and only points to the policy file' {
        $text = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $text | Should Match 'business/policy\.json'
        $text | Should Match 'docs/admission-gate\.md'
        # The SKILL must no longer carry rule-table rows like "| `deny-xxx` |"; rule names are defined only in policy.json
        ([regex]::Matches($text, '\| `(deny-[a-z-]+|ask-[a-z-]+)`')).Count | Should Be 0
    }

    It 'Rule names appearing in the docs all exist in business\policy.json (skipped when the file is missing)' {
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
