---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18197: Define safe reconciliation and rollback contracts

## Pre-flight

- [x] Memory recall: `managed field ownership three-way reconciliation desired last applied actual revision CAS retirement rollback audit stable external IDs drift` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: exact reconciliation-schema targets have 0 recent commits, 0 related merged PRs, and 0 related open PRs; current user-content preservation and CAS routines are precedents, not a provider reconciliation contract.
- [x] File refs verified: 7 mission, source-review, CAS/replay, rollback, and user-field preservation references checked at current HEAD; Buzz remains at the reviewed baseline `0afeac8a7c173fd3ede8a22e27919e63161bf07c`.
- [x] Tier: `tier:standard` — ownership classes, three-way decisions, CAS preconditions, retirement, rollback, audit, and fallback behavior are decided below; implementation follows established schema/test patterns.
- [x] Seeded draft PR decision recorded: skipped — a partial schema without stale-plan, user-overwrite, display-name adoption, delete, and rollback negatives would be unsafe to reuse.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive
- **Parent task:** none; this is Milestone 1 feature 1.4
- **Blocked by:** t18193 / #29494 — reconciliation records reference versioned core resources, capabilities, identities, stable IDs, and secret references
- **Conversation context:** The mission requires idempotent non-destructive updates that preserve user customizations, fail closed on security drift, use revision/CAS, never adopt by display name, and fall back to owner-reviewed drafts where providers lack safe apply capabilities.

## What

Add a version-1 reconciliation schema covering field ownership, three-way
inputs, deterministic plans, CAS preconditions, apply receipts, retirement,
rollback, and audit evidence. Add positive and negative fixtures, executable
schema/semantic tests, and reference documentation.

This leaf defines records and decision invariants only. It does not detect
providers, read or write live resources, submit Buzz drafts, mutate user
configuration, apply plans, retire records, or execute rollback.

## Why

Blind replacement would overwrite user-edited names, models, startup settings,
memberships, mappings, and provider state. Retrying a stale plan could also
clobber concurrent edits, while matching by display name could adopt the wrong
resource. A provider-neutral contract is needed so every adapter produces the
same explainable field decisions and can prove preconditions, side effects,
conflicts, recovery, and non-deletion.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The security and ownership policy is fully prescribed in
this brief. The worker implements additive closed schemas, fixtures, semantic
assertions, and documentation with bounded local judgment.

## PR Conventions

This is a leaf task. Use a closing keyword for its issue and reference mission
`m-20260804-5d06b1` plus blocker #29494. Do not modify or close the core-contract
issue from this task.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Field decisions, CAS, non-adoption, retirement, receipts, and rollback must be reviewed as one coherent safety contract.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, exact-path discovery, mission/source review, coordinator replay/CAS, recovery rollback, and user-field preservation reads completed on 2026-08-04.
- **Verification run:** Unrun before implementation; the core schema dependency is not merged yet.
- **Stale-assumption warning:** Re-check the merged core resource/capability definitions and current Buzz managed-agent API before implementation if #29494 or the pinned baseline changes.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start and decision table; they are the authoritative reconciliation algorithm.
- **Then load:** `todo/missions/m-20260804-5d06b1/research/source-review.md:272-284`, `.agents/reference/task-coordinator-architecture.md:228-263`, and the merged `core-v1.schema.json` definitions.
- **Load only if:** user-field merge precedent is unclear — `.agents/scripts/update-claude-settings.py:235-257` and `.agents/scripts/frontmatter-helper.sh:144-176`; rollback evidence is unclear — `.agents/reference/dirty-worktree-preservation.md:53-72`.
- **Why:** implement one deterministic contract without importing provider-specific apply behavior or unrelated transaction machinery.
- **Stop when:** every ownership class, decision outcome, precondition, terminal/indeterminate state, retire/rollback rule, and negative fixture maps to a schema field and test.

### Worker Quick-Start

```text
1. Reference merged core resources by stable internal and opaque external IDs; display labels never identify or adopt a record.
2. Decide each field from desired, last-applied, and freshly observed actual state under a versioned ownership policy.
3. User-owned or user-modified fields are preserved; ordinary managed fields update only when actual still equals last-applied.
4. Security-required drift yields review/disable, never silent preservation, overwrite, or widened authority.
5. Every apply/retire/rollback plan binds an immutable plan hash and expected provider revision/ETag/observation hash; stale preconditions produce conflict and replan.
6. Missing safe provider capabilities yields an owner-reviewed draft or unsupported result, never simulated unattended apply.
7. Removal means reviewed disable/retire/archive/detach; automatic delete is not representable.
8. Rollback is a new CAS-guarded plan from verified receipts, not a blind rewind or deletion.
```

