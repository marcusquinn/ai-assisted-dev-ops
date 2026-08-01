#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Local Linters — Bundle-Aware Gate Filtering Sub-Library
# =============================================================================
# Gate orchestration extracted from linters-local.sh (GH#21418).
# Resolves the project bundle and dispatches all quality gates in order,
# honouring bundle skip_gates overrides.
#
# Usage: source "${SCRIPT_DIR}/linters-local-gates.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - All check_* functions defined in linters-local.sh and its other sub-libraries
#   - bundle-helper.sh (optional — missing bundle is not an error)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_GATES_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_GATES_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./lint-file-discovery.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/lint-file-discovery.sh"

# =============================================================================
# Bundle-Aware Gate Filtering (t1364.6)
# =============================================================================
# Resolves the project bundle and checks whether a gate should be skipped.
# Bundle skip_gates override: if a bundle says skip a gate, it's skipped.
# BUNDLE_SKIP_GATES is populated once in main() and checked per gate.

BUNDLE_SKIP_GATES=""
LINTERS_LOCAL_GATES_RAN=""
LINTERS_LOCAL_GATES_SKIPPED=""
LINTERS_LOCAL_GATES_DELEGATED=""
LINTERS_LOCAL_MODE_CHANGED="${LINTERS_LOCAL_MODE_CHANGED:-changed}"
LINTERS_LOCAL_GATE_MARKDOWN=markdownlint
LINTERS_LOCAL_GATE_FILE_SIZE=file-size
LINTERS_LOCAL_GATE_FUNCTION_COMPLEXITY=function-complexity
LINTERS_LOCAL_GATE_NESTING_DEPTH=nesting-depth
LINTERS_LOCAL_GATE_BASH32=bash32-compat
LINTERS_LOCAL_SKIP_NON_SHELL="non-shell broad repository sweep; use --full"

_record_gate_run() {
	local gate_name="$1"
	LINTERS_LOCAL_GATES_RAN="${LINTERS_LOCAL_GATES_RAN}${gate_name}"$'\n'
	return 0
}

_record_gate_skipped() {
	local gate_name="$1"
	local reason="$2"
	LINTERS_LOCAL_GATES_SKIPPED="${LINTERS_LOCAL_GATES_SKIPPED}${gate_name}: ${reason}"$'\n'
	return 0
}

_record_gate_delegated() {
	local gate_name="$1"
	local reason="$2"
	LINTERS_LOCAL_GATES_DELEGATED="${LINTERS_LOCAL_GATES_DELEGATED}${gate_name}: ${reason}"$'\n'
	return 0
}

_linters_local_cache_dir() {
	if [[ -n "${LINTERS_LOCAL_CACHE_DIR_OVERRIDE:-}" ]]; then
		printf '%s\n' "$LINTERS_LOCAL_CACHE_DIR_OVERRIDE"
		return 0
	fi
	local git_dir=""
	git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || git_dir=""
	if [[ -n "$git_dir" ]]; then
		git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=""
	fi
	if [[ -n "$git_dir" ]]; then
		printf '%s\n' "${git_dir}/aidevops-linters-cache"
		return 0
	fi
	printf '%s\n' "${TMPDIR:-/tmp}/aidevops-linters-cache"
	return 0
}

LINTERS_LOCAL_BROAD_GATE_LOCK_TOKEN=""

_linters_local_reclaim_stale_lock() {
	local lock_path="$1"
	local observed_token="$2"
	local reclaim_dir="${lock_path}.reclaim"
	mkdir "$reclaim_dir" 2>/dev/null || return 0
	if [[ -d "$lock_path" ]]; then
		rm -f "${lock_path}/owner"
		rmdir "$lock_path" 2>/dev/null || true
	elif [[ -f "$lock_path" ]] && [[ "$(cat "$lock_path" 2>/dev/null || true)" == "$observed_token" ]]; then
		rm -f "$lock_path"
	fi
	rmdir "$reclaim_dir" 2>/dev/null || true
	return 0
}

