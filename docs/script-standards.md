# 项目开发规范与踩坑速查

## 零、编码原则：奥卡姆剃刀（Python / VBS / PAD / PowerShell 通用）

所有新增或修改的代码，先按下面顺序自问；没有证据支持“必须做”，就不做：

1. **只做当前需求**：不实现用户没点名、且当前结果不需要的功能。
2. **能复用不新建**：优先复用现有脚本、入口、工具、配置；一个用途不新建文件。
3. **能删不加**：能删掉的代码、分支、参数、依赖、兼容层、抽象层就删；三行重复优于过早抽象。
4. **不预设未来**：不为“以后可能有用”加 hash、依赖、迁移、开关、扩展点。
5. **改动最小**：只改必要文件与行，不顺手重构、不顺手改格式。
6. **验证最小**：用现有校验/测试；结果已有足够证据后，不重复跑搜索/测试/审查。

**例外（不得以“简洁”为由删除）**：副作用守卫（DRY_RUN/确认）、幂等、审计（manifest）、错误处理、数据正确性校验、安全边界。奥卡姆剃刀只砍“多余”，不砍“必要”。

## 一、外部脚本输出规范（RunDOSCommand hook 解析依据）

PAD 的 RunDOSCommand 调 VBS/Python 失败时，Actions.log 只记录 exitCode + stdout/stderr。
agent 要从这些文本里解析出有意义的错误，脚本必须遵循以下输出约定。

### VBScript 约定

| 项目 | 约定 |
|---|---|
| 退出码 | 由各脚本自定义，必须在 PAD 的报错弹窗里逐条列出含义（见下方实例） |
| stdout 首行 | MIGO_FAILED <原因> / MIGO_OK <简述> / MB51_FAILED <原因> / MB51_OK <行数> — hook 读首行 |
| 日志文件 | 在脚本里用 `Const RESULT_DIR = "..."` 声明目录，日志文件名写死为 `xxx_result.txt` — hook 从源码提取目录与文件名，取最新的 result 类文件 |
| 日志编码 | `OpenTextFile(..., 8, True)` 写成 UTF-16LE，hook 按 BOM 自动识别；不要混用 GBK |
| 非 Unicode SAP | 中文字符用 ChrW(&HXXXX)，避免 GBK 编码吞字 |

**现有脚本实例（以实际源码为准）**

| 脚本 | 退出码 | 日志 |
|---|---|---|
| `MIGO201_501.vbs` | 0=成功 / 1=界面元素没找到 / 2=SAP 报错 / 3=CSV 读不到 / 5=用户取消 | `%RESULT_DIR%\migo_result.txt` |
| `MB51导出.vbs` | 0=成功 / 1=界面步骤失败 / 2=保存失败 / 3=60 秒内没等到导出文件 / 4=导出文件被 Excel 占用 | `%RESULT_DIR%\saveas_result.txt`、`saveas_stop.txt`、`export_excel.log` |

### Python 约定

| 项目 | 约定 |
|---|---|
| 退出码 | 0=全一致，1=运行错，2=存在差异 |
| stdout 末行 | 固定 RECONCILE_RESULT=OK / DIFF / ERROR |
| 详细错误 | stdout 里自由输出 |

## 二、pad-deploy 变量占位符规范

测试 .robin 里用 {{VAR}} 占位符 + config.json 替换。**测试 .robin 绝对不能有真实邮箱/密码/生产路径**。

### 占位符

| 占位符 | 含义 |
|---|---|
| {{RECIPIENT}} | 报表收件人邮箱 |
| {{SAP_USER}} | SAP 登录用户 |
| {{SAP_PWD}} | SAP 密码（config.json 里存，不要进版本控制） |
| {{RESULTS_DIR}} | 输出目录 |

### 安全检查（pad-deploy.ps1 自动执行）

- 残留 {{...}} → 硬阻断（config.json 缺 key）
- 疑似硬编码邮箱 → 软警告

## 三、PAD Designer UIAutomation 关键元素

PAD Designer 必须在屏幕可见区域，操作前先 SetWindowPos 移到 (40,40)。

| 元素 | 属性 | 用途 |
|---|---|---|
| 进程名 | PAD.Designer | 查找主窗口 |
| 动作列表容器 | ClassName=FunctionView | 注入后动作行 |
| 动作行 | ControlType=ListItem（在 FunctionView 下） | 统计注入成功数 |
| 发布按钮 | AutomationId=PublishFlowButton | **核心**：注入→发布→运行 |
| 控制台 OK 按钮 | AutomationId=OKRunFlowFromProtocolHandlerButton | URL 触发后的外部确认框 |
| 机器人业务弹窗 | 不点击，只观察并记 debug 日志 | 见下方「弹窗处理」 |

