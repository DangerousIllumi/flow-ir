# Project development standards and pitfall quick reference

## 0. Coding principle: Occam's razor (applies to Python / VBS / PAD / PowerShell)

For any new or modified code, ask the questions below in order first; without evidence that something "must be
done", do not do it:

1. **Do only what the current requirement needs**: do not implement features the user did not name and the current result does not require.
2. **Reuse instead of creating**: prefer existing scripts, entry points, tools and configuration; one purpose does not justify a new file.
3. **Delete instead of adding**: delete code, branches, parameters, dependencies, compatibility layers and abstractions that can be removed; three repeated lines beat a premature abstraction.
4. **Do not design for the future**: do not add hashes, dependencies, migrations, switches or extension points for "might be useful later".
5. **Minimal change**: change only the necessary files and lines; no incidental refactoring or reformatting.
6. **Minimal verification**: use the existing checks and tests; once the evidence is sufficient, do not rerun searches/tests/reviews.

**Exceptions (which "simplicity" may never delete)**: side-effect guards (DRY_RUN/confirmation), idempotency,
audit (manifest), error handling, data-correctness checks and security boundaries. Occam's razor cuts "superfluous",
never "necessary".

Side-effect nodes must answer two orthogonal questions, mapped to two fields in `flow.json`:
- `idempotent`: does a rerun with the same input converge (rerun safety); when `false`, write `idempotency_note`;
- `reversible`: can the consequences already produced be withdrawn; when `false`, write `reversibility_note` (it must state the revert path).
Saving attachments, exporting files, reconciliation files and marking as read are reversible; sending mail and posting documents are not.

## 1. External script output conventions (what the RunDOSCommand hook parses)

When a RunDOSCommand in PAD calls VBS/Python and it fails, Actions.log records only exitCode + stdout/stderr.
For an agent to extract a meaningful error from that text, scripts must follow these output conventions.

### VBScript conventions

| Item | Convention |
|---|---|
| Exit code | Defined by each script, and every value's meaning must be listed in PAD's error dialog (see the examples below) |
| First stdout line | POST_FAILED <reason> / POST_OK <summary> / EXPORT_FAILED <reason> / EXPORT_OK <line count> — the hook reads the first line |
| Log file | Declare the directory in the script as `Const RESULT_DIR = "..."` and hard-code log names as `xxx_result.txt` — the hook extracts the directory and filename from the source and takes the newest result-type file |
| Log encoding | `OpenTextFile(..., 8, True)` writes UTF-16LE, and the hook detects it by BOM; never mix in GBK |
| Non-Unicode SAP | Write non-ASCII characters with ChrW(&HXXXX) so GBK encoding does not swallow them |

**Existing script examples (the actual source is authoritative)**

| Script | Exit codes | Logs |
|---|---|---|
| `sap-posting.vbs` | 0=success / 1=UI element not found / 2=SAP error / 3=CSV unreadable / 5=user cancelled | `%RESULT_DIR%\posting_result.txt` |
| `sap-export.vbs` | 0=success / 1=interface step failed / 2=save failed / 3=no export file within 60 seconds / 4=export file locked by Excel | `%RESULT_DIR%\saveas_result.txt`, `saveas_stop.txt`, `export_excel.log` |

### Python conventions

| Item | Convention |
|---|---|
| Exit code | 0=all match, 1=run error, 2=differences exist |
| Last stdout line | Fixed `RECONCILE_RESULT=OK / DIFF / ERROR` |
| Detailed errors | Free-form on stdout |

## 2. pad-deploy variable placeholder conventions

The test `.robin` uses `{{VAR}}` placeholders replaced from config.json. **A test `.robin` must never contain a
real mailbox, password or production path.**

### Placeholders

| Placeholder | Meaning |
|---|---|
| {{RECIPIENT}} | Report recipient mailbox |
| {{SAP_USER}} | SAP login user |
| {{SAP_PWD}} | SAP password (stored in config.json; never under version control) |
| {{RESULTS_DIR}} | Output directory |

### Safety checks (run automatically by pad-deploy.ps1)

- A leftover `{{...}}` → hard block (config.json is missing a key)
- A suspected hard-coded mailbox → soft warning

