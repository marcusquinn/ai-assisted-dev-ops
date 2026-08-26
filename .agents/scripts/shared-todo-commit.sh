#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared TODO.md Serialized Commit+Push (extracted from shared-constants.sh)
# =============================================================================
# Atomic-locked, pull-rebase-retry commit+push for TODO.md and adjacent
# planning files (todo/). Extracted from shared-constants.sh (t2441, GH#20094)
# to keep that file below the file-size-debt ratchet (1500 lines). Mirrors the
# Phase 1 (shared-feature-toggles.sh, t2427/PR #20063) and Phase 2
# (shared-model-tier.sh, t2440/PR #20092) split precedents.
#
# Prevents race conditions when multiple actors (supervisor, interactive
# sessions) push to TODO.md on main simultaneously. Workers (headless dispatch
# runners) must NOT call this function or edit TODO.md directly — they report
# status via exit code/log/mailbox; the supervisor handles all TODO.md updates.
#
# Public API (backward-compatible — single non-test caller is
# planning-commit-helper.sh, which sources shared-constants.sh and gets this
# function transitively):
#   - todo_commit_push <repo_path> <commit_message> [files]
#                                     — acquires lock, calls inner with
#                                       pull-rebase-retry, releases lock on
#                                       EXIT. `files` defaults to
#                                       "TODO.md todo/". Returns 0 on success
#                                       or 1 on failure after retries.
#
# Internal helpers:
#   - _todo_acquire_lock <log_target>  — portable atomic lock via mkdir,
#                                        with stale-lock detection (PID +
#                                        age safety net). Returns 0 on
#                                        acquired, 1 on timeout.
#   - _todo_release_lock              — removes the lock dir.
#   - _todo_commit_push_inner         — pull-rebase-retry loop bounded by
#                                        TODO_MAX_RETRIES.
#
# Tunable constants (readonly):
#   - TODO_LOCK_DIR              — ${HOME}/.aidevops/locks, or a user-scoped
#                                  /tmp fallback when HOME is unset
#   - TODO_LOCK_PATH             — ${TODO_LOCK_DIR}/todo-md.lock
#   - TODO_MAX_RETRIES           — 3
#   - TODO_LOCK_TIMEOUT          — 30 (seconds to wait for lock acquisition)
#   - TODO_STALE_LOCK_AGE        — 120 (seconds before age-based reclaim)
#   - AIDEVOPS_PLANNING_FORCE_PR_FALLBACK=1
#                                 — force the protected-default planning PR
#                                   path (test/operator override).
#   - AIDEVOPS_PLANNING_PR_REPO_SLUG=owner/repo
#                                 — override GitHub slug detection for PRs.
#
# Usage: source "${SCRIPT_DIR}/shared-todo-commit.sh"
#        # Sourced from shared-constants.sh — rarely sourced directly.
#
# Dependencies:
#   - git (must be on PATH).
#   - bash 4+ (uses `${var:-default}` and trap EXIT).
#   - portable-stat.sh (cross-platform stat via shared-constants.sh).
#   - $AIDEVOPS_LOG_FILE (optional — log target for lock + retry diagnostics;
#     defaults to /dev/null).
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh
# first — this library does not call any print_* helpers directly.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_TODO_COMMIT_LOADED:-}" ]] && return 0
_SHARED_TODO_COMMIT_LOADED=1

# =============================================================================
# TODO.md Serialized Commit+Push
# =============================================================================
# Provides atomic locking and pull-rebase-retry for TODO.md operations.
# Prevents race conditions when multiple actors (supervisor, interactive sessions)
# push to TODO.md on main simultaneously.
#
# Workers (headless dispatch runners) must NOT call this function or edit TODO.md
# directly. They report status via exit code/log/mailbox; the supervisor handles
# all TODO.md updates.
#
# Usage:
#   todo_commit_push "repo_path" "commit message"
#   todo_commit_push "repo_path" "commit message" "TODO.md todo/"  # custom paths
#
# Returns 0 on success, 1 on failure after retries.

