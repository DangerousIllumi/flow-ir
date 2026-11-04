# PadDesigner.psm1 — PAD 设计器 UI 自动化（找窗 / 动作列表 / 清空 / 注入 / 运行 / 状态栏 / 画布回读）
#
# 这是设计器交互的唯一实现，pad-sync.ps1 只保留编排（注入 → 发布 → 运行 → 收集）。
#
# 硬约束：
#   1) 禁止坐标点击，一律走 UIAutomation Pattern（InvokePattern / SetFocus）
#   2) 窗口被拖到屏幕外或最小化时先修复位置，否则 Ctrl+A / Ctrl+V 全部落空
#   3) -VerifyCanvas：粘贴后把画布内容复制回来，规范化后与源 .robin 逐行比对，
#      “只粘进去一部分”时按第一处差异中止，不继续发布/运行

Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

# Win32 声明只注册一次：模块被重复导入（-Force）时 Add-Type 会因类型重名失败
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

# 设计器日志：控制台只打印 info，debug 级只落文件（用于复盘“扫描到但跳过”）
# 文件默认写 %LOCALAPPDATA%\flow-ir\pad-designer.log，可用环境变量 FLOW_IR_PAD_DESIGNER_LOG 覆盖
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

# ── 找窗口 ────────────────────────────────────────────────────
# 设计器主窗口：进程名 PAD.Designer 且标题包含流程名
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

# ── 元素查找 ──────────────────────────────────────────────────
function Get-PadElementById($Window, [string]$AutoId) {
    $c = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $AutoId)
    return $Window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
}

# 工具栏按钮（保存草稿/发布）的 AutomationId 实测都是通用值 'Button'，
# 只有名称是稳定的，因此按 Name 查找
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