## 3. PAD Designer UIAutomation key elements

The PAD Designer must be in a visible area of the screen; move it to (40,40) with SetWindowPos before operating.

| Element | Attribute | Purpose |
|---|---|---|
| Process name | PAD.Designer | Find the main window |
| Action list container | ClassName=FunctionView | Action rows after injection |
| Action row | ControlType=ListItem (under FunctionView) | Count successful injections |
| Publish button | AutomationId=PublishFlowButton | **Core**: inject → publish → run |
| Console OK button | AutomationId=OKRunFlowFromProtocolHandlerButton | The external confirmation dialog after a URL trigger |
| Robot business popup | Do not click; observe and log debug output | See "Popup handling" below |

### Popup handling (click only the externally triggered confirmation dialog)

- Click only when the top-level window's process is `PAD.Console.Host`, the title **exactly equals** `Power Automate`,
  and the button's `AutomationId = OKRunFlowFromProtocolHandlerButton`;
- Click each window handle once; re-check 2 seconds later whether the button disappeared, and if it did not, only
  warn and never click again;
- Business popups in the robot process (such as a "sample flow run complete" message) are observed and logged at
  debug level only and **never clicked**;
- In non-interactive (unattended) runs, a robot business popup that stays on screen for about 20 seconds means
  `NeedsHumanConfirm`, exit code 3, without killing the process and without confirming on the user's behalf.

### Simplified flow (no draft save)

PAD Designer's "publish" publishes a new version straight from the current canvas state, so **there is no need to
save a draft first**.

```
pad-sync.ps1 flow: inject .robin -> clear canvas -> paste -> publish -> URL trigger -> handle popups (only the external trigger dialog; business popups go to a human) -> poll RunDefinition.json -> read Actions.log
```

## 4. error.code repair strategy quick reference

| error.code | Common cause | Agent repair strategy |
|---|---|---|
| File.FileNotFoundError | Wrong path / file not produced | Take the path from failedAction.inputs.file, check the spelling, or add a preceding Copy action |
| File.FileAlreadyExists | Excel holds the file | Wait for Excel to close, or switch to a temporary filename |
| RunDOSCommand.ExitCodeNonZero | Internal VBS/Python failure | Read stdout + the external log the hook reads automatically → judge from the exit code and first line |
| RunDOSCommand + VBS ExitCode=2 | SAP UI error | Find the SAP status-bar error text in the VBS log |
| Excel.BookNotFoundError | Excel instance collected | Tick "nested in a new Excel process" on RunApplication |

## 5. PAD default mode pitfalls (Power Fx not enabled)

### An IF condition must wrap the whole expression in one pair of %%

```
Correct: the first operand holds $'''%business type = "YAQY" OR business type = "YAR7"%'''
Wrong:   $'''%business type% = "YAQY" OR %business type% = "YAR7"'''
```

The second form makes PAD substitute variable values only; OR/AND outside %% are compared as plain text and never match.

### Use the Action for text extraction, not left()/right()/mid()

Those are Power Fx functions and are unavailable in default mode. Use the Get subtext Action.

### SAP element ids start at wnd[0]

PAD's SAPInstance matches the session prefix `/app/con[N]/ses[M]/` automatically. When an element id contains a
single % (such as btn%_WERKS_%), write it as %% in PAD (%% escapes to a literal %).

### SAP menu navigation: SelectNavigationBarItem vs SelectMenuItem

| Operation | Supported | Not supported |
|---|---|---|
| SelectNavigationBarItem | Multi-level menus: list > export > spreadsheet... | Only a single window toolbar button |
| SelectMenuItem | A single window toolbar button such as "Save" | Multi-level menu navigation (measured ineffective) |

### PopulateTextField cannot take an empty string

When clearing a SAP input field, fill in `*` instead (in SAP selection screens `*` is equivalent to an empty condition).

### Dynamic screen numbers after a transaction code

After choosing ACTION in a SAP transaction code, the screen number changes from 0002 to 0003/0006, and sub-screen
numbers follow no pattern. PAD approach: LOOP + ON ERROR over 0001-0009; **the VBS approach is better**.

### SAP export "save as" dialog

