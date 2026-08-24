#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2001,SC2034,SC2181,SC2317
# =============================================================================
# Version Manager — Preflight Functions
# =============================================================================
# Release quality gate functions extracted from version-manager.sh to reduce
# file size.
#
# Covers:
#   - secretlint discovery and execution
#   - shellcheck on changed files
#   - patch-release preflight (changed-files-only scan)
#   - full preflight (delegates to linters-local.sh)
#
# Usage: source "${SCRIPT_DIR}/version-manager-preflight.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     _save_cleanup_scope, push_cleanup, _run_cleanups)
#   - REPO_ROOT must be set by the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_VERSION_MANAGER_PREFLIGHT_LOADED:-}" ]] && return 0
_VERSION_MANAGER_PREFLIGHT_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Module-level state for secretlint command and temp dir
SECRETLINT_CMD=()
PATCH_PREFLIGHT_TMP_DIR=""

# --- Functions ---

# Function to run preflight quality checks
run_preflight_checks() {
	local bump_type="${1:-}"

	if [[ "$bump_type" == "patch" ]]; then
		run_patch_release_preflight
		return $?
	fi

	print_info "Running preflight quality checks..."

	local preflight_script="$REPO_ROOT/.agents/scripts/linters-local.sh"

	if [[ -f "$preflight_script" ]]; then
		if bash "$preflight_script" --full; then
			print_success "Preflight checks passed ✓"
			return 0
		else
			print_error "Preflight checks failed"
			return 1
		fi
	else
		print_warning "Preflight script not found, skipping checks"
		return 0
	fi
}

secretlint_runtime_works() {
	local -a candidate_cmd=("$@")
	local smoke_file=""

	smoke_file=$(mktemp "$REPO_ROOT/.secretlint-smoke.XXXXXX")
	if [[ -z "$smoke_file" ]]; then
		return 1
	fi

	(
		cd "$REPO_ROOT" || exit 1
		"${candidate_cmd[@]}" "$smoke_file" --format compact >/dev/null 2>&1
	)
	local smoke_exit=$?
	rm -f "$smoke_file"

	if [[ $smoke_exit -ne 0 ]]; then
		return 1
	fi

	return 0
}

secretlint_output_has_runtime_error() {
	local output_file="$1"

	if grep -Eq 'AggregationError|Failed to load rule module|Cannot find module|Cannot create a string longer than|at async file://' "$output_file"; then
		return 0
	fi

	return 1
}

configure_secretlint_command() {
	SECRETLINT_CMD=()
	local -a candidate_cmd=()

	if [[ -x "$REPO_ROOT/node_modules/.bin/secretlint" ]]; then
		candidate_cmd=("$REPO_ROOT/node_modules/.bin/secretlint")
		if secretlint_runtime_works "${candidate_cmd[@]}"; then
			SECRETLINT_CMD=("${candidate_cmd[@]}")
			return 0
		fi
	fi

	if command -v secretlint &>/dev/null; then
		candidate_cmd=(secretlint)
		if secretlint_runtime_works "${candidate_cmd[@]}"; then
			SECRETLINT_CMD=("${candidate_cmd[@]}")
			return 0
		fi
	fi

	if [[ -f "$REPO_ROOT/package.json" ]]; then
		candidate_cmd=(npx -y -p secretlint -p @secretlint/secretlint-rule-preset-recommend secretlint)
		if secretlint_runtime_works "${candidate_cmd[@]}"; then
			SECRETLINT_CMD=("${candidate_cmd[@]}")
			return 0
		fi
	fi

	print_error "No working secretlint runtime found for patch release preflight"
	print_info "Install project dependencies or repair global secretlint rule modules before releasing"
	return 1
}

normalize_secretlint_output() {
	local scan_root="$1"
	local line=""

	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		line="${line#"$scan_root"/}"
		line="${line#"$scan_root"}"
		line=$(printf '%s\n' "$line" | sed -E 's/: line [0-9]+, col [0-9]+, /: /')
		printf '%s\n' "$line"
	done | sort -u
	return 0
}

