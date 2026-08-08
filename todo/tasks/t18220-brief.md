---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18220: Route output-heavy interactive work through lower-tier subagents

## Pre-flight

- [x] Memory recall: `interactive parent subagent model tier token output parallelism` → 0 hits — no relevant stored lessons
- [x] Discovery pass: 1 commit / 0 merged related PRs / 0 open related PRs touch the target files in the last 48 hours — commit `e47941c6d` changed an unrelated recommendation line in `.agents/AGENTS.md`; it does not overlap the routing rule at line 55
- [x] File refs verified: 3 refs checked at `a61ad9f568197b5a07b28859603ba9f57280bfc0`, all present and matching HEAD
- [x] Tier: `tier:simple` — exact replacements and a complete comprehension scenario are supplied; no runtime or architecture choice remains
- [x] Seeded draft PR decision recorded: skipped — the issue contains the complete low-risk documentation/test contract, so an unverified implementation seed would add no useful context

## Origin

- **Created:** 2026-08-08
- **Session:** OpenCode:interactive-2026-08-08
- **Created by:** ai-interactive, at the user's request
- **Parent task:** None
- **Blocked by:** None
- **Conversation context:** Interactive parent sessions usually use a thinking-tier model. The user wants independent, verbose tool work to use simple or standard subagents where sufficient, run independent work in parallel, and return only decision-relevant summaries to the parent.

## What

Strengthen interactive subagent routing so a thinking-tier parent deliberately considers lower-tier children for bounded, independent, output-heavy discovery, analysis, and tool work. Independent child work should run in parallel within the existing two-child cap, retain raw output in child context, and return a concise final-only summary containing the decision, evidence, uncertainty, and next action.

The parent remains authoritative for synthesis and the active critical path. Small, low-output calls remain direct when delegation overhead would exceed the likely context savings.

This is a provider-neutral routing-policy and comprehension-test change. Existing runtime effort mapping remains responsible for resolving `simple`, `standard`, and `thinking` to concrete models.

## Why

Thinking-tier interactive parents are the expensive and context-sensitive layer, but many supporting operations do not need thinking-tier reasoning. A representative routing search at current HEAD emitted 1,075 lines and 90,581 bytes (about 22,645 tokens by the documented chars/4 approximation) before synthesis:

```text
matches=1075 bytes=90581 approx_tokens=22645
```

A bounded simple-tier research child in the same session reduced comparable repository/GitHub exploration to one focused final summary. The desired optimization is specifically lower expensive-parent usage and lower parent-context pressure; child work still consumes tokens and must not be described as free.

Prior art already supplies the safety and routing primitives: `#27421` / PR `#27467` added bounded full-loop orchestration, while PR `#27060` canonicalized effort-tier model routing. The remaining gap is an explicit output-aware delegation rule and a comprehension scenario that preserves it.

## Tier

### Tier checklist

- [x] **Exact execution contract supplied?** Every existing-file edit has a complete old/new block and the YAML scenario is supplied in full.
- [x] **Targets and reference pattern verified?** All three targets were read at HEAD; the existing routing bullets and comprehension scenario format are the reference patterns.
- [x] **No semantic or design decision remains?** Parent authority, two-child cap, result shape, direct-call exception, and provider-neutral boundary are decided below.
- [x] **Bounded, reversible, low-consequence impact?** Documentation plus one comprehension scenario; rollback is a three-file revert.
- [x] **No stateful coordination to invent?** No scheduler, runtime interception, persistence, or shared-state changes.
- [x] **Focused verification and rollback are explicit?** The targeted benchmark, changed-file lint, prompt-size ratchet, and exact rollback scope are specified.
- [x] **No dispatch-path risk override?** None of the three files appears in `.agents/configs/self-hosting-files.conf`.

**Selected tier:** `tier:simple`

**Tier rationale:** Exact documentation replacements and one complete comprehension scenario, with no runtime behavior or unresolved design decision, make this a bounded reversible simple-tier task.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The exact edits are inline; an untested draft would not improve handoff quality.
- **Status:** `not-created`
- **Freshness evidence:** Memory, collision, recent-change, and file-reference checks completed against current HEAD.
- **Verification run:** `UNVERIFIED — implementation tests not run because this issue only briefs future work`
- **Stale-assumption warning:** Re-read all three old strings before editing; if any changed, preserve the current semantics and re-run duplicate discovery before adapting the replacements.

