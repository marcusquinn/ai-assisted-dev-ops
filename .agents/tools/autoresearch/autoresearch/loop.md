<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoresearch — Experiment Loop

Sub-doc for `autoresearch.md`. Loaded on demand during Step 2.

---

## Loop Pseudocode

```text
SESSION_START = current time

while true:
    elapsed = now - SESSION_START
    if elapsed >= TIMEOUT: break with reason "timeout"
    if ITERATION_COUNT >= MAX_ITER: break with reason "max_iterations"
    if GOAL is set and goal_met(BEST_METRIC, GOAL, METRIC_DIR): break with reason "goal_reached"

    ITERATION_COUNT += 1
    ITER_START_TOKENS = current_token_estimate()
    Log: "--- Iteration {ITERATION_COUNT} ---"

    if CAMPAIGN_ID is set:
        peer_discoveries = check_peer_discoveries()

    hypothesis = generate_hypothesis(...)
    instruction_review = prepare_instruction_review(hypothesis)
    if instruction_review == INCOMPLETE:
        FAILED_HYPOTHESES.append(hypothesis)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "provenance_fail", hypothesis, ITER_TOKENS, 0, "-")
        continue
    apply_modification(hypothesis)

    semantic_result = verify_instruction_semantic_preservation(instruction_review)
    if semantic_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "provenance_fail", hypothesis, ITER_TOKENS, 0, "-")
        continue

    constraint_result = run_constraints()
    if constraint_result == FAIL:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS, 0, "-")
        continue

    if TRIALS > 1:
        (metric_result, variance, trial_results) = multi_trial_evaluate(METRIC_CMD, TRIALS, PER_EXPERIMENT)
    else:
        metric_result = run_metric()
        variance = 0
        trial_results = [metric_result]

    if metric_result == ERROR:
        git -C WORKTREE_PATH reset --hard HEAD
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS, 0, "-")
        continue

    track_tokens(ITER_START_TOKENS)

    if is_improvement(metric_result, BEST_METRIC, METRIC_DIR):
        # Multi-trial consistency check: median improved but require majority of trials to improve
        if TRIALS > 1:
            improvement_count = count(r for r in trial_results if is_improvement(r, BEST_METRIC, METRIC_DIR))
            if improvement_count <= TRIALS / 2:
                # Median improved but not consistently — treat as noise
                git -C WORKTREE_PATH reset --hard HEAD
                FAILED_HYPOTHESES.append(hypothesis)
                log_result(ITERATION_COUNT, null, metric_result, "discard_inconsistent", hypothesis, ITER_TOKENS, TRIALS, variance)
                store_memory(hypothesis, metric_result, "discard_inconsistent")
                send_discovery(hypothesis, metric_result, "discard_inconsistent", null)
                continue

        git -C WORKTREE_PATH add -A
        git -C WORKTREE_PATH commit -m "experiment: {hypothesis[:60]} ({METRIC_NAME}: {metric_result})"
        HEAD_SHA = git -C WORKTREE_PATH rev-parse --short HEAD
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis, ITER_TOKENS, TRIALS, variance)
        store_memory(hypothesis, metric_result, "keep")
        send_discovery(hypothesis, metric_result, "keep", HEAD_SHA)
    else:
        git -C WORKTREE_PATH reset --hard HEAD
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis, ITER_TOKENS, TRIALS, variance)
        store_memory(hypothesis, metric_result, "discard")
        send_discovery(hypothesis, metric_result, "discard", null)

# track_tokens helper (called above):
#   ITER_TOKENS = current_token_estimate() - ITER_START_TOKENS
#   TOTAL_TOKENS += ITER_TOKENS
```

---

## Hypothesis Generation

### Input context (provide all of these)

1. **Program hints** — from `## Hints` section
2. **Memory context** — recalled findings from prior sessions
3. **Peer discoveries** — from mailbox (multi-dimension mode only)
4. **Failed hypotheses** — what was tried and discarded this session
5. **Current best** — metric value and which commit achieved it
6. **Current code state** — read the target files (FILES glob)
7. **Iteration number** — to guide progression strategy
8. **Agent Review context** — for instruction-semantic candidates, the assembled
   delivery stack, provenance, classification, boundaries, and target-specific
   behaviour required by `.agents/tools/build-agent/agent-review.md`

### Progression strategy

| Phase | Iterations | Strategy |
|-------|-----------|---------|
| **Low-hanging fruit** | 1–5 | Apply hints directly; obvious improvements from code reading |
| **Systematic** | 6–20 | Vary one parameter at a time; measure effect of each change |
| **Combination** | 21–35 | Combine two individually-successful changes |
| **Radical** | 36–45 | Try fundamentally different approaches if incremental gains stall |
| **Simplification** | 46+ | Reduce mechanics or context only after applicable preservation gates pass |

### Rules

- Never repeat a discarded hypothesis (check FAILED_HYPOTHESES)
- Prefer high-impact changes with low constraint-failure risk
- Agent optimization: prefer relevant information density after proving retained
  semantics, delivery, and target-specific behaviour
- Build optimization: structural changes (tree-shaking, module boundaries) > config tweaks
- Simplification is a hypothesis, not proof: aggregate metrics cannot override an
  incomplete instruction-semantic review

---

## Helpers

**Constraint check:**

```bash
timeout PER_EXPERIMENT bash -c "{constraint_command}"
# exit_code != 0 → return FAIL; all constraints must pass (first failure short-circuits)
```

**Metric measurement (single trial):**

```bash
timeout PER_EXPERIMENT bash -c "{METRIC_CMD}" 2>/dev/null
# Parse last non-empty stdout line as float. Parsing failure or non-zero exit → ERROR.
```

**Multi-trial evaluation (when TRIALS > 1):**

```text
multi_trial_evaluate(metric_cmd, n_trials, per_experiment_timeout):
    results = []
    for i in 1..n_trials:
        result = timeout per_experiment_timeout bash -c "{metric_cmd}" 2>/dev/null
        # Parse last non-empty stdout line as float
        if parse_error or non_zero_exit:
            return ERROR  # Any trial failure = overall failure (infrastructure problem, not noise)
        results.append(parsed_float)

    # Sort and take median (robust to outliers)
    sorted_results = sort(results)
    if n_trials is odd:
        median = sorted_results[n_trials / 2]
    else:
        median = (sorted_results[n_trials/2 - 1] + sorted_results[n_trials/2]) / 2

    variance = max(results) - min(results)  # range as variance proxy
    return (median, variance, results)
```

**Improvement check:**

```text
is_improvement(new, best, dir):
    if best == null: return true   # first measurement always keeps
    return new < best if dir=="lower" else new > best
```

**Token estimation:** Use API response token counts if available; otherwise estimate from character count (~4 chars/token).
