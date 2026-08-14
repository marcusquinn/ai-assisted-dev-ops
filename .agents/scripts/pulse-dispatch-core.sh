#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-core.sh — Core worker dispatch primitives — dedup check, issue lock/unlock + linked PR lock, impl-commit detection, main-commit check, large-file gate, dispatch_with_dedup orchestrator + helpers, terminal blocker matching.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Functions in this module (in source order):
#   - _resolve_worker_tier
#   - has_worker_for_repo_issue
#   - check_dispatch_dedup
#   - lock_issue_for_worker
#   - _lock_linked_prs
#   - unlock_issue_after_worker
#   - _unlock_linked_prs
#   - _count_impl_commits
#   - _task_id_in_recent_commits
#   - _task_id_in_merged_pr
#   - _task_id_in_changed_files
#   - _check_nmr_approval_gate
#   - _check_commit_subject_dedup_gate
#   - _has_force_dispatch_label
#   - _has_publication_pending_label
#   - _is_bot_generated_cleanup_issue
#   - _is_task_committed_to_main
#   - _dispatch_target_is_pull_request
#   - _is_renovate_dependency_dashboard_issue
#   - _dispatch_waiting_for_maintainer_permission
#   - _dispatch_permission_history_requires_grant
#   - _dispatch_has_interactive_hold
#   - _dispatch_registered_worktree_count
#   - _dispatch_run_guarded_worktree_cleanup
#   - _dispatch_cleanup_worktree_capacity
#   - _dispatch_worktree_capacity_gate
#   - _dispatch_dedup_check_layers  (t1999: extracted from dispatch_with_dedup)
#   - dispatch_with_dedup           (t1999: thin orchestrator, <80 lines)
#   - _ensure_issue_body_has_brief
#   - _match_terminal_blocker_pattern
#   - _apply_terminal_blocker
#   - check_terminal_blockers
#
# Extracted sub-modules (sourced below):
#   - pulse-dispatch-dedup-layers.sh    — 7-layer dedup chain + stale classifier
#   - pulse-dispatch-large-file-gate.sh — large-file simplification gate
#   - pulse-dispatch-worker-launch.sh   — worker launch helpers + orchestrator
#   - dispatch-dedup-footprint.sh       — file-footprint overlap throttle (t2117)
#   - pre-dispatch-eligibility-helper.sh — generic eligibility gate: CLOSED, status:done, recent-merge (t2424)
#   - pulse-stats-helper.sh             — operational counters: pre_dispatch_aborts_24h (t2424)
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Phase 12 post-gate simplification: _is_task_committed_to_main split into
# _task_id_in_recent_commits, _task_id_in_merged_pr, _task_id_in_changed_files
# (t2004). Phase 12 (t1999): dispatch_with_dedup split into decision helper
# (_dispatch_dedup_check_layers) + action helper (_dispatch_launch_worker)
# + thin orchestrator. External signature of dispatch_with_dedup unchanged.
# GH#18832: extracted dedup layers, large-file gate, and worker launch helpers
# into sub-modules to bring this file below the 2000-line simplification gate.

