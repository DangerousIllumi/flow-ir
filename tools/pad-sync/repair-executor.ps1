# repair-executor.ps1 — 修复循环的可插拔执行器（规则版）
#
# 协议（agent 可换成任意程序，只要遵守同一接口）：
#   入参：-ContextFile <repair_ctx_N.json>  -InputRobin <current.robin>  -OutputRobin <round_N.robin>
#   成功：产出 OutputRobin 并 exit 0，循环继续下一轮
#   放弃：exit 1，循环停止（同时写 .hint.md 供人或 agent 接手）
#
# 内置规则只做「能确定安全」的修复，其余一律放弃，避免自动改坏流程。
# 规则表：
#   R1 缺失文件 / 缺失目录 → 先试“去空格、去尾反斜杠”的纠正写法，再在 -PadRoot 下找唯一同名项
#   R2 缺失目录（-PadRoot 下）→ 直接创建
#   R3 其他错误码 → 按错误族给出针对性提示，不自动改（SAP/UI/Excel/剪贴板/脚本退出码…）

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ContextFile,
    [Parameter(Mandatory = $true)][string]$InputRobin,
    [Parameter(Mandatory = $true)][string]$OutputRobin,
    # 路径修复的搜索根目录：只在它下面找同名项、建目录。测试时指向临时目录即可脱离真实环境
    [string]$PadRoot = 'C:\PAD',
    # 错误码 → 修复规则与提示模板的 JSON：新增错误码只改它，不改本脚本
    [string]$RulesFile
)
$ErrorActionPreference = 'Stop'
$PadRoot = $PadRoot.TrimEnd('\')

# 规则表默认取脚本同目录的 repair-rules.json
if (-not $RulesFile) { $RulesFile = Join-Path $PSScriptRoot 'repair-rules.json' }
if (-not (Test-Path $RulesFile)) { Write-Host "[executor] 找不到规则文件：$RulesFile"; exit 1 }
$rules = [IO.File]::ReadAllText($RulesFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

$ctx = [IO.File]::ReadAllText($ContextFile, [Text.Encoding]::UTF8) | ConvertFrom-Json

# 错误码有两个来源：run 级 padExceptionInfo、动作级 Actions.log；
# 设计器本地运行时内置动作失败只有 run 级，UI 动作失败只有动作级，因此两级兜底
$code = ''
$msg = ''
if ($ctx.error -and $ctx.error.code) { $code = [string]$ctx.error.code }
if ($ctx.error -and $ctx.error.type) { $msg = [string]$ctx.error.type }
$actCode = ''
$actMsg = ''
if ($ctx.failedAction -and $ctx.failedAction.error) {
    $actCode = [string]$ctx.failedAction.error.code
    $actMsg = [string]$ctx.failedAction.error.message
}
if (-not $code) { $code = $actCode }
if (-not $msg) { $msg = $actMsg }
$actName = ''
$sysName = ''
if ($ctx.failedAction) {
    if ($ctx.failedAction.name) { $actName = [string]$ctx.failedAction.name }
    if ($ctx.failedAction.systemActionName) { $sysName = [string]$ctx.failedAction.systemActionName }
}
Write-Host "[executor] 第 $($ctx.round) 轮 错误码：$code ；动作：$sysName / $actName"

$text = [IO.File]::ReadAllText($InputRobin, [Text.Encoding]::UTF8)
$raw = [IO.File]::ReadAllBytes($InputRobin)
$hadBom = ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)

function Save-Robin([string]$content) {
    if ($hadBom) { [IO.File]::WriteAllText($OutputRobin, $content, (New-Object Text.UTF8Encoding($true))) }
    else { [IO.File]::WriteAllText($OutputRobin, $content, (New-Object Text.UTF8Encoding($false))) }
}

# .robin 里的路径是双反斜杠转义写法，这里统一匹配「盘符 + 双反斜杠」
$PathRx = [regex]'[A-Za-z]:\\\\[^\x27\x22\s,;\)]+'

# 判断是不是目录路径：没有扩展名的一律当目录
function Is-DirPath([string]$p) {
    return -not ([IO.Path]::GetExtension($p))
}

function Find-UniqueUnderPad([string]$leaf, [bool]$isDir) {
    if ($isDir) {
        return @(Get-ChildItem $PadRoot -Recurse -Directory -Filter $leaf -ErrorAction SilentlyContinue)
    }
    return @(Get-ChildItem $PadRoot -Recurse -File -Filter $leaf -ErrorAction SilentlyContinue)
}

function To-Raw([string]$p) { return $p.Replace('\', '\\') }

function Log-Fix([string]$rule, [string]$detail) { Write-Host "[executor] $rule：$detail" }

# ── R1/R2：路径类错误（文件或目录不存在）────────────────────────
# 是否允许改路径由规则表 fixerRules 决定：只有错误码或错误消息能确认是“找不到路径”时才动路径，
# 避免把普通失败误改成改路径
$fixerRule = @($rules.fixerRules) | Where-Object {
    ($_.codePattern -and $code -match $_.codePattern) -or
    ($_.messagePattern -and $msg -and $msg -match $_.messagePattern)
} | Select-Object -First 1
$isPathErr = [bool]($fixerRule -and $fixerRule.action -eq 'resolve-path')
if ($isPathErr) {
    $missing = @()
    foreach ($m in $PathRx.Matches($text)) {
        $real = $m.Value.Replace('\\', '\')
        if (Test-Path $real) { continue }
        $missing += [pscustomobject]@{ Raw = $m.Value; Real = $real }
    }
    $missing = @($missing | Sort-Object Real -Unique)

    if ($missing.Count -eq 0) {
        Write-Host '[executor] R1：.robin 里的绝对路径都存在，说明报错来自非路径原因'
    } elseif ($missing.Count -gt 1) {
        Write-Host "[executor] R1：有 $($missing.Count) 个路径不存在，无法确定该改哪个：$(@($missing | ForEach-Object { $_.Real }) -join ' | ')"
    } else {
        $one = $missing[0]
        $isDir = Is-DirPath $one.Real
        $fixed = $null
        $rule = $null

        # 1) 纠正写法：去首尾空格、去结尾多余反斜杠、把重复反斜杠压成一个
        $trim = $one.Real.Trim().TrimEnd('\')
        $trim = [regex]::Replace($trim, '\\{2,}', '\')
        if ($trim -ne $one.Real -and (Test-Path $trim)) {
            $fixed = $trim; $rule = 'R1'
        }

        # 2) $PadRoot 下唯一同名项（文件按文件名、目录按目录名）
        if (-not $fixed) {
            $leaf = Split-Path $one.Real -Leaf
            $cand = @(Find-UniqueUnderPad $leaf $isDir)
            if ($cand.Count -eq 1) {
                $fixed = $cand[0].FullName; $rule = 'R1'
                Log-Fix 'R1' "$($one.Real) 不存在，$PadRoot 下唯一同名项改为 $fixed"
            } elseif ($cand.Count -gt 1) {
                Write-Host "[executor] R1：$PadRoot 下有 $($cand.Count) 个同名项 $leaf，无法确定唯一目标"
            }
        }

        # 3) 目录且位于 $PadRoot 下 → 直接创建（不会覆盖任何东西）
        if (-not $fixed -and $isDir -and $one.Real -like "$PadRoot\*") {
            try {
                New-Item -ItemType Directory -Path $one.Real -Force | Out-Null
                $rule = 'R2'
                Log-Fix 'R2' "已创建缺失目录 $($one.Real)"
            } catch {
                Write-Host "[executor] R2：创建目录失败：$($_.Exception.Message)"
            }
        }

        # 目录已经创建好时无需改 .robin
        if ($rule -eq 'R2') { Save-Robin $text; exit 0 }
        if ($fixed) {
            $newRaw = To-Raw $fixed
            $text = $text.Replace($one.Raw, $newRaw)
            Save-Robin $text
            exit 0
        }
    }
}

# ── R3：不能自动改的错误族 —— 按规则表给出针对性提示 ─────────────────
# 匹配顺序就是 JSON 里的数组顺序：错误码优先，其次系统动作名（如 RunDOSCommand）
$hintRule = @($rules.hintRules) | Where-Object {
    ($_.codePattern -and $code -match $_.codePattern) -or
    ($_.systemActionPattern -and $sysName -match $_.systemActionPattern)
} | Select-Object -First 1
if ($hintRule) {
    $codeHelp = [string]$hintRule.hint
} elseif ($rules.defaultHint) {
    $codeHelp = [string]$rules.defaultHint
} else {
    $codeHelp = '未识别的错误码：按错误消息在 docs/script-standards.md 第四节查表。'
}

$extraJson = ''
if ($ctx.extraLogs) { $extraJson = ($ctx.extraLogs | ConvertTo-Json -Depth 6) }

$hint = @"
# 修复建议（第 $($ctx.round) 轮）

- 错误码：$code
- 错误消息：$msg
- 失败动作：$sysName / $actName
- 遥测日志：$($ctx.logPath)
- 当前 .robin：$($ctx.currentRobinPath)

## 判断

$codeHelp

## 外部脚本日志（extraLogs）

``````json
$extraJson
``````

## 失败动作

``````json
$($ctx.failedAction | ConvertTo-Json -Depth 6)
``````

## 下一步

1. 打开上面的 .robin，定位失败动作
2. 按 docs/script-standards.md 第四节（error.code 修复策略表）处理
3. 修好后输出到：$OutputRobin
4. 重新运行 pad-repair-loop 跑下一轮
"@
$hintPath = [IO.Path]::ChangeExtension($OutputRobin, '.hint.md')
[IO.File]::WriteAllText($hintPath, $hint, (New-Object Text.UTF8Encoding($false)))
Write-Host "[executor] 未能自动修复，修复建议已写入 $hintPath"
exit 1
