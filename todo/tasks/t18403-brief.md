<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18403: Establish compounding-value purpose in README and architectural guidance

## Pre-flight

- [x] Memory recall: no matching search result; maintainer direction retained in the parent plan.
- [x] Discovery pass: README already has The Aim; PR #31228 already preserves guidance. This task adds the clarified purpose, not a duplicate overview or slimming pass.
- [x] File refs verified: README opening, architecture, self-improvement and agent-review sources checked at `5393632ee`.
- [x] Tier: standard; purpose and boundaries are decided, editorial integration remains.
- [x] Seeded draft PR decision recorded: skipped; use current source at execution, not a speculative prose patch.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** no implementation dependency; publication must land before dispatch.

## What

Make the maintainer's clarified operating purpose prominent near the start of
README and reliably inherited by architectural and self-improvement work. Create
one canonical purpose reference, with short owning summaries/pointers rather than
several independently maintained essays.

## Why

The review misclassified cross-domain DevOps discipline as removable coding
overhead. Aidevops codifies information flows into compounding value without
compounding human supervision. Time/money are ultimate metrics; 100x capability
is an ambition, not an established result. Repo-native plans/progress outlive a
forge. Build+ is the default, with domain primaries and lighter bounded children.

## Tier

**Selected tier:** `tier:standard` — resolved purpose; preserve meaning while fitting existing entry points.

## How (Approach)

### Files to Modify

- `NEW: .agents/aidevops/purpose.md` — canonical purpose and architectural decision criteria; model on the concise ownership/reference structure of `.agents/aidevops/architecture.md`.
- `EDIT: README.md` — refine the existing opening/The Aim before feature inventories, not a second competing introduction.
- `EDIT: AGENTS.md` and `EDIT: .agents/AGENTS.md` — short purpose/architecture pointers only.
- `EDIT: .agents/aidevops/architecture.md`, `EDIT: .agents/reference/self-improvement.md`, `EDIT: .agents/tools/build-agent/agent-review.md`, `EDIT: .agents/tools/build-agent/build-agent.md` — inherit the canonical purpose at their decision points.

### Complete Write Surface

- **Callers/readers:** `README.md`, `AGENTS.md`, `.agents/AGENTS.md` and the listed authoring/self-improvement entry points.
- **Writers/mutation paths:** `.agents/aidevops/purpose.md` and owning Markdown summaries; `setup.sh` deploys the source without a runtime behavior change in this leaf.
- **Tests/fixtures:** `.agents/scripts/tests/test-context-engineering-guidance.sh` and `.agents/scripts/progressive-load-check.sh` are existing semantic/pointer checks.
- **Schemas/config:** preserve `.agents/AGENTS.md` size ratchet and existing frontmatter; `.agents/prompts/build.txt` remains the empty compatibility surface.
- **Generated/deployed mirrors:** `.agents/` ships to deployed agents; generated runtime wrappers should inherit pointers, not copied philosophy.
- **Migrations/backfills:** N/A because this leaf changes documentation and references, not data/state schemas.
- **Cleanup/rollback paths:** revert the bounded `README.md`/`.agents/` documentation change without deleting pre-existing rules, history or task references.

### Implementation Steps

1. Preserve all eight maintainer directions in the parent plan in the canonical purpose reference.
2. Explain common DevOps across domains, durable repo knowledge, interchangeable forge conversations, focus profiles, structural drift prevention and economic value in the existing README opening.
3. Add short source pointers in architecture/self-improvement/authoring entry points; keep actionable universal safety and authority invariants visible.
4. Replace self-improvement wording that makes forge-only threads canonical with a reference to the repo/forge ownership contract, clearly separating intended contract from implementation gaps tracked by t18404.
5. Do not add branding assets, unsupported performance promises, arbitrary instruction quotas or a checklist on every trivial interaction.

### Hazards and Compatibility

- **Concurrency/atomicity:** README is actively maintained; rebase and preserve unrelated quality/version updates.
- **Migration/rollback:** introduce the reference before changing pointers; retain all current protected guidance.
- **Mixed-version/backward compatibility:** old runtimes still get a sufficient invariant and valid path; no new runtime hook is assumed.
- **Idempotency/retry:** one canonical purpose section/reference; retries must not append duplicate statements.
- **Partial failure/recovery:** commit a coherent pointer-plus-target change; never leave a missing target or claim portability already proven.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-context-engineering-guidance.sh
.agents/scripts/progressive-load-check.sh --quiet
.agents/scripts/linters-local.sh --changed
git diff --check
```

- **Surface mapping:** existing context tests and pointer checks protect authoring delivery; changed-file lint covers Markdown/size/security. Implementation checks are not yet run for this future task.

### Progressive Context Plan

- **Read first:** parent plan Maintainer direction, then README The Aim and the owning architecture/self-improvement sections.
- **Load only if:** the agent-review provenance rubric when moving a directive or an existing test exposes a protected boundary.
- **Stop when:** purpose ownership, short pointers and preservation checks are clear; do not read the entire specialist corpus.

## Acceptance Criteria

- [ ] README presents compounding value across information flows before feature detail; 100x is explicitly an ambition, not a guaranteed or measured result.
- [ ] Architecture and self-improvement entry points inherit one canonical purpose without losing hard-won rules or expanding always-loaded content unnecessarily.
- [ ] Repo task/plan/progress authority, portable forge conversations and flexible domain delegation are explicit; no non-coding domain is demoted outside DevOps.
- [ ] Existing context/pointer checks pass and no unsupported claims of current forge-loss recovery are introduced.

## Seeded Draft PR

Skipped — no implementation seed; verified targets and decided semantics are sufficient.

Parent: #31280
