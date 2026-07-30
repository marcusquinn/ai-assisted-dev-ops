#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-dedup-layers.sh — Dedup layer functions for dispatch — 7-layer duplicate-detection chain plus stale-recovery crash classifier.
#
# Extracted from pulse-dispatch-core.sh (GH#18832) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh and worker-lifecycle-common.sh being sourced first.
#
# Functions in this module (in source order):
#   - _classify_stale_recovery_crash_type
#   - _stale_recovery_has_worker_evidence
#   - _dedup_layer1_ledger_check
#   - _dedup_layer2_process_match
#   - _dedup_layer3_title_match
#   - _dedup_layer4_pr_evidence
#   - _dedup_layer5_dispatch_comment
#   - _dedup_layer6_assignee_and_stale
#   - _dedup_layer7_claim_lock

[[ -n "${_PULSE_DISPATCH_DEDUP_LAYERS_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_DEDUP_LAYERS_LOADED=1

#######################################
# Classify a stale-recovered worker by what (if anything) it produced
# before stalling. Used by the STALE_RECOVERED branch in
# _dispatch_dedup_check_layers to give escalate_issue_tier a meaningful
# crash_type instead of leaving it empty.
#
# t2042: addresses the diagnostic gap on #18418 where two stale-recovered
# workers escalated to tier:thinking with reason="stale_timeout" and no
# crash_type, so the cascade comment couldn't tell the next worker
# whether it was a no-work infra failure or a partial implementation
# stall.
#
# Returns one of:
#   "partial"  — open PR or remote branch references this issue
#                (worker reached at least the worktree/PR stage)
#   "no_work"  — no PR, no branch (worker died before producing any
#                durable artifact — transient/infrastructure failure)
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
# Output: crash_type string on stdout
#######################################
_classify_stale_recovery_crash_type() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || {
		printf 'no_work'
		return 0
	}
	[[ -n "$repo_slug" ]] || {
		printf 'no_work'
		return 0
	}

	# Fast path: open PR exists referencing the issue. Worker got far
	# enough to produce a PR — definitely "partial".
	local _open_pr_count
	_open_pr_count=$(gh_pr_list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 1 \
		--json number --jq 'length' 2>/dev/null) || _open_pr_count=0
	[[ "$_open_pr_count" =~ ^[0-9]+$ ]] || _open_pr_count=0
	if [[ "$_open_pr_count" -gt 0 ]]; then
		printf 'partial'
		return 0
	fi

	# Second check: any remote branch whose name references the issue
	# number. Workers create branches like `bugfix/t1992-...`,
	# `feature/auto-...-issue-18418`, or contain `gh-18418`. If we find
	# anything, the worker reached the worktree-creation stage.
	local _branch_count
	_branch_count=$(gh api "repos/${repo_slug}/branches" --paginate \
		--jq "[.[] | select(.name | test(\"(t|gh-?)${issue_number}([^0-9]|\$)\"))] | length" \
		2>/dev/null) || _branch_count=0
	[[ "$_branch_count" =~ ^[0-9]+$ ]] || _branch_count=0
	if [[ "$_branch_count" -gt 0 ]]; then
		printf 'partial'
		return 0
	fi

	# No PR, no branch — the worker died before producing any durable
	# artifact. Classify as no_work so the cascade tier escalation
	# comment renders the "Likely infrastructure/transient failure" line.
	printf 'no_work'
	return 0
}

#######################################
# Decide whether a stale-recovery event is evidence of a worker failure.
#
# GH#4011/GH#4012: pre-launch abort cleanup can leave an old active label +
# assignee without any dispatch claim comment because no worker ever started
# and the claim comment was deleted as audit noise. Stale recovery should clean
# that orphaned state, but it must not feed the no_work fast-fail counter: a
# missing dispatch claim proves there is no worker artifact to classify.
#
# Args: $1 - captured dispatch-dedup-helper output
# Returns: 0 if stale recovery found worker evidence, 1 otherwise
#######################################
_stale_recovery_has_worker_evidence() {
	local assigned_output="$1"
	[[ "$assigned_output" == *STALE_RECOVERED* ]] || return 1
	[[ "$assigned_output" != *"no dispatch claim comment found"* ]] || return 1
	return 0
}

#######################################
# Check if dispatching a worker would be a duplicate (GH#4400, GH#5210, GH#6696, GH#11086)
#
# Seven-layer dedup:
#   1. dispatch-ledger-helper.sh check-issue — in-flight ledger (GH#6696)
#   2. has_worker_for_repo_issue() — exact repo+issue process match
#   3. dispatch-dedup-helper.sh is-duplicate — normalized title key match
#   4. dispatch-dedup-helper.sh has-open-pr — merged PR evidence for issue/task
#   5. dispatch-dedup-helper.sh has-dispatch-comment — cross-machine dispatch comment (GH#11141)
#   6. dispatch-dedup-helper.sh is-assigned — cross-machine assignee guard (GH#6891)
#   7. dispatch-dedup-helper.sh claim — cross-machine optimistic lock (GH#11086)
#
# Layer 1 (ledger) is checked first because it's the fastest (local file
# read, no process scanning or GitHub API calls) and catches the primary
# failure mode: workers dispatched but not yet visible in process lists
# or GitHub PRs (the 10-15 minute gap between dispatch and PR creation).
#
# Layer 6 (claim) is last because it's the slowest (posts a GitHub comment,
# sleeps DISPATCH_CLAIM_WINDOW seconds, re-reads comments). It's the final
# cross-machine safety net: two runners that pass layers 1-5 simultaneously
# will both post a claim, but only the oldest claim wins. Previously this
# was an LLM-instructed step in pulse.md that runners could skip — the
# GH#11086 incident showed both marcusquinn and johnwaldo dispatching on
# the same issue 45 seconds apart because the LLM skipped the claim step.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - dispatch title (e.g., "Issue #42: Fix auth")
#   $4 - issue title (optional; used for merged-PR task-id fallback)
#   $5 - self login (optional; runner's GitHub login for assignee check)
# Exit codes:
#   0 - duplicate detected (do NOT dispatch)
#   1 - no duplicate (safe to dispatch)
#######################################
#######################################
# Layer 1 (GH#6696): in-flight dispatch ledger check.
# Catches workers in the 10-15 min gap between dispatch and PR creation.
# Arguments: issue_number, repo_slug
# Exit: 0 = blocked (duplicate), 1 = continue to next layer
#######################################
_dedup_layer1_ledger_check() {
	local issue_number="$1"
	local repo_slug="$2"
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		if "$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: in-flight ledger entry for #${issue_number} in ${repo_slug} (GH#6696)" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

#######################################
# Layer 2: exact repo+issue process match.
# Arguments: issue_number, repo_slug
# Exit: 0 = blocked, 1 = continue
#######################################
_dedup_layer2_process_match() {
	local issue_number="$1"
	local repo_slug="$2"
	if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Dedup: worker already running for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Layer 3: normalized title key match via dispatch-dedup-helper.
# Arguments: title
# Exit: 0 = blocked, 1 = continue
#######################################
_dedup_layer3_title_match() {
	local title="$1"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]] && [[ -n "$title" ]]; then
		if "$dedup_helper" is-duplicate "$title" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Dedup: title match for '${title}' — worker already running" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

#######################################
# Layer 4: open or merged PR evidence for this issue/task.
# If a worker already produced a PR (open or merged), do not dispatch another.
# Previously only checked --state merged, missing open PRs entirely.
# Arguments: issue_number, repo_slug, issue_title
# Exit: 0 = blocked, 1 = continue, 2 = worker draft needs stale-assignment routing
#######################################
_dedup_layer4_pr_evidence() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	local dedup_helper_output=""
	if [[ -x "$dedup_helper" ]]; then
		if dedup_helper_output=$("$dedup_helper" has-open-pr "$issue_number" "$repo_slug" "$issue_title" 2>>"$LOGFILE"); then
			if [[ -n "$dedup_helper_output" ]]; then
				echo "[pulse-wrapper] Dedup: ${dedup_helper_output}" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Dedup: PR evidence already exists for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			fi
			if [[ "$dedup_helper_output" == WORKER_DRAFT_CHECKPOINT:* ]]; then
				return 2
			fi
			return 0
		fi
	fi
	return 1
}

#######################################
# Layer 5 (GH#11141): cross-machine dispatch comment check.
# Detects "Dispatching worker" comments posted by other runners — the
# persistent cross-machine signal that survives beyond the claim lock's
# 8-second window. See GH#11141 incident for rationale.
# Arguments: issue_number, repo_slug, self_login
# Exit: 0 = blocked, 1 = continue
#######################################
_dedup_layer5_dispatch_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local dispatch_comment_output=""
		if dispatch_comment_output=$("$dedup_helper" has-dispatch-comment "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} has active dispatch comment — ${dispatch_comment_output}" >>"$LOGFILE"
			printf '%s\n' "$dispatch_comment_output"
			return 0
		fi
	fi
	return 1
}

#######################################
# Layer 6 (GH#6891): cross-machine assignee guard + stale recovery.
# Prevents runners from dispatching workers for issues already assigned to
# another login. On STALE_RECOVERED with worker evidence, records fast-fail
# (t1927/t2042).
# Arguments: issue_number, repo_slug, self_login
# Exit: 0 = blocked, 1 = continue
#######################################
_dedup_layer6_assignee_and_stale() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		local assigned_output=""
		if assigned_output=$("$dedup_helper" is-assigned "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE"); then
			local assigned_reason="unknown"
			assigned_reason=$("$dedup_helper" classify-blocker "$assigned_output" 2>/dev/null) || assigned_reason="unknown"
			echo "[pulse-wrapper] Dedup: #${issue_number} in ${repo_slug} already assigned — DISPATCH_BLOCK_REASON reason=${assigned_reason} signal=${assigned_output}" >>"$LOGFILE"
			printf '%s\n' "$assigned_output"
			return 0
		fi
		# GH#27853: exhausted stale-recovery paths are terminal outcomes. Route
		# them through the same idempotent consolidation dispatcher used by
		# substantive-thread triage, then block this cycle so a stale candidate
		# snapshot cannot launch a competing worker after NMR was applied.
		if [[ "$assigned_output" == *STALE_ESCALATED* || "$assigned_output" == *STALE_PR_ESCALATED* ]]; then
			local _stale_breaker_source="stale-recovery-threshold"
			[[ "$assigned_output" == *STALE_PR_ESCALATED* ]] && _stale_breaker_source="stale-pr-checkpoint"
			if declare -F _route_terminal_breaker_to_consolidation >/dev/null 2>&1; then
				_route_terminal_breaker_to_consolidation "$issue_number" "$repo_slug" \
					"$_stale_breaker_source" "$assigned_output" || true
			else
				echo "[pulse-wrapper] Dedup: terminal stale breaker for #${issue_number} in ${repo_slug} could not route to consolidation because bridge is unavailable" >>"$LOGFILE"
			fi
			echo "[pulse-wrapper] Dedup: terminal stale breaker blocked redispatch for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
			return 0
		fi
		# t1927: Stale recovery must record fast-fail. When _is_stale_assignment()
		# recovers a stale assignment (silent worker timeout), the dedup helper
		# outputs STALE_RECOVERED on stdout. Without recording this as a failure,
		# the fast-fail counter stays at 0 and the issue loops through unlimited
		# dispatch→timeout→stale-recovery cycles. Observed: 8+ dispatches in 6h
		# with 0 PRs and 0 fast-fail entries (GH#17700, GH#17701, GH#17702).
		if [[ "$assigned_output" == *STALE_RECOVERED* ]]; then
			if ! _stale_recovery_has_worker_evidence "$assigned_output"; then
				echo "[pulse-wrapper] Dedup: stale recovery detected for #${issue_number} in ${repo_slug} without worker evidence — skipping fast-fail record (GH#4011/GH#4012)" >>"$LOGFILE"
				return 1
			fi
			# t2042: classify what (if anything) the dead worker produced
			# before stalling so the cascade tier escalation comment can
			# render a "Crash type: no_work | partial" diagnostic line
			# instead of a bare "Reason: stale_timeout" with no signal.
			local _stale_crash_type
			_stale_crash_type=$(_classify_stale_recovery_crash_type "$issue_number" "$repo_slug")
			echo "[pulse-wrapper] Dedup: stale recovery detected for #${issue_number} in ${repo_slug} crash_type=${_stale_crash_type} — recording fast-fail (t1927/t2042)" >>"$LOGFILE"
			fast_fail_record "$issue_number" "$repo_slug" "stale_timeout" "" "$_stale_crash_type" || true
		fi
		if [[ "$assigned_output" == *STALE_BLOCKED_BY_DEPENDENCY* ]]; then
			echo "[pulse-wrapper] Dedup: stale recovery for #${issue_number} in ${repo_slug} found unresolved blocked-by dependency — blocking re-dispatch (GH#23932)" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

#######################################
# Layer 7 (GH#11086): cross-machine optimistic claim lock.
# Final safety net for multi-runner environments. Posts a plain-text claim
# comment, sleeps the consensus window, and checks if this runner's claim
# is the oldest. See the GH#11086 incident (23:07:43 vs 23:08:28 race).
#
# GH#15317: Captures claim output to extract comment_id for audit-trail
# retention. The caller-caller (dispatch_with_dedup) reads _claim_comment_id
# via bash dynamic scoping — this helper assigns without `local` so the
# value propagates up two stack frames.
#
# Arguments: issue_number, repo_slug, self_login
# Exit: 0 = blocked, 1 = continue (won claim)
#######################################
_dedup_layer7_claim_lock() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	# GH#15317: reset the dynamically-scoped _claim_comment_id unconditionally
	# so the dispatch_with_dedup caller always sees a fresh value. Do NOT
	# declare local here — see function header.
	_claim_comment_id=""
	_claim_lease_token=""
	_claim_lease_device=""
	if [[ -x "$dedup_helper" ]] && [[ "$issue_number" =~ ^[0-9]+$ ]]; then
		# GH#17590: Pre-check for existing claims BEFORE posting our own.
		# Without this, two runners both post claims within seconds, then
		# the consensus window resolves the race — but the losing claim
		# comment is left on the issue, wasting a GitHub API call and
		# cluttering the issue. The pre-check is cheap (read-only) and
		# catches the common case where another runner already claimed.
		local _precheck_output="" _precheck_exit=0
		_precheck_output=$("$dedup_helper" check-claim "$issue_number" "$repo_slug") || _precheck_exit=$?
		if [[ "$_precheck_exit" -eq 0 ]]; then
			# Active claim exists from another runner — skip claim entirely
			echo "[pulse-wrapper] Dedup: pre-check found active claim on #${issue_number} in ${repo_slug} — skipping (${_precheck_output})" >>"$LOGFILE"
			return 0
		fi
		if [[ "$_precheck_exit" -eq 2 ]]; then
			echo "[pulse-wrapper] Dedup: claim pre-check error for #${issue_number} in ${repo_slug} — blocking dispatch for this cycle (fail-closed)" >>"$LOGFILE"
			return 0
		fi
		# No active claim found (exit 1) — proceed to claim.
		local claim_exit=0 claim_output=""
		claim_output=$("$dedup_helper" claim "$issue_number" "$repo_slug" "$self_login" 2>>"$LOGFILE") || claim_exit=$?
		echo "$claim_output" >>"$LOGFILE"
		if [[ "$claim_exit" -eq 1 ]]; then
			echo "[pulse-wrapper] Dedup: claim lost for #${issue_number} in ${repo_slug} — another runner claimed first (GH#11086)" >>"$LOGFILE"
			return 0
		fi
		if [[ "$claim_exit" -eq 2 ]]; then
			echo "[pulse-wrapper] Dedup: claim error for #${issue_number} in ${repo_slug} — blocking dispatch for this cycle (fail-closed)" >>"$LOGFILE"
			return 0
		fi
		# Extract claim comment_id for post-dispatch cleanup (GH#15317)
		_claim_comment_id=$(printf '%s' "$claim_output" | sed -n 's/.*comment_id=\([0-9]*\).*/\1/p')
		_claim_lease_token=$(printf '%s' "$claim_output" | sed -n 's/.*lease_token=\([^ ]*\).*/\1/p')
		_claim_lease_device=$(printf '%s' "$claim_output" | sed -n 's/.*device=\([^ ]*\).*/\1/p')
		# claim_exit 0 = won, proceed to dispatch
	fi
	return 1
}
