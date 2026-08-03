#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2086
# =============================================================================
# Local Linters - Fast Offline Quality Checks (Orchestrator)
# =============================================================================
# Thin orchestrator that sources sub-libraries and runs all quality gates.
# Split from a monolithic 1567-line file into focused modules (GH#21296).
#
# Sub-libraries:
#   - linters-local-validators.sh — pattern validation, shell linting, secrets
#   - linters-local-analysis.sh   — complexity, formatting, misc checks
#   - linters-local-gates.sh      — bundle-aware gate filtering / dispatch
#   - linters-local-ratchet.sh    — anti-pattern regression ratchets
#
# Checks performed (via sub-libraries):
#   - ShellCheck for shell scripts
#   - Secretlint for exposed secrets
#   - Pattern validation (return statements, positional parameters)
#   - Markdown formatting
#   - Report renderer fixtures and command docs are covered by
#     tests/test-report-render-helper.sh
#   - Skill frontmatter validation (name field matches skill-sources.json)
#   - Ratchet quality checks (anti-pattern regression prevention)
#   - Function complexity, nesting depth, file size
#   - Bash 3.2 compatibility
#   - Pulse wrapper canary
#
# For remote auditing (CodeRabbit, Codacy, SonarCloud), use:
#   /code-audit-remote or code-audit-helper.sh
#
# Execution flags:
#   --changed           Changed-file scope (default; safety gates still run)
#   --no-cache          Do not reuse broad/advisory gate cache entries
#   --full              Release-boundary path: run every gate without cache/time-budget downgrade
#   --strict            Make ratchet failures and broad-gate timeouts blocking
# Ratchet flags:
#   --update-baseline   Record only same/lower committed compatibility counts
#   --init-baseline     Same as --update-baseline (alias for first-time setup)
#   --migrate-baseline  Explicit schema/count migration; requires evidence env vars
#   --strict            Make ratchet failures blocking (default: advisory)
#   --changed           Fast PR mode: run changed-file safety gates only
#   --fast-pr           Alias for --changed
#   --full              Run the broad local sweep for release boundaries
#   RATCHET_STEP_TIMEOUT_SECONDS=N bounds each ratchet counter (default: 120)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/lint-file-discovery.sh"
# shellcheck source=./linters-local-ratchet.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-ratchet.sh"
# shellcheck source=./linters-local-validators.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-validators.sh"
# shellcheck source=./linters-local-analysis.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-analysis.sh"
# shellcheck source=./linters-local-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/linters-local-gates.sh"

set -euo pipefail

# Color codes for output

# Quality thresholds
# Note: These thresholds are set to allow existing code patterns while catching regressions
# - Return issues: Simple utility functions (log_*, print_*) don't need explicit returns
# - Positional params: Using $1/$2 in case statements and argument parsing is valid
#   SonarCloud S7679 reports ~200 issues; local check is more aggressive (~280)
#   Threshold set to catch regressions while allowing existing patterns
# - String literals: Code duplication is a style issue, not a bug
readonly MAX_TOTAL_ISSUES=100
readonly MAX_RETURN_ISSUES=10
readonly MAX_POSITIONAL_ISSUES=300
readonly MAX_STRING_LITERAL_ISSUES=2300

# Complexity thresholds (aligned with Codacy defaults — GH#4939)
# These catch the same issues Codacy flags so they're caught locally before push.
# Thresholds are set above the current baseline to catch regressions, not existing debt.
# Existing debt is tracked by the code-simplifier (priority 8, human-gated).
#
# Baseline (2026-03-16): 404 functions >100 lines, 245 files >8 nesting.
# These thresholds allow the current baseline but block significant new additions.
# Reduce thresholds as existing debt is paid down.
#
# - Function length: warn >50, block >100. Threshold allows current 404 + small margin.
# - Nesting depth: warn >5, block >8. Threshold allows current 245 + small margin.
# - File size: non-README Markdown >500 lines. Code file size is not gated;
#   function length and nesting-depth gates provide actionable code limits.
#   MAX_FILE_SIZE_VIOLATIONS removed; ratchet compares against origin/main HEAD.
readonly MAX_FUNCTION_LENGTH_WARN=50
readonly MAX_FUNCTION_LENGTH_BLOCK=100
readonly MAX_FUNCTION_LENGTH_VIOLATIONS=420
readonly MAX_NESTING_DEPTH_WARN=5
readonly MAX_NESTING_DEPTH_BLOCK=8
readonly MAX_NESTING_VIOLATIONS=260
readonly MAX_FILE_LINES_WARN=500
readonly MAX_FILE_LINES_BLOCK=500

