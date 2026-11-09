# Contributing

## Environment

- Windows 10/11 with PowerShell 5.1 (do not run Pester under PowerShell 7; the tests are written in Pester 3.4 syntax)
- Node.js ≥ 18
- Python 3.13 (tests and tooling scripts)
- Power Automate Desktop (needed only for end-to-end testing on a real machine)

First-time setup:

```powershell
.\setup.ps1
```

It installs Node dependencies, clones the action knowledge base `pad-robin-action-kb/`, and creates the
`business/flows/` directory. The knowledge base is a third-party MIT project and is **not committed here**.

## Checks you must run locally

```powershell
python -m pytest tests -q
node --test tools\pad-robin\flow-to-robin.test.js tools\pad-robin\compare-robin.test.js
node tools\flow-drawio\check-flow.js business\flows\<name>.json
node tools\pad-robin\check.js business\flows
node tools\pad-robin\eval-flow.js business\tests\eval\<name>.cases.json
```

Pester (invoked the same way as CI):

```powershell
Import-Module Pester -RequiredVersion 3.4.0 -Force
Get-ChildItem tests\*.Tests.ps1 | ForEach-Object { Invoke-Pester -Script $_.FullName -PassThru }
```

## Core conventions

1. **`flow.json` is the only design source.** Do not edit `.robin` directly: change
   `business/flows/<name>.json`, regenerate, then run
   `node tools/pad-robin/compare-robin.js <generated .robin> business/flows/<name>.robin` to confirm they match.
   In CI this is a hard failure.
2. **`.ps1` / `.psm1` files must stay UTF-8 with BOM.** PowerShell 5.1 parses BOM-less non-ASCII text as ANSI,
   producing puzzling syntax errors.
3. **Everything committed outside `business/` is written in English**: documents, code comments, log wording.
   Identifiers, rule IDs, exit codes and JSON keys are English too. Text under `business/` stays in the
   operator's own language; see [docs/doc-language.md](../doc-language.md).
4. For a new action, look up its `actionId` in the KB; never invent one from memory. The generator refuses to
   produce anything it cannot look up.
5. New acceptance criteria go into the `acceptance` declaration in `flow.json` and are rendered into
   `*.acceptance.json` by `tools\pad-sync\build-acceptance.ps1`. Never hand-write a second copy.
6. Before committing, confirm you are not carrying any of the following along (the whole `business/` directory
   is already in `.gitignore`):
   `business/config/*.json` (real config), `business/snapshots/`, `business/manifest.jsonl`, `business/logs/`,
   `*.deployed.robin`, `pad-robin-action-kb/`, `business/worklog/`.
   The push gate rejects `business/` paths outright (exit code 2).
7. Business-specific reconciliation scripts and synthetic data generators also live in `business/tools/` and
   never enter the public repository.

## Pre-commit checklist

- [ ] All test commands pass
- [ ] If `flow.json` changed, the `.robin` was regenerated and `compare-robin` reports a match
- [ ] If a `.ps1` changed, the file still carries a BOM and `pad-admit.ps1` exits 0 end to end
- [ ] Numbers in the docs (poll counts, timings, switches, sample counts) match the code and the actual files
      (grounded in `eval-flow.js tests/eval` and the admission output)
- [ ] No real email addresses, employee IDs, intranet addresses or business data
