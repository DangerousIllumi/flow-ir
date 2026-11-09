# Security

## Reporting a problem

**Do not** post vulnerability details, real accounts, mail content or SAP data in a public issue.

- Preferred: the repository's **Security → Report a vulnerability** (GitHub Security Advisories, privately visible)
- Alternative: contact the maintainer by email (via Contact on the repository home page)

Please include: the affected file/command, reproduction steps, expected versus actual behaviour, and whether
credentials are exposed. We fix confirmed reports and credit reporters in the release notes (unless you ask
to stay anonymous).

## Scope

This repository is a **local toolchain** and provides no server. The following count as security issues:

- A generated `.robin` performs side effects that were not planned (for example, it still sends mail or posts
  documents while `DRY_RUN=1`)
- The admission gate or static checks can be bypassed (for example, renaming a node label or variable skips a deny rule)
- The publishing pipeline ships unconfirmed content to production (the file is swapped after confirmation without an error)
- Credentials that should never land on disk end up in logs or artifacts

The following are generally not security issues, but issues are still welcome:

- Anything that requires local administrator rights to accomplish
- Behaviour caused by defects in PAD / SAP GUI itself
- Configuration mistakes when using real business credentials (please reproduce with `business/config/*.example.json` instead)

## Known design boundaries

- The policy constrains PAD actions and tool entry points only; it **cannot govern SAP operations or file writes
  inside VBS**
- Acceptance criteria prove only that "the artifact exists and has the right format", not that business amounts
  or batches are correct
- Alerts are written only to the local `business/logs/alerts.jsonl` and are never sent out
- Real configuration, the knowledge base and run artifacts are never committed; please do not submit them in a PR
