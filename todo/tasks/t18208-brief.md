<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18208: Generate restricted OpenCode conversation launch overlays

## Pre-flight

- [x] Memory recall: `mission OpenCode overlay canonical roster workload tier read-only conversation permission` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: roster PR #29605 provides the stable input; existing launcher/plugin isolation paths are merged; no open issue or PR implements the team-interface conversation overlay.
- [x] File refs verified: 25 roster, schema, launcher, plugin config/tool/permission, effort routing, research-only, test, mission, and source-review references checked at `52773f5a9`.
- [x] Tier: `tier:thinking` — this is an execution security boundary spanning ephemeral config, plugin mutation order, root-session model variants, cwd, and subagent/network escape prevention.
- [x] Seeded draft PR decision recorded: skipped — a generator without final plugin enforcement would create a misleading partial security boundary.

## Origin

- **Created:** 2026-08-06
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18201 / #29541
- **Blocked by:** none — F2.2 / t18203 merged through PR #29605
- **Conversation context:** The canonical roster now exposes stable agent IDs, source digests, and workload tiers without models or permissions. Current OpenCode persistent profiles remain write-capable, and plugin config hooks can widen tools/MCPs/paths after initial config resolution, so restricted conversational launch must be schema-backed and enforced last.

## What

Generate a deterministic, closed, ephemeral OpenCode conversation overlay from a
verified canonical roster, selected stable agent ID, workload tier, and bounded
team-interface context. Add a fixed-argv ACP/conversation launcher and a final
plugin isolation pass that makes the selected root profile locally read-only,
denies subagents/network/MCP/custom/mutating tools, disables sharing and mutable
runtime services, resolves only the workload variant at runtime, and never edits
persistent `opencode.json`.

The descriptor carries identity and evidence references only. It excludes raw
messages, instructions, credentials, private paths, model/provider IDs, shell
fragments, arbitrary environment values, and authority grants. The overlay is
not an approval boundary; actor/trust/authority evidence remains input to later
broker policy.

## Why

Canonical aidevops profiles intentionally support development and therefore
include Bash, write, task, MCP, and managed-directory access. Selecting one by
name for Buzz/Matrix conversation would expose write-capable execution, permit
subagent escape, and let plugin config mutation widen an apparently read-only
overlay. F2.5 supplies the reusable restricted launch boundary required before
owner-reviewed onboarding and delegated conversational execution can proceed.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The design is decided below, but correctness depends on
effective merged OpenCode configuration, plugin ordering, tool-deny precedence,
root-session variant routing, and real runtime behavior across security seams.

## PR Conventions

