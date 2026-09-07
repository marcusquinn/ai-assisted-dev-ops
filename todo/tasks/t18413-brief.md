<!-- aidevops:brief-schema=v2 -->

# t18413: Recover complete comparable Codacy default-branch analysis

## Pre-flight

- [x] Memory recall: `issue 31450 aidevops full loop` → 0 hits
- [x] Discovery pass: parent #31275 and related TODO/PR history checked; no recovery child exists
- [x] File refs verified: `.agents/scripts/stats-quality-sweep-tools.sh` and `.agents/tools/code-review/codacy.md` exist at HEAD
- [x] Tier: `tier:thinking` — third-party authorization and service recovery remain consequential
- [x] Seeded draft PR decision recorded: skipped — service operation may require no repository edit

## Origin

- **Created:** 2026-09-07
- **Session:** OpenCode:issue-31450
- **Created by:** ai-interactive
- **Parent task:** GH#31275
- **Blocked by:** Codacy-authorized account or provider support
- **Conversation context:** Decomposition required by GH#31450 after verified parent premise.

## What

Recover a completed Codacy analysis of the current GitHub default-branch SHA with scope comparable to the last trustworthy baseline.

## Why

The parent cannot distinguish real rating defects from the documented index discontinuity until Codacy analyses the complete current tree. The configured API token currently receives HTTP 403 from the clean-cache reanalysis endpoint.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Third-party authorization and index-recovery evidence require judgment and cannot be delegated safely without credentials.

## How

### Files to Modify

- `EDIT: .agents/tools/code-review/codacy.md` — only if verified recovery behavior makes current guidance inaccurate
- `EDIT: .agents/scripts/stats-quality-sweep-tools.sh` — only if live-schema evidence exposes a diagnostic defect

### Complete Write Surface

- **Callers/readers:** Maintainers read `.agents/tools/code-review/codacy.md`; the quality sweep invokes `.agents/scripts/stats-quality-sweep-tools.sh`.
- **Writers/mutation paths:** Codacy service state and evidence comments on `GH#31457` are primary; repository edits are limited to the two scoped files.
- **Tests/fixtures:** `.agents/scripts/stats-quality-sweep-tools.sh` and existing quality-sweep checks encode current diagnostic behavior.
- **Schemas/config:** Live `Codacy v3` response schema is observed, not changed by this task.
- **Generated/deployed mirrors:** `Codacy analysis` and the public badge are external derived state used as completion evidence.
- **Migrations/backfills:** `clean-cache reanalysis` of the exact current default SHA is the required index backfill.
- **Cleanup/rollback paths:** Keep `GH#31457` open and revert any scoped edit if it misstates observed service behavior.

### Implementation Steps

1. Use an authorized Codacy account or Codacy support to resolve the permission/index incident.
2. Request clean reanalysis of the exact current default-branch SHA.
3. Compare repository summary, ten-day commit statistics, issues overview, analysed LOC/files, and the live badge with historical evidence in GH#31275.
4. Record exact SHA, completion timestamp, grade, LOC, issue count, and comparability.

### Hazards and Compatibility

- **Concurrency/atomicity:** Pin evidence to the exact default SHA so a concurrent push cannot create false recovery proof.
- **Migration/rollback:** Recovery must preserve prior policy; undo any service setting that reduces analysed coverage.
- **Mixed-version/backward compatibility:** Compare live v3 responses with the documented schema before changing diagnostic parsing.
- **Idempotency/retry:** Read-only diagnostics are replay-safe; do not repeat unauthorized mutations after an explicit 403.
- **Partial failure/recovery:** Record the failed service operation and owner action, retain the open task, and resume from fresh exact-SHA evidence.

### Verification Before Dispatch

```bash
.agents/scripts/stats-quality-sweep-tools.sh codacy marcusquinn/aidevops "$PWD"
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The diagnostic proves exact-SHA service/index state; changed-file lint verifies any scoped documentation or diagnostic repair.
- **Broad verification trigger:** Not required unless the diagnostic implementation changes shared quality-sweep contracts.

### Files Scope

- `.agents/tools/code-review/codacy.md`
- `.agents/scripts/stats-quality-sweep-tools.sh`

## Acceptance Criteria

- [ ] **Positive:** Completed analysis matches the then-current default-branch SHA and analysed scope is proven complete and comparable.
- [ ] Evidence contains no secrets and names any remaining service blocker.
- [ ] **Negative/regression:** Quality policy, thresholds, badge visibility, and production-source coverage remain intact.

## Context

Monitoring shipped in PR #31274; monitoring alone does not prove index recovery. This child is intentionally `no-auto-dispatch` because it requires authorized service access.