### 弹窗处理（只点外部触发的确认框）

- 只有顶层窗口进程是 `PAD.Console.Host`、标题**精确等于** `Power Automate`、按钮
  `AutomationId = OKRunFlowFromProtocolHandlerButton` 时才点击；
- 同一窗口句柄只点一次；点后 2 秒复核按钮是否消失，未消失只告警，不再重复点击；
- 机器人进程里的业务弹窗（“示例流程运行完成”这类）只观察、只写 debug 日志，**绝不点击**；
- 非交互运行（无人值守）时，机器人业务弹窗稳定存在约 20 秒即判定为
  `NeedsHumanConfirm`，退出码 3，不杀进程、不代为确认。

### 简化流程（去掉保存草稿）

PAD Designer 的"发布"直接从当前画布状态发布新版本，**不需要先点保存草稿**。

```
pad-sync.ps1 流程：注入 .robin → 清空画布 → 粘贴 → 发布 → URL 触发 → 处理弹窗（只认外部触发确认框，业务弹窗转人工） → 轮询 RunDefinition.json → 读 Actions.log
```

## 四、error.code 修复策略速查表

| error.code | 常见原因 | agent 修复策略 |
|---|---|---|
| File.FileNotFoundError | 路径错/文件未生成 | 从 failedAction.inputs.file 取出路径，检查拼写或加前置 Copy 动作 |
| File.FileAlreadyExists | Excel 占用 | 等待关闭 Excel，或改成临时文件名 |
| RunDOSCommand.ExitCodeNonZero | VBS/Python 内部失败 | 读 stdout + hook 自动读外部日志 → 对照退出码和首行消息判断 |
| RunDOSCommand + VBS ExitCode=2 | SAP 界面报错 | 从 VBS 日志里找 SAP 状态栏错误文本 |
| Excel.BookNotFoundError | Excel 实例被回收 | RunApplication 勾选"嵌套在新 Excel 进程中" |

## 五、PAD 默认模式（未启用 Power Fx）踩坑

### IF 条件必须用一对 %% 包裹整个表达式

```
正确：第一个操作数填 $'''%业务类型 = "YAQY" OR 业务类型 = "YAR7"%'''
错误：$'''%业务类型% = "YAQY" OR %业务类型% = "YAR7"'''
```
后一种写法 PAD 只做变量值替换，OR/AND 在 %% 外被当纯文本比较，永远不匹配。

### 文本截取用 Action，不用 left()/right()/mid()

这些是 Power Fx 函数，默认模式下不可用。用 Get subtext Action。

### SAP 元素 ID 从 wnd[0] 开始写

PAD 的 SAPInstance 自动匹配会话前缀 /app/con[N]/ses[M]/。元素 ID 里含单个 %（如 btn%_WERKS_%）时，PAD 中需写成 %%（%% 转义表示字面 %）。

### SAP 菜单导航：SelectNavigationBarItem vs SelectMenuItem

| 操作 | 支持 | 不支持 |
|---|---|---|
| SelectNavigationBarItem | 多级菜单 清单>导出>电子表格... | 只有窗口工具栏单按钮 |
| SelectMenuItem | 窗口工具栏单按钮"保存" | 多级菜单导航（实测无效） |

### PopulateTextField 不能传空字符串

清空 SAP 输入框时填 * 代替（SAP 选择屏幕里 * 等效于空条件）。

### MIGO 动态屏幕号

MIGO 选完 ACTION 后屏幕号从 0002 变 0003/0006，子屏幕号无规律。
PAD 方案：LOOP + ON ERROR 遍历 0001-0009；**VBS 方案更优**。

### SAP 导出"另存为"对话框

- SAP 选项即使取消"显示本机 Windows 对话框"，某些场景仍弹 Windows 原生 #32770
- PAD 的 RunDOSCommand 阻塞等待会和 PowerShell 形成死锁
- **正确做法**：PAD 先 RunApplication（立即继续）启动轮询 PowerShell → 再触发 SAP 导出
- Win11 对话框控件的 ControlType 是 Pane 不是 Edit/Button，用 ClassName 筛选

### SAP 路径不能含中文

SAP 非 Unicode (MDMP) 模式下 GB2312/GBK 编码吞某些汉字（如"运"）。
路径只用英文/数字 + 下划线，或先在 Windows 建好文件夹再让 SAP 写入。

## 六、VBScript 操作 SAP 会话踩坑

