<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18406: Deduplicate Claude proxy framework context without losing provenance

## Pre-flight

- [x] Memory recall: preservation constraints are retained in the parent plan.
- [x] Discovery pass: PR #31228 already supplies exact-body/skill-advertising compaction; this leaf covers the later Claude proxy assembly boundary.
- [x] File refs verified: `buildClaudeArgs()` unconditionally combines framework, agent and incoming system text at `5393632ee`.
- [x] Tier: standard; exact-overlap treatment within existing authority is bounded, with fallback behavior specified.
- [x] Seeded draft PR decision recorded: skipped; tests must establish the actual overlap first.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18405 (reuse its source identity/delivery evidence).

## What

Remove confirmed duplicate framework payload at the Claude CLI proxy boundary
while retaining selected-domain knowledge, protected reinforcement and fallback
delivery when the incoming request lacks the framework.

## Why

`buildClaudeArgs()` appends framework + selected agent + incoming system prompt.
The latter may already contain framework guidance. OpenCode's earlier exact-body
compaction cannot remove a copy added later by the proxy. Similar prose is not
necessarily duplication; cross-authority content must not be conflated.

## Tier

**Selected tier:** `tier:standard` — a bounded assembly repair with defined preservation rules.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/claude-proxy-context.mjs` — `getFrameworkPrompt()`, `getAgentPrompt()` and `buildClaudeArgs()` as required by the proven overlap.
- `EDIT: .agents/plugins/opencode-aidevops/context-catalogue.mjs` only if reusing its exact-body helper avoids duplication without widening its semantics.
- Extend the existing plugin test directory using `.agents/plugins/opencode-aidevops/tests/test-context-catalogue.mjs` as the bounded preservation pattern.

### Complete Write Surface

- **Callers/readers:** `.agents/plugins/opencode-aidevops/claude-proxy.mjs` consumes the argv/system-prompt builder.
- **Writers/mutation paths:** only serialized prompt/argv construction in `claude-proxy-context.mjs`; do not change user agent documents or credentials.
- **Tests/fixtures:** existing `test-context-catalogue.mjs` exact-duplicate/skill-boundary assertions and focused builder fixtures in the same test runner.
- **Schemas/config:** `.agents/plugins/opencode-aidevops/claude-proxy-context.mjs` request fields/argv and the source identity contract from t18405; no auth schema change.
- **Generated/deployed mirrors:** `.agents/plugins/opencode-aidevops/claude-proxy-context.mjs` is deployed and constructs CLI prompts; source remains authoritative.
- **Migrations/backfills:** N/A because request assembly is ephemeral; persisted user/session content is not rewritten.
- **Cleanup/rollback paths:** revert `claude-proxy-context.mjs` assembly changes; preserve incoming content and full required guidance on unknown identity.

### Implementation Steps

1. Reproduce framework-present and framework-absent incoming payloads using sanitized fixtures.
2. Reuse exact/provenance-aware identity; keep one required framework body and the selected agent material when genuinely absent.
3. Preserve similar-but-different instructions, authority distinctions, unknown wrappers and standalone Claude proxy fallback.
4. Keep stable prefix ordering where compatible; measure assembled bytes/occurrences without logging private prompts.

### Hazards and Compatibility

- **Concurrency/atomicity:** pure per-request assembly must not share mutable source ownership across sessions.
- **Migration/rollback:** no stored transcript rewrite; reverting restores existing request construction.
- **Mixed-version/backward compatibility:** unknown marker formats retain full guidance rather than dropping it.
- **Idempotency/retry:** repeated assembly of identical inputs yields the same prompt and never accumulates copies.
- **Partial failure/recovery:** missing metadata cannot remove framework safeguards or turn untrusted text into policy.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-context-catalogue.mjs
node --check .agents/plugins/opencode-aidevops/claude-proxy-context.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** catalogue tests preserve current exact-only semantics; builder fixtures must prove framework present/absent/unknown cases and argv shape; syntax/lint cover changed modules. No live credential-bearing request is needed for this deterministic repair.

## Acceptance Criteria

- [ ] A fixture with an already-present canonical framework body produces one required copy after proxy assembly; selected-domain knowledge remains.
- [ ] Absent/unknown/similar-but-different and different-authority cases preserve the required fallback and distinct instructions.
- [ ] Repeated assembly is deterministic and no raw prompts, credentials or user files are rewritten/logged.

## Seeded Draft PR

Skipped — current pure-builder fixtures are preferable to a speculative code seed.

Parent: #31280
