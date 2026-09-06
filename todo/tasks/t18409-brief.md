<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18409: Scope detailed guidance to decisions while preserving universal DevOps

## Pre-flight

- [x] Memory recall: parent direction forbids treating non-code domains as outside DevOps or deleting hard-won knowledge for size alone.
- [x] Discovery pass: PR #31228 and the context-engineering refinement plan already establish semantic preservation; this leaf adds verified action-boundary delivery only.
- [x] File refs verified: AGENTS, progressive-disclosure, agent-review, prompt-hook registry and domain/routing guides checked at `5393632ee`.
- [x] Tier: thinking; deciding reliable activation boundaries requires semantic and fallback analysis.
- [x] Seeded draft PR decision recorded: skipped; no blind compression patch.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18405 and t18407.

## What

Refine delivery of a small evidenced set of detailed operating procedures so they
arrive before their protected decisions, while the shared DevOps/value/safety core
remains universally available. Preserve full knowledge, provenance and sufficient
fallback instructions on runtimes without enforcement hooks.

## Why

The valid distinction is universal principles versus action-specific mechanics,
not coding versus non-coding. Redundant or premature detail can add work, but a
shorter file is not proof of better outcomes. Current safety and task discipline
must not depend on an optional plugin silently loading.

## Tier

**Selected tier:** `tier:thinking` — instruction semantics and delivery boundaries, not mechanical shortening.

## How (Approach)

### Files Scope

- `.agents/AGENTS.md`
- `.agents/reference/progressive-disclosure.md`
- `.agents/configs/prompt-hook-candidates.conf`
- `.agents/tools/build-agent/agent-review.md`
- `.agents/reference/agent-routing.md`
- `.agents/scripts/tests/test-context-engineering-guidance.sh`
- `.agents/scripts/progressive-load-check.sh`
- `todo/tasks/t18409-brief.md`

Scope normalization for GH#31294: these paths are already named in Files to
Modify and Complete Write Surface below. The local brief is included solely to
persist this scope contract; no implementation authority is expanded. Owning
reference targets beyond this list still require verified integration recovery.
Verification remains the four commands in Verification Before Dispatch.

### Files to Modify

- `EDIT: .agents/AGENTS.md`, `EDIT: .agents/reference/progressive-disclosure.md`, `EDIT: .agents/configs/prompt-hook-candidates.conf` — preserve the core and record each proven relocation/enforcement relationship.
- `EDIT: .agents/tools/build-agent/agent-review.md`, `EDIT: .agents/reference/agent-routing.md` only where the activation contract needs clarification.
- Owning workflow/reference targets must be selected from the specific directives and verified before editing; do not pre-create a new generic operating manual.

### Complete Write Surface

- **Callers/readers:** all `.agents/AGENTS.md` consumers and the relevant action/domain entry points from t18405/t18407.
- **Writers/mutation paths:** `.agents/AGENTS.md`, owning reference files and existing generated adapters; each moved directive has one declared owner.
- **Tests/fixtures:** `.agents/scripts/tests/test-context-engineering-guidance.sh` and `.agents/scripts/progressive-load-check.sh`; reuse existing comprehension scenarios at the protected boundary.
- **Schemas/config:** `.agents/configs/prompt-hook-candidates.conf` records hooked/partial/candidate/prompt-only status and the existing AGENTS size ratchet remains intact.
- **Generated/deployed mirrors:** generated runtime instruction views from t18405 and deployed `.agents/` pointers, not hand-edited duplicates.
- **Migrations/backfills:** introduce `.agents/reference/` targets/triggers before extracting detail; retain old-runtime sufficient guidance until delivery is proven.
- **Cleanup/rollback paths:** restore `.agents/AGENTS.md` directive wording/placement from Git if coverage is uncertain; never delete rationale, source IDs or protected behavior as cleanup.

### Implementation Steps

1. Select only a small high-frequency or high-overhead set using actual delivered-context evidence; preserve the purpose from t18403 inline at the appropriate core scope.
2. For each directive record provenance, current enforcement, decision trigger, owning source, generated views and fallback. Unknown provenance/delivery defaults to keeping it.
3. Keep authority, secrets, external-content trust, verified completion and portable durable work invariants universal. Deliver platform CLI mechanics before the corresponding action.
4. Distinguish registered capability from ready/authorized execution; avoid service probes for purely conceptual work without exempting later side effects.
5. Compare the protected behavior through affected runtime routes; revert any reduction that makes required knowledge arrive late or relies on missing hooks.

### Hazards and Compatibility

- **Concurrency/atomicity:** source and trigger updates ship together; preserve unrelated policy changes from parallel sessions.
- **Migration/rollback:** complete reference/trigger coverage precedes removal of inline detail; rollback restores sufficient prior delivery.
- **Mixed-version/backward compatibility:** keep non-hook and older-runtime fallbacks; never infer enforcement from documentation alone.
- **Idempotency/retry:** one owning rule plus deliberate boundary reinforcement; repeated generation must not multiply blocks.
- **Partial failure/recovery:** missing target, unavailable hook or failed behavioral proof leaves the directive preserved and the acceptance criterion open.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-context-engineering-guidance.sh
.agents/scripts/progressive-load-check.sh --quiet
.agents/scripts/linters-local.sh --changed
git diff --check
```

- **Surface mapping:** context/progressive-load checks protect current semantics/pointers; targeted delivered-route/comprehension evidence must cover each relocated decision boundary. Lint/size reductions alone do not satisfy acceptance.

### Progressive Context Plan

- **Read first:** canonical purpose and Agent Review classification/provenance rubric, then the selected directives only.
- **Load only if:** their owning workflow/history is needed to establish the protected failure and reliable trigger.
- **Stop when:** preservation and delivery are proven; no blanket corpus rewriting, hard token quotas or new global rituals.

## Acceptance Criteria

- [ ] Every changed directive has retained provenance, one owner, reliable pre-decision delivery and a tested fallback.
- [ ] Universal DevOps purpose and safety remain available in every affected runtime; no domain is treated as a disposable Q&A mode.
- [ ] No rules are removed for instruction count alone, and failed delivery evidence causes preservation rather than a false efficiency claim.

## Seeded Draft PR

Skipped — each semantic change must follow the verified activation boundary.

Parent: #31280