This is a leaf child. Its PR uses a closing keyword for the F2.5 issue and
`For #29541` for the parent. It must not close the parent, grant conversational
writes, implement provider approval, alter persistent user config, or release.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Schema, generator, launcher, final plugin guard, and effective-config/runtime tests must be reviewed as one security boundary.
- **Status:** merged through PR #29673 as `670d77b074928d70ef07e62055c8f434c7258db1`; post-merge verification repairs merged through PRs #29689 and #29687
- **Freshness evidence:** Roster generator/schema, OpenCode launcher/config generator, plugin config mutation order, research-only policy, installed OpenCode 1.18.9 behavior, and collision searches were refreshed on 2026-08-06.
- **Verification run:** Focused, broad, installed-runtime, changed-file lint, Qlty 49/49, exact-head review, remote CI, and merged-main integration gates pass.
- **Stale-assumption warning:** Recheck installed OpenCode config/ACP behavior and plugin hook contracts before any downstream authority or provider integration extends this boundary.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/team-interface-agent-roster.py`, `.agents/schemas/team-interface/agent-roster-v1.schema.json`, and `.agents/plugins/opencode-aidevops/config-hook.mjs:291-350`.
- **Then load:** `.agents/scripts/opencode-launcher-helper.sh:588-986`, `.agents/plugins/opencode-aidevops/config-safety-guards.mjs`, and `.agents/tools/ai-assistants/research-only.md`.
- **Load only if:** variant routing is unclear — `.agents/plugins/opencode-aidevops/subagent-effort.mjs` and `.agents/configs/model-routing-table.json`.
- **Why:** build from canonical roster evidence, bypass every normal plugin widening seam in conversation mode, and attest the effective config without changing persistent agent generation.
- **Stop when:** descriptor validation, digest/agent selection, effective tool/permission merge, plugin ordering, cwd/argv, variant routing, secret/path rejection, and negative escape cases all map to tests.

### Worker Quick-Start

1. Define one closed overlay schema with roster/agent/source digests, workload tier, fixed `conversation_read_only_v1`, bounded interface references, and context digest.
2. Reject unknown/duplicate agents, digest mismatch, malformed refs, secret/path/model/provider/shell/env keys, raw message/instruction content, and non-canonical output.
3. Generate ephemeral canonical JSON only; never write or merge persistent OpenCode configuration.
4. The selected primary profile may use only credential-filtered local `read`, `grep`, and `glob`. Deny Bash, task/subagent, write/edit/apply_patch, skill, web/network, question, todos, every MCP/custom tool, and every unknown future tool.
5. Disable sharing, snapshots, LSP, formatter, MCPs, and subagent depth. Bypass normal agent/MCP/tool/grant/provider registration and expose only the required conversation hooks.
6. Carry workload tier, not model ID. Resolve provider-specific root-session variant from current routing policy at chat-parameter time.
7. Launch through a dedicated fixed-argv ACP/conversation path with verified `--cwd`; reject `--auto`, passthrough args, unsafe cwd, unknown overlay, and environment widening.
8. Inject bounded context through a validated plugin transform/system block, not prompt concatenation or a temporary instruction file.
9. Prove effective merged config and actual OpenCode 1.18.9 debug/ACP startup where locally available; fail closed rather than self-assess a critical/high runtime boundary.

### Files to Modify

- NEW: `.agents/schemas/team-interface/opencode-launch-overlay-v1.schema.json` — closed descriptor/input contract.
- NEW: `.agents/scripts/team-interface-opencode-overlay.mjs` — roster validation, stable selection, context validation/digest, canonical overlay/config generation.
- NEW: `.agents/reference/team-interface-opencode-overlays.md` — contract, threat model, compatibility, launch, rollback, and verification.
- EDIT: `.agents/scripts/opencode-launcher-helper.sh` — fixed-argv conversation/ACP path with cwd and validated overlay environment.
- NEW: `.agents/plugins/opencode-aidevops/team-interface-context.mjs` — parse/validate bounded context and supply the root-session transform/variant evidence.
- NEW: `.agents/plugins/opencode-aidevops/team-interface-roster-binding.mjs` — regenerate and bind the fresh canonical roster, selected identity, overlay bytes, and source digest at consumption.
- NEW: `.agents/plugins/opencode-aidevops/team-interface-runtime-boundary.mjs` — attest private runtime directories, bootstrap config, runtime package metadata, pinned plugin, and project binding.
- NEW: `.agents/plugins/opencode-aidevops/team-interface-path-guard.mjs` — enforce project-root, symlink, search-scope, and credential-path restrictions before permitted local tools execute.
- EDIT: `.agents/plugins/opencode-aidevops/config-hook.mjs` and `config-safety-guards.mjs` — branch before normal widening registration and apply closed conversation isolation to the resolved config.
- EDIT: `.agents/plugins/opencode-aidevops/index.mjs` and root chat-parameter routing — inject bounded context and resolve the selected workload variant without persisting model IDs.
- NEW: `.agents/scripts/tests/test-team-interface-opencode-overlay.mjs` — schema, roster, canonical output, secret/path/model/tool negative tests.
- NEW: `.agents/plugins/opencode-aidevops/tests/test-team-interface-conversation-profile.mjs` — final effective config, plugin ordering, context, root variant, and escape negatives.
- NEW: `.agents/scripts/tests/test-team-interface-opencode-installed-runtime.mjs` — bounded installed OpenCode effective-config and ACP startup canary with persistent-config exclusions.
- NEW: `.agents/scripts/team-interface-opencode-project-root.mjs` — validate canonical repository registrations and linked-worktree Git identity without widening cwd.
- EDIT: `.agents/scripts/tests/test-opencode-launcher-helper.sh` — fixed argv, cwd, env, redaction, passthrough/auto/unsafe input rejection.
- EDIT: team-interface/OpenCode references and README where the new user command is exposed.
- EDIT: `TODO.md`, mission/source-review, and this brief for task/completion evidence.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/team-interface-opencode-overlay.mjs` receives bounded team-interface/Buzz/Matrix descriptors; the launcher validates and passes them; plugin config and root chat hooks consume only validated context; the canonical roster remains source identity authority.
- **Writers/mutation paths:** `.agents/scripts/team-interface-opencode-overlay.mjs` writes only explicit output or stdout through atomic file replacement. The launcher creates no persistent config and execs fixed OpenCode ACP/TUI argv. The plugin mutates only the in-memory resolved config for the current conversation. No provider, repository, credential, issue, or persistent user-config write is authorized.
- **Tests/fixtures:** `.agents/scripts/tests/test-team-interface-opencode-overlay.mjs` uses synthetic roster/context fixtures with no real actors, communities, paths, or secrets. Fake OpenCode records argv/env; plugin tests exercise widened pre-state then assert final denial. A bounded local debug/startup test validates installed runtime behavior without network/provider traffic.
- **Schemas/config:** add one versioned overlay schema. Persistent `opencode.json`, global aidevops config schema, canonical agent source files, and team-interface runtime config remain unchanged.
- **Generated/deployed mirrors:** tracked `.agents/scripts/`, schema, plugin, and reference sources deploy through setup. No generated overlay is committed or copied into canonical config.
- **Migrations/backfills:** `.agents/scripts/team-interface-opencode-overlay.mjs` needs no migration because the overlay is ephemeral and opt-in. Existing launch commands remain unchanged unless the dedicated conversation mode is selected.
- **Cleanup/rollback paths:** terminate the conversation process and remove its ephemeral descriptor/output, then revert `.agents/scripts/team-interface-opencode-overlay.mjs`, the launcher, and plugin guard together; persistent config and roster remain untouched.

