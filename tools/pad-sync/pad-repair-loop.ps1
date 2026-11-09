# pad-repair-loop.ps1 — automatic analyse-and-repair loop
#
# What it does: inject the .robin into the test flow → run it automatically → collect the failing actions →
# print repair guidance → wait for the agent to edit → inject again
#
# Safety boundaries (hard constraints):
#   1) By default only the PAD_SYNC_TEST test flow may be touched (-AllowProd exists purely as an emergency override)
#   2) May only read and write the %TEMP%\pad-repair-*.robin temporary files and the %RESULT_DIR%\*.txt logs
#   3) Retries at most -MaxRound times (default 3)
#   4) Any .robin produced by an external repair must still pass the basic static self-check

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$SourceRobin,
    [string]$FlowName = 'PAD_SYNC_TEST',
    [int]$MaxRound = 3,
    [int]$RunTimeoutSec = 120,
    [string]$ResultDir,
    [switch]$AllowProd,
    # During testing, click the designer's Run button directly instead of publishing to the cloud
    [switch]$LocalRun,
    # Single round: write the repair context to disk and exit immediately; run the next round manually after the agent edits
    [switch]$SingleRound,
    # Pluggable executor: call it automatically after a failure to repair the .robin, then go straight to the next round
    [string]$Executor,
    # Maximum seconds the executor may run
    [int]$ExecutorTimeoutSec = 600
)
$ErrorActionPreference = 'Stop'

if ($FlowName -ne 'PAD_SYNC_TEST' -and -not $AllowProd) {
    Write-Error 'safety fuse: only the PAD_SYNC_TEST flow may be touched by default. Add -AllowProd explicitly to operate on a production flow.'
}
# V-model red line: production flows may only be observed or repaired manually; automatic code edits are forbidden
if ($FlowName -ne 'PAD_SYNC_TEST' -and $Executor) {
    throw 'automatic repair is forbidden for production flows: use -SingleRound to observe, or edit the .robin manually'
}
if (-not (Test-Path $SourceRobin)) { Write-Error ".robin not found: $SourceRobin" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$padSync = Join-Path $here 'pad-sync.ps1'
# Log and VBS source encoding detection both go through the TextEncoding module
Import-Module (Join-Path $here 'TextEncoding.psm1') -Force
# Parsing the child process's final RESULT line is provided by PadTelemetry; this script carries no regex of its own
Import-Module (Join-Path $here 'PadTelemetry.psm1') -Force
if (-not (Test-Path $padSync)) { Write-Error "pad-sync.ps1 not found: $padSync" }

if (-not $ResultDir) { $ResultDir = Join-Path $env:TEMP "pad-repair-$(Get-Date -Format 'HHmmss')" }
New-Item -ItemType Directory -Force -Path $ResultDir | Out-Null

$rootResult = [ordered]@{
    ok = $false; rounds = @(); flow = $FlowName
    sourceRobin = $SourceRobin; finalRobinPath = $null
    lastError = $null; log = @()
}

function Log([string]$m) {
    $script:rootResult.log += $m
    Write-Host "[repair-loop] $m"
}

# Static self-check: non-empty and at least 2 lines
function Test-RobinSyntax([string]$path) {
    $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    if (-not $text.Trim()) { return $false, '.robin is empty' }
    if ($text.Contains([char]0)) { return $false, '.robin contains NUL characters' }
    $lines = ($text -split "`r?`n").Where({ $_.Trim() -ne '' })
    if ($lines.Count -lt 2) { return $false, '.robin has too few actions (at least 2 lines required)' }
    return $true, $null
}

# Read a log with the encoding detected from the BOM (VBS OpenTextFile with the 3rd argument True writes UTF-16LE, PowerShell usually writes UTF-8/GBK)
function Read-LogAuto([string]$path, [int]$maxChars = 4000) {
    # Encoding detection and decoding are delegated to the TextEncoding module (Pester covers the UTF-16LE / UTF-8-BOM / ANSI cases)
    $text = (Read-TextFileAuto $path).text
    # The log may be large, keep only the tail (error messages are usually at the end)
    if ($text.Length -gt $maxChars) { $text = '...(truncated)...' + $text.Substring($text.Length - $maxChars) }
    return $text
}

# Read the logging convention from the VBS source instead of guessing "scriptname_result.txt":
#   1) Find Const RESULT_DIR = "..." to get the log directory
#   2) Find every hard-coded .txt/.log file name in the source (posting script → posting_result.txt; export script → saveas_result.txt/saveas_stop.txt/export_excel.log)
#   3) Keep only the ones that really exist on disk, preferring names containing result, then the newest modification time
function Get-VbsLogFile([string]$vbsPath) {
    $src = (Read-TextFileAuto $vbsPath).text

    # Candidate directories: the RESULT_DIR constant + full-path literals in the source + the script's own directory
    $dirs = @()
    if ($src -match 'Const\s+RESULT_DIR\s*=\s*"([^"\r\n]+)"') { $dirs += $Matches[1] }
    foreach ($m in [regex]::Matches($src, '"([A-Za-z]:\\[^"\r\n]+\\[^"\\]+)"')) {
        $d = Split-Path $m.Groups[1].Value -Parent
        if ($d) { $dirs += $d }
    }
    $dirs += (Split-Path $vbsPath -Parent)
    $dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)

    # Log file names appearing in the source (they may carry a backslash prefix or a full path, e.g. "\posting_result.txt", "%RESULT_DIR%\saveas_result.txt")
    $names = @([regex]::Matches($src, '"([^"\r\n]*?([A-Za-z0-9_\-\.]+\.(?:txt|log)))"') | ForEach-Object {
        [pscustomobject]@{ Full = $_.Groups[1].Value; Name = $_.Groups[2].Value }
    })
    if (-not $names) { return $null }

    $files = @()
    foreach ($n in $names) {
        if ($n.Full -match '^[A-Za-z]:\\') {
            # The source spells out a full path; validate it directly
            if (Test-Path $n.Full) { $files += (Get-Item $n.Full) }
            continue
        }
        foreach ($d in $dirs) {
            $p = Join-Path $d $n.Name
            if (Test-Path $p) { $files += (Get-Item $p) }
        }
    }
    if (-not $files) { return $null }

    # Sort: result-like names first, then the newest modification time
    return ($files | Sort-Object @{ Expression = { if ($_.Name -match 'result') { 0 } else { 1 } } },
        @{ Expression = { $_.LastWriteTime }; Descending = $true })[0]
}

