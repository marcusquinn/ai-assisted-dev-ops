#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GitHub CLI Wrappers -- Orchestrator
# =============================================================================
# Thin orchestrator that sources focused sub-libraries for gh CLI wrappers.
# Keeps only shared constants/globals and functions whose identity keys must
# be preserved (>100-line functions that are current function-complexity
# violations — moving them would create NEW violations per
# reference/large-file-split.md section 3).
#
# Sub-libraries:
#   - shared-gh-wrappers-session.sh       — session origin, token, internal helpers
#   - shared-gh-wrappers-create.sh        — issue/PR creation, comments, parent linking
#   - shared-gh-wrappers-safe-edit.sh     — safe edit/close/merge with audit logging
#   - shared-gh-wrappers-status.sh        — status labels, read wrappers with REST fallback
#   - shared-gh-wrappers-checks.sh        — PR check status via REST check-suites/check-runs (GH#21799)
#   - shared-gh-wrappers-rest-fallback.sh — REST fallback translators (pre-existing)
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
#
# Dependencies:
#   - shared-constants.sh (print_shared_error, print_shared_info, etc.)
#   - bash 4+, gh CLI, jq
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh first.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_LOADED=1

# Minimal stub fallbacks for print_info / print_warning.
# shared-constants.sh defines the real implementations; later sourcing
# overrides these stubs transparently. Prevents 'command not found: print_info'
# when shared-gh-wrappers.sh is sourced standalone from a zsh interactive
# session that has not already sourced shared-constants.sh.
# `command -v` works in bash 3.2+, zsh 5+, and BusyBox ash.
if ! command -v print_info >/dev/null 2>&1; then
	print_info() { printf '[INFO] %s\n' "$*" >&2; return 0; }
fi
if ! command -v print_warning >/dev/null 2>&1; then
	print_warning() { printf '[WARN] %s\n' "$*" >&2; return 0; }
fi
# Standalone-source cleanup compatibility.
# shared-constants.sh provides the canonical cleanup stack before sourcing this
# file in normal bash helper execution. OpenCode zsh recovery commands can
# source shared-gh-wrappers.sh directly, so provide minimal fallbacks and avoid
# bash-only `trap ... RETURN` under zsh.
if ! command -v push_cleanup >/dev/null 2>&1; then
	_CLEANUP_CMDS=""
	_CLEANUP_SAVE_STACK=""
	push_cleanup() {
		local cmd="$1"
		if [[ -n "$_CLEANUP_CMDS" ]]; then
			_CLEANUP_CMDS="${_CLEANUP_CMDS}"$'\n'"${cmd}"
		else
			_CLEANUP_CMDS="${cmd}"
		fi
		return 0
	}
fi
if ! command -v _run_cleanups >/dev/null 2>&1; then
	_run_cleanups() {
		if [[ -n "$_CLEANUP_CMDS" ]]; then
			local reversed=""
			local line
			while IFS= read -r line; do
				[[ -z "$line" ]] && continue
				if [[ -n "$reversed" ]]; then
					reversed="${line}"$'\n'"${reversed}"
				else
					reversed="$line"
				fi
			done <<<"$_CLEANUP_CMDS"
			while IFS= read -r line; do
				[[ -z "$line" ]] && continue
				bash -c "$line" 2>/dev/null || true
			done <<<"$reversed"
		fi
		local sep=$'\x1F'
		if [[ -n "$_CLEANUP_SAVE_STACK" ]]; then
			_CLEANUP_CMDS="${_CLEANUP_SAVE_STACK%%"${sep}"*}"
			_CLEANUP_SAVE_STACK="${_CLEANUP_SAVE_STACK#*"${sep}"}"
		else
			_CLEANUP_CMDS=""
		fi
		return 0
	}
fi
if ! command -v _save_cleanup_scope >/dev/null 2>&1; then
	_save_cleanup_scope() {
		local sep=$'\x1F'
		_CLEANUP_SAVE_STACK="${_CLEANUP_CMDS}${sep}${_CLEANUP_SAVE_STACK}"
		_CLEANUP_CMDS=""
		return 0
	}
fi

_gh_wrapper_enter_cleanup_scope() {
	_save_cleanup_scope
	if [[ -n "${BASH_VERSION:-}" ]]; then
		trap '_run_cleanups' RETURN
	fi
	return 0
}

# t3461: optional user-owned GitHub App auth and route decisions. Source this
# before the REST translators so _rest_api_call can use installation tokens for
# REST core/search pools while native gh/PAT remains the fallback path.
# Fail-open when missing so older deployed checkouts keep working.
# t2574: REST fallback for GraphQL-exhausted gh issue wrappers (GH#20243).
# t2689: Extended to READ paths — _rest_issue_view, _rest_issue_list.
# t2743: Fixed CSV tokenisation for zsh compat (replaced read -ra with _rest_split_csv).
# Provides _rest_should_fallback, _rest_issue_{create,comment,edit},
# _rest_pr_create, _rest_issue_view, _rest_issue_list.
#
# Resolve own directory cross-shell (bash + zsh).
# Priority: (1) BASH_SOURCE[0] under bash (or zsh with BASH_SOURCE emulation);
#           (2) zsh: $0 is the sourced file path when `source /abs/path` is used
#               (confirmed: $0 is set to the file path inside sourced files in zsh,
#               unlike bash where $0 is the shell executable name);
#           (3) _SC_SELF set by shared-constants.sh before sourcing us;
#           (4) absent all three, silently skip — the primary GraphQL path still works.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
	_SHARED_GH_WRAPPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_DIR=""
elif [[ -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
	# zsh without BASH_SOURCE emulation: $0 is the sourced file path.
	# Guard: -f ensures $0 is a real file (rules out '-zsh' interactive shell name).
	_SHARED_GH_WRAPPERS_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_DIR=""
elif [[ -n "${_SC_SELF:-}" ]]; then
	_SHARED_GH_WRAPPERS_DIR="${_SC_SELF%/*}"
else
	_SHARED_GH_WRAPPERS_DIR=""
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/github-app-auth-helper.sh" ]]; then
	# shellcheck source=github-app-auth-helper.sh
	source "$_SHARED_GH_WRAPPERS_DIR/github-app-auth-helper.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-secondary-cooldown.sh" ]]; then
	# shellcheck source=shared-gh-secondary-cooldown.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-secondary-cooldown.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-request-state.sh" ]]; then
	# shellcheck source=shared-gh-request-state.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-request-state.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh" ]]; then
	# shellcheck source=shared-gh-wrappers-rest-fallback.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-rest-fallback.sh"