- Even with "show local Windows dialogs" disabled in SAP options, some scenarios still raise the native Windows #32770 dialog
- PAD's RunDOSCommand blocks waiting and deadlocks with PowerShell
- **Correct approach**: PAD starts the polling PowerShell with RunApplication first (which returns immediately), then triggers the SAP export
- On Windows 11 the dialog controls have ControlType Pane rather than Edit/Button, so filter by ClassName

### SAP paths must not contain non-ASCII characters

In SAP's non-Unicode (MDMP) mode, GB2312/GBK encoding swallows some Chinese characters (such as 运).
Use only English letters/digits plus underscores in paths, or create the folder in Windows first and let SAP write into it.

## 6. VBScript SAP session pitfalls

| Problem | Solution |
|---|---|
| Every connection.Children(i) is Nothing | Use `For Each sess In connection.Children` instead |
| For Each order is not guaranteed | Extract the number from sess.Id and compare |
| The last match overrides a higher priority | Priority system: menu=True(3) > txCode=target(2) > title match(1) |
| Garbled Chinese in a VBS file | Build characters with ChrW(&HXXXX) |

## 7. PowerShell and non-ASCII text

```powershell
# Correct: build characters from code points
$saveCn = "$([char]0x4FDD)$([char]0x5B58)"   # 保存 (save)
$cancelCn = "$([char]0x53D6)$([char]0x6D88)"  # 取消 (cancel)
```

## 8. Multiple Excel instances

Tick "nested in a new Excel process" on Excel.LaunchExcel to guarantee a separate process.

## 9. Project directory structure

```
flow-ir/
├── AGENTS.md                         <- AI assistant entry point
├── docs/script-standards.md          <- this file
├── docs/robin-format-reference.md    <- .robin syntax reference
├── docs/agent-prompts.md             <- agent prompts
├── docs/prompts/nl-to-flow.md        <- prompt you can paste straight into an AI
├── docs/governance/                  <- NOTICE / SECURITY / CONTRIBUTING
├── skills/                           <- custom agent skills
├── tools/
│   ├── check-env.ps1                 <- environment check
│   ├── pad-robin/                    <- flow.json -> .robin generator + checks
│   ├── pad-sync/                     <- * core toolchain
│   │   ├── pad-sync.ps1              <- inject -> publish -> run -> collect (the only entry point that touches PAD)
│   │   ├── pad-repair-loop.ps1       <- automatic repair loop (including the RunDOSCommand hook)
│   │   ├── pad-deploy.ps1            <- production deployment (variable substitution + user confirmation)
│   │   ├── pad-rollback.ps1          <- snapshot rollback (rewrites the fingerprint baseline after success)
│   │   ├── pad-fingerprint.ps1       <- fingerprint baseline: show what it located / -Set for confirmed seeding
│   │   ├── PadFingerprint.psm1       <- the single fingerprint implementation (revision lookup, hashing, comparison)
│   │   ├── PadConfig.psm1            <- runtime config loading and per-field validation
│   │   └── confirm-deploy.ps1        <- MessageBox dialog helper
│   ├── flow-drawio/                  <- flow.json <-> .drawio visualization
│   ├── publish/                      <- pre-push content gate + denylist
│   └── workday/                      <- workday calendar checks
├── setup.ps1                         <- first-time setup
├── pad-robin-action-kb/              <- PAD Action KB (the single source of truth)
│   ├── PAD_Robin_ActionKB.json       <- the current action KB
│   ├── PAD_Robin_TypeReference.json  <- type reference
│   └── rules/                        <- .robin validation rules
├── business/                         <- business layer (never committed)
│   ├── flows/                        <- real flows
│   ├── config/                       <- real configuration
│   ├── docs/                         <- runbooks and internal notes
│   ├── policy.json                   <- production admission policy
│   ├── tools/                        <- business-only scripts (such as report reconciliation)
│   ├── tests/                        <- business regression cases and structural assertions
│   ├── logs/ snapshots/ worklog/      <- audit, snapshots, work records
│   └── manifest.jsonl                <- run/publish history
└── README.md
```

