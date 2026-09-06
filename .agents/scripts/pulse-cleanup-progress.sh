#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by pulse-cleanup-worktree-removal.sh for watchdog-bounded invocations.
# Cursor data controls ordering only; every job invokes existing removal guards.

# shellcheck source=./canonical-guard-helper.sh
source "${BASH_SOURCE[0]%/*}/canonical-guard-helper.sh" || return 1

_pc_progress_repo_jobs() {
	local repo="$1" slug="" main_branch="" inventory=""
	git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0
	# Match the legacy cleanup's live-remote identity, not a possibly stale slug
	# in repos.json. The candidate's existing guards still validate removability.
	slug=$(git -C "$repo" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || slug=""
	main_branch=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || main_branch=origin/main
	main_branch="${main_branch#origin/}"
	inventory=$(git -C "$repo" worktree list --porcelain -z | jq -Rsc '
		split("\u0000\u0000") | map(split("\u0000") | {
		path: (map(select(startswith("worktree ")) | ltrimstr("worktree "))[0] // ""),
		branch: (map(select(startswith("branch refs/heads/")) | ltrimstr("branch refs/heads/"))[0] // "")
		}) | map(select(.path != "" and (.path | test("[\\r\\n]") | not)))') || return 1
	jq -cn --arg repo "$repo" '["merged",$repo]'
	# Git lists the main worktree first. Exclude it even when repos.json uses
	# an alias or a linked path rather than the canonical inventory spelling.
	jq -c --arg repo "$repo" --arg slug "$slug" --arg main "$main_branch" '
		.[1:][] | select(.path != $repo) | ["orphan",$repo,$slug,.path,.branch,$main]' <<<"$inventory"
	return $?
}

_pc_progress_jobs() {
	local repos_json="$1" record="" repo=""
	while IFS= read -r record; do
		repo=$(jq -r '.path // empty' <<<"$record") || return 1
		[[ -n "$repo" ]] || continue
		_pc_progress_repo_jobs "$repo" || return 1
	done < <(jq -c '.initialized_repos[] | select((.local_only // false) == false) | select((.path // "" | test("[\\r\\n]")) | not)' "$repos_json")
	printf '["relocate"]\n["outliers"]\n'
	return 0
}

_pc_progress_checkpoint() {
	local cursor="$1" next_job="$2" temporary=""
	temporary=$(mktemp "${cursor}.XXXXXX") || return 1
	if ! printf '%s\n' "$next_job" >"$temporary" || ! mv -f "$temporary" "$cursor"; then
		rm -f "$temporary"
		return 1
	fi
	return 0
}

_pc_progress_run_job() {
	local job="$1" repos_json="$2" kind="" repo="" count=0
	kind=$(jq -r '.[0]' <<<"$job") || return 1
	case "$kind" in
	merged)
		repo=$(jq -r '.[1]' <<<"$job") || return 1
		local helper="${_PULSE_CLEANUP_SCRIPT_DIR}/worktree-helper.sh"
		[[ -x "$helper" ]] || return 0
		count=$(_pc_cleanup_merged_repo "$helper" "$repo") || count=0
		;;
	orphan)
		local slug="" path="" branch="" main_branch=""
		repo=$(jq -r '.[1]' <<<"$job") || return 1
		slug=$(jq -r '.[2]' <<<"$job") || return 1
		path=$(jq -r '.[3]' <<<"$job") || return 1
		branch=$(jq -r '.[4]' <<<"$job") || return 1
		main_branch=$(jq -r '.[5]' <<<"$job") || return 1
		[[ -d "$path" && "$path" != "$repo" ]] || return 0
		if _cleanup_single_worktree "$repo" "$path" "$branch" "$(date +%s)" "$slug" "$main_branch"; then count=1; fi
		;;
	relocate) _pc_relocate_registered_worktrees "$repos_json" >/dev/null || true ;;
	outliers) count=$(_pc_cleanup_orphan_sibling_dirs "$repos_json" "$(date +%s)") || count=0 ;;
	*) return 1 ;;
	esac
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	CLEANUP_WORKTREES_REMOVED_COUNT=$((CLEANUP_WORKTREES_REMOVED_COUNT + count))
	return 0
}