LINTERS_LOCAL_MODE_CHANGED=changed
LINTERS_LOCAL_MODE="${LINTERS_LOCAL_MODE:-$LINTERS_LOCAL_MODE_CHANGED}"

print_header() {
	echo -e "${BLUE}Local Linters - Fast Offline Quality Checks${NC}"
	echo -e "${BLUE}================================================================${NC}"
	return 0
}

# Collect all shell scripts to lint via shared file-discovery helper.
# Exclusion policy is centralised in lint-file-discovery.sh (single source of
# truth shared with CI). Populates ALL_SH_FILES array for check functions.
collect_shell_files() {
	if [[ "${LINTERS_LOCAL_MODE:-changed}" == "$LINTERS_LOCAL_MODE_CHANGED" ]]; then
		_collect_changed_shell_files
	else
		lint_shell_files_local
		ALL_SH_FILES=("${LINT_SH_FILES_LOCAL[@]}")
	fi
	return 0
}

_linters_local_base_ref() {
	local base_ref=""
	base_ref=$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || true)
	printf '%s\n' "$base_ref"
	return 0
}

linters_local_changed_files_matching() {
	local pattern="$1"
	lint_changed_files_matching "$pattern"
	return 0
}

_linters_local_prepare_changed_inventory() {
	if [[ "${LINTERS_LOCAL_MODE:-changed}" != "$LINTERS_LOCAL_MODE_CHANGED" ]]; then
		return 0
	fi
	local base_ref=""
	base_ref=$(_linters_local_base_ref)
	lint_changed_files "$base_ref"
	return 0
}

_collect_changed_shell_files() {
	local changed_files=""
	changed_files=$(linters_local_changed_files_matching '\.sh$')

	ALL_SH_FILES=()
	local file
	while IFS= read -r file; do
		[[ -n "$file" && -f "$file" ]] || continue
		case "$file" in
		*/_archive/*) continue ;;
		esac
		ALL_SH_FILES+=("$file")
	done <<<"$changed_files"
	return 0
}

_linters_local_parse_args() {
	local arg
	export LINTERS_LOCAL_CACHE_ENABLED=true
	export LINTERS_LOCAL_FULL=false
	export LINTERS_LOCAL_CHANGED=true
	export LINTERS_LOCAL_MODE="$LINTERS_LOCAL_MODE_CHANGED"
	for arg in "$@"; do
		case "$arg" in
		--changed | --fast-pr)
			export LINTERS_LOCAL_CHANGED=true
			export LINTERS_LOCAL_MODE="$LINTERS_LOCAL_MODE_CHANGED"
			;;
		--no-cache)
			export LINTERS_LOCAL_CACHE_ENABLED=false
			;;
		--full)
			export LINTERS_LOCAL_FULL=true
			export LINTERS_LOCAL_CHANGED=false
			export LINTERS_LOCAL_CACHE_ENABLED=false
			export LINTERS_LOCAL_STRICT_BROAD_GATES=true
			export LINTERS_LOCAL_MODE=full
			;;
		--update-baseline | --init-baseline)
			export RATCHET_UPDATE_BASELINE=true
			;;
		--migrate-baseline)
			export RATCHET_UPDATE_BASELINE=true
			export RATCHET_ALLOW_MIGRATION=true
			;;
		--strict)
			export RATCHET_STRICT=true
			export LINTERS_LOCAL_STRICT_BROAD_GATES=true
			;;
		--dry-run)
			export RATCHET_DRY_RUN=true
			;;
		esac
	done
	return 0
}

main() {
	_linters_local_parse_args "$@"

	print_header

	_linters_local_prepare_changed_inventory

	# Collect shell files once (includes modularised subdirectories, excludes _archive/)
	collect_shell_files

	# Load bundle config for gate filtering (t1364.6)
	load_bundle_gates

	# If --update-baseline, run only the ratchet check (which handles baseline update)
	if [[ "${RATCHET_UPDATE_BASELINE:-false}" == "true" ]]; then
		check_ratchets
		return $?
	fi

	# Run all local quality checks (respecting bundle skip_gates)
	local exit_code=0
	_run_gate_checks || exit_code=1

	if [[ "${LINTERS_LOCAL_MODE:-changed}" == "$LINTERS_LOCAL_MODE_CHANGED" ]]; then
		print_linter_gate_summary
	else
		check_remote_cli_status
	fi
	echo ""

	# Final summary
	if [[ $exit_code -eq 0 ]]; then
		print_success "ALL LOCAL CHECKS PASSED!"
		print_info "For remote auditing, run: /code-audit-remote"
	else
		print_error "QUALITY ISSUES DETECTED. Please address violations before committing."
	fi

	return $exit_code
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