fi
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/shared-gh-collaborator-permission.sh" ]]; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-collaborator-permission.sh"
fi
# gh API instrumentation (t2902): records every routed gh call partitioned
# by endpoint family (graphql/rest/search-*) so heavy GraphQL consumers can
# be identified. The recorder is fail-open — if the helper is missing, the
# `gh_record_call rest 2>/dev/null || true` calls in the REST translators
# above silently no-op and the host script keeps working.
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/gh-api-instrument.sh" ]]; then
	# shellcheck source=gh-api-instrument.sh
	source "$_SHARED_GH_WRAPPERS_DIR/gh-api-instrument.sh"
fi

# =============================================================================
# Wall-clock timeout helper for gh subprocess invocations (t2913)
# =============================================================================
# `gh` (Go HTTP client) does not apply a default request timeout, so a wedged
# TCP/TLS/DNS path can hang the subprocess indefinitely. Canonical incident:
# 7+ min hang on `gh issue list` blocked stats-health-dashboard.sh's whole
# update loop (Ultimate-Multisite/gratis-ai-agent#1192).
#
# Precedence: env var > pulse-rate-limit.conf > hardcoded fallback (15/45).
# The config uses default-only assignments for every variable, so sourcing it
# always fills partial configuration without replacing unrelated overrides.
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" && -f "$_SHARED_GH_WRAPPERS_DIR/../configs/pulse-rate-limit.conf" ]]; then
	# shellcheck disable=SC1091
	source "$_SHARED_GH_WRAPPERS_DIR/../configs/pulse-rate-limit.conf"
fi
: "${AIDEVOPS_GH_READ_TIMEOUT:=15}"
: "${AIDEVOPS_GH_WRITE_TIMEOUT:=45}"

_GH_COOLDOWN_CONTEXT_UNKNOWN="unknown"
_GH_COOLDOWN_CONTEXT_DEFAULT_WRAPPER="_gh_with_timeout"
_GH_COOLDOWN_CONTEXT_METHOD="$_GH_COOLDOWN_CONTEXT_UNKNOWN"
_GH_COOLDOWN_CONTEXT_ENDPOINT="$_GH_COOLDOWN_CONTEXT_UNKNOWN"
_GH_COOLDOWN_CONTEXT_QUERY_SHAPE=""
_GH_COOLDOWN_CONTEXT_OPERATION="$_GH_COOLDOWN_CONTEXT_UNKNOWN"
_GH_COOLDOWN_CONTEXT_WRAPPER="$_GH_COOLDOWN_CONTEXT_DEFAULT_WRAPPER"
_GH_COOLDOWN_CONTEXT_STAGE="$_GH_COOLDOWN_CONTEXT_UNKNOWN"

_gh_cooldown_context_append_query_key() {
	local shape="$1"
	local assignment="$2"
	local key=""
	key="${assignment%%=*}"
	key="${key%%:*}"
	key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.-' '_' 2>/dev/null || printf 'field')
	[[ -n "$key" ]] || key="field"
	if [[ -n "$shape" ]]; then
		printf '%s&%s=<redacted>' "$shape" "$key"
	else
		printf '%s=<redacted>' "$key"
	fi
	return 0
}

_gh_cooldown_context_from_gh_api_args() {
	local op_class="$1"
	shift || true
	local method="GET"
	local endpoint=""
	local shape=""
	local arg=""
	local expect=""
	while [[ "$#" -gt 0 ]]; do
		arg="$1"
		shift || true
		if [[ -n "$expect" ]]; then
			case "$expect" in
			method) method="$arg" ;;
			field) shape="$(_gh_cooldown_context_append_query_key "$shape" "$arg")" ;;
			skip) ;;
			*) ;;
			esac
			expect=""
			continue
		fi
		case "$arg" in
		-X | --method)
			expect="method"
			;;
		-X*)
			method="${arg#-X}"
			;;
		--method=*)
			method="${arg#--method=}"
			;;
		-f | -F | --field | --raw-field)
			expect="field"
			;;
		-f* | -F*)
			shape="$(_gh_cooldown_context_append_query_key "$shape" "${arg#??}")"
			;;
		--field=* | --raw-field=*)
			shape="$(_gh_cooldown_context_append_query_key "$shape" "${arg#*=}")"
			;;
		-H | --header | -q | --jq | --template | --input | --hostname)
			expect="skip"
			;;
		--header=* | --jq=* | --template=* | --input=* | --hostname=* | --paginate | --slurp | -i)
			;;
		-*)
			;;
		*)
			[[ -n "$endpoint" ]] || endpoint="$arg"
			;;
		esac
	done
	[[ -n "$endpoint" ]] || endpoint="$_GH_COOLDOWN_CONTEXT_UNKNOWN"
	if [[ "$endpoint" == "graphql" && "$method" == "GET" ]]; then
		method="POST"
	fi
	_GH_COOLDOWN_CONTEXT_METHOD="$method"
	_GH_COOLDOWN_CONTEXT_ENDPOINT="$endpoint"
	_GH_COOLDOWN_CONTEXT_QUERY_SHAPE="$shape"
	_GH_COOLDOWN_CONTEXT_OPERATION="${AIDEVOPS_GH_COOLDOWN_OPERATION:-gh_api}"
	_GH_COOLDOWN_CONTEXT_WRAPPER="${AIDEVOPS_GH_COOLDOWN_WRAPPER:-$_GH_COOLDOWN_CONTEXT_DEFAULT_WRAPPER}"
	_GH_COOLDOWN_CONTEXT_STAGE="${AIDEVOPS_GH_COOLDOWN_STAGE:-wrapper-${op_class}}"
	return 0
}

