<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoresearch — Agent Optimization Domain

Sub-doc for `autoresearch.md`. Load when `PROGRAM_NAME == "agent-optimization"` or `METRIC_CMD` contains `agent-test-helper.sh`.

---

## Instruction-Semantic Preservation Gate

Before evaluating any hypothesis that removes, consolidates, relocates, weakens,
or materially rephrases instructions, load
`.agents/tools/build-agent/agent-review.md` and complete its canonical review flow.
The review record must recover directive provenance, inspect the assembled context
stack, classify affected directives, define activation/exclusion boundaries,
distinguish exact duplication from boundary reinforcement, and name the delivery
mechanism plus target-specific behavioural scenarios that preserve the lesson.

Verify the exact candidate diff and every changed delivery route against that
record before running the metric. Incomplete provenance, delivery, or behavioural
evidence defaults to preservation: record `provenance_fail`, discard the candidate,
and do not interpret aggregate test stability or token reduction. Semantically
neutral formatting is exempt only when the diff demonstrably changes no directive
or delivery route.

---

## Security Instruction Exemptions

Discard any hypothesis that removes or weakens the following — do not test:

| Category | Detection pattern |
|----------|------------------|
| Credential/secret handling | `credentials`, `NEVER expose`, `gopass`, `secret` |
| File operation safety | `Read before Edit`, `pre-edit-check`, `verify path` |
| Git safety | `pre-edit-check.sh`, `never edit on main`, `worktree` |
| Traceability | `PR title MUST`, `task ID`, `Closes #` |
| Prompt injection | `prompt injection`, `adversarial`, `scan` |
| Destructive operations | `destructive`, `confirm before`, `irreversible` |

Enforced by both the research program constraint list and the researcher model.
These are unconditional hard stops within the broader semantic-preservation gate,
not the complete set of directives that deserve protection. Both layers must hold.

---

## Composite Metric Parsing

```bash
METRIC_JSON=$(eval "$METRIC_CMD")
COMPOSITE_SCORE=$(echo "$METRIC_JSON" | jq '.composite_score')
PASS_RATE=$(echo "$METRIC_JSON" | jq '.pass_rate')
TOKEN_RATIO=$(echo "$METRIC_JSON" | jq '.token_ratio')
```

Use `COMPOSITE_SCORE` as the primary metric for keep/discard decisions only after
the instruction-semantic preservation gate passes.
Log `PASS_RATE` and `TOKEN_RATIO` as supplementary columns in results.tsv.

**Formula**: `composite_score = pass_rate * (1 - 0.3 * token_ratio)` (higher = better)

- `pass_rate`: fraction of tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars` — proxy for token usage

---

## Baseline Setup

On first run (`BASELINE == null`), establish baseline before measuring:

```bash
agent-test-helper.sh baseline .agents/tests/agent-optimization.test.json
```

Sets `baseline_chars` for `token_ratio` computation. Without this, `token_ratio` defaults to 1.0.

---

## Simplification State Integration

Before generating hypotheses, skip unchanged files:

```bash
TARGET_FILE=".agents/build-plus.md"
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
STORED_HASH=$(jq -r --arg f "$TARGET_FILE" '.files[$f].hash // empty' \
    .agents/configs/simplification-state.json 2>/dev/null)
[[ "$CURRENT_HASH" == "$STORED_HASH" ]] && log "File unchanged. Skipping."
```

After a successful session (`composite_score` improved vs baseline), update the hash:

```bash
CURRENT_HASH=$(md5sum "$TARGET_FILE" | awk '{print $1}')
jq --arg file "$TARGET_FILE" \
   --arg hash "$CURRENT_HASH" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.files[$file] = ((.files[$file] // {}) + {"hash": $hash, "at": $ts, "pr": null})' \
   .agents/configs/simplification-state.json > /tmp/ss.json && \
   mv /tmp/ss.json .agents/configs/simplification-state.json
```

---

## Agent Optimization Hypothesis Types

| Phase | Hypothesis type | Example |
|-------|----------------|---------|
| 1–5 | Recover provenance and conflicts | Identify which history, owner, and decision boundary an apparent duplicate protects |
| 6–15 | Tighten proven repetition | Merge only exact duplicates with equivalent activation, semantics, owner, and delivery |
| 16–25 | Clarify phrasing and boundaries | Shorten wording while preserving every actionable clause and interface |
| 26–35 | Relocate triggered detail | Replace inline rationale with a pointer whose trigger reaches the same decision point |
| 36–45 | Add deterministic enforcement | Move mechanics behind a verified hook or validator while retaining the invariant until delivery is proven |
| 46+ | Evidence-backed simplification | Reduce context only when provenance and target-specific activation/exclusion scenarios pass |

The metric ranks candidates that have already passed these gates. A rule's absence
from broad tests proves a coverage gap, not that the rule is low value.
