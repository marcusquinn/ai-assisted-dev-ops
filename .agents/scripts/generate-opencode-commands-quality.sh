#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Generate OpenCode Commands -- Quality & Review
# =============================================================================
# Quality, review, and check command definitions for OpenCode.
#
# Usage: source "${SCRIPT_DIR}/generate-opencode-commands-quality.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - create_command() from the orchestrator
#   - AGENT_BUILD constant from the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OPENCODE_CMDS_QUALITY_LOADED:-}" ]] && return 0
_OPENCODE_CMDS_QUALITY_LOADED=1

# --- Quality & Review Commands ---
# Split into review-focused and check-focused sub-groups for readability.

define_review_commands() {
	create_command "agent-review" \
		"Systematic review and improvement of agent instructions" \
		"$AGENT_BUILD" "true" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/tools/build-agent/agent-review.md and follow it as the canonical review rubric.

Review target: $ARGUMENTS

If no target is provided, review the instruction surfaces used in this session.
BODY

	create_command "review-issue-pr" \
		"Review external issue or PR - validate problem and evaluate solution" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/review.md, select the maintainer policy, then follow ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/review-issue-pr.md.

Review this issue or PR: $ARGUMENTS

This is the legacy alias for `/review issue ...` or `/review pr ...`.

**Usage:**
- `/review-issue-pr 123` - Review issue or PR by number
- `/review-issue-pr https://github.com/owner/repo/issues/123` - Review by URL
- `/review-issue-pr https://github.com/owner/repo/pull/456` - Review PR by URL

**Core questions to answer:**
1. Is the issue real? (reproducible, not duplicate, actually a bug)
2. Is this the best solution? (simplest approach, fixes root cause)
3. Is the scope appropriate? (minimal changes, no scope creep)

End every completed review with the exact ready-to-run approval command when the recommendation is Approve. Group same-kind targets as `sudo aidevops approve issue|pr N N... owner/repo`, or mixed targets as `sudo aidevops approve batch issue:N pr:N... owner/repo`; otherwise state why no approval command is appropriate.
BODY

	create_command "code-standards" \
		"Check code against documented quality standards" \
		"$AGENT_BUILD" "true" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/tools/code-review/code-standards.md and follow its instructions.

Check target: $ARGUMENTS

This validates against our documented standards:
- S7682: Explicit return statements
- S7679: Positional parameters assigned to locals
- S1192: Constants for repeated strings
- S1481: No unused variables
- ShellCheck: Zero violations
BODY

	create_command "code-simplifier" \
		"Simplify and refine code for clarity, consistency, and maintainability" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/tools/code-review/code-simplifier.md and follow it as the canonical analysis guide.

Target: $ARGUMENTS
BODY

	return 0
}

define_check_commands() {
	create_command "preflight" \
		"Run quality checks before version bump and release" \
		"$AGENT_BUILD" "true" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)
BODY

	create_command "postflight" \
		"Check code audit feedback on latest push (branch or PR)" \
		"$AGENT_BUILD" "true" <<'BODY'
Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If in a linked worktree with open PR -> check that PR's feedback
2. If in a linked worktree without PR -> check ref CI status
3. If on main -> check latest commit's CI/audit status
4. If no git context or ambiguous -> ask user which branch/PR to check

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status
5. Any blocking issues that need resolution

**Commands used:**
- `gh pr view --json reviews,comments` (if PR exists)
- `gh run list --branch=<branch>` (CI status)
- `gh api repos/{owner}/{repo}/commits/{sha}/check-runs` (detailed checks)

Report findings and recommend next actions (fix issues, merge, etc.)
BODY

	create_command "linters-local" \
		"Run local linting tools (ShellCheck, secretlint, pattern checks)" \
		"$AGENT_BUILD" "" <<'BODY'
Run the local linters script:

!`${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/linters-local.sh $ARGUMENTS`

This runs fast, offline checks:
1. ShellCheck for shell scripts
2. Secretlint for exposed secrets
3. Pattern validation (return statements, positional parameters)
4. Markdown formatting checks

For remote auditing (CodeRabbit, Codacy, SonarCloud), use /code-audit-remote
BODY

	create_command "code-audit-remote" \
		"Run remote code auditing (CodeRabbit, Codacy, SonarCloud)" \
		"$AGENT_BUILD" "true" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/code-audit-remote.md and follow its instructions.

Audit target: $ARGUMENTS

This calls external quality services:
1. CodeRabbit - AI-powered code review
2. Codacy - Code quality analysis
3. SonarCloud - Security and maintainability

For local linting (fast, offline), use /linters-local first
BODY

	return 0
}

define_quality_commands() {
	define_review_commands
	define_check_commands
	return 0
}