# Guard against re-declaration when shared-constants.sh is sourced more than once
# in a process (the readonly statement would otherwise abort the second source).
if [[ -z "${TODO_LOCK_DIR:-}" ]]; then
	readonly TODO_LOCK_DIR="${HOME:-/tmp/aidevops-${USER:-uid-${UID:-shared}}}/.aidevops/locks"
	readonly TODO_LOCK_PATH="${TODO_LOCK_DIR}/todo-md.lock"
	readonly TODO_MAX_RETRIES=3
	readonly TODO_LOCK_TIMEOUT=30
	readonly TODO_STALE_LOCK_AGE=120
	readonly TODO_COMMIT_RESULT_NOOP="noop"
	readonly TODO_COMMIT_RESULT_DIRECT="direct"
	readonly TODO_COMMIT_RESULT_PR="pr"
fi
if [[ -z "${TODO_COMMIT_RESULT_NOOP:-}" ]]; then
	readonly TODO_COMMIT_RESULT_NOOP="noop"
	readonly TODO_COMMIT_RESULT_DIRECT="direct"
	readonly TODO_COMMIT_RESULT_PR="pr"
fi

# good stuff — portable atomic lock using mkdir (works on macOS + Linux).
# mkdir is atomic on all POSIX systems -- only one process succeeds.
_todo_acquire_lock() {
	local log_target="${1:-/dev/null}"
	local waited=0

	while [[ $waited -lt $TODO_LOCK_TIMEOUT ]]; do
		if mkdir "$TODO_LOCK_PATH" 2>/dev/null; then
			echo $$ >"$TODO_LOCK_PATH/pid"
			return 0
		fi

		# Check for stale lock (owner process died)
		if [[ -f "$TODO_LOCK_PATH/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$TODO_LOCK_PATH/pid" 2>/dev/null || echo "")
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if [[ -n "$lock_pid" ]] && ! _is_process_alive_and_matches "$lock_pid" "${FRAMEWORK_PROCESS_PATTERN:-}"; then
				echo "[todo_lock] Removing stale lock (PID $lock_pid dead or reused, t2421)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$TODO_LOCK_PATH" ]]; then
			local lock_age
			lock_age=$(($(date +%s) - $(_file_mtime_epoch "$TODO_LOCK_PATH")))
			if [[ $lock_age -gt $TODO_STALE_LOCK_AGE ]]; then
				echo "[todo_lock] Removing stale lock (age ${lock_age}s > ${TODO_STALE_LOCK_AGE}s)" >>"$log_target"
				rm -rf "$TODO_LOCK_PATH"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	echo "[todo_lock] Failed to acquire lock after ${TODO_LOCK_TIMEOUT}s" >>"$log_target"
	return 1
}

_todo_release_lock() {
	rm -rf "$TODO_LOCK_PATH"
	return 0
}

_todo_current_branch() {
	local repo_path="$1"
	local current_branch=""
	current_branch=$(git -C "$repo_path" branch --show-current 2>/dev/null) || current_branch=""
	printf '%s\n' "$current_branch"
	return 0
}

_todo_default_branch() {
	local repo_path="$1"
	local default_branch=""
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||') || default_branch=""
	if [[ -z "$default_branch" ]]; then
		default_branch=$(git -C "$repo_path" remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1) || default_branch=""
	fi
	if [[ -z "$default_branch" ]]; then
		if git -C "$repo_path" rev-parse --verify --quiet main >/dev/null 2>&1; then
			default_branch="main"
		elif git -C "$repo_path" rev-parse --verify --quiet master >/dev/null 2>&1; then
			default_branch="master"
		else
			default_branch=$(_todo_current_branch "$repo_path")
		fi
	fi
	printf '%s\n' "$default_branch"
	return 0
}