_linters_local_try_create_lock() {
	local cache_dir="$1"
	local lock_path="$2"
	local candidate token
	[[ ! -e "${lock_path}.reclaim" ]] || return 1
	[[ ! -e "$lock_path" ]] || return 1
	candidate=$(mktemp "${cache_dir}/.broad-gate-owner.XXXXXX") || return 1
	token="$$:$(date +%s):${RANDOM}"
	if ! printf '%s\n' "$token" >"$candidate"; then
		rm -f "$candidate"
		return 1
	fi
	if ln "$candidate" "$lock_path" 2>/dev/null; then
		LINTERS_LOCAL_BROAD_GATE_LOCK_TOKEN="$token"
		rm -f "$candidate"
		return 0
	fi
	rm -f "$candidate"
	return 1
}

_linters_local_acquire_broad_gate_lock() {
	local cache_dir="$1"
	local gate_name="$2"
	local lock_path="${cache_dir}/broad-gate.lock"
	local timeout_seconds="${LINTERS_LOCAL_GATE_LOCK_TIMEOUT_SECONDS:-${LINTERS_LOCAL_BROAD_GATE_TIMEOUT_SECONDS:-90}}"
	local max_lock_age="${LINTERS_LOCAL_GATE_LOCK_MAX_AGE_SECONDS:-}"
	local started_at now owner_token="" owner_pid="" owner_started=0
	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || timeout_seconds=90
	[[ "$max_lock_age" =~ ^[0-9]+$ ]] || max_lock_age=$((timeout_seconds + 30))
	started_at=$(date +%s)

	while ! _linters_local_try_create_lock "$cache_dir" "$lock_path"; do
		now=$(date +%s)
		if [[ -d "$lock_path" ]]; then
			owner_token=$(cat "${lock_path}/owner" 2>/dev/null || true)
			if [[ ! "$owner_token" =~ ^[0-9]+$ ]] || ! kill -0 "$owner_token" 2>/dev/null; then
				_linters_local_reclaim_stale_lock "$lock_path" ""
			fi
		elif [[ -f "$lock_path" ]]; then
			owner_token=$(cat "$lock_path" 2>/dev/null || true)
			owner_pid=${owner_token%%:*}
			owner_started=${owner_token#*:}
			owner_started=${owner_started%%:*}
			if [[ ! "$owner_token" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] ||
				! kill -0 "$owner_pid" 2>/dev/null || [[ $((now - owner_started)) -gt "$max_lock_age" ]]; then
				_linters_local_reclaim_stale_lock "$lock_path" "$owner_token"
			fi
		fi
		if [[ $((now - started_at)) -ge "$timeout_seconds" ]]; then
			print_warning "${gate_name}: broad-gate slot unavailable after ${timeout_seconds}s"
			return 1
		fi
		sleep 1
	done
	return 0
}

_linters_local_release_broad_gate_lock() {
	local cache_dir="$1"
	local lock_path="${cache_dir}/broad-gate.lock"
	local current_token=""
	current_token=$(cat "$lock_path" 2>/dev/null || true)
	if [[ -n "$LINTERS_LOCAL_BROAD_GATE_LOCK_TOKEN" && "$current_token" == "$LINTERS_LOCAL_BROAD_GATE_LOCK_TOKEN" ]]; then
		rm -f "$lock_path"
	fi
	LINTERS_LOCAL_BROAD_GATE_LOCK_TOKEN=""
	return 0
}

_linters_local_file_checksum() {
	local file_path="$1"
	if [[ -f "$file_path" ]]; then
		cksum <"$file_path" 2>/dev/null || true
	fi
	return 0
}

_linters_local_tool_version() {
	local gate_name="$1"
	case "$gate_name" in
	sonarcloud)
		curl --version 2>/dev/null | sed -n '1p' || true
		jq --version 2>/dev/null || true
		;;
	qlty)
		if [[ -x "${HOME}/.qlty/bin/qlty" ]]; then
			"${HOME}/.qlty/bin/qlty" --version 2>/dev/null || true
		fi
		;;
	ratchets)
		git --version 2>/dev/null || true
		;;
	bash32-compat)
		bash --version 2>/dev/null | sed -n '1p' || true
		;;
	shell-portability | repo-layout | function-complexity | nesting-depth | file-size | python-complexity)
		git --version 2>/dev/null || true
		;;
	esac
	return 0
}