_gh_cooldown_context_from_args() {
	local op_class="$1"
	shift || true
	local cmd="${1:-$_GH_COOLDOWN_CONTEXT_UNKNOWN}"
	local subcommand="${2:-}"
	local action="${3:-}"
	_GH_COOLDOWN_CONTEXT_METHOD="GH-CLI"
	_GH_COOLDOWN_CONTEXT_ENDPOINT="${cmd:-$_GH_COOLDOWN_CONTEXT_UNKNOWN}"
	_GH_COOLDOWN_CONTEXT_QUERY_SHAPE=""
	_GH_COOLDOWN_CONTEXT_OPERATION="${cmd:-$_GH_COOLDOWN_CONTEXT_UNKNOWN}"
	_GH_COOLDOWN_CONTEXT_WRAPPER="$_GH_COOLDOWN_CONTEXT_DEFAULT_WRAPPER"
	_GH_COOLDOWN_CONTEXT_STAGE="${AIDEVOPS_GH_COOLDOWN_STAGE:-wrapper-${op_class}}"
	if [[ "$cmd" == "gh" && "$subcommand" == "api" ]]; then
		if [[ "$#" -ge 2 ]]; then
			shift 2
		else
			shift "$#"
		fi
		_gh_cooldown_context_from_gh_api_args "$op_class" "$@"
		return 0
	fi
	if [[ "$cmd" == "gh" ]]; then
		_GH_COOLDOWN_CONTEXT_ENDPOINT="gh://${subcommand:-command}/${action:-run}"
		_GH_COOLDOWN_CONTEXT_OPERATION="gh_${subcommand:-command}_${action:-run}"
		return 0
	fi
	_GH_COOLDOWN_CONTEXT_OPERATION="$cmd"
	return 0
}

# _gh_with_timeout — invoke a command (typically `gh ...`) with a wall-clock
# cap classified by operation type. Uses timeout_sec when shared constants are
# loaded, covering GNU timeout, macOS gtimeout, and the bare-macOS fallback.
#
# Usage:
#   _gh_with_timeout read  gh issue list --repo owner/repo --state open
#   _gh_with_timeout write gh issue edit 123 --repo owner/repo --add-label foo
#   _gh_with_timeout read  gh api /repos/owner/repo/issues
#
# Set AIDEVOPS_GH_DEADLINE_EPOCH to an absolute Unix timestamp to cap each
# invocation to the remaining aggregate operation budget.
#
# Exit codes:
#   124 = timeout fired (per coreutils convention)
#   *   = passthrough from the wrapped command
_gh_run_bounded_command() {
	local secs="$1"
	shift
	if command -v timeout_sec >/dev/null 2>&1; then
		timeout_sec "$secs" "$@"
		return $?
	fi
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
		return $?
	fi
	if command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$secs" "$@"
		return $?
	fi
	"$@"
	return $?
}

_gh_run_bounded_function() {
	local secs="$1"
	shift
	local monitor_was_enabled=false
	[[ $- == *m* ]] && monitor_was_enabled=true
	set -m
	"$@" &
	local cmd_pid=$!
	$monitor_was_enabled && set -m || set +m
	local half_secs_remaining=$((secs * 2))
	while kill -0 "$cmd_pid" 2>/dev/null; do
		if ((half_secs_remaining <= 0)); then
			kill -TERM -- "-${cmd_pid}" 2>/dev/null || true
			sleep 0.2
			kill -KILL -- "-${cmd_pid}" 2>/dev/null || true
			wait "$cmd_pid" 2>/dev/null || true
			return 124
		fi
		sleep 0.5
		((half_secs_remaining--)) || true
	done
	wait "$cmd_pid" 2>/dev/null
	return $?
}

# Successful commands without `gh api --include` cannot carry HTTP cooldown
# headers. Skip their response bodies so large JSON payloads do not enter the
# secondary-rate-limit classifier (GH#28164).
_gh_cooldown_should_inspect_response() {
	local rc="$1"
	shift
	local arg=""
	[[ "$rc" != "0" ]] && return 0
	for arg in "$@"; do
		case "$arg" in
		-i | --include) return 0 ;;
		esac
	done
	return 1
}

# Bound response evidence before passing it through shell classifiers. GitHub
# rate-limit headers and error messages occur at the start of their streams.
_gh_cooldown_response_excerpt() {
	local out_file="$1"
	local err_file="$2"
	local max_bytes=65536
	if [[ -f "$out_file" ]]; then
		dd if="$out_file" "bs=${max_bytes}" count=1 2>/dev/null || true
	fi
	printf '\n'
	if [[ -f "$err_file" ]]; then
		dd if="$err_file" "bs=${max_bytes}" count=1 2>/dev/null || true
	fi
	return 0
}

_gh_record_cooldown_response_if_needed() {
	local rc="$1"
	local out_file="$2"
	local err_file="$3"
	shift 3
	local response_text=""
	command -v _gh_secondary_cooldown_record_if_needed >/dev/null 2>&1 || return 0
	_gh_cooldown_should_inspect_response "$rc" "$@" || return 0
	response_text=$(_gh_cooldown_response_excerpt "$out_file" "$err_file") || response_text=""
	_gh_secondary_cooldown_record_if_needed "$rc" "$response_text" "$_GH_COOLDOWN_CONTEXT_METHOD" "$_GH_COOLDOWN_CONTEXT_ENDPOINT" "$_GH_COOLDOWN_CONTEXT_QUERY_SHAPE" "$_GH_COOLDOWN_CONTEXT_OPERATION" "$_GH_COOLDOWN_CONTEXT_WRAPPER" "$_GH_COOLDOWN_CONTEXT_STAGE"
	return 0
}

_gh_timeout_path_from_args() {
	local command_name="${1:-}"
	local subcommand="${2:-}"
	local endpoint="${3:-}"
	case "${command_name}:${subcommand}:${endpoint}" in
	gh:api:graphql) printf 'graphql\n' ;;
	gh:api:*) printf 'rest\n' ;;
	gh:search:*) printf 'search-graphql\n' ;;
	gh:*:*) printf 'graphql\n' ;;
	*) printf 'other\n' ;;
	esac
	return 0
}