_todo_origin_slug() {
	local repo_path="$1"
	local override_slug="${AIDEVOPS_PLANNING_PR_REPO_SLUG:-}"
	if [[ -n "$override_slug" ]]; then
		printf '%s\n' "$override_slug"
		return 0
	fi

	local remote_url=""
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || remote_url=""
	[[ -n "$remote_url" ]] || return 1

	local slug="$remote_url"
	case "$remote_url" in
	git@github.com:*) slug="${remote_url#git@github.com:}" ;;
	ssh://git@github.com/*) slug="${remote_url#ssh://git@github.com/}" ;;
	https://github.com/*) slug="${remote_url#https://github.com/}" ;;
	http://github.com/*) slug="${remote_url#http://github.com/}" ;;
	*) return 1 ;;
	esac
	slug="${slug%.git}"
	case "$slug" in
	*/*) printf '%s\n' "$slug" ;;
	*) return 1 ;;
	esac
	return 0
}

_todo_branch_requires_planning_pr() {
	local repo_path="$1"
	local branch_name="$2"
	local slug=""

	if [[ "${AIDEVOPS_PLANNING_FORCE_PR_FALLBACK:-0}" == "1" ]]; then
		return 0
	fi
	[[ -n "$branch_name" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1
	slug=$(_todo_origin_slug "$repo_path") || return 1
	if gh api "repos/${slug}/branches/${branch_name}/protection" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_todo_slugify_ref_fragment() {
	local raw_text="$1"
	local slug=""
	slug=$(printf '%s' "$raw_text" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-48)
	[[ -n "$slug" ]] || slug="planning-files"
	printf '%s\n' "$slug"
	return 0
}

_todo_safe_planning_path() {
	local rel_path="$1"
	case "$rel_path" in
	TODO.md | todo/*) return 0 ;;
	*) return 1 ;;
	esac
}

_todo_changed_planning_files() {
	local repo_path="$1"
	local files="$2"
	{
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" diff --name-only HEAD -- $files 2>/dev/null || true
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" diff --name-only --cached -- $files 2>/dev/null || true
		# shellcheck disable=SC2086 # files is the legacy space-delimited API.
		git -C "$repo_path" ls-files --others --exclude-standard -- $files 2>/dev/null || true
	} | sort -u | grep -E '^(TODO\.md|todo/)' || true
	return 0
}

_todo_changed_task_ids() {
	local repo_path="$1"
	local changed_files="$2"
	local rel_path=""
	local task_id=""
	{
		git -C "$repo_path" diff --no-ext-diff --unified=0 HEAD -- TODO.md 2>/dev/null |
			sed -nE 's/^\+[[:space:]]*- \[[^]]\][[:space:]]+(t[1-9][0-9]*(\.[1-9][0-9]*)*).*/\1/p'
		while IFS= read -r rel_path; do
			case "$rel_path" in
			todo/tasks/t*-brief.md)
				task_id="${rel_path##*/}"
				task_id="${task_id%-brief.md}"
				[[ "$task_id" =~ ^t[1-9][0-9]*(\.[1-9][0-9]*)*$ ]] && printf '%s\n' "$task_id"
				;;
			esac
		done <<<"$changed_files"
	} | sort -u
	return 0
}

_todo_changed_task_manifest() {
	local repo_path="$1"
	local changed_files="$2"
	local task_ids=""
	local task_id=""
	local task_line=""
	local task_count=0
	local issue_refs=""
	local issue_count=0
	local issue_num=""
	local manifest=""
	task_ids=$(_todo_changed_task_ids "$repo_path" "$changed_files")
	[[ -n "$task_ids" ]] || return 0
	while IFS= read -r task_id; do
		[[ -n "$task_id" ]] || continue
		task_count=$(grep -Ec "^[[:space:]]*- \[[^]]\][[:space:]]+${task_id}([[:space:]]|$)" \
			"${repo_path}/TODO.md" 2>/dev/null || true)
		if [[ "$task_count" -ne 1 ]]; then
			printf '[todo_commit_push] Planning publication cannot safely map %s: expected one current TODO entry, found %s.\n' \
				"$task_id" "$task_count" >&2
			return 2
		fi
		task_line=$(grep -E "^[[:space:]]*- \[[^]]\][[:space:]]+${task_id}([[:space:]]|$)" \
			"${repo_path}/TODO.md") || return 2
		issue_refs=$(printf '%s\n' "$task_line" | grep -Eo '(^|[[:space:]])ref:GH#[1-9][0-9]*([[:space:]]|$)' || true)
		issue_count=$(printf '%s\n' "$issue_refs" | grep -c 'ref:GH#' || true)
		if [[ "$issue_count" -ne 1 ]]; then
			printf '[todo_commit_push] Planning publication cannot safely map %s: expected one same-repository ref:GH#NNN field, found %s.\n' \
				"$task_id" "$issue_count" >&2
			return 2
		fi
		issue_num="${issue_refs#*ref:GH#}"
		issue_num="${issue_num%%[[:space:]]*}"
		manifest="${manifest}${manifest:+$'\n'}${task_id}"$'\t'"${issue_num}"
	done <<<"$task_ids"
	printf '%s\n' "$manifest" | sort -u
	return 0
}

