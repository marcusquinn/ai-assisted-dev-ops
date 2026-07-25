---
description: Autonomous framework self-improvement loop — mines signals, generates hypotheses, modifies framework files, measures improvement, keeps only what helps
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

# Autoagent Subagent

Runs signal-mining → hypothesis generation → modification → multi-trial evaluation → keep/discard → log → repeat until budget exhausted or goal reached.

Arguments: `--program <path>` (required)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Program format**: `.agents/templates/autoagent-program-template.md`
- **Source program**: reviewed input path supplied by `--program`
- **Owned program**: `WORKTREE_PATH/todo/research/autoagent-{name}.md`
- **Results file**: `WORKTREE_PATH/todo/research/{name}-results.tsv`
- **Worktree**: managed, owned worktree under `AIDEVOPS_WORKTREE_BASE_DIR`
- **State**: experiment branch contains code plus committed program/results/history
- **Resume**: normally requires clean; narrowly recover valid runner-owned state dirt
- **Memory**: `aidevops-memory` — cross-session finding persistence
- **Metric command**: `autoagent-metric-helper.sh` — composite score for framework quality
- **Sub-docs**: `autoagent/signal-mining.md` · `autoagent/hypothesis-types.md` · `autoagent/safety.md` · `autoagent/evaluation.md`

<!-- AI-CONTEXT-END -->

## Step 0: Parse Arguments

Extract `--program <path>` as `SOURCE_PROGRAM`, resolve it to a readable regular file,
and read/review its complete contents before any worktree or ref side effect. Exit if
it is missing or invalid. Record `SOURCE_PROGRAM_SHA256` after review and require the
same digest immediately before copying. Parse only the named sections below; comments
and similarly named fields in examples do not count.

| Variable | Source |
|----------|--------|
| `PROGRAM_NAME` | frontmatter `name` |
| `MODE` | frontmatter `mode` (`in-repo` \| `cross-repo` \| `standalone`) |
| `TARGET_REPO` | frontmatter `target_repo` (path or `"."`) |
| `FILES` | `## Target` section, `files:` line |
| `BRANCH` | `## Target` section, `branch:` line (default: `experiment/{name}`) |
| `METRIC_CMD` | `## Metric` section, `command:` line |
| `METRIC_NAME` | `## Metric` section, `name:` line |
| `METRIC_DIR` | `## Metric` section, `direction:` line (`lower` \| `higher`) |
| `BASELINE` | `## Metric` section, `baseline:` line (`null` = not yet measured) |
| `GOAL` | `## Metric` section, `goal:` line (`null` = no goal) |
| `CONSTRAINTS` | shell command from each `## Constraints` bullet's inline-code span |
| `SIGNAL_SOURCES` | enabled boolean keys in `## Signal Sources` |
| `HYPOTHESIS_TYPES` | enabled boolean keys in `## Hypothesis Types` |
| `SAFETY_LEVEL` | `## Safety` section, `level:` line (`standard` \| `elevated`) |
| `NEVER_MODIFY` | `## Safety` section, `never_modify:` array |
| `REQUIRE_REVIEW` | `## Safety` section, `require_review:` array |
| `TRIALS_PER_HYPOTHESIS` | `## Evaluation` section, `trials:` positive integer |
| `REQUIRED_IMPROVEMENTS` | `## Evaluation` section, `required_improvements:` (`majority` \| `all`) |
| `TIMEOUT` | `## Budget` section, `timeout:` line (seconds) |
| `MAX_ITER` | `## Budget` section, `max_iterations:` line |
| `PER_EXPERIMENT` | `## Budget` section, `per_experiment:` line |
| `HINTS` | `## Hints` section, all bullet lines |

### Required validation

Fail closed before setup or command execution when any required field is missing,
duplicated, empty, or malformed. Required fields are `name`, `mode`, `target_repo`,
`files`, `constraints`, all signal-source and hypothesis-type booleans, `level`,
`never_modify`, `require_review`, `command`, `name`, `direction`, `researcher`,
`trials`, `required_improvements`, `timeout`, and `max_iterations`.

- Require each signal key exactly once: `session_miner`, `comprehension`, `linters`,
  `git_churn`, and `pulse_outcomes`. Require each hypothesis key exactly once:
  `self_healing`, `tool_optimization`, `instruction_refinement`, `tool_creation`,
  `agent_composition`, and `workflow_optimization`. Reject unknown or duplicate
  keys, accept only literal `true` or `false`, and require at least one enabled
  key in each section.