| 问题 | 解决 |
|---|---|
| connection.Children(i) 全部 Nothing | 改用 For Each sess In connection.Children |
| For Each 顺序不确定 | 从 sess.Id 提取数字比较 |
| 最后匹配覆盖高优先级 | 优先级系统：menu=True(3) > txCode=目标(2) > 标题匹配(1) |
| VBS 文件中文乱码 | ChrW(&HXXXX) 拼接 |

## 七、PowerShell 中文处理

```powershell
# 正确：char 拼接
$saveCn = "$([char]0x4FDD)$([char]0x5B58)"   # 保存
$cancelCn = "$([char]0x53D6)$([char]0x6D88)"  # 取消
```

## 八、Excel 多实例

Excel.LaunchExcel 勾选"嵌套在新的 Excel 进程中"确保独立进程。

## 九、项目目录结构

```
flow-ir/
├── AGENTS.md                         ← AI 助手入口
├── docs/script-standards.md          ← 本文件
├── docs/robin-format-reference.md    ← .robin 语法参考
├── docs/agent-prompts.md             ← agent 提示词
├── docs/prompts/nl-to-flow.md        ← 可直接粘给 AI 的提示词
├── docs/governance/                  ← NOTICE / SECURITY / CONTRIBUTING
├── skills/                           ← agent 自定义技能
├── tools/
│   ├── check-env.ps1                 ← 环境检查
│   ├── pad-robin/                    ← flow.json → .robin 生成器 + 校验
│   ├── pad-sync/                     ← ⭐ 核心工具链
│   │   ├── pad-sync.ps1              ← 注入→发布→运行→收集（唯一触碰 PAD 的入口）
│   │   ├── pad-repair-loop.ps1       ← 自动修复循环（含 RunDOSCommand hook）
│   │   ├── pad-deploy.ps1            ← 生产部署（变量替换 + 用户确认）
│   │   └── confirm-deploy.ps1        ← MessageBox 弹窗辅助
│   ├── flow-drawio/                  ← flow.json ↔ .drawio 可视化
│   ├── publish/                      ← 推送前内容门禁 + 词表
│   └── workday/                       ← 工作日历判断
├── setup.ps1                         ← 首次安装
├── pad-robin-action-kb/              ← PAD Action KB（唯一事实来源）
│   ├── PAD_Robin_ActionKB.json       ← 最新版 Action KB
│   ├── PAD_Robin_TypeReference.json  ← 类型引用
│   └── rules/                        ← .robin 校验规则
├── business/                         ← 业务层（绝不入库）
│   ├── flows/                        ← 真实流程
│   ├── config/                       ← 真实配置
│   ├── docs/                         ← 运行手册与内部现状
│   ├── policy.json                   ← 生产准入策略
│   ├── tools/                        ← 业务专属脚本（如报表核对）
│   ├── tests/                        ← 业务回归用例与结构断言
│   ├── logs/ snapshots/ worklog/     ← 审计、快照、工作记录
│   └── manifest.jsonl                ← 运行/发布历史
└── README.md
```

> **日历口径**：表里没有今天 ≠ 今天休息。今天早于 `CALENDAR_MIN` 或晚于 `CALENDAR_MAX` 时，
> `workday.py` 输出 `CALENDAR_STALE=1` 且 `WORKDAY=1`；`pad-schedule` 以退出码 5 +
> `calendar-stale` 事件硬失败，不再静默跳过。只有「今天在覆盖范围内、但标记为非工作日」才正常跳过。
> 触发层上线后复用同一事件名 `calendar-stale`，不另造 `trigger-calendar-stale`。

## 十、文件编码与 PowerShell 编写规范

### 10.1 编码硬约束

| 文件类型 | 编码要求 | 违反后果 |
|---|---|---|
| `.ps1` | UTF-8 **带 BOM** | PS 5.1 按 GBK 解析中文 → 整份脚本乱码 + 语法错误 |
| `.js` | UTF-8 **无 BOM** | BOM 会破坏 `#!` shebang，报 SyntaxError |
| `.vbs` | ANSI/GBK 或 UTF-8，中文一律用 `ChrW(&HXXXX)` | 中文乱码 |
| `.robin` / `.json` | UTF-8（带不带 BOM 均可） | — |

用 Python 批量改文件时统一 `encode('utf-8-sig')`，**写完立刻校验前 3 字节是否为 `ef bb bf`**：

```powershell
Get-Content $p -Encoding Byte -TotalCount 3 | ForEach-Object { $_.ToString('x2') }
```

读文件统一用 `[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)`，不要用 `Get-Content`（默认 ANSI）。

