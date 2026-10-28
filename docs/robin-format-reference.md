# Robin 格式参考手册（v2 · 已校正）

> **权威源已变更**
> Robin 没有官方文档（robin-language.org 已于 2021 年下线）。本手册的**权威源**是：
> - `JoeG592/pad-robin-action-kb` —— 1,086 个动作的**粘贴验证** KB（`PAD_Robin_ActionKB.json`）、44 种类型参考（`PAD_Robin_TypeReference.json`）、官方提示词（`PROMPT.md`）、443 条实测语料（`rules/probe-corpus.json`）
> - 原始规则清单（23 条）：见 KB 仓库 README 的 "Syntax rules PAD enforces"
>
> 本文件只是**速查 + 常见陷阱**，不能替代 KB。生成代码时以 KB 的 template / golden_example / input_params 为准。
>
> **v1 校正说明**：v1 有若干条错误（尤其是"文件头可粘贴""FUNCTION 可粘贴""%Var% 可作动作参数""WHEN...END 表示 while"），已在文末列出并更正。**这些错误会导致整段粘贴被 PAD 静默丢弃。**

---

## 〇、最重要的一条：粘贴失败的代价

**PAD 的粘贴失败大多无声**：画布保持空白，不显示任何错误。**一行坏 → 整脚本报废。**

所以：
- 生成后**必须先静态自检**：`node check-flows.js PAD_Robin_ActionKB.json your_flow.robin`
- 再粘贴进 Designer，看错误面板

---

## 一、文件结构（`script.robin`）与**哪些内容不能粘**

社区用户从本地 `script.robin` 复制的完整结构：

```
@@ConnectionString: ''
@@Type: 'Local'
@@DisplayName: 'Computer'
IMPORT 'controlRepo.appmask' AS appmask
IMPORT 'imageRepo.imgrepo' AS imgrepo
@SENSITIVE: []
WebAutomation.LaunchEdge.AttachToEdgeByUrl TabUrl: $'''power''' AttachTimeout: 5 BrowserInstance=> Browser2
LOOP LoopIndex FROM 1 TO 4 STEP 1
 WebAutomation.GoToWebPage.GoToWebPage BrowserInstance: Browser2 Url: $'''https://example.com/page=%LoopIndex%''' WaitForPageToLoadTimeout: 30
 IF (WebAutomation.IfWebPageContains.WebPageContainsText BrowserInstance: Browser2 Text: $'''yesterday''') THEN
  MouseAndKeyboard.SendKeys.FocusAndSendKeysByInstanceOrHandle WindowInstance: Browser2 TextToSend: $'''{Control}({F})yesterday''' DelayBetweenKeystrokes: 20 SendTextAsHardwareKeys: True
  EXIT Code: 0
 END
END
```

### ⚠️ 关键：哪些**不能**粘进 Designer

| 内容 | 能否粘贴 | 说明 |
|---|---|---|
| `@@ConnectionString` / `@@Type` / `@@DisplayName` | ❌ | 文件头，粘贴会**整段被丢弃**。生成代码时**不要产出这些行** |
| `IMPORT ... AS appmask` / `@SENSITIVE: []` | ❌ | 同上 |
| `FUNCTION ... END FUNCTION` | ❌ | 子流程定义不能粘。**子流程要在 Designer 里手工创建**，再把每条子流程的正文分别粘进去 |
| `@@copilotGeneratedAction: 'False'` | ⚠️ | 仅可紧贴在某个动作之前；其他 `@@` 行一律丢弃粘贴 |
| 动作/控制流语句本身 | ✅ | 这些才是可粘的正文 |

> 因此 Agent B 的产物 = **纯正文脚本**：没有文件头、没有 FUNCTION。

---

## 二、语法元素速查（已校正）