> **Calendar convention**: today missing from the table does not mean today is a holiday. When today is earlier
> than `CALENDAR_MIN` or later than `CALENDAR_MAX`, `workday.py` prints `CALENDAR_STALE=1` and `WORKDAY=1`;
> `pad-schedule` then hard-fails with exit code 5 and a `calendar-stale` event instead of skipping silently. Only
> "today is inside the covered range but marked as a non-workday" is a normal skip.
> Once the trigger layer lands it reuses the same event name `calendar-stale` and does not invent
> `trigger-calendar-stale`.

## 10. File encoding and PowerShell authoring standards

### 10.1 Encoding hard constraints

| File type | Encoding requirement | Consequence of violation |
|---|---|---|
| `.ps1` | UTF-8 **with BOM** | PS 5.1 parses non-ASCII text as GBK → the whole script is garbled plus syntax errors |
| `.js` | UTF-8 **without BOM** | A BOM breaks the `#!` shebang and raises SyntaxError |
| `.vbs` | ANSI/GBK or UTF-8; always build non-ASCII characters with `ChrW(&HXXXX)` | Garbled text |
| `.robin` / `.json` | UTF-8 (with or without BOM) | — |

When batch-editing files with Python, always use `encode('utf-8-sig')`, and **verify the first 3 bytes are
`ef bb bf` immediately after writing**:

```powershell
Get-Content $p -Encoding Byte -TotalCount 3 | ForEach-Object { $_.ToString('x2') }
```

Always read files with `[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)`, not `Get-Content` (which defaults to ANSI).

### 10.2 PowerShell control flow

**Never use `return` inside a `try` block to exit a script**. `return` terminates the script scope immediately and
skips the output and cleanup code after `try`:

```powershell
# Wrong: PAD_SYNC_RESULT is never printed
try {
    if ($InjectOnly) { $ok = $true; return }

    ...run...
}
catch { ... }
finally { Write-Output "PAD_SYNC_RESULT=$json" }   # actually skipped

# Correct: branch with if/else and keep the result output at the end
if ($InjectOnly) { $ok = $true }
else { ...run... }
Write-Output "PAD_SYNC_RESULT=$json"
```

### 10.3 Operating the PAD Designer UI

**Coordinate-based clicking is forbidden**. The Designer window may be dragged off screen (measured `L=878 R=2078`),
or the coordinates may land on other toolbar buttons (once measured clicking "subflow" by mistake).

| Target | Correct approach |
|---|---|
| Toolbar buttons | Try `InvokePattern.Invoke()` first; if that fails, find the inner `Button` child by `Name` |
| Selecting a canvas action | `SelectionItemPattern.AddToSelection()`; do not click |
| Keyboard focus | Call `SetFocus()` on a **freshly queried** `ListItem` (the list is virtualized and old handles go stale) |
| Select all | After `Ctrl+A` **always re-check the selected count**; only press `Delete` when it matches |
| Clear the canvas | Select-all check passes → `Delete` → re-check that the action count is 0, otherwise throw and abort |

The `FunctionView` container itself cannot take focus (`IsKeyboardFocusable=False`); focus must land on a concrete `ListItem`.

### 10.4 Judging a run result

Runs inside the Designer **do not write** `Console\Scripts\<guid>\Runs\<runId>\Actions.log`; that log exists only for
cloud/console-triggered runs.

| Signal | Location |
|---|---|
| Overall result | `robin.execution.success` / `robin.execution.failure` in `DataCollection\<date>-RobinRobot.log` |
| Error code | `eventData.padExceptionInfo.errorCode` (such as `File.FileNotFoundError`) |
| Action duration | `durationInMilliseconds`, present **only** for module actions such as Outlook/SAP/UIAutomation |
| Step details | Built-in actions (SET/IF/LOOP/RunDOSCommand) emit no telemetry, so they are unavailable |
| Variable values | Not in telemetry; only the flow's own output or the Designer variable panel has them |

To judge success you must **check both** the `success` and `failure` events — looking only at
`robin.execution.start` misjudges a failure as a success.

### 10.5 Two-directory synchronization

The workspace may hold several copies (development directory / migration target). After changing a script, sync
it and verify:

```powershell
(Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash
```

### 10.6 Read the file before patching it