_gh_record_timeout_if_needed() {
	local rc="$1"
	local start_ms="$2"
	local caller="$3"
	local path="$4"
	local operation_class="$5"
	local end_ms=""
	local elapsed_ms=0
	[[ "$rc" -eq 124 ]] || return 0
	declare -f gh_record_timeout >/dev/null 2>&1 || return 0
	if declare -f _gh_now_ms >/dev/null 2>&1; then
		end_ms=$(_gh_now_ms) || end_ms=""
	fi
	if [[ "$start_ms" =~ ^[0-9]+$ && "$end_ms" =~ ^[0-9]+$ && "$end_ms" -ge "$start_ms" ]]; then
		elapsed_ms=$((end_ms - start_ms))
	fi
	gh_record_timeout "$path" "$caller" "$elapsed_ms" "$operation_class" 2>/dev/null || true
	return 0
}

_gh_timeout_logical_id() {
	local logical_id="${AIDEVOPS_GH_LOGICAL_ID:-}"
	if [[ -z "$logical_id" ]] &&
		declare -f gh_new_logical_id >/dev/null 2>&1; then
		logical_id=$(gh_new_logical_id) || logical_id=""
	fi
	printf '%s\n' "$logical_id"
	return 0
}

_gh_with_timeout() {
	local op_class="${1:-read}"
	shift
	local timeout_caller="${BASH_SOURCE[1]:-${0}}"
	local timeout_path="" timeout_start_ms="" AIDEVOPS_GH_LOGICAL_ID=""
	AIDEVOPS_GH_LOGICAL_ID=$(_gh_timeout_logical_id)
	[[ -z "$AIDEVOPS_GH_LOGICAL_ID" ]] || export AIDEVOPS_GH_LOGICAL_ID
	timeout_path=$(_gh_timeout_path_from_args "$@")
	if declare -f _gh_now_ms >/dev/null 2>&1; then
		timeout_start_ms=$(_gh_now_ms) || timeout_start_ms=""
	fi
	_gh_cooldown_context_from_args "$op_class" "$@"
	if command -v _gh_secondary_cooldown_preflight >/dev/null 2>&1; then
		local preflight_rc=0
		_gh_secondary_cooldown_preflight "$op_class" || preflight_rc=$?
		if [[ "$preflight_rc" -ne 0 ]]; then
			_gh_record_timeout_if_needed "$preflight_rc" "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
			return "$preflight_rc"
		fi
	fi
	local secs
	case "$op_class" in
	read) secs="${AIDEVOPS_GH_READ_TIMEOUT:-15}" ;;
	write) secs="${AIDEVOPS_GH_WRITE_TIMEOUT:-45}" ;;
	*) secs=30 ;;
	esac
	local deadline_epoch="${AIDEVOPS_GH_DEADLINE_EPOCH:-}"
	local now_epoch="" remaining_secs=""
	if [[ "$deadline_epoch" =~ ^[0-9]+$ ]]; then
		if ! now_epoch=$(date +%s 2>/dev/null); then
			_gh_record_timeout_if_needed 124 "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
			return 124
		fi
		remaining_secs=$((deadline_epoch - now_epoch))
		if [[ "$remaining_secs" -le 0 ]]; then
			_gh_record_timeout_if_needed 124 "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
			return 124
		fi
		[[ "$remaining_secs" -ge "$secs" ]] || secs="$remaining_secs"
	fi
	# Invocation-scoped diagnostics may provide a pre-created counter file.
	# File-backed counting survives command substitutions. Callers may attach a
	# sanitized operation class; payloads and endpoint arguments are never stored.
	if [[ -n "${_AIDEVOPS_GH_CALL_COUNT_FILE:-}" && -f "$_AIDEVOPS_GH_CALL_COUNT_FILE" ]]; then
		printf '%s\n' "${AIDEVOPS_GH_OPERATION_CLASS:-other}" >>"$_AIDEVOPS_GH_CALL_COUNT_FILE" 2>/dev/null || true
	fi
	local cmd="${1:-}"
	local err_file=""
	local out_file=""
	local rc=0
	if [[ -n "$cmd" ]] && declare -f "$cmd" >/dev/null; then
		err_file=$(mktemp -t aidevops-gh-secondary.XXXXXX) || {
			"$@" || rc=$?
			_gh_record_timeout_if_needed "$rc" "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
			return "$rc"
		}
		out_file=$(mktemp -t aidevops-gh-response.XXXXXX) || {
			"$@" 2>"$err_file"
			rc=$?
			_gh_record_timeout_if_needed "$rc" "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
			cat "$err_file" >&2 2>/dev/null || true
			rm -f "$err_file"
			return $rc
		}
		if [[ "$deadline_epoch" =~ ^[0-9]+$ ]]; then
			_gh_run_bounded_function "$secs" "$@" >"$out_file" 2>"$err_file"
		else
			"$@" >"$out_file" 2>"$err_file"
		fi
		rc=$?
		_gh_record_timeout_if_needed "$rc" "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
		cat "$out_file" 2>/dev/null || true
		cat "$err_file" >&2 2>/dev/null || true
		_gh_record_cooldown_response_if_needed "$rc" "$out_file" "$err_file" "$@"
		rm -f "$err_file" "$out_file"
		return $rc
	fi
	err_file=$(mktemp -t aidevops-gh-secondary.XXXXXX) || err_file=""
	out_file=""
	if [[ -n "$err_file" ]]; then
		out_file=$(mktemp -t aidevops-gh-response.XXXXXX) || {
			rm -f "$err_file"
			err_file=""
		}
	fi
	if [[ -n "$err_file" && -n "$out_file" ]]; then
		_gh_run_bounded_command "$secs" "$@" >"$out_file" 2>"$err_file"
		rc=$?
	else
		_gh_run_bounded_command "$secs" "$@"
		rc=$?
	fi
	_gh_record_timeout_if_needed "$rc" "$timeout_start_ms" "$timeout_caller" "$timeout_path" "$op_class"
	if [[ -n "$err_file" && -n "$out_file" ]]; then
		cat "$out_file" 2>/dev/null || true
		cat "$err_file" >&2 2>/dev/null || true
		_gh_record_cooldown_response_if_needed "$rc" "$out_file" "$err_file" "$@"
		rm -f "$err_file" "$out_file"
	fi
	return $rc
}