| 元素 | 语法 | 示例 |
|---|---|---|
| 动作调用 | `Module.ActionName` 或 `Module.ActionName.Selector` | `Excel.LaunchExcel.LaunchAndOpen` |
| 命名参数 | `ParameterName: value` | `Path: $'''C:\file.xlsx'''` |
| 输出赋值 | `=> VariableName` | `Instance=> ExcelInstance` |
| 字符串（插值，最安全） | `$'''text'''` | `Message: $'''Hello %Name%'''` |
| 字符串（非插值） | `'''text'''` | `Name: '''Sheet1'''` |
| 空字符串 | `$''''''` | — |
| 变量引用（**仅字符串内**） | `%Name%` | `Url: $'''…/page=%LoopIndex%'''` |
| 变量/表达式（字符串外，**裸写**） | 直接写名字 | `Instance: ExcelInstance`、`SET Total TO Price * Qty` |
| 枚举 | `Module.EnumType.Value`（**必须带模块名**） | `Text.StandardDelimiter.NewLine` |
| 布尔 / 数字 | `True` / `False`；裸数字 | `Visible: True`、`Row: 2` |
| 注释 | `# 文本` | `# 这是注释` |
| 区域 | `**REGION Name` / `**ENDREGION` | 注意：`REGION` / `END REGION` 会丢弃粘贴 |
| 禁用某行 | `DISABLE ` 前缀 | — |
| 数据表字面量 | `{ ... }` | `InputTable: { ^['Name'], [$'''v1'''] }` |
| 条件分支 | `IF ... THEN ... ELSE ... END` | 见第四节 |
| 循环 | `LOOP ... END` | 见第四节 |
| 开关 | `SWITCH ... CASE ... DEFAULT ... END` | 见第四节 |
| 等待 | `WAIT 5` | 秒 |
| 退出 | `EXIT Code: 0` | — |

**大小写不敏感**：变量名、关键字、动作 id、枚举值、参数名在粘贴时都不区分大小写。

---

## 三、值语法硬规则（来自 KB 的实测规则，逐条都会"一行坏全废"）

1. 字符串 `$'''value'''`；布尔 `True`/`False` 裸写；数字裸写；空串 `$''''''`。
2. 变量/表达式**裸写**：`Instance: ExcelInstance`、`SET Total TO Price * Qty`、`IF Files.Count = 0 THEN`、`Items[Items.Count - 1]`、`Items[-1]`、`Row['Amount']`、`Obj.a.b`。
3. **`%...%` 只能出现在字符串内部**：`$'''Saved %Count% files'''`、`$'''Total %Price * Qty%'''`。
   写在字符串外会**整段丢弃**：`SET X TO %N + 1%`、`IF %N% = 5`、`Text: %Msg%`、`WAIT %N%` ❌
4. 枚举**必须全限定**，且值必须是该输入 `enumValues` 里列出的：`File.IfExists` 只有 `DoNothing` / `Overwrite` 两个值。
5. 输出写作 `Name=> Variable`。
6. **字符串内反斜杠是转义符**：`\'` 是一个单引号，`\\` 是一个反斜杠。**所有单引号都要写成 `\'`**：
   `$'''Joe\'s report'''`、`$'''WHERE Name = \'Joe\''''`。裸 `'` 会丢弃整段粘贴 —— 注意 SQL / XPath / JS。
   （`%...%` 表达式内部的单引号不受影响：`$'''%Row['Name']%'''` ✅）
7. **紧跟变量或结尾引号之前的反斜杠要双写**：`$'''C:\Reports\\%Month%'''`、`$'''%Root%\\%Name%'''`、`$'''C:\Temp\\'''`。
   普通字母前的单个反斜杠原样保留：`$'''%Folder%\Report.xlsx'''` ✅。**不要写 `\%`**（PAD 会丢掉百分号）。