Before changing code by string replacement you **must `Read` it to confirm the current state**. This session had 3
duplicate-insertion incidents (duplicate parameters, duplicate `-InjectOnly`, a second replacement of an already
deleted `GetFileName` that failed to match); all of them came from editing from memory.

### 10.7 Judging whether a run really started

Never infer process state from "is there a window". `PAD.RobotV2` is a **windowless** process and it is running;
only `PAD.Designer` has a window. Check in this order:

1. `PAD.RobotV2` appears → execution started
2. `PAD.RobotV2` disappears → execution finished
3. The status bar goes from `状态: 正在运行…` back to `状态: 就绪` (PAD UI text: running → ready)
4. Finally, the run-level events in `RobinRobot.log` are authoritative

### 10.8 Scheduled tasks must not pop up a terminal window

Scheduled task actions always use
`wscript.exe //nologo "tools\pad-sync\run-hidden.vbs" "powershell.exe" ...`; never write `powershell.exe` directly.
`wscript.exe` is a GUI-subsystem program, and `WScript.Shell.Run(cmd, 0, True)` hides the console from creation, so
no black window flashes; it can also pass the child process's exit code back to the scheduled task.

Do not switch the task to "run whether the user is logged on or not" just to hide the window: this project's PAD
flows need an interactive desktop, and UI automation stops working once they land in session 0.

## 11. Repair-loop interface (executor protocol)

`pad-repair-loop.ps1` carries a pluggable executor channel that closes the loop "run failed → fix the code → run again".

### 11.1 Three run modes

| Usage | Behaviour |
|---|---|
| Default | After each failed round, copy current.robin into the next round and **perform no repair** (for observation) |
| `-SingleRound` | Run one round, write `repair_ctx_N.json` and **stop**, waiting for an agent or human to make changes |
| `-Executor <script>` | After each failed round, call the executor to fix `.robin` and then **automatically proceed to the next round** until success or `-MaxRound` |

### 11.2 Executor interface

```
<Executor> -ContextFile <repair_ctx_N.json> -InputRobin <current.robin> -OutputRobin <round_N.robin>
```

| Exit code | Meaning | Loop behaviour |
|---|---|---|
| 0 | OutputRobin was produced | Proceed to the next round after verifying `.robin` is non-empty |
| 1 | Give up on repairing | Stop the loop, `executorAborted = true` |

Returning 0 without producing a file, or a produced file that fails its own check, also stops the loop.

### 11.3 Context structure (repair_ctx_N.json)

| Field | Content |
|---|---|
| `round` | Round number |
| `failedAction` | The failed action (local runs only have run-level errors, so `name` may be null) |
| `error.code` / `error.type` | Error code and type, such as `File.FileNotFoundError` / `User` |
| `actions` | The list of telemetry events |
| `logPath` | Path of `RobinRobot.log` |
| `currentRobinPath` / `nextRobinPath` | Input and expected output |
| `extraLogs` | VBS/Python logs attached when RunDOSCommand failed |

### 11.4 Built-in rule-based executor

`tools/pad-sync/repair-executor.ps1`:

- **Rule 1**: `FileNotFound*` → extract the missing absolute path from `.robin`, look for a same-name file under the
  PAD root given by `-PadRoot`, and **replace only on a unique hit**; otherwise give up
- **Rule 2**: `SAP.*` → never auto-change (screen numbers follow the transaction code and need human review)
- Anything else → write `<output>.hint.md` and exit 1

### 11.5 Hooking up an agent / LLM

The executor may be any program (`.ps1` / `.exe` / `node` / `python`) that follows the parameters and exit codes above.
Wrapping an LLM call in a script is enough:

```
pad-repair-loop.ps1 -Executor tools/pad-sync/repair-executor-llm.ps1 -MaxRound 3
```

The LLM executor works like this: read ctx → assemble the prompt (full `.robin` + `error.code` + `extraLogs`) → call
the model → extract the modified `.robin` → write OutputRobin → exit 0.

**Safety constraint**: executor output passes the `Test-RobinSyntax` self-check first, the loop defaults to
`-MaxRound 3`, and by default only `PAD_SYNC_TEST` is allowed.

## 12. Runtime configuration (PadConfig)