_todo_planning_publication_id() {
	local repo_path="$1"
	local changed_files="$2"
	local rel_path=""
	local object_id=""
	local snapshot=""
	while IFS= read -r rel_path; do
		[[ -n "$rel_path" ]] || continue
		_todo_safe_planning_path "$rel_path" || continue
		if [[ -f "${repo_path}/${rel_path}" ]]; then
			object_id=$(git -C "$repo_path" hash-object -- "$rel_path") || return 1
		else
			object_id="deleted"
		fi
		snapshot="${snapshot}${rel_path}"$'\t'"${object_id}"$'\n'
	done <<<"$changed_files"
	[[ -n "$snapshot" ]] || return 1
	printf '%s' "$snapshot" | git -C "$repo_path" hash-object --stdin
	return $?
}

_todo_copy_planning_changes_to_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	local changed_files="$3"

	local rel_path
	while IFS= read -r rel_path; do
		[[ -n "$rel_path" ]] || continue
		_todo_safe_planning_path "$rel_path" || continue
		if [[ -e "${repo_path}/${rel_path}" ]]; then
			mkdir -p "${worktree_path}/$(dirname "$rel_path")" || return 1
			cp -p "${repo_path}/${rel_path}" "${worktree_path}/${rel_path}" || return 1
		else
			rm -f "${worktree_path}/${rel_path}" || return 1
		fi
	done <<<"$changed_files"
	return 0
}

_todo_clean_source_planning_changes() {
	local repo_path="$1"
	local changed_files="$2"

	local rel_path
	while IFS= read -r rel_path; do
		[[ -n "$rel_path" ]] || continue
		_todo_safe_planning_path "$rel_path" || continue
		if git -C "$repo_path" ls-files --error-unmatch -- "$rel_path" >/dev/null 2>&1; then
			git -C "$repo_path" reset -q HEAD -- "$rel_path" >/dev/null 2>&1 || true
			git -C "$repo_path" checkout -q -- "$rel_path" >/dev/null 2>&1 || return 1
		else
			rm -f "${repo_path}/${rel_path}" || return 1
		fi
	done <<<"$changed_files"
	return 0
}

_todo_remove_temp_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	[[ -n "$worktree_path" ]] || return 0
	if [[ -e "${worktree_path}/.git" ]]; then
		git -C "$repo_path" worktree remove --force "$worktree_path" >/dev/null 2>&1 || return 1
	fi
	[[ ! -e "$worktree_path" ]] || return 1
	return 0
}

_todo_planning_pr_body() {
	local source_branch="$1"
	local default_branch="$2"
	local commit_msg="$3"
	local publication_id="$4"
	local task_manifest="$5"
	local task_id=""
	local issue_num=""
	local issue_refs=""
	while IFS=$'\t' read -r task_id issue_num; do
		[[ -n "$task_id" && "$issue_num" =~ ^[1-9][0-9]*$ ]] || continue
		if ! grep -Eq "(^|[[:space:]])${issue_num}($|[[:space:]])" <<<"$issue_refs"; then
			issue_refs="${issue_refs}${issue_refs:+ }${issue_num}"
		fi
	done <<<"$task_manifest"
	cat <<EOF
## Planning publication

- Publishes TODO.md and todo/ planning-file changes through a PR because ${default_branch} does not accept direct planning pushes.
- Source branch at helper invocation: ${source_branch}.
- Commit message: ${commit_msg}.

## Task and issue manifest

<!-- aidevops:planning-publication:v1 id=${publication_id} -->
EOF
	while IFS=$'\t' read -r task_id issue_num; do
		[[ -n "$task_id" && "$issue_num" =~ ^[1-9][0-9]*$ ]] || continue
		printf '<!-- aidevops:planning-task:v1 task=%s issue=%s -->\n' "$task_id" "$issue_num"
	done <<<"$task_manifest"
	for issue_num in $issue_refs; do
		printf -- '- For #%s\n' "$issue_num"
	done
	cat <<EOF

## Security and architecture guardrails

- This PR does not update .task-counter.
- Task IDs still come from claim-task-id.sh CAS allocation on a branch that permits atomic counter pushes.
- Do not replace counter allocation with a PR-backed counter update; PR review is not an atomic ID lock.

## Merge note

- Merge this planning-only PR before expecting pulse or issue-sync to see the TODO/todo changes.
EOF
	return 0
}