### Implementation Steps

1. Add the closed schema and Ajv-backed validator using existing team-interface schema-loading/canonical helpers.
2. Validate roster schema/digest and exact agent selection; map `primary` and `framework_guide` explicitly rather than silently substituting Build+.
3. Validate bounded interface context/reference grammar, reject sensitive/arbitrary fields, compute canonical context/overlay digests, and produce deterministic JSON.
4. Generate a deny-by-default effective OpenCode overlay with one selected read-only primary and no nested/delegated/network/mutating capability.
5. Add plugin context parsing, bypass normal plugin registration in conversation mode, and apply closed isolation to the resolved config. Assert unknown future tools/permissions remain denied by wildcard.
6. Route root-session tier to the current provider-specific variant at chat params; never serialize model/provider identity into the descriptor.
7. Add a dedicated launcher subcommand/path that validates source, cwd, fixed arguments, and environment before invoking `opencode acp --cwd`; preserve existing TUI/server/attach/Desktop paths.
8. Inject a bounded, immutable context block for the selected root session and prevent prompt/user content from altering the permission profile.
9. Add generator, plugin, launcher, roster, model-tier, discovery, and real effective-config/ACP tests; update docs and mission evidence.

### Hazards and Compatibility

- **Concurrency/atomicity:** descriptors are immutable content-addressed values; explicit output uses atomic replace. Each process gets its own environment/context and cannot update persistent config.
- **Migration/rollback:** no migration. Existing OpenCode launches remain unchanged. Rollback removes the opt-in conversation path and leaves canonical profiles/config intact.
- **Mixed-version/backward compatibility:** unknown OpenCode/plugin behavior or missing required config hooks blocks restricted launch. Do not silently fall back to a write-capable canonical profile.
- **Idempotency/retry:** identical roster/selection/context produces identical descriptor/config digests. Retry starts a new isolated process but does not mutate providers or persistent state.
- **Partial failure/recovery:** schema/digest/cwd/runtime/debug failure occurs before exec; malformed plugin context forces deny-all/no launch. Removing the ephemeral descriptor is sufficient cleanup.

### Complexity Impact

- **Target functions:** launcher command dispatch and plugin config orchestration.
- **Current risk:** both files already coordinate multiple launch/config modes.
- **Estimated growth:** one small launcher branch and one final guard call; place validation/generation/context logic in new focused modules.
- **Action required:** do not inline schema parsing or permission matrices into shell/config-hook orchestration; preserve existing complexity ratchets.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-opencode-overlay.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-conversation-profile.mjs
bash .agents/scripts/tests/test-opencode-launcher-helper.sh
node .agents/scripts/tests/test-team-interface-agent-roster.mjs
bash .agents/scripts/tests/test-opencode-subagent-runtime-guards.sh
bash .agents/scripts/tests/test-agent-discovery-smoke.sh
bash .agents/scripts/tests/test-canonical-model-tiers.sh
bash .agents/scripts/tests/test-opencode-server-launcher.sh
npm test --prefix .agents/plugins/opencode-aidevops
python3 -m py_compile .agents/scripts/team-interface-agent-roster.py
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** overlay tests prove closed canonical input/output; plugin tests prove final effective denial and context/variant behavior; launcher tests prove argv/cwd/env/redaction; roster/discovery/model tests protect identity/tier compatibility; plugin suite protects existing config behavior.
- **Broad verification trigger:** mandatory runtime verification because this is an execution security boundary. In addition to suites, run a bounded installed OpenCode `debug config` and ACP startup smoke against synthetic context with no network/provider action.