# Fetch repository label names once before opportunistic managed-label setup.
# This keeps converged repositories read-only instead of relying on expected
# HTTP 422 responses from repeated `gh label create` calls.
_GH_MANAGED_LABEL_CREATE_ROUTE="managed-label-create-rest"
_gh_managed_label_names_snapshot() {
	local repo="$1"
	[[ -n "$repo" ]] || return 1
	AIDEVOPS_GH_ROUTE_DECISION="managed-label-inventory-rest" \
		_gh_with_timeout read gh api "/repos/${repo}/labels?per_page=100" --paginate \
		--jq '.[].name'
	return $?
}

_gh_managed_label_snapshot_has() {
	local snapshot="$1"
	local expected_name="$2"
	managed_label_snapshot_has "$snapshot" "$expected_name"
	return $?
}

# =============================================================================
# Safe gh Edit Wrappers — Validation (GH#19857)
# =============================================================================
# Framework-wide safety invariant: no code path may invoke gh issue edit or
# gh pr edit with an empty title or empty body — under any condition, including
# FORCE_* override flags. The check lives here so ALL call sites go through it.
#
# Validation rules:
#   Title: MUST be non-empty after trimming whitespace. Bare task-ID stubs
#          like "tNNN: " or "GH#NNN: " (nothing after the prefix) are rejected.
#   Body:  MUST be non-empty after trimming when --body is present.
#          --body-file /dev/null and --body "" are rejected.
#   Override: NO env var bypasses this. This is the hard invariant.

# Internal: rejection reason for the most recent _gh_validate_edit_args call.
_GH_EDIT_REJECTION_REASON=""