_todo_planning_pr_title() {
	local commit_msg="$1"
	local task_manifest="$2"
	local manifest_count=0
	local task_id=""
	local subject="$commit_msg"
	manifest_count=$(printf '%s\n' "$task_manifest" | grep -c $'^[^\t][^\t]*\t[1-9][0-9]*$' || true)
	if [[ "$manifest_count" -eq 1 ]]; then
		task_id="${task_manifest%%$'\t'*}"
		subject="${commit_msg#*: }"
		printf 'plan(%s): %s\n' "$task_id" "$subject"
		return 0
	fi
	printf '%s\n' "$commit_msg"
	return 0
}

_todo_planning_pr_slug() {
	local repo_path="$1"
	local log_target="$2"

	local slug=""
	if ! command -v gh >/dev/null 2>&1 || ! command -v gh_create_pr >/dev/null 2>&1; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback unavailable: gh/gh_create_pr not available" >>"$log_target"
		return 1
	fi
	slug=$(_todo_origin_slug "$repo_path") || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback unavailable: cannot resolve GitHub repo slug" >>"$log_target"
		return 1
	}
	printf '%s\n' "$slug"
	return 0
}

_TODO_PLANNING_PR_BRANCH=""
_TODO_PLANNING_PR_WORKTREE=""
_TODO_PLANNING_PR_COMMIT=""
_TODO_PLANNING_PR_REUSED=0

_todo_create_planning_worktree() {
	local repo_path="$1"
	local commit_msg="$2"
	local default_branch="$3"
	local publication_id="$4"
	local log_target="$5"

	if git -C "$repo_path" remote get-url origin >/dev/null 2>&1; then
		git -C "$repo_path" fetch -q origin "$default_branch" 2>>"$log_target" || {
			printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot fetch origin/${default_branch}" >>"$log_target"
			return 1
		}
	fi

	local repo_abs parent_dir repo_name slug_part branch_name worktree_path remote_commit
	repo_abs=$(cd "$repo_path" 2>/dev/null && pwd -P) || return 1
	parent_dir=$(dirname "$repo_abs") || return 1
	repo_name=$(basename "$repo_abs") || return 1
	slug_part=$(_todo_slugify_ref_fragment "$commit_msg")
	branch_name="planning/${publication_id:0:12}-${slug_part}"
	worktree_path="${parent_dir}/${repo_name}-planning-${publication_id:0:12}-$$-${slug_part}"
	_TODO_PLANNING_PR_BRANCH="$branch_name"
	_TODO_PLANNING_PR_WORKTREE=""
	_TODO_PLANNING_PR_COMMIT=""
	_TODO_PLANNING_PR_REUSED=0

	if git -C "$repo_path" ls-remote --exit-code --heads origin "refs/heads/${branch_name}" >/dev/null 2>&1; then
		git -C "$repo_path" fetch -q origin "+refs/heads/${branch_name}:refs/remotes/origin/${branch_name}" 2>>"$log_target" || return 1
		remote_commit=$(git -C "$repo_path" rev-parse "refs/remotes/origin/${branch_name}" 2>/dev/null) || return 1
		if ! git -C "$repo_path" log -1 --format=%B "$remote_commit" 2>/dev/null |
			grep -Fqx "Planning-Publication-ID: ${publication_id}"; then
			printf '%s\n' "[todo_commit_push] Planning publication branch collision: ${branch_name}" >>"$log_target"
			printf '[todo_commit_push] Existing remote branch %s does not match publication %s; refusing to overwrite it.\n' \
				"$branch_name" "$publication_id" >&2
			return 1
		fi
		_TODO_PLANNING_PR_COMMIT="$remote_commit"
		_TODO_PLANNING_PR_REUSED=1
		return 0
	fi

	if [[ -e "$worktree_path" ]]; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: worktree path already exists" >>"$log_target"
		return 1
	fi

	git -C "$repo_path" worktree add --detach "$worktree_path" "origin/${default_branch}" >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot create linked worktree" >>"$log_target"
		return 1
	}

	_TODO_PLANNING_PR_WORKTREE="$worktree_path"
	return 0
}

