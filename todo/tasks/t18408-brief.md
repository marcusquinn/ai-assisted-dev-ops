<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18408: Support focused domain-primary and lighter delegated profiles

## Pre-flight

- [x] Memory recall: maintainer direction explicitly permits relevant main domains or lighter profiles for delegated work.
- [x] Discovery pass: existing main-agent selection, bounded primary registration and subagent-effort controls are foundations, not replacements.
- [x] File refs verified: profile registration, agent loader, subagent validation/effort and routing guide paths checked at `5393632ee`.
- [x] Tier: thinking; inherited permissions, domain context and cross-runtime delegation require a decided contract.
- [x] Seeded draft PR decision recorded: skipped pending the startup/discovery contracts.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18405 and t18407.

## What

Implement bounded delegated profiles that can inherit the appropriate primary
domain's canonical knowledge, or a lighter purpose-specific subset, without
copying agent essays or gaining permissions/model budget from the domain name.
Keep Build+ as the normal systems/development default.

## Why

Primary versus subagent is an execution role, not a restriction on useful domain
knowledge. Narrow workers should not need the entire parent conversation, but
must retain the objective, operating discipline, authority and required expertise.
Do not solve this by registering every leaf or making every primary globally callable.

## Tier

**Selected tier:** `tier:thinking` — permission inheritance and bounded profile derivation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/build-plus.md` — integration clarification (2026-09-06): the canonical main-agent frontmatter in Complete Write Surface must allow the two generated Task roles. `agent_config.py` derives a deny-by-default Task allowlist from this source, so otherwise Build+ cannot invoke either profile. Recognize the plugin-provided names in the already-scoped `subagent_validation.py`. The issue author is an admin, the assigned runner owns this work, and targeted prework discovery found no competing implementation. Verify with existing effort/MCP suites, native context-engineering/generator checks, progressive-load and changed-file lint. Other adapters retain their existing fallback; no tools or external authority are added.
- `EDIT: .agents/plugins/opencode-aidevops/config-agent-profiles.mjs`, `EDIT: .agents/plugins/opencode-aidevops/agent-loader.mjs` — bounded profile derivation/registration from canonical sources.
- `EDIT: .agents/plugins/opencode-aidevops/subagent-effort.mjs`, `EDIT: .agents/plugins/opencode-aidevops/subagent-effort-handlers.mjs`, `EDIT: .agents/scripts/lib/subagent_validation.py` — preserve parent envelope, cancellation and effort bounds as required.
- `EDIT: .agents/reference/agent-routing.md`, `EDIT: .agents/tools/build-agent/build-agent.md`; runtime generation changes must reuse t18405's contract and enumerate affected launch adapters first.

### Complete Write Surface

- **Callers/readers:** parent dispatch, `.agents/reference/agent-routing.md`, native Task profiles and headless launch readers.
- **Writers/mutation paths:** profile generation in `config-agent-profiles.mjs`, `agent-loader.mjs` and validated runtime adapters, not hand-written parallel domain prompts.
- **Tests/fixtures:** `.agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs` and `.agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs` cover bounded delegation/tool ownership.
- **Schemas/config:** `.agents/scripts/lib/subagent_validation.py` and canonical main-agent frontmatter; preserve current mode/tool/permission contracts.
- **Generated/deployed mirrors:** generated agent profiles and deployed `.agents/` knowledge reference the same source; custom user profiles remain user-owned.
- **Migrations/backfills:** add bounded profiles through `config-agent-profiles.mjs` first; no renaming/removing existing primary agents or rewriting session histories.
- **Cleanup/rollback paths:** remove/revert only newly generated profiles and preserve source `.agents/` documents and parent-owned child cancellation state.

### Implementation Steps

1. Define a child envelope: objective, scope, canonical domain source, essential decisions, output/evidence contract, available tools, authority and effort ceiling.
2. Derive a bounded child profile from canonical domain metadata using the source identity proven by t18405; do not embed a copy of every source file.
3. Require tool/permission/effort availability to remain within the parent-authorized envelope. Readiness is evidence, not permission.
4. Demonstrate Build+ delegating independent work to a non-code domain and a lighter bounded variant; preserve task identity and concise evidence handoff.
5. Preserve cancellation/resource ownership and avoid recursive leaf registration, critical-path handoff without user intent, or copying the full parent transcript.

### Hazards and Compatibility

- **Concurrency/atomicity:** child identity/context and ownership must not leak across simultaneous sessions or repositories.
- **Migration/rollback:** additive profiles can be disabled without altering existing source agents or stored work.
- **Mixed-version/backward compatibility:** unsupported runtimes retain the existing safe delegation path; do not assume OpenCode-only hooks exist elsewhere.
- **Idempotency/retry:** derived profile identities are stable and do not accumulate duplicates on reload.
- **Partial failure/recovery:** unavailable capability or cancelled child returns truthful bounded evidence and cannot widen authority through fallback.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-mcp-activation.mjs
.agents/scripts/progressive-load-check.sh --quiet
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** effort/MCP suites protect delegation bounds; focused profile captures prove inherited knowledge and lighter-scope exclusion; pointer/lint gates protect generated references. No live external side effect is required.

### Progressive Context Plan

- **Read first:** t18405/t18407 contracts and the current parent-to-child registration path.
- **Load only if:** one selected domain source and the affected runtime adapter; do not load every primary or leaf.
- **Stop when:** the inherited envelope, derived profile and bounded handoff are proven.

## Acceptance Criteria

- [ ] A delegated domain-primary profile and a lighter variant receive their required canonical knowledge and return usable evidence.
- [ ] Neither profile gains tools, authority, recursion or effort beyond the parent envelope; unavailable/cancelled cases are exercised.
- [ ] Registration stays bounded and repeated generation does not fork prompts, duplicate profiles or leak cross-repo context.

## Seeded Draft PR

Skipped — depends on the verified delivery and discovery contracts.

Parent: #31280