### 10.2 PowerShell 控制流

**`try` 块内禁止用 `return` 退出脚本**。`return` 会直接终止脚本作用域，跳过 `try` 之后的输出与清理代码：

```powershell
# 错误：PAD_SYNC_RESULT 永远不会输出
try {
    if ($InjectOnly) { $ok = $true; return }

    ...运行...
}
catch { ... }
finally { Write-Output "PAD_SYNC_RESULT=$json" }   # 实际被跳过

# 正确：用 if/else 控制分支，结果输出留在最后
if ($InjectOnly) { $ok = $true }
else { ...运行... }
Write-Output "PAD_SYNC_RESULT=$json"
```

### 10.3 PAD 设计器 UI 操作

**禁止使用坐标点击**。设计器窗口可能被拖出屏幕（实测 `L=878 R=2078`），或者坐标落在工具栏其他按钮上（实测误点过“子流程”）。

| 目标 | 正确做法 |
|---|---|
| 工具栏按钮 | 先 `InvokePattern.Invoke()`；失败再按 `Name` 找内部 `Button` 子元素 |
| 画布动作选中 | `SelectionItemPattern.AddToSelection()`，不要点 |
| 键盘焦点 | 对**刚查询出来**的 `ListItem` 调 `SetFocus()`（列表虚拟化，旧句柄会失效） |
| 全选 | `Ctrl+A` 后**必须复查选中数量**，不等才允许按 `Delete` |
| 清空画布 | 全选校验通过 → `Delete` → 复查动作数为 0，否则抛错中止 |

`FunctionView` 容器本身不可聚焦（`IsKeyboardFocusable=False`），焦点必须落到具体 `ListItem`。

### 10.4 运行结果判定

设计器内运行**不写** `Console\Scripts\<guid>\Runs\<runId>\Actions.log`，那套日志只存在于云端/控制台触发。

| 信号 | 位置 |
|---|---|
| 运行总结果 | `DataCollection\<date>-RobinRobot.log` 的 `robin.execution.success` / `robin.execution.failure` |
| 错误码 | `eventData.padExceptionInfo.errorCode`（如 `File.FileNotFoundError`） |
| 动作耗时 | `durationInMilliseconds`，**只有** Outlook/SAP/UIAutomation 等模块动作有值 |
| 步骤明细 | 内置动作（SET/IF/LOOP/RunDOSCommand）不写遥测，拿不到 |
| 变量值 | 遥测里没有，只能靠流程自己输出或设计器变量面板 |

判定成功必须**同时检查** `success` 和 `failure` 两个事件——只看 `robin.execution.start` 会把失败误判为成功。

### 10.5 双目录同步

工作区有两份副本（开发目录 / 迁移目标目录），任何脚本改动后必须同步并校验：

```powershell
(Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash
```

### 10.6 打补丁前先读文件

用字符串替换改代码前**必须先 `Read` 确认现状**。本次出现 3 次重复插入事故（参数重复、`-InjectOnly` 重复、`GetFileName` 早已删除却再次替换匹配失败），根因都是凭记忆改文件。

### 10.7 判断运行是否真正开始

不要用“有没有窗口”推断进程状态。`PAD.RobotV2` 是**无窗口**进程，它在运行中；只有 `PAD.Designer` 才有窗口。判断顺序：

1. `PAD.RobotV2` 出现 → 开始执行
2. `PAD.RobotV2` 消失 → 执行结束
3. 状态栏从 `状态: 正在运行…` 回到 `状态: 就绪`
4. 最后以 `RobinRobot.log` 的 run 级事件为准

### 10.8 计划任务不得弹出终端窗口

计划任务动作统一用 `wscript.exe //nologo "tools\pad-sync\run-hidden.vbs" "powershell.exe" ...`，
禁止直接写 `powershell.exe`。`wscript.exe` 是 GUI 子系统程序，`WScript.Shell.Run(cmd, 0, True)`
从创建起就隐藏控制台，不会闪黑框；同时能把子进程退出码回传给计划任务。

不要为了隐藏窗口把任务改成“不管用户是否登录都运行”：本项目的 PAD 流程需要交互桌面，
落到 session 0 后 UI 自动化会失效。

## 十一、修复闭环接口（executor 协议）

`pad-repair-loop.ps1` 内置可插拔执行器通道，把「运行失败 → 修代码 → 再运行」串成闭环。

### 11.1 三条运行模式