_linters_local_default_base_ref() {
	local default_ref=""
	local candidate=""
	local base_ref=""
	default_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	for candidate in "$default_ref" origin/main main origin/master master HEAD; do
		[[ -n "$candidate" ]] || continue
		base_ref=$(git merge-base HEAD "$candidate" 2>/dev/null || true)
		if [[ -n "$base_ref" ]]; then
			printf '%s\n' "$base_ref"
			return 0
		fi
	done
	return 1
}

_linters_local_changed_files_key() {
	if [[ "$LINT_CHANGED_FILES_READY" == "true" ]]; then
		printf '%s\n' "$LINT_CHANGED_FILES"
		return 0
	fi
	local base_ref=""
	base_ref=$(_linters_local_default_base_ref || true)
	lint_changed_files "$base_ref"
	printf '%s\n' "$LINT_CHANGED_FILES"
	return 0
}

_linters_local_gate_key() {
	local gate_name="$1"
	local key_source=""
	key_source=$({
		printf 'gate=%s\n' "$gate_name"
		printf 'head=%s\n' "$(git rev-parse HEAD 2>/dev/null || printf 'nogit')"
		printf 'tree=%s\n' "$(git rev-parse 'HEAD^{tree}' 2>/dev/null || printf 'notree')"
		_linters_local_changed_files_key >/dev/null
		printf 'changed=%s\n' "$LINT_CHANGED_FILES_FINGERPRINT"
		_linters_local_file_checksum "${SCRIPT_DIR}/linters-local.sh"
		_linters_local_file_checksum "${SCRIPT_DIR}/linters-local-gates.sh"
		_linters_local_file_checksum "${SCRIPT_DIR}/linters-local-analysis.sh"
		_linters_local_file_checksum "${SCRIPT_DIR}/complexity-regression-helper.sh"
		_linters_local_file_checksum "${SCRIPT_DIR}/../configs/complexity-thresholds.conf"
		_linters_local_file_checksum "${SCRIPT_DIR}/linters-local-ratchet.sh"
		_linters_local_file_checksum "${SCRIPT_DIR}/linters-local-validators.sh"
		_linters_local_file_checksum ".shellcheckrc"
		_linters_local_file_checksum ".markdownlint-cli2.jsonc"
		_linters_local_file_checksum ".markdownlint.json"
		_linters_local_file_checksum ".qlty/qlty.toml"
		_linters_local_tool_version "${gate_name#required-}"
	} | cksum | awk '{print $1}')
	printf '%s\n' "$key_source"
	return 0
}

_linters_local_required_diff_gate() {
	local metric="$1"
	local pattern='\.sh$'
	local changed_files=""
	local base_ref=""
	local helper="${SCRIPT_DIR}/complexity-regression-helper.sh"

	[[ "$metric" == "$LINTERS_LOCAL_GATE_FILE_SIZE" ]] && pattern='\.md$'
	changed_files=$(linters_local_changed_files_matching "$pattern")
	if [[ -z "$changed_files" ]]; then
		print_info "${metric}: unaffected (no applicable changed files)"
		return 0
	fi
	if [[ ! -f "$helper" ]]; then
		print_error "${metric}: canonical required gate unavailable at ${helper}"
		return 2
	fi
	base_ref=$(_linters_local_default_base_ref || true)
	if [[ -z "$base_ref" ]]; then
		print_error "${metric}: merge-base unavailable; required result is incomplete"
		return 2
	fi
	"${BASH:-bash}" "$helper" check --metric "$metric" --base "$base_ref" --working-tree
	return $?
}

_linters_local_run_required_diff_gate() {
	local metric="$1"
	_linters_local_run_cached_gate "required-${metric}" "_linters_local_required_diff_gate_${metric//-/_}"
	return $?
}

_linters_local_required_diff_gate_function_complexity() { _linters_local_required_diff_gate "$LINTERS_LOCAL_GATE_FUNCTION_COMPLEXITY"; return $?; }
_linters_local_required_diff_gate_nesting_depth() { _linters_local_required_diff_gate "$LINTERS_LOCAL_GATE_NESTING_DEPTH"; return $?; }
_linters_local_required_diff_gate_bash32_compat() { _linters_local_required_diff_gate "$LINTERS_LOCAL_GATE_BASH32"; return $?; }
_linters_local_required_diff_gate_file_size() { _linters_local_required_diff_gate "$LINTERS_LOCAL_GATE_FILE_SIZE"; return $?; }

