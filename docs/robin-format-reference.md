# Robin format reference (v2 · corrected)

> **The authoritative source has changed**
> Robin has no official documentation (robin-language.org went offline in 2021). The **authoritative sources**
> for this manual are:
> - `JoeG592/pad-robin-action-kb` — a **paste-verified** KB of 1,086 actions (`PAD_Robin_ActionKB.json`), a
>   44-type reference (`PAD_Robin_TypeReference.json`), the official prompt (`PROMPT.md`), and a 443-case
>   measured corpus (`rules/probe-corpus.json`)
> - The original rule list (23 rules): see "Syntax rules PAD enforces" in the KB repository README
>
> This file is a **quick reference plus common pitfalls only** and cannot replace the KB. When generating code,
> the KB's template / golden_example / input_params are authoritative.
>
> **v1 correction note**: v1 contained several errors (notably "file headers are pasteable", "FUNCTION is
> pasteable", "%Var% can be an action parameter", "WHEN...END means while"). They are listed and corrected at the
> end of this file. **These errors make PAD silently discard the entire paste.**

---

## 0. The most important point: the cost of a failed paste

**Most PAD paste failures are silent**: the canvas stays blank and no error appears. **One bad line kills the whole script.**

So:
- After generating, **always run the static self-check first**: `node check-flows.js PAD_Robin_ActionKB.json your_flow.robin`
- Then paste into the Designer and read the error panel

---

## 1. File structure (`script.robin`) and **what must not be pasted**

The complete structure a community user copies out of a local `script.robin`:

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

### ⚠️ Key point: what must **not** be pasted into the Designer

| Content | Pasteable | Note |
|---|---|---|
| `@@ConnectionString` / `@@Type` / `@@DisplayName` | ❌ | File headers; pasting **discards the entire script**. Never emit these lines when generating |
| `IMPORT ... AS appmask` / `@SENSITIVE: []` | ❌ | Same as above |
| `FUNCTION ... END FUNCTION` | ❌ | Subflow definitions cannot be pasted. **Create subflows by hand in the Designer** and paste each subflow's body separately |
| `@@copilotGeneratedAction: 'False'` | ⚠️ | Only valid immediately before an action; every other `@@` line is discarded on paste |
| Action / control-flow statements themselves | ✅ | This is the pasteable body |

> So Agent B's output = **a body-only script**: no file header, no FUNCTION.

---

## 2. Syntax elements quick reference (corrected)

| Element | Syntax | Example |
|---|---|---|
| Action call | `Module.ActionName` or `Module.ActionName.Selector` | `Excel.LaunchExcel.LaunchAndOpen` |
| Named parameter | `ParameterName: value` | `Path: $'''C:\file.xlsx'''` |
| Output assignment | `=> VariableName` | `Instance=> ExcelInstance` |
| String (interpolated, safest) | `$'''text'''` | `Message: $'''Hello %Name%'''` |
| String (non-interpolated) | `'''text'''` | `Name: '''Sheet1'''` |
| Empty string | `$''''''` | — |
| Variable reference (**inside a string only**) | `%Name%` | `Url: $'''…/page=%LoopIndex%'''` |
| Variable / expression (outside a string, **bare**) | write the name directly | `Instance: ExcelInstance`, `SET Total TO Price * Qty` |
| Enum | `Module.EnumType.Value` (**module name required**) | `Text.StandardDelimiter.NewLine` |
| Boolean / number | `True` / `False`; bare numbers | `Visible: True`, `Row: 2` |
| Comment | `# text` | `# this is a comment` |
| Region | `**REGION Name` / `**ENDREGION` | Note: `REGION` / `END REGION` are discarded on paste |
| Disable a line | `DISABLE ` prefix | — |
| Data-table literal | `{ ... }` | `InputTable: { ^['Name'], [$'''v1'''] }` |
| Conditional branch | `IF ... THEN ... ELSE ... END` | See section 4 |
| Loop | `LOOP ... END` | See section 4 |
| Switch | `SWITCH ... CASE ... DEFAULT ... END` | See section 4 |
| Wait | `WAIT 5` | seconds |
| Exit | `EXIT Code: 0` | — |

**Case-insensitive**: variable names, keywords, action ids, enum values and parameter names are all case-insensitive on paste.

---

## 3. Hard rules for value syntax (measured KB rules, each of which "one bad line kills everything")

1. Strings are `$'''value'''`; booleans are bare `True`/`False`; numbers are bare; the empty string is `$''''''`.
2. Variables/expressions are **bare**: `Instance: ExcelInstance`, `SET Total TO Price * Qty`, `IF Files.Count = 0 THEN`, `Items[Items.Count - 1]`, `Items[-1]`, `Row['Amount']`, `Obj.a.b`.
3. **`%...%` may only appear inside a string**: `$'''Saved %Count% files'''`, `$'''Total %Price * Qty%'''`.
   Outside a string it **discards the whole script**: `SET X TO %N + 1%`, `IF %N% = 5`, `Text: %Msg%`, `WAIT %N%` ❌
4. Enums **must be fully qualified**, and the value must appear in that input's `enumValues`: `File.IfExists` has only `DoNothing` / `Overwrite`.
5. Outputs are written as `Name=> Variable`.
6. **Inside a string a backslash is an escape character**: `\'` is one apostrophe and `\\` is one backslash. **Every apostrophe must be written `\'`**:
   `$'''Joe\'s report'''`, `$'''WHERE Name = \'Joe\''''`. A bare `'` discards the whole paste — watch out in SQL / XPath / JS.
   (Apostrophes inside a `%...%` expression are unaffected: `$'''%Row['Name']%'''` ✅)
7. **A backslash immediately before a variable or before the closing quotes must be doubled**: `$'''C:\Reports\\%Month%'''`, `$'''%Root%\\%Name%'''`, `$'''C:\Temp\\'''`.
   A single backslash before an ordinary letter is kept as-is: `$'''%Folder%\Report.xlsx'''` ✅. **Never write `\%`** (PAD drops the percent sign).
8. **UNC paths need four backslashes**: `$'''\\\\<host>\<share>'''`. Two backslashes paste but are read as `\<host>\<share>`.
9. **A literal percent sign is written `%%`**: `$'''100%% done'''`. A single `%` discards the whole paste.
10. A string may span multiple lines, including blank lines and lines starting with `END`/`#`/`IF`.
11. **PAD keywords cannot be used as variable or property names** (otherwise the whole paste is discarded):
    `From` `To` `Step` `End` `In` `Then` `If` `Else` `Loop` `Foreach` `While` `Set` `Wait` `Next` `Exit` `Label` `Goto` `Call` `Case` `Default` `Switch` `Block` `Error` `On` `Not` `And` `Or` `Mod` `True` `False` `Global` `Disable` `Function` `Throw`.
    Mail properties are a common trap: write `Mail['From']` / `Mail['To']`, **never** `Mail.From`; `Subject`/`Count`/`Name`/`Text`/`Value`/`Body` are safe.
12. Variable names **start with a letter**: `SET 1abc TO 1` discards the whole paste; Unicode letters are allowed (`SET Café TO 1`).
13. A variable must first be produced in the flow by a `SET`, an action output, a loop, or an in-place list action (such as `Variables.AddItemToList List:`), otherwise PAD reports "Variable 'X' doesn't exist".
14. One statement per line; two statements on one line discards the whole script. Indentation is visual only; a trailing `# note` becomes a separate comment line.
15. `CASE` accepts comparison expressions only (`CASE = 1` / `CASE <> 3` / `CASE > 5`); `CASE Contains ...` discards the whole script.
16. Condition actions (kind=Condition) are written `IF (Action ...) THEN`; **`ELSE IF (Action ...) THEN` discards the whole script**, so write it as `ELSE` containing `IF (Action ...) THEN ... END`.
17. Ids removed in PAD 2.72 report "Unknown action": bare `Database.Connect` (use `Database.Connect.Connect` / `.ConnectOracle`) and bare `Scripting.RunPythonScript` (use `.RunPythonScript` / `.RunPythonScript34` / `.RunPythonScriptCPython`).

---

## 4. Control flow (built into Robin, not in the KB action table)

List of built-in statements (one per line):

```
SET x TO value
IF condition THEN / ELSE IF condition THEN / ELSE / END
SWITCH x / CASE = 1 / CASE > 5 / DEFAULT / END
LOOP FOREACH item IN list / END
LOOP i FROM 0 TO n - 1 STEP 1 / END
LOOP WHILE (A) < (B) / END
EXIT LOOP / NEXT LOOP / LABEL Name / GOTO Name / WAIT 5 / EXIT Code: 0
```

Conditional operators: `=` `<>` `>` `<` `>=` `<=`, `AND`, `OR`, `NOT(...)`, plus
`IsEmpty(x)`, `IsNotEmpty(x)`, `Contains(x, $'''y''', False)`, `NotContains`, `StartsWith`, `EndsWith`.

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
    # process CurrentItem
END

LOOP LoopIndex FROM 1 TO 10 STEP 1
    # use %LoopIndex%
END

SET Counter TO 0
LOOP WHILE (Counter) < (10)
    SET Counter TO Counter + 1
END
```

### Error handling

```
# fault tolerance for a group of actions
BLOCK ReadFiles
ON BLOCK ERROR
    SET Failed TO True
END
    # ... actions ...
END

# fault tolerance for a single action
Text.ToNumber Text: Raw Number=> Amount
ON ERROR REPEAT 2 TIMES WAIT 5
    SET Amount TO 0
END
```

- An error handler **may contain only** `SET` / `CALL` / `GOTO` / `THROW ERROR`; any other action reports "The statement isn't allowed inside exception handling", and an `IF` inside a handler discards the whole paste. Workaround: set a flag inside the handler and test it after the block.
- `REPEAT` is valid only on an action's `ON ERROR`. `ERROR => LastError` reads the most recent error.
- For cloud triggers, adding `ON ERROR` to "an action that cannot fail" makes the flow load be rejected (console runs are unaffected).

---

## 5. Action id format and verified samples

### 5.1 Action ids are **fully qualified three-part selectors** (important correction)

```
Module.Action.Selector
```

For example: `Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments`

- The same `Module.Action` has **several selectors** (the KB's `sibling_selectors`), and **each selector has its own parameter set**.
- The wrong selector produces `Unknown argument`, or is discarded by PAD outright.
- How to choose: **pick the selector that lists the parameters you need**.

> The KB has **1,086 actions / 48 modules**, all in this three-part form.
> Writing it in two parts (such as `Outlook.RetrieveEmailMessages`) makes `check.js` report `unknown action` directly.
> The earlier v2 manual was vague here, which is a source of errors.

### 5.2 Verified samples (each taken from the KB's `golden_example`, zero paste errors)

### Outlook (mail)

```
Outlook.Launch Instance=> OutlookInstance
Outlook.RetrieveEmailMessages.RetrieveEmails Instance: OutlookInstance Account: $'''user@example.com''' MailFolder: $'''example''' EmailsToRetrieve: Outlook.RetrieveMessagesMode.All MarkAsRead: True ReadBodyAsHtml: False
Outlook.RetrieveEmailMessages.RetrieveEmailsAndSaveAttachments ReadBodyAsHtml: False MarkAsRead: True MailFolder: $'''example''' ToContains: $'''example''' SubjectContains: $'''example''' SaveAttachmentsInto: $'''C:\temp''' BodyContains: $'''example''' Account: $'''example''' Instance: OutlookInstance FromContains: $'''example''' EmailsToRetrieve: Outlook.RetrieveMessagesMode.All Messages=> RetrievedEmails
Outlook.SendEmailThroughOutlook.SendEmail Instance: OutlookInstance Account: $'''user@example.com''' SendTo: $'''example''' IsBodyHtml: False IsDraft: False
Outlook.ProcessEmailMessages.MoveEmails MailFolder: $'''example''' Instance: OutlookInstance Account: $'''example''' EmailsToProcess: List
Outlook.SaveOutlookEmailMessages.SaveEmails Instance: OutlookInstance Account: $'''example''' EmailsToSave: FileList SaveFormat: Outlook.MessageType.OutlookMessageFormatUnicode SaveEmailsTo: $'''C:\temp''' MessagesFiles=> StoredMessagesFiles
Outlook.Close Instance: OutlookInstance
```

Key points:
- The retrieval output is `Messages=> RetrievedEmails` (not `RetrievedEmails=>`).
- The recipient parameter for sending mail is **`SendTo`** (not `To`), and the HTML switch is **`IsBodyHtml`** (not `BodyIsHtml`).
- The retrieval-mode enum is the fully qualified `Outlook.RetrieveMessagesMode.All` (not `Outlook.RetrieveMode.UnreadOnly`).
- Saving attachments is its **own selector** `RetrieveEmailsAndSaveAttachments` plus the parameter `SaveAttachmentsInto`; there is no such form as `Attachments: Outlook.MailAttachments.Save`.

### Excel

```
Excel.LaunchExcel.LaunchAndOpen Path: $'''C:\temp\test.xlsx''' Visible: True ReadOnly: False LoadAddInsAndMacros: False Instance=> ExcelInstance
Excel.ReadFromExcel.ReadAllCells FirstLineIsHeader: False GetCellContentsMode: Excel.GetCellContentsMode.TypedValues Instance: ExcelInstance RangeValue=> ExcelData
Excel.WriteToExcel.WriteCell Instance: ExcelInstance Value: $'''sample''' Column: $'''example''' Row: 1
Excel.SetColor.SetColorRangePredefined Instance: ExcelInstance EndRow: 1 StartRow: 1 StartColumn: $'''example''' ColorName: $'''example''' EndColumn: $'''example'''
Excel.CloseExcel.CloseAndSave Instance: ExcelInstance
```

Key points: there is no `ReadAsText` parameter; the reading mode is `GetCellContentsMode` (fully qualified enum); the read output is `RangeValue`.

### Web

```
WebAutomation.LaunchChrome.LaunchChrome Url: $'''example''' WindowState: WebAutomation.BrowserWindowState.Normal ClearCache: False ClearCookies: False WaitForPageToLoadTimeout: 60 Timeout: 60 BrowserInstance=> Browser
Web.DownloadFromWeb.DownloadToFile UserAgent: $'''example''' Url: $'''example''' ConnectionTimeout: 30 AcceptUntrustedCertificates: False ClearCookies: False FilePath: $'''C:\temp\test.xlsx''' FollowRedirection: True Encoding: Web.Encoding.AutoDetect DownloadedFile=> DownloadedFile
```

> Sample actions that reference recorded UI elements (marked `needs_ui_selector: true` in the KB, **114 actions**) cannot be run as copied; record the element in the Designer first, then fill in `appmask['<screen>']['<element>']`.

### Script execution (SAP / VBS / PowerShell)

```
SAP.AttachToRunning.AttachToRunningSapByActiveSession SapInstance=> SapInstance
SAP.SapLogin.SapLogInOptionSingle Password: $'''password''' Username: $'''example''' Client: $'''example''' Language: $'''example''' Description: $'''example''' SapInstance=> SapInstance OtherSapLoginTerminated=> OtherSapLoginTerminated
SAP.EndTransaction SapInstance: SapInstance
SAP.CloseSapConnection SapInstance: SapInstance CloseSapLogonOnLastConnection: True
Scripting.RunVBScript.RunVBScript VBScriptCode: $'''''' ScriptOutput=> VBScriptOutput ScriptError=> ScriptError
Scripting.RunPowershellScript.RunScript Script: $'''''' ScriptOutput=> PowershellOutput ScriptError=> ScriptError
Scripting.RunDOSCommand.RunDOSCommand DOSCommandOrApplication: $'''C:\temp\test.xlsx''' WorkingDirectory: $'''C:\temp''' StandardOutput=> CommandOutput StandardError=> CommandErrorOutput ExitCode=> CommandExitCode
```

Key points: VBS is `Scripting.RunVBScript.RunVBScript` (**not** `Scripting.RunPythonScript`, which does not exist in the KB); DOS commands are `Scripting.RunDOSCommand.RunDOSCommand` (**not** `System.RunDOSCommand`). SAP has native actions, so **there is no need** to fall back to VBS.

### Files and variables

```
File.ReadTextFromFile.ReadText File: $'''C:\temp\test.xlsx''' Encoding: File.TextFileEncoding.UTF8 Content=> FileContents
File.WriteText File: $'''C:\temp\test.xlsx''' AppendNewLine: True IfFileExists: File.IfFileExists.Overwrite Encoding: File.FileEncoding.Unicode TextToWrite: $'''sample'''
Folder.GetFiles Folder: $'''C:\temp''' FileFilter: $'''*''' IncludeSubfolders: False FailOnAccessDenied: True SortBy1: Folder.SortBy.NoSort SortDescending1: False SortBy2: Folder.SortBy.NoSort SortDescending2: False SortBy3: Folder.SortBy.NoSort SortDescending3: False Files=> Files
Variables.CreateNewDatatable InputTable: { } DataTable=> DataTable
SET VarName TO $'''value'''
SET Counter TO 0
SET FilePath TO $'''C:\Users\Desktop\\%VarName%.xlsx'''
```

Key points: the encoding enums are `File.TextFileEncoding.UTF8` (read) / `File.FileEncoding.Unicode` (write), not `File.Encoding.UTF8`; the id for writing a file is `File.WriteText` (not `File.WriteTextToFile.WriteText`); a backslash before a variable inside a path must be **doubled** (see 5.3).

### 5.3 Paths and variables inside strings (the easiest trap)

```
SET FilePath TO $'''C:\Users\Desktop\\%VarName%.xlsx'''    # double backslash before the variable
SET Unc     TO $'''\\\\<host>\<share>\file.xlsx'''        # UNC needs four backslashes
SET Pct     TO $'''completion 100%%'''                    # literal percent sign is doubled
SET Owner   TO $'''Joe\'s report'''                        # escaped apostrophe
```

---

## 6. Common handle types (summary of `PAD_Robin_TypeReference.json`)

| Type | Written as | Produced by |
|---|---|---|
| `ExcelInstanceHandle` | bare `ExcelInstance` | `Excel.LaunchExcel.LaunchAndOpen` / `Excel.Attach` |
| `WebBrowserInstanceHandle` | bare `Browser` | `WebAutomation.LaunchEdge.LaunchEdge` |
| `OutlookInstanceHandle` | bare `OutlookInstance` | `Outlook.Launch` |
| `SapInstanceHandle` | bare `SapInstance` | `SAP.SapLogin.SapLogInOptionTerminate` |
| `List`1` | bare `FileList` | `SET` / `CreateNewList` |
| `DataTable` | bare `DataTable` | `CreateNewDatatable` or an action output |
| `String` | `$'''…'''` | — |
| `Int32` / `Int64` / `Decimal` | bare number | — |
| `Boolean` | `True` / `False` | — |
| `UIControl` / `WebControl` | `$'''selector'''` (from recording) | recording a UI element |
| `_ENUM_RULE` | `Module.EnumType.Value` | — |

Principle: **close what you open** (Launch pairs with Close); a variable must be produced by an upstream action before it is used.

---

## 7. Self-check list before pasting (replaces v1's invented list)

- [ ] The script does **not** contain `@@` file headers, `IMPORT` or `@SENSITIVE`
- [ ] The script does **not** contain `FUNCTION ... END FUNCTION`
- [ ] `%…%` appears only inside strings
- [ ] Every apostrophe inside a string is written `\'`
- [ ] A backslash right before a variable or the closing quotes is doubled; UNC uses four backslashes
- [ ] Literal percent signs are written `%%`
- [ ] Every enum is written `Module.EnumType.Value` and its value is in `enumValues`
- [ ] No PAD keyword is used as a variable or property name (mail uses `Mail['From']`)
- [ ] One statement per line; every IF/LOOP/SWITCH has its matching `END`
- [ ] Every variable has an upstream source; every handle is opened and closed in pairs
- [ ] `node tools/pad-robin/check.js output.robin` was run with 0 violations (the generator runs it automatically, or you can run it standalone)

---

## 8. Generating Robin from flow.json (the deterministic toolchain)

There is no need to assemble scripts by hand any more. The whole chain is deterministic, and **the model is used
only for Agent A understanding the requirement and for explicit AI steps**.

| Step | Command | Product |
|---|---|---|
| Design → canvas | `node tools/flow-drawio/flow-to-drawio.js <flow.json> <flow.drawio>` | A draggable, renamable draw.io canvas |
| Canvas → read back | `node tools/flow-drawio/drawio-to-flow.js <flow.drawio> <flow.json> <new.json>` | Manual changes read back + change summary |
| Generate the script | `node tools/pad-robin/flow-to-robin.js <flow.json> output.txt` | The Robin body (and check-flows runs automatically) |
| Static checks | `node tools/pad-robin/check.js <output.txt \| directory>` | Violation list (0 = pasteable) |

### Generator rules (`flow-to-robin.js`)

- **The skeleton comes from the KB**: action id, parameter names, parameter order and output names are all taken from that action's `golden_example`; only values are filled in.
- **Value source precedence**: ① `params` given explicitly on the flow node → ② handle types (`*Handle`) are wired automatically to the upstream Launch variable
  → ③ the KB's `input_params` `default` → ④ keep the golden placeholder value (and print a warning).
- **Type formatting**: `String/FileObject/FolderObject/EncryptableObject` → `$'''…'''`; numbers/booleans bare;
  bare enum values are expanded automatically to `Module.EnumType.Value` (`Module` comes from the first segment of the actionId).
- **String escaping** (against silent discards): `\` → `\\`, `'` → `\'`, a literal `%` → `%%`.
- **References**: `{{2.RetrievedEmails}}` → the output variable bound by the upstream node; `{{config.X}}` / `{{variables.X}}` → the bare variable `X`;
  a reference embedded in a string → `$'''…%X%…'''`.
- **Branches**: a node with `branch` generates `IF <condition> THEN`; when the end of the true path rejoins the false target,
  only `IF … END` is generated (no ELSE), otherwise `IF/ELSE/END`.
- **Variable initialization**: flow `variables[]` → `SET` lines at the top (the script stays self-contained, which helps the static checks; delete them if they are PAD input variables).
- **Safety gates** (report an error and `exit 1`, refusing to produce): `pad_hint` not in the KB / a parameter name not in `input_params` /
  a hit on `needs_ui_selector: true` / a `{{reference}}` pointing at a node or output that does not exist.

> Fully consistent with the "template filler" paradigm in PROMPT.md: **the action skeleton is never rewritten; only values are filled in**.
> Hand-editing the product reintroduces parameter name/order errors — to change something, change `flow.json` and rerun.

### Normalized comparison (shared by publish verification and fingerprint comparison)

`tools/pad-sync/RobinText.psm1::ConvertTo-NormalizedRobin` does only the following before comparing:

1. Explicitly strip the `U+FEFF` (BOM) file header so the first line does not gain an invisible character;
2. `\"` → `"`;
3. Split into lines and `Trim()`, dropping blank lines, lines starting with `#`, metadata lines starting with `@`, and `IMPORT ` lines;
4. Drop `**REGION` / `**ENDREGION` folded-region marker lines (PAD may or may not keep them when writing to disk);
5. Join again with LF.

**Known boundary**: blank lines inside multi-line strings, indentation differences, and lines starting with `#` / `@` are absorbed by those line rules, so two definitions that really differ may be judged identical (a false pass). For now we do not write a string-aware parser and do not add `-Strict`, and accept that risk. If a real misjudgement appears: first use `compare-robin.js` to compare line by line and locate the difference, then rewrite that content into an explicitly visible form (for example use `\n` instead of a blank line inside the string); never loosen or tighten the normalization rules for it.

### Verified end to end (example)

```
node tools/flow-drawio/flow-to-drawio.js tools/flow-drawio/example-flow.json tools/flow-drawio/example-flow.drawio
node tools/flow-drawio/drawio-to-flow.js tools/flow-drawio/example-flow.drawio tools/flow-drawio/example-flow.json /tmp/x.json
    -> 11 节点 / 11 边，回读 0 变更
node tools/pad-robin/flow-to-robin.js tools/flow-drawio/example-flow.json tools/pad-robin/samples/monthly-reconciliation.robin
    -> 静态自检: 通过（10 行动作，0 处违规）
```

(the `->` lines above are tool output, quoted as emitted)

---

## 9. v1 error correction table

| v1 wording | Problem | Correction |
|---|---|---|
| Treating `@@ConnectionString`/`IMPORT`/`@SENSITIVE` in file examples as pasteable content | Pasting **discards the entire script** | These are `.robin` file headers and **must not be pasted**; Agent B does not emit them |
| Treating `FUNCTION ... END FUNCTION` as pasteable | Pasting **discards the entire script** | Subflows must be created by hand in the Designer and their bodies pasted separately |
| "Variable references use the `%VariableName%` format" (generalized) | Outside a string it **discards the entire script** | Inside a string use `%Name%`; outside a string write the bare variable name |
| `WHEN Counter < 10 … END` expressing a while loop | Syntax error | `LOOP WHILE (Counter) < (10) … END` |
| Not stressing apostrophe escaping / `%%` / doubled backslashes / UNC four backslashes | Common silent failures | See section 3, rules 6–9 |
| Mixing "variable references use `%...%`" with "action parameters take variable names directly" | Produces errors such as `Text: %Msg%` | Be explicit: inside parameters write `Text: Msg` bare, or a bare handle name |
| Not mentioning that enums must be fully qualified | A missing module name raises an error | `Module.EnumType.Value` |
| Not mentioning "one statement per line" and "keywords are forbidden" | Silent failures | See section 3, rules 11 and 14 |

---

> References: `JoeG592/pad-robin-action-kb` (CC BY 4.0) · `jonathan-haubrich/power-automate-flows` (architecture reference) · Microsoft's official action reference · the Power Platform community