- Accept only `in-repo`, `cross-repo`, or `standalone` for `mode`.
- Accept only the provider-agnostic workload tiers `simple`, `standard`, or
  `thinking` for `researcher`; runtime configuration owns concrete model mapping.
- Require `PROGRAM_NAME` to match the safe slug pattern
  `^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$` before using it in any path.
- Resolve the default or supplied `BRANCH`, then require
  `git check-ref-format --branch "$BRANCH"` to pass before creating any ref.
  Reject protected branch names such as `main`, `master`, and `develop`.
- Accept only JSON-style string arrays for `never_modify` and `require_review`.
- Accept only `lower` or `higher` for metric direction, positive integers for
  evaluation and budget counts, and a non-empty metric command.
- Require at least one `## Constraints` bullet. Each bullet must contain exactly
  one non-empty inline-code span and no other inline-code spans; surrounding text
  is a label only. Extract and execute only the span as a shell command from the
  candidate worktree. Never execute the whole Markdown bullet.
- Reject `level: elevated` when `trials < 3`.
- Resolve target patterns and safety paths relative to the target repository and
  reject any path or pattern that escapes it. Broad target patterns may overlap
  protected files: derive `ALLOWED_FILES` by excluding never-modify files and,
  under standard safety, elevated-only files. Reject an empty resulting set.
- Require every `require_review` entry to resolve to a target-matched file in
  `ALLOWED_FILES`; reject escaped, unmatched, never-modify, or otherwise excluded
  entries. Under elevated safety, every target-matched elevated-only file must be
  listed in `require_review` before any modification.
- Report every validation error with its section and field, then exit without
  creating a worktree, changing a ref, or running a program command.

## Step 1: Setup

**1.1 Resolve target repo:** `REPO_ROOT = cwd` if `MODE == "in-repo"` or `TARGET_REPO == "."`, else expand `TARGET_REPO` and verify it's a git repo. This does not copy or modify `SOURCE_PROGRAM`.

**1.2 Create or resume the owned experiment worktree:**

```bash
WORKTREE_BASE="${AIDEVOPS_WORKTREE_BASE_DIR:-$HOME/Git/_worktrees}"
WORKTREE_PATH="$WORKTREE_BASE/$(basename "$REPO_ROOT")-${BRANCH//\//-}"
PROGRAM_REL="todo/research/autoagent-${PROGRAM_NAME}.md"
RESULTS_REL="todo/research/${PROGRAM_NAME}-results.tsv"
if registered worktree exists at exactly WORKTREE_PATH:
    verify it is on BRANCH
    RESUMING=true
elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH":
    verify WORKTREE_PATH does not exist and BRANCH is not checked out elsewhere
    inspect "$BRANCH:$PROGRAM_REL" and "$BRANCH:$RESULTS_REL" with git show
    validate the committed program/results schemas and immutable config against SOURCE_PROGRAM
    git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" "$BRANCH"
    RESUMING=true
else:
    verify WORKTREE_PATH does not exist
    git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH"
    RESUMING=false
```

Never adopt an unregistered directory or a worktree on another branch. The runner
owns only the exact managed path it creates. Never reset, stash, clean, or overwrite
dirty state. When an owned experiment branch exists without a worktree, inspect and
validate its committed `PROGRAM_REL` and `RESULTS_REL` before attaching it at the
exact managed path. Never use `-b` for an existing branch or adopt an unverified
branch.

**1.3 Establish exact owned state paths:**

```text
PROGRAM_FILE = "$WORKTREE_PATH/todo/research/autoagent-${PROGRAM_NAME}.md"
RESULTS_FILE = "$WORKTREE_PATH/todo/research/${PROGRAM_NAME}-results.tsv"
TRAJECTORY_FILE = "$WORKTREE_PATH/todo/research/${PROGRAM_NAME}-trajectory.jsonl"
CHECKPOINT_DIR = "$WORKTREE_PATH/todo/research/checkpoints/${PROGRAM_NAME}"
```

These are the only runner-owned state paths. Checkpoint ownership is limited to
regular files directly beneath `CHECKPOINT_DIR`; reject symlinks and path escapes.
Always subtract runner-owned state paths from `ALLOWED_FILES` so candidate code
commits cannot modify or absorb lifecycle state.

**1.4 Pass the pre-edit gate:** Run `pre-edit-check.sh` from the exact
`WORKTREE_PATH` and require exit 0 before copying the program, creating result
files, or making any other owned-state write. No owned-state file may be written
before this gate passes. A failure stops and preserves the new or resumed
worktree for inspection.

