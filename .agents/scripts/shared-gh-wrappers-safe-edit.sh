#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Safe Edit, Close, Merge with Audit Logging
# =============================================================================
# Drop-in replacements for gh issue/pr edit/close/reopen/merge that add:
#   - Validation (no empty title/body, no stub titles)
#   - NDJSON audit logging via gh-audit-log-helper.sh
#   - REST fallback on GraphQL exhaustion
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-safe-edit.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, etc.)
#   - _gh_validate_edit_args, _GH_EDIT_REJECTION_REASON (from orchestrator)
#   - shared-gh-wrappers-rest-fallback.sh (_rest_should_fallback,
#     _rest_issue_edit)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_SAFE_EDIT_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_SAFE_EDIT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Load dependencies when this focused module is sourced directly instead of via
# shared-gh-wrappers.sh. Set our include guard before this block so the
# orchestrator can safely source this file without recursive redefinition.
if ! command -v _gh_validate_edit_args >/dev/null 2>&1; then
	if [[ -f "${SCRIPT_DIR}/shared-gh-wrappers.sh" ]]; then
		# shellcheck source=shared-gh-wrappers.sh
		# shellcheck disable=SC1091  # resolved from SCRIPT_DIR at runtime
		source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
	fi
fi
if ! command -v _rest_should_fallback >/dev/null 2>&1 ||
	! command -v _rest_issue_edit >/dev/null 2>&1; then
	if [[ -f "${SCRIPT_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=shared-gh-wrappers-rest-fallback.sh
		# shellcheck disable=SC1091  # resolved from SCRIPT_DIR at runtime
		source "${SCRIPT_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
fi

#######################################
# Internal: audit-log a safety rejection.
# Non-fatal — if audit-log-helper.sh is unavailable, the stderr message
# from _gh_validate_edit_args is still emitted.
# Args:
#   $1 — operation name (e.g. "gh issue edit")
#   $2 — rejection reason
#   $3..N — original command args (truncated to 500 chars for the log)
#######################################
_gh_edit_audit_rejection() {
	local operation="$1"
	local reason="$2"
	shift 2
	local context
	context=$(printf '%q ' "$@" | head -c 500)
	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/audit-log-helper.sh"
	if [[ -x "$audit_helper" ]]; then
		"$audit_helper" log operation.block \
			"gh_edit_safety: ${operation} rejected — ${reason}. Context: ${context}" \
			2>/dev/null || true
	fi
	return 0
}

# =============================================================================
# GH Audit Log Integration (GH#20145)
# =============================================================================
# Every destructive gh operation writes a structured NDJSON event to
# ~/.aidevops/logs/gh-audit.log via gh-audit-log-helper.sh record.
# Captures before/after state + anomaly signals. Fail-open: audit errors
# never block the main operation.

#######################################
# Extract the first positional argument (issue/PR number) from a gh arg list.
# Positional = first arg that does not start with "-".
# Output: number string on stdout, or empty if none found.
#######################################
_gh_extract_number_from_args() {
	local arg
	for arg in "$@"; do
		case "$arg" in
		-*)
			continue
			;;
		*)
			echo "$arg"
			return 0
			;;
		esac
	done
	echo ""
	return 0
}

