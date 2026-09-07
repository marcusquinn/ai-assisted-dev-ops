<!-- aidevops:brief-schema=v2 -->

# t18415: Triage refreshed Codacy findings into bounded remediation children

## Pre-flight

- [x] Memory recall: `issue 31450 aidevops full loop` → 0 hits
- [x] Discovery pass: parent #31275 and related TODO/PR history checked; no remediation-planning child exists
- [x] File refs verified: task-allocation and parent-lifecycle references exist at HEAD
- [x] Tier: `tier:thinking` — refreshed external evidence determines safe remediation boundaries
- [x] Seeded draft PR decision recorded: skipped — blocked on earlier recovery phases

## Origin

- **Created:** 2026-09-07
- **Session:** OpenCode:issue-31450
- **Created by:** ai-interactive
- **Parent task:** GH#31275
- **Blocked by:** t18414 / GH#31459
- **Conversation context:** Final currently knowable phase of the decomposition required by GH#31450.

## What

Use trustworthy post-recovery Codacy evidence to classify remaining genuine rating drivers and file small, non-overlapping implementation children directly under parent GH#31275.

## Why

Source-fix paths cannot be selected responsibly before index and policy recovery. Once those phases complete, the parent needs dispatchable remediation leaves rather than one unbounded quality-debt task.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Exact remediation boundaries depend on refreshed third-party analysis and must avoid hiding or misclassifying findings.

## How

### Files to Modify

- EDIT: `TODO.md`
- EDIT: `todo/tasks`

### Complete Write Surface

- **Callers/readers:** Pulse and issue-sync read `TODO.md` and `todo/tasks` to dispatch and reconcile children.
- **Writers/mutation paths:** `claim-task-id.sh` allocates IDs and writes mappings; issue-sync and GitHub relationship APIs publish issue metadata.
- **Tests/fixtures:** `.agents/scripts/verify-brief-helper.sh`, issue-sync relationship checks, and changed-file lint cover the planning surface.
- **Schemas/config:** `brief schema v2` and canonical TODO metadata are the only planning schemas changed.
- **Generated/deployed mirrors:** `GitHub issues` and native relationships are derived from the committed planning records.
- **Migrations/backfills:** The parent `## Children` body and native sub-issue links are backfilled for every remediation task.
- **Cleanup/rollback paths:** Close an accidental `duplicate issue` with rationale and reconcile only its matching TODO entry and relationships.

### Implementation Steps

1. Start only after GH#31459 completes policy reconciliation against comparable analysis.
2. Retrieve exact-default-SHA findings and group genuine security/error and complexity drivers by independent file or subsystem.
3. Claim a fresh task ID for each bounded batch, create a worker-ready brief and issue, and link it directly under GH#31275.
4. Add every child to the parent Children section and encode dependencies where ordering is required.
5. If no genuine findings remain and the public grade is A, record exact-SHA and badge evidence rather than inventing work.

### Hazards and Compatibility

- **Concurrency/atomicity:** Claim every ID through CAS and deduplicate against current issues/PRs before filing.
- **Migration/rollback:** Keep issue/TODO mappings immutable; correct mistakes with explicit reconciled edits rather than ID reuse.
- **Mixed-version/backward compatibility:** Preserve canonical TODO and brief schema consumed by current Pulse and issue-sync versions.
- **Idempotency/retry:** Re-run relationship sync safely; never create a replacement task before checking whether the first issue exists.
- **Partial failure/recovery:** Retain publication-pending mappings and resume issue/relationship reconciliation instead of abandoning allocated IDs.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18415-brief.md
.agents/scripts/issue-sync-helper.sh relationships --dry-run --repo marcusquinn/aidevops
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Brief readiness proves worker context, relationship sync proves dependency/parent metadata, and changed-file lint verifies TODO/brief formatting.
- **Broad verification trigger:** Not required because this phase changes planning records only.

### Files Scope

- `TODO.md`
- `todo/tasks`

## Acceptance Criteria

- [ ] **Positive:** Every genuine rating driver is mapped to a bounded child or ruled out with exact-SHA evidence.
- [ ] Every filed child has a fresh task ID, worker-ready context, direct parent relationship, and correct dispatch/dependency metadata.
- [ ] The parent Children section remains current for completion reconciliation.
- [ ] **Negative/regression:** Quality policy, badge visibility, and production-source coverage remain intact.

## Context

This phase converts refreshed evidence into implementable leaves; it does not guess source fixes early.
