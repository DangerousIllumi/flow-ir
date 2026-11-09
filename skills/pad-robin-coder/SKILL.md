# pad-robin-coder (Agent B: code generator)

## When To Use
When a `flow.json` must be turned into a Robin script that can be pasted into Power Automate Desktop.
Typical triggers: "generate PAD code", "translate to Robin", "/generate", "read flow.json and generate code".

## Core principle
You are a **template filler**, not a code generator.
- Take the action skeleton directly from the KB's `golden_example` and never rewrite it
- Only substitute parameter values; never add or remove parameters, never reorder them
- The table-driven filling is done by the deterministic tool `flow-to-robin.js`; you never copy it by hand

## Reference material
- `pad-robin-action-kb/PAD_Robin_ActionKB.json` — the action library
- `pad-robin-action-kb/PAD_Robin_TypeReference.json` — 44 type forms
- `pad-robin-action-kb/PROMPT.md` — the red-line list (consult it when something fails)

## Workflow

### 1. Run the generator (one step)
```bash
node tools/pad-robin/flow-to-robin.js business/flows/<name>.json output.txt
```
The generator: looks up the KB → takes `golden_example` → fills values by type → resolves references →
generates IF/ELSE → automatically runs the repository's own `tools/pad-robin/check-flows.js` self-check.

### 2. Handle the generator output
- **Generation errors** (unknown action / unknown parameter / UI selector required / dangling reference /
  missing handle) → these are defects in flow.json; have Agent A fix them and rerun, **do not work around them by hand**
- **Warnings** (KB placeholder values still in use / a variable has no default) → relay them to the user verbatim
  and point out what still has to be filled in inside PAD
- **Self-check failure**: fix the **generator input** (flow.json) according to the reported line and the
  PROMPT.md red lines, not the artifact

### 3. Output
- Write `output.txt` (pure Robin, no markdown, no explanation)
- Give a preview plus caveats in the conversation
- Tell the user: "open output.txt in Notepad → select all and copy → paste into the PAD canvas with Ctrl+V"

## Common commands
```bash
# Generate + self-check
node tools/pad-robin/flow-to-robin.js business/flows/<name>.json output.txt

# Run the static check on its own
node tools/pad-robin/check.js output.txt
```

## Red lines (violating any of them makes the paste fail)
- ❌ Never hand-write the `@@` file header, `FUNCTION...END` or `IMPORT` (the generator's own output contains none;
  the PAD-permitted `@@copilotGeneratedAction` is the only exception)
- ❌ `%Var%` may only appear inside the string `$'''…'''`; outside a string it must be written bare
- ❌ Never use `WHEN...END`; use `LOOP WHILE (...) ... END`
- ❌ Never write action names from memory; the KB is authoritative
- ❌ Never add or remove parameters by hand

## Type formatting quick reference
Per-type syntax is defined by `pad-robin-action-kb/PAD_Robin_TypeReference.json` (44 types); this document does
not copy the table. Only three high-frequency mistakes exist: `%Var%` may only appear inside `$'''…'''`; UNC paths
are written as `$'''\\\\<host>\<share>'''`; a literal percent sign is written as `%%`.
