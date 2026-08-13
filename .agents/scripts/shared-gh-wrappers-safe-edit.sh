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
[[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_SAFE_EDIT_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_SAFE_EDIT_LIB_LOADED=1
_GH_AUDIT_ISSUE_EDIT_OP="issue_edit"
_GH_AUDIT_NMR_LABEL="needs-maintainer-review"

# Resolve this module's dependencies from its own location. Do not inherit a
# caller-owned SCRIPT_DIR from an interactive recovery shell.
_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR="${_SHARED_GH_WRAPPERS_DIR:-}"
if [[ -z "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}" && -n "${BASH_SOURCE[0]:-}" ]]; then
	_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_SAFE_EDIT_DIR=""
elif [[ -z "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}" && -n "${ZSH_VERSION:-}" && -f "${0:-}" ]]; then
	_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR="$(cd "$(dirname "${0}")" 2>/dev/null && pwd)" || _SHARED_GH_WRAPPERS_SAFE_EDIT_DIR=""
fi

# Load dependencies when this focused module is sourced directly instead of via
# shared-gh-wrappers.sh. Set our include guard before this block so the
# orchestrator can safely source this file without recursive redefinition.
if ! command -v _gh_validate_edit_args >/dev/null 2>&1; then
	if [[ -f "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers.sh" ]]; then
		# shellcheck source=shared-gh-wrappers.sh
		# shellcheck disable=SC1091  # resolved from this module's directory at runtime
		source "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers.sh"
	fi
fi
if ! command -v _rest_should_fallback >/dev/null 2>&1 ||
	! command -v _rest_issue_edit >/dev/null 2>&1; then
	if [[ -f "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers-rest-fallback.sh" ]]; then
		# shellcheck source=shared-gh-wrappers-rest-fallback.sh
		# shellcheck disable=SC1091  # resolved from this module's directory at runtime
		source "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers-rest-fallback.sh"
	fi
fi
if ! command -v _gh_guard_public_write_args >/dev/null 2>&1 && [[ -f "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers-create.sh" ]]; then
	# shellcheck source=shared-gh-wrappers-create.sh
	# shellcheck disable=SC1091  # resolved from this module's directory at runtime
	source "${_SHARED_GH_WRAPPERS_SAFE_EDIT_DIR}/shared-gh-wrappers-create.sh"
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
# Non-blocking: returns an explicitly unavailable snapshot on any failure so a
# read outage can never masquerade as a destructive edit.
# Args: $1=issue_num $2=repo_slug
# Output: JSON {"capture_status":"ok|unavailable","title_len":N|null,
#               "body_len":N|null,"labels":["l1",...]|null}
#######################################
_gh_audit_fetch_issue_state_json() {
	local issue_num="$1"
	local repo="$2"
	local unavailable='{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null}'

	[[ -z "$issue_num" || -z "$repo" ]] && printf '%s\n' "$unavailable" && return 0
	[[ ! "$issue_num" =~ ^[0-9]+$ ]] && printf '%s\n' "$unavailable" && return 0
	command -v jq &>/dev/null || {
		printf '%s\n' "$unavailable"
		return 0
	}

	local data=""
	if command -v gh_issue_view >/dev/null 2>&1; then
		data=$(gh_issue_view "$issue_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	# REST-first routing can be locally unavailable while GitHub's GraphQL
	# transport remains healthy. Audit capture must try the independent native
	# read before declaring the state unavailable.
	if [[ -z "$data" ]]; then
		data=$(gh issue view "$issue_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	# The routed wrapper's fallback decision can itself be stale or unavailable.
	# Audit capture is read-only, so exhaust the independent REST transport before
	# recording a visibility gap.
	if [[ -z "$data" ]] && command -v _rest_issue_view >/dev/null 2>&1; then
		data=$(_rest_issue_view "$issue_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	if [[ -z "$data" ]]; then
		printf '%s\n' "$unavailable"
		return 0
	fi

	jq -c '{
		capture_status: "ok",
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || printf '%s\n' "$unavailable"
	return 0
}

#######################################
# Fetch PR state as JSON for the audit log.
# Non-blocking: returns an explicitly unavailable snapshot on any failure so a
# read outage can never masquerade as a destructive edit.
# Args: $1=pr_num $2=repo_slug
# Output: JSON {"capture_status":"ok|unavailable","title_len":N|null,
#               "body_len":N|null,"labels":["l1",...]|null}
#######################################
_gh_audit_fetch_pr_state_json() {
	local pr_num="$1"
	local repo="$2"
	local unavailable='{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null}'

	[[ -z "$pr_num" || -z "$repo" ]] && printf '%s\n' "$unavailable" && return 0
	[[ ! "$pr_num" =~ ^[0-9]+$ ]] && printf '%s\n' "$unavailable" && return 0
	command -v jq &>/dev/null || {
		printf '%s\n' "$unavailable"
		return 0
	}

	local data=""
	if command -v gh_pr_view >/dev/null 2>&1; then
		data=$(gh_pr_view "$pr_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	# Mirror issue capture: a failed REST-capable wrapper is not proof that the
	# native GraphQL read is unavailable.
	if [[ -z "$data" ]]; then
		data=$(gh pr view "$pr_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	if [[ -z "$data" ]] && command -v _rest_pr_view >/dev/null 2>&1; then
		data=$(_rest_pr_view "$pr_num" --repo "$repo" \
			--json title,body,labels 2>/dev/null) || data=""
	fi
	if [[ -z "$data" ]]; then
		printf '%s\n' "$unavailable"
		return 0
	fi

	jq -c '{
		capture_status: "ok",
		title_len: ((.title // "") | length),
		body_len:  ((.body  // "") | length),
		labels:    ([.labels[]?.name // empty])
	}' <<<"$data" 2>/dev/null || printf '%s\n' "$unavailable"
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
	local flags_json="{}"

	# Skip audit when number is unavailable or not an integer
	[[ -z "$number" || ! "$number" =~ ^[0-9]+$ ]] && return 0
	[[ -z "$repo" ]] && return 0

	local audit_helper
	audit_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-audit-log-helper.sh"
	[[ ! -x "$audit_helper" ]] && return 0
	# aidevops:trust-boundary — caller provenance alone is spoofable. Record the
	# exemption proof only after independently re-verifying the signed approval
	# and authenticated actor authority against current GitHub state.
	local approval_target_type=""
	if [[ "$op" == "$_GH_AUDIT_ISSUE_EDIT_OP" && "$caller_function" == "_approval_apply_issue_lifecycle_updates" ]]; then
		approval_target_type="issue"
	elif [[ "$op" == "pr_edit" && "$caller_function" == "_approval_apply_pr_lifecycle_updates" ]]; then
		approval_target_type="pr"
	fi
	if [[ -n "$approval_target_type" ]] && command -v cmd_verify &>/dev/null; then
		local approval_verification=""
		approval_verification=$(cmd_verify "$approval_target_type" "$number" "$repo" --require-authority 2>/dev/null) || approval_verification=""
		if [[ "$approval_verification" == "VERIFIED" ]]; then
			flags_json='{"approval_verified":"v2-current-state"}'
		fi
	fi
	# aidevops:trust-boundary — trusted-author NMR normalization is expected only
	# when the immutable snapshots show a pure NMR removal and live GitHub state
	# independently confirms both issue-author and current-token write authority.
	if [[ "$op" == "$_GH_AUDIT_ISSUE_EDIT_OP" && "$caller_function" == "_nmr_edit_issue_labels" ]] &&
		[[ "$caller_script" == */agents/scripts/pulse-nmr-approval.sh ||
			"$caller_script" == */.agents/scripts/pulse-nmr-approval.sh ]] &&
		_gh_audit_verify_trusted_author_nmr_transition "$repo" "$number" "$before_json" "$after_json"; then
		flags_json='{"trusted_author_nmr_verified":"v1-current-state"}'
	fi
	# aidevops:trust-boundary — a PR handoff removes an active worker status only
	# after full-loop opened a reviewable PR. Restrict the audit exemption to that
	# framework path and independently verify the resulting live lifecycle state.
	if [[ "$op" == "$_GH_AUDIT_ISSUE_EDIT_OP" ]] &&
		{ { [[ "$caller_function" == "_label_issue_in_review" ]] &&
			[[ "$caller_script" == */agents/scripts/full-loop-helper-commit.sh ||
				"$caller_script" == */.agents/scripts/full-loop-helper-commit.sh ]]; } ||
			{ [[ "$caller_function" == "main" ]] &&
				[[ "$caller_script" == */agents/scripts/full-loop-helper.sh ||
					"$caller_script" == */.agents/scripts/full-loop-helper.sh ]]; }; } &&
		_gh_audit_verify_full_loop_review_transition "$repo" "$number" "$before_json" "$after_json"; then
		flags_json='{"pr_review_handoff_verified":"v1-current-state"}'
	fi
	# aidevops:trust-boundary — planning publication may remove its temporary
	# manual hold only after preserving publication:pending. Require an exact,
	# content-preserving transition and re-read the current issue so a generic
	# wrapper invocation cannot suppress an unrelated protected-label removal.
	if [[ "$op" == "$_GH_AUDIT_ISSUE_EDIT_OP" &&
		"$caller_function" == "_publication_reconcile_one" ]] &&
		[[ "$caller_script" == */agents/scripts/planning-publication-reconcile.sh ||
			"$caller_script" == */.agents/scripts/planning-publication-reconcile.sh ]] &&
		_gh_audit_verify_planning_publication_transition "$repo" "$number" "$before_json" "$after_json"; then
		flags_json='{"planning_publication_verified":"v1-current-state"}'
	fi

	GH_AUDIT_QUIET=true "$audit_helper" record \
		--op "$op" \
		--repo "$repo" \
		--number "$number" \
		--before-json "${before_json:-{\}}" \
		--after-json "${after_json:-{\}}" \
		--caller-script "${caller_script:-unknown}" \
		--caller-function "${caller_function:-unknown}" \
		--caller-line "${caller_line:-0}" \
		--flags-json "$flags_json" \
		2>/dev/null || true

	return 0
}

#######################################
# Verify that a full-loop PR handoff changed only the active worker status.
# Args: repo, issue number, before JSON, after JSON
# Returns: 0 only for a comparable in-progress -> in-review transition whose
# current remote state still reflects the completed handoff.
#######################################
_gh_audit_verify_full_loop_review_transition() {
	local repo="$1"
	local number="$2"
	local before_json="$3"
	local after_json="$4"
	local issue_json=""
	local active_status="status:in-progress"
	local review_status="status:in-review"
	local capture_ok="ok"
	local open_state="open"

	[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || return 1
	jq -e -n --arg active "$active_status" --arg review "$review_status" --arg capture_ok "$capture_ok" \
		--argjson before "$before_json" --argjson after "$after_json" '
		($before.capture_status // $capture_ok) == $capture_ok
		and ($after.capture_status // $capture_ok) == $capture_ok
		and ([$before.labels[]?] | index($active) != null)
		and ([$before.labels[]?] | index($review) == null)
		and ([$after.labels[]?] | index($active) == null)
		and ([$after.labels[]?] | index($review) != null)
	' >/dev/null 2>&1 || return 1

	issue_json=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || return 1
	printf '%s\n' "$issue_json" | jq -e --arg active "$active_status" --arg review "$review_status" --arg open "$open_state" '
		(.state | strings | ascii_downcase) == $open
		and ([.labels[]?.name] | index($review) != null)
		and ([.labels[]?.name] | index($active) == null)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Verify that planning publication released only its temporary manual hold.
# Args: repo, issue number, before JSON, after JSON
# Returns: 0 only for a comparable no-auto-dispatch removal that retains the
# publication blocker and is still reflected by the current remote issue.
#######################################
_gh_audit_verify_planning_publication_transition() {
	local repo="$1"
	local number="$2"
	local before_json="$3"
	local after_json="$4"
	local issue_json=""
	local manual_hold="no-auto-dispatch"
	local publication_hold="publication:pending"
	local auto_dispatch="auto-dispatch"
	local open_state="open"

	[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || return 1
	jq -e -n --arg manual "$manual_hold" --arg publication "$publication_hold" \
		--arg auto "$auto_dispatch" --argjson before "$before_json" --argjson after "$after_json" '
		($before.capture_status // "ok") == "ok"
		and ($after.capture_status // "ok") == "ok"
		and $before.title_len == $after.title_len
		and $before.body_len == $after.body_len
		and ([$before.labels[]?] | index($manual) != null)
		and ([$before.labels[]?] | index($publication) != null)
		and ([$after.labels[]?] | index($manual) == null)
		and ([$after.labels[]?] | index($publication) != null)
		and ([$after.labels[]?] | index($auto) != null)
	' >/dev/null 2>&1 || return 1

	issue_json=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || return 1
	printf '%s\n' "$issue_json" | jq -e --arg manual "$manual_hold" \
		--arg publication "$publication_hold" --arg auto "$auto_dispatch" --arg open "$open_state" '
		(.state | strings | ascii_downcase) == $open
		and ([.labels[]?.name] | index($manual) == null)
		and ([.labels[]?.name] | index($publication) != null)
		and ([.labels[]?.name] | index($auto) != null)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Verify an audited trusted-author NMR normalization against live GitHub state.
# Args: repo, issue number, before JSON, after JSON
# Returns: 0 only for a comparable NMR removal by a write-authorized actor on a
# write-authorized author's issue; 1 for incomplete or untrusted evidence.
#######################################
_gh_audit_verify_trusted_author_nmr_transition() {
	local repo="$1"
	local number="$2"
	local before_json="$3"
	local after_json="$4"
	local issue_json=""
	local issue_identity=""
	local issue_author=""
	local issue_association=""
	local issue_author_type=""
	local current_actor=""

	[[ -n "$repo" && "$number" =~ ^[0-9]+$ ]] || return 1
	declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1 || return 1
	jq -e -n --arg nmr "$_GH_AUDIT_NMR_LABEL" \
		--argjson before "$before_json" --argjson after "$after_json" '
		($before.capture_status // "ok") == "ok"
		and ($after.capture_status // "ok") == "ok"
		and ([$before.labels[]?] | index($nmr) != null)
		and ([$after.labels[]?] | index($nmr) == null)
	' >/dev/null 2>&1 || return 1

	issue_json=$(gh api "repos/${repo}/issues/${number}" 2>/dev/null) || return 1
	printf '%s\n' "$issue_json" | jq -e --arg nmr "$_GH_AUDIT_NMR_LABEL" '
		([.labels[]?.name] | index($nmr) == null)
		and ([.labels[]?.name] | index("external-contributor") == null)
	' >/dev/null 2>&1 || return 1
	issue_identity=$(printf '%s\n' "$issue_json" | jq -r '
		if (.user.login // "") != "" and (.author_association // "") != ""
		then [(.user.login // ""), (.author_association // ""), (.user.type // "")] | @tsv
		else error("missing issue identity") end
	' 2>/dev/null) || return 1
	IFS=$'\t' read -r issue_author issue_association issue_author_type <<<"$issue_identity"
	[[ -n "$issue_author" && -n "$issue_association" ]] || return 1
	if [[ "$issue_author_type" != "Bot" ]]; then
		_gh_actor_has_repo_write_authority "$repo" "$issue_author" "$issue_association" >/dev/null 2>&1 || return 1
	fi

	current_actor=$(gh api user --jq '.login // empty' 2>/dev/null) || return 1
	[[ -n "$current_actor" ]] || return 1
	_gh_actor_has_repo_write_authority "$repo" "$current_actor" "COLLABORATOR" >/dev/null 2>&1 || return 1
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
	if ! _gh_guard_public_write_args "$@"; then
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
	_gh_audit_record_op "$_GH_AUDIT_ISSUE_EDIT_OP" "$_repo" "$_num" "$_before" "$_after" \
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
	if command -v _gh_wrapper_auto_sig >/dev/null 2>&1; then
		_gh_wrapper_auto_sig "$@"
		set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	fi
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr edit" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	if ! _gh_guard_public_write_args "$@"; then
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
# Records before/after state in gh-audit.log. Comment-bearing close calls are
# signed before the native one-shot close so retries cannot double-post.
# All arguments are forwarded to gh issue close.
# Returns the exit code of the underlying gh command.
#######################################
gh_issue_close_safe() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_issue_close_safe 2>/dev/null || true
	if command -v _gh_wrapper_auto_sig >/dev/null 2>&1; then
		_gh_wrapper_auto_sig "$@"
		set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	fi
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
