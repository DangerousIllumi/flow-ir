# Admission gate checklist (draft)

> Goal: before generating, deploying or running anything, a deterministic checker decides
> "is this flow / this run allowed?"
> Inspired by the admission gate idea in GraphARC, but keeping only the parts that fit PAD RPA.

## 1. Invariants

1. **No action is executed during the check**: PAD is not started, SAP is not contacted, no mail is sent, no artifact is written.
2. **All problems are returned in one pass**: every check runs to completion; the first failure does not abort the run.
3. **No downgrading, no truncation**: "delete half the branches to get it running" is not allowed, and a rejected edge is never downgraded to an allowed one.
4. **Every failure carries evidence**: `code` + human wording + the specific node/parameter/line.
5. **Approvals are bound to fingerprints**: only an approval bound to the current `robin + config + acceptance` hashes is valid.
6. **For unattended runs, ask = deny**: no human is present for a scheduled task, so `ask` always blocks.

## 2. Checks

| # | Check | Input | Pass condition | Failure code | Current implementation |
|---|---|---|---|---|---|
| 1 | REGISTRY | Node `pad_hint` in `flow.json` | Every action exists in the KB | `UNKNOWN_ACTION` | `flow-to-robin.js` safety gate |
| 2 | ARGS | Node `params` | Parameter names exist, required ones present, types match | `UNKNOWN_PARAM` / `MISSING_PARAM` / `TYPE_MISMATCH` | `flow-to-robin.js` |
| 3 | SELECTOR | Action metadata | Actions needing a UI selector must be explicitly allowlisted | `UI_SELECTOR` | `flow-to-robin.js` |
| 4 | STATIC | `.robin` | `check-flows.js` reports 0 errors | `STATIC_SYNTAX` | `tools/pad-robin/check.js` |
| 5 | EDGE | `flow.json` | `edges` covers everything derived from `next/branch`, with no dangling or duplicate edges | `EDGE_DRIFT` / `EDGE_DANGLING` / `EDGE_DUPLICATE` | `tools/flow-drawio/check-flow.js` |
| 6 | BOUNDED | `flow.json` | Loops have an explicit upper bound; no unbounded `LOOP WHILE` | `UNBOUNDED_LOOP` | Partial (manual review) |
| 7 | POLICY | `business/policy.json` + run context | No `deny`; any `ask` has a valid approval | `POLICY_DENY` / `POLICY_ASK` | New |
| 8 | BUDGET | Budget declaration + preflight result | The worst case fits the budget; an undeclared budget is treated as over budget | `BUDGET_EXCEEDED` / `BUDGET_UNKNOWN` | `pad-admit.ps1` (`flow.budget`; undeclared means fail) |
| 9 | ACCEPTANCE | `*.acceptance.json` | Valid JSON, known check types, resolvable placeholders | `ACCEPTANCE_INVALID` | `PadAcceptance.psm1` |
| 10 | CONFIG | `business/config/*.json` + schema | Schema validation passes | `CONFIG_INVALID` | `pad-deploy.ps1` |
| 11 | PREFLIGHT | Machine environment | PAD/Python/SAP/Outlook/directories all present | `PREFLIGHT_MISSING` | `PadPreflight.psm1` |
| 12 | FINGERPRINT | SHA256 of three files + baseline | Matches the approval record or `business/fingerprints/<flow name>.json` | `pass` / `FINGERPRINT_*` (see 2.1) | `PadFingerprint.psm1` (mismatch is fail; a missing baseline is warn in report mode and fail with `-Unattended`) |
| 13 | SCRIPT_FINGERPRINT | Scripts referenced by the flow + the baseline `scripts`/`external` sections | Matches the baseline | `FINGERPRINT_*` / `SCRIPT_FINGERPRINT_LEGACY` | `PadFingerprint.psm1` (a missing or legacy baseline is always warn; FINGERPRINT gates first) |
| 14 | INTENT | Node `intent` / `tags` | Generic actions such as `RunDOSCommand` and `RunVBScript` must carry a semantic tag that policy can match | `MISSING_INTENT` | `pad-admit.ps1` (a missing intent is fail; policy supports `when.intent`) |
| 15 | TRIGGER | The `trigger` block in `flow.json` | Kind domain, required fields, directory must come from a config reference, unattended runs may not require human confirmation | `TRIGGER_*` (see 2.2) | `pad-admit.ps1` (an undeclared trigger is warn during the observation period) |
| 16 | INPUT | Node-level `inputs` declaration + `config` | Directory must come from a config reference; `required` declared explicitly; a required file with 0 candidates fails; ≥2 candidates is always ambiguous | `INPUT_*` (see 2.3) | `pad-admit.ps1` (undeclared is warn, for backward compatibility) |