**1.5 Copy or validate the owned program:** On a new worktree, copy the already
reviewed `SOURCE_PROGRAM` to `PROGRAM_FILE`; never parse a different copy. On resume,
parse both files and compare their immutable configuration: every validated field
except `baseline` must match exactly. A differing source baseline is allowed because
the committed `PROGRAM_FILE` baseline is authoritative. Any other difference stops
without modifying the worktree. Verify `SOURCE_PROGRAM_SHA256` immediately before
the initial copy so `PROGRAM_FILE` contains the exact reviewed bytes.

**1.6 Recover or reject dirty resume state:** Normal resume requires a clean
worktree. If dirty, list every changed/untracked path. If any path is outside the
exact runner-owned state paths, stop and preserve all dirt. If all dirty paths are
owned, validate the program contract, TSV header and row shape, every JSONL record,
checkpoint path/type, and cross-file iteration consistency before offering an
interactive recovery state commit. A headless run may perform that commit only after
the same validation. Stage only the validated exact paths, commit with an explicit
recovery message, and verify the worktree is clean. Never reset, stash, or clean
during recovery.

**1.7 Load prior results (resume mode):**

```text
if RESUMING:
    require committed PROGRAM_FILE and RESULTS_FILE; stop if either is missing
    ITERATION_COUNT = data rows (excl. header)
    BEST_METRIC     = best metric_value (per direction)
    BASELINE        = metric_value where status == "baseline"
    FAILED_HYPOTHESES = hypothesis list where status == "discard"
    TOTAL_TOKENS    = sum of tokens_used column
    Log: "Resuming from iteration N, best metric: X"
else:
    ITERATION_COUNT=0; BEST_METRIC=null; BASELINE=null; FAILED_HYPOTHESES=[]; TOTAL_TOKENS=0
    create RESULTS_FILE with header: iteration\tcommit\tmetric_name\tmetric_value\tbaseline\tdelta\tstatus\thypothesis\ttimestamp\ttokens_used
```

**1.8 Recall cross-session memory:** `aidevops-memory recall "autoagent $PROGRAM_NAME" --limit 10` → store as MEMORY_CONTEXT.

**1.9 Mine signals:** Load `autoagent/signal-mining.md`. Run signal extraction for each source in `SIGNAL_SOURCES`. Store as `SIGNAL_FINDINGS` — list of `{file, issue, source}` objects.

**1.10 Load safety constraints:** Load `autoagent/safety.md`. Apply `SAFETY_LEVEL`
to determine modifiable files and elevated-approval requirements. For every
instruction-semantic hypothesis, also load `.agents/tools/build-agent/agent-review.md`
and enforce the instruction-semantic preservation gate before metric evaluation.

**1.11 Initialize and commit baseline state:** On a new worktree, run constraints and,
when `BASELINE == null`, run `METRIC_CMD`. On success update only `PROGRAM_FILE`'s
baseline and append a `baseline` row to `RESULTS_FILE`. When the reviewed source
already has a non-null validated baseline, keep it unchanged, set `BEST_METRIC`, and
append the matching `baseline` row without rerunning the metric. If baseline setup
fails, leave baseline null and append a `baseline_error` row before stopping. In
either case, validate and call `commit_runner_state("baseline")` or
`commit_runner_state("baseline_error")`, staging only exact owned program/state paths,
then verify the worktree is clean. This makes initialization durable without mixing
state artifacts into candidate code commits.

`commit_runner_state(reason)` must validate schemas and path ownership, stage only
changed exact runner-owned state paths, create `chore(autoagent): record {reason}
state`, and verify a clean worktree. It must never use `git add -A`, a broad pathspec,
reset, stash, or clean.

## Step 2: Experiment Loop

See `autoagent/hypothesis-types.md` (6 hypothesis types, progression, overfitting
test) and `autoagent/evaluation.md` (multi-trial pseudocode, trajectory recording,
failure analysis).

Each hypothesis runs in a disposable detached candidate worktree created at the
current best SHA under `WORKTREE_BASE`:

```bash
BEST_SHA=$(git -C "$WORKTREE_PATH" rev-parse HEAD)
git -C "$REPO_ROOT" worktree add --detach "$CANDIDATE_PATH" "$BEST_SHA"
```

Verify the exact candidate path is registered to the experiment repository, starts
with the program-specific candidate prefix, and has detached `HEAD`. Never create a
per-iteration branch or ref. Apply changes and run constraints only there. Results,
trajectories, and discard checkpoints always remain under
`WORKTREE_PATH/todo/research/`.