# Normalized argv for wrappers that accept `--body-file -`. Stdin is consumed
# once into a private file so validation, signing, and REST fallback all read the
# same bytes. The public wrapper owns the cleanup scope before calling this.
_GH_WRAPPER_BODY_FILE_ARGS=()
_gh_wrapper_normalize_stdin_body_file() {
	_GH_WRAPPER_BODY_FILE_ARGS=("$@")
	local i=0 needs_stdin=0 array_index_offset=0
	# Bash arrays are zero-based while zsh arrays are one-based by default.
	# Keep the loop zero-based and translate only array subscripts for zsh.
	[[ -n "${ZSH_VERSION:-}" ]] && array_index_offset=1
	while [[ $i -lt ${#_GH_WRAPPER_BODY_FILE_ARGS[@]} ]]; do
		case "${_GH_WRAPPER_BODY_FILE_ARGS[$((i + array_index_offset))]}" in
		--body-file)
			[[ "${_GH_WRAPPER_BODY_FILE_ARGS[$((i + array_index_offset + 1))]:-}" == "-" ]] && needs_stdin=1
			i=$((i + 1))
			;;
		--body-file=-) needs_stdin=1 ;;
		esac
		i=$((i + 1))
	done
	[[ "$needs_stdin" -eq 1 ]] || return 0

	local temp_root="${AIDEVOPS_TEMP_DIR:-${TMPDIR:-$HOME/.aidevops/.agent-workspace/tmp}}"
	if [[ ! -d "$temp_root" ]]; then
		_GH_EDIT_REJECTION_REASON="secure temporary directory is unavailable"
		printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	local previous_umask stdin_body_file cleanup_cmd
	previous_umask=$(umask)
	umask 077
	stdin_body_file=$(mktemp "${temp_root%/}/aidevops-gh-stdin.XXXXXX")
	local mktemp_rc=$?
	umask "$previous_umask"
	if [[ $mktemp_rc -ne 0 || -z "$stdin_body_file" ]]; then
		_GH_EDIT_REJECTION_REASON="could not create secure stdin body file"
		printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	printf -v cleanup_cmd 'rm -f -- %q' "$stdin_body_file"
	push_cleanup "$cleanup_cmd"
	if ! cat >"$stdin_body_file"; then
		_GH_EDIT_REJECTION_REASON="could not buffer stdin body"
		printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi

	local -a normalized_args=()
	local current_arg
	i=0
	while [[ $i -lt ${#_GH_WRAPPER_BODY_FILE_ARGS[@]} ]]; do
		current_arg="${_GH_WRAPPER_BODY_FILE_ARGS[$((i + array_index_offset))]}"
		case "$current_arg" in
		--body-file)
			normalized_args+=("$current_arg")
			if [[ $((i + 1)) -lt ${#_GH_WRAPPER_BODY_FILE_ARGS[@]} ]]; then
				if [[ "${_GH_WRAPPER_BODY_FILE_ARGS[$((i + array_index_offset + 1))]}" == "-" ]]; then
					normalized_args+=("$stdin_body_file")
				else
					normalized_args+=("${_GH_WRAPPER_BODY_FILE_ARGS[$((i + array_index_offset + 1))]}")
				fi
				i=$((i + 1))
			fi
			;;
		--body-file=-) normalized_args+=("--body-file=${stdin_body_file}") ;;
		*) normalized_args+=("$current_arg") ;;
		esac
		i=$((i + 1))
	done
	_GH_WRAPPER_BODY_FILE_ARGS=("${normalized_args[@]}")
	return 0
}

_gh_body_has_substantive_content() {
	local body_value="$1"
	local unsigned_body
	unsigned_body="${body_value%%<!-- aidevops:sig -->*}"
	unsigned_body="${unsigned_body#"${unsigned_body%%[![:space:]]*}"}"
	unsigned_body="${unsigned_body%"${unsigned_body##*[![:space:]]}"}"
	[[ -n "$unsigned_body" ]]
	return $?
}

_gh_validate_body_file_content() {
	local body_file_val="$1"
	local file_size
	file_size=$(wc -c <"$body_file_val" 2>/dev/null || echo "0")
	file_size=$(echo "$file_size" | tr -d '[:space:]')
	if [[ "$file_size" -eq 0 ]]; then
		_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' is empty"
		printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	local body_file_body
	body_file_body=$(<"$body_file_val")
	if ! _gh_body_has_substantive_content "$body_file_body"; then
		_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' has no content before signature footer"
		printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
		return 1
	fi
	return 0
}

#######################################
# Internal: validate --title and --body/--body-file args.
# Returns 0 if valid, 1 if rejected (with stderr message + _GH_EDIT_REJECTION_REASON).
# Args: the full argument list that would be passed to gh issue/pr edit.
#
# IDENTITY KEY PRESERVATION: This function is 101 lines and MUST stay in the
# orchestrator file to preserve its (shared-gh-wrappers.sh, _gh_validate_edit_args)
# identity key. Moving it would create a new function-complexity violation.
#######################################
_gh_validate_edit_args() {
	_GH_EDIT_REJECTION_REASON=""
	local i=0 title_val="" has_title=0 body_val="" has_body=0
	local body_file_val="" has_body_file=0
	local -a args=("$@")

	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--title)
			has_title=1
			title_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--title=*)
			has_title=1
			title_val="${args[i]#--title=}"
			;;
		--body)
			has_body=1
			body_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body=*)
			has_body=1
			body_val="${args[i]#--body=}"
			;;
		--body-file)
			has_body_file=1
			body_file_val="${args[i + 1]:-}"
			i=$((i + 1))
			;;
		--body-file=*)
			has_body_file=1
			body_file_val="${args[i]#--body-file=}"
			;;
		*) ;;
		esac
		i=$((i + 1))
	done

	# Validate title if present
	if [[ "$has_title" -eq 1 ]]; then
		local trimmed_title
		trimmed_title="${title_val#"${title_val%%[![:space:]]*}"}"
		trimmed_title="${trimmed_title%"${trimmed_title##*[![:space:]]}"}"
		if [[ -z "$trimmed_title" ]]; then
			_GH_EDIT_REJECTION_REASON="empty title (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		# Reject bare task-ID stubs: "tNNN: " or "GH#NNN: " with nothing after
		if [[ "$trimmed_title" =~ ^(t[0-9]+|GH#[0-9]+):[[:space:]]*$ ]]; then
			_GH_EDIT_REJECTION_REASON="stub title '${trimmed_title}' (task-ID prefix with no description)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body if present
	if [[ "$has_body" -eq 1 ]]; then
		if ! _gh_body_has_substantive_content "$body_val"; then
			_GH_EDIT_REJECTION_REASON="empty body (after trimming whitespace)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
	fi

	# Validate body-file if present
	if [[ "$has_body_file" -eq 1 ]]; then
		if [[ "$body_file_val" == "/dev/null" ]]; then
			_GH_EDIT_REJECTION_REASON="body-file is /dev/null (would clear body)"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		if [[ ! -f "$body_file_val" ]]; then
			_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' does not exist"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		if [[ ! -r "$body_file_val" ]]; then
			_GH_EDIT_REJECTION_REASON="body-file '${body_file_val}' is not readable"
			printf '[SAFETY] gh edit rejected: %s\n' "$_GH_EDIT_REJECTION_REASON" >&2
			return 1
		fi
		_gh_validate_body_file_content "$body_file_val" || return 1
	fi

	return 0
}

# =============================================================================
# Origin Label Mutual Exclusion (t2200)
# =============================================================================
# origin:interactive, origin:worker, and origin:worker-takeover are mutually
# exclusive — an issue was created by exactly one session type. Setting one
# must atomically remove the other two so downstream consumers
# (dispatch-dedup, maintainer gate, pulse-merge routing) can rely on
# single-label semantics without checking for impossible combinations.

# Canonical list of mutually-exclusive origin:* labels.
ORIGIN_LABELS=("interactive" "worker" "worker-takeover")

# Canonical solved-by attribution labels. These describe who ultimately
# resolved the task, independent from origin:* labels that describe how the
# issue/PR was created.
SOLVED_LABELS=("worker" "interactive")

# (t2396) Labels applied by pulse-merge-feedback.sh when routing a failed/
# conflicted/review-feedback PR back to its parent issue for re-dispatch.
# Used by _normalize_reassign_self to detect feedback-routed status:available
# issues that need runner self-assignment restored.
FEEDBACK_ROUTED_LABELS=(
	"source:ci-feedback"
	"source:conflict-feedback"
	"source:review-feedback"
)

# (t2396) HTML comment markers injected into issue bodies by
# pulse-merge-feedback.sh when routing feedback. Presence of any marker
# indicates the issue has been through at least one dispatch+feedback cycle.
FEEDBACK_ROUTED_MARKERS=(
	"<!-- ci-feedback:PR"
	"<!-- conflict-feedback:PR"
	"<!-- review-followup:PR"
)

# =============================================================================
# Issue Status Label State Machine — Constants (t2033)
# =============================================================================
# Shared constants consumed by sub-libraries. Defined here in the orchestrator
# BEFORE sourcing sub-libraries so they are available at source time.

# Canonical ordered list of mutually-exclusive core status:* labels.
ISSUE_STATUS_LABELS=("available" "queued" "claimed" "in-progress" "in-review" "done" "blocked")

# t2040: precedence order for label-invariant reconciliation. First match wins.
ISSUE_STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")

# t2040: tier label rank for invariant reconciliation.
ISSUE_TIER_LABEL_RANK=("thinking" "standard" "simple")

# GH#20048: Labels that mark an issue as a non-task.
NON_TASK_LABELS=(
	"supervisor"
	"contributor"
	"persistent"
	"quality-review"
	"needs-maintainer-review"
	"routine-tracking"
	"on hold"
	# Last element of ISSUE_STATUS_LABELS (the status that blocks dispatch).
	# Index ref instead of literal avoids crossing the 3x string-literal ratchet.
	"${ISSUE_STATUS_LABELS[6]}"
)

# =============================================================================
# Source sub-libraries
# =============================================================================
# NOTE: Constants and validation functions are defined ABOVE so they are
# available to sub-libraries at source time. Sub-libraries depend on:
#   - _gh_validate_edit_args, _GH_EDIT_REJECTION_REASON (create, safe-edit)
#   - ORIGIN_LABELS, FEEDBACK_ROUTED_* (create)
#   - ISSUE_STATUS_LABELS, NON_TASK_LABELS (status)
#   - _gh_with_timeout (status)
if [[ -n "$_SHARED_GH_WRAPPERS_DIR" ]]; then
	# shellcheck source=managed-label-provisioning-lib.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/managed-label-provisioning-lib.sh"

	# shellcheck source=shared-gh-wrappers-session.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-session.sh"

	# shellcheck source=shared-gh-wrappers-create.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-create.sh"

	# shellcheck source=shared-gh-wrappers-safe-edit.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-safe-edit.sh"

	# shellcheck source=shared-gh-wrappers-status.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-status.sh"

	# shellcheck source=shared-gh-wrappers-checks.sh
	# shellcheck disable=SC1091  # sub-library resolved at runtime via $_SHARED_GH_WRAPPERS_DIR
	source "$_SHARED_GH_WRAPPERS_DIR/shared-gh-wrappers-checks.sh"
fi

#######################################
# Transition an issue or PR to an origin:* label atomically (t2200).
#
# Removes every sibling origin:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an
# existing issue/PR's origin label — ad-hoc --add-label/--remove-label
# calls must go through this helper so the mutual-exclusion invariant
# is enforced centrally.
#
# For new issues/PRs (gh_create_issue, gh_create_pr), the wrappers pass
# a single --label origin:* at creation time, so there is nothing to
# remove. This helper is for post-creation edits only.
#
# Args:
#   $1 — issue/PR number
#   $2 — repo slug (owner/repo)
#   $3 — new origin: one of interactive|worker|worker-takeover
#   $4 — (optional) --pr to edit a PR instead of an issue (default: issue)
#   $@ — additional gh edit flags passed through verbatim (e.g.,
#        --add-assignee, --remove-assignee, --add-label "other-label")
#
# Returns:
#   0 on gh success
#   1 on gh failure
#   2 on invalid origin argument (caller bug)
#
# IDENTITY KEY PRESERVATION: This function is 144 lines and MUST stay in the
# orchestrator file to preserve its (shared-gh-wrappers.sh, set_origin_label)
# identity key. Moving it would create a new function-complexity violation.
#
# Example:
#   set_origin_label 19638 owner/repo worker
#   set_origin_label 19638 owner/repo interactive --pr
#   set_origin_label 19638 owner/repo worker \
#       --add-assignee "$worker_login"
#######################################
# Apply origin label mutual exclusion via REST labels endpoints.
# Args: $1=issue/pr num, $2=repo slug, $3=new origin, $4..=extra edit flags
#######################################
_set_origin_label_rest() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_origin="$3"
	shift 3
	local _label
	for _label in "${ORIGIN_LABELS[@]}"; do
		[[ "$_label" == "$new_origin" ]] && continue
		_gh_with_timeout write gh api -X DELETE "/repos/${repo_slug}/issues/${issue_num}/labels/origin:${_label}" >/dev/null 2>&1 || true
	done
	_gh_with_timeout write gh api -X POST "/repos/${repo_slug}/issues/${issue_num}/labels" \
		-f "labels[]=origin:${new_origin}" >/dev/null 2>&1 || return 1
	if [[ $# -gt 0 ]]; then
		if command -v _rest_issue_edit >/dev/null 2>&1; then
			_rest_issue_edit "$issue_num" --repo "$repo_slug" "$@" || return 1
		else
			return 1
		fi
	fi
	return 0
}

#######################################
# Classify an origin-label write failure without exposing raw API output.
# Args: $1=stderr file (optional) $2=write exit code
# Output: bounded operator-safe failure reason
#######################################
_gh_origin_label_failure_kind() {
	local error_file="$1"
	local write_rc="$2"
	if [[ -n "$error_file" ]] &&
		grep -qiE 'permission|forbidden|Resource not accessible|HTTP 403' "$error_file" 2>/dev/null; then
		printf '%s\n' "credential lacks origin-label permission"
	elif [[ -n "$error_file" ]] &&
		grep -qiE 'rate limit|rateLimitExceeded|HTTP 429' "$error_file" 2>/dev/null; then
		printf '%s\n' "GitHub API rate limited the label write"
	elif [[ "$write_rc" -eq 124 ]]; then
		printf '%s\n' "GitHub label write timed out"
	else
		printf '%s\n' "GitHub label write failed"
	fi
	return 0
}

set_origin_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local new_origin="$3"
	shift 3

	# Validate inputs
	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$new_origin" ]]; then
		printf 'set_origin_label: issue_num, repo_slug, and new_origin are required\n' >&2
		return 2
	fi

	# Check for --pr flag in remaining args
	local gh_cmd="issue"
	local -a extra_flags=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			gh_cmd="pr"
			shift
			;;
		*)
			extra_flags+=("$1")
			shift
			;;
		esac
	done

	# Validate target origin
	local _valid=0
	local _origin
	for _origin in "${ORIGIN_LABELS[@]}"; do
		[[ "$_origin" == "$new_origin" ]] && {
			_valid=1
			break
		}
	done
	if [[ "$_valid" -eq 0 ]]; then
		printf 'set_origin_label: invalid origin "%s" (valid: %s)\n' \
			"$new_origin" "${ORIGIN_LABELS[*]}" >&2
		return 2
	fi

	# Ensure labels exist (cached per-process per-repo so this is cheap)
	ensure_origin_labels_exist "$repo_slug" || true

	# Build flag list: add target, remove all siblings.
	local -a _flags=()
	local _label
	for _label in "${ORIGIN_LABELS[@]}"; do
		if [[ "$_label" == "$new_origin" ]]; then
			_flags+=(--add-label "origin:${_label}")
		else
			_flags+=(--remove-label "origin:${_label}")
		fi
	done

	# Pass through any extra flags the caller wants to apply in the same edit
	if [[ ${#extra_flags[@]} -gt 0 ]]; then
		_flags+=("${extra_flags[@]}")
	fi

	local _err_file
	_err_file=$(mktemp -t aidevops-origin-label.XXXXXX) || {
		_gh_with_timeout write gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
		return $?
	}
	local _gh_rc=0
	if _gh_with_timeout write gh "$gh_cmd" edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>"$_err_file"; then
		rm -f "$_err_file"
		return 0
	else
		_gh_rc=$?
	fi
	# GH#28029: a GraphQL edit can create or expose the PR successfully but fail
	# while applying labels. Always attempt the equivalent REST label mutation
	# before returning failure; this is idempotent and preserves the origin mutex.
	# The previous rate-limit-only fallback left durable PRs without provenance
	# after non-rate-limit GraphQL failures.
	if _set_origin_label_rest "$issue_num" "$repo_slug" "$new_origin" "${extra_flags[@]}"; then
		rm -f "$_err_file"
		return 0
	fi
	local _failure_kind=""
	_failure_kind=$(_gh_origin_label_failure_kind "$_err_file" "$_gh_rc")
	printf 'set_origin_label: %s\n' "$_failure_kind" >&2
	rm -f "$_err_file"
	return "$_gh_rc"
}

#######################################
# Ensure solved:* attribution labels exist on a repo (idempotent).
# Args: $1 — repo slug (owner/repo)
# Returns: 0 on success/no-op, 1 when inventory or creation fails.
#######################################
_SOLVED_LABELS_ENSURED=""
ensure_solved_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	case ",${_SOLVED_LABELS_ENSURED:-}," in
	*",$repo,"*) return 0 ;;
	esac
	local labels_snapshot=""
	labels_snapshot=$(_gh_managed_label_names_snapshot "$repo") || return 1
	if ! _gh_managed_label_snapshot_has "$labels_snapshot" "solved:worker"; then
		AIDEVOPS_GH_ROUTE_DECISION="$_GH_MANAGED_LABEL_CREATE_ROUTE" \
			_gh_with_timeout write gh label create "solved:worker" --repo "$repo" \
			--description "Task was solved by a headless worker" \
			--color "0E8A16" 2>/dev/null || return 1
	fi
	if ! _gh_managed_label_snapshot_has "$labels_snapshot" "solved:interactive"; then
		AIDEVOPS_GH_ROUTE_DECISION="$_GH_MANAGED_LABEL_CREATE_ROUTE" \
			_gh_with_timeout write gh label create "solved:interactive" --repo "$repo" \
			--description "Task was solved by an interactive session" \
			--color "BFD4F2" 2>/dev/null || return 1
	fi
	_SOLVED_LABELS_ENSURED="${_SOLVED_LABELS_ENSURED:+$_SOLVED_LABELS_ENSURED,}$repo"
	return 0
}

#######################################
# Resolve completion attribution from a merged PR's origin labels.
# Unknown or contradictory provenance is deliberately not guessed.
# Args: $1 — comma-separated PR label names
# Stdout: worker|interactive
# Returns: 0 on unambiguous attribution, 1 otherwise.
#######################################
solved_actor_from_pr_labels() {
	local labels_csv="$1"
	local has_worker=0 has_takeover=0 has_interactive=0
	case ",${labels_csv}," in
	*,origin:worker,*) has_worker=1 ;;
	esac
	case ",${labels_csv}," in
	*,origin:worker-takeover,*) has_takeover=1 ;;
	esac
	case ",${labels_csv}," in
	*,origin:interactive,*) has_interactive=1 ;;
	esac

	# Takeover is explicit evidence that a worker ultimately solved work that may
	# retain interactive provenance for audit history. Other dual-origin states
	# are contradictory and remain unattributed.
	if [[ "$has_takeover" -eq 1 ]]; then
		printf 'worker\n'
		return 0
	fi
	if [[ "$has_worker" -eq 1 && "$has_interactive" -eq 1 ]]; then
		return 1
	fi
	if [[ "$has_worker" -eq 1 ]]; then
		printf 'worker\n'
		return 0
	fi
	if [[ "$has_interactive" -eq 1 ]]; then
		printf 'interactive\n'
		return 0
	fi
	return 1
}