### 2.1 Fingerprint (FINGERPRINT) result codes

The whole mechanism lives in `tools/pad-sync/PadFingerprint.psm1` and treats every `flow.json` the same way.
Baseline data lives only in the business layer, in `business/fingerprints/<flow name>.json` (containing the flow
name, flowGuid, environmentId, machine name and real paths); it is never committed and never enters the public layer.

| Result code | Meaning | Evidence field `evidence` |
|---|---|---|
| `pass` | Matches the approval record or the baseline | The matched approval record / baseline path |
| `FINGERPRINT_MISMATCH` | Does not match the approval record (always fail) | `approve=` + the three current hashes |
| `FINGERPRINT_UNKNOWN` | `.robin` cannot be read, the flow identity cannot be parsed, or the environment/machine does not match the baseline | `robin=` / `scriptsRoot=` / identity differences |
| `FINGERPRINT_NO_BASELINE` | No baseline yet (the normal state of a flow that has never been published) | `baseline=` + the three current hashes + `fix=` (the seeding command, ready to run) |
| `FINGERPRINT_FLOW_STALE` | The flowGuid behind the baseline has changed | Baseline and current flowGuid |
| `FINGERPRINT_SOURCE_MISMATCH` | The source `.robin` does not match the baseline | Baseline path + current/baseline hash prefixes |
| `FINGERPRINT_CONFIG_STALE` | The deployment config does not match the baseline | Same as above |
| `FINGERPRINT_BASELINE_CORRUPT` | The baseline JSON is corrupt or missing `flow`/`hashes.robin` | `baseline=` |
| `AMBIGUOUS` | The Workspace matched several candidate revisions, so it cannot be determined which one this publish corresponds to | Candidate revision directory names |

### 2.2 Trigger declaration (TRIGGER) result codes

The mechanism is defined in the design doc `docs/trigger-adapter-design.md`; this check is **static** only and
does not query the local scheduled-task registration state.

| Result code | Level | Meaning |
|---|---|---|
| `TRIGGER_MISSING` | warn (observation period) | No `trigger` block; the launch method still relies on verbal agreements |
| `TRIGGER_LEGACY_SHAPE` | warn (observation period) | Only the old `type/config`, no `kind` |
| `TRIGGER_UNKNOWN_KIND` | fail | `kind` is not one of `manual/schedule/file` |
| `TRIGGER_KIND_UNSUPPORTED` | fail | `kind` is a reserved value (`mail`/`callback`); v1 has no registrar for it |
| `TRIGGER_INVALID` | fail | Missing required field, `time` not `HH:mm`, illegal `days`/`gate`, empty `file.pattern`, non-boolean `assisted`, or `manual` declaring `assisted` |
| `TRIGGER_ASSISTED_NO_TIMEOUT` | fail | `assisted=true` without an explicit `timeout_sec` |
| `TRIGGER_PATH_LITERAL` | fail | `file.dir` hard-codes a path instead of using a `{{config.<KEY>}}` reference |
| `TRIGGER_UNATTENDED_CONFIRM` | fail | A non-`manual` trigger with a `run_mode=confirm` node, without `assisted=true` |
| `TRIGGER_UNATTENDED_IRREVERSIBLE` | warn | A non-`manual` trigger with a `reversible=false` node (the consequence cannot be withdrawn); evidence lists the node id and `reversibility_note` |
| `TRIGGER_MISSING_REVERSIBILITY` | warn | A node has `idempotent=false` but declares no `reversible`; the declaration must be added (never filled in by default) |
| `TRIGGER_UNATTENDED_NONIDEMPOTENT` | warn (compatibility alias, **narrowed**) | The name is kept only while existing cases/callers still reference the old code; the decision is no longer triggered by `idempotent=false` but by the two reversibility rules above |
| `TRIGGER_NO_GATE` | warn | `schedule` without `gate`; it would still run on holidays |
| `TRIGGER_AMBIGUOUS` | fail | The task name is already taken by another flow under `business/flows` |
| `TRIGGER_NOT_REGISTERED` | warn | Only with `-TriggerLive` (not implemented yet) |
| `TRIGGER_DRIFT` | fail | Only with `-TriggerLive` (not implemented yet) |

