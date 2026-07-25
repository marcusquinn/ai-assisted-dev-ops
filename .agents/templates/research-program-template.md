---
name: {program-name}
mode: in-repo          # in-repo | cross-repo | standalone
target_repo: .         # path or "." for current repo
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Research: {Title}

<!-- AI-CONTEXT-START -->

A research program defines what an autoresearch session optimizes, how it measures success,
what constraints must hold, and when to stop. The subagent reads this file at session start
and uses it as the contract for the entire experiment loop.

Fields marked `# required` must be present. Fields marked `# optional` may be omitted.

<!-- AI-CONTEXT-END -->

## Target

```text
files: {glob patterns of modifiable files, comma-separated}   # required
branch: experiment/{program-name}                              # auto-generated if omitted
```

Examples:
- `files: .agents/prompts/build.txt` — single file
- `files: .agents/**/*.md` — all agent docs
- `files: src/**/*.ts, webpack.config.js` — multiple patterns

## Metric

```text
command: {shell command that outputs a single numeric value}   # required
name: {metric_name_snake_case}                                 # required
direction: lower                                               # required: lower | higher
baseline: null                                                 # auto-populated on first run
goal: null                                                     # optional: stop when reached (e.g., "< 3.0")
```

The metric command must:
- Exit 0 on success
- Print exactly one number to stdout (the subagent parses the last line)
- Be deterministic enough to distinguish signal from noise

Examples:
- Build time: `npm run build 2>&1 | grep 'Time:' | awk '{print $2}'`
- Token count: `agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric tokens | tail -1`
- Test pass rate: `pytest --tb=no -q 2>&1 | grep passed | awk '{print $1}'`
- File size: `wc -c < dist/bundle.js`

## Constraints

Each constraint is a shell command that must exit 0 before the metric is measured.
The subagent runs all constraints after each modification. Failure = discard the experiment.

```text
- {constraint description}: {shell command}
```

Examples:
- Tests must pass: `npm test`
- No new dependencies: `git diff HEAD -- package.json | grep -c '^+' | awk '{exit ($1 > 0)}'`
- Lint clean: `markdownlint-cli2 .agents/**/*.md`
- ShellCheck clean: `find .agents/scripts -name '*.sh' -exec shellcheck {} \;`
- Public API unchanged: `git diff HEAD -- src/index.ts | grep -c '^[+-]export' | awk '{exit ($1 > 0)}'`

## Models

```text
researcher: standard   # required: workload tier that runs the experiment loop
evaluator: simple      # optional: workload tier that scores qualitative output
target: standard       # optional: workload tier under test (agent optimization only)
```

Workload tiers are `simple`, `standard`, and `thinking`; runtime configuration
owns concrete model mappings. Use a concrete `target` only for an explicitly
declared model benchmark that records provider/model/version provenance and
compares equivalent workloads within a tier.

Instruction-semantic candidates automatically load
`.agents/tools/build-agent/agent-review.md` and must pass provenance, delivery,
classification, activation/exclusion, and target-specific behavioural checks
before the metric is evaluated. Missing coverage defaults to preservation.

## Budget

```text
timeout: 7200          # required: total wall-clock seconds (default: 2h)
max_iterations: 50     # required: max experiment count
per_experiment: 300    # optional: max seconds per single experiment (default: 5min)
trials: 1              # optional: evaluations per hypothesis (default: 1, use 2-3 for noisy metrics)
```

Multi-trial evaluation reduces noise from stochastic metrics (e.g., LLM-scored tests). Each trial re-runs the full metric command. The median result is used for keep/discard. Set to 2-3 for LLM-based metrics, 1 for deterministic metrics (build time, file size).

## Concurrency

```text
mode: sequential          # sequential | population | multi-dimension
population_size: 4        # population mode: N hypotheses per iteration (ignored otherwise)
convoy_id: null           # auto-generated campaign ID for mailbox grouping (null = auto)
```

Modes:

- `sequential` — one hypothesis at a time (default, lowest cost)
- `population` — N hypotheses per iteration; all measured in parallel, best kept. Set `population_size` to control N.
- `multi-dimension` — separate agent sessions per dimension, coordinated via mailbox. Requires `## Dimensions` section.

`convoy_id` is auto-generated at dispatch time as `autoresearch-{name}-{date}`. Set manually to group related campaigns.

## Dimensions

Only used when `concurrency.mode = multi-dimension`. Each dimension gets its own worktree and agent session.
File targets MUST NOT overlap between dimensions — enforced at dispatch time, not parse time.
Dimensions inherit the parent `## Constraints`, `## Models`, and `## Budget` sections unless overridden per-dimension.

```text
# dimensions:
#   - name: build-perf
#     files: webpack.config.js, src/utils/**
#     metric:
#       command: npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
#       name: build_time_s
#       direction: lower
#   - name: test-speed
#     files: jest.config.ts, tests/**
#     metric:
#       command: npm test 2>&1 | grep 'Time:' | awk '{print $2}'
#       name: test_time_s
#       direction: lower
#   - name: bundle-size
#     files: rollup.config.js, src/index.ts
#     metric:
#       command: du -sb dist/bundle.js | cut -f1
#       name: bundle_bytes
#       direction: lower
```