[[ -n "${_PULSE_DISPATCH_CORE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CORE_LOADED=1
_PULSE_DISPATCH_FALSE="false"
_PULSE_DISPATCH_ELIGIBILITY_STAGE="eligibility_gate"
_PULSE_DISPATCH_NMR_LABEL="needs-maintainer-review"
_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION="COLLABORATOR"

# t2863: Module-level variable defaults (set -u guards).
# Ensures LOGFILE is safe to dereference in all functions when this module
# is sourced outside the pulse-wrapper.sh bootstrap context.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# shellcheck source=disk-capacity-lib.sh
source "${BASH_SOURCE[0]%/*}/disk-capacity-lib.sh"

# Extracted modules — sourced in load order.
# shellcheck source=pulse-dispatch-dedup-layers.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-dedup-layers.sh"
# shellcheck source=pulse-dispatch-large-file-gate.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-large-file-gate.sh"
# shellcheck source=pulse-dispatch-worker-launch.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-worker-launch.sh"
# t2117/GH#19109: file-footprint overlap throttle
# shellcheck source=dispatch-dedup-footprint.sh
source "${BASH_SOURCE[0]%/*}/dispatch-dedup-footprint.sh"
# t2424/GH#20030: generic pre-dispatch eligibility gate (CLOSED, status:done, recent-merge)
# shellcheck source=pre-dispatch-eligibility-helper.sh
source "${BASH_SOURCE[0]%/*}/pre-dispatch-eligibility-helper.sh"
# t2424/GH#20030: pulse operational counters (pre_dispatch_aborts_24h)
# shellcheck source=pulse-stats-helper.sh
source "${BASH_SOURCE[0]%/*}/pulse-stats-helper.sh"
# t3034: per-stage dispatch ceremony timing instrumentation
# shellcheck source=dispatch-stage-instrument.sh
source "${BASH_SOURCE[0]%/*}/dispatch-stage-instrument.sh"
if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	source "${BASH_SOURCE[0]%/*}/shared-gh-collaborator-permission.sh"
fi

#######################################
# Resolve the worker tier from issue labels. When multiple tier:* labels
# are present (collision — see t1997), pick the highest rank order.
# Fallback: tier:standard if no tier label is present.
# Arguments:
#   $1 - comma-separated label list (e.g., "bug,tier:simple,auto-dispatch")
# Output:
#   tier:thinking, tier:standard, or tier:simple
# Exit codes:
#   0 - always succeeds
#######################################
_resolve_worker_tier() {
	local labels_csv="$1"
	# Convert to lowercase for case-insensitive matching (Bash 3.2 compatible)
	local labels_lower
	labels_lower=$(printf '%s' "$labels_csv" | tr '[:upper:]' '[:lower:]')
	local labels_with_commas=",${labels_lower},"

	if [[ "$labels_with_commas" == *",tier:thinking,"* ]]; then
		printf 'tier:thinking'
	elif [[ "$labels_with_commas" == *",tier:standard,"* ]]; then
		printf 'tier:standard'
	elif [[ "$labels_with_commas" == *",tier:simple,"* ]]; then
		printf 'tier:simple'
	else
		printf 'tier:standard' # default when no tier label present
	fi
	return 0
}

#######################################
# Check if a worker exists for a specific repo+issue pair
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
# Exit codes:
#   0 - matching worker exists
#   1 - no matching worker
#######################################
has_worker_for_repo_issue() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local repo_path
	repo_path=$(get_repo_path_by_slug "$repo_slug")

	local worker_lines
	worker_lines=$(list_active_worker_processes) || worker_lines=""

	# Primary match: repo path + issue number in command line.
	# Requires get_repo_path_by_slug to return a non-empty path.
	if [[ -n "$repo_path" ]]; then
		local matches
		matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" -v path="$repo_path" '
			BEGIN {
				esc = path
				gsub(/[][(){}.^$*+?|\\]/, "\\\\&", esc)
			}
			$0 ~ ("--dir[[:space:]]+" esc "([[:space:]]|$)") &&
			($0 ~ ("issue-" issue "([^0-9]|$)") || $0 ~ ("Issue #" issue "([^0-9]|$)")) { count++ }
			END { print count + 0 }
		') || matches=0
		[[ "$matches" =~ ^[0-9]+$ ]] || matches=0
		if [[ "$matches" -gt 0 ]]; then
			return 0
		fi
	fi

	# Fallback: match by session-key alone (GH#6453).
	# When get_repo_path_by_slug returns empty (slug not in repos.json,
	# path mismatch, or repos.json unavailable), the primary match above
	# always returns 0 matches — a false-negative that causes the backfill
	# cycle to re-dispatch already-running workers.
	# The session-key "issue-<number>" is always present in the command line
	# of workers dispatched via headless-runtime-helper.sh run --session-key.
	# This fallback catches those workers regardless of path resolution.
	local sk_matches
	sk_matches=$(printf '%s\n' "$worker_lines" | awk -v issue="$issue_number" '
		$0 ~ ("--session-key[[:space:]]+issue-" issue "([^0-9]|$)") { count++ }
		END { print count + 0 }
	') || sk_matches=0
	[[ "$sk_matches" =~ ^[0-9]+$ ]] || sk_matches=0
	if [[ "$sk_matches" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Thin orchestrator — runs read-only dedup layers in order.
# Byte-for-byte behavioural equivalent of the pre-GH#18654 single-function
# implementation. Layers return 0 to block or 1 to continue; Layer 4 returns 2
# only for a worker draft that must reach stale-assignment recovery first.
# The optimistic GitHub claim lock runs after the worker canary preflight in
# _dispatch_launch_worker so a broken local runtime does not publish noisy
# DISPATCH_CLAIM comments when no worker can start.
#######################################
check_dispatch_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"

	_dedup_layer1_ledger_check "$issue_number" "$repo_slug" && return 0
	_dedup_layer2_process_match "$issue_number" "$repo_slug" && return 0
	_dedup_layer3_title_match "$title" && return 0
	local _pr_evidence_rc=0
	_dedup_layer4_pr_evidence "$issue_number" "$repo_slug" "$issue_title" || _pr_evidence_rc=$?
	if [[ "$_pr_evidence_rc" -eq 0 ]]; then
		return 0
	fi
	# A verified worker-owned draft is still a hard duplicate-dispatch block,
	# but its assignment may need the existing stale-checkpoint transition.
	# Unknown Layer 4 outcomes fail closed rather than weakening PR protection.
	if [[ "$_pr_evidence_rc" -ne 1 && "$_pr_evidence_rc" -ne 2 ]]; then
		return 0
	fi
	# Active dispatch comments and assignment/claim guards are expected
	# cross-runner locks, not launch failures. Preserve the block while giving
	# dispatch_max a distinct benign rc so the stage wrapper suppresses generic
	# "Stage failed" noise and refill loops can skip this candidate for the
	# current pulse cycle (GH#23541).
	_dedup_layer5_dispatch_comment "$issue_number" "$repo_slug" "$self_login" && return 3
	_dedup_layer6_assignee_and_stale "$issue_number" "$repo_slug" "$self_login" && return 3
	[[ "$_pr_evidence_rc" -eq 2 ]] && return 0

	return 1
}

#######################################
# Verify an issue conversation lock after GitHub accepts the lock mutation.
# The issue REST read can briefly lag the mutation, so retry boundedly while
# preserving the fail-closed trust boundary.
#
# Args:
#   $1 = issue number
#   $2 = repository slug
# Returns:
#   0 when a read confirms locked=true, 1 after bounded exhaustion
#######################################
_verify_issue_conversation_lock() {
	local issue_num="$1"
	local slug="$2"
	local attempts="${AIDEVOPS_CONVERSATION_LOCK_VERIFY_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_CONVERSATION_LOCK_VERIFY_DELAY:-2}"
	local attempt=1
	local locked_state=""

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$attempts" -le 3 ]] || attempts=3
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=2
	[[ "$retry_delay" -le 5 ]] || retry_delay=2

	while [[ "$attempt" -le "$attempts" ]]; do
		locked_state=$(gh api "repos/${slug}/issues/${issue_num}" --jq '.locked == true' 2>/dev/null) || locked_state=""
		if [[ "$locked_state" == "true" ]]; then
			return 0
		fi
		if [[ "$attempt" -lt "$attempts" ]]; then
			sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done

	return 1
}

#######################################
# Lock an issue (and any linked PRs) to prevent prompt injection
# (t1894, t1934, GH#30180). Auto-dispatch is the authorization boundary,
# so the issue must be frozen before it enters worker-readable context.
# Also locks open PRs linked to the issue (worker may read PR comments).
# The issue lock is strict and verified; linked PR locks remain best-effort.
#######################################
lock_issue_for_worker() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	# aidevops:trust-boundary — never launch a worker when the mutable public
	# instruction surface could not be frozen and independently re-read.
	local lock_applied=0
	if ! gh issue lock "$issue_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1; then
		if ! _verify_issue_conversation_lock "$issue_num" "$slug"; then
			echo "[pulse-wrapper] Failed to verify conversation lock for #${issue_num} in ${slug}; dispatch remains blocked (GH#30180)" >>"$LOGFILE"
			return 1
		fi
		echo "[pulse-wrapper] Reused existing verified conversation lock for #${issue_num} in ${slug} (GH#30180)" >>"$LOGFILE"
	else
		lock_applied=1
	fi
	if [[ "$lock_applied" -eq 1 ]] && ! _verify_issue_conversation_lock "$issue_num" "$slug"; then
		echo "[pulse-wrapper] Failed to verify conversation lock for #${issue_num} in ${slug}; dispatch remains blocked (GH#30180)" >>"$LOGFILE"
		return 1
	fi
	_record_auto_dispatch_lock "$issue_num" "$slug" || return 1
	echo "[pulse-wrapper] Locked #${issue_num} in ${slug} during worker execution (t1934)" >>"$LOGFILE"

	# Lock any open PRs linked to this issue (t1934: PRs have same injection surface)
	_lock_linked_prs "$issue_num" "$slug" "$reason"

	return 0
}

_auto_dispatch_lock_marker() {
	local issue_num="$1"
	local slug="$2"
	local lock_dir="${AIDEVOPS_AUTO_DISPATCH_LOCK_DIR:-${HOME}/.aidevops/cache/auto-dispatch-locks}"
	local lock_key="${slug//\//--}-${issue_num}"
	printf '%s/%s\n' "$lock_dir" "$lock_key"
	return 0
}

_record_auto_dispatch_lock() {
	local issue_num="$1"
	local slug="$2"
	local marker=""
	marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || return 1
	mkdir -p "${marker%/*}" 2>/dev/null || return 1
	: >"$marker" 2>/dev/null || return 1
	return 0
}

#######################################
# Reconcile conversation locks for every visible auto-dispatch issue,
# including blocked and queued work that cannot reach the launch path yet.
# Only markers owned by this mechanism may trigger an unlock.
#######################################
reconcile_auto_dispatch_issue_locks() {
	local slug="$1"
	local issue_json="$2"
	local issue_num="" marker="" labels="" labels_csv=""
	[[ -n "$slug" && -n "$issue_json" ]] || return 1

	while IFS=$'\t' read -r issue_num labels; do
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
		marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || continue
		labels_csv=",${labels},"
		if [[ "$labels_csv" == *,auto-dispatch,* && "$labels_csv" != *,no-auto-dispatch,* ]]; then
			lock_issue_for_worker "$issue_num" "$slug" || return 1
		elif [[ -f "$marker" && "$labels_csv" != *,no-auto-dispatch,* ]]; then
			gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || return 1
			rm -f "$marker" 2>/dev/null || return 1
			echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after auto-dispatch removal (GH#30180)" >>"$LOGFILE"
		fi
	done < <(printf '%s' "$issue_json" | jq -r '.[] | [(.number | tostring), ([.labels[]? | .name? // .] | join(","))] | @tsv' 2>/dev/null)

	return 0
}

#######################################
# Lock open PRs that reference a given issue number (t1934).
# Finds PRs whose title contains the issue number pattern
# (e.g., "GH#123" or "#123") and locks their conversations.
# Non-fatal: best-effort, failures are logged but ignored.
#######################################
_lock_linked_prs() {
	local issue_num="$1"
	local slug="$2"
	local reason="${3:-resolved}"

	local pr_numbers
	pr_numbers=$(gh_pr_list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh pr lock "$pr_num" --repo "$slug" --reason "$reason" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Locked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# Release conversation locks after terminal worker handling only when the issue
# is no longer auto-dispatch eligible. Retryable work stays frozen across the
# worker-to-Pulse handoff, closing the post-worker comment race (GH#30180).
#######################################
unlock_issue_after_worker() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	local labels=""
	if ! labels=$(gh api "repos/${slug}/issues/${issue_num}" --jq '[.labels[]? | .name] | join(",")' 2>/dev/null); then
		echo "[pulse-wrapper] Could not verify labels before unlocking #${issue_num} in ${slug}; retaining conversation lock (GH#30180)" >>"$LOGFILE"
		return 1
	fi
	# aidevops:trust-boundary — auto-dispatch remains authoritative across
	# retries, so completion cleanup must not reopen its instruction surface.
	if [[ ",$labels," == *,auto-dispatch,* && ",$labels," != *,no-auto-dispatch,* ]]; then
		echo "[pulse-wrapper] Retained conversation lock for auto-dispatch #${issue_num} in ${slug} after worker handoff (GH#30180)" >>"$LOGFILE"
		return 0
	fi

	gh issue unlock "$issue_num" --repo "$slug" >/dev/null 2>&1 || true
	local marker=""
	marker=$(_auto_dispatch_lock_marker "$issue_num" "$slug") || marker=""
	[[ -z "$marker" ]] || rm -f "$marker" 2>/dev/null || true
	echo "[pulse-wrapper] Unlocked #${issue_num} in ${slug} after worker completion (t1934)" >>"$LOGFILE"

	# Unlock any open PRs linked to this issue (symmetric with lock)
	_unlock_linked_prs "$issue_num" "$slug"

	return 0
}

#######################################
# Unlock open PRs that reference a given issue number (t1934).
# Symmetric with _lock_linked_prs. Non-fatal.
#######################################
_unlock_linked_prs() {
	local issue_num="$1"
	local slug="$2"

	local pr_numbers
	pr_numbers=$(gh_pr_list --repo "$slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_num}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh pr unlock "$pr_num" --repo "$slug" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Unlocked PR #${pr_num} in ${slug} (linked to issue #${issue_num}) (t1934)" >>"$LOGFILE"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# GH#17779: Helper for _is_task_committed_to_main.
# Reads commit hashes from stdin, applies the two-stage planning filter
# (subject-line prefix + path-based), and prints the count of real
# implementation commits to stdout.
#
# Planning-only path allowlist (t2379, GH#19863):
#   - TODO.md / todo/**           — task entries and briefs
#   - AGENTS.md / .agents/AGENTS.md — agent guides
#   - docs/** / */docs/**         — documentation
#   - .task-counter               — CAS counter file touched by
#                                   claim-task-id.sh on every ID allocation.
#                                   Without this, a planning PR that
#                                   touches TODO.md + brief + .task-counter
#                                   is misclassified as implementation and
#                                   permanently blocks future dispatch via
#                                   the main-commit dedup false positive
#                                   (GH#17574). Root cause of the t2366
#                                   r914 task getting stuck after its
#                                   plan-filing PR #19819 merged.
#
# Args:
#   $1 - repo_path (local path to the repo)
# Stdin: one commit hash per line
#######################################
_count_impl_commits() {
	local repo_path_inner="$1"
	local match_count_inner=0
	local commit_hash_inner
	while IFS= read -r commit_hash_inner; do
		[[ -z "$commit_hash_inner" ]] && continue
		local is_planning_only_inner=true
		local touched_path_inner
		while IFS= read -r touched_path_inner; do
			[[ -z "$touched_path_inner" ]] && continue
			case "$touched_path_inner" in
			TODO.md | todo/* | AGENTS.md | .agents/AGENTS.md | */docs/* | docs/* | .task-counter) ;;
			*)
				is_planning_only_inner=false
				break
				;;
			esac
		done < <(git -C "$repo_path_inner" diff-tree --no-commit-id --name-only -r "$commit_hash_inner" 2>/dev/null)
		if [[ "$is_planning_only_inner" == "$_PULSE_DISPATCH_FALSE" ]]; then
			match_count_inner=$((match_count_inner + 1))
		fi
	done
	echo "$match_count_inner"
	return 0
}

#######################################
# t2004: Signal 1 — search git log subject lines for task ID patterns.
# Handles tNNN and GH#NNN prefixes extracted from the issue title.
# Subject-only matching prevents body cross-references from causing false
# positives (GH#17779). Uses _count_impl_commits to filter planning-only
# commits (GH#17707).
#
# Args:
#   $1 - issue_title (to extract tNNN / GH#NNN prefix patterns)
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_recent_commits() {
	local issue_title="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 1: tNNN or tNNN.X task ID from title (e.g., "t153: add dark mode", "t2053.2: shell init")
	# Subject-only: body cross-references like "(t101)" must not match.
	# grep -w enforces word boundaries — prevents t101 matching t1010.
	# Subtask decimal suffix preserved (GH#19165) — t2053.2 must NOT match parent t2053 commits.
	local -a subject_patterns=()
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9a-z]+)*' | head -1 | sed 's/[.]/\\./g') || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		subject_patterns+=("$task_id_match")
	fi

	# Pattern 2: GH#NNN from title (e.g., "GH#17574: fix pulse dispatch")
	# Subject-only: body mentions of other GH# IDs must not match.
	local gh_id_match
	gh_id_match=$(printf '%s' "$issue_title" | grep -oE '^GH#[0-9]+' | head -1) || gh_id_match=""
	if [[ -n "$gh_id_match" ]]; then
		subject_patterns+=("$gh_id_match")
	fi

	[[ ${#subject_patterns[@]} -gt 0 ]] || return 1

	# Bash 3.2 + set -u: length check already done above.
	local pattern
	for pattern in "${subject_patterns[@]}"; do
		local match_count=0
		# Fetch all commits as "HASH SUBJECT", filter planning subjects, then
		# grep -w for word-boundary match on the subject portion only.
		#
		# Subject exclusions (t2379, GH#19863):
		#   - chore: claim        — claim-task-id.sh counter bump commits
		#   - chore: mark tNNN complete — task-complete-helper.sh bookkeeping
		#       commits written by issue-sync.yml after ANY PR merge. Touch
		#       TODO.md only, but belt+braces against future regressions.
		#   - plan: / pNN:        — explicit planning prefixes
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				--format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|chore: mark t[0-9]+ complete|plan:|p[0-9]+:)' |
				grep -wE "$pattern" |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_recent_commits: found ${match_count} commit(s) matching subject pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 2 — search git log commit messages for closing keywords and
# squash-merge suffixes that indicate the issue was resolved via a merged PR.
#
# Patterns: "(#NNN)" squash-merge suffix, "Closes #NNN", "Fixes #NNN".
# Full-message matching is safe here — these keywords legitimately appear
# only in commit bodies for commits that close an issue (GH#17779).
#
# Args:
#   $1 - issue_number
#   $2 - repo_path (local path to the repo)
#   $3 - created_at (ISO timestamp for --since filter)
#
# Exit codes:
#   0 - found matching implementation commit(s) on origin/main
#   1 - no match
#######################################
_task_id_in_merged_pr() {
	local issue_number="$1"
	local repo_path="$2"
	local created_at="$3"

	# Pattern 3: GitHub squash-merge suffix "(#NNN)" — only matches commit
	# titles, not body references. The bare "#NNN" pattern previously caused
	# false positives: any commit that MENTIONED an issue (e.g., "Relabeled
	# #17659 and #17660") would match, closing issues whose work hadn't been
	# done. Restrict to the "(#NNN)" suffix that GitHub adds to squash merges.
	# t1927: Escape parens for -E regex — unescaped parens are capture groups
	# that match bare "#NNN" in commit bodies (evidence tables, PR descriptions).
	# With \( \) the pattern only matches the literal "(#NNN)" suffix.
	local -a message_patterns=()
	message_patterns+=("\\(#${issue_number}\\)")

	# Patterns 4-5: "Closes #NNN" / "Fixes #NNN" in commit messages — these
	# are the conventional patterns for commits that resolve an issue.
	# \b word boundary prevents #17779 from matching #177790 (longer IDs).
	message_patterns+=("[Cc]loses #${issue_number}\\b")
	message_patterns+=("[Ff]ixes #${issue_number}\\b")

	# Bash 3.2 + set -u: guard empty array iteration.
	local pattern
	for pattern in "${message_patterns[@]}"; do
		local match_count=0
		match_count=$(_count_impl_commits "$repo_path" < <(
			git -C "$repo_path" log origin/main --since="$created_at" \
				-E --grep="$pattern" --format='%H %s' |
				grep -vE '^[0-9a-f]+ (chore: claim|plan:|p[0-9]+:)' |
				cut -d' ' -f1 || true
		))
		if [[ "$match_count" -gt 0 ]]; then
			echo "[pulse-wrapper] _task_id_in_merged_pr: found ${match_count} commit(s) matching message pattern '${pattern}' on origin/main since ${created_at}" >>"$LOGFILE"
			return 0
		fi
	done

	return 1
}

#######################################
# t2004: Signal 3 — scan TODO.md on origin/main for completed task markers.
# Catches tasks marked [x] in planning files without a conventional commit
# message — e.g., tasks completed via direct TODO edit + push.
#
# Args:
#   $1 - issue_number
#   $2 - issue_title (to extract tNNN prefix)
#   $3 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task found completed ([x]) in TODO.md on origin/main
#   1 - no match (or TODO.md unavailable)
#######################################
_task_id_in_changed_files() {
	local issue_number="$1"
	local issue_title="$2"
	local repo_path="$3"

	local todo_content
	todo_content=$(git -C "$repo_path" show origin/main:TODO.md 2>/dev/null) || return 1

	# Check for tNNN or tNNN.X completion marker: "- [x] tNNN ..."
	local task_id_match
	task_id_match=$(printf '%s' "$issue_title" | grep -oE '^t[0-9]+(\.[0-9a-z]+)*' | head -1 | sed 's/[.]/\\./g') || task_id_match=""
	if [[ -n "$task_id_match" ]]; then
		if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\]\s+${task_id_match}(\s|$)"; then
			echo "[pulse-wrapper] _task_id_in_changed_files: found completed '${task_id_match}' in TODO.md on origin/main" >>"$LOGFILE"
			return 0
		fi
	fi

	# Check for GH#NNN completion marker: "- [x] ... GH#NNN ..."
	if printf '%s' "$todo_content" | grep -qE "^\s*-\s*\[x\].*\bGH#${issue_number}\b"; then
		echo "[pulse-wrapper] _task_id_in_changed_files: found completed 'GH#${issue_number}' in TODO.md on origin/main" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# t1894 + GH#18648: Cryptographic approval gate (ever-NMR) with
# review-followup exemption for bot-generated cleanup issues.
#
# Extracted from _dispatch_dedup_check_layers() to keep the parent
# function under the 100-line complexity threshold while the exemption
# logic grew.
#
# Logic:
#   1. Determine if the issue currently has `needs-maintainer-review`
#      — set known_ever_nmr="true" for the cache-path short-circuit.
#   2. If the issue is bot-generated cleanup (review-followup or
#      source:review-scanner) AND the label is not currently present,
#      override known_ever_nmr=false to skip the historical timeline
#      check. This clears the ever-NMR permanence trap for routine
#      cleanup issues whose NMR label was applied by the fast-fail
#      escalation path and has since been removed.
#   3. If NMR is not currently present, skip historical ever-NMR for
#      trusted maintainer threads: issue author is OWNER/MEMBER and every
#      issue comment is OWNER/MEMBER or a known framework-generated GitHub
#      Actions hold/remediation notice. COLLABORATOR authors/comments are
#      trusted only after an authenticated collaborator-permission lookup
#      confirms write/admin/maintain. This preserves prompt-injection
#      protection while avoiding permanent crypto approval for internal
#      retry/hold labels that a maintainer has already removed.
#   4. Call issue_has_required_approval with the determined state.
#
# The exemption does NOT fire when the label is currently present —
# maintainer-applied or bot-applied NMR still blocks dispatch until
# the label is removed or cryptographic approval is posted.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate blocks dispatch (ever-NMR without approval)
#   1 - gate allows dispatch
#######################################
_issue_thread_is_trusted_maintainer_only() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1

	local issue_api_path="repos/${repo_slug}/issues/"
	issue_api_path="${issue_api_path}${issue_number}"
	local issue_comments_path="${issue_api_path}/comments"
	local issue_json
	local issue_author_association
	local issue_author_login
	issue_json=$(gh api "$issue_api_path" 2>/dev/null) || return 1
	IFS=$'\t' read -r issue_author_association issue_author_login < <(printf '%s' "$issue_json" |
		jq -r '[.author_association // "NONE", (.user.login // .author.login // "")] | @tsv') || {
		issue_author_association=""
		issue_author_login=""
	}
	case "$issue_author_association" in
	OWNER | MEMBER) ;;
	COLLABORATOR)
		_issue_actor_has_repo_write_permission "$repo_slug" "$issue_author_login" || return 1
		;;
	*)
		return 1
		;;
	esac

	local comments_json
	comments_json=$(gh api "$issue_comments_path" \
		--paginate --slurp 2>/dev/null) || return 1
	[[ -n "$comments_json" && "$comments_json" != "null" ]] || comments_json="[]"

	local untrusted_comment_count
	untrusted_comment_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "array" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select(
			((.author_association // "NONE") as $a | ($a != "OWNER" and $a != "MEMBER" and $a != $collaborator_association))
			and (((.user.login // .author.login // "") as $login
				| ((($login == "github-actions[bot]") or ($login == "github-actions"))
					and ((.body // "") | test("^<!-- (nmr-hold-guidance|ever-nmr-remediation) -->")))) | not)
		) ]
		| length
	') || return 1
	[[ "$untrusted_comment_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$untrusted_comment_count" -eq 0 ]] || return 1

	local missing_collaborator_login_count
	missing_collaborator_login_count=$(printf '%s' "$comments_json" | jq -r --arg array_type "array" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select(
			(.author_association // "NONE") == $collaborator_association
			and ((.user.login // .author.login // "") == "")
		) ]
		| length
	') || return 1
	[[ "$missing_collaborator_login_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$missing_collaborator_login_count" -eq 0 ]] || return 1

	local collaborator_comment_logins
	collaborator_comment_logins=$(printf '%s' "$comments_json" | jq -r --arg array_type "array" \
		--arg collaborator_association "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION" '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[] | select((.author_association // "NONE") == $collaborator_association) | (.user.login // .author.login // "") ]
		| unique | .[]
	') || return 1
	local comment_login
	while IFS= read -r comment_login; do
		[[ -n "$comment_login" ]] || continue
		_issue_actor_has_repo_write_permission "$repo_slug" "$comment_login" || return 1
	done <<<"$collaborator_comment_logins"

	return 0
}

_issue_actor_has_repo_write_permission() {
	local repo_slug="$1"
	local login="$2"

	[[ -n "$repo_slug" && -n "$login" ]] || return 1
	# #aidevops:trust-boundary — never trust bare COLLABORATOR association for
	# ever-NMR bypass. GitHub can use COLLABORATOR for ambiguous private-org
	# events; require an authenticated per-repo permission lookup.
	_gh_actor_has_repo_write_authority "$repo_slug" "$login" "$_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION"
	return $?
}

_check_nmr_approval_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"

	local known_ever_nmr="unknown"
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | index("needs-maintainer-review")' >/dev/null 2>&1; then
		known_ever_nmr="true"
	fi

	# GH#18648: bot-generated cleanup exemption. See
	# _is_bot_generated_cleanup_issue() doc for full rationale.
	if [[ "$known_ever_nmr" != "true" ]] && _is_bot_generated_cleanup_issue "$issue_meta_json"; then
		known_ever_nmr="$_PULSE_DISPATCH_FALSE"
		echo "[pulse-wrapper] dispatch_with_dedup: review-followup exemption for #${issue_number} in ${repo_slug} — skipping historical ever-NMR check (GH#18648)" >>"$LOGFILE"
	fi

	# <!-- aidevops:trust-boundary -->
	# Historical NMR is a prompt-injection trust boundary only when untrusted
	# content may have entered the worker prompt. If the active NMR label has
	# been removed and both issue author plus every comment author are OWNER or
	# MEMBER, allow dispatch without requiring a cryptographic approval marker.
	if [[ "$known_ever_nmr" != "true" ]] && _issue_thread_is_trusted_maintainer_only "$issue_number" "$repo_slug"; then
		known_ever_nmr=false
		echo "[pulse-wrapper] dispatch_with_dedup: trusted maintainer thread exemption for #${issue_number} in ${repo_slug} — skipping historical ever-NMR check" >>"$LOGFILE"
	fi

	if ! issue_has_required_approval "$issue_number" "$repo_slug" "$known_ever_nmr"; then
		echo "[pulse-wrapper] dispatch_with_dedup: BLOCKED #${issue_number} in ${repo_slug} — requires cryptographic approval (ever-NMR)" >>"$LOGFILE"
		echo "[pulse-wrapper] DISPATCH_BLOCK_REASON reason=ever_nmr_without_approval issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		# GH#20682: when the NMR label is absent (human removed it) but the
		# ever-NMR block still fires, post a one-shot remediation comment so
		# the maintainer knows why dispatch is still skipped and what to do.
		if [[ "$known_ever_nmr" != 'true' ]]; then
			notify_ever_nmr_without_approval "$issue_number" "$repo_slug"
		fi
		return 0
	fi
	return 1
}

#######################################
# GH#22399: Fail-closed external issue author gate.
#
# GitHub Actions issue-triage-gate.yml applies needs-maintainer-review to
# non-collaborator issues, but Actions can sit queued while the pulse keeps
# dispatching. This gate repeats the trust-boundary check in the dispatch path
# immediately before worker launch. OWNER/MEMBER, write-authorized collaborators,
# and bot-created issues keep the fast path. External, read/triage collaborator,
# or unknown authors must carry a valid cryptographic approval; otherwise the
# pulse applies NMR and blocks this candidate in the current cycle.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0 - gate blocks dispatch (external/unknown author without approval)
#   1 - gate allows dispatch
#######################################
_check_external_issue_author_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local nmr_label="${_PULSE_DISPATCH_NMR_LABEL:-needs-maintainer-review}"

	local issue_author_meta=""
	issue_author_meta=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq 'if (type == "object" and ((.labels | type) == "array") and all(.labels[]; if type == "object" then ((.name | type) == "string" and (.name | length) > 0) else false end)) then [.author_association // "NONE", .user.type // "", .user.login // "", (([.labels[].name] | index("external-contributor") != null) | tostring)] | join("|") else empty end' 2>/dev/null) || issue_author_meta=""

	local author_association="NONE"
	local author_type=""
	local author_login=""
	local external_source="unknown"
	local metadata_valid=0
	if [[ -n "$issue_author_meta" ]]; then
		IFS='|' read -r author_association author_type author_login external_source <<<"$issue_author_meta"
		if [[ -n "$author_login" && "$external_source" =~ ^(true|false)$ ]]; then
			metadata_valid=1
		fi
	fi
	[[ -n "$author_association" ]] || author_association="NONE"

	if [[ "$metadata_valid" -eq 1 && "$author_type" == "Bot" && "$external_source" != "true" ]]; then
		return 1
	fi
	local authority_rc=2
	if [[ "$metadata_valid" -eq 1 && "$external_source" != "true" ]]; then
		authority_rc=0
		_gh_actor_has_repo_write_authority "$repo_slug" "$author_login" "$author_association" || authority_rc=$?
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 1
	fi

	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	local verify_result=""
	if [[ -f "$approval_helper" ]]; then
		verify_result=$(bash "$approval_helper" verify "$issue_number" "$repo_slug" 2>/dev/null || true)
		if [[ "$verify_result" == "VERIFIED" ]]; then
			echo "[dispatch_with_dedup] GH#22399: external/unknown issue author for #${issue_number} in ${repo_slug} has cryptographic approval; allowing dispatch" >>"$LOGFILE"
			return 1
		fi
		# <!-- aidevops:trust-boundary -->
		# Distinguish an absent approval from an unverifiable approval marker. A
		# worker missing the approval public key must fail closed for dispatch, but
		# must not mutate lifecycle labels over a maintainer's signed handoff.
		if [[ -n "$verify_result" && "$verify_result" != "NO_APPROVAL" ]]; then
			echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: cryptographic approval marker present but verification returned ${verify_result}; not re-applying ${nmr_label} (GH#22733)" >>"$LOGFILE"
			return 0
		fi
	fi

	echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: author_association=${author_association}, author_type=${author_type:-unknown}, external_source=${external_source}, authority=${AIDEVOPS_GH_ACTOR_AUTHORITY_REASON:-unknown}; applying ${nmr_label} until cryptographic approval lands (GH#22399)" >>"$LOGFILE"
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_number" --repo "$repo_slug" \
			--add-label "$nmr_label" >/dev/null 2>&1 || true
	else
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "$nmr_label" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# GH#17574 + GH#18644: Combined commit-subject dedup gate with
# force-dispatch maintainer override.
#
# Wraps the _is_task_committed_to_main call with an early bypass when
# the issue carries the `force-dispatch` label. Extracted from
# _dispatch_dedup_check_layers() to keep the parent function under the
# 100-line complexity threshold while the logic-body grows.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - target_title (issue title from meta_json)
#   $4 - repo_path (local path to the repo)
#   $5 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - gate fires (block dispatch — task appears committed to main,
#       force-dispatch is NOT set)
#   1 - gate allows dispatch (task not committed, OR force-dispatch
#       override is set)
#######################################
_check_commit_subject_dedup_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_title="$3"
	local repo_path="$4"
	local issue_meta_json="$5"

	# GH#18644: force-dispatch label bypasses the commit-subject dedup
	# entirely. The override is for legacy task-ID collisions where a
	# commit subject accidentally mentions a task ID that was never
	# claimed via claim-task-id.sh. Maintainer-only — workers must not
	# apply this label. Does NOT bypass ever-NMR, claim/lock layers,
	# large-file gates, or blocked-by dependencies.
	if _has_force_dispatch_label "$issue_meta_json"; then
		echo "[pulse-wrapper] dispatch_with_dedup: force-dispatch label active on #${issue_number} in ${repo_slug} — bypassing _is_task_committed_to_main (GH#18644)" >>"$LOGFILE"
		return 1
	fi

	# t2955: cache fast-path. If a previous cycle already verified this
	# issue is committed to main, the `dispatch-blocked:committed-to-main`
	# label was applied. Skip the expensive `gh issue view` + `git fetch` +
	# 3 `git log --grep` ops and block immediately. Production data showed
	# this check was the dominant cost in `preflight_early_dispatch` —
	# 224 affected issues × 5 ops/cycle was timing out the 600s stage on
	# 100% of recent cycles, capping concurrency at 1-2 dispatches/cycle.
	#
	# Force-dispatch override (above) takes precedence — a maintainer
	# applying force-dispatch unblocks the cache too.
	#
	# Revert handling: if a commit is reverted, the cache label sticks
	# (false-positive block). Manual remediation: remove the label via
	# `gh issue edit N --remove-label dispatch-blocked:committed-to-main`.
	# A periodic scrubber to automate this is tracked separately —
	# kept out of this PR per one-fix-per-PR (Review Bot Gate t1382).
	if _has_committed_to_main_cache_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574) (cached, t2955)" >>"$LOGFILE"
		return 0
	fi

	# GH#17574: Skip dispatch if the task has already been committed
	# directly to main. Workers that bypass the PR flow (direct commits)
	# complete the work invisibly — the issue stays open until the
	# pulse's mark-complete pass runs, which happens AFTER dispatch
	# decisions for the next cycle. Without this check, the pulse
	# dispatches redundant workers for already-completed work.
	#
	# GH#17642: Do NOT auto-close the issue on a block. The main-commit
	# check has a high false-positive rate (casual mentions, multi-
	# runner deployment gaps, stale patterns). A false skip is harmless
	# (next cycle retries), a false close is destructive (needs manual
	# reopen, re-dispatch, and loses worker context). Let the verified
	# merge-pass or human close it.
	if _is_task_committed_to_main "$issue_number" "$repo_slug" "$target_title" "$repo_path"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: task already committed to main (GH#17574) (scanned, t2955)" >>"$LOGFILE"
		# t2955: apply cache label so subsequent cycles skip the scan.
		# Best-effort — do not fail dispatch decision if label apply errors.
		_apply_committed_to_main_cache_label "$issue_number" "$repo_slug" || true
		return 0
	fi

	return 1
}

#######################################
# GH#18644: Detect the `force-dispatch` maintainer override label.
#
# Purpose: escape hatch for false-positive task-ID collisions in the
# commit-subject dedup (_is_task_committed_to_main). When a commit
# subject accidentally mentions a task ID that was never claimed via
# claim-task-id.sh — e.g., `chore(build.txt): add rule (t2046)` for a
# task that is actually GH#18508, not the canonical t2046 — the dedup
# block fires permanently even though no implementation has happened.
#
# The `force-dispatch` label is a maintainer-only override that
# bypasses this specific check. It does NOT bypass:
#   - The cryptographic approval gate (ever-NMR) above it
#   - Any Layer 1-7 claim/lock/assignee/open-PR machinery below it
#   - Large-file gates, blocked-by dependencies, or supervisor title guards
#
# Workers MUST NOT apply this label themselves. It represents a
# human decision that the dedup signal is wrong for this specific issue.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - force-dispatch label is present
#   1 - force-dispatch label is absent (or meta_json is empty/invalid)
#######################################
_has_force_dispatch_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("force-dispatch")' >/dev/null 2>&1
}

#######################################
# Detect the publication hold label before any claim or worker launch.
#
# `publication:pending` represents an issue that was intentionally created
# before its TODO.md entry and worker brief/stub reached the default branch.
# This dedicated pre-launch check remains effective if candidate filtering or
# the dispatch-dedup helper is bypassed. Malformed metadata fails closed.
#
# Args:
#   $1 - issue metadata JSON with a .labels array
# Exit codes:
#   0 - publication is pending or metadata cannot be safely read
#   1 - publication is not pending
#######################################
_has_publication_pending_label() {
	local issue_meta_json="$1"
	local label_state=""
	[[ -n "$issue_meta_json" ]] || return 0
	label_state=$(printf '%s' "$issue_meta_json" |
		jq -r 'if ((.labels // []) | map(.name) | index("publication:pending")) != null then "pending" else "published" end' 2>/dev/null) || return 0
	[[ "$label_state" == "pending" ]]
}

#######################################
# t2955: Detect the `dispatch-blocked:committed-to-main` cache label.
#
# Purpose: cache fast-path for `_check_commit_subject_dedup_gate`. When
# the expensive `_is_task_committed_to_main` check first detects a block,
# the gate applies this label so subsequent dispatch cycles skip the
# `gh issue view` + `git fetch` + 3 `git log --grep` ops on the same
# issue. Eliminates the spam pattern where 224+ affected issues ran the
# expensive scan every cycle and timed out `preflight_early_dispatch` at
# its 600s budget (100% of last 10 cycles before this fix).
#
# The cache label is set by `_apply_committed_to_main_cache_label` (next
# helper) and never removed automatically by this gate. Periodic
# revalidation for revert handling is a follow-up; for now, manual
# remediation is via `gh issue edit N --remove-label
# dispatch-blocked:committed-to-main`.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - cache label is present (skip the expensive scan)
#   1 - cache label is absent (run the full scan)
#######################################
_has_committed_to_main_cache_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("dispatch-blocked:committed-to-main")' >/dev/null 2>&1
}

#######################################
# Detect terminal consolidated issues before worker dispatch.
#
# Consolidated source issues are archival records and must not be dispatched
# again. Consolidated successor specs are dispatchable only when they carry
# both the explicit auto-dispatch handoff and the canonical body marker.
# Review/CI feedback specs remain dispatchable through their source labels.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with a .labels array)
#
# Exit codes:
#   0 - consolidated label is present
#   1 - consolidated label is absent (or meta_json is empty/invalid)
#######################################
_has_consolidated_label() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	if printf '%s' "$issue_meta_json" | jq -e '
		(.labels | map(.name)) as $labels
		| (
			(($labels | index("auto-dispatch")) != null)
			and ((.body // "") | test("(^|\\n)_Supersedes #[0-9]+ (—|-) this issue is the consolidated spec\\._(\\n|$)"))
		) as $dispatchable_spec
		| (($labels | index("consolidated")) != null)
		and (($labels | index("quality-debt")) == null)
		and (($labels | index("source:review-feedback")) == null)
		and (($labels | index("source:ci-feedback")) == null)
		and ($dispatchable_spec | not)
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Determine whether a GitHub issue-number target is actually a pull request.
#
# `gh issue view` intentionally presents PRs through the issue facade, so the
# dispatch preflight must use the REST issue object and inspect the
# `pull_request` marker before any label/assignee writes. This is a hard
# trust-boundary guard: dispatching a worker against a PR number would mutate an
# interactive review object and can open a competing implementation PR.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
# Returns:
#   0 - target is a PR
#   1 - target is a plain Issue
#   2 - unable to verify safely
#######################################
_dispatch_target_is_pull_request() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_json="" has_pull_request=""

	target_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 2
	has_pull_request=$(printf '%s' "$target_json" | jq -r 'has("pull_request")' 2>/dev/null) || return 2
	if [[ "$has_pull_request" == "true" ]]; then
		return 0
	fi
	if [[ "$has_pull_request" == "$_PULSE_DISPATCH_FALSE" ]]; then
		return 1
	fi
	return 2
}

#######################################
# Return success when issue metadata identifies a Renovate Dependency Dashboard
# meta-issue. These are maintenance tracking issues, not implementation work.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with .author and .title)
# Returns:
#   0 - renovate[bot] Dependency Dashboard issue
#   1 - not a Renovate Dependency Dashboard issue
#######################################
_is_renovate_dependency_dashboard_issue() {
	local issue_meta_json="$1"
	local author_login="" issue_title="" title_lower=""

	[[ -n "$issue_meta_json" ]] || return 1
	author_login=$(printf '%s' "$issue_meta_json" | jq -r '.author.login // empty' 2>/dev/null | tr '[:upper:]' '[:lower:]') || author_login=""
	issue_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // empty' 2>/dev/null) || issue_title=""
	title_lower=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]')

	[[ "$author_login" == "renovate[bot]" ]] || return 1
	[[ "$title_lower" == *"dependency dashboard"* ]] || return 1
	return 0
}

#######################################
# t2955: Apply the `dispatch-blocked:committed-to-main` cache label.
#
# Called by `_check_commit_subject_dedup_gate` after the first scan
# detects a committed-to-main block. Best-effort: failures (rate limit,
# label-not-yet-created on the repo, transient API error) do NOT fail
# the dispatch decision. The current cycle's block stands regardless;
# the cache miss simply repeats next cycle.
#
# The `--add-label` call auto-creates the label on the repo if it
# doesn't exist (GitHub default behaviour for `gh issue edit`).
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   Always 0 — best-effort, never blocks the caller.
#######################################
_apply_committed_to_main_cache_label() {
	local issue_number="$1"
	local repo_slug="$2"
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "dispatch-blocked:committed-to-main" >/dev/null 2>&1 || true
	return 0
}

#######################################
# GH#18648 (Fix 3a): Detect bot-generated cleanup issues.
#
# Bot-generated cleanup issues carry `review-followup` (from
# post-merge-review-scanner.sh), `source:review-scanner`, or
# `source:review-feedback` (from quality-feedback-helper.sh scan-merged).
# These labels indicate: "this issue was auto-created from already-merged
# PR review comments, no new maintainer decision is required".
#
# Callers use this to exempt the issue from the ever-NMR permanence
# trap — historical NMR labels applied by automated escalation paths
# (dispatch-dedup fast-fail circuit breaker) no longer drain the
# dispatch queue once the label is manually removed.
#
# The exemption does NOT fire when the issue CURRENTLY has the
# needs-maintainer-review label — a present label still requires
# cryptographic approval, regardless of issue provenance. The fix
# is surgical to the historical-timeline false-positive case.
#
# Args:
#   $1 - issue_meta_json (pre-fetched JSON with .labels array)
#
# Exit codes:
#   0 - issue is bot-generated cleanup
#   1 - issue is not bot-generated (or meta_json is empty/invalid)
#######################################
_is_bot_generated_cleanup_issue() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | (index("review-followup") != null or index("source:review-scanner") != null or index("source:review-feedback") != null)' >/dev/null 2>&1
}

_dispatch_waiting_for_maintainer_permission() {
	local issue_meta_json="$1"
	printf '%s' "$issue_meta_json" |
		jq -e '.labels | map(.name) | index("needs-maintainer-permissions") != null' >/dev/null 2>&1
	return $?
}

_dispatch_permission_history_requires_grant() {
	local issue_number="$1"
	local repo_slug="$2"
	local events_json="" labeled_count="" verification=""
	_DISPATCH_PERMISSION_VERIFY_RESULT=""
	events_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/events?per_page=100" --paginate --slurp 2>/dev/null) || {
		_DISPATCH_PERMISSION_VERIFY_RESULT="API_ERROR"
		return 0
	}
	labeled_count=$(jq '[.[][]? | select(.event == "labeled" and .label.name == "needs-maintainer-permissions")] | length' <<<"$events_json" 2>/dev/null) || {
		_DISPATCH_PERMISSION_VERIFY_RESULT="API_ERROR"
		return 0
	}
	[[ "$labeled_count" -gt 0 ]] || return 1
	local approval_helper="${BASH_SOURCE[0]%/*}/approval-helper.sh"
	[[ -x "$approval_helper" ]] || {
		_DISPATCH_PERMISSION_VERIFY_RESULT="HELPER_MISSING"
		return 0
	}
	verification=$($approval_helper verify-permissions issue "$issue_number" "$repo_slug" 2>/dev/null) || true
	_DISPATCH_PERMISSION_VERIFY_RESULT="${verification:-NO_APPROVAL}"
	[[ "$verification" == "VERIFIED" ]] && return 1
	return 0
}

#######################################
# GH#17574: Check if a task has already landed on main (via PR merge or direct commit).
#
# Workers that bypass the PR flow (direct commits to main) complete the
# work invisibly — the issue stays open until the pulse's mark-complete
# pass runs, which happens AFTER dispatch decisions for the next cycle.
# This caused 3× token waste in the observed incident (t153–t160).
#
# Delegates to three per-signal helpers (t2004):
#   _task_id_in_recent_commits — task ID in commit subject line
#   _task_id_in_merged_pr      — closing keywords / squash-merge suffix
#   _task_id_in_changed_files  — [x] completion marker in TODO.md
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - issue_title (e.g., "t153: add dark mode toggle")
#   $4 - repo_path (local path to the repo)
#
# Exit codes:
#   0 - task IS committed to main (do NOT dispatch)
#   1 - task is NOT committed to main (safe to dispatch)
#######################################
_is_task_committed_to_main() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local repo_path="$4"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$repo_path" ]] || return 1

	# Get the issue creation date for --since filtering.
	# t3027: route through gh_issue_view wrapper for REST fallback under
	# GraphQL exhaustion. The `// .created_at` jq fallback handles both
	# camelCase (gh native) and snake_case (REST) field names — the REST
	# endpoint /repos/.../issues/N returns `created_at`, gh returns `createdAt`.
	local created_at
	created_at=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json createdAt --jq '.createdAt // .created_at' 2>/dev/null) || created_at=""
	if [[ -z "$created_at" ]]; then
		return 1
	fi

	# Ensure we have the latest remote refs (the dispatch loop already
	# does git pull, but fetch is cheaper and sufficient for log queries)
	if [[ -d "$repo_path/.git" ]] || git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "$repo_path" fetch origin main --quiet 2>/dev/null || true
	else
		return 1
	fi

	_task_id_in_recent_commits "$issue_title" "$repo_path" "$created_at" && return 0
	_task_id_in_merged_pr "$issue_number" "$repo_path" "$created_at" && return 0
	_task_id_in_changed_files "$issue_number" "$issue_title" "$repo_path" && return 0
	return 1
}

#######################################
# Detect labels that mean a human/review workflow owns the target.
#
# status:in-review is a live interactive hold signal while the issue is not
# explicitly worker-dispatchable. origin:interactive is provenance only unless a
# same-session owner/assignee is still attached; unassigned status:available
# issues must remain dispatchable so TODO/brief sync does not strand worker-ready
# backlog items that lack auto-dispatch labels.
#
# Args:
#   $1 - issue metadata JSON with optional .labels[].name
# Returns: 0 when an interactive hold label is present, 1 otherwise
#######################################
_dispatch_has_interactive_hold() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e '
			([.labels[]?.name]) as $labels |
			(($labels | index("auto-dispatch")) | not) and
			(
				($labels | index("status:in-review")) or
				(($labels | index("origin:interactive")) and (((.assignees // []) | length) > 0))
			)
		' >/dev/null 2>&1
	return $?
}

#######################################
# Pre-dispatch validation + dedup check layers for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Runs all pre-dispatch safety gates in order:
#   1. Issue state (must be OPEN)
#   2. Management labels (supervisor/contributor/persistent/etc.)
#   3. External issue author gate (GH#22399 — Actions queue race)
#   4. Cryptographic approval gate (t1894, ever-NMR)
#   5. Supervisor telemetry title guard
#   6. Main-commit check (GH#17574 — task already done)
#   7. Blocked-by dependency enforcement (t1927)
#   8. Issue consolidation pre-check
#   9. Large-file simplification gate
#   10. Read-only check_dispatch_dedup chain (Layers 1–6)
#       Layer 7 claim lock runs after canary preflight in worker launch.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title, may differ from dispatch_title)
#   $5 - self_login (dispatching runner login)
#   $6 - repo_path (local path to the repo)
#   $7 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Exit codes:
#   0 - all gates passed; safe to dispatch
#   1 - blocked (reason logged to LOGFILE by the failing gate)
#   3 - expected benign dispatch block with structured DISPATCH_BLOCK_REASON
#######################################
_dispatch_registered_worktree_count() {
	local repo_path="$1"
	local worktree_list=""
	local count=""
	worktree_list=$(git -C "$repo_path" worktree list 2>/dev/null) || return 1
	[[ -n "$worktree_list" ]] || return 1
	count=$(printf '%s\n' "$worktree_list" | wc -l | tr -d ' ')
	[[ "$count" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$count"
	return 0
}

_dispatch_run_guarded_worktree_cleanup() {
	local repo_path="$1"
	local helper="$2"
	(
		cd -- "$repo_path" || exit 125
		bash "$helper" clean --auto --force-merged
	) >>"${LOGFILE:-/dev/null}" 2>&1
}

# At the dispatch worktree cap, synchronously give the existing guarded cleanup
# one bounded chance to recover capacity. The helper remains responsible for
# preserving dirty, active, open-PR, unmerged, and externally-owned worktrees.
_dispatch_cleanup_worktree_capacity() {
	local repo_path="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local before_count="$4"
	local max_count="$5"
	local helper="${AIDEVOPS_WORKTREE_HELPER:-${BASH_SOURCE[0]%/*}/worktree-helper.sh}"
	local cleanup_timeout="${AIDEVOPS_DISPATCH_WORKTREE_CLEANUP_TIMEOUT:-60}"
	local cleanup_rc=0
	local after_count=""

	[[ "$cleanup_timeout" =~ ^[0-9]+$ ]] || cleanup_timeout=60
	[[ "$cleanup_timeout" -ge 1 ]] || cleanup_timeout=1
	if [[ ! -x "$helper" ]]; then
		echo "[dispatch_with_dedup] Capacity cleanup unavailable for #${issue_number} in ${repo_slug}: guarded helper not executable (${helper}); count remains ${before_count}/${max_count}" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F run_stage_with_timeout >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Capacity cleanup unavailable for #${issue_number} in ${repo_slug}: bounded stage runner missing; count remains ${before_count}/${max_count}" >>"$LOGFILE"
		return 1
	fi

	echo "[dispatch_with_dedup] Worktree count ${before_count} >= cap ${max_count} for #${issue_number} in ${repo_slug}; attempting guarded cleanup (timeout ${cleanup_timeout}s)" >>"$LOGFILE"
	run_stage_with_timeout "dispatch_worktree_capacity_cleanup" "$cleanup_timeout" \
		_dispatch_run_guarded_worktree_cleanup "$repo_path" "$helper" || cleanup_rc=$?
	if ! after_count=$(_dispatch_registered_worktree_count "$repo_path"); then
		echo "[dispatch_with_dedup] Guarded capacity cleanup could not verify the post-cleanup worktree count for #${issue_number} in ${repo_slug} (before ${before_count}, cap ${max_count}, cleanup_rc=${cleanup_rc}); dispatch remains fail-closed" >>"$LOGFILE"
		return 1
	fi
	if [[ "$after_count" =~ ^[0-9]+$ ]] && [[ "$after_count" -lt "$max_count" ]]; then
		echo "[dispatch_with_dedup] Guarded capacity cleanup recovered dispatch capacity for #${issue_number} in ${repo_slug}: ${before_count} -> ${after_count} worktrees (cap ${max_count}, cleanup_rc=${cleanup_rc})" >>"$LOGFILE"
		return 0
	fi

	[[ "$after_count" =~ ^[0-9]+$ ]] || after_count="$before_count"
	echo "[dispatch_with_dedup] Guarded capacity cleanup could not recover dispatch capacity for #${issue_number} in ${repo_slug}: ${before_count} -> ${after_count} worktrees (cap ${max_count}, cleanup_rc=${cleanup_rc}); existing cleanup safety gates preserved remaining worktrees" >>"$LOGFILE"
	return 1
}

_dispatch_worktree_capacity_gate() {
	local repo_path="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local max_count="$4"
	local count=""

	if ! count=$(_dispatch_registered_worktree_count "$repo_path"); then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to verify registered worktree count; capacity gate remains fail-closed" >>"$LOGFILE"
		return 1
	fi
	if [[ "$count" -lt "$max_count" ]]; then
		return 0
	fi
	_dispatch_cleanup_worktree_capacity "$repo_path" "$issue_number" "$repo_slug" "$count" "$max_count"
	return $?
}

_dispatch_dedup_check_layers() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local self_login="$5"
	local repo_path="$6"
	local issue_meta_json="$7"

	# t3043: per-sub-stage timing inside dedup_check. The outer
	# dispatch_with_dedup records "dedup_check" as one blob; these
	# sub-stage records let us identify which gate dominates the 235s avg.
	local _dss_t0

	local target_state="" target_title=""
	# GH#21717: normalize to uppercase — REST fallback returns lowercase "open"/"closed"
	# while GraphQL returns enum "OPEN"/"CLOSED". The comparison at line 921 is
	# case-sensitive, so without normalization every issue appears non-OPEN when
	# GraphQL is exhausted, silently blocking all dispatch for 30+ min.
	target_state=$(printf '%s' "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null | tr '[:lower:]' '[:upper:]')
	target_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // ""' 2>/dev/null)

	# GH#22948/GH#22964/GH#29535: interactive/review holds remain independent
	# of assignee identity. A terminal worker draft checkpoint is the sole narrow
	# exception: route its existing exact PR before consuming the generic hold.
	_dss_t0=$(_ds_now_ns)
	if _dispatch_interactive_hold_gate "$issue_number" "$repo_slug" "$issue_title" \
		"$self_login" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.interactive_hold" "$_dss_t0"
		return 3
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.interactive_hold" "$_dss_t0"

	# GH#18987/GH#28543: refuse dispatch when the worktree filesystem has less
	# than 5 GiB or 5% available. The same fail-closed policy runs at the actual
	# worktree creation boundary, covering interactive and non-Pulse callers.
	_dss_t0=$(_ds_now_ns)
	local _capacity_rc=0
	aidevops_worktree_capacity_check "${AIDEVOPS_WORKTREE_BASE_DIR:-$HOME}" || _capacity_rc=$?
	if [[ "$_capacity_rc" -ne 0 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: disk space critical (reason=${AIDEVOPS_DISK_CAPACITY_REASON}, available=${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}KB/${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}%, require at least ${AIDEVOPS_MIN_WORKTREE_FREE_KB:-5242880}KB and ${AIDEVOPS_MIN_WORKTREE_FREE_PERCENT:-5}%). Run: worktree-helper.sh clean --auto --force-merged" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.disk_space" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.disk_space" "$_dss_t0"

	# GH#18987: Worktree count cap — refuse dispatch when the repo has 200+
	# registered git worktrees. At that scale, new worktrees risk consuming
	# tens of GB; stale merged ones should be cleaned before adding more.
	_dss_t0=$(_ds_now_ns)
	local _wt_max=""
	_wt_max="${AIDEVOPS_MAX_WORKTREES:-200}"
	[[ "$_wt_max" =~ ^[1-9][0-9]*$ ]] || _wt_max=200
	if ! _dispatch_worktree_capacity_gate "$repo_path" "$issue_number" "$repo_slug" "$_wt_max"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: worktree capacity remains unavailable after bounded guarded cleanup" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.worktree_cap" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.worktree_cap" "$_dss_t0"

	_dss_t0=$(_ds_now_ns)
	if [[ "$target_state" != "OPEN" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: issue state is ${target_state:-unknown}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.state_check" "$_dss_t0"
		return 1
	fi

	# publication:pending is an unconditional hold while canonical planning is
	# absent from the default branch. It is checked here as defence-in-depth
	# before direct-dispatch paths can claim or launch a worker.
	if _has_publication_pending_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: publication:pending label present" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.publication_pending" "$_dss_t0"
		return 1
	fi

	# GH#20219: parent-task / meta added here as defence-in-depth. The
	# canonical parent-task guard is in dispatch-dedup-helper.sh Layer 6
	# (_is_assigned_check_parent_task), but adding it to the early management-
	# label block ensures it fires even if Layer 6 is somehow bypassed (e.g.
	# dedup_helper missing, jq failure in the helper, or a direct-dispatch
	# code path that skips check_dispatch_dedup). This closes Factor 1 of
	# the #20161 incident where a parent-task issue was dispatched despite
	# the label being continuously present.
	if _has_consolidated_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: consolidated issue label present (GH#23187)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.mgmt_label" "$_dss_t0"
		return 1
	fi

	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("on hold") or index("blocked") or index("parent-task") or index("meta"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: non-dispatchable management label present" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.mgmt_label" "$_dss_t0"
		return 1
	fi

	# t2424/GH#20030: resolved-status label check (defence-in-depth alongside eligibility gate).
	# status:done and status:resolved signal already-completed work. Checking here (in the
	# dedup layers) catches these before the more expensive eligibility check fires.
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("status:done") or index("status:resolved"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: status:done or status:resolved label present (t2424)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.label_checks" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.label_checks" "$_dss_t0"

	# GH#22399: fail closed for external/unknown issue authors before the
	# historical ever-NMR gate. The ever-NMR gate allows never-labeled issues;
	# this gate closes the race where GitHub Actions has not applied NMR yet.
	_dss_t0=$(_ds_now_ns)
	if _check_external_issue_author_gate "$issue_number" "$repo_slug"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.external_author_gate" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.external_author_gate" "$_dss_t0"

	# t1894/GH#18648: Cryptographic approval gate (ever-NMR) with
	# review-followup exemption for bot-generated cleanup issues.
	_dss_t0=$(_ds_now_ns)
	if _check_nmr_approval_gate "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.nmr_gate" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.nmr_gate" "$_dss_t0"

	if [[ "$target_title" == \[Supervisor:* ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: supervisor telemetry title" >>"$LOGFILE"
		return 1
	fi

	# t3040: commit-subject dedup gate REMOVED from dispatch hot path
	# (cost 100-156s/candidate). Workers do their own t2046 duplicate
	# discovery; helpers retained for diagnostic use. Regression guard:
	# tests/test-pulse-dispatch-core-t3040-gate-removed.sh.

	# t1927/GH#23932: Blocked-by enforcement — skip dispatch if a dependency is unresolved.
	# Checks GitHub's native blockedBy relationship field first, then falls back
	# to issue-body markers such as "blocked-by:tNNN" or "Blocked by #NNN".
	# t2996: body now travels in $issue_meta_json (`,body` was added at the
	# canonical gh call); extract once and reuse for the consolidation,
	# large-file, and footprint gates below — eliminating 1-2 extra gh calls
	# per dispatch candidate.
	_dss_t0=$(_ds_now_ns)
	local _dispatch_issue_body
	_dispatch_issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null) || _dispatch_issue_body=""
	if is_blocked_by_unresolved "$_dispatch_issue_body" "$repo_slug" "$issue_number"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (t1927)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.blocked_by" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.blocked_by" "$_dss_t0"

	# Pre-dispatch: issue consolidation check. If an issue has accumulated
	# multiple substantive comments that change scope (not dispatch/approval
	# machinery), dispatch a consolidation worker first to merge everything
	# into a clean issue body. This prevents implementing workers from spending
	# tokens reconstructing scope from comment archaeology.
	# t2996: pass meta_json through so the consolidation helper skips its
	# `gh issue view --json labels` call (label CSV derived from JSON instead).
	_dss_t0=$(_ds_now_ns)
	if _issue_needs_consolidation "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_dispatch_issue_consolidation "$issue_number" "$repo_slug" "$repo_path"
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: issue needs comment consolidation" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.consolidation" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.consolidation" "$_dss_t0"

	# Pre-dispatch: large-file simplification gate. If the issue body
	# references files that exceed LARGE_FILE_LINE_THRESHOLD, create a
	# blocked-by simplification task instead of dispatching. Workers
	# shouldn't pay the complexity tax of navigating a 12,000-line file.
	# t2996: pass meta_json through so the gate skips its `gh issue view --json
	# labels` AND `--json title` calls (both derived from the bundled JSON).
	_dss_t0=$(_ds_now_ns)
	if _issue_targets_large_files "$issue_number" "$repo_slug" "$_dispatch_issue_body" "$repo_path" "" "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: targets large file(s), simplification gate" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.large_file" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.large_file" "$_dss_t0"

	# t2117/GH#19109: File-footprint overlap throttle. If another in-flight
	# worker is already modifying the same files, defer this dispatch to
	# prevent CONFLICTING cascades. The check is cheap (cached per repo per
	# cycle) and decays naturally when the blocking issue's status labels clear.
	_dss_t0=$(_ds_now_ns)
	local _footprint_signal=""
	_footprint_signal=$(_footprint_check_overlap "$issue_number" "$repo_slug" "$_dispatch_issue_body" 2>/dev/null) || true
	if [[ -n "$_footprint_signal" ]]; then
		echo "[dispatch_with_dedup] (t2117) Dispatch deferred for #${issue_number} in ${repo_slug}: ${_footprint_signal}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.footprint" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.footprint" "$_dss_t0"

	# Read-only dedup layers — cannot be skipped.
	# t2996: ISSUE_META_JSON forwards the canonical bundle to
	# dispatch-dedup-helper.sh (Layer 6 `is-assigned`, Layer 4 `has-open-pr`,
	# etc.). The helper's t-prefixed lookup paths already detect the env var
	# (see dispatch-dedup-helper.sh:898-900) and skip their own
	# `gh issue view --json labels,assignees` call when present. Without this
	# export, those layers re-fetch the same JSON we just bundled — wasting
	# 1-2 more gh calls under load.
	_dss_t0=$(_ds_now_ns)
	local _dedup_rc=0
	local _dedup_signal=""
	_dedup_signal=$(ISSUE_META_JSON="$issue_meta_json" \
		check_dispatch_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" "$self_login") || _dedup_rc=$?
	if [[ "$_dedup_rc" -eq 0 || "$_dedup_rc" -eq 3 ]]; then
		local _dedup_block_signal="dedup_guard_blocked"
		local _dedup_block_reason="dedup_active_claim"
		if [[ -n "$_dedup_signal" ]]; then
			_dedup_block_signal="${_dedup_signal%%$'\n'*}"
			local _dedup_helper_path="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/dispatch-dedup-helper.sh"
			_dedup_block_reason=$("$_dedup_helper_path" classify-blocker "$_dedup_block_signal") || _dedup_block_reason="dedup_active_claim"
		fi
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=${_dedup_block_reason} signal=${_dedup_block_signal} issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.7_layers" "$_dss_t0"
		if [[ "$_dedup_rc" -eq 3 ]]; then
			return 3
		fi
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.7_layers" "$_dss_t0"

	return 0
}

#######################################
# t2424/GH#20030: Run the generic pre-dispatch eligibility gate and
# translate its exit codes into a simple 0=proceed, 1=abort contract
# for dispatch_with_dedup. Keeps dispatch_with_dedup short.
#
# Gate exit codes (from _run_predispatch_eligibility_check):
#   0  — eligible; proceed
#   2  — CLOSED state; abort
#   3  — status:done/resolved label; abort
#   4  — linked PR merged in recent window; abort
#   5  — recent closing commit on default branch; abort
#   6  — parent-task or meta label; abort (GH#20219)
#   20 — gh API error; fail-open (proceed with warning)
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - issue_meta_json (pre-fetched; forwarded via ISSUE_META_JSON to avoid duplicate gh calls)
#
# Exit codes:
#   0 — dispatch should proceed
#   1 — dispatch aborted (gate found issue ineligible)
#######################################
_run_eligibility_gate_or_abort() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"

	local rc=0
	ISSUE_META_JSON="$issue_meta_json" \
		_run_predispatch_eligibility_check "$issue_number" "$repo_slug" || rc=$?

	if [[ "$rc" -ne 0 && "$rc" -ne 20 ]]; then
		echo "[dispatch_with_dedup] t2424: Pre-dispatch eligibility gate aborted #${issue_number} in ${repo_slug} (rc=${rc}) — not dispatching" >>"$LOGFILE"
		return 1
	fi
	if [[ "$rc" -eq 20 ]]; then
		echo "[dispatch_with_dedup] t2424: Eligibility gate API error for #${issue_number} (rc=20) — fail-open, proceeding" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Verify and roll back queued ownership created by this exact pre-launch claim.
# The claim comment remains present while this runs, providing a lease identity
# that prevents an older abort from clearing a newer dispatch attempt.
# Args: issue number, repo slug, runner login, claim comment id
# Returns: 0 when ownership is absent or verified rolled back; 1 on uncertainty.
#######################################
_rollback_prelaunch_ownership() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local claim_comment_id="$4"
	local comments_endpoint="repos/${repo_slug}/issues/${issue_number}/comments"
	local latest_claim_id=""

	latest_claim_id=$(gh api "$comments_endpoint" --paginate --jq \
		'[.[] | select((.body // "") | contains("DISPATCH_CLAIM nonce="))] | last | (.id // "")' 2>/dev/null) || return 1
	if [[ -z "$latest_claim_id" || "$latest_claim_id" != "$claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Pre-launch rollback skipped for #${issue_number}: claim ${claim_comment_id} is no longer current (latest=${latest_claim_id:-unknown})" >>"$LOGFILE"
		return 1
	fi

	local issue_meta_json=""
	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees,locked 2>/dev/null) || return 1
	local owns_queued=""
	owns_queued=$(printf '%s' "$issue_meta_json" | jq -r --arg self "$self_login" '
		(.state == "OPEN") and
		(([.labels[].name] | index("status:queued")) != null) and
		(([.assignees[].login] | index($self)) != null)
	' 2>/dev/null) || return 1
	[[ "$owns_queued" == "true" ]] || return 0

	if ! set_issue_status "$issue_number" "$repo_slug" "available" \
		--remove-assignee "$self_login" >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Pre-launch rollback failed for #${issue_number}: unable to restore available ownership" >>"$LOGFILE"
		return 1
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_number" "$repo_slug" || return 1
	fi

	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees,locked 2>/dev/null) || return 1
	if ! printf '%s' "$issue_meta_json" | jq -e --arg self "$self_login" '
		.state == "OPEN" and
		(([.labels[].name] | index("status:queued")) == null) and
		(([.labels[].name] | index("status:available")) != null) and
		(([.assignees[].login] | index($self)) == null) and
		(.locked != true)
	' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Pre-launch rollback verification failed for #${issue_number}; retaining claim for stale recovery" >>"$LOGFILE"
		return 1
	fi

	echo "[dispatch_with_dedup] Pre-launch rollback verified for #${issue_number}: queued ownership removed and issue unlocked" >>"$LOGFILE"
	return 0
}

#######################################
# Release a dispatch claim when a post-claim pre-launch step aborts.
#
# dispatch-claim-helper.sh posts DISPATCH_CLAIM before later gates and launch
# sub-stages run. When those later steps abort before the worker wrapper starts,
# neither the worker EXIT trap nor _dlw_post_launch_hooks can emit lifecycle
# evidence. Post CLAIM_RELEASED here so peer runners see a terminal marker and
# the issue thread records why no worker comment appeared.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - self_login
#   $4 - reason suffix for dispatch_aborted:<reason>
#######################################
_release_dispatch_claim_on_abort() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local reason="$4"

	[[ -n "${_claim_comment_id:-}" ]] || return 0
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	[[ -n "$self_login" ]] || self_login="$(whoami 2>/dev/null || printf '%s' unknown)"
	case "$reason" in
	*[^A-Za-z0-9_.:-]* | "") reason="unknown" ;;
	esac

	# t3549 (GH#22615): for pre-launch aborts where the worker never
	# started (canary preflight fail, eligibility gate, predispatch
	# validator close, worktree precreation fail), the claim comment is
	# noise — no audit trail value (no worker existed) and the issue
	# thread accumulates 89+ DISPATCH_CLAIM/CLAIM_RELEASED pairs over a
	# canary-failure storm. DELETE the original claim instead of posting a
	# release receipt. The negative cache (90s timeout / 300s overload)
	# carries the dedup signal locally; cross-runner dedup loses the lock
	# but the next runner will face the same canary failure and back off
	# the same way. For any other abort reason the legacy CLAIM_RELEASED
	# audit comment is preserved.
	local _is_pre_launch_abort=0
	case "$reason" in
	worker_launch_rc_* | predispatch_validator_closed | eligibility_gate)
		_is_pre_launch_abort=1
		;;
	esac

	if [[ "$_is_pre_launch_abort" == "1" ]]; then
		if [[ "$reason" == worker_launch_rc_* ]] &&
			! _rollback_prelaunch_ownership "$issue_number" "$repo_slug" "$self_login" "$_claim_comment_id"; then
			echo "[dispatch_with_dedup] Retaining dispatch claim ${_claim_comment_id} after uncertain pre-launch rollback for #${issue_number} (${reason})" >>"$LOGFILE"
			return 1
		fi
		local _claim_helper="${SCRIPT_DIR}/dispatch-claim-helper.sh"
		if [[ -x "$_claim_helper" ]]; then
			# Use the helper's _delete_comment if exposed via subcommand,
			# otherwise fall back to a direct gh api DELETE.
			gh api "repos/${repo_slug}/issues/comments/${_claim_comment_id}" \
				--method DELETE >/dev/null 2>>"$LOGFILE" || {
				echo "[dispatch_with_dedup] Warning: failed to delete dispatch claim ${_claim_comment_id} on pre-launch abort #${issue_number} (${reason})" >>"$LOGFILE"
			}
		else
			gh api "repos/${repo_slug}/issues/comments/${_claim_comment_id}" \
				--method DELETE >/dev/null 2>>"$LOGFILE" || true
		fi
		echo "[dispatch_with_dedup] Deleted dispatch claim ${_claim_comment_id} for pre-launch abort #${issue_number} (${reason}) — no worker started, audit trail noise eliminated (t3549)" >>"$LOGFILE"
		_claim_comment_id=""
		return 0
	fi

	local body
	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=dispatch_aborted:${reason} runner=${self_login} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) aidevops_version=${aidevops_version} opencode_version=${opencode_version}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to release dispatch claim for aborted #${issue_number} (${reason})" >>"$LOGFILE"
	}
	echo "[dispatch_with_dedup] Released dispatch claim ${_claim_comment_id} for aborted #${issue_number} (${reason})" >>"$LOGFILE"
	_claim_comment_id=""
	return 0
}

#######################################
# Dispatch a worker for the given issue, guarded by all dedup and
# pre-dispatch safety layers. Thin orchestrator: delegates to
# _dispatch_dedup_check_layers (decision) and _dispatch_launch_worker
# (action). External signature is unchanged from the pre-t1999 version.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title; optional, default empty)
#   $5 - self_login (dispatching runner login; optional, default empty)
#   $6 - repo_path (local path to the repo)
#   $7 - prompt (worker prompt string)
#   $8 - session_key (optional, default "issue-{issue_number}")
#   $9 - model_override (optional, default empty = auto round-robin)
#
# Exit codes:
#   0 - worker dispatched successfully
#   1 - hard error (metadata unavailable, dedup gate blocked)
#   2 - explicit launch no-op (canary/precreate/orphan guard; retry later)
#######################################
dispatch_with_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"
	local repo_path="$6"
	local prompt="$7"
	local session_key="${8:-issue-${issue_number}}"
	local model_override="${9:-}"
	# GH#15317 fix: _claim_comment_id is set by check_dispatch_dedup() via
	# bash dynamic scoping, but must be declared in the calling function's
	# scope first. Without this, set -u crashes the wrapper on every dispatch,
	# SIGTERM-ing all active workers.
	local _claim_comment_id=""

	# GH#17503: Claim comments are NEVER deleted — they form the audit trail.
	# The _cleanup_claim_comment function is retained as a no-op for backward
	# compatibility (callers may still reference it on early-return paths).
	_cleanup_claim_comment() {
		# No-op: claim comments are persistent audit trail (GH#17503).
		# Previously deleted DISPATCH_CLAIM comments, which destroyed both
		# the lock and the audit trail — causing duplicate dispatches.
		return 0
	}

	# t3034: per-stage timing instrumentation — capture ceremony overhead.
	local _ds_ceremony_t0="" _ds_t0=""
	_ds_ceremony_t0=$(_ds_now_ns)

	# Hard stop for supervisor/telemetry issues (t1702 pulse guard).
	# The pulse prompt should already avoid these, but this deterministic
	# gate prevents dispatch when prompt fallback logic is too permissive.
	#
	# t2996: Single canonical gh call. Fetch number,title,state,labels,
	# assignees AND body in ONE request, then thread the bundle through every
	# downstream gate so they don't re-fetch. Replaces 4-5 redundant gh calls
	# (the old meta call + the blocked-by body fetch + the consolidation labels
	# fetch + the large-file labels/title fetches + the brief-freshness body
	# fetch) with a single call. See .agents/reference/dispatch-architecture.md
	# "gh API call budget" for the full inventory.
	_ds_t0=$(_ds_now_ns)
	local issue_meta_json
	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,body,author 2>/dev/null) || issue_meta_json=""
	_ds_record "$issue_number" "$repo_slug" "gh_issue_view" "$_ds_t0"
	if [[ -z "$issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to load issue metadata" >>"$LOGFILE"
		return 1
	fi
	local issue_state
	issue_state=$(printf '%s' "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null | tr '[:lower:]' '[:upper:]') || issue_state=""
	if [[ "$issue_state" == "CLOSED" ]]; then
		echo "[dispatch] Skipping #${issue_number}: state=CLOSED" >>"$LOGFILE"
		pulse-batch-prefetch-helper.sh evict-issue "$repo_slug" "$issue_number" 2>/dev/null || true
		return 1
	fi

	#aidevops:trust-boundary -- a worker permission request is dispatchable only
	# after the request-specific signed grant flow removes its dedicated label.
	if _dispatch_waiting_for_maintainer_permission "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: waiting for a scoped signed maintainer permission grant" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=needs_maintainer_permissions signal=needs-maintainer-permissions issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 1
	fi
	if _dispatch_permission_history_requires_grant "$issue_number" "$repo_slug"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: permission-request history lacks a current matching signed grant (${_DISPATCH_PERMISSION_VERIFY_RESULT:-unknown})" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=permission_grant_unverified signal=${_DISPATCH_PERMISSION_VERIFY_RESULT:-unknown} issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# GH#22948: hard PR-target guard before any lifecycle mutation. A pull
	# request shares the Issues API number space, but it is already an
	# implementation under review; dispatching a worker against it can relabel
	# origin:interactive to origin:worker and open a competing PR.
	local _target_pr_rc=0
	_dispatch_target_is_pull_request "$issue_number" "$repo_slug" || _target_pr_rc=$?
	if [[ "$_target_pr_rc" -eq 0 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: target is a pull request, not a dispatchable issue (GH#22948)" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=pr_target_not_dispatchable signal=pr_target_not_dispatchable issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 3
	fi
	if [[ "$_target_pr_rc" -ne 1 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to verify target is not a pull request (GH#22948, rc=${_target_pr_rc})" >>"$LOGFILE"
		return 1
	fi

	if _is_renovate_dependency_dashboard_issue "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: Renovate Dependency Dashboard issues are metadata only" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=renovate_dependency_dashboard signal=renovate_dependency_dashboard issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 3
	fi

	# Run all pre-dispatch validation and dedup check layers (10 gates total).
	# Each gate logs its own blocked reason to LOGFILE before returning 1.
	# _claim_comment_id is set by check_dispatch_dedup inside this call via
	# bash dynamic scoping — accessible below because it was declared local above.
	_ds_t0=$(_ds_now_ns)
	local _dedup_check_rc=0
	_dispatch_dedup_check_layers \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$issue_meta_json" || _dedup_check_rc=$?
	if [[ "$_dedup_check_rc" -ne 0 ]]; then
		_ds_record "$issue_number" "$repo_slug" "dedup_check" "$_ds_t0"
		if [[ "$_dedup_check_rc" -eq 3 ]]; then
			return 3
		fi
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup_check" "$_ds_t0"

	# t2063: brief-body freshness guard — defence-in-depth.
	# If a brief file exists for this issue but the issue body lacks the
	# `## Task Brief` or `## Worker Guidance` marker, force-enrich the body
	# so the worker sees inlined implementation context on first read. This
	# catches any legacy issue created via the pre-t2063 bare path, and
	# any future path that might bypass the primary fixes in claim-task-id.sh
	# and issue-sync-helper.sh. Non-fatal — dispatch proceeds even if enrich fails.
	# t2996: thread meta_json so the helper extracts body from JSON instead of
	# making a 5th `gh issue view --json body` call on the same candidate.
	_ds_t0=$(_ds_now_ns)
	_ensure_issue_body_has_brief "$issue_number" "$repo_slug" "$repo_path" "$issue_title" "$issue_meta_json"
	_ds_record "$issue_number" "$repo_slug" "brief_freshness" "$_ds_t0"

	# t2389: explicit tier:simple execution-contract guard.
	# Non-blocking: normalizes tier:simple → tier:standard when a present checklist
	# is incomplete or the issue lacks a canonical exact execution contract.
	# Always returns 0. Dispatch proceeds at the corrected tier on hit, or
	# unchanged tier on miss. See .agents/reference/task-taxonomy.md.
	# Label-mutating policy helpers emit one internal marker; metadata is refreshed
	# once after this guard and the self-hosting override have both run.
	_TIER_LABELS_MUTATED=0
	_ds_t0=$(_ds_now_ns)
	_run_tier_simple_body_shape_check "$issue_number" "$repo_slug"
	_ds_record "$issue_number" "$repo_slug" "tier_body_shape" "$_ds_t0"

	# GH#19118: Pre-dispatch validator — runs after dedup, before worker spawn.
	# Checks generator-tagged auto-generated issues to verify the premise is
	# still true. Exit 0 = dispatch proceeds; exit 10 = premise falsified
	# (issue already closed by validator); exit 20 = optional validator error
	# (dispatch proceeds with warning); exit 30 = duplicate-state uncertainty
	# (fail closed for this cycle).
	_ds_t0=$(_ds_now_ns)
	_run_predispatch_validator "$issue_number" "$repo_slug"
	local _validator_rc=$?
	issue_meta_json=$(_refresh_issue_meta_after_tier_policy_checks \
		"$issue_number" "$repo_slug" "$issue_meta_json" "$_TIER_LABELS_MUTATED")
	local _review_followup_validator_required=0
	if printf '%s' "$issue_meta_json" | jq -e '[.labels[]?.name] | (index("review-followup") != null or index("source:review-scanner") != null)' >/dev/null 2>&1; then
		_review_followup_validator_required=1
	fi
	_ds_record "$issue_number" "$repo_slug" "predispatch_validator" "$_ds_t0"
	if [[ "$_validator_rc" -eq 10 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch validator falsified premise for #${issue_number} in ${repo_slug} — issue closed, not dispatching" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_closed"
		return 1
	fi
	if [[ "$_review_followup_validator_required" -eq 1 && "$_validator_rc" -ne 0 ]]; then
		echo "[dispatch_with_dedup] Required review-followup validation failed for #${issue_number} in ${repo_slug} (rc=${_validator_rc}) — failing closed" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_uncertain"
		return 1
	fi
	if [[ "$_validator_rc" -eq 20 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch validator error for #${issue_number} in ${repo_slug} (rc=${_validator_rc}) — proceeding with dispatch" >>"$LOGFILE"
	fi
	if [[ "$_validator_rc" -eq 30 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch duplicate lookup uncertain for #${issue_number} in ${repo_slug} — failing closed for this cycle" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_uncertain"
		return 1
	fi

	# t2424/GH#20030: Generic eligibility gate — final check BEFORE worker spawn.
	_ds_t0=$(_ds_now_ns)
	if ! _run_eligibility_gate_or_abort "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE" "$_ds_t0"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE" "$_ds_t0"

	# All checks passed — launch the worker.
	_ds_t0=$(_ds_now_ns)
	local _launch_rc=0
	_dispatch_launch_worker \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "$session_key" \
		"$model_override" "$issue_meta_json" || _launch_rc=$?
	_ds_record "$issue_number" "$repo_slug" "worker_launch_total" "$_ds_t0"
	if [[ "$_launch_rc" -ne 0 ]]; then
		local _launch_abort_reason="worker_launch_rc_${_launch_rc}"
		if [[ -n "${_DLW_LAST_PRE_RUNTIME_FAILURE:-}" ]]; then
			_launch_abort_reason="${_launch_abort_reason}:${_DLW_LAST_PRE_RUNTIME_FAILURE}"
		fi
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "$_launch_abort_reason"
	fi

	# t3034: record total ceremony time
	_ds_record "$issue_number" "$repo_slug" "ceremony_total" "$_ds_ceremony_t0"
	return "$_launch_rc"
}

#######################################
# t2063: Pre-dispatch brief-body freshness guard.
#
# If a task brief file exists at `${repo_path}/todo/tasks/${task_id}-brief.md`
# but the issue body does not contain the `## Task Brief` or `## Worker Guidance`
# marker, force-enrich the body via issue-sync-helper.sh. This ensures the
# worker sees the full implementation context on its first read of the issue,
# eliminating the ~1500-3000 token exploration overhead of hunting for the
# brief file inside the worktree.
#
# Defence-in-depth: the primary fixes in claim-task-id.sh (_compose_issue_body)
# and issue-sync-helper.sh (_enrich_update_issue) should make this a no-op in
# all normal paths. This guard catches:
#   - Legacy issues created via the pre-t2063 bare path before the TODO push
#   - Any future path that bypasses both primary fixes
#   - Briefs added after the issue was created
#
# Non-fatal: always returns 0 so dispatch proceeds even if enrich fails.
# The worker will still run, just with the pre-t2063 context cost.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - repo_path (local checkout)
#   $4 - issue_title (used to extract task ID)
#######################################
_ensure_issue_body_has_brief() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local issue_title="$4"
	# t2996: optional pre-fetched issue JSON (full bundle from
	# dispatch_with_dedup including `.body`). Skips the duplicate
	# `gh issue view --json body` call that this guard would otherwise
	# make as the 5th gh hit on the same candidate. Falls back to a
	# fresh fetch when omitted (defence-in-depth callers).
	local pre_fetched_json="${5:-}"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$issue_title" =~ (t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"
	[[ -z "$task_id" ]] && return 0

	# Check for brief file on disk
	local brief_file="${repo_path}/todo/tasks/${task_id}-brief.md"
	[[ ! -f "$brief_file" ]] && return 0

	# Check if body already has substantial content (framework-synced markers OR
	# an externally-composed brief-style body).
	# Layer 4 (t2377): the narrow marker check mis-classified externally-
	# composed bodies as stubs. #19778/#19779/#19780 had "## What" / "## Why" /
	# "## How" bodies ~5KB each; the old check treated them as stubs and
	# force-enriched them into emptiness.
	local current_body
	if [[ -n "$pre_fetched_json" ]] &&
		printf '%s' "$pre_fetched_json" | jq -e '.body' >/dev/null 2>&1; then
		current_body=$(printf '%s' "$pre_fetched_json" | jq -r '.body // ""' 2>/dev/null) || current_body=""
	else
		# t3027: route through gh_issue_view wrapper for REST fallback under
		# GraphQL exhaustion. The `body` field name is identical between gh
		# native and REST shape, so --jq '.body' works on both paths.
		current_body=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json body --jq '.body' 2>/dev/null || echo "")
	fi
	if [[ "$current_body" == *"## Task Brief"* ]] || [[ "$current_body" == *"## Worker Guidance"* ]]; then
		return 0
	fi
	# Brief-template-style headings count as substantial content too (layer 4).
	if [[ "$current_body" == *"## What"* ]] && [[ "$current_body" == *"## How"* ]]; then
		return 0
	fi
	# Fallback length heuristic: 500+ chars is unlikely to be a stub (layer 4).
	# Real stubs from claim-task-id.sh are <200 chars.
	if [[ ${#current_body} -ge 500 ]]; then
		return 0
	fi

	# Layer 5 (t2377): refuse to force-enrich when the task has a brief on disk
	# but no TODO.md entry. This combination makes compose_issue_body fail, and
	# the resulting empty body previously destroyed the issue content. The
	# correct behaviour in this case is: leave the existing (externally-
	# composed) body alone; the worker will read the brief from disk directly.
	local todo_file="${repo_path}/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_id_ere
		# shellcheck disable=SC2016  # $ inside single quotes is a literal regex metachar, not a shell expansion
		task_id_ere=$(printf '%s' "$task_id" | sed 's/[].[\*^$()+?{|]/\\&/g')
		if ! grep -qE "^[[:space:]]*- \[.\] ${task_id_ere}( |$)" "$todo_file" 2>/dev/null; then
			echo "[dispatch_with_dedup] t2377: issue #${issue_number} has brief but no TODO.md entry; skipping force-enrich (safe: worker will read brief from disk)" >>"$LOGFILE"
			return 0
		fi
	fi

	# GH#19856: cross-runner dedup guard — before force-enriching, verify no
	# other runner holds an active claim. Even though dispatch_with_dedup
	# runs its dedup check upstream, this guard catches TOCTOU races where
	# another runner claims between the dedup check and the enrich call.
	local dedup_helper
	# GH#19922: use parameter expansion instead of external dirname command.
	dedup_helper="${BASH_SOURCE[0]%/*}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]]; then
		local _dedup_out=""
		# GH#19922/GH#28498: preserve the self-login exemption while using the
		# read-only guard so enrichment cannot stale-recover active ownership.
		_dedup_out=$("$dedup_helper" is-assigned-read-only "$issue_number" "$repo_slug" "${AIDEVOPS_SESSION_USER:-}" 2>/dev/null) || true
		if [[ -n "$_dedup_out" ]]; then
			echo "[dispatch_with_dedup] GH#19856: skipping force-enrich for #${issue_number} — active claim: ${_dedup_out}" >>"$LOGFILE"
			return 0
		fi
	fi

	# Brief exists but body is a stub — force-enrich before worker sees it.
	# Run enrich from the repo_path so `find_project_root` resolves correctly,
	# and pass REPO_SLUG + FORCE_ENRICH via env so the helper skips the body
	# preservation gate and targets the right repo.
	echo "[dispatch_with_dedup] t2063: issue #${issue_number} has brief on disk but stub body — force-enriching" >>"$LOGFILE"
	local issue_sync_helper
	issue_sync_helper="$(dirname "${BASH_SOURCE[0]}")/issue-sync-helper.sh"
	if [[ -x "$issue_sync_helper" ]]; then
		(
			cd "$repo_path" 2>/dev/null || exit 0
			FORCE_ENRICH=true REPO_SLUG="$repo_slug" "$issue_sync_helper" enrich "$task_id" >>"$LOGFILE" 2>&1
		) || {
			echo "[dispatch_with_dedup] t2063: force-enrich failed for #${issue_number}; proceeding with stub body" >>"$LOGFILE"
		}
	fi
	return 0
}

#######################################
# GH#19118: Run the pre-dispatch validator for auto-generated issues.
#
# Delegates to pre-dispatch-validator-helper.sh validate <issue> <slug>.
# Non-fatal wrapper: if the helper is missing or fails unexpectedly, logs
# a warning and returns 0 (validator error semantics = dispatch proceeds).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0  — dispatch proceeds (validator passed, unregistered generator, or helper missing)
#   10 — premise falsified; caller must NOT dispatch (issue already closed by validator)
#   20 — validator error; caller should log warning and continue dispatch
#   30 — duplicate-state uncertainty; caller must fail closed
#######################################
_record_tier_policy_output() {
	local helper_output="$1"
	if [[ -z "$helper_output" ]]; then
		return 0
	fi
	printf '%s\n' "$helper_output" >>"$LOGFILE"
	if [[ "$helper_output" == *"[aidevops:tier-labels-mutated]"* ]]; then
		_TIER_LABELS_MUTATED=1
	fi
	return 0
}

_run_predispatch_validator() {
	local issue_number="$1"
	local repo_slug="$2"

	local validator_helper
	validator_helper="$(dirname "${BASH_SOURCE[0]}")/pre-dispatch-validator-helper.sh"
	if [[ ! -x "$validator_helper" ]]; then
		echo "[dispatch_with_dedup] GH#19118: pre-dispatch-validator-helper.sh not found — validator unavailable" >>"$LOGFILE"
		return 20
	fi

	local validator_rc=0 validator_output=""
	validator_output=$("$validator_helper" validate "$issue_number" "$repo_slug" 2>&1) || validator_rc=$?
	_record_tier_policy_output "$validator_output"
	return "$validator_rc"
}

#######################################
# t2389: tier:simple body-shape check wrapper (GH#19929).
#
# Invokes tier-simple-body-shape-helper.sh on any issue tagged tier:simple;
# the helper auto-downgrades to tier:standard + posts a feedback comment
# when the body contains a disqualifier from reference/task-taxonomy.md
# "Tier Assignment Validation". Non-blocking by design — always exits 0
# from the helper's perspective (dispatch always proceeds, at whatever
# tier the labels now indicate).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0 — always (non-blocking by design)
#######################################
_run_tier_simple_body_shape_check() {
	local issue_number="$1"
	local repo_slug="$2"

	local check_helper
	check_helper="$(dirname "${BASH_SOURCE[0]}")/tier-simple-body-shape-helper.sh"
	if [[ ! -x "$check_helper" ]]; then
		# Helper missing is non-fatal — just log and continue. The dispatch
		# pipeline must never block on a missing optional helper.
		echo "[dispatch_with_dedup] t2389: tier-simple-body-shape-helper.sh not found — skipping" >>"$LOGFILE"
		return 0
	fi

	# Always pass regardless of helper exit code. Capture the mutation marker so
	# the caller can refresh bundled metadata once after all tier policy checks.
	local check_output=""
	check_output=$("$check_helper" check "$issue_number" "$repo_slug" 2>&1) || true
	_record_tier_policy_output "$check_output"
	return 0
}

#######################################
# Refresh bundled issue metadata after tier policy label mutation.
#
# The simple-contract guard and self-hosting detector may normalize tier labels
# on GitHub. Refresh once when either emitted the internal mutation marker so
# eligibility and worker model resolution consume the normalized single tier.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - current issue_meta_json bundle
#   $4 - mutation flag (1 when a policy helper changed labels)
#
# Output:
#   refreshed issue_meta_json when available; otherwise the original bundle
# Exit codes:
#   0 — always (fail-open metadata refresh)
#######################################
_refresh_issue_meta_after_tier_policy_checks() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local tier_labels_mutated="$4"

	if [[ "$tier_labels_mutated" != "1" ]]; then
		printf '%s' "$issue_meta_json"
		return 0
	fi

	local refreshed_issue_meta_json
	refreshed_issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,body,author 2>/dev/null) || refreshed_issue_meta_json=""
	if [[ -z "$refreshed_issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] unable to refresh issue metadata after tier policy mutation for #${issue_number} in ${repo_slug}; continuing with original snapshot" >>"$LOGFILE"
		printf '%s' "$issue_meta_json"
		return 0
	fi

	printf '%s' "$refreshed_issue_meta_json"
	return 0
}

#######################################
# Check issue comments for terminal blocker patterns (GH#5141)
#
# Scans the last N comments on an issue for known patterns that indicate
# a user-action-required blocker. Workers cannot resolve these — they
# require the repo owner to take a manual action (e.g., refresh a token,
# grant a scope, configure a secret). Dispatching workers against these
# issues wastes compute on guaranteed failures.
#
# Known terminal blocker patterns:
#   - workflow scope missing (token lacks `workflow` scope)
#   - token lacks scope / missing scope
#   - ACTION REQUIRED (supervisor-posted user-action comments)
#   - refusing to allow an OAuth App to create or update workflow
#   - authentication required / permission denied (persistent auth failures)
#
# When a blocker is detected, the function:
#   1. Adds `status:blocked` label to the issue
#   2. Posts a comment directing the user to the required action
#      (idempotent — checks for existing blocker comment first)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - (optional) max comments to scan (default: 5)
#
# Exit codes:
#   0 - terminal blocker detected (skip dispatch)
#   1 - no blocker found (safe to dispatch)
#   2 - API error (fail open — allow dispatch to proceed)
#######################################
#######################################
# Match terminal blocker patterns in comment bodies (GH#5627)
#
# Checks concatenated comment bodies against known blocker patterns.
# Returns blocker_reason and user_action via stdout (2 lines).
#
# Arguments:
#   $1 - all_bodies (concatenated comment text)
# Output: 2 lines to stdout (blocker_reason, user_action) — empty if no match
# Exit codes:
#   0 - blocker pattern matched
#   1 - no match
#######################################
_match_terminal_blocker_pattern() {
	local all_bodies="$1"
	local blocker_reason=""
	local user_action=""

	# Pattern 1: GitHub CLI too old for gh api --paginate --slurp
	if echo "$all_bodies" | grep -qiE 'unknown flag: --slurp'; then
		local gh_slurp_message=""
		if declare -F aidevops_gh_slurp_status_message >/dev/null 2>&1; then
			gh_slurp_message=$(aidevops_gh_slurp_status_message)
		else
			gh_slurp_message="GitHub CLI (gh) is too old for gh api --paginate --slurp; upgrade gh to >= 2.51.0."
		fi
		blocker_reason="GitHub CLI prerequisite failed — ${gh_slurp_message}"
		user_action="Upgrade GitHub CLI to a version that supports \`gh api --paginate --slurp\` (minimum gh ${AIDEVOPS_GH_MIN_SLURP_VERSION:-2.51.0}), then remove the \`status:blocked\` label."
	# Pattern 2: workflow scope missing
	elif echo "$all_bodies" | grep -qiE 'workflow scope|refusing to allow an OAuth App to create or update workflow|token lacks.*workflow'; then
		blocker_reason="GitHub token lacks \`workflow\` scope — workers cannot push workflow file changes"
		user_action="Run \`gh auth refresh -s workflow\` to add the workflow scope to your token, then remove the \`status:blocked\` label."
	# Pattern 3: generic token/auth scope issues
	elif echo "$all_bodies" | grep -qiE 'token lacks.*scope|missing.*scope.*token|token.*missing.*scope'; then
		blocker_reason="GitHub token is missing a required scope — workers cannot complete this task"
		user_action="Check the error details in the comments above, run \`gh auth refresh -s <missing-scope>\` to add the required scope, then remove the \`status:blocked\` label."
	# Pattern 4: ACTION REQUIRED (supervisor-posted)
	elif echo "$all_bodies" | grep -qF 'ACTION REQUIRED'; then
		blocker_reason="A previous supervisor comment flagged this issue as requiring user action"
		user_action="Read the ACTION REQUIRED comment above, complete the requested action, then remove the \`status:blocked\` label."
	# Pattern 5: persistent authentication/permission failures
	elif echo "$all_bodies" | grep -qiE 'authentication required.*workflow|permission denied.*workflow|push declined.*workflow'; then
		blocker_reason="Persistent authentication or permission failure for workflow files"
		user_action="Check your GitHub token scopes with \`gh auth status\`, refresh if needed with \`gh auth refresh -s workflow\`, then remove the \`status:blocked\` label."
	fi

	if [[ -z "$blocker_reason" ]]; then
		return 1
	fi

	echo "$blocker_reason"
	echo "$user_action"
	return 0
}

#######################################
# Apply terminal blocker labels and comment to an issue (GH#5627)
#
# Idempotent — checks for existing label and comment before acting.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - blocker_reason
#   $4 - user_action
#   $5 - all_bodies (for existing comment check)
#######################################
_apply_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_reason="$3"
	local user_action="$4"
	local all_bodies="$5"

	# Check if already labelled
	local existing_labels
	existing_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || existing_labels=""

	local already_blocked=0
	if [[ ",${existing_labels}," == *",status:blocked,"* ]]; then
		already_blocked=1
	fi

	# Add label if not already present (t2033: use set_issue_status to atomically
	# clear all sibling status:* labels, not just available/queued)
	if [[ "$already_blocked" -eq 0 ]]; then
		set_issue_status "$issue_number" "$repo_slug" "blocked" || true
	fi

	# Post comment if not already posted (idempotent — safe against concurrent pulses)
	local blocker_body="**Terminal blocker detected** (GH#5141) — skipping dispatch.

**Reason:** ${blocker_reason}

**Action required:** ${user_action}

---
*This issue will not be dispatched to workers until the blocker is resolved. Once you have completed the required action, remove the \`status:blocked\` label to re-enable dispatch.*"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"Terminal blocker detected" "$blocker_body"

	return 0
}

check_terminal_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_comments="${3:-5}"
	[[ "$max_comments" =~ ^[0-9]+$ ]] || max_comments=5

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: missing arguments" >>"$LOGFILE"
		return 2
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 2
	fi

	# Fetch the last N comments
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[ .[-${max_comments}:][] | {body: .body, created_at: .created_at} ]" 2>/dev/null)
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: API error (exit=$api_exit) for #${issue_number} in ${repo_slug} — failing open" >>"$LOGFILE"
		return 2
	fi

	if [[ -z "$comments_json" || "$comments_json" == "[]" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Concatenate comment bodies for pattern matching
	local all_bodies
	all_bodies=$(echo "$comments_json" | jq -r '.[].body // ""' 2>/dev/null)

	if [[ -z "$all_bodies" ]]; then
		return 1
	fi

	# Match against known terminal blocker patterns
	local pattern_output
	pattern_output=$(_match_terminal_blocker_pattern "$all_bodies") || return 1

	local blocker_reason="" user_action=""
	blocker_reason=$(echo "$pattern_output" | sed -n '1p')
	user_action=$(echo "$pattern_output" | sed -n '2p')

	# Apply labels and comment
	_apply_terminal_blocker "$issue_number" "$repo_slug" "$blocker_reason" "$user_action" "$all_bodies"

	echo "[pulse-wrapper] check_terminal_blockers: blocker detected for #${issue_number} in ${repo_slug} — ${blocker_reason}" >>"$LOGFILE"
	return 0
}
