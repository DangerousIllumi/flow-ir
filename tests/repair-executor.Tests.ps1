# repair-executor.Tests.ps1 — 修复执行器规则测试（Pester 3.4，PS 5.1 自带）
#
# 覆盖规则表：
#   R1 唯一同名重定位 / 多缺失放弃 / 同名不唯一放弃 / 路径都存在时放弃
#   R2 缺失目录直接创建
#   R3 SAP 错误族提示 / 未识别错误码提示
#   协议级：错误码两级兜底（run 级为空时取 failedAction 级）、输出 .robin 保留 BOM
#
# 注意：Pester 3.4 的 $TestDrive 是整个 Describe 共享的，用例之间不自动清理，
# 因此每个 It 用 New-Work 建独立子目录，避免产物互相污染。

$script:Executor = Join-Path $PSScriptRoot '..\tools\pad-sync\repair-executor.ps1'

# 每个用例的独立工作目录
function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

# 写最小可用的修复上下文 JSON（run 级错误码可留空，走 failedAction 兜底）
function Write-Ctx([string]$Path, [string]$Code, [string]$Msg = '', [string]$SysName = '', [string]$ActCode = '') {
    $ctx = [ordered]@{
        round   = 1
        error   = @{ code = $Code; type = $Msg }
        failedAction = @{
            name             = '动作A'
            systemActionName = $SysName
            error            = @{ code = $ActCode; message = '' }
        }
        logPath          = ''
        currentRobinPath = ''
    }
    [IO.File]::WriteAllText($Path, ($ctx | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

# 在子进程里跑执行器，返回真实退出码（脚本内部用 exit，不能在同进程调）
# -PadRoot 为空时不传该参数：用于验证执行器自身的根目录解析优先级
# -RulesFile 可选：用于验证「新增错误码只改 JSON、不改脚本」
function Invoke-Executor([string]$CtxPath, [string]$InRobin, [string]$OutRobin, [string]$PadRoot = '', [string]$RulesFile = '') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Executor,
        '-ContextFile', $CtxPath, '-InputRobin', $InRobin, '-OutputRobin', $OutRobin)
    if ($PadRoot) { $argList += @('-PadRoot', $PadRoot) }
    if ($RulesFile) { $argList += @('-RulesFile', $RulesFile) }
    & powershell @argList | Out-Null
    return $LASTEXITCODE
}

# 把真实路径写成 .robin 里的双反斜杠转义形式
function To-Raw([string]$p) { return $p.Replace('\', '\\') }

# 提示文件路径：与 repair-executor 内部 ChangeExtension('.hint.md') 一致
function Hint-Of([string]$outRobin) { return [IO.Path]::ChangeExtension($outRobin, '.hint.md') }

# 写输入 .robin（默认无 BOM）
function Write-Robin([string]$Path, [string]$Text, [bool]$Bom = $false) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($Bom)))
}