8. **UNC 路径要四个反斜杠**：`$'''\\\\server\share'''`。写两个能粘但会被读成 `\server\share`。
9. **字面百分号写 `%%`**：`$'''100%% done'''`。单个 `%` 丢弃整段粘贴。
10. 字符串可跨多行，包括空行和以 `END`/`#`/`IF` 开头的行。
11. **PAD 关键字不能作变量名或属性名**（否则丢弃整段）：
    `From` `To` `Step` `End` `In` `Then` `If` `Else` `Loop` `Foreach` `While` `Set` `Wait` `Next` `Exit` `Label` `Goto` `Call` `Case` `Default` `Switch` `Block` `Error` `On` `Not` `And` `Or` `Mod` `True` `False` `Global` `Disable` `Function` `Throw`。
    邮件属性是常见坑：写 `Mail['From']` / `Mail['To']`，**不要** `Mail.From`；`Subject`/`Count`/`Name`/`Text`/`Value`/`Body` 是安全的。
12. 变量名**以字母开头**：`SET 1abc TO 1` 丢弃整段；Unicode 字母可以（`SET Café TO 1`）。
13. 变量必须先在流程里被 `SET`、被动作输出、被循环、或被就地列表动作（如 `Variables.AddItemToList List:`）产生，否则报"Variable 'X' doesn't exist"。
14. 一行一条语句；一行两条丢弃整段。缩进只是视觉；行尾 `# 备注` 会变成独立的注释行。
15. `CASE` 只接受比较式（`CASE = 1` / `CASE <> 3` / `CASE > 5`）；`CASE Contains ...` 丢弃整段。
16. 条件动作（kind=Condition）写成 `IF (Action ...) THEN`；**`ELSE IF (Action ...) THEN` 丢弃整段**，要写成 `ELSE` 内嵌 `IF (Action ...) THEN ... END`。
17. PAD 2.72 移除的 id 会报 "Unknown action"：裸 `Database.Connect`（要用 `Database.Connect.Connect` / `.ConnectOracle`）、裸 `Scripting.RunPythonScript`（要用 `.RunPythonScript` / `.RunPythonScript34` / `.RunPythonScriptCPython`）。

---

## 四、控制流（Robin 内建，不在 KB 的动作表里）

内置语句清单（一行一条）：

```
SET x TO value
IF condition THEN / ELSE IF condition THEN / ELSE / END
SWITCH x / CASE = 1 / CASE > 5 / DEFAULT / END
LOOP FOREACH item IN list / END
LOOP i FROM 0 TO n - 1 STEP 1 / END
LOOP WHILE (A) < (B) / END
EXIT LOOP / NEXT LOOP / LABEL Name / GOTO Name / WAIT 5 / EXIT Code: 0
```

条件运算符：`=` `<>` `>` `<` `>=` `<=`、`AND`、`OR`、`NOT(...)`，以及
`IsEmpty(x)`、`IsNotEmpty(x)`、`Contains(x, $'''y''', False)`、`NotContains`、`StartsWith`、`EndsWith`。

### IF / ELSE

```
SET NewVar TO $'''Option A'''
IF (Contains(NewVar, $'''Option A''', False) OR Contains(NewVar, $'''Option B''', False)) = True THEN
    Display.ShowMessageDialog.ShowMessage Message: $'''Yes''' Icon: Display.Icon.None Buttons: Display.Buttons.OK DefaultButton: Display.DefaultButton.Button1 IsTopMost: False
END
```

### SWITCH

```
SWITCH NewVar
    CASE = $'''Option A'''
        # ...
    CASE = $'''Option B'''
        # ...
    DEFAULT
        # ...
END
```

### LOOP FOREACH / FROM TO / WHILE

```
LOOP FOREACH CurrentItem IN ItemList
    # 处理 CurrentItem
END

LOOP LoopIndex FROM 1 TO 10 STEP 1
    # 用 %LoopIndex%
END

SET Counter TO 0
LOOP WHILE (Counter) < (10)
    SET Counter TO Counter + 1
END
```

### 错误处理

```
# 一组动作的容错
BLOCK ReadFiles
ON BLOCK ERROR
    SET Failed TO True
END
    # ... 动作 ...
END

# 单个动作的容错
Text.ToNumber Text: Raw Number=> Amount
ON ERROR REPEAT 2 TIMES WAIT 5
    SET Amount TO 0
END
```