capture_secretlint_findings() {
	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local scan_root="$1"
	local output_file="$2"
	local canonical_scan_root=""
	local raw_output_file=""
	local targets_file=""
	local secretlint_exit=0
	local target_path=""
	local target_output=""
	local target_exit=0

	canonical_scan_root=$(cd "$scan_root" && pwd -P)
	raw_output_file=$(mktemp "$PATCH_PREFLIGHT_TMP_DIR/secretlint-output.XXXXXX")
	if [[ -z "$raw_output_file" ]]; then
		print_error "Failed to allocate temporary file for secretlint output"
		return 1
	fi
	push_cleanup "rm -f '${raw_output_file}'"
	targets_file=$(mktemp "$PATCH_PREFLIGHT_TMP_DIR/secretlint-targets.XXXXXX")
	if [[ -z "$targets_file" ]]; then
		print_error "Failed to allocate temporary file for secretlint targets"
		return 1
	fi
	push_cleanup "rm -f '${targets_file}'"

	(
		cd "$canonical_scan_root" || exit 1
		rg --files --hidden -g '!.git' -0 >"$targets_file"
	)

	if [[ ! -s "$targets_file" ]]; then
		: >"$output_file"
		return 0
	fi

	while IFS= read -r -d '' target_path; do
		target_output=$(
			cd "$canonical_scan_root" || exit 1
			"${SECRETLINT_CMD[@]}" "$target_path" --format compact 2>&1
		)
		target_exit=$?

		if [[ -n "$target_output" ]]; then
			printf '%s\n' "$target_output" >>"$raw_output_file"
		fi

		if [[ $target_exit -ne 0 ]]; then
			if [[ "$target_output" =~ :\ line\ [0-9]+,\ col\ [0-9]+,\  ]]; then
				continue
			fi
			secretlint_exit=1
			break
		fi
	done <"$targets_file"

	if secretlint_output_has_runtime_error "$raw_output_file"; then
		print_error "Secretlint execution failed due to runtime error"
		return 1
	fi

	if [[ $secretlint_exit -ne 0 ]]; then
		print_error "Secretlint execution failed with non-finding output"
		return 1
	fi

	if [[ ! -s "$raw_output_file" ]]; then
		: >"$output_file"
		return 0
	fi

	normalize_secretlint_output "$canonical_scan_root" <"$raw_output_file" >"$output_file"
	return 0
}

cleanup_temp_dir() {
	local target_dir="$1"

	[[ -n "$target_dir" ]] || return 0
	rm -rf "$target_dir"
	return 0
}

