# pre-commit.ps1 — 提交边界内容门禁：只扫描「这次提交会入库的暂存区快照」
#
# 由 .githooks\pre-commit 调用；setup.ps1 会把 core.hooksPath 指到 .githooks。
# 工作区里未暂存的改动不参与扫描，避免「扫到的是工作区、提交的却是另一份内容」。
#
# 退出码：0 放行；非 0 阻断提交（内容命中 / 门禁自身出错）。

param()

$ErrorActionPreference = 'Stop'

function Write-GateInfo {
    param($Message, $Color = 'Gray')
    Write-Host "[pre-commit] $Message" -ForegroundColor $Color
}

# 1) 仓库根：钩子的工作目录不一定可靠，统一以 git 的判定为准
$repoRoot = (& git rev-parse --show-toplevel 2>$null | Select-Object -First 1)
if (-not $repoRoot) {
    Write-GateInfo '不在 Git 仓库内，跳过公开库内容门禁'
    exit 0
}
$repoRoot = $repoRoot.Trim()

$gate = Join-Path $repoRoot 'tools\publish\check-public-safe.ps1'
if (-not (Test-Path -LiteralPath $gate)) {
    Write-GateInfo "找不到扫描脚本：$gate" 'Red'
    exit 1
}

# 2) 暂存区清单：ACMR = 新增/复制/修改/重命名；删除的文件没有内容可扫
#    --no-renames 让重命名退化成「新增 + 删除」，避免只扫到一半路径
$staged = @(& git -C $repoRoot -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR --no-renames |
        Where-Object { $_ -and $_.Trim() })
if ($staged.Count -eq 0) {
    Write-GateInfo '暂存区没有待扫描的文件，放行'
    exit 0
}

# 3) business\ 正常被 .gitignore 忽略；被 git add -f 强行加入时直接阻断
$forcedBusiness = @($staged | Where-Object { $_ -eq 'business' -or $_ -like 'business/*' -or $_ -like 'business\*' })
if ($forcedBusiness.Count -gt 0) {
    Write-GateInfo '暂存区出现 business\ 下的文件（该目录绝不入库）：' 'Red'
    $forcedBusiness | ForEach-Object { Write-Host "    $_" }
    exit 1
}

# 4) 默认词表缺失时只打印提示、不改变退出码（与 CI 口径一致，否则换个 clone 就卡死所有提交）
$defaultList = Join-Path $repoRoot 'tools\publish\public-safe.denylist.json'
if (-not (Test-Path -LiteralPath $defaultList)) {
    Write-GateInfo '缺少默认词表 tools\publish\public-safe.denylist.json，内容门禁未生效（仅提示，不阻断）' 'Yellow'
    exit 0
}

$localList = Join-Path $repoRoot 'tools\publish\public-safe.denylist.local.json'
if (-not (Test-Path -LiteralPath $localList)) {
    Write-GateInfo '未找到本地词表 public-safe.denylist.local.json：仅按默认 5 条结构化规则扫描（PAD/Robot 根路径、UNC、内网主机后缀、邮箱、手机号）；业务名、流程名、普通本地路径不在覆盖范围' 'Yellow'
}

# 5) 把暂存区导出成临时目录快照：检查的是「将要提交的字节」，不是当前工作区
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('pre-commit-public-safe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$exitCode = 0
try {
    $prefix = $tmpRoot.Replace('\', '/') + '/'
    & git -C $repoRoot -c core.quotePath=false checkout-index --prefix="$prefix" -f -- @staged | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git checkout-index 导出暂存区失败' }

    # 复用扫描脚本的纯函数入口，不另抄一份匹配逻辑；不传 -DenylistFile 以自动合并本地覆盖词表
    . $gate -NoMain
    $scanFiles = @($staged | ForEach-Object { Join-Path $tmpRoot $_ })
    $result = Invoke-PublicSafeScan -Files $scanFiles -RepoRoot $repoRoot

    # 命中行固定输出「相对路径:行号:命中词」，与 check-public-safe.ps1 的口径一致
    foreach ($hit in @($result.Hits)) {
        $rel = $hit.File
        if ($rel.StartsWith($tmpRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($tmpRoot.Length).TrimStart('\', '/')
        }
        Write-Output ('{0}:{1}:{2}' -f $rel, $hit.Line, $hit.Match)
        Write-Host ("    规则 {0}（{1}）：{2}" -f $hit.RuleId, $hit.Category, $hit.Reason)
    }

    foreach ($e in @($result.Errors)) { Write-GateInfo "扫描错误：$e" 'Red' }

    if ([int]$result.ExitCode -ne 0) {
        Write-GateInfo ("公开库内容门禁未通过（命中 {0} 条）：按 文件:行号 改写为通用说法或占位符后重新暂存；不要删词、注释命中行或用 --no-verify 绕过" -f @($result.Hits).Count) 'Red'
        $exitCode = [int]$result.ExitCode
    } else {
        Write-GateInfo ("公开库内容门禁通过（扫描 {0} 个暂存文件）" -f @($result.Scanned).Count) 'Green'
    }
} catch {
    Write-GateInfo "门禁执行失败：$($_.Exception.Message)" 'Red'
    $exitCode = 1
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

exit $exitCode
