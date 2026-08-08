---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18221: Show delegated child counts in routing feedback toasts

## Pre-flight

- [x] Memory recall: `session subagent analysis escalation toast delegation events observability` → 0 hits — no relevant stored lessons
- [x] Discovery pass: 1 commit / 1 merged PR / 0 open PRs touch the target files in the last 48 hours — PR #29682 created the routing-feedback pipeline; no in-flight collision or exact open duplicate exists
- [x] File refs verified: 8 refs checked at `b6676f77c02cd51b377386bd439fac2b7a57cecf`, all present and matching HEAD
- [x] Tier: `tier:standard` — the pipeline and data fields exist, but distinct-child aggregation and concise toast wording require bounded implementation judgment
- [x] Seeded draft PR decision recorded: skipped — current-session research resolved the boundaries, but issue-only avoids anchoring the worker to untested aggregation code

## Origin

- **Created:** 2026-08-08
- **Session:** OpenCode:interactive-2026-08-08
- **Created by:** ai-interactive after the user asked whether lower-tier delegations appear in the existing escalation/routing toast
- **Parent task:** None; follow-up to completed t18220 / issue #29813
- **Blocked by:** None; PR #29814 has merged
- **Conversation context:** t18220 teaches thinking-tier parents to delegate bounded output-heavy work to simple or standard children, but it deliberately excluded runtime/plugin telemetry. The user expects the existing session routing analysis and toast to show those delegations as well as escalations.

## What

Extend the existing provider-neutral routing-feedback summary so it derives the number of distinct delegated child sessions and their starting-tier distribution from records that already contain `parent_session_id`. Show that aggregate in the existing Markdown feedback and the existing interactive `session.idle` toast, alongside escalation data.

Count one delegation per distinct parent/child session pair, not one per LLM request. Attribute each child to the first valid routing tier recorded for that child so a child that later escalates remains one delegation while the existing route path and escalation count describe its escalation.

Do not add a new event stream, database column, per-tool-call toast, or toast invocation. The current idle-only, fingerprint-deduplicated feedback surface remains authoritative.

## Why

PR #29814 now encourages thinking-tier interactive parents to use simple or standard advisory children for bounded verbose work. The telemetry pipeline created by PR #29682 already records child and parent session IDs and reports tier paths, retries, costs, and escalations, but `summarizeRoutingMetrics()` does not expose delegated-child counts and `formatRoutingFeedbackToast()` therefore cannot show whether lower-tier delegation actually occurred.

Without delegation visibility, the user sees escalation outcomes but cannot tell from the completion toast whether the new cost/context-saving route was used. Reusing existing completed-request records provides that feedback without increasing toast frequency or collecting new data.

## Tier

### Tier checklist

- [ ] **Exact execution contract supplied?** Function boundaries and semantics are fixed, but the worker must adapt established JavaScript patterns and test fixtures rather than copy complete file replacements.
- [x] **Targets and reference pattern verified?** Summary, formatter, fingerprint, handler, parent join, and tests were read at HEAD.
- [x] **No semantic or design decision remains?** Distinct-child identity, first-tier attribution, missing-field behavior, output surface, and no-new-toast boundary are decided.
- [x] **Bounded, reversible, low-consequence impact?** Derived telemetry only; no routing decision or persisted request changes.
- [x] **No stateful coordination to invent?** Aggregation reads existing records and the existing handler keeps its current lifecycle.
- [x] **Focused verification and rollback are explicit?** Node tests, shell consumers, plugin suite, and five-file rollback are specified.
- [x] **No dispatch-path risk override?** None of the scoped files appears in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:standard`

**Tier rationale:** This is bounded adaptation of an established telemetry pipeline with normal local implementation judgment and no unresolved architecture or trust boundary.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The issue supplies verified data semantics and tests; implementation code has not been run and should not be presented as a seed.
- **Status:** `not-created`
- **Freshness evidence:** Files and foundational PR #29682 were verified against current HEAD after PR #29814 merged.
- **Verification run:** `UNVERIFIED — implementation tests not run because this issue briefs future work`
- **Stale-assumption warning:** Re-read the summary return shape, toast format, and handler fingerprint use before editing; stop and reassess if another PR changes those contracts.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/routing-feedback-summary.mjs:58-74,116-158` — derive distinct delegated children and starting-tier counts, then expose them in the summary.
- `EDIT: .agents/scripts/routing-feedback.mjs:91-148` — format delegation aggregates in Markdown/toasts and include them in duplicate-suppression fingerprints.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs:18-131` — cover deduplication, tier attribution, formatting, and fingerprints.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-routing-feedback-handler.mjs:14-48` — prove delegation changes update the existing idle toast once without adding event types.
- `EDIT: .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs:10-57` — prove a completed child joined to its parent contributes one delegation.