- 错误处理器里**只允许** `SET` / `CALL` / `GOTO` / `THROW ERROR`；其他动作报 "The statement isn't allowed inside exception handling"；处理器里放 `IF` 会丢弃整段粘贴。做法：在处理器里置标志位，出块后再判断。
- `REPEAT` 只能用在动作的 `ON ERROR` 上。`ERROR => LastError` 读最近一次错误。
- 云端触发时，给"不可能报错的动作"加 `ON ERROR` 会让流程加载被拒（控制台运行不受影响）。

---

## 五、动作 id 格式与已验证样本

### 5.1 动作 id 是**选择器全限定三段式**（重要更正）

```
Module.Action.Selector
```

例如：`Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments`

- 同一个 `Module.Action` 下有**多个 selector**（KB 的 `sibling_selectors`），**每个 selector 的参数集不同**。
- 用错 selector → `Unknown argument`，或被 PAD 直接丢弃。
- 选法：**你需要哪些参数，就选列出了这些参数的那个 selector**。

> KB 里共 **1086 条动作 / 48 个模块**，全部是这种三段式。
> 写成两段（如 `Outlook.RetrieveEmailMessages`）会被 `check.js` 直接报 `unknown action`。
> 此前的 v2 手册在这点上含糊，是错误来源。

### 5.2 已验证样本（逐条取自 KB 的 `golden_example`，粘贴零错误）

### Outlook（邮件）

```
Outlook.Launch Instance=> OutlookInstance
Outlook.RetrieveEmailMessages.RetrieveEmails Instance: OutlookInstance Account: $'''test@test.com''' MailFolder: $'''example''' EmailsToRetrieve: Outlook.RetrieveMessagesMode.All MarkAsRead: True ReadBodyAsHtml: False
Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments ReadBodyAsHtml: False MarkAsRead: True MailFolder: $'''example''' ToContains: $'''example''' SubjectContains: $'''example''' SaveAttachmentsInto: $'''C:\temp''' BodyContains: $'''example''' Account: $'''example''' Instance: OutlookInstance FromContains: $'''example''' EmailsToRetrieve: Outlook.RetrieveMessagesMode.All Messages=> RetrievedEmails
Outlook.SendEmailThroughOutlook.SendEmail Instance: OutlookInstance Account: $'''test@test.com''' SendTo: $'''example''' IsBodyHtml: False IsDraft: False
Outlook.ProcessEmailMessages.MoveEmails MailFolder: $'''example''' Instance: OutlookInstance Account: $'''example''' EmailsToProcess: List
Outlook.SaveOutlookEmailMessages.SaveEmails Instance: OutlookInstance Account: $'''example''' EmailsToSave: FileList SaveFormat: Outlook.MessageType.OutlookMessageFormatUnicode SaveEmailsTo: $'''C:\temp''' MessagesFiles=> StoredMessagesFiles
Outlook.Close Instance: OutlookInstance
```

要点：
- 检索输出是 `Messages=> RetrievedEmails`（不是 `RetrievedEmails=>`）。
- 发邮件收件人参数是 **`SendTo`**（不是 `To`），HTML 开关是 **`IsBodyHtml`**（不是 `BodyIsHtml`）。
- 检索模式枚举是全限定的 `Outlook.RetrieveMessagesMode.All`（不是 `Outlook.RetrieveMode.UnreadOnly`）。
- 存附件是**独立 selector** `RetrieveEmailsAndSaveAttachments` + 参数 `SaveAttachmentsInto`；没有 `Attachments: Outlook.MailAttachments.Save` 这种写法。

### Excel

```
Excel.LaunchExcel.LaunchAndOpen Path: $'''C:\temp\test.xlsx''' Visible: True ReadOnly: False LoadAddInsAndMacros: False Instance=> ExcelInstance
Excel.ReadFromExcel.ReadAllCells FirstLineIsHeader: False GetCellContentsMode: Excel.GetCellContentsMode.TypedValues Instance: ExcelInstance RangeValue=> ExcelData
Excel.WriteToExcel.WriteCell Instance: ExcelInstance Value: $'''sample''' Column: $'''example''' Row: 1
Excel.SetColor.SetColorRangePredefined Instance: ExcelInstance EndRow: 1 StartRow: 1 StartColumn: $'''example''' ColorName: $'''example''' EndColumn: $'''example'''
Excel.CloseExcel.CloseAndSave Instance: ExcelInstance
```

