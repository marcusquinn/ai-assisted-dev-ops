---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18194: Define adaptive ingress trust and authority contracts

## Pre-flight

- [x] Memory recall: `adaptive ingress trust profiles scan cache attachments deterministic authority prompt injection provider events` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: exact trust-schema targets have 0 recent commits, 0 related merged PRs, and 0 related open PRs; existing prompt/privacy guards are implementation precedents, not an ingress policy contract.
- [x] File refs verified: 9 mission, prompt-guard, privacy, RBAC, Matrix, and Buzz baseline references checked at current HEAD; Buzz remains at `0afeac8a7c173fd3ede8a22e27919e63161bf07c`.
- [x] Tier: `tier:standard` — the trust profiles, minimum controls, cache key, authority ceiling, attachment states, and failure behavior are decided below; implementation adapts established schema/test patterns.
- [x] Seeded draft PR decision recorded: skipped — a partial trust schema without all four profile and escalation negatives would be unsafe to reuse.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive
- **Parent task:** none; this is Milestone 1 feature 1.2
- **Blocked by:** t18193 / #29494 — the trust contract references the versioned core event and identity definitions
- **Conversation context:** The mission requires low-overhead owner-local ingress, progressively stronger shared/external screening, scan-once caching, bounded attachment handling, and deterministic capability enforcement independent of model judgment.

## What

Add a version-1 trust-policy schema, canonical four-profile policy fixture,
ingress-decision and scan-verdict fixtures, executable schema/semantic tests, and
reference documentation. The contract must separate actor trust, content
provenance, attachment risk, requested capability, scan requirements, and final
deterministic authority decisions.

This leaf defines the policy and evidence records only. It does not wire provider
ingress, add a semantic classifier, extract attachments, grant tools, or change
the current prompt/privacy guards.

## Why

A binary trusted/untrusted flag either wastes latency and tokens by rescanning
every owner message or dangerously trusts forwarded content and shared users.
Membership also cannot serve as administrator authority. A contract is needed so
every adapter makes the same fail-closed decision, reuses only valid scan
verdicts, and records why a capability was allowed, denied, reviewed, or
quarantined.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This brief resolves the trust and authority policy rather
than delegating it. The worker implements closed schemas, defaults, tests, and
documentation inside those boundaries with normal local judgment.

## PR Conventions

This is a leaf task. Use a closing keyword for its issue and reference both
mission `m-20260804-5d06b1` and blocker #29494. Do not modify or close the core
issue from this task.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The security contract is only reviewable with all profiles, cache invalidation, attachment outcomes, and privilege-escalation negatives present together.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, exact-path discovery, current prompt/privacy/RBAC reads, and Buzz author-gate/event-format verification completed on 2026-08-04.
- **Verification run:** Unrun before implementation; the core schema dependency is not merged yet.
- **Stale-assumption warning:** Re-check the core schema and Buzz inbound author gate if #29494 or the pinned Buzz baseline changes before this worker starts.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start and profile matrix; they are the authoritative policy decisions.
- **Then load:** `todo/missions/m-20260804-5d06b1/research/source-review.md:162-198` and the merged `core-v1.schema.json` definitions used by the new records.
- **Load only if:** scanner failure/result semantics are unclear — `.agents/scripts/prompt-guard-helper.sh:250-358,1144-1282`; role/capability semantics are unclear — `.agents/tools/app-stack/rbac-permissions.md:30-67`.
- **Why:** implement a bounded contract without copying prompt-guard internals or treating current Buzz author filtering as the final authority broker.
- **Stop when:** all profile minima, decision inputs, cache invalidators, attachment states, and negative privilege cases map to schema fields and tests.

### Worker Quick-Start

```text
1. Reference the merged core contract by stable $id; do not duplicate its actor, event, attachment, or ID definitions.
2. Authorization is deterministic and independent of content scanning.
3. Every profile performs signature/provenance, schema, size/type/path, correlation, idempotency, and output-secret controls.
4. `owner-local` skips semantic scanning only for ordinary direct text; forwarded/external content, attachments, or elevated operations re-enter stronger policy.
5. Membership grants only configured role capabilities, never implicit admin, secret, destructive, billing, publication, or release authority.
6. Cache verdicts only by every declared content, attachment, provenance, profile, scanner, policy, and requested-capability input.
7. Scanner errors, unknown provenance, unsafe attachments, or capability escalation never become a clean/allow result.
```

