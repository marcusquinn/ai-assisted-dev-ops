---
description: Auto-research autonomous experiment loop — optimize code, agents, or standalone research programs
agent: autoresearch
mode: subagent
model: standard
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run an autonomous experiment loop that modifies code, measures a metric, and keeps only improvements.

Canonical command: `/auto-research`.

Compatibility alias: `/autoresearch` remains supported for existing tasks, memories,
and older runbooks. Prefer `/auto-research` in new docs and user-facing prompts.

Use `/deep-research` instead when the desired deliverable is a cited research
report, source ledger, claim ledger, outline, and export bundle rather than a
metric-driven modify/measure/keep loop.

Arguments: $ARGUMENTS

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| `--program <path>` | `/auto-research --program todo/research/optimize-build.md` | Skip interview, run directly |
| One-liner | `/auto-research "reduce build time"` | Infer defaults, short confirmation |
| Bare | `/auto-research` | Full interactive setup |
| Init | `/auto-research init "name"` | Scaffold standalone research repo |
| Compatibility alias | `/autoresearch --program todo/research/optimize-build.md` | Same behaviour; deprecated spelling |

## Step 1: Resolve Invocation Pattern

```text
if $ARGUMENTS starts with "init ":      → Init Mode
elif $ARGUMENTS contains "--program ":  → extract program path, skip to Step 3
elif $ARGUMENTS contains "--population" or "--dimensions" or "--concurrent":
                                        → extract flags, merge with one-liner or bare mode
elif $ARGUMENTS is non-empty:           → One-Liner Mode (infer all fields, show summary)
else:                                   → Interactive Setup (Q1–Q8 below)
```

### Concurrency CLI Flags

| Flag | Example | Behaviour |
|------|---------|-----------|
| `--population N` | `/auto-research --population 4` | Population-based mode: N hypotheses per iteration, keep best |
| `--dimensions "d1,d2,d3"` | `/auto-research --dimensions "build-perf,test-speed,bundle-size"` | Multi-dimension mode: separate agent per dimension |
| `--concurrent N` | `/auto-research --concurrent 3` | Shorthand: N sequential agents on different repos |

**Multi-dimension dispatch** (when `--dimensions` is provided): validate targets don't overlap (error if they do); generate shared convoy ID `autoresearch-{name}-$(date +%Y%m%d-%H%M%S)`; dispatch each dimension as a separate subagent session with its own worktree; show summary on completion.

**One-Liner summary format** (headless: skip confirmation):

```text
Research program: optimize-build-time
  Mode:       in-repo (.)
  Files:      webpack.config.js, tsconfig.json, src/**/*.ts
  Metric:     build_time_seconds (lower) — npm run build 2>&1 | grep 'Time:' | awk '{print $2}'
  Constraints: npm test
  Budget:     2h / 50 iterations / 5m per-experiment
  Models:     researcher=standard

[Enter] confirm  [e] edit  [q] quit
```

## Step 2: Interactive Setup (Q1–Q8)

Ask sequentially; show inferred default as option 1; Enter accepts default.

**Q1 — What are you researching?**

| Signal | Suggestion |
|--------|-----------|
| Repo is aidevops | "agent instruction optimization (reduce tokens, improve pass rate)" |
| `package.json` | "build time reduction" or "test suite speed" |
| `pyproject.toml` / `setup.py` | "pytest suite speed" or "import time" |
| `Cargo.toml` | "cargo build time" or "benchmark regression" |
| `Makefile` / `CMakeLists.txt` | "build time" |
| `go.mod` | "go test or go build time" |
| No signal | "code quality improvement" |

**Q2 — Where does the work happen?**

```text
1. This repo (.)                    [default]
2. Another managed repo (which?)    → validate in ~/.config/aidevops/repos.json
3. New standalone repo              → Init Mode
```

**Q3 — What files can be modified?**

| Q1 contains | Suggestion |
|-------------|-----------|
| "agent" / "instruction" / "prompt" | `.agents/**/*.md, .agents/prompts/*.txt` |
| "build" / "webpack" / "bundle" | `webpack.config.js, tsconfig.json, src/**/*.ts` |
| "test" / "pytest" / "jest" | `tests/**/*.py, conftest.py` or `tests/**/*.ts, jest.config.js` |
| "performance" / "speed" | `src/**/*.{ts,js,py}` |
| default | `src/**/*` |

**Q4 — Success metric?**

| Context | Command | Name | Direction |
|---------|---------|------|-----------|
| aidevops + "agent" | `agent-test-helper.sh run {suite} --json \| jq '.composite_score'` | `composite_score` | higher |
| aidevops + "token" | `agent-test-helper.sh run {suite} --json \| jq '.avg_response_chars'` | `avg_response_chars` | lower |
| Node + "build" | `npm run build 2>&1 \| grep 'Time:' \| awk '{print $2}'` | `build_time_seconds` | lower |
| Node + "test" | `npm test -- --json 2>/dev/null \| jq '.numPassedTests'` | `tests_passed` | higher |
| Python + "test" | `pytest --tb=no -q 2>&1 \| grep passed \| awk '{print $1}'` | `tests_passed` | higher |
| Python + "speed" | `hyperfine --runs 3 'python main.py' --export-json /tmp/bench.json && jq '.results[0].mean' /tmp/bench.json` | `execution_seconds` | lower |
| Cargo + "bench" | `cargo bench 2>&1 \| grep 'time:' \| awk '{print $5}'` | `bench_ns` | lower |
| default | ask user | — | — |

