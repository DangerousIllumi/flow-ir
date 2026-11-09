# PadDesigner.psm1 — PAD designer UI automation (window lookup / action list / clearing / injection / run / status bar / canvas read-back)
#
# This is the only implementation of designer interaction; pad-sync.ps1 keeps orchestration only (inject → publish → run → collect).
#
# Hard constraints:
#   1) No coordinate clicks: always use UIAutomation patterns (InvokePattern / SetFocus)
#   2) When the window was dragged off-screen or minimized, repair its position first; otherwise Ctrl+A / Ctrl+V all miss
#   3) -VerifyCanvas: after pasting, copy the canvas content back, normalize it and compare it line by line
#      with the source .robin; when "only part of it was pasted", abort at the first difference and do not publish/run

Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

# The Win32 declarations are registered only once: on a repeated import (-Force) Add-Type fails on the duplicate type name
if (-not ('PadNative' -as [type])) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class PadNative {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
    public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr h, EnumWindowsProc f, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public struct RECT { public int L, T, R, B; }
}
"@
}

# Designer log: the console prints info only, debug-level entries go to the file only (for reviewing "scanned but skipped")
# By default the file is %LOCALAPPDATA%\flow-ir\pad-designer.log and can be overridden with the FLOW_IR_PAD_DESIGNER_LOG environment variable
$script:PadDesignerLogFile = if ($env:FLOW_IR_PAD_DESIGNER_LOG) { $env:FLOW_IR_PAD_DESIGNER_LOG } else {
    Join-Path (Join-Path $env:LOCALAPPDATA 'flow-ir') 'pad-designer.log'
}

