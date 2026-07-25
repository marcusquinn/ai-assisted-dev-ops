---
name: {program-name}
mode: in-repo
target_repo: .
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Autoagent: {Title}

<!-- AI-CONTEXT-START -->

An autoagent research program defines what the framework self-improvement loop
optimizes, which signals it mines, which hypothesis types it uses, what safety
constraints apply, and how it evaluates changes.

Fields marked `# required` must be present. Fields marked `# optional` may be omitted.

The autoagent subagent reads this file at session start and uses it as the
contract for the entire experiment loop. Unlike the base research-program-template,
this template adds autoagent-specific sections: Signal Sources, Hypothesis Types,
Safety, and multi-trial Evaluation.

<!-- AI-CONTEXT-END -->

## Target

```text
files: {glob patterns of modifiable files, comma-separated}   # required
branch: experiment/autoagent-{name}                            # auto-generated if omitted
```

Examples:

- `files: .agents/scripts/*.sh` — all helper scripts
- `files: .agents/**/*.md` — all agent docs
- `files: .agents/tools/**/*.md, .agents/scripts/*.sh` — multiple patterns

## Signal Sources

```text
session_miner: true     # mine session-miner-pulse.sh output for error patterns
comprehension: true     # run agent-test-helper.sh and analyze failures
linters: true           # run linters and count violations
git_churn: true         # identify high-churn framework files
pulse_outcomes: false   # mine pulse dispatch success/failure (requires pulse history)
```

At least one signal source must be `true`. Signal sources inform hypothesis generation —
the autoagent reads signal output before proposing each experiment. All documented
keys are required exactly once so a misspelling or duplicate cannot silently
change signal selection.

## Hypothesis Types

```text
self_healing: true          # fix recurring failures from session logs
tool_optimization: true     # improve existing helper scripts
instruction_refinement: true # optimize agent docs for clarity/tokens
tool_creation: false        # propose new tools (higher risk)
agent_composition: false    # restructure subagent routing
workflow_optimization: false # modify operational patterns
```

At least one hypothesis type must be `true`. Higher-risk types (`tool_creation`,
`agent_composition`, `workflow_optimization`) should only be enabled after lower-risk
types have been exhausted or in elevated-safety programs with 3+ trials. All six
documented keys are required exactly once.

## Safety

```text
level: standard             # required: standard | elevated
never_modify: []            # required: additional files beyond default list
require_review: []          # required: files needing manual review before keep
```

**Standard safety** (default): excludes elevated-only files, including root
`AGENTS.md` and `.agents/AGENTS.md`, from the expanded target set. It always
excludes `prompts/build.txt`, an intentionally near-empty compatibility placeholder
that must never receive framework rules. `.agents/AGENTS.md` is canonical.

**Elevated safety**: may modify elevated-only files only when each target-matched
file is listed in `require_review`. It never permits security-section changes.
Elevated programs require at least three trials and explicit `level: elevated`.
Broad target patterns may overlap protected files because protected matches are
excluded; the remaining allowed set must not be empty.

Every candidate that changes a `require_review` path needs explicit interactive
approval after its complete diff is shown and before it is kept. Headless runs
checkpoint the candidate as `review_required` and stop; they never auto-approve.

## Metric

```text
command: autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json # required
name: composite_score                          # required
direction: higher                              # required: lower | higher
baseline: null                                 # auto-populated on first run
goal: null                                     # optional: stop when reached
weights: "0.6,0.3,0.1"                        # optional: comprehension,lint,tokens
```

The default `autoagent-metric-helper.sh score` command outputs a composite score
(0.0–1.0) weighted across comprehension pass rate, lint cleanliness, and token
efficiency. Always name a shipped suite explicitly so comprehension cannot silently
degrade to neutral. Override `weights` to shift emphasis; exactly three
non-negative values summing to 1.0 are required.

Custom metric commands must:

