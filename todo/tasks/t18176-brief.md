---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18176: Plan secure personal and shared social knowledge corpora

## Pre-flight

- [x] Memory recall: `social account knowledge base personal shared corpora X API ingestion routines workspace RBAC Vault` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: recent target-file history and existing t2844/t2850/t18047-t18052 work reviewed; 0 related merged/open PRs implement this corpus architecture.
- [x] File refs verified: 15 knowledge, X, Reach, routine, RBAC, retrieval, and Vault references checked at current HEAD.
- [x] Tier: `tier:thinking` — seven leaves introduce a new cross-cutting storage, authorization, sync, and retrieval contract.
- [x] Seeded draft PR decision recorded: skipped — the planning PR records decisions only; implementation belongs to bounded child issues.

## Origin

- **Created:** 2026-07-25
- **Session:** OpenCode interactive social-knowledge architecture session
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** The user requested a local knowledge base for personal and shared X accounts, initial backfill plus periodic collection, future multi-platform support, and evidence-backed questions about gathered knowledge, ideas, products, and opinions.

## What

Track seven sequential implementation leaves that add provider-neutral personal
and shared social knowledge corpora. The completed capability must collect each
shared account once, preserve raw and normalized provenance, isolate personal
and workspace retrieval physically, federate only authorized corpora, and use
official APIs/account archives before bounded browser fallback.

The accepted architecture is recorded in
`todo/plans/social-knowledge-corpora.md`. This issue is a permanent parent
tracker; it is never implemented or dispatched directly.

## Why

The existing framework has X API operations, browser capture, personal
knowledge, routines, workspace/RBAC guidance, and Vault sync primitives, but no
contract joins them into a secure account mirror. Ad hoc ingestion would risk
duplicate API costs, cursor races, unsupported completeness claims, private/team
data leaks, and false opinion inference from likes or bookmarks.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The parent coordinates seven security- and architecture-heavy
leaves spanning storage, API pagination, authorization, encrypted sharing,
retrieval, routines, and browser fallback. Each child is independently scoped
and re-tiered before dispatch.

## PR Conventions

This is a `parent-task`. Planning and intermediate child PRs use a non-closing
reference to the parent. Only the final child may close the parent after every
declared phase is filed, merged, and verified.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Planning files contain the complete architecture; seeding implementation would anchor workers before phase-specific file discovery and schema tests.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, prework discovery, related-task review, and file-reference reads completed against current HEAD on 2026-07-25.
- **Verification run:** Planning validation and changed-file lint are required in this PR; implementation tests are intentionally deferred to children.
- **Stale-assumption warning:** Re-run discovery if knowledge-plane, Vault, xurl, routine, or workspace contracts change before a child is filed.

## Phases

- Phase 1 - Add the corpus catalog, personal/workspace corpus contract, authenticated authorization resolver, and backward-compatible alias for existing personal knowledge.
- Phase 2 - Add the provider-neutral social schema, immutable raw-batch store, archive importer, FTS5 projection, coverage records, and idempotent migration/rebuild path. [auto-fire:on-prior-merge]
- Phase 3 - Add a read-only X adapter using guarded xurl account verification, independent stream backfill/delta cursors, media policy, cost budgets, and terminal rate-limit handling. [auto-fire:on-prior-merge]
- Phase 4 - Add authorized federated query, per-corpus RRF/dedup, evidence citations, private annotation overlays, and authored-versus-inferred opinion semantics. [auto-fire:on-prior-merge]
- Phase 5 - Add deterministic sync/reconciliation routines, one-collector shared leases with fencing, run receipts, and crash-safe cursor recovery. [auto-fire:on-prior-merge]
- Phase 6 - Add workspace grants, encrypted shared-batch distribution, local index rebuild, membership/key revocation, and cross-principal negative tests. [auto-fire:on-prior-merge]
- Phase 7 - Add bounded browser-gap capture, the provider extension contract, operator documentation, and end-to-end privacy/cost/coverage verification. [auto-fire:on-prior-merge]

## How (Approach)

### Progressive Context Plan

- **Read first:** `todo/plans/social-knowledge-corpora.md` — accepted architecture, schemas, boundaries, and phase verification matrix.
- **Then load:** only the existing contracts named by the current phase in the plan's “Relevant existing contracts” section.
- **Load only if:** a phase touches protected storage or remote model routing — `.agents/reference/vault.md` and `.agents/aidevops/knowledge-plane/03-platform-and-policy.md`.
- **Why:** preserve the parent decisions while keeping each worker below a bounded reading budget.
- **Stop when:** the child has verified target files, one complete write surface, focused tests, narrow file scope, and no unresolved cross-phase schema decision.

### Worker Quick-Start