Canonical field decisions:

| Ownership/state | Decision | Required result |
|---|---|---|
| User-owned | Preserve actual | `preserve_actual`; report desired difference without mutation |
| Managed; actual equals last-applied | Apply desired or no-op | `apply_desired` or `no_change` |
| Managed; actual differs from last-applied | Preserve as user-modified | `preserve_actual` plus drift evidence |
| Security-required drift | Stop unsafe execution | `review_required` or `disable_execution` |
| Missing last-applied/ownership identity on existing record | Do not adopt | `review_required` with unmanaged-resource evidence |

### Files to Modify

- `NEW: .agents/schemas/team-interface/reconciliation-v1.schema.json` — ownership policy, three-way input, plan, receipt, retirement, rollback, and audit records.
- `NEW: .agents/reference/team-interface-reconciliation.md` — algorithm, capability gates, concurrency, non-adoption, retirement, rollback, failure, and audit rules.
- `NEW: .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs` — Ajv validation plus deterministic field/CAS invariants.
- `NEW: .agents/scripts/tests/fixtures/team-interface/reconciliation-valid-plan.json` — apply, preserve, no-op, review, and disable field decisions.
- `NEW: .agents/scripts/tests/fixtures/team-interface/reconciliation-valid-retire-rollback.json` — reviewed retirement and receipt-based rollback plans.
- `NEW: .agents/scripts/tests/fixtures/team-interface/reconciliation-invalid-overwrite.json` — user/user-modified or security field silently overwritten.
- `NEW: .agents/scripts/tests/fixtures/team-interface/reconciliation-invalid-cas.json` — missing/stale preconditions, ambiguous retry, or receipt mismatch.
- `NEW: .agents/scripts/tests/fixtures/team-interface/reconciliation-invalid-adoption-delete.json` — display-name adoption or automatic delete attempt.

### Complete Write Surface