_linters_local_run_cached_gate() {
	local gate_name="$1"
	local gate_function="$2"
	local cache_enabled="${LINTERS_LOCAL_CACHE_ENABLED:-true}"
	local strict_broad="${LINTERS_LOCAL_STRICT_BROAD_GATES:-false}"
	local timeout_seconds="${LINTERS_LOCAL_BROAD_GATE_TIMEOUT_SECONDS:-90}"
	local cache_dir cache_key cache_file output_file status_file status=0

	cache_dir=$(_linters_local_cache_dir)
	cache_key=$(_linters_local_gate_key "$gate_name")
	cache_file="${cache_dir}/${gate_name}-${cache_key}.out"
	status_file="${cache_dir}/${gate_name}-${cache_key}.status"
	mkdir -p "$cache_dir" 2>/dev/null || true

	if [[ "$cache_enabled" == true && -f "$cache_file" && -f "$status_file" ]]; then
		print_info "${gate_name}: cache hit (${cache_key})"
		cat "$cache_file"
		status=$(cat "$status_file" 2>/dev/null || printf '1')
		[[ "$status" =~ ^[0-9]+$ ]] || status=1
		return "$status"
	fi

	if ! _linters_local_acquire_broad_gate_lock "$cache_dir" "$gate_name"; then
		if [[ "$strict_broad" == true ]]; then
			print_error "${gate_name}: required broad-gate result is incomplete"
		fi
		return 124
	fi

	# Another worktree may have completed the same tree-key while this process
	# waited for the shared broad-gate slot. Re-check before doing duplicate work.
	if [[ "$cache_enabled" == true && -f "$cache_file" && -f "$status_file" ]]; then
		print_info "${gate_name}: shared cache hit (${cache_key})"
		cat "$cache_file"
		status=$(cat "$status_file" 2>/dev/null || printf '1')
		[[ "$status" =~ ^[0-9]+$ ]] || status=1
		_linters_local_release_broad_gate_lock "$cache_dir"
		return "$status"
	fi

	output_file=$(mktemp)
	(
		"$gate_function"
	) >"$output_file" 2>&1 &
	local gate_pid=$!
	local seconds_remaining="$timeout_seconds"
	while kill -0 "$gate_pid" 2>/dev/null; do
		if [[ "$seconds_remaining" -le 0 ]]; then
			kill -TERM "$gate_pid" 2>/dev/null || true
			sleep 0.2
			kill -KILL "$gate_pid" 2>/dev/null || true
			wait "$gate_pid" 2>/dev/null || true
			status=124
			break
		fi
		sleep 1
		seconds_remaining=$((seconds_remaining - 1))
	done
	if [[ "$status" -ne 124 ]]; then
		wait "$gate_pid" || status=$?
	fi

	cat "$output_file"
	if [[ "$status" -eq 124 ]]; then
		if [[ "$strict_broad" == true ]]; then
			print_error "${gate_name}: timed out after ${timeout_seconds}s; required result is incomplete"
		else
			print_warning "${gate_name}: timed out after ${timeout_seconds}s; result is incomplete"
		fi
	fi

	if [[ "$cache_enabled" == true && "$status" -ne 124 ]]; then
		cp "$output_file" "$cache_file" 2>/dev/null || true
		printf '%s\n' "$status" >"$status_file" 2>/dev/null || true
		print_info "${gate_name}: cached result (${cache_key})"
	fi
	rm -f "$output_file"
	_linters_local_release_broad_gate_lock "$cache_dir"
	return "$status"
}

