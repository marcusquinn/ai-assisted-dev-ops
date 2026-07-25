---
name: agent-optimization
mode: in-repo
target_repo: .
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Research: Agent Instruction Optimization

Improve agent instruction delivery while preserving directive provenance and
target-specific behaviour. After the semantic-preservation gate passes, use the
composite metric `pass_rate * (1 - 0.3 * token_ratio)` to compare quality and size.

<!-- AI-CONTEXT-START -->

## How to use

1. Set the target agent and test suite in the Target and Metric sections below.
2. Run: `/auto-research --program todo/research/agent-optimization.md`
3. The auto-research subagent will iterate, keeping only changes that pass Agent
   Review's semantic gate and improve the composite score.

Default target: `build-plus.md` with `smoke-test` suite. Override by editing the Target section.

<!-- AI-CONTEXT-END -->

## Target

```text
files: .agents/build-plus.md
branch: experiment/optimize-build-plus
```

## Metric

```text
command: agent-test-helper.sh run smoke-test --json | jq '.composite_score'
name: composite_score
direction: higher
baseline: null
goal: null
```

The composite score formula `pass_rate * (1 - 0.3 * token_ratio)` applies only
after directive provenance, delivery, and target-specific behaviour are verified.

- `pass_rate`: fraction of tests passing (0–1). Computed from `agent-test-helper.sh --json` output.
- `token_ratio`: `avg_response_chars / baseline_chars`. Proxy for token usage relative to baseline.
  Lower response length = lower token ratio = higher composite score.
- Weights: 70% quality preservation, 30% size reduction.
- Example: 100% pass + 70% of baseline chars → score = 1.0 × (1 − 0.3 × 0.7) = 0.79
- Example: 100% pass + 100% of baseline chars → score = 1.0 × (1 − 0.3 × 1.0) = 0.70
- Example: 95% pass + 50% of baseline chars → score = 0.95 × (1 − 0.3 × 0.5) = 0.808

## Constraints

Each constraint must exit 0 before the metric is measured. Failure = discard the experiment.

Instruction-semantic candidates also load
`.agents/tools/build-agent/agent-review.md`. Missing provenance, assembled-context
analysis, directive classification, activation/exclusion boundaries, or
target-specific behavioural coverage records `provenance_fail` before this metric.

```text
- Lint clean: markdownlint-cli2 .agents/build-plus.md
- Pass rate must not drop below 80%: agent-test-helper.sh run smoke-test --json | jq -e '.pass_rate >= 0.8'
- Security instructions intact: grep -q "NEVER expose credentials" .agents/build-plus.md
- File operation rules intact: grep -q "Read before Edit" .agents/build-plus.md || grep -q "Read.*before.*Edit" .agents/build-plus.md
- Traceability rules intact: grep -q "PR title MUST have task ID" .agents/build-plus.md || grep -q "task ID" .agents/build-plus.md
```

## Instruction-Semantic Preservation

The following instruction categories must NEVER be removed by automated
optimization. They are hard minimums, not an allowlist: every changed directive
must satisfy the Agent Review provenance and delivery gate before metric evaluation.

- Credential and secret handling rules (gopass, credentials.sh, NEVER expose)
- File operation safety rules (Read before Edit/Write, verify paths)
- Git safety rules (pre-edit-check.sh, never edit on main)
- Traceability requirements (PR title task ID, Closes #NNN)
- Prompt injection defense rules
- Destructive operation confirmation requirements

When a hypothesis would remove or weaken any of the above, discard it without
testing. For every other directive, incomplete provenance, delivery, or behavioural
evidence also defaults to preservation; a stable broad test or improved token ratio
does not prove the lesson is redundant.

## Simplification State Integration

Before generating hypotheses, check if the target file's hash matches the last-tested hash
in `.agents/configs/simplification-state.json`. If the hash matches, the file has not changed
since the last optimization session — skip to the next target file or exit if no targets remain.

After a successful optimization session (semantic gate passed and composite score
improved), update the hash:

```bash
# Read current hash
CURRENT_HASH=$(md5sum .agents/build-plus.md | awk '{print $1}')
STATE_TMP="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/agent-optimization-state.json"
mkdir -p "$(dirname "$STATE_TMP")"

# Update simplification-state.json
jq --arg file ".agents/build-plus.md" \
   --arg hash "$CURRENT_HASH" \
   --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   '.files[$file] = {"hash": $hash, "at": $ts, "pr": null}' \
   .agents/configs/simplification-state.json > "$STATE_TMP" && \
   mv "$STATE_TMP" .agents/configs/simplification-state.json
```

## Models

```text
researcher: standard
evaluator: simple
target: standard
```

## Budget

```text
timeout: 7200
max_iterations: 50
per_experiment: 300
```

## Hints

- Treat apparent duplicates as review candidates; recover their history and
  decision boundaries before consolidation
- Examples with long code blocks inflate tokens; prefer references to `file:line`
- Merge thin sections only when activation, owner, semantics, and delivery match
- Verbose preambles ("Before doing X, you must always...") can often be shortened
- Tables with many columns can sometimes be replaced with a shorter prose rule
- Avoid removing security rules, traceability requirements, or file operation rules
- The Agent Review gate protects non-security lessons as well as hard limits
- Start with the most verbose sections (long tables, multi-paragraph rules)
- Prefer proven semantic equivalence over presumed consolidation
- Add focused activation/exclusion scenarios before relying on aggregate suites

## Multi-Agent Targets

To optimize multiple agent files in sequence, run separate sessions with different targets.
Suggested order (highest token impact first):

1. `build-plus.md` — primary agent, highest usage
2. `.agents/AGENTS.md` — user guide, loaded on every interactive session

For each target, update the `files:` and `branch:` in the Target section, and update
the `command:` in the Metric section to use the appropriate test suite.

## Baseline Setup

Before the first optimization run, establish a baseline:

```bash
# Save current test results as baseline (sets baseline_chars for token_ratio)
agent-test-helper.sh baseline smoke-test

# Verify baseline was saved
agent-test-helper.sh results smoke-test
```

The autoresearch subagent will measure the baseline metric on first run if `baseline: null`.
