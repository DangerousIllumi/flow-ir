# From one sentence to a runnable flow: example and scoring

> This document answers two questions:
> 1. What does "requirement → flow.json → checks pass → paste into PAD" actually look like?
> 2. When an agent generates several requirements in one go, how do you quantify whether it is reliable?
>    (The public sample set currently holds 10 flow samples + 6 trigger samples.)

---

## 1. Example: how one sentence becomes flow.json

**The user's exact words**

> Every day, copy the contents of `C:\Temp\input.txt` verbatim to `output.txt`; if something goes wrong, tell me.

**What Agent A has to do** (following the steps in `skills/pad-flow-designer/`)

1. Extract the elements: trigger = daily; steps = read file → write file; no branches, no loops, no external systems.
2. Check the knowledge base to confirm the action exists (**never invent from memory**):

   ```powershell
   node -e "const kb=require('./pad-robin-action-kb/PAD_Robin_ActionKB.json');for(const id of ['File.ReadTextFromFile.ReadText','File.WriteText'])console.log(id, kb.actions.some(a=>a.actionId===id)?'OK':'MISS')"
   ```

3. Produce `business/flows/copy-text.json` (copy `tests/eval/fixtures/file-copy-text.json` and edit it):

   ```json
   {
     "name": "copy-text",
     "trigger": { "kind": "manual" },
     "budget": { "maxLoop": 1 },
     "acceptance": {
       "description": "After a successful copy the target file exists and is not empty",
       "checks": [
         { "name": "target file exists", "type": "fileExists",
           "path": "{{variables.OutputFile}}", "minBytes": 1 }
       ]
     },
     "variables": [
       { "name": "InputFile",  "type": "string", "default": "C:\\Temp\\input.txt" },
       { "name": "OutputFile", "type": "string", "default": "C:\\Temp\\output.txt" }
     ],
     "edges": [{ "from": "1", "to": "2" }],
     "nodes": [
       { "id": "1", "pad_hint": "File.ReadTextFromFile.ReadText",
         "params": { "File": "{{variables.InputFile}}", "Encoding": "UTF8" },
         "output_map": { "Content": "FileContent" }, "next": ["2"],
         "run_mode": "auto", "idempotent": true },
       { "id": "2", "pad_hint": "File.WriteText",
         "params": { "File": "{{variables.OutputFile}}", "TextToWrite": "{{1.FileContent}}",
                     "IfFileExists": "Overwrite", "AppendNewLine": false, "Encoding": "UTF8" },
         "run_mode": "auto", "idempotent": true }
     ]
   }
   ```

   Key points: `budget` is required; parameter values use `{{variables.X}}` / `{{1.FileContent}}`; string
   literals are written as `$'''…'''`.
   `trigger` **accepts only `kind`** (`manual` / `schedule` / `file`), and `manual` allows only
   `{ "kind": "manual" }`; the old shape `{ "type": "...", "config": {...} }` is reported as
   `TRIGGER_LEGACY_SHAPE` with no silent mapping. Full fields:
   [trigger-adapter-design.md](trigger-adapter-design.md).
   **The design rules require every node** (control nodes included) to declare `run_mode`
   (auto/confirm/observe) and `idempotent` (its semantics are "rerun safety": when false, add one or two
   sentences of Chinese `idempotency_note` describing what a rerun does).
   Note that these two are **a gate for design and structural assertions, not a global hard check in the
   generator**: a flow missing the fields can still generate `.robin`, and enforcement comes from the
   mandatory-answer process in `skills/pad-flow-designer` plus the `nodeDeclaration` / `declarationsComplete`
   assertions in the cases (every node in the `tests/eval/fixtures` samples declares them, so copy from there).
   Do not generate flow.json until both are answered. This toolchain does no automatic retry: a failed run is
   always "alert + manual rerun", so the field is never used to unlock automation.
   Steps that read external files also declare **node-level `inputs`** (`dir` uses `{{config.<KEY>}}`,
   `pattern` is a wildcard, `required` is an explicit boolean). The field is used only for admission and
   structural checks and **never enters the generated `.robin`**.

