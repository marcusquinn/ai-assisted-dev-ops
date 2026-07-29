#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-issue-reconcile-stale.sh — Stale assignment recovery helpers (t2375)
#
# Extracted from pulse-issue-reconcile.sh (t2375) to keep that file below the
# 1500-line complexity gate after the cross-runner safety hardening in t2375
# added runner-identity parsing and fail-CLOSED paths. Mirrors the
# dispatch-dedup-stale.sh extraction pattern (GH#18916).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, PULSE_QUEUED_SCAN_LIMIT,
# WORKER_MAX_RUNTIME, and STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS.
#
# Exports:
#   _normalize_clear_status_labels     — Reset a stale issue's labels + assignee
#   _normalize_stale_get_dispatch_info — Read PID, timestamp, runner from dispatch comment
#   _normalize_stale_should_skip_reset — Gate reset decision (t1933 + t2375 cross-runner)
#   _normalize_unassign_stale          — Detect and reset stale runner assignments

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_STALE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_STALE_LOADED=1

#######################################
# (Phase 12 helper) Reset a single stale issue's labels and assignee.
#
# Removes the active dispatch labels (status:queued, status:in-progress)
# and the runner's assignee from one issue, then marks it status:available
# so the deterministic fill floor can re-dispatch it.
#
# Called by _normalize_unassign_stale once it has confirmed that no worker
# process is actively handling the issue.
#
# Args:
#   $1 issue_num   — numeric GitHub issue number
#   $2 slug        — owner/repo
#   $3 runner_user — GH login to remove as assignee
# Returns: 0 on gh success, non-zero on gh failure
#######################################
_normalize_clear_status_labels() {
	local issue_num="$1"
	local slug="$2"
	local runner_user="$3"

	# t2033: atomic transition to status:available, clearing all sibling
	# core status labels in one edit (not just queued/in-progress).
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_num" || true
	set_issue_status "$issue_num" "$slug" "available" \
		--remove-assignee "$runner_user" >/dev/null 2>&1
	return $?
}

#######################################
# (Phase 12 helper) Read the Worker PID, dispatch timestamp, and owning
# runner login from the most recent `Dispatching worker` comment on an issue.
#
# t2375: also parses the `**Runner**: <login>` field so the caller can gate
# cross-machine detection on runner identity rather than local PID presence.
# See pulse-dispatch-worker-launch.sh:463-470 for the comment format.
#
# Outputs three lines to stdout: Worker PID, ISO-8601 created_at, runner
# login. Each is blank if the field is missing from the comment (or no
# dispatch comment exists). All three lines may legitimately be empty on
# success — the caller distinguishes by checking which fields are populated.
#
# Args:
#   $1 slug       — owner/repo
#   $2 stale_num  — numeric GitHub issue number
# Returns: 0 on success (even if no dispatch comment found);
#          1 on gh api failure (caller should fail-CLOSED — skip reset).
#######################################
_normalize_stale_get_dispatch_info() {
	local slug="$1"
	local stale_num="$2"

	# t2375: capture gh output + exit code separately so we can distinguish
	# "no dispatch comment" (empty output, rc=0) from "gh api failure"
	# (rc!=0). The reactive path in dispatch-dedup-stale.sh:401-405 fails
	# CLOSED on the same signal; match that stance here.
	local gh_output
	local gh_rc=0
	gh_output=$(gh api "repos/${slug}/issues/${stale_num}/comments" \
		--jq '[.[] | select(.body | contains("Dispatching worker"))] | sort_by(.created_at) | last | if . then ((.body | capture("\\*\\*Worker PID\\*\\*: (?<pid>[0-9]+)") // {pid: ""} | .pid), (.created_at | sub("\\.[0-9]+Z$"; "Z")), (.body | capture("\\*\\*Runner\\*\\*: (?<runner>[A-Za-z0-9][A-Za-z0-9-]*)") // {runner: ""} | .runner)) else empty end' \
		2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 ]]; then
		return 1
	fi

	local dispatch_pid=""
	local dispatch_created_at=""
	local dispatch_runner=""
	{
		IFS= read -r dispatch_pid
		IFS= read -r dispatch_created_at
		IFS= read -r dispatch_runner
	} <<<"$gh_output"

	printf '%s\n%s\n%s\n' "$dispatch_pid" "$dispatch_created_at" "$dispatch_runner"
	return 0
}