function Write-PadDesignerLog([string]$msg, [string]$Level = 'info') {
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('o'), $Level, $msg
    if ($Level -eq 'info') { Write-Host "[pad-designer] $msg" }
    try {
        $dir = Split-Path -Parent $script:PadDesignerLogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [IO.File]::AppendAllText($script:PadDesignerLogFile, $line + "`r`n",
            (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Get-UiRoot { [System.Windows.Automation.AutomationElement]::RootElement }

# ── Window lookup ──────────────────────────────────────────────
# Designer main window: process name PAD.Designer with a title containing the flow name
function Get-DesignerWindow {
    param(
        [Parameter(Mandatory = $true)][string]$FlowName,
        [string]$ProcessName = 'PAD.Designer'
    )
    $root = Get-UiRoot
    foreach ($p in (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)) {
        $c = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
        $w = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $c)
        if ($w -and $w.Current.Name -like "*$FlowName*") { return $w }
    }
    return $null
}

# ── Element lookup ────────────────────────────────────────────
function Get-PadElementById($Window, [string]$AutoId) {
    $c = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutoId)
    return $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

# The AutomationId of the toolbar buttons (save draft / publish) is measured to be the generic value 'Button';
# only the name is stable, so lookup by Name
function Get-PadElementByName($Window, [string]$Name) {
    $c = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    return $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

function Get-PadElementByClass($Window, [string]$ClassName) {
    $c = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, $ClassName)
    return $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

# Click the center of an element (a fallback only for when InvokePattern is unavailable).
# Prefer GetClickablePoint (the UIA recommendation); on failure fall back to the BoundingRectangle center
function Invoke-UiClick($Element) {
    if (-not $Element) { return $false }
    # Prefer InvokePattern: on PAD designer buttons the BoundingRectangle can be measured off-screen
    # (e.g. -31707,-31960), where a coordinate click is guaranteed to miss
    try {
        $pat = $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        $pat.Invoke()
        return $true
    } catch { }
    $x = $null; $y = $null
    try {
        $pt = $Element.GetClickablePoint()
        $x = [int]$pt.X; $y = [int]$pt.Y
    } catch {
        $rc = $Element.Current.BoundingRectangle
        $x = [int]($rc.X + $rc.Width / 2)
        $y = [int]($rc.Y + $rc.Height / 2)
    }
    if ($null -eq $x) { return $false }
    [void][PadNative]::SetCursorPos($x, $y)
    [PadNative]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [PadNative]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
    return $true
}

# Reclaim the foreground: the Windows foreground lock makes a single call fail silently, so stack four layers
#   1) AppActivate  2) Temporary HWND_TOPMOST (the most reliable way past the foreground lock)  3) Alt key unstick  4) Poll and retry
function Set-PadForeground([IntPtr]$Hwnd) {
    $SWP_NOSIZE = 0x0001; $SWP_NOMOVE = 0x0002
    $HWND_TOPMOST = [IntPtr](-1); $HWND_NOTOPMOST = [IntPtr](-2)
    try { [Microsoft.VisualBasic.Interaction]::AppActivate([int]$Hwnd) } catch { }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 6) {
        if ([PadNative]::GetForegroundWindow() -eq $Hwnd) { return $true }
        [void][PadNative]::ShowWindow($Hwnd, 9)   # SW_RESTORE
        [void][PadNative]::SetWindowPos($Hwnd, $HWND_TOPMOST, 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE))
        [void][PadNative]::SetForegroundWindow($Hwnd)
        [void][PadNative]::SetWindowPos($Hwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, ($SWP_NOSIZE -bor $SWP_NOMOVE))
        try { [System.Windows.Forms.SendKeys]::SendWait('%') } catch { }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

# Whether the window is outside the visible area (a pure function shared by the repair logic and unit tests)
# When minimized Windows reports the coordinates as -32000, which is also treated as "outside"
function Test-WindowOutside {
    param(
        [int]$Left, [int]$Top, [int]$Right, [int]$Bottom,
        [int]$ScreenWidth, [int]$ScreenHeight,
        [switch]$Minimized
    )
    if ($Minimized) { return $true }
    return (($Right -gt $ScreenWidth) -or ($Left -lt 0) -or ($Top -lt 0))
}

# The designer window can be dragged off-screen (measured L=878 R=2078, beyond a 1920 screen width);
# any coordinate click then lands on another window, so it must be moved back on-screen first
function Repair-DesignerBounds($Window) {
    $hwnd = [IntPtr]$Window.Current.NativeWindowHandle
    # SetWindowPos has no effect while minimized, so SW_RESTORE first;
    # otherwise the following Ctrl+A / Ctrl+V all miss (measured clearing 14 → 14)
    if ([PadNative]::IsIconic($hwnd)) {
        Write-PadDesignerLog 'designer window is minimized; restoring it first'
        [void][PadNative]::ShowWindow($hwnd, 9)
        Start-Sleep -Milliseconds 900
    }
    $r = New-Object PadNative+RECT
    [void][PadNative]::GetWindowRect($hwnd, [ref]$r)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $outside = Test-WindowOutside -Left $r.L -Top $r.T -Right $r.R -Bottom $r.B `
        -ScreenWidth $screen.Width -ScreenHeight $screen.Height -Minimized:([PadNative]::IsIconic($hwnd))
    if ($outside) {
        Write-PadDesignerLog "designer window is outside the visible area (L=$($r.L) T=$($r.T) R=$($r.R) B=$($r.B)); moving it back to (40,40)"
        [void][PadNative]::ShowWindow($hwnd, 9)
        [void][PadNative]::SetWindowPos($hwnd, [IntPtr]0, 40, 40, 1200, 900, 0x0040)
        Start-Sleep -Milliseconds 900
    }
    return $hwnd
}

# A single accidental touch of the recorder dims the whole designer and makes it uneditable; press Esc to exit and verify
function Exit-Recorder($Window) {
    $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $recording = $false
    foreach ($e in $all) {
        if ($e.Current.Name -match '尚未记录|选择记录以开始') { $recording = $true; break }
    }
    if (-not $recording) { return $true }
    Write-PadDesignerLog 'UI recorder is open; trying Esc to close it'
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Seconds 1
    $all2 = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all2) {
        if ($e.Current.Name -match '尚未记录|选择记录以开始') { return $false }
    }
    return $true
}

# ── Action list ───────────────────────────────────────────────
function Get-ActionItems($Window) {
    $fv = Get-PadElementByClass $Window 'FunctionView'
    if (-not $fv) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    return @($fv.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
}

# Send keyboard focus into the action list (a prerequisite for Ctrl+V / Ctrl+A to take effect)
# No more coordinate clicks: coordinates easily land on other toolbar buttons (measured accidentally hitting "subflow")
function Focus-ActionList($Window) {
    $items = Get-ActionItems $Window
    if ($items.Count -eq 0) {
        # An empty canvas has no focusable element; focus is on the canvas by default, so return directly
        return $false
    }
    try {
        # Must use the element just queried: once the list is virtualized the old handle becomes invalid
        $items[0].SetFocus()
        Start-Sleep -Milliseconds 300
        return $true
    } catch {
        Write-PadDesignerLog "failed to focus the action list: $($_.Exception.Message)"
        return $false
    }
}

# Clear the canvas: loop Ctrl+A + Delete until the action list is empty
# Why the loop: FunctionView is a virtualized list and FindAll only sees "rendered" actions,
#   so a check like "selected == total" necessarily misjudges (measured: 15 actions but only 14 rendered);
#   instead "delete, then query, run another delete round if any remain", trusting the real remaining count
#   after deletion
function Clear-ActionList($Window) {
    for ($round = 1; $round -le 5; $round++) {
        $items = Get-ActionItems $Window
        if ($items.Count -eq 0) { return 0 }
        [void](Focus-ActionList $Window)
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.SendKeys]::SendWait('{DEL}')
        Start-Sleep -Milliseconds 1500
        $left = (Get-ActionItems $Window).Count
        Write-PadDesignerLog "clear canvas round ${round}: $left action(s) left after deleting"
        if ($left -eq 0) { return 0 }
    }
    throw 'failed to clear the canvas: actions remain after 5 rounds of Ctrl+A + Delete'
}

# Canvas read-back: Ctrl+A + Ctrl+C copies the current actions as robin text
# Returning null means the clipboard stayed empty (usually missing focus, or the canvas is not selectable)
function Get-CanvasText($Window) {
    [void](Focus-ActionList $Window)
    try { [System.Windows.Forms.Clipboard]::Clear() } catch { }
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    Start-Sleep -Milliseconds 300
    [System.Windows.Forms.SendKeys]::SendWait('^c')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 6) {
        Start-Sleep -Milliseconds 300
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) { return [System.Windows.Forms.Clipboard]::GetText() }
        } catch { }
    }
    return $null
}

# Line-by-line comparison of the canvas content with the source .robin (after normalization), locating the first difference
function Test-CanvasMatch {
    param([string]$CanvasText, [string]$SourceText)
    return (Compare-RobinText $SourceText $CanvasText)
}

# Find the element that can really be invoked: PAD's PublishFlowButton is a Custom container
# that does not support InvokePattern itself, so descend into its inner Button child
function Get-InvokableElement($Element) {
    if (-not $Element) { return $null }
    try {
        [void]$Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        return $Element
    } catch { }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    return $Element.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}

# Click a toolbar button. Whether the button is greyed out depends on the PAD version and can no longer be a success criterion
function Click-ToolButton($Window, [string]$AutoId) {
    $btn = Get-PadElementById $Window $AutoId
    if (-not $btn) { throw "button not found: $AutoId" }
    $btn = Get-InvokableElement $btn
    if (-not $btn) { throw "button $AutoId has no invokable Button inside" }
    if (-not $btn.Current.IsEnabled) { throw "button $AutoId is not enabled" }
    return (Invoke-UiClick $btn)
}

# ── Status bar ────────────────────────────────────────────────
# The save/publish progress element of the status bar; returns its text (null when the element is absent)
function Get-StatusBarText($Window) {
    $el = Get-PadElementById $Window 'Flow_status_saving_process'
    if ($el) { return $el.Current.Name }
    return $null
}

# Wait for publishing to finish: poll the status bar
# Publishing counts as confirmed only when "publishing" was seen first and then disappeared
function Wait-PublishDone($Window, [int]$TimeoutSec = 240) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sawPublishing = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $text = Get-StatusBarText $Window
        if ($text -and $text -match '正在发布|正在保存') {
            $sawPublishing = $true
        } elseif ($sawPublishing) {
            return $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ── Injection: paste the .robin into the canvas ─────────────────
# Returns { actions / verified / diff }; verified is $true only with -VerifyCanvas
function Invoke-PadInject {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$Replace,
        [switch]$VerifyCanvas
    )
    $hwnd = Repair-DesignerBounds $Window
    if (-not (Set-PadForeground $hwnd)) { throw 'cannot bring the PAD designer to the foreground; Ctrl+A / Ctrl+V would do nothing' }
    # Retract any leftover dropdown/overlay first, otherwise the first click lands on the overlay instead of the canvas
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 400
    if (-not (Exit-Recorder $Window)) { throw 'cannot close the UI recorder; the designer is not editable' }

    $before = (Get-ActionItems $Window).Count
    [void](Focus-ActionList $Window)
    [void](Set-PadForeground $hwnd)

    if ($Replace -and $before -gt 0) {
        [void](Set-PadForeground $hwnd)
        $afterClear = Clear-ActionList $Window
        Write-PadDesignerLog "clear canvas: $before -> $afterClear"
        # Failing to clear must not continue appending, otherwise old actions pile up under the new ones
        if ($afterClear -gt 0) { throw "failed to clear the canvas ($afterClear action(s) remain)" }
        [void](Focus-ActionList $Window)
        [void](Set-PadForeground $hwnd)
    }

    # Baseline action count before pasting (0 after a successful clear)
    $baseCount = (Get-ActionItems $Window).Count
    Set-Clipboard -Value $Text
    [void](Set-PadForeground $hwnd)
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    # Wait for new actions to appear on the canvas
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 500
        if ((Get-ActionItems $Window).Count -gt $baseCount) { break }
    }
    $final = (Get-ActionItems $Window).Count
    if ($final -le $baseCount) { throw "canvas action count did not increase after paste (still $final)" }
    Write-PadDesignerLog "injection done: action count $baseCount -> $final"

    # Canvas read-back check: a paste may go in only partially (long text / lost focus), so it must be compared line by line with the source
    $verified = $false
    $cmp = $null
    if ($VerifyCanvas) {
        $canvas = Get-CanvasText $Window
        if (-not $canvas) { throw 'canvas read-back failed: the clipboard is empty after copying (missing focus, or the canvas is not selectable)' }
        $cmp = Test-CanvasMatch -CanvasText $canvas -SourceText $Text
        if (-not $cmp.match) {
            throw ("canvas content differs from the source .robin (the paste may be partial): line {0}`n  source: {1}`n  canvas: {2}" -f $cmp.diffIndex, $cmp.lineA, $cmp.lineB)
        }
        $verified = $true
        Write-PadDesignerLog 'canvas read-back check passed: the pasted content matches the source .robin line by line'
    }
    return [ordered]@{ actions = $final; verified = $verified; diff = $cmp }
}

# ── Run: trigger + decide start and finish by "run log on disk" ────────────────
# The old implementation judged whether this run had finished by "is the PAD.RobotV2 process still present". On one machine,
# as soon as someone runs another flow at the same time (e.g. manually in the designer), that process is mistaken for this
# run's robot: it exits and the run is judged finished early, and the later log collection naturally cannot find this run's
# directory.
# It now works like this:
#   1) Record a baseline before triggering: existing run directories / robot processes / telemetry logs do not belong to this run
#   2) After triggering accept only run directories (URL trigger) or telemetry logs (designer local run) that newly appear beyond the baseline
#   3) Completion is decided by the terminal status in the log, not by the process table
#   4) Click message boxes only for robot processes started after the trigger, to avoid someone else's popup for that round
# Returns [ordered]@{ robotId; evidence; runDir; logPath; status } for the orchestration layer to collect results

# List all run directories under Console\Scripts\<flowGuid>\Runs
function Get-PadRunDirs {
    param([string]$ScriptsRoot)
    $dirs = @()
    if (-not $ScriptsRoot -or -not (Test-Path $ScriptsRoot)) { return $dirs }
    foreach ($flowDir in (Get-ChildItem $ScriptsRoot -Directory -ErrorAction SilentlyContinue)) {
        $runs = Join-Path $flowDir.FullName 'Runs'
        if (Test-Path $runs) { $dirs += @(Get-ChildItem $runs -Directory -ErrorAction SilentlyContinue) }
    }
    return $dirs
}

# Locate the run directory precisely by the runId of this trigger; return $null when not found
# Never degrade to "take the newest directory after the trigger": with concurrency on the same machine that picks someone else's run directory.
# Get-PadRunDirs is reused here so the locating criteria stay exactly the same as in the wait phase (one implementation only).
function Resolve-PadRunDir {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptsRoot,
        [string]$RunId
    )
    if (-not $RunId) { return $null }
    return (@(Get-PadRunDirs -ScriptsRoot $ScriptsRoot |
        Where-Object { $_.Name -eq $RunId }) | Select-Object -First 1)
}

# Read text in shared mode: PAD holds a write handle on the log for the whole run,
# so ReadAllText / ReadAllLines directly would throw "the file is being used by another process".
# Opening with FileShare.ReadWrite lets us read the current content without stopping PAD from writing.
function Read-TextShared {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

# Read the summary line at the end of Actions.log and return the terminal status (Succeeded / Failed / Cancelled)
# Every per-action line carries an index; only the summary line of the whole run has none, which distinguishes it
function Get-RunLogStatus {
    param([string]$LogPath)
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $null }
    try { $lines = (Read-TextShared $LogPath) -split "`r?`n" } catch { return $null }
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if (-not $lines[$i].Trim()) { continue }
        try { $j = $lines[$i] | ConvertFrom-Json } catch { continue }
        if ($null -eq $j.index -and $j.status) { return [string]$j.status }
    }
    return $null
}

# External trigger confirmation dialog decision (a pure function to ease unit testing)
#
# Real-machine probe findings (2026-11-04, read-only probe, log %TEMP%\pad-dialog-probe.log):
#   The confirmation dialog popped after triggering a URI belongs to PAD.Console.Host; its top-level window title is exactly "Power Automate"
#   (class=WinAutomationWindow) and the confirm button AutomationId is OKRunFlowFromProtocolHandlerButton.
#   During the same period PAD.RobotV2 showed no confirmation dialog.
#
# Acceptance therefore requires all of: source process + title allowlist + button AutomationId (+ control type).
# Never decide by button text (OK/Yes) - business dialogs (completion prompts, manual confirmations) carry those buttons too.
function Test-ExternalTriggerDialog {
    param(
        [string]$ProcessName,
        [string]$WindowTitle,
        [string]$ButtonAutomationId,
        [string]$ButtonControlType = 'Button'
    )
    $titleWhitelist = @('Power Automate')
    if ($ProcessName -ne 'PAD.Console.Host') { return $false }
    if ($titleWhitelist -notcontains $WindowTitle) { return $false }
    if ($ButtonAutomationId -ne 'OKRunFlowFromProtocolHandlerButton') { return $false }
    if ($ButtonControlType -ne 'Button') { return $false }
    return $true
}

# List the top-level windows currently visible for a given PAD.RobotV2 process (titles only, no clicks)
# Purpose: in a non-interactive run decide whether the flow is stuck at a manual-confirmation dialog; interactive runs only log at debug level
function Get-PadRobotDialogs {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $script:robotDialogPid = $ProcessId
    $script:robotDialogList = New-Object System.Collections.ArrayList
    $cb = [PadNative+EnumWindowsProc]{
        param($h, $l)
        $pid2 = 0
        [void][PadNative]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($pid2 -eq $script:robotDialogPid -and [PadNative]::IsWindowVisible($h)) {
            $t = New-Object System.Text.StringBuilder 512
            [void][PadNative]::GetWindowText($h, $t, 512)
            $title = $t.ToString()
            if ($title) {
                $cn = New-Object System.Text.StringBuilder 128
                [void][PadNative]::GetClassName($h, $cn, 128)
                # Whether it contains native buttons: only a window with buttons can be a dialog that needs a human click
                $script:robotHasButton = $false
                $cb2 = [PadNative+EnumWindowsProc]{
                    param($h2, $l2)
                    $cn2 = New-Object System.Text.StringBuilder 128
                    [void][PadNative]::GetClassName($h2, $cn2, 128)
                    if ($cn2.ToString() -match 'BUTTON') { $script:robotHasButton = $true }
                    return $true
                }
                [void][PadNative]::EnumChildWindows($h, $cb2, [IntPtr]::Zero)
                [void]$script:robotDialogList.Add([pscustomobject]@{
                    Handle = [IntPtr]$h; Title = $title; ClassName = $cn.ToString()
                    HasButton = $script:robotHasButton
                })
            }
        }
        return $true
    }
    [void][PadNative]::EnumWindows($cb, [IntPtr]::Zero)
    return @($script:robotDialogList)
}

# Pre-trigger validation: resolve the flow name into the local PAD flowId / environmentId
#
# PAD's URL trigger carries only workflowName; the environment and flow IDs are resolved internally by Console.
# When the name does not match, Console pops an error such as "environment with the specified ID not found",
# and if the outer layer treats that as a finished run, it misjudges the run as complete.
# Historical RunDefinition.json files under Console\Scripts (workflow.name ↔ workflowId,
# environmentId) are parsed read-only here: if nothing resolves, the trigger is refused instead of leaving the error to a PAD popup.
function Resolve-PadFlowIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowName,
        [string]$ScriptsRoot
    )
    if (-not $ScriptsRoot) {
        $ScriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    }
    if (-not (Test-Path -LiteralPath $ScriptsRoot)) { return $null }

    $pattern = Join-Path $ScriptsRoot '*\Runs\*\RunDefinition.json'
    $best = $null
    foreach ($f in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
        $j = $null
        try { $j = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $j.workflow -or [string]$j.workflow.name -ne $WorkflowName) { continue }
        $start = [datetime]::MinValue
        [void][datetime]::TryParse([string]$j.startTime, [ref]$start)
        if (-not $best -or $start -gt $best.StartTime) {
            $best = [pscustomobject]@{
                FlowName      = $WorkflowName
                FlowId        = [string]$j.workflow.workflowId
                EnvironmentId = [string]$j.environmentId
                RunId         = [string]$j.diagnosticInfo.runId
                StartTime     = $start
            }
        }
    }
    if (-not $best -or -not $best.FlowId) { return $null }
    # The flow directory must really exist, otherwise Console refuses as well
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptsRoot $best.FlowId))) { return $null }
    return $best
}

function Invoke-PadRun {
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowName,
        [string]$RunId,
        [int]$TimeoutSec = 300,
        # How long after the trigger we may still see no log of this run before judging "it never started" (e.g. the user clicked cancel in the console)
        [int]$StartupTimeoutSec = 180,
        # Non-interactive (scheduled task): on a stable manual-confirmation dialog, hand control back to the outer layer instead of clicking
        [switch]$NonInteractive,
        # How many seconds a manual-confirmation dialog must stay present to count (filters transient error boxes)
        [int]$HumanConfirmGraceSec = 20,
        [switch]$Local
    )
    $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    $dcDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'

    # Baseline: robot processes / telemetry logs that existed before the trigger do not count as this run
    # (URL triggers take no directory baseline: this run is identified only by its own runId, see the evidence lookup below)
    $beforePids = @{}
    foreach ($p in (Get-Process -Name 'PAD.RobotV2' -ErrorAction SilentlyContinue)) { $beforePids[$p.Id] = $true }
    $beforeLogs = @{}
    if (Test-Path $dcDir) {
        foreach ($f in (Get-ChildItem $dcDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) { $beforeLogs[$f.Name] = $true }
    }

    if ($Local) {
        # At the test stage click the designer's "Run" button to execute the current canvas instead of publishing to the cloud:
        # this skips the cloud publish wait and never runs into version conflicts
        $win = Get-DesignerWindow -FlowName $WorkflowName
        if (-not $win) { throw "designer window not found: $WorkflowName" }
        $hwnd = Repair-DesignerBounds $win
        if (-not (Set-PadForeground $hwnd)) { throw 'cannot bring the designer to the foreground; the run button cannot be clicked' }
        # The designer's "Run" executes the current canvas directly and needs no draft save;
        # measured: clicking save puts the designer into a locked state (dimmed and uneditable), which in turn makes the run button unclickable
        $btn = Get-PadElementById $win 'StartFlowButton'
        if (-not $btn) { throw 'designer run button StartFlowButton not found' }
        [void](Invoke-UiClick $btn)
        Write-PadDesignerLog 'clicked the designer Run button (local run, not published)'
    } else {
        # Pre-trigger validation: the flow name must resolve to a flowId in the local Console run history,
        # otherwise PAD only pops "environment with the specified ID not found" and the outer layer misjudges a dismissed popup as a completed run.
        $identity = Resolve-PadFlowIdentity -WorkflowName $WorkflowName
        if (-not $identity) {
            # An exception carrying Data['code']: the caller classifies by code and never parses the Chinese message
            $msg = ("pre-trigger check failed: the PAD console has no flow named '{0}' (no parseable RunDefinition under Console\Scripts). " +
                'Confirm the flow name in the PAD console and run it at least once; nothing was triggered.') -f $WorkflowName
            $ex = [System.Exception]::new($msg)
            $ex.Data['code'] = 'TRIGGER_PREFLIGHT_FAILED'
            throw $ex
        }
        Write-PadDesignerLog ("pre-trigger check passed: flow={0} flowId={1} environmentId={2}" -f `
            $identity.FlowName, $identity.FlowId, $identity.EnvironmentId)
        $uri = "ms-powerautomate:/console/flow/run?workflowName=$WorkflowName&runId=$RunId"
        Write-PadDesignerLog "trigger run: $uri"
        Start-Process $uri
    }

    $result = [ordered]@{
        robotId = 0; evidence = $null; runDir = $null; logPath = $null; status = $null
        # Evidence markers for trigger-type failures: let the orchestration layer distinguish "never started" from "ran but failed", instead of always recording run-failed
        startupTimedOut = $false   # no robot / run log visible even at the decision window
        timedOut = $false          # the entire wait reached TimeoutSec without a terminal status
    }
    $root = Get-UiRoot
    $quietPolls = 0
    # Whether this run really saw a robot process: the run directory exists the moment the trigger fires,
    # so "directory exists" cannot imply "already running"
    $everAlive = $false
    # Handles of dialogs already clicked: each window is clicked once only; cleared once the confirm button disappears, ready for the next trigger
    $clickedConfirm = @{}
    # First-seen time of manual-confirmation dialogs in non-interactive mode: handle -> @{ First; Title }
    $humanDialogs = @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Milliseconds 800

        # 1) External trigger confirmation dialog: click only when Console.Host + title allowlist + protocol button all match;
        #    each window handle is clicked at most once, and the button is verified gone afterwards to avoid double triggers
        foreach ($p in (Get-Process -Name 'PAD.Console.Host' -ErrorAction SilentlyContinue)) {
            $c = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
            $cw = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $c)
            if (-not $cw) { continue }
            $hwnd = [IntPtr]$cw.Current.NativeWindowHandle
            $ok = Get-PadElementById $cw 'OKRunFlowFromProtocolHandlerButton'
            if (-not $ok) {
                # The dialog has gone: clear the "clicked" mark so a later trigger can confirm again
                if ($clickedConfirm.ContainsKey($hwnd)) { $clickedConfirm.Remove($hwnd) }
                continue
            }
            $accept = Test-ExternalTriggerDialog -ProcessName $p.ProcessName `
                -WindowTitle $cw.Current.Name -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton' `
                -ButtonControlType $ok.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
            if (-not $accept) {
                Write-PadDesignerLog ("found a confirm button but skipped it: process={0} title={1} button={2}" -f `
                    $p.ProcessName, $cw.Current.Name, 'OKRunFlowFromProtocolHandlerButton') 'debug'
                continue
            }
            if ($clickedConfirm.ContainsKey($hwnd)) {
                Write-PadDesignerLog ("window handle {0} was already confirmed; waiting for the popup to disappear without clicking again" -f $hwnd) 'debug'
                continue
            }
            try {
                $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $clickedConfirm[$hwnd] = Get-Date
                Write-PadDesignerLog ("clicked the external-trigger confirmation dialog: window title='{0}' time={1} basis=process PAD.Console.Host + title allowlist + OKRunFlowFromProtocolHandlerButton" -f `
                    $cw.Current.Name, (Get-Date).ToString('HH:mm:ss.fff'))
            } catch {
                Write-PadDesignerLog ("failed to click the confirmation dialog: {0}" -f $_.Exception.Message)
            }
            # Verify after clicking: the button should disappear within 2 seconds; if it remains, log a warning and do not click again
            $gone = $false
            $swVerify = [Diagnostics.Stopwatch]::StartNew()
            while ($swVerify.Elapsed.TotalSeconds -lt 2) {
                Start-Sleep -Milliseconds 300
                if (-not (Get-PadElementById $cw 'OKRunFlowFromProtocolHandlerButton')) { $gone = $true; break }
            }
            if (-not $gone) {
                Write-PadDesignerLog ("the confirmation dialog is still visible 2 seconds after clicking (handle {0}); keeping the 'clicked' mark and not clicking again" -f $hwnd)
            } else {
                $clickedConfirm.Remove($hwnd)
            }
        }

        # 2) Robot windows: observe only, never click.
        #    Business dialogs (completion prompts / manual confirmations) must be left to a human; after this narrowing there is no BM_CLICK here any more.
        $robotAlive = $false
        $currentHumanHandles = @{}
        foreach ($rp in (Get-Process -Name 'PAD.RobotV2' -ErrorAction SilentlyContinue)) {
            if ($beforePids.ContainsKey($rp.Id)) { continue }
            $robotAlive = $true
            $everAlive = $true
            if (-not $result.robotId) { $result.robotId = $rp.Id }
            if ($rp.Id -ne $result.robotId) { continue }   # other robots that pop up at the same time do not belong to this run
            foreach ($d in (Get-PadRobotDialogs -ProcessId $rp.Id)) {
                $h = [string]$d.Handle
                # A robot has no visible top-level window while executing normally; a visible window with a title means a dialog waiting for a human.
                # Shell windows whose title equals the console's are excluded to avoid a false positive.
                if ($d.Title -eq 'Power Automate') {
                    Write-PadDesignerLog ("found a robot window but skipped it: title='{0}' class={1} hasButton={2}" -f `
                        $d.Title, $d.ClassName, $d.HasButton) 'debug'
                    continue
                }
                $currentHumanHandles[$h] = $true
                if ($humanDialogs.ContainsKey($h)) {
                    $age = ((Get-Date) - $humanDialogs[$h].First).TotalSeconds
                    Write-PadDesignerLog ("robot popup detected: title='{0}' present for {1:N0} second(s) (not auto-clicked)" -f `
                        $d.Title, $age) 'debug'
                    if ($NonInteractive -and $age -ge $HumanConfirmGraceSec) {
                        $result.evidence = 'human-confirm'
                        $result.dialogTitle = $d.Title
                        Write-PadDesignerLog ("unattended run is waiting at a manual-confirmation popup: title='{0}', waited {1:N0} second(s); handing it back to the outer alerting layer and leaving the flow waiting for a human click" -f `
                            $d.Title, $age)
                        break
                    }
                } else {
                    $humanDialogs[$h] = @{ First = Get-Date; Title = $d.Title }
                    Write-PadDesignerLog ("robot popup found: title='{0}' (in unattended mode it must stay for {1} second(s) before it counts as manual confirmation)" -f `
                        $d.Title, $HumanConfirmGraceSec) 'debug'
                }
            }
            if ($result.evidence -eq 'human-confirm') { break }
        }
        # Clean up handles of dialogs that have disappeared
        foreach ($h in @($humanDialogs.Keys)) {
            if (-not $currentHumanHandles.ContainsKey($h)) { $humanDialogs.Remove($h) }
        }
        if ($result.evidence -eq 'human-confirm') { break }

        # 3) Evidence of this run: run directories (URL) or telemetry logs (local run) that appear beyond the baseline
        if (-not $result.evidence) {
            if ($Local) {
                $new = @(Get-ChildItem $dcDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                    Where-Object { -not $beforeLogs.ContainsKey($_.Name) } |
                    Sort-Object LastWriteTime -Descending)
                if ($new.Count -gt 0) {
                    $result.evidence = 'telemetry'
                    $result.logPath = $new[0].FullName
                    Write-PadDesignerLog "located the telemetry log of this run: $($new[0].Name)"
                }
            } else {
                # Accept only the directory matching the runId in this URL.
                # "The newest run directory after the trigger" is unusable: with concurrency on the same machine, the second triggered flow
                # would take the first flow's run directory as its own (measured), and all later logs/status would be wrong.
                $hit = $null
                if ($RunId) {
                    $hit = @(Get-PadRunDirs $scriptsRoot |
                        Where-Object { $_.Name -eq $RunId }) | Select-Object -First 1
                }
                if ($hit) {
                    $result.evidence = 'run-dir'
                    $result.runDir = $hit.FullName
                    $result.logPath = Join-Path $hit.FullName 'Actions.log'
                    Write-PadDesignerLog "located the run directory of this run: $($hit.Name)"
                }
            }
        }

        # 4) Completion decision: a terminal status in the log ends it (no process table involved)
        if ($result.evidence -eq 'run-dir') {
            $st = Get-RunLogStatus $result.logPath
            if ($st) { $result.status = $st; break }
        } elseif ($result.evidence -eq 'telemetry') {
            $txt = ''
            try { $txt = Read-TextShared $result.logPath } catch { }
            if ($txt -match 'robot\.execution\.completion') { break }
        }

        # 5) This run is located, but PAD already cleared the log and our robot has exited too → finish after two quiet rounds
        #    (PAD cleans up Actions.log after a run, which is normal)
        #    The precondition is that this run really ran ($everAlive): the run directory exists the moment the trigger fires,
        #    while the robot still takes a few seconds to start; judging it finished right now would end the wait while PAD is just
        #    starting, and the collect phase would then read a log that PAD holds exclusively and fail (measured).
        if ($result.evidence -and $everAlive -and -not $robotAlive) {
            $quietPolls++
            if ($quietPolls -ge 3) {
                Write-PadDesignerLog 'the robot of this run has exited; treating the run as finished'
                break
            }
        } elseif ($result.evidence -and -not $everAlive -and $sw.Elapsed.TotalSeconds -gt $StartupTimeoutSec) {
            # The directory appeared but the robot never started: most likely the console confirmation was cancelled, or PAD failed to start
            $result.startupTimedOut = $true
            Write-PadDesignerLog "the robot did not start within $StartupTimeoutSec second(s) after the trigger; treating the run as not started"
            break
        } else {
            $quietPolls = 0
        }

        # 6) No evidence of this run at all (e.g. someone clicked cancel in the console confirmation) → do not wait out the entire timeout
        if (-not $result.evidence -and $sw.Elapsed.TotalSeconds -gt $StartupTimeoutSec) {
            $result.startupTimedOut = $true
            Write-PadDesignerLog "no log of this run appeared within $StartupTimeoutSec second(s) after the trigger; treating the run as not started"
            break
        }
    }
    # The whole wait reached TimeoutSec without a terminal status: that is a run timeout, not "result unknown"
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { $result.timedOut = $true }
    Start-Sleep -Seconds 2
    return $result
}

Export-ModuleMember -Function `
    Get-DesignerWindow, Get-PadElementById, Get-PadElementByName, Get-PadElementByClass, `
    Get-ActionItems, Focus-ActionList, Clear-ActionList, Get-CanvasText, Test-CanvasMatch, `
    Test-WindowOutside, Repair-DesignerBounds, Exit-Recorder, Click-ToolButton, `
    Get-StatusBarText, Wait-PublishDone, Invoke-PadInject, Invoke-PadRun, `
    Get-PadRunDirs, Get-RunLogStatus, Read-TextShared, Resolve-PadRunDir, `
    Test-ExternalTriggerDialog, Get-PadRobotDialogs, Resolve-PadFlowIdentity
