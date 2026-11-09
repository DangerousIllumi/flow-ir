# Paste this to your AI assistant

> How to use: open this repository (or your fork) in an IDE, copy the whole block below to the AI, and append
> your requirement at the end.

```text
I am working in the flow-ir repository. Please build a PAD workflow for me by following the AGENTS.md in the repository.

Steps:
1. Read AGENTS.md in the repository root first; run .\setup.ps1 and .\tools\check-env.ps1 if needed (once only).
2. Following the rules in skills/pad-flow-designer, turn my requirement into business/flows/<name>.json.
   - pad_hint must be an actionId that really exists in pad-robin-action-kb; never invent one.
   - params may only use the real parameter names of that action.
   - budget is mandatory; script-type nodes must carry intent; sending mail / posting documents / deleting files go inside guard.
3. Run the following in order and paste the result of each step back to me:
   node tools\pad-robin\flow-to-robin.js business\flows\<name>.json out.robin
   node tools\pad-robin\check.js out.robin
   .\tools\pad-sync\pad-admit.ps1 -FlowFile business\flows\<name>.json -RobinFile out.robin
4. If any step fails, fix business\flows\<name>.json and rerun. Do not change the generator and do not hand-edit out.robin.

Delivery requirements:
- Write business files only under business\ (that directory is ignored by .gitignore and is never pushed to the public repository).
- Generation must report 0 errors, check.js 0 errors, and admission 0 fails (warnings are acceptable but must be explained).
- Tell me the full path of out.robin, the steps to paste it into PAD, and everything I have to fill in by hand (UI elements, VBS, accounts).

My requirement:
<write your requirement here, e.g. every day archive the CSVs in one directory to another directory, overwriting same-name files, then show a popup with the count>
```

## If your AI says it cannot find the files

- Make sure the current working directory is the repository root (where `AGENTS.md` and `tools\` are visible).
- Ask it to list the repository root first, then read `AGENTS.md`.
- The first run must start with `.\setup.ps1`; otherwise `pad-robin-action-kb/` is missing and the generator
  refuses to produce anything.

## Ready-made samples you can copy

`tests/eval/fixtures/` contains 16 copy-ready `flow.json` files (10 flows and 6 triggers):
foreach iteration, a three-way switch, guard plus mail, a bounded loop with break, file read/write, Excel
read/write, an HTTP call, multi-condition AND, and early exit with no match.