Switch-over order: first let existing flows add `trigger` while `$script:TriggerMode` stays `warn` during the
observation period, then flip to `fail` in a separate commit once no reports are missed.

`FINGERPRINT_NO_BASELINE` means "not seeded yet", not "tampered with": `pad-admit` downgrades it to `warn` in
report mode and puts the ready-to-run seeding command directly in the message (including `-FlowName` /
`-FlowFile` / `-ConfigFile` / `-AcceptanceFile` / `-Set` / `-Confirm`). `-Unattended` (`pad-release` /
`pad-deploy` / scheduled runs) still reports `fail`, so the production gate stays strict.

Switch-over order (a hard requirement): first ship the write side (`pad-release` / `pad-rollback`) and
`pad-fingerprint.ps1 -Set`, seed baselines for existing flows, and keep the initial level at warn; after real runs
have been observed without problems, flip `$script:FingerprintMode` in `pad-admit.ps1` to `fail` in a separate
commit. This machine has already been seeded and the default level is now fail; a missing baseline is graded as
described in the previous paragraph.
Seeding requires human confirmation: `-Set` only prints what it located (revision directory, Workspace path,
mtime, the three hashes), and writes only with `-Confirm`; `-DryRun` never writes; several candidates report
`AMBIGUOUS` and stop immediately.

### 2.3 Input file declaration (INPUT) result codes

The node-level `inputs` declaration answers "step N checks only the input files step N needs" and is used for
**admission and structural validation**.
Fields: `dir` (must be `{{config.<KEY>}}`), `pattern` (filename wildcard), `required` (explicit boolean).
**This capability does not change the generated `.robin`**: `flow-to-robin.js` does not read `inputs` and never
writes it into the script; `eval-flow.js` validates only the shape of the declaration, while directory readability
and candidate counting are checked read-only by this check at admission time.

| Result code | Level | Meaning |
|---|---|---|
| `INPUT_UNDECLARED` | warn | No node declares `inputs` (backward compatible for existing flows; informational only) |
| `INPUT_INVALID` | fail | `inputs` is not a non-empty array, an entry is not an object, `dir`/`pattern` is missing, or `required` is not declared explicitly |
| `INPUT_PATH_LITERAL` | fail | `dir` hard-codes a literal path instead of using a `{{config.<KEY>}}` reference |
| `INPUT_CONFIG_UNRESOLVED` | fail | No config was supplied, a key is missing, or the value is empty, so the directory cannot be resolved (no fallback to the literal path) |
| `INPUT_DIR_UNREADABLE` | fail | The directory of a required input does not exist or is unreadable |
| `INPUT_FILE_MISSING` | fail | A required input has 0 candidates in the directory |
| `INPUT_FILE_AMBIGUOUS` | fail | ≥2 candidates is always ambiguous; **never "take the newest"**; the same applies to optional inputs |

Level rationale:
- Not declaring is a notice (warn), preserving backward compatibility for existing `flow.json` files;
- Once declared, shape/config/file checks are all fail-closed: better to block than to pretend the check passed;
- `required=false` relaxes only "0 candidates", not "multiple candidates" (several candidates are still ambiguous).

## 3. Execution stages