Describe 'repair-executor rule tests' {

    It 'R1: a missing file with a unique same-name match under PadRoot → path rewritten and exit 0' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $missing = Join-Path $pad 'Old\target.py'   # 不存在的旧路径
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET Target TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 0
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Match ([regex]::Escape((To-Raw $real)))
        (Test-Path (Hint-Of $out)) | Should Be $false
    }

    It 'R1: a missing path with several same-name matches under PadRoot → give up and write a hint' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        New-Item -ItemType File -Path (Join-Path $pad 'A\dup.txt') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $pad 'B\dup.txt') -Force | Out-Null
        $missing = Join-Path $pad 'X\dup.txt'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET X TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 1
        (Test-Path (Hint-Of $out)) | Should Be $true
        (Test-Path $out) | Should Be $false
    }

    It 'R1: several paths missing at once → give up (cannot decide which one to rewrite)' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        New-Item -ItemType Directory -Path $pad -Force | Out-Null
        $m1 = Join-Path $pad 'a.txt'
        $m2 = Join-Path $pad 'b.txt'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET A TO '{0}'`nSET B TO '{1}'" -f (To-Raw $m1), (To-Raw $m2))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 1
        (Test-Path (Hint-Of $out)) | Should Be $true
    }

    It 'R2: a missing directory under PadRoot → created directly, .robin emitted unchanged' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        New-Item -ItemType Directory -Path $pad -Force | Out-Null
        $missingDir = Join-Path $pad 'NewSub'
        $in = Join-Path $work 'in.robin'
        # 目录路径在 .robin 里以双反斜杠结尾
        $robinText = "SET X TO '$(To-Raw $missingDir)\\'"
        Write-Robin $in $robinText
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FolderNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 0
        (Test-Path $missingDir) | Should Be $true
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Be $robinText
    }

    It 'All paths exist but FileNotFound is reported → no path rewrite, give up and write a hint' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'exists.txt'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET X TO '{0}'" -f (To-Raw $real))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 1
        (Test-Path (Hint-Of $out)) | Should Be $true
    }

    It 'R3: SAP error family → the hint contains SAP-specific advice' {
        $work = New-Work
        $in = Join-Path $work 'in.robin'
        Write-Robin $in 'SET X TO 1'
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'SAP.Gui' '' 'SapGuiScripting'

        (Invoke-Executor $ctx $in $out $work) | Should Be 1
        $hint = [IO.File]::ReadAllText((Hint-Of $out), [Text.Encoding]::UTF8)
        $hint | Should Match 'SAP'
    }

    It 'R3: unrecognized error code → the hint uses the default text' {
        $work = New-Work
        $in = Join-Path $work 'in.robin'
        Write-Robin $in 'SET X TO 1'
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'Acme.Weird'

        (Invoke-Executor $ctx $in $out $TestDrive) | Should Be 1
        $hint = [IO.File]::ReadAllText((Hint-Of $out), [Text.Encoding]::UTF8)
        $hint | Should Match 'script-standards'
    }

    It 'Two-level error code fallback: when the run-level code is empty the failedAction-level one is used (R1 still triggers)' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $missing = Join-Path $pad 'Old\target.py'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET Target TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx '' '' '' 'FileNotFound'

        (Invoke-Executor $ctx $in $out $pad) | Should Be 0
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Match ([regex]::Escape((To-Raw $real)))
    }

    It 'The output .robin preserves the input BOM: BOM in → BOM out; no BOM in → no BOM out' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $missing = Join-Path $pad 'Old\target.py'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'
        $body = "SET Target TO '{0}'" -f (To-Raw $missing)

        $inBom = Join-Path $work 'in_bom.robin'
        $outBom = Join-Path $work 'out_bom.robin'
        Write-Robin $inBom $body $true
        (Invoke-Executor $ctx $inBom $outBom $pad) | Should Be 0
        $b = [IO.File]::ReadAllBytes($outBom)
        ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should Be $true

        $inNo = Join-Path $work 'in_nobom.robin'
        $outNo = Join-Path $work 'out_nobom.robin'
        Write-Robin $inNo $body $false
        (Invoke-Executor $ctx $inNo $outNo $pad) | Should Be 0
        $b2 = [IO.File]::ReadAllBytes($outNo)
        ($b2[0] -eq 0xEF) | Should Be $false
    }

    It 'Rules as JSON: adding an error code only appends hintRules without changing the executor script' {
        $work = New-Work
        $in = Join-Path $work 'in.robin'
        Write-Robin $in 'SET X TO 1'
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'Acme.Widget'
        $rules = Join-Path $work 'rules.json'
        $custom = [ordered]@{
            version     = 1
            defaultHint = '默认提示'
            fixerRules  = @()
            hintRules   = @(@{ id = 'acme'; codePattern = '^Acme\.'; hint = '自定义规则：Acme 错误族' })
        }
        [IO.File]::WriteAllText($rules, ($custom | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

        (Invoke-Executor $ctx $in $out $work $rules) | Should Be 1
        $hint = [IO.File]::ReadAllText((Hint-Of $out), [Text.Encoding]::UTF8)
        $hint | Should Match '自定义规则：Acme 错误族'
    }

    It 'Rules as JSON: after adding fixerRules a new error code can also go through R1 relocation' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $missing = Join-Path $pad 'Old\target.py'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET Target TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        # 错误码是执行器从没见过的新值，靠规则表命中路径修复
        Write-Ctx $ctx 'Custom.PathMissing'
        $rules = Join-Path $work 'rules.json'
        $custom = [ordered]@{
            version     = 1
            defaultHint = '默认提示'
            fixerRules  = @(@{ id = 'custom-path'; codePattern = '^Custom\.'; action = 'resolve-path' })
            hintRules   = @()
        }
        [IO.File]::WriteAllText($rules, ($custom | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

        (Invoke-Executor $ctx $in $out $pad $rules) | Should Be 0
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Match ([regex]::Escape((To-Raw $real)))
    }

    It 'Without -PadRoot the search root comes from the FLOW_IR_PAD_ROOT environment variable (no longer fixed to C:\PAD)' {
        $work = New-Work
        $pad = Join-Path $work 'pad'
        $real = Join-Path $pad 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        $missing = Join-Path $pad 'Old\target.py'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET Target TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        $old = $env:FLOW_IR_PAD_ROOT
        try {
            $env:FLOW_IR_PAD_ROOT = $pad
            (Invoke-Executor $ctx $in $out) | Should Be 0
        } finally {
            if ($old) { $env:FLOW_IR_PAD_ROOT = $old }
            else { Remove-Item Env:FLOW_IR_PAD_ROOT -ErrorAction SilentlyContinue }
        }
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Match ([regex]::Escape((To-Raw $real)))
    }

    It 'An explicit -PadRoot takes precedence over the FLOW_IR_PAD_ROOT environment variable' {
        $work = New-Work
        $explicit = Join-Path $work 'explicit'
        $fromEnv = Join-Path $work 'from-env'
        # 两侧都放同名文件，改到哪个根就说明哪个来源生效
        $real = Join-Path $explicit 'Scripts\target.py'
        New-Item -ItemType File -Path $real -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $fromEnv 'Scripts\target.py') -Force | Out-Null
        $missing = Join-Path $work 'Old\target.py'
        $in = Join-Path $work 'in.robin'
        Write-Robin $in ("SET Target TO '{0}'" -f (To-Raw $missing))
        $out = Join-Path $work 'out.robin'
        $ctx = Join-Path $work 'ctx.json'
        Write-Ctx $ctx 'FileNotFound'

        $old = $env:FLOW_IR_PAD_ROOT
        try {
            $env:FLOW_IR_PAD_ROOT = $fromEnv
            (Invoke-Executor $ctx $in $out $explicit) | Should Be 0
        } finally {
            if ($old) { $env:FLOW_IR_PAD_ROOT = $old }
            else { Remove-Item Env:FLOW_IR_PAD_ROOT -ErrorAction SilentlyContinue }
        }
        ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)) | Should Match ([regex]::Escape((To-Raw $real)))
    }
}
