# PadFingerprint.psm1 — 流程指纹：Workspace 修订定位、身份解析、基线读写与比对
#
# 为什么单独成模块：
#   1) 「精确到修订、禁止取最新」的 Workspace 定位与身份解析必须是唯一实现；
#      pad-release.ps1（发布后写基线）、pad-rollback.ps1（回滚后重写基线）、
#      pad-fingerprint.ps1（存量流播种）、pad-admit.ps1（准入第 12 项）都从这里取，
#      避免出现第二套哈希/定位实现。
#   2) 对所有 flow.json 一视同仁：本模块不含任何「只对某条流程生效」的分支。
#
# 分层边界：
#   机制（定位、哈希、比对）在公开层；
#   基线数据写在 business\fingerprints\<流程名>.json（含流程名、flowGuid、
#   environmentId、机器名与真实路径），只在业务层，不入库、不推公开库。

# 规范化与哈希的唯一实现（RobinText.psm1）：本模块不另写一份规范化规则
Import-Module (Join-Path $PSScriptRoot 'RobinText.psm1') -Force

# 模块所在的仓库根：本模块位于 tools\pad-sync，退两级即仓库根
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# 指纹 v3 收录的脚本清单（相对仓库根，统一用正斜杠）
# 收录依据是「流程实际引用」而不是目录扫描：
#   - flow.json 直接引用 MB51导出.vbs / MIGO201_501.vbs / reconcile.py；
#   - MB51 导出链路依赖 handle_saveas_dialog_v7_final.ps1 / close_excel_window.ps1，
#     收信链路依赖 读取msg.vbs；
#   - reconcile.py 的 workday 从仓库根 tools\workday\workday.py 导入（见其文件头 sys.path 候选），
#     不是 business 下的副本；
#   - reconcile.py 的 Excel 读取（表头定位、日期/数值转换、整表读取）从
#     tools\xlsx\xlsx_io.py 导入，同属流程实际引用的通用脚本。
$script:DefaultScriptPaths = @(
    'business/scripts/MB51导出.vbs'
    'business/scripts/MIGO201_501.vbs'
    'business/scripts/handle_saveas_dialog_v7_final.ps1'
    'business/scripts/close_excel_window.ps1'
    'business/scripts/读取msg.vbs'
    'business/tools/reconcile/reconcile.py'
    'tools/workday/workday.py'
    'tools/xlsx/xlsx_io.py'
)

# 指纹 v3 的 external 段：仓库外的旧拷贝（只能用绝对路径锁），播种时由调用方显式传入。
# 公共代码不写死具体业务路径；路径只落进 business\ 下的基线文件。
# 单开一段而不是混进 scripts：这些文件不在仓库里、路径与本机环境绑定，
# 混在一起会让人误以为键都能在仓库内找到。
# 注意：外部旧拷贝与 business\scripts 同名文件本就因路径常量（PS1_PATH / CLOSE_PS1_PATH /
# 日志路径等）不同而哈希不同，属预期差异；纳入哈希只能发现「某一侧被单独改动」，
# 不能判断两侧语义是否等价。

# 从 Actions.log 路径解析流程 GUID 与 runId：
#   ...\Console\Scripts\<flowGuid>\Runs\<runId>\Actions.log
function Get-FlowGuidFromLogPath([string]$LogPath) {
    $m = [regex]::Match($LogPath, 'Scripts\\([0-9a-fA-F-]{36})\\Runs\\([0-9a-fA-F-]{36})\\')
    if (-not $m.Success) { return $null }
    return [ordered]@{ flowGuid = $m.Groups[1].Value.ToLower(); runId = $m.Groups[2].Value }
}