要点：没有 `ReadAsText` 参数；判读模式是 `GetCellContentsMode`（枚举全限定）；读取输出是 `RangeValue`。

### Web

```
WebAutomation.LaunchChrome.LaunchChrome Url: $'''example''' WindowState: WebAutomation.BrowserWindowState.Normal ClearCache: False ClearCookies: False WaitForPageToLoadTimeout: 60 Timeout: 60 BrowserInstance=> Browser
Web.DownloadFromWeb.DownloadToFile UserAgent: $'''example''' Url: $'''example''' ConnectionTimeout: 30 AcceptUntrustedCertificates: False ClearCookies: False FilePath: $'''C:\temp\test.xlsx''' FollowRedirection: True Encoding: Web.Encoding.AutoDetect DownloadedFile=> DownloadedFile
```

> 引用录制的 UI 元素的动作（KB 中 `needs_ui_selector: true`，**114 条**）示例不能照搬运行；需在 Designer 里录制元素，再填成 `appmask['<屏幕>']['<元素>']`。

### 脚本执行（SAP / VBS / PowerShell）

```
SAP.AttachToRunning.AttachToRunningSapByActiveSession SapInstance=> SapInstance
SAP.SapLogin.SapLogInOptionSingle Password: $'''password''' Username: $'''example''' Client: $'''example''' Language: $'''example''' Description: $'''example''' SapInstance=> SapInstance OtherSapLoginTerminated=> OtherSapLoginTerminated
SAP.EndTransaction SapInstance: SapInstance
SAP.CloseSapConnection SapInstance: SapInstance CloseSapLogonOnLastConnection: True
Scripting.RunVBScript.RunVBScript VBScriptCode: $'''''' ScriptOutput=> VBScriptOutput ScriptError=> ScriptError
Scripting.RunPowershellScript.RunScript Script: $'''''' ScriptOutput=> PowershellOutput ScriptError=> ScriptError
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''C:\temp\test.xlsx''' WorkingDirectory: $'''C:\temp''' StandardOutput=> CommandOutput StandardError=> CommandErrorOutput ExitCode=> CommandExitCode
```

要点：VBS 是 `Scripting.RunVBScript.RunVBScript`（**不是** `Scripting.RunPythonScript`，KB 里无此 id）；DOS 命令是 `Scripting.RunDOSCommand.RunDOSCommand`（**不是** `System.RunDOSCommand`）。SAP 有原生动作，**不必**退回 VBS。

### 文件与变量

```
File.ReadTextFromFile.ReadText File: $'''C:\temp\test.xlsx''' Encoding: File.TextFileEncoding.UTF8 Content=> FileContents
File.WriteText File: $'''C:\temp\test.xlsx''' AppendNewLine: True IfFileExists: File.IfFileExists.Overwrite Encoding: File.FileEncoding.Unicode TextToWrite: $'''sample'''
Folder.GetFiles Folder: $'''C:\temp''' FileFilter: $'''*''' IncludeSubfolders: False FailOnAccessDenied: True SortBy1: Folder.SortBy.NoSort SortDescending1: False SortBy2: Folder.SortBy.NoSort SortDescending2: False SortBy3: Folder.SortBy.NoSort SortDescending3: False Files=> Files
Variables.CreateNewDatatable InputTable: { } DataTable=> DataTable
SET VarName TO $'''value'''
SET Counter TO 0
SET FilePath TO $'''C:\Users\Desktop\\%VarName%.xlsx'''
```

