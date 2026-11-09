# pad-verify.ps1 — 按验收判据检查一次运行的产物（只读，不触碰 PAD）
#
# 用法：
#   .\pad-verify.ps1 -AcceptanceFile business\flows\sample-report.acceptance.json `
#                    -ConfigFile business\config\sample-report.json
#   .\pad-verify.ps1 -BuildFromFlow -FlowFile business\flows\sample-report.json `
#                    -ConfigFile business\config\sample-report.json
#
# 参数：
#   -AcceptanceFile  验收判据 JSON
#   -BuildFromFlow   由 flow.json 的 acceptance 声明现生成判据（忽略 -AcceptanceFile）
#   -FlowFile        配合 -BuildFromFlow；不传时要求 business\flows 目录里唯一匹配，否则报候选数
#   -ConfigFile      部署配置（用于替换 {{KEY}} 占位符）
#   -Since           只认这个时间之后产生的文件；默认 6 小时前
#   -Json            打印完整 JSON 明细
#
# 输出：最后一行固定 PAD_VERIFY_RESULT=<JSON>；退出码 0=通过 / 1=失败

[CmdletBinding()]
param(
    [string]$AcceptanceFile,
    [Parameter(Mandatory = $true)][string]$ConfigFile,
    # 直接从 flow.json 的 acceptance 声明生成判据（不再依赖手写的 acceptance.json）
    [string]$FlowFile,
    [switch]$BuildFromFlow,
    [datetime]$Since = (Get-Date).AddHours(-6),
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PadAcceptance.psm1') -Force

# 生成模式：先由 flow.json 现算一份判据到临时目录，再走同一套验收逻辑
if ($BuildFromFlow) {
    if (-not $FlowFile) {
        # 不再默认到某个具体业务流程：business\flows 目录里必须唯一匹配，否则要求显式指定
        $flowsDir = Join-Path (Split-Path -Parent $PSScriptRoot) '..\business\flows'
        $cands = @(Get-ChildItem -LiteralPath $flowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '\.(acceptance|requirements|schema)\.json$' })
        if ($cands.Count -eq 1) { $FlowFile = $cands[0].FullName }
        elseif ($cands.Count -eq 0) { $FlowFile = $null }
        else {
            Write-Output ('PAD_VERIFY_RESULT={"ok":false,"error":"business\\flows 目录有 ' + $cands.Count + ' 个候选，请用 -FlowFile 指定"}')
            exit 1
        }
    }
    if (-not $FlowFile) {
        Write-Output 'PAD_VERIFY_RESULT={"ok":false,"error":"未提供 -FlowFile，business\\flows 目录里也没有流程定义；请用 -FlowFile 指定"}'
        exit 1
    }
    $AcceptanceFile = Join-Path $env:TEMP ("pad-acceptance-" + [guid]::NewGuid().ToString('N') + ".json")
    & (Join-Path $PSScriptRoot 'build-acceptance.ps1') -FlowFile $FlowFile -OutFile $AcceptanceFile
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('PAD_VERIFY_RESULT={"ok":false,"error":"从 flow.json 生成验收判据失败"}')
        exit 1
    }
}
if (-not $AcceptanceFile) {
    Write-Error "缺少 -AcceptanceFile（或用 -BuildFromFlow 指定 -FlowFile）"
    exit 1
}

try {
    $config = Get-AcceptanceConfig -Path $ConfigFile
    $result = Test-AcceptanceFile -Path $AcceptanceFile -Config $config -Since $Since

    if ($Json) {
        Write-Output ($result | ConvertTo-Json -Depth 8)
    } else {
        Write-Host "[verify] 验收判据：$($result.acceptanceFile)"
        foreach ($c in $result.checks) {
            $mark = 'FAIL'
            if ($c.skipped) { $mark = 'SKIP' }
            elseif ($c.ok) { $mark = 'OK  ' }
            Write-Host ("  [{0}] {1}：{2}" -f $mark, $c.name, $c.detail)
        }
        Write-Host ("[verify] 通过 {0} / 失败 {1} / 跳过 {2}" -f $result.passed, $result.failed, $result.skipped)
    }

    Write-Output ("PAD_VERIFY_RESULT=" + ($result | ConvertTo-Json -Depth 8 -Compress))
    if ($result.ok) { exit 0 } else { exit 1 }
} catch {
    $err = [ordered]@{ ok = $false; error = $_.Exception.Message }
    Write-Output ("PAD_VERIFY_RESULT=" + ($err | ConvertTo-Json -Compress))
    exit 1
}
