#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-stale.sh — Stale assignment recovery subsystem (GH#15060, t2008)
#
# Extracted from dispatch-dedup-helper.sh (GH#18916) to reduce that file below
# the 2000-line simplification gate.
#
# Sourced by dispatch-dedup-helper.sh. Do NOT invoke directly.
#
# Exports:
#   STALE_ASSIGNMENT_THRESHOLD_SECONDS — configurable staleness window (default 600s)
#   _ts_to_epoch <iso8601>             — portable ISO→epoch conversion
#   _is_stale_assignment <issue> <slug> <assignees>
#   _recover_stale_assignment <issue> <slug> <assignees> <reason>

#######################################
# Configurable staleness threshold (seconds).
# GH#17549: Reduced from 30 min to 10 min to match DISPATCH_COMMENT_MAX_AGE.
# Workers either succeed in ~10 min or crash in ~2 min; 30-min TTL wasted
# 28 min of dispatch capacity per crash.
#######################################
STALE_ASSIGNMENT_THRESHOLD_SECONDS="${STALE_ASSIGNMENT_THRESHOLD_SECONDS:-${DISPATCH_COMMENT_MAX_AGE:-600}}"
_DDS_NMR_LABEL="needs-maintainer-review"
_DDS_KIND_DRAFT="draft_checkpoint"
_DDS_KIND_READY="ready"
_DDS_KIND_READY_FAILED="ready_failed"

#######################################
# t2132: Separate threshold for interactive claims.
# Interactive sessions routinely go 30-60+ minutes between actions on an issue
# (writing briefs, reading code, thinking). The default 600s threshold designed
# for headless workers was stripping interactive claims after 10 minutes.
# Default: 7200s (2 hours).
#######################################
INTERACTIVE_STALE_THRESHOLD_SECONDS="${INTERACTIVE_STALE_THRESHOLD_SECONDS:-7200}"

#######################################
# Convert ISO 8601 timestamp to epoch seconds
# Handles both "2026-03-31T23:59:07Z" and "2026-03-31T23:59:07+00:00" formats.
# Bash 3.2 compatible (no date -d on macOS).
# Args: $1 = ISO timestamp
# Returns: epoch seconds on stdout
#######################################
_ts_to_epoch() {
	local ts="$1"
	# macOS date -j -f parses a formatted date string
	if [[ "$(uname)" == "Darwin" ]]; then
		# Strip trailing Z or timezone offset for macOS date parsing
		local clean_ts="${ts%%Z*}"
		clean_ts="${clean_ts%%+*}"
		# GH#17699: TZ=UTC is critical — without it, macOS date interprets
		# the input as local time, making UTC timestamps appear TZ-offset
		# seconds older than they are (e.g. BST/UTC+1 = 3600s too old).
		TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" "+%s" 2>/dev/null || echo "0"
	else
		date -d "$ts" "+%s" 2>/dev/null || echo "0"
	fi
	return 0
}

#######################################
# Load the stale-recovery escalation threshold from config (default 2).
# Sources .agents/configs/dispatch-stale-recovery.conf if present.
# Output: integer threshold on stdout
#######################################
_stale_recovery_load_threshold() {
	# SCRIPT_DIR is set by the sourcing file (dispatch-dedup-helper.sh)
	local _stale_conf="${SCRIPT_DIR}/../configs/dispatch-stale-recovery.conf"
	if [[ -f "$_stale_conf" ]]; then
		# shellcheck source=/dev/null
		source "$_stale_conf"
	fi
	printf '%s' "${STALE_RECOVERY_THRESHOLD:-2}"
	return 0
}

#######################################
# Count prior non-reset stale-recovery-tick comments on an issue
# (cross-runner counter). Fails open: returns 0 on gh failure.
# Args: $1 = issue number, $2 = repo slug
# Output: integer count on stdout
#######################################
_stale_recovery_count_ticks() {
	local issue_number="$1"
	local repo_slug="$2"
	local _comments_pages _prior_ticks
	_comments_pages=$(_stale_recovery_fetch_comments_pages "$issue_number" "$repo_slug") || _comments_pages=""
	if [[ -z "$_comments_pages" ]]; then
		printf '0'
		return 0
	fi
	_prior_ticks=$(_stale_recovery_count_ticks_from_pages "$_comments_pages") || _prior_ticks=0
	[[ "$_prior_ticks" =~ ^[0-9]+$ ]] || _prior_ticks=0
	printf '%s' "$_prior_ticks"
	return 0
}

#######################################
# Fetch issue comments as one slurped JSON document.
# Args: $1 = issue number, $2 = repo slug
# Output: slurped comments pages JSON, or empty on gh failure
#######################################
_stale_recovery_fetch_comments_pages() {
	local issue_number="$1"
	local repo_slug="$2"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --slurp 2>/dev/null || true
	return 0
}

#######################################
# Count non-reset stale recovery ticks from a slurped comments JSON document.
# Args: $1 = slurped comments pages JSON
# Output: integer tick count
#######################################
_stale_recovery_count_ticks_from_pages() {
	local comments_pages="$1"
	local prior_ticks
	prior_ticks=$(printf '%s' "$comments_pages" | jq \
		'[
			.[] | .[]?
			| select(.body | (test("<!-- stale-recovery-tick:[1-9]") and (test("reset") | not)))
		] | length' \
		2>/dev/null) || prior_ticks=0
	[[ "$prior_ticks" =~ ^[0-9]+$ ]] || prior_ticks=0
	printf '%s' "$prior_ticks"
	return 0
}