_pc_progress_locked() (
	local budget="$1"
	local log_dir="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}"
	local LOCK_DIR="${log_dir}/cleanup_worktrees.lock"
	local PID_FILE="${LOCK_DIR}/pid"
	# Scoped process traps must not replace the caller's exit/signal handlers.
	# shellcheck source=./cleanup-worktrees-lock.sh
	source "${BASH_SOURCE[0]%/*}/cleanup-worktrees-lock.sh" || exit 1
	mkdir -p "$log_dir" || exit 1
	if ! _lock_acquire; then
		printf '0 0 0 1\n'
		exit 0
	fi
	_pc_cleanup_resumable_unlocked "$budget" >>"${LOGFILE:-/dev/null}" || exit $?
	printf '%s %s %s %s\n' "$CLEANUP_WORKTREES_REMOVED_COUNT" "$CLEANUP_WORKTREES_ARCHIVED_COUNT" \
		"$CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT" "$CLEANUP_WORKTREES_SKIPPED"
)

_pc_cleanup_resumable() {
	local result=""
	assert_git_available || return 1
	result=$(_pc_progress_locked "$1") || return $?
	read -r CLEANUP_WORKTREES_REMOVED_COUNT CLEANUP_WORKTREES_ARCHIVED_COUNT \
		CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT CLEANUP_WORKTREES_SKIPPED <<<"$result"
	return $?
}

_pc_cleanup_resumable_unlocked() {
	local budget="$1" deadline=0 cursor="" saved="" manifest="" job=""
	local repos_json="${HOME}/.config/aidevops/repos.json"
	local state_dir="${PULSE_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pulse}"
	local jobs=() start=0 index=0 offset=0 next=0 api_checked=0 remaining=""
	CLEANUP_WORKTREES_SKIPPED=0
	CLEANUP_WORKTREES_REMOVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVED_COUNT=0
	CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT=0
	assert_git_available || return 1
	[[ "$budget" =~ ^[0-9]+$ && "$budget" -ge 1 ]] || return 1
	deadline=$(($(date +%s) + budget))
	command -v jq >/dev/null 2>&1 || return 1
	[[ -f "$repos_json" ]] || { cleanup_worktrees; return $?; }
	jq -e '.initialized_repos | type == "array"' "$repos_json" >/dev/null || return 1
	# Preserve the existing API-free fixture pass before any quota gate, even
	# when this invocation resumes halfway through the repository queue.
	CLEANUP_WORKTREES_REMOVED_COUNT=$(_pc_cleanup_fixture_passes) || CLEANUP_WORKTREES_REMOVED_COUNT=0
	[[ "$CLEANUP_WORKTREES_REMOVED_COUNT" =~ ^[0-9]+$ ]] || CLEANUP_WORKTREES_REMOVED_COUNT=0
	mkdir -p "$state_dir" || return 1
	cursor="${state_dir}/worktree-cleanup-next.json"
	[[ ! -f "$cursor" ]] || saved=$(<"$cursor")
	manifest=$(_pc_progress_jobs "$repos_json") || return 1
	while IFS= read -r job; do
		[[ "$job" != "$saved" ]] || start="${#jobs[@]}"
		jobs+=("$job")
	done <<<"$manifest"
	_pc_log_local_only_worktree_skips "$repos_json"
	for ((offset = 0; offset < ${#jobs[@]}; offset++)); do
		[[ "$(date +%s)" -lt "$deadline" ]] || break
		index=$(((start + offset) % ${#jobs[@]}))
		next=$(((index + 1) % ${#jobs[@]}))
		# Write ahead: watchdog termination retries this job after a fair rotation,
		# never indefinitely before the same later repository or orphan candidate.
		_pc_progress_checkpoint "$cursor" "${jobs[$next]}" || return 1
		if [[ "$api_checked" -eq 0 ]]; then
			api_checked=1
			remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null) || remaining=""
			if [[ "$remaining" =~ ^[0-9]+$ && "$remaining" -lt 100 ]]; then
				CLEANUP_WORKTREES_SKIPPED=1
				break
			fi
		fi
		_pc_progress_run_job "${jobs[$index]}" "$repos_json" || return 1
	done
	echo "[pulse-cleanup] resumable progress: attempted=${offset}, removed=${CLEANUP_WORKTREES_REMOVED_COUNT}, budget=${budget}s" >>"${LOGFILE:-/dev/null}"
	return 0
}