```text
1. Do not implement this parent issue directly; file or execute only the current child.
2. Keep social as knowledge ingress/retrieval, not a new `_social` plane.
3. Use one physical store/index per corpus and derive access from authenticated membership.
4. Raw evidence is authoritative; normalized rows, FTS, embeddings, and Markdown are projections.
5. Official API/archive first; browser capture only for an explicit, tested gap.
6. Likes/bookmarks/reposts/follows are not proof of opinion.
7. No social-platform writes, credentials in AI context, or private data in public Git/GitHub.
```

### Files to Modify

- `NEW: todo/plans/social-knowledge-corpora.md` — parent architecture and phased delivery contract.
- `NEW: todo/tasks/t18176-brief.md` — canonical parent brief and sequential phase declarations.
- `EDIT: TODO.md` — parent task entry and issue reference.
- `CHILD-DEFINED: .agents/aidevops/knowledge-plane/**` — corpus contract and policy documentation where required by a leaf.
- `CHILD-DEFINED: .agents/scripts/**` — corpus, social adapter, query, routine, Vault integration, and focused tests selected by each leaf after discovery.

### Complete Write Surface

- **Callers/readers:** `TODO.md`, the canonical issue body, `.agents/scripts/shared-phase-filing.sh`, `.agents/scripts/issue-sync-helper.sh`, parent-task worker diagnostics, maintainers, and child issue authors read this plan. Runtime callers are not modified by this planning task.
- **Writers/mutation paths:** This planning PR writes only `todo/plans/social-knowledge-corpora.md`, `todo/tasks/t18176-brief.md`, `TODO.md`, and the canonical issue body. Each child must enumerate its runtime writers before dispatch.
- **Tests/fixtures:** `.agents/scripts/verify-brief.sh`, `.agents/scripts/verify-brief-helper.sh`, and `.agents/scripts/linters-local.sh` validate this planning change. Runtime fixtures are not applicable because the parent changes no runtime code.
- **Schemas/config:** `todo/plans/social-knowledge-corpora.md` defines intended catalog/social schema contracts. Runtime schema/config changes are deferred because each child must select and test its own concrete files.
- **Generated/deployed mirrors:** Not applicable because this planning-only parent does not change `setup.sh` or a deployed mirror. Any child adding one must list the source and mirror and run the repository mirror validator.
- **Migrations/backfills:** Not applicable because this planning-only parent runs no migration. `todo/plans/social-knowledge-corpora.md` assigns legacy discovery, archive import, and API backfill/checkpoint semantics to Phases 1-3.
- **Cleanup/rollback paths:** Not applicable because this parent adds only `TODO.md` and planning documents. Child phases must preserve resumability, avoid destructive rollback, and document cleanup of temporary/staging artifacts.

### Implementation Steps

1. Land this parent plan and brief without changing runtime behavior.
2. Let parent reconciliation file Phase 1 as a native child issue after the
   planning state is canonical.
3. Before each child is dispatchable, re-run memory recall, duplicate discovery,
   file-reference verification, task-tier validation, and brief readiness.
4. Preserve sequential GitHub dependencies so only one schema-changing leaf is
   active at a time.
5. Close the parent only after Phase 7 verifies every earlier leaf's merged
   evidence and the end-to-end negative isolation guarantees.

### Hazards and Compatibility

- **Concurrency/atomicity:** The planning task has no runtime writer. Children must transactionally couple normalized writes and cursor advancement and use fenced shared-collector leases.
- **Migration/rollback:** Existing personal/repo knowledge remains unchanged until migration fixtures pass; automatic destructive moves are prohibited.
- **Mixed-version/backward compatibility:** Corpus-aware commands are additive; current single-corpus commands remain valid by default.
- **Idempotency/retry:** Parent/phase filing is idempotent. Archive/API imports, encrypted sync, and cursor replay require child-level idempotency tests.
- **Partial failure/recovery:** A failed child leaves the parent open and later phases blocked. Rate, cost, security, or process fuses preserve checkpoints rather than satisfying criteria.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief.sh todo/tasks/t18176-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18176-brief.md
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Brief validators cover the parent schema/phases/acceptance contract; changed-file lint covers the two new Markdown files and TODO edit.
- **Broad verification trigger:** Not required — this planning PR changes no runtime, shared config, dependencies, or deployment surface.

### Recoverability Checkpoint

- [x] Focused validation passes: `.agents/scripts/verify-brief.sh todo/tasks/t18176-brief.md`
- [x] WIP commit created before PR gates: `wip: plan social knowledge corpora`
- [x] Evidence-triggered broad verification then run: not required — planning-only three-file change.

### Safety-Stop Recovery

