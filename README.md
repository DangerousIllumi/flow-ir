# flow-ir

An engine-agnostic intermediate representation (IR) for business processes, plus a multi-engine adapter toolchain.

`flow.json` is the single source of truth. It describes a business process in engine-neutral terms — nodes,
branches, guards, budgets, idempotency and reversibility, trigger conditions. The toolchain reads that IR,
runs design checks, compiles it, statically validates the output, and applies admission review; an adapter
then lands the IR on a concrete engine.

> **Only one adapter is implemented today: PAD (Power Automate Desktop / Robin).** It generates `.robin`,
> statically validates it, admits it, injects and publishes it, and handles scheduling and monitoring.
> Other engines (another RPA product, cloud flows, Python/VBS) are extension points that are **not implemented**:
> adding one means adding a "read the IR, emit this engine's artifact" generator and validator — the IR and the
> gates stay unchanged. The adapter code lives in `tools/pad-robin/` and `tools/pad-sync/`.

Pipeline: IR (`flow.json`) → design check → compile → static check → admission → adapter landing (today: PAD / Robin) → scheduling and monitoring.

Two audiences: business colleagues who want an AI assistant to build their RPA, and developers who will take over or extend this toolchain.

---

## Layering: the IR is the source of truth, engines are replaceable back ends

| Layer | Responsibility | Status |
|---|---|---|
| IR | `flow.json` plus its companion contracts (requirements / acceptance / cases): nodes, edges, `guard`, `budget`, idempotency, reversibility, `trigger` | Stable; every check and generator reads it |
| IR checks | Canvas vs `edges` consistency, requirement-level structural assertions | Engine-agnostic, implemented |
| PAD adapter | `.robin` generation, `.robin` static checks, admission, injection, publishing, rollback, scheduling, telemetry, acceptance | **The only implemented adapter**, in `tools/pad-robin/`, `tools/pad-sync/` |
| Other engine adapters | Another RPA product, cloud flows, Python/VBS | **Not implemented**; new adapters must not bypass the same IR checks and hard rules |

PAD-specific things belong to the adapter, not to the IR. The action table comes from the PAD action knowledge
base; `.robin` syntax, UI selectors and injection-based publishing only exist in the PAD adapter. To be precise:
the `pad_hint` field in `flow.json` is today a lookup key for the PAD adapter. The IR structures — nodes, edges,
`guard`, `budget` — are engine-neutral and stay as they are when the engine changes; a new adapter interprets
the action-layer hint fields against its own action table.

---

## Tool layer and business layer

This repository separates the two strictly:

| Layer | Contents | Committed? |
|---|---|---|
| Tool layer | `tools/`, `docs/`, `tests/`, `skills/`, `AGENTS.md`, `setup.ps1`, `.github/`, `.githooks/` | Committed, public |
| Business layer | Flow definitions, deployment config, admission policy, internal docs, business scripts, logs, snapshots, fingerprints under `business/` | **Never committed** |

`business/` is ignored **as a whole directory** by `.gitignore`: `git status` never shows its files, and both the
`pre-commit` hook and the public-content gate hard-block paths under it (exit code 2).

A local workspace may keep business flows and internal documents under `business/`; nothing there is committed,
and **a fresh clone starts empty**. In other words: the repository distributes the toolchain itself. Business
processes exist only on the user's own machine and never leak through the repository.

---

## What it can and cannot do

