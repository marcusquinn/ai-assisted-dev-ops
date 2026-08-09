<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t18222: Ship owner-reviewed Buzz interactive team runtime

## Pre-flight

- [x] Memory recall: `Buzz OpenCode immutable runtime plugin schema private-local-ai` → 0 hits — no relevant stored lessons
- [x] Discovery pass: existing worktree commits and open/merged PRs inspected — no competing implementation PR found
- [x] File refs verified: runtime, snapshot, roster, plugin, tests, references, design, and mission paths are present in the linked worktree
- [x] Tier: `thinking` — runtime trust, persisted-secret exclusion, and identity-preserving deployment are consequential boundaries
- [x] Seeded draft PR decision recorded: skipped — implementation remains owned by this interactive full-loop session

## Origin

- **Created:** 2026-08-09
- **Session:** OpenCode interactive issue #29831
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** mission `m-20260804-5d06b1`
- **Blocked by:** No external implementation blocker; release remains gated on exact-head verification and identity-preserving live replacement.
- **Conversation context:** The owner authorized completion, merge, patch release, and deployment of the reviewed Buzz team runtime. Live prompt evidence exposed an incomplete pinned plugin dependency closure and persisted credential-bearing OpenCode fields, so the security repair is part of this leaf.

## What

Ship the owner-reviewed **AI DevOps** Buzz snapshot and immutable full-interactive
OpenCode runtime. The snapshot contains fourteen existing members on
`aidevops-interactive-v1` plus `private-local-ai` on
`buzz-agent`/`relay-mesh`/`auto`. All members remain owner-only, parallelism one,
without portable memory. The pinned runtime must answer a real ACP prompt,
exclude persisted credentials, preserve existing Buzz identities during updates,
and survive mutable aidevops deployment changes.

## Why

Mutable runtime paths can drift during aidevops updates, while incomplete plugin
packaging allowed ACP initialization but crashed on the first real prompt. Copying
the normal OpenCode config also retained credential-bearing MCP environment data.
Deleting and recreating Buzz identities is not a safe update path because existing
DMs and threads remain attached to the removed identity.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The implementation crosses runtime isolation, persisted-secret,
provider-routing, and identity-migration boundaries. The required behavior is
decided, but review must reason about security and rollback evidence rather than
apply a low-consequence mechanical edit.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The primary interactive session owns the implementation and verification critical path.
- **Status:** `not-created`
- **Freshness evidence:** Current linked-worktree status, recent commits, issue state, installed dependency manifests, and focused tests were inspected.
- **Verification run:** Focused roster, snapshot, runtime, remote-profile, ACP proxy, and installed OpenCode `session/prompt` canaries pass locally.
- **Stale-assumption warning:** Recheck installed OpenCode/plugin versions, Buzz snapshot schema support, live process state, and exact PR head before replacement or merge.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/team-interface-buzz-runtime.py` and `.agents/scripts/team-interface-buzz-team-snapshot.py` — runtime packaging and snapshot routing boundaries.
- **Load only if:** `.agents/reference/team-interface-buzz-provisioning.md` and `todo/missions/m-20260804-5d06b1/mission.md` — operator lifecycle or mission handoff changes.
- **Why:** Preserve immutable anchors, secret-negative config, owner-only ingress, and create-only snapshot review without conflating shared compute with local execution.
- **Stop when:** Exact package versions, fifteen-member output, prompt canary, rollback path, and verification commands are clear.
- **For UI/UX tasks:** `DESIGN.md` controls stable hue assignment and host-qualified mention naming; no new application layout is in scope.

### Files to Modify

- `NEW: .agents/private-local-ai.md` — canonical privacy-first investigator source.
- `EDIT: .agents/scripts/team-interface-buzz-runtime.py` — sanitize config before hashing/copying and pin the exact OpenCode plugin dependency closure.
- `EDIT: .agents/plugins/opencode-aidevops/tools.mjs` — fail early when required pinned schemas cannot resolve.
- `EDIT: .agents/scripts/team-interface-buzz-team-snapshot.py` — map only Private AI to `buzz-agent`/`relay-mesh`/`auto`.
- `EDIT: .agents/scripts/tests/test-team-interface-agent-roster.mjs` — assert fourteen primaries plus the framework guide.
- `EDIT: .agents/scripts/tests/test-team-interface-buzz-team-snapshot.mjs` — assert fifteen unique members and the one-member routing exception.
- `EDIT: .agents/scripts/tests/test-team-interface-buzz-runtime.mjs` — assert secret-negative pinned config and complete dependencies.
- `EDIT: .agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs` — send and validate a real ACP `session/prompt`.
- `EDIT: .agents/reference/team-interface-buzz-provisioning.md`, `DESIGN.md`, `todo/missions/m-20260804-5d06b1/mission.md`, and `TODO.md` — operator, design, mission, and task handoff.

### Complete Write Surface

- **Callers/readers:** Buzz manifest installation invokes `team-interface-buzz-runtime.py`; the snapshot helper and runtime preparation both consume the canonical roster; OpenCode loads the pinned plugin entry.
- **Writers/mutation paths:** `.agents/scripts/team-interface-buzz-runtime.py` atomically creates content-addressed anchors and a Buzz custom-harness manifest; `.agents/scripts/team-interface-buzz-team-snapshot.py` creates only a private draft for owner review.
- **Tests/fixtures:** `.agents/scripts/tests/test-team-interface-agent-roster.mjs`, `test-team-interface-buzz-team-snapshot.mjs`, `test-team-interface-buzz-runtime.mjs`, and `test-team-interface-buzz-installed-startup.mjs` cover the changed contracts alongside ACP proxy, worktree, launcher, overlay, and remote-profile suites.
- **Schemas/config:** `.agents/configs/buzz-runtime-aidevops-interactive-v1.json` remains machine-neutral and uses existing Buzz snapshot v1 fields; no schema migration is required.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/`; live runtime replacement must materialize a fresh anchor rather than mutate an old one.
- **Migrations/backfills:** `todo/missions/m-20260804-5d06b1/mission.md` records why no unattended Buzz identity migration exists. Existing agents must be preserved; the fifteenth member is added through owner-reviewed import.
- **Cleanup/rollback paths:** `.agents/scripts/team-interface-buzz-runtime.py` writes a private manifest rollback copy. Old immutable anchors remain usable until the replacement passes the prompt canary and live verification.