# 在本地运行历史里找该流程最近一次运行的定义信息（按 startTime 取最新）
# 返回：flowGuid / flowVersion（云端版本 ETag）/ startTime / status / path；找不到返回 $null
# 注意：这里只用于「按流程名解析身份」，不用于定位要比对的定义副本；
#       定义副本一律走 Find-WorkspaceRobin 的精确修订规则。
function Find-LatestFlowRun([string]$ScriptsRoot, [string]$FlowName) {
    if (-not $ScriptsRoot -or -not (Test-Path $ScriptsRoot)) { return $null }
    $best = $null
    $files = Get-ChildItem -LiteralPath $ScriptsRoot -Recurse -Filter 'RunDefinition.json' -ErrorAction SilentlyContinue
    foreach ($rd in $files) {
        try { $j = [IO.File]::ReadAllText($rd.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not $j.workflow -or $j.workflow.name -ne $FlowName) { continue }
        if (-not $j.startTime) { continue }
        if (-not $best -or ([string]$j.startTime) -gt ([string]$best.startTime)) {
            $best = [ordered]@{
                flowGuid    = [string]$j.workflow.workflowId
                flowVersion = $(if ($j.diagnosticInfo) { [string]$j.diagnosticInfo.flowVersion } else { $null })
                startTime   = [string]$j.startTime
                status      = [string]$j.status
                path        = $rd.FullName
            }
        }
    }
    return $best
}

# 已发布流程的本地定义副本：Console\Workspace\<flowGuid>\<修订目录>\script.robin
# 精确匹配本次发布/运行的修订，绝不退化成「取最新一份」（同机并发时会拿别人的定义来比对）：
#   1) 修订目录名等于本次 runId 时直接采用（与 PadDesigner 的运行目录同一口径）；
#   2) 否则只认「本次发布之后写入」的修订；命中多个视为无法确定并报错。
function Find-WorkspaceRobin([string]$WorkspaceRoot, [string]$FlowGuid, [string]$RunId, [datetime]$SinceUtc) {
    if (-not $WorkspaceRoot -or -not $FlowGuid) { return $null }
    $dir = Join-Path $WorkspaceRoot $FlowGuid
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $all = @(Get-ChildItem -LiteralPath $dir -Recurse -Filter 'script.robin' -ErrorAction SilentlyContinue)
    $hit = @($all | Where-Object {
        ($RunId -and $_.Directory.Name -eq $RunId) -or
        ($_.LastWriteTime.ToUniversalTime() -ge $SinceUtc.AddMinutes(-2))
    })
    if ($hit.Count -gt 1) {
        throw ("Workspace 里有 $($hit.Count) 个候选修订，无法确定本次发布对应哪一份：" +
            (($hit | ForEach-Object { $_.Directory.Name }) -join '、'))
    }
    if ($hit.Count -eq 1) { return $hit[0].FullName }
    return $null
}

# 从 PAD 控制台配置读取当前环境 ID（console.config 的 UserConfigs 里首个 EnvironmentId）
# 读不到返回 $null：基线里记 null，准入时不比较环境，避免臆造身份
function Get-PadEnvironmentId([string]$ConsoleConfigPath) {
    if (-not $ConsoleConfigPath) {
        $ConsoleConfigPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\console.config'
    }
    if (-not (Test-Path -LiteralPath $ConsoleConfigPath)) { return $null }
    try {
        $j = [IO.File]::ReadAllText($ConsoleConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $j.UserConfigs.PSObject.Properties) {
            if ($p.Value -and $p.Value.EnvironmentId) { return [string]$p.Value.EnvironmentId }
        }
    } catch { return $null }
    return $null
}

# 三份文件的 SHA256（小写）。缺失的文件记 null，调用方据此判「读不到」
function Get-FingerprintParts([string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath) {
    $parts = [ordered]@{ robin = $null; config = $null; acceptance = $null }
    foreach ($pair in @(@('robin', $RobinPath), @('config', $ConfigPath), @('acceptance', $AcceptancePath))) {
        if ($pair[1] -and (Test-Path -LiteralPath $pair[1])) {
            $parts[$pair[0]] = (Get-FileHash -LiteralPath $pair[1] -Algorithm SHA256).Hash.ToLower()
        }
    }
    return $parts
}

# 指纹 v3 的 scripts 段：逐文件算原始字节 SHA256，键是相对仓库路径（正斜杠），值是哈希。
# 文件缺失记 null，由比对侧判「当前缺失」，不在计算阶段抛异常（准入要一次报全）。
function Get-ScriptFingerprintParts {
    param(
        [string]$RepoRoot,
        [string[]]$Paths
    )
    if (-not $RepoRoot) { $RepoRoot = $script:RepoRoot }
    $list = @($Paths)
    if ($list.Count -eq 0) { $list = @($script:DefaultScriptPaths) }
    $parts = [ordered]@{}
    foreach ($rel in $list) {
        if (-not $rel) { continue }
        # 统一成正斜杠再拼本机路径：基线里的键与平台无关，便于跨机器读
        $key = ([string]$rel).Replace('\', '/')
        $full = Join-Path $RepoRoot ($key.Replace('/', '\'))
        if (Test-Path -LiteralPath $full) {
            $parts[$key] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
        } else {
            $parts[$key] = $null
        }
    }
    return $parts
}

# 指纹 v3 的 external 段：逐个绝对路径算原始字节 SHA256，键保留绝对路径（正斜杠）。
# 文件缺失同样记 null，由比对侧判「当前缺失」。
function Get-ExternalScriptFingerprintParts {
    param([string[]]$Paths)
    $list = @($Paths)
    $parts = [ordered]@{}
    foreach ($p in $list) {
        if (-not $p) { continue }
        $full = [string]$p
        $key = $full.Replace('\', '/')
        if (Test-Path -LiteralPath $full) {
            $parts[$key] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
        } else {
            $parts[$key] = $null
        }
    }
    return $parts
}

# 比对基线里的 scripts 段与当前脚本文件，返回 status/code/message/evidence。
# 观察期只报 warn 不阻断：旧基线没有 scripts 段属于「还没播种」而不是被篡改，
# 一律 warn（SCRIPT_FINGERPRINT_LEGACY），绝不因为缺段就判 fail。
function Test-ScriptFingerprint {
    param(
        [string]$BaselinePath,
        [string]$RepoRoot,
        [string[]]$Paths
    )
    if (-not $RepoRoot) { $RepoRoot = $script:RepoRoot }
    $read = Read-FingerprintBaseline $BaselinePath
    if (-not $read.ok) {
        return [ordered]@{
            status = 'warn'; code = $read.code
            message = "$($read.message)，无法核对脚本指纹：$BaselinePath"
            evidence = @("baseline=$BaselinePath")
        }
    }
    $base = $read.data
    $props = @($base.PSObject.Properties.Name)
    $hasScripts = ($props -contains 'scripts') -and $base.scripts
    if (-not $hasScripts) {
        # 向后兼容：v2 及更早基线没有 scripts 段，按 warn 提示重新播种
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_LEGACY'
            message = '基线缺少 scripts 段（v3 之前的旧基线），请重新播种后再核对脚本指纹'
            evidence = @("baseline=$BaselinePath")
        }
    }
    $hasExternal = ($props -contains 'external') -and $base.external
    if (-not $hasExternal) {
        # 已播种 v3 但还没收录 PAD 旧拷贝的基线：同样按 legacy 提示重播，不判 fail
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_LEGACY'
            message = '基线缺少 external 段（PAD 旧拷贝未收录），请重新播种后再核对脚本指纹'
            evidence = @("baseline=$BaselinePath")
        }
    }

    $expected = $base.scripts
    $expectedKeys = @($expected.PSObject.Properties.Name)
    $keys = @($Paths)
    if ($keys.Count -eq 0) { $keys = $expectedKeys }
    $keys = @($keys | Where-Object { $_ } | ForEach-Object { ([string]$_).Replace('\', '/') })
    $now = Get-ScriptFingerprintParts -RepoRoot $RepoRoot -Paths $keys

    # external 段按基线里的绝对路径键逐项核对（不看 -Paths，避免和仓库相对路径混淆）
    $expectedExternal = $base.external
    $extKeys = @($expectedExternal.PSObject.Properties.Name)
    $nowExt = Get-ExternalScriptFingerprintParts -Paths $extKeys

    $bad = @()
    foreach ($k in $keys) {
        $was = $null
        if ($expectedKeys -contains $k) { $was = [string]$expected.$k }
        $cur = [string]$now[$k]
        if (-not $was) {
            $bad += "$k 基线未记录"
        } elseif (-not $cur) {
            $bad += "$k 当前缺失（基线 $($was.Substring(0, 12))）"
        } elseif ($cur -ne $was) {
            $bad += "$k 基线 $($was.Substring(0, 12)) 当前 $($cur.Substring(0, 12))"
        }
    }
    foreach ($k in $extKeys) {
        $was = [string]$expectedExternal.$k
        $cur = [string]$nowExt[$k]
        if (-not $was) {
            $bad += "$k 基线未记录"
        } elseif (-not $cur) {
            $bad += "$k 当前缺失（基线 $($was.Substring(0, 12))）"
        } elseif ($cur -ne $was) {
            $bad += "$k 基线 $($was.Substring(0, 12)) 当前 $($cur.Substring(0, 12))"
        }
    }
    $total = $keys.Count + $extKeys.Count
    if ($bad.Count -gt 0) {
        return [ordered]@{
            status = 'warn'; code = 'SCRIPT_FINGERPRINT_MISMATCH'
            message = ("$($bad.Count)/$total 个脚本哈希与基线不一致（观察期只提醒，不阻断）")
            evidence = $bad
        }
    }
    return [ordered]@{
        status = 'pass'; code = 'OK'
        message = "$($keys.Count) 个仓库脚本 + $($extKeys.Count) 个 PAD 旧拷贝哈希与基线一致"
        evidence = @("baseline=$BaselinePath")
    }
}

# .robin 的规范化哈希（逻辑哈希）：剥掉注释/元数据/缩进与转义差异后再算 SHA256。
# 源文件与已发布副本的原始字节必然不同（PAD 会加 @@ 头、IMPORT 行、重写转义），
# 只有逻辑哈希才能安全地跨"落盘格式"比较。
function Get-RobinLogicHash([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return (Get-RobinHash $text)
}

# 由 ScriptsRoot 推 Workspace 根：两者都在 ...\Power Automate Desktop\Console\ 下
function Get-WorkspaceRootFromScriptsRoot([string]$ScriptsRoot) {
    if (-not $ScriptsRoot) { return $null }
    $consoleRoot = Split-Path -Parent $ScriptsRoot
    if (-not $consoleRoot) { return $null }
    $root = Join-Path $consoleRoot 'Workspace'
    if (Test-Path -LiteralPath $root) { return $root }
    return $null
}

# 基线文件位置：business\fingerprints\<流程名>.json（业务层，不入库）
function Get-FingerprintBaselinePath([string]$RepoRoot, [string]$FlowName) {
    return (Join-Path (Join-Path (Join-Path $RepoRoot 'business') 'fingerprints') ($FlowName + '.json'))
}

# 读基线。不抛异常：返回 ok/code/message，由调用方决定按 warn 还是 fail
function Read-FingerprintBaseline([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_NO_BASELINE'; message = '没有指纹基线'; data = $null }
    }
    try {
        $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "基线无法解析：$($_.Exception.Message)"; data = $null }
    }
    foreach ($k in @('flow', 'hashes')) {
        if ($j.PSObject.Properties.Name -notcontains $k) {
            return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = "基线缺少字段 $k"; data = $null }
        }
    }
    if ($j.hashes.PSObject.Properties.Name -notcontains 'robin' -or -not $j.hashes.robin) {
        return [ordered]@{ ok = $false; code = 'FINGERPRINT_BASELINE_CORRUPT'; message = '基线缺少 robin 哈希'; data = $null }
    }
    return [ordered]@{ ok = $true; code = $null; message = '基线可读'; data = $j }
}

# 写基线：先写临时文件再原子替换，避免半份 JSON
function Write-FingerprintBaseline([string]$Path, $Baseline) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllText($tmp, ($Baseline | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $Path
}

# 构造一份基线记录（哈希与修改时间都在这里算，避免调用方各写一份）
function New-FingerprintBaseline {
    param(
        [string]$FlowName, [string]$FlowGuid, [string]$EnvironmentId,
        [string]$SourceRobin, [string]$WorkspaceRobin,
        [string]$ConfigPath, [string]$AcceptancePath, [string]$Machine,
        # 仓库外旧拷贝的绝对路径清单；由 CLI 显式传入，公共模块不写死业务路径
        [string[]]$ExternalPaths
    )
    $parts = Get-FingerprintParts $SourceRobin $ConfigPath $AcceptancePath
    # v3 新增：流程实际引用的脚本文件（相对仓库路径 + 原始字节 SHA256）
    $scripts = Get-ScriptFingerprintParts -RepoRoot $script:RepoRoot
    # v3 新增：仓库外旧拷贝（绝对路径 + 原始字节 SHA256）
    $external = Get-ExternalScriptFingerprintParts -Paths $ExternalPaths
    $mtime = $null
    $deployedRaw = $null
    if ($WorkspaceRobin -and (Test-Path -LiteralPath $WorkspaceRobin)) {
        $mtime = (Get-Item -LiteralPath $WorkspaceRobin).LastWriteTime.ToString('o')
        $deployedRaw = (Get-FileHash -LiteralPath $WorkspaceRobin -Algorithm SHA256).Hash.ToLower()
    }
    return [ordered]@{
        version       = 3
        flow          = $FlowName
        flowGuid      = $FlowGuid
        environmentId = $EnvironmentId
        machine       = $(if ($Machine) { $Machine } else { $env:COMPUTERNAME })
        # 源：仓库里的 .robin（原始字节 + 逻辑哈希），config/acceptance 同源
        source        = [ordered]@{
            robinPath      = $SourceRobin
            robinSha256    = $parts.robin
            robinLogicHash = (Get-RobinLogicHash $SourceRobin)
            configSha256   = $parts.config
            acceptanceSha256 = $parts.acceptance
        }
        # 已发布：Workspace 副本（原始字节 + 逻辑哈希），只允许在这个域内自比
        deployed      = [ordered]@{
            robinPath   = $WorkspaceRobin
            robinSha256 = $deployedRaw
            logicHash   = (Get-RobinLogicHash $WorkspaceRobin)
            workspaceMtime = $mtime
        }
        # 兼容旧读取方：robin 仍指源 .robin 的原始字节哈希，别再往里塞已发布哈希
        hashes        = $parts
        # v3：脚本清单（相对仓库路径 -> sha256）；观察期仅告警，不参与 .robin 的严格比对
        scripts       = $scripts
        # v3：PAD 运行目录下的旧拷贝（绝对路径 -> sha256）；与 scripts 分开存放
        external      = $external
        seededAt      = [datetime]::UtcNow.ToString('o')
    }
}

# 比对当前文件与基线/批准记录，返回统一结果：
#   status = pass / warn / fail；code + message + evidence
# 默认 Mode=fail：基线已播种并核对无误，指纹不一致即按 fail 处理；
# 需要观察期或临时降级时显式传 -Mode warn
function Test-FlowFingerprint {
    param(
        [string]$FlowName,
        [string]$RobinPath, [string]$ConfigPath, [string]$AcceptancePath,
        [string]$BaselinePath,
        [string]$ScriptsRoot,
        [string]$EnvironmentId, [string]$Machine,
        [string]$ApprovePath,
        # 部署产物路径（占位符替换后的 .robin）；不传时按「源文件名.deployed.robin」自动派生
        [string]$DeployedRobinPath,
        [ValidateSet('warn', 'fail')][string]$Mode = 'fail'
    )
    if (-not $Machine) { $Machine = $env:COMPUTERNAME }
    $parts = Get-FingerprintParts $RobinPath $ConfigPath $AcceptancePath
    $nonPass = $(if ($Mode -eq 'fail') { 'fail' } else { 'warn' })
    $fpLine = (@('robin', 'config', 'acceptance') | Where-Object { $parts[$_] } |
        ForEach-Object { "$_=$($parts[$_].Substring(0, 12))" }) -join ' '

    # 读不到 robin：连「这份流程是什么」都无法证明
    if (-not $parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = "读不到 .robin，无法计算指纹：$RobinPath"
            evidence = @("robin=$RobinPath")
        }
    }

    # 1) 有批准记录：先按批准记录绑定（这条是硬约束，始终 fail）
    if ($ApprovePath -and (Test-Path -LiteralPath $ApprovePath)) {
        $ok = $false
        foreach ($l in [IO.File]::ReadAllLines($ApprovePath, [Text.Encoding]::UTF8)) {
            if (-not $l.Trim()) { continue }
            try { $rec = $l | ConvertFrom-Json } catch { continue }
            if ([string]$rec.robin -eq [string]$parts.robin -and
                [string]$rec.config -eq [string]$parts.config -and
                [string]$rec.acceptance -eq [string]$parts.acceptance) { $ok = $true; break }
        }
        if ($ok) {
            return [ordered]@{ status = 'pass'; code = 'OK'; message = "与批准记录一致：$fpLine"; evidence = @($ApprovePath) }
        }
        return [ordered]@{
            status = 'fail'; code = 'FINGERPRINT_MISMATCH'
            message = "与批准记录不一致：$fpLine"
            evidence = @("approve=$ApprovePath")
        }
    }

    # 2) 没有基线：存量流还没播种，按 warn（后续单独切 fail）
    $read = Read-FingerprintBaseline $BaselinePath
    if (-not $read.ok) {
        return [ordered]@{
            status = $nonPass; code = $read.code
            message = "$($read.message)：$BaselinePath"
            evidence = @("baseline=$BaselinePath", "now=$fpLine")
        }
    }
    $base = $read.data
    # 新基线把哈希分成 source / deployed 两个域；旧基线只有 hashes（源哈希）与已发布路径。
    $srcBase = $null
    if ($base.PSObject.Properties.Name -contains 'source' -and $base.source) { $srcBase = $base.source }
    $depBase = $null
    if ($base.PSObject.Properties.Name -contains 'deployed' -and $base.deployed) { $depBase = $base.deployed }

    $baseSource = [string]$(if ($srcBase -and $srcBase.robinSha256) { $srcBase.robinSha256 } else { $base.hashes.robin })
    $baseShort = if ($baseSource.Length -gt 12) { $baseSource.Substring(0, 12) } else { $baseSource }
    $ev = @("baseline=$BaselinePath", "now=$fpLine", "baselined=$baseShort")

    # 3) 身份：必须用基线里记录的 PAD 显示名去找本地运行历史。
    #    入参 $FlowName 通常来自 flow.json 的文件名（如 demo-flow），与 PAD 里注册的显示名
    #    可能完全不同；用文件名去找会让每条流程都永远 UNKNOWN。
    $displayName = [string]$base.flow
    if (-not $displayName) { $displayName = $FlowName }
    if ($ScriptsRoot) {
        $run = Find-LatestFlowRun $ScriptsRoot $displayName
        $searched = $displayName
        if (-not $run -and $displayName -ne $FlowName) {
            # 兜底：极少数旧基线把业务名写进了 flow 字段
            $run = Find-LatestFlowRun $ScriptsRoot $FlowName
            $searched = "$displayName（兜底 $FlowName）"
        }
        if (-not $run) {
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
                message = "本地运行历史里找不到流程 $displayName，无法解析身份"
                evidence = @("scriptsRoot=$ScriptsRoot", "searched=$searched")
            }
        }
        if ($base.flowGuid -and [string]$base.flowGuid -ne [string]$run.flowGuid) {
            $ev += "flowGuid 基线=$($base.flowGuid) 当前=$($run.flowGuid)"
            return [ordered]@{
                status = $nonPass; code = 'FINGERPRINT_FLOW_STALE'
                message = '基线对应的流程 GUID 已变化（流程被重建或换了目标）'
                evidence = $ev
            }
        }
    }
    if ($base.environmentId -and $EnvironmentId -and [string]$base.environmentId -ne [string]$EnvironmentId) {
        $ev += "environmentId 基线=$($base.environmentId) 当前=$EnvironmentId"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = '基线与当前 PAD 环境不一致'
            evidence = $ev
        }
    }
    if ($base.machine -and [string]$base.machine -ne [string]$Machine) {
        $ev += "machine 基线=$($base.machine) 当前=$Machine"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = '基线与当前机器不一致'
            evidence = $ev
        }
    }

    # 4) 向后兼容：旧基线没有 deployed 段，无法证明已发布副本一致 → 不许当 pass
    if (-not $depBase -or -not $depBase.logicHash) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = '基线缺少已发布哈希，请重新播种（source/deployed 拆分后的新格式）'
            evidence = $ev
        }
    }

    # 5) 源对源：仓库 .robin 只与基线里的源哈希比（原始字节）
    if ($baseSource -ne [string]$parts.robin) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_SOURCE_MISMATCH'
            message = '源 .robin 与基线不一致（流程定义有改动，需要重新发布或重新播种）'
            evidence = $ev
        }
    }
    $baseConfig = [string]$(if ($srcBase -and $srcBase.configSha256) { $srcBase.configSha256 } else { $base.hashes.config })
    if ($baseConfig -and $baseConfig -ne [string]$parts.config) {
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_CONFIG_STALE'
            message = '部署配置与基线不一致（变量替换结果会变）'
            evidence = $ev
        }
    }

    # 6) 已发布侧只跟部署产物比：源是含 {{VAR}} 占位符的模板，规范化后天然不可能等于
    #    替换后的发布副本。这里改比「部署产物」，仍然只比规范化哈希，不跨域比原始字节。
    if (-not $DeployedRobinPath) {
        # 自动派生：与源 .robin 同目录的 <源文件名去扩展名>.deployed.robin
        $srcLeaf = [IO.Path]::GetFileNameWithoutExtension($RobinPath) + '.deployed.robin'
        $srcDir = [IO.Path]::GetDirectoryName($RobinPath)
        $DeployedRobinPath = Join-Path $srcDir $srcLeaf
    }
    $depLeaf = [IO.Path]::GetFileName($DeployedRobinPath)
    if (-not (Test-Path -LiteralPath $DeployedRobinPath)) {
        $ev += "deployed=$DeployedRobinPath"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_UNKNOWN'
            message = "找不到部署产物，请先生成 $depLeaf"
            evidence = $ev
        }
    }
    $nowLogic = Get-RobinLogicHash $DeployedRobinPath
    if ($nowLogic -ne [string]$depBase.logicHash) {
        $ev += "deployed=$DeployedRobinPath"
        return [ordered]@{
            status = $nonPass; code = 'FINGERPRINT_DEPLOYED_MISMATCH'
            message = '部署产物与已发布副本逻辑不一致（发布副本已过期或被改过）'
            evidence = $ev
        }
    }

    # 原始字节不同是常态（源是模板、PAD 落盘还会追加 @@ 头），只记录不判失败
    $note = '（源是模板，含占位符，与部署产物原始字节不同属正常）'
    $ev += "deployed=$DeployedRobinPath"
    $depRaw = (Get-FileHash -LiteralPath $DeployedRobinPath -Algorithm SHA256).Hash.ToLower()
    if ([string]$depBase.robinSha256 -and $depRaw -ne [string]$depBase.robinSha256) {
        $note += '（部署产物与已发布副本原始字节不同，规范化后一致）'
        $ev += "deployedRaw=$($depRaw.Substring(0,12)) workspaceRaw=$([string]$depBase.robinSha256.ToString().Substring(0,12))"
    }
    return [ordered]@{
        status = 'pass'; code = 'OK'
        message = "与基线一致：$fpLine$note"
        evidence = (@($BaselinePath) + $ev)
    }
}

Export-ModuleMember -Function Get-FlowGuidFromLogPath, Find-LatestFlowRun, Find-WorkspaceRobin,
    Get-PadEnvironmentId, Get-FingerprintParts, Get-FingerprintBaselinePath,
    Get-RobinLogicHash, Get-WorkspaceRootFromScriptsRoot,
    Get-ScriptFingerprintParts, Get-ExternalScriptFingerprintParts, Test-ScriptFingerprint,
    Read-FingerprintBaseline, Write-FingerprintBaseline, New-FingerprintBaseline, Test-FlowFingerprint