_todo_commit_planning_worktree() {
	local repo_path="$1"
	local worktree_path="$2"
	local changed_files="$3"
	local files="$4"
	local commit_msg="$5"
	local branch_name="$6"
	local publication_id="$7"
	local log_target="$8"
	local commit_sha=""
	if [[ "$_TODO_PLANNING_PR_REUSED" -eq 1 ]]; then
		return 0
	fi

	if ! _todo_copy_planning_changes_to_worktree "$repo_path" "$worktree_path" "$changed_files"; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot copy planning changes" >>"$log_target"
		return 1
	fi

	# shellcheck disable=SC2086 # files is the legacy space-delimited API.
	git -C "$worktree_path" add $files 2>>"$log_target" || true
	if git -C "$worktree_path" diff --cached --quiet 2>/dev/null; then
		printf '%s\n' "[todo_commit_push] No changes staged in planning PR worktree" >>"$log_target"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi

	git -C "$worktree_path" commit -m "$commit_msg" \
		-m "Planning-Publication-ID: ${publication_id}" --no-verify >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: commit failed" >>"$log_target"
		return 1
	}
	commit_sha=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || return 1
	_TODO_PLANNING_PR_COMMIT="$commit_sha"
	git -C "$repo_path" update-ref "refs/aidevops/planning/${publication_id}" "$commit_sha" || return 1

	git -C "$worktree_path" push origin "HEAD:refs/heads/${branch_name}" >/dev/null 2>>"$log_target" || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: branch push failed" >>"$log_target"
		return 1
	}
	return 0
}

_todo_open_planning_pr() {
	local slug="$1"
	local default_branch="$2"
	local branch_name="$3"
	local current_branch="$4"
	local commit_msg="$5"
	local publication_id="$6"
	local task_manifest="$7"
	local log_target="$8"

	local pr_title pr_body pr_url pr_error_file pr_error
	pr_title=$(_todo_planning_pr_title "$commit_msg" "$task_manifest")
	pr_body=$(_todo_planning_pr_body "$current_branch" "$default_branch" "$commit_msg" \
		"$publication_id" "$task_manifest")
	pr_error_file=$(mktemp -t aidevops-planning-pr-error.XXXXXX 2>/dev/null) || pr_error_file=""
	[[ -n "$pr_error_file" ]] || {
		printf '[todo_commit_push] Planning PR fallback failed: cannot allocate diagnostic capture.\n' >&2
		return 1
	}
	pr_url=$(AIDEVOPS_PR_CREATE_READY=1 gh_create_pr \
		--repo "$slug" \
		--base "$default_branch" \
		--head "$branch_name" \
		--title "$pr_title" \
		--body "$pr_body" 2>"$pr_error_file") || {
		pr_error=$(<"$pr_error_file") || pr_error=""
		rm -f "$pr_error_file"
		[[ -z "$pr_error" ]] || printf '%s\n' "$pr_error" >&2
		[[ "$log_target" == "/dev/null" || -z "$pr_error" ]] || printf '%s\n' "$pr_error" >>"$log_target"
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: PR creation failed" >>"$log_target"
		return 1
	}
	rm -f "$pr_error_file"
	printf '%s\n' "$pr_url"
	return 0
}

_todo_existing_planning_pr_url() {
	local slug="$1"
	local branch_name="$2"
	local pr_url=""
	pr_url=$(gh pr list --repo "$slug" --head "$branch_name" --state open \
		--json url --jq '.[0].url // empty' 2>/dev/null) || pr_url=""
	[[ -n "$pr_url" ]] || return 1
	printf '%s\n' "$pr_url"
	return 0
}