- Exit 0 on success
- Print exactly one number to stdout (the subagent parses the last line)
- Be deterministic enough to distinguish signal from noise

## Constraints

At least one constraint is required. Every bullet must contain exactly one
non-empty inline-code shell command. Text outside that span is a human label and
is never executed. The autoagent runs the extracted commands after each
modification; any non-zero exit discards the experiment.

```text
- Tests must pass: `autoagent-metric-helper.sh comprehension --suite .agents/tests/agents-md-knowledge.json | awk '{exit ($1 < 0.8)}'`
- Lint clean: `autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'`
- ShellCheck: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`
```

## Models

```text
researcher: standard   # required: workload tier that runs the experiment loop
```

Workload tiers: `simple` (mechanical), `standard` (implementation/review), and
`thinking` (complex reasoning). Use `standard` for most programs and reserve
`thinking` for hypotheses whose ambiguity or consequence justifies deeper
reasoning. Runtime configuration maps tiers to concrete models.

Instruction-semantic candidates automatically load
`.agents/tools/build-agent/agent-review.md`. They fail closed as `provenance_fail`
before metric evaluation unless provenance, assembled delivery, classification,
activation/exclusion boundaries, preservation, and target-specific behavioural
coverage are complete.

## Evaluation

```text
trials: 2                    # required: positive integer
required_improvements: majority # required: majority | all
```

Each trial is compared with the current best score. `majority` requires improvement
in more than half of the trials; `all` requires every trial to improve. Elevated
safety requires at least three trials.

## Budget

```text
timeout: 7200          # required: total wall-clock seconds
max_iterations: 30     # required: max experiment count
per_experiment: 300    # optional: max seconds per single experiment (default: 5min)
```

## Hints

Optional human guidance for the researcher model's hypothesis generation.
The autoagent reads these before generating each hypothesis.

- {hint about where to look for improvements}
- {hint about what approaches to avoid}
- {hint about known constraints or gotchas}

---

## Examples

The following are complete, runnable autoagent programs. Copy and adapt.

---

### Example 1: Self-Healing Focus

```markdown
---
name: self-healing-focus
mode: in-repo
target_repo: .
---

# Autoagent: Self-Healing — Fix Recurring Session Errors

## Target

\`\`\`text
files: .agents/scripts/*.sh, .agents/workflows/*.md
branch: experiment/autoagent-self-healing
\`\`\`

## Signal Sources

\`\`\`text
session_miner: true
comprehension: false
linters: true
git_churn: true
pulse_outcomes: false
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: true
tool_optimization: true
instruction_refinement: false
tool_creation: false
agent_composition: false
workflow_optimization: false
\`\`\`

## Safety

\`\`\`text
level: standard
never_modify: []
require_review: []
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.6,0.3,0.1"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: `autoagent-metric-helper.sh comprehension --suite .agents/tests/agents-md-knowledge.json | awk '{exit ($1 < 0.8)}'`
- Lint clean: `autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'`
- ShellCheck: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`
\`\`\`

## Models

\`\`\`text
researcher: standard
\`\`\`

## Evaluation

\`\`\`text
trials: 2
required_improvements: majority
\`\`\`

## Budget

\`\`\`text
timeout: 3600
max_iterations: 15
per_experiment: 300
\`\`\`

## Hints

- Check error-feedback patterns for recurring failures first
- Priority: fix errors that occur in >10% of sessions
- Prefer adding validation/guards over rewriting logic
- ShellCheck violations in helper scripts are high-signal targets
- Git churn identifies scripts that change frequently — likely fragile
```

---

### Example 2: Instruction Refinement

