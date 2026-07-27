#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Watchdog — Kill Actions and GitHub Updates
# =============================================================================
# Killing hung workers and updating GitHub issues after a watchdog kill:
#   - Graceful then force kill of the process tree
#   - Posting a comment on the GitHub issue with the kill reason
#   - Updating issue labels (status:available or status:blocked)
#   - Unlocking the issue and any linked PRs (t1934)
#   - Recording the failure in the fast-fail counter
#
# Usage: source "${SCRIPT_DIR}/worker-watchdog-kill.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_comment, set_issue_status, sourced by orchestrator)
#   - worker-lifecycle-common.sh (_kill_tree, _force_kill_tree, _format_duration,
#       _sanitize_log_field, _sanitize_markdown)
#   - worker-watchdog-detect.sh (extract_issue_number, extract_repo_slug,
#       extract_provider_from_cmd)
#   - worker-watchdog-ff.sh (_watchdog_record_failure_and_escalate)
#   - Globals: WORKER_DRY_RUN, WORKER_IDLE_CPU_THRESHOLD, WORKER_IDLE_TIMEOUT,
#       WORKER_PROGRESS_TIMEOUT, WORKER_THRASH_ELAPSED_THRESHOLD,
#       WORKER_THRASH_MESSAGE_THRESHOLD, IDLE_STATE_DIR, LOG_FILE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKER_WATCHDOG_KILL_LOADED:-}" ]] && return 0
_WORKER_WATCHDOG_KILL_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Kill Actions
# =============================================================================

#######################################
# Kill a worker and handle cleanup
#
# Arguments:
#   $1 - PID
#   $2 - reason (idle|stall|thrash|runtime)
#   $3 - command line
#   $4 - elapsed seconds
#   $5 - evidence summary (optional)
#######################################
kill_worker() {
	local pid="$1"
	local reason="$2"
	local cmd="$3"
	local elapsed_seconds="$4"
	local evidence_summary="${5:-}"

	local duration
	duration=$(_format_duration "$elapsed_seconds")
	local sanitized_cmd
	sanitized_cmd=$(_sanitize_log_field "$cmd")
	local sanitized_evidence=""
	if [[ -n "$evidence_summary" ]]; then
		sanitized_evidence=$(_sanitize_log_field "$evidence_summary")
	fi

	if [[ "$WORKER_DRY_RUN" == "true" ]]; then
		log_msg "DRY RUN: Would kill worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}${sanitized_evidence:+ evidence=${sanitized_evidence}}"
		echo "  DRY RUN: Would kill PID ${pid} (${reason}, running ${duration})"
		return 0
	fi

	log_msg "Killing worker PID=${pid} reason=${reason} elapsed=${duration} cmd=${sanitized_cmd}${sanitized_evidence:+ evidence=${sanitized_evidence}}"

	# Graceful kill first
	_kill_tree "$pid" || true
	sleep 2

	# Force kill if still alive
	if kill -0 "$pid" 2>/dev/null; then
		_force_kill_tree "$pid" || true
		log_msg "Force-killed worker PID=${pid}"
	fi

	# Clean up idle/stall tracking files
	rm -f "${IDLE_STATE_DIR}/idle-${pid}" "${IDLE_STATE_DIR}/stall-${pid}" "${IDLE_STATE_DIR}/stall-grace-${pid}" 2>/dev/null || true

	# Post-kill: update GitHub issue labels and comment
	post_kill_github_update "$cmd" "$reason" "$duration" "$evidence_summary"

	# Notify
	notify "Worker Watchdog" "Killed worker (${reason}) after ${duration}"

	return 0
}

# =============================================================================
# GitHub Issue Updates
# =============================================================================

#######################################
# Map kill reason to human-readable description and destination status
#
# Arguments:
#   $1 - kill reason (idle|stall|thrash|runtime|backoff|*)
#   $2 - formatted duration
#   $3 - evidence summary
# Output: "reason_desc|destination_status|destination_text" (pipe-separated)
#######################################
_post_kill_map_reason() {
	local reason="$1"
	local duration="$2"
	local evidence_summary="$3"

	local reason_desc=""
	local destination_status="status:available"
	local destination_text="This issue has been re-labeled \`status:available\` for re-dispatch. The next pulse or manual dispatch will pick it up."

	case "$reason" in
	idle) reason_desc="Worker process became idle (CPU below ${WORKER_IDLE_CPU_THRESHOLD}% for ${WORKER_IDLE_TIMEOUT}s) — likely completed or hit the OpenCode idle-state bug." ;;
	stall) reason_desc="Worker stopped producing output for ${WORKER_PROGRESS_TIMEOUT}s — likely stuck on API rate limiting or an unrecoverable error." ;;
	thrash)
		reason_desc="Worker hit zero-commit/high-message thrash guardrail (runtime >= ${WORKER_THRASH_ELAPSED_THRESHOLD}s, commits=0, messages >= ${WORKER_THRASH_MESSAGE_THRESHOLD})."
		destination_status="status:blocked"
		destination_text="This issue has been re-labeled \`status:blocked\` to prevent blind re-dispatch of the same failing strategy."
		;;
	runtime) reason_desc="Worker exceeded the ${duration} runtime ceiling — killed to prevent infinite loops." ;;
	backoff) reason_desc="Worker's provider is backed off in the headless-runtime state DB (${evidence_summary}). Worker was alive but making no progress — killed for immediate re-queue." ;;
	*) reason_desc="Worker killed by watchdog (reason: ${reason})." ;;
	esac

	echo "${reason_desc}|${destination_status}|${destination_text}"
	return 0
}