| Can do | How |
|---|---|
| Turn a plain-language requirement into a **reviewable structured definition** (IR: `flow.json` + flowchart) | An AI assistant following [AGENTS.md](AGENTS.md) and [skills/pad-flow-designer](skills/pad-flow-designer/SKILL.md) |
| **Deterministically compile** the IR into the target engine's artifact (the current adapter emits `.robin`) | The adapter fills in blanks from the action table; a made-up action or parameter is rejected outright |
| **Static checks** before and after compiling: IR structure (`edges` / variable references) and artifact syntax | `check.js` / `check-flows.js` / `lint-robin.js` / `check-flow.js` (the `.robin` part belongs to the PAD adapter) |
| **Admission**: is the action registered, does it need a UI selector, is there a budget, is the trigger declared, does the policy deny/ask/allow | `pad-admit.ps1` (16 read-only checks, part of the PAD adapter) |
| **Skippable side effects**: sending mail, posting documents, deleting files wrapped in `guard` and controlled by `DRY_RUN` | IR structure, generator and admission policy, layered |
| Injecting into the designer, publishing, rollback, scheduling, telemetry, artifact acceptance (PAD adapter) | `tools/pad-sync/` |

| Cannot do | Why |
|---|---|
| Understand natural language by itself | There is no NL parser in this repository; "requirement → `flow.json`" is done by **the AI assistant you configure**, this repository supplies the prompts, contracts and yardsticks |
| Record UI elements for you | Actions that need selectors (parts of web/desktop automation) must be recorded by a human in PAD; the generator refuses them by design |
| Generate SAP VBS scripts | Transaction exports and posting scripts are recording artifacts and are not distributed with this repository |
| Press publish for production on your behalf | `pad-deploy` / `pad-release` trigger real runs and require human confirmation |
| Provide ready-made adapters beyond PAD | PAD is the only adapter today; other engines need a new generator/validator pair that reads the IR and emits that engine's artifact |

**In one sentence**: `AI assistant + this repository + the action knowledge base` together form the
"natural language → runnable process" loop (PAD is the current engine). Without the AI, you can still start from
`flow.json`.

---

## Requirements

| Dependency | Required | Purpose |
|---|---|---|
| Node.js ≥ 18 | Yes | Adapter implementation, flow diagrams, evaluation sets |
| Git | Yes | Cloning the action knowledge base, enabling the pre-commit hook |
| PowerShell 5.1+ | Yes | Admission / deploy / release / scheduling (PAD adapter) |
| Power Automate Desktop (Windows) | Required to run flows | Executes `.robin` (the only adapter today) |
| Python 3.x + openpyxl | No | Workday calendar checks, Excel assertions in acceptance |
| An AI coding assistant (any) | No | Writing `flow.json` from natural language |

> Running desktop flows requires an appropriate PAD license. The "flow diagram mode" and "flow checker" in the
> designer are not separately paid features.

---

## Quick start

```powershell
git clone https://github.com/DangerousIllumi/flow-ir.git flow-ir
cd flow-ir
.\tools\check-env.ps1    # verify Node >= 18, Git and PowerShell
.\setup.ps1              # install Node deps, enable the pre-commit gate, clone the action knowledge base

# Verify the environment (no business/, no action knowledge base, no node_modules needed; exits 0 when green)
.\examples\smoke.ps1
```

`setup.ps1` does four things:

1. Checks Node.js / Git versions.
2. Installs Node dependencies (used by automatic diagram layout) and sets `core.hooksPath=.githooks`.
3. Clones `pad-robin-action-kb` (the action table used by the PAD adapter) and validates key files, falling back to SSH when HTTPS fails.
4. Creates `business\flows`.

> On restricted networks or behind a proxy/firewall, direct HTTPS access to GitHub may be blocked
> (the usual error is `Recv failure: Connection was reset`).
> Use SSH instead: `git clone git@github.com:DangerousIllumi/flow-ir.git flow-ir`.
> Cloning is enough to use the toolchain; fork only if you intend to change the toolchain itself.
> If PowerShell says "running scripts is disabled on this system", use
> `powershell -ExecutionPolicy Bypass -File .\setup.ps1`.