Canonical minimum profile behavior:

| Profile | Required screening | Default capability ceiling |
|---|---|---|
| `owner-local` | Universal structural controls; semantic scan only for suspicious encoding/content, forwarded provenance, external attachments, or elevated operations | Configured owner operations; explicit destructive/security/billing/publication/release gates remain |
| `trusted-team` | Structural controls plus cached deterministic prompt-pattern scan; semantic escalation for findings, external attachments, or elevated operations | Role-scoped operations; no implicit administrator or secret scope |
| `shared-member` | Deterministic scan before model use, sandboxed attachment extraction only when needed, broker-enforced action scope | Read, answer, and draft by default; explicitly granted non-admin operations only |
| `external-bridged` | Strict deterministic scan/quarantine, content limits, attachment isolation, provenance labeling | Read-only or draft-only; privileged work requires a new trusted authorized job |

### Files to Modify

- `NEW: .agents/schemas/team-interface/trust-v1.schema.json` — trust policy, scan cache/verdict, ingress decision, attachment decision, and authority records.
- `NEW: .agents/reference/team-interface-trust.md` — profile minima, decision order, cache invalidation, attachment handling, authority ceilings, failure behavior, and audit rules.
- `NEW: .agents/scripts/tests/test-team-interface-trust-schema.mjs` — Ajv validation plus semantic policy invariants.
- `NEW: .agents/scripts/tests/fixtures/team-interface/trust-policy-defaults.json` — all four canonical profiles.
- `NEW: .agents/scripts/tests/fixtures/team-interface/trust-valid-decisions.json` — allowed, denied, reviewed, and quarantined outcomes.
- `NEW: .agents/scripts/tests/fixtures/team-interface/trust-invalid-cache-key.json` — incomplete/stale verdict key.
- `NEW: .agents/scripts/tests/fixtures/team-interface/trust-invalid-authority.json` — membership/admin and model-widening attempts.
- `NEW: .agents/scripts/tests/fixtures/team-interface/trust-invalid-attachment.json` — unsafe extraction or bypass attempt.

### Complete Write Surface