Loop exits when any budget condition is met (timeout / max_iterations / goal_reached).

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

    hypothesis = generate_hypothesis(SIGNAL_FINDINGS, MEMORY_CONTEXT, FAILED_HYPOTHESES,
                                     BEST_METRIC, ITERATION_COUNT, HYPOTHESIS_TYPES)
    instruction_review = prepare_instruction_review(hypothesis)
    if instruction_review == INCOMPLETE:
        FAILED_HYPOTHESES.append(hypothesis)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "provenance_fail", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, null, "provenance_fail")
        commit_runner_state("provenance_fail")
        continue
    BEST_SHA = current HEAD of WORKTREE_PATH
    CANDIDATE_PATH = create_owned_detached_candidate_worktree(BEST_SHA, ITERATION_COUNT)
    run_pre_edit_check(CANDIDATE_PATH)
    apply_modification(hypothesis, CANDIDATE_PATH)
    validate_candidate_paths(CANDIDATE_PATH, ALLOWED_FILES)

    semantic_result = verify_instruction_semantic_preservation(
        CANDIDATE_PATH, instruction_review
    )
    if semantic_result == FAIL:
        checkpoint_candidate_diff(CANDIDATE_PATH, WORKTREE_PATH, "provenance_fail")
        remove_owned_candidate_worktree(CANDIDATE_PATH)
        FAILED_HYPOTHESES.append(hypothesis)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "provenance_fail", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, null, "provenance_fail")
        commit_runner_state("provenance_fail")
        continue

    constraint_result = run_constraints(CANDIDATE_PATH)
    if constraint_result == FAIL:
        checkpoint_candidate_diff(CANDIDATE_PATH, WORKTREE_PATH, "constraint_fail")
        remove_owned_candidate_worktree(CANDIDATE_PATH)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "constraint_fail", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, null, "constraint_fail")
        commit_runner_state("constraint_fail")
        continue

    evaluation = multi_trial_evaluate(METRIC_CMD, TRIALS_PER_HYPOTHESIS,
                                      REQUIRED_IMPROVEMENTS, BEST_METRIC, METRIC_DIR,
                                      CANDIDATE_PATH)
    if evaluation == ERROR:
        checkpoint_candidate_diff(CANDIDATE_PATH, WORKTREE_PATH, "crash")
        remove_owned_candidate_worktree(CANDIDATE_PATH)
        track_tokens(ITER_START_TOKENS)
        log_result(ITERATION_COUNT, null, null, "crash", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, null, "crash")
        commit_runner_state("crash")
        continue

    metric_result = evaluation.median_score
    track_tokens(ITER_START_TOKENS)

    if evaluation.passed:
        review_files = changed files intersecting REQUIRE_REVIEW
        if review_files is not empty and explicit_candidate_review(review_files) != APPROVED:
            checkpoint_candidate_diff(CANDIDATE_PATH, WORKTREE_PATH, "review_required")
            remove_owned_candidate_worktree(CANDIDATE_PATH)
            log_result(ITERATION_COUNT, null, metric_result, "review_required", hypothesis, ITER_TOKENS)
            record_trajectory(ITERATION_COUNT, hypothesis, metric_result, "review_required")
            commit_runner_state("review_required")
            stop for manual review
        commit allowed target files in CANDIDATE_PATH
        CANDIDATE_SHA = candidate commit
        fast-forward WORKTREE_PATH to CANDIDATE_SHA
        remove_owned_candidate_worktree(CANDIDATE_PATH)
        HEAD_SHA = CANDIDATE_SHA
        BEST_METRIC = metric_result
        log_result(ITERATION_COUNT, HEAD_SHA, metric_result, "keep", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, metric_result, "keep")
        commit_runner_state("keep")
        aidevops-memory store "autoagent {PROGRAM_NAME}: {hypothesis[:80]} → keep ({METRIC_NAME}: {metric_result})" --confidence medium
    else:
        checkpoint_candidate_diff(CANDIDATE_PATH, WORKTREE_PATH, "discard")
        remove_owned_candidate_worktree(CANDIDATE_PATH)
        FAILED_HYPOTHESES.append(hypothesis)
        log_result(ITERATION_COUNT, null, metric_result, "discard", hypothesis, ITER_TOKENS)
        record_trajectory(ITERATION_COUNT, hypothesis, metric_result, "discard")
        commit_runner_state("discard")
        aidevops-memory store "autoagent {PROGRAM_NAME}: {hypothesis[:80]} → discard ({METRIC_NAME}: {metric_result})" --confidence medium