> **A fresh clone must rebuild the real denylist by hand**: `tools\publish\public-safe.denylist.local.json` is
> not in the repository (it is ignored by `.gitignore`). Without that file, `check-public-safe.ps1` loads only the
> placeholder rules from `public-safe.denylist.json` and cannot catch real business names, flow names or internal
> paths. To rebuild it, follow the category structure of `public-safe.denylist.json`
> (`businessName` / `flowName` / `realPath` / `accountOrServer` / `privateIdentifier`), create a JSON file with the
> same shape, fill in your own real terms, and save it at the same path. **Never commit that file.**

**Shortest path when you have an AI assistant**: in an AI coding assistant that has this directory open, send
this as your first message (a bare link is not enough — without opening the directory the AI cannot see
`AGENTS.md`):

```text
Read AGENTS.md and follow docs/prompts/nl-to-flow.md: run .\setup.ps1 first, then turn the requirement below into business/flows/<name>.json, going through design → generate → static check → admission.

Requirement: <your requirement here, e.g. "every day copy the CSVs in the source directory to the archive directory, overwrite same-name files, then show a popup with the count">
```

After that you only need to:

1. Let the AI read `AGENTS.md` and `docs/prompts/nl-to-flow.md` itself; you do not have to relay their contents.
2. When it finishes generate → static check → admission, select everything in `out.robin`, copy it and paste it
   into the canvas of a new PAD flow (`Ctrl+V`) — this is the closing step of the current PAD adapter.
3. The delivery bar is in AGENTS.md section 6: generator 0 errors, `check.js` 0 errors, admission 0 fails,
   plus an explicit list of what you still have to do by hand (UI elements / scripts / accounts).

---

## Standard workflow (six steps)

Without an AI assistant, start from an existing `flow.json`. The six steps below are the **current PAD adapter**;
the IR layer itself is only `flow.json` plus its companion contracts, so switching engines means replacing the
commands in this section:

```powershell
# 1) Draw a review diagram (optional) and check that edges agree with next/branch (IR layer, engine-agnostic)
node tools\flow-drawio\flow-to-drawio.js business\flows\<name>.json business\flows\<name>.drawio
node tools\flow-drawio\check-flow.js business\flows\<name>.json

# 2) Generate (current adapter: IR → .robin)
node tools\pad-robin\flow-to-robin.js business\flows\<name>.json out.robin

# 3) Static check the artifact (0 errors required to continue; PAD adapter)
node tools\pad-robin\check.js out.robin

# 4) Flow hygiene (unread outputs / unused variables / deep IF nesting; advisory, non-blocking; PAD adapter)
node tools\pad-robin\lint-robin.js out.robin

# 5) Admission (read-only, 0 fails required to deliver; PAD adapter)
.\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<name>.json -RobinFile out.robin

# 6) Structural evaluation (requirement-level assertions, reads only the IR, engine-agnostic)
node tools\pad-robin\eval-flow.js business\tests\eval\<name>.cases.json
```

- For how to write `flow.json`, see [docs/agent-prompts.md](docs/agent-prompts.md).
- Copy-ready neutral samples live in [tests/eval/fixtures](tests/eval/fixtures): 16 synthetic samples
  (10 flows + 6 triggers), with 11 matching `*.cases.json` files in [tests/eval](tests/eval); the whole directory
  runs at once with `node tools\pad-robin\eval-flow.js tests\eval`.
- Business cases go under `business\tests\eval\` as described in AGENTS.md (never committed).
- A `trigger` declares only `kind` (`manual` / `schedule` / `file`); the old shape
  `{ "type": "...", "config": {...} }` is reported as `TRIGGER_LEGACY_SHAPE`. Field reference:
  [docs/trigger-adapter-design.md](docs/trigger-adapter-design.md).

### Going live (requires a real PAD machine)

```powershell
# Runtime config (used by admission / preflight / injection runs): fill in real local paths based on the neutral template
Copy-Item docs\config.example.json business\config\runtime.json