**Q5 — Constraints?** Auto-detect test command:

```text
1. Existing detected tests must keep passing: <detected command>  [default: include when configured]
2. No new dependencies                  [default: include]
3. Keep public API unchanged            [default: skip]
4. Lint clean                           [default: skip]
5. Custom constraint
```

**Q6 — Budget?** Defaults: `2h / 50 iterations / 5m per-experiment / no goal`.

**Q7 — Workload tiers?** Defaults: `researcher=standard, evaluator=simple`.
Ask about the Target tier only if Q1 mentions "agent" or "instruction"
(`target=standard`). Concrete target models are accepted only for an explicitly
declared, like-for-like model benchmark; runtime configuration maps normal tiers.

**Q8 — Concurrency?**

```text
1. Sequential [default] — one hypothesis at a time, lowest cost
2. Population-based — N hypotheses per iteration, keep best (ask: how many? default: 4)
3. Multi-dimension — parallel agents on independent file sets (ask: which dimensions?)
```

| Signal | Suggestion |
|--------|-----------|
| User mentions "fast" or "overnight" | Suggest population-based (N=4) |
| Multiple independent metrics detected | Suggest multi-dimension |
| Single metric, single file set | Sequential (default) |

Multi-dimension selected: prompt for dimensions (suggest splitting by file area), validate no overlap, generate convoy ID automatically.

## Step 3: Write Research Program

Write to `todo/research/{name}.md` from `.agents/templates/research-program-template.md`:

- YAML frontmatter: `name`, `mode`, `target_repo`
- `## Target`: `files:`, `branch:`
- `## Metric`: `command:`, `name:`, `direction:`, `baseline: null`
- `## Constraints`, `## Models`, `## Budget`
- `## Concurrency`: `mode:`, `population_size:` (if population), `convoy_id: null`
- `## Dimensions`: populated if multi-dimension, commented out otherwise

Confirm: "Research program written to `todo/research/{name}.md`."

## Step 4: Dispatch

```text
1. Begin now (dispatch to autoresearch subagent)    [default]
2. Queue for later (add to TODO.md)
3. Show program file and exit
```

Headless: begin now (option 1).

**Begin now:** dispatch to `.agents/tools/autoresearch/autoresearch.md` with `--program todo/research/{name}.md`.

**Queue:** add to TODO.md:

```text
- [ ] t{next_id} autoresearch: {name} — {description} #auto-dispatch ~{hours}h ref:GH#{issue}
```

## Init Mode (`/auto-research init "name"`)

`/autoresearch init "name"` is accepted as a compatibility alias.

Scaffold a standalone research repo at `~/Git/autoresearch-{name}/` (`autoresearch-` prefix mandatory for discoverability).

**I1: Validate name** — slugify (lowercase, hyphens). Error if path already exists.

**I2: Prompts** (skip if headless; defaults: description=empty, GitHub=no, pulse=no, begin=no):

```text
1. Description? (one line)     → [Enter to skip]
2. Create GitHub remote? [y/N]
3. Enable pulse dispatch? [y/N]
4. Begin experiment loop now? [y/N]
```

**I3: Scaffold:**

```bash
mkdir -p "$REPO_PATH/baseline" "$REPO_PATH/results" "$REPO_PATH/todo/research"
touch "$REPO_PATH/baseline/.gitkeep" "$REPO_PATH/results/.gitkeep"
```

Write `$REPO_PATH/program.md` (README) and `$REPO_PATH/todo/research/program.md` from template (`mode: standalone`, `target_repo: .`, `files: baseline/**/*`). Write `$REPO_PATH/.gitignore`: `results/`, `*.log`, `.DS_Store`.

**I4–I5: Init:**

```bash
git -C "$REPO_PATH" init && git -C "$REPO_PATH" add . && git -C "$REPO_PATH" commit -m "chore: init autoresearch-{name} repo"
aidevops init --path "$REPO_PATH" --non-interactive  # warn and continue if unavailable
```

**I6: Register in `~/.config/aidevops/repos.json`:**

```json
{
  "path": "~/Git/autoresearch-{name}",
  "slug": "local/autoresearch-{name}",
  "local_only": true,
  "pulse": false,
  "priority": "research",
  "app_type": "generic",
  "maintainer": "<gh api user --jq '.login'>"
}
```

**I7: Optional GitHub remote:**

```bash
gh repo create "autoresearch-{name}" --private --source "$REPO_PATH" --push
```

On success: remove `local_only`, set `slug: "{gh_username}/autoresearch-{name}"`. On failure: warn, keep `local_only: true`.

**I8: Optional pulse** — set `"pulse": true`; suggest `"pulse_hours": {"start": 17, "end": 5}` for overnight runs.

**I9: Optional begin now** — dispatch `/auto-research --program "$REPO_PATH/todo/research/program.md"`. Otherwise print next steps:

```text
Repo ready at ~/Git/autoresearch-{name}/
  1. Edit todo/research/program.md — define metric, files, budget
  2. Add starting code/data to baseline/
  3. Run: /auto-research --program ~/Git/autoresearch-{name}/todo/research/program.md
```

## Related

`.agents/templates/research-program-template.md` · `.agents/tools/autoresearch/autoresearch.md` · `.agents/scripts/commands/deep-research.md` · `todo/research/`