- **Callers/readers:** Future provider ingress adapters and authority broker will consume `NEW: .agents/schemas/team-interface/trust-v1.schema.json`; the new Node test is the only runtime reader added now. The schema references core identities/events from t18193 rather than duplicating them.
- **Writers/mutation paths:** Not applicable because this contract-only leaf adds no ingress or cache writer; discovery found prompt/privacy scanners but no team-interface verdict store. Milestone 2 and 6 implementations must validate records before writing them.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-team-interface-trust-schema.mjs` reads the four-profile default plus valid and three invalid fixture families and asserts minimum controls beyond structural schema validation.
- **Schemas/config:** `NEW: .agents/schemas/team-interface/trust-v1.schema.json` is the sole schema/config change and must reference `urn:aidevops:team-interface:core:v1`. Existing prompt-guard and aidevops config schemas remain unchanged.
- **Generated/deployed mirrors:** Tracked `.agents/` sources deploy through the existing setup copy path; no generated mirror or runtime cache file is created by this task.
- **Migrations/backfills:** Not applicable because no prior team-interface trust records exist. Unknown policy/schema versions and legacy records fail closed instead of receiving inferred allow decisions.
- **Cleanup/rollback paths:** Reverting `.agents/schemas/team-interface/trust-v1.schema.json` and its reference/test/fixtures removes only additive contracts; no scan cache, provider event, permission, or attachment is mutated.

### Implementation Steps

1. Create a closed draft-2020-12 schema with stable `$id` `urn:aidevops:team-interface:trust:v1`, `schema_version: 1`, and discriminated documents for `trust_policy`, `scan_verdict`, and `ingress_decision`.
2. Define canonical trust-profile records with the four fixed profile IDs, universal structural checks, deterministic/semantic scan modes, attachment policy, default capabilities, explicit capability ceiling, and escalation conditions. Tests must assert the table above as minimum behavior.
3. Define a content-addressed verdict key requiring `content_digest`, sorted `attachment_digests`, provider/provenance class, trust profile, scanner engine/version, policy version, and requested capability class. A changed key component invalidates reuse.
4. Define scan evidence that distinguishes `not_required`, `not_run`, `clean`, `findings`, `quarantined`, and `error`; record structural, deterministic, semantic, and attachment stages separately. `error` and unknown states cannot produce final `allow`.
5. Define attachment metadata/preflight, sandbox extraction, quarantine, and rejection outcomes. Active documents, executables, archives, macros, unsafe paths/types, or mismatched digests cannot use an owner-local bypass.
6. Define ingress authority inputs and output: verified actor/roles, configured grants and ceilings, requested operation/capability, deterministic decision `allow|deny|review|quarantine`, reason codes, policy version, scan-verdict reference, correlation/idempotency, timestamps, and audit reference. Exclude model-proposed scopes from authority inputs.
7. Add semantic test assertions that membership alone never grants high-risk capability classes, profile defaults cannot exceed their ceilings, semantic scanning is conditional rather than universal for owner-local, and any cache-key change prevents reuse.
8. Document evaluation order: validate provenance/structure → resolve actor/membership/role → derive profile → calculate required scans → validate or create verdict → enforce deterministic capability ceiling → emit auditable decision → run output-secret guard.
9. Run the focused test and changed-file quality gates without editing existing scanners or runtime permissions.

### Hazards and Compatibility

- **Concurrency/atomicity:** The task creates no cache writer, but the contract binds one verdict to an immutable composite key and one policy version. Later writers must publish complete verdicts atomically and never expose partial stage results as clean.
- **Migration/rollback:** There is no prior record migration. A future policy change creates a new policy version and invalidates affected cache entries; rollback may read older evidence only when every composite key field still matches.
- **Mixed-version/backward compatibility:** Existing direct OpenCode and Matrix flows remain unchanged. Legacy inputs without a verified actor, profile, policy version, or decision evidence fail closed rather than inheriting owner permissions.
- **Idempotency/retry:** Repeated ingress for the same event and complete cache key reuses one terminal verdict and one authority decision. Retries after scanner error remain denied/reviewed until a new terminal verdict is recorded.
- **Partial failure/recovery:** Signature, schema, scanner, sandbox, policy lookup, or authority resolution failure yields `deny`, `review`, or `quarantine`; none may be normalized to `clean` or `allow` by a model or adapter.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-trust-schema.mjs
node --input-type=module -e 'import Ajv2020 from "ajv/dist/2020.js"; const ajv = new Ajv2020(); process.exit(typeof ajv.addSchema === "function" ? 0 : 1)'
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Node test loads the core and trust schemas, validates every fixture, and checks profile/authority/cache invariants; the Ajv probe confirms multi-schema support; changed-file lint covers JSON, JavaScript, Markdown, licensing, and secret detection.
- **Broad verification trigger:** Not required — this leaf adds isolated contract/test files and does not alter runtime scanners, permissions, root dependencies, or deployment routing.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-trust-schema.mjs`
- [ ] WIP commit created before broad gates: `wip: add adaptive ingress trust contract`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Define adaptive ingress trust, scan-cache, attachment, and deterministic authority contracts for Milestone 1 feature 1.2.
- **Preserved user directions:** Keep safeguards proportionate, scan once at ingress, never grant administrator authority from membership, and create no write-capable provider flow.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Mission/source evidence, profile minima, and the implementation contract are preserved in this brief.
- **Remaining acceptance criteria:** Implement and verify every schema, fixture, semantic invariant, and reference criterion below.
- **Unsafe route not to repeat:** Do not treat scanner output as authorization, reuse incomplete cache keys, or bypass attachment controls based only on actor trust.
- **Next safe route:** Fail the affected event closed and complete the missing policy/verdict evidence without weakening the other profiles.
- **Resume condition:** t18193 is merged and no in-flight PR touches the declared trust paths.
- **Owner and status:** Assigned implementation worker; blocked by t18193

### Files Scope

- `.agents/schemas/team-interface/trust-v1.schema.json`
- `.agents/reference/team-interface-trust.md`
- `.agents/scripts/tests/test-team-interface-trust-schema.mjs`
- `.agents/scripts/tests/fixtures/team-interface/trust-*.json`