#######################################
# Extract the --repo value from a gh arg list.
# Output: "owner/repo" on stdout, or empty if not present.
#######################################
_gh_extract_repo_from_args() {
	local i=0
	local -a args=("$@")
	while [[ $i -lt ${#args[@]} ]]; do
		case "${args[i]}" in
		--repo)
			echo "${args[i + 1]:-}"
			return 0
			;;
		--repo=*)
			echo "${args[i]#--repo=}"
			return 0
			;;
		esac
		i=$((i + 1))
	done
	echo ""
	return 0
}

#######################################
# Fetch issue state as JSON for the audit log.
# Non-blocking: returns empty-state JSON on any failure.
# Args: $1=issue_num $2=repo_slug
# Output: JSON {"title_len":N,"body_len":N,"labels":["l1",...]}
#######################################
_gh_audit_fetch_issue_state_json() {
	local issue_num="$1"
	local repo="$2"
	local empty='{"title_len":0,"body_len":0,"labels":[]}'

	[[ -z "$issue_num" || -z "$repo" ]] && echo "$empty" && return 0
	[[ ! "$issue_num" =~ ^[0-9]+$ ]] && echo "$empty" && return 0
	command -v jq &>/dev/null || { echo "$empty"; return 0; }

	local data
	data=$(gh issue view "$issue_num" --repo "$repo" \
		--json title,body,labels 2>/dev/null) || { echo "$empty"; return 0; }

	jq -c '{
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || echo "$empty"
	return 0
}

#######################################
# Fetch PR state as JSON for the audit log.
# Non-blocking: returns empty-state JSON on any failure.
# Args: $1=pr_num $2=repo_slug
# Output: JSON {"title_len":N,"body_len":N,"labels":["l1",...]}
#######################################
_gh_audit_fetch_pr_state_json() {
	local pr_num="$1"
	local repo="$2"
	local empty='{"title_len":0,"body_len":0,"labels":[]}'

	[[ -z "$pr_num" || -z "$repo" ]] && echo "$empty" && return 0
	[[ ! "$pr_num" =~ ^[0-9]+$ ]] && echo "$empty" && return 0
	command -v jq &>/dev/null || { echo "$empty"; return 0; }

	local data
	data=$(gh pr view "$pr_num" --repo "$repo" \
		--json title,body,labels 2>/dev/null) || { echo "$empty"; return 0; }

	jq -c '{
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || echo "$empty"
	return 0
}

#######################################
# Write one audit record via gh-audit-log-helper.sh record.
# Non-blocking: silently returns 0 on any failure.
# Args:
#   $1  op               — issue_edit | issue_close | etc.
#   $2  repo             — owner/repo (may be empty)
#   $3  number           — integer (may be empty, skips record if so)
#   $4  before_json      — state before operation
#   $5  after_json       — state after operation
#   $6  caller_script    — BASH_SOURCE of the wrapper's caller
#   $7  caller_function  — FUNCNAME of the wrapper's caller
#   $8  caller_line      — BASH_LINENO of the call site
#######################################
_gh_audit_record_op() {
	local op="$1" repo="$2" number="$3"
	local before_json="$4" after_json="$5"
	local caller_script="$6" caller_function="$7" caller_line="$8"

	# Skip audit when number is unavailable or not an integer
	[[ -z "$number" || ! "$number" =~ ^[0-9]+$ ]] && return 0
	[[ -z "$repo" ]] && return 0

	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-audit-log-helper.sh"
	[[ ! -x "$audit_helper" ]] && return 0

	GH_AUDIT_QUIET=true "$audit_helper" record \
		--op "$op" \
		--repo "$repo" \
		--number "$number" \
		--before-json "${before_json:-{\}}" \
		--after-json "${after_json:-{\}}" \
		--caller-script "${caller_script:-unknown}" \
		--caller-function "${caller_function:-unknown}" \
		--caller-line "${caller_line:-0}" \
		2>/dev/null || true

	return 0
}

#######################################
# gh_issue_edit_safe — drop-in replacement for gh issue edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# Records an audit event to gh-audit.log on success.
# All arguments are forwarded to gh issue edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_issue_edit_safe() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_issue_edit_safe 2>/dev/null || true
	if ! _gh_wrapper_normalize_stdin_body_file "$@"; then
		_gh_edit_audit_rejection "gh issue edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue edit "$@"
	local _exit=$?
	if [[ $_exit -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue edit"
		_rest_issue_edit "$@"
		_exit=$?
	fi
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_edit" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_edit_safe — drop-in replacement for gh pr edit.
# Validates --title/--body before delegating. Rejects empty/stub values.
# Records an audit event to gh-audit.log on success.
# All arguments are forwarded to gh pr edit on success.
# Returns 1 with stderr message on validation failure.
#######################################
gh_pr_edit_safe() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_pr_edit_safe 2>/dev/null || true
	if ! _gh_wrapper_normalize_stdin_body_file "$@"; then
		_gh_edit_audit_rejection "gh pr edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr edit "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_edit" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_issue_close_safe — close a GitHub issue with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh issue close.
# Returns the exit code of the underlying gh command.
#######################################
gh_issue_close_safe() {
	gh_record_call graphql gh_issue_close_safe 2>/dev/null || true
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue close "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_close" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_issue_reopen_safe — reopen a GitHub issue with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh issue reopen.
# Returns the exit code of the underlying gh command.
#######################################
gh_issue_reopen_safe() {
	gh_record_call graphql gh_issue_reopen_safe 2>/dev/null || true
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	gh issue reopen "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_issue_state_json "$_num" "$_repo")"
	_gh_audit_record_op "issue_reopen" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_close_safe — close a GitHub PR with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh pr close.
# Returns the exit code of the underlying gh command.
#######################################
gh_pr_close_safe() {
	gh_record_call graphql gh_pr_close_safe 2>/dev/null || true
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr close "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_close" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}

#######################################
# gh_pr_merge_safe — merge a GitHub PR with audit logging.
# Records before/after state in gh-audit.log.
# All arguments are forwarded to gh pr merge.
# Returns the exit code of the underlying gh command.
#######################################
gh_pr_merge_safe() {
	gh_record_call graphql gh_pr_merge_safe 2>/dev/null || true
	local _num _repo _before _after
	_num="$(_gh_extract_number_from_args "$@")"
	_repo="$(_gh_extract_repo_from_args "$@")"
	_before="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	gh pr merge "$@"
	local _exit=$?
	_after="$(_gh_audit_fetch_pr_state_json "$_num" "$_repo")"
	_gh_audit_record_op "pr_merge" "$_repo" "$_num" "$_before" "$_after" \
		"${BASH_SOURCE[1]:-}" "${FUNCNAME[1]:-}" "${BASH_LINENO[0]:-0}"
	return "$_exit"
}
