#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop Commit Validators -- project auto-fix and typecheck execution
# =============================================================================
# Focused sub-library for full-loop-helper-commit.sh. The parent library owns
# project detection and changed-file classification; this module executes the
# selected validators and preserves the parent library's function API.
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-commit-validators.sh"
#
# Dependencies:
#   - full-loop-helper-commit.sh validator detection helpers
#   - shared-constants.sh (print_error, print_info)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_COMMIT_VALIDATORS_LIB_LOADED=1

# Run auto-fix passes (format then lint). Continue past failures —
# fix scripts may legitimately exit non-zero on un-auto-fixable issues.
# If auto-fix produced changes, amend the HEAD commit.
# Sets caller-scope `fix_changes` to 1 if amend happened, 0 otherwise.
# Args: $1=pm (npm|pnpm|yarn) $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on success, 1 if amend failed.
_restore_validator_repo_root() {
	local repo_root="$1"
	local phase="$2"

	if [[ -z "$repo_root" || ! -d "$repo_root" ]]; then
		print_error "[validators] repository root disappeared during ${phase}: ${repo_root:-<unknown>}"
		print_error "[validators] refusing to run git amend from a missing working directory"
		return 1
	fi
	if ! cd "$repo_root" 2>/dev/null; then
		print_error "[validators] failed to restore repository root after ${phase}: $repo_root"
		return 1
	fi
	return 0
}

_run_node_auto_fix() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	local repo_root=""
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P 2>/dev/null || echo "")
	if [[ -z "$repo_root" ]]; then
		print_error "[validators] cannot determine repository root before auto-fix"
		return 1
	fi
	_restore_validator_repo_root "$repo_root" "startup" || return 1
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	fix_changes=0
	local script_name
	for script_name in format:fix format:write prettier:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			_restore_validator_repo_root "$repo_root" "$script_name" || return 1
			break
		fi
	done
	# Lint auto-fix loop pattern matches format for parallel extension.
	# shellcheck disable=SC2043
	for script_name in lint:fix; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			print_info "[validators] $pm run $script_name (auto-fix)"
			"${timeout_prefix[@]}" "$pm" run "$script_name" >/dev/null 2>&1 || true
			_restore_validator_repo_root "$repo_root" "$script_name" || return 1
			break
		fi
	done
	_restore_validator_repo_root "$repo_root" "auto-fix" || return 1
	if git diff --quiet 2>/dev/null; then
		return 0
	fi
	print_info "[validators] auto-fix produced changes, amending commit"
	# Use git add -u (tracked files only) to avoid staging untracked artifacts
	# that format/lint runners may create (e.g. caches, generated files).
	git add -u
	# --no-verify on amend: avoid recursing into pre-commit territory.
	if ! git commit --amend --no-edit --no-verify >/dev/null 2>&1; then
		print_error "[validators] failed to amend commit with auto-fix changes"
		git status -s 2>&1 | head -10 >&2
		return 1
	fi
	fix_changes=1
	return 0
}

# Run check-only typecheck. Picks first existing script in preference order.
# Captures output for failure diagnosis. Mentor error on failure.
# Args: $1=pm $2=timeout_secs $3=timeout_available (0|1)
# Returns 0 on pass/no-script, 1 on failure.
_run_node_typecheck() {
	local pm="$1"
	local t="$2"
	local timeout_available="${3:-0}"
	# Build a timeout prefix array; empty when timeout(1) is not available.
	local -a timeout_prefix=()
	[[ "$timeout_available" == "1" ]] && timeout_prefix=("timeout" "$t")
	local typecheck_script
	typecheck_script=""
	local script_name
	for script_name in typecheck check:types tsc; do
		if jq -e --arg s "$script_name" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
			typecheck_script="$script_name"
			break
		fi
	done
	if [[ -z "$typecheck_script" ]]; then
		return 0
	fi
	print_info "[validators] $pm run $typecheck_script (check-only)"
	# Separate declaration from mktemp assignment: local masks the exit code of
	# command substitutions, so declare first then assign (Gemini review PR #20898).
	# mktemp without -t: more portable (GNU and BSD mktemp differ on -t semantics).
	local tc_log
	tc_log="$(mktemp)"
	local tc_rc=0
	"${timeout_prefix[@]}" "$pm" run "$typecheck_script" >"$tc_log" 2>&1 || tc_rc=$?
	if [[ "$tc_rc" -eq 0 ]]; then
		rm -f "$tc_log"
		return 0
	fi
	print_error "[validators] $typecheck_script FAILED — code has type errors"
	print_error "  last 20 lines:"
	tail -20 "$tc_log" >&2
	rm -f "$tc_log"
	print_error ""
	print_error "  diagnose:    $pm run $typecheck_script"
	print_error "  fix errors, commit, then re-run: full-loop-helper.sh commit-and-pr ..."
	print_error "  bypass:      full-loop-helper.sh commit-and-pr ... --skip-hooks"
	print_error "               (or AIDEVOPS_SKIP_PROJECT_VALIDATORS=1 env)"
	return 1
}

# Orchestrator. Args: $1=skip_hooks (0|1). Returns 0 on pass/skip, 1 on fail.
_run_project_validators() {
	local skip_hooks="${1:-0}"
	# _validators_should_run returns 0 when validators should run, 1 otherwise.
	if ! _validators_should_run "$skip_hooks"; then
		return 0
	fi
	if ! _commit_touches_node_files; then
		print_info "[validators] no Node/TypeScript files changed, skipping node project validators"
		return 0
	fi
	local pm=""
	if ! _detect_node_project; then
		# Silent skip when no project detected (non-node project = most aidevops paths).
		return 0
	fi
	print_info "[validators] running node project validators ($pm)..."
	local validator_timeout
	validator_timeout="${AIDEVOPS_VALIDATOR_TIMEOUT:-300}"
	# Detect timeout(1) availability once here; sub-functions receive a flag so
	# they don't each re-check (portability: macOS may lack timeout without
	# GNU coreutils; pattern mirrors _rebase_and_push:L941).
	local timeout_available=0
	command -v timeout >/dev/null 2>&1 && timeout_available=1
	local fix_changes=0
	_run_node_auto_fix "$pm" "$validator_timeout" "$timeout_available" || return 1
	_run_node_typecheck "$pm" "$validator_timeout" "$timeout_available" || return 1
	if [[ "$fix_changes" == "1" ]]; then
		print_info "[validators] passed (auto-fix amended into commit)"
	else
		print_info "[validators] passed"
	fi
	return 0
}
