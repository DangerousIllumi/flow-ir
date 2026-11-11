> Status: design baseline v1. Trigger assertions, the TRIGGER checks in pad-admit, the schedule/manual/file
> registrars and the file watcher are implemented; everything else is covered in section 7.

# Trigger declarations (`trigger`) and registrar design draft (v1)

> Design baseline: `flow.json` already has a top-level `trigger` key (see `docs/agent-prompts.md` and
> `tools/flow-drawio/example-flow.json`).
> Until this design landed it was an **inert field**: the generator and `check.js` neither read nor validated it,
> and `drawio-to-flow.js` only carried it through verbatim. Today the trigger assertions in `eval-flow.js` and
> the TRIGGER checks in `pad-admit` do validate it. This design **reuses that key instead of inventing a second
> configuration system**, promoting it from a "comment" to a "validatable, registrable declaration".

## 1. Why this is needed: three concrete problems

| Problem | Evidence today | Consequence |
|---|---|---|
| **Invisible** | The launch method exists only in the command-line arguments of `pad-schedule.ps1`, the scheduled-task list, and people's memory | When someone else takes over, or the machine is rebuilt, the setup can only be reconstructed from old commands |
| **Not validatable** | `eval-flow.js` only checked node-level `run_mode`/`idempotent`; early `pad-admit` had no check on the trigger at all (the `TRIGGER` check has since been added) | "Run daily at 09:00" and "every node has `run_mode=confirm`" could coexist without any error |
| **Not registrable** | Registration logic was scattered across `tools/pad-sync/pad-schedule.ps1`, with only the `-Daily/-Weekly` and `-LastWorkday` paths, and task names derived ad hoc by `Get-ScheduleTaskName` | Adding a flow meant assembling arguments by hand; re-registering relied on blind `-Force` overwrites; there was no unified "is it in effect" verification |

**Boundary**: `trigger` declares only "how it starts". It does not replace `budget`, does not replace `guard`,
and does not describe process steps. Registration is an **operating-system-level** action on the local machine
(Windows Task Scheduler / file watching); it **adds no PAD action and does not modify `.robin`**.

## 2. The `trigger` block in `flow.json`

### 2.1 Fields

```json
"trigger": {
  "kind": "schedule",
  "task_name": "flow-ir-<scheduled task name>",
  "time": "09:00",
  "days": ["mon", "tue", "wed", "thu", "fri"],
  "gate": "workday",
  "timeout_sec": 4200,
  "assisted": true
}
```

| Field | Required | Value domain / default | Description |
|---|---|---|---|
| `kind` | Yes | `manual` / `schedule` / `file` | Lowercase; any other value is rejected, never guessed |
| `task_name` | No | Derived from the flow name by default: `flow-ir-` plus illegal characters replaced with `_` | When given explicitly it must match `^[A-Za-z0-9._-]{1,64}$` and be globally unique |
| `time` | Required for `schedule`/`file` | `HH:mm` (24-hour) | `schedule`: the firing time; `file`: the time watching starts |
| `days` | No | Default `mon`–`fri`; values `mon..sun` | No holiday inference; holidays are left to `gate` |
| `gate` | No | `none` / `workday` / `last-workday`, default `none` | `workday`/`last-workday` reuse the existing workday calendar; an unavailable calendar is a hard failure, never a guess |
| `timeout_sec` | No | Defaults to `RunTimeoutSec` from the runtime config | Same definition as `-RunTimeoutSec` in `pad-schedule` |
| `assisted` | No | Boolean, default `false` | Semantics: starts automatically on time, a human confirms partway through. Allowed only for `kind=schedule/file`; with `kind=manual` it triggers `TRIGGER_INVALID`. When `true`, `timeout_sec` must be declared explicitly (otherwise `TRIGGER_ASSISTED_NO_TIMEOUT`); if nobody confirms, the timeout alert is the fallback |
| `file.dir` | Required for `file` | Must be a `{{config.<KEY>}}` reference | Literal absolute paths are forbidden; registration resolves it via `-ConfigFile` |
| `file.pattern` | Required for `file` | glob, e.g. `*.xlsx` | Filename matching only; never decides new versus old by modification time |
| `file.poll_sec` | No | Default 60, minimum 15 | Polling interval |
| `file.settle_sec` | No | Default 60 | A file counts as fully written only when two consecutive polls see the same size |
| `file.max_wait_sec` | No | Default 7200 | Watching limit; on timeout it exits silently with code 0 and is not a failure |
| `file.once_per_file` | No | Default `true` | Marks each file by "name + size + last write time" and records it in the state ledger; never used to pick new versus old files |