# Per-flow deployment config: <flow name>.json, whose fields are defined by <flow name>.schema.json in the same directory (neither is committed)
.\tools\pad-sync\pad-deploy.ps1 -FlowName <PAD flow name> -SourceRobin business\flows\<name>.robin -ConfigFile business\config\<name>.json -AllowProd -SkipConfirm -PublishOnly
```

- `pad-deploy` replaces `{{KEY}}` placeholders, injects into the designer, publishes and verifies the hash;
  use `-ValidateOnly` to validate the config without injecting.
- `pad-release` adds "test summary → human confirmation (three-hash fingerprint) → snapshot".
- `pad-rollback` restores from a snapshot; `pad-schedule` / `pad-trigger` own scheduling and trigger registration.

To check the artifact on its own afterwards (read-only, no PAD involved):

```powershell
.\tools\pad-sync\pad-verify.ps1 -AcceptanceFile business\flows\<name>.acceptance.json -ConfigFile business\config\<name>.json
```

---

## Tool directories

| Directory | Purpose |
|---|---|
| `tools/check-env.ps1` | Environment check (Node / Git / PowerShell) |
| `tools/flow-drawio/` | IR layer: `flow.json` ↔ `.drawio` canvas; `check-flow.js` validates edge consistency |
| `tools/pad-robin/` | PAD adapter: compile (`flow-to-robin.js`), artifact static checks (`check.js` / `check-flows.js`), flow hygiene (`lint-robin.js`), generation diffing (`compare-robin.js`); also `eval-flow.js`, which reads only the IR |
| `tools/pad-sync/` | PAD adapter: read-only admission (`pad-admit.ps1`), deploy (`pad-deploy.ps1`), release (`pad-release.ps1`), rollback (`pad-rollback.ps1`), scheduling (`pad-schedule.ps1`), trigger registration (`pad-trigger.ps1`), injection runs (`pad-sync.ps1`), fingerprints (`pad-fingerprint.ps1`), acceptance (`pad-verify.ps1`), plus shared modules for alerts / preflight / telemetry / encoding |
| `tools/publish/` | Pre-push content gate `check-public-safe.ps1` and its structured denylist (engine-agnostic) |
| `tools/workday/` | Workday calendar checks (general-purpose, reusable on its own) |
| `skills/` | `pad-flow-designer` (rules for requirement → `flow.json`) and `pad-robin-coder` (red lines when writing PAD scripts) |
| `tests/` | Pester unit tests, Python tests, the public evaluation set and telemetry samples |

Ownership: `tools/flow-drawio/`, `eval-flow.js`, `tools/publish/` and `tools/workday/` only deal with the IR or
engine-agnostic jobs. Generation and `.robin` checks in `tools/pad-robin/`, and all of `tools/pad-sync/`, belong to
the **current PAD adapter** and must be implemented separately for another engine.

---

## Three hard rules

Violating any of them makes the tool refuse outright — no half-finished artifacts. They are enforced by the
**current PAD adapter**; any future engine adapter must reuse the same constraints rather than invent its own:

1. **Never invent actions**: `pad_hint` must be a real three-part `actionId` from the action knowledge base.
2. **Never invent parameters**: every key in `params` must be a real parameter name from that action's `input_params`.
3. **Side effects must be skippable**: sending mail, posting documents and deleting files go inside `guard`
   (condition `DryRun <> $'''1'''`); `flow.json` must declare a `budget`; `Scripting.RunDOSCommand*` /
   `Scripting.RunVBScript*` nodes must carry an `intent`.

---

## Gates and fingerprints

Two gates, each answering a different question:

| Gate | Question | Key implementation |
|---|---|---|
| Content scan | **Can these files be pushed?** (File-level compliance is not enough — business names and real paths in comments can still leak, so every line is scanned) | `tools/publish/check-public-safe.ps1`: any denylist hit fails; a `business/` path is rejected outright (exit code 2). The `pre-commit` hook scans the staged set; CI backstops with `git ls-files` |
| Admission gate | **Can this flow / this run execute?** (16 read-only checks, all findings returned in one pass) | `tools/pad-sync/pad-admit.ps1` (PAD adapter): exit `0` pass / `1` has fails / `2` only asks |

**Fingerprints (PAD adapter)**: after publishing, the SHA256 of three inputs — the `.robin`, the deployment config
and the acceptance criteria — is written into a baseline (v3 also records the scripts the flow actually
references). Admission compares against that baseline; a mismatch is a `fail` by default and blocks outright.
Baseline data lives only in `business/fingerprints/<flow name>.json` and is never committed. Other engine adapters
need their own equivalent, but the idea — seed a baseline first, compare before running — should stay the same.

Business layer and public boundary details: section 9 of [docs/admission-gate.md](docs/admission-gate.md).

---

## Contract files

| File | Question it answers |
|---|---|
| `business/flows/<name>.json` | What the flow looks like (nodes, edges, parameters, variables, budget, trigger declaration) |
| `business/flows/<name>.requirements.json` | What must exist in the environment before it runs (directories, files, executables) |
| `business/flows/<name>.acceptance.json` | What counts as success after a run (artifact exists / is updated / content matches) |
| `business/config/<name>.json` + `<name>.schema.json` | What the placeholders resolve to at deploy time, and whether the config itself is valid |
| `business/tests/eval/<name>.cases.json` | Structural assertions the requirement must satisfy (usable as regression tests) |

Acceptance criteria support `fileExists` / `globNewerThan` / `pair` / `json` / `jsonl` / `logState`.
The contract formats are engine-agnostic; the deploy/acceptance executors that consume them (placeholder
substitution, criterion evaluation) currently live in `tools/pad-sync/` and belong to the PAD adapter.
A new engine can reuse the contract formats but must rewrite the executors.

---

## Directory layout

```
.
├── AGENTS.md                  Entry manual for AI assistants (read this first)
├── README.md                  This file
├── setup.ps1                  One-shot setup of Node deps, hooks and the action knowledge base
├── tools/                     Tool layer
│   ├── check-env.ps1          Environment check
│   ├── flow-drawio/           IR layer: flow.json ↔ .drawio, edge consistency checks
│   ├── pad-robin/             PAD adapter: compiler, artifact checks, flow hygiene, diffing; plus IR-only eval-flow.js
│   ├── pad-sync/              PAD adapter: admission, deploy, release, rollback, scheduling, trigger registration, injection runs, telemetry, acceptance
│   ├── publish/               Pre-push content gate + denylist (engine-agnostic)
│   └── workday/               Workday calendar checks
├── docs/                      Documentation layer (prompts, admission and script standards)
├── skills/                    Design rules and script red lines
├── tests/                     Pester / Python tests + public evaluation set
├── .githooks/                 pre-commit content gate
├── .github/workflows/ci.yml   On Windows: pytest / Pester / Node / evaluation set / admission sample
├── pad-robin-action-kb/       Action knowledge base (not committed; cloned by setup.ps1)
├── node_modules/              Node dependencies (not committed)
└── business/                  Business layer: local workspace, not committed, empty after a clone
    ├── flows/                 Flow definitions and companion criteria
    ├── config/                Deployment config and schemas
    ├── policy.json            Admission policy (deny / ask / allow)
    ├── docs/                  Runbooks and internal notes
    ├── scripts/               VBS / PowerShell recording artifacts referenced by flows
    ├── tools/                 Business-only scripts and synthetic data generators
    ├── tests/                 Business regression cases and structural assertions
    ├── fingerprints/          Publish baselines (machine names and real paths; never committed)
    ├── logs/ snapshots/ worklog/ manifest.jsonl
