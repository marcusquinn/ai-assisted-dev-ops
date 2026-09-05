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

**Historical rationale (GH#4910, t1489):** Originally 0 max new issues. Tripped 4x during extract-function refactoring — new helper functions add complexity counts, subprocess calls trigger Bandit warnings. The grade remained A during that investigation. Raised to 10 Warning+ to absorb refactoring noise; this historical decision does not establish today's grade or justify ignoring genuine new findings.

**Do not change thresholds merely to improve a badge.** Evaluate the live project grade, analysis completeness, and individual findings together. A passing per-PR issue-count gate does not establish an A-grade repository.

## Local Pre-Push Checks (GH#4939)

`linters-local.sh` includes checks aligned with Codacy's complexity engine, catching issues locally before push:

| Check | Codacy equivalent | Warning | Blocking | Gate |
|-------|-------------------|---------|----------|------|
| `function-complexity` | Function length | >50 lines | >100 lines | `function-complexity` |
| `nesting-depth` | Cyclomatic complexity | >5 levels | >8 levels | `nesting-depth` |
| `file-size` | Non-README Markdown length | >500 lines | New violations | `file-size` |
| `python-complexity` | Lizard CCN | >8 (advisory) | — | `python-complexity` |

`python-complexity` runs Lizard (same tool Codacy uses) and Pyflakes locally.

Use the checked-in linter and CI policy as the authority for thresholds. Pay down existing debt through bounded fixes; do not increase allowances to pass a quality campaign.

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
files, analysed SHA, an analysis-health state, and a separate A-grade target.

For a read-only remote report without posting to GitHub or running other scanners:

```bash
bash .agents/scripts/stats-quality-sweep-tools.sh codacy OWNER/REPO /path/to/repo
```

The command uses the existing Codacy account token from secure storage. It only
updates the local healthy-sample file when the evidence permits it. Override
`QUALITY_SWEEP_STATE_DIR` to isolate a diagnostic run from daily-sweep state.

The verified API v3.1.0 contracts are:

- Repository summary: `GET /analysis/organizations/gh/{owner}/repositories/{repo}`;
  fields are `data.gradeLetter`, `data.issuesCount`, `data.loc`,
  `data.complexFilesCount`, and `data.lastAnalysedCommit.sha`.
- Issue overview: `POST /analysis/organizations/gh/{owner}/repositories/{repo}/issues/overview`
  with `{"branchName":"<summary branch>"}`; complete rule counts are under
  `data.counts.patterns[]` as `id` and `total`. A first search page is not an
  aggregate and must never establish zero policy drift.
- The summary defaults to Codacy's configured default branch, not a hard-coded
  `main`. Its analysed SHA must match `git ls-remote origin HEAD`.

| State | Meaning | Operator response |
|-------|---------|-------------------|
| `BASELINE_UNKNOWN` | A current, drift-free analysis was recorded, but no trusted prior sample exists. | Independently check indexing scope before relying on the new baseline. |
| `HEALTHY` | The analysed SHA matches the remote default head, LOC is at least 80% of the healthy high-water sample, and overview data is valid and drift-free. | Treat the telemetry as comparable; this does not mean grade A. |
| `STALE_ANALYSIS` | Codacy analysed a different commit from the remote default head. | Request/retry analysis; do not compare findings yet. |
| `INDEX_DEGRADED` | Current analysed LOC is below 80% of the last healthy sample. | Investigate Codacy indexing; the healthy denominator is retained. |
| `POLICY_DRIFT` | A documented-noise rule has a non-zero overview count. | Investigate coding-standard drift; do not change external settings from the sweep. |
| `UNKNOWN` | An API, parse, remote-SHA, or state-write failure prevented a trustworthy classification. | Resolve telemetry failure and retain the previous baseline. |

Healthy samples are stored atomically in `QUALITY_SWEEP_STATE_DIR` per repository.
Stale, degraded, policy-drift, malformed, and API-failure samples never replace
that baseline, including on first observation. Small LOC drops retain the entire
prior sample, so successive drops cannot gradually normalize a collapsed index.
An intentional analysis-scope reduction requires an independently verified new
baseline; do not erase state merely to clear an index warning.
The documented-noise rules are `Bandit_B404`, `ESLint8_es-x_no-modules`,
`ESLint8_es-x_no-block-scoped-variables`, and
`ESLint8_es-x_no-trailing-commas`; their counts are observational evidence, not
permission to alter Codacy, Bandit, ESLint, or exclusions.

The separate **Grade target** is `A / AT_TARGET`, `A / BELOW_TARGET`, or
`A / UNVERIFIED`. Only a current A with `HEALTHY` analysis is verified at target.
A current B–F remains below target even if indexing or policy needs investigation;
stale, invalid, or incomplete telemetry cannot verify the target.

## Restoring and maintaining A

1. **Verify the denominator first.** Compare the live summary with
   `GET /analysis/organizations/gh/{owner}/repositories/{repo}/commit-statistics?days=10`
   and the corresponding Git changes. On 2026-08-29 the aidevops index dropped from
   814,993 to 285,591 LOC while findings changed from 2,361 to 2,356. Do not describe
   such a discontinuity as thousands of newly introduced defects.
2. **Recover indexing through authorised Codacy operations.** The documented
   `POST /organizations/gh/{owner}/repositories/{repo}/reanalyzeCommit` accepts
   `{"commitUuid":"<verified SHA>","cleanCache":true}`. Verify the completed
   analysis and restored scope, not just an accepted request. A 403 is an access
   blocker: use an authorised account or Codacy support, not repeated requests,
   synthetic source edits, or expanded exclusions.
3. **Triage genuine findings in small batches.** Start with security/error findings,
   then high-density complexity, duplication and unused-code hotspots. Inspect
   actual callsites and preserve behaviour. Incorrect language-version rules need
   a documented configuration correction, not obsolete rewrites or blanket ignores.
   Codacy's configuration file cannot enable/disable tools; verify actual tool
   settings rather than assuming `engines.*.enabled` entries take effect.
4. **Prevent new debt.** Run scoped local lint and applicable existing tests, review
   exact-head Codacy annotations, and retain required PR gates. A tolerated new-issue
   count is not a daily debt budget. The daily sweep must surface below-target and
   unknown states for investigation, with deduplicated, owner-assigned remediation.
5. **Verify publication honestly.** Record the analysed SHA and live grade after
   merge/release. Keep the live badge visible; never substitute a hard-coded A or
   zero-findings claim. A release can deliver safeguards without proving restoration:
   report any unresolved service-side blocker separately and keep that objective open.

Sources: [API schema](https://api.codacy.com/api/api-docs/swagger.yaml),
[Codacy configuration](https://docs.codacy.com/repositories-configure/codacy-configuration-file/),
[quality metrics](https://docs.codacy.com/faq/code-analysis/which-metrics-does-codacy-calculate/).
Codacy's numeric grade boundaries and metric weights are not published there;
use `gradeLetter` rather than inventing a numeric A cutoff.

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
