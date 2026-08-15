#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Live interactive ownership fence shared by stale recovery, dispatch, and merge.

[[ -n "${_INTERACTIVE_CLAIM_FENCE_LOADED:-}" ]] && return 0
_INTERACTIVE_CLAIM_FENCE_LOADED=1

_ICF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_ICF_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _ICF_SCRIPT_DIR="."
if ! declare -F _is_process_alive_and_matches >/dev/null 2>&1; then
	# shellcheck source=shared-constants.sh
	source "${_ICF_SCRIPT_DIR}/shared-constants.sh"
fi
if ! declare -F check_worktree_owner >/dev/null 2>&1; then
	# shellcheck source=shared-worktree-registry.sh
	source "${_ICF_SCRIPT_DIR}/shared-worktree-registry.sh"
fi

_icf_stamp_path() {
	local issue="$1"
	local repo_slug="$2"
	local stamp_dir="${CLAIM_STAMP_DIR:-${HOME}/.aidevops/.agent-workspace/interactive-claims}"
	printf '%s/%s-%s.json' "$stamp_dir" "${repo_slug//\//-}" "$issue"
	return 0
}

_icf_worktree_repo_slug() {
	local worktree_path="$1"
	local remote_url=""
	remote_url=$(git -C "$worktree_path" remote get-url origin 2>/dev/null) || return 1
	remote_url=${remote_url%.git}
	remote_url=${remote_url#*github.com:}
	remote_url=${remote_url#*github.com/}
	[[ "$remote_url" =~ ^[^/]+/[^/]+$ ]] || return 1
	printf '%s' "$remote_url"
	return 0
}

_icf_stamp_owner_is_live() {
	local stamp_file="$1"
	local stamp_host=""
	local local_host=""
	local owner_pid=""
	local owner_hash=""
	stamp_host=$(jq -r '.hostname // empty' "$stamp_file" 2>/dev/null) || return 2
	local_host=$(hostname 2>/dev/null || printf '%s' "unknown")
	# Another host owns its liveness decision. Its matching durable stamp and
	# worktree remain authoritative until that host explicitly releases them.
	[[ -n "$stamp_host" && "$stamp_host" != "$local_host" ]] && return 0
	owner_pid=$(jq -r '.pid // empty' "$stamp_file" 2>/dev/null) || return 2
	owner_hash=$(jq -r '.owner_argv_hash // empty' "$stamp_file" 2>/dev/null) || return 2
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 2
	if _is_process_alive_and_matches "$owner_pid" "${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}" "$owner_hash"; then
		return 0
	fi
	return 1
}

# Exit 0: verified live owner. Exit 1: absent or proven dead. Exit 2: matching
# ownership evidence exists but cannot be disproved safely.
_interactive_claim_fence_status() {
	local issue="$1"
	local repo_slug="$2"
	local stamp_file=""
	local worktree_path=""
	local worktree_slug=""
	local stamp_pid=""
	local owner_info=""
	local registry_pid=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$repo_slug" =~ ^[^/]+/[^/]+$ ]] || return 2
	stamp_file=$(_icf_stamp_path "$issue" "$repo_slug")
	[[ -f "$stamp_file" ]] || return 1
	jq -e --arg slug "$repo_slug" --argjson issue "$issue" \
		'.slug == $slug and .issue == $issue' "$stamp_file" >/dev/null 2>&1 || return 2
	worktree_path=$(jq -r '.worktree_path // empty' "$stamp_file" 2>/dev/null) || return 2
	[[ -n "$worktree_path" && -d "$worktree_path" ]] || return 2
	worktree_slug=$(_icf_worktree_repo_slug "$worktree_path") || return 2
	[[ "$worktree_slug" == "$repo_slug" ]] || return 2
	stamp_pid=$(jq -r '.pid // empty' "$stamp_file" 2>/dev/null) || return 2
	owner_info=$(check_worktree_owner "$worktree_path" 2>/dev/null) || return 2
	registry_pid=${owner_info%%|*}
	[[ "$registry_pid" =~ ^[1-9][0-9]*$ && "$registry_pid" == "$stamp_pid" ]] || return 2
	_icf_stamp_owner_is_live "$stamp_file"
	return $?
}

_interactive_claim_fence_blocks_dispatch() {
	local issue="$1"
	local repo_slug="$2"
	local fence_rc=0
	_interactive_claim_fence_status "$issue" "$repo_slug" || fence_rc=$?
	[[ "$fence_rc" -eq 0 || "$fence_rc" -eq 2 ]]
}

_icf_worktree_has_unmerged_work() {
	local worktree_path="$1"
	local default_branch=""
	local ahead_count=""
	[[ -z "$(git -C "$worktree_path" status --porcelain 2>/dev/null)" ]] || return 0
	default_branch=$(git -C "$worktree_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || return 2
	default_branch=${default_branch#refs/remotes/origin/}
	[[ -n "$default_branch" ]] || return 2
	ahead_count=$(git -C "$worktree_path" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null) || return 2
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || return 2
	[[ "$ahead_count" -gt 0 ]] && return 0
	return 1
}

# Block only a duplicate PR. The PR whose exact head is owned by the live
# interactive worktree remains eligible for its session's normal merge path.
_interactive_claim_fence_blocks_merge() {
	local issue="$1"
	local repo_slug="$2"
	local candidate_head="$3"
	local fence_rc=0
	local stamp_file=""
	local worktree_path=""
	local worktree_head=""
	_interactive_claim_fence_status "$issue" "$repo_slug" || fence_rc=$?
	[[ "$fence_rc" -eq 1 ]] && return 1
	[[ "$fence_rc" -eq 2 ]] && return 0
	stamp_file=$(_icf_stamp_path "$issue" "$repo_slug")
	worktree_path=$(jq -r '.worktree_path // empty' "$stamp_file" 2>/dev/null) || return 0
	worktree_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || return 0
	[[ -n "$candidate_head" && "$candidate_head" == "$worktree_head" ]] && return 1
	_icf_worktree_has_unmerged_work "$worktree_path" || fence_rc=$?
	[[ "$fence_rc" -eq 0 || "$fence_rc" -eq 2 ]]
}
