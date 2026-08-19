---
description: Error checking, debugging, and feedback loops for CI/CD
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

# Error Checking and Feedback Loops

## CI Error Resolution Loop

```bash
gh run list --status failure --limit 1          # identify failure
gh run view {run_id} --log-failed               # diagnose
# fix locally, then:
git add . && git commit -m "fix: CI error description"
git push origin {branch} && gh run watch {run_id}
```

## GitHub Actions Monitoring

```bash
gh run list --limit 10                          # recent runs
gh run list --status failure --limit 5          # failed runs only
gh run view {run_id} --log-failed               # failure logs
gh run watch {run_id}                           # watch live
gh api repos/{owner}/{repo}/actions/runs --jq '.workflow_runs[:5] | .[] | "\(.name): \(.conclusion // .status)"'
```

## Code Quality Tools

```bash
bash ~/.aidevops/agents/scripts/linters-local.sh           # universal quality check
bash ~/.aidevops/agents/scripts/qlty-cli.sh fmt --all      # auto-fix all
shellcheck script.sh                                       # bash scripts
npx --no-install eslint . --format json                    # Existing JavaScript linter
pylint module/ --output-format=json                        # Python
```

## Quality Feedback via GitHub Checks API

```bash
REPO="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
SHA="$(git rev-parse HEAD)"

# All check runs (status summary)
gh api "repos/$REPO/commits/$SHA/check-runs" \
  --jq '.check_runs[] | "\(.conclusion // .status | ascii_upcase)\t\(.name)"' | sort

# Failed checks only
gh api "repos/$REPO/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "action_required") | {name: .name, conclusion: .conclusion}'

# Line-level annotations from a check run
gh api repos/{owner}/{repo}/check-runs/{check_run_id}/annotations \
  --jq '.[] | {path: .path, line: .start_line, level: .annotation_level, message: .message}'

# Bot-specific queries (Codacy / CodeRabbit / SonarCloud)
gh api "repos/$REPO/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.app.slug == "codacy-production") | {conclusion: .conclusion, summary: .output.summary}'
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  --jq '.[] | select(.user.login | contains("coderabbit")) | {path: .path, line: .line, body: .body}'
gh api "repos/$REPO/commits/$SHA/check-runs" \
  --jq '.check_runs[] | select(.name | contains("SonarCloud")) | {conclusion: .conclusion, url: .details_url}'
```

**Processing feedback:** Collect (`gh pr view {pr_number} --comments --json comments` + `gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews`). Prioritize: Critical (security, breaking) → High (quality) → Medium (style) → Low (docs). Fix critical first; group related.

## Escalation to Humans

Escalate: product design decisions, security-critical changes, architectural decisions, deployment approvals, ambiguous requirements.

Format: issue summary → context (goal + what happened) → error details → attempted solutions → specific questions → recommendations with pros/cons.

## Contributing Fixes Upstream

See `reference/external-repo-submissions.md` for fork/PR workflow to external repos.