#######################################
# Find the latest dispatch/claim timestamp in slurped GitHub comments.
# GitHub comments remain the multi-user/multi-machine coordination source.
# Args: $1 = slurped comments pages JSON
# Output: ISO timestamp or empty
#######################################
_stale_recovery_latest_dispatch_ts_from_pages() {
	local comments_pages="$1"
	printf '%s' "$comments_pages" | jq -r '
		[
			.[] | .[]?
			| select((.body // "") | test("Dispatching worker|DISPATCH_CLAIM|Worker \\(PID|Interactive session claimed"; "i"))
		] | sort_by(.created_at) | last | .created_at // empty
	' 2>/dev/null || true
	return 0
}

_stale_recovery_final_evidence_recheck() {
	local issue_number="$1"
	local repo_slug="$2"
	local expected_dispatch_ts="$3"
	local pages="" latest_dispatch_ts="" now_epoch=""
	pages=$(_stale_recovery_fetch_comments_pages "$issue_number" "$repo_slug")
	[[ -n "$pages" ]] || return 1
	latest_dispatch_ts=$(_stale_recovery_latest_dispatch_ts_from_pages "$pages")
	[[ "$latest_dispatch_ts" == "$expected_dispatch_ts" ]] || return 1
	now_epoch=$(date +%s)
	local comments="" claims="" parsed=""
	comments=$(printf '%s' "$pages" | jq -c '[.[] | .[]?]' 2>/dev/null) || return 1
	claims=$(printf '%s' "$comments" | jq -c '[.[] | select((.body // "") | contains("DISPATCH_CLAIM nonce="))]' 2>/dev/null) || return 1
	parsed=$(printf '%s' "$claims" | jq -c --argjson now "$now_epoch" --argjson max_age 2147483647 \
		--argjson include_terminal false --argjson comments "$comments" \
		-f "${SCRIPT_DIR}/dispatch-lease-claims.jq" 2>/dev/null) || return 1
	if printf '%s' "$parsed" | jq -e 'any(.lease_phase == "ready")' >/dev/null 2>&1; then
		return 1
	fi
	# PID exit is deliberately absent: remote completion requires durable evidence.
	return 0
}

#######################################
# Check for terminal worker-failure evidence after a dispatch timestamp.
# Stale escalation should not infer failure from GitHub silence alone; in a
# multi-runner system, the issue comment stream must contain an explicit worker
# terminal marker before historical stale ticks suspend future dispatch.
# Args: $1 = slurped comments pages JSON, $2 = dispatch timestamp
# Returns: 0 if terminal evidence exists, 1 otherwise
#######################################
_stale_recovery_has_terminal_evidence_since() {
	local comments_pages="$1"
	local since_ts="$2"
	[[ -z "$since_ts" ]] && return 1
	if printf '%s' "$comments_pages" | jq -e --arg since "$since_ts" '
		[
			.[] | .[]?
			| select((.created_at // "") > $since)
			| select((.body // "") | test("CLAIM_RELEASED reason=worker_failed|Worker Watchdog Kill|provider is backed off|reason=rate_limit|headless-runtime state DB"; "i"))
		] | length > 0
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Classify an open PR referencing this issue for stale recovery.
# Output: "number|ready|ready_failed|draft_checkpoint|protected_draft".
# Args: $1 = issue number, $2 = repo slug
# Output: PR number (or empty) on stdout
#######################################
_stale_recovery_find_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local _open_pr _open_pr_json
	_open_pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 20 \
		--json number,isDraft,labels,statusCheckRollup 2>/dev/null) || _open_pr_json="[]"
	_open_pr=$(printf '%s' "$_open_pr_json" | jq -r \
		--arg ready_failed "$_DDS_KIND_READY_FAILED" \
		--arg ready "$_DDS_KIND_READY" \
		--arg draft "$_DDS_KIND_DRAFT" '
			def names: [.labels[]?.name];
			def protected: names | any(
				. == "origin:interactive" or . == "hold-for-review" or
				. == "no-auto-dispatch" or . == "needs-maintainer-review"
			);
			def worker_owned: names | any(. == "origin:worker" or . == "origin:worker-takeover");
			def successful_review_status:
				[.statusCheckRollup[]? |
					select((.__typename // "") == "StatusContext" and
						((.context // "") | ascii_downcase) == "review-bot-gate") |
					(.state // "" | ascii_upcase)] | any(. == "SUCCESS");
			def terminal_failure:
				successful_review_status as $review_pass |
				[.statusCheckRollup[]? |
					select((
						$review_pass and (.__typename // "") == "CheckRun" and
						((.name // "") | ascii_downcase | contains("review-bot-gate"))
					) | not) |
					(.conclusion // .status // .state // empty) | ascii_upcase] |
				any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or
					. == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STALE");
			def kind:
				if (.isDraft != true) and terminal_failure then $ready_failed
				elif .isDraft != true then $ready
				elif worker_owned and (protected | not) then $draft
				else "protected_draft" end;
			map(. + {lifecycle_kind: kind}) |
			sort_by(if .lifecycle_kind == $ready_failed then 0
				elif .lifecycle_kind == $ready then 1
				elif .lifecycle_kind == $draft then 2 else 3 end) |
			.[0] | if . then "\(.number)|\(.lifecycle_kind)" else "" end' \
		2>/dev/null) || _open_pr=""
	printf '%s' "$_open_pr"
	return 0
}

#######################################
# Verify that a blocking NMR transition is visible before releasing ownership.
# Args: issue number, repo slug, stale assignees CSV
#######################################
_stale_recovery_verify_blocking_transition() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local issue_json=""

	issue_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e --arg nmr "$_DDS_NMR_LABEL" --arg stale "$stale_assignees" '
		($stale | split(",") | map(select(length > 0))) as $stale_users |
		([.labels[]?.name]) as $labels |
		([.assignees[]?.login]) as $current_users |
		.state == "OPEN" and
		($labels | index($nmr)) != null and
		($labels | index("status:queued")) == null and
		($labels | index("status:in-progress")) == null and
		([ $stale_users[] as $user | select(($current_users | index($user)) != null) ] | length == 0)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Escalate an exhausted worker draft or terminally failed ready PR. Protected
# drafts never call this path. Ownership is retained unless the blocking label
# and assignee/status transition can be read back from GitHub.
# Args: issue, repo, stale assignees, reason, PR number, dispatch ts, kind
#######################################
_stale_recovery_escalate_pr_checkpoint() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"
	local pr_number="$5"
	local expected_dispatch_ts="${6:-}"
	local checkpoint_kind="${7:-$_DDS_KIND_DRAFT}"
	local description="worker draft PR"
	local event="STALE_DRAFT_ESCALATED"
	local old_ifs="${IFS-}"
	local ifs_was_set=0
	local assignee=""
	local -a assignees=()
	local -a transition_args=(--add-label "$_DDS_NMR_LABEL" --remove-label "auto-dispatch")

	if [[ "$checkpoint_kind" == "$_DDS_KIND_READY_FAILED" ]]; then
		description="ready PR with terminally failed checks"
		event="STALE_READY_FAILED_ESCALATED"
	fi
	if ! _stale_recovery_final_evidence_recheck "$issue_number" "$repo_slug" "$expected_dispatch_ts"; then
		printf 'STALE_RECHECK_BLOCKED: issue #%s in %s — evidence changed before PR escalation\n' "$issue_number" "$repo_slug"
		return 0
	fi

	[[ -n "${IFS+x}" ]] && ifs_was_set=1
	IFS=',' read -ra assignees <<<"$stale_assignees"
	if [[ "$ifs_was_set" -eq 1 ]]; then
		IFS="$old_ifs"
	else
		unset IFS
	fi
	for assignee in "${assignees[@]}"; do
		[[ -n "$assignee" ]] && transition_args+=(--remove-assignee "$assignee")
	done

	if ! set_issue_status "$issue_number" "$repo_slug" "" "${transition_args[@]}"; then
		printf 'STALE_PR_ESCALATION_FAILED: issue #%s in %s — blocking transition failed; ownership retained\n' "$issue_number" "$repo_slug"
		return 1
	fi
	if ! _stale_recovery_verify_blocking_transition "$issue_number" "$repo_slug" "$stale_assignees"; then
		printf 'STALE_PR_ESCALATION_FAILED: issue #%s in %s — blocking transition not visible; ownership retained\n' "$issue_number" "$repo_slug"
		return 1
	fi

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- stale-pr-checkpoint:escalated pr=${pr_number} kind=${checkpoint_kind} -->
**PR checkpoint requires continuation review**

The ${description} #${pr_number} preserves committed progress but is not completion evidence. Ordinary redispatch remains blocked to avoid a competing implementation.

Previously assigned to: ${stale_assignees}
Stale reason: ${reason}

Applied \`${_DDS_NMR_LABEL}\`. Continue or repair the existing PR before re-enabling dispatch.
<!-- ops:end -->" 2>/dev/null || true
	printf '%s: issue #%s in %s — PR #%s preserved, applied %s\n' \
		"$event" "$issue_number" "$repo_slug" "$pr_number" "$_DDS_NMR_LABEL"
	return 0
}

#######################################
# Look up the most recent open PR activity referencing this issue.
# This is a targeted fallback only used after issue comments look stale, so
# branch pushes / draft PR updates can act as natural liveness signals without
# posting extra heartbeat comments on the issue.
# Args: $1 = issue number, $2 = repo slug
# Output: "<number>|<updatedAt>" (or empty)
#######################################
_stale_recovery_find_open_pr_activity() {
	local issue_number="$1"
	local repo_slug="$2"
	local _open_pr
	_open_pr=$(gh pr list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 1 \
		--json number,updatedAt --jq '.[0] | if . then "\(.number)|\(.updatedAt // "")" else "" end') || _open_pr=""
	printf '%s' "$_open_pr"
	return 0
}

#######################################
# Escalate to needs-maintainer-review after the stale-recovery threshold
# is reached (t2008).
#
# Unassigns stale workers, clears status labels via set_issue_status, adds
# needs-maintainer-review, and posts an explanatory comment. Emits
# STALE_ESCALATED on stdout for caller pattern matching.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason for latest stale
#   $5 = threshold
#   $6 = prior tick count
# Returns: 0 (always — all gh ops are fire-and-forget)
#######################################
_stale_recovery_escalate() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"
	local _threshold="$5"
	local _prior_ticks="$6"
	local expected_dispatch_ts="${7:-}"
	if ! _stale_recovery_final_evidence_recheck "$issue_number" "$repo_slug" "$expected_dispatch_ts"; then
		printf 'STALE_RECHECK_BLOCKED: issue #%s in %s — evidence changed before escalation\n' "$issue_number" "$repo_slug"
		return 0
	fi

	# Unassign stale workers (still needed to clean up the assignment)
	local _esc_ifs="${IFS:-}"
	local -a _esc_assignee_arr=()
	IFS=',' read -ra _esc_assignee_arr <<<"$stale_assignees"
	IFS="$_esc_ifs"
	# t2033: build remove-assignee flags and clear all core status labels
	# in one atomic edit via set_issue_status (empty target = clear only).
	# NMR is a dispatch hold, so remove auto-dispatch in the same mutation;
	# otherwise a racing recovery can restore status:available and make the
	# held issue look runnable to idle-backoff even though dispatch rejects it.
	local -a _esc_extra=(
		--add-label "$_DDS_NMR_LABEL"
		--remove-label "auto-dispatch"
	)
	for _esc_assignee in "${_esc_assignee_arr[@]}"; do
		_esc_extra+=(--remove-assignee "$_esc_assignee")
	done
	set_issue_status "$issue_number" "$repo_slug" "" "${_esc_extra[@]}" || true

	# Post escalation comment explaining the suspension
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- stale-recovery-tick:escalated (threshold=${_threshold}) -->
**Stale recovery threshold reached** (t2008)

This issue has been stale-recovered **${_prior_ticks}** consecutive time(s) without producing a PR. Further automated dispatch is suspended until a human reviews the root cause.

Previously assigned to: ${stale_assignees}
Reason for latest stale: ${reason}
Recovery count: ${_prior_ticks} (threshold: ${_threshold})

Marked \`needs-maintainer-review\`. Remove this label after investigating why workers keep failing (wrong brief, unimplementable scope, missing dependency, etc.) to re-enable dispatch.

_This escalation is the \"no-progress fail-safe\" from t2008 (paired with t1986 parent-task guard and t2007 cost circuit breaker)._
<!-- ops:end -->" \
		2>/dev/null || true
	printf 'STALE_ESCALATED: issue #%s in %s — unassigned %s, applied needs-maintainer-review (threshold %s reached after %s ticks)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$_threshold" "$_prior_ticks"
	return 0
}

#######################################
# Re-check declared blocked-by dependencies before stale relaunch.
#
# Stale recovery may remove an abandoned assignment, but it must not convert
# an issue with open/unknown declared blockers back to status:available. The
# normal dispatch path also checks blocked-by before launch; this earlier gate
# prevents stale/no_work recovery from re-amplifying blocked issues into the
# ranked candidate pool.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
# Returns: 0 if declared dependency is open/unknown; 1 otherwise.
#######################################
_stale_recovery_has_unresolved_blocked_by() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ "$(type -t is_blocked_by_unresolved 2>/dev/null)" != "function" ]]; then
		local dep_graph_lib="${SCRIPT_DIR}/pulse-dep-graph.sh"
		# shellcheck source=/dev/null
		[[ -f "$dep_graph_lib" ]] && source "$dep_graph_lib" 2>/dev/null || true
	fi
	[[ "$(type -t is_blocked_by_unresolved 2>/dev/null)" == "function" ]] || return 1

	local issue_body=""
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	[[ -n "$issue_body" ]] || return 1

	if is_blocked_by_unresolved "$issue_body" "$repo_slug" "$issue_number"; then
		return 0
	fi
	return 1
}

#######################################
# Verify a stale-recovery status transition before publishing success.
# Args: issue number, repo slug, target status, stale assignees CSV
#######################################
_stale_recovery_verify_transition() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_status="$3"
	local stale_assignees="$4"
	local issue_meta_json=""

	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees 2>/dev/null) || return 1
	printf '%s' "$issue_meta_json" | jq -e --arg target "status:${target_status}" --arg stale "$stale_assignees" '
		($stale | split(",") | map(select(length > 0))) as $stale_users |
		([.assignees[].login] // []) as $current_users |
		.state == "OPEN" and
		(([.labels[].name] | index("status:queued")) == null) and
		(([.labels[].name] | index("status:in-progress")) == null) and
		(([.labels[].name] | index($target)) != null) and
		([ $stale_users[] as $stale_user |
			select(($current_users | index($stale_user)) != null) ] | length == 0)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Apply stale recovery as dependency-blocked instead of available.
# Args mirror _stale_recovery_apply.
#######################################
_stale_recovery_apply_blocked_by_hold() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"
	local expected_dispatch_ts="$5"
	shift 5
	local -a recov_extra=("$@")

	if ! _stale_recovery_final_evidence_recheck "$issue_number" "$repo_slug" "$expected_dispatch_ts"; then
		printf 'STALE_RECHECK_BLOCKED: issue #%s in %s — evidence changed before blocked takeover\n' "$issue_number" "$repo_slug"
		return 0
	fi
	if ! set_issue_status "$issue_number" "$repo_slug" "blocked" "${recov_extra[@]}"; then
		printf 'STALE_RECOVERY_UNCERTAIN: issue #%s in %s — blocked transition failed\n' "$issue_number" "$repo_slug"
		return 1
	fi
	if ! _stale_recovery_verify_transition "$issue_number" "$repo_slug" "blocked" "$stale_assignees"; then
		printf 'STALE_RECOVERY_UNCERTAIN: issue #%s in %s — blocked transition verification failed\n' "$issue_number" "$repo_slug"
		return 1
	fi

	local _now_ts=""
	_now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- WORKER_SUPERSEDED runners=${stale_assignees} ts=${_now_ts} -->
<!-- stale-recovery-blocked-by-unresolved -->
**Stale assignment recovered, but re-dispatch remains blocked** (GH#23932)

Previously assigned to: ${stale_assignees}
Reason: ${reason}
Threshold: ${STALE_ASSIGNMENT_THRESHOLD_SECONDS}s

The stale assignment was unassigned, but the issue still declares an open or unknown \`blocked-by\` dependency. Kept the issue at \`status:blocked\` instead of \`status:available\` so stale/no_work recovery cannot relaunch it until every declared blocker is positively clear.

_This is the stale-recovery dependency re-check for GH#23932._
<!-- ops:end -->" 2>/dev/null || true

	printf 'STALE_BLOCKED_BY_DEPENDENCY: issue #%s in %s — unassigned %s but kept status:blocked due to unresolved blocked-by (%s)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}

#######################################
# Apply normal stale recovery: unassign stale users, transition to
# status:available, post the audit comment with WORKER_SUPERSEDED marker.
#
# t2033: atomically unassign all stale users and transition to status:available
# via set_issue_status — previously two separate gh edits could race and leave
# conflicting labels (e.g., status:available + status:queued on #18444).
#
# The WORKER_SUPERSEDED marker (t1955) is a structured HTML comment that
# workers can detect before creating PRs. If a worker's runner login matches
# the superseded runner, it knows its assignment was revoked and should
# abort or re-claim.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason
# Returns: 0 (always)
#######################################
_stale_recovery_apply() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"
	local expected_dispatch_ts="${5:-}"
	local recovery_tick="${6:-}"
	local recovery_threshold="${7:-}"

	local saved_ifs="${IFS:-}"
	local -a assignee_arr=()
	IFS=',' read -ra assignee_arr <<<"$stale_assignees"
	IFS="$saved_ifs"

	local -a _recov_extra=()
	local assignee
	for assignee in "${assignee_arr[@]}"; do
		[[ -n "$assignee" ]] && _recov_extra+=(--remove-assignee "$assignee")
	done
	if _stale_recovery_has_unresolved_blocked_by "$issue_number" "$repo_slug"; then
		_stale_recovery_apply_blocked_by_hold "$issue_number" "$repo_slug" "$stale_assignees" "$reason" "$expected_dispatch_ts" "${_recov_extra[@]}"
		return 0
	fi
	if ! _stale_recovery_final_evidence_recheck "$issue_number" "$repo_slug" "$expected_dispatch_ts"; then
		printf 'STALE_RECHECK_BLOCKED: issue #%s in %s — evidence changed before takeover\n' "$issue_number" "$repo_slug"
		return 0
	fi
	if ! set_issue_status "$issue_number" "$repo_slug" "available" "${_recov_extra[@]}"; then
		printf 'STALE_RECOVERY_UNCERTAIN: issue #%s in %s — available transition failed\n' "$issue_number" "$repo_slug"
		return 1
	fi
	if ! _stale_recovery_verify_transition "$issue_number" "$repo_slug" "available" "$stale_assignees"; then
		printf 'STALE_RECOVERY_UNCERTAIN: issue #%s in %s — available transition verification failed\n' "$issue_number" "$repo_slug"
		return 1
	fi

	local _now_ts
	_now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- WORKER_SUPERSEDED runners=${stale_assignees} ts=${_now_ts} -->
<!-- stale-recovery-tick:${recovery_tick:-1} -->
**Stale assignment recovered** (GH#15060)

Previously assigned to: ${stale_assignees}
Reason: ${reason}
Threshold: ${STALE_ASSIGNMENT_THRESHOLD_SECONDS}s
Global recovery attempt: ${recovery_tick:-1}/${recovery_threshold:-unknown}

The assigned runner had no active worker process and produced no progress within the threshold. Unassigned and relabeled \`status:available\` for re-dispatch.

_This recovery prevents the orphaned-assignment deadlock where offline runners permanently block all dispatch._
<!-- ops:end -->" 2>/dev/null || true

	printf 'STALE_RECOVERED: issue #%s in %s — unassigned %s (%s)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}

#######################################
# Recover a stale assignment.
#
# Decision flow (t2008 escalation check):
#   1. Load threshold from config (default 2).
#   2. Count prior non-reset tick comments from the GitHub issue comment log.
#   3. Find the latest dispatch marker in that same GitHub comment log.
#   4. Look up any open PR referencing this issue.
#      - If an open PR exists: preserve ownership and stop; the PR is progress.
#      - Else increment the global recovery count. At the threshold, escalate
#        immediately. A stale assignment is itself terminal no-progress evidence.
#      - Under threshold, record the tick inside the single recovery comment.
#   5. Normal recovery: unassign stale users, set status:available, post audit.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason
#######################################
_recover_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"

	# ── Stale-recovery escalation check (t2008) ──────────────────────────
	# After STALE_RECOVERY_THRESHOLD consecutive recoveries without a PR, stop
	# resetting to status:available and apply needs-maintainer-review instead.
	# Counter is stored as structured comment markers for cross-runner correctness.
	# Config: .agents/configs/dispatch-stale-recovery.conf
	local _threshold _prior_ticks _open_pr _open_pr_number _open_pr_kind _comments_pages _latest_dispatch_ts _next_tick
	_threshold=$(_stale_recovery_load_threshold)
	_comments_pages=$(_stale_recovery_fetch_comments_pages "$issue_number" "$repo_slug")
	_prior_ticks=$(_stale_recovery_count_ticks_from_pages "$_comments_pages")
	_latest_dispatch_ts=$(_stale_recovery_latest_dispatch_ts_from_pages "$_comments_pages")
	_open_pr=$(_stale_recovery_find_open_pr "$issue_number" "$repo_slug")
	if [[ -n "$_open_pr" ]]; then
		_open_pr_number="${_open_pr%%|*}"
		_open_pr_kind="${_open_pr#*|}"
		if [[ "$_open_pr_kind" == "$_DDS_KIND_DRAFT" || "$_open_pr_kind" == "$_DDS_KIND_READY_FAILED" ]]; then
			if printf '%s' "$_comments_pages" | jq -e --arg marker "stale-pr-checkpoint:escalated pr=${_open_pr_number} kind=${_open_pr_kind}" \
				'any(.[] | .[]?; (.body // "") | contains($marker))' >/dev/null 2>&1; then
				printf 'STALE_PR_ESCALATED: issue #%s in %s — PR #%s already escalated\n' \
					"$issue_number" "$repo_slug" "$_open_pr_number"
				return 0
			fi
			_stale_recovery_escalate_pr_checkpoint "$issue_number" "$repo_slug" "$stale_assignees" \
				"$reason" "$_open_pr_number" "$_latest_dispatch_ts" "$_open_pr_kind" || return 1
			return 0
		fi
		if [[ "$_open_pr_kind" == "protected_draft" ]]; then
			printf 'STALE_DRAFT_PROTECTED: issue #%s in %s — draft PR #%s is held or not worker-owned; no automated mutation\n' \
				"$issue_number" "$repo_slug" "$_open_pr_number"
			return 0
		fi
		printf 'STALE_PROGRESS_PRESERVED: issue #%s in %s — open PR #%s is durable progress\n' \
			"$issue_number" "$repo_slug" "$_open_pr_number"
		return 0
	fi
	_next_tick=$((_prior_ticks + 1))
	if [[ "$_next_tick" -ge "$_threshold" ]]; then
		_stale_recovery_escalate "$issue_number" "$repo_slug" "$stale_assignees" "$reason" "$_threshold" "$_next_tick" "$_latest_dispatch_ts"
		return 0
	fi
	# ── End stale-recovery escalation check ──────────────────────────────

	_stale_recovery_apply "$issue_number" "$repo_slug" "$stale_assignees" "$reason" "$_latest_dispatch_ts" "$_next_tick" "$_threshold" || return 1
	return 0
}

#######################################
# Stale assignment detection.
#
# When an issue is assigned to a blocking user (another runner), check
# whether that assignment is stale: no active worker process, dispatch
# claim comment is >1h old, and no progress (comments) in the last hour.
#
# If stale, calls _recover_stale_assignment which unassigns the blocking
# users, removes status:queued and status:in-progress labels, posts a
# recovery comment, and returns 0 (stale, safe to re-dispatch).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = comma-separated blocking assignee logins
# Returns:
#   exit 0 = stale assignment recovered (safe to dispatch)
#   exit 1 = assignment is NOT stale (genuine active claim, block dispatch)
#
# GH#18816: gh comments API failure → fail-CLOSED (return 1, block dispatch).
# jq and timestamp parse failures → fail-OPEN (unreadable ≠ stale).
#######################################

#######################################
# t2132: Resolve the effective stale threshold for an issue.
# Interactive sessions use a longer threshold because human-driven sessions
# routinely go 30-60+ minutes between actions. Creation provenance remains one
# signal, but a recent interactive claim paired with live in-review ownership is
# authoritative even when immutable provenance is origin:worker.
#
# t2153 (GH#19424): Also returns the issue's createdAt timestamp so the
# caller can apply the age-floor guard. A single `gh issue view --json
# labels,createdAt,updatedAt` round-trip serves the age-floor and issue-level
# timeline liveness checks — no extra API call.
#
# Args: $1 = issue number, $2 = repo slug, $3 = normalized comments JSON,
#       $4 = current epoch
# Stdout: four lines —
#   1. "is_interactive" ("true"/"false")
#   2. threshold (seconds)
#   3. createdAt (ISO 8601, or empty when absent)
#   4. updatedAt (ISO 8601, or empty when absent)
#######################################
_stale_assignment_has_live_interactive_claim() {
	local issue_meta_json="$1"
	local comments_json="$2"
	local now_epoch="$3"
	local claim_record=""
	claim_record=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select((.body_start // "") | contains("Interactive session claimed"))]
		| first
		| if . == null then empty else [.created_at, .author] | @tsv end
	' 2>/dev/null) || return 1
	[[ -n "$claim_record" ]] || return 1

	local claim_timestamp=""
	local claim_author=""
	IFS=$'\t' read -r claim_timestamp claim_author <<<"$claim_record"
	[[ -n "$claim_timestamp" && -n "$claim_author" ]] || return 1
	local claim_epoch=0
	claim_epoch=$(_ts_to_epoch "$claim_timestamp")
	[[ "$claim_epoch" -gt 0 ]] || return 1
	local claim_age=$((now_epoch - claim_epoch))
	if [[ "$claim_age" -lt 0 || "$claim_age" -ge "$INTERACTIVE_STALE_THRESHOLD_SECONDS" ]]; then
		return 1
	fi

	printf '%s' "$issue_meta_json" | jq -e --arg claimant "$claim_author" '
		(.state | ascii_downcase) == "open" and
		([.labels[]?.name] | index("status:in-review") != null) and
		([.assignees[]?.login] | index($claimant) != null)
	' >/dev/null 2>&1 || return 1
	return 0
}

_resolve_stale_threshold() {
	local issue_number="$1"
	local repo_slug="$2"
	local comments_json="${3:-[]}"
	local now_epoch="${4:-}"
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=$(date +%s)
	local _issue_meta_json _meta_rc=0
	_issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees,createdAt,updatedAt 2>/dev/null) || _meta_rc=$?
	if [[ "$_meta_rc" -ne 0 || -z "$_issue_meta_json" ]]; then
		return 1
	fi

	local is_interactive='false'
	local threshold="$STALE_ASSIGNMENT_THRESHOLD_SECONDS"
	local created_at=''
	local updated_at=''

	if printf '%s' "$_issue_meta_json" | jq -e '.labels | map(.name) | index("origin:interactive")' >/dev/null 2>&1 ||
		_stale_assignment_has_live_interactive_claim "$_issue_meta_json" "$comments_json" "$now_epoch"; then
		is_interactive='true'
		threshold="$INTERACTIVE_STALE_THRESHOLD_SECONDS"
	fi
	created_at=$(printf '%s' "$_issue_meta_json" | jq -r '.createdAt // empty' 2>/dev/null) || created_at=''
	updated_at=$(printf '%s' "$_issue_meta_json" | jq -r '.updatedAt // empty' 2>/dev/null) || updated_at=''
	printf '%s\n%s\n%s\n%s\n' "$is_interactive" "$threshold" "$created_at" "$updated_at"
	return 0
}

#######################################
# t2153 (GH#19424): Age-floor guard. An issue cannot be "stale" if it is
# itself younger than the staleness threshold. Without this guard, freshly
# created issues with assignees but no comments yet (the common case for
# issues created via issue-sync from TODO entries) fall through to
# _recover_stale_assignment within seconds — both last_dispatch_ts and
# last_activity_ts are empty, so the inner activity-age check is skipped
# and _is_stale_assignment reports stale.
#
# Production case: #19414 was stale-recovered 4 min 53s after creation
# despite carrying origin:interactive (threshold=7200s). The threshold was
# never compared against issue age — only against (non-existent) comment
# timestamps.
#
# Fail-open on missing/unparseable createdAt — the caller's downstream
# fail-CLOSED stance (return 1, block dispatch) handles transient gh errors.
#
# Args: $1 = issue createdAt (ISO 8601, may be empty)
#       $2 = effective threshold seconds
#       $3 = now epoch
# Returns: 0 if too young to be stale; 1 otherwise (caller continues).
#######################################
_issue_too_young_for_staleness() {
	local issue_created_at="$1"
	local effective_threshold="$2"
	local now_epoch="$3"
	[[ -z "$issue_created_at" ]] && return 1
	local epoch
	epoch=$(_ts_to_epoch "$issue_created_at")
	[[ "$epoch" -le 0 ]] && return 1
	if [[ "$((now_epoch - epoch))" -lt "$effective_threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Fetch and normalize issue comments for stale-assignment checks.
# Args: $1 = issue number, $2 = repo slug
# Output: normalized comments JSON sorted newest-first
# Returns: 0 on success, 1 on API/jq failure
#######################################
_stale_assignment_fetch_comments_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local comments_pages comments_json
	comments_pages=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --slurp 2>/dev/null) || return 1
	comments_json=$(printf '%s' "$comments_pages" | jq \
		'[.[] | .[]? | {created_at: .created_at, author: .user.login, body_start: ((.body // "")[:200])}] | sort_by(.created_at) | reverse' \
		2>/dev/null) || return 1
	printf '%s' "$comments_json"
	return 0
}

#######################################
# Find the most recent worker dispatch or interactive claim comment.
# Args: $1 = normalized comments JSON
# Output: ISO timestamp or empty
#######################################
_stale_assignment_latest_dispatch_ts() {
	local comments_json="$1"
	printf '%s' "$comments_json" | jq -r '
		[.[] | select(
			(.body_start | test("Dispatching worker"; "i")) or
			(.body_start | test("DISPATCH_CLAIM"; "i")) or
			(.body_start | test("Worker \\(PID"; "i")) or
			(.body_start | test("Interactive session claimed"; "i"))
		)] | first | .created_at // empty
	' 2>/dev/null || true
	return 0
}

#######################################
# Find the latest GitHub-visible issue activity timestamp.
# Args: $1 = normalized comments JSON, $2 = issue updatedAt timestamp
# Output: ISO timestamp or empty
#######################################
_stale_assignment_latest_activity_ts() {
	local comments_json="$1"
	local issue_updated_at="$2"
	local last_activity_ts=""
	last_activity_ts=$(printf '%s' "$comments_json" | jq -r '
		first | .created_at // empty
	' 2>/dev/null) || last_activity_ts=""
	if [[ -n "$issue_updated_at" && ( -z "$last_activity_ts" || "$issue_updated_at" > "$last_activity_ts" ) ]]; then
		last_activity_ts="$issue_updated_at"
	fi
	printf '%s' "$last_activity_ts"
	return 0
}

#######################################
# Determine whether recent issue activity protects an assignment without a claim.
# Args: $1 = last activity timestamp, $2 = now epoch, $3 = effective threshold
# Returns: 0 if recent activity should block stale recovery, 1 otherwise
#######################################
_stale_assignment_has_recent_activity() {
	local last_activity_ts="$1"
	local now_epoch="$2"
	local effective_threshold="$3"
	local activity_epoch activity_age
	[[ -z "$last_activity_ts" ]] && return 1
	activity_epoch=$(_ts_to_epoch "$last_activity_ts")
	activity_age=$((now_epoch - activity_epoch))
	if [[ "$activity_age" -lt "$effective_threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Determine whether recent open PR activity protects a stale-looking assignment.
# Args: $1 = issue number, $2 = repo slug, $3 = now epoch, $4 = threshold seconds,
#       $5 = optional precomputed "<number>|<updatedAt>" open PR activity
# Returns: 0 if recent PR activity exists, 1 otherwise
#######################################
_stale_assignment_has_recent_open_pr_activity() {
	local issue_number="$1"
	local repo_slug="$2"
	local now_epoch="$3"
	local effective_threshold="$4"
	local open_pr_activity="${5:-}"
	local open_pr_number open_pr_updated_at open_pr_epoch open_pr_age
	if [[ "$#" -lt 5 ]]; then
		open_pr_activity=$(_stale_recovery_find_open_pr_activity "$issue_number" "$repo_slug")
	fi
	[[ -z "$open_pr_activity" ]] && return 1
	open_pr_number="${open_pr_activity%%|*}"
	open_pr_updated_at="${open_pr_activity#*|}"
	[[ -z "$open_pr_number" || -z "$open_pr_updated_at" ]] && return 1
	open_pr_epoch=$(_ts_to_epoch "$open_pr_updated_at")
	[[ "$open_pr_epoch" -le 0 ]] && return 1
	open_pr_age=$((now_epoch - open_pr_epoch))
	if [[ "$open_pr_age" -lt "$effective_threshold" ]]; then
		return 0
	fi
	return 1
}

_stale_assignment_load_threshold_context() {
	local issue_number="$1"
	local repo_slug="$2"
	local comments_json="$3"
	local now_epoch="$4"
	local threshold_output=""
	if ! threshold_output=$(_resolve_stale_threshold "$issue_number" "$repo_slug" "$comments_json" "$now_epoch"); then
		return 1
	fi
	local -a threshold_fields=()
	local threshold_line=""
	while IFS= read -r threshold_line; do
		threshold_fields[${#threshold_fields[@]}]="$threshold_line"
	done <<<"$threshold_output"
	_STALE_CONTEXT_INTERACTIVE="${threshold_fields[0]:-false}"
	_STALE_CONTEXT_THRESHOLD="${threshold_fields[1]:-$STALE_ASSIGNMENT_THRESHOLD_SECONDS}"
	_STALE_CONTEXT_CREATED_AT="${threshold_fields[2]:-}"
	_STALE_CONTEXT_UPDATED_AT="${threshold_fields[3]:-}"
	return 0
}

_is_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocking_assignees="$3"

	local now_epoch
	now_epoch=$(date +%s)

	# Fetch issue comments to find the most recent dispatch claim and
	# overall activity timestamp. Use --paginate --slurp so gh combines all
	# pages before jq sorts them; `gh api --paginate --jq ...` applies jq per
	# page, which can leave page-1 timestamps ahead of newer activity on long
	# issue threads and trigger false stale recovery (GH#3894 / t2769 incident).
	#
	# GH#18816: fail-CLOSED on API failure. A transient gh error is NOT evidence
	# that the assignment is stale — block this pulse cycle and retry next cycle.
	local comments_json
	if ! comments_json=$(_stale_assignment_fetch_comments_json "$issue_number" "$repo_slug"); then
		# Cannot fetch comments — cannot determine staleness. Fail-CLOSED:
		# keep the existing assignment protection for this pulse cycle.
		return 1
	fi

	# t2132+t2153: resolve interactive ownership after comments are available so
	# origin:worker issues can still honor a live interactive takeover. Metadata
	# lookup failures fail closed instead of silently falling back to 600 seconds.
	if ! _stale_assignment_load_threshold_context "$issue_number" "$repo_slug" "$comments_json" "$now_epoch"; then
		return 1
	fi
	local is_interactive="$_STALE_CONTEXT_INTERACTIVE"
	local effective_threshold="$_STALE_CONTEXT_THRESHOLD"
	local issue_created_at="$_STALE_CONTEXT_CREATED_AT"
	local issue_updated_at="$_STALE_CONTEXT_UPDATED_AT"
	# t2153 age-floor guard: issue cannot be stale before it could signal.
	_issue_too_young_for_staleness "$issue_created_at" "$effective_threshold" "$now_epoch" && return 1

	# t2132 Fix D: Find the most recent dispatch/claim comment.
	# Matches worker dispatch patterns AND interactive session claim pattern.
	# Previously only matched "Dispatching worker|DISPATCH_CLAIM|Worker (PID",
	# which missed the interactive claim comment posted by
	# interactive-session-helper.sh ("Interactive session claimed").
	local last_dispatch_ts=""
	last_dispatch_ts=$(_stale_assignment_latest_dispatch_ts "$comments_json")

	# Find the most recent GitHub-visible activity. Comments are the detailed
	# event log; issue updatedAt covers lightweight timeline events such as label,
	# assignee, cross-reference, or state transitions without an extra API call.
	local last_activity_ts=""
	last_activity_ts=$(_stale_assignment_latest_activity_ts "$comments_json" "$issue_updated_at")

	# If no dispatch comment exists at all, the assignment is from a
	# non-worker source (e.g., auto-assignment at issue creation). Treat
	# as stale since there's no worker claim to protect.
	# (now_epoch already computed above for the t2153 age-floor guard.)
	local dispatch_epoch

	if [[ -z "$last_dispatch_ts" ]]; then
		# No dispatch comment — check if the last activity is also old
		if _stale_assignment_has_recent_activity "$last_activity_ts" "$now_epoch" "$effective_threshold"; then
			# Recent activity but no dispatch comment — could be manual work
			return 1
		fi
		# No dispatch comment AND no recent activity — stale
		_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" "no dispatch claim comment found, no recent activity (threshold=${effective_threshold}s, interactive=${is_interactive})"
		return 0
	fi

	# Dispatch comment exists — check its age against the effective threshold
	dispatch_epoch=$(_ts_to_epoch "$last_dispatch_ts")
	local dispatch_age=$((now_epoch - dispatch_epoch))

	if [[ "$dispatch_age" -lt "$effective_threshold" ]]; then
		# Dispatch claim is recent (< threshold) — honour it
		return 1
	fi

	# Dispatch claim is old. Check if there's been any progress since.
	local activity_age_msg="unknown"
	if [[ -n "$last_activity_ts" ]]; then
		local activity_epoch activity_age
		activity_epoch=$(_ts_to_epoch "$last_activity_ts")
		activity_age=$((now_epoch - activity_epoch))
		activity_age_msg="${activity_age}s"
		if [[ "$activity_age" -lt "$effective_threshold" ]]; then
			# Old dispatch but recent activity — worker may still be alive
			return 1
		fi
	fi

	# Issue comments/updatedAt are quiet. Check for an open PR only now so normal
	# dispatch checks do not burn PR-list API budget; branch pushes and draft PR
	# updates are better liveness signals than synthetic issue heartbeats.
	if _stale_assignment_has_recent_open_pr_activity "$issue_number" "$repo_slug" "$now_epoch" "$effective_threshold"; then
		return 1
	fi

	# Both dispatch claim and last activity are older than threshold — stale
	_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" \
		"dispatch claim ${dispatch_age}s old, last activity ${activity_age_msg} old (threshold=${effective_threshold}s, interactive=${is_interactive})"
	return 0
}