```

---

## Design principles

- **Single design source**: `flow.json` is the only editable source; `.robin` is an artifact, and edits to it are
  overwritten on the next generation. CI hard-asserts that "a fresh generation == the script in the repository"
  whenever `business/` is present.
- **Engine replaceable**: IR structures hard-code no engine assumption; adding an engine means adding an adapter,
  not changing the IR or the gates.
- **Determinism first**: compilation never calls a model, it only looks things up in tables; the model appears
  only when writing `flow.json`.
- **Fail early**: errors that can be caught before compiling (action names, parameter names, dangling references,
  unbounded loops, policy hits) never reach run time.
- **Side effects reversible**: run the branches under `DRY_RUN` first, then go live; publishing has snapshots and
  rollback.

---

## Troubleshooting

| Symptom | Meaning | What to do |
|---|---|---|
| `unknown action pad_hint="..."` / `unknown parameter "..."` | The `flow.json` is wrong; the generator is not broken | Fix `flow.json`; do not edit the generator and do not hand-edit `.robin` |
| `variable X is used but never set in this script` | A variable was used without being SET or produced by an action | Declare the variable, or fix the `{{node-id.output}}` reference |
| `[BAD] edges disagree with next/branch` | The diagram edges drifted from the structure used for generation | Add the missing `edges` entries as the error asks |
| Admission `POLICY_DENY` | A deny rule in `business/policy.json` was hit | Remove the action or change the condition; do not bypass it |
| Admission `MISSING_INTENT` / `BUDGET_UNKNOWN` | A mandatory declaration is missing | Add `intent` / `budget` |
| Structural evaluation: missing declaration node / `run_mode=` | "Run mode / idempotency" was never answered | Add `run_mode` / `idempotent` / `idempotency_note`; never fill them in by default |
| `[error] PAD_Robin_ActionKB.json not found` | `setup.ps1` was not run | Run the environment setup from Quick start |
| Pasting into the canvas yields an empty flow and no error | PAD most likely silently dropped the syntax | Run `node tools\pad-robin\check.js out.robin`; it reports the line and identifier |

**`git clone` of the knowledge base fails?** Download the ZIP from
<https://github.com/JoeG592/pad-robin-action-kb> and extract it into `pad-robin-action-kb\`.

**PowerShell says "running scripts is disabled on this system"?**

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

**Editing `.robin` makes production drift?** That is expected: `.robin` is an artifact. Edit `flow.json` and
regenerate. The designer's "apply fix" behaves the same way — don't use it.

**Does it run on Linux/CI?** Compiling, static checks, evaluation sets and diagram generation all do. Injection
into PAD, running and publishing require Windows with PAD installed.

---

## Companion action knowledge base (PAD adapter)

The PAD adapter's generator accepts only three-part `actionId` values and real parameter names that exist in the
knowledge base; anything else is refused. The IR layer does not depend on it — a different engine needs that
engine's own action table.

| Repository | What it provides | Required? |
|---|---|---|
| **This repository** | IR (`flow.json`), IR checks and evaluation sets, PAD adapter (generate / admit / publish / rollback / schedule), prompts and skills | Yes |
| [pad-robin-action-kb](https://github.com/JoeG592/pad-robin-action-kb) | The PAD adapter's action table: real `actionId` / parameter names / output names / paste samples for 1,086 actions | **Yes** (`setup.ps1` clones it; it is not committed here) |

---

## Documentation language

Short version: everything committed outside `business/` is English — documents, skills, AI entry files and code
comments — and so are identifiers, rule IDs, exit codes and JSON keys. Text under `business/` stays in the
operator's own language because it is never published. There is no bilingual mirror of any document. Full policy,
both hard rules and their rationale: [docs/doc-language.md](docs/doc-language.md).

---

## License

MIT, see [LICENSE](LICENSE). Third-party components and content not distributed with this repository (such as
the action knowledge base) are listed in [NOTICE](docs/governance/NOTICE).
Report security issues per [SECURITY.md](docs/governance/SECURITY.md); contribution process in
[CONTRIBUTING.md](docs/governance/CONTRIBUTING.md).