### Recoverability Checkpoint

- [x] Schema/generator/plugin/launcher focused tests pass.
- [x] WIP commit created before real runtime/broad gates: `wip: add restricted OpenCode conversation overlays`.
- [x] Effective OpenCode 1.18.9 config and bounded ACP startup evidence is recorded; exact-head PR review and merge gates passed.

### Safety-Stop Recovery

- **Original objective:** Launch canonical agents for provider conversations with bounded context and enforce read-only execution despite persistent write-capable profiles.
- **Preserved user directions:** Continue through the no-release full loop; never widen authority, persist provider secrets, or modify canonical user config.
- **Trigger and evidence:** not triggered.
- **Completed and verified:** schema, generator, source binding, launcher, plugin mutation order, tool/permission isolation, workload variant, bounded context, automated regressions, documentation, and installed-runtime smoke.
- **Remaining acceptance criteria:** none for F2.5; integrated Milestone 2 validation now passes and parent bookkeeping is handled by the final t18201 closeout PR.
- **Unsafe route not to repeat:** Do not rely on `OPENCODE_CONFIG_CONTENT` alone, select a persistent primary without final denial, permit task/network tools, store model IDs, concatenate raw prompts, or accept arbitrary launch args/env.
- **Next safe route:** preserve the merged proof and continue only through separately scoped downstream mission features.
- **Resume condition:** a downstream brief verifies current roster, plugin, launcher, and installed-runtime contracts before extending conversational authority.
- **Owner and status:** maintainer-owned interactive repair; merged and verified without release.

### Files Scope

- `.agents/schemas/team-interface/opencode-launch-overlay-v1.schema.json`
- `.agents/plugins/opencode-aidevops/team-interface-overlay-contract.mjs`
- `.agents/scripts/team-interface-opencode-overlay.mjs`
- `.agents/scripts/team-interface-opencode-effective-config.mjs`
- `.agents/reference/team-interface-opencode-overlays.md`
- `.agents/scripts/opencode-launcher-helper.sh`
- `.agents/plugins/opencode-aidevops/team-interface-context.mjs`
- `.agents/plugins/opencode-aidevops/team-interface-roster-binding.mjs`
- `.agents/plugins/opencode-aidevops/team-interface-runtime-boundary.mjs`
- `.agents/plugins/opencode-aidevops/team-interface-path-guard.mjs`
- `.agents/plugins/opencode-aidevops/config-hook.mjs`
- `.agents/plugins/opencode-aidevops/config-safety-guards.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/scripts/tests/test-team-interface-opencode-overlay.mjs`
- `.agents/scripts/tests/test-team-interface-opencode-installed-runtime.mjs`
- `.agents/scripts/team-interface-opencode-project-root.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-team-interface-conversation-profile.mjs`
- `.agents/scripts/tests/test-opencode-launcher-helper.sh`
- `.agents/reference/team-interfaces.md`
- `README.md`
- `TODO.md`
- `todo/tasks/t18208-brief.md`
- `todo/missions/m-20260804-5d06b1/mission.md`
- `todo/missions/m-20260804-5d06b1/research/source-review.md`
- `todo/missions/m-20260804-5d06b1/research/milestone-2-final-leaves.md`

## Acceptance Criteria

- [x] A valid canonical roster, selected stable agent, workload tier, and bounded synthetic interface context produce deterministic schema-valid overlay/config digests with no raw message, instruction, credential, path, model/provider ID, shell fragment, arbitrary environment, or authority grant.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-opencode-overlay.mjs && node .agents/scripts/tests/test-team-interface-agent-roster.mjs"
  ```

- [x] The fully merged plugin config for conversation mode leaves exactly credential-filtered local read/grep/glob access and denies Bash, task/subagents, writes, patches, skills, network/web, MCP/custom/unknown tools, managed-directory widening, sharing, snapshots, LSP, and formatter behavior.

  ```yaml
  verify:
    method: bash
    run: "node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-conversation-profile.mjs && npm test --prefix .agents/plugins/opencode-aidevops"
  ```

- [x] The dedicated launcher uses fixed OpenCode ACP/conversation argv with verified cwd and validated overlay context, rejects `--auto`, passthrough/env/cwd abuse, and leaves persistent `opencode.json` unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-opencode-launcher-helper.sh && bash .agents/scripts/tests/test-opencode-server-launcher.sh"
  ```

