# AGENTS.md — entry notes for AI assistants

> You (the AI assistant) are in a **PAD workflow toolchain** repository. Users describe a process in natural
> language; you turn it into a Robin script that can be pasted into Power Automate Desktop.
> This file is your operating manual: **read it fully before doing anything**.

> **Just want to understand the project?** Read [`llms.txt`](llms.txt): the engine-agnostic IR and multi-engine
> adapter positioning, layer ownership, red lines and the documentation index.
> **About to change a flow or a script?** Keep reading — this file is the operating manual, so do not start work
> from the summary alone.
> **Changing documentation wording or adding a document?** Read
> [`docs/doc-language.md`](docs/doc-language.md) first: it defines which document uses which language, plus the
> two hard rules (one language per document; machine-consumed output must keep an ASCII anchor).

## 0. Prepare the environment once

```powershell
.\setup.ps1          # install Node dependencies + clone the action knowledge base pad-robin-action-kb/
.\tools\check-env.ps1
```

- The knowledge base is **required**: the generator looks actions up precisely there and refuses to produce
  anything it cannot find.
- `.ps1` / `.psm1` files must stay **UTF-8 with BOM** (PowerShell 5.1 misparses BOM-less Chinese text).
- Create the `business/flows/` directory yourself when it does not exist.

## 1. Repository map

| Path | Purpose |
|---|---|
| `tools/flow-drawio/` | `flow.json → .drawio` canvas, `check-flow.js` edge consistency, `example-flow.json` runnable example |
| `tools/pad-robin/` | `flow-to-robin.js` generator, `check.js` static checks, `compare-robin.js` diffing, `eval-flow.js` structural evaluation |
| `tools/pad-sync/` | `pad-admit.ps1` read-only admission gate, `pad-sync.ps1` injection/run, `pad-deploy/-release/-rollback/-schedule` |
| `tools/workday/` | Workday calendar checks (general-purpose) |
| `tools/xlsx/` | Read-only Excel layer (general-purpose): column lookup by header name, lenient date/number conversion, header inspection entry point (`--dump`) |
| `tools/publish/` | Public-content denylist scan `check-public-safe.ps1`: blocks business terms and internal paths before a push |
| `skills/pad-flow-designer/` | Design rules for requirement → `flow.json` |
| `skills/pad-robin-coder/` | Red lines for writing scripts |
| `docs/nl-to-flow-guide.md` | Complete example: one sentence → flow.json → the four checks |
| `docs/engine-selection.md` | Which lane (Python / PowerShell / PAD) a step belongs to; records that only the PAD adapter exists |
| `tests/eval/` | 18 synthetic samples (11 flows + 6 triggers + 1 reversibility counterexample) plus structural assertions, ready to copy |

## 1.5 Directory convention (tools and business strictly separated)

| Layer | Directories | Publicly visible |
|---|---|---|
| Tools / docs / tests / skills | `tools/`, `docs/`, `tests/`, `skills/`, `docs/prompts/` | Yes |
| Business | `business/` (`flows/`, `config/`, `docs/`, `policy.json`, `manifest.jsonl`, `logs/`, `snapshots/`, `worklog/`) | **Never**, ignored by `.gitignore` and hard-blocked by the push gate |
| AI entry points | `AGENTS.md`, `README.md` in the repository root | Yes |

Business files simply go under `business/`; `git status` will not show them, and the push gate exits with code 2
when it encounters one.

## 2. Three hard rules (violations are rejected by the tools)

1. **Never invent actions**: `pad_hint` must be a real three-part `actionId` from `pad-robin-action-kb/PAD_Robin_ActionKB.json`.
2. **Never invent parameters**: every key in `params` must be a real parameter name from that action's `input_params`.
3. **Side effects must be skippable**: sending mail, posting documents and deleting files go inside a `guard`
   node (condition `DryRun <> $'''1'''`), and `flow.json` must declare a `budget`;
   `Scripting.RunDOSCommand*` / `RunVBScript*` nodes must carry an `intent`.

Trigger declarations have exactly one accepted shape: `"trigger": { "kind": "manual" | "schedule" | "file" }`.
`manual` allows only `{ "kind": "manual" }`. The old shape `{ "type": "...", "config": {...} }` is reported as
`TRIGGER_LEGACY_SHAPE` (no silent mapping); the full field reference is in `docs/trigger-adapter-design.md`.

