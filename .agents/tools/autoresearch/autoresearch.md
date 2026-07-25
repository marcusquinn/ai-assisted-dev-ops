---
description: Autonomous experiment loop runner — reads a research program, generates hypotheses, modifies code, measures results, and keeps only improvements
mode: subagent
model: standard
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoresearch Subagent

Runs setup → hypothesis → modify → constrain → measure → keep/discard → log → repeat until budget exhausted or goal reached.

User-facing command: `/auto-research`. `/autoresearch` remains a compatibility
alias for existing tasks and memories. Use `/deep-research` for cited,
deliverable-oriented research reports that do not modify code or optimize a
metric.

Arguments: `--program <path>` (required)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Command**: `/auto-research` (`/autoresearch` compatibility alias)
- **Program format**: `.agents/templates/research-program-template.md`
- **Results file**: `todo/research/{name}-results.tsv`
- **Worktree**: `experiment/{name}` (created at session start)
- **State**: git HEAD of experiment branch = current best; results.tsv = full history
- **Resume**: re-run with same `--program` — reads results.tsv to reconstruct state
- **Mailbox**: `mail-helper.sh` — inter-agent discovery sharing (multi-dimension mode)
- **Memory**: `aidevops-memory` — cross-session finding persistence
- **Concurrency modes**: `sequential` (default) · `population` (N hypotheses/iteration) · `multi-dimension` (parallel agents per dimension)
- **Sub-docs**: `autoresearch/loop.md` · `autoresearch/logging.md` · `autoresearch/completion.md` · `autoresearch/agent-optimization.md`

<!-- AI-CONTEXT-END -->

## Step 0: Parse Arguments

Extract `--program <path>`; exit with error if missing or file not found. Extract variables:

| Variable | Source |
|----------|--------|
| `PROGRAM_NAME` | frontmatter `name` |
| `MODE` | frontmatter `mode` (`in-repo` \| `cross-repo` \| `standalone`) |
| `TARGET_REPO` | frontmatter `target_repo` (path or `"."`) |
| `DIMENSION` | frontmatter `dimension` (optional, multi-dimension campaigns) |
| `CAMPAIGN_ID` | frontmatter `campaign_id` (optional, multi-dimension campaigns) |
| `FILES` | `## Target` section, `files:` line |
| `BRANCH` | `## Target` section, `branch:` line (default: `experiment/{name}`) |
| `METRIC_CMD` | `## Metric` section, `command:` line |
| `METRIC_NAME` | `## Metric` section, `name:` line |
| `METRIC_DIR` | `## Metric` section, `direction:` line (`lower` \| `higher`) |
| `BASELINE` | `## Metric` section, `baseline:` line (`null` = not yet measured) |
| `GOAL` | `## Metric` section, `goal:` line (`null` = no goal) |
| `CONSTRAINTS` | `## Constraints` section, each bullet as a shell command |
| `RESEARCHER` | `## Models` section, `researcher:` line |
| `EVALUATOR` | `## Models` section, `evaluator:` line (optional) |
| `TARGET_MODEL` | `## Models` section, `target:` line (optional) |
| `TIMEOUT` | `## Budget` section, `timeout:` line (seconds) |
| `MAX_ITER` | `## Budget` section, `max_iterations:` line |
| `PER_EXPERIMENT` | `## Budget` section, `per_experiment:` line |
| `TRIALS` | `## Budget` section, `trials:` line (default: 1) |
| `HINTS` | `## Hints` section, all bullet lines |
| `CONCURRENCY_MODE` | `## Concurrency` section, `mode:` line (default: `sequential`) |
| `POPULATION_SIZE` | `## Concurrency` section, `population_size:` line (default: 4) |
| `CONVOY_ID` | `## Concurrency` section, `convoy_id:` line (`null` = auto-generate) |
| `DIMENSIONS` | `## Dimensions` section, parsed list of `{name, files, metric}` objects |

`RESEARCHER` and optional `EVALUATOR` are provider-agnostic workload tiers and
accept only `simple`, `standard`, or `thinking`; runtime configuration owns their
concrete model mappings. `TARGET_MODEL` defaults to one of the same tiers. A
concrete provider/model identifier is permitted only for an explicitly declared
model benchmark that records model/version provenance and compares equivalent
workloads within a tier.