## How (Approach)

### Files to Modify

- `EDIT: .agents/AGENTS.md:55` — keep the always-loaded rule short while exposing output-aware lower-tier delegation.
- `EDIT: .agents/reference/agent-routing.md:24-28` — define parent/child tier independence, output-funneling, parallel batching, and the direct-call exception.
- `EDIT: .agents/tests/comprehension/reference--agent-routing.yaml:39-50` — add a scenario that tests the behavior from a thinking-tier parent.

### Complete Write Surface

- **Callers/readers:** `.agents/AGENTS.md:55` points all interactive agents to `.agents/reference/agent-routing.md`; `.agents/build-plus.md:73-83` separately preserves advisory-only delegation and lowest-effort routing.
- **Writers/mutation paths:** `.agents/AGENTS.md`, `.agents/reference/agent-routing.md`, and `.agents/tests/comprehension/reference--agent-routing.yaml` are the only mutation paths; no runtime state writer changes.
- **Tests/fixtures:** `.agents/tests/comprehension/reference--agent-routing.yaml` is the behavior fixture consumed by `.agents/scripts/comprehension-benchmark-helper.sh`.
- **Schemas/config:** No schema or model-routing configuration changes; `.agents/configs/model-routing-table.json` remains the concrete provider/model resolver.
- **Generated/deployed mirrors:** No checked-in generated mirror changes. Normal `setup.sh` deployment copies merged `.agents/` content; do not edit deployed `~/.aidevops/agents/` files.
- **Migrations/backfills:** N/A — documentation-only because the task changes no persisted runtime state, schema, or generated data.
- **Cleanup/rollback paths:** Revert `.agents/AGENTS.md`, `.agents/reference/agent-routing.md`, and `.agents/tests/comprehension/reference--agent-routing.yaml` together. Existing routing remains valid if the new comprehension scenario is removed with the policy text.

### Implementation Steps

1. In `.agents/AGENTS.md`, replace this complete old string:

**oldString:**

```markdown
- Keep interactive subagents off the critical path and bounded; prefix delegated prompts with the lowest sufficient `[effort:simple|standard|thinking]`; details: `reference/agent-routing.md`.
```

with this complete new string:

**newString:**

```markdown
- Keep interactive subagents off the critical path; when sufficient, send independent output-heavy work to bounded simple/standard children and require concise evidence summaries. Details: `reference/agent-routing.md`.
```

Do not add rationale or examples to `.agents/AGENTS.md`; detailed semantics belong in the reference file so the always-loaded prompt stays within its size ratchet.

2. In `.agents/reference/agent-routing.md`, replace this complete old string:

**oldString:**

```markdown
- Prefix every delegated prompt with `[effort:simple]`, `[effort:standard]`, or `[effort:thinking]`; use the lowest tier that can reliably complete the task.
```

with this complete new block:

**newString:**

```markdown
- Prefix every delegated prompt with `[effort:simple]`, `[effort:standard]`, or `[effort:thinking]`; use the lowest tier that can reliably complete the task.
- A thinking-tier parent does not require thinking-tier children. When reliable, offload bounded, independent, output-heavy discovery, analysis, and tool work to simple or standard children; keep small low-output calls direct when delegation overhead outweighs context savings.
- Batch independent children in one parallel call. Require final-only summaries with the decision, evidence (paths/lines or commands), uncertainty, and next action; raw logs stay in child context and the parent owns synthesis.
```

Keep the existing two-child cap, no-nested-subagents rule, critical-path ownership, completion waiting rule, and concurrency constraints unchanged.

3. Append this complete scenario to `scenarios:` in `.agents/tests/comprehension/reference--agent-routing.yaml`:

**Exact transform:** Append the following block as the final item under `scenarios:` without changing existing scenarios.

