<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18402: Compounding-value architecture and portable organisational knowledge

## Pre-flight

- [x] Memory recall: architecture/value/portability queries returned no matches; maintainer direction is copied into the repo-native plan.
- [x] Discovery pass: current source and recent related PRs reviewed; #31228, #31207, #31201 and #31249 are already shipped foundations, not duplicate tasks.
- [x] File refs verified: plan, README, AGENTS, architecture, self-improvement and relevant adapter/registry paths checked at `5393632ee`.
- [x] Tier: thinking; cross-system ownership and preservation decisions require architectural judgment.
- [x] Seeded draft PR decision recorded: skipped; this is a coordination parent, not implementation.

## Origin

- Created: 2026-09-05; OpenCode interactive architecture review following PR #31249.
- Created by: ai-interactive, at the maintainer's request.
- Canonical plan: `todo/plans/compounding-value-architecture.md`.
- Parent status: coordination only; use `parent-task`, never auto-dispatch.

## What

Deliver the bounded child program that makes aidevops's purpose durable and its
knowledge/context/execution architecture support compounding value across domains.
Repo-native plans and progress remain portable if any forge disappears.

## Why

The review incorrectly treated common DevOps discipline as removable coding
overhead. The maintainer clarified that codifying all information flows is the
product: improve time/money outcomes and value-generation capability without
compounding human supervision. A 100x capability ambition is not a proven result.
The pilot supports measurement and calibration work, not blanket prompt pruning.

## Tier

**Selected tier:** `tier:thinking`. Parent coordination is not worker-dispatchable;
each child carries a separate implementation contract and tier.

## How (Approach)

### Files to Modify

- `EDIT: todo/plans/compounding-value-architecture.md` — canonical purpose and coordination.
- `EDIT: TODO.md` — durable task/ref/dependency tracking; child briefs remain in `todo/tasks/`.
- Implementation ownership belongs to the child targets, not a monolithic parent PR.

### Complete Write Surface

- **Callers/readers:** `TODO.md`, repo briefs and `.agents/scripts/issue-sync-helper.sh` feed execution conversations and worker context.
- **Writers/mutation paths:** `todo/plans/compounding-value-architecture.md`, `todo/tasks/`, and `TODO.md`; issue-sync updates corresponding tracker views.
- **Tests/fixtures:** `.agents/scripts/verify-brief-helper.sh` validates briefs and `.agents/scripts/progressive-load-check.sh` protects existing context pointers.
- **Schemas/config:** `TODO.md` Format and `.agents/templates/brief-template.md` define task/ref/dependency syntax and brief schema v2; no runtime configuration change.
- **Generated/deployed mirrors:** `.agents/scripts/issue-sync-helper.sh` derives issue bodies and relationship views from the repo planning snapshot.
- **Migrations/backfills:** N/A because this parent adds planning records in `TODO.md` and `todo/tasks/`, not database schemas or production data migrations.
- **Cleanup/rollback paths:** `.agents/scripts/planning-commit-helper.sh` preserves publication scope; retain IDs and correct `TODO.md` refs rather than deleting history after a failure.

### Implementation Steps

1. Preserve the eight maintainer directions in the plan and the purpose child.
2. File substantive child briefs with verified dependencies and publication gates.
3. Track each child's acceptance evidence in repo-native progress; do not treat
   forge-only comments or external issue IDs as the sole record of the work.
4. Close the parent only after all children complete or explicit scope change.

### Hazards and Compatibility

- **Concurrency/atomicity:** Allocate IDs through the CAS helper and publish one planning snapshot; do not expose dependents before native edges exist.
- **Migration/rollback:** No runtime migration; retain unpublished tasks and reconcile the same issue refs after publication recovery.
- **Mixed-version/backward compatibility:** Keep existing TODO syntax, native relationships and source brief content usable by current workers.
- **Idempotency/retry:** Reuse task IDs and issue refs; the parent has no auto-phase filing and must not duplicate explicit children.
- **Partial failure/recovery:** Keep publication/dependency blocks until repaired. Parent-task prevents implementation dispatch and premature completion.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18402-brief.md
.agents/scripts/planning-commit-helper.sh --status
.agents/scripts/progressive-load-check.sh --quiet
git diff --check
```

- **Surface mapping:** Brief readiness checks this record; planning status checks only TODO/brief/plan publication scope; progressive-load protects the current pointer graph; diff checking protects written planning syntax. None authorizes dispatch of this parent.

### Progressive Context Plan

- **Read first:** `todo/plans/compounding-value-architecture.md` for maintainer direction and work-package ownership.
- **Load only if:** the relevant child brief when verifying that child's completion or dependency.
- **Stop when:** every child has a distinct owner, acceptance contract and durable reference; do not load all implementation libraries for parent coordination.

## Acceptance Criteria

- [ ] Canonical purpose is prominent in README and reaches architecture/self-improvement decision points without global prompt duplication or unsupported claims.
- [ ] Every child has a repo-native brief, stable task identity, linked issue and verified ordering; loss of a forge does not remove the brief/plan.
- [ ] Runtime/context, portability and value-evaluation children deliver their own evidence without deleting unverified hard-won guidance or weakening permissions.
- [ ] The parent is not dispatched or marked complete merely because this plan or one child merges.

## Context

Build+ is the default, not the only useful main-domain profile. Lighter delegated
work means narrower scope/context, not weaker operating discipline. Time and money
are ultimate value measures; tokens and task counts alone are not value.

## Seeded Draft PR

Skipped: implementation is decomposed into children; this parent contains no code seed.