要点：编码枚举是 `File.TextFileEncoding.UTF8`（读）/ `File.FileEncoding.Unicode`（写），不是 `File.Encoding.UTF8`；写文件的 id 是 `File.WriteText`（不是 `File.WriteTextToFile.WriteText`）；路径里变量前的反斜杠要**双写**（见 5.3）。

### 5.3 字符串里的路径与变量（最容易踩的坑）

```
SET FilePath TO $'''C:\Users\Desktop\\%VarName%.xlsx'''    # 变量前双反斜杠
SET Unc     TO $'''\\\\server\share\file.xlsx'''            # UNC 四个反斜杠
SET Pct     TO $'''完成度 100%%'''                           # 字面百分号双写
SET Owner   TO $'''Joe\'s report'''                          # 单引号转义
```

---

## 六、常见句柄类型（`PAD_Robin_TypeReference.json` 摘要）

| 类型 | 写法 | 由谁产生 |
|---|---|---|
| `ExcelInstanceHandle` | 裸名 `ExcelInstance` | `Excel.LaunchExcel.LaunchAndOpen` / `Excel.Attach` |
| `WebBrowserInstanceHandle` | 裸名 `Browser` | `WebAutomation.LaunchEdge.LaunchEdge` |
| `OutlookInstanceHandle` | 裸名 `OutlookInstance` | `Outlook.Launch` |
| `SapInstanceHandle` | 裸名 `SapInstance` | `SAP.SapLogin.SapLogInOptionTerminate` |
| `List`1` | 裸名 `FileList` | `SET` / `CreateNewList` |
| `DataTable` | 裸名 `DataTable` | `CreateNewDatatable` 或动作输出 |
| `String` | `$'''…'''` | — |
| `Int32` / `Int64` / `Decimal` | 裸数字 | — |
| `Boolean` | `True` / `False` | — |
| `UIControl` / `WebControl` | `$'''selector'''`（来自录制） | 录制 UI 元素 |
| `_ENUM_RULE` | `Module.EnumType.Value` | — |

原则：**开什么就关什么**（Launch 对应 Close）；变量必须先由上游动作产生再使用。

---

## 七、粘贴前自检清单（替换 v1 的自造清单）

- [ ] 脚本**不含** `@@` 文件头、`IMPORT`、`@SENSITIVE`
- [ ] 脚本**不含** `FUNCTION ... END FUNCTION`
- [ ] `%…%` 只出现在字符串内部
- [ ] 字符串里的单引号都写成 `\'`
- [ ] 紧跟变量/结尾引号前的反斜杠已双写；UNC 用四个反斜杠
- [ ] 字面百分号写成 `%%`
- [ ] 枚举都写成 `Module.EnumType.Value`，且值在 `enumValues` 内
- [ ] 没把 PAD 关键字当变量名/属性名（邮件用 `Mail['From']`）
- [ ] 一行一语句；IF/LOOP/SWITCH 都有对应 `END`
- [ ] 每个变量都有上游来源；开闭成对
- [ ] 跑过 `node tools/pad-robin/check.js output.robin` 且 0 违规（由生成器自动执行，也可单跑）

---

## 八、从 flow.json 生成 Robin（确定性工具链）

不需要手工拼脚本了。整条链路都是确定性工具，**模型只用在 Agent A 理解需求和显式的 AI 步骤**。

| 步骤 | 命令 | 产物 |
|---|---|---|
| 设计 → 画布 | `node tools/flow-drawio/flow-to-drawio.js <flow.json> <flow.drawio>` | 可拖拽/改名的 draw.io 画布 |
| 画布 → 回读 | `node tools/flow-drawio/drawio-to-flow.js <flow.drawio> <flow.json> <new.json>` | 回读人工改动 + 变更摘要 |
| 生成脚本 | `node tools/pad-robin/flow-to-robin.js <flow.json> output.txt` | Robin 正文（并自动跑 check-flows） |
| 静态校验 | `node tools/pad-robin/check.js <output.txt \| 目录>` | 违规清单（0 = 可粘贴） |

### 生成器规则（`flow-to-robin.js`）