```

`checkpoint_candidate_diff` stages only allowed target files in the candidate and
writes a binary patch plus an untracked-file manifest to the owned experiment
worktree. `remove_owned_candidate_worktree` may force-remove only after verifying
the candidate is registered, is below the program-specific managed prefix, and
is not `WORKTREE_PATH`; otherwise it stops. This makes discard recoverable without
rewriting the current-best worktree.

`run_pre_edit_check(path)` executes the runtime pre-edit check from the exact
registered worktree and requires exit 0 before the first write there.
`validate_candidate_paths` requires at least one changed target file and rejects
every symlink, path escape, runner-owned state path, or changed path outside
`ALLOWED_FILES`; it never silently ignores out-of-scope dirt. When changed files
intersect `REQUIRE_REVIEW`, show the complete candidate diff and require explicit
interactive approval before committing or fast-forwarding. Headless runs must never
auto-approve: checkpoint the candidate as `review_required`, commit that runner
state, and stop without creating a PR.

For a keep, the candidate code commit and experiment-worktree fast-forward happen
before the runner appends state and calls `commit_runner_state("keep")`. For every
keep, discard, constraint failure, crash, or review-required stop, the state commit
is the final worktree-mutating operation at that stable boundary. Results,
trajectory, and applicable checkpoints therefore remain durable on the experiment
branch, and each next iteration starts clean.

## Step 3: Completion

**3.1 Store final memory:**

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME} complete: {kept_count} kept, {discarded_count} discarded, {improvement_pct:.1f}% improvement in {METRIC_NAME}. Top finding: {top_hypothesis}" \
  --confidence high
```

**3.2 Generate completion summary** (use as PR body):

```markdown
## Autoagent Results: {PROGRAM_NAME}

**Program:** {PROGRAM_NAME}
**Duration:** {elapsed_human} ({ITERATION_COUNT} iterations)
**Baseline → Best:** {BASELINE} → {BEST_METRIC} ({improvement_pct:+.1f}%)
**Exit reason:** {timeout | max_iterations | goal_reached | review_required}

### Experiment Outcomes

| Status | Count |
|--------|-------|
| Kept | {kept_count} |
| Discarded | {discarded_count} |
| Constraint failures | {constraint_fail_count} |
| Crashes | {crash_count} |
| Review required | {review_required_count} |

### Key Findings

{For each kept hypothesis, sorted by delta (best first):}
{N}. **{hypothesis}**: {METRIC_NAME} {metric_before} → {metric_after} ({delta:+.2f}, {improvement_pct:.1f}%)

### Failed Approaches

{For top 3-5 discarded hypotheses:}
- {hypothesis}: {METRIC_NAME} = {metric_value} (delta={delta:+.2f})

### Token Usage

- Total: ~{TOTAL_TOKENS:,} tokens across {ITERATION_COUNT} iterations
- Average per iteration: ~{avg_tokens:,} tokens
```

**3.3 Create PR:**

```bash
PR_BODY_DIR="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/autoagent-pr-bodies"
PR_BODY_FILE="$PR_BODY_DIR/${PROGRAM_NAME}-pr-body.md"
verify the temp parent and create PR_BODY_DIR if needed
generate_completion_summary > "$PR_BODY_FILE"
append the issue reference to PR_BODY_FILE
read PR_BODY_FILE and verify its complete contents before the GitHub write
verify WORKTREE_PATH is clean
git -C "$WORKTREE_PATH" push -u origin "$BRANCH"

gh pr create \
  --repo {REPO_SLUG} \
  --head "$BRANCH" \
  --base main \
  --title "autoagent({PROGRAM_NAME}): {improvement_pct:+.1f}% improvement in {METRIC_NAME}" \
  --body-file "$PR_BODY_FILE"
```

The PR body is a reviewed temp artifact, not repository state. Final push must start
from a clean experiment worktree whose committed history includes all runner state.

**3.4 Store PR memory:**

```text
aidevops-memory store \
  "autoagent {PROGRAM_NAME} PR created: {pr_url}. Best: {METRIC_NAME}={BEST_METRIC}. Key finding: {top_hypothesis}" \
  --confidence high
```

## Related

`.agents/templates/autoagent-program-template.md` · `.agents/scripts/autoagent-metric-helper.sh` · `todo/research/` · `.agents/tools/autoresearch/autoresearch.md`