Uncomment and populate when using `multi-dimension` mode. Leave commented for `sequential` or `population` modes.

## Hints

Optional human guidance for the researcher model's hypothesis generation.
The subagent reads these before generating each hypothesis.

- {hint about where to look for improvements}
- {hint about what approaches to avoid}
- {hint about known constraints or gotchas}

---

## Examples

The following are complete, runnable research programs. Copy and adapt.

---

### Example 1: Agent Instruction Optimization

```markdown
---
name: optimize-build-plus-tokens
mode: in-repo
target_repo: .
---

# Research: Reduce build-plus token usage without quality loss

## Target

\`\`\`
files: .agents/build-plus.md, .agents/prompts/build.txt
branch: experiment/optimize-build-plus-tokens
\`\`\`

## Metric

\`\`\`
command: agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric tokens | tail -1
name: avg_tokens_per_task
direction: lower
baseline: null
goal: null
\`\`\`

## Constraints

- Tests must pass: `agent-test-helper.sh run --suite .agents/tests/build-plus.json --metric pass_rate | tail -1 | awk '{exit ($1 < 0.9)}'`
- Lint clean: `markdownlint-cli2 .agents/build-plus.md .agents/prompts/build.txt`

## Models

\`\`\`
researcher: standard
evaluator: simple
target: standard
\`\`\`

## Budget

\`\`\`
timeout: 14400
max_iterations: 100
per_experiment: 600
\`\`\`

## Hints

- Treat apparent duplication as review pressure; recover provenance and decision
  boundaries before consolidating
- Examples with long code blocks inflate tokens; prefer references to file:line
- Merge thin sections only when activation, ownership, semantics, and delivery match
- Avoid removing security rules or traceability requirements
```

---

### Example 2: Build Performance Optimization

```markdown
---
name: optimize-build-time
mode: in-repo
target_repo: .
---

# Research: Reduce TypeScript build time

## Target

\`\`\`
files: src/**/*.ts, tsconfig.json, webpack.config.js
branch: experiment/optimize-build-time
\`\`\`

## Metric

\`\`\`
command: npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
name: build_time_seconds
direction: lower
baseline: null
goal: "< 10.0"
\`\`\`

## Constraints

- Tests must pass: `npm test`
- No new dependencies: `git diff HEAD -- package.json | grep -c '^+' | awk '{exit ($1 > 2)}'`
- Bundle size within 10%: `node -e "const s=require('fs').statSync('dist/bundle.js').size; process.exit(s > 1.1 * 512000 ? 1 : 0)"`

## Models

\`\`\`
researcher: standard
\`\`\`

## Budget

\`\`\`
timeout: 7200
max_iterations: 50
per_experiment: 300
\`\`\`

## Hints

- Tree-shaking opportunities in utils/ — barrel exports may prevent dead-code elimination
- tsconfig `incremental` and `composite` flags can reduce rebuild time
- Check for unnecessary `include` globs pulling in test files
- `isolatedModules: true` enables faster single-file transpilation
```

---

### Example 3: Multi-Dimension Frontend Optimization

Three independent dimensions (build speed, test speed, bundle size) optimized in parallel.
Each dimension targets non-overlapping files and runs in its own worktree.

```markdown
---
name: optimize-frontend-multi
mode: in-repo
target_repo: .
---

# Research: Optimize frontend build, test, and bundle size in parallel

## Target

\`\`\`
files: webpack.config.js, jest.config.ts, rollup.config.js, src/**
branch: experiment/optimize-frontend-multi
\`\`\`

## Metric

\`\`\`
command: npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
name: build_time_seconds
direction: lower
baseline: null
\`\`\`

## Constraints

- Tests must pass: `npm test`
- No new dependencies: `git diff HEAD -- package.json | grep -c '^+' | awk '{exit ($1 > 2)}'`

## Models

\`\`\`
researcher: standard
\`\`\`

## Budget

\`\`\`
timeout: 14400
max_iterations: 60
per_experiment: 300
\`\`\`

## Concurrency

\`\`\`
mode: multi-dimension
population_size: 1
convoy_id: null
\`\`\`

## Dimensions

\`\`\`
dimensions:
  - name: build-perf
    files: webpack.config.js, tsconfig.json, src/utils/**
    metric:
      command: npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
      name: build_time_s
      direction: lower
  - name: test-speed
    files: jest.config.ts, tests/**
    metric:
      command: npm test 2>&1 | grep 'Time:' | awk '{print $2}'
      name: test_time_s
      direction: lower
  - name: bundle-size
    files: rollup.config.js, src/index.ts
    metric:
      command: du -sb dist/bundle.js | cut -f1
      name: bundle_bytes
      direction: lower
\`\`\`

## Hints

- build-perf: tree-shaking in utils/, barrel exports may block dead-code elimination
- test-speed: jest worker count, transform cache, test isolation overhead
- bundle-size: dynamic imports, externals, minification settings
```