_todo_finalize_planning_pr() {
	local repo_path="$1"
	local worktree_path="$2"
	local publication_id="$3"
	local terminal_rc="$4"
	local pr_state="$5"
	local source_state="$6"
	local log_target="$7"
	local cleanup_state="not-created"
	local remote_state="not-pushed"
	if [[ -n "$worktree_path" ]]; then
		if _todo_remove_temp_worktree "$repo_path" "$worktree_path"; then
			cleanup_state="removed"
		else
			cleanup_state="retained"
			terminal_rc=1
		fi
	fi
	if [[ -n "${_TODO_PLANNING_PR_BRANCH:-}" ]] &&
		git -C "$repo_path" ls-remote --exit-code --heads origin \
			"refs/heads/${_TODO_PLANNING_PR_BRANCH}" >/dev/null 2>&1; then
		remote_state="pushed"
		git -C "$repo_path" update-ref -d "refs/aidevops/planning/${publication_id}" 2>/dev/null || true
	elif [[ -n "${_TODO_PLANNING_PR_COMMIT:-}" ]]; then
		remote_state="local-recovery-ref"
	fi
	if [[ "$terminal_rc" -ne 0 ]]; then
		printf '[todo_commit_push] Planning publication stopped after %s; caller planning edits are %s and the disposable worktree is %s.\n' \
			"$remote_state" "$source_state" "$cleanup_state" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_PUBLICATION_ID=%s\n' "$publication_id" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_BRANCH=%s\n' "${_TODO_PLANNING_PR_BRANCH:-}" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_COMMIT=%s\n' "${_TODO_PLANNING_PR_COMMIT:-}" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_REMOTE_STATE=%s\n' "$remote_state" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_PR_STATE=%s\n' "$pr_state" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_SOURCE_STATE=%s\n' "$source_state" >&2
		printf 'AIDEVOPS_PLANNING_RECOVERY_WORKTREE_STATE=%s\n' "$cleanup_state" >&2
		printf '[todo_commit_push] Retry with the same planning snapshot; publication %s reuses branch %s instead of creating a duplicate.\n' \
			"$publication_id" "${_TODO_PLANNING_PR_BRANCH:-unknown}" >&2
		if [[ "$log_target" != "/dev/null" ]]; then
			printf '%s\n' "[todo_commit_push] Recovery publication=${publication_id} branch=${_TODO_PLANNING_PR_BRANCH:-} commit=${_TODO_PLANNING_PR_COMMIT:-} remote=${remote_state} pr=${pr_state} source=${source_state} worktree=${cleanup_state}" >>"$log_target"
		fi
	fi
	return "$terminal_rc"
}

_todo_create_planning_pr() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="$3"
	local current_branch="$4"
	local default_branch="$5"
	local log_target="$6"

	local slug="" changed_files="" branch_name="" worktree_path="" pr_url=""
	local task_manifest="" publication_id="" pr_state="not-created" source_state="preserved"
	local terminal_rc=0 manifest_rc=0
	slug=$(_todo_planning_pr_slug "$repo_path" "$log_target") || return 1
	changed_files=$(_todo_changed_planning_files "$repo_path" "$files")
	if [[ -z "$changed_files" ]]; then
		printf '%s\n' "[todo_commit_push] No planning changes available for PR fallback" >>"$log_target"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi
	task_manifest=$(_todo_changed_task_manifest "$repo_path" "$changed_files") || manifest_rc=$?
	if [[ "$manifest_rc" -ne 0 ]]; then
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: changed task/issue manifest is ambiguous" >>"$log_target"
		return 1
	fi
	publication_id=$(_todo_planning_publication_id "$repo_path" "$changed_files") || {
		printf '%s\n' "[todo_commit_push] Planning PR fallback failed: cannot derive publication identity" >>"$log_target"
		return 1
	}

	_todo_create_planning_worktree "$repo_path" "$commit_msg" "$default_branch" "$publication_id" "$log_target" || return 1
	branch_name="$_TODO_PLANNING_PR_BRANCH"
	worktree_path="$_TODO_PLANNING_PR_WORKTREE"
	_todo_commit_planning_worktree "$repo_path" "$worktree_path" "$changed_files" "$files" \
		"$commit_msg" "$branch_name" "$publication_id" "$log_target" || terminal_rc=$?
	if [[ "$terminal_rc" -eq 0 && "$TODO_COMMIT_PUSH_RESULT" != "$TODO_COMMIT_RESULT_NOOP" ]]; then
		pr_url=$(_todo_existing_planning_pr_url "$slug" "$branch_name" 2>/dev/null || true)
		if [[ -n "$pr_url" ]]; then
			pr_state="open-reused"
		else
			pr_url=$(_todo_open_planning_pr "$slug" "$default_branch" "$branch_name" "$current_branch" \
				"$commit_msg" "$publication_id" "$task_manifest" "$log_target") || terminal_rc=$?
			[[ "$terminal_rc" -eq 0 ]] && pr_state="open" || pr_state="missing"
		fi
	fi

	if [[ "$terminal_rc" -eq 0 && "$TODO_COMMIT_PUSH_RESULT" != "$TODO_COMMIT_RESULT_NOOP" ]] &&
		! _todo_clean_source_planning_changes "$repo_path" "$changed_files"; then
		printf '%s\n' "[todo_commit_push] Planning PR created but source planning cleanup failed" >>"$log_target"
		terminal_rc=1
		source_state="modified"
	elif [[ "$terminal_rc" -eq 0 ]]; then
		source_state="cleaned"
	fi
	_todo_finalize_planning_pr "$repo_path" "$worktree_path" "$publication_id" "$terminal_rc" \
		"$pr_state" "$source_state" "$log_target" || return $?
	if [[ "$TODO_COMMIT_PUSH_RESULT" == "$TODO_COMMIT_RESULT_NOOP" ]]; then
		return 0
	fi
	TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_PR"
	TODO_COMMIT_PUSH_PR_URL="$pr_url"
	printf '%s\n' "[todo_commit_push] Planning PR created: ${pr_url}" >>"$log_target"
	return 0
}

