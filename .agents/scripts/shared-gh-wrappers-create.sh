#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared GH Wrappers -- Issue/PR Creation, Comments, Parent Linking
# =============================================================================
# Functions for creating issues and PRs with origin-label awareness,
# posting comments with auto-signature, and auto-linking sub-issues
# to parent issues at creation time.
#
# Usage: source "${SCRIPT_DIR}/shared-gh-wrappers-create.sh"
#
# Dependencies:
#   - shared-constants.sh (print_info, print_warning, etc.)
#   - shared-gh-wrappers-session.sh (detect_session_origin, session_origin_label,
#     _gh_wrapper_args_have_assignee, _gh_wrapper_args_have_label,
#     _gh_wrapper_auto_assignee, _gh_wrapper_auto_sig)
#   - shared-gh-wrappers-rest-fallback.sh (_rest_should_fallback,
#     _rest_issue_create, _rest_pr_create, _rest_issue_comment,
#     _rest_pr_comment)
#   - _gh_validate_edit_args, _gh_edit_audit_rejection (from orchestrator)
#   - gh CLI, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_GH_WRAPPERS_CREATE_LIB_LOADED:-}" ]] && return 0
_SHARED_GH_WRAPPERS_CREATE_LIB_LOADED=1
_GH_CREATE_AUTO_DISPATCH_LABEL="auto-dispatch"

# Resolve this module's directory rather than trusting a caller-owned
# SCRIPT_DIR. Recovery shells commonly export SCRIPT_DIR for their own helper.
_GH_WRAPPERS_CREATE_SOURCE="${BASH_SOURCE[0]:-${0:-}}"
_GH_WRAPPERS_CREATE_DIR="$(cd "$(dirname "${_GH_WRAPPERS_CREATE_SOURCE}")" 2>/dev/null && pwd)" || _GH_WRAPPERS_CREATE_DIR=""
if [[ -z "${_GH_WRAPPERS_CREATE_DIR}" || ! -f "${_GH_WRAPPERS_CREATE_DIR}/privacy-guard-helper.sh" ]]; then
	printf 'shared-gh-wrappers-create: cannot load privacy-guard-helper.sh from this module directory\n' >&2
	return 1
fi

if ! command -v privacy_guard_public_write >/dev/null 2>&1; then
	# shellcheck source=privacy-guard-helper.sh
	# shellcheck disable=SC1091  # resolved from this module's directory at runtime
	source "${_GH_WRAPPERS_CREATE_DIR}/privacy-guard-helper.sh"
fi
if ! command -v privacy_guard_public_write >/dev/null 2>&1; then
	printf 'shared-gh-wrappers-create: privacy_guard_public_write did not load\n' >&2
	return 1
fi

#######################################
# Scan normalized GitHub write arguments before public transport.
# Private targets remain untouched; unknown targets fail closed.
#######################################
_gh_guard_public_write_args() {
	local repo="" text="" expect="" arg body_file
	for arg in "$@"; do
		if [[ -n "$expect" ]]; then
			case "$expect" in
			repo) repo="$arg" ;;
			text) text+=$'\n'"$arg" ;;
			body-file)
				body_file="$arg"
				[[ -r "$body_file" ]] || return 1
				text+=$'\n'"$(<"$body_file")"
				;;
			esac
			expect=""
			continue
		fi
		case "$arg" in
		--repo) expect="repo" ;;
		--repo=*) repo="${arg#--repo=}" ;;
		--title | --body | --comment | -c) expect="text" ;;
		--title=* | --body=* | --comment=* | -c=*) text+=$'\n'"${arg#*=}" ;;
		--body-file) expect="body-file" ;;
		--body-file=*)
			body_file="${arg#--body-file=}"
			[[ -r "$body_file" ]] || return 1
			text+=$'\n'"$(<"$body_file")"
			;;
		esac
	done
	privacy_guard_public_write "$repo" "$text"
	return $?
}

# t2436: Extract the tNNN task ID from a --title "tNNN: ..." argument.
# Also accepts an explicit --todo-task-id tNNN flag (callers that know the ID).
# Returns the task ID (e.g., "t2436") or empty string on stdout. Non-blocking.
#
# t2688: Uses module-level globals instead of `local -n` namerefs for
# compatibility with bash 3.2 AND zsh. Namerefs (bash 4.3+) fail with
# `local:2: bad option: -n` under zsh, and are unavailable on macOS system
# bash 3.2 in the rare case the re-exec guard in shared-constants.sh cannot
# fire (e.g., file sourced directly into a zsh interactive shell via a
# user's .zshrc chain). Canonical pattern: claim-task-id.sh:643,757.
_GH_WRAPPER_EXTRACT_TODO=""
_GH_WRAPPER_EXTRACT_TITLE=""
_gh_wrapper_extract_task_id_from_title() {
	# Reset the module-level globals before each call.
	_GH_WRAPPER_EXTRACT_TODO=""
	_GH_WRAPPER_EXTRACT_TITLE=""
	local _prev="" _a
	for _a in "$@"; do
		_gh_wrapper_extract_task_id_from_title_step "$_a" "$_prev"
		_prev="$_a"
	done
	echo "${_GH_WRAPPER_EXTRACT_TODO:-$_GH_WRAPPER_EXTRACT_TITLE}"
	return 0
}