Any candidate that changes instruction semantics must load
`.agents/tools/build-agent/agent-review.md` and satisfy the preservation gate in
`autoresearch/agent-optimization.md`, regardless of program name or metric command.

## Step 1: Setup

**1.1 Resolve target repo:** `REPO_ROOT = cwd` if `MODE == "in-repo"` or `TARGET_REPO == "."`, else expand `TARGET_REPO` and verify it's a git repo.

**1.2 Create or resume experiment worktree:**

```bash
WORKTREE_PATH="$REPO_ROOT/../$(basename $REPO_ROOT)-$BRANCH"  # replace / with - in branch name
if worktree exists: cd WORKTREE_PATH && git reset --hard HEAD; RESUMING=true
else: git -C REPO_ROOT worktree add WORKTREE_PATH -b BRANCH; RESUMING=false
```

**1.3 Load prior results (resume mode):**

```text
RESULTS_FILE = "$REPO_ROOT/todo/research/{name}-results.tsv"
if RESUMING and RESULTS_FILE exists:
    ITERATION_COUNT = data rows (excl. header)
    BEST_METRIC     = best metric_value (per direction)
    BASELINE        = metric_value where status == "baseline"
    FAILED_HYPOTHESES = hypothesis list where status == "discard"
    TOTAL_TOKENS    = sum of tokens_used column
    Log: "Resuming from iteration N, best metric: X"
else:
    ITERATION_COUNT=0; BEST_METRIC=null; BASELINE=null; FAILED_HYPOTHESES=[]; TOTAL_TOKENS=0
    mkdir -p $(dirname RESULTS_FILE)
    Write TSV header: iteration\tcommit\tmetric_name\tmetric_value\tbaseline\tdelta\tstatus\thypothesis\ttimestamp\ttokens_used\tpass_rate\ttoken_ratio\ttrials\ttrial_variance
```

**1.4 Recall cross-session memory:** `aidevops-memory recall "autoresearch $PROGRAM_NAME" --limit 10` → store as MEMORY_CONTEXT.

**1.5 Mailbox setup:**

```text
if CONVOY_ID == null and CONCURRENCY_MODE != "sequential":
    CONVOY_ID = "autoresearch-${PROGRAM_NAME}-$(date +%Y%m%d-%H%M%S)"

AGENT_ID = "autoresearch-${PROGRAM_NAME}-${DIMENSION:-solo}"

if CONCURRENCY_MODE == "multi-dimension":
    mail-helper.sh register --agent "$AGENT_ID" --role worker --worktree "$WORKTREE_PATH"
    mail-helper.sh check --agent "$AGENT_ID" --unread-only  # initial peer discovery check
```

Graceful degradation: when no concurrent peers exist, mailbox calls return empty results and are treated as no-ops. Never error on empty mailbox.

**1.6 Measure baseline (first run only):** If `BASELINE == null`: run all constraints (fail → exit); run METRIC_CMD → `BASELINE = BEST_METRIC`; update program file `baseline: {value}`; append baseline row to results.tsv.

## Step 2: Experiment Loop

See `autoresearch/loop.md` for full loop pseudocode, instruction-semantic review,
hypothesis generation rules, constraint checking, metric measurement, improvement
check, and token estimation.

Loop exits when any budget condition is met (timeout / max_iterations / goal_reached).

**Mailbox integration within the loop** (multi-dimension mode):

Before each hypothesis generation:

```bash
mail-helper.sh check --agent "$AGENT_ID" --unread-only
# Incorporate peer discoveries into hypothesis generation context
```

After each keep/discard decision:

```bash
mail-helper.sh send \
  --to "broadcast" \
  --type discovery \
  --convoy "$CONVOY_ID" \
  --payload "$(cat <<EOF
{
  "campaign": "$CONVOY_ID",
  "dimension": "${DIMENSION:-solo}",
  "hypothesis": "$HYPOTHESIS",
  "status": "$STATUS",
  "metric_name": "$METRIC_NAME",
  "metric_before": $PREV_BEST,
  "metric_after": $CURRENT_VALUE,
  "metric_delta": $DELTA,
  "files_changed": $FILES_CHANGED_JSON,
  "iteration": $ITERATION_COUNT,
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)"
```

Graceful degradation: skip mailbox send/check calls when `CONCURRENCY_MODE == "sequential"` or when no peers are registered. Never block the loop on mailbox errors.

