# pad-trigger.ps1 —— command-line shell for the trigger registrar
#
# Usage:
#   .\pad-trigger.ps1 -FlowFile business\flows\<flow name>.json -Register -DryRun
#   .\pad-trigger.ps1 -FlowFile ... -Register -AllowProd
#   .\pad-trigger.ps1 -FlowFile ... -Test
#   .\pad-trigger.ps1 -FlowFile ... -Unregister [-DryRun]
#   .\pad-trigger.ps1 -FlowFile ... -ConfigFile ... -Watch [-AllowProd]
#
# The last line always prints PAD_TRIGGER_RESULT=<JSON>; exit code 0 success / 1 registration, validation or watch failure / 2 input error.
# -Test and -Register -DryRun are read-only throughout: they do not write to the system, create directories or trigger a run.
# -Watch is the watch entry point the scheduled task actually calls: it polls every poll_sec and exits 0 silently when max_wait_sec is reached.

[CmdletBinding()]
param(
    [string]$FlowFile,
    [string]$ConfigFile,
    [string]$RuntimeConfigPath,
    [switch]$Register,
    [switch]$Test,
    [switch]$Unregister,
    # Watch form of a file trigger: called by the scheduled task on time; it is not kept running manually in the foreground
    [switch]$Watch,
    [switch]$DryRun,
    # Must be given explicitly for a production flow, matching the safety-fuse policy of the other deployment scripts
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

# Input-type errors all use exit code 2: a missing parameter, a missing file, an illegal declaration, a bad config.
# Directory/config/ambiguity/watch failures on the file branch are "runtime hard failures" and return 1.
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
        $ex = New-Object System.Exception('specify exactly one action: -Register / -Test / -Unregister / -Watch')
        $ex.Data['code'] = 'TRIGGER_INPUT_ACTION'
        throw $ex
    }
    # Watch is live polling and has no "dry run" form; use -Register -DryRun to rehearse
    if ($Watch -and $DryRun) {
        $ex = New-Object System.Exception('-Watch cannot be combined with -DryRun')
        $ex.Data['code'] = 'TRIGGER_INPUT_ACTION'
        throw $ex
    }
    if (-not $FlowFile) {
        $ex = New-Object System.Exception('missing -FlowFile')
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
            # Synchronous watch: the scheduled task polls within the max_wait_sec window and returns timeout (exit code 0) on expiry
            $r = Invoke-TriggerWatch -FlowFile $FlowFile -ConfigFile $ConfigFile `
                -RuntimeConfigPath $RuntimeConfigPath -AllowProd:$AllowProd
        }
    }
    foreach ($k in @($r.Keys)) { $result[$k] = $r[$k] }
    $exitCode = $(if ($r.ok) { 0 } else { 1 })
    if (-not $r.ok) { Write-Host ("[trigger] {0} failed: {1} {2}" -f $action, $r.code, $r.message) }
    else { Write-Host ("[trigger] {0} succeeded: {1} {2}" -f $action, $result.kind, $result.taskName) }
} catch {
    $code = 'TRIGGER_ERROR'
    if ($_.Exception.Data.Contains('code')) { $code = [string]$_.Exception.Data['code'] }
    $result.ok = $false
    $result.code = $code
    $result.error = $_.Exception.Message
    $exitCode = $(if (Test-TriggerInputCode $code) { 2 } else { 1 })
    Write-Host ("[trigger] failed ({0}): {1}" -f $code, $_.Exception.Message)
}

# The last line must be the result JSON so callers can parse line by line
Write-Output ('PAD_TRIGGER_RESULT=' + ($result | ConvertTo-Json -Depth 8 -Compress))
exit $exitCode
