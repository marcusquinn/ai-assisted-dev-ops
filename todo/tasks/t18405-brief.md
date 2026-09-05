<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18405: Verify primary-agent knowledge delivery across runtime entry points

## Pre-flight

- [x] Memory recall: parent plan retains the pilot's silent plugin-loading failure and maintainer direction.
- [x] Discovery pass: PR #31207 already implements runtime/main-agent selection and #31201 Codex workflow setup; extend these rather than create parallel launchers.
- [x] File refs verified: `get_agent_config()` still uses a source-path description and shared prompt at `5393632ee`; delivery loss is a risk to reproduce, not assumed universal.
- [x] Tier: thinking; runtime delivery/fallback and dispatch-path behavior require explicit cross-runtime judgment.
- [x] Seeded draft PR decision recorded: skipped pending assembled-context evidence.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18403.

## What

Give supported entry routes a tested contract that the canonical operational core
and selected primary-domain knowledge reach the model before their decisions.
Add content-free provenance/readiness evidence, and repair confirmed missing or
shadowed routes without forking agent guidance or widening permissions.

## Why

An agent name/description or installed plugin is not proof its knowledge loaded.
The benchmark initially passed tasks while the intended observer/plugin was absent.
Generated primaries currently point at their source in `description`; the shared
`build.txt` is a placeholder. Existing launcher-selected routes may differ, so
capture actual assembled context before attributing a defect.

## Tier

**Selected tier:** `tier:thinking` — generated/runtime contracts and safe degraded behavior.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/lib/agent_config.py`, `EDIT: .agents/scripts/agent-discovery.py`, `EDIT: .agents/scripts/generate-runtime-config-agents.sh` — generated primary delivery.
- `EDIT: .agents/scripts/codex-setup.py`, `EDIT: .agents/scripts/prompt-injection-adapter.sh`, `EDIT: .agents/scripts/opencode-agent-discovery.py` — supported native and compatibility paths only where evidence requires.
- `EDIT: .agents/plugins/opencode-aidevops/config-agent-profiles.mjs` and relevant existing runtime launch modules discovered through PR #31207; exact additional launcher paths must be enumerated before edits.
- Existing `.agents/plugins/opencode-aidevops/plugin-health.mjs` is the provenance/health pattern; do not invent a second health database.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/agent-discovery.py`, `.agents/plugins/opencode-aidevops/config-agent-profiles.mjs` and native/launcher entry routes consume primary selection and generated stubs.
- **Writers/mutation paths:** `.agents/scripts/lib/agent_config.py`, unified/fallback generators and `.agents/scripts/codex-setup.py` generate user-facing runtime adapters.
- **Tests/fixtures:** `.agents/plugins/opencode-aidevops/tests/test-plugin-health.mjs`, `.agents/scripts/tests/test-context-engineering-guidance.sh`; use disposable HOME captures for affected routes.
- **Schemas/config:** `.agents/scripts/lib/agent_config.py` defines prompt/description, source identity, tool/permission profile and instruction-list merge contracts.
- **Generated/deployed mirrors:** generated OpenCode JSON/stubs, Claude preload locations, Codex AGENTS/skills and deployed `.agents/` sources; never hand-edit real user mirrors as the fix.
- **Migrations/backfills:** `.agents/scripts/opencode-agent-discovery.py` compatibility fallback must preserve unrelated instruction entries; Codex override precedence remains user-owned.
- **Cleanup/rollback paths:** generators in `.agents/scripts/generate-runtime-config-agents.sh` must use isolated test homes/reversible outputs and retain a sufficient core fallback when hooks/imports are unavailable.

### Implementation Steps

1. Capture sanitized delivered context for Build+ plus two non-code primary domains on supported entry routes, including the existing launcher path.
2. Define source identity, selected-profile and enforcement-availability evidence. Keep it internal/content-free, not a verbose greeting or a new permission grant.
3. Where primary knowledge is absent, explicitly deliver the canonical agent's essential knowledge or a reliable required load before its decision point; do not rely solely on a description field.
4. Fix confirmed fallback list replacement and surface shadowed Codex preload without overwriting user AGENTS.override choices.
5. Verify cold start, existing custom config and unavailable-hook behavior; preserve permission and publication boundaries and no paid API fallback.

### Hazards and Compatibility

- **Concurrency/atomicity:** generated configuration writes must preserve user entries and existing atomic deployment behavior.
- **Migration/rollback:** introduce readers/evidence before relying on leaner prompts; rollback restores prior sufficient delivery.
- **Mixed-version/backward compatibility:** distinguish runtime contracts and explicit overrides; do not assume every harness supports OpenCode hooks.
- **Idempotency/retry:** repeated setup/startup must not append duplicate sources or overwrite unrelated instructions.
- **Partial failure/recovery:** failed imports or unavailable hooks produce truthful degraded-state evidence, not silent claims of full protection.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-plugin-health.mjs
bash .agents/scripts/tests/test-context-engineering-guidance.sh
.agents/scripts/progressive-load-check.sh --quiet
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** health/context tests cover evidence and inherited semantics; pointer/lint gates protect source/deployed references. Add only focused clean-HOME delivery captures for demonstrated route uncertainty; record runtime versions and untested routes.

### Progressive Context Plan

- **Read first:** the existing launch/generation call path and chosen primary source; compare delivered payload, not Markdown line counts.
- **Load only if:** runtime-specific adapter docs for a changed route or a fallback failure.
- **Stop when:** source, delivery point, fallback, permission profile and proof are explicit; do not load every specialist file or real auth store.

## Acceptance Criteria

- [ ] Supported sampled starts prove canonical core and selected-domain knowledge arrive before decisions, with source/version/profile evidence.
- [ ] Missing/duplicate/shadowed cases are exercised; unavailable hooks do not falsely claim protection or remove the sufficient fallback.
- [ ] Repeated setup preserves unrelated user configuration and explicit override precedence.
- [ ] No new broad tool access, secret logging, paid API fallback or independent agent-content fork is introduced.

## Seeded Draft PR

Skipped — reproduce delivered-context behavior before selecting a code repair.

Parent: #31280