```markdown
---
name: instruction-refinement
mode: in-repo
target_repo: .
---

# Autoagent: Instruction Refinement — Optimize Agent Docs for Clarity and Tokens

## Target

\`\`\`text
files: .agents/**/*.md, .agents/prompts/*.txt
branch: experiment/autoagent-instruction-refinement
\`\`\`

## Signal Sources

\`\`\`text
session_miner: false
comprehension: true
linters: true
git_churn: false
pulse_outcomes: false
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: false
tool_optimization: false
instruction_refinement: true
tool_creation: false
agent_composition: false
workflow_optimization: false
\`\`\`

## Safety

\`\`\`text
level: standard
never_modify: []
require_review: [".agents/tools/autoagent/autoagent.md"]
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.4,0.2,0.4"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: `autoagent-metric-helper.sh comprehension --suite .agents/tests/agents-md-knowledge.json | awk '{exit ($1 < 0.8)}'`
- Lint clean: `autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'`
- Markdownlint: `markdownlint-cli2 ".agents/**/*.md"`
\`\`\`

## Models

\`\`\`text
researcher: standard
\`\`\`

## Evaluation

\`\`\`text
trials: 2
required_improvements: majority
\`\`\`

## Budget

\`\`\`text
timeout: 7200
max_iterations: 30
per_experiment: 300
\`\`\`

## Hints

- Treat apparent duplicates as review candidates; distinguish exact duplication
  from decision-boundary reinforcement
- Merge thin sections only when provenance, activation, and delivery are equivalent
- Never remove security instructions or traceability requirements
- Treat shorter phrasing as a candidate until target-specific scenarios prove the
  same semantics and delivery
- Comprehension test failures reveal which instructions are unclear — fix those first
- weights "0.4,0.2,0.4" ranks candidates only after the semantic gate passes
```

---

### Example 3: Full Autonomous (Overnight)

```markdown
---
name: full-autonomous-overnight
mode: in-repo
target_repo: .
---

# Autoagent: Full Autonomous — All Hypothesis Types, All Signal Sources

## Target

\`\`\`text
files: .agents/tools/**/*.md, .agents/scripts/*.sh, .agents/AGENTS.md, AGENTS.md
branch: experiment/autoagent-full-autonomous
\`\`\`

## Signal Sources

\`\`\`text
session_miner: true
comprehension: true
linters: true
git_churn: true
pulse_outcomes: true
\`\`\`

## Hypothesis Types

\`\`\`text
self_healing: true
tool_optimization: true
instruction_refinement: true
tool_creation: true
agent_composition: true
workflow_optimization: true
\`\`\`

## Safety

\`\`\`text
level: elevated
never_modify: []
require_review: [".agents/AGENTS.md", "AGENTS.md"]
\`\`\`

## Metric

\`\`\`text
command: autoagent-metric-helper.sh score --suite .agents/tests/agents-md-knowledge.json
name: composite_score
direction: higher
baseline: null
goal: null
weights: "0.6,0.3,0.1"
\`\`\`

## Constraints

\`\`\`text
- Tests must pass: `autoagent-metric-helper.sh comprehension --suite .agents/tests/agents-md-knowledge.json | awk '{exit ($1 < 0.8)}'`
- Lint clean: `autoagent-metric-helper.sh lint | awk '{exit ($1 < 0.9)}'`
- ShellCheck: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`
- Markdownlint: `markdownlint-cli2 ".agents/**/*.md"`
\`\`\`

## Models

\`\`\`text
researcher: standard
\`\`\`

## Evaluation

\`\`\`text
trials: 3
required_improvements: majority
\`\`\`

## Budget

\`\`\`text
timeout: 14400
max_iterations: 50
per_experiment: 600
\`\`\`

## Hints

- Start with self-healing (highest signal, lowest risk)
- Progress to instruction refinement after self-healing exhausts low-hanging fruit
- Tool creation and agent composition only after iteration 20
- Simplification is kept only after applicable semantic and behavioural gates pass
- Elevated safety: all target-matched elevated-only files require review
- 3 trials required for consistency — a change must improve in 2 of 3 runs to be kept
- pulse_outcomes requires pulse history in ~/.aidevops/.agent-workspace/; skip if absent
```