`tools/pad-sync/PadConfig.psm1` provides `Get-PadRuntimeConfig -ConfigPath <json>`, which reads the file once at
startup and validates every field. Explicit command-line parameters take precedence, and only items not given
explicitly are taken from the config. **There is no "fall back to a hard-coded default when it cannot be read"**.

| Field | Type | Description |
|---|---|---|
| `PadSyncPath` | string | Full path to `pad-sync.ps1` |
| `PythonExe` | string | Path to the Python interpreter |
| `CalendarPath` | string | Path to the workday calendar `.xlsx` |
| `WorkdayScript` | string | Path to `workday.py` |
| `RunTimeoutSec` | positive integer | Seconds to wait for the flow itself to finish |
| `PadRoot` | string | Root of the result directory (PAD root directory) |

Example (neutral placeholders; the real config goes in `business/config/runtime.json` and is never committed):

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

Error codes (hard failures, never downgraded to warn):

| Code | Trigger condition |
|---|---|
| `CONFIG_MISSING` | A required field is missing or empty |
| `CONFIG_PATH_NOT_FOUND` | The config file itself, or the path in any field, does not exist |
| `CONFIG_INVALID_VALUE` | Invalid JSON, or `RunTimeoutSec` is not a positive integer |

`pad-schedule.ps1`: passing `-ConfigPath` loads it under the rules above; without it, and with key parameters
missing, it reports `CONFIG_MISSING` and exits, with no fallback to built-in paths (historical callers still pass
parameters explicitly — that is the compatibility path; new tasks should use a config file).

## 13. Run-scoped workspace

### When it applies

Use it only when both conditions hold:

1. Old files must be **deleted after each run** (keep only the most recent N);
2. The target files have **no reliable time marker** (the filename has no date, the content has no generation time, etc.).

As soon as the target files can reliably prove "this run produced me" (for example a filename containing the export
time), prefer that marker and never introduce a directory for it.

### How

- Each run creates a new `YYYYMMDD-HHmmss` subdirectory under the parent directory (called
  `<attachment directory>\<run-timestamp directory>` below);
- Every file this run writes goes **only into that directory**; never write back into the parent;
- The parent is a container only and holds no large files besides the run-timestamp directories.

```text
<attachment directory>\
  20260101-090001\
  20260102-090002\
  legacy-<manual archive>\
```

### Deciding (picking this run's input)

- Accept only files **inside this run's directory**;
- Do **not compare** `ctime`/`mtime`, and do **not compare** filename suffixes or numeric suffixes;
- If the candidates in the directory are not unique or are empty → **hard failure** listing the directory contents,
  never falling back to "the newest anywhere".

### Cleanup

- Sort by **directory name** (`YYYYMMDD-HHmmss`) only and keep the most recent N (default 2);
- Clean up **only after this run succeeded**; failed paths are not cleaned (the scene is kept for investigation);
- **Empty directories do not take a retention slot**: a directory that was created but received no target files
  (mail retrieval failed, aborted midway, empty run) is a failure trace and is deleted directly; otherwise a few
  consecutive failures would push out every recent successful record;
- Directories whose names do not match `YYYYMMDD-HHmmss` (`legacy-*`, manual archives and so on) are never deleted;
- A delete failure (file in use, etc.) only warns and does not interrupt the main flow.

### Forbidden

**Never judge new versus old by a file's `ctime`/`mtime`.** Measured facts:

- Common mail clients **inherit the attachment's own creation/modification time** when saving it (the write moment is not recorded);
- Overwriting an existing same-name file **also rewrites even the creation time** to the attachment's time.

So for "an attachment saved just now", both `ctime` and `mtime` may point at the moment the attachment was produced
and cannot represent "this run". Similarly, a directory's `mtime` changes when it is opened or written, so it cannot
be used for sorting either — only the directory name, written by the flow itself, is trustworthy.

### Counterexamples

| Approach | Problem |
|---|---|
| Take the newest attachment by `mtime` in one parent directory | A file left over from yesterday is re-saved, its mtime becomes today, and the wrong file is picked |
| Take the largest numeric filename suffix (`(2)` > no suffix) | Suffixes are a human/client behaviour, unrelated to age |
| Clean up by keeping only "the file that was picked" | One wrong pick permanently deletes today's newly arrived file |
