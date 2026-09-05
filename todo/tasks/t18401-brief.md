---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18401: Restore profile activity reporting

## Pre-flight

- [x] Memory recall: `GitHub profile README screen-time publication commit-history model usage metrics GPT-5.5` → 0 hits — no relevant lessons.
- [x] Discovery pass: 2 recent commits / 0 merged related PRs / 0 open related PRs touched the target area.
- [x] File refs verified: 6 target refs checked and present at HEAD.
- [x] Tier: `standard` — the SQL aggregation and publication boundary are resolved but span multiple shell components.
- [x] Seeded draft PR decision recorded: skipped — implementation and focused verification were already complete before task allocation.

## Origin

- **Created:** 2026-09-05
- **Session:** OpenCode interactive session
- **Created by:** AI DevOps (ai-interactive)
- **Conversation context:** Restore a stale public profile update path, replace speculative cost/savings presentation with measurable activity, and remove GPT-5.5 from active auto-reason examples.

## What

Publish profile README updates even when the read-only canonical checkout contains harmless untracked files, link the commit-history chart to the user's activity profile, and render per-model cache hit rate, distinct session count, and generation hours instead of API cost and savings estimates.

## Why

The screen-time collector was healthy, but publication stopped because `.DS_Store` made the canonical checkout fail a strict cleanliness check. The profile also exposed cost assumptions that do not represent subscription usage and omitted the measurable session activity available in local observability data.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The behavior and target paths are known, but the work coordinates SQL fallback sources, Markdown rendering, isolated Git publication, and backward-compatible chart migration.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/profile-readme-data-lib.sh` — aggregate distinct sessions and request duration from observability, OpenCode, and JSONL fallback data.
- `EDIT: .agents/scripts/profile-readme-render-lib.sh` — replace cost/savings columns and prose with cache and session activity.
- `EDIT: .agents/scripts/profile-readme-helper.sh` — link and migrate commit-history charts; ignore untracked canonical files while retaining tracked-change and unpushed-commit guards.
- `EDIT: .agents/scripts/tests/test-profile-readme-boundary.sh` — cover aggregation, rendering, chart migration, and cleanliness boundaries.
- `EDIT: .agents/scripts/commands/auto-reason.md` — use workload tiers in defaults and examples.
- `EDIT: .agents/tools/auto-reason.md` — remove GPT-5.5 from concrete comparison examples.

### Complete Write Surface

- **Callers/readers:** `profile-readme-helper.sh generate` calls `_get_profile_model_usage_bundle` and `_render_model_usage_table`; `update` calls `_ensure_commit_history_chart` inside an isolated publication worktree.
- **Writers/mutation paths:** profile updates write only `README.md` in the temporary publication worktree and push its default branch; the configured canonical checkout remains unchanged.
- **Existing verification/tests:** `.agents/scripts/tests/test-profile-readme-boundary.sh`, ShellCheck, and `.agents/scripts/linters-local.sh` cover the affected shell surfaces.
- **Schemas/config:** `llm_requests.session_id`, `duration_ms`, token columns, and OpenCode `message.session_id` plus assistant JSON timestamps supply the metrics; no schema migration is required.
- **Generated/deployed mirrors:** `~/.aidevops/agents/` and OpenCode command files are refreshed through `setup.sh` after merge; the public profile README refreshes through `profile-readme-helper.sh update`.
- **Migrations/backfills:** existing unlinked commit-history picture blocks are wrapped during the next update; historical model rows remain reportable.
- **Cleanup/rollback paths:** publication worktrees retain guarded cleanup; reverting the source commit restores the prior table and cleanliness policy without data migration.

### Implementation Steps

1. Add session fields to every model-data source and preserve exact all-period distinct-session totals.
2. Render only rows with requests, calculate cache hit rate from token totals, and show unavailable duration as an em dash rather than a false zero.
3. Wrap new and legacy commit-history pictures in the documented user-profile link.
4. Change canonical preflight to ignore untracked files while preserving tracked-change, unpushed-commit, and before/after mutation checks.
5. Replace GPT-5.5 auto-reason defaults/examples with workload tiers or the current intentional comparison model.

### Hazards and Compatibility

- **Concurrency/atomicity:** the existing isolated publication worktree and before/after canonical state comparison remain unchanged.
- **Migration/rollback:** legacy chart migration is idempotent and adds at most one profile anchor; rollback needs no data change.
- **Mixed-version/backward compatibility:** JSONL rows without duration render `—`; older data without global session totals falls back to the sum of available per-model counts.
- **Idempotency/retry:** repeated profile updates detect the existing exact link and do not nest anchors or duplicate charts.
- **Partial failure/recovery:** a failed chart migration removes its temporary file and aborts before replacing or committing the generated README.

### Verification Before Dispatch

```bash
.agents/scripts/tests/test-profile-readme-boundary.sh
.agents/scripts/profile-readme-helper.sh generate
shellcheck .agents/scripts/profile-readme-data-lib.sh .agents/scripts/profile-readme-render-lib.sh .agents/scripts/profile-readme-helper.sh .agents/scripts/tests/test-profile-readme-boundary.sh
.agents/scripts/linters-local.sh
```

- **Surface mapping:** the boundary test covers SQL aggregation, Markdown output, migration idempotency, and canonical Git safety; `generate` exercises current local data; ShellCheck and local linters cover shell and repository policy.
- **Broad verification trigger:** not required; no shared dependency, root config, or release infrastructure changed.

### Recoverability Checkpoint

- [x] Focused functional verification passes: `.agents/scripts/tests/test-profile-readme-boundary.sh` — 26/26 passed.
- [x] WIP commit created before broad gates: `c603e83f5 fix: restore profile activity reporting`.

## Acceptance Criteria

- [x] A canonical profile checkout containing only untracked files can publish through an isolated worktree, while tracked changes and unpushed commits remain blocked.
- [x] New and legacy commit-history charts link exactly once to `https://commit-history.com/<user>` and retain light/dark embeds.
- [x] Model tables show `Cache Hit-Rate %`, `Session Count`, and `Session Hours` and contain no API-cost or savings columns/prose.
- [x] Current observability data produces exact distinct-session totals and summed generation duration; unavailable fallback duration is not represented as measured zero.
- [x] Active auto-reason guidance no longer selects GPT-5.5 by default or example.
