<!-- aidevops:brief-schema=v2 -->

# t18414: Audit and correct Codacy policy drift after index recovery

## Pre-flight

- [x] Memory recall: `issue 31450 aidevops full loop` → 0 hits
- [x] Discovery pass: parent #31275 and TODO/PR history checked; no policy-recovery child exists
- [x] File refs verified: five named policy and diagnostic files exist at HEAD
- [x] Tier: `tier:thinking` — live service policy must be reconciled without weakening gates
- [x] Seeded draft PR decision recorded: skipped — blocked on index recovery evidence

## Origin

- **Created:** 2026-09-07
- **Session:** OpenCode:issue-31450
- **Created by:** ai-interactive
- **Parent task:** GH#31275
- **Blocked by:** t18413 / GH#31457
- **Conversation context:** Second phase of the verified decomposition requested by GH#31450.

## What

Verify Codacy tools, patterns, and supported language versions against repository policy after comparable index recovery, then correct only confirmed drift.

## Why

Unexpected Bandit and ESLint legacy-language findings are not safely actionable until analysed scope is trustworthy. Blanket suppression would hide defects and violate the parent objective.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Live service settings and repository policy must be reconciled across a consequential quality boundary.

## How

### Files to Modify

- `EDIT: .codacy.yml` — only when live engine evidence proves repository policy drift
- `EDIT: .bandit` — only when live Bandit evidence proves repository policy drift
- `EDIT: biome.json` — only when live JavaScript policy evidence proves repository drift
- `EDIT: .shellcheckrc` — only when live ShellCheck evidence proves repository drift
- `EDIT: .agents/tools/code-review/codacy.md` — document verified service behavior when current guidance is incomplete

### Complete Write Surface

- **Callers/readers:** Codacy reads repository policy files; maintainers read `.agents/tools/code-review/codacy.md` during recovery.
- **Writers/mutation paths:** Codacy repository settings and only `.codacy.yml`, `.bandit`, `biome.json`, `.shellcheckrc`, and the scoped guide may change.
- **Tests/fixtures:** `.agents/scripts/stats-quality-sweep-tools.sh` provides the production-facing read-only diagnostic; changed-file lint covers repository edits.
- **Schemas/config:** `.codacy.yml`, `.bandit`, `biome.json`, and `.shellcheckrc` are the complete known configuration surface.
- **Generated/deployed mirrors:** `Codacy reanalysis` is the external derived state; no repository-generated mirror applies.
- **Migrations/backfills:** Exact-SHA `clean reanalysis` is the required backfill after policy correction.
- **Cleanup/rollback paths:** Revert `.codacy.yml` or other scoped policy edits and restore prior service settings if coverage regresses.

### Implementation Steps

1. Start only after GH#31457 proves comparable analysis.
2. Inspect actual Codacy tool/pattern settings and supported language versions.
3. Compare live settings with repository policy; do not assume legacy `engines.*.enabled` entries activate engines.
4. Correct only demonstrated drift and record before/after exact-SHA counts for the four patterns in GH#31275.

### Hazards and Compatibility

- **Concurrency/atomicity:** Snapshot the exact default SHA and live settings before mutation so concurrent default-branch advances cannot be mistaken for policy effects.
- **Migration/rollback:** Preserve before-state settings and revert any change that reduces analysed scope or quality coverage.
- **Mixed-version/backward compatibility:** Confirm supported language versions before changing legacy ESLint behavior; keep current repository tooling valid.
- **Idempotency/retry:** Re-reading settings is safe; do not replay mutations after a confirmed successful reanalysis without new evidence.
- **Partial failure/recovery:** Keep the task open with exact failed operation evidence when service mutation or reanalysis is incomplete.

### Verification Before Dispatch

```bash
.agents/scripts/stats-quality-sweep-tools.sh codacy marcusquinn/aidevops "$PWD"
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Codacy diagnostic proves exact-SHA service state and policy counts; changed-file lint verifies any edited repository policy or documentation files.
- **Broad verification trigger:** Not required unless a root policy edit demonstrably changes cross-repository tooling behavior.

### Files Scope

- `.codacy.yml`
- `.bandit`
- `biome.json`
- `.shellcheckrc`
- `.agents/tools/code-review/codacy.md`

## Acceptance Criteria

- [ ] **Positive:** Actual enabled tools, patterns, and language versions are documented against intended policy, and confirmed drift is corrected with exact-SHA reanalysis evidence.
- [ ] **Negative/regression:** Existing quality rules, thresholds, badge visibility, and production-source coverage remain intact.
- [ ] Applicable existing checks and changed-file lint pass for every repository edit.

## Context

This child handles policy reconciliation only, not bulk source remediation.