### Complete Write Surface

- **Callers/readers:** `.agents/plugins/opencode-aidevops/observability-routing.mjs:30-59` indexes each routed child record under child and parent IDs and calls `summarizeRoutingFeedback()`; `.agents/plugins/opencode-aidevops/routing-feedback-handler.mjs:17-46` formats and fingerprints the summary at `session.idle`; routine and closeout consumers call the Markdown formatter.
- **Writers/mutation paths:** `.agents/plugins/opencode-aidevops/observability-routing.mjs:36-59` already writes `session_id`, `parent_session_id`, and `routing_tier`; this task does not change that writer.
- **Tests/fixtures:** The three scoped Node test files encode summary, toast, idle dedup, and child-to-parent joining. `.agents/scripts/tests/test-routine-routing-feedback.sh` and `.agents/scripts/tests/test-routing-feedback-closeout.sh` verify shared Markdown consumers and must run unchanged.
- **Schemas/config:** N/A — derived analysis because all required fields already exist in in-memory and persisted request records; no config or model-routing schema changes.
- **Generated/deployed mirrors:** N/A — source-only JavaScript and tests because normal setup/release deployment copies merged `.agents/` content; do not edit deployed files.
- **Migrations/backfills:** N/A — read-time aggregation because no database field or historical record shape changes.
- **Cleanup/rollback paths:** Revert `.agents/scripts/routing-feedback-summary.mjs`, `.agents/scripts/routing-feedback.mjs`, and the three scoped plugin test files together; existing route/escalation feedback remains valid when delegation fields are absent.

### Implementation Steps

1. Add a bounded helper near `tierCounts()` in `.agents/scripts/routing-feedback-summary.mjs` that scans routed request records only. For each record, normalize `parent_session_id`, `session_id`, and tier; skip records missing any of them. Key children by parent plus child ID, retain only the first valid tier for each key, and return:

```js
{
  delegationCount: children.size,
  delegationTiers: { simple: 0, standard: 0, thinking: 0 },
}
```

Do not count routed attempts, repeated requests in one child, or records without a parent as new delegations. A child that starts simple and later records standard remains one simple-start delegation; existing escalation fields retain the later transition.

2. Merge those derived fields into `summarizeRoutingMetrics()` without changing existing fields or recommendation thresholds. Keep `hasData` semantics based on routed evidence.

3. In `.agents/scripts/routing-feedback.mjs`, add a compact delegation label only when `delegationCount > 0`, for example `2 delegated children (1 simple, 1 standard)`. Include it in both Markdown counts and the existing toast sentence. Add `delegationCount` and deterministic tier counts to `routingFeedbackFingerprint()` so a newly completed child changes the root summary once.

4. Do not change `createRoutingFeedbackHandler()` timing or add tool/message hooks. Extend its test data so the existing `session.idle` path emits once for one delegation, suppresses an identical second idle event, and emits one updated toast when another distinct child appears.

5. Add summary tests with repeated requests and an escalated child. Assert distinct-child count, first-tier attribution, omission for parentless records, Markdown/toast wording, and fingerprint change. Add parent-join assertions in `test-observability-routing-join.mjs`.

6. Run focused Node tests first, unchanged shell-consumer tests second, then the plugin suite and changed-file lint. Treat wording assertions as user-visible behavior; do not weaken them to make a noisy or ambiguous toast pass.