| 用法 | 行为 |
|---|---|
| 默认 | 每一轮失败后复制 current.robin 到下一轮，**不做任何修复**（用于观察） |
| `-SingleRound` | 跑一轮，落盘 `repair_ctx_N.json` 后**停住**，等 agent/人改 |
| `-Executor <脚本>` | 每轮失败后调用执行器修 `.robin`，修完**自动进下一轮**，直到成功或达到 `-MaxRound` |

### 11.2 执行器接口

```
<Executor> -ContextFile <repair_ctx_N.json> -InputRobin <current.robin> -OutputRobin <round_N.robin>
```

| 退出码 | 含义 | 循环行为 |
|---|---|---|
| 0 | 已产出 OutputRobin | 校验 `.robin` 非空后进下一轮 |
| 1 | 放弃修复 | 停止循环，`executorAborted = true` |

执行器返回 0 但没产出文件、或产物自检失败，同样停止。

### 11.3 上下文结构（repair_ctx_N.json）

| 字段 | 内容 |
|---|---|
| `round` | 轮次 |
| `failedAction` | 失败动作（本地运行只有 run 级错误，`name` 可能为 null） |
| `error.code` / `error.type` | 错误码与类型，如 `File.FileNotFoundError` / `User` |
| `actions` | 遥测事件列表 |
| `logPath` | `RobinRobot.log` 路径 |
| `currentRobinPath` / `nextRobinPath` | 输入与期望输出 |
| `extraLogs` | RunDOSCommand 失败时附带的 VBS/Python 日志 |

### 11.4 内置规则版执行器

`tools/pad-sync/repair-executor.ps1`：

- **规则 1**：`FileNotFound*` → 从 `.robin` 提取缺失的绝对路径，在 `C:\PAD` 下找同名文件，**唯一命中才替换**，否则放弃
- **规则 2**：`SAP.*` → 不自动改（屏幕号随事务码变化，必须人工复核）
- 其他 → 写 `<output>.hint.md` 后 exit 1

### 11.5 接 agent / LLM

执行器可以是任意程序（`.ps1` / `.exe` / `node` / `python`），只要遵守上面的参数与退出码。把 LLM 调用包成脚本即可：

```
pad-repair-loop.ps1 -Executor tools/pad-sync/repair-executor-llm.ps1 -MaxRound 3
```

LLM 版执行器内部流程：读 ctx → 拼提示词（含 `.robin` 全文 + `error.code` + `extraLogs`）→ 调模型 → 取出修改后的 `.robin` → 写 OutputRobin → exit 0。

**安全约束**：执行器产物会先经过 `Test-RobinSyntax` 自检，且循环默认限制 `-MaxRound 3`、默认只允许 `PAD_SYNC_TEST`。

## 十二、运行时配置（PadConfig）

`tools/pad-sync/PadConfig.psm1` 提供 `Get-PadRuntimeConfig -ConfigPath <json>`，启动时一次性读取并逐字段校验；
显式命令行参数优先级最高，只有未显式给出的项才从配置取。**不存在「读不到就退回硬编码默认值」**。

| 字段 | 类型 | 说明 |
|---|---|---|
| `PadSyncPath` | string | `pad-sync.ps1` 的完整路径 |
| `PythonExe` | string | Python 解释器路径 |
| `CalendarPath` | string | 工作日历 `.xlsx` 路径 |
| `WorkdayScript` | string | `workday.py` 路径 |
| `RunTimeoutSec` | 正整数 | 等待流程自身运行结束的超时秒数 |
| `PadRoot` | string | 结果目录根（PAD 根目录） |

示例（中性占位，真实配置放 `business/config/runtime.json`，不入库）：

```json
{
  "PadSyncPath": "C:\\example\\tools\\pad-sync\\pad-sync.ps1",
  "PythonExe": "C:\\example\\python\\python.exe",
  "CalendarPath": "C:\\example\\calendar.xlsx",
  "WorkdayScript": "C:\\example\\tools\\workday\\workday.py",
  "RunTimeoutSec": 4200,
  "PadRoot": "C:\\example\\results"
}
```

错误码（硬失败，不降级为 warn）：

| 码 | 触发条件 |
|---|---|
| `CONFIG_MISSING` | 必填字段缺失或为空 |
| `CONFIG_PATH_NOT_FOUND` | 配置文件本身或任一字段路径不存在 |
| `CONFIG_INVALID_VALUE` | JSON 非法，或 `RunTimeoutSec` 非正整数 |

`pad-schedule.ps1`：传 `-ConfigPath` 时按上述规则加载；不传且缺关键参数时直接报 `CONFIG_MISSING` 退出，
不再回退到内置路径（现有计划任务显式传参，属兼容路径，仍然可跑；新任务推荐用配置文件）。