- **Callers/readers:** Future desired-state planner, provider adapters, app-team manifests, aidevops.app plan/review APIs, apply coordinator, and audit views will consume `NEW: .agents/schemas/team-interface/reconciliation-v1.schema.json`; the new Node test is the only runtime reader added now. The schema references t18193 core resources/capabilities rather than duplicating them.
- **Writers/mutation paths:** Not applicable because this contract-only leaf performs no detection, provider read, plan persistence, apply, draft submission, retirement, or rollback. Milestones 2-5 must validate these records before any external or local mutation.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs` loads two valid and three invalid fixture families, compiles core plus reconciliation schemas, and asserts the field-decision and state-transition rules beyond structural validation.
- **Schemas/config:** `NEW: .agents/schemas/team-interface/reconciliation-v1.schema.json` is the sole schema/config change. Existing setup/config merge code, provider state, and runtime configuration remain unchanged; app-team manifests carry only a stable reconciliation-policy reference.
- **Generated/deployed mirrors:** Tracked `.agents/` sources deploy through the existing setup copy path. This task generates no desired state, plan, provider draft, receipt, snapshot, audit log, or separately maintained mirror.
- **Migrations/backfills:** Not applicable because no prior team-interface reconciliation records exist. Legacy/ad hoc provider records without stable ownership and last-applied evidence remain unmanaged and require owner review; the task must not infer a backfill from names.
- **Cleanup/rollback paths:** Reverting `.agents/schemas/team-interface/reconciliation-v1.schema.json`, `.agents/reference/team-interface-reconciliation.md`, `.agents/scripts/tests/test-team-interface-reconciliation-schema.mjs`, and the `reconciliation-*.json` fixtures removes the additive contract. No provider resource, user field, receipt, or state snapshot is created or deleted.

### Implementation Steps

1. Create a closed draft-2020-12 schema with stable `$id` `urn:aidevops:team-interface:reconciliation:v1`, `schema_version: 1`, and discriminated documents for `ownership_policy`, `reconciliation_input`, `reconciliation_plan`, `apply_receipt`, and `rollback_plan`.
2. Define versioned ownership rules keyed by normalized JSON Pointer: `user_owned`, `managed`, or `security_required`; include policy ID/version, resource kind, safe value/reference representation, and explicit prohibition on unknown-field ownership inference.
3. Define three-way field input with desired, last-applied, and actual value digests plus safe non-secret value/reference data, observation time, stable resource/external identity, manager marker, and policy reference. Sensitive fields accept approved secret references only, never values.
4. Define field decisions exactly as the table above with reason codes and drift evidence. The schema/test must prevent `apply_desired` for user-owned fields, changed managed fields, or security drift.
5. Define plan-level outcomes `create|update|no_change|review|disable|retire|rollback|owner_reviewed_draft|unsupported`; do not include `delete`. Require provider capability evidence and force `owner_reviewed_draft|unsupported` when stable external IDs, managed metadata, supported apply, or revision/CAS are absent.
6. Bind every mutating plan to `operation_id`, canonical resource ID, provider/community, plan hash, desired/policy/adapter versions, fresh observed revision or ETag plus observation hash/time, expected revision, correlation/idempotency, verified actor/authorization references, and expiry. A mismatch returns `conflict` without side effects or stale retry.
7. Define apply receipts with terminal state `published|retryable|indeterminate|terminal|conflict|partial`, before/after revisions and digests, exact field outcomes, provider receipt/evidence references, timestamps, and audit reference. Reusing an operation ID with a different plan hash is a hard conflict; indeterminate/partial results require read-after-write reconciliation.
8. Define retirement as explicit reviewed `disable|archive|detach` policy with stable identity retained. Define rollback as a new plan referencing a verified successful receipt/snapshot, restoring only previously managed fields under current ownership/CAS and never deleting or resurrecting an ambiguous record.
9. Add semantic tests for all decision-table rows, stable-ID-only matching, stale revision/plan expiry, changed operation payload, unsupported-provider draft fallback, no delete enum, auditable partial/indeterminate states, and rollback receipt/revision binding.
10. Document re-read-before-apply, no blind retry, provider capability negotiation, atomicity/partial failure, per-provider/community rollback boundaries, redaction, and how future planners expose decisions without moving security logic into the UI.
11. Run focused schema tests and changed-file quality gates without touching current setup merges, provider adapters, runtime permissions, or user configuration.

### Hazards and Compatibility

- **Concurrency/atomicity:** Plans bind a fresh observation and expected revision/ETag. A mismatch or expired plan is `conflict`; re-read and generate a new plan. Providers without atomic apply/CAS are owner-reviewed only, and partial writes remain non-success until observed and reconciled.
- **Migration/rollback:** No prior record is auto-adopted or backfilled. Schema evolution requires explicit version migration. Contract rollback removes additive files; operational rollback is always a new receipt-bound, CAS-checked plan limited to managed fields.
- **Mixed-version/backward compatibility:** Existing setup merges, Matrix, Buzz drafts, and direct aidevops use remain unchanged. Unknown schema/policy/adapter versions or missing capability evidence return unsupported/review rather than permissive apply.
- **Idempotency/retry:** The same operation ID and plan hash may return its recorded receipt. A different hash is conflict. Timeouts and ambiguous provider responses become indeterminate and require stable-ID read-after-write before retry.
- **Partial failure/recovery:** A partial/indeterminate receipt records each known field effect, blocks success, and preserves before/after evidence. Recovery re-reads actual state and replans; it never assumes rollback, repeats create, or overwrites preserved fields.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs
node --input-type=module -e 'import Ajv2020 from "ajv/dist/2020.js"; const ajv = new Ajv2020(); process.exit(typeof ajv.addSchema === "function" ? 0 : 1)'
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Node test compiles core and reconciliation schemas, validates every fixture, and checks ownership, three-way, identity, capability, CAS, retry, retirement, receipt, rollback, and audit invariants; the Ajv probe confirms multi-schema support; changed-file lint covers JSON, JavaScript, Markdown, licensing, and secrets.
- **Broad verification trigger:** Not required — this leaf adds isolated contract/test files and does not alter runtime writers, setup/config merge paths, provider behavior, root dependencies, or deployment routing.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs`
- [ ] WIP commit created before broad gates: `wip: add safe reconciliation contract`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Define managed ownership, three-way reconciliation, CAS, retirement, rollback, and audit contracts for Milestone 1 feature 1.4.
- **Preserved user directions:** Preserve user customizations, stop on security drift, require safe provider capabilities, never match by display name, and never delete automatically.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Mission/source evidence, field decisions, lifecycle states, and implementation boundaries are preserved in this brief.
- **Remaining acceptance criteria:** Implement and verify every schema, fixture, semantic invariant, and reference criterion below.
- **Unsafe route not to repeat:** Do not blind-replace records, infer ownership, retry stale plans, claim ambiguous success, adopt by name, simulate unattended Buzz apply, or encode automatic deletion.
- **Next safe route:** Preserve current state, emit conflict/review/indeterminate evidence, re-read by stable identity, and build a new bounded plan.
- **Resume condition:** t18193 is merged and no in-flight PR touches the declared reconciliation paths.
- **Owner and status:** Assigned implementation worker; blocked by t18193

### Files Scope