### Hazards and Compatibility

- **Concurrency/atomicity:** Analysis operates on a snapshot of existing records. No new event or mutable shared-state path is introduced; the handler's existing fingerprint map remains the toast dedup authority.
- **Migration/rollback:** No migration. Reverting the five scoped files removes only derived fields and assertions.
- **Mixed-version/backward compatibility:** Missing `parent_session_id`, `session_id`, or tier produces zero delegations while preserving all existing summary fields and output. Persisted historical records remain readable.
- **Idempotency/retry:** Repeated requests from one child and repeated `session.idle` events must not inflate counts or duplicate identical toasts. Separate child session IDs count as separate actual delegations.
- **Partial failure/recovery:** Malformed or incomplete records are skipped for delegation counting but remain eligible for existing routing analysis where applicable; formatting must tolerate absent new fields as zero.
- **Noise budget:** Do not emit per-delegation or per-tool-call notifications. One existing idle toast may update only when its fingerprinted aggregate changes.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs .agents/plugins/opencode-aidevops/tests/test-routing-feedback-handler.mjs .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs
bash .agents/scripts/tests/test-routine-routing-feedback.sh
bash .agents/scripts/tests/test-routing-feedback-closeout.sh
npm --prefix .agents/plugins/opencode-aidevops test
bash .agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Node tests cover summary, toast, fingerprint, idle dedup, and parent join; shell tests protect shared Markdown consumers; the plugin suite catches observability/plugin regressions; changed lint validates the exact edited files.
- **Broad verification trigger:** The plugin suite is required because the formatter and summary are shared plugin contracts; no full-repository gate is required.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node --test .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs .agents/plugins/opencode-aidevops/tests/test-routing-feedback-handler.mjs .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`
- [ ] WIP commit created before broader gates: `wip: add delegation counts to routing feedback`
- [ ] Evidence-triggered broad verification then run: `npm --prefix .agents/plugins/opencode-aidevops test`

### Files Scope

- `.agents/scripts/routing-feedback-summary.mjs`
- `.agents/scripts/routing-feedback.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-routing-feedback-handler.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs`

## Acceptance Criteria

- [ ] A parent summary counts each distinct parent/child session pair once and reports starting-tier totals for simple, standard, and thinking children.
- [ ] Repeated LLM requests and later escalation within one child do not inflate delegation count or reclassify that child's starting tier.
- [ ] Existing Markdown feedback and the existing interactive idle toast show a concise delegated-child aggregate when nonzero, alongside escalation data.
- [ ] Parentless, malformed, or historical records without complete delegation identity preserve existing output and do not create false delegations.
- [ ] No new toast event, per-tool-call notification, persistence field, database migration, runtime router, or provider-specific model logic is added.
- [ ] Fingerprint dedup suppresses unchanged idle summaries and permits exactly one updated toast when a new distinct delegation changes the aggregate.
- [ ] Focused Node tests, unchanged shell-consumer tests, the plugin suite, and changed-file lint pass.

## Context & Decisions

- t18220 / issue #29813 and PR #29814 changed guidance and comprehension only; they explicitly excluded plugin/runtime telemetry.
- PR #29682 is the canonical implementation pattern for routing summaries, parent joins, fingerprints, and idle toasts.
- Count actual delegated child sessions, not raw request volume. Starting tier answers whether simple/standard delegation was attempted; existing escalation metrics answer whether it had to rise.
- Reuse the current aggregate idle surface to avoid notification fatigue.
- Keep the implementation provider-neutral and derive data at read time from fields already collected.

## Dependencies

- **Blocked by:** None; PR #29814 is merged.
- **Blocks:** Observable validation that interactive parents are using lower-tier delegated work as intended.
- **External:** None; no credentials, purchases, or provider setup.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | Re-read summary, formatter, handler, join, and prior-art tests |
| Implementation | 25m | Add distinct-child aggregation and bounded formatting |
| Testing | 25m | Focused Node, shell consumers, plugin suite, changed lint |
| **Total** | **1h** | Bounded provider-neutral telemetry enhancement |
