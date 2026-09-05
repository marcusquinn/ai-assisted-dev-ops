<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18407: Make domain discovery and dependent views structurally consistent

## Pre-flight

- [x] Memory recall: no matching search result; review evidence retained in the parent plan.
- [x] Discovery pass: existing TOON/capability registries and progressive-load checks are foundations; no open discovery title match found.
- [x] File refs verified: domain index, capability registry/readiness helper, agent metadata and discovery helpers checked at `5393632ee`.
- [x] Tier: standard; consolidate ownership and validate existing representations rather than redesign the corpus.
- [x] Seeded draft PR decision recorded: skipped; preserve current metadata until the source/dependent map is explicit.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18403.

## What

Define ownership of primary-agent, domain-entry and capability views; fix the
confirmed stale/ambiguous routes; extend existing consistency validation so future
component changes update or reject stale dependants structurally.

## Why

The domain index points to `tools/task/beads.md` instead of the tracked
`tools/task-management/beads.md`, repeats Networking/VPN, and overlaps broad
Business with substantive Accounting. Multiple independently maintained
inventories can drift even when individual files are reasonable. Keep the large
knowledge library; improve the selected route, not storage size.

## Tier

**Selected tier:** `tier:standard` — bounded registry/view consistency using existing patterns.

## How (Approach)

### Files to Modify

- `EDIT: .agents/reference/domain-index.md`, `EDIT: .agents/reference/agent-routing.md`, `EDIT: .agents/reference/capability-registry.md` — distinguish primary registration, user-intent entry and executable readiness.
- `EDIT: .agents/scripts/verify-agent-discoverability.sh` and/or `EDIT: .agents/scripts/progressive-load-check.sh` — extend existing checks, not a parallel registry.
- `.agents/configs/capability-registry.json`, `.agents/subagent-index.toon`, `.agents/scripts/subagent-index-helper.sh`, `.agents/build-plus.md`, `.agents/seo.md` are source/dependent surfaces to map before deciding which generated views need edits.

### Complete Write Surface

- **Callers/readers:** domain routing, primary registration and `.agents/scripts/capability-readiness-helper.py` consumers.
- **Writers/mutation paths:** source metadata plus `.agents/scripts/subagent-index-helper.sh` and current registry generation paths; document one owner per field.
- **Tests/fixtures:** `.agents/scripts/verify-agent-discoverability.sh` and `.agents/scripts/progressive-load-check.sh`; add small stale-path/duplicate-view cases only for the new guard.
- **Schemas/config:** `.agents/configs/capability-registry.json` and TOON field contracts remain compatible.
- **Generated/deployed mirrors:** `.agents/subagent-index.toon`, generated counts and runtime primary views; generated artifacts must not become new hand-maintained authorities.
- **Migrations/backfills:** correct `.agents/reference/domain-index.md` links in place; no mass path moves and preserve aliases needed by current callers.
- **Cleanup/rollback paths:** regenerate `.agents/subagent-index.toon` from canonical metadata or revert bounded mapping changes; do not delete specialist knowledge.

### Implementation Steps

1. Document which view owns primary registration, all-domain entry points and runtime/service readiness.
2. Repair Beads, reconcile duplicate VPN rows without losing service choices, and route bookkeeping/invoices/reconciliation to Accounting while keeping Business as coordinator.
3. Separate machine metadata from prose judgment; generate or validate dependent inventories rather than maintain copies.
4. Preserve registered/installed/authenticated/authorized distinctions. Gate provider actions, not conceptual discussion, and preserve direct-domain readiness inheritance.
5. Extend existing validation to name stale source/target paths and inconsistent declared views; avoid a full corpus reorganisation or leaf-agent registration explosion.

### Hazards and Compatibility

- **Concurrency/atomicity:** regenerate against the same source snapshot; preserve unrelated domain additions from other sessions.
- **Migration/rollback:** update target references and views together; retain runtime-compatible names and stable aliases.
- **Mixed-version/backward compatibility:** current TOON and JSON consumers must keep working; metadata availability is never permission.
- **Idempotency/retry:** repeated generation has no duplicate rows, changed ordering noise or accumulating inventory entries.
- **Partial failure/recovery:** reject stale/missing views with actionable paths instead of claiming unavailable services work.

### Verification Before Dispatch

```bash
bash .agents/scripts/verify-agent-discoverability.sh --agents-dir .agents
.agents/scripts/progressive-load-check.sh --quiet
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** discoverability/pointer checks cover declared links; focused new cases cover stale/misaligned view rejection; scoped lint protects Markdown/JSON/shell. Inspect generator invocation before writing deployed mirrors; source-worktree overrides must be used.

### Progressive Context Plan

- **Read first:** domain-index rows and canonical registry definitions, then the generator/checker for those fields.
- **Load only if:** the owning domain source when resolving an ambiguous route or a concrete stale link.
- **Stop when:** ownership and affected edges are known; do not read all leaf agent bodies or add repeated capability catalogues.

## Acceptance Criteria

- [ ] Confirmed stale/duplicate routes are corrected without losing capabilities, finance controls or narrow WordPress entry points.
- [ ] Each maintained view has a declared owner/generation or validation relationship; stale paths and mismatches fail with useful diagnostics.
- [ ] Existing consumers still resolve the same valid agents and no new global service probes or permissions are introduced.

## Seeded Draft PR

Skipped — map ownership and regenerate from current metadata before proposing edits.

Parent: #31280
