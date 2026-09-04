<!-- aidevops:brief-schema=v2 -->

# t18397: Make email facade exports explicit and clear Pylint unused-import noise

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `Codacy indexing quality findings issue creation worker briefs task lifecycle` → 0 hits — no relevant reusable lesson
- [x] Discovery pass: 0 recent target-file commits / 0 merged related PRs / 0 open related PRs
- [x] File refs verified: 7 existing refs plus the new-test parent directory checked at `c2347f0b222e6ac88804f85a6a495fc05ee51f47`
- [x] Tier: `tier:standard` — compatibility behavior is fixed, but the worker must distinguish facade exports from genuinely dead imports
- [x] Seeded draft PR decision recorded: skipped — a focused issue is sufficient and avoids speculative export lists

## Origin

- **Created:** 2026-09-04
- **Session:** OpenCode `ses_f9595a114ffe165mBLWoXbpLl2`
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Codacy reports 93 Pylint W0611 findings. Inspection showed that many are intentional compatibility re-exports already marked for Ruff/Pyflakes, mixed with a smaller number of genuinely unused standard-library imports.

## What

Express the public compatibility surfaces of the decomposed email modules with explicit export contracts and remove only imports proven to be dead. Clear the current W0611 findings in the scoped files without deleting names that downstream callers may import.

## Why

`# noqa: F401` documents intent for Ruff/Pyflakes but does not tell Pylint that a name is part of a module’s public API. Codacy therefore reports facade imports as dead code, obscuring real unused imports such as `re` in `email_normaliser.py` and `os`/`datetime` in `email_thread.py`.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The desired compatibility guarantee is resolved, but the exact public export lists must be derived from current modules and validated against import behavior.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The worker should construct export lists from current symbols and tests rather than inherit an unverified hand-written list.
- **Status:** `not-created`
- **Freshness evidence:** Target files, import references, tests, recent commits, and related PRs were checked on 2026-09-04.
- **Verification run:** `UNVERIFIED — brief only`
- **Stale-assumption warning:** Re-run import searches if any email decomposition PR lands before implementation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/email_jmap_adapter.py:33-78` — convert documented compatibility re-exports into an explicit public surface.
- `EDIT: .agents/scripts/email_normaliser.py:9-25` — retain parser/section re-exports explicitly and remove the unused `re` import if still dead.
- `EDIT: .agents/scripts/email-to-markdown.py:30-83` — preserve the compatibility API of dynamically loaded pipeline modules with an explicit export contract.
- `EDIT: .agents/scripts/email_thread.py:19-27` — remove only standard-library imports still proven unused.
- `NEW: tests/test-email-facade-exports.py` — verify expected facade names remain importable and dead standard-library imports do not return.

### Complete Write Surface

- **Callers/readers:** `email-to-markdown.py:70-79` imports the `email_normaliser` facade; shell entry points execute `email-to-markdown.py`; external users may import the documented JMAP/email facade names even where no in-repo caller exists.
- **Writers/mutation paths:** Module-level imports and `__all__` declarations only. Do not change command parsers, email conversion output, JMAP requests, or thread index writes.
- **Tests/fixtures:** Follow the dynamic-import setup in `tests/test-email-summary.py:296-315` and the JMAP module loading pattern in `.agents/scripts/tests/test-email-jmap-push.py:16-23`.
- **Schemas/config:** Module `__all__` declarations are the public-symbol compatibility schema; no persisted data migration is involved.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/**`; edit repository sources only.
- **Migrations/backfills:** N/A because the scoped modules do not change persisted records.
- **Cleanup/rollback paths:** Revert `__all__` declarations and import removals together; the compatibility test must fail if a public symbol disappears.

### Implementation Steps

1. Search each scoped module for local and external-facing documented symbols before editing. Treat comments stating “Re-export public surface” as compatibility requirements.
2. Add explicit module-level `__all__` declarations covering the intended facade names. Keep needed imports even when their only use is export.
3. Remove only imports with no execution or export role. Reconfirm `re` in `email_normaliser.py` and `os`, `datetime`, and `timezone` in `email_thread.py` against current HEAD.
4. Remove obsolete `noqa: F401` markers only when the explicit export declaration makes intent clear; retain unrelated E402 markers required by dynamic sibling loading.
5. Add a focused test that imports each facade through its supported loading path and asserts representative compatibility names. Include negative source assertions for the proven-dead imports without coupling to formatting.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A; imports initialize synchronously and no shared mutable state changes.
- **Migration/rollback:** No data migration. Reverting restores the prior implicit facade.
- **Mixed-version/backward compatibility:** Every currently documented/re-exported public symbol must remain importable; do not narrow the API based only on in-repo usage.
- **Idempotency/retry:** Module imports and tests remain repeatable with no external network calls.
- **Partial failure/recovery:** A missing facade symbol must fail focused tests before merge; no generated artifacts are written.

### Verification Before Dispatch

```bash
python3 tests/test-email-facade-exports.py
python3 tests/test-email-summary.py
python3 .agents/scripts/tests/test-email-jmap-push.py
python3 -m compileall -q .agents/scripts/email_jmap_adapter.py .agents/scripts/email_normaliser.py .agents/scripts/email-to-markdown.py .agents/scripts/email_thread.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Facade tests protect public imports; existing summary/JMAP tests protect runtime behavior; compileall and changed-file lint catch syntax and lint regressions.
- **Broad verification trigger:** Run additional email integration tests only if implementation touches behavior outside module exports/import cleanup.

### Files Scope

- `.agents/scripts/email_jmap_adapter.py`
- `.agents/scripts/email_normaliser.py`
- `.agents/scripts/email-to-markdown.py`
- `.agents/scripts/email_thread.py`
- `tests/test-email-facade-exports.py`

## Acceptance Criteria

- [ ] All compatibility names currently re-exported by the three facade modules remain importable and are represented in explicit public export contracts.
- [ ] The scoped Codacy Pylint W0611 findings are removed or reduced only through explicit export intent and deletion of proven-dead imports, never through a global Pylint disable.
- [ ] `email_normaliser.py` and `email_thread.py` no longer import the currently dead standard-library names unless current code proves a semantic use.
- [ ] Email conversion and JMAP tests retain their existing behavior and output contracts.
- [ ] Focused tests, compileall, and changed-file lint pass.

## Context & Decisions

- Preserve compatibility over badge cleanup: absence of an in-repo caller is not evidence that a documented facade export can be deleted.
- Use standard Python export semantics rather than tool-specific blanket suppressions.
- This is a bounded first batch; remaining W0611 findings should be triaged by subsystem, not mass-deleted.

## Dependencies

- **Blocked by:** none.
- **Blocks:** none.
- **External:** Codacy reanalysis is confirmation after merge, not a local test dependency.

## Estimate Breakdown

| Phase | Time |
|---|---:|
| Export inventory | 30m |
| Implementation | 45m |
| Focused tests | 1h |
| Review buffer | 15m |
| **Total** | **~2.5h** |
