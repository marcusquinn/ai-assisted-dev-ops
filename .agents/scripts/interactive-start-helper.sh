#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# interactive-start-helper.sh — safe interactive issue implementation entrypoint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_usage() {
	cat <<'EOF'
Usage: interactive-start-helper.sh --issue N --repo owner/repo --task "description" [--auto-dispatch] [--background]

Claims the issue for interactive implementation, runs the pre-edit loop check,
validates and enters the linked worktree selected by pre-edit, refreshes the
claim with that worktree, and starts full-loop there. Foreground is the default;
--background requires explicit user background intent.
EOF
	return 0
}

_interactive_start_output_value() {
	local output="$1"
	local key="$2"
	local value=""
	local matches=0
	local line=""
	while IFS= read -r line; do
		line="${line%$'\r'}"
		case "$line" in
		"${key}="*)
			value="${line#*=}"
			matches=$((matches + 1))
			;;
		esac
	done <<<"$output"
	if [[ "$matches" -gt 1 ]]; then
		printf 'ERROR: pre-edit returned multiple %s values\n' "$key" >&2
		return 1
	fi
	printf '%s' "$value"
	return 0
}

_interactive_start_validate_linked_worktree() {
	local candidate="$1"
	if [[ -z "$candidate" || "$candidate" != /* || ! -d "$candidate" ]]; then
		printf 'ERROR: pre-edit returned an invalid worktree path: %s\n' "${candidate:-<empty>}" >&2
		return 1
	fi

	local resolved_path=""
	resolved_path=$(cd "$candidate" 2>/dev/null && pwd -P) || return 1
	local repo_root=""
	repo_root=$(git -C "$resolved_path" rev-parse --show-toplevel 2>/dev/null) || {
		printf 'ERROR: pre-edit worktree path is not a Git worktree: %s\n' "$resolved_path" >&2
		return 1
	}
	repo_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 1
	if [[ "$repo_root" != "$resolved_path" ]]; then
		printf 'ERROR: pre-edit worktree path is not the registered worktree root: %s\n' "$resolved_path" >&2
		return 1
	fi

	local policy_helper="${SCRIPT_DIR}/canonical-write-policy-helper.py"
	local classification=""
	if [[ ! -f "$policy_helper" ]] ||
		! classification=$(python3 "$policy_helper" classify --cwd "$resolved_path" --field classification 2>/dev/null) ||
		[[ "$classification" != "linked" ]]; then
		printf 'ERROR: pre-edit path is not a safe linked worktree: %s\n' "$resolved_path" >&2
		return 1
	fi

	local registered=0
	local worktree_line=""
	while IFS= read -r worktree_line; do
		if [[ "$worktree_line" == "worktree ${resolved_path}" ]]; then
			registered=1
			break
		fi
	done < <(git -C "$resolved_path" worktree list --porcelain 2>/dev/null)
	if [[ "$registered" -ne 1 ]]; then
		printf 'ERROR: pre-edit path is not registered in Git worktree metadata: %s\n' "$resolved_path" >&2
		return 1
	fi

	printf '%s' "$resolved_path"
	return 0
}

_interactive_start_resolve_worktree() {
	local pre_edit_output="$1"
	local decision=""
	local worktree_path=""
	decision=$(_interactive_start_output_value "$pre_edit_output" "LOOP_DECISION") || return 1
	worktree_path=$(_interactive_start_output_value "$pre_edit_output" "WORKTREE_PATH") || return 1

	if [[ "$decision" == "worktree_created" && -z "$worktree_path" ]]; then
		printf 'ERROR: pre-edit reported worktree creation without WORKTREE_PATH\n' >&2
		return 1
	fi
	if [[ -n "$decision" && "$decision" != "worktree_created" ]]; then
		printf 'ERROR: pre-edit returned non-continuable decision: %s\n' "$decision" >&2
		return 1
	fi
	if [[ -z "$worktree_path" ]]; then
		worktree_path=$(git rev-parse --show-toplevel 2>/dev/null) || {
			printf 'ERROR: unable to resolve current linked worktree after pre-edit\n' >&2
			return 1
		}
	fi

	_interactive_start_validate_linked_worktree "$worktree_path"
	return $?
}

_interactive_start_parse_args() {
	_INTERACTIVE_START_ISSUE=""
	_INTERACTIVE_START_REPO=""
	_INTERACTIVE_START_TASK=""
	_INTERACTIVE_START_AUTO_DISPATCH=0
	_INTERACTIVE_START_BACKGROUND=0
	_INTERACTIVE_START_HELP_REQUESTED=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
		--issue)
			[[ $# -gt 0 ]] || {
				printf 'ERROR: --issue requires a value\n' >&2
				return 2
			}
			local issue_value="$1"
			_INTERACTIVE_START_ISSUE="$issue_value"
			shift
			;;
		--repo)
			[[ $# -gt 0 ]] || {
				printf 'ERROR: --repo requires a value\n' >&2
				return 2
			}
			local repo_value="$1"
			_INTERACTIVE_START_REPO="$repo_value"
			shift
			;;
		--task)
			[[ $# -gt 0 ]] || {
				printf 'ERROR: --task requires a value\n' >&2
				return 2
			}
			local task_value="$1"
			_INTERACTIVE_START_TASK="$task_value"
			shift
			;;
		--auto-dispatch) _INTERACTIVE_START_AUTO_DISPATCH=1 ;;
		--background | --bg) _INTERACTIVE_START_BACKGROUND=1 ;;
		--help | -h)
			_INTERACTIVE_START_HELP_REQUESTED=1
			_usage
			return 0
			;;
		*)
			printf 'ERROR: unknown option: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done
	if [[ -z "$_INTERACTIVE_START_ISSUE" || -z "$_INTERACTIVE_START_REPO" || -z "$_INTERACTIVE_START_TASK" ]]; then
		_usage >&2
		return 2
	fi
	return 0
}

main() {
	_interactive_start_parse_args "$@" || return $?
	if [[ "$_INTERACTIVE_START_HELP_REQUESTED" -eq 1 ]]; then
		return 0
	fi
	local issue="$_INTERACTIVE_START_ISSUE"
	local repo="$_INTERACTIVE_START_REPO"
	local task="$_INTERACTIVE_START_TASK"
	local auto_dispatch="$_INTERACTIVE_START_AUTO_DISPATCH"
	local background="$_INTERACTIVE_START_BACKGROUND"
	# Reaching this entrypoint means the issue is being implemented locally.
	# Export the marker so asynchronous local children inherit that authority.
	export AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION=1
	# Retain --auto-dispatch for CLI compatibility; takeover is now unconditional.
	: "$auto_dispatch"
	local initial_claim_args=(claim "$issue" "$repo" --implementing --defer-comment)
	if ! interactive-session-helper.sh "${initial_claim_args[@]}"; then
		printf 'ERROR: initial interactive claim failed for #%s in %s\n' "$issue" "$repo" >&2
		return 1
	fi

	local pre_edit_output=""
	local pre_edit_rc=0
	pre_edit_output=$(pre-edit-check.sh --loop-mode --task "$task" 2>&1) || pre_edit_rc=$?
	[[ -z "$pre_edit_output" ]] || printf '%s\n' "$pre_edit_output"
	if [[ "$pre_edit_rc" -ne 0 ]]; then
		return "$pre_edit_rc"
	fi

	local worktree_path=""
	worktree_path=$(_interactive_start_resolve_worktree "$pre_edit_output") || return 1
	local refresh_claim_args=(claim "$issue" "$repo" --implementing --worktree "$worktree_path")
	if ! interactive-session-helper.sh "${refresh_claim_args[@]}"; then
		printf 'ERROR: interactive claim refresh failed; recoverable worktree: %s\n' "$worktree_path" >&2
		return 1
	fi

	local start_args=(start "GH#${issue} ${task}")
	if [[ $background -eq 1 ]]; then
		start_args+=(--background)
	fi
	local full_loop_rc=0
	(
		cd "$worktree_path" || exit 1
		full-loop-helper.sh "${start_args[@]}"
	) || full_loop_rc=$?
	if [[ "$full_loop_rc" -ne 0 ]]; then
		printf 'ERROR: full-loop start failed; recoverable worktree: %s\n' "$worktree_path" >&2
	fi
	return "$full_loop_rc"
}

main "$@"
