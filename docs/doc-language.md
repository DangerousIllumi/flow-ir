# Documentation language policy

> This document answers one question: **which language should each piece of text in this repository use?**
> The criterion is "who reads it", not personal taste. Two hard rules guard against the two most common traps:
> the same fact written in several places drifting apart, and Chinese prose being treated as a
> machine-matchable identifier.

## 1. Language by audience

| Audience | Carriers | Language |
|---|---|---|
| Anyone reading the repository: external visitors, search engines and crawlers, maintainers, AI assistants | `README.md`, `llms.txt`, `AGENTS.md`, `CLAUDE.md`, `docs/*.md`, `skills/*.md`, `.github/copilot-instructions.md` | **English** |
| People reading source code | code comments under `tools/`, `tests/` and the rest of the repository | **English** |
| Programs rather than people | identifiers, parameter names, rule ids, exit codes, JSON keys, CLI switches | **English** |
| The business layer, which is never committed and lives only on the operator's machine | flow definitions, configuration, notes and human-facing explanation fields such as `idempotency_note` under `business/` | **Chinese** |
| Tool output quoted inside documentation | real error strings the tools emit | kept verbatim as emitted, marked as tool output |

Why this split:

- Everything outside `business/` is English so external readers, search engines and AI assistants can consume the
  repository directly, without depending on the reader understanding another language.
- `business/` is never committed and never published. Its text is written by and for the operator running the
  flows, so it stays in the language that operator works in; business-layer content is outside the public surface.
- The layer boundaries do not move with language: identifiers, parameter names, rule ids, exit codes and JSON keys
  are consumed by compilers, scripts, tests and logs, so they stay English regardless of the prose around them.

## 2. Hard rule one: one language per document, no bilingual mirrors

- A document body uses exactly one language. No document gets a translated twin, and no document gets an
  appendix in another language.
- **Never add a bilingual copy**: when the same fact is needed elsewhere, give a **link**, not a **restatement**.

Rationale: a fact written in several places inevitably drifts. This repository has already seen a real drift:
one change raised the admission checks from 15 to 16, but the numbering in another document was not updated,
so the same repository simultaneously said "15 checks" and "16 checks" and a reader could not tell which one
described the current behaviour. Maintaining two language versions multiplies that kind of drift by the number
of languages — one more language means one more copy that a human has to keep in sync.

## 3. Hard rule two: machine-consumed output must keep an ASCII anchor

Any output that is **asserted by tests**, **annotated by CI**, or **matched by script regular expressions** must
keep an ASCII anchor (an error code, a fixed English identifier, a path or a number). Prose in any other
language is supplementary only and **must not be the sole matching basis**.

Real evidence: this repository once used non-ASCII prose in Pester regex assertions. On the CI runner, 13 cases
across 7 test files failed together while the same code kept passing locally. The root cause was that the
runner's console code page (possibly a non-UTF-8 page such as 437) disagreed with the UTF-8 bytes emitted by
child processes, so the non-ASCII text had been decoded into `?` before it reached `Should Match` — the assertion
was matching a string that no longer existed. The failure was finally traced to specific files and cases only
through the ASCII fallback line in CI
(`FAILED_CASE_FILE <relative path> LINE <line number> NAME <case name>`). ASCII falls outside that decoding
ambiguity, which is why it is the reliable anchor.

How to apply it:

- Assertions prefer error codes or rule ids (for example `ADMIT_AMBIGUOUS_FLOW`, `-FlowFile`); when prose must
  be checked, make it an **additional** condition, never the only one.
- Test and CI location information (file, line, case name) stays ASCII; non-ASCII text appears only in
  human-facing explanation.
- New rule ids are English and get a separate human description; never use a prose sentence as an id.
- Prose wording may change between versions; the part that is asserted must stay stable.

## 4. Checklist before touching documentation

- [ ] Who is the reader of this document? Pick the language per section 1 and do not mix languages.
- [ ] Is any fact restated from somewhere else? Delete the copy and replace it with a link.
- [ ] Do newly added outputs, logs and assertions carry an ASCII anchor?
- [ ] Do the numbers match the code: 16 admission checks, 16 public samples (10 flows + 6 triggers),
      11 `*.cases.json` files, the CI step order and names.
- [ ] Are identifiers, parameter names, rule ids and exit codes still English?