# Log hook for a failed RunDOSCommand: parse the VBS/Python script path from the command line and read the external log
# Project script convention (agent-generated scripts must follow it):
#   VBS    → non-zero exit code; the log file is decided by the hard-coded .txt/.log name in the VBS source (the hook extracts it)
#   Python → non-zero exit code; RECONCILE_RESULT=ERROR at the end of stdout
function Get-RunDosExtraLog($failedAction) {
    $extra = [ordered]@{ scriptPath = $null; vbsLogPath = $null; vbsLog = $null; pythonStdout = $null; hookNote = $null }
    $actionName = $failedAction.action
    $sysName = $failedAction.systemActionName
    if (-not ($sysName -match 'RunDOSCommand' -or $actionName -match 'RunDOS')) {
        $extra.hookNote = 'not a RunDOSCommand action; hook skipped'; return $extra
    }
    $cmdLine = $failedAction.inputs.DOSCommandOrApplication
    if (-not $cmdLine) { $extra.hookNote = 'inputs has no DOSCommandOrApplication'; return $extra }
    # Extract the script path with regexes: .vbs first, then .py; single-quoted patterns avoid double-quote escaping
    $scriptPath = $null
    if ($cmdLine -match '"([^"]+\.vbs)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match 'cscript[^"]*"([^"]+\.vbs)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match 'python[^"]*"([^"]+\.py)"') { $scriptPath = $Matches[1] }
    elseif ($cmdLine -match '"([^"]+\.py)"') { $scriptPath = $Matches[1] }
    $extra.scriptPath = $scriptPath
    if (-not $scriptPath) { $extra.hookNote = 'cannot resolve the script path'; return $extra }
    if ($scriptPath -match '\.vbs$') {
        # No longer guess "scriptname_result.txt"; extract the real log file name and directory from the VBS source
        $logFile = Get-VbsLogFile $scriptPath
        if ($logFile) {
            $extra.vbsLogPath = $logFile.FullName
            $extra.vbsLog = Read-LogAuto $logFile.FullName
            $extra.hookNote = "VBS log read: $($logFile.FullName) ($($logFile.Length) bytes, modified at $($logFile.LastWriteTime.ToString('HH:mm:ss'))"
        } else {
            $extra.hookNote = "none of the log files declared by the VBS source exists on disk: $scriptPath"
        }
    } elseif ($scriptPath -match '\.py$') {
        $out = $failedAction.inputs.standardOutput
        if (-not $out) { $out = $failedAction.inputs.standardError }
        if ($out) { $extra.pythonStdout = $out; $extra.hookNote = 'Python stdout read' }
        else { $extra.hookNote = 'Python action but no standardOutput/standardError' }
    }
    return $extra
}

function Invoke-RunCycle([string]$robinPath, [int]$round) {
    Log "--- round ${round}: inject + run ---"
    $tmpOut = Join-Path $ResultDir "pad-sync-out_$round.log"
    $syncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $padSync,
        '-FlowName', $FlowName, '-RobinFile', $robinPath, '-Replace',
        '-RunTimeoutSec', $RunTimeoutSec)
    if ($LocalRun) { $syncArgs += '-LocalRun' }
    & powershell @syncArgs > $tmpOut 2>&1
    $lines = @(Get-Content $tmpOut)
    if ($lines.Count -gt 0) { Log "pad-sync last line: $($lines[$lines.Count - 1])" }
    return (Read-ChildResult -Name 'SYNC' -Lines $lines -Logger { param($m) Log $m })
}

