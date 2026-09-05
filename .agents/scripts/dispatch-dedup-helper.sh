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

# Live interactive ownership is stronger than GitHub-visible activity age.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/interactive-claim-fence.sh"

# GH#18917: cost circuit breaker extracted to keep this file below 2000 lines.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-cost.sh"

# Shared strict GitHub closing-clause parser for stale PR routing.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pr-closing-link-lib.sh"

# GH#18916: stale assignment recovery subsystem extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-stale.sh"

# GH#30937: assignment and orphan dispatch guards extracted.
# shellcheck source=./dispatch-dedup-assignment.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/dispatch-dedup-assignment.sh"

# GH#18916: PR evidence dedup checks extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-pr.sh"

# Issue-level worker recovery loop fuse.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-recovery-loop.sh"

# Cross-runner hold for repeated unchanged terminal worker blockers.
# shellcheck source=terminal-blocker-circuit.sh
source "${SCRIPT_DIR}/terminal-blocker-circuit.sh"

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
	# aidevops:trust-boundary — an explicit generation never falls back to
	# timestamp-only or prose evidence, including when its marker is malformed.
	if [[ "$dispatch_body" == *"aidevops:dispatch"* ]]; then
		[[ -n "$marker_json" ]] || return 1
		if printf '%s' "$parsed_claims" | jq -e \
			--argjson marker "$marker_json" --arg dispatch_author "$dispatch_author" '
			any(.[];
				.lease_phase == "terminal" and
				.claim_author == $dispatch_author and
				.lease_token == $marker.lease_token and
				.device == $marker.device and
				.session == $marker.session and
				(.lease_terminal_attempt_id == $marker.attempt_id or .lease_terminal_attempt_id == "release") and
				((.id // 0) | tostring) == $marker.claim_id
			)' >/dev/null 2>&1; then
			return 0
		fi
		return 1
	fi

	if printf '%s' "$parsed_claims" | jq -e \
		--arg dispatch_ts "$dispatch_created_at" --argjson dispatch_id "$dispatch_id" \
		--arg dispatch_author "$dispatch_author" '
		map(select(
			.claim_author == $dispatch_author and
			[.created_at, ((.id // 0) | tonumber? // 0)] <= [$dispatch_ts, $dispatch_id]))
		| sort_by([.created_at, ((.id // 0) | tonumber? // 0)]) | last
		| .lease_phase == "terminal" and
			[.lease_terminal_at, (.lease_terminal_id // 0)] > [$dispatch_ts, $dispatch_id]
		' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Preserve historical prose completion only for streams without claim identity.
#
# Args: comments JSON, dispatch timestamp, dispatch ID, author, body
# Returns: 0 when trusted completion evidence supersedes dispatch; 1 otherwise
#######################################
_dd_has_trusted_completion_after_dispatch() {
	local comments_json="$1"
	local dispatch_created_at="$2"
	local dispatch_id="$3"
	local dispatch_author="${4:-}"
	local dispatch_body="${5:-}"

	[[ -n "$dispatch_created_at" && -n "$dispatch_author" ]] || return 1
	[[ "$dispatch_body" != *"aidevops:dispatch"* ]] || return 1
	[[ "$dispatch_id" =~ ^[0-9]+$ ]] || dispatch_id=0
	# aidevops:trust-boundary — once a stream has claim generations, unbound
	# completion prose cannot retire one of them, even from the same login.
	if printf '%s' "$comments_json" | jq -e \
		--arg dispatch_ts "$dispatch_created_at" --argjson dispatch_id "$dispatch_id" \
		--arg author "$dispatch_author" '
		(any(.[]; (.body // "") | test("(^|[[:space:]])DISPATCH_CLAIM[[:space:]]+nonce="; "i")) | not) and
		any(.[];
			.author == $author and
			(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") and
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
	if terminal_blocker_circuit_active "$comments_json" "${ISSUE_META_JSON:-}" \
		"$repo_slug" "$issue_number" "${DISPATCH_REPO_PATH:-}"; then
		return 0
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
	if _dd_has_trusted_completion_after_dispatch "$comments_json" "$dispatch_created_at" "$dispatch_id" "$dispatch_author" "$dispatch_body"; then
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
		*terminal_blocker_circuit*)
			printf 'terminal_blocker_circuit\n'
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
		*pr_lookup_uncertain* | *pr_lookup_result=uncertain*)
			printf 'pr_lookup_uncertain\n'
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
		*worker*already*running* | *live_worker=true* | *process_evidence=live*)
			printf 'dedup_active_claim_live_owner\n'
			return 0
			;;
		*stale_recovered* | *stale_owner=true*)
			printf 'dedup_active_claim_stale_owner\n'
			return 0
			;;
		*no*dispatch*claim* | *attempt_count=0* | *zero_attempt*)
			printf 'dedup_active_claim_zero_attempt\n'
			return 0
			;;
		*current*pulse*cycle* | *current_cycle=true*)
			printf 'dedup_active_claim_current_cycle\n'
			return 0
			;;
		*in-flight*ledger* | *has-open-pr* | *pr*evidence* | *dispatch*comment*)
			printf 'dedup_active_claim_durable_launch\n'
			return 0
			;;
		*dedup*guard*blocked* | *assigned* | *claim* | *ledger* | *duplicate*)
			printf 'dedup_active_claim_unverified\n'
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
