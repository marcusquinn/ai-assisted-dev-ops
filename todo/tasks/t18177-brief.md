---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18177: Add approval-bound shared X scheduling and notification operations

## Pre-flight

- [x] Memory recall: `X shared account scheduled posts notifications outbound queue approval idempotency xurl social operations` → 0 hits.
- [x] Discovery: no related open issue or PR; recent social corpus phases and PR #28621 reviewed.
- [x] File refs verified against current `origin/main` in the linked worktree.
- [x] Installed dependency check: `xurl` is not installed; fake-executable runtime tests are required and live X verification remains credential-gated.
- [x] Tier: `tier:thinking` — security-sensitive state machine, scheduler, provider writes, migration, and cross-surface tests.

## Origin

- **Created:** 2026-07-25
- **Session:** OpenCode interactive follow-up to t18176
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** no implementation blocker; live provider verification requires a separately configured `xurl` installation/profile.
- **Conversation context:** The user requested shared-account storage plus posting, scheduled publishing, notification tracking, likes, bookmarks, and replies.

## What

Add a provider-neutral outbound operations layer for owner-managed personal or
workspace corpora, with X as the first execution adapter. Support immediate and
scheduled `post`, `reply`, `like`, and `bookmark` actions through one durable,
approval-bound queue. Project inbound mentions/replies into a mutable local
notification workflow without changing immutable social evidence.

The outbound subsystem remains separate from the API/archive/browser knowledge
collector, whose provider contract stays read-only.

## Why