`manual` allows only `{ "kind": "manual" }`; any `time`/`file`/`assisted` field makes it invalid (this prevents
"declared but never executed").

**Migrating the old shape**: the existing `{ "type": "...", "config": {...} }` is treated as a legacy shape and
reported as `TRIGGER_LEGACY_SHAPE` (a warning during the observation period; it becomes fail once migration
finishes). There is no silent mapping — `type: "event"` and `config.dayOfMonth` cannot be mapped reliably onto `kind`.

### 2.2 Relationship to existing fields

| Existing field | Relationship |
|---|---|
| `budget` | A different dimension: `budget` bounds loops, `trigger` controls the start time; neither derives from the other. `timeout_sec` is only the runner wrapper timeout and does not change budget decisions |
| `guard` | Unrelated. Registration touches no business data and needs no `DryRun` guard; node ids are not allowed inside the `trigger` block |
| Node `run_mode` | **Cross-check**: when `kind != manual` and a node has `run_mode=confirm` — `assisted=true` is **pass** (starts automatically on time, a human confirms partway through, and the `timeout_sec` alert is the fallback when nobody does); a missing or `false` `assisted` yields `TRIGGER_UNATTENDED_CONFIRM` (fail). A fully unattended flow can never wait for a human click |
| Node `idempotent` / `reversible` | **Cross-check (reversibility)**: these two fields are orthogonal axes — `idempotent` covers "does a rerun with the same input converge", `reversible` covers "can the consequences already produced be withdrawn". When `kind != manual` and a node has `reversible=false` → `TRIGGER_UNATTENDED_IRREVERSIBLE` (warn, with evidence listing the node id and `reversibility_note`); when a `Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` node declares no `reversible` → `TRIGGER_MISSING_REVERSIBILITY` (**ask**: a script's reversibility cannot be inferred from its `pad_hint`, so the gate asks instead of guessing); for non-script nodes with `idempotent=false` and no `reversible` it is warn, asking for the declaration rather than filling it in by default. The old code `TRIGGER_UNATTENDED_NONIDEMPOTENT` survives as a compatibility alias only and is **no longer triggered by `idempotent=false`** (it has been narrowed) |
| Node `intent_destructive` | **Cross-check (destructive intent)**: on script nodes the boolean must be declared explicitly, because `pad_hint` cannot distinguish a read script from a delete script. Missing → `INTENT_DESTRUCTIVE_MISSING` (ask); non-boolean → `INTENT_DESTRUCTIVE_INVALID` (fail); `true` without `reversibility_note` → `INTENT_DESTRUCTIVE_NO_NOTE` (fail); the same `intent` declaring different values → `INTENT_DESTRUCTIVE_CONFLICT` (fail); a posting intent (`sap-migo`/`posting`) declaring `false` → `INTENT_DESTRUCTIVE_DOWNGRADED` (fail). Full table in `docs/admission-gate.md` §2.2b |
| Automatic retry | `trigger` **introduces no retry**: a missed time is not caught up and a failure is not re-triggered, consistent with the chain-wide "alert + manual rerun" convention |

### 2.3 Valid example

```json
{
  "name": "<flow name>",
  "trigger": {
    "kind": "schedule",
    "task_name": "flow-ir-<scheduled task name>",
    "time": "09:00",
    "days": ["mon", "tue", "wed", "thu", "fri"],
    "gate": "workday",
    "timeout_sec": 4200
  },
  "budget": { "maxLoop": 3 },
  "nodes": [ ... ]
}
```

### 2.4 Invalid examples

**Example A — unsupported kind**

```json
"trigger": { "kind": "mail", "task_name": "flow-ir-<scheduled task name>" }
```

Violation: the `kind` domain is `manual/schedule/file` only. Reported as `TRIGGER_KIND_UNSUPPORTED` (fail).
v1 has no mail registrar, so writing `mail` would mean "declared but never registered" and must be rejected on
the spot.

**Example B — literal path plus an unattended confirm node**

```json
"trigger": {
  "kind": "file",
  "time": "08:30",
  "file": { "dir": "<attachment directory>", "pattern": "*.xlsx" }
},
"nodes": [
  { "id": "9", "pad_hint": "Outlook.SendEmailThroughOutlook.SendEmail", "run_mode": "confirm", ... }
]
```

Two violations:
1. `file.dir` is a literal absolute path and does not use `{{config.<KEY>}}` → `TRIGGER_PATH_LITERAL` (fail).
   The registrar cannot reuse it on another machine, and it violates "external parameters are read from config".
2. `kind=file` without `assisted=true` plus a node with `run_mode=confirm` → `TRIGGER_UNATTENDED_CONFIRM` (fail).
   When a file lands there is nobody next to the machine to click confirm; if someone really does confirm partway
   through, declare `assisted: true` explicitly and provide `timeout_sec`.

**Example C — missing required field**

```json
"trigger": { "kind": "schedule" }
```

Violation: `schedule` without `time` → `TRIGGER_INVALID` (fail). **There is no 09:00 default**, because "the
default time" is exactly the kind of invisible verbal agreement this design removes.

## 3. Registrar interfaces (two in the MVP)

### 3.1 `schedule` (Windows Task Scheduler)

| Item | Design |
|---|---|
| Input | `flow.json` (including `trigger`) + `-ConfigFile` (resolves `{{config.*}}` and the timeout default) + `-AllowProd` |
| Generated action | Reuse the action construction already in `pad-schedule.ps1` (`run-hidden.vbs` wrapping `powershell`, `-LogonType Interactive`, `-MultipleInstances IgnoreNew`); no new launch mechanism |
| Idempotency key | `task_name` plus the SHA256 of the canonical JSON (`specHash`); written into the task description prefix `flow-ir-spec:<specHash>` |
| Re-registration | Task exists and `specHash` matches → return `unchanged` without writing to the system; otherwise `Register-ScheduledTask -Force`, then read back and verify |
| Verify in effect | ① `Get-ScheduledTask` finds it; ② the `specHash` read back from the description matches; ③ the action parameters contain the correct `-FlowName`; ④ `Get-ScheduledTaskInfo.NextRunTime` is non-empty and later than now; ⑤ `LastTaskResult` plays no part in "did registration take effect" (it describes a run outcome) |
| Catch-up | `StartWhenAvailable` is **explicitly set to `False`**: triggers missed while the machine slept or was off are not caught up after resume. The trade-off is "if the machine is off at 9:00, it does not run that day" — the calendar gate only decides whether today is a workday and cannot recognize that a catch-up instance belongs to a missed weekend trigger, which would otherwise run unplanned early on a workday morning |
| Failure behaviour | **Hard failure** (exit code 1) plus a `trigger-register-failed` alert; no "registration failed but deployment continues" downgrade |

### 3.2 `file` (file arrival)

| Item | Design |
|---|---|
| Input | Same as `schedule`, except that the resolved `file.dir` must exist and be readable (a read-only probe; no probe file is written) |
| Run shape | Register a scheduled task that starts `pad-trigger.ps1 -Watch` at `time`; the watcher polls at `poll_sec` internally and, on a hit, calls the **existing** `pad-sync.ps1 -RunOnly -AllowProd -NonInteractive`. No new run entry point is introduced |
| Idempotency | ① Registration layer: same `specHash` as above; ② Run layer: the state ledger `<state directory>/<scheduled task name>.json` records `fileName|size|lastWriteUtc`, so the same file triggers only once |
| Verify in effect | ① The task exists and `specHash` matches; ② `file.dir` is readable and `pattern` matches 0 or 1 candidate (picking the newest among several would be a guess, so v1 does not do it and fails with `TRIGGER_FILE_AMBIGUOUS`); ③ the state ledger directory is writable; ④ `NextRunTime` is non-empty |
| Failure behaviour | **Hard failure** (exit code 1) plus `trigger-register-failed` |

### 3.3 Draft of the unified function signatures

```powershell
# tools/pad-sync/TriggerRegistry.psm1 (new)

# Read and normalize the trigger block; throw an exception carrying Data['code'] when invalid (same style as PadConfig)
function Get-TriggerSpec {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
}

# SHA256 of the canonical JSON (sorted keys, no whitespace), used as the idempotency key
function Get-TriggerFingerprint {
    param([Parameter(Mandatory)]$Spec)
}

# Unified entry point: dispatch by kind; returns [ordered]@{ ok; kind; taskName; action; specHash; evidence }
function Register-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun,
        [switch]$AllowProd
    )
}

# Read-only verification: writes nothing to the system, creates no directory, triggers no run
function Test-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile
    )
}

function Unregister-Trigger {
    param(
        [Parameter(Mandatory)][string]$FlowFile,
        [string]$ConfigFile,
        [switch]$DryRun
    )
}

# ---- Internally split by kind, for easier Pester unit tests ----
function Register-ScheduleTrigger { param($Spec, [switch]$DryRun, [switch]$AllowProd) }
function Test-ScheduleTrigger     { param($Spec) }
function Unregister-ScheduleTrigger { param($Spec, [switch]$DryRun) }
function Register-FileTrigger     { param($Spec, [switch]$DryRun, [switch]$AllowProd) }
function Test-FileTrigger         { param($Spec) }
function Unregister-FileTrigger   { param($Spec, [switch]$DryRun) }
```

CLI shell:

```powershell
# tools/pad-sync/pad-trigger.ps1 (new)
# .\pad-trigger.ps1 -FlowFile business\flows\<flow name>.json -ConfigFile business\config\<flow name>.json -Register -AllowProd
# .\pad-trigger.ps1 ... -Test
# .\pad-trigger.ps1 ... -Unregister
# Last line prints PAD_TRIGGER_RESULT=<JSON>; exit code 0 success / 1 failure / 2 input error
```

**Task name conflicts**: before registering, look up existing tasks by `task_name`; if the flow identity in the
description differs from this run → `TRIGGER_AMBIGUOUS` (fail), with no overwrite.

## 4. Where validation happens

### 4.1 `eval-flow.js`

It has no result-code system; a failed assertion means the whole run exits with code 1. Two assertion operations
are added, without changing the semantics of existing `OPS`:

| Assertion op | What it checks | Failure behaviour |
|---|---|---|
| `trigger` | Validates required fields, value domains, the `time` format and whether `file.dir` is `{{config.*}}`, by `kind` | That case fails, exit code 1 |
| `triggerComplete` | `trigger` exists and `kind` is valid (equivalent to the "trigger declared" gate) | Same as above |

`check.js` is **unchanged**: it only sees `.robin` and cannot see top-level `flow.json` fields, which is already
an established convention.

### 4.2 The `TRIGGER` check in `pad-admit`

Static validation plus optional read-only verification on the local machine (the `-TriggerLive` switch, off by
default so results during offline generation stay reproducible).

| Result code | Level | Trigger condition |
|---|---|---|
| `TRIGGER_MISSING` | warn (observation period, `$script:TriggerMode = 'warn'`; flipped to fail in a separate commit once existing flows have migrated) | No `trigger` block |
| `TRIGGER_LEGACY_SHAPE` | warn | Only the old `type/config`, no `kind` |
| `TRIGGER_UNKNOWN_KIND` | **fail** | `kind` is not one of `manual/schedule/file` |
| `TRIGGER_KIND_UNSUPPORTED` | **fail** | `kind` uses a reserved value such as `mail`/`callback` |
| `TRIGGER_INVALID` | **fail** | Missing required field, `time` not `HH:mm`, illegal `days`, empty `pattern`, non-boolean `assisted`, `manual` declaring `assisted` |
| `TRIGGER_ASSISTED_NO_TIMEOUT` | **fail** | `assisted=true` without an explicit `timeout_sec` |
| `TRIGGER_PATH_LITERAL` | **fail** | `file.dir` is a literal path and does not use `{{config.<KEY>}}` |
| `TRIGGER_UNATTENDED_CONFIRM` | **fail** | `kind != manual` and a `run_mode=confirm` node exists, without `assisted=true` |
| `TRIGGER_UNATTENDED_IRREVERSIBLE` | warn | `kind != manual` and a node has `reversible=false` (the consequence cannot be withdrawn) |
| `TRIGGER_MISSING_REVERSIBILITY` | **ask** (script nodes) / warn (other nodes) | A `RunDOSCommand`/`RunVBScript` node declares no `reversible` (ask: the gate cannot infer it); a non-script node has `idempotent=false` but declares no `reversible` (warn) |
| `TRIGGER_UNATTENDED_NONIDEMPOTENT` | warn (compatibility alias, **narrowed**) | The name is kept for existing cases that reference it; it is no longer triggered by `idempotent=false` |
| `TRIGGER_NO_GATE` | warn | `kind=schedule` with `gate=none` (it would run on holidays) |
| `TRIGGER_NOT_REGISTERED` | warn (only with `-TriggerLive`) | No matching scheduled task is found on this machine |
| `TRIGGER_DRIFT` | **fail** (only with `-TriggerLive`) | The task exists but its `specHash`/action parameters disagree with the declaration |
| `TRIGGER_AMBIGUOUS` | **fail** | `task_name` is already taken by another flow |

The observation-period strategy matches fingerprints: `pad-admit.ps1` already sets
`$script:FingerprintMode = 'warn'` at the top, and the same pattern is copied as `$script:TriggerMode = 'warn'`
so the default behaviour does not change and existing flows are not interrupted.

## 5. Relationship to alert consolidation

The alert record schema follows `Write-RunAlert` in `tools/pad-sync/pad-schedule.ps1`:
`ts / kind / flow / exitCode / stage / status / errorCode / error / logPath / acceptance / note` (optional `reason`).

Only two new kinds are added; runtime trigger failures keep reusing the existing `trigger-failed`:

| kind | stage | status | Purpose |
|---|---|---|---|
| `trigger-register-failed` | `register` | `failed` | Registration or read-back verification failed; `reason` carries the result code (such as `TRIGGER_DRIFT`) |
| `trigger-unregister-failed` | `unregister` | `failed` | Unregistration failed |
| `trigger-failed` (existing) | `trigger` | `failed` | No run evidence after a trigger; keeps `reason = identity-mismatch / no-evidence / no-robot` |

New optional fields: `triggerKind`, `taskName`, `specHash`.

**How it is reused**: `pad-trigger.ps1` does not implement its own JSONL writer. If the in-flight "alert from the
direct-call path" change extracts alert writing into a shared function or module, `pad-trigger` calls it directly
(`-Stage 'register' -Status 'failed'`); until that change lands, `pad-trigger` writes directly against the same
schema with fields and kinds fully aligned, so a second kind vocabulary never appears.

## 6. Explicitly out of scope for v1

| Not doing | Reason | Condition to revisit |
|---|---|---|
| **Outlook rule triggers** | Rules live in client mailbox configuration, outside the repository and impossible to review; registration/verification goes through the Outlook object model and mailbox credentials; local protocol links fired by rules easily cause duplicate and missed triggers, and a `Test-*` "do not really run" check is impossible | A local, read-only, verifiable rule registration interface exists (able to export rule definitions for diffing), and the trigger entry point carries an idempotency token, with no mailbox address in the public layer |
| **Cloud callbacks** | They depend on a cloud environment, connection credentials and a publicly reachable endpoint; every tool here is a local, read-only toolchain that cannot verify offline whether registration took effect; they also involve replay attacks and idempotency design, beyond the MVP | A controlled cloud connection and callback registration API exists, able to verify by "read back after registering", with replay protection defined |
| Registering URL protocol triggers separately | The `ms-powerautomate` protocol is invoked inside `pad-sync`; it is an execution mechanism, not a launch declaration, and `manual` already covers it | Only when a third-party system must launch it directly |
| Catch-up runs / automatic retry | Conflicts with the chain-wide "alert + manual rerun" convention | Not planned |

## 7. Implementation order (4 steps, each verifiable)

**Size**: 4 new files (`TriggerRegistry.psm1`, `pad-trigger.ps1`, `tests/trigger-registry.Tests.ps1`,
`tests/eval/trigger.cases.json`) + 2 fixture files (`tests/eval/fixtures/trigger-*.json`, test data) + 2
validation changes (`eval-flow.js`, `pad-admit.ps1`). The watching logic is folded into
`pad-trigger.ps1 -Watch` rather than opened as a fifth file.

| Step | Content | Acceptance command and criteria |
|---|---|---|
| 1 Declaration layer | Standardize `trigger` + two new ops in `eval-flow.js` + positive/negative cases | `node tools\pad-robin\eval-flow.js tests\eval` exits 0; negative cases use `expect=invalid` + `code` assertions that must hit `TRIGGER_*` (the suite stays green); turning a negative case into "expected valid" makes it exit 1 and print the result code |
| 2 Admission layer | The `TRIGGER` check in `pad-admit`, warn by default | `.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<flow name>.json -Json` output contains `"id":"TRIGGER"`; an existing flow without `trigger` warns and the exit code is unchanged; a `kind=mail` sample exits 1 |
| 3 Scheduled task registrar | `TriggerRegistry.psm1` + `pad-trigger.ps1` (schedule) | `-Register -DryRun` only prints the action and writes nothing to the system; after a real registration to `flow-ir-<scheduled task name>-selftest`, `-Test` returns `ok=true`; `schtasks /Query /TN <scheduled task name> /XML` shows the time/weekdays matching the declaration; registering again returns `unchanged`; after `-Unregister`, `-Test` reports it is no longer registered |
| 4 File arrival registrar | `file` branch + `-Watch` + state ledger | Register against a temporary `<attachment directory>`; drop in a probe file with a stable size → a new runId appears; drop in another file with the same name and size → it does not trigger again; `-Test` is read-only throughout (the directory mtime is unchanged) |

At the end of every step, run `node tools\pad-robin\check.js <out.robin>` and `pad-admit` once to confirm that no
existing check turned red.

---

## Outstanding verification list

| # | Item to verify | How to verify | Uncertainty |
|---|---|---|---|
| 1 | Is the scheduled-task description long enough for `flow-ir-spec:<hash>` | Read the full description back with `schtasks /Query /XML` after registering | The Task Scheduler description limit and truncation behaviour |
| 2 | Does a failed `Register-ScheduledTask -Force` keep the old task | Register deliberately with illegal action parameters and compare the task XML before and after | Whether a failure is atomic |
| 3 | What `Get-ScheduledTaskInfo.NextRunTime` means for a "workdays only" task | Observe `NextRunTime` on two consecutive days after registering | How the `-Weekly` and `-Daily+gate` forms differ in display |
| 4 | Can file watching start the flow while the PAD console is closed | Close the console, drop in a probe file, and observe how `pad-sync` classifies `trigger-failed` | Whether the protocol handler needs a resident console |
| 5 | Does a copy operation rewrite `lastWriteUtc` in the state ledger | Copy the same file twice and see whether the ledger misjudges it | It is used only to deduplicate the same file, never to pick new versus old |
| 6 | Does resolving `{{config.<KEY>}}` need an extension of the fixed key set in `PadConfig.psm1` | Run `-Register -DryRun` with a config containing a custom key | The module recognizes only 6 fixed keys, so read-only resolution may be needed instead of changing the module |
| 7 | How does `-TriggerLive` behave when the account cannot query scheduled tasks | Run `-Test` as a standard user | Whether it returns empty instead of erroring, and whether that should downgrade to `TRIGGER_UNKNOWN` or hard-fail |
| 8 | How many legacy `type/config` shapes actually exist | Read-only scan of how often `trigger.type` appears in `business/flows/*.json` | Decides how long the `TRIGGER_LEGACY_SHAPE` observation period lasts |