4. Produce the companion declarations (admission blocks without them):
   - `business/flows/copy-text.requirements.json`: environment dependencies. The minimal content is
     `{ "checks": [] }` (this example depends on no external environment). A real flow uses these fields:

     ```json
     {
       "checks": [
         { "name": "PAD root directory", "type": "dirs", "base": "PadRoot",
           "paths": ["Scripts", "Results"], "hint": "install or copy the PAD deployment package first" }
       ]
     }
     ```

     Fields: `name` is the check name; `type` is `dirs` (subdirectories present) or `files` (files present);
     `base` references a variable name from `flow.json`; `paths` are sub-paths relative to `base`;
     `hint` is the advice shown to a human on failure.
   - `acceptance`: written into flow.json (the example above already contains one `fileExists` criterion), or
     split into `business/flows/copy-text.acceptance.json`. Generate the criteria file:

     ```powershell
     .\tools\pad-sync\build-acceptance.ps1 -FlowFile business\flows\copy-text.json -OutFile business\flows\copy-text.acceptance.json
     # expected tool output: [build-acceptance] 已生成 …（1 条判据）
     ```

     Note that `acceptance.checks` is required: without it the tool reports
     `Write-Error: flow.json 里没有 acceptance.checks，无法生成验收判据`.
   - `business/tests/eval/copy-text.cases.json`: turn "the facts that must hold for this requirement" into
     assertions. **Do not run the repository's `tests/eval/*.cases.json` directly** — those score the neutral
     samples shipped with the repository, not the flow you wrote. Copy one and point `flow` at your own file:

     ```powershell
     Copy-Item tests\eval\file-copy-text.cases.json business\tests\eval\copy-text.cases.json
     # open the file, change "flow" to "business/flows/copy-text.json", and add or remove assertions to match your requirement
     ```

> **Boundary between samples and business cases**: `tests/eval/fixtures` (16 neutral synthetic samples:
> 10 flows + 6 triggers) and `tests/eval/*.cases.json` (11 case files containing structural assertions) ship
> with the repository for demos and CI. Assertions for real flows always live in `business/tests/eval/`
> (that directory is never committed). Both share the same format and the same command: `eval-flow.js` accepts
> a single case file or a whole directory.

**Four-step verification** (order matters)

```powershell
node tools\pad-robin\flow-to-robin.js business\flows\copy-text.json out.robin
node tools\pad-robin\check.js out.robin
.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\copy-text.json -RobinFile out.robin
node tools\pad-robin\eval-flow.js business\tests\eval\copy-text.cases.json
```

Expected output (the numbers below are measured values from this repository):

```text
已生成: out.robin（2 个节点）          <- tool output: the generator writes this to stderr, which is normal
OK   out.robin: 2 action lines, 0 errors
[admit] 通过 10 / 警告 6 / 待批 0 / 失败 0
PASS  read-then-write  需求：先读源文件，再写目标文件
PASS  content-passed-through  需求：写的内容来自上一步读取结果，不能是空串
[eval-flow] 通过 2 / 2（1 个流程样例）
```

The 6 warnings are **informational**, not failures. In order:

| Check | Code | Why it is normal |
|---|---|---|
| `ACCEPTANCE` | `ACCEPTANCE_MISSING` | The criteria file has not been generated yet. Running `build-acceptance.ps1` from step 4 turns it into a pass (11 passed / 5 warnings) |
| `CONFIG` | `CONFIG_MISSING` | The local `business\config\runtime.json` has not been filled in per `docs\config.example.json` yet |
| `PREFLIGHT` | `PREFLIGHT_SKIPPED` | Without a config the preflight probe cannot run, so it is skipped rather than failed |
| `FINGERPRINT` | `FINGERPRINT_NO_BASELINE` | A new flow has no fingerprint baseline on its first run (older versions treated this as fail; it is now a warning) |
| `SCRIPT_FINGERPRINT` | `FINGERPRINT_NO_BASELINE` | Same as above; the baseline seed covers both the artifact and the scripts |
| `INPUT` | `INPUT_UNDECLARED` | This example "copies two given paths" and does not depend on input files in a directory; a real flow that declares node-level `inputs` turns this into a pass |