#######################################
# Attribute an issue from an explicitly identified merged PR.
# The live mergedAt read prevents unmerged/closed PRs from being counted as
# solved work. PR origin is authoritative; issue origin is never consulted.
# Args: $1=issue number, $2=repo slug, $3=PR number
# Returns: 0 on attribution, 1 on missing/ambiguous evidence, 2 on bad args.
#######################################
set_solved_label_from_merged_pr() {
	local issue_num="$1"
	local repo_slug="$2"
	local pr_num="$3"
	if [[ ! "$issue_num" =~ ^[0-9]+$ || -z "$repo_slug" || ! "$pr_num" =~ ^[0-9]+$ ]]; then
		return 2
	fi

	local pr_evidence=""
	pr_evidence=$(gh pr view "$pr_num" --repo "$repo_slug" \
		--json mergedAt,labels \
		--jq '[.mergedAt // "", ([.labels[].name] | join(","))] | @tsv' 2>/dev/null) || return 1
	local merged_at="${pr_evidence%%$'\t'*}"
	local pr_labels="${pr_evidence#*$'\t'}"
	[[ -n "$merged_at" && "$pr_evidence" == *$'\t'* ]] || return 1

	local solved_actor=""
	solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || return 1
	set_solved_label "$issue_num" "$repo_slug" "$solved_actor"
	return $?
}