Supplementary coding principle: all py / vbs / PAD / ps1 code follows the **Occam's razor** rule in
`docs/script-standards.md` — do only what the current requirement needs, reuse instead of creating, delete
instead of adding. Side-effect guards, idempotency, audit trails and error handling are exempt from that rule.

## 3. Standard workflow (follow in order, do not skip steps)

```powershell
# 1) Design: follow skills/pad-flow-designer "mandatory answers before generating flow.json"
#    Ask, per node, for "run mode (auto/confirm/observe)" and "idempotency (true/false + idempotency key)".
#    Do not generate business\flows\<name>.json if the user has not answered these.
# 2) Canvas (optional, for human review)
node tools\flow-drawio\flow-to-drawio.js business\flows\<name>.json business\flows\<name>.drawio
# 3) Generate
node tools\pad-robin\flow-to-robin.js business\flows\<name>.json out.robin
# 4) Static checks (0 errors required to continue)
node tools\pad-robin\check.js out.robin
# 5) Admission (read-only; deliver only with fail=0 and ask=0 — ask exits with code 2 and also blocks)
.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<name>.json -RobinFile out.robin
# 6) Structural evaluation (cases live in business\tests\eval\; only neutral samples go in the public repo)
node tools\pad-robin\eval-flow.js business\tests\eval\<name>.cases.json
```

When everything passes, tell the user:

> Open PAD → create a new flow → paste `out.robin` into the canvas with Ctrl+V → fill in the UI elements the
> prompts ask for → run.

**Reading local Pester output**: `Invoke-Pester tests` may end with process exit code 1 even when the summary says
`Failed: 0`, because some tests spawn child `powershell` processes that exit 1/2 by design and the leftover
`$LASTEXITCODE` becomes the script's exit code. Trust the summary's `failed` count, or clear the variable when you
need a clean exit status: `Invoke-Pester tests; exit 0`. The CI step already ends with `exit 0` for this reason.

## 4. How to handle errors

| Symptom | Meaning | What you do |
|---|---|---|
| `unknown action pad_hint="..."` / `unknown parameter "..."` (tool output) | `flow.json` is wrong; the generator is not broken | Fix `flow.json`; do not touch the generator and do not hand-edit `.robin` |
| `variable X is used but never set in this script` (tool output) | A variable was used without being SET or produced by an action | Declare the variable, or fix the `{{node-id.output}}` reference |
| `[BAD] edges disagree with next/branch` (tool output) | The diagram edges drifted from the generation structure | Add the missing `edges` entries |
| Admission `POLICY_DENY` | A deny rule in `business/policy.json` was hit | Remove the action or change the condition; do not bypass it |
| Admission `MISSING_INTENT` / `BUDGET_UNKNOWN` | A mandatory declaration is missing | Add `intent` / `budget` |
| Structural evaluation: missing declaration node / `run_mode=` | "Run mode / idempotency" was never answered | Ask the user again and add `run_mode` / `idempotent` / `idempotency_note`; never fill them in by default |
| `[error] PAD_Robin_ActionKB.json not found` (tool output) | `setup.ps1` was not run | Run step 0 first |

## 5. Things you explicitly do not do

- **Do not** record UI elements for the user: actions that need a UI selector (parts of web/desktop automation)
  must be recorded by a human in PAD; the generator refuses them.
- **Do not** fabricate SAP scripts: transaction exports and posting VBS files are recording artifacts and are not
  in this repository.
- **Do not** publish to production for the user: `pad-deploy` / `pad-release` trigger real runs and require human
  confirmation.
- **Do not** edit `.robin`: it is an artifact of `flow.json` and edits are overwritten on the next generation.

## 6. Definition of done

A requirement is done only when all of the following hold:

1. `flow.json` passes the generator (0 errors)
2. `check.js` reports 0 errors
3. `pad-admit` reports fail=0 and ask=0 (warnings are acceptable but must be explained to the user; ask exits
   with code 2 and also blocks delivery)
4. The user is told the artifact path, the paste steps, and everything that still needs human work
   (UI elements / VBS / accounts)

See `docs/nl-to-flow-guide.md` for a worked example; the 18 copy-ready samples are in `tests/eval/fixtures/`
(11 flows + 6 triggers + 1 reversibility counterexample).