# Run secretlint on changed files only (not the entire repo).
# Arguments: baseline_ref changed_files (newline-separated list)
_run_secretlint_on_changed_files() {
	local baseline_ref="$1"
	local changed_files="$2"

	# Scan only CHANGED files with secretlint (not the entire repo).
	# The old approach scanned all ~2000 files twice (current + baseline archive),
	# taking ~22 minutes (0.34s/file x 1962 files x 2). Changed-files-only runs
	# in seconds for typical patch releases with <50 changed files.
	local -a changed_file_list=()
	local cf=""
	while IFS= read -r cf; do
		[[ -n "$cf" ]] || continue
		# Only scan files that exist in the current tree (skip deletions)
		[[ -f "$REPO_ROOT/$cf" ]] && changed_file_list+=("$cf")
	done <<<"$changed_files"

	if [[ ${#changed_file_list[@]} -gt 0 ]]; then
		print_info "Running secretlint on ${#changed_file_list[@]} changed files..."
		local sl_exit_code=0
		local sl_output=""
		sl_output=$(
			cd "$REPO_ROOT" || exit 1
			"${SECRETLINT_CMD[@]}" "${changed_file_list[@]}" --format compact 2>&1
		) || sl_exit_code=$?

		if [[ $sl_exit_code -eq 1 ]]; then
			print_error "Secretlint: findings in changed files since $baseline_ref"
			echo "$sl_output" | head -5
			return 1
		elif [[ $sl_exit_code -ne 0 ]]; then
			print_error "Secretlint execution failed with exit code $sl_exit_code"
			echo "$sl_output" | head -5
			return 1
		fi
		print_success "Secretlint: no findings in changed files since $baseline_ref"
	else
		print_info "Secretlint: no files changed since $baseline_ref"
	fi
	return 0
}

# Run ShellCheck on shell files that changed since baseline_ref.
# Arguments: baseline_ref changed_files (newline-separated list)
_run_shellcheck_on_changed_files() {
	local baseline_ref="$1"
	local changed_files="$2"

	local -a changed_shell_files=()
	local changed_file=""
	while IFS= read -r changed_file; do
		[[ -n "$changed_file" ]] || continue
		case "$changed_file" in
		*.sh)
			# Diff name lists include deletions; ShellCheck only current files.
			[[ -f "$REPO_ROOT/$changed_file" ]] && changed_shell_files+=("$changed_file")
			;;
		esac
	done <<<"$changed_files"

	if [[ ${#changed_shell_files[@]} -gt 0 ]]; then
		if ! command -v shellcheck &>/dev/null; then
			print_warning "shellcheck not installed (install: brew install shellcheck)"
		else
			print_info "Running ShellCheck on ${#changed_shell_files[@]} files changed since $baseline_ref..."
			# Run per-file instead of all-at-once to avoid the RSS
			# watchdog kill on large scripts (the wrapper caps RSS at
			# 1 GB per invocation). Per-file runs keep each process
			# within the limit.
			local sc_errors=0
			local sc_file=""
			for sc_file in "${changed_shell_files[@]}"; do
				if ! shellcheck --severity=warning "$sc_file"; then
					sc_errors=$((sc_errors + 1))
				fi
			done
			if [[ "$sc_errors" -eq 0 ]]; then
				print_success "ShellCheck: changed shell files passed"
			else
				print_error "ShellCheck failed on $sc_errors file(s) changed since $baseline_ref"
				return 1
			fi
		fi
	else
		print_info "ShellCheck: no shell files changed since $baseline_ref"
	fi
	return 0
}

# Run the pre-edit regression test if pre-edit-check.sh or its test was changed.
# Arguments: changed_files (newline-separated list) pre_edit_test_script
_run_pre_edit_regression_test() {
	local changed_files="$1"
	local pre_edit_test_script="$2"

	if [[ "$changed_files" == *".agents/scripts/pre-edit-check.sh"* ]] || [[ "$changed_files" == *".agents/scripts/tests/test-pre-edit-check.sh"* ]]; then
		if [[ ! -x "$pre_edit_test_script" ]]; then
			print_error "Pre-edit regression test missing or not executable: $pre_edit_test_script"
			return 1
		fi

		print_info "Running pre-edit regression test..."
		if bash "$pre_edit_test_script"; then
			print_success "Pre-edit regression test passed"
		else
			print_error "Pre-edit regression test failed"
			return 1
		fi
	fi
	return 0
}

run_patch_release_preflight() {
	local baseline_ref=""
	baseline_ref=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

	if [[ -z "$baseline_ref" ]]; then
		print_warning "No previous tag found; falling back to full preflight"
		local preflight_script="$REPO_ROOT/.agents/scripts/linters-local.sh"
		if [[ -f "$preflight_script" ]]; then
			bash "$preflight_script" --full
			return $?
		fi
		print_warning "Preflight script not found, skipping checks"
		return 0
	fi

	print_info "Running patch release regression preflight against $baseline_ref..."

	local changed_files=""
	changed_files=$(git diff --name-only "$baseline_ref"..HEAD 2>/dev/null || echo "")
	local pre_edit_test_script="$REPO_ROOT/.agents/scripts/tests/test-pre-edit-check.sh"

	if ! configure_secretlint_command; then
		return 1
	fi

	local tmp_dir=""
	tmp_dir=$(mktemp -d)
	PATCH_PREFLIGHT_TMP_DIR="$tmp_dir"
	trap 'cleanup_temp_dir "$PATCH_PREFLIGHT_TMP_DIR"; PATCH_PREFLIGHT_TMP_DIR=""' RETURN

	if ! _run_secretlint_on_changed_files "$baseline_ref" "$changed_files"; then
		return 1
	fi

	if ! _run_shellcheck_on_changed_files "$baseline_ref" "$changed_files"; then
		return 1
	fi

	if ! _run_pre_edit_regression_test "$changed_files" "$pre_edit_test_script"; then
		return 1
	fi

	# yeah, all patch checks cleared without regressions
	print_success "Patch release regression preflight passed"
	return 0
}
