<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent — Multi-Trial Evaluation

Sub-doc for `autoagent.md`. Loaded during Step 2 (Loop) for metric measurement.

## Multi-Trial Evaluation

Single-trial measurements are noisy. Use the program's `## Evaluation` contract
for statistically reliable keep/discard decisions.

```text
results = run METRIC_CMD in CANDIDATE_PATH exactly TRIALS_PER_HYPOTHESIS times
if any trial times out, exits non-zero, or does not emit exactly one number: ERROR

improved = count(score improves on BEST_METRIC in METRIC_DIR)
required = TRIALS_PER_HYPOTHESIS when REQUIRED_IMPROVEMENTS == "all"
required = floor(TRIALS_PER_HYPOTHESIS / 2) + 1 otherwise
median_score = median(results)
passed = improved >= required and median_score improves on BEST_METRIC

return results, median_score, improved, required, passed
```

**Statistical rules:**
- **Trials:** use the validated positive integer from `## Evaluation`
- **Keep threshold:** enforce `required_improvements` and require an improved median
- **Tie-breaking:** median equals `BEST_METRIC` → discard (no improvement = not worth keeping)
- **Error handling:** any trial error checkpoints and removes only the owned candidate
- **Why median:** robust against outlier runs (cold cache, background load)

---

## Trajectory Recording

Every hypothesis attempt is recorded in
`WORKTREE_PATH/todo/research/{PROGRAM_NAME}-trajectory.jsonl` (JSONL,
append-only). The runner commits this exact owned path with the matching results and
checkpoint state after every keep, discard, constraint failure, or crash.

### Record Format

```json
{
  "iteration": 5,
  "hypothesis": "Consolidate file discovery rules in .agents/reference/error-prevention.md",
  "hypothesis_type": "instruction_refinement",
  "files_modified": [".agents/reference/error-prevention.md"],
  "diff_summary": "+3/-7 lines",
  "trials": [
    {"trial": 1, "score": 0.87, "sub_scores": {"pass_rate": 0.90, "token_ratio": 0.82}},
    {"trial": 2, "score": 0.85, "sub_scores": {"pass_rate": 0.88, "token_ratio": 0.80}}
  ],
  "median_score": 0.86,
  "baseline": 0.83,
  "delta": 0.03,
  "decision": "keep",
  "constraint_result": "pass",
  "regression_check": "pass",
  "instruction_review": {
    "status": "pass",
    "provenance": ["task/issue/PR and file-history evidence"],
    "context_stack": ["canonical source", "runtime adapter"],
    "verification": ["target-specific activation and exclusion scenarios"]
  },
  "timestamp": "2026-04-03T15:00:00Z",
  "tokens_used": 2340
}
```

```bash
record_trajectory() {
    local iteration="$1" hypothesis="$2" median_score="$3"
    local decision="$4" hypothesis_type="$5" files_modified="$6"
    local trajectory_file="$WORKTREE_PATH/todo/research/${PROGRAM_NAME}-trajectory.jsonl"
    mkdir -p "$(dirname "$trajectory_file")"
    jq -n \
      --argjson iter "$iteration" --arg hyp "$hypothesis" \
      --arg hyp_type "$hypothesis_type" --argjson files "$files_modified" \
      --argjson score "$median_score" --argjson baseline "$BASELINE" \
      --arg decision "$decision" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{iteration:$iter,hypothesis:$hyp,hypothesis_type:$hyp_type,
        files_modified:$files,median_score:$score,baseline:$baseline,
        delta:($score-$baseline),decision:$decision,timestamp:$ts}' \
      >> "$trajectory_file"
    return 0
}
```

---

## Failure Analysis

### Failure Categories

| Category | Condition | Action |
|----------|-----------|--------|
| `constraint_fail` | Constraint shell command exits non-zero | Log which constraint failed; avoid similar changes |
| `metric_regression` | Metric worse than `BEST_METRIC` | Log delta; note what made it worse |
| `metric_neutral` | Metric equals `BEST_METRIC` | Log as neutral; try a different approach |
| `crash` | Metric command errors | Log error; check if modification broke the metric command itself |
| `safety_skip` | Elevated-only file under standard safety | Log as skipped; not a failure |
| `provenance_fail` | Instruction provenance, delivery, classification, or target-specific evidence is incomplete | Preserve the directive; do not evaluate the metric |

After 3+ consecutive discards of the same type:

```text
if consecutive_discards >= 3:
    if all_same_type:   switch to next hypothesis type in progression
    if all_same_file:   skip that file for next 5 iterations
    if all_constraint_fail: review constraint list — may be too strict
```

Failed hypotheses narrow the search space. Analyze patterns post-session:

```bash
# Most common failure types
jq -r 'select(.decision == "discard") | .hypothesis_type' \
    "todo/research/${PROGRAM_NAME}-trajectory.jsonl" | sort | uniq -c | sort -rn

# Files most often in discarded hypotheses
jq -r 'select(.decision == "discard") | .files_modified[]' \
    "todo/research/${PROGRAM_NAME}-trajectory.jsonl" | sort | uniq -c | sort -rn
```

---

## Metric Command Integration

```bash
# Standard invocation — returns composite score as float on last line of stdout
autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json

# With JSON sub-scores
METRIC_JSON=$(autoagent-metric-helper.sh compare --suite .agents/tests/agents-md-knowledge.json)
COMPOSITE=$(jq '.composite_score' <<<"$METRIC_JSON")
PASS_RATE=$(jq '.sub_scores.comprehension' <<<"$METRIC_JSON")
TOKEN_RATIO=$(jq '.sub_scores.token_cost_ratio' <<<"$METRIC_JSON")
```

**Composite score formula:**
`wc * comprehension + wl * lint + wt * clamp(2 - token_ratio, 0, 1)`

For instruction-semantic candidates, this metric is evaluated only after the
preservation gate in `autoagent/safety.md` passes. It ranks already-safe candidates;
it cannot establish that a directive was redundant or unneeded.

- `comprehension`: fraction of suite tests passing (0–1)
- `token_ratio`: `avg_response_chars / baseline_chars`; ratios at or below 1 earn
  full token weight, while ratios at or above 2 earn zero token weight
- Direction: `higher` is better

---

## Budget Enforcement

| Condition | Check | Action |
|-----------|-------|--------|
| Wall-clock timeout | `elapsed >= TIMEOUT` | Break loop, proceed to completion |
| Max iterations | `ITERATION_COUNT >= MAX_ITER` | Break loop, proceed to completion |
| Goal reached | `goal_met(BEST_METRIC, GOAL, METRIC_DIR)` | Break loop, proceed to completion |
| Per-experiment timeout | `timeout PER_EXPERIMENT cmd` | Checkpoint candidate, treat as crash, continue |
| All hypothesis types exhausted | No new hypotheses possible | Break loop, proceed to completion |
