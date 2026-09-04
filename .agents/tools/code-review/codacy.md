---
description: Codacy auto-fix for code quality issues
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Codacy Auto-Fix Integration Guide

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Auto-fix:** `bash .agents/scripts/codacy-cli.sh analyze --fix`
- **Via manager:** `bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix`
- **Fix types:** Code style, best practices, security, performance, maintainability
- **Safety:** Non-breaking, reversible, conservative (skips ambiguous)
- **Metrics:** 70-90% time savings, 99%+ accuracy, 60-80% violation coverage
- **Cannot fix:** Complex logic, architecture, context-dependent, breaking changes
- **Workflow:** quality-check → analyze --fix → quality-check → commit with metrics

## Quality Gate Settings

**Current gate (PR and commits):** max 10 new issues, minimum severity Warning.

**Rationale (GH#4910, t1489):** Originally 0 max new issues. Tripped 4x during extract-function refactoring — new helper functions add complexity counts, subprocess calls trigger Bandit warnings. Project grade stays A; these aren't real regressions. Raised to 10 Warning+ to absorb refactoring noise while blocking genuine issues.

**Do not revert to 0.** Threshold 0 makes extract-function refactoring impossible without manual Codacy dashboard intervention per PR. The project grade (A) is the meaningful quality signal, not per-PR new-issue count.

## Local Pre-Push Checks (GH#4939)

`linters-local.sh` includes checks aligned with Codacy's complexity engine, catching issues locally before push:

| Check | Codacy equivalent | Warning | Blocking | Gate |
|-------|-------------------|---------|----------|------|
| `function-complexity` | Function length | >50 lines | >100 lines | `function-complexity` |
| `nesting-depth` | Cyclomatic complexity | >5 levels | >8 levels | `nesting-depth` |
| `file-size` | File length | >800 lines | >1500 lines | `file-size` |
| `python-complexity` | Lizard CCN | >8 (advisory) | — | `python-complexity` |

`python-complexity` runs Lizard (same tool Codacy uses) and Pyflakes locally.

Gates are set above current baseline to catch regressions. Reduce thresholds as existing debt is paid down (via code-simplifier issues). Also covers Python files in `.agents/scripts/` for file-size checks.

CI enforcement: `.github/workflows/code-quality.yml` runs the same checks on every PR via the `complexity-check` job, blocking merges that exceed thresholds.

Skip via bundle config: add gate names to `skip_gates` in the project bundle.

## Codacy API Patterns (verified working)

```bash
# Commit delta statistics (new issues count + complexity delta)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/deltaStatistics"

# Per-file new issues (paginate with cursor)
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/commits/<SHA>/files?limit=100"
# Filter: .data[] | select(.quality.deltaNewIssues > 0)

# Search all issues (POST, filter by language)
curl -s -H "api-token: $CODACY_API_TOKEN" -H "Content-Type: application/json" \
  -X POST "https://app.codacy.com/api/v3/analysis/organizations/gh/marcusquinn/repositories/aidevops/issues/search?limit=50" \
  -d '{"languages": ["Python"]}'
```

## Quality-sweep health telemetry

The daily quality sweep reads the repository summary and issue overview without
changing Codacy settings. It renders grade, issue count, analysed LOC, complex
files, analysed SHA, and one explicit state:

| State | Meaning | Operator response |
|-------|---------|-------------------|
| `BASELINE_UNKNOWN` | A current analysis was recorded, but no trusted prior sample exists. | Wait for the next sweep before comparing LOC. |
| `HEALTHY` | The analysed SHA matches the remote default head and LOC is at least 80% of the prior healthy sample. | Treat the telemetry as comparable. |
| `STALE_ANALYSIS` | Codacy analysed a different commit from the remote default head. | Request/retry analysis; do not compare findings yet. |
| `INDEX_DEGRADED` | Current analysed LOC is below 80% of the last healthy sample. | Investigate Codacy indexing; the healthy denominator is retained. |
| `POLICY_DRIFT` | A documented-noise rule has a non-zero overview count. | Investigate coding-standard drift; do not change external settings from the sweep. |
| `UNKNOWN` | An API, parse, remote-SHA, or state-write failure prevented a trustworthy classification. | Resolve telemetry failure and retain the previous baseline. |

Healthy samples are stored atomically in `QUALITY_SWEEP_STATE_DIR` per repository.
Stale, degraded, malformed, and API-failure samples never replace that baseline.
The documented-noise rules are `Bandit_B404`, `ESLint8_es-x_no-modules`,
`ESLint8_es-x_no-block-scoped-variables`, and
`ESLint8_es-x_no-trailing-commas`; their counts are observational evidence, not
permission to alter Codacy, Bandit, ESLint, or exclusions.

**Updating quality gate via API:**

```bash
# Update PR gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/pull-requests" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'

# Update commits gate
curl -s -H "api-token: $CODACY_API_TOKEN" \
  "https://app.codacy.com/api/v3/organizations/gh/marcusquinn/repositories/aidevops/settings/quality/commits" \
  -X PUT -H "Content-Type: application/json" \
  -d '{"issueThreshold":{"threshold":10,"minimumSeverity":"Warning"}}'
```

<!-- AI-CONTEXT-END -->

## Usage

### Direct CLI

```bash
bash .agents/scripts/codacy-cli.sh analyze --fix           # Auto-fix
bash .agents/scripts/codacy-cli.sh analyze eslint --fix     # Specific tool
bash .agents/scripts/codacy-cli.sh analyze                  # Dry-run (what would be fixed)
```

### Via Quality CLI Manager

```bash
bash .agents/scripts/quality-cli-manager.sh analyze codacy-fix
bash .agents/scripts/quality-cli-manager.sh status codacy
```

### Pre-Commit Workflow

```bash
bash .agents/scripts/linters-local.sh              # 1. Identify issues
bash .agents/scripts/codacy-cli.sh analyze --fix    # 2. Auto-fix
bash .agents/scripts/linters-local.sh              # 3. Verify improvements
```

### CI/CD Integration

```yaml
# GitHub Actions example
- name: Auto-fix code quality issues
  run: |
    bash .agents/scripts/codacy-cli.sh analyze --fix
    git add .
    git diff --staged --quiet || git commit -m "fix: applied Codacy automated fixes"
```