- **骨架来自 KB**：动作 id、参数名、参数顺序、输出名一律取该动作的 `golden_example`，只填值。
- **值来源优先级**：① flow 节点 `params` 显式给定 → ② 句柄类型（`*Handle`）自动接上游 Launch 的变量
  → ③ KB `input_params` 的 `default` → ④ 沿用 golden 占位值（并打印告警）。
- **类型格式化**：`String/FileObject/FolderObject/EncryptableObject` → `$'''…'''`；数字/布尔裸写；
  枚举裸值自动补成 `Module.EnumType.Value`（`Module` 取 actionId 首段）。
- **字符串转义**（防静默丢弃）：`\` → `\\`、`'` → `\'`、字面 `%` → `%%`。
- **引用**：`{{2.RetrievedEmails}}` → 上游节点绑定到的输出变量；`{{config.X}}` / `{{variables.X}}` → 裸变量 `X`；
  字符串里内嵌引用 → `$'''…%X%…'''`。
- **分支**：带 `branch` 的节点生成 `IF <condition> THEN`；true 支路终点若正好汇合到 false 目标，
  只生成 `IF … END`（不带 ELSE），否则生成 `IF/ELSE/END`。
- **变量初始化**：flow `variables[]` → 顶部 `SET` 行（脚本自包含，便于过静态校验；已是 PAD 输入变量可删）。
- **安全闸门**（报错并 `exit 1`，拒绝产出）：`pad_hint` 不在 KB / 参数名不在 `input_params` /
  命中 `needs_ui_selector: true` / `{{引用}}` 指向不存在的节点或输出。

> 与 PROMPT.md「模板填空器」范式完全一致：**动作骨架零改写，只填值**。
> 手工修改产物会重新引入参数名/顺序错误——要改就改 `flow.json` 再重跑。

### 端到端已验证（示例）

```
node tools/flow-drawio/flow-to-drawio.js tools/flow-drawio/example-flow.json tools/flow-drawio/example-flow.drawio
node tools/flow-drawio/drawio-to-flow.js tools/flow-drawio/example-flow.drawio tools/flow-drawio/example-flow.json /tmp/x.json
    -> 11 节点 / 11 边，回读 0 变更
node tools/pad-robin/flow-to-robin.js tools/flow-drawio/example-flow.json tools/pad-robin/samples/monthly-reconciliation.robin
    -> 静态自检: 通过（10 行动作，0 处违规）
```

---

## 九、v1 错误更正表

| v1 原文 | 问题 | 更正 |
|---|---|---|
| 在文件示例里把 `@@ConnectionString`/`IMPORT`/`@SENSITIVE` 当作可粘贴内容 | 粘贴会**整段丢弃** | 这些是 `.robin` 文件头，**不能粘**；Agent B 不产出 |
| 把 `FUNCTION ... END FUNCTION` 当可粘贴 | 粘贴会**整段丢弃** | 子流程须在 Designer 手工建，正文分别粘 |
| "变量引用用 `%VariableName%` 格式"（泛化） | 字符串外会**整段丢弃** | 字符串内用 `%Name%`；字符串外裸写变量名 |
| `WHEN Counter < 10 … END` 表示 while | 语法错误 | `LOOP WHILE (Counter) < (10) … END` |
| 未强调单引号转义 / `%%` / 反斜杠双写 / UNC 四斜杠 | 常见静默失败 | 见第三节 6–9 条 |
| "变量引用用 `%...%`" + "动作参数直接用变量名"混用 | 造成 `Text: %Msg%` 类错误 | 明确：参数里裸写 `Text: Msg` 或裸名句柄 |
| 未提枚举必须全限定 | 漏模块名即报错 | `Module.EnumType.Value` |
| 未提"一行一语句""关键字禁用" | 静默失败 | 见第三节 11、14 条 |

---

> 参考：`JoeG592/pad-robin-action-kb`（CC BY 4.0）· `jonathan-haubrich/power-automate-flows`（架构参考）· 微软官方动作参考 · Power Platform 社区
