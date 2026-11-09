# 冒烟脚本：在全新 clone 上验证工具链（不依赖业务目录、指纹基线或 PAD 运行历史）
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File examples\smoke.ps1
# 退出码：0 全部步骤通过 / 1 任意步骤失败
#
# 步骤：画布 → 生成 → check.js → pad-admit → eval-flow

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$flow = Join-Path $PSScriptRoot 'smoke-flow.json'
$kb = Join-Path $PSScriptRoot 'smoke-kb.json'
$cases = Join-Path $PSScriptRoot 'smoke.cases.json'
$work = Join-Path ([IO.Path]::GetTempPath()) ('flow-ir-smoke-' + [guid]::NewGuid().ToString('N'))
$failed = $false

function Invoke-Step {
    param(
        [string]$Name,
        [string]$WorkingDirectory,
        [string]$Command,
        [string[]]$Arguments
    )
    Write-Host "[smoke] $Name"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Command @Arguments
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($code -ne 0) { throw "$Name 失败（exit=$code）" }
}

try {
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    # check.js 的 KB 查找优先仓库根，其次当前目录；把最小动作表放到当前目录，
    # 这样没有 pad-robin-action-kb/ 的全新 clone 也能完成静态校验
    $kbDir = Join-Path $work 'pad-robin-action-kb'
    New-Item -ItemType Directory -Path $kbDir -Force | Out-Null
    Copy-Item -LiteralPath $kb -Destination (Join-Path $kbDir 'PAD_Robin_ActionKB.json') -Force

    $drawio = Join-Path $work 'smoke-flow.drawio'
    $robin = Join-Path $work 'smoke-flow.robin'
    $admit = Join-Path $repo 'tools\pad-sync\pad-admit.ps1'

    # 全新 clone 可能还没执行 npm install；此时退回仓库自带的确定性 BFS 布局，
    # 保证「画布」这一步不依赖 node_modules/elkjs
    $drawioScript = Join-Path $repo 'tools\flow-drawio\flow-to-drawio.js'
    if (-not (Test-Path (Join-Path $repo 'node_modules\elkjs'))) {
        $drawioScript = Join-Path $repo 'tools\flow-drawio\flow-to-drawio-bfs.js'
    }

    Invoke-Step '画布' $repo 'node' @($drawioScript, $flow, $drawio)
    Invoke-Step '生成' $repo 'node' @(
        (Join-Path $repo 'tools\pad-robin\flow-to-robin.js'), $flow, $robin, '--kb', $kb, '--no-check')
    Invoke-Step '静态校验' $work 'node' @(
        (Join-Path $repo 'tools\pad-robin\check.js'), $robin)
    Invoke-Step '准入' $work 'powershell' @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $admit,
        '-FlowFile', $flow, '-RobinFile', $robin, '-KbPath', $kb)
    Invoke-Step '结构评估' $repo 'node' @(
        (Join-Path $repo 'tools\pad-robin\eval-flow.js'), $cases)

    Write-Host '[smoke] 通过（exit 0）'
} catch {
    Write-Host "[smoke] 失败：$($_.Exception.Message)"
    $failed = $true
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
exit 0
