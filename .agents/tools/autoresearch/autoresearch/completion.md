<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoresearch — Completion, Crash Recovery & Budget

Sub-doc for `autoresearch.md`. Loaded on demand during Step 3.

## Step 3: Completion

**3.1 Deregister** (multi-dimension — if `CAMPAIGN_ID` set):

```bash
mail-helper.sh deregister --agent "$AGENT_ID"
```

**3.2 Store final memory:**

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} complete: {kept_count} kept, {discarded_count} discarded, {improvement_pct:.1f}% improvement in {METRIC_NAME}. Top finding: {top_hypothesis}" \
  --confidence high
```

**3.3 Generate completion summary** (use as PR body; append ASCII sparkline if ≥5 kept iterations):

```markdown
## Autoresearch Results: {PROGRAM_NAME}

**Research:** {PROGRAM_NAME}
**Duration:** {elapsed_human} ({ITERATION_COUNT} iterations)
**Baseline → Best:** {BASELINE} → {BEST_METRIC} ({improvement_pct:+.1f}%)
**Exit reason:** {timeout | max_iterations | goal_reached}

### Experiment Outcomes

| Status | Count |
|--------|-------|
| Kept | {kept_count} |
| Discarded | {discarded_count} |
| Constraint failures | {constraint_fail_count} |
| Crashes | {crash_count} |

### Key Findings

{For each kept hypothesis, sorted by delta (best first):}
{N}. **{hypothesis}**: {METRIC_NAME} {metric_before} → {metric_after} ({delta:+.2f}, {improvement_pct:.1f}%)

### Failed Approaches

{For top 3-5 discarded hypotheses:}
- {hypothesis}: {METRIC_NAME} = {metric_value} (delta={delta:+.2f})

### Token Usage

- Total: ~{TOTAL_TOKENS:,} tokens across {ITERATION_COUNT} iterations
- Average per iteration: ~{avg_tokens:,} tokens
- Cost estimate: ~${cost_estimate:.2f} (configured researcher-model pricing)
```

Sparkline (if ≥5 kept iterations):

```text
{METRIC_NAME} progression ({direction}):
{sparkline of metric_value for kept rows, 40 chars wide}
  iter: {first_kept}  →  {last_kept}
```

**3.4 Cross-dimension summary** (if `CAMPAIGN_ID` set — append to PR body):

```bash
sqlite3 ~/.aidevops/.agent-workspace/mail/mailbox.db \
  "SELECT from_agent, payload FROM messages
   WHERE convoy='{CAMPAIGN_ID}' AND type='discovery' AND json_extract(payload,'$.status')='keep'
   ORDER BY created_at"
```

```markdown
### Cross-Dimension Summary

| Dimension | Baseline | Best | Delta | Improvement | Iterations |
|-----------|----------|------|-------|-------------|------------|
| {dimension} | {baseline} | {best} | {delta:+.2f} | {improvement_pct:.1f}% | {iteration_count} |

### Cross-Pollination

- {source_dimension} found "{hypothesis}" → {target_dimension} adopted (iteration {N})
- (or: Dimensions ran independently — no cross-pollination detected)
```

**3.5 Create PR:**

```bash
git -C WORKTREE_PATH push -u origin BRANCH

gh pr create \
  --repo {REPO_SLUG} \
  --head BRANCH \
  --base main \
  --title "experiment({PROGRAM_NAME}): {improvement_pct:+.1f}% improvement in {METRIC_NAME}" \
  --body "$(generate_completion_summary)

Resolves #{issue_number_if_any}"
```

**3.6 Store PR memory:**

```text
aidevops-memory store \
  "autoresearch {PROGRAM_NAME} PR created: {pr_url}. Best: {METRIC_NAME}={BEST_METRIC}. Key finding: {top_hypothesis}" \
  --confidence high
```

## Crash Recovery

Worktree, results.tsv, and branch HEAD persist across crashes. On resume, uncommitted changes are discarded via `git reset --hard HEAD`.

Resume: re-run `/auto-research --program {program_path}`. The `/autoresearch`
compatibility alias is also accepted. The subagent detects the existing worktree
and results.tsv and continues from where it left off.

## Budget Enforcement

| Condition | Check | Action |
|-----------|-------|--------|
| Wall-clock timeout | `elapsed >= TIMEOUT` | Break loop, proceed to completion |
| Max iterations | `ITERATION_COUNT >= MAX_ITER` | Break loop, proceed to completion |
| Goal reached | `goal_met(BEST_METRIC, GOAL)` | Break loop, proceed to completion |
| Per-experiment timeout | `timeout PER_EXPERIMENT cmd` | Treat as crash, revert, continue |