`xurl-helper.sh` can execute individual writes after `--confirm-write`, but that
boolean is not bound to a durable payload, account, target, approver, or expiry.
The content calendar records dates without publishing, and mention activities
have no unread/action-required/responded lifecycle. Directly joining these
surfaces would permit approval substitution, duplicate writes after timeouts,
competing schedulers, or shared-member access becoming posting authority.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The task creates a new security-sensitive state machine,
migrates private SQLite stores, executes external writes, handles concurrency and
ambiguous outcomes, and must preserve encrypted-sharing and read-only boundaries.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The queue/approval transition design must be verified with focused tests before any implementation is published.
- **Status:** `not-created`
- **Freshness evidence:** memory, duplicate, target history, file-reference, dependency, and implementation-map discovery completed on 2026-07-25.
- **Verification run:** all seven social suites pass 247 tests; changed-file lint passes.
- **Stale-assumption warning:** re-check `xurl-helper.sh`, social schema version, and sharing table allowlist after rebasing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/knowledge_social_store.py`, `.agents/scripts/xurl-helper.sh`, and `.agents/aidevops/knowledge-plane/05-social-operations.md`.
- **Then load:** `_knowledge_social_share_data.py`, X persistence/normalization, catalog authorization, and the focused social tests.
- **Load only if:** scheduler mechanics need a precedent — `deferred-job-helper.sh` and `reference/routines.md`.
- **Why:** preserve collection/sharing invariants while keeping outbound state independently reviewable.
- **Stop when:** all acceptance criteria have exact tests and the fake-X runtime proves mapped command arguments and identity binding.

### Reference Patterns

- `.agents/scripts/deferred-job-helper.sh:282-330` — versioned queued/claimed/running/terminal state shape.
- `.agents/scripts/_knowledge_social_x_persist.py:237-284` — one transaction for lease assertion, durable state, cursor, and receipt.
- `.agents/scripts/xurl-helper.sh:11-97` — mapped writes, forbidden secret flags, and explicit write confirmation.
- `.agents/scripts/_knowledge_social_share_data.py:37-142` — explicit snapshot table allowlist that must continue excluding local operational state.

### Files to Modify

- `EDIT: .agents/scripts/knowledge_social_store.py` — additive schema migration.
- `NEW: .agents/scripts/_knowledge_social_outbound.py` — canonical intent and approval state.
- `NEW: .agents/scripts/_knowledge_social_outbound_runtime.py` — fenced claims, attempts, receipts, and lease expiry.
- `NEW: .agents/scripts/_knowledge_social_outbound_reconciliation.py` — explicit unknown-outcome reconciliation and privacy-safe history.
- `NEW: .agents/scripts/_knowledge_social_outbound_provider.py` — fixed-argv X write mapping and response validation.
- `NEW: .agents/scripts/_knowledge_social_notifications.py` — idempotent notification projection and state changes.
- `NEW: .agents/scripts/knowledge_social_operations.py` — authenticated CLI and mapped X executor.
- `EDIT: .agents/scripts/knowledge-social-helper.sh` — operator command dispatch.
- `EDIT: .agents/scripts/_knowledge_social_share_data.py` — explicit exclusion assertions/restore preservation.
- `NEW: .agents/tests/test-knowledge-social-operations.sh` — positive and negative runtime fixtures.
- `EDIT: .agents/content/social-xurl.md`, `.agents/aidevops/knowledge-plane/05-social-operations.md`, `README.md` — user/operator contract.

### Complete Write Surface

- **Callers/readers:** `knowledge-social-helper.sh`, authenticated corpus catalog, private scheduler/routine invocation, `xurl-helper.sh`, operators reading due work/receipts/notifications, and sharing export/import.
- **Writers/mutation paths:** `.agents/scripts/knowledge_social_operations.py` dispatches create/approve/cancel, one atomic due executor, operation reconciliation, notification projection, and per-principal notification transitions through the split outbound state modules.
- **Tests/fixtures:** new fake-`xurl` runtime suite plus existing corpus, X, sync, query, sharing, and browser suites.
- **Schemas/config:** additive per-corpus `social.db` migration; local app/profile selection is private and excluded from transport. No credentials are stored.
- **Generated/deployed mirrors:** `.agents/` remains the setup source; no top-level path or independent deployed mirror is added.
- **Migrations/backfills:** schema migration creates empty operational tables. Existing mention evidence is projected idempotently on explicit refresh; no provider backfill is triggered automatically.
- **Cleanup/rollback paths:** `_knowledge_social_outbound_runtime.py` and `_knowledge_social_outbound_reconciliation.py` use monotonic tokens, terminal attempts, explicit cancellation, and unknown-outcome reconciliation; they never auto-retry.

### Implementation Steps

1. Add operations, approvals, attempts, and notification state to schema v3.
2. Canonicalize each intent and bind approval to operation/action/account/target/payload/profile/schedule digest, authenticated approver, and expiry.
3. Make operation `scheduled_at` the only execution clock; the content calendar remains planning metadata.
4. Resolve owner `knowledge.manage`, verify local X identity immediately before every write, and invoke mapped helper commands only.
5. Claim due operations atomically; record one running attempt before provider execution and one privacy-safe terminal receipt afterward.
6. Treat every post-write non-zero/transport failure as `unknown`; never blind-retry.
7. Project mention activities into deduplicated mention/reply notifications and support unread, seen, action-required, responded, and dismissed transitions.
8. Prove sharing excludes local operational state and read-only collection cannot call writes.

### Hazards and Compatibility

- **Concurrency/atomicity:** one `BEGIN IMMEDIATE` claim increments a fencing token; stale executors cannot finalize. Cancellation only succeeds before claim.
- **Migration/rollback:** schema v3 is additive. Mixed-version writes fail closed; existing v2 data migrates without moving raw evidence.
- **Mixed-version/backward compatibility:** existing archive/API/browser/query commands and corpus defaults remain unchanged.
- **Idempotency/retry:** operation IDs and intent digests deduplicate local writes. Ambiguous external outcomes are terminal until operator reconciliation.
- **Partial failure/recovery:** identity or authorization failure occurs before a provider attempt. Provider invocation failure preserves a durable unknown receipt and the original objective remains open.
- **Privacy:** payloads stay in mode-0600 databases; public output contains opaque IDs/status only. Operational tables and local auth selectors never enter encrypted snapshots.

### Verification Before Dispatch

```bash
bash .agents/tests/test-knowledge-social-operations.sh
bash .agents/tests/test-knowledge-social.sh
bash .agents/tests/test-knowledge-social-x.sh
bash .agents/tests/test-knowledge-social-sync.sh
bash .agents/tests/test-knowledge-social-query.sh
bash .agents/tests/test-knowledge-social-sharing.sh
bash .agents/tests/test-knowledge-social-browser.sh
shellcheck .agents/scripts/knowledge-social-helper.sh .agents/scripts/xurl-helper.sh
python3 -m py_compile .agents/scripts/knowledge_social_store.py .agents/scripts/knowledge_social_operations.py .agents/scripts/_knowledge_social_outbound.py .agents/scripts/_knowledge_social_outbound_runtime.py .agents/scripts/_knowledge_social_outbound_reconciliation.py .agents/scripts/_knowledge_social_outbound_provider.py .agents/scripts/_knowledge_social_notifications.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** focused operations tests cover the state machine/provider route; existing suites cover migration, read-only collection, sharing, query, and browser regressions.
- **Broad verification trigger:** changed-file lint is required because the shell dispatch surface and user-facing docs change; full-repository lint is not required.