| Stage | Which checks run | Trigger point |
|---|---|---|
| Offline (before generating) | 1–16 (`pad-admit` runs them in one pass; missing inputs make the corresponding check warn) | `pad-admit` / `flow-to-robin` / CI |
| Before a run | Reuses 7, 8, 11, 12, 16 | `pad-sync`, before injection |
| After a run | Acceptance criteria | `pad-sync`, after the run (G6) |

The smoke sample is in `examples/` (1 neutral flow, 2 structural assertions): `examples/smoke.ps1` runs
canvas → generate → `check.js` → `pad-admit` → `eval-flow` in order on a fresh clone, and any non-zero step makes
the overall exit code 1.

## 4. Output contract

```json
{
  "ok": false,
  "flow": "sample-report",
  "fingerprint": "sha256:...",
  "checks": [
    {
      "id": "EDGE",
      "status": "fail",
      "code": "EDGE_DRIFT",
      "message": "旧结构有 1 条边没写进 edges",
      "evidence": ["34 -> 35"]
    },
    {
      "id": "POLICY",
      "status": "ask",
      "code": "POLICY_ASK",
      "message": "生产部署需要操作员确认",
      "evidence": ["ask-prod-deploy"]
    }
  ]
}
```

(`message` values above are tool output: the checker emits them in their original language.)

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Everything passed |
| 1 | At least one `fail` |
| 2 | Only `ask` (awaiting approval, not a failure) |

## 5. Policy evaluation semantics