```yaml
  - name: "offloads output-heavy work from a thinking parent"
    prompt: "A thinking-tier interactive parent needs three independent, verbose repository and CI investigations, but only their conclusions matter. How should it route the work?"
    expected:
      contains:
        - "simple"
        - "standard"
        - "parallel"
        - "evidence"
        - "critical path"
      min_length: 60
      max_length: 700
    reference_answer: |
      The parent's thinking tier does not force thinking-tier children. Keep
      synthesis and the active critical path in the parent. Send up to two
      independent investigations in one parallel batch at the lowest reliable
      simple or standard tier, then run the remaining child only after that
      batch returns. Each child should return a final-only decision, path/line
      or command evidence, uncertainty, and next action so verbose raw output
      stays out of the parent context. Keep a small low-output call direct when
      delegation overhead would cost more than it saves.
    fast_fail_triggers:
      - refusal
```

4. Run the focused comprehension benchmark first, then changed-file lint and the prompt-size check. Hand-apply any wording fix rather than weakening test expectations or increasing the size baseline.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing interactive concurrency remains capped at two. The new policy parallelizes only independent advisory work and does not alter shared-state or file-ownership rules.
- **Migration/rollback:** No migration. A three-file revert restores prior guidance and its fixture.
- **Mixed-version/backward compatibility:** Older runtimes that do not expose effort-tier child routing continue using their current fallback; this task does not change runtime adapters or concrete model IDs.
- **Idempotency/retry:** Re-reading the policy is idempotent. Existing evidence-reuse and late-child rules continue to govern retries.
- **Partial failure/recovery:** If a child fails or returns unusable evidence, the parent follows the existing rule to proceed locally or retry only when evidence is absent, stale, or contradictory; it never abandons the objective.
- **Cost semantics:** Do not claim delegation eliminates total token usage. It isolates verbose context from the expensive parent and enables lower-tier processing where sufficient.

### Verification Before Dispatch

```bash
bash .agents/scripts/comprehension-benchmark-helper.sh test .agents/tests/comprehension/reference--agent-routing.yaml
bash .agents/scripts/linters-local.sh --changed
test "$(wc -c < .agents/AGENTS.md | tr -d ' ')" -le 24000
```

- **Surface mapping:** The benchmark verifies routing comprehension; changed-file lint validates Markdown/YAML and repository policy; the byte check protects the always-loaded prompt budget.
- **Broad verification trigger:** Not required — the task changes no runtime, model table, dispatcher, plugin, dependency, or release infrastructure.

### Files Scope

- `.agents/AGENTS.md`
- `.agents/reference/agent-routing.md`
- `.agents/tests/comprehension/reference--agent-routing.yaml`

## Acceptance Criteria

- [ ] A thinking-tier interactive parent is explicitly instructed to consider simple or standard children for bounded independent output-heavy work rather than inheriting the parent's tier automatically.
- [ ] Independent advisory work is batched in parallel within the existing two-child cap, and each child is required to return a final-only decision, evidence, uncertainty, and next action.
- [ ] The parent retains synthesis and active-critical-path ownership; nested subagents remain forbidden, and small low-output calls are not delegated when overhead outweighs savings.
- [ ] No runtime adapter, concrete model ID, scheduler, dispatcher, or model-routing configuration is changed.
- [ ] The targeted routing comprehension benchmark passes.
- [ ] Changed-file lint passes and `.agents/AGENTS.md` remains at or below 24,000 bytes without a ratchet increase.

## Context & Decisions

- Optimize expensive-parent context and model usage, not an unverifiable claim of zero total child tokens.
- Prefer guidance plus comprehension enforcement because effort-tier routing, parallel caps, child isolation, and completion joining already exist.
- Do not add automatic tool interception, a new scheduler, a new tier, plugin-specific semantics, or forced delegation of trivial calls.
- Keep the always-loaded change to one short pointer-level replacement; rationale and examples stay in `reference/agent-routing.md`.
- Prior art: issue `#27421`, PR `#27467`, and PR `#27060`; none fully specifies the output-funnel decision and summary contract requested here.

## Dependencies

- **Blocked by:** None
- **Blocks:** More consistent use of lower-cost child models and parallel advisory work in interactive parent sessions.
- **External:** None; no credentials, purchases, or provider-specific setup.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 5m | Re-read three exact targets and prior-art references |
| Implementation | 10m | Apply two exact documentation replacements and append one YAML scenario |
| Testing | 10m | Focused benchmark, changed lint, and prompt-size check |
| **Total** | **25m** | Bounded documentation/test task |