#######################################
# (Phase 12 helper) Decide whether a stale-assigned issue should be skipped
# (worker still active) or reset (worker gone).
#
# Applies checks in order:
#   1. Local pgrep — is any process referencing this issue number still running?
#   2. Dispatch-comment ownership gate (t1933 + t2375):
#        - gh-api failure to fetch dispatch info → fail-CLOSED (skip).
#        - dispatch_runner != self_login → cross-machine worker. Skip `ps -p`
#          (PID collisions across machines are meaningless); apply time-based
#          expiry against WORKER_MAX_RUNTIME.
#        - dispatch_runner == self_login → local worker; use `ps -p` against
#          the recorded Worker PID.
#        - dispatch_runner empty but dispatch_pid present → legacy format,
#          fail-CLOSED (cannot verify ownership).
#   3. Worker log recency — local log written in last 10 min (local workers only).
#
# Returns: 0 = skip (worker still active or unverifiable), 1 = reset (worker gone)
#
# Args:
#   $1 stale_num                — numeric GitHub issue number
#   $2 slug                     — owner/repo
#   $3 now_epoch                — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before cross-runner dispatch expires
#   $5 self_login               — GH login of this runner (for identity gate)
#######################################
_normalize_stale_should_skip_reset() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local self_login="$5"

	# Check 1: local worker process still referencing this issue
	if pgrep -f "pulse-reconcile.*[^0-9]${stale_num}([^0-9]|$)" >/dev/null 2>&1 || pgrep -f "#${stale_num}([^0-9]|$)" >/dev/null 2>&1; then
		return 0
	fi

	# t2375: Read dispatch PID, timestamp, and runner from the most recent
	# dispatch comment. Fail-CLOSED on gh api error — match the reactive-path
	# stance in dispatch-dedup-stale.sh:401-405. A transient gh failure is
	# not evidence of staleness.
	local dispatch_info
	local dispatch_info_rc=0
	dispatch_info=$(_normalize_stale_get_dispatch_info "$slug" "$stale_num") || dispatch_info_rc=$?
	if [[ "$dispatch_info_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Stale assignment skip (gh-api fail-closed): #${stale_num} in ${slug} — cannot fetch dispatch info" >>"$LOGFILE"
		return 0
	fi

	local dispatch_pid=""
	local dispatch_created_at=""
	local dispatch_runner=""
	{
		IFS= read -r dispatch_pid
		IFS= read -r dispatch_created_at
		IFS= read -r dispatch_runner
	} <<<"$dispatch_info"

	local dispatch_comment_age=0
	if [[ -n "$dispatch_created_at" ]]; then
		local dispatch_epoch
		dispatch_epoch=$(date -u -d "$dispatch_created_at" '+%s' 2>/dev/null ||
			TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$dispatch_created_at" '+%s' 2>/dev/null ||
			echo "0")
		if [[ "$dispatch_epoch" -gt 0 ]]; then
			dispatch_comment_age=$((now_epoch - dispatch_epoch))
		fi
	fi

	# Check 2: t1933 + t2375 dispatch-ownership gate.
	if [[ -n "$dispatch_pid" ]] && [[ "$dispatch_pid" =~ ^[0-9]+$ ]]; then
		if [[ -z "$dispatch_runner" ]]; then
			# t2375 fail-closed: legacy dispatch comment without **Runner**
			# line. Cannot verify ownership, so skip reset — safer than
			# potentially stealing a live cross-machine worker's assignment.
			echo "[pulse-wrapper] Stale assignment skip (fail-closed legacy format): #${stale_num} in ${slug} — dispatch comment predates Runner field, cannot verify ownership" >>"$LOGFILE"
			return 0
		fi

		if [[ "$dispatch_runner" != "$self_login" ]]; then
			# t2375 cross-machine branch: dispatch came from another runner.
			# PID collision is meaningless across machines — skip `ps -p`
			# and rely on time-based expiry against WORKER_MAX_RUNTIME.
			if [[ "$dispatch_comment_age" -lt "$cross_runner_max_runtime" ]]; then
				echo "[pulse-wrapper] Stale assignment skip (cross-runner guard): #${stale_num} in ${slug} — runner=${dispatch_runner} != self=${self_login}, comment age ${dispatch_comment_age}s < max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
				return 0
			fi
			echo "[pulse-wrapper] Stale assignment reset (cross-runner expired): #${stale_num} in ${slug} — runner=${dispatch_runner} != self=${self_login}, comment age ${dispatch_comment_age}s >= max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
			# Fall through — reset fires (return 1 below unless Check 3 catches a stray local log).
		else
			# t1933 local branch: dispatch_runner == self_login. PID check
			# is authoritative here. If our own PID is still running, skip;
			# otherwise fall through to Check 3 (local log) and reset.
			if ps -p "$dispatch_pid" >/dev/null 2>&1; then
				return 0
			fi
			echo "[pulse-wrapper] Stale assignment reset candidate (local worker gone): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not running, comment age ${dispatch_comment_age}s" >>"$LOGFILE"
		fi
	fi

	# Check 3: worker log recency — log written in last 10 min means worker may still be active
	local worker_log=""
	worker_log=$(aidevops_pulse_worker_log_path "$slug" "$stale_num" 2>/dev/null || true)
	if [[ -f "$worker_log" ]]; then
		local log_mtime
		log_mtime=$(_file_mtime_epoch "$worker_log")
		if [[ $((now_epoch - log_mtime)) -lt 600 ]]; then
			return 0
		fi
	fi

	return 1
}

#######################################
# (Phase 12) Detect and reset stale runner assignments.
#
# Pass 2 of normalize_active_issue_assignments: find issues assigned to
# runner_user with status:queued/in-progress whose updatedAt is older than
# STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS (default 600s = 10 min), verify
# no worker process is handling them (via _normalize_stale_should_skip_reset),
# and reset via _normalize_clear_status_labels so they can be re-dispatched.
#
# t2372: outer time filter lowered from 3600s (1h) to 600s (10 min) so this
# proactive sweep matches the reactive _is_stale_assignment threshold in
# dispatch-dedup-stale.sh. Previously a worker that died between dispatch
# and PR creation stayed assigned for ~60 min before this sweep would even
# consider it as a candidate, because the issue's updatedAt (the dispatch
# comment timestamp) was still within the 1h window. The reactive path
# (Layer 6 dedup) only fires when the pulse retries dispatching the same
# issue, which may not happen for hours under queue pressure.
#
# Inner safeguards in _normalize_stale_should_skip_reset still protect
# live workers (local pgrep, dispatch-comment ownership gate with
# WORKER_MAX_RUNTIME cross-runner expiry, worker log mtime <600s). Lowering
# the outer filter expands the candidate set; the inner guards still gate
# the actual reset. Override via env var:
#
#   STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=N (default 600)
#
# t1933 + t2375: cross-runner safety is gated on the dispatch comment's
# `**Runner**: <login>` field. When dispatch_runner != self_login, the
# sweep skips local `ps -p` entirely (PID collisions across machines are
# meaningless) and relies on time-based expiry against
# WORKER_MAX_RUNTIME. When dispatch_runner == self_login, local PID and
# log checks are authoritative. Legacy dispatch comments without a
# `**Runner**` line and gh-api failures both fail CLOSED (skip reset) —
# matches the reactive path in dispatch-dedup-stale.sh:401-405.
#
# Args:
#   $1 runner_user              — GH login of the current runner
#   $2 repos_json               — path to repos.json
#   $3 now_epoch                — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before a cross-runner dispatch is
#                                  considered expired (default: WORKER_MAX_RUNTIME)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_unassign_stale() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"

	# t2372: tunable outer-filter age. Default matches the reactive
	# STALE_ASSIGNMENT_THRESHOLD_SECONDS=600 in dispatch-dedup-stale.sh so
	# proactive (this sweep) and reactive (Layer 6 dedup) paths agree on
	# what "stale" means for workers. Validate as int; fall back to 600.
	local _stale_threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
	[[ "$_stale_threshold" =~ ^[0-9]+$ ]] || _stale_threshold=600

	local total_reset=0
	local total_candidates=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$slug"; then
			continue
		fi

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json
		stale_json=$(gh_issue_list --repo "$slug" --assignee "$runner_user" --state open \
			--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		[[ -n "$stale_json" && "$stale_json" != "null" ]] || continue

		# Filter: has status:queued or status:in-progress, updatedAt older than _stale_threshold
		local stale_issues
		stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - _stale_threshold))" '
			[.[] | select(
				((.labels | map(.name)) | (index("status:queued") or index("status:in-progress")))
				and ((.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]
		' 2>/dev/null) || stale_issues=""
		[[ -n "$stale_issues" ]] || continue

		local stale_num
		while IFS= read -r stale_num; do
			[[ "$stale_num" =~ ^[0-9]+$ ]] || continue
			total_candidates=$((total_candidates + 1))

			if _normalize_stale_should_skip_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime" "$runner_user"; then
				continue
			fi

			# No active worker and all guards passed — reset for re-dispatch
			echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
			_normalize_clear_status_labels "$stale_num" "$slug" "$runner_user" || true
			total_reset=$((total_reset + 1))
		done <<<"$stale_issues"
	done < <(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	# t2372: always log scan summary so silent runs are visible in pulse log
	# and operators can confirm the sweep is firing per-cycle.
	echo "[pulse-wrapper] Stale assignment scan: threshold=${_stale_threshold}s candidates=${total_candidates} reset=${total_reset}" >>"$LOGFILE"

	return 0
}