### Implementation Steps

1. Resolve the installed `@opencode-ai/plugin` manifest and exact `@opencode-ai/sdk`/`zod` versions, copy that closure into the content-addressed runtime, and reject mismatches.
2. Structurally remove credential-bearing provider fields plus MCP environment/header containers before config hashing and copying; validate the pinned output remains secret-negative.
3. Extend installed startup coverage from ACP initialization and session creation through a real `session/prompt`, rejecting ToolRegistry/Zod schema failures.
4. Add `private-local-ai` and special-case only its Buzz runtime/provider/model fields; retain fourteen existing members without provider/model fields.
5. Update operator/design/mission evidence, run focused and broad gates, then merge and replace the live runtime only from the released exact source.

### Hazards and Compatibility

- **Concurrency/atomicity:** Anchors are staged privately and published with atomic rename; existing roots are validated rather than modified.
- **Migration/rollback:** Never delete/recreate existing Buzz agents during routine update. Back up manifest replacement and retain the prior anchor until live prompt success.
- **Mixed-version/backward compatibility:** Validate installed plugin dependency versions before packaging. OpenCode absence skips only the installed canary; supported CI/runtime environments must execute it.
- **Idempotency/retry:** Content digests make materialization idempotent. Snapshot import remains create-only and owner-confirmed to prevent duplicate identity reconciliation.
- **Partial failure/recovery:** A missing package, version mismatch, residual private field, invalid prompt schema, or running Buzz process fails closed before manifest publication.

### Verification Before Dispatch

- **Surface mapping:** `test-team-interface-buzz-installed-startup.mjs` proves package/config/prompt viability; roster and snapshot suites prove fifteen-member routing; ACP proxy/worktree/remote-profile suites prove isolation; ShellCheck and changed-file lint cover launcher and complete changed-source regressions.

```bash
python3 -m py_compile \
  .agents/scripts/team-interface-buzz-runtime.py \
  .agents/scripts/team-interface-buzz-team-snapshot.py \
  .agents/scripts/team-interface-agent-roster.py
node .agents/scripts/tests/test-team-interface-agent-roster.mjs
node .agents/scripts/tests/test-team-interface-buzz-team-snapshot.mjs
node .agents/scripts/tests/test-team-interface-buzz-runtime.mjs
node .agents/scripts/tests/test-team-interface-acp-cwd-proxy.mjs
node .agents/scripts/tests/test-team-interface-buzz-worktree.mjs
node .agents/scripts/tests/test-team-interface-buzz-installed-startup.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-remote-interactive-profile.mjs
shellcheck .agents/bin/aidevops-buzz-acp \
  .agents/bin/aidevops-buzz-acp-interactive \
  .agents/scripts/buzz-team-provision-helper.sh \
  .agents/scripts/team-interface-buzz-worktree.sh
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] A generated snapshot has fifteen unique members: exactly one
  `buzz-agent`/`relay-mesh`/`auto` Private AI member and fourteen unchanged
  `aidevops-interactive-v1` members without provider/model fields.
- [ ] Every member is owner-only, parallelism one, has no portable memory, and
  uses a deterministic distinct reviewed avatar.
- [ ] A newly materialized runtime contains real OpenCode plugin/Zod schemas and
  completes ACP `initialize`, `session/new`, and `session/prompt` without
  ToolRegistry/schema errors.
- [ ] Pinned config and manifests contain no persisted credential fields or
  fixture secret values; missing/mismatched dependencies fail before publish.
- [ ] Existing Buzz identities, DMs, and threads are preserved during routine
  deployment; delete/recreate is not used as reconciliation.
- [ ] Focused tests, ShellCheck, changed-file lint, required CI, exact-head
  review, merge, explicitly authorized patch release, and deployment complete.

## Recovery

If any runtime or live gate fails, keep the prior manifest/anchor active, retain
the issue open, record the exact failed command and source SHA, and repair through
a fresh content-addressed anchor. Resume replacement only when the real-prompt
canary passes and Buzz is safely stopped for the atomic manifest update.
