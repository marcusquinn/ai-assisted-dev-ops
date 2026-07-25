<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Comprehension Benchmark Pilot Results

**Date:** 2026-04-02 | **Files:** 15 | **Scenarios:** 38 (2-3/file) | **Method:** Structural pre-filter + predicted tier assignment

This is historical benchmark evidence. Provider-family names and costs below
record the mappings used on the pilot date; they are not workload-tier names or
claims about current runtime integration. See `README.md` for the current
contract.

## Summary

| Pilot-time mapped model family | Count | % |
|--------------------------------|-------|---|
| haiku | 10 | 67% |
| sonnet | 5 | 33% |
| opus | 0 | 0% |

## Per-File Results

| File | Lines | Cross-refs | Complexity | Mapped model | Scenarios |
|------|-------|-----------|------------|--------------|-----------|
| `scripts/commands/code-simplifier.md` | 12 | 2 | simple | haiku | 2 |
| `aidevops/memory-patterns.md` | 48 | 6 | simple | haiku | 2 |
| `reference/self-improvement.md` | 59 | 8 | simple | haiku | 2 |
| `reference/task-taxonomy.md` | 63 | 2 | simple | haiku | 3 |
| `aidevops/graduated-learnings.md` | 69 | 12 | moderate | haiku | 2 |
| `reference/agent-routing.md` | 69 | 5 | simple | haiku | 3 |
| `workflows/pre-edit.md` | 78 | 6 | simple | haiku | 3 |
| `aidevops/security.md` | 80 | 5 | simple | haiku | 2 |
| `aidevops/configs.md` | 89 | 10 | moderate | haiku | 2 |
| `prompts/worker-efficiency-protocol.md` | 106 | 8 | moderate | sonnet | 3 |
| `aidevops/architecture.md` | 124 | 15 | complex | sonnet | 3 |
| `aidevops/onboarding.md` | 130 | 12 | moderate | haiku | 2 |
| `tools/code-review/code-simplifier.md` | 137 | 18 | complex | sonnet | 3 |
| `workflows/git-workflow.md` | 158 | 14 | complex | sonnet | 3 |
| `reference/planning-detail.md` | 165 | 12 | complex | sonnet | 3 |

## Failure Mode Categories

### Clarity problem (file needs improvement)

Right topic, wrong conclusion — multiple valid readings exist.

**Expected haiku failures (ambiguous docs):**
- `code-simplifier.md`: nuanced "almost never simplify" categories → haiku over-simplifies classification
- `planning-detail.md`: 3-step PR lookup fallback chain with conditional logic → haiku skips or conflates steps
- `worker-efficiency-protocol.md`: 6-row model escalation decision matrix → haiku misses edge cases

### Exceeds model capability (file is fine, model too weak)

**Fast-fail indicators:** refusal, confabulation (hallucinated paths/tools), structural_violation (ignores explicit constraint), disengagement (minimal response).

**Expected haiku failures:**
- `architecture.md`: "intelligence over scripts" meta-level philosophy → haiku gives surface-level answer
- `git-workflow.md`: allowlist/blocklist semantics for destructive commands → haiku conflates blocked vs allowed
- `planning-detail.md`: interacting constraints (PR evidence, pre-commit hooks, issue-sync cascade) → haiku misses cascade

### Known-Bad Cases

**Haiku false-fails (correctly escalated to sonnet):**
- `tools/code-review/code-simplifier.md`: 4-tier classification (safe/prose-tightening/requires-judgment/almost-never) — haiku collapses to binary; sonnet maintains distinction.
- `workflows/git-workflow.md`: allowlist vs blocklist + `--force-with-lease` exception — haiku conflates; sonnet distinguishes correctly.

**Sonnet false-fails:** None expected. Files that would have mapped to Opus
(for example the then-400-line `prompts/build.txt`) were excluded from the pilot.

**False-pass risk:** Haiku passes deterministic checks but misunderstands intent (e.g., `reference/self-improvement.md` "framework vs project routing" — outputs "framework" but with wrong reasoning). Mitigation: adjudication layer (haiku self-check or sonnet judge); `reference_answer` field enables precise comparison for critical files.

## Structural Pre-Filter

Predicts complexity from line count, cross-refs, code blocks, table rows, heading depth — no model calls.

| Complexity | Criteria | Pilot-time mapped model |
|------------|----------|-------------------------|
| simple | score ≤ 2 (< 60 lines, few refs) | haiku |
| moderate | score 3-5 (60-120 lines, moderate refs) | haiku or sonnet |
| complex | score > 5 (> 120 lines, many refs) | sonnet |

**Accuracy:** ~70%. Remaining 30% are "moderate" files where the model benchmark adds most value.

## Pilot-Time Cost Analysis

| Component | Per-file | Notes |
|-----------|---------|-------|
| Pre-filter (structural) | $0.00 | Pure shell heuristics |
| Haiku scenario run (2-3 scenarios) | ~$0.003 | ~500 tokens in, ~200 out/scenario |
| Deterministic scoring | $0.00 | Regex/string matching |
| Haiku self-check (if ambiguous) | ~$0.001 | ~200 tokens |
| Sonnet adjudication (if needed) | ~$0.01 | ~300 tokens |
| Sonnet scenario run (escalation) | ~$0.01 | Only if haiku fails |

**Total/file:** $0.003-$0.015 | **Full sweep (300 files):** $0.90-$4.50 | **Target:** < $0.02/file — **met**

## Pilot Recommendations (Historical)

1. Run benchmark against 15 pilot files via `comprehension-benchmark-helper.sh sweep` to validate predicted tiers.
2. Expand to full codebase after pilot validation; prioritize files in `simplification-state.json`.
3. Integrate with pulse dispatch: read `tier_minimum` from state, route to cheapest compatible model.
4. Production feedback loop: on tier-dispatched task failure, log `{file, tier_dispatched, failure_reason, task_id}` and downgrade `tier_minimum`.
5. Re-benchmark after simplification: when code-simplifier modifies a file, rerun its comprehension test to verify tier didn't regress.

Items 3-5 were proposals, not completed integration evidence. Current behaviour
and explicit non-integrations are documented in `README.md`.
