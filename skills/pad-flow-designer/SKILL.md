# pad-flow-designer (Agent A: flow designer)

## When To Use
When the user describes, in natural language, a business process that should run on Power Automate Desktop.
Typical triggers: "build me a flow", "design a flow", "read from the mailbox … then …", "/design".

## Your responsibilities

1. Take a natural-language requirement
2. Produce the structured flow definition `flow.json` (the single authoritative source)
3. Annotate every node with a candidate PAD action (`pad_hint`, which must be a real three-part actionId from the KB)
4. Generate a `.drawio` diagram for drag-and-drop review
5. Read back the user's edits after they adjust the diagram
6. Do design and validation only; never execute any real business action

Exception: a step that needs no desktop UI does not belong on this track — pick the lane in
[`docs/engine-selection.md`](../../docs/engine-selection.md) first.

## Workflow

### 1. Understand the requirement
Extract: how it is triggered, which systems are involved, the step order, conditional branches, loops, and any
step that needs special AI assistance.

### 2. Annotate pad_hint (look it up in the table, never invent)
Look the action up in the KB first to confirm it exists:
```bash
node -e "const kb=require('./pad-robin-action-kb/PAD_Robin_ActionKB.json'); console.log(kb.actions.find(a=>a.actionId==='Module.Action.Selector')?'OK':'MISS')"
```
Pitfall: `Outlook.Close*` is always forbidden (it also closes the main window the user already has open).
For every other action, the KB lookup result is the authority; do not copy action lists into documents.

**Handles must be opened and closed in pairs**: Launch produces the handle → later steps reference it → Close
finishes it. The single exception is Outlook: **Launch only, never Close**, otherwise the user's already-open
main window is closed too.

### 3. Mandatory answers before generating flow.json (hard gate)

**The questions below must be answered node by node; without answers you may not generate `flow.json`.**
Never answer on the user's behalf with "automatic by default" or "safe by default"; when the user only describes
the overall process, split it into nodes and ask again.

> **This toolchain does no automatic retry.** A failed run always means "alert + manual rerun"; there is no
> automatic retry path. `idempotent` therefore never unlocks automated behaviour; it only tells a human what
> they need to know before pressing Run.

| # | Mandatory answer | Values | Field written to flow.json |
|---|---|---|---|
| 1 | How does this node run | `auto` runs automatically / `confirm` needs human confirmation / `observe` read-only observation | node-level `run_mode` |
| 2 | What happens on a rerun (rerun safety) | `true` a rerun gives the same result / `false` a rerun changes state or loses input | node-level `idempotent`; when `false`, `idempotency_note` is also required |
| 2b | Can the consequence be undone (reversibility) | `true` deleting rebuilds it or it can be reverted (saved attachment / exported file / reconciliation file / marked as read) / `false` sending mail, posting documents and similar cannot be undone | node-level `reversible`; when `false`, `reversibility_note` is also required (state how to revert, e.g. "a posting needs a reversal document to be undone") |
| 2c | Does this script delete or overwrite data (destructive) | `true` the script removes files, directories, rows, or cells, or overwrites existing files / `false` the script only reads or creates new files | node-level `intent_destructive` on `Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` nodes; when `true`, `reversibility_note` is also required (state how the deleted/overwritten data is recovered) |
| 3 | With multiple files written to disk and old files to clean up, how do you tell "this run's artifacts" apart | `yes` use a run-timestamp directory / `no` describe which reliable marker you use instead | this run's output directory + the selection condition of the cleanup node |
| 4 | Which input files must exist before this step starts | `none` / for each file: directory (config key), filename wildcard, `true` required / `false` optional | node-level `inputs[]` (see "Input file declarations" below) |
| 5 | How is this flow triggered | `manual` / `schedule` (`time` + `days` + `gate=workday|last-workday`) / `file` (`dir` must be `{{config.<KEY>}}`) | top-level `trigger`; fields and values in `docs/trigger-adapter-design.md`; `assisted=true` requires `timeout_sec` |

Decision criteria:
- **`idempotent` and `reversible` are two orthogonal axes; neither substitutes for the other**:
  `idempotent` answers "does rerunning with the same input pile up side effects", `reversible` answers
  "can the consequences already produced be withdrawn".
- **The semantics of `idempotent` are "rerun safety"**: it answers "what a human must know before pressing Run",
  not "is automatic retry allowed".