### Recoverability Checkpoint

- [x] Focused operation/schema tests pass.
- [x] WIP task-tracking commit exists before implementation.
- [x] Create a second WIP commit after focused runtime verification and before broad regression/lint gates.

### Safety-Stop Recovery

- **Original objective:** shared-account posting, scheduling, notifications, likes, bookmarks, and replies.
- **Preserved user directions:** support every named X capability through a safe owner-managed operational path.
- **Trigger and evidence:** not triggered.
- **Completed and verified:** schema, exact approvals, mapped queue execution, notification workflow, sharing exclusions, docs, all seven social suites, and changed-file lint.
- **Remaining acceptance criteria:** PR review and merge lifecycle.
- **Unsafe route not to repeat:** no raw mutating API calls, caller-only confirmation booleans, competing scheduling clocks, or retries after unknown provider acceptance.
- **Next safe route:** publish the verified branch for review, then merge without releasing.
- **Resume condition:** linked worktree and issue #28627 remain active with a clean WIP checkpoint.
- **Owner and status:** interactive primary session; in progress.

### Files Scope

- `TODO.md`
- `todo/tasks/t18177-brief.md`
- `.agents/scripts/knowledge_social_store.py`
- `.agents/scripts/_knowledge_social_outbound.py`
- `.agents/scripts/_knowledge_social_notifications.py`
- `.agents/scripts/knowledge_social_operations.py`
- `.agents/scripts/knowledge-social-helper.sh`
- `.agents/scripts/_knowledge_social_share_data.py`
- `.agents/tests/test-knowledge-social-operations.sh`
- `.agents/tests/test-knowledge-social-sync.sh`
- `.agents/content/social-xurl.md`
- `.agents/aidevops/knowledge-plane/05-social-operations.md`
- `README.md`

## Acceptance Criteria

- [x] Exact approval binding rejects payload/account/action/target/profile substitution, expiry, and revocation.
- [x] Immediate and scheduled post, reply, like, and bookmark intents execute through one idempotent queue with privacy-safe receipts.
- [x] Concurrent due runners make at most one provider attempt; stale claims, cancellation races, and ambiguous outcomes cannot duplicate a write.
- [x] X identity mismatch or unavailable local profile fails before a provider write.
- [x] Mention/reply projection is idempotent and supports authorized bounded listing and explicit workflow transitions.
- [x] Read-only ingestion/provider manifests remain unable to reach platform writes.
- [x] Sharing snapshots and restores contain no operations, approvals, attempts, local auth selectors, or per-principal notification workflow state.
- [x] Existing social corpus, X, sync, query, sharing, and browser behavior remains green.

## Context & Decisions

- Shared account operations live only on the owner runner's workspace corpus; ordinary shared members do not inherit posting authority.
- Queue `scheduled_at` is canonical. The content calendar may reference an operation later but does not execute it.
- Local owner context is the first approval authority; collaborative signed approvals remain a separate future security review.
- Provider write failures are classified conservatively as unknown because a timeout may occur after acceptance.
- Notifications are mutable workflow overlays on immutable mention/reply evidence.

## Relevant Files

- `.agents/scripts/knowledge_social_store.py:101-246`
- `.agents/scripts/xurl-helper.sh:11-218`
- `.agents/scripts/_knowledge_social_x_persist.py:237-284`
- `.agents/scripts/_knowledge_social_share_data.py:37-142`
- `.agents/scripts/knowledge_corpus_catalog.py:300-358`
- `.agents/aidevops/knowledge-plane/05-social-operations.md:6-74`

## Dependencies

- **Blocked by:** none for implementation and fixture verification.
- **Blocks:** production use requires a local `xurl` installation and authenticated profile.
- **External:** X API availability, permissions, subscription limits, and endpoint semantics; no credential values enter this brief or model context.
