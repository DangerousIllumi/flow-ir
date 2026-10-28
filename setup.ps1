<#
.SYNOPSIS
    Workflow Graphics Engineering - 本地框架安装脚本
.DESCRIPTION
    1. 检查 Node.js / Git 环境
    2. 克隆 pad-robin-action-kb（Agent B 的知识库）
    3. 验证 check-flows.js 自检可用
    4. 创建工程目录结构
.PARAMETER SkipDrawIO
    跳过 next-ai-draw-io 安装（默认跳过，需要画流程图时再装）
.EXAMPLE
    .\setup.ps1
    .\setup.ps1 -SkipDrawIO:$false
.NOTES
    运行前请先运行 .\scripts\check-env.ps1 确认环境就绪
#>

param(
    [switch]$SkipDrawIO = $true
)

$ErrorActionPreference = "Stop"
$WorkDir = $PSScriptRoot
$KBDir = Join-Path $WorkDir "pad-robin-action-kb"
$KBRepo = "https://github.com/JoeG592/pad-robin-action-kb.git"

function Write-Step { param($msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok   { param($msg) Write-Host "    [OK]   $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "    [INFO] $msg" -ForegroundColor Gray }
function Write-Warn { param($msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }

# ── 1. 环境预检 ──────────────────────────────────────────────
Write-Step "1/4 检查运行环境"

$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
    Write-Fail "未检测到 Node.js，请先安装（https://nodejs.org/）"
    exit 1
}
$nodeVer = & node -v
$major = [int]($nodeVer -replace 'v','' -split '\.')[0]
if ($major -lt 18) {
    Write-Fail "Node.js 版本过低（$nodeVer < v18），请升级"
    exit 1
}
Write-Ok "Node.js $nodeVer"

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    Write-Fail "未检测到 Git，请先安装（https://git-scm.com/download/win）"
    exit 1
}
Write-Ok "Git $(& git --version)"

# 安装 Node 依赖（流程图 ELK 布局）
if (Test-Path (Join-Path $WorkDir "package.json")) {
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($npm) {
        Write-Info "安装 Node 依赖（elkjs）"
        Push-Location $WorkDir
        & npm install --no-audit --no-fund
        $npmExit = $LASTEXITCODE
        Pop-Location
        if ($npmExit -eq 0) {
            Write-Ok "Node 依赖安装完成"
        } else {
            Write-Warn "npm install 失败，流程图生成需手动执行 npm install"
        }
    } else {
        Write-Warn "未检测到 npm，流程图 ELK 布局不可用；其余功能不受影响"
    }
}

# ── 2. 克隆 KB ───────────────────────────────────────────────
Write-Step "2/4 克隆 pad-robin-action-kb（Agent B 知识库）"

if (Test-Path $KBDir) {
    Write-Info "目录已存在，执行 git pull 更新"
    Push-Location $KBDir
    & git pull --ff-only
    Pop-Location
} else {
    Write-Info "正在克隆 $KBRepo"
    & git clone --depth 1 $KBRepo $KBDir
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "克隆失败，请检查网络或 GitHub 可达性"
        Write-Info "也可手动下载 ZIP 解压到 $KBDir"
        exit 1
    }
}

# 验证关键文件存在
$kbFile     = Join-Path $KBDir "PAD_Robin_ActionKB.json"
$typeFile   = Join-Path $KBDir "PAD_Robin_TypeReference.json"
$promptFile = Join-Path $KBDir "PROMPT.md"
$rulesFile  = Join-Path $KBDir "rules\robin-rules.json"
$checkFlows = Join-Path $KBDir "marketing\video\tools\check-flows.js"

foreach ($f in @($kbFile, $typeFile, $promptFile, $rulesFile, $checkFlows)) {
    if (Test-Path $f) {
        $rel = $f.Replace("$KBDir\", "")
        Write-Ok "已获取：$rel"
    } else {
        Write-Fail "缺少关键文件：$f"
        exit 1
    }
}

# 打印 KB 统计信息（让用户知道这是什么版本）
$kb = Get-Content $kbFile -Raw | ConvertFrom-Json
Write-Info "KB 版本 $($kb.version)，PAD build $($kb.pad_build)，$(($kb.actions).Count) 个动作，$((Get-Member -InputObject $kb.modules -MemberType NoteProperty).Count) 个模块"
Write-Info "规则文件：$((Get-Content $rulesFile -Raw | ConvertFrom-Json).rules.Count) 条，验证日期 $((Get-Content $rulesFile -Raw | ConvertFrom-Json).date)"

# ── 3. 验证 check-flows.js ───────────────────────────────────
Write-Step "3/4 验证 check-flows.js 自检器可用"

$okFlow   = Join-Path $env:TEMP "wfg-smoke-ok.robin"
$badFlow  = Join-Path $env:TEMP "wfg-smoke-bad.robin"

# 合法脚本（退出码应为 0）
@'
SET Counter TO 0
LOOP WHILE (Counter) < (3)
    SET Counter TO Counter + 1
END
'@ | Set-Content -Path $okFlow -Encoding UTF8

# 非法脚本：用保留关键字 Mail.From 当变量名（check-flows 应报错）
@'
SET Mail.From TO "x@y.com"
'@ | Set-Content -Path $badFlow -Encoding UTF8

Push-Location $KBDir
$okOutput  = & node "marketing\video\tools\check-flows.js" PAD_Robin_ActionKB.json $okFlow  2>&1
$okExit    = $LASTEXITCODE
$badOutput = & node "marketing\video\tools\check-flows.js" PAD_Robin_ActionKB.json $badFlow 2>&1
$badExit   = $LASTEXITCODE
Pop-Location

Remove-Item $okFlow, $badFlow -ErrorAction SilentlyContinue

if ($okExit -eq 0 -and $badExit -ne 0) {
    Write-Ok "双重冒烟测试通过"
    Write-Info "合法脚本：$okOutput"
    Write-Info "非法脚本：$badOutput"
} else {
    Write-Warn "check-flows.js 行为可疑（合法=$okExit / 非法=$badExit），但不影响安装"
    Write-Info "合法脚本输出：$okOutput"
    Write-Info "非法脚本输出：$badOutput"
}

# ── 4. 创建工程目录结构 ──────────────────────────────────────
Write-Step "4/4 创建工程目录结构"

$dirs = @("flows", "outputs", "docs")
foreach ($d in $dirs) {
    $path = Join-Path $WorkDir $d
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
        Write-Ok "创建目录：$d"
    } else {
        Write-Info "目录已存在：$d"
    }
}

# 说明：docs\ 下的框架文档随本包一起分发，安装脚本不再重复复制，
# 避免根目录与 docs\ 出现两份同名文档（改一处读另一处的坑）。

# ── 完成 ─────────────────────────────────────────────────────
Write-Host "`n"
Write-Host "========================================" -ForegroundColor Green
Write-Host "  框架安装完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "目录结构：" -ForegroundColor Cyan
Write-Host "  $WorkDir\"
Write-Host "  ├── pad-robin-action-kb\   Agent B 知识库（动作 + 类型 + 校验器）"
Write-Host "  ├── scripts\               环境检查脚本"
Write-Host "  ├── docs\                  框架文档（Agent 提示词 + Robin 手册）"
Write-Host "  ├── flows\                 你设计的流程定义（flow.json）"
Write-Host "  └── outputs\               Agent B 生成的 Robin 脚本"
Write-Host ""
Write-Host "下一步：" -ForegroundColor Yellow
Write-Host "  1. 用编辑器或 AI 编程助手打开本文件夹"
Write-Host "  2. 参考 docs\agent-prompts.md 配置 Agent A（设计器）和 Agent B（代码生成器）"
Write-Host "  3. 设计流程后，Agent B 生成 output.txt，复制到 PAD 画布粘贴"
Write-Host ""
if ($SkipDrawIO) {
    Write-Host "提示：如需可拖拽编辑的流程图，运行：" -ForegroundColor Gray
    Write-Host "  .\setup.ps1 -SkipDrawIO:`$false" -ForegroundColor Gray
}
Write-Host ""