try {
    $currentRobin = Join-Path $ResultDir 'current.robin'
    Copy-Item $SourceRobin $currentRobin -Force
    for ($round = 1; $round -le $MaxRound; $round++) {
        $ok, $msg = Test-RobinSyntax $currentRobin
        if (-not $ok) { throw "round ${round}: .robin static self-check failed: $msg" }
        $res = Invoke-RunCycle $currentRobin $round
        if (-not $res) { throw "round ${round}: pad-sync returned no valid result" }
        # A designer-local run returns the action-level exception array failedActions (no singular failedAction);
        # take the first exception and add the systemActionName field the hook needs
        $fa = $res.failedAction
        if (-not $fa -and $res.failedActions -and @($res.failedActions).Count -gt 0) {
            $fa = @($res.failedActions)[0]
            if (-not $fa.PSObject.Properties['systemActionName']) {
                $fa | Add-Member -NotePropertyName systemActionName -NotePropertyValue $fa.action -Force
            }
        }
        $roundRec = [ordered]@{
            round = $round; status = $res.status; ok = $res.ok
            actions = $res.actions; failedAction = $fa
            failedActions = $res.failedActions
            timedActions = $res.timedActions; totalMs = $res.totalMs
            error = $res.error; logPath = $res.logPath
        }
        $rootResult.rounds += $roundRec
        if ($res.ok) {
            Log "✅ round $round passed! status=$($res.status)"
            if ($res.failedActions -and @($res.failedActions).Count -gt 0) {
                $names = @($res.failedActions | ForEach-Object { "$($_.module).$($_.action)" }) -join ', '
                Log "⚠️ this round has caught action exceptions (they do not affect the final result): $names"
            }
            $rootResult.ok = $true; break
        }
        $f = $fa
        if (-not $f) { Log 'failed without a Failed action; stopping'; break }
        Log "round $round failed: action=$($f.name) error.code=$($f.error.code)"
        $ctxPath = Join-Path $ResultDir "repair_ctx_$round.json"
        $nextPath = Join-Path $ResultDir "round_$($round+1).robin"
        [ordered]@{
            round = $round
            failedAction = $f
            error = $res.error
            actions = $res.actions
            logPath = $res.logPath
            currentRobinPath = $currentRobin
            nextRobinPath = $nextPath
            extraLogs = (Get-RunDosExtraLog $f)
        } | ConvertTo-Json -Depth 10 | Out-File $ctxPath -Encoding UTF8
        Log "repair context written: $ctxPath"
        Log "repair guidance: read $ctxPath -> edit current.robin -> write to $nextPath"
        # Pluggable executor: hand the context to an external program; the repaired .robin goes straight into the next round
        if ($Executor) {
            if (-not (Test-Path $Executor)) { throw "executor not found: $Executor" }
            Log "calling executor: $Executor"
            $execLog = Join-Path $ResultDir "executor_$round.log"
            $execSw = [Diagnostics.Stopwatch]::StartNew()
            & powershell -NoProfile -ExecutionPolicy Bypass -File $Executor -ContextFile $ctxPath -InputRobin $currentRobin -OutputRobin $nextPath *> $execLog
            $execCode = $LASTEXITCODE
            $execSw.Stop()
            Log "executor exit code=$execCode, took $([int]$execSw.Elapsed.TotalSeconds) second(s) (log $execLog)"
            if ($execCode -ne 0) {
                Log 'executor gave up repairing; stopping the loop'
                $rootResult.executorAborted = $true
                break
            }
            if (-not (Test-Path $nextPath)) {
                Log "executor produced no $nextPath; stopping the loop"
                $rootResult.executorAborted = $true
                break
            }
            $okFix, $msgFix = Test-RobinSyntax $nextPath
            if (-not $okFix) { Log "executor output failed the self-check: $msgFix"; break }
            $currentRobin = $nextPath
            continue
        }
        if ($SingleRound) {
            Log 'single-round mode: repair context is ready; run the next round after the agent edits current.robin'
            $rootResult.nextRobinPath = $nextPath
            break
        }
        if ($round -eq $MaxRound) { Log "reached the maximum number of rounds $MaxRound; stopping"; break }
        Copy-Item $currentRobin $nextPath -Force
        $currentRobin = $nextPath
    }
    $rootResult.finalRobinPath = $currentRobin
}
catch {
    $rootResult.lastError = $_.Exception.Message
    Log "loop failed: $($_.Exception.Message)"
}
finally {
    Write-Output ('PAD_REPAIR_LOOP_RESULT=' + ($rootResult | ConvertTo-Json -Depth 10 -Compress))
}