- Evaluation order is fixed: **deny → ask → allow**.
- Within the same layer, the first hit in the order it is written in `business/policy.json` wins.
- When nothing matches, `defaultEffect` applies (currently `deny`).
- `match` matches the action kind (`pad_hint`) or the tool name, and **never the node id/label**, so renaming cannot bypass it.
- For generic actions (`Scripting.RunDOSCommand` / `RunVBScript`), add an `intent` to the node (such as `sap-posting`) and let policy match on `intent`; otherwise identification relies on the variable name inside the parameters (such as `%PostingVbsPath%`), which breaks as soon as the variable is renamed.
- `when.env`: `PAD_SYNC_TEST` = `test`, everything else = `prod`.
- `when.dryRun`: taken from the config's `DRY_RUN`.
- `when.paramsMatch`: glob matching against action parameters (such as the posting script's `DOSCommandOrApplication`).
- `ask` must carry an `approver`; unattended scenarios treat `ask` as `deny`.

## 6. Budget draft (for this flow)

| Item | Limit | Basis |
|---|---|---|
| Poll count | 7 | `LOOP 1 TO 7` in the `.robin` |
| Single run duration | 75 minutes | Six `WAIT 600` (60 minutes) + roughly 5–15 minutes for export/posting/reconciliation |
| Posting line count | The pending line count in `<PLAN_FILE>` | Preflight before execution |
| Mail sent | 1 message | The reminder branch |
| Report attachments | 1 (matched by report filename) | Inline signature images are not counted |
| Business artifacts modified | Report, export file, state ledger | Signature images in the attachment directory are not included |

If any budget item cannot be obtained from preflight, reject with `BUDGET_UNKNOWN`; never let it through as
"safe by default".

> **Timeout convention**: unified at 4200 seconds (`pad-schedule`, `pad-release`, `pad-deploy`); the `pad-sync`
> test default remains 300 seconds. For quick verification you may pass a smaller `-RunTimeoutSec` explicitly.

## 7. What is explicitly not checked (Limits)

- Static checks cannot prove business logic is correct.
- Acceptance criteria check artifacts only; they do not prove that SAP documents, amounts or batches are
  business-correct.
- Policy constrains PAD actions and tool entry points only and **cannot govern SAP operations or file writes
  inside VBS**.
- The allowed roots for `resource: artifact` are resolved by the gate: `{{PAD_ROOT}}`, `{{REPO_ROOT}}`, `{{TEMP}}`; writes outside those roots are always rejected.
- **The save-attachment action also persists inline images from the mail signature, so the count is not
  controllable**; budgets and acceptance cannot judge business completeness by "number of files", only by
  matching the report filename.
- No runtime dynamic re-planning: business steps must be fixed and the model may not add steps on the fly.

## 8. Rollout order

1. **Read-only version**: add `pad-admit.ps1`; it runs every check and only prints a report, blocking no existing flow.
2. **Wiring in**: make it a hard gate before `pad-sync` injection and before `pad-deploy` deployment.
3. **Disclosure**: put one pointer to `business/policy.json` and this document in Agent A's design prompt;
   never copy the rule list (a copy always drifts).
4. **Fingerprint approval**: the confirmation dialog shows the three hashes, they are re-checked before
   publishing, and an "approval record" file is supported.

## 9. Pre-push gate (public-safe)

> This is step 0 of the "publish to the public repository" process and sits at the same level as `pad-admit`:
> `pad-admit` decides whether a flow may run, this gate decides **whether these files may be pushed**.
> A filename allowlist is not enough — a file can be compliant while comments still leak business names and
> real paths, so this layer blocks **content**.

### 9.1 How to run it

```powershell
# Call it directly from PowerShell (-Files is an array; relative to the repository root or absolute)
.\tools\publish\check-public-safe.ps1 -Files @(
  'tools\pad-sync\pad-sync.ps1',
  'docs\admission-gate.md'
) -Verbose

# With a child process, use -Command so the array expression is evaluated (-File would split @(...) into literals)
powershell -NoProfile -ExecutionPolicy Bypass -Command `
  "& '.\tools\publish\check-public-safe.ps1' -Files @('tools\pad-sync\pad-sync.ps1','docs\admission-gate.md') -Verbose"
```

- Each hit prints one line `file:line:hit term` (through `Write-Output`, so it can be piped directly);
- `-Verbose` prints the denylist sources, the encoding decision per file, and binary-file notices; `-Quiet` prints only hit lines;
- Exit codes: `0` everything clean; `1` at least one hit; `2` the gate itself failed (empty file list, missing file, missing denylist or no enabled rules).

### 9.2 Denylist

| File | Purpose |
|---|---|
| `tools/publish/public-safe.denylist.json` | Structured rules that are committed: UNC paths, PAD root directories, intranet domain suffixes, email/mobile numbers; **only placeholders and regexes, no real business terms** |
| `tools/publish/public-safe.denylist.local.json` | Local overlay: real business names, real flow names, real paths, accounts; ignored by `.gitignore` and merged automatically by the script |

- **Sensitive by nature**: the denylist itself is sensitive. The real version of `public-safe.denylist.local.json` exists only on the local machine and is never committed, and **must never be pushed to the public repository**.
- Rule fields: `id`, `pattern`, `regex` (false means literal, true means regular expression), `caseSensitive` (default false), `enabled` (default true), `reason`; the category is given by the `categories` key (`businessName` / `realPath` / `flowName` / `accountOrServer` / `privateIdentifier`).
- Patterns that cannot be written in full (paths, host names, accounts) use regexes; concrete business terms use literals (the script escapes them automatically so regex metacharacters do not cause false hits).

### 9.3 Handling a failure

1. Go back to the source by `file:line` and locate it;
2. Rewrite the business name with a generic phrase ("sample flow", "long-running SAP download") and replace real paths with placeholders (such as `<PAD_ROOT>`);
3. **Never delete a rule, never comment out the matching line, never relax the whole denylist**;
4. For a genuine false positive, change the structured rule (for example narrow the match to a specific directory prefix) and explain why in the commit message;
5. Rerun until the exit code is 0, then continue with the normal push steps.

### 9.4 The business directory is a "never committed" zone

`business/` is ignored as a whole by `.gitignore`, and `git status --short` does not show files there. The push
gate adds a hard stop on top: any `business/` path passed in `-Files` is rejected outright (exit code `2`) rather
than silently skipped, which closes the invisible risk of "shipping a business file as a candidate".

### 9.5 I am a clone/fork user — where do business files go?

1. **Where**: put real flows, configuration, internal documents, logs and artifacts under the `business/`
   subdirectory of the repository root, for example `business/flows/my-flow.json` and
   `business/config/my-flow.json`. The generator and deployment scripts also default to the `business/` convention.
2. **Why it cannot be pushed**: `.gitignore` contains a `business/` line and Git ignores the whole directory by
   default; even if you `git add -f` it manually, `check-public-safe.ps1` before the push rejects it with exit code `2`.
3. **How to confirm** (run these in the repository root, ready to copy):

```powershell
# 1) create a fake business file for the check (delete it afterwards)
'{"demo":true}' | Set-Content business\flows\_ignore-probe.json -Encoding UTF8

# 2) git status must not show it
git status --short

# 3) the ignore rule must report the business/ line
git check-ignore -v business\flows\_ignore-probe.json

# 4) the push gate must reject it outright (exit code 2, not 0/1)
.\tools\publish\check-public-safe.ps1 -Files 'business\flows\_ignore-probe.json'
$LASTEXITCODE   # expected 2

# 5) clean up the probe
Remove-Item business\flows\_ignore-probe.json
```

> Exit code meanings: `0` = can be pushed; `1` = content hit a real business term; `2` = the gate rejected it
> (including a business directory, a missing file list, or a broken denylist). Whenever it is not `0`, stop and do
> not force the file into the staging area.

### 9.6 Scenarios it cannot catch

- Business names assembled at run time (string concatenation) or encoded content (base64, archives, encrypted payloads);
- Paths and accounts produced only at run time and not registered in the denylist;
- New business terms not yet in the denylist — the gate can only catch known patterns and cannot infer meaning;
- Binary files are scanned only with ASCII-style rules via Latin1 (`-Verbose` marks them `binary`), so non-ASCII business terms may be missed.

Conclusion: this gate is a deterministic check that **lowers the probability of a leak**, not a substitute for
redaction; the public repository should still be pushed with the smallest possible file set.

### 9.7 Automatic gates and coverage boundary

**Interception points**

| Layer | Location | Scanned object | Consequence of a hit |
|---|---|---|---|
| Commit boundary (the only real interception) | `.githooks/pre-commit` → `.githooks/pre-commit.ps1` | Staging snapshot (exported with `git checkout-index`) | Non-zero exit; the commit is rejected |
| CI backstop | The public-safe step in `.github/workflows/ci.yml` | Files already tracked by the repository (`git ls-files`) | The build fails |

- `setup.ps1` runs `git config core.hooksPath .githooks` automatically; existing clones only need to run it once by hand.
- **pre-commit is the only boundary that can stop content before it enters history**; CI can only discover a leak
  that has **already been pushed**, at which point the content is in the public history and cleanup or history
  rewriting is far more expensive. So do not treat CI as the first gate.
- pre-commit scans only **what this commit will add to the repository**; unstaged working-tree changes are not
  scanned. `business/`, `out.robin` and the like are already ignored by `.gitignore` and never enter the staging
  area, so no extra exemption logic is needed.
- When a hook genuinely must be bypassed, use `git commit --no-verify`, but state the reason in the commit message; CI still backstops it.

**Coverage boundary**

The current default denylist (`tools/publish/public-safe.denylist.json`) has only **5 structured rules**:

1. `PAD` / `Robot` root paths (`path-pad-root`)
2. UNC network share paths (`path-unc`)
3. Intranet host suffixes (`.corp` / `.intra` / `.internal` / `.lan`, `host-internal-suffix`)
4. Email addresses (`email-address`)
5. Mainland China mobile numbers (`mobile-number`)

**Not caught**: business names, flow names, ordinary local paths, account credentials, and new terms not yet
registered in the local denylist. These can only be covered by registering them one by one in
`public-safe.denylist.local.json` or by manual review.

**Behaviour without a local denylist**: when only the default denylist exists and no local overlay file is present,
the hook and CI print one prominent notice (stating that only the 5 structured rules above are active) and
**do not change the exit code** — otherwise the public CI would fail forever, since it never has a local denylist.
