---
description: Verify release health after tag and GitHub release
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Postflight Verification Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Verify release health after `release.md` completes
- **Trigger**: After tag creation and GitHub release publication
- **Timeouts**: CI/CD 10 min, code review tools 5 min
- **Script**: `.agents/scripts/postflight-check.sh` (canonical implementation)
- **GH Actions**: `.github/workflows/postflight.yml` (canonically dispatched by verified package publication)
- **Rollback**: See [Rollback Procedures](#rollback-procedures)

<!-- AI-CONTEXT-END -->

## Critical: Avoiding Circular Dependencies

Exclude the postflight workflow itself when checking CI/CD status:

```bash
SELF_NAME="Verify Release Health"
gh api repos/{owner}/{repo}/commits/{sha}/check-runs \
  --jq "[.check_runs[] | select(.status != \"completed\" and .name != \"$SELF_NAME\")] | length"
```

## Postflight Checklist

Check both `main` and tag refs: `gh run list --branch=main --limit=5` and `gh run list --branch=v{VERSION} --limit=5`.

### 1. CI/CD Pipeline Status

| Check | Command | Expected |
|-------|---------|----------|
| GitHub Actions | `gh run list --limit=5` | All passing |
| Tag workflows | `gh run list --workflow=code-quality.yml` | Success |
| Version validation | `gh run list --workflow=version-validation.yml` | Success |

### 2. Code Quality Tools

| Tool | Threshold |
|------|-----------|
| SonarCloud | No new bugs, vulnerabilities, or code smells |
| Codacy | Grade maintained (A/B) |
| CodeRabbit | No blocking issues |
| Qlty | No new violations |

### 3. Security Evidence

| Tool | Threshold |
|------|-----------|
| Required CI security checks | Terminal success for the released SHA |
| Dependabot | No new alerts |

## Running Postflight

Wait for `postflight.yml` GH Actions workflow to complete before running locally. Only declare success if ALL workflows passed.

**Local**: `.agents/scripts/postflight-check.sh` — verifies CI/CD and external
quality-gate state. It does not rescan source: targeted/affected checks belong to
development and PR CI, while release preflight owns any evidence-triggered broad
gate. Use `--security-only` only for explicit diagnostics, not routine release
completion.

**Automated**: `.github/workflows/publish-packages.yml` dispatches `.github/workflows/postflight.yml` with its verified exact tag only after GitHub, npm, and Homebrew verification succeeds. `postflight.yml` accepts that canonical `workflow_dispatch` input and reports terminal CI and external quality evidence without reinstalling scanners or duplicating source analysis.

Do not duplicate these scripts inline — they are the source of truth. Read them directly when implementation details are needed.

## Rollback Procedures

### Severity Assessment

| Severity | Indicators | Action |
|----------|------------|--------|
| **Critical** | Security vulnerability, data loss, service outage | Immediate rollback |
| **High** | Broken functionality, failed tests, quality gate failure | Rollback within 1 hour |
| **Medium** | Minor regressions, code smell increase | Hotfix in next release |
| **Low** | Style issues, documentation gaps | Fix in next release |

### Rollback Commands

```bash
# Signed release tags and published versions are immutable. Roll forward from a
# reviewed revert or hotfix PR; never delete or retag a release.
# Option A: Create a reviewed revert in a safe linked worktree
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add revert/v{NEW_VERSION} --base origin/main
# After changing into the printed worktree: git revert <defective-commit-hash>,
# verify, commit, open/merge the PR, then publish a new patch through `aidevops release`.
# Option B: Hotfix release from a safe linked worktree
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add hotfix/v{VERSION}.1 --base v{VERSION}
# Critical: cd into the linked worktree path printed by the helper before editing;
# otherwise commits land in the canonical checkout, which can corrupt main state
# or disrupt active agents that depend on their own linked worktrees.
# Example after changing into that linked worktree: stage the intended files first,
# because `git commit -m` without staging can create an empty or incomplete commit.
# git add <changed-files> && git commit -m "fix: resolve critical issue"
# Open and merge the reviewed PR, then run: aidevops release patch <merged-pr>
```

Post-rollback: verify terminal CI and deployment health for the rollback SHA. A
hotfix returns through targeted development checks and normal release preflight;
postflight does not rerun source lint.

## Handling SonarCloud Quality Gate Failures

### Security Hotspots

Security hotspots require **individual human review**, not blanket dismissal.

```bash
curl -s "https://sonarcloud.io/api/hotspots/search?projectKey=marcusquinn_aidevops&status=TO_REVIEW" | \
  jq '{total: .paging.total, by_rule: ([.hotspots[] | .ruleKey] | group_by(.) | map({rule: .[0], count: length}))}'
```

Review each individually in SonarCloud — mark **Safe** (with comment), **Fixed**, or **Acknowledged** (accepted risk). Never blanket-dismiss; real vulnerabilities hide among false positives.

| Rule | Typical Resolution |
|------|--------------------|
| `shell:S5332` | Safe: "Localhost HTTP intentional for local dev" |
| `shell:S6505` | Safe: "Postinstall scripts required for package setup" |
| `shell:S6506` | Safe: "Installing from trusted npm registry" |

### Bugs, Vulnerabilities, or Code Smells

```bash
curl -s "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&resolved=false&types=BUG,VULNERABILITY" | \
  jq '.issues[] | {type, severity, message, file: .component}'
```

Fix in code, not dismissed, unless clear false positives.

## Worktree Cleanup

```bash
~/.aidevops/agents/scripts/worktree-helper.sh list
~/.aidevops/agents/scripts/worktree-helper.sh clean  # Auto-detects squash merges
```

## Related Workflows

- `release.md` - Pre-release and release process
- `code-review.md` - Code review guidelines
- `version-bump.md` - Version management
- `worktree.md` - Parallel branch development