- **Original objective:** Create a secure personal/shared social knowledge capability with API-first ingestion and federated retrieval.
- **Preserved user directions:** Initial backfill, periodic routines, shared collection once, personal plus shared queries, future provider support, and evidence-backed opinion semantics.
- **Trigger and evidence:** not triggered.
- **Completed and verified:** Architecture research and decisions are recorded in the plan.
- **Remaining acceptance criteria:** Every declared implementation phase and final end-to-end verification.
- **Unsafe route not to repeat:** No unbounded API/browser retry, plaintext team sync, central collection of personal corpora, or weak-signal opinion inference.
- **Next safe route:** Execute one verified sequential child at a time.
- **Resume condition:** Current child has a worker-ready brief and all predecessor PRs are merged.
- **Owner and status:** Parent coordinator; not-triggered.

### Files Scope

- `TODO.md`
- `todo/plans/social-knowledge-corpora.md`
- `todo/tasks/t18176-brief.md`

## Acceptance Criteria

- [ ] The canonical plan defines placement, physical layout, catalog/social schemas, API/archive/browser boundaries, authorization, routines, Vault sharing, query semantics, migrations, and negative tests.

  ```yaml
  verify:
    method: codebase
    pattern: "^## (4\\. Placement|5\\. Tenancy|6\\. Per-corpus|7\\. Authorization|8\\. Ingestion|9\\. Query|10\\. Vault|11\\. Browser|12\\. Sequential|13\\. Verification|14\\. Migration)"
    path: "todo/plans/social-knowledge-corpora.md"
  ```

- [ ] Seven ordered, independently mergeable phases are declared and later phases use prior-merge auto-fire markers.

  ```yaml
  verify:
    method: bash
    run: "test $(rg -c '^- Phase [1-7] - ' todo/tasks/t18176-brief.md) -eq 7 && test $(rg -c '\\[auto-fire:on-prior-merge\\]' todo/tasks/t18176-brief.md) -eq 6"
  ```

- [ ] The architecture explicitly prevents cross-corpus access, personal-to-team annotation/cache leakage, platform writes, credential exposure, and opinion inference from weak signals.

  ```yaml
  verify:
    method: codebase
    pattern: "Default deny|never persist the blended result|Non-goals|Likes/bookmarks/reposts/follows are not proof"
    path: "todo"
  ```

- [ ] Existing repo/personal knowledge behavior is preserved until child migration and compatibility tests pass.
- [ ] The parent remains `parent-task`/non-dispatchable and is not closed by this planning PR.
- [ ] Brief validation and changed-file lint pass.

## Context & Decisions

- One physical SQLite/index boundary per personal or workspace corpus is safer than relying on a global database predicate.
- A shared account has one collector; authorized users receive encrypted shared batches and rebuild indexes locally.
- Combined personal/team queries run on a trusted user device, not by uploading personal corpora to the shared runner.
- Raw evidence is authoritative; generated Markdown and search indexes are projections.
- Social remains a source adapter for knowledge and optional feedback/performance promotion, not a new data plane.
- DMs and protected content are disabled by default and require stricter separate authorization.
- Official APIs and archives precede bounded browser fallback.

## Relevant Files

- `todo/plans/social-knowledge-corpora.md` — accepted architecture and phase contract.
- `.agents/aidevops/knowledge-plane/01-core-contract.md:14-40` — current modes and directory layout.
- `.agents/aidevops/knowledge-plane/03-platform-and-policy.md:59-177` — sensitivity and model-routing policy.
- `.agents/aidevops/knowledge-plane/04-enrichment-index-review.md:87-154` — current corpus projection/index pattern.
- `.agents/content/social-xurl.md:22-109` — guarded API, account profiles, and write boundary.
- `.agents/tools/app-stack/workspace-model.md:45-67` — workspace ownership and isolation rules.
- `.agents/tools/app-stack/rbac-permissions.md:30-67` — capability and default-deny contract.
- `.agents/tools/database/vector-search/per-tenant-rag.md:48-68` — physical retrieval isolation and negative tests.
- `.agents/reference/routines.md:64-82` — deterministic routine ownership.
- `.agents/reference/vault.md:61-139` — protected data classes and provider routing.
- `.agents/workflows/vault-fleet.md:78-145` — encrypted collections, local reindex, and transport constraints.

## Dependencies

- **Blocked by:** none.
- **Blocks:** all seven declared child phases.
- **External:** X developer-app/account authorization is required only for live Phase 3 testing; credentials never enter issue bodies, briefs, arguments, logs, or model context.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Parent planning publication | 1h | Plan, brief, issue mapping, validation |
| Phase 1 | 3h | Corpus/catalog/auth foundation |
| Phase 2 | 4h | Store, archive import, FTS, migration |
| Phase 3 | 4h | X API adapter, cursors, budgets |
| Phase 4 | 3h | Federated retrieval and evidence semantics |
| Phase 5 | 2.5h | Routines, leases, reconciliation |
| Phase 6 | 3.5h | Encrypted team grants/sync/revocation |
| Phase 7 | 2h | Browser gaps, provider docs, final verification |
| **Total** | **23h** | Sequential, independently mergeable leaves |
