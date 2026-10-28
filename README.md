# Workflow Graphics Engineering

用自然语言设计流程 → Agent 生成可粘贴到 Power Automate Desktop 的 Robin 脚本。

## 架构

```
用户自然语言
    │
    ▼
Agent A（流程设计器）──生成──▶ flow.json + 流程图
    │                              │
    │                         人工评审/修改
    │                              │
    ▼                              ▼
Agent B（代码生成器）──查表填空──▶ output.txt（Robin 脚本）
                                   │
                                   ▼
                          复制 → PAD 画布 Ctrl+V 粘贴
```

## 前置条件

| 组件 | 版本 | 用途 | 下载 |
|---|---|---|---|
| Node.js | ≥ 18 | 运行 check-flows.js 校验器 | https://nodejs.org/ |
| Git | 任意 | 克隆知识库 | https://git-scm.com/download/win |
| Power Automate Desktop | 最新 | 执行 Robin 脚本 | Microsoft Store 搜索 |

## 依赖关系

| 依赖 | 必需 | 用途 | 获取方式 |
|---|---|---|---|
| Node.js ≥ 18 | 是 | 生成器、静态校验、流程图、评估集 | nodejs.org |
| Git | 是 | 克隆动作知识库 | git-scm.com |
| Power Automate Desktop | 是（要跑 PAD 时） | 执行 Robin 脚本 | Microsoft Store |
| `pad-robin-action-kb` | 是 | 动作 Schema（生成器精确查表） | `setup.ps1` 自动 clone；MIT 第三方，**不入库** |
| Python 3.x + openpyxl | 否 | 工作日历判断（`tools/workday`）、调度 | python.org |
| AI 编程助手（任意） | 否 | 把自然语言需求写成 `flow.json` | 自备；本仓库只提供提示词与 Skill，不含模型 |

> 说明：`flow.json → .robin` 这一段是确定性的，不需要模型；「需求 → flow.json」这一段依赖 AI 助手或人工，
> 本仓库只提供契约（schema、`pad_hint` 必须存在于 KB）与尺子（`tests/eval`）。

## 快速开始

```powershell
.\setup.ps1                  # 安装依赖 + 克隆动作知识库 + 建目录
.\scripts\check-env.ps1      # 环境体检（PAD / Python / SAP / Outlook / 目录）
```

设计一个流程后，按顺序跑：

```powershell
node tools\flow-drawio\flow-to-drawio.js flows\<name>.json flows\<name>.drawio   # 生成可评审画布
node tools\pad-robin\flow-to-robin.js flows\<name>.json output.robin             # 生成 Robin 脚本
node tools\pad-robin\check.js output.robin                                       # 静态校验
.\tools\pad-sync\pad-admit.ps1 -FlowFile flows\<name>.json -ConfigFile config\<name>.json   # 准入检查（只读）
```

配置从示例复制，填入你自己的账号与路径（示例文件不含任何真实凭据）：

```powershell
Copy-Item config\sample.example.json config\<name>.json
```

许可：MIT，见 [LICENSE](LICENSE)；第三方组件与不随仓库分发的内容见 [NOTICE](NOTICE)。

## 安装步骤

### 第 1 步：把本文件夹复制到本地

将本目录（`deploy-package`）内的**所有内容**复制到：

```
C:\Workflow Graphics Engineering\
```

