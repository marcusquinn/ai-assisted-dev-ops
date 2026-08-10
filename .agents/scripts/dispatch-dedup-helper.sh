#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-helper.sh - Normalize and deduplicate worker dispatch titles (t2310)
#
# Prevents duplicate worker dispatch by extracting canonical dedup keys from
# worker process titles, issue/PR numbers, and task IDs. The pulse agent calls
# this before dispatching to check if a worker is already running for the same
# issue, PR, or task.
#
# The root cause (issue #2310): title matching is not normalized. The same issue
# can be dispatched with different title formats:
#   - "issue-2300-simplify-infra-scripts"
#   - "Issue #2300: t1337 Simplify Tier 3 infrastructure scripts"
#   - "t1337: Simplify Tier 3 over-engineered infrastructure scripts"
# All three refer to issue #2300 / task t1337, but raw string comparison misses this.
#
# Solution: extract canonical dedup keys (issue-NNN, pr-NNN, task-tNNN) from any
# title format, then compare keys instead of raw strings.
#
# Usage:
#   dispatch-dedup-helper.sh extract-keys <title>
#     Extract dedup keys from a title string. Returns one key per line.
#
#   dispatch-dedup-helper.sh is-duplicate <title>
#     Check if any running worker already covers the same issue/PR/task.
#     Exit 0 = duplicate found (do NOT dispatch), exit 1 = no duplicate (safe to dispatch).
#
#   dispatch-dedup-helper.sh has-open-pr <issue> <slug> [issue-title]
#     Check whether an issue already has merged PR evidence (closing keyword or
#     task-id fallback) and should be skipped by pulse dispatch.
#     Exit 0 = PR evidence exists (do NOT dispatch), exit 1 = no evidence.
#
#   dispatch-dedup-helper.sh check-orphan-loop <issue> <slug> <branch> [todo-file] [worktree-path]
#     Check whether repeated worker_branch_orphan outcomes for the same issue
#     and branch should hold dispatch before launching another worker.
#     Exit 0 = threshold reached (do NOT dispatch), exit 1 = no hold.
#
#   dispatch-dedup-helper.sh check-recovery-loop <issue> <slug>
#     Check whether repeated worker recovery failures across branches should
#     pause dispatch before another claim/comment is posted.
#     Exit 0 = threshold reached (do NOT dispatch), exit 1 = no hold.
#
#   dispatch-dedup-helper.sh is-assigned <issue> <slug> [self-login]
#     Check if issue is assigned to another runner (not self, owner, or maintainer).
#     GH#10521: Ignores repo owner (from slug) and maintainer (from repos.json).
#     Exit 0 = assigned to another runner (do NOT dispatch), exit 1 = safe to dispatch.
#
#   dispatch-dedup-helper.sh is-assigned-read-only <issue> <slug> [self-login]
#     Run the same assignment guard without stale-assignment recovery writes.
#     Exit 0 = assignment/guard blocks, exit 1 = no assignment/guard block.
#
#   dispatch-dedup-helper.sh list-running-keys
#     List dedup keys for all currently running workers.
#
#   dispatch-dedup-helper.sh claim <issue> <slug> [runner-login]
#     Cross-machine optimistic lock via GitHub comments (t1686).
#     Exit 0 = claim won (safe to dispatch), exit 1 = lost, exit 2 = error (fail-open).
#
#   dispatch-dedup-helper.sh normalize <title>
#     Return the normalized (lowercased, stripped) form of a title for comparison.

set -euo pipefail

# Resolve path to dispatch-claim-helper.sh (co-located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAIM_HELPER="${SCRIPT_DIR}/dispatch-claim-helper.sh"

# t2033: source shared-constants for set_issue_status helper. Include guard
# inside shared-constants.sh makes this safe even when orchestrator already
# sourced it.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# GH#18917: cost circuit breaker extracted to keep this file below 2000 lines.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-cost.sh"

# Shared strict GitHub closing-clause parser for stale PR routing.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pr-closing-link-lib.sh"

# GH#18916: stale assignment recovery subsystem extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-stale.sh"

# GH#18916: PR evidence dedup checks extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-pr.sh"

# Issue-level worker recovery loop fuse.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-recovery-loop.sh"

_DDH_ORPHAN_PR_HINT_NONE="none found"

