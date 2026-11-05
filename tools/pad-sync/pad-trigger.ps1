# pad-trigger.ps1 —— 触发注册器的命令行外壳
#
# 用法：
#   .\pad-trigger.ps1 -FlowFile business\flows\<流程名>.json -Register -DryRun
#   .\pad-trigger.ps1 -FlowFile ... -Register -AllowProd
#   .\pad-trigger.ps1 -FlowFile ... -Test
#   .\pad-trigger.ps1 -FlowFile ... -Unregister [-DryRun]
#   .\pad-trigger.ps1 -FlowFile ... -ConfigFile ... -Watch [-AllowProd]
#
# 末行固定输出 PAD_TRIGGER_RESULT=<JSON>；退出码 0 成功 / 1 注册、校验或守望失败 / 2 输入错误。
# -Test 与 -Register -DryRun 全程只读：不写系统、不建目录、不触发运行。
# -Watch 是计划任务实际调用的守望入口：按 poll_sec 轮询，max_wait_sec 到点静默退出 0。

[CmdletBinding()]
param(
    [string]$FlowFile,
    [string]$ConfigFile,
    [string]$RuntimeConfigPath,
    [switch]$Register,
    [switch]$Test,
    [switch]$Unregister,
    # file 触发的守望形态：由计划任务到点调用，不在前台手工常驻
    [switch]$Watch,
    [switch]$DryRun,
    # 生产流程必须显式给出，与其它部署脚本的熔断口径一致
    [switch]$AllowProd
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
Import-Module (Join-Path $here 'TriggerRegistry.psm1') -Force

$result = [ordered]@{
    ok = $false; action = 'none'; kind = $null; flow = $null
    taskName = $null; specHash = $null; changed = $null; code = $null; error = $null
}
$exitCode = 0

# 输入类错误统一退出码 2：缺参数、文件不存在、声明非法、配置错误。
# file 分支的目录/配置/歧义/守望失败属于“运行期硬失败”，按 1 返回。
function Test-TriggerInputCode([string]$Code) {
    return ($Code -notin @('TRIGGER_NOT_REGISTERED', 'TRIGGER_DRIFT',
        'TRIGGER_REGISTER_FAILED', 'TRIGGER_UNREGISTER_FAILED',
        'TRIGGER_FILE_AMBIGUOUS', 'TRIGGER_FILE_DIR_UNREADABLE',
        'TRIGGER_STATE_DIR_UNWRITABLE', 'TRIGGER_CONFIG_UNRESOLVED',
        'TRIGGER_WATCH_RUN_FAILED'))
}

try {
    $actions = @()
    if ($Register) { $actions += 'register' }
    if ($Test) { $actions += 'test' }
    if ($Unregister) { $actions += 'unregister' }
    if ($Watch) { $actions += 'watch' }
    if ($actions.Count -ne 1) {
        $ex = New-Object System.Exception('必须且只能指定一个动作：-Register / -Test / -Unregister / -Watch')
        $ex.Data['code'] = 'TRIGGER_INPUT_ACTION'
        throw $ex
    }
    # 守望是实时轮询，没有“演练”形态；要演练请用 -Register -DryRun
    if ($Watch -and $DryRun) {
        $ex = New-Object System.Exception('-Watch 不能与 -DryRun 同时使用')
        $ex.Data['code'] = 'TRIGGER_INPUT_ACTION'
        throw $ex
    }
    if (-not $FlowFile) {
        $ex = New-Object System.Exception('未提供 -FlowFile')
        $ex.Data['code'] = 'TRIGGER_INPUT_MISSING'
        throw $ex
    }

    $action = $actions[0]
    $result.action = $action
    switch ($action) {
        'register' {
            $r = Register-Trigger -FlowFile $FlowFile -ConfigFile $ConfigFile `
                -RuntimeConfigPath $RuntimeConfigPath -DryRun:$DryRun -AllowProd:$AllowProd
        }
        'test' {
            $r = Test-Trigger -FlowFile $FlowFile -ConfigFile $ConfigFile -RuntimeConfigPath $RuntimeConfigPath
        }
        'unregister' {
            $r = Unregister-Trigger -FlowFile $FlowFile -ConfigFile $ConfigFile -DryRun:$DryRun
        }
        'watch' {
            # 同步守望：计划任务在 max_wait_sec 窗口内轮询，到点返回 timeout（退出码 0）
            $r = Invoke-TriggerWatch -FlowFile $FlowFile -ConfigFile $ConfigFile `
                -RuntimeConfigPath $RuntimeConfigPath -AllowProd:$AllowProd
        }
    }
    foreach ($k in @($r.Keys)) { $result[$k] = $r[$k] }
    $exitCode = $(if ($r.ok) { 0 } else { 1 })
    if (-not $r.ok) { Write-Host ("[trigger] {0} 未通过：{1} {2}" -f $action, $r.code, $r.message) }
    else { Write-Host ("[trigger] {0} 成功：{1} {2}" -f $action, $result.kind, $result.taskName) }
} catch {
    $code = 'TRIGGER_ERROR'
    if ($_.Exception.Data.Contains('code')) { $code = [string]$_.Exception.Data['code'] }
    $result.ok = $false
    $result.code = $code
    $result.error = $_.Exception.Message
    $exitCode = $(if (Test-TriggerInputCode $code) { 2 } else { 1 })
    Write-Host ("[trigger] 失败（{0}）：{1}" -f $code, $_.Exception.Message)
}

# 末行必须是结果 JSON，便于调用方逐行解析
Write-Output ('PAD_TRIGGER_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
exit $exitCode