#######################################
# Post kill comment and update labels on a GitHub issue
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - reason description
#   $4 - formatted duration
#   $5 - evidence summary
#   $6 - destination status label
#   $7 - destination text
#######################################
_post_kill_github_comment_and_labels() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason_desc="$3"
	local duration="$4"
	local evidence_summary="$5"
	local destination_status="$6"
	local destination_text="$7"

	local comment_body="## Worker Watchdog Kill

**Reason:** ${reason_desc}

**Runtime:** ${duration}

**Diagnostic tail:** ${evidence_summary}

${destination_text}

**Retry guidance:** Post a blocker update describing a changed plan (or newly unblocked dependency), then move the issue back to \`status:available\` before re-dispatch.

_Automated by \`worker-watchdog.sh\` (t1419)_"
	comment_body=$(_sanitize_markdown "$comment_body")

	if gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$comment_body" 2>>"$LOG_FILE"; then
		log_msg "Posted kill comment on ${repo_slug}#${issue_number}"
	else
		log_msg "Failed to post comment on ${repo_slug}#${issue_number}"
	fi

	# t2033: atomic transition via set_issue_status. Strip the "status:" prefix
	# because the helper takes the bare name. For thrash kills destination is
	# status:blocked, otherwise status:available.
	local dest_bare="${destination_status#status:}"
	if ! set_issue_status "$issue_number" "$repo_slug" "$dest_bare" 2>>"$LOG_FILE"; then
		log_msg "Failed to update labels on ${repo_slug}#${issue_number}"
	fi

	return 0
}

#######################################
# Unlock an issue and any linked PRs after watchdog kill (t1934).
# Issues are locked at dispatch time (pulse-wrapper.sh lock_issue_for_worker)
# to prevent prompt injection. The watchdog must unlock on kill so the
# issue can be re-dispatched on the next pulse cycle.
# Non-fatal: unlock failures are logged but never block.
#######################################
_watchdog_unlock_issue_and_prs() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0

	# Unlock the issue
	gh issue unlock "$issue_number" --repo "$repo_slug" >/dev/null 2>&1 || true
	log_msg "Unlocked #${issue_number} in ${repo_slug} after watchdog kill (t1934)"

	# Unlock any open PRs linked to this issue
	local pr_numbers
	pr_numbers=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title --jq \
		"[.[] | select(.title | test(\"(GH)?#${issue_number}([^0-9]|$)\"))] | .[].number" \
		--limit 5 2>/dev/null) || pr_numbers=""

	local pr_num
	while IFS= read -r pr_num; do
		[[ -n "$pr_num" && "$pr_num" =~ ^[0-9]+$ ]] || continue
		gh pr unlock "$pr_num" --repo "$repo_slug" >/dev/null 2>&1 || true
		log_msg "Unlocked PR #${pr_num} in ${repo_slug} (linked to issue #${issue_number}) (t1934)"
	done <<<"$pr_numbers"

	return 0
}

#######################################
# Post-kill GitHub issue update
#
# Comments on the issue and swaps labels so the issue is re-queued.
#
# Arguments:
#   $1 - command line
#   $2 - kill reason
#   $3 - formatted duration
#   $4 - evidence summary (optional)
#######################################
post_kill_github_update() {
	local cmd="$1"
	local reason="$2"
	local duration="$3"
	local evidence_summary="${4:-No transcript evidence available.}"

	# Extract issue number and repo slug
	local issue_number
	issue_number=$(extract_issue_number "$cmd")
	local repo_slug
	repo_slug=$(extract_repo_slug "$cmd")

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		log_msg "Cannot update GitHub: issue=${issue_number:-unknown} repo=${repo_slug:-unknown}"
		return 0
	fi

	local mapped_reason
	mapped_reason=$(_post_kill_map_reason "$reason" "$duration" "$evidence_summary")
	local reason_desc destination_status destination_text
	IFS='|' read -r reason_desc destination_status destination_text <<<"$mapped_reason"

	_post_kill_github_comment_and_labels \
		"$issue_number" "$repo_slug" "$reason_desc" \
		"$duration" "$evidence_summary" \
		"$destination_status" "$destination_text"

	# t1934: Unlock issue and linked PRs after watchdog kill.
	# Issues are locked at dispatch time to prevent prompt injection.
	# The watchdog must unlock on kill so the issue can be re-dispatched.
	_watchdog_unlock_issue_and_prs "$issue_number" "$repo_slug"

	# Record failure in the fast-fail counter and escalate tier if threshold reached.
	# The fast-fail state file is shared with pulse-wrapper.sh — both use the same
	# JSON file so pulse can skip issues that the watchdog has flagged. (GH#2076)
	#
	# Classify crash type for crash-type-aware tier escalation:
	#   - "idle" kill = worker produced no LLM output → "no_work"
	#   - "thrash" kill = worker was active but zero-commit looping → "overwhelmed"
	#   - "backoff" = provider rate limit → "" (not a model capability issue)
	local provider
	provider=$(extract_provider_from_cmd "$cmd")
	local watchdog_crash_type=""
	case "$reason" in
	idle) watchdog_crash_type="no_work" ;;
	thrash) watchdog_crash_type="overwhelmed" ;;
	*) watchdog_crash_type="" ;;
	esac
	_watchdog_record_failure_and_escalate "$issue_number" "$repo_slug" "$reason" "$provider" "$watchdog_crash_type" || true

	return 0
}