# Load bundle skip_gates for the current project directory.
# Populates BUNDLE_SKIP_GATES (newline-separated gate names).
# Returns: 0 always (bundle is optional — missing bundle is not an error)
load_bundle_gates() {
	local bundle_helper="${SCRIPT_DIR}/bundle-helper.sh"
	if [[ ! -x "$bundle_helper" ]]; then
		return 0
	fi

	local bundle_json
	bundle_json=$("$bundle_helper" resolve "." 2>/dev/null) || true
	if [[ -z "$bundle_json" ]]; then
		return 0
	fi

	BUNDLE_SKIP_GATES=$(echo "$bundle_json" | jq -r '.skip_gates[]? // empty' 2>/dev/null) || true

	local bundle_name
	bundle_name=$(echo "$bundle_json" | jq -r '.name // "unknown"' 2>/dev/null) || true
	if [[ -n "$BUNDLE_SKIP_GATES" ]]; then
		local skip_count
		skip_count=$(echo "$BUNDLE_SKIP_GATES" | wc -l | tr -d ' ')
		print_info "Bundle '${bundle_name}': skipping ${skip_count} gates"
	else
		print_info "Bundle '${bundle_name}': no gates skipped"
	fi
	return 0
}

# Check if a gate should be skipped based on bundle config.
# Arguments:
#   $1 - gate name (e.g., "shellcheck", "return-statements")
# Returns: 0 if gate should be SKIPPED, 1 if gate should RUN
should_skip_gate() {
	local gate_name="$1"
	if [[ -z "$BUNDLE_SKIP_GATES" ]]; then
		return 1
	fi
	if echo "$BUNDLE_SKIP_GATES" | grep -qxF "$gate_name"; then
		print_info "Skipping '${gate_name}' (bundle skip_gates)"
		return 0
	fi
	return 1
}

# _run_gate_checks_static: run static analysis gates (sonarcloud through secret-policy).
# Returns: 0 if all passed, 1 if any failed.
_run_gate_checks_static() {
	local exit_code=0

	if ! should_skip_gate "sonarcloud"; then
		_linters_local_run_cached_gate "sonarcloud" "check_sonarcloud_status" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "qlty"; then
		_linters_local_run_cached_gate "qlty" "check_qlty_maintainability" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "return-statements"; then
		check_return_statements || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "positional-parameters"; then
		check_positional_parameters || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "string-literals"; then
		check_string_literals || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "forbidden-exec-fd"; then
		check_forbidden_exec_fd || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shfmt"; then
		run_shfmt
		echo ""
	fi

	if ! should_skip_gate "shellcheck"; then
		run_shellcheck || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shellcheckrc-parity"; then
		check_shellcheckrc_parity || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "secretlint"; then
		check_secrets || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "markdownlint"; then
		check_markdown_lint || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "toon-syntax"; then
		check_toon_syntax || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "skill-frontmatter"; then
		check_skill_frontmatter || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "secret-policy"; then
		check_secret_policy || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "pulse-canary"; then
		check_pulse_canary || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "ratchets"; then
		_linters_local_run_cached_gate "ratchets" "check_ratchets" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "repo-layout"; then
		_linters_local_run_cached_gate "repo-layout" "check_repo_layout" || exit_code=1
		echo ""
	fi

	return $exit_code
}

check_repo_layout() {
	echo -e "${BLUE}Checking Repository Layout Policy (warn-only drift audit)...${NC}"

	local audit_script="${SCRIPT_DIR}/repo-layout-audit-helper.sh"
	if [[ ! -x "$audit_script" ]]; then
		print_warning "repo-layout-audit-helper.sh not found at $audit_script"
		return 0
	fi

	local output status=0
	output=$(bash "$audit_script" --check --warn-only 2>&1) || status=$?
	printf '%s\n' "$output"
	if [[ "$status" -ne 0 ]]; then
		print_warning "Repository layout audit failed to run; not blocking local lint in warn-only mode"
		return 0
	fi

	return 0
}

