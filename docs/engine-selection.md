# Engine selection: which lane carries a piece of automation

> This document answers one question: **for a given step, should the work be done by a Python script, a PowerShell
> script, or a Power Automate Desktop flow?** It is a rule for humans and AI assistants writing new automation, not
> a description of new machinery: nothing here is enforced by a gate today (see
> [the candidate rule](#5-candidate-rule-not-implemented)).

## 1. The one-line criterion

**Decide by asking whether the step has to click a desktop application that exposes no API — not by habit, and not
by where the existing code happens to live.**

If the answer is yes, the clicking belongs to PAD. If the answer is no, the step belongs to a script, even when a
PAD flow already exists for the neighbouring steps.

## 2. Three lanes

| Lane | Takes | May do | Must not do |
|---|---|---|---|
| **Python (`py`)** | Reading and writing workbooks, joining and comparing data sets, arithmetic, rule evaluation, producing output files | Parse files with a library, compute, write results, return a non-zero exit code on failure | Drive a GUI, wait for a window, close another application, hold a session open waiting for a human |
| **PowerShell (`ps1`)** | The operating-system surface: windows, modal dialogs, files locked by another process, process start/stop | Find a window by title, dismiss or drive a modal dialog through UI Automation, release a lock, wait for a file to become readable | Contain business rules or money arithmetic; parse and reconcile business workbooks |
| **PAD** | A desktop client that has to be clicked and exposes no scriptable API | Click, type, navigate, read a value off the screen | Compute, decide business rules, keep a blocking dialog in an unattended run, or act as a scheduler |

Two boundaries follow from the table and are easy to get wrong:

- **PAD only clicks.** A PAD flow may orchestrate (call a script, branch on its exit code, show a confirmation), but
  the calculation stays in the script it calls.
- **`ps1` only touches the OS.** A window-handling script must not grow a copy of the reconciliation rules; that is
  how the same rule ends up implemented twice and drifts.

## 3. Decision table

Apply it per step, before choosing a tool. The first matching row wins.

| # | Question about the step | Answer | Lane |
|---|---|---|---|
| 1 | Does it require clicking or typing into a desktop application whose automation API does not exist or does not cover this action? | yes | **PAD** |
| 2 | Does its success depend on a window, a modal dialog, or a file held open by another process? | yes | **ps1** |
| 3 | Is it otherwise reading, transforming, comparing or producing files and values? | — | **py** |
| 4 | Does it only need to run on a schedule? | yes | **any lane**; scheduling is orthogonal, see [section 6](#6-scheduling-is-orthogonal-to-engine-choice) |

A step that satisfies row 1 *and* row 3 is split, not assigned wholesale: PAD performs the click, the script
performs the computation, and the flow passes data between them through a file or a command-line argument.

## 4. Flow-level composition

| The whole job contains | Correct shape |
|---|---|
| At least one step that matches row 1 | A PAD flow (`flow.json` → `.robin`), with scripts called from `Scripting.RunDOSCommand*` nodes |
| Only rows 2 and 3 | An entry script (a `py` entry point, optionally wrapped by `ps1`), run directly or from Task Scheduler |
| Only row 3 | An entry script, no PAD, no OS-level wrapper |

A flow that contains no UI step is a script wearing a flow's clothes: it pays the PAD deployment cost (designer
session, action knowledge base, injection, fingerprinting) without gaining anything a plain entry script lacks.

## 5. Candidate rule (not implemented)

The flow-level table above can be turned into a mechanical check, stated here as a **candidate only**:

> **`NO_UI_ACTIONS_BUT_PAD` (candidate):** a `flow.json` whose nodes contain zero UI-class actions should not be
> expressed as a PAD flow; report it instead of generating `.robin`.

This rule is **not implemented**. `tools/pad-sync/pad-admit.ps1` and `tools/pad-robin/eval-flow.js` contain no UI-node
criterion today; this document adds none, and changing either gate is out of scope for it.

Implementing the rule needs three decisions that do not exist yet:

1. **Which actions count as UI-class.** The reviewed list has to come from the action knowledge base, not from a
   guess. It must say, per action, whether it touches a real application surface (web automation, window/mouse/
   keyboard automation, a client application's controls) or only computes and moves data.
2. **Where `Display.ShowMessageDialog` belongs.** It talks to a human, not to an application. The natural reading is
   "human confirmation, not UI automation", so it should not by itself justify PAD — but that has to be decided
   explicitly, because it is the most common node in a thin wrapper flow.
3. **What the check is allowed to conclude.** A missing UI action is evidence that PAD is not needed; it is not
   proof, because a flow can legitimately exist only for scheduling or for its deployment/audit machinery. The rule
   would therefore be a report, and any hard failure would need its own separate decision.

## 6. Scheduling is orthogonal to engine choice

"Must run every day at a fixed time" is a scheduling requirement, not an engine requirement. A plain entry script
can be registered in Task Scheduler and run unattended; introducing PAD only to obtain a timer adds a designer
session, an interactive desktop requirement and a second moving part.

In this repository the two dimensions are already separated: `tools/pad-sync/pad-schedule.ps1` registers a task that
runs the **PAD runner**, so it schedules the PAD lane specifically. A non-PAD job does not need that script; it needs
its own task entry pointing at the entry script.

The trade-off is real and must be stated to the user: outside the PAD lane, the scheduling helpers, alerting,
acceptance checks, fingerprints and rollback in `tools/pad-sync/` do not apply (see section 7).

## 7. Explicit limitation: one adapter, one track

The IR is engine-agnostic; the implementation is not. `llms.txt` states the position in its opening block:

> `flow.json` is the source of truth, and **only one adapter is implemented today — PAD (Power Automate Desktop /
> Robin)**. Other engines (another RPA product, cloud flows, Python/VBS) are extension points that are not
> implemented yet.

What exists, verified in the tree:

- `tools/pad-robin/flow-to-robin.js` is the only generator that emits an engine target; it writes `.robin` at
  `tools/pad-robin/flow-to-robin.js:594`.
- `tools/flow-drawio/flow-to-drawio.js` and `flow-to-drawio-bfs.js` write `.drawio` canvases for review, not targets
  for an engine.
- No generator emits `ps1`, `py` or any other engine's artifact.

Consequences, stated plainly:

- **Leaving `flow.json` means leaving the safety net.** A task executed as a standalone script gets no admission
  gate, no acceptance checks, no fingerprints, no alerting and no rollback, because all of those live in
  `tools/pad-sync/` and are driven by the `.robin` artifact.
- **That is a trade-off, not a bug to paper over.** For a file-only job the safety net mostly protects against
  deployment drift, which a local entry script does not have; for a UI-driven job it protects against the failure
  modes that actually occur.
- **A second adapter would need more than a generator.** At minimum: an IR-to-target generator that consumes the same
  `flow.json` structures; an acceptance expression for the target's artifacts (what proves the run happened); an
  idempotency and reversibility expression in that target's vocabulary; and an admission equivalent. None of these
  exist for a non-PAD target, so this repository must not be described as multi-engine today.

## 8. Two shapes where PAD makes things worse

1. **A flow that only wraps an existing script and keeps its blocking dialog.** The script pops a modal message on
   every failure; the flow wraps it, so on a scheduled run nobody is present to dismiss it and the run hangs until
   the timeout. The wrapper adds deployment cost and removes no failure mode. The fix is in the script (fail with an
   exit code and a log line), and then the script can be scheduled directly.
2. **Unattended automation of a judgement that occurs twice a month.** A decision that needs a human reading a note
   or a one-off exception is cheaper to perform twice than to encode, and encoding it as an unattended flow turns
   "a person looks at two rows" into "the flow silently skips them, or asks for confirmation at an hour when nobody
   is there". Keep it as a checklist step next to the automated run.

A third anti-pattern follows from section 6: adding a PAD flow whose only purpose is to be scheduled.

## 9. Evidence used for this document

| Claim | Evidence |
|---|---|
| Only the PAD adapter is implemented | `llms.txt:3-6`; `git ls-files tools` shows one `flow-to-robin.js` and no other engine generator |
| The `.robin` writer is `flow-to-robin.js` | `tools/pad-robin/flow-to-robin.js:594` (`fs.writeFileSync(outPath, output, "utf8")`) |
| Canvas generators are not engine adapters | `tools/flow-drawio/flow-to-drawio.js:194`, `tools/flow-drawio/flow-to-drawio-bfs.js:270` — both write `.drawio` XML |
| No UI-node gate exists today | `Select-String` over `tools/pad-sync/pad-admit.ps1` and `tools/pad-robin/eval-flow.js` for UI-action patterns returns only `assisted` / `run_mode` matches |
| Generic libraries are PAD-independent | `tools/workday/workday.py` header ("generic; contains no business checking rules"); `tools/xlsx/xlsx_io.py` header ("generic; contains no business rules") |
| Window/dialog handling already lives in `ps1`, called from a recorded script | `business/scripts/*.ps1` declare a `param()` entry point and are started by `WScript.Shell.Run` from a `.vbs` in the same directory |
| Documentation language | `docs/doc-language.md:12` — `docs/*.md` are English |