# Helper for _gh_wrapper_extract_task_id_from_title: process one arg/prev pair.
# Writes to module-level globals _GH_WRAPPER_EXTRACT_TODO and
# _GH_WRAPPER_EXTRACT_TITLE. The caller initialises both globals to ""
# before the loop. Bash 3.2 / zsh compatible (no nameref / no `local -n`).
_gh_wrapper_extract_task_id_from_title_step() {
	local _cur="$1" _prev="$2"
	if [[ "$_prev" == "--todo-task-id" ]]; then
		_GH_WRAPPER_EXTRACT_TODO="$_cur"
	elif [[ "$_prev" == "--title" && "$_cur" =~ ^(t[0-9]+): ]]; then
		_GH_WRAPPER_EXTRACT_TITLE="${BASH_REMATCH[1]}"
	elif [[ "$_cur" =~ ^--title=(t[0-9]+): ]]; then
		_GH_WRAPPER_EXTRACT_TITLE="${BASH_REMATCH[1]}"
	fi
	return 0
}

# t2436: Derive labels from TODO.md tags for a given task ID.
# Scans the current working directory's TODO.md (or the repo containing it)
# for the task entry and maps its tags to canonical GitHub labels via
# map_tags_to_labels() from issue-sync-lib.sh.
#
# This closes the race window between issue creation and the asynchronous
# issue-sync workflow trigger: protected labels like parent-task are applied
# at creation time rather than seconds later.
#
# Non-blocking: returns empty on any failure (missing TODO.md, no task found,
# lib unavailable). Never errors — callers ignore empty return value.
_gh_wrapper_derive_todo_labels() {
	local task_id="$1"
	[[ -z "$task_id" ]] && return 0

	local todo_file="${PWD}/TODO.md"
	[[ ! -f "$todo_file" ]] && return 0

	# Find the task line matching the task ID
	local task_line
	task_line=$(grep -m1 -E "^[[:space:]]*-[[:space:]]\[.\][[:space:]]*${task_id}([[:space:]]|\.|$)" \
		"$todo_file" 2>/dev/null || echo "")
	[[ -z "$task_line" ]] && return 0

	# Extract hashtags — mirrors parse_task_line() in issue-sync-lib.sh
	local tags
	tags=$(printf '%s' "$task_line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//')
	[[ -z "$tags" ]] && return 0

	# Lazy-source issue-sync-lib.sh for map_tags_to_labels if not yet loaded.
	# Guarded with include-flag to prevent double-sourcing in scripts that
	# already have issue-sync-lib.sh in scope (e.g. claim-task-id.sh).
	if [[ "$(type -t map_tags_to_labels 2>/dev/null)" != "function" ]]; then
		local _gh_w_script_dir
		_gh_w_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || true
		local _gh_w_lib="${_gh_w_script_dir}/issue-sync-lib.sh"
		# shellcheck source=/dev/null
		[[ -f "$_gh_w_lib" ]] && source "$_gh_w_lib" 2>/dev/null || true
	fi

	if [[ "$(type -t map_tags_to_labels 2>/dev/null)" == "function" ]]; then
		local derived_labels
		derived_labels=$(map_tags_to_labels "$tags") || true
		[[ -n "$derived_labels" ]] && echo "$derived_labels"
	fi
	return 0
}

# t2436 / t3088: Prepare creation-time labels and a filtered arg list.
# Extracts --todo-task-id from args, derives labels from TODO.md tags for the
# embedded task ID, and writes the result to module-level globals so the caller
# can splice them into the gh issue create invocation. Bash-3.2 / zsh compatible
# (no nameref); pattern mirrors _gh_wrapper_extract_task_id_from_title.
#
# Outputs (set on every call):
#   _GH_CI_FILTERED_ARGS  — original args minus --todo-task-id and its value
#   _GH_CI_TODO_LABEL_ARGS — empty array, or (--label "$derived_labels")
#
# Non-blocking: every step returns silently on failure.
_GH_CI_FILTERED_ARGS=()
_GH_CI_TODO_LABEL_ARGS=()
_gh_ci_prepare_todo_labels() {
	_GH_CI_FILTERED_ARGS=()
	_GH_CI_TODO_LABEL_ARGS=()

	local _todo_task_id=""
	_todo_task_id=$(_gh_wrapper_extract_task_id_from_title "$@") || true

	# Filter --todo-task-id and its value out of the arg list
	local _gh_ci_skip_next=false
	local _gh_ci_arg
	for _gh_ci_arg in "$@"; do
		if [[ "$_gh_ci_skip_next" == "true" ]]; then
			_gh_ci_skip_next=false
			continue
		fi
		if [[ "$_gh_ci_arg" == "--todo-task-id" ]]; then
			_gh_ci_skip_next=true
			continue
		fi
		_GH_CI_FILTERED_ARGS+=("$_gh_ci_arg")
	done

	if [[ -n "$_todo_task_id" ]]; then
		local _todo_derived_labels=""
		_todo_derived_labels=$(_gh_wrapper_derive_todo_labels "$_todo_task_id") || true
		if [[ -n "$_todo_derived_labels" ]]; then
			print_info "[INFO] t2436: Derived labels from TODO.md for ${_todo_task_id}: ${_todo_derived_labels}"
			_GH_CI_TODO_LABEL_ARGS=(--label "$_todo_derived_labels")
		fi
	fi
	return 0
}

# t3099: Prepare the default issue lifecycle label. gh_create_issue already
# injects an origin label when absent; this companion default prevents newly
# created origin-labelled issues from entering the reconciler's triage-missing
# bucket when callers also omit tier/auto-dispatch metadata.
_GH_CI_STATUS_LABEL_ARGS=()
_gh_ci_prepare_status_label() {
	_GH_CI_STATUS_LABEL_ARGS=()
	if ! _gh_wrapper_args_have_label_prefix "status:" "$@"; then
		_GH_CI_STATUS_LABEL_ARGS=(--label "status:available")
	fi
	return 0
}

# GH#29394/GH#29408: NMR is reserved for external-author trust gates.
# Wrapper-created issues are authored by the authenticated token actor, so a
# live write-level permission check can safely remove legacy trusted-author NMR.
# The old NMR request implies dispatch intent unless a separate explicit
# hold/tracker label suppresses it. Unknown permission fails closed.
_GH_CI_TRUST_NORMALIZED_ARGS=()
_gh_ci_replace_nmr_label_csv() {
	local labels_csv="$1"
	local replacement_label="$2"
	local old_ifs="${IFS-}"
	local ifs_was_set=0
	local label=""
	local normalized=""
	local replacement_seen=0
	local -a labels=()

	[[ -n "${IFS+x}" ]] && ifs_was_set=1
	IFS=',' read -ra labels <<<"$labels_csv"
	if [[ "$ifs_was_set" -eq 1 ]]; then
		IFS="$old_ifs"
	else
		unset IFS
	fi

	for label in "${labels[@]}"; do
		if [[ "$label" == "needs-maintainer-review" ]]; then
			[[ -n "$replacement_label" ]] || continue
			label="$replacement_label"
		fi
		if [[ -n "$replacement_label" && "$label" == "$replacement_label" ]]; then
			[[ "$replacement_seen" -eq 1 ]] && continue
			replacement_seen=1
		fi
		if [[ -n "$normalized" ]]; then
			normalized="${normalized},${label}"
		else
			normalized="$label"
		fi
	done
	printf '%s\n' "$normalized"
	return 0
}

_gh_ci_prepare_trusted_nmr_labels() {
	_GH_CI_TRUST_NORMALIZED_ARGS=("$@")
	_gh_wrapper_args_have_label "needs-maintainer-review" "$@" || return 0
	# A trusted automation account can create an issue from external source
	# material. The explicit provenance label keeps that authority boundary from
	# being mistaken for a self-review hold.
	if _gh_wrapper_args_have_label "external-contributor" "$@"; then
		print_info "[INFO] GH#29394: preserving external-origin needs-maintainer-review"
		return 0
	fi

	local target_repo=""
	target_repo=$(_gh_extract_repo_from_args "$@" 2>/dev/null || true)
	[[ -n "$target_repo" ]] || return 0
	declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1 || return 0
	if ! _gh_current_user_allows_repo_write "$target_repo" >/dev/null 2>&1; then
		print_warning "[WARN] GH#29394: preserving needs-maintainer-review because creator write authority could not be verified (${AIDEVOPS_GH_WRITE_PERMISSION_REASON:-unknown})"
		return 0
	fi

	local infer_dispatch=1
	local replacement_label="$_GH_CREATE_AUTO_DISPATCH_LABEL"
	local explicit_suppress=0
	local suppression_label=""
	for suppression_label in \
		"hold-for-review" "no-auto-dispatch" "parent-task" "meta" \
		"persistent" "supervisor" "contributor" "quality-review" \
		"routine-tracking" "needs-credentials" "needs-maintainer-permissions" \
		"status:done" "status:resolved"; do
		if _gh_wrapper_args_have_label "$suppression_label" "${_GH_CI_TRUST_NORMALIZED_ARGS[@]}"; then
			explicit_suppress=1
			infer_dispatch=0
			replacement_label=""
			break
		fi
	done
	if _gh_wrapper_args_have_label "security" "${_GH_CI_TRUST_NORMALIZED_ARGS[@]}" \
		|| _gh_wrapper_args_have_label "security-review" "${_GH_CI_TRUST_NORMALIZED_ARGS[@]}"; then
		infer_dispatch=0
		replacement_label="hold-for-review"
	elif [[ "$explicit_suppress" -eq 0 ]] \
		&& _gh_wrapper_args_have_label "$_GH_CREATE_AUTO_DISPATCH_LABEL" "${_GH_CI_TRUST_NORMALIZED_ARGS[@]}"; then
		infer_dispatch=0
		replacement_label=""
	fi

	local i=0
	local labels_csv=""
	local original_labels=""
	local -a normalized_args=()
	while [[ "$i" -lt ${#_GH_CI_TRUST_NORMALIZED_ARGS[@]} ]]; do
		case "${_GH_CI_TRUST_NORMALIZED_ARGS[i]}" in
		--label)
			if [[ $((i + 1)) -lt ${#_GH_CI_TRUST_NORMALIZED_ARGS[@]} ]]; then
				original_labels="${_GH_CI_TRUST_NORMALIZED_ARGS[i + 1]}"
				labels_csv=$(_gh_ci_replace_nmr_label_csv "$original_labels" "$replacement_label")
				if [[ -n "$labels_csv" ]]; then
					normalized_args+=(--label "$labels_csv")
				fi
				if [[ -n "$replacement_label" && ",${original_labels}," == *",needs-maintainer-review,"* ]]; then
					replacement_label=""
				fi
				i=$((i + 2))
				continue
			fi
			normalized_args+=("${_GH_CI_TRUST_NORMALIZED_ARGS[i]}")
			;;
		--label=*)
			original_labels="${_GH_CI_TRUST_NORMALIZED_ARGS[i]#--label=}"
			labels_csv=$(_gh_ci_replace_nmr_label_csv "$original_labels" "$replacement_label")
			if [[ -n "$labels_csv" ]]; then
				normalized_args+=("--label=${labels_csv}")
			fi
			if [[ -n "$replacement_label" && ",${original_labels}," == *",needs-maintainer-review,"* ]]; then
				replacement_label=""
			fi
			;;
		*) normalized_args+=("${_GH_CI_TRUST_NORMALIZED_ARGS[i]}") ;;
		esac
		i=$((i + 1))
	done
	_GH_CI_TRUST_NORMALIZED_ARGS=("${normalized_args[@]}")
	if [[ "$infer_dispatch" -eq 1 ]]; then
		print_info "[INFO] GH#29408: translated trusted-author needs-maintainer-review to auto-dispatch"
	else
		print_info "[INFO] GH#29408: removed trusted-author needs-maintainer-review while preserving explicit lifecycle intent"
	fi
	return 0
}

_GH_CI_CONTRACT_ARGS=()
_gh_ci_prepare_parent_close_contract() {
	local is_parent_task="$1"
	shift
	_GH_CI_CONTRACT_ARGS=("$@")
	[[ "$is_parent_task" -eq 1 ]] || return 0

	local i=0 body_idx=-1 body="" body_file_idx=-1 body_file=""
	local body_eq=0 body_file_eq=0
	while [[ "$i" -lt ${#_GH_CI_CONTRACT_ARGS[@]} ]]; do
		case "${_GH_CI_CONTRACT_ARGS[i]}" in
		--body)
			body_idx=$i
			body="${_GH_CI_CONTRACT_ARGS[i + 1]:-}"
			;;
		--body=*)
			body_idx=$i
			body="${_GH_CI_CONTRACT_ARGS[i]#--body=}"
			body_eq=1
			;;
		--body-file)
			body_file_idx=$i
			body_file="${_GH_CI_CONTRACT_ARGS[i + 1]:-}"
			;;
		--body-file=*)
			body_file_idx=$i
			body_file="${_GH_CI_CONTRACT_ARGS[i]#--body-file=}"
			body_file_eq=1
			;;
		esac
		i=$((i + 1))
	done
	if [[ -z "$body" && -n "$body_file" && -r "$body_file" ]]; then
		body=$(<"$body_file")
	fi
	[[ -n "$body" ]] || return 0
	[[ "$body" == *"<!-- parent-close-contract:"* ]] && return 0

	local marker='<!-- parent-close-contract: needs-decomposition -->'
	if printf '%s\n' "$body" | grep -qE '^##[[:space:]]+Phases([[:space:]]|$)'; then
		marker='<!-- parent-close-contract: phase-plan -->'
	else
		local children_count=0
		children_count=$(printf '%s\n' "$body" | awk '
			/^##[[:space:]]+(Children|Child Issues|Sub-issues|Sub-tasks)([[:space:]]|$)/ { in_children=1; next }
			in_children && /^##[[:space:]]/ { exit }
			in_children { print }
		' | grep -oE '#[0-9]+' | sort -u | wc -l | tr -d ' ' || true)
		if [[ "$children_count" =~ ^[0-9]+$ ]] && [[ "$children_count" -gt 0 ]]; then
			marker="<!-- parent-close-contract: expected-children=${children_count} -->"
		fi
	fi
	local contracted_body="${body}

${marker}"

	if [[ "$body_idx" -ge 0 ]]; then
		if [[ "$body_eq" -eq 1 ]]; then
			_GH_CI_CONTRACT_ARGS[body_idx]="--body=${contracted_body}"
		else
			_GH_CI_CONTRACT_ARGS[body_idx + 1]="$contracted_body"
		fi
		return 0
	fi
	if [[ "$body_file_idx" -ge 0 ]]; then
		local contracted_body_file=""
		contracted_body_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-parent-body.XXXXXX") || return 0
		push_cleanup "rm -f \"$contracted_body_file\""
		printf '%s\n' "$contracted_body" >"$contracted_body_file" || return 0
		if [[ "$body_file_eq" -eq 1 ]]; then
			_GH_CI_CONTRACT_ARGS[body_file_idx]="--body-file=${contracted_body_file}"
		else
			_GH_CI_CONTRACT_ARGS[body_file_idx + 1]="$contracted_body_file"
		fi
	fi
	return 0
}

_GH_CI_READY_ARGS=()
_gh_ci_prepare_parent_contract_and_signature() {
	local is_parent_task=0
	if _gh_wrapper_args_have_label "parent-task" "$@" "${_GH_CI_TODO_LABEL_ARGS[@]}"; then
		is_parent_task=1
	fi
	_gh_ci_prepare_parent_close_contract "$is_parent_task" "$@"
	_gh_wrapper_auto_sig "${_GH_CI_CONTRACT_ARGS[@]}"
	_GH_CI_READY_ARGS=("${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}")
	return 0
}

_gh_lock_created_auto_dispatch_issue() {
	local issue_number="$1"
	local target_repo="$2"
	local lock_dir="${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR:-${HOME}/.aidevops/cache/auto-dispatch-locks}"
	local lock_key="${target_repo//\//--}-${issue_number}"
	local locked_state=""

	# aidevops:trust-boundary — freeze worker-authorized instructions at
	# creation time instead of leaving a public comment window until spawn.
	if gh issue lock "$issue_number" --repo "$target_repo" --reason resolved >/dev/null 2>&1; then
		locked_state=$(gh api "repos/${target_repo}/issues/${issue_number}" --jq '.locked == true' 2>/dev/null) || locked_state=""
	fi
	if [[ "$locked_state" != "true" ]]; then
		print_warning "Issue #${issue_number} was created with auto-dispatch, but its conversation lock could not be verified; Pulse will fail closed before worker spawn."
		return 1
	fi
	mkdir -p "$lock_dir" 2>/dev/null || return 1
	: >"${lock_dir}/${lock_key}" 2>/dev/null || return 1
	return 0
}

_gh_finish_created_issue() {
	local issue_output="$1"
	local target_repo="$2"
	local auto_assignee="$3"
	shift 3
	local issue_number="${issue_output##*/}"
	issue_number="${issue_number%%[[:space:]]*}"

	if [[ "$issue_number" =~ ^[0-9]+$ ]] &&
		_gh_wrapper_args_have_label "$_GH_CREATE_AUTO_DISPATCH_LABEL" "$@"; then
		_gh_lock_created_auto_dispatch_issue "$issue_number" "$target_repo" || true
	fi
	if [[ -n "$auto_assignee" && "$issue_number" =~ ^[0-9]+$ ]] &&
		! gh issue edit "$issue_number" --repo "$target_repo" --add-assignee "$auto_assignee" >/dev/null 2>&1; then # aidevops-allow: raw-gh-wrapper
		print_warning "Issue #${issue_number} was created, but automatic assignment to ${auto_assignee} failed; continuing with the durable issue."
	fi
	_gh_auto_link_sub_issue "$issue_output" "$@"
	return 0
}

gh_create_issue() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_create_issue 2>/dev/null || true
	if ! _gh_wrapper_normalize_stdin_body_file "$@"; then
		_gh_edit_audit_rejection "gh issue create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh issue create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	# t3088: inject session origin only when the caller has not supplied one.
	local -a _origin_label_args=()
	if ! _gh_wrapper_args_have_origin_label "$@"; then
		local origin_label
		origin_label=$(session_origin_label)
		_origin_label_args=(--label "$origin_label")
	fi
	# Ensure labels exist on the target repo (once per repo per process)
	_ensure_origin_labels_for_args "$@"

	# t2436: Derive creation-time labels from TODO.md tags + filter --todo-task-id.
	# Helper writes _GH_CI_FILTERED_ARGS and _GH_CI_TODO_LABEL_ARGS globals.
	_gh_ci_prepare_todo_labels "$@"
	if [[ ${#_GH_CI_FILTERED_ARGS[@]} -gt 0 ]]; then
		set -- "${_GH_CI_FILTERED_ARGS[@]}"
	else
		set --
	fi
	local -a _todo_label_args=()
	if [[ ${#_GH_CI_TODO_LABEL_ARGS[@]} -gt 0 ]]; then
		_todo_label_args=("${_GH_CI_TODO_LABEL_ARGS[@]}")
	fi

	# Stamp parent close contracts before the signature so it remains the footer.
	_gh_ci_prepare_parent_contract_and_signature "$@"
	set -- "${_GH_CI_READY_ARGS[@]}"

	# Fold derived labels into one list, then normalize trusted-author NMR before
	# building either the GraphQL or REST creation command.
	if [[ ${#_todo_label_args[@]} -gt 0 ]]; then
		_gh_ci_prepare_trusted_nmr_labels "$@" "${_todo_label_args[@]}"
	else
		_gh_ci_prepare_trusted_nmr_labels "$@"
	fi
	set -- "${_GH_CI_TRUST_NORMALIZED_ARGS[@]}"
	_todo_label_args=()
	_gh_ci_prepare_status_label "$@"
	if ! _gh_guard_public_write_args "$@"; then
		return 1
	fi

	# Build command arrays safely; avoid empty-arg injection (GH#22056).
	local -a _issue_cmd=(gh issue create "$@")
	local -a _rest_args=("$@")
	if [[ ${#_GH_CI_STATUS_LABEL_ARGS[@]} -gt 0 ]]; then
		_issue_cmd+=("${_GH_CI_STATUS_LABEL_ARGS[@]}")
		_rest_args+=("${_GH_CI_STATUS_LABEL_ARGS[@]}")
	fi
	if [[ ${#_origin_label_args[@]} -gt 0 ]]; then
		_issue_cmd+=("${_origin_label_args[@]}")
		_rest_args+=("${_origin_label_args[@]}")
	fi

	# t2028/t2406/GH#27929: choose an eligible auto-assignee before creation,
	# but keep durable creation independent from the best-effort assignment.
	local issue_output rc auto_assignee="" target_repo=""
	target_repo=$(_gh_extract_repo_from_args "$@" 2>/dev/null || true)
	if ! _gh_wrapper_args_have_assignee "$@"; then
		if _gh_wrapper_args_have_label "$_GH_CREATE_AUTO_DISPATCH_LABEL" "$@"; then
			# t2157/t2406: auto-dispatch means worker-owned; skip self-assignment.
			print_info "[INFO] auto-dispatch label present — skipping self-assignment per t2157"
		else
			auto_assignee=$(_gh_wrapper_auto_assignee "$target_repo")
		fi
	fi

	issue_output=$("${_issue_cmd[@]}") # aidevops-allow: raw-gh-wrapper
	rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue create"
		issue_output=$(_rest_issue_create "${_rest_args[@]}")
		rc=$?
	fi
	echo "$issue_output"
	if [[ $rc -eq 0 ]]; then
		_gh_finish_created_issue "$issue_output" "$target_repo" "$auto_assignee" "$@"
	fi
	return $rc
}

# Resolve a tNNN task ID to its GitHub issue number via title prefix search.
# Used by both detection methods in _gh_auto_link_sub_issue. Echoes the issue
# number on stdout, empty string if not found. Non-blocking.
_gh_resolve_task_id_to_issue() {
	local tid="$1"
	local repo="$2"
	[[ -z "$tid" || -z "$repo" ]] && return 0
	gh_issue_list --repo "$repo" --state all \
		--search "${tid}: in:title" --json number,title --limit 5 2>/dev/null |
		jq -r --arg prefix "${tid}: " \
			'.[] | select(.title | startswith($prefix)) | .number // ""' 2>/dev/null |
		head -1
	return 0
}

# Parse a `Parent:` line from an issue body and resolve to an issue number.
# Accepts plain, bold-markdown (`**Parent:**`), and backtick-quoted variants.
# Supports `#NNN`, `GH#NNN`, `tNNN` ref forms. `tNNN` resolves via
# `_gh_resolve_task_id_to_issue`. Echoes the issue number on stdout, empty
# string if no parent ref found. Non-blocking.
_gh_parse_parent_from_body() {
	local body="$1"
	local repo="$2"
	[[ -z "$body" ]] && return 0
	local parent_ref
	# shellcheck disable=SC2016  # sed pattern contains literal `*` and backticks
	parent_ref=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Parent:\**[[:space:]]*`?(t[0-9]+|GH#[0-9]+|#[0-9]+)`?.*/\1/p' |
		head -1 || true)
	[[ -z "$parent_ref" ]] && return 0
	if [[ "$parent_ref" =~ ^#([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$parent_ref" =~ ^GH#([0-9]+)$ ]]; then
		echo "${BASH_REMATCH[1]}"
	elif [[ "$parent_ref" =~ ^(t[0-9]+)$ ]]; then
		_gh_resolve_task_id_to_issue "${BASH_REMATCH[1]}" "$repo"
	fi
	return 0
}

# Internal: detect the parent issue number using two ordered methods.
# Method 1: dot-notation in title (tNNN.M: → parent tNNN).
# Method 2: `Parent:` line in body — delegates to _gh_parse_parent_from_body.
# This consolidates the shared detection shape so _gh_auto_link_sub_issue does
# not mix inline Method-1 logic with a helper-delegated Method 2.
#
# Echoes the parent issue number on stdout, empty string if no parent found.
# Non-blocking — every detection / resolution step returns silently on failure.
#
# Arguments:
#   $1 - issue title
#   $2 - issue body
#   $3 - repo slug (owner/repo)
_gh_detect_parent_issue() {
	local title="$1"
	local body="$2"
	local repo="$3"
	local parent_num=""

	# Method 1: dot-notation in title
	if [[ "$title" =~ ^(t[0-9]+\.[0-9]+[a-z]?) ]]; then
		local _cid="${BASH_REMATCH[1]}"
		local _pid="${_cid%.*}"
		if [[ -n "$_pid" && "$_pid" != "$_cid" ]]; then
			parent_num=$(_gh_resolve_task_id_to_issue "$_pid" "$repo")
		fi
	fi

	# Method 2: `Parent:` line in body (only if method 1 did not resolve)
	[[ -z "$parent_num" ]] && parent_num=$(_gh_parse_parent_from_body "$body" "$repo")

	echo "$parent_num"
	return 0
}

# GH#18735 + GH#20473 (t2738): auto-link newly created issues as sub-issues of
# their parent at create-time. Two detection methods, in order of preference:
#
#   1. Dot-notation in title — `tNNN.M:` / `tNNN.M.K:` → parent is the dotted
#      prefix one level up. Original behaviour.
#
#   2. `Parent:` line in body — plain, bold-markdown, or backtick-quoted.
#      Supports `#NNN`, `GH#NNN`, `tNNN` refs. Delegates parsing to
#      `_gh_parse_parent_from_body`. Mirrors method 2 of
#      `_detect_parent_from_gh_state` so the detection shape stays consistent
#      across create-time and backfill-time paths.
#
# Non-blocking — every detection / resolution step returns silently on failure
# so issue creation is never affected.
#
# Arguments:
#   $1 - issue URL output from gh issue create
#   $2... - original args passed to gh issue create (to extract
#           --title, --repo, --body, --body-file and their `=` variants)
_gh_auto_link_sub_issue() {
	local issue_url="$1"
	shift

	# Extract --title, --repo, and --body (or --body-file) from the original args.
	# Whitelist-based parsing: only flags listed here consume the next positional
	# argument. Unknown flags (--assignee, --label, --project, …) are shifted
	# without consuming their value, so a flag value that happens to look like
	# --title or --repo is never mis-identified as one of our targets.
	# _a/_v capture $1/$2 into locals before use, satisfying the positional-param
	# style rule; shift-2 then consumes both the flag and its value atomically.
	local title=""
	local repo=""
	local body=""
	local _a _v _bf
	while [[ $# -gt 0 ]]; do
		_a="$1"
		_v="${2:-}"
		case "$_a" in
		--title)
			if [[ $# -gt 1 ]]; then title="$_v"; shift 2; else shift; fi
			;;
		--title=*)
			title="${_a#--title=}"; shift
			;;
		--repo)
			if [[ $# -gt 1 ]]; then repo="$_v"; shift 2; else shift; fi
			;;
		--repo=*)
			repo="${_a#--repo=}"; shift
			;;
		--body)
			if [[ $# -gt 1 ]]; then body="$_v"; shift 2; else shift; fi
			;;
		--body=*)
			body="${_a#--body=}"; shift
			;;
		--body-file)
			if [[ $# -gt 1 && -r "$_v" ]]; then body=$(<"$_v"); fi
			if [[ $# -gt 1 ]]; then shift 2; else shift; fi
			;;
		--body-file=*)
			_bf="${_a#--body-file=}"
			if [[ -n "$_bf" && -r "$_bf" ]]; then body=$(<"$_bf"); fi
			shift
			;;
		*)
			shift
			;;
		esac
	done
	[[ -z "$title" ]] && return 0

	# Extract the child issue number from the URL — both detection methods need it.
	local child_num
	child_num=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
	[[ -z "$child_num" ]] && return 0

	# Resolve repo slug (from --repo arg or current repo)
	[[ -z "$repo" ]] && repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
	[[ -z "$repo" ]] && return 0

	local owner="${repo%%/*}" name="${repo##*/}"

	# Detect parent using both methods (dot-notation title, then Parent: body line).
	local parent_num
	parent_num=$(_gh_detect_parent_issue "$title" "$body" "$repo")
	[[ -z "$parent_num" ]] && return 0

	# Resolve both to node IDs and link
	local parent_node child_node
	# shellcheck disable=SC2016 # GraphQL variables are expanded by gh, not Bash.
	parent_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$parent_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	# shellcheck disable=SC2016 # GraphQL variables are expanded by gh, not Bash.
	child_node=$(gh api graphql \
		-f query='query($o:String!,$n:String!,$num:Int!){repository(owner:$o,name:$n){issue(number:$num){id}}}' \
		-f o="$owner" -f n="$name" -F num="$child_num" \
		--jq '.data.repository.issue.id' 2>/dev/null || echo "")
	[[ -z "$parent_node" || -z "$child_node" ]] && return 0

	# Fire and forget — suppress all errors
	# shellcheck disable=SC2016 # GraphQL variables are expanded by gh, not Bash.
	_gh_with_timeout write gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' \
		-f p="$parent_node" -f c="$child_node" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Check if argv already contains a specific flag.
# Args: $1=flag name, remaining args=argv
# Returns: 0=present, 1=absent
#######################################
_gh_wrapper_args_have_flag() {
	local needle="$1"
	shift
	while [[ $# -gt 0 ]]; do
		local cur="$1"
		case "$cur" in
		"$needle" | "$needle"=*) return 0 ;;
		esac
		shift
	done
	return 1
}

#######################################
# Decide whether gh_create_pr should default the PR to draft.
# Args: PR create argv
# Returns: 0=add --draft, 1=leave as caller requested
#######################################
_gh_create_pr_should_default_draft() {
	local origin=""
	origin=$(detect_session_origin 2>/dev/null) || origin=""
	if [[ "$origin" != "interactive" ]]; then
		return 1
	fi
	if [[ "${AIDEVOPS_PR_CREATE_READY:-0}" == "1" ]]; then
		return 1
	fi
	if _gh_wrapper_args_have_flag "--draft" "$@"; then
		return 1
	fi
	return 0
}

gh_create_pr() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_create_pr 2>/dev/null || true
	if ! _gh_wrapper_normalize_stdin_body_file "$@"; then
		_gh_edit_audit_rejection "gh pr create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi
	set -- "${_GH_WRAPPER_BODY_FILE_ARGS[@]}"
	# GH#19857: validate title/body before creating (same invariant as edit wrappers)
	if ! _gh_validate_edit_args "$@"; then
		_gh_edit_audit_rejection "gh pr create" "$_GH_EDIT_REJECTION_REASON" "$@"
		return 1
	fi

	# t3088: defence-in-depth — only auto-inject the session origin label when
	# the caller has NOT already specified one. Prevents the dual-origin-label
	# bug (t2200 violation) where a caller's --label "origin:X" plus the
	# wrapper's --label "$session_origin_label" produces two distinct origin
	# labels on the resulting PR. Canonical failure: PR #21825.
	local -a _origin_label_args=()
	if ! _gh_wrapper_args_have_origin_label "$@"; then
		local origin_label
		origin_label=$(session_origin_label)
		_origin_label_args=(--label "$origin_label")
	fi
	local -a _draft_args=()
	if _gh_create_pr_should_default_draft "$@"; then
		_draft_args=(--draft)
	fi
	_ensure_origin_labels_for_args "$@"

	# t2115: auto-append signature footer when body lacks one
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	if ! _gh_guard_public_write_args "$@"; then
		return 1
	fi

	local -a pr_cmd=(gh pr create "$@")
	if [[ ${#_draft_args[@]} -gt 0 ]]; then
		pr_cmd+=("${_draft_args[@]}")
	fi
	if [[ ${#_origin_label_args[@]} -gt 0 ]]; then
		pr_cmd+=("${_origin_label_args[@]}")
	fi

	local pr_output rc
	pr_output=$("${pr_cmd[@]}") # aidevops-allow: raw-gh-wrapper
	rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr create"
		if [[ ${#_origin_label_args[@]} -gt 0 || ${#_draft_args[@]} -gt 0 ]]; then
			pr_output=$(_rest_pr_create "$@" "${_draft_args[@]}" "${_origin_label_args[@]}")
		else
			pr_output=$(_rest_pr_create "$@")
		fi
		rc=$?
	fi
	printf '%s\n' "$pr_output"
	return $rc
}

# t2767: Partial-success recovery for gh pr create.
# When gh pr create returns non-zero, GitHub may have successfully created the
# PR but a follow-up update call (label application, body normalisation, etc.)
# failed with a transient GraphQL error. This helper checks whether a PR already
# exists for the given branch in the repo, returning its URL if found.
#
# Usage: recovered_url=$(_gh_recover_pr_if_exists "$branch" "$repo")
# Returns: PR URL (HTTPS) or empty string. Always exits 0 (fail-open).
#
# Callers must treat a non-empty return value as the PR URL to continue with
# and log a recovery warning so operators know a transient error occurred.
_gh_recover_pr_if_exists() {
	local branch="$1" repo="${2:-}"
	[[ -z "$branch" ]] && return 0
	local url_candidate=""
	url_candidate=$(gh_pr_list --head "$branch" ${repo:+--repo "$repo"} --state open \
		--json number,url --jq '.[0].url // empty' 2>/dev/null || true)
	printf '%s\n' "${url_candidate:-}"
	return 0
}

# t2393: auto-append signature footer on all `gh issue comment` posts.
# Thin wrapper mirroring gh_create_issue/gh_create_pr — invokes
# _gh_wrapper_auto_sig on --body/--body-file before delegating to the
# underlying gh command. No origin-label or assignee logic (creation-only
# concerns); comments just need the runtime/version/model/token sig so
# operators and pulse readers can diagnose which session posted them.
# Dedup: _gh_wrapper_auto_sig skips bodies already containing the
# <!-- aidevops:sig --> marker, so callers that build their own footer
# are not double-signed.
gh_issue_comment() {
	_gh_wrapper_enter_cleanup_scope
	local ephemeral_body_file="${AIDEVOPS_GH_EPHEMERAL_BODY_FILE:-}"
	local gh_command="gh"
	if [[ -n "$ephemeral_body_file" ]]; then
		# Ephemeral comments must already carry the canonical footer. Otherwise
		# _gh_wrapper_auto_sig would create another pathname-backed temp copy.
		if [[ "$ephemeral_body_file" != /* || ! -f "$ephemeral_body_file" || \
			-L "$ephemeral_body_file" ]] || \
			! grep -Fqx '<!-- aidevops:sig -->' "$ephemeral_body_file" 2>/dev/null; then
			printf '[aidevops][gh-wrapper][BLOCK] Invalid pre-signed ephemeral comment body.\n' >&2
			return 1
		fi
		local wrapper_script_dir=""
		wrapper_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
		gh_command="${wrapper_script_dir}/gh"
		if [[ ! -x "$gh_command" ]]; then
			printf '[aidevops][gh-wrapper][BLOCK] Ephemeral comment transport requires the aidevops gh shim.\n' >&2
			return 1
		fi
	fi
	gh_record_call graphql gh_issue_comment 2>/dev/null || true
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	if ! _gh_guard_public_write_args "$@"; then
		return 1
	fi
	_gh_with_timeout write "$gh_command" issue comment "$@"
	local rc=$?
	if [[ $rc -ne 0 && -z "$ephemeral_body_file" ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for issue comment"
		_rest_issue_comment "$@"
		rc=$?
	fi
	return $rc
}

gh_pr_comment() {
	_gh_wrapper_enter_cleanup_scope
	gh_record_call graphql gh_pr_comment 2>/dev/null || true
	_gh_wrapper_auto_sig "$@"
	set -- "${_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}"
	if ! _gh_guard_public_write_args "$@"; then
		return 1
	fi
	_gh_with_timeout write gh pr comment "$@"
	local rc=$?
	if [[ $rc -ne 0 ]] && _rest_should_fallback; then
		print_info "[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr comment"
		_rest_pr_comment "$@"
		rc=$?
	fi
	return $rc
}

# Internal: extract --repo from args and ensure labels exist (cached per repo).
_ORIGIN_LABELS_ENSURED=""
_ensure_origin_labels_for_args() {
	local repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="${2:-}"
			break
			;;
		--repo=*)
			repo="${1#--repo=}"
			break
			;;
		*) shift ;;
		esac
	done
	[[ -z "$repo" ]] && return 0
	# Skip if already ensured for this repo in this process
	case ",$_ORIGIN_LABELS_ENSURED," in
	*",$repo,"*) return 0 ;;
	esac
	if ensure_origin_labels_exist "$repo"; then
		_ORIGIN_LABELS_ENSURED="${_ORIGIN_LABELS_ENSURED:+$_ORIGIN_LABELS_ENSURED,}$repo"
	fi
	return 0
}

# Ensure origin labels exist on a repo (idempotent).
# Usage: ensure_origin_labels_exist "owner/repo"
ensure_origin_labels_exist() {
	local repo="$1"
	[[ -z "$repo" ]] && return 1
	managed_labels_ensure_origin_set "$repo" \
		_gh_managed_label_names_snapshot _gh_managed_label_create_runner
	return $?
}

_gh_managed_label_create_runner() {
	local repo="$1"
	local label_name="$2"
	local label_description="$3"
	local label_color="$4"
	AIDEVOPS_GH_ROUTE_DECISION="$_GH_MANAGED_LABEL_CREATE_ROUTE" \
		_gh_with_timeout write gh label create "$label_name" --repo "$repo" \
		--description "$label_description" --color "$label_color" 2>/dev/null
	return $?
}