As long as there is no `[FAIL]`, none of these 6 warnings block delivery. Two common variants:

- If `trigger` still uses the old `type` shape, one more `TRIGGER_LEGACY_SHAPE` appears (that is
  **9 passed / 7 warnings**); change it to `kind` as described above to remove it.
- If the criteria file was generated per step 4, `ACCEPTANCE` becomes a pass and the result is
  **11 passed / 5 warnings**.
- After the first publish and one real run, seed the baseline with `pad-fingerprint -Set`; both fingerprint
  checks then pass on the next run.

Finally: create a new PAD flow → paste `out.robin` → fill in UI elements (this example has none) → run.

---

## 2. Batch scoring: measure "generation quality", not "whether this one run worked"

The fixed requirement set is `tests/eval/*.cases.json` (11 files: assertions for 10 flow samples plus 1 trigger
assertion). The `flow` field in each case file points at the `flow.json` under test.

**Scoring procedure**

1. Give the original text of the 10 flow requirements to Agent A and require each output to land in
   `candidates/<requirement id>.json`
2. Prepare scoring rules per requirement (reuse the existing `*.cases.json` and repoint `flow` at the candidate file)
3. Run four things per candidate: **structural assertions → generate → static check → admission**
4. Record them in a table

**One command to run it all (PowerShell example)**

```powershell
$rows = @()
Get-ChildItem candidates\*.json | ForEach-Object {
    $id = $_.BaseName
    # assertions for public samples live in tests\eval; those for real flows live in business\tests\eval (never committed)
    $casesBiz = "business\tests\eval\$id.cases.json"
    $cases = if (Test-Path $casesBiz) { $casesBiz } else { "tests\eval\$id.cases.json" }
    $out = "candidates\$id.robin"
    $struct = "skip"
    if (Test-Path $cases) {
        node tools\pad-robin\eval-flow.js $cases *> $null; $struct = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    }
    node tools\pad-robin\flow-to-robin.js $_.FullName $out --no-check 2>$null
    $gen = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    $chk = "-"
    if ($gen -eq "PASS") {
        node tools\pad-robin\check.js $out *> $null; $chk = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File tools\pad-sync\pad-admit.ps1 -FlowFile $_.FullName -RobinFile $out *> $null
    $admit = if ($LASTEXITCODE -eq 0) { "PASS" } else { "FAIL" }
    $rows += [pscustomobject]@{ Requirement = $id; Structure = $struct; Generate = $gen; Static = $chk; Admit = $admit }
}
$rows | Format-Table -AutoSize
"deliverable rate = {0:P0}" -f (($rows | Where-Object { $_.Structure -eq 'PASS' -and $_.Generate -eq 'PASS' -and $_.Static -eq 'PASS' -and $_.Admit -eq 'PASS' }).Count / $rows.Count)
```

**Scoreboard template**

| Requirement id | Structural assertions | Generate | Static check | Admission | Verdict |
|---|---|---|---|---|---|
| foreach-archive | PASS | PASS | PASS | PASS | Deliverable |
| switch-exit-code | PASS | PASS | FAIL | - | Design right, parameter wrong |
| http-webhook | FAIL | - | - | - | Design wrong (missing failure branch) |

Decision criteria:

- **All four green** → deliverable (a human still has to review the business semantics)
- **Structure green, a later stage red** → the design is right and a parameter/variable is wrong; the
  "auto-fixable" class
- **Structure red** → the requirement was understood wrongly; changing parameters will not help and you must
  return to design

**Two disciplines**

1. The pass rate measures **structure and generability only**, not wording or business correctness — amounts,
   batches and accounting conventions still need human confirmation.
2. Only a fixed requirement set is comparable. Changing a requirement is changing the exam, so historical pass
   rates cannot be compared directly; add a new row for a new requirement and record its start date.