- [x] All three workload tiers resolve at root-session runtime without persisting model IDs; unknown/digest-mismatched/duplicate agents and plugin/runtime incompatibility fail closed, including an installed OpenCode effective-config/ACP smoke.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-canonical-model-tiers.sh && bash .agents/scripts/tests/test-opencode-subagent-runtime-guards.sh && node .agents/scripts/tests/test-team-interface-opencode-installed-runtime.mjs"
  ```

## Completion Evidence

- **Pull request:** [#29673](https://github.com/marcusquinn/aidevops/pull/29673) merged as `670d77b074928d70ef07e62055c8f434c7258db1` after the accepted security repairs, exact-head review, and required CI gates passed.
- **Implementation:** the closed schema, canonical contract/generator, bounded
  plugin context, workload routing, final config isolation, effective-config
  verifier, and fixed-argv launcher are implemented in the scoped paths above.
- **Focused verification:** overlay, source-binding, plugin conversation-profile,
  launcher, model-tier, discovery, subagent-runtime, and server-launcher suites
  pass; the repaired profile and launcher suites report 14 and 16 passing cases.
- **Review repair:** fresh canonical-roster/selected-agent binding, private
  runtime and bootstrap attestation, missing-overlay failure, registered
  project/worktree cwd validation, credential-safe local path enforcement, and
  a minimal conversation-only hook surface address all six accepted findings.
- **Broad verification:** team-interface, provider, runtime, compatibility, and
  full plugin suites pass from the merged-main tree; the expanded full plugin
  suite reports 595 passing tests.
- **Runtime verification:** isolated OpenCode 1.18.9 `debug config` excludes
  persistent home/project canaries and verifies the generated restriction
  profile; an actual ACP process remains healthy for the bounded startup window
  without provider traffic before test termination.
- **Quality:** JavaScript/Bash/Python syntax checks, ShellCheck, secretlint,
  Markdown, and changed-file lint pass. PR #29689 restored Qlty to 49/49
  without increasing the threshold.
- **Post-merge verification:** issue #29686 identified isolation-sensitive test
  assumptions after merge; PR #29687 repaired the tests, passed exact-head
  review and CI, and established the merged integration baseline at
  `0c817c462fc87d583c89a6ab768807daab5892df`.
- **Integrated validation:** overlay/roster, 14-case restricted profile,
  16-case launcher, 12-case server launcher, workload-tier, subagent guard,
  installed OpenCode 1.18.9, and full 595-test plugin suites pass from the
  merged integration baseline.
- **Publication:** no provider write, persistent user-config mutation,
  deployment, publication, or release was requested or performed.
- **Environment note:** `bun` is unavailable on the host. The first push used
  the repository's narrow `AIDEVOPS_PREPUSH_REPO_VERIFY=0` bypass only after the
  relevant checks above passed.

## Context & Decisions

- Support the `framework_guide` roster entry explicitly as a restricted guide profile; never map it silently to Build+.
- Interface context is a validated plugin system transform, not user prompt text and not authorization.
- Network reads are denied by default because attacker-chosen URLs can exfiltrate context.
- Workload tier is portable roster intent; provider/model resolution remains runtime-owned.
- Conversation mode must fail closed if final plugin isolation or effective-config verification is unavailable.

## Relevant Files

- `.agents/scripts/team-interface-agent-roster.py:72-108,146-207` — canonical selection input.
- `.agents/schemas/team-interface/agent-roster-v1.schema.json:17-42,69-90` — roster contract.
- `.agents/scripts/opencode-launcher-helper.sh:588-986` — existing launch modes.
- `.agents/plugins/opencode-aidevops/config-hook.mjs:291-350` — current config mutation order.
- `.agents/plugins/opencode-aidevops/config-safety-guards.mjs:48-123` — managed-directory and isolation patterns.
- `.agents/tools/ai-assistants/research-only.md` — credential-sensitive local read policy.
- `todo/missions/m-20260804-5d06b1/research/source-review.md` — decided F2.5 boundary.

## Dependencies

- **Blocked by:** none; F2.2 / #29543 is closed through PR #29605.
- **Unblocks:** Milestone 2 completion and the F2.5 dependency edge for F4.5, F6.2, and F6.6; those features retain their remaining independent dependencies and briefing gates.
- **External:** installed OpenCode is used only for local bounded effective-config/startup verification; no provider credential, publication, release, or deployment is required.

## Estimate

~5h: 1h schema/generator, 1.5h plugin guard/context/variant, 1h launcher, 1h tests/runtime proof, 0.5h docs/review.