# 鼠标点击元素中心（仅作为 InvokePattern 不可用时的兜底）。
# 优先 GetClickablePoint（UIA 推荐），失败时退到 BoundingRectangle 中心
function Invoke-UiClick($Element) {
    if (-not $Element) { return $false }
    # 优先 InvokePattern：实测 PAD 设计器按钮的 BoundingRectangle 可能落在屏幕外
    # （如 -31707,-31960），此时坐标点击必然打空
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

# 抢回前台：Windows 前台锁定会让单次调用静默失败，用四层手段叠加
#   1) AppActivate  2) HWND_TOPMOST 临时置顶（突破前台锁最可靠）  3) Alt 解键  4) 轮询重试
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

# 窗口是否在可视区域外（纯函数，供修复逻辑与单元测试共用）
# 最小化时 Windows 把坐标记为 -32000，也按“在区域外”处理
function Test-WindowOutside {
    param(
        [int]$Left, [int]$Top, [int]$Right, [int]$Bottom,
        [int]$ScreenWidth, [int]$ScreenHeight,
        [switch]$Minimized
    )
    if ($Minimized) { return $true }
    return (($Right -gt $ScreenWidth) -or ($Left -lt 0) -or ($Top -lt 0))
}

# 设计器窗口可能被拖到屏幕外（实测出现过 L=878 R=2078 超出 1920 屏宽），
# 此时任何坐标点击都会落到别的窗口上，必须先移回屏幕内
function Repair-DesignerBounds($Window) {
    $hwnd = [IntPtr]$Window.Current.NativeWindowHandle
    # 最小化时 SetWindowPos 不生效，必须先 SW_RESTORE 恢复，
    # 否则后续 Ctrl+A / Ctrl+V 全部打空（实测清空 14 → 14）
    if ([PadNative]::IsIconic($hwnd)) {
        Write-PadDesignerLog '设计器窗口处于最小化状态，先恢复窗口'
        [void][PadNative]::ShowWindow($hwnd, 9)
        Start-Sleep -Milliseconds 900
    }
    $r = New-Object PadNative+RECT
    [void][PadNative]::GetWindowRect($hwnd, [ref]$r)
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $outside = Test-WindowOutside -Left $r.L -Top $r.T -Right $r.R -Bottom $r.B `
        -ScreenWidth $screen.Width -ScreenHeight $screen.Height -Minimized:([PadNative]::IsIconic($hwnd))
    if ($outside) {
        Write-PadDesignerLog "设计器窗口不在可视区域 (L=$($r.L) T=$($r.T) R=$($r.R) B=$($r.B))，移回 (40,40)"
        [void][PadNative]::ShowWindow($hwnd, 9)
        [void][PadNative]::SetWindowPos($hwnd, [IntPtr]0, 40, 40, 1200, 900, 0x0040)
        Start-Sleep -Milliseconds 900
    }
    return $hwnd
}

# 记录器一旦被误触，整个设计器会变暗、无法编辑；按 Esc 退出并校验
function Exit-Recorder($Window) {
    $all = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    $recording = $false
    foreach ($e in $all) {
        if ($e.Current.Name -match '尚未记录|选择记录以开始') { $recording = $true; break }
    }
    if (-not $recording) { return $true }
    Write-PadDesignerLog '检测到 UI 记录器处于打开状态，尝试按 Esc 退出'
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Seconds 1
    $all2 = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all2) {
        if ($e.Current.Name -match '尚未记录|选择记录以开始') { return $false }
    }
    return $true
}

# ── 动作列表 ──────────────────────────────────────────────────
function Get-ActionItems($Window) {
    $fv = Get-PadElementByClass $Window 'FunctionView'
    if (-not $fv) { return @() }
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    return @($fv.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond))
}

# 把键盘焦点送进动作列表（Ctrl+V / Ctrl+A 生效的前提）
# 不再用鼠标坐标点击：坐标容易落到工具栏其他按钮上（实测误点过“子流程”）
function Focus-ActionList($Window) {
    $items = Get-ActionItems $Window
    if ($items.Count -eq 0) {
        # 空画布没有可聚焦的元素，焦点默认就在画布上，直接返回
        return $false
    }
    try {
        # 必须用刚查询出来的元素：列表虚拟化后旧句柄会失效
        $items[0].SetFocus()
        Start-Sleep -Milliseconds 300
        return $true
    } catch {
        Write-PadDesignerLog "聚焦动作列表失败：$($_.Exception.Message)"
        return $false
    }
}

# 清空画布：Ctrl+A + Delete 循环，直到动作列表为空
# 为什么要循环：FunctionView 是虚拟化列表，FindAll 只能看到“已渲染”的动作，
#   “选中数 == 总数”这种校验必然误判（实测 15 个动作只渲染 14 个），
#   改为“删完再查、还有就再删一轮”，以删除后的真实剩余数为准
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
        Write-PadDesignerLog "清空画布第 $round 轮：删除后剩余 $left 个动作"
        if ($left -eq 0) { return 0 }
    }
    throw '清空画布失败：连续 5 轮 Ctrl+A + Delete 后仍有动作残留'
}

# 画布回读：Ctrl+A + Ctrl+C 把当前动作复制成 robin 文本
# 返回 null 表示剪贴板一直是空的（通常是没有焦点或画布不可选）
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

# 画布内容与源 .robin 的逐行比对（规范化后），差异定位到第一处
function Test-CanvasMatch {
    param([string]$CanvasText, [string]$SourceText)
    return (Compare-RobinText $SourceText $CanvasText)
}

# 找到真正可 Invoke 的元素：PAD 的 PublishFlowButton 是 Custom 容器，
# 自身不支持 InvokePattern，必须下沉到内部的 Button 子元素
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

# 点击工具栏按钮。按钮是否变灰取决于 PAD 版本，不能再作为成功判据
function Click-ToolButton($Window, [string]$AutoId) {
    $btn = Get-PadElementById $Window $AutoId
    if (-not $btn) { throw "找不到按钮 $AutoId" }
    $btn = Get-InvokableElement $btn
    if (-not $btn) { throw "按钮 $AutoId 内部没有可 Invoke 的 Button" }
    if (-not $btn.Current.IsEnabled) { throw "按钮 $AutoId 不可用" }
    return (Invoke-UiClick $btn)
}

# ── 状态栏 ────────────────────────────────────────────────────
# 状态栏保存/发布进度元素，返回其文本（无该元素时返回 null）
function Get-StatusBarText($Window) {
    $el = Get-PadElementById $Window 'Flow_status_saving_process'
    if ($el) { return $el.Current.Name }
    return $null
}

# 等待发布结束：轮询状态栏
# 只有先看到“正在发布”再看到它消失，才算确认发布完成
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

# ── 注入：粘贴 .robin 到画布 ──────────────────────────────────
# 返回 { actions / verified / diff }；verified 只在 -VerifyCanvas 时为 $true
function Invoke-PadInject {
    param(
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$Replace,
        [switch]$VerifyCanvas
    )
    $hwnd = Repair-DesignerBounds $Window
    if (-not (Set-PadForeground $hwnd)) { throw '无法把 PAD 设计器切到前台，Ctrl+A / Ctrl+V 会全部落空' }
    # 先收掉可能残留的下拉/浮层，否则第一次点击会落在浮层上而不是画布
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 400
    if (-not (Exit-Recorder $Window)) { throw 'UI 记录器无法关闭，设计器处于不可编辑状态' }

    $before = (Get-ActionItems $Window).Count
    [void](Focus-ActionList $Window)
    [void](Set-PadForeground $hwnd)

    if ($Replace -and $before -gt 0) {
        [void](Set-PadForeground $hwnd)
        $afterClear = Clear-ActionList $Window
        Write-PadDesignerLog "清空画布：$before → $afterClear"
        # 清空失败不能继续追加，否则旧动作会和新动作叠加
        if ($afterClear -gt 0) { throw "清空画布失败（仍有 $afterClear 个动作）" }
        [void](Focus-ActionList $Window)
        [void](Set-PadForeground $hwnd)
    }

    # 粘贴前的基准动作数（清空成功后为 0）
    $baseCount = (Get-ActionItems $Window).Count
    Set-Clipboard -Value $Text
    [void](Set-PadForeground $hwnd)
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    # 等待画布出现新动作
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 20) {
        Start-Sleep -Milliseconds 500
        if ((Get-ActionItems $Window).Count -gt $baseCount) { break }
    }
    $final = (Get-ActionItems $Window).Count
    if ($final -le $baseCount) { throw "粘贴后画布动作数没有增加（仍为 $final）" }
    Write-PadDesignerLog "注入完成：动作数 $baseCount → $final"

    # 画布回读校验：粘贴可能只进去一部分（长文本/焦点丢失），必须与源逐行比对
    $verified = $false
    $cmp = $null
    if ($VerifyCanvas) {
        $canvas = Get-CanvasText $Window
        if (-not $canvas) { throw '画布回读失败：复制后剪贴板为空（可能没有焦点或画布不可选）' }
        $cmp = Test-CanvasMatch -CanvasText $canvas -SourceText $Text
        if (-not $cmp.match) {
            throw ("画布内容与源 .robin 不一致（可能只粘进去一部分）：第 {0} 行`n  源：{1}`n  画布：{2}" -f $cmp.diffIndex, $cmp.lineA, $cmp.lineB)
        }
        $verified = $true
        Write-PadDesignerLog '画布回读校验通过：粘贴内容与源 .robin 逐行一致'
    }
    return [ordered]@{ actions = $final; verified = $verified; diff = $cmp }
}

# ── 运行：触发 + 按“运行日志落盘”判定开始与结束 ───────────────
# 旧实现用「PAD.RobotV2 进程还在不在」判断本次运行是否结束。同一台机器上只要有人
# 同时跑别的流（例如在设计器里手工运行），那个进程就会被误当成本次的机器人：它一退出
# 就提前判定结束，随后收集日志时自然找不到本次的运行目录。
# 现在改为：
#   1) 触发前记基线：已有运行目录 / 机器人进程 / 遥测日志都不属于本次
#   2) 触发后只认「基线之外新出现」的运行目录（URL 触发）或遥测日志（设计器本地运行）
#   3) 结束判定看日志里的终止状态，不看进程表
#   4) 只点「触发之后新起」的机器人进程的消息框，避免误点别人那一轮的弹窗
# 返回 [ordered]@{ robotId; evidence; runDir; logPath; status }，供编排层收集结果

# 列出 Console\Scripts\<流程Guid>\Runs 下的所有运行目录
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

# 按本次触发的 runId 精确定位运行目录；找不到返回 $null
# 绝不退化成“取触发之后最新的目录”：同机并发时那会拿到别人的运行目录。
# 这里复用 Get-PadRunDirs，保证与等待阶段的定位口径完全一致（只有一套写法）。
function Resolve-PadRunDir {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptsRoot,
        [string]$RunId
    )
    if (-not $RunId) { return $null }
    return (@(Get-PadRunDirs -ScriptsRoot $ScriptsRoot |
        Where-Object { $_.Name -eq $RunId }) | Select-Object -First 1)
}

# 以共享模式读文本：PAD 在流程运行期间会一直持有日志的写句柄，
# 直接用 ReadAllText / ReadAllLines 会抛“文件正由另一进程使用”。
# 用 FileShare.ReadWrite 打开既能读到当前内容，也不影响 PAD 继续写。
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

# 读 Actions.log 末尾的汇总行，返回终止状态（Succeeded / Failed / Cancelled）
# 逐动作行都带 index，只有整次运行的汇总行没有 index，用它区分
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

# 外部触发确认框判定（纯函数，便于单测）
#
# 真机探测结论（2026-11-04，只读探测，日志 %TEMP%\pad-dialog-probe.log）：
#   触发 URI 后弹出的确认框属于 PAD.Console.Host，顶层窗口标题原文为「Power Automate」
#   （class=WinAutomationWindow），确认按钮 AutomationId=OKRunFlowFromProtocolHandlerButton。
#   同一时段 PAD.RobotV2 没有出现确认框。
#
# 因此判定必须同时满足：来源进程 + 标题白名单 + 按钮 AutomationId（+ 控件类型）。
# 绝不按按钮文字（确定/OK/是）判定——业务弹窗（完成提示、催办确认）也带这些按钮。
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

# 列出某个 PAD.RobotV2 进程当前可见的顶层窗口（只看标题，不点击）
# 用途：非交互运行下判断流程是否停在人工确认弹窗；交互运行只记 debug 日志
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
                # 是否含原生按钮：只有按钮的窗口才可能是需要人点的弹窗
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

# 触发前校验：把流程名解析成 PAD 本机的 flowId / environmentId
#
# PAD 的 URL 触发只带 workflowName，环境与流程 ID 由 Console 内部解析。
# 名字对不上时 Console 会弹“未找到具有指定 ID 的环境”之类的错误，
# 若外层再把它当成一次运行收尾，就会误判为跑完。
# 这里用 Console\Scripts 下历史运行的 RunDefinition.json（workflow.name ↔ workflowId、
# environmentId）做只读解析：解析不到就拒绝触发，而不是把错误留给 PAD 弹窗。
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
    # 流程目录必须真实存在，否则 Console 同样会拒绝
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptsRoot $best.FlowId))) { return $null }
    return $best
}

function Invoke-PadRun {
    param(
        [Parameter(Mandatory = $true)][string]$WorkflowName,
        [string]$RunId,
        [int]$TimeoutSec = 300,
        # 触发后多久仍看不到本次运行日志就判定“没起来”（例如用户点了控制台的取消）
        [int]$StartupTimeoutSec = 180,
        # 非交互（定时任务）：遇到稳定存在的人工确认弹窗就交回上层收尾，不自动点击
        [switch]$NonInteractive,
        # 人工确认弹窗需稳定存在多少秒才判定（过滤瞬时错误框）
        [int]$HumanConfirmGraceSec = 20,
        [switch]$Local
    )
    $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
    $dcDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\DataCollection'

    # 基线：触发之前就存在的机器人进程 / 遥测日志，一律不算本次运行
    # （URL 触发不拍目录基线：本次运行只认自己的 runId，见下面的证据定位）
    $beforePids = @{}
    foreach ($p in (Get-Process -Name 'PAD.RobotV2' -ErrorAction SilentlyContinue)) { $beforePids[$p.Id] = $true }
    $beforeLogs = @{}
    if (Test-Path $dcDir) {
        foreach ($f in (Get-ChildItem $dcDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) { $beforeLogs[$f.Name] = $true }
    }

    if ($Local) {
        # 测试阶段直接点设计器的“运行”按钮执行当前画布，不发布到云端：
        # 免掉云端发布等待，也不会再遇到版本冲突
        $win = Get-DesignerWindow -FlowName $WorkflowName
        if (-not $win) { throw "找不到设计器窗口：$WorkflowName" }
        $hwnd = Repair-DesignerBounds $win
        if (-not (Set-PadForeground $hwnd)) { throw '无法把设计器切到前台，点不到运行按钮' }
        # 设计器的“运行”直接执行当前画布，不需要保存草稿；
        # 实测点保存会让设计器进入锁定态（整体变暗、不可编辑），反而导致运行点不动
        $btn = Get-PadElementById $win 'StartFlowButton'
        if (-not $btn) { throw '找不到设计器运行按钮 StartFlowButton' }
        [void](Invoke-UiClick $btn)
        Write-PadDesignerLog '已点击设计器“运行”（本地运行，未发布）'
    } else {
        # 触发前校验：流程名必须能在本机 Console 的运行记录里解析出 flowId，
        # 否则 PAD 只会弹“未找到具有指定 ID 的环境”，外层再把弹窗点掉就误判成跑完。
        $identity = Resolve-PadFlowIdentity -WorkflowName $WorkflowName
        if (-not $identity) {
            throw ("触发前校验失败：PAD 控制台找不到名为「{0}」的流程（Console\Scripts 下没有可解析的 RunDefinition）。" +
                '请先在 PAD 控制台确认流程名并至少运行一次；本次未触发。') -f $WorkflowName
        }
        Write-PadDesignerLog ("触发前校验通过：flow={0} flowId={1} environmentId={2}" -f `
            $identity.FlowName, $identity.FlowId, $identity.EnvironmentId)
        $uri = "ms-powerautomate:/console/flow/run?workflowName=$WorkflowName&runId=$RunId"
        Write-PadDesignerLog "触发运行：$uri"
        Start-Process $uri
    }

    $result = [ordered]@{ robotId = 0; evidence = $null; runDir = $null; logPath = $null; status = $null }
    $root = Get-UiRoot
    $quietPolls = 0
    # 本次运行是否真的见过机器人进程：运行目录在触发瞬间就存在，
    # 不能用“目录出现”推断“已经在跑”
    $everAlive = $false
    # 已点过的确认框句柄：同一窗口只点一次；确认按钮消失后再清除，供下一次触发使用
    $clickedConfirm = @{}
    # 非交互模式下的人工确认弹窗首见时间：句柄 -> @{ First; Title }
    $humanDialogs = @{}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Milliseconds 800

        # 1) 外部触发确认框：只有 Console.Host + 标题白名单 + 协议按钮同时匹配才点；
        #    每个窗口句柄最多点一次，点后校验按钮确实消失，避免重复触发
        foreach ($p in (Get-Process -Name 'PAD.Console.Host' -ErrorAction SilentlyContinue)) {
            $c = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
            $cw = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $c)
            if (-not $cw) { continue }
            $hwnd = [IntPtr]$cw.Current.NativeWindowHandle
            $ok = Get-PadElementById $cw 'OKRunFlowFromProtocolHandlerButton'
            if (-not $ok) {
                # 确认框已消失：解除“已点”标记，允许后续触发再次确认
                if ($clickedConfirm.ContainsKey($hwnd)) { $clickedConfirm.Remove($hwnd) }
                continue
            }
            $accept = Test-ExternalTriggerDialog -ProcessName $p.ProcessName `
                -WindowTitle $cw.Current.Name -ButtonAutomationId 'OKRunFlowFromProtocolHandlerButton' `
                -ButtonControlType $ok.Current.ControlType.ProgrammaticName.Replace('ControlType.', '')
            if (-not $accept) {
                Write-PadDesignerLog ("扫描到确认按钮但跳过：进程={0} 标题={1} 按钮={2}" -f `
                    $p.ProcessName, $cw.Current.Name, 'OKRunFlowFromProtocolHandlerButton') 'debug'
                continue
            }
            if ($clickedConfirm.ContainsKey($hwnd)) {
                Write-PadDesignerLog ("窗口句柄 {0} 已确认过，等待弹窗消失，不重复点击" -f $hwnd) 'debug'
                continue
            }
            try {
                $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $clickedConfirm[$hwnd] = Get-Date
                Write-PadDesignerLog ("点击外部触发确认框：窗口标题=「{0}」 时间={1} 依据=进程 PAD.Console.Host + 标题白名单 + OKRunFlowFromProtocolHandlerButton" -f `
                    $cw.Current.Name, (Get-Date).ToString('HH:mm:ss.fff'))
            } catch {
                Write-PadDesignerLog ("点击确认框失败：{0}" -f $_.Exception.Message)
            }
            # 点后校验：2 秒内按钮应消失；仍存在则记警告且不再重复点击
            $gone = $false
            $swVerify = [Diagnostics.Stopwatch]::StartNew()
            while ($swVerify.Elapsed.TotalSeconds -lt 2) {
                Start-Sleep -Milliseconds 300
                if (-not (Get-PadElementById $cw 'OKRunFlowFromProtocolHandlerButton')) { $gone = $true; break }
            }
            if (-not $gone) {
                Write-PadDesignerLog ("确认框点击后 2 秒仍未消失（句柄 {0}），保持「已点」标记，不重复点击" -f $hwnd)
            } else {
                $clickedConfirm.Remove($hwnd)
            }
        }

        # 2) 机器人窗口：只观察，绝不点击。
        #    业务弹窗（完成提示 / 催办确认）必须留给人；收窄后这里不再有 BM_CLICK。
        $robotAlive = $false
        $currentHumanHandles = @{}
        foreach ($rp in (Get-Process -Name 'PAD.RobotV2' -ErrorAction SilentlyContinue)) {
            if ($beforePids.ContainsKey($rp.Id)) { continue }
            $robotAlive = $true
            $everAlive = $true
            if (-not $result.robotId) { $result.robotId = $rp.Id }
            if ($rp.Id -ne $result.robotId) { continue }   # 同时冒出来的其它机器人不归本次
            foreach ($d in (Get-PadRobotDialogs -ProcessId $rp.Id)) {
                $h = [string]$d.Handle
                # 机器人正常执行时没有可见顶层窗口；出现可见且有标题的窗口即等待人处理的弹窗。
                # 标题与控制台同名的外壳窗口排除，避免误判。
                if ($d.Title -eq 'Power Automate') {
                    Write-PadDesignerLog ("扫描到机器人窗口但跳过：标题=「{0}」 class={1} 含按钮={2}" -f `
                        $d.Title, $d.ClassName, $d.HasButton) 'debug'
                    continue
                }
                $currentHumanHandles[$h] = $true
                if ($humanDialogs.ContainsKey($h)) {
                    $age = ((Get-Date) - $humanDialogs[$h].First).TotalSeconds
                    Write-PadDesignerLog ("检测到机器人弹窗：标题=「{0}」 已存在 {1:N0} 秒（不自动点击）" -f `
                        $d.Title, $age) 'debug'
                    if ($NonInteractive -and $age -ge $HumanConfirmGraceSec) {
                        $result.evidence = 'human-confirm'
                        $result.dialogTitle = $d.Title
                        Write-PadDesignerLog ("非交互运行停在人工确认弹窗：标题=「{0}」，已等待 {1:N0} 秒，交回上层告警，流程保持等待人工点击" -f `
                            $d.Title, $age)
                        break
                    }
                } else {
                    $humanDialogs[$h] = @{ First = Get-Date; Title = $d.Title }
                    Write-PadDesignerLog ("发现机器人弹窗：标题=「{0}」（非交互模式下需稳定 {1} 秒才判定为人工确认）" -f `
                        $d.Title, $HumanConfirmGraceSec) 'debug'
                }
            }
            if ($result.evidence -eq 'human-confirm') { break }
        }
        # 清理已消失的弹窗句柄
        foreach ($h in @($humanDialogs.Keys)) {
            if (-not $currentHumanHandles.ContainsKey($h)) { $humanDialogs.Remove($h) }
        }
        if ($result.evidence -eq 'human-confirm') { break }

        # 3) 本次运行的证据：基线之外新出现的运行目录（URL）或遥测日志（本地运行）
        if (-not $result.evidence) {
            if ($Local) {
                $new = @(Get-ChildItem $dcDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                    Where-Object { -not $beforeLogs.ContainsKey($_.Name) } |
                    Sort-Object LastWriteTime -Descending)
                if ($new.Count -gt 0) {
                    $result.evidence = 'telemetry'
                    $result.logPath = $new[0].FullName
                    Write-PadDesignerLog "已定位本次运行遥测日志：$($new[0].Name)"
                }
            } else {
                # 只认「本次 URL 里那个 runId」对应的目录。
                # 不能用“触发后最新的运行目录”：同机并发时，第二个触发的流会
                # 把第一个流的运行目录当成自己的（实测已发生），后续日志/状态全错。
                $hit = $null
                if ($RunId) {
                    $hit = @(Get-PadRunDirs $scriptsRoot |
                        Where-Object { $_.Name -eq $RunId }) | Select-Object -First 1
                }
                if ($hit) {
                    $result.evidence = 'run-dir'
                    $result.runDir = $hit.FullName
                    $result.logPath = Join-Path $hit.FullName 'Actions.log'
                    Write-PadDesignerLog "已定位本次运行目录：$($hit.Name)"
                }
            }
        }

        # 4) 结束判定：日志里出现终止状态即结束（不看进程表）
        if ($result.evidence -eq 'run-dir') {
            $st = Get-RunLogStatus $result.logPath
            if ($st) { $result.status = $st; break }
        } elseif ($result.evidence -eq 'telemetry') {
            $txt = ''
            try { $txt = Read-TextShared $result.logPath } catch { }
            if ($txt -match 'robot\.execution\.completion') { break }
        }

        # 5) 已定位本次运行，但日志被 PAD 清掉且我们的机器人也退出了 → 静默两轮后收工
        #    （运行结束后 PAD 会清理 Actions.log，属正常现象）
        #    前提是本次运行真的跑过（$everAlive）：运行目录在触发瞬间就已经存在，
        #    而机器人还要几秒才启动；此时若直接判定结束，会在 PAD 刚开始跑时就收工，
        #    随后 collect 阶段去读一个正被 PAD 独占的日志而报错（实测踩过）
        if ($result.evidence -and $everAlive -and -not $robotAlive) {
            $quietPolls++
            if ($quietPolls -ge 3) {
                Write-PadDesignerLog '本次运行的机器人已退出，按结束处理'
                break
            }
        } elseif ($result.evidence -and -not $everAlive -and $sw.Elapsed.TotalSeconds -gt $StartupTimeoutSec) {
            # 目录已出现但机器人始终没起来：多半是控制台确认框被取消，或 PAD 启动失败
            Write-PadDesignerLog "触发后 $StartupTimeoutSec 秒内机器人未启动，判定未运行"
            break
        } else {
            $quietPolls = 0
        }

        # 6) 一直没有本次运行的任何证据（比如控制台确认框被点了取消）→ 别傻等满超时
        if (-not $result.evidence -and $sw.Elapsed.TotalSeconds -gt $StartupTimeoutSec) {
            Write-PadDesignerLog "触发后 $StartupTimeoutSec 秒内没有出现本次运行的日志，判定未启动"
            break
        }
    }
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