## Population-Based Mode

When `CONCURRENCY_MODE == "population"`, replace the single-hypothesis loop with:

```text
Iteration K:
  1. Generate POPULATION_SIZE hypotheses from current best state
  2. For each hypothesis H in parallel (background bash jobs):
     a. Fork experiment worktree → temp copy at experiment/{name}-pop-{K}-{i}
     b. Apply hypothesis H to temp worktree
     c. Run all constraints — skip to step 3 if any fail
     d. Run METRIC_CMD → record result
  3. Compare all results:
     - Best result (per METRIC_DIR) → commit to experiment branch, update BEST_METRIC
     - All others → discard temp worktrees (git worktree remove --force)
  4. Log all POPULATION_SIZE results to results.tsv
     (winner: status=keep, others: status=discard-pop)
  5. Continue to next iteration
```

Trade-offs: N× measurement cost per iteration (parallel, same wall-clock), N× hypothesis generation tokens. Benefit: N× exploration per iteration, faster convergence on complex search spaces.

## Multi-Dimension Mode

When `CONCURRENCY_MODE == "multi-dimension"`, the orchestrator (command doc) dispatches this subagent once per dimension. Each instance:

- Receives its own sub-program with `dimension:` and `campaign_id:` in frontmatter
- Creates its own worktree: `experiment/{campaign_id}-{dimension}`
- Targets only its dimension's `files:` (non-overlapping enforced at dispatch)
- Shares discoveries via mailbox under the shared `CONVOY_ID`

Non-overlapping file enforcement: if two dimensions claim overlapping file targets, the orchestrator errors before dispatch. This subagent trusts that its file set is exclusive.

## Discovery Payload Schema

All mailbox discovery messages use this JSON schema:

```json
{
  "campaign": "autoresearch-widget-2026-04-01",
  "dimension": "build-perf",
  "hypothesis": "removed lodash, replaced with native Array methods",
  "status": "keep",
  "metric_name": "build_time_s",
  "metric_before": 12.4,
  "metric_after": 11.1,
  "metric_delta": -1.3,
  "files_changed": ["src/utils/index.ts", "package.json"],
  "iteration": 5,
  "timestamp": "2026-04-01T10:48:00Z"
}
```

Fields:

| Field | Type | Description |
|-------|------|-------------|
| `campaign` | string | Convoy ID grouping all messages from this research run |
| `dimension` | string | Dimension name, or `"solo"` for non-multi-dimension runs |
| `hypothesis` | string | Human-readable description of the change attempted |
| `status` | `"keep"` \| `"discard"` \| `"discard-pop"` \| `"constraint_fail"` \| `"crash"` | Outcome |
| `metric_name` | string | Metric name from program `## Metric` section |
| `metric_before` | number | Best metric value before this experiment |
| `metric_after` | number | Measured metric value after this experiment |
| `metric_delta` | number | `metric_after - metric_before` (negative = improvement for `lower`) |
| `files_changed` | string[] | Relative paths of files modified in this experiment |
| `iteration` | integer | Iteration number within this dimension's loop |
| `timestamp` | ISO 8601 | UTC timestamp of the keep/discard decision |

## Step 3: Completion

**3.1 Mailbox deregister** (multi-dimension mode):

```bash
if CONCURRENCY_MODE == "multi-dimension":
    mail-helper.sh deregister --agent "$AGENT_ID"
```

See `autoresearch/completion.md` for final memory, completion summary,
cross-dimension summary, PR creation, crash recovery, and budget enforcement table.

## Logging, Memory & Mailbox

See `autoresearch/logging.md` for results TSV schema, memory storage commands,
and mailbox discovery integration (multi-dimension campaigns).

## Agent Optimization Domain

When a candidate changes instruction semantics, or when `PROGRAM_NAME ==
"agent-optimization"` or `METRIC_CMD` contains `agent-test-helper.sh`, load
`autoresearch/agent-optimization.md` for the preservation gate, composite metric
parsing, security exemptions, simplification state integration, and hypothesis
type ordering.

## Related

`.agents/templates/research-program-template.md` · `.agents/scripts/commands/autoresearch.md` · `.agents/scripts/commands/deep-research.md` · `todo/research/` · `todo/research/agent-optimization.md`
