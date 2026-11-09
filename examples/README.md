# Smoke example

Verify the toolchain on a fresh clone with a single command: canvas → generate → static check → admission →
structural evaluation.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File examples\smoke.ps1
```

- If any step returns non-zero, the overall exit code is 1; 0 when every step passes.
- It does not depend on the business directory, fingerprint baselines or PAD run history; temporary artifacts
  are cleaned up inside the process.
- Without a prior `npm install`, the "canvas" step falls back to the repository's deterministic BFS layout,
  so no network access is needed to install dependencies.
- `smoke-kb.json` is a minimal action table with only two neutral actions. It exists for this example alone and
  cannot replace the real `pad-robin-action-kb/`.