复制后根目录应该有：`setup.ps1`、`README.md`、`HANDOVER.md`、`scripts\`、`docs\`。

> 文档只放在 `docs\` 一处（`agent-prompts.md`、`robin-format-reference.md`），根目录**不要**再放同名副本，否则会改一处、读另一处。

### 第 2 步：检查环境

在 `C:\Workflow Graphics Engineering` 文件夹空白处，**按住 Shift + 右键** → 选"在此处打开 PowerShell 窗口"。

运行：

```powershell
.\scripts\check-env.ps1
```

如果有 [FAIL] 项，先装好缺失组件再继续。装完可能需要**关闭并重开 PowerShell** 让 PATH 生效。

### 第 3 步：安装框架

```powershell
.\setup.ps1
```

脚本会：
1. 检查 Node.js / Git
2. 克隆 `pad-robin-action-kb`（Agent B 的知识库，约 37MB）
3. 验证 `check-flows.js` 可用
4. 安装 Node 依赖 `elkjs`（流程图 ELK 布局用）
5. 创建工程目录

看到 `框架安装完成！` 即成功。

### 第 4 步（可选）：安装可拖拽流程图工具 next-ai-draw-io

```powershell
.\setup.ps1 -SkipDrawIO:$false
```

> 不装也行，流程图可用 Mermaid 文本代替；只是不能拖拽编辑。

## 目录结构

```
C:\Workflow Graphics Engineering\
├── setup.ps1                    安装脚本
├── README.md                    本说明
├── HANDOVER.md                  会话交接 / 恢复清单（新会话 AI 先读）
├── scripts\
│   └── check-env.ps1            环境检查
├── docs\                        框架文档（唯一归属地）
│   ├── agent-prompts.md             Agent A/B 的完整提示词
│   └── robin-format-reference.md    Robin 语法速查
├── pad-robin-action-kb\         Agent B 知识库（setup.ps1 克隆）
│   ├── PAD_Robin_ActionKB.json      1,086 个动作的粘贴验证模板
│   ├── PAD_Robin_TypeReference.json 44 种参数类型写法
│   ├── PROMPT.md                    Agent B 系统提示词
│   ├── rules\robin-rules.json       24 条实测规则
│   └── marketing\video\tools\check-flows.js   粘贴前自检器
├── flows\                       你设计的流程定义（flow.json）
└── outputs\                     Agent B 生成的 Robin 脚本
```

## 使用流程

### 1. 配置 Agent

用任意支持本地提示词的 AI 编程助手打开 `C:\Workflow Graphics Engineering`，参考 `docs\agent-prompts.md`：
- 创建 Agent A「流程设计器」，粘贴其系统提示词
- 创建 Agent B「代码生成器」，粘贴其系统提示词

### 2. 设计流程（Agent A）

对 Agent A 说你的需求，例如：
> 每月3号从邮箱读取带对账单附件的邮件，提取发票号和金额，跟SAP核对，不一致的做成Excel发邮件给经理

Agent A 会生成 `flows\你的流程名\flow.json` + 流程图。

在 draw.io（或 Mermaid）中评审、拖拽调整。改完保存，告诉 Agent A「调整完成」。

### 3. 生成代码（Agent B）

对 Agent B 说：
> 读取 flows/xxx/flow.json，生成 PAD 代码

Agent B 会：
- 从 `pad-robin-action-kb` 查表填空
- 用 `check-flows.js` 自检
- 输出到 `outputs\xxx.txt`

### 4. 粘贴到 PAD

1. 记事本打开 `outputs\xxx.txt`
2. 全选 → 复制
3. 在 PAD 新建流程 → 画布上 `Ctrl+V`
4. 检查有无报错，填写占位参数（如邮箱地址、文件路径）
5. 运行

## 常见问题

**Q: 粘贴后画布空白，没报错？**
A: 说明脚本里有语法错误被 PAD 静默丢弃了。运行检查器：
```powershell
node pad-robin-action-kb\marketing\video\tools\check-flows.js pad-robin-action-kb\PAD_Robin_ActionKB.json outputs\xxx.txt
```
合法输出 `OK  ... 0 errors`（退出码 0）；非法输出 `BAD ... M errors  line X: ...`（退出码 1）。

**Q: git clone 失败？**
A: 可能网络问题。手动到 https://github.com/JoeG592/pad-robin-action-kb 下载 ZIP，解压到 `pad-robin-action-kb\` 目录。

**Q: PowerShell 提示「无法加载文件，因为在此系统上禁止运行脚本」？**
A: 以管理员身份打开 PowerShell，运行：
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```
然后重开 PowerShell。

## 参考资料

- Agent 提示词：`docs\agent-prompts.md`
- Robin 语法手册：`docs\robin-format-reference.md`
- PAD 知识库：`pad-robin-action-kb\`
- 流程图工具：https://github.com/DayuanJiang/next-ai-draw-io