#######################################
# Resolve configured PR base branch for worker-orphan diagnostics.
#
# Args: $1 = repo slug
# Outputs: branch name
# Returns: 0 always
#######################################
_ddh_resolve_pr_base_branch() {
	local repo_slug="$1"
	local base_branch="${WORKER_PR_BASE_BRANCH:-${DISPATCH_REPO_PR_BASE_BRANCH:-${AIDEVOPS_PR_BASE_BRANCH:-}}}"
	local repos_json="${AIDEVOPS_REPOS_JSON:-${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}}"

	if [[ -z "$base_branch" && -n "$repo_slug" && -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		base_branch=$(jq -r --arg slug "$repo_slug" '
			.initialized_repos[]?
			| select(.slug == $slug)
			| .pr_base_branch // .pr_target_branch // .base_branch // .default_branch // empty
		' "$repos_json" 2>/dev/null | sed -n '1p') || base_branch=""
	fi

	if [[ -z "$base_branch" && -n "$repo_slug" ]]; then
		base_branch=$(gh repo view "$repo_slug" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
	fi

	printf '%s' "${base_branch:-main}"
	return 0
}

#######################################
# Build the issue comments endpoint used by orphan-branch checks.
#
# Args: $1 = repo slug, $2 = issue number
# Outputs: GitHub API endpoint path
# Returns: 0 always
#######################################
_ddh_issue_comments_endpoint() {
	local repo_slug="$1"
	local issue_number="$2"

	printf 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number"
	return 0
}

#######################################
# Probe a branch-orphan candidate before redispatch.
#
# Args: $1 = repo slug, $2 = branch name, $3 = worktree path, $4 = base branch
# Outputs: pipe-delimited remote status and commit count fields.
# Returns: 0 always
#######################################
_ddh_probe_orphan_branch_state() {
	local repo_slug="$1"
	local branch_name="$2"
	local worktree_path="${3:-}"
	local base_branch="${4:-main}"
	local unknown_value="unknown"
	local remote_probe="unavailable"
	local remote_exists="$unknown_value"
	local commit_count="$unknown_value"

	if [[ -n "$branch_name" && "$branch_name" != "HEAD" ]]; then
		local remote_rc=0
		remote_probe="git ls-remote --exit-code origin refs/heads/${branch_name}"
		if [[ -n "$worktree_path" && ( -d "$worktree_path/.git" || -f "$worktree_path/.git" ) ]]; then
			GIT_TERMINAL_PROMPT=0 git -C "$worktree_path" ls-remote --exit-code origin "refs/heads/${branch_name}" >/dev/null || remote_rc=$?
		else
			GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code origin "refs/heads/${branch_name}" >/dev/null || remote_rc=$?
		fi
		case "$remote_rc" in
		0)
			remote_exists="yes"
			;;
		2)
			remote_exists="no"
			;;
		*)
			remote_exists="$unknown_value"
			;;
		esac
	fi

	if [[ -n "$worktree_path" && ( -d "$worktree_path/.git" || -f "$worktree_path/.git" ) ]]; then
		commit_count=$(git -C "$worktree_path" rev-list --count "origin/${base_branch}..origin/${branch_name}" || true)
		if ! [[ "$commit_count" =~ ^[0-9]+$ ]]; then
			commit_count=$(git -C "$worktree_path" rev-list --count "origin/${branch_name}" || true)
		fi
		[[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count="$unknown_value"
	fi

	printf '%s|%s|%s|%s\n' "$repo_slug" "$remote_probe" "$remote_exists" "$commit_count"
	return 0
}

#######################################
# Post a diagnostic and hold dispatch for unrecoverable orphan evidence.
#
# Args: $1 issue, $2 repo, $3 branch, $4 reason, $5 remote probe,
#       $6 remote exists, $7 commit count, $8 comments endpoint,
#       $9 comments json
# Returns: 0 always
#######################################
_ddh_hold_unrecoverable_orphan_branch() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local hold_reason="$4"
	local remote_probe="$5"
	local remote_exists="$6"
	local commit_count="$7"
	local comments_post_endpoint="$8"
	local comments_json="$9"
	local existing_block="0"

	existing_block=$(printf '%s' "$comments_json" |
		jq -r --arg branch "$branch_name" --arg reason "$hold_reason" '
			[.[][] | (.body // empty)
			| select(contains("worker-branch-orphan-unrecoverable:blocked branch=" + $branch + " "))
			| select(contains("reason=" + $reason + " "))] | length
		' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0

	if [[ "$existing_block" -eq 0 ]]; then
		local diag=""
		# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
		diag=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan-unrecoverable:blocked branch=%s issue=%s reason=%s remote_exists=%s commit_count=%s -->\n## Dispatch held: unrecoverable worker_branch_orphan\n\nThe dispatch path found `WORKER_BRANCH_ORPHAN` telemetry for issue #%s on branch `%s`, but the recovery evidence is not actionable. Standard redispatch is held to avoid burning additional worker attempts.\n\n- Branch: `%s`\n- Remote-branch probe: `%s`\n- Remote branch exists: `%s`\n- Branch commit count: `%s`\n- Root cause: `%s`\n- Next action: inspect the worker worktree/logs, recover or recreate the missing commits, then remove the stale orphan marker/worktree before dispatching again.\n<!-- ops:end -->' \
			"$branch_name" "$issue_number" "$hold_reason" "$remote_exists" "$commit_count" \
			"$issue_number" "$branch_name" "$branch_name" "$remote_probe" "$remote_exists" "$commit_count" "$hold_reason")
		gh api "$comments_post_endpoint" \
			--method POST \
			--field body="$diag" \
			>/dev/null 2>&1 || true
	fi

	printf 'WORKER_BRANCH_ORPHAN_UNRECOVERABLE_BLOCKED (issue=%s repo=%s branch=%s reason=%s remote_probe=%s remote_exists=%s commit_count=%s)\n' \
		"$issue_number" "$repo_slug" "$branch_name" "$hold_reason" "$remote_probe" "$remote_exists" "$commit_count"
	return 0
}

#######################################
# Auto-recover a provably disposable zero-commit orphan branch.
#
# Args: $1 issue, $2 repo, $3 branch, $4 remote probe, $5 commit count,
#       $6 comments endpoint, $7 comments json
# Returns: 0 if recovered, 1 if caller should keep normal hold/block logic
#######################################
_ddh_auto_recover_zero_commit_orphan_branch() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local remote_probe="$4"
	local commit_count="$5"
	local comments_post_endpoint="$6"
	local comments_json="$7"
	local pr_hint="$_DDH_ORPHAN_PR_HINT_NONE"
	local existing_recovery="0"

	[[ "$commit_count" == "0" ]] || return 1
	pr_hint=$(_ddh_orphan_branch_pr_hint "$repo_slug" "$branch_name")
	[[ "$pr_hint" == "$_DDH_ORPHAN_PR_HINT_NONE" ]] || return 1

	existing_recovery=$(printf '%s' "$comments_json" |
		jq -r --arg branch "$branch_name" '
			[.[][] | (.body // empty)
			| select(contains("worker-branch-orphan-auto-recovered branch=" + $branch + " "))] | length
		' 2>/dev/null) || existing_recovery="0"
	[[ "$existing_recovery" =~ ^[0-9]+$ ]] || existing_recovery=0

	if gh api -X DELETE "repos/${repo_slug}/git/refs/heads/${branch_name}" >/dev/null 2>&1; then
		if [[ "$existing_recovery" -eq 0 ]]; then
			local diag=""
			# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
			diag=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan-auto-recovered branch=%s issue=%s reason=zero_commits commit_count=%s -->\n## Dispatch recovered: zero-commit worker_branch_orphan\n\nThe dispatch path found `WORKER_BRANCH_ORPHAN` telemetry for issue #%s on branch `%s`, but the remote branch has zero commits and no open or closed PR references it. The remote branch was deleted so dispatch can create or reuse a clean worker branch instead of feeding the no-work circuit breaker.\n\n- Branch: `%s`\n- Remote-branch probe: `%s`\n- Branch commit count: `%s`\n- PR for branch: none\n- Local worktree cleanup: not forced; any local state remains available for normal safety checks.\n<!-- ops:end -->' \
				"$branch_name" "$issue_number" "$commit_count" \
				"$issue_number" "$branch_name" "$branch_name" "$remote_probe" "$commit_count")
			gh api "$comments_post_endpoint" \
				--method POST \
				--field body="$diag" \
				>/dev/null 2>&1 || true
		fi
		printf 'WORKER_BRANCH_ORPHAN_AUTO_RECOVERED (issue=%s repo=%s branch=%s reason=zero_commits remote_probe=%s commit_count=%s)\n' \
			"$issue_number" "$repo_slug" "$branch_name" "$remote_probe" "$commit_count"
		return 0
	fi

	return 1
}

#######################################
# Extract canonical dedup keys from a title string.
# Looks for patterns: issue #NNN, PR #NNN, tNNN (task IDs), issue-NNN, pr-NNN.
# Args: $1 = title string
# Returns: one key per line on stdout (e.g., "issue-2300", "task-t1337")
#######################################
extract_keys() {
	local title="$1"
	local keys=()

	# Normalize to lowercase for pattern matching
	local lower_title
	lower_title=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')

	# Pattern 1: Explicit "issue #NNN" or "issue-NNN" (not bare #NNN)
	local issue_nums
	issue_nums=$(printf '%s' "$lower_title" | grep -oE 'issue\s*#?[0-9]+|issue-[0-9]+' | grep -oE '[0-9]+' || true)
	if [[ -n "$issue_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("issue-${num}")
		done <<<"$issue_nums"
	fi

	# Pattern 2: "pr #NNN" or "pr-NNN" or "pull #NNN"
	local pr_nums
	pr_nums=$(printf '%s' "$lower_title" | grep -oE '(pr\s*#?|pr-|pull\s*#?)[0-9]+' | grep -oE '[0-9]+' || true)
	if [[ -n "$pr_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("pr-${num}")
		done <<<"$pr_nums"
	fi

	# Pattern 2b: Bare "#NNN" (GitHub-style reference, could be issue or PR)
	# Produces a generic ref-NNN key that matches against both issue-NNN and pr-NNN
	local bare_refs
	bare_refs=$(printf '%s' "$lower_title" | grep -oE '(^|[^a-z])#([0-9]+)' | grep -oE '[0-9]+' || true)
	if [[ -n "$bare_refs" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("ref-${num}")
		done <<<"$bare_refs"
	fi

	# Pattern 3: task IDs "tNNN" (e.g., t1337, t128.5)
	local task_ids
	task_ids=$(printf '%s' "$lower_title" | grep -oE '\bt[0-9]+(\.[0-9]+)?\b' || true)
	if [[ -n "$task_ids" ]]; then
		while IFS= read -r tid; do
			[[ -n "$tid" ]] && keys+=("task-${tid}")
		done <<<"$task_ids"
	fi

	# Pattern 4: Branch-style "issue-NNN-" or "pr-NNN-" (from worktree names)
	# Use a portable fallback chain: rg (ripgrep) → ggrep -P (GNU grep on macOS) → grep -E
	local branch_issue_nums
	if command -v rg &>/dev/null; then
		branch_issue_nums=$(printf '%s' "$lower_title" | rg -o 'issue-([0-9]+)' | grep -oE '[0-9]+' || true)
	elif command -v ggrep &>/dev/null && ggrep -P '' /dev/null 2>/dev/null; then
		branch_issue_nums=$(printf '%s' "$lower_title" | ggrep -oP 'issue-\K[0-9]+' || true)
	else
		branch_issue_nums=$(printf '%s' "$lower_title" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+' || true)
	fi
	if [[ -n "$branch_issue_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("issue-${num}")
		done <<<"$branch_issue_nums"
	fi

	# Deduplicate keys
	if [[ ${#keys[@]} -gt 0 ]]; then
		printf '%s\n' "${keys[@]}" | sort -u
	fi

	return 0
}

#######################################
# Normalize a title for fuzzy comparison.
# Lowercases, strips punctuation, collapses whitespace.
# Args: $1 = title string
# Returns: normalized string on stdout
#######################################
normalize_title() {
	local title="$1"

	printf '%s' "$title" |
		tr '[:upper:]' '[:lower:]' |
		sed 's/[^a-z0-9 ]/ /g' |
		tr -s ' ' |
		sed 's/^ //; s/ $//'

	return 0
}

#######################################
# List dedup keys for all currently running workers.
# Scans process list for /full-loop workers and extracts keys from their titles.
# Returns: one "pid|key" pair per line on stdout
#######################################
list_running_keys() {
	# Get PIDs of running worker processes using portable pgrep -f (no -a flag).
	# pgrep -f matches against the full command line on both Linux and macOS.
	# We then resolve the full command line per PID via ps -p <pid> -o args=
	# which is POSIX-compatible and works on Linux, macOS, and BSD.
	local worker_pids=""
	worker_pids=$(pgrep -f '/full-loop|opencode run|claude.*run' || true)

	if [[ -z "$worker_pids" ]]; then
		return 0
	fi

	while IFS= read -r pid; do
		[[ -z "$pid" ]] && continue
		local cmdline=""
		# ps -p <pid> -o args= prints only the command line (no header, no PID prefix)
		cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
		[[ -z "$cmdline" ]] && continue

		local extracted_keys=""
		extracted_keys=$(extract_keys "$cmdline")
		if [[ -n "$extracted_keys" ]]; then
			while IFS= read -r key; do
				[[ -n "$key" ]] && printf '%s|%s\n' "$pid" "$key"
			done <<<"$extracted_keys"
		fi
	done <<<"$worker_pids"

	return 0
}

#######################################
# Check one candidate key against running process keys.
# Handles cross-type matching: ref-NNN matches issue-NNN and pr-NNN.
# Args: $1 = candidate key (e.g., "issue-2300", "ref-42", "task-t1337")
#       $2 = newline-separated "pid|key" pairs from list_running_keys
# Returns: exit 0 if match found (prints DUPLICATE line),
#          exit 1 if no match
#######################################
_match_candidate_key() {
	local candidate_key="$1"
	local running_keys="$2"

	local -a match_patterns=("$candidate_key")
	local key_type key_num
	key_type=$(printf '%s' "$candidate_key" | cut -d'-' -f1)
	key_num=$(printf '%s' "$candidate_key" | cut -d'-' -f2-)

	# ref-NNN should match issue-NNN and pr-NNN (and vice versa)
	case "$key_type" in
	ref)
		match_patterns+=("issue-${key_num}" "pr-${key_num}")
		;;
	issue | pr)
		match_patterns+=("ref-${key_num}")
		;;
	esac

	local pattern
	for pattern in "${match_patterns[@]}"; do
		local match
		match=$(printf '%s\n' "$running_keys" | grep "|${pattern}$" | head -1 || true)
		if [[ -n "$match" ]]; then
			local match_pid
			match_pid=$(printf '%s' "$match" | cut -d'|' -f1)
			printf 'DUPLICATE: key=%s matches running %s (PID %s)\n' "$candidate_key" "$pattern" "$match_pid"
			return 0
		fi
	done

	return 1
}

#######################################
# Query supervisor DB for one candidate key and verify PID liveness.
# GH#5662: stale DB entries (dead PIDs, missing PID files) are reset to
# 'failed' and treated as safe to dispatch.
# Args: $1 = candidate key (e.g., "issue-2300", "task-t1337", "pr-42")
#       $2 = path to supervisor.db
# Returns: exit 0 if live duplicate found (prints DUPLICATE line),
#          exit 1 if no match or stale entry (prints STALE line if stale)
#
# t2061 audit (2026-04-14):
#
# Error path classification for _check_db_entry:
#
#   sqlite3 DB unavailable (missing file, access error):
#     → 2>/dev/null || true swallows the error → db_match="" → return 1
#     → FAIL-OPEN INTENTIONAL: missing DB = no prior dispatch claim entry.
#       The correct answer to "is this a duplicate?" when the DB is absent is
#       "no" — genuine duplicates have DB entries; absence is evidence of absence.
#
#   sqlite3 query error (permission, corruption, format mismatch):
#     → 2>/dev/null || true → db_match="" → return 1
#     → FAIL-OPEN INTENTIONAL: same rationale. Cannot confirm a claim we
#       cannot read; the safe assumption is no prior claim.
#
#   PID file read error (unreadable, missing):
#     → cat 2>/dev/null || true → stored_pid="" → "No valid PID file" branch
#     → stale → return 1 (safe to dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot prove liveness without the PID. The
#       GH#5662 design intent is to recover stale entries; unreadable PID
#       files match the stale criteria.
#
#   sqlite3 UPDATE error during stale cleanup:
#     → 2>/dev/null || true → cleanup silently fails → return 1 (stale)
#     → FAIL-OPEN INTENTIONAL: cleanup failure does not affect the dispatch
#       decision. The dispatch is already allowed; cleanup is housekeeping.
#
# All fail-open paths answer "is this a duplicate?" with "no", which is the
# safest default for this guard. A genuine duplicate has a live DB entry;
# absence or unreadability is not evidence of a claim.
# NOTE: this is a LOCAL-ONLY guard (this machine's supervisor DB only).
# The cross-machine guard (is_assigned) enforces GUARD_UNCERTAIN fail-closed.
#######################################
_check_db_entry() {
	local candidate_key="$1"
	local supervisor_db="$2"

	local key_type key_num
	key_type=$(printf '%s' "$candidate_key" | cut -d'-' -f1)
	key_num=$(printf '%s' "$candidate_key" | cut -d'-' -f2-)

	local db_match=""
	case "$key_type" in
	issue)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND (description LIKE '%#${key_num}%'
			     OR description LIKE '%issue ${key_num}%'
			     OR description LIKE '%issue-${key_num}%')
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	task)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND id = '${key_num}'
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	pr)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND (pr_url LIKE '%/${key_num}'
			     OR description LIKE '%PR #${key_num}%'
			     OR description LIKE '%pr-${key_num}%')
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	esac

	[[ -z "$db_match" ]] && return 1

	# GH#5662: Verify the stored PID is still alive before reporting duplicate.
	local supervisor_dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	local pid_file="${supervisor_dir}/pids/${db_match}.pid"
	local stored_pid=""
	[[ -f "$pid_file" ]] && stored_pid=$(cat "$pid_file" 2>/dev/null || true)

	if [[ -n "$stored_pid" ]] && [[ "$stored_pid" =~ ^[0-9]+$ ]]; then
		# t2421: command-aware liveness check — bare kill -0 lies on macOS PID reuse
		if ! _is_process_alive_and_matches "$stored_pid" "${WORKER_PROCESS_PATTERN:-}"; then
			# Process is dead or PID was reused by an unrelated process — stale DB entry
			sqlite3 "$supervisor_db" "
				UPDATE tasks SET status = 'failed',
				  error = 'stale: PID ${stored_pid} not running or reused (GH#5662/t2421)',
				  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$(printf '%s' "$db_match" | sed "s/'/''/g")';
			" 2>/dev/null || true
			printf 'STALE: key=%s task %s PID %s is dead or reused — entry reset, safe to dispatch\n' \
				"$candidate_key" "$db_match" "$stored_pid"
			return 1
		fi
		# PID is alive AND command matches expected worker pattern — genuine duplicate
		printf 'DUPLICATE: key=%s already active in supervisor DB (task %s PID %s)\n' \
			"$candidate_key" "$db_match" "$stored_pid"
		return 0
	fi

	# No PID file or non-numeric content — treat as stale (GH#5662)
	printf 'STALE: key=%s task %s has no valid PID file — treating as stale, safe to dispatch\n' \
		"$candidate_key" "$db_match"
	sqlite3 "$supervisor_db" "
		UPDATE tasks SET status = 'failed',
		  error = 'stale: no PID file found (GH#5662)',
		  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$(printf '%s' "$db_match" | sed "s/'/''/g")';
	" 2>/dev/null || true
	return 1
}

#######################################
# Check if a title's dedup keys overlap with any running worker.
# Args: $1 = title of the item to be dispatched
# Returns: exit 0 if duplicate found (do NOT dispatch),
#          exit 1 if no duplicate (safe to dispatch)
# Outputs: matching key and PID on stdout if duplicate found
#
# GH#5662: When a supervisor DB match is found, the stored PID is verified
# with kill -0 before returning exit 0. Dead PIDs cause the stale DB entry
# to be reset to 'failed' and exit 1 is returned (safe to dispatch).
#
# t2061 audit (2026-04-14):
#
# Error path classification for is_duplicate:
#
#   extract_keys failure or empty output:
#     → candidate_keys="" → [[ -z ]] branch → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot deduplicate without keys. Dispatch
#       is allowed to avoid permanently blocking any title that can't be
#       parsed. The cross-machine is_assigned() guard is the safety net.
#
#   list_running_keys failure or empty output:
#     → running_keys="" → process-match loop not entered → proceed to DB check
#     → FAIL-OPEN INTENTIONAL: no running keys = no running duplicates on
#       this machine. This check is local-only; is_assigned() covers cross-machine.
#
#   _check_db_entry failures:
#     → return 1 (no duplicate found) — see _check_db_entry audit above.
#     → FAIL-OPEN INTENTIONAL: same rationale as _check_db_entry.
#
#   sqlite3 unavailable:
#     → `command -v sqlite3` gate → DB check skipped entirely → return 1
#     → FAIL-OPEN INTENTIONAL: cannot use a tool that is not installed.
#
# is_duplicate is a LOCAL-ONLY guard (running processes + supervisor DB on
# this machine only). It complements but does not replace is_assigned().
# Fail-open is appropriate because is_assigned() is the definitive
# cross-machine guard with GUARD_UNCERTAIN fail-closed semantics (t2046).
#######################################
is_duplicate() {
	local title="$1"

	# Extract keys from the candidate title
	local candidate_keys
	candidate_keys=$(extract_keys "$title")

	if [[ -z "$candidate_keys" ]]; then
		# No extractable keys — cannot deduplicate, allow dispatch
		return 1
	fi

	# Check against running worker processes
	local running_keys
	running_keys=$(list_running_keys)

	if [[ -n "$running_keys" ]]; then
		while IFS= read -r candidate_key; do
			[[ -z "$candidate_key" ]] && continue
			if _match_candidate_key "$candidate_key" "$running_keys"; then
				return 0
			fi
		done <<<"$candidate_keys"
	fi

	# Also check the supervisor DB if available
	local supervisor_db="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}/supervisor.db"
	if [[ -f "$supervisor_db" ]] && command -v sqlite3 &>/dev/null; then
		while IFS= read -r candidate_key; do
			[[ -z "$candidate_key" ]] && continue
			if _check_db_entry "$candidate_key" "$supervisor_db"; then
				return 0
			fi
		done <<<"$candidate_keys"
	fi

	# No duplicates found
	return 1
}

#######################################
# Get the repo owner from the slug.
# Args: $1 = repo slug (owner/repo)
# Returns: owner login on stdout (empty if invalid)
#######################################
_get_repo_owner() {
	local repo_slug="$1"

	if [[ -z "$repo_slug" || "$repo_slug" != */* ]]; then
		return 0
	fi

	printf '%s' "${repo_slug%%/*}"
	return 0
}

#######################################
# Look up the repo maintainer from repos.json.
# The maintainer is the repo owner/admin — not a runner account.
# Args: $1 = repo slug (owner/repo)
# Returns: maintainer login on stdout (empty if not found)
#######################################
_get_repo_maintainer() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local maintainer=""
	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null) || maintainer=""

	printf '%s' "$maintainer"
	return 0
}

# Stale assignment recovery functions are in dispatch-dedup-stale.sh (GH#18916).

#######################################
# Return "true" if the issue metadata represents an active claim that
# should override the owner/maintainer passive-assignee exemption in
# is_assigned(). An issue is actively claimed when EITHER:
#   - a lifecycle status label is set: status:queued, status:in-progress,
#     status:in-review, or status:claimed, OR
#   - the origin:interactive label is present without auto-dispatch (a live
#     human session is driving the work regardless of status label state), OR
#   - the consolidation-in-progress label is present (t2151 — a cross-
#     runner advisory lock held by a pulse runner that is mid-way through
#     creating a consolidation-task child issue; treat as an active claim
#     so unrelated dispatch paths can't sneak past during the write window)
#
# Extracted from is_assigned() to keep that function under the 100-line
# complexity cap after GH#18352 expanded the active-claim signal set
# (see t1961). Adding new active-state labels is a one-line change here.
#
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient:
#   - Label without assignee = degraded state (safe to reclaim after stale recovery)
#   - Assignee without active label = passive backlog bookkeeping (owner/maintainer
#     passive exemption applies; non-owner/maintainer still blocks)
#   - Label WITH non-self assignee = active claim (always blocks)
#   This function evaluates only the label half. is_assigned() enforces the
#   combined check by calling this only after an assignee is confirmed present.
#
# Args:
#   $1 = issue metadata JSON from `gh issue view --json labels` (at minimum
#        must contain a .labels array of {name: ...} objects)
# Stdout: "true" or "false"
#######################################
_has_active_claim() {
	local issue_meta_json="$1"
	local result
	result=$(printf '%s' "$issue_meta_json" | jq -r '
		.labels? // [] | map(.name) | (any(.[]; . == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed" or . == "consolidation-in-progress") or ((index("origin:interactive") != null) and (index("auto-dispatch") == null)))
	' 2>/dev/null) || result="false"
	[[ "$result" == "true" || "$result" == "false" ]] || result="false"
	printf '%s' "$result"
	return 0
}

#######################################
# Check if a GitHub issue is already assigned to another runner.
#
# This is the primary cross-machine dedup guard. Process-based checks
# (is_duplicate, has_worker_for_repo_issue) only see local processes —
# they miss workers running on other machines. The GitHub assignee is
# the single source of truth visible to all runners.
#
# Owner/maintainer assignment carries two different meanings:
#   1. passive backlog ownership / maintainer review bookkeeping
#   2. active worker claim (when paired with status:queued/in-progress)
#
# Treating all owner/maintainer assignees as active claims created a queue
# starvation bug: the pulse discovers unassigned issues by default, while
# several tooling pipelines auto-assigned newly created debt issues to the
# maintainer. The result was hundreds of open issues that looked "claimed"
# to the deterministic guard but had no worker, no queued state, and no PR.
#
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient.
#   See _has_active_claim() for the label-half definition.
#   This function enforces the combined check: it first checks whether an
#   assignee is present; if so, it calls _has_active_claim() to determine
#   if the passive exemption for owner/maintainer should be bypassed.
#
# Systemic rule:
# - self_login never blocks
# - owner/maintainer assignees are passive unless EITHER:
#     (a) the issue has an active claim status label — status:queued,
#         status:in-progress, status:in-review, or status:claimed
#         (full active lifecycle, not just the worker-set states), OR
#     (b) the issue has the origin:interactive label without auto-dispatch —
#         a human session is actively driving the work regardless of status
#         label state
#         (GH#18352 — closes the race where an interactive claim used
#         status:claimed, which was not recognised as an active state,
#         so the pulse dispatched a duplicate worker mid-flight)
# - auto-dispatch is an explicit handoff signal: origin:interactive remains
#   provenance but no longer bypasses owner/maintainer passive assignment.
# - any other assignee blocks dispatch — UNLESS the assignment is stale
#   (no active worker, dispatch claim >1h old, no recent progress).
#   Stale assignments are auto-recovered (GH#15060).
#
# Every dispatch decision site that emits a worker assignment MUST route
# through this function (or apply an equivalent inline combined check)
# before claiming. Any code path that checks only labels or only assignees
# is not safe in multi-operator conditions. (t1996 — audit confirmed that
# dispatch_with_dedup, apply_dispatch_max, and all implementation
# dispatch paths correctly route through check_dispatch_dedup which calls
# this function at Layer 6; normalize_active_issue_assignments was hardened
# in the same fix to also call this before self-assigning orphaned issues.)
#
# This preserves GH#10521 (maintainer assignment alone must not starve the
# queue) while still protecting GH#11141 (owner-assigned queued work must
# block other runners once a real claim is active) and GH#18352 (interactive
# sessions working on owner-assigned issues must not be raced by the pulse).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = (optional) current runner login — if assigned to self, not a dup
# Returns:
#   exit 0 if assigned to another login (do NOT dispatch), parent-task labeled,
#          no-auto-dispatch labeled, cost-budget exceeded, or guard cannot
#          determine safety (GUARD_UNCERTAIN)
#   exit 1 if unassigned or assigned only to self (safe to dispatch)
# Outputs: one of the following signals on stdout when blocking:
#   PARENT_TASK_BLOCKED (label=<name>)      — unconditional parent-task / meta block
#   PUBLICATION_PENDING_BLOCKED (label=...) — canonical planning publication has not landed
#   NO_AUTO_DISPATCH_BLOCKED (label=...)    — unconditional no-auto-dispatch block (t2832)
#   INFRASTRUCTURE_BLOCKED (label=...)      — infrastructure / billing / runner advisory block
#   COST_BUDGET_EXCEEDED (...)              — token spend circuit breaker
#   GUARD_UNCERTAIN (reason=...)            — internal error, cannot determine safety
#   <assignee info>                         — active claim by another runner
#
# FAIL-CLOSED CONTRACT (t2046):
#   When the guard cannot determine whether dispatch is safe due to an internal
#   error (gh API failure, jq error, helper failure), the function MUST block
#   dispatch and emit GUARD_UNCERTAIN. This is intentionally conservative:
#   a transient block clears in the next pulse cycle at zero cost; a wasted
#   worker dispatch burns ~20K tokens for zero output (GH#18458 incident).
#   The previous default (fail-open) allowed three workers to be dispatched
#   to a parent-task issue because a jq null-handling bug silently fell through
#   to the "allow dispatch" code path (see plan in todo/plans/parent-task-incident-hardening.md).
#######################################
#######################################
# is_assigned helper: check the parent-task / meta unconditional block.
#
# t1986: parent-task / meta label is an unconditional dispatch block.
# Any issue tagged as parent-only is plan-only work and must never
# receive a dispatched worker, regardless of assignees or status
# labels. Closes the dispatch loop observed on GH#18356 during
# t1962 Phase 3 (parent task dispatched twice with opus-4-6,
# burning ~20K tokens for zero productive output) and the
# same race reproduced on GH#18399 / GH#18400 while filing the
# follow-up issues for this very fix.
#
# Emits PARENT_TASK_BLOCKED on stdout for caller pattern matching
# (mirrors the STALE_RECOVERED token used by stale-recovery path).
#
# t2061: explicit jq failure capture — fail-closed. A jq failure here
# (type error, compile error, malformed labels field) would previously
# fall through to "no parent-task label found" via the || true pattern,
# silently skipping the unconditional dispatch block. Now emits
# GUARD_UNCERTAIN on any internal jq failure.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if parent-task label found or jq fails (prints signal),
#          exit 1 if no parent-task label and jq succeeds
#######################################
_is_assigned_check_parent_task() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	# t2061: explicit rc capture — fail-closed on jq failure.
	local _jq_rc=0
	local parent_task_hit
	parent_task_hit=$(printf '%s' "$meta_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' 2>/dev/null | head -n 1) || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=parent-task-check issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$parent_task_hit" ]]; then
		printf 'PARENT_TASK_BLOCKED (label=%s)\n' "$parent_task_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: block issues whose canonical planning publication has not
# landed on the default branch. The label is applied before an issue can exist
# ahead of its TODO.md row/brief and is removed only by exact-SHA reconciliation.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if publication:pending is present or jq fails (prints signal),
#          exit 1 if the label is absent and jq succeeds
#######################################
_is_assigned_check_publication_pending() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"publication:pending" "PUBLICATION_PENDING_BLOCKED" "publication-pending-check"
}

#######################################
# is_assigned helper: check an unconditional label block.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = issue number for traceable error output
#   $3 = repo slug for traceable error output
#   $4 = label name to check
#   $5 = block signal to emit when label is present
#   $6 = check name for GUARD_UNCERTAIN output
# Returns: exit 0 if label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_label_block() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	local label_name="$4"
	local block_signal="$5"
	local check_name="$6"
	local _jq_rc=0
	local label_hit
	label_hit=$(printf '%s' "$meta_json" |
		jq -r --arg label_name "$label_name" '(.labels // [])[].name | select(. == $label_name)' 2>/dev/null | head -n 1) || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=%s issue=%s repo=%s)\n' \
			"$check_name" "$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$label_hit" ]]; then
		printf '%s (label=%s)\n' "$block_signal" "$label_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: check the no-auto-dispatch unconditional block (t2832).
#
# t2832: no-auto-dispatch label is an unconditional dispatch block. The label
# was previously honoured by enrichment, decomposition, and backfill paths but
# NOT by the dispatch path itself — workers got dispatched to issues carrying
# the label, contradicting maintainer intent and the documented behaviour.
# Closes the dispatch hole observed on GH#20827 (t2821 policy issue): six
# worker dispatches over two hours despite the label being applied at issue
# creation, all failing in the dispatch-path tautology, ~30-50K opus tokens
# burned. The label now carries the same hard-block semantics as parent-task.
#
# Use cases this enables (post-fix):
#   - Maintainer-applied "do not auto-dispatch" hold without needing #parent
#     (which forces decomposition lifecycle on focused fixes that don't decompose)
#   - interactive-session-helper.sh lockdown — already applies this label;
#     the label now actually blocks dispatch end-to-end as documented
#   - Policy-level dispatch-path tasks (t2821) — sufficient as a focused-fix
#     blocker without combining with #parent
#
# Emits NO_AUTO_DISPATCH_BLOCKED on stdout for caller pattern matching
# (mirrors the PARENT_TASK_BLOCKED token used by parent-task check).
#
# Mirrors _is_assigned_check_parent_task structure:
#   - Same jq-failure fail-closed contract (t2061): GUARD_UNCERTAIN on jq error
#   - Same return-code contract: 0 = block (with signal printed), 1 = allow
#   - Same args shape for traceable error output
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if no-auto-dispatch label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_no_auto_dispatch() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"no-auto-dispatch" "NO_AUTO_DISPATCH_BLOCKED" "no-auto-dispatch-check"
}

_is_assigned_check_maintainer_permissions() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	#aidevops:trust-boundary -- only the request-specific signed grant flow may
	# clear this unconditional worker-dispatch hold.
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"needs-maintainer-permissions" "MAINTAINER_PERMISSIONS_BLOCKED" "maintainer-permissions-check"
}

#######################################
# is_assigned helper: check the infrastructure unconditional block.
#
# Infrastructure issues often describe billing, runner, hosting, or platform
# advisories that must remain visible for human operations rather than consume
# worker dispatch capacity. Candidate enumeration filters this label, but the
# dispatch path also checks it to close the race where a label is added after
# candidate build and before worker launch.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if infrastructure label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_infrastructure() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"infrastructure" "INFRASTRUCTURE_BLOCKED" "infrastructure-check"
}

#######################################
# is_assigned helper: check the hold-for-review unconditional block.
#
# Maintainers use `hold-for-review` to pause automation while they inspect an
# issue or PR. PR auto-merge paths already honour the label; the issue dispatch
# path must treat it as a hard dispatch block too, without overloading
# `needs-maintainer-review` (which is the non-maintainer trust gate).
#
# Mirrors _is_assigned_check_no_auto_dispatch structure:
#   - Same jq-failure fail-closed contract: GUARD_UNCERTAIN on jq error
#   - Same return-code contract: 0 = block (with signal printed), 1 = allow
#   - Same args shape for traceable error output
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if hold-for-review label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_hold_for_review() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"hold-for-review" "HOLD_FOR_REVIEW_BLOCKED" "hold-for-review-check"
}

#######################################
# t3197: is_assigned helper — per-issue dispatch cooldown after launch failure.
#
# When `recover_failed_launch_state` records a `no_worker_process` failure,
# `_post_launch_cooldown_marker` (in pulse-cleanup.sh) writes an audit
# comment containing the marker:
#   <!-- dispatch-cooldown-until:<ISO8601-UTC> reason=no_worker_process runner=<login> -->
#
# This check fetches the issue's comments, finds the latest unexpired
# cooldown marker, and short-circuits dispatch with `DISPATCH_COOLDOWN_ACTIVE`.
# Closes the rapid-retry loop where a broken runtime burns ~5 worker
# spawns over 3-4 hours per issue with 95-99s lifespans each, repeating
# across many issues simultaneously when one runner is unhealthy.
#
# Complementary to:
#   - t2769 (per-issue 3-stack circuit breaker → status:blocked + meta-repair)
#   - t2897 (per-runner health breaker, 10 events / 6h → runner pause)
# This guard is per-issue and short (default 30 min), so it absorbs
# transient runner failures before the longer-horizon breakers fire.
#
# Gating:
#   - Skipped entirely when DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0
#     (saves one gh API call per dispatch decision when the feature is off).
#   - Fail-open on gh API or jq error — cooldown is an optimization, not a
#     security gate, so a flaky API call should not permanently block
#     dispatch the way GUARD_UNCERTAIN does for label/assignee checks.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if active cooldown found (prints DISPATCH_COOLDOWN_ACTIVE),
#          exit 1 if no cooldown / expired / fetch failure / parse failure
#######################################
_is_assigned_check_dispatch_cooldown() {
	local issue_number="$1"
	local repo_slug="$2"

	# Feature gate. 0 disables; any other non-numeric falls back to default.
	local cooldown_s="${DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS:-1800}"
	[[ "$cooldown_s" =~ ^[0-9]+$ ]] || cooldown_s=1800
	[[ "$cooldown_s" -gt 0 ]] || return 1

	# Fetch comments across every page. GitHub's issue comments endpoint returns
	# oldest-first and ignores sort/direction parameters, so select the last
	# matching marker after pagination to use the newest cooldown. Fail-open on API
	# error — cooldown is an optimisation, not a guarantee.
	local comments_endpoint
	comments_endpoint=$(printf 'repos/%s/issues/%s/comments?per_page=100' "$repo_slug" "$issue_number")
	local comments_json
	comments_json=$(gh api --paginate --slurp "$comments_endpoint" 2>/dev/null) || return 1
	[[ -n "$comments_json" ]] || return 1

	# Extract the latest cooldown marker timestamp.
	# `(.body // "")` guards against null bodies; `match` with "g" emits zero
	# results on no-match (no error), so empty bodies and unrelated comments
	# fall through cleanly. Fail-open on jq error.
	local _jq_rc=0
	local marker_iso
	marker_iso=$(printf '%s' "$comments_json" |
		jq -r '[.[][] | (.body // "") | match("<!-- dispatch-cooldown-until:([^ ]+) reason=no_worker_process"; "g") | .captures[0].string] | last // ""') || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		return 1
	fi
	[[ -n "$marker_iso" ]] || return 1

	# Parse ISO8601 → epoch. GNU date first, BSD date fallback for macOS dev.
	local until_epoch=""
	until_epoch=$(date -u -d "$marker_iso" +%s 2>/dev/null) ||
		until_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$marker_iso" +%s 2>/dev/null) ||
		return 1
	[[ "$until_epoch" =~ ^[0-9]+$ ]] || return 1

	local now_epoch
	now_epoch=$(date -u +%s 2>/dev/null) || return 1

	if [[ "$until_epoch" -gt "$now_epoch" ]]; then
		printf 'DISPATCH_COOLDOWN_ACTIVE (until=%s reason=no_worker_process)\n' "$marker_iso"
		return 0
	fi
	return 1
}

#######################################
# Fetch paginated issue comments for orphan-branch checks.
#
# Args: $1 = issue number, $2 = repo slug
# Outputs: JSON from `gh api --paginate --slurp`
# Returns: gh api exit status
#######################################
_ddh_fetch_issue_comments() {
	local issue_number="$1"
	local repo_slug="$2"
	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_endpoint="${comments_post_endpoint}?per_page=100"

	gh api --paginate --slurp "$comments_endpoint" 2>/dev/null
	return $?
}

#######################################
# Count orphan markers matching an exact branch marker prefix.
#
# Args: $1 = comments JSON, $2 = marker prefix
# Outputs: numeric count
# Returns: 0 always (parse failures output 0)
#######################################
_ddh_count_orphan_marker_prefix() {
	local comments_json="$1"
	local orphan_marker_prefix="$2"
	local orphan_marker_count="0"

	orphan_marker_count=$(printf '%s' "$comments_json" |
		jq -r --arg marker "$orphan_marker_prefix" '
			[.[][]
			| (.body // "")
			| select(contains($marker))] | length
		' 2>/dev/null) || orphan_marker_count="0"
	[[ "$orphan_marker_count" =~ ^[0-9]+$ ]] || orphan_marker_count=0
	printf '%s' "$orphan_marker_count"
	return 0
}

#######################################
# Hold an orphan branch when recovery evidence is not actionable.
#
# Args: $1 issue, $2 repo, $3 branch, $4 worktree path, $5 base branch,
#       $6 comments endpoint, $7 comments JSON
# Returns: 0 if dispatch was held, 1 otherwise
#######################################
_ddh_hold_unrecoverable_orphan_branch_if_needed() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local worktree_path="$4"
	local pr_base_branch="$5"
	local comments_post_endpoint="$6"
	local comments_json="$7"
	local branch_state="" state_repo="" remote_probe="" remote_exists="" commit_count=""

	[[ -n "$worktree_path" ]] || return 1
	branch_state=$(_ddh_probe_orphan_branch_state "$repo_slug" "$branch_name" "$worktree_path" "$pr_base_branch")
	IFS='|' read -r state_repo remote_probe remote_exists commit_count <<<"$branch_state"
	: "${state_repo}"

	if [[ "$remote_exists" == "no" ]]; then
		_ddh_hold_unrecoverable_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"remote_branch_missing" "$remote_probe" "$remote_exists" "$commit_count" \
			"$comments_post_endpoint" "$comments_json"
		return 0
	fi
	if [[ "$commit_count" == "0" ]]; then
		if _ddh_auto_recover_zero_commit_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"$remote_probe" "$commit_count" "$comments_post_endpoint" "$comments_json"; then
			return 0
		fi
		_ddh_hold_unrecoverable_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"zero_commits" "$remote_probe" "$remote_exists" "$commit_count" \
			"$comments_post_endpoint" "$comments_json"
		return 0
	fi
	return 1
}

#######################################
# Count recent orphan markers and return the latest timestamp seen.
#
# Args: $1 = comments JSON, $2 = marker prefix, $3 = window seconds
# Outputs: count|latest_iso
# Returns: 0 on parse success, 1 on date/jq failure
#######################################
_ddh_recent_orphan_marker_summary() {
	local comments_json="$1"
	local orphan_marker_prefix="$2"
	local window_s="$3"
	local now_epoch="" marker_list="" count=0 latest_iso="" marker_iso=""

	now_epoch=$(date -u +%s 2>/dev/null) || return 1
	marker_list=$(printf '%s' "$comments_json" |
		jq -r --arg marker "$orphan_marker_prefix" '
			.[][]
			| (.body // "")
			| select(contains($marker))
			| (capture("WORKER_BRANCH_ORPHAN branch=[^ ]+ session=[^ ]+ ts=(?<ts>[^\\n ]+)")? // {})
			| .ts // empty
		' 2>/dev/null) || return 1

	while IFS= read -r marker_iso; do
		[[ -n "$marker_iso" ]] || continue
		local marker_epoch=""
		marker_epoch=$(date -u -d "$marker_iso" +%s 2>/dev/null) ||
			marker_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$marker_iso" +%s 2>/dev/null) ||
			continue
		[[ "$marker_epoch" =~ ^[0-9]+$ ]] || continue
		if [[ $((now_epoch - marker_epoch)) -le "$window_s" ]]; then
			count=$((count + 1))
			latest_iso="$marker_iso"
		fi
	done <<<"$marker_list"

	printf '%s|%s\n' "$count" "$latest_iso"
	return 0
}

#######################################
# Count existing orphan-loop diagnostic blocks for a branch.
#
# Args: $1 = comments JSON, $2 = branch name
# Outputs: numeric count
# Returns: 0 always (parse failures output 0)
#######################################
_ddh_count_orphan_loop_blocks() {
	local comments_json="$1"
	local branch_name="$2"
	local existing_block="0"

	existing_block=$(printf '%s' "$comments_json" |
		jq -r --arg branch "$branch_name" '
			[.[][] | (.body // "") | select(contains("worker-branch-orphan-loop:blocked branch=" + $branch + " "))] | length
		' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0
	printf '%s' "$existing_block"
	return 0
}

#######################################
# Resolve a human PR hint for an orphan branch.
#
# Args: $1 = repo slug, $2 = branch name
# Outputs: PR hint string
# Returns: 0 always
#######################################
_ddh_orphan_branch_pr_hint() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_line=""

	pr_line=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state all \
		--json number,state,url --jq '.[0] | select(.number != null) | "#\(.number) (\(.state)) \(.url)"' 2>/dev/null || true)
	if [[ -n "$pr_line" ]]; then
		printf '%s' "$pr_line"
		return 0
	fi
	printf '%s' "$_DDH_ORPHAN_PR_HINT_NONE"
	return 0
}

#######################################
# Post the repeated-orphan-loop diagnostic comment.
#
# Args: $1 issue, $2 repo, $3 branch, $4 count, $5 window seconds,
#       $6 latest ISO, $7 PR hint, $8 next action, $9 base branch,
#       $10 comments endpoint
# Returns: 0 always
#######################################
_ddh_post_orphan_loop_diagnostic() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local count="$4"
	local window_s="$5"
	local latest_iso="$6"
	local pr_hint="$7"
	local next_action="$8"
	local pr_base_branch="$9"
	local comments_post_endpoint="${10}"
	local diag=""

	# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
	diag=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan-loop:blocked branch=%s issue=%s count=%s window_s=%s -->\n## Dispatch held: repeated worker_branch_orphan\n\nThe dispatch path has seen `%s` `WORKER_BRANCH_ORPHAN` outcomes for issue #%s on branch `%s` within the last %s seconds. Dispatch is held for this same branch to avoid burning more worker attempts while preserving evidence.\n\n- Branch: `%s`\n- Latest orphan marker: `%s`\n- PR for branch: %s\n- Next action: %s\n- Next verification: `gh pr list --repo %s --head %s --state all --json number,state,url`\n\nIf no PR exists and the branch has commits, open the recovery PR against `%s`. If no commits exist to PR, remove/reset that worktree/branch so a fresh branch can dispatch.\n<!-- ops:end -->' \
		"$branch_name" "$issue_number" "$count" "$window_s" \
		"$count" "$issue_number" "$branch_name" "$window_s" \
		"$branch_name" "${latest_iso:-unknown}" "$pr_hint" "$next_action" "$repo_slug" "$branch_name" "$pr_base_branch")
	gh api "$comments_post_endpoint" \
		--method POST \
		--field body="$diag" \
		>/dev/null 2>&1 || true
	return 0
}

#######################################
# Check repeated worker_branch_orphan outcomes for a single issue+branch.
#
# This is a surgical dispatch-loop fuse for the branch-orphan class. The
# headless runtime posts structured WORKER_BRANCH_ORPHAN comments containing
# branch, session, and timestamp. When the same branch hits the threshold within
# the configured window, the dispatch path holds that branch before spawning yet
# another worker and posts one mentor-quality diagnostic comment for triage.
#
# Gating:
#   WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD  default 3, 0 disables
#   WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S   default 7200 seconds
#
# Fail-open on missing branch, gh/jq/date errors, or malformed comments. This is
# a blast-radius limiter, not a security gate; unrelated dispatch should not be
# starved by telemetry read failures.
#
# Args: $1 = issue number, $2 = repo slug, $3 = branch name,
#       $4 = TODO.md path (optional), $5 = worktree path (optional)
# Returns: exit 0 if loop threshold reached (prints ORPHAN_LOOP_BLOCKED),
#          exit 1 otherwise.
#######################################
check_worker_branch_orphan_loop() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local todo_file="${4:-}"
	local worktree_path="${5:-}"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$branch_name" != "HEAD" ]] || return 1

	local threshold="${WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD:-3}"
	local window_s="${WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S:-7200}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
	[[ "$window_s" =~ ^[0-9]+$ ]] || window_s=7200
	[[ "$threshold" -gt 0 && "$window_s" -gt 0 ]] || return 1

	if [[ -n "$todo_file" ]] && check_worker_orphan_remote_children "$issue_number" "$repo_slug" "$todo_file"; then
		return 0
	fi

	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_json=""
	comments_json=$(_ddh_fetch_issue_comments "$issue_number" "$repo_slug") || return 1
	[[ -n "$comments_json" ]] || return 1

	local orphan_marker_prefix="WORKER_BRANCH_ORPHAN branch=${branch_name} "
	local orphan_marker_count="0"
	orphan_marker_count=$(_ddh_count_orphan_marker_prefix "$comments_json" "$orphan_marker_prefix")

	local pr_base_branch=""
	pr_base_branch=$(_ddh_resolve_pr_base_branch "$repo_slug")
	if [[ "$orphan_marker_count" -gt 0 ]] && _ddh_hold_unrecoverable_orphan_branch_if_needed \
		"$issue_number" "$repo_slug" "$branch_name" "$worktree_path" "$pr_base_branch" \
		"$comments_post_endpoint" "$comments_json"; then
		return 0
	fi

	local summary="" count="0" latest_iso=""
	summary=$(_ddh_recent_orphan_marker_summary "$comments_json" "$orphan_marker_prefix" "$window_s") || return 1
	IFS='|' read -r count latest_iso <<<"$summary"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	[[ "$count" -ge "$threshold" ]] || return 1

	local existing_block=""
	existing_block=$(_ddh_count_orphan_loop_blocks "$comments_json" "$branch_name")

	local pr_hint="$_DDH_ORPHAN_PR_HINT_NONE"
	pr_hint=$(_ddh_orphan_branch_pr_hint "$repo_slug" "$branch_name")
	local next_action="Open recovery PR: \`gh pr create --repo ${repo_slug} --head ${branch_name} --base ${pr_base_branch}\`" # aidevops-allow: raw-gh-wrapper
	if [[ "$pr_hint" != "$_DDH_ORPHAN_PR_HINT_NONE" ]]; then
		next_action="Link, review, or merge the existing PR for this branch."
	fi

	if [[ "$existing_block" -eq 0 ]]; then
		_ddh_post_orphan_loop_diagnostic "$issue_number" "$repo_slug" "$branch_name" \
			"$count" "$window_s" "$latest_iso" "$pr_hint" "$next_action" \
			"$pr_base_branch" "$comments_post_endpoint"
	fi

	printf 'WORKER_BRANCH_ORPHAN_LOOP_BLOCKED (issue=%s repo=%s branch=%s count=%s threshold=%s window_s=%s latest=%s pr=%s)\n' \
		"$issue_number" "$repo_slug" "$branch_name" "$count" "$threshold" "$window_s" "${latest_iso:-unknown}" "$pr_hint"
	return 0
}

#######################################
# Hold orphan redispatch when remote child issues exist but local TODO lacks them.
#
# This is intentionally conservative: it does not import issue bodies or trust
# remote relationships. It only detects the dangerous retry state from GH#24565
# and posts one quarantine diagnostic so maintainers can reconcile or import the
# canonical child set before a retry allocates replacement task IDs.
#
# Args: $1 = parent issue number, $2 = repo slug, $3 = TODO.md path (optional)
# Returns: exit 0 if remote children require a hold, exit 1 otherwise.
#######################################
check_worker_orphan_remote_children() {
	local issue_number="$1"
	local repo_slug="$2"
	local todo_file="${3:-TODO.md}"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1

	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_endpoint="${comments_post_endpoint}?per_page=100"
	local comments_json=""
	comments_json=$(gh api --paginate --slurp "$comments_endpoint" 2>/dev/null) || return 1
	[[ -n "$comments_json" ]] || return 1

	local orphan_count="0"
	orphan_count=$(printf '%s' "$comments_json" |
		jq -r '[.[][] | (.body // empty) | select(contains("WORKER_BRANCH_ORPHAN"))] | length' 2>/dev/null) || orphan_count="0"
	[[ "$orphan_count" =~ ^[0-9]+$ ]] || orphan_count=0
	[[ "$orphan_count" -gt 0 ]] || return 1

	local children_json=""
	children_json=$(gh issue list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" \
		--json number,title,body,labels --limit 50 2>/dev/null) || return 1
	[[ -n "$children_json" ]] || return 1

	local candidate_rows=""
	candidate_rows=$(printf '%s' "$children_json" |
		jq -r --arg parent "${issue_number}" '
			.[]
			| select((.number | tostring) != $parent)
			| select(((.body // empty) + "\n" + (.title // empty))
				| test("(#|GH#|issue[[:space:]]+#?)" + $parent + "\\b"; "i"))
			| [.number, (.title // empty)] | @tsv
		' 2>/dev/null) || candidate_rows=""
	[[ -n "$candidate_rows" ]] || return 1

	local missing_count=0
	local candidate_count=0
	local missing_lines=""
	local child_number="" child_title=""
	while IFS=$'\t' read -r child_number child_title; do
		[[ "$child_number" =~ ^[0-9]+$ ]] || continue
		candidate_count=$((candidate_count + 1))
		if [[ ! -f "$todo_file" ]] || ! grep -qE "ref:GH#${child_number}([^0-9]|$)" "$todo_file" 2>/dev/null; then
			missing_count=$((missing_count + 1))
			missing_lines="${missing_lines}- #${child_number}: ${child_title}\n"
		fi
	done <<<"$candidate_rows"

	[[ "$candidate_count" -gt 0 && "$missing_count" -gt 0 ]] || return 1

	local existing_block="0"
	existing_block=$(printf '%s' "$comments_json" |
		jq -r '[.[][] | (.body // empty) | select(contains("worker-orphan-remote-children:blocked"))] | length' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0

	if [[ "$existing_block" -eq 0 ]]; then
		local diag=""
		# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
		diag=$(printf '<!-- ops:start -->\n<!-- worker-orphan-remote-children:blocked issue=%s missing=%s -->\n## Dispatch held: orphaned remote child issues need reconciliation\n\nThis parent has `WORKER_BRANCH_ORPHAN` telemetry and open child-like issues that reference #%s, but local TODO state does not contain `ref:GH#` entries for every candidate. Auto-dispatch is held to avoid allocating replacement task IDs and creating duplicate children.\n\nMissing local refs detected:\n%s\nNext verification:\n- Run `issue-sync pull` or manually reconcile the canonical child set.\n- Validate blocker relationships before trusting recovered issue bodies.\n- Re-run dispatch only after TODO/brief state exists or the duplicates are closed/quarantined.\n<!-- ops:end -->' \
			"$issue_number" "$missing_count" "$issue_number" "$missing_lines")
		gh api "$comments_post_endpoint" \
			--method POST \
			--field body="$diag" \
			>/dev/null 2>&1 || true
	fi

	printf 'WORKER_BRANCH_ORPHAN_REMOTE_CHILDREN_BLOCKED (issue=%s repo=%s candidates=%s missing_local_refs=%s)\n' \
		"$issue_number" "$repo_slug" "$candidate_count" "$missing_count"
	return 0
}

#######################################
# is_assigned helper: cost-per-issue circuit breaker (t2007).
#
# Aggregate token spend across all worker attempts; if the cumulative total
# exceeds the tier-appropriate budget, apply status:blocked and stop dispatch.
# Fail-open on aggregation errors so unrelated GitHub API
# hiccups don't starve the queue. Closes the cost-runaway hole that t1986
# (parent-task guard) and t2008 (stale-recovery escalation) leave open: an
# issue with a correct tier assignment that workers can never finish
# (loop, hidden blocker, scope).
#
# Args: $1 = issue number, $2 = repo slug, $3 = issue metadata JSON
# Returns: exit 0 if budget tripped (prints signal), exit 1 if under budget
#######################################
_is_assigned_check_cost_budget() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json="$3"

	local _t2007_tier
	_t2007_tier=$(printf '%s' "$meta_json" |
		jq -r '[(.labels // [])[].name] | map(select(. != null and startswith("tier:"))) | .[0] // "tier:standard"' 2>/dev/null)
	[[ -z "$_t2007_tier" || "$_t2007_tier" == "null" ]] && _t2007_tier="tier:standard"

	local _t2007_signal _t2007_rc=0
	_t2007_signal=$(_check_cost_budget "$issue_number" "$repo_slug" "$_t2007_tier" "$meta_json") || _t2007_rc=$?
	if [[ "$_t2007_rc" -eq 0 ]]; then
		printf '%s\n' "$_t2007_signal"
		return 0
	fi
	return 1
}

#######################################
# t2436: is_assigned helper — hydration window grace period (Approach B).
#
# Labels applied by the asynchronous issue-sync workflow (issue-sync.yml)
# may not yet be present on an issue that was just created. The window
# between issue creation and the subsequent TODO.md push + workflow run
# is adversarial in multi-runner fleets: a peer runner can see an issue
# missing parent-task (not yet synced) and dispatch a worker on it.
#
# This check adds a configurable grace period (default 30s) during which
# newly created issues are skipped. It is a secondary safety net — the
# primary fix is applying labels synchronously at creation time (see
# _scan_todo_labels_for_task in claim-task-id.sh and
# _gh_wrapper_derive_todo_labels in shared-gh-wrappers.sh).
#
# Fail-open:
#   - If DISPATCH_HYDRATION_WINDOW_S=0, the check is disabled.
#   - If createdAt is absent from meta_json (pre-fetched JSON may lack it),
#     the check returns 1 (allow dispatch to continue).
#   - If date parsing fails on either platform, fail-open.
#
# Env:
#   DISPATCH_HYDRATION_WINDOW_S  grace period in seconds (default 30, 0=off)
#
# Args: $1 = issue metadata JSON (must include createdAt field)
#        $2 = issue number (for log output)
#        $3 = repo slug (for log output)
# Returns: exit 0 (block) if issue is within grace period + prints signal,
#          exit 1 (allow) if old enough or data unavailable
#######################################
_is_assigned_check_hydration_window() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"

	local window="${DISPATCH_HYDRATION_WINDOW_S:-30}"
	[[ "$window" -le 0 ]] && return 1  # disabled

	local created_at _jq_rc=0
	created_at=$(printf '%s' "$meta_json" | jq -r '.createdAt // ""' 2>/dev/null) || _jq_rc=$?
	# Fail-open: missing or unparseable JSON → allow dispatch
	[[ "$_jq_rc" -ne 0 || -z "$created_at" ]] && return 1

	local now_epoch=0 created_epoch=0
	now_epoch=$(date -u '+%s' 2>/dev/null || echo "0")
	# Support both GNU date (-d) and BSD date (-j -f)
	created_epoch=$(date -u -d "$created_at" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%s' 2>/dev/null || echo "0")

	# Fail-open: cannot parse timestamps
	[[ "$now_epoch" -eq 0 || "$created_epoch" -eq 0 ]] && return 1

	local age_s=$(( now_epoch - created_epoch ))
	if [[ "$age_s" -lt "$window" ]]; then
		printf 'HYDRATION_WINDOW (issue=%s repo=%s age=%ss window=%ss — labels may not be synced yet)\n' \
			"$issue_number" "$repo_slug" "$age_s" "$window"
		return 0  # block dispatch
	fi
	return 1  # old enough — allow normal dispatch checks to continue
}

#######################################
# is_assigned helper: compute the blocking assignees set.
#
# Walks the assignees list and filters out:
#   - self_login when there is NO active claim (passive bookkeeping)
#   - owner/maintainer if no active claim state (GH#18352 / t1961)
#
# Owner/maintainer is passive UNLESS _has_active_claim returned "true".
# See _has_active_claim() for the full rule set.
#
# The self_login exemption is intentionally bypassed when active_claim
# is "true". In a single-user setup the interactive user and the pulse
# runner share the same GitHub login. Without this exception the pulse
# skips the assignee (it looks like self) and ignores origin:interactive,
# dispatching a duplicate worker. The exemption exists to prevent a runner
# from blocking its own re-dispatch on a passively-bookmarked issue — that
# use-case has no active claim label, so the guard is still satisfied.
# (GH#18956 incident root cause — fixed in t2091.)
#
# Args:
#   $1 = assignees (comma-separated login list)
#   $2 = repo_owner
#   $3 = repo_maintainer (may be empty)
#   $4 = active_claim ("true" or other)
#   $5 = self_login (may be empty)
# Output: comma-separated list of blocking assignees on stdout (may be empty)
#######################################
_is_assigned_compute_blocking() {
	local assignees="$1"
	local repo_owner="$2"
	local repo_maintainer="$3"
	local active_claim="$4"
	local self_login="$5"

	local -a assignee_array=()
	local saved_ifs="${IFS:-}"
	IFS=',' read -ra assignee_array <<<"$assignees"
	IFS="$saved_ifs"

	local blocking_assignees=""
	local assignee
	for assignee in "${assignee_array[@]}"; do
		# Self-login is passive UNLESS an active claim exists. When active_claim
		# is "true" (status label OR origin:interactive), the assignment is
		# intentional — skip the self-login exemption so the issue blocks
		# re-dispatch even in single-user setups. (t2091)
		if [[ -n "$self_login" && "$assignee" == "$self_login" && "$active_claim" != "true" ]]; then
			continue
		fi

		if [[ "$assignee" == "$repo_owner" || (-n "$repo_maintainer" && "$assignee" == "$repo_maintainer") ]]; then
			# Owner/maintainer is passive UNLESS _has_active_claim returned
			# "true" (GH#18352 / t1961).
			if [[ "$active_claim" != "true" ]]; then
				continue
			fi
		fi

		if [[ -n "$blocking_assignees" ]]; then
			blocking_assignees="${blocking_assignees},${assignee}"
		else
			blocking_assignees="$assignee"
		fi
	done
	printf '%s' "$blocking_assignees"
	return 0
}

#######################################
# Load issue metadata for assignment checks.
#
# Args: $1 = issue number, $2 = repo slug, $3 = gh rc output variable name
# Outputs: issue metadata JSON on stdout when available
# Returns: 0 always; caller inspects the named rc variable
#######################################
_is_assigned_load_issue_meta() {
	local issue_number="$1"
	local repo_slug="$2"
	local rc_var="$3"
	local issue_meta_json=""
	local gh_rc=0

	if [[ -n "${ISSUE_META_JSON:-}" ]] \
		&& printf '%s' "$ISSUE_META_JSON" | jq -e '.assignees and .labels' >/dev/null 2>&1; then
		issue_meta_json="$ISSUE_META_JSON"
	else
		# t2436: include createdAt for the hydration window check (Approach B safety net).
		# Existing callers that pass ISSUE_META_JSON without createdAt will skip that
		# check (fail-open), which is correct — the primary fix is label sync at creation.
		issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state,assignees,labels,createdAt 2>/dev/null) || gh_rc=$?
	fi

	printf -v "$rc_var" '%s' "$gh_rc"
	printf '%s' "$issue_meta_json"
	return 0
}

#######################################
# Extract assignees from issue metadata with explicit jq failure handling.
#
# Args: $1 = issue metadata JSON, $2 = issue number, $3 = repo slug
# Outputs: comma-separated assignee logins, or GUARD_UNCERTAIN on jq failure
# Returns: 0 on extracted assignees, 2 on jq failure
#######################################
_is_assigned_extract_assignees() {
	local issue_meta_json="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local jq_rc=0
	local assignees=""

	assignees=$(printf '%s' "$issue_meta_json" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null) || jq_rc=$?
	if [[ "$jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=assignees-extract issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 2
	fi

	printf '%s' "$assignees"
	return 0
}

#######################################
# Read a peer override/quarantine value for an assignee.
#
# Args: $1 = override config path, $2 = assignee login
# Outputs: override value, if configured
# Returns: 0 always
#######################################
_is_assigned_peer_override_value() {
	local override_conf="$1"
	local assignee="$2"
	local upper=""
	local override_val=""

	# Slug normalisation matches pulse-peer-quarantine-helper.sh's
	# _pq_login_to_var: dash/dot/@ → underscore, uppercase.
	upper="$(printf '%s' "$assignee" | tr 'a-z\-.@' 'A-Z___')"
	override_val=$(grep -E "^DISPATCH_OVERRIDE_${upper}=" "$override_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")
	printf '%s' "$override_val"
	return 0
}

#######################################
# Check whether a peer quarantine override is still active.
#
# Args: $1 = override value, $2 = current epoch seconds
# Returns: 0 when quarantine is active, 1 otherwise
#######################################
_is_assigned_peer_quarantine_active() {
	local override_val="$1"
	local now_epoch="$2"
	local q_until=""
	local q_until_epoch=""

	if [[ "$override_val" != peer-quarantine-until=* ]]; then
		return 1
	fi

	q_until="${override_val#peer-quarantine-until=}"
	# BSD date (macOS) first, then GNU date (Linux). Both variants succeed;
	# one returns empty, and the OR keeps going.
	q_until_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$q_until" '+%s' 2>/dev/null || true)
	[[ -z "$q_until_epoch" ]] && q_until_epoch=$(date -u -d "$q_until" '+%s' 2>/dev/null || true)
	[[ -z "$q_until_epoch" ]] && q_until_epoch=0

	if [[ "$q_until_epoch" -gt "$now_epoch" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Append an assignee to a comma-separated list.
#
# Args: $1 = current list, $2 = assignee login
# Outputs: updated comma-separated list
# Returns: 0 always
#######################################
_is_assigned_append_assignee() {
	local current_list="$1"
	local assignee="$2"

	if [[ -n "$current_list" ]]; then
		printf '%s,%s' "$current_list" "$assignee"
	else
		printf '%s' "$assignee"
	fi
	return 0
}

#######################################
# Filter ignored/quarantined peer assignees from the blocking set.
#
# Args: $1 = assignees, $2 = self login
# Outputs: filtered comma-separated assignee logins
# Returns: 0 always
#######################################
_is_assigned_filter_override_assignees() {
	local assignees="$1"
	local self_login="$2"
	local override_conf="${HOME}/.config/aidevops/dispatch-override.conf"
	local filtered_assignees=""
	local saved_ifs="${IFS:-}"
	local -a override_array=()
	local assignee=""
	local override_val=""
	local now_epoch=""

	if [[ ! -f "$override_conf" ]]; then
		printf '%s' "$assignees"
		return 0
	fi

	now_epoch=$(date -u '+%s')
	IFS=',' read -ra override_array <<<"$assignees"
	IFS="$saved_ifs"
	for assignee in "${override_array[@]}"; do
		# Overrides and quarantine are peer-only. The current runner's own
		# assignment remains authoritative so a worker never ignores its own
		# in-flight claim state because its login appears in local override config.
		if [[ -n "$self_login" && "$assignee" == "$self_login" ]]; then
			filtered_assignees=$(_is_assigned_append_assignee "$filtered_assignees" "$assignee")
			continue
		fi

		override_val=$(_is_assigned_peer_override_value "$override_conf" "$assignee")
		[[ "$override_val" == "ignore" ]] && continue
		if _is_assigned_peer_quarantine_active "$override_val" "$now_epoch"; then
			continue
		fi
		filtered_assignees=$(_is_assigned_append_assignee "$filtered_assignees" "$assignee")
	done

	printf '%s' "$filtered_assignees"
	return 0
}

#######################################
# Run assignment guard checks that block before assignee interpretation.
#
# Args: $1 = issue metadata JSON, $2 = issue number, $3 = repo slug
# Returns: 0 when a guard blocked and emitted its signal, 1 otherwise
#######################################
_is_assigned_pre_assignee_guard_blocks() {
	local issue_meta_json="$1"
	local issue_number="$2"
	local repo_slug="$3"

	# Parent-task, pending publication, and no-auto-dispatch are unconditional blocks.
	if _is_assigned_check_parent_task "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_publication_pending "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_no_auto_dispatch "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_maintainer_permissions "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	# Advisory/review/cooldown/cost/hydration gates short-circuit before assignees.
	if _is_assigned_check_infrastructure "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_hold_for_review "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_dispatch_cooldown "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_cost_budget "$issue_number" "$repo_slug" "$issue_meta_json"; then
		return 0
	fi
	if _is_assigned_check_hydration_window "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	return 1
}

_is_assigned_impl() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"
	local allow_stale_recovery="${4:-1}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		# Missing args — cannot check, allow dispatch
		return 1
	fi

	# Validate issue number is numeric
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	local issue_meta_json gh_rc=0
	issue_meta_json=$(_is_assigned_load_issue_meta "$issue_number" "$repo_slug" gh_rc)

	# t2046: fail-closed on gh API failure. When we cannot fetch issue metadata
	# (network error, auth failure, rate limit, issue not found), we cannot
	# determine whether dispatch is safe. Block and emit GUARD_UNCERTAIN so the
	# pulse skips this cycle rather than dispatching blindly.
	if [[ "$gh_rc" -ne 0 || -z "$issue_meta_json" ]]; then
		printf 'GUARD_UNCERTAIN (reason=gh-api-failure issue=%s repo=%s rc=%s)\n' \
			"$issue_number" "$repo_slug" "$gh_rc"
		return 0
	fi

	if _is_assigned_pre_assignee_guard_blocks "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	local assignees=""
	if ! assignees=$(_is_assigned_extract_assignees "$issue_meta_json" "$issue_number" "$repo_slug"); then
		printf '%s\n' "$assignees"
		return 0
	fi

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi

	assignees=$(_is_assigned_filter_override_assignees "$assignees" "$self_login")
	if [[ -z "$assignees" ]]; then
		return 1
	fi

	local repo_owner repo_maintainer
	repo_owner=$(_get_repo_owner "$repo_slug")
	repo_maintainer=$(_get_repo_maintainer "$repo_slug")
	# GH#18352 / t1961: owner/maintainer assignees are passive unless
	# _has_active_claim() reports an active lifecycle label (queued,
	# in-progress, in-review, claimed) or origin:interactive is present.
	# See _has_active_claim() above for the full rule set.
	# t2061: explicit helper rc capture — fail-closed.
	# _has_active_claim normalises output to "true"/"false" and always exits 0,
	# but explicit capture documents the contract and protects against future changes.
	local _hac_rc=0
	local active_claim
	active_claim=$(_has_active_claim "$issue_meta_json") || _hac_rc=$?
	if [[ "$_hac_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=helper-failure call=_has_active_claim issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi

	local blocking_assignees
	blocking_assignees=$(_is_assigned_compute_blocking \
		"$assignees" "$repo_owner" "$repo_maintainer" "$active_claim" "$self_login")

	if [[ -z "$blocking_assignees" ]]; then
		# Only passive assignees remain (self and/or owner/maintainer without
		# active claim state) — safe to dispatch.
		return 1
	fi

	# Stale assignment recovery (GH#15060): if the blocking assignee has no
	# active worker process AND the most recent dispatch/claim comment is >1h
	# old AND there's been no progress (no new comments) in the last hour,
	# treat the assignment as abandoned. Unassign the stale user, remove
	# queued/in-progress labels, and allow re-dispatch.
	#
	# Root cause: when a runner goes offline or a worker crashes without
	# cleanup, the issue stays assigned to that runner forever. The dedup
	# guard blocks all other runners from dispatching for it, creating a
	# permanent deadlock where 0 workers run despite available slots and
	# open issues. This was observed in production with 370 issues and 0
	# active workers — 100% dispatch failure rate.
	if [[ "$allow_stale_recovery" == "1" ]] \
		&& _is_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees"; then
		return 1
	fi

	printf 'ASSIGNED: issue #%s in %s is assigned to %s\n' "$issue_number" "$repo_slug" "$blocking_assignees"
	return 0
}

#######################################
# Dispatch assignment guard with stale recovery enabled.
# Args: $1 = issue number, $2 = repo slug, $3 = self login (optional)
# Returns: 0 when blocked, 1 when safe to dispatch
#######################################
is_assigned() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"

	_is_assigned_impl "$issue_number" "$repo_slug" "$self_login" 1
	return $?
}

#######################################
# Read-only assignment guard for inspection-only callers such as enrichment.
# Reuses all fail-closed and active-claim logic but never invokes stale recovery.
# Args: $1 = issue number, $2 = repo slug, $3 = self login (optional)
# Returns: 0 when blocked, 1 when no assignment/guard block exists
#######################################
is_assigned_read_only() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"

	_is_assigned_impl "$issue_number" "$repo_slug" "$self_login" 0
	return $?
}

#######################################
# enumerate_blockers — report ALL structural dispatch blockers for an issue.
#
# Unlike is_assigned() which short-circuits on the first match, this function
# runs every unconditional structural check (parent-task, pending publication,
# no-auto-dispatch, infrastructure, hold-for-review)
# and emits ALL matching signals as newline-separated tokens on stdout.
#
# Intentionally excludes cost-budget, hydration window, and assignee checks —
# those have nuanced interactive UX that the caller handles separately.
# GUARD_UNCERTAIN is emitted when the gh API call fails (fail-closed).
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = self_login (optional, reserved for future extension)
#
# Stdout: newline-separated blocker tokens; empty when no structural blockers.
# Returns:
#   0 — at least one blocker token was emitted
#   1 — no structural blockers found (safe to dispatch for label-based checks)
#
# t2894: used by _check_linked_issue_gate in full-loop-helper.sh to surface
# ALL label-based blockers in a single pass rather than stopping at the first.
#######################################
enumerate_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	# self_login reserved for future extension — not used by structural checks
	# local self_login="${3:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 1
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	# Re-use pre-fetched JSON when the caller has already loaded issue metadata.
	local issue_meta_json gh_rc=0
	if [[ -n "${ISSUE_META_JSON:-}" ]] \
		&& printf '%s' "$ISSUE_META_JSON" | jq -e '.assignees and .labels' >/dev/null 2>&1; then
		issue_meta_json="$ISSUE_META_JSON"
	else
		issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state,assignees,labels,createdAt 2>/dev/null) || gh_rc=$?
	fi

	if [[ "$gh_rc" -ne 0 || -z "$issue_meta_json" ]]; then
		printf 'GUARD_UNCERTAIN (reason=gh-api-failure issue=%s repo=%s rc=%s)\n' \
			"$issue_number" "$repo_slug" "$gh_rc"
		return 0
	fi

	local _found=false
	local _blocker_out

	# Check 1: parent-task / meta unconditional block (t1986).
	_blocker_out=$(_is_assigned_check_parent_task "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 2: canonical planning publication has not landed.
	_blocker_out=$(_is_assigned_check_publication_pending "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 3: no-auto-dispatch unconditional block (t2832).
	_blocker_out=$(_is_assigned_check_no_auto_dispatch "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 4: request-specific signed worker permission hold.
	_blocker_out=$(_is_assigned_check_maintainer_permissions "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 5: infrastructure advisory/operator block.
	_blocker_out=$(_is_assigned_check_infrastructure "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 6: hold-for-review unconditional maintainer hold.
	_blocker_out=$(_is_assigned_check_hold_for_review "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 7: t3197 dispatch cooldown after no_worker_process launch failure.
	_blocker_out=$(_is_assigned_check_dispatch_cooldown "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	if [[ "$_found" == "true" ]]; then
		return 0
	fi
	return 1
}

# PR evidence dedup check functions are in dispatch-dedup-pr.sh (GH#18916).

#######################################
# Check whether a single dispatch comment is still active.
#
# Local process absence is not completion evidence: the same GitHub login can
# dispatch from another device. Durable terminal comments or a matching lease
# transition retire the lock early; otherwise the extended worker TTL applies.
#
# Args:
#   $1 = comment created_at (ISO 8601)
#   $2 = comment author login
#   $3 = issue number (for process search)
#   $4 = now_epoch (seconds since epoch)
#   $5 = max_age (seconds)
#   $6 = self login (retained for backward-compatible callers)
# Returns: exit 0 if comment is active (blocks dispatch), exit 1 if stale/expired
# Outputs: reason string on stdout when active
#
# t2061 audit (2026-04-14):
#
# Error path classification for _is_dispatch_comment_active:
#
#   empty created_at ($1):
#     → [[ -z "$created_at" ]] → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: no timestamp = no comment to evaluate.
#
#   date parsing failure (both GNU and macOS date variants fail):
#     → comment_epoch set to "0" (printf '0' fallback in the || chain)
#     → age = now_epoch - 0 = very large number → age >= max_age → return 1
#     → FAIL-OPEN INTENTIONAL: unreadable timestamp cannot prove recency.
#       Defaulting to "expired" avoids permanently blocking dispatch on
#       malformed or unrecognised timestamp formats. The TTL design
#       (default 10 min) means blocks are always temporary; unreadable
#       timestamps should not create permanent blocks.
#
#   No jq calls in this function. jq is used in the calling function
#   has_dispatch_comment() which handles its own jq failures with || fallbacks.
#   See has_dispatch_comment() for its error handling.
#
# Summary: this function is a pure TTL-comparison check on a single comment.
# Fail-open on timestamp parse failures is appropriate because: (a) TTLs are
# already conservative (10 min), (b) permanent blocks from bad timestamps
# cause deadlock, and (c) this is a secondary guard — is_assigned() is the
# primary cross-machine dedup guard with GUARD_UNCERTAIN fail-closed behavior.
# ALREADY CONFIRMED FAIL-OPEN BY DESIGN — no hardening needed (t2061).
#######################################
_is_dispatch_comment_active() {
	local created_at="$1"
	local author="$2"
	local issue_number="$3"
	local now_epoch="$4"
	local max_age="$5"
	# $6 is intentionally unused: local process state cannot disprove a remote
	# worker owned by the same GitHub login.
	local active_worker_max_age="${DISPATCH_ACTIVE_WORKER_MAX_AGE:-7200}"
	[[ "$active_worker_max_age" =~ ^[0-9]+$ ]] || active_worker_max_age=7200

	[[ -z "$created_at" ]] && return 1

	local comment_epoch
	comment_epoch=$(date -u -d "$created_at" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%s' 2>/dev/null ||
		printf '%s' "0")
	local age=$((now_epoch - comment_epoch))

	# GH#22356: the soft dispatch-comment TTL is only the normal claim window.
	# A deterministic dispatch comment with no later terminal marker still means
	# a worker may be live on another runner. Keep blocking until the extended
	# non-terminal worker window expires; after that, a later claim path can emit
	# an explicit stale-worker takeover reason instead of a bare DISPATCH_CLAIM.
	if [[ "$age" -ge "$max_age" ]]; then
		if [[ "$age" -lt "$active_worker_max_age" ]]; then
			printf 'non-terminal dispatch comment by %s posted %ds ago on issue #%s (soft TTL expired; active-worker window: %ds remaining)\n' \
				"$author" "$age" "$issue_number" "$((active_worker_max_age - age))"
			return 0
		fi
		return 1
	fi

	printf 'dispatch comment by %s posted %ds ago on issue #%s (TTL: %ds remaining)\n' \
		"$author" "$age" "$issue_number" "$((max_age - age))"
	return 0
}

#######################################
# Check whether an issue has a recent "Dispatching worker" comment (GH#11141).
#
# The pulse agent posts a "Dispatching worker" comment on every issue
# it dispatches. This is a persistent, cross-machine signal that a
# worker is in-flight — unlike the dispatch ledger (local-only) or
# the claim lock (8-second window). Checking for this comment catches
# the gap between dispatch and PR creation across machines.
#
# GH#17503: This is now the PRIMARY dedup guard. Dispatch comments are
# never deleted (audit trail). A dispatch comment blocks re-dispatch for
# DISPATCH_COMMENT_MAX_AGE seconds (default 600 = 10 min). After that,
# the comment stays for audit but no longer blocks — allowing a fresh
# dispatch attempt.
#
# A completion or failure comment posted by a trusted repository actor AFTER
# the dispatch comment cancels the lock early — the worker is done and
# re-dispatch is safe. Untrusted issue commenters cannot mutate dispatch state.
# Recognised completion signals: "TASK_COMPLETE", "FULL_LOOP_COMPLETE",
# "Worker failed", "Worker Watchdog Kill", "BLOCKED",
# "Stale assignment recovered", "Kill signal sent", "gh pr merge",
# "Closes #", "MERGE_SUMMARY", "CLAIM_RELEASED".
#
# No active-claim-state gate (removed GH#17503) — the dispatch comment
# itself IS the claim. Labels and assignees are secondary signals.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = self login (unused; kept for backward compatibility — GH#15317)
# Returns:
#   exit 0 if a recent dispatch comment exists (do NOT dispatch)
#   exit 1 if no recent dispatch comment or superseded by completion (safe to dispatch)
# Outputs:
#   single-line reason when evidence is found
#######################################

#######################################
# t3194: Opportunistic peer-quarantine event detection. Pipes already-
# fetched comments JSON to pulse-peer-quarantine-helper.sh's scan-comments
# subcommand to record any
# `CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=<peer>`
# events from peers (not self). Zero new API calls; non-fatal on any
# failure. Extracted from has_dispatch_comment to keep that function below
# the function-complexity gate.
# Args:
#   $1 = comments JSON (already fetched in caller)
#   $2 = repo slug (owner/repo)
#   $3 = issue number
#   $4 = self login (optional; used to skip self events)
#######################################
_dd_opportunistic_peer_scan() {
	local comments_json="$1"
	local repo_slug="$2"
	local issue_number="$3"
	local self_login="${4:-}"
	local pq_helper=""
	pq_helper="${PEER_QUARANTINE_HELPER_OVERRIDE:-${HELPER_DIR:-${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}}/pulse-peer-quarantine-helper.sh}"
	[[ -x "$pq_helper" ]] || return 0
	if [[ -n "$self_login" ]]; then
		printf '%s' "$comments_json" | "$pq_helper" scan-comments \
			--self-login "$self_login" \
			--issue-ref "${repo_slug}#${issue_number}" \
			>/dev/null 2>&1 || true
	else
		printf '%s' "$comments_json" | "$pq_helper" scan-comments \
			--issue-ref "${repo_slug}#${issue_number}" \
			>/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Fetch every issue-comment page and keep only comments posted by repository
# actors trusted to mutate dispatch coordination state. GitHub supplies
# author_association; issue-body text cannot forge it.
# Args: issue number, repo slug
# Returns: normalized JSON on stdout, 1 on fetch or parse failure
#######################################
_dd_fetch_trusted_issue_comments() {
	local issue_number="$1"
	local repo_slug="$2"
	local raw_comments=""

	raw_comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$raw_comments" | jq -c '
		def trusted_association:
			. == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";
		[ (
			if (type == "array" and ((.[0]? | type) == "array")) then
				.[]
			else
				.
			end
		)[]
		| {
			id: .id,
			body: (.body // ""),
			body_start: ((.body // "")[:300]),
			author: .user.login,
			author_association: (.author_association // ""),
			created_at: .created_at
		}
		| select((.author_association // "") | trusted_association)]
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Check for a cryptographically-unpredictable lease token whose terminal
# transition matches the trusted dispatch author, original claim author,
# device, and session. Correlated markers bind directly to the exact claim and
# may be retired by terminal state on either side of the delayed audit write.
# Legacy markers retain strict claim-before/terminal-after ordering.
#
# Args: comments JSON, dispatch timestamp, dispatch comment ID, dispatch author,
#       dispatch comment body
# Returns: 0 when a matching terminal lease supersedes dispatch; 1 otherwise
#######################################
_dd_has_matching_terminal_lease() {
	local comments_json="$1"
	local dispatch_created_at="$2"
	local dispatch_id="$3"
	local dispatch_author="$4"
	local dispatch_body="${5:-}"
	local lease_filter="${SCRIPT_DIR}/dispatch-lease-claims.jq"
	local claims_json="[]"
	local parsed_claims="[]"
	local now_epoch=""

	[[ -r "$lease_filter" && -n "$dispatch_created_at" && -n "$dispatch_author" ]] || return 1
	[[ "$dispatch_id" =~ ^[0-9]+$ ]] || dispatch_id=0
	claims_json=$(printf '%s' "$comments_json" | jq -c \
		'[.[] | select((.body // "") | contains("DISPATCH_CLAIM nonce="))]' \
		2>/dev/null) || return 1
	[[ "$claims_json" != "[]" ]] || return 1
	now_epoch=$(date -u '+%s')
	parsed_claims=$(printf '%s\n%s\n' "$claims_json" "$comments_json" | jq -nc \
		--argjson now "$now_epoch" --argjson max_age 2147483647 \
		--argjson include_terminal true \
		-f "$lease_filter" 2>/dev/null) || return 1

	local marker_json=""
	marker_json=$(printf '%s' "$dispatch_body" | jq -Rrc '
		try capture("aidevops:dispatch lease_token=(?<lease_token>[^ ]+) device=(?<device>[^ ]+) session=(?<session>[^ ]+) attempt_id=(?<attempt_id>[^ ]+) claim_id=(?<claim_id>[0-9]+)")
		catch empty
	' 2>/dev/null) || marker_json=""
	if [[ -n "$marker_json" ]] && printf '%s' "$parsed_claims" | jq -e \
		--argjson marker "$marker_json" --arg dispatch_author "$dispatch_author" '
		any(.[];
			.lease_phase == "terminal" and
			.claim_author == $dispatch_author and
			.lease_token == $marker.lease_token and
			.device == $marker.device and
			.session == $marker.session and
			.lease_terminal_attempt_id == $marker.attempt_id and
			((.id // 0) | tostring) == $marker.claim_id
		)' >/dev/null 2>&1; then
		return 0
	fi

	if printf '%s' "$parsed_claims" | jq -e \
		--arg dispatch_ts "$dispatch_created_at" --argjson dispatch_id "$dispatch_id" \
		--arg dispatch_author "$dispatch_author" '
		any(.[];
			.lease_phase == "terminal" and
			.claim_author == $dispatch_author and
			[.created_at, ((.id // 0) | tonumber? // 0)] <= [$dispatch_ts, $dispatch_id] and
			[.lease_terminal_at, (.lease_terminal_id // 0)] > [$dispatch_ts, $dispatch_id]
		)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Check for trusted completion evidence ordered after a dispatch comment.
#
# Args: comments JSON, dispatch timestamp, dispatch comment ID
# Returns: 0 when trusted completion evidence supersedes dispatch; 1 otherwise
#######################################
_dd_has_trusted_completion_after_dispatch() {
	local comments_json="$1"
	local dispatch_created_at="$2"
	local dispatch_id="$3"

	[[ -n "$dispatch_created_at" ]] || return 1
	[[ "$dispatch_id" =~ ^[0-9]+$ ]] || dispatch_id=0
	if printf '%s' "$comments_json" | jq -e \
		--arg dispatch_ts "$dispatch_created_at" --argjson dispatch_id "$dispatch_id" '
		any(.[];
			[.created_at, ((.id // 0) | tonumber? // 0)] > [$dispatch_ts, $dispatch_id] and (
				(.body_start | test("TASK_COMPLETE"; "i")) or
				(.body_start | test("FULL_LOOP_COMPLETE"; "i")) or
				(.body_start | test("Worker failed"; "i")) or
				(.body_start | test("Worker Watchdog Kill"; "i")) or
				(.body_start | test("BLOCKED"; "i")) or
				(.body_start | test("Kill signal sent"; "i")) or
				(.body_start | test("Closes #"; "i")) or
				(.body_start | test("gh pr merge"; "i")) or
				(.body_start | test("MERGE_SUMMARY"; "i")) or
				(.body_start | test("Stale assignment recovered"; "i")) or
				(.body_start | test("CLAIM_RELEASED"; "i"))
			)
		)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

has_dispatch_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	# $3 = self_login — unused since GH#15317 (trusted dispatch comments from
	# every repository actor are checked regardless of author identity)

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# GH#17503: No active-claim-state gate — dispatch comment IS the claim.
	# Active-claim pre-gate was removed: it required OPEN + assigned +
	# status:queued/in-progress, but stale recovery could destroy that state and
	# bypass this check entirely.

	local max_age="${DISPATCH_COMMENT_MAX_AGE:-600}" # 10 min (was 30 min/1800s — reduced to match worker lifecycle; crash recovery was wasting 28 min per crash)
	local now_epoch
	now_epoch=$(date -u '+%s')

	# Fetch every comment page because fresh dispatch and terminal evidence on a
	# long-running issue can be absent from GitHub's oldest-first default page.
	local comments_json
	comments_json=$(_dd_fetch_trusted_issue_comments "$issue_number" "$repo_slug") || comments_json="[]"

	if [[ -z "$comments_json" || "$comments_json" == "null" || "$comments_json" == "[]" ]]; then
		return 1
	fi

	# t3194: Opportunistic peer-quarantine event detection — extracted to
	# _dd_opportunistic_peer_scan to keep this function below the
	# function-complexity gate. Zero new API calls; non-fatal.
	_dd_opportunistic_peer_scan "$comments_json" "$repo_slug" "$issue_number" "${3:-}" || true

	# Find the most recent dispatch comment (newest first)
	local last_dispatch_json
	last_dispatch_json=$(printf '%s' "$comments_json" | jq -c '
		[.[]
		| select((.body_start // "") | test("(^|\\n)Dispatching worker"))]
		| sort_by(.created_at, ((.id // 0) | tonumber? // 0)) | reverse | first // empty
	' 2>/dev/null) || last_dispatch_json=""

	if [[ -z "$last_dispatch_json" || "$last_dispatch_json" == "null" ]]; then
		return 1
	fi

	local dispatch_created_at dispatch_author dispatch_id dispatch_body
	dispatch_created_at=$(printf '%s' "$last_dispatch_json" | jq -r '.created_at // ""' 2>/dev/null) || dispatch_created_at=""
	dispatch_author=$(printf '%s' "$last_dispatch_json" | jq -r '.author // ""' 2>/dev/null) || dispatch_author=""
	dispatch_id=$(printf '%s' "$last_dispatch_json" | jq -r '.id // 0' 2>/dev/null) || dispatch_id=0
	dispatch_body=$(printf '%s' "$last_dispatch_json" | jq -r '.body // ""' 2>/dev/null) || dispatch_body=""
	[[ "$dispatch_id" =~ ^[0-9]+$ ]] || dispatch_id=0

	# Check if the dispatch comment is within TTL
	if ! _is_dispatch_comment_active "$dispatch_created_at" "$dispatch_author" "$issue_number" "$now_epoch" "$max_age" "${3:-}"; then
		return 1
	fi

	# A CLAIM_RELEASED write can fail after the worker has already emitted its
	# structured terminal lease transition. Reconcile that authenticated
	# transition as equivalent durable completion evidence (GH#28437).
	if _dd_has_matching_terminal_lease "$comments_json" "$dispatch_created_at" "$dispatch_id" "$dispatch_author" "$dispatch_body"; then
		return 1
	fi

	# GH#17503: trusted completion/failure evidence posted after dispatch retires
	# the lock early; untrusted issue comments cannot mutate coordination state.
	if _dd_has_trusted_completion_after_dispatch "$comments_json" "$dispatch_created_at" "$dispatch_id"; then
		# Worker completed or failed — dispatch comment superseded, safe to re-dispatch
		return 1
	fi

	# Dispatch comment is active and not superseded — block re-dispatch
	return 0
}

#######################################
# Validate subcommand arg count. Used by main() to collapse the repeated
# "[[ $# -lt N ]] && { echo Error; return 1; }" pattern into a single call.
# Args:
#   $1 = subcommand name (for error message)
#   $2 = required arg count
#   $3 = provided arg count (typically "$#")
#   $4 = usage hint (e.g., "<issue-number> <repo-slug>")
# Returns: 0 if enough args, 1 otherwise (and prints error to stderr)
#######################################
_require_args() {
	local cmd="$1"
	local required="$2"
	local provided="$3"
	local usage="$4"
	if [[ "$provided" -lt "$required" ]]; then
		echo "Error: ${cmd} requires ${usage}" >&2
		return 1
	fi
	return 0
}

#######################################
# t3077 — has_fix_the_fixer_label
#
# Read-only check: does the issue carry the `fix-the-fixer` label
# (applied by pulse-fix-the-fixer-detector.sh)? Used by the dispatch
# path (headless-runtime-helper.sh) to enable extra observability for
# tasks that touch the worker dispatch system itself.
#
# Args:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Output (stdout): "labeled" or "unlabeled" (always one of these)
# Returns: 0 if labeled, 1 if unlabeled OR on API failure (fail-conservative)
#######################################
has_fix_the_fixer_label() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		printf 'unlabeled\n'
		return 1
	fi
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		printf 'unlabeled\n'
		return 1
	fi

	local meta_json
	meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json labels 2>/dev/null) || meta_json=""
	if [[ -z "$meta_json" ]]; then
		printf 'unlabeled\n'
		return 1
	fi

	# Use numeric match-count rather than a boolean string token —
	# the codebase ratchet flags repeated boolean-token literals.
	local match_count
	match_count=$(printf '%s' "$meta_json" | \
		jq -r '[.labels[] | select(.name == "fix-the-fixer")] | length' 2>/dev/null) || match_count="0"
	[[ "$match_count" =~ ^[0-9]+$ ]] || match_count="0"

	if [[ "$match_count" -gt 0 ]]; then
		printf 'labeled\n'
		return 0
	fi
	printf 'unlabeled\n'
	return 1
}

#######################################
# Classify a dispatch dedup/pre-launch blocker into a stable low-cardinality
# metric reason.
#
# Args:
#   $1 = lower-case blocker signal text
# Output: one dispatch_candidate_failed reason token when matched
#######################################
_classify_structural_dispatch_blocker_reason() {
	local lower_signal="$1"
	case "$lower_signal" in
		*footprint_overlap* | *footprint*overlap*)
			printf 'footprint_overlap\n'
			return 0
			;;
		*blocked_by_unresolved* | *blocked-by-unresolved* | *blocked*by*unresolved* | *unresolved*blocked-by* | *unresolved*blocked*by*)
			printf 'blocked_by_unresolved\n'
			return 0
			;;
		*issue_closed* | *issue*closed* | *state=closed* | *state*closed*)
			printf 'issue_closed\n'
			return 0
			;;
		*consolidated*)
			printf 'consolidated\n'
			return 0
			;;
		*parent_task_blocked* | *parent-task* | *label=meta*)
			printf 'parent_task\n'
			return 0
			;;
		*publication_pending_blocked* | *publication:pending*)
			printf 'publication_pending\n'
			return 0
			;;
		*infrastructure_blocked* | *label=infrastructure* | *hold_for_review_blocked* | *hold-for-review* | *external*author*gate* | *nmr*gate* | *approval*required*)
			printf 'policy_gate\n'
			return 0
			;;
		*no_auto_dispatch_blocked* | *no-auto-dispatch*)
			printf 'no_auto_dispatch\n'
			return 0
			;;
	esac
	return 1
}

#######################################
# Classify a dispatch dedup/pre-launch blocker into a stable low-cardinality
# metric reason.
#
# Args:
#   $1 = blocker signal text emitted by dispatch-dedup-helper or pulse logs
# Output: one of the dispatch_candidate_failed reason tokens
#######################################
classify_dispatch_blocker_reason() {
	local signal="$1"
	local lower_signal
	lower_signal=$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')
	if _classify_structural_dispatch_blocker_reason "$lower_signal"; then
		return 0
	fi

	case "$lower_signal" in
		*interactive_review_hold* | *interactive*review*hold*)
			printf 'interactive_review_hold\n'
			return 0
			;;
		*pr_target_not_dispatchable* | *pull*request*not*a*dispatchable*issue* | *target*is*a*pull*request*)
			printf 'pr_target_not_dispatchable\n'
			return 0
			;;
		*cost_budget_exceeded*)
			printf 'cost_budget_exceeded\n'
			return 0
			;;
		*dispatch_cooldown_active* | *reason=no_worker_process* | *no_worker_process*)
			printf 'cooldown_no_worker_process\n'
			return 0
			;;
		*graphql*circuit* | *circuit_broken* | *graphql*budget*below*)
			printf 'graphql_circuit_breaker\n'
			return 0
			;;
		*runner-health*circuit* | *runner_health*circuit*)
			printf 'runner_health_circuit_breaker\n'
			return 0
			;;
		*dispatch_block_reason*ever_nmr_without_approval* | *blocked*ever*nmr*lacks*approval* | *requires*cryptographic*approval*)
			printf 'ever_nmr_without_approval\n'
			return 0
			;;
		*blocked_by_native_lookup_unavailable* | *native*blocked*by*lookup*unavailable*)
			printf 'blocked_by_native_lookup_unavailable\n'
			return 0
			;;
		*canary*failed*)
			printf 'canary_failed\n'
			return 0
			;;
		*launch*error* | *launch*validation*failed* | *per-candidate*timeout*)
			printf 'launch_error\n'
			return 0
			;;
		*missing*worker*context* | *needs-brief* | *missing*implementation*context*)
			printf 'missing_worker_context\n'
			return 0
			;;
		*renovate*dependency*dashboard*)
			printf 'renovate_dependency_dashboard\n'
			return 0
			;;
		*local*capacity*gate* | *worktree*cap* | *max*worktree* | *disk*space* | *large*file*)
			printf 'local_capacity_gate\n'
			return 0
			;;
		*dedup*guard*blocked*)
			printf 'dedup_active_claim\n'
			return 0
			;;
		*assigned* | *claim* | *ledger* | *has-open-pr* | *pr*evidence* | *duplicate* | *stale_recovered*)
			printf 'dedup_active_claim\n'
			return 0
			;;
		"")
			printf 'no_recent_log_evidence\n'
			return 0
			;;
	esac

	printf 'unclassified_signal\n'
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-dedup-helper.sh - Normalize and deduplicate worker dispatch titles (t2310)

Usage:
  dispatch-dedup-helper.sh extract-keys <title>    Extract dedup keys from a title
  dispatch-dedup-helper.sh is-duplicate <title>     Check if already running (exit 0=dup, 1=safe)
  dispatch-dedup-helper.sh has-open-pr <issue> <slug> [issue-title]
                                                    Check merged PR evidence (exit 0=evidence, 1=none)
  dispatch-dedup-helper.sh has-dispatch-comment <issue> <slug> [self-login]
                                                     Check for recent "Dispatching worker" comment (exit 0=found, 1=none)
  dispatch-dedup-helper.sh is-assigned <issue> <slug> [self-login]
                                                       Check if assigned to another login (exit 0=blocked, 1=free)
  dispatch-dedup-helper.sh is-assigned-read-only <issue> <slug> [self-login]  Inspect without recovery writes
  dispatch-dedup-helper.sh enumerate-blockers <issue> <slug> [runner]
                                                       Report ALL structural label blockers (exit 0=blocked, 1=none)
                                                        Emits newline-separated tokens: PARENT_TASK_BLOCKED, NO_AUTO_DISPATCH_BLOCKED,
                                                        GUARD_UNCERTAIN. Unlike is-assigned,
                                                       does not short-circuit on first match. t2894.
  dispatch-dedup-helper.sh classify-blocker <signal>
                                                       Classify a blocker signal into a stable metric reason.
  dispatch-dedup-helper.sh check-cost-budget <issue> <slug> [tier]
                                                       t2007: cost circuit breaker (exit 0=tripped, 1=under budget)
  dispatch-dedup-helper.sh sum-issue-token-spend <issue> <slug>
                                                       t2007: aggregate token spend (returns "spent|attempts")
  dispatch-dedup-helper.sh check-orphan-loop <issue> <slug> <branch> [todo-file] [worktree-path]
                                                       Hold repeated worker_branch_orphan loops or unreconciled remote children
  dispatch-dedup-helper.sh check-recovery-loop <issue> <slug>
                                                       Hold repeated worker recovery failures across branches before posting a new claim
  dispatch-dedup-helper.sh has-fix-the-fixer-label <issue> <slug>
                                                       t3077: detect the fix-the-fixer label (exit 0=labeled, 1=unlabeled).
                                                       Used by headless-runtime-helper.sh to enable verbose lifecycle,
                                                       tighter watchdog, and a preflight sentinel for dispatch-path workers.
  dispatch-dedup-helper.sh claim <issue> <slug> [runner-login]
                                                     Cross-machine claim lock (exit 0=won, 1=lost, 2=error)
  dispatch-dedup-helper.sh list-running-keys        List keys for all running workers
  dispatch-dedup-helper.sh normalize <title>        Normalize a title for comparison
  dispatch-dedup-helper.sh help                     Show this help
Examples:
  # Extract keys from various title formats
  dispatch-dedup-helper.sh extract-keys "Issue #2300: t1337 Simplify infra scripts"
  # Output: issue-2300
  #         task-t1337

  # Check before dispatching (local process dedup)
  if dispatch-dedup-helper.sh is-duplicate "Issue #2300: Fix auth"; then
    echo "Already running — skip dispatch"
  else
    echo "Safe to dispatch"
  fi

  # Check before dispatching (cross-machine assignee dedup — GH#11141)
  # Blocks if assigned to any login other than self
  if dispatch-dedup-helper.sh is-assigned 2300 owner/repo mylogin; then
    echo "Assigned to another login — skip dispatch"
  else
    echo "Unassigned or assigned to self — safe"
  fi

  # Check before dispatching (dispatch comment dedup — GH#11141)
  if dispatch-dedup-helper.sh has-dispatch-comment 2300 owner/repo mylogin; then
    echo "Another runner already dispatched — skip"
  else
    echo "No recent dispatch comment — safe"
  fi

  # Check before dispatching (merged PR dedup)
  if dispatch-dedup-helper.sh has-open-pr 2300 owner/repo "t2300: Fix auth"; then
    echo "Issue already has merged PR evidence — skip dispatch"
  else
    echo "No merged PR evidence — safe to dispatch"
  fi

  # Check before launching a worker on a reused branch-orphan worktree
  if dispatch-dedup-helper.sh check-orphan-loop 2300 owner/repo feature/auto-20260501-000000-gh2300; then
    echo "Repeated worker_branch_orphan on this branch — hold dispatch"
  else
    echo "No branch-orphan loop — safe to dispatch"
  fi

  # Check before claim/comment creation for repeated recovery failures across branches
  if dispatch-dedup-helper.sh check-recovery-loop 2300 owner/repo; then
    echo "Repeated worker recovery failures — hold dispatch"
  fi

  # Report ALL structural label blockers in one pass (t2894)
  while IFS= read -r blocker; do
    echo "Blocker: $blocker"
  done < <(dispatch-dedup-helper.sh enumerate-blockers 2300 owner/repo)

  # Cross-machine claim lock (t1686)
  if dispatch-dedup-helper.sh claim 2300 owner/repo mylogin; then
    echo "Claim won — safe to dispatch"
    # ... dispatch worker ...
    # Claim comment persists as audit trail
  else
    echo "Claim lost or error — skip dispatch"
  fi
HELP
	return 0
}

_ddh_main_simple_command() {
	local command_name="$1"
	shift || true
	case "$command_name" in
	extract-keys)
		_require_args extract-keys 1 "$#" "a title argument" || return 1
		local title="$1"
		extract_keys "$title"
		return $?
		;;
	is-duplicate)
		_require_args is-duplicate 1 "$#" "a title argument" || return 1
		local duplicate_title="$1"
		is_duplicate "$duplicate_title"
		return $?
		;;
	classify-blocker)
		_require_args classify-blocker 1 "$#" "a blocker signal" || return 1
		local blocker_signal="$1"
		classify_dispatch_blocker_reason "$blocker_signal"
		return $?
		;;
	list-running-keys)
		list_running_keys
		return $?
		;;
	normalize)
		_require_args normalize 1 "$#" "a title argument" || return 1
		local normalized_title="$1"
		normalize_title "$normalized_title"
		return $?
		;;
	*)
		return 2
		;;
	esac
}

_ddh_main_issue_command() {
	local command_name="$1"
	local assignment_usage="<issue-number> <repo-slug> [self-login]"
	shift || true
	case "$command_name" in
	is-assigned)
		_require_args is-assigned 2 "$#" "$assignment_usage" || return 1
		local assigned_issue="$1" assigned_repo="$2" assigned_runner="${3:-}"
		is_assigned "$assigned_issue" "$assigned_repo" "$assigned_runner"
		return $?
		;;
	is-assigned-read-only)
		_require_args is-assigned-read-only 2 "$#" "$assignment_usage" || return 1
		local readonly_issue="$1" readonly_repo="$2" readonly_runner="${3:-}"
		is_assigned_read_only "$readonly_issue" "$readonly_repo" "$readonly_runner"
		return $?
		;;
	enumerate-blockers)
		_require_args enumerate-blockers 2 "$#" "<issue-number> <repo-slug> [runner]" || return 1
		local blocker_issue="$1" blocker_repo="$2" blocker_runner="${3:-}"
		enumerate_blockers "$blocker_issue" "$blocker_repo" "$blocker_runner"
		return $?
		;;
	check-cost-budget)
		_require_args check-cost-budget 2 "$#" "<issue-number> <repo-slug> [tier]" || return 1
		local cost_issue="$1" cost_repo="$2" cost_tier="${3:-standard}"
		_check_cost_budget "$cost_issue" "$cost_repo" "$cost_tier"
		return $?
		;;
	sum-issue-token-spend)
		_require_args sum-issue-token-spend 2 "$#" "<issue-number> <repo-slug>" || return 1
		local spend_issue="$1" spend_repo="$2"
		_sum_issue_token_spend "$spend_issue" "$spend_repo"
		return $?
		;;
	has-dispatch-comment)
		_require_args has-dispatch-comment 2 "$#" "<issue-number> <repo-slug> [self-login]" || return 1
		local comment_issue="$1" comment_repo="$2" comment_runner="${3:-}"
		has_dispatch_comment "$comment_issue" "$comment_repo" "$comment_runner"
		return $?
		;;
	has-open-pr)
		_require_args has-open-pr 2 "$#" "<issue-number> <repo-slug> [issue-title]" || return 1
		local pr_issue="$1" pr_repo="$2" pr_title="${3:-}"
		has_open_pr "$pr_issue" "$pr_repo" "$pr_title"
		return $?
		;;
	*)
		return 2
		;;
	esac
}

_ddh_main_loop_command() {
	local command_name="$1"
	shift || true
	case "$command_name" in
	check-orphan-loop)
		_require_args check-orphan-loop 3 "$#" "<issue-number> <repo-slug> <branch> [todo-file] [worktree-path]" || return 1
		local orphan_issue="$1" orphan_repo="$2" orphan_branch="$3" orphan_todo="${4:-}" orphan_worktree="${5:-}"
		check_worker_branch_orphan_loop "$orphan_issue" "$orphan_repo" "$orphan_branch" "$orphan_todo" "$orphan_worktree"
		return $?
		;;
	check-recovery-loop)
		_require_args check-recovery-loop 2 "$#" "issue-number repo-slug" || return 1
		local recovery_issue="$1" recovery_repo="$2"
		check_worker_recovery_failure_loop "$recovery_issue" "$recovery_repo"
		return $?
		;;
	test-recover)
		_require_args test-recover 4 "$#" "<issue> <repo> <assignees> <reason>" || return 1
		local recover_issue="$1" recover_repo="$2" recover_assignees="$3" recover_reason="$4"
		_recover_stale_assignment "$recover_issue" "$recover_repo" "$recover_assignees" "$recover_reason"
		return $?
		;;
	has-fix-the-fixer-label)
		_require_args has-fix-the-fixer-label 2 "$#" "<issue> <slug>" || return 1
		local fixer_issue="$1" fixer_repo="$2"
		has_fix_the_fixer_label "$fixer_issue" "$fixer_repo"
		return $?
		;;
	*)
		return 2
		;;
	esac
}

_ddh_main_claim_command() {
	local command_name="$1"
	shift || true
	case "$command_name" in
	claim)
		_require_args claim 2 "$#" "<issue-number> <repo-slug> [runner-login]" || return 1
		if [[ ! -x "$CLAIM_HELPER" ]]; then
			printf 'Error: dispatch-claim-helper.sh not found at %s\n' "$CLAIM_HELPER" >&2
			return 2
		fi
		local claim_issue="$1" claim_repo="$2" claim_runner="${3:-}"
		local claim_guard_output="" claim_guard_rc=0
		claim_guard_output=$(is_assigned "$claim_issue" "$claim_repo" "$claim_runner" 2>&1) || claim_guard_rc=$?
		case "$claim_guard_rc" in
		0)
			printf 'CLAIM_BLOCKED: active_assignment issue=#%s repo=%s runner=%s signal=%s\n' \
				"$claim_issue" "$claim_repo" "$claim_runner" "$claim_guard_output"
			return 1
			;;
		1) ;;
		*)
			printf 'CLAIM_BLOCKED: assignment_guard_error issue=#%s repo=%s runner=%s rc=%s signal=%s\n' \
				"$claim_issue" "$claim_repo" "$claim_runner" "$claim_guard_rc" "$claim_guard_output"
			return 1
			;;
		esac
		DISPATCH_CLAIM_ASSIGNMENT_GUARD=false "$CLAIM_HELPER" claim "$claim_issue" "$claim_repo" "$claim_runner"
		return $?
		;;
	check-claim)
		_require_args check-claim 2 "$#" "<issue-number> <repo-slug>" || return 1
		if [[ ! -x "$CLAIM_HELPER" ]]; then
			printf 'Error: dispatch-claim-helper.sh not found at %s\n' "$CLAIM_HELPER" >&2
			return 2
		fi
		local check_issue="$1" check_repo="$2"
		"$CLAIM_HELPER" check "$check_issue" "$check_repo"
		return $?
		;;
	*)
		return 2
		;;
	esac
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	extract-keys | is-duplicate | classify-blocker | list-running-keys | normalize)
		_ddh_main_simple_command "$command" "$@"
		return $?
		;;
	is-assigned | is-assigned-read-only | enumerate-blockers | check-cost-budget | sum-issue-token-spend | has-dispatch-comment | has-open-pr)
		_ddh_main_issue_command "$command" "$@"
		return $?
		;;
	check-orphan-loop | check-recovery-loop | test-recover | has-fix-the-fixer-label)
		_ddh_main_loop_command "$command" "$@"
		return $?
		;;
	claim | check-claim)
		_ddh_main_claim_command "$command" "$@"
		return $?
		;;
	help | --help | -h)
		show_help
		return 0
		;;
	*)
		printf 'Error: Unknown command: %s\n' "$command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