- **A node with `reversible=false` must be able to state how to revert** (e.g. "a submission needs a reversal
  document to be withdrawn", "the mail has been sent, so all we can do is send another explanation").
  If no revert path can be stated, the side effect does not belong in an unattended flow.
- **`Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` nodes must declare `intent_destructive`**:
  `pad_hint` cannot tell a read script from a delete script, so the boolean must be declared explicitly by reading
  the script source. `true` when the script deletes files/directories/rows/cells or overwrites existing files;
  `false` when it only reads or creates new files. `intent_destructive=true` additionally requires a
  `reversibility_note` saying how the deleted/overwritten data is recovered (regenerated, re-exported, …).
- **`reversible` is also mandatory on script nodes** (not only when `idempotent=false`): the admission gate
  cannot infer reversibility for a script from its `pad_hint` alone, so a script node without `reversible`
  reports `TRIGGER_MISSING_REVERSIBILITY` (ask).
- **Control nodes (SET / IF / LOOP / SWITCH / GUARD) must be annotated too**; do not annotate only business actions.
- For side-effect nodes such as sending mail, posting documents, deleting files and changing state, always ask
  about the rerun consequence; if it cannot be established, treat it as `idempotent=false`.
- `idempotency_note` must be one or two sentences of **plain Chinese meant for humans**, stating "what happens on
  a rerun / what to watch out for", for example "rerunning after the attachment was saved will not find the mail,
  so restore the unread state first" or "every rerun sends one more reminder mail".
- **Item 3 is mandatory only when the flow both "writes several files at once" and "needs to delete old files"**:
  the default is a **run-timestamp directory** (each run creates a new `YYYYMMDD-HHmmss` subdirectory, every file
  of that run goes only there, and cleanup keeps the newest N directories by name). See the "run-timestamp
  directory" section of `docs/script-standards.md`.
  If the user insists on not using it, they must state a **concrete and verifiable new/old marker** (such as a
  sequence or batch number the flow itself writes into the filename).
  **Answers such as "use the file modification time" or "keep whichever has the newer modification time" are not
  accepted**, because common mail clients preserve the attachment's original timestamp when saving, and
  overwriting a same-name file rewrites even the creation time, so timestamps cannot distinguish new from old.
  If no reliable marker can be established, do not generate `flow.json`.
- Counterexamples to remember:
  - **Export scripts are rerun-safe**: each run produces a new timestamped export file, so `idempotent=true`.
  - **Posting scripts are not rerun-safe**: repeated execution creates duplicate documents, so `idempotent=false`
    and `idempotency_note` states the manual pre-check (e.g. "confirm the state ledger is complete before
    rerunning"); also `reversible=false`, with `reversibility_note` saying "a submission needs a reversal
    document to be undone".
  - **A cleanup script is destructive**: it removes directories or attachments, so `intent_destructive=true`,
    `reversible=true` when a rerun of the whole flow re-drops the same batch (the individual directory is lost,
    but the data can be regenerated from the mailbox) and `reversibility_note` states that.

- **Catch-up runs are always disabled**: `StartWhenAvailable` for a scheduled trigger must be `false`. A catch-up
  run would execute instances missed over the weekend early on a workday morning, and the calendar gate only
  looks at "today", so it cannot detect that.
- **Every flow must declare `budget`**; `Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` nodes must carry
  `intent`, `reversible` and `intent_destructive`, otherwise admission asks (`INTENT_DESTRUCTIVE_MISSING` /
  `TRIGGER_MISSING_REVERSIBILITY`) or fails outright (see "Admission red lines").
- Consequence of a missing field: `eval-flow.js` **unconditionally** runs `declarationsComplete` once for every
  flow under test (it no longer depends on cases declaring it); `nodeDeclaration` is used for single-node
  assertions. A missing item fails outright (exit code 1) and is never downgraded to a warning. A deliberately
  broken flow can be pinned as a permanent case with `declarationsComplete` + `expect=invalid` + `code` (it must
  fail and name that code); a reversible=true mislabel is reported as `REVERSIBLE_MISLABELED` on this path too,
  whether or not the flow declares a trigger. Self-check:
  
```bash
node tools/pad-robin/eval-flow.js business/tests/eval/<name>.cases.json
```

> `check.js` only sees the generated `.robin` and cannot see `flow.json` fields; the gate for these two
> declarations lives in `eval-flow.js`.

### 3.5 Input file declarations (node-level `inputs`)

Declare these only for **steps that read external files**, answering "step N checks only the input files step N needs":

```json
{
  "id": "3",
  "pad_hint": "File.ReadTextFromFile.ReadText",
  "inputs": [
    { "dir": "{{config.InputDir}}", "pattern": "*.csv", "required": true },
    { "dir": "{{config.ReferenceDir}}", "pattern": "reference-*.csv", "required": false }
  ]
}
```

Rules:
- `dir` may only contain `{{config.<KEY>}}` (reusing the existing config placeholders); **real paths or literal
  directories are forbidden**. If admission cannot resolve it, that is a hard failure; it never falls back to
  the literal path.
- `pattern` is a filename wildcard (such as `*.csv`); one entry means one file.
- `required` must be written explicitly as `true` / `false`; there is no default. `true` blocks when the file is
  missing, `false` means "continue without it".
- **Multiple candidates always fail**: when the same pattern in the same directory matches ≥2 files, report an
  ambiguity; **picking the newest is not allowed**.
- An older flow without `inputs` does not error; admission only emits an `INPUT_UNDECLARED` notice.
- This field is **used only for admission and structural checks and never enters the generated `.robin`**
  (the generator does not consume it).
- Self-check assertion: use the `inputs` op, `node tools/pad-robin/eval-flow.js tests/eval/input-files.cases.json`.

### 4. Generate flow.json
Follow the structure strictly (full schema in `docs/agent-prompts.md`). The schema is authoritative for node
fields: `outputs` lists the output variable names to bind, and `{{2.RetrievedEmails}}` references the output of
an upstream node.

### 5. Generate the diagram
```bash
node tools/flow-drawio/flow-to-drawio.js business/flows/<name>.json business/flows/<name>.drawio
```

### 6. Read back changes
```bash
node tools/flow-drawio/drawio-to-flow.js business/flows/<name>.drawio business/flows/<name>.json business/flows/<name>.new.json
```
Summarize the changes, fill in `type`/`pad_hint` for nodes the user drew by hand, and after confirmation say
"ready to hand over to Agent B".

## Flow hygiene (flagged by `check.js` / `lint-robin.js`)

These three match the "flow checker" in the top-right corner of the PAD designer and are visible offline, so you
do not need to open the designer:

| Rule | Meaning | What to do at design time |
|---|---|---|
| `unused-output` | An action captured an output variable that is never read later | **Capture only the outputs you use**; list unused ones in the node's `output_skip` (equivalent to leaving them empty in PAD) instead of wiring everything for convenience |
| `unused-var` | `SET` declared a variable that is never referenced | Declare only what the derivation path really uses; delete template leftovers |
| `nested-if` | IF nesting deeper than 3 levels | Switch to **guard-style early exit**: wrap the whole section in a one-shot `LOOP 1 TO 1` block, and each failure branch shows its dialog and then `EXIT LOOP`; subsequent steps sit flat inside the block instead of a chain of "IF fails ELSE continue" |

> The **index variable of the one-shot block should reuse an existing one** (for example the polling counter):
> PAD's For loop requires a variable, and if you introduce a variable such as `StageIdx` that is used only once,
> the designer's flow checker reports an unused variable.

Standalone check: `node tools/pad-robin/lint-robin.js out.robin`

> **Do not press** the designer's "apply fix" button: it edits the canvas directly while `flow.json` stays
> unchanged, so the next generation overwrites it and production drifts from the repository immediately. Always
> fix `flow.json` and regenerate.

## Admission red lines (the policy file is authoritative)

Action-level red lines are not copied into documents: they are defined in `business/policy.json` and enforced by
the POLICY checks in `pad-admit.ps1`. The rule list and decision details are in `docs/admission-gate.md`.
At design time you only need to hold two lines:

- Never use `Outlook.Close*` (it also closes the main window the user already has open)
- Always put side effects (sending mail, posting documents, deleting files) inside a `guard` node with the
  condition `DryRun <> $'''1'''`
- Every `Scripting.RunDOSCommand*` / `Scripting.RunVBScript*` node declares `reversible` and `intent_destructive`;
  `intent_destructive=true` also requires `reversibility_note`

Before submitting, run the read-only admission check (generate the `.robin` first; without `-RobinFile`, a
missing same-name script silently skips the static check):

```powershell
.\tools\pad-sync\pad-admit.ps1 -FlowFile business/flows/<name>.json -ConfigFile business/config/<name>.json -RobinFile business/flows/<name>.robin
```

The delivery condition is `fail=0` **and** `ask=0`: `ask` exits with code 2 and also blocks delivery.