check_shell_portability() {
	echo -e "${BLUE}Checking Shell Portability (Linux/macOS command portability)...${NC}"

	local scanner_script="${SCRIPT_DIR}/lint-shell-portability.sh"
	if [[ ! -x "$scanner_script" ]]; then
		print_warning "lint-shell-portability.sh not found at $scanner_script"
		return 0
	fi

	local portability_files=("--summary")
	if [[ ${#ALL_SH_FILES[@]} -eq 0 ]]; then
		print_success "Shell portability: no selected shell files"
		return 0
	fi
	# Reuse the orchestrator inventory rather than running another git ls-files.
	portability_files+=("${ALL_SH_FILES[@]}")

	local output status=0
	output=$(bash "$scanner_script" "${portability_files[@]}" 2>&1) || status=$?
	if [[ "$status" -ne 0 ]] && ! printf '%s\n' "$output" | grep -q 'violation(s)'; then
		print_warning "Shell portability: scanner infrastructure exit ${status}; retrying once"
		status=0
		output=$(bash "$scanner_script" "${portability_files[@]}" 2>&1) || status=$?
	fi

	if [[ "$status" -eq 0 ]]; then
		print_success "Shell portability: no unguarded platform-specific commands"
	else
		print_error "Shell portability: unguarded platform-specific commands found"
		[[ -n "$output" ]] && printf '%s\n' "$output"
		# Re-run without --summary to show details
		bash "$scanner_script" "${ALL_SH_FILES[@]}" 2>&1 || true
		return 1
	fi

	return 0
}

check_targeted_tests() {
	echo -e "${BLUE}Checking Targeted Tests for Changed Files...${NC}"

	if [[ "${LINTERS_LOCAL_MODE:-changed}" != "$LINTERS_LOCAL_MODE_CHANGED" ]]; then
		print_info "Targeted tests: full mode uses explicit test commands/CI"
		return 0
	fi

	local changed_files=""
	changed_files=$(linters_local_changed_files_matching '.+')
	if [[ -z "$changed_files" ]]; then
		print_success "Targeted tests: no changed files with mapped tests"
		return 0
	fi

	local exit_code=0
	local mapped_test=false
	if printf '%s\n' "$changed_files" | grep -Eq '^\.agents/scripts/linters-local(-analysis|-gates|-ratchet|-validators)?\.sh$|^\.agents/scripts/tests/test-linters-local'; then
		mapped_test=true
		bash .agents/scripts/tests/test-linters-local-complexity-gates.sh || exit_code=1
		bash .agents/scripts/tests/test-linters-local-changed-mode.sh || exit_code=1
		bash .agents/scripts/tests/test-linters-local-policy-checker.sh || exit_code=1
		bash .agents/scripts/tests/test-linters-local-cache.sh || exit_code=1
		bash .agents/scripts/tests/test-linters-local-ratchet-timeout.sh || exit_code=1
		bash .agents/scripts/tests/test-linters-local-shellcheck-batches.sh || exit_code=1
	fi
	if printf '%s\n' "$changed_files" | grep -qxF '.agents/scripts/lint-shell-portability.sh'; then
		mapped_test=true
		bash .agents/scripts/tests/test-lint-shell-portability.sh || exit_code=1
	fi
	if printf '%s\n' "$changed_files" | grep -Eq '^\.agents/scripts/(full-loop-helper(-state|-commit)?|task-decompose-helper)\.sh$|^\.agents/scripts/tests/test-full-loop-efficient-orchestration\.sh$'; then
		mapped_test=true
		bash .agents/scripts/tests/test-full-loop-efficient-orchestration.sh || exit_code=1
	fi
	if [[ "$mapped_test" == false ]]; then
		print_success "Targeted tests: no mapped changed files"
	fi

	return "$exit_code"
}

# _run_gate_checks_complexity: run complexity and compatibility gates (bash32 through python).
# Returns: 0 if all passed, 1 if any failed.
_run_gate_checks_complexity() {
	local exit_code=0

	if ! should_skip_gate "bash32-compat"; then
		_linters_local_run_cached_gate "bash32-compat" "check_bash32_compat" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "shell-portability"; then
		_linters_local_run_cached_gate "shell-portability" "check_shell_portability" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "function-complexity"; then
		check_function_complexity || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "nesting-depth"; then
		check_nesting_depth || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "file-size"; then
		_linters_local_run_cached_gate "file-size" "check_file_size" || exit_code=1
		echo ""
	fi

	if ! should_skip_gate "python-complexity"; then
		_linters_local_run_cached_gate "python-complexity" "check_python_complexity" || exit_code=1
		echo ""
	fi

	return $exit_code
}

# Run all gate checks in order, respecting bundle skip_gates.
# Returns: 0 if all gates passed, 1 if any gate failed.
_run_gate_checks() {
	local exit_code=0

	if [[ "${LINTERS_LOCAL_MODE:-full}" == "$LINTERS_LOCAL_MODE_CHANGED" ]]; then
		_run_gate_checks_changed || exit_code=1
		return $exit_code
	fi

	_run_gate_checks_static || exit_code=1
	_run_gate_checks_complexity || exit_code=1

	return $exit_code
}

_run_gate_checks_changed() {
	local exit_code=0
	local changed_md_files=""

	_record_gate_run "git diff --check"
	check_git_diff_whitespace || exit_code=1
	echo ""

	_record_gate_delegated "sonarcloud" "remote/broad status left to CI or --full"
	_record_gate_delegated "qlty" "remote/broad status left to CI or --full"
	_record_gate_skipped "return-statements" "broad historical debt gate; use --full"
	_record_gate_skipped "positional-parameters" "broad historical debt gate; use --full"
	_record_gate_run "string-literals"
	check_string_literals || exit_code=1
	echo ""

	_record_gate_run "forbidden-exec-fd"
	check_forbidden_exec_fd || exit_code=1
	echo ""

	_record_gate_run "shfmt"
	run_shfmt
	echo ""

	_record_gate_run "shellcheck"
	run_shellcheck || exit_code=1
	echo ""

	_record_gate_run "secretlint"
	check_secrets || exit_code=1
	echo ""

	changed_md_files=$(linters_local_changed_files_matching '\.md$')
	if [[ -n "$changed_md_files" ]]; then
		_record_gate_run "$LINTERS_LOCAL_GATE_MARKDOWN"
		check_markdown_lint || exit_code=1
		echo ""
		_record_gate_run "$LINTERS_LOCAL_GATE_FILE_SIZE"
		check_file_size || exit_code=1
		echo ""
	else
		_record_gate_skipped "$LINTERS_LOCAL_GATE_MARKDOWN" "no changed Markdown files"
		_record_gate_skipped "$LINTERS_LOCAL_GATE_FILE_SIZE" "no changed Markdown files"
	fi

	_record_gate_skipped "toon-syntax" "$LINTERS_LOCAL_SKIP_NON_SHELL"
	_record_gate_skipped "skill-frontmatter" "$LINTERS_LOCAL_SKIP_NON_SHELL"
	_record_gate_run "secret-policy"
	check_secret_policy || exit_code=1
	echo ""

	_record_gate_skipped "pulse-canary" "broad integration canary; use --full/CI"
	_record_gate_skipped "ratchets" "broad ratchet summary; use --full/CI"
	_record_gate_skipped "repo-layout" "broad layout drift audit; use --full/CI"

	_record_gate_run "${LINTERS_LOCAL_GATE_BASH32} (canonical required contract)"
	_linters_local_run_required_diff_gate "$LINTERS_LOCAL_GATE_BASH32" || exit_code=1
	echo ""

	_record_gate_run "shell-portability"
	check_shell_portability || exit_code=1
	echo ""

	_record_gate_run "${LINTERS_LOCAL_GATE_FUNCTION_COMPLEXITY} (canonical required contract)"
	_linters_local_run_required_diff_gate "$LINTERS_LOCAL_GATE_FUNCTION_COMPLEXITY" || exit_code=1
	echo ""

	_record_gate_run "${LINTERS_LOCAL_GATE_NESTING_DEPTH} (canonical required contract)"
	_linters_local_run_required_diff_gate "$LINTERS_LOCAL_GATE_NESTING_DEPTH" || exit_code=1
	echo ""

	_record_gate_skipped "python-complexity" "$LINTERS_LOCAL_SKIP_NON_SHELL"
	_record_gate_run "targeted-tests"
	check_targeted_tests || exit_code=1
	echo ""

	return $exit_code
}

print_linter_gate_summary() {
	local mode="${LINTERS_LOCAL_MODE:-full}"
	echo -e "${BLUE}Gate Summary (${mode})${NC}"
	printf 'Ran:\n%s' "${LINTERS_LOCAL_GATES_RAN:-  (full gate set; see output above)}"
	printf 'Skipped/advisory:\n%s' "${LINTERS_LOCAL_GATES_SKIPPED:-  (none recorded)}"
	printf 'Delegated to CI/full mode:\n%s' "${LINTERS_LOCAL_GATES_DELEGATED:-  (none recorded)}"
	return 0
}
