# pad-verify.ps1 — check the artefacts of one run against the acceptance criteria (read-only; never touches PAD)
#
# Usage:
#   .\pad-verify.ps1 -AcceptanceFile business\flows\sample-report.acceptance.json `
#                    -ConfigFile business\config\sample-report.json
#   .\pad-verify.ps1 -BuildFromFlow -FlowFile business\flows\sample-report.json `
#                    -ConfigFile business\config\sample-report.json
#
# Parameters:
#   -AcceptanceFile  Acceptance criteria JSON
#   -BuildFromFlow   Generate the criteria on the fly from flow.json's acceptance declaration (ignores -AcceptanceFile)
#   -FlowFile        Used with -BuildFromFlow; when omitted it requires a unique match in the business\flows directory, otherwise it reports the number of candidates
#   -ConfigFile      Deployment config (used to substitute {{KEY}} placeholders)
#   -Since           Only accept files produced after this time; default is 6 hours ago
#   -Json            Print the full JSON detail
#
# Output: the last line is always PAD_VERIFY_RESULT=<JSON>; exit code 0=pass / 1=fail

[CmdletBinding()]
param(
    [string]$AcceptanceFile,
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    # Build the criteria directly from flow.json's acceptance declaration (no longer relies on a hand-written acceptance.json)
    [string]$FlowFile,
    [switch]$BuildFromFlow,
    [datetime]$Since = (Get-Date).AddHours(-6),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PadAcceptance.psm1') -Force

# Generation mode: compute the criteria from flow.json into a temp directory, then go through the same acceptance logic
if ($BuildFromFlow) {
    if (-not $FlowFile) {
        # No longer default to a particular business flow: the business\flows directory must yield a unique match, otherwise an explicit value is required
        $flowsDir = Join-Path (Split-Path -Parent $PSScriptRoot) '..\business\flows'
        $cands = @(Get-ChildItem -LiteralPath $flowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' })
        if ($cands.Count -eq 1) { $FlowFile = $cands[0].FullName }
        elseif ($cands.Count -eq 0) { $FlowFile = $null }
        else {
            Write-Output ('PAD_VERIFY_RESULT={"ok":false,"error":"E_FLOW_AMBIGUOUS(candidates=' + $cands.Count + '): the business\\flows directory has ' + $cands.Count + ' candidates; specify one with -FlowFile"}')
            exit 1
        }
    }
    if (-not $FlowFile) {
        Write-Output 'PAD_VERIFY_RESULT={"ok":false,"error":"E_FLOW_FILE_REQUIRED: -FlowFile not provided and the business\\flows directory has no flow definition; specify it with -FlowFile"}'
        exit 1
    }
    $AcceptanceFile = Join-Path $env:TEMP ("pad-acceptance-" + [guid]::NewGuid().ToString('N') + ".json")
    & (Join-Path $PSScriptRoot 'build-acceptance.ps1') -FlowFile $FlowFile -OutFile $AcceptanceFile
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('PAD_VERIFY_RESULT={"ok":false,"error":"E_ACCEPTANCE_BUILD_FAILED: failed to build acceptance criteria from flow.json"}')
        exit 1
    }
}
if (-not $AcceptanceFile) {
    Write-Error "-AcceptanceFile is missing (or pass -FlowFile with -BuildFromFlow)"
    exit 1
}

try {
    $config = Get-AcceptanceConfig -Path $ConfigFile
    $result = Test-AcceptanceFile -Path $AcceptanceFile -Config $config -Since $Since

    if ($Json) {
        Write-Output ($result | ConvertTo-Json -Depth 8)
    } else {
        Write-Host "[verify] acceptance criteria: $($result.acceptanceFile)"
        foreach ($c in $result.checks) {
            $mark = 'FAIL'
            if ($c.skipped) { $mark = 'SKIP' }
            elseif ($c.ok) { $mark = 'OK  ' }
            Write-Host ("  [{0}] {1}: {2}" -f $mark, $c.name, $c.detail)
        }
        Write-Host ("[verify] VERIFY_SUMMARY pass {0} / fail {1} / skipped {2}" -f $result.passed, $result.failed, $result.skipped)
    }

    Write-Output ("PAD_VERIFY_RESULT=" + ($result | ConvertTo-Json -Depth 8 -Compress))
    if ($result.ok) { exit 0 } else { exit 1 }
} catch {
    $err = [ordered]@{ ok = $false; error = $_.Exception.Message }
    Write-Output ("PAD_VERIFY_RESULT=" + ($err | ConvertTo-Json -Compress))
    exit 1
}