## Acceptance Criteria

- [ ] The canonical policy fixture validates all four profiles and enforces the documented universal controls, conditional escalation rules, attachment handling, and capability ceilings.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-trust-schema.mjs"
  ```

- [ ] A complete cache key reuses one verdict, while any content, attachment, provenance, profile, scanner, policy, or requested-capability change prevents reuse without stale fallback.

  ```yaml
  verify:
    method: codebase
    pattern: "content_digest|attachment_digests|provenance_class|scanner_version|policy_version|requested_capability"
    path: ".agents/scripts/tests/test-team-interface-trust-schema.mjs"
  ```

- [ ] Membership, display labels, model suggestions, or a clean scan never grant implicit administrator, secret, destructive, billing, publication, or release authority.

  ```yaml
  verify:
    method: codebase
    pattern: "trust-invalid-authority|administrator|destructive|publication|release"
    path: ".agents/scripts/tests/test-team-interface-trust-schema.mjs"
  ```

- [ ] Scanner errors, unknown provenance, malformed events, unsafe attachments, and capability escalation are denied, reviewed, or quarantined and are never represented as clean/allowed decisions.

  ```yaml
  verify:
    method: codebase
    pattern: "error.*(deny|review|quarantine)|unsafe.*attachment|unknown.*provenance"
    path: ".agents/reference/team-interface-trust.md"
  ```

- [ ] Existing prompt-guard, privacy filter, Matrix, and Buzz runtime behavior remains unchanged by this contract-only leaf.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code -- .agents/scripts/prompt-guard-helper.sh .agents/scripts/privacy-filter-helper.sh .agents/services/communications/matrix-bot.md"
  ```

- [ ] Changed-file quality and secret scans pass.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Actor trust, content provenance, attachment risk, and requested capability are independent axes.
- Universal structural checks are cheap and mandatory; semantic scanning is conditional and never an authority oracle.
- Trust profiles choose minimum screening and maximum default capability, while deterministic grants/ceilings produce the final decision.
- Scan-once reuse is safe only when the complete composite key matches; policy and capability changes invalidate prior verdicts.
- Internally generated signed events may skip semantic scanning but not structural validation, authorization, idempotency, or output-secret checks.

## Relevant Files

- `todo/missions/m-20260804-5d06b1/mission.md:93-111,141-153` — trust policy and feature scope.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:162-198` — adaptive controls and cache-key recommendation.
- `.agents/scripts/prompt-guard-helper.sh:250-358` — deterministic scan findings versus scanner-error distinction.
- `.agents/scripts/prompt-guard-helper.sh:1144-1282` — current conditional deep-classification pattern and fail-closed unknown handling.
- `.agents/scripts/privacy-filter-helper.sh:48-95,176-207` — existing output/privacy secret patterns and Secretlint path.
- `.agents/tools/app-stack/rbac-permissions.md:30-67` — action/scope dimensions, default deny, cache invalidation, and audit precedent.
- `.agents/services/communications/matrix-bot.md:124-138` — current Matrix trigger, privacy, and runner restrictions to preserve.
- `crates/buzz-acp/src/lib.rs:218-279` in Buzz baseline `0afeac8a7c173fd3ede8a22e27919e63161bf07c` — current coarse author gate and DM fail-closed behavior.
- `crates/buzz-acp/src/queue.rs:1072-1147` in the same Buzz baseline — provider event/actor/thread fields currently rendered into prompts.

## Dependencies

- **Blocked by:** t18193 / #29494 — core event, identity, attachment, correlation, and secret-reference definitions.
- **Blocks:** Milestone 3 trust-policy views, Milestone 6 authority-broker handoff, and Milestone 7 trust-profile overhead/security fixtures.
- **External:** No credentials or live provider are required. Semantic scanning and sandbox extraction remain later implementations; this task defines their inputs/outcomes only.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Trust/decision schema | 1h 15m | Profiles, verdicts, authority, attachments |
| Fixtures and semantic tests | 1h 15m | Four profiles plus three negative families |
| Reference documentation | 40m | Evaluation order, cache, failure behavior |
| Focused verification/review | 20m | Node test and changed-file lint |
| **Total** | **3h 30m** | |
