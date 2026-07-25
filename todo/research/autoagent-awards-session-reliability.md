---
name: awards-session-reliability
mode: in-repo
target_repo: .
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent: Awards Session Reliability

## Target

```text
files: .agents/scripts/commands/autoagent.md, .agents/workflows/autoagent.md, .agents/scripts/autoagent-metric-helper.sh, .agents/scripts/tests/test-autoagent-metric-helper.sh, .agents/templates/autoagent-program-template.md, .agents/tools/autoagent/**/*.md, .agents/tests/test-autoagent-contract.sh
branch: experiment/autoagent-awards-session-reliability
```

## Signal Sources

```text
session_miner: true
comprehension: false
linters: true
git_churn: true
pulse_outcomes: false
```

## Hypothesis Types

```text
self_healing: true
tool_optimization: true
instruction_refinement: true
tool_creation: false
agent_composition: false
workflow_optimization: true
```

## Safety

```text
level: standard
never_modify: [".agents/AGENTS.md", "AGENTS.md", "prompts/build.txt"]
require_review: []
```

## Metric

```text
command: bash todo/research/autoagent-awards-session-reliability-score.sh
name: contract_score
direction: higher
baseline: 0.1000
goal: 1.0
```

## Constraints

- Shell syntax must pass: `bash -n todo/research/autoagent-awards-session-reliability-score.sh`
- Autoagent tests must pass: `bash .agents/tests/test-autoagent-contract.sh && bash .agents/scripts/tests/test-autoagent-metric-helper.sh`
- ShellCheck must pass: `shellcheck .agents/tests/test-autoagent-contract.sh .agents/scripts/autoagent-metric-helper.sh .agents/scripts/tests/test-autoagent-metric-helper.sh`
- Markdown style must pass: `markdownlint .agents/workflows/autoagent.md .agents/templates/autoagent-program-template.md '.agents/tools/autoagent/**/*.md'`

## Models

```text
researcher: standard
```

## Evaluation

```text
trials: 2
required_improvements: majority
```

## Budget

```text
timeout: 1800
max_iterations: 5
per_experiment: 300
```

## Hints

- The session reached a verified merge, but a high-priority responsive-layout review finding landed before merge and required a later corrective PR. Current review-thread tooling already addresses this; do not duplicate it.
- The session used raw `gh pr checks --watch`, produced repeated output, and timed out. Current `full-loop.md` already requires `full-loop-helper.sh wait-checks`; preserve that existing fix.
- The live Autoagent program template uses `Signal Sources`, `Hypothesis Types`, `Safety`, and `Evaluation`, while the runner documents parsing a nonexistent `Autoagent` section. Align the runner to the template and fail closed on malformed required fields.
- The runner currently places worktrees beside the repository, writes results through `REPO_ROOT`, and discards work with `git reset --hard`. Align it with the managed worktree base, keep artifacts inside the owned worktree, and use disposable per-hypothesis worktrees or another non-destructive owned-worktree pattern.
- GitHub PR bodies must use a reviewed `--body-file`; do not use command substitution.
- Keep `.agents/scripts/commands/autoagent.md` and `.agents/workflows/autoagent.md` byte-identical unless one is explicitly reduced to a documented compatibility shim.
- The documented `agent-optimization` suite does not exist, `agent-test-helper.sh run --suite` and `autoagent-metric-helper.sh run` are invalid command shapes, and the default metric omits a suite so comprehension silently degrades to neutral. Use a shipped suite and pin commands against the real helper interfaces.
- The metric helper currently runs the same AI suite repeatedly inside one score/compare call and its default weights top out at 0.9 because token weight is penalty-only. Reuse one suite result per command, validate normalized weights, and make token efficiency contribute its weight without rewarding ratios below 1.0.
- Candidate lint scoring must include staged, unstaged, and untracked candidate files rather than diffing only committed `HEAD`; queued task text must never persist a local temp path; detached candidate worktrees and existing-branch reattachment must not leak refs or break resume.
- Prefer a small regression test over additional prose. Do not change generic full-loop/review-thread behavior that is already fixed on current main.