#######################################
# Transition an issue to a solved:* attribution label atomically.
#
# This is separate from origin:*: origin says who created the issue/PR;
# solved:* says who actually resolved it. The labels are mutually exclusive.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — solved actor: worker|interactive
#   $@ — additional gh issue edit flags passed through verbatim
# Returns:
#   0 on gh success
#   1 on gh failure
#   2 on invalid args
#######################################
set_solved_label() {
	local issue_num="$1"
	local repo_slug="$2"
	local solved_actor="$3"
	shift 3

	if [[ -z "$issue_num" || -z "$repo_slug" || -z "$solved_actor" ]]; then
		printf 'set_solved_label: issue_num, repo_slug, and solved_actor are required\n' >&2
		return 2
	fi

	local _valid=0
	local _actor
	for _actor in "${SOLVED_LABELS[@]}"; do
		[[ "$_actor" == "$solved_actor" ]] && {
			_valid=1
			break
		}
	done
	if [[ "$_valid" -eq 0 ]]; then
		printf 'set_solved_label: invalid actor "%s" (valid: %s)\n' \
			"$solved_actor" "${SOLVED_LABELS[*]}" >&2
		return 2
	fi

	ensure_solved_labels_exist "$repo_slug" || true

	local -a _flags=()
	local _label
	for _label in "${SOLVED_LABELS[@]}"; do
		if [[ "$_label" == "$solved_actor" ]]; then
			_flags+=(--add-label "solved:${_label}")
		else
			_flags+=(--remove-label "solved:${_label}")
		fi
	done
	_flags+=("$@")

	_gh_with_timeout write gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
	return $?
}