- `.agents/schemas/team-interface/reconciliation-v1.schema.json`
- `.agents/reference/team-interface-reconciliation.md`
- `.agents/scripts/tests/test-team-interface-reconciliation-schema.mjs`
- `.agents/scripts/tests/fixtures/team-interface/reconciliation-*.json`

## Acceptance Criteria

- [ ] Valid plan fixtures deterministically produce apply/no-op for unchanged managed fields, preserve for user/user-modified fields, and review/disable for security-required drift.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs"
  ```

- [ ] User-owned or user-modified fields cannot produce `apply_desired`, security drift cannot silently preserve/overwrite, and unknown ownership cannot be inferred.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-overwrite|user_owned|preserve_actual|security_required|disable_execution|unknown.*ownership"
    path: ".agents/scripts/tests/test-team-interface-reconciliation-schema.mjs"
  ```

- [ ] Every mutation plan has a fresh expected revision/ETag and immutable plan hash; stale, expired, changed-payload, partial, or indeterminate cases require conflict/read-after-write/replan rather than blind retry.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-cas|expected_revision|etag|plan_hash|indeterminate|read-after-write|conflict"
    path: ".agents/scripts/tests/test-team-interface-reconciliation-schema.mjs"
  ```

- [ ] Display-name adoption and automatic deletion are unrepresentable; retirement preserves stable identity, and rollback references a verified receipt while restoring only managed fields under current CAS.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-adoption-delete|display.*name|retire|archive|detach|rollback.*receipt|managed.*field"
    path: ".agents/reference/team-interface-reconciliation.md"
  ```

- [ ] Missing stable management/CAS/apply capabilities yields owner-reviewed draft or unsupported state and never unattended mutation; all terminal and ambiguous outcomes carry redacted audit evidence.

  ```yaml
  verify:
    method: codebase
    pattern: "owner_reviewed_draft|unsupported|capabilit|audit|redact|partial|indeterminate"
    path: ".agents/reference/team-interface-reconciliation.md"
  ```

- [ ] Existing setup/config merge, Matrix, Buzz, and direct aidevops behavior remains unchanged by this contract-only leaf.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code -- .agents/scripts/update-claude-settings.py .agents/scripts/frontmatter-helper.sh .agents/services/communications/matrix-bot.md .agents/configs/aidevops-config.schema.json"
  ```

- [ ] Changed-file quality and secret scans pass.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Field ownership is explicit and versioned. A desired document alone never grants permission to manage every field.
- Three-way comparison is field-level: desired and last-applied describe framework intent; freshly observed actual state determines whether an ordinary managed field is still safe to change.
- Security-required fields fail closed because preserving unsafe drift can be as dangerous as overwriting user changes.
- Provider capability evidence controls apply mode. Buzz's current owner-reviewed draft is a legitimate compatibility outcome, not an unattended apply substitute.
- Retirement and rollback preserve stable identity and audit history. Neither operation authorizes automatic delete or blind replacement.

## Relevant Files

- `todo/missions/m-20260804-5d06b1/mission.md:49-91,141-153` — non-destructive reconciliation requirements and feature boundary.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:58-64,272-284,383-403` — Buzz capability gap, three-way algorithm, and required regression families.
- `.agents/reference/task-coordinator-architecture.md:228-263` — expected-revision, operation hash, replay, indeterminate, terminal, and conflict precedent.
- `.agents/reference/dirty-worktree-preservation.md:53-72` — verified snapshot, CAS, rollback, and safe-retry precedent.
- `.agents/scripts/update-claude-settings.py:235-257` — exact framework-owned removal plus user-authored permission preservation pattern.
- `.agents/scripts/frontmatter-helper.sh:144-176` — managed standard fields with preserved custom fields pattern.
- `todo/tasks/t18193-brief.md:114-136` — future core resource, stable-ID, version, and failure boundaries this schema must reference after merge.

## Dependencies

- **Blocked by:** t18193 / #29494 — core resources, provider capabilities, identities, stable IDs, event correlation, and secret references.
- **Blocks:** Milestone 2 desired-state planner, Milestone 3 reconciliation views, Milestone 4 Buzz managed provisioning, and Milestone 7 drift/rollback fixtures.
- **External:** No credentials or live provider are required. Buzz remains owner-reviewed until upstream exposes verified stable management metadata, revision/CAS, and supported apply semantics.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Reconciliation schema | 1h 30m | Ownership, plans, CAS, receipts, retire/rollback |
| Fixtures and semantic tests | 1h 25m | Decision table plus stale/overwrite/adoption negatives |
| Reference documentation | 40m | Algorithm, capability gates, recovery, audit |
| Focused verification/review | 25m | Node test and changed-file lint |
| **Total** | **4h** | |