todo_commit_push() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="${3:-TODO.md todo/}"
	local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"
	TODO_COMMIT_PUSH_RESULT=""
	TODO_COMMIT_PUSH_PR_URL=""

	mkdir -p "$TODO_LOCK_DIR" 2>/dev/null || true

	if ! _todo_acquire_lock "$log_target"; then
		return 1
	fi

	# Ensure lock is released on exit (including signals)
	trap '_todo_release_lock' EXIT

	local rc=0
	_todo_commit_push_inner "$repo_path" "$commit_msg" "$files" "$log_target" || rc=$?

	_todo_release_lock
	trap - EXIT

	return $rc
}

_todo_commit_push_inner() {
	local repo_path="$1"
	local commit_msg="$2"
	local files="$3"
	local log_target="$4"
	local attempt=0
	local current_branch=""
	local default_branch=""

	current_branch=$(_todo_current_branch "$repo_path")
	default_branch=$(_todo_default_branch "$repo_path")
	if [[ -n "$current_branch" && -n "$default_branch" ]] &&
		_todo_branch_requires_planning_pr "$repo_path" "$default_branch"; then
		printf '%s\n' "[todo_commit_push] Default branch ${default_branch} requires PR publication for planning files" >>"$log_target"
		_todo_create_planning_pr "$repo_path" "$commit_msg" "$files" "$current_branch" "$default_branch" "$log_target"
		return $?
	fi

	current_branch=$(_todo_current_branch "$repo_path")
	[[ -n "$current_branch" ]] || current_branch="main"

	# Stage and commit before pull/rebase. Pulling first fails when the caller has
	# unstaged planning edits; after a local planning commit, rebase can safely
	# linearise against a moved remote branch before push.
	local file
	for file in $files; do
		git -C "$repo_path" add "$file" 2>/dev/null || true
	done

	if git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
		echo "[todo_commit_push] No changes staged" >>"$log_target"
		TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_NOOP"
		return 0
	fi

	if ! git -C "$repo_path" commit -m "$commit_msg" --no-verify 2>>"$log_target"; then
		echo "[todo_commit_push] Commit failed" >>"$log_target"
		return 1
	fi

	while [[ $attempt -lt $TODO_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		# Push first; only pay the rebase cost if the remote moved or rejected.
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success on attempt $attempt" >>"$log_target"
			TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_DIRECT"
			return 0
		fi

		echo "[todo_commit_push] Push failed (attempt $attempt/$TODO_MAX_RETRIES), retrying..." >>"$log_target"

		# Push failed: pull --rebase to incorporate remote changes, then retry push
		git -C "$repo_path" pull --rebase origin "$current_branch" 2>>"$log_target" || {
			git -C "$repo_path" rebase --abort 2>/dev/null || true
			sleep 1
			continue
		}

		# Retry push after rebase
		if git -C "$repo_path" push origin "$current_branch" 2>>"$log_target"; then
			echo "[todo_commit_push] Success after rebase on attempt $attempt" >>"$log_target"
			TODO_COMMIT_PUSH_RESULT="$TODO_COMMIT_RESULT_DIRECT"
			return 0
		fi

		sleep $((attempt))
	done

	echo "[todo_commit_push] Failed after $TODO_MAX_RETRIES attempts" >>"$log_target"
	return 1
}
