#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-cleanup.sh — Worktree/stash/zombie-worker cleanup + orphan/stalled worker recovery + stale opencode process cleanup.
#
# Extracted from pulse-wrapper.sh in Phase 5 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Worktree cleanup is split into focused sourced modules:
#   - pulse-cleanup-worktree-state.sh    (branch/PR, age, ownership, and audit state)
#   - pulse-cleanup-worktree-removal.sh  (archive/removal, relocation, and cleanup_worktrees)
#
# This orchestrator retains worker recovery, stash cleanup, and stale process
# cleanup, including recover_failed_launch_state() so its complexity-scanner
# identity key remains stable.
#
# Phase 12 refactor (t2003 / GH#18451): split cleanup_worktrees() (250 lines)
# into the three private helpers above. Also preserves the GH#18346 fix
# (silent-skip logging) that was applied during Phase 5 extraction — see
# _worktree_owner_alive() and _cleanup_single_worktree() for the two
# previously-silent continue paths that now emit diagnostic log entries.
#
# GH#18704 refactor: split _cleanup_single_worktree() (125 lines) into three
# focused private helpers: _worktree_creation_epoch(),
# _evaluate_worktree_removal(), and _record_orphan_crash_classification().
# The orchestrator now reads as a linear five-step pipeline instead of a
# single flat function. Preserves identical behaviour including the GH#18346
# silent-skip log entry, the GH#16830/t1884 age thresholds, and the crash
# classification rules for "overwhelmed" vs "no_work" workers.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CLEANUP_LOADED:-}" ]] && return 0
_PULSE_CLEANUP_LOADED=1
_PULSE_CLEANUP_FALSE="false"

# t2559: canonical-guard-helper.sh provides is_registered_canonical and
# assert_git_available, used by guarded removal helpers and
# _cleanup_merged_prs_for_all_repos below. Guarded missing-file so older
# deployments fail open.
_PULSE_CLEANUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || _PULSE_CLEANUP_SCRIPT_DIR=""
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/canonical-guard-helper.sh" ]]; then
	# shellcheck source=/dev/null
	source "$_PULSE_CLEANUP_SCRIPT_DIR/canonical-guard-helper.sh"
fi
# t2976: canonical audit logger for worktree-removal events
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/audit-worktree-removal-helper.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/lib/version.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/gh-signature-helper-detect.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/shared-dispatch-label-cleanup.sh" ]]; then
	# shellcheck source=shared-dispatch-label-cleanup.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/shared-dispatch-label-cleanup.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/worktree-paths.sh" ]]; then
	# shellcheck source=worktree-paths.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/worktree-paths.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-temp-worktree-cleanup.sh" ]]; then
	# shellcheck source=pulse-temp-worktree-cleanup.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-temp-worktree-cleanup.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-degraded-orphans.sh" ]]; then
	# shellcheck source=pulse-cleanup-degraded-orphans.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-degraded-orphans.sh"
fi
# GH#23677 / t3700: Do NOT `unset _PULSE_CLEANUP_SCRIPT_DIR`. The previous
# version unset this immediately after sourcing the four sibling helpers,
# but _cleanup_merged_prs_for_all_repos() (line ~251) reads it later to
# locate worktree-helper.sh. Under `set -u` (the standard pulse-wrapper
# orchestrator setting) that read aborts the cleanup pass with
# `_PULSE_CLEANUP_SCRIPT_DIR: unbound variable`. The variable already uses
# the module-private `_PULSE_` prefix and survives the include guard on
# line 49 unset-free, so keeping it bound is consistent.
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"
# Caller ID constant for audit log calls (avoids repeated literals).
_WTAR_PC_CALLER="pulse-cleanup.sh"
_PC_REASON_AGE_ELIGIBLE="age-eligible"
_PC_ARCHIVE_REQUIRED_FAILURE_RC=2

if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-worktree-state.sh" ]]; then
	# shellcheck source=pulse-cleanup-worktree-state.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-worktree-state.sh"
fi
if [[ -n "$_PULSE_CLEANUP_SCRIPT_DIR" && -f "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-worktree-removal.sh" ]]; then
	# shellcheck source=pulse-cleanup-worktree-removal.sh
	source "$_PULSE_CLEANUP_SCRIPT_DIR/pulse-cleanup-worktree-removal.sh"
fi

#######################################
# Clean up safe-to-drop stashes across ALL managed repos (t1417)
#
# Iterates repos.json (.initialized_repos[]) and runs
# stash-audit-helper.sh auto-clean in each repo directory. Pulse preflight calls
# this via cleanup-stashes-async-helper.sh so slow stash audits cannot block
# early dispatch (GH#21997); direct callers remain synchronous.
# Only drops stashes whose content is already in HEAD — safe
# and deterministic, no judgment needed.
#
# Stashes classified as "needs-review" or "obsolete" are left
# for the LLM hygiene triage (see prefetch_hygiene + pulse.md).
#######################################
cleanup_stashes() {
	local helper="${HOME}/.aidevops/agents/scripts/stash-audit-helper.sh"
	if [[ ! -x "$helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	local total_dropped=0

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local repo_paths
		repo_paths=$(jq -r '.initialized_repos[] | select((.local_only // false) == false) | .path // ""' "$repos_json" || echo "")

		local repo_path
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path/.git" ]] && continue

			# Skip repos with no stashes
			local stash_count
			stash_count=$(git -C "$repo_path" stash list 2>/dev/null | wc -l | tr -d ' ')
			if [[ "${stash_count:-0}" -eq 0 ]]; then
				continue
			fi

			local clean_result
			clean_result=$(cd "$repo_path" && bash "$helper" auto-clean 2>&1) || true

			local count
			count=$(echo "$clean_result" | grep -c 'Dropped') || count=0
			if [[ "$count" -gt 0 ]]; then
				local repo_name
				repo_name=$(basename "$repo_path")
				echo "[pulse-wrapper] Stash cleanup ($repo_name): $count stash(es) dropped" >>"$LOGFILE"
				total_dropped=$((total_dropped + count))
			fi
		done <<<"$repo_paths"
	else
		# Fallback: just clean the current repo
		local clean_result
		clean_result=$(bash "$helper" auto-clean 2>&1) || true
		local fallback_count
		fallback_count=$(echo "$clean_result" | grep -c 'Dropped') || fallback_count=0
		if [[ "$fallback_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Stash cleanup: $fallback_count stash(es) dropped" >>"$LOGFILE"
			total_dropped=$((total_dropped + fallback_count))
		fi
	fi

	if [[ "$total_dropped" -gt 0 ]]; then
		echo "[pulse-wrapper] Stash cleanup total: $total_dropped stash(es) dropped across all repos" >>"$LOGFILE"
	fi

	return 0
}

#######################################
# Find the one merged PR that both closes an issue structurally and matches
# the exact active worker branch/head. Search text is never lifecycle proof.
# Args: repo slug, issue number, branch name, head SHA
# Returns: 0 + PR number, 1 no match, 2 API/ambiguity failure.
#######################################
_verified_worker_closing_pr() {
	local repo_slug="$1"
	local issue_number="$2"
	local branch_name="$3"
	local head_oid="$4"
	local owner="${repo_slug%%/*}"
	local repo_name="${repo_slug#*/}"
	local response=""
	local reported_cost=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 2
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 2
	[[ -n "$branch_name" ]] || return 2
	[[ "$head_oid" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 2

	# Both connections are bounded. Their pageInfo fields are part of the trust
	# proof so truncated evidence can never authorize worker termination.
	# shellcheck disable=SC2016  # GraphQL variables are expanded by GitHub.
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="pulse-zombie-merged-pr-exact-cost" \
		gh api graphql -F owner="$owner" -F name="$repo_name" -F head="$branch_name" -f query='
		query($owner: String!, $name: String!, $head: String!) {
			repository(owner: $owner, name: $name) {
				nameWithOwner
				pullRequests(first: 100, states: MERGED, headRefName: $head) {
					nodes {
						number
						state
						mergedAt
						headRefName
						headRefOid
						closingIssuesReferences(first: 100) {
							nodes { number repository { nameWithOwner } }
							pageInfo { hasNextPage }
						}
					}
					pageInfo { hasNextPage }
				}
			}
			rateLimit { cost }
		}' 2>/dev/null) || return 2
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 2
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 2

	local verification="" verified_count="" verified_pr=""
	verification=$(printf '%s' "$response" | jq -er --arg repo "$repo_slug" --arg issue "$issue_number" \
		--arg branch "$branch_name" --arg head "$head_oid" '
		select(((.errors // []) | length) == 0)
		| .data.repository as $repository
		| select(($repository.nameWithOwner // "" | ascii_downcase) == ($repo | ascii_downcase))
		| $repository.pullRequests as $pull_requests
		| [$pull_requests.nodes[]? | select(
			.state == "MERGED" and (.mergedAt // "") != "" and
			.headRefName == $branch and .headRefOid == $head
		)] as $head_matches
		| if ($pull_requests.pageInfo.hasNextPage != false) or
			any($head_matches[]?; .closingIssuesReferences.pageInfo.hasNextPage != false)
		then "limit"
		else
			[$head_matches[] | select(
				([.closingIssuesReferences.nodes[]?
					| select((.repository.nameWithOwner // "" | ascii_downcase) == ($repo | ascii_downcase))
					| .number | tostring] | index($issue)) != null
			)] as $verified |
			[($verified | length | tostring), ($verified[0].number // "" | tostring)] | @tsv
		end
	' 2>/dev/null) || return 2
	[[ "$verification" != "limit" ]] || return 2
	IFS=$'\t' read -r verified_count verified_pr <<<"$verification"
	[[ "$verified_count" =~ ^[0-9]+$ ]] || return 2
	[[ "$verified_count" -le 1 ]] || return 2
	[[ "$verified_count" -eq 1 && -n "$verified_pr" ]] || return 1
	printf '%s\n' "$verified_pr"
	return 0
}

#######################################
# Reap zombie workers whose PRs have already been merged (t1751/GH#15489)
#
# Workers don't detect when the deterministic merge pass merges their PR.
# This function runs each pulse cycle (before worker counting) to kill
# workers that are still running after their work is done.
#
# Uses the dispatch ledger session keys (issue-{N}) to bind the issue,
# repo, and PID before checking for merged PRs and terminating the worker.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################
reap_zombie_workers() {
	local reaped=0
	local worker_key="" issue_number=""

	local session_keys
	session_keys=$(ps aux | grep '[h]eadless-runtime.*--role worker' | grep -v grep |
		sed 's/.*--session-key //' | awk '{print $1}' | sort -u) || return 0

	while IFS= read -r worker_key; do
		[[ -z "$worker_key" ]] && continue
		issue_number="${worker_key#issue-}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue

		# Session keys are issue-number only, so require the live ledger's repo
		# and PID to avoid same-number cross-repo PR/issue collisions.
		local repo_slug="" ledger_entry="" ledger_issue="" ledger_pid="" ledger_worktree="" lease_token=""
		local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
		if [[ -x "$_ledger_helper" ]]; then
			ledger_entry=$("$_ledger_helper" check --session-key "$worker_key" 2>/dev/null) || ledger_entry=""
			if [[ -n "$ledger_entry" ]]; then
				local ledger_fields
				ledger_fields=$(printf '%s' "$ledger_entry" | jq -r '[.repo_slug // "", (.issue_number // "" | tostring), (.pid // "" | tostring), .worktree_path // "", .lease_token // ""] | @tsv' 2>/dev/null) || ledger_fields=$'\t\t\t\t'
				IFS=$'\t' read -r repo_slug ledger_issue ledger_pid ledger_worktree lease_token <<<"$ledger_fields"
			fi
		fi
		if [[ -z "$repo_slug" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: no live ledger repo; refusing repo-less merged-PR lookup" >>"$LOGFILE"
			continue
		fi
		if [[ -n "$ledger_issue" && "$ledger_issue" != "$issue_number" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: ledger issue ${ledger_issue} does not match session issue ${issue_number}" >>"$LOGFILE"
			continue
		fi
		if [[ -z "$ledger_pid" || ! "$ledger_pid" =~ ^[0-9]+$ ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: no ledger PID; refusing session-key-wide kill" >>"$LOGFILE"
			continue
		fi
		if [[ -z "$lease_token" || -z "$ledger_worktree" || ! -d "$ledger_worktree" ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: active dispatch generation/worktree is unavailable" >>"$LOGFILE"
			continue
		fi
		local branch_name="" head_oid=""
		branch_name=$(git -C "$ledger_worktree" branch --show-current 2>/dev/null) || branch_name=""
		head_oid=$(git -C "$ledger_worktree" rev-parse HEAD 2>/dev/null) || head_oid=""
		if [[ -z "$branch_name" || ! "$head_oid" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: worker branch/head could not be verified" >>"$LOGFILE"
			continue
		fi
		local merged_pr="" verification_rc=0
		merged_pr=$(_verified_worker_closing_pr "$repo_slug" "$issue_number" "$branch_name" "$head_oid") || verification_rc=$?
		if [[ "$verification_rc" -eq 2 ]]; then
			echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: merged PR evidence is ambiguous or API-indeterminate" >>"$LOGFILE"
			continue
		fi

		if [[ "$verification_rc" -eq 0 && -n "$merged_pr" ]]; then
			if ! "$_ledger_helper" complete --session-key "$worker_key" --lease-token "$lease_token" \
				--reason merged_pr_reap 2>/dev/null; then
				echo "[pulse-wrapper] Zombie reap skipped for ${worker_key}: active dispatch generation changed before termination" >>"$LOGFILE"
				continue
			fi
			# The lease transition is the compare-and-set gate. Only the exact active
			# generation can reach process termination and terminal telemetry.
			echo "[pulse-wrapper] Reaping zombie worker ${worker_key}: PR #${merged_pr} already merged in ${repo_slug}" >>"$LOGFILE"
			echo "[INFO] [lifecycle] worker_reap pid=${ledger_pid} kill_reason=merged_pr_reap issue=${issue_number} pr=${merged_pr}" >>"$LOGFILE"
			"$_ledger_helper" record-outcome --issue "$issue_number" --repo "$repo_slug" --outcome success \
				--reason merged_pr_reap --session-key "$worker_key" --lease-token "$lease_token" 2>/dev/null || true
			kill "$ledger_pid" 2>/dev/null || true
			reaped=$((reaped + 1))
		fi
	done <<<"$session_keys"

	if [[ "$reaped" -gt 0 ]]; then
		echo "[pulse-wrapper] Reaped ${reaped} zombie worker(s) with merged PRs (t1751)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Recover issue state after launch validation failure (t1702)
#
# When launch validation fails, the issue may remain assigned + queued even
# though no worker process exists. This traps capacity by blocking redispatch.
#
# Safety gates:
#   - Only act on OPEN issues
#   - Only act when current GitHub login is assigned on the issue
#   - Only act when issue still has status:queued label
#   - Re-check for a late-started worker before mutating issue state
#
# Actions (best-effort):
#   1. Mark any in-flight ledger entry for this issue as failed
#   2. Remove self assignee and status:queued
#   3. Re-label status:available unless issue is blocked
#
# Args:
#   $1 - issue number
#   $2 - repo slug
#   $3 - failure reason string (for logs)
#######################################

# t2394 helper: post CLAIM_RELEASED so cross-runner dedup immediately re-opens
# the issue for dispatch instead of waiting for the 30-min DISPATCH_CLAIM TTL
# to expire. Without this, a fast-failing worker leaves a stale claim comment
# that poisons cross-runner coordination for up to 1800s per failure — the
# local state (assignee, status label) is already reset but the claim comment
# is authoritative for peer runners. Mirrors the pattern in
# worker-activity-watchdog.sh:222 and headless-runtime-failure.sh:59 — those
# paths already post CLAIM_RELEASED; the launch-failure recovery path was the
# missing coverage.
#
# t2814 (Phase 3, fix #1): Include the tail of the worker log in the claim-
# released comment for `no_worker_process` failures. Closes the diagnostic
# gap identified in t2813 root cause analysis: worker logs in the pulse temp
# directory existed but were never read
# during recovery, so every `no_worker_process` event ended with the same
# opaque "no active worker process" message and no insight into whether the
# canary failed, the session lock collided, or the runtime crashed before
# OpenCode could spawn. The 20-line tail captures canary diagnostics
# (last `print_warning` lines) and any early-exit traceback.
_post_launch_recovery_claim_released() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local failure_reason="$4"

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
CLAIM_RELEASED reason=launch_recovery:${failure_reason} runner=${self_login} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) aidevops_version=${aidevops_version} opencode_version=${opencode_version}"

	# t2814: append worker-log tail when available so the failure is
	# diagnosable from the audit trail alone (no log-file forensics needed).
	# Bounded to last 20 lines and 4KB to keep comments readable and avoid
	# accidental credential leakage from verbose stack traces.
	#
	# t2820: extracted to `_read_worker_log_tail_classified` in
	# shared-claim-lifecycle.sh — same bounds + path enumeration. The
	# classification side-output is unused here (the comment just embeds
	# the raw tail); escalate_issue_tier consumes the classification for
	# its no_work reclassification path. Keeping a single reader prevents
	# the two consumers from drifting on log-path conventions.
	if declare -F _read_worker_log_tail_classified >/dev/null 2>&1; then
		_read_worker_log_tail_classified "$issue_number" "$repo_slug"
		if [[ -n "${_WORKER_LOG_TAIL_FILE:-}" && -n "${_WORKER_LOG_TAIL_CONTENT:-}" ]]; then
			body="${body}

<details>
<summary>worker log tail (last 20 lines, source: ${_WORKER_LOG_TAIL_FILE})</summary>

\`\`\`text
${_WORKER_LOG_TAIL_CONTENT}
\`\`\`

</details>"
		fi
	fi
	body="${body}
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || true
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_number" || true
	return 0
}

# t2897 helper: record a launch failure as a zero-attempt outcome for the
# per-runner circuit breaker. Only `no_worker_process` counts as a zero-
# attempt signal — other failure_reasons (cli_usage_output, stale_timeout,
# etc.) are real-attempt failures and aren't recorded. Extracted from
# recover_failed_launch_state to keep that function under the 100-line
# function-complexity gate.
_record_runner_health_zero_attempt() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="$3"

	[[ "$failure_reason" == "no_worker_process" ]] || return 0
	local _rh_helper="${SCRIPT_DIR}/pulse-runner-health-helper.sh"
	[[ -x "$_rh_helper" ]] || return 0
	"$_rh_helper" record-outcome no_worker_process \
		"${repo_slug}#${issue_number}" >/dev/null 2>&1 || true
	return 0
}

# t3197: write a per-issue dispatch-cooldown audit marker after a
# `no_worker_process` launch failure. The reader is
# `dispatch-dedup-helper.sh::_is_assigned_check_dispatch_cooldown`, which
# parses the most recent `<!-- dispatch-cooldown-until:<ISO> ... -->`
# marker on the issue and short-circuits dispatch with
# `DISPATCH_COOLDOWN_ACTIVE` while the timestamp is in the future.
#
# Closes the rapid-retry loop where a broken runtime (CLI changes, missing
# binary, network flake) burns ~5 worker spawns over 3-4 hours per issue
# with 95-99s lifespans each, repeating across 30+ issues simultaneously
# when one runner is unhealthy.
#
# Only `no_worker_process` qualifies — `cli_usage_output`, `stale_timeout`,
# and other failure_reasons have their own retry/escalation mechanisms;
# layering a cooldown on top would over-throttle.
#
# Disabled by setting DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0.
# Default cooldown: 1800 seconds (30 minutes).
#
# Always returns 0 — cooldown is a soft optimization, never blocks the
# wider recovery path on its own failure (gh API hiccup, date parse
# error, etc.).
_post_launch_cooldown_marker() {
	# $4 is the failure_reason; only no_worker_process should write a marker.
	# Unquoted RHS in [[ ]] keeps the literal off the repeated-string counter.
	[[ ${4-} == no_worker_process ]] || return 0

	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"

	local cooldown_s="${DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS:-1800}"
	[[ "$cooldown_s" =~ ^[0-9]+$ ]] || cooldown_s=1800
	(( cooldown_s > 0 )) || return 0

	local now_epoch until_epoch iso
	now_epoch=$(date -u +%s 2>/dev/null) || return 0
	until_epoch=$((now_epoch + cooldown_s))

	# Portable ISO formatting: GNU `date -d "@<epoch>"` first, BSD `date -r` fallback.
	iso=$(date -u -d "@${until_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		iso=$(date -u -r "${until_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) ||
		return 0
	[[ -n "$iso" ]] || return 0

	local body="<!-- dispatch-cooldown-until:${iso} reason=no_worker_process runner=${self_login} -->
Dispatch cooldown active until ${iso} following a no_worker_process launch failure (t3197). The pulse will not redispatch this issue until the marker expires. Set DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0 to disable."

	local comments_endpoint
	# printf single-quoted format keeps the endpoint literal off the
	# repeated-string-literal counter (the same path appears verbatim in
	# _post_launch_recovery_claim_released and _is_stale_assignment).
	comments_endpoint=$(printf 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number")
	gh api "$comments_endpoint" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || true
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_number" || true
	return 0
}

#######################################
# Confirm launch recovery removed this runner's launch ownership and applied
# the intended replacement status before publishing any success receipt.
# Args: issue number, repo slug, runner login, target status
#######################################
_verify_launch_recovery_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local target_status="$4"
	local issue_meta_json=""

	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees 2>/dev/null) || return 1
	printf '%s' "$issue_meta_json" | jq -e --arg self "$self_login" --arg target "status:${target_status}" '
		.state == "OPEN" and
		(([.labels[].name] | index("status:queued")) == null) and
		(([.labels[].name] | index("status:in-progress")) == null) and
		(([.labels[].name] | index($target)) != null) and
		(([.assignees[].login] | index($self)) == null)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Prove that an in-progress issue is still owned by the exact registered
# prelaunch attempt that launch validation is recovering. The local ledger and
# latest durable dispatch marker must agree on every generated identity field,
# and the registered PID/start-token pair must no longer identify a live
# process. Queued issues retain their established recovery path.
# Args: issue number, repo slug, ledger entry JSON
#######################################
_launch_recovery_owns_registered_attempt() {
	local issue_number="$1"
	local repo_slug="$2"
	local ledger_entry="$3"
	local fields="" session_key="" attempt_id="" lease_token="" runner_device=""
	local worker_pid="" owner_process_start="" ledger_status="" lease_phase=""

	fields=$(printf '%s' "$ledger_entry" | jq -r '[.session_key // "", .attempt_id // "", .lease_token // "", .runner_device // "", (.pid // "" | tostring), .owner_process_start // "", .status // "", .lease_phase // ""] | @tsv' 2>/dev/null) || return 1
	IFS=$'\t' read -r session_key attempt_id lease_token runner_device worker_pid owner_process_start ledger_status lease_phase <<<"$fields"
	[[ -n "$session_key" && -n "$attempt_id" && -n "$lease_token" && -n "$runner_device" ]] || return 1
	[[ "$worker_pid" =~ ^[1-9][0-9]*$ && -n "$owner_process_start" ]] || return 1
	[[ "$ledger_status" == "in-flight" && "$lease_phase" == "prelaunch" ]] || return 1

	if kill -0 "$worker_pid" 2>/dev/null; then
		local current_start=""
		current_start=$(_process_start_token "$worker_pid" 2>/dev/null || true)
		[[ -n "$current_start" && "$current_start" != "$owner_process_start" ]] || return 1
	fi

	local comments_endpoint="" latest_dispatch=""
	comments_endpoint=$(printf 'repos/%s/issues/%s/comments' "$repo_slug" "$issue_number")
	latest_dispatch=$(gh api "$comments_endpoint" --paginate --jq \
		'[.[] | select(.body | contains("<!-- aidevops:dispatch "))] | last | .body // ""' 2>/dev/null) || return 1
	[[ "$latest_dispatch" == *"lease_token=${lease_token} "* ]] || return 1
	[[ "$latest_dispatch" == *"device=${runner_device} "* ]] || return 1
	[[ "$latest_dispatch" == *"session=${session_key} "* ]] || return 1
	[[ "$latest_dispatch" == *"attempt_id=${attempt_id} "* ]] || return 1
	return 0
}

recover_failed_launch_state() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_reason="${3:-launch_validation_failed}"
	local crash_type="${4:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Capture the exact in-flight attempt. It is marked failed only after its
	# GitHub ownership has been proven and released.
	local ledger_helper ledger_entry="" session_key="" lease_token="" attempt_id=""
	ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		ledger_entry=$("$ledger_helper" check-issue --issue "$issue_number" --repo "$repo_slug" 2>/dev/null || true)
		session_key=$(printf '%s' "$ledger_entry" | jq -r '.session_key // ""' 2>/dev/null)
		lease_token=$(printf '%s' "$ledger_entry" | jq -r '.lease_token // ""' 2>/dev/null)
		attempt_id=$(printf '%s' "$ledger_entry" | jq -r '.attempt_id // ""' 2>/dev/null)
	fi

	# For no-worker failures, skip cleanup if a late-started worker appears.
	# For cli_usage_output failures, always continue to clear stale claim state.
	if [[ "$failure_reason" != "cli_usage_output" ]]; then
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): worker appeared after validation failure" >>"$LOGFILE"
			return 0
		fi
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): unable to resolve current login" >>"$LOGFILE"
		return 0
	fi

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json state,labels,assignees 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		return 0
	fi

	local issue_state="" assigned_to_self="" has_queued="" has_in_progress="" is_blocked=""
	issue_state=$(echo "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null)
	assigned_to_self=$(echo "$issue_meta_json" | jq -r --arg self "$self_login" '([.assignees[].login] | index($self)) != null' 2>/dev/null)
	has_queued=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:queued")) != null' 2>/dev/null)
	has_in_progress=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:in-progress")) != null' 2>/dev/null)
	is_blocked=$(echo "$issue_meta_json" | jq -r '([.labels[].name] | index("status:blocked")) != null' 2>/dev/null)

	[[ "$assigned_to_self" == "true" || "$assigned_to_self" == "$_PULSE_CLEANUP_FALSE" ]] || assigned_to_self=""
	[[ "$has_queued" == "true" || "$has_queued" == "$_PULSE_CLEANUP_FALSE" ]] || has_queued=""
	[[ "$has_in_progress" == "true" || "$has_in_progress" == "$_PULSE_CLEANUP_FALSE" ]] || has_in_progress=""
	[[ "$is_blocked" == "true" || "$is_blocked" == "$_PULSE_CLEANUP_FALSE" ]] || is_blocked=""

	if [[ "$issue_state" != "OPEN" ]] || [[ "$assigned_to_self" != "true" ]]; then
		return 0
	fi
	if [[ "$has_queued" != "true" ]]; then
		if [[ "$has_in_progress" != "true" ]] || ! _launch_recovery_owns_registered_attempt "$issue_number" "$repo_slug" "$ledger_entry"; then
			echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): in-progress ownership does not match the failed registered attempt" >>"$LOGFILE"
			return 0
		fi
	fi
	if [[ "$has_queued" == "true" && "$has_in_progress" == "true" ]]; then
		echo "[pulse-wrapper] Launch recovery skipped for #${issue_number} (${repo_slug}): ambiguous queued/in-progress overlap" >>"$LOGFILE"
		return 0
	fi

	# t2033: atomic transitions via set_issue_status. The blocked branch
	# preserves status:blocked (target = "blocked"); the normal branch
	# transitions to status:available.
	local target_status="available"
	[[ "$is_blocked" == "true" ]] && target_status="blocked"
	if ! set_issue_status "$issue_number" "$repo_slug" "$target_status" \
		--remove-assignee "$self_login" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Launch recovery uncertain for #${issue_number} (${repo_slug}): ownership mutation failed" >>"$LOGFILE"
		return 1
	fi
	if ! _verify_launch_recovery_state "$issue_number" "$repo_slug" "$self_login" "$target_status"; then
		echo "[pulse-wrapper] Launch recovery uncertain for #${issue_number} (${repo_slug}): post-mutation verification failed" >>"$LOGFILE"
		return 1
	fi
	if [[ -n "$session_key" && -x "$ledger_helper" ]]; then
		local -a fail_args=(fail --session-key "$session_key")
		[[ -n "$lease_token" ]] && fail_args+=(--lease-token "$lease_token")
		[[ -n "$attempt_id" ]] && fail_args+=(--attempt-id "$attempt_id")
		"$ledger_helper" "${fail_args[@]}" >/dev/null 2>&1 || true
	fi

	# t2394: Invalidate stale cross-runner claims immediately (see helper below).
	_post_launch_recovery_claim_released "$issue_number" "$repo_slug" "$self_login" "$failure_reason"
	# t3197: Write a per-issue dispatch cooldown marker so other runners
	# (and this one) skip redispatch for the configured cooldown window.
	# Only fires for `no_worker_process` — the recurring no-spawn failure mode.
	_post_launch_cooldown_marker "$issue_number" "$repo_slug" "$self_login" "$failure_reason"
	# t2897: Record zero-attempt outcome for the per-runner circuit breaker.
	_record_runner_health_zero_attempt "$issue_number" "$repo_slug" "$failure_reason"
	# t1934 / GH#30180: Guardedly release only the issue conversation lock.
	unlock_issue_after_worker "$issue_number" "$repo_slug"

	# Record the launch failure in the fast-fail counter (t1888).
	# t2815: no_worker_process = infra failure; map to no_work so escalate_issue_tier
	# short-circuits at the t2387 guard and skips tier escalation.
	local effective_crash_type="$crash_type"
	if [[ "$failure_reason" == "no_worker_process" && -z "$effective_crash_type" ]]; then
		effective_crash_type="no_work"
	fi
	fast_fail_record "$issue_number" "$repo_slug" "$failure_reason" "anthropic" "$effective_crash_type" || true
	# t1959: Wire global circuit breaker for launch-class failures only.
	# Stale timeouts and in-execution failures have their own per-issue backoff
	# and should not trip a global halt. Only true launch failures signal
	# systemic runtime breakage. Recovery happens via record-success on PR merge
	# or issue close (already wired in supervisor) — NEVER reset on launch success.
	case "$failure_reason" in
	no_worker_process | cli_usage_output)
		local cb_helper="${SCRIPT_DIR}/circuit-breaker-helper.sh"
		if [[ -x "$cb_helper" ]]; then
			"$cb_helper" record-failure "${repo_slug}#${issue_number}" "$failure_reason" >/dev/null 2>&1 || true
		fi
		;;
	esac

	echo "[pulse-wrapper] Launch recovery reset #${issue_number} (${repo_slug}) after ${failure_reason} crash_type=${effective_crash_type:-unclassified}: removed self assignee + launch status" >>"$LOGFILE"
	return 0
}

cleanup_stalled_workers() {
	local killed=0
	local freed_mb=0

	while IFS= read -r line; do
		local pid etime cpu rss cmd
		read -r pid etime cpu rss cmd <<<"$line"

		# Only check headless workers (no TTY, full-loop in command)
		case "$cmd" in
		*"/full-loop"*) ;;
		*) continue ;;
		esac

		# Check process age
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALLED_WORKER_MIN_AGE" ]]; then
			continue
		fi

		# Extract issue number and find log file
		local issue_num
		issue_num=$(echo "$cmd" | grep -oE 'issue #[0-9]+' | grep -oE '[0-9]+' | head -1)
		[[ -n "$issue_num" ]] || continue

		local log_file="" log_size=""
		# Check all registered repos for matching logs, including dormant scope.
		local found_log=""
		local repo_slug=""
		while IFS= read -r repo_slug; do
			[[ -n "$repo_slug" ]] || continue
			log_file=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_num" 2>/dev/null || true)
			if [[ -f "$log_file" ]]; then
				found_log="$log_file"
				break
			fi
		done < <(jq -r '.initialized_repos[] | .slug // ""' "$REPOS_JSON")
		# Fallback log path
		if [[ -z "$found_log" ]]; then
			log_file=$(aidevops_pulse_worker_log_fallback_path "$issue_num" 2>/dev/null || true)
			[[ -f "$log_file" ]] && found_log="$log_file"
		fi

		if [[ -z "$found_log" ]]; then
			continue
		fi

		# Check log size — stalled workers have ≤500 bytes (just sandbox startup)
		log_size=$(wc -c <"$found_log" 2>/dev/null || echo "0")
		log_size=$(echo "$log_size" | tr -d ' ')
		[[ "$log_size" =~ ^[0-9]+$ ]] || log_size=0

		if [[ "$log_size" -gt "$STALLED_WORKER_MAX_LOG_BYTES" ]]; then
			# Worker has produced real output — it's working, not stalled
			continue
		fi

		# Extract model from the command line for backoff recording
		local worker_model
		worker_model=$(echo "$cmd" | grep -oE '\-m [^ ]+' | head -1 | sed 's/-m //')

		# Kill the stalled worker
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		freed_mb=$((freed_mb + mb))

		# Record provider backoff so next dispatch rotates away
		if [[ -n "$worker_model" ]]; then
			local provider
			provider=$(echo "$worker_model" | cut -d/ -f1)
			local tmp_backoff
			tmp_backoff=$(mktemp)
			printf 'Worker stalled: PID %s, issue #%s, model %s, age %ss, log %s bytes\n' \
				"$pid" "$issue_num" "$worker_model" "$age_seconds" "$log_size" >"$tmp_backoff"

			# Use the headless runtime helper to record backoff properly
			if [[ -x "${SCRIPT_DIR}/headless-runtime-helper.sh" ]]; then
				"${SCRIPT_DIR}/headless-runtime-helper.sh" backoff set "$worker_model" "rate_limit" 900 2>/dev/null || true
			fi
			rm -f "$tmp_backoff"
		fi

		echo "[pulse-wrapper] Killed stalled worker PID $pid (issue #${issue_num}, model=${worker_model:-unknown}, age=${age_seconds}s, log=${log_size}B) — provider likely rate-limited" >>"$LOGFILE"

	done < <(ps axwwo pid,etime,%cpu,rss,command | grep '[.]opencode run' | grep -v grep)

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] cleanup_stalled_workers: killed ${killed} stalled workers (freed ~${freed_mb}MB)" >>"$LOGFILE"
	fi
	# Accumulate into per-cycle health counter (GH#15107)
	_PULSE_HEALTH_STALLED_KILLED=$((_PULSE_HEALTH_STALLED_KILLED + killed))
	return 0
}

cleanup_orphans() {

	local killed=0
	local total_mb=0

	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		# Skip interactive sessions (has a real TTY).
		# Exclude both '?' (Linux headless) and '??' (macOS headless) — only
		# those are headless; anything else (pts/N, ttys00N) is interactive.
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		# Skip active workers, pulse, strategic reviews, and language servers.
		# Use case instead of [[ =~ ]] with | alternation — zsh parses the |
		# as a pipe operator inside [[ ]], causing a parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# Skip young processes
		# t2859: ${ORPHAN_MAX_AGE:-7200} fallback (2h) — without this,
		# unbound expansion to "" makes every process look "older than 0"
		# and would kill all matched orphans regardless of actual age.
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "${ORPHAN_MAX_AGE:-7200}" ]]; then
			continue
		fi

		# This is an orphan — kill it
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		kill "$pid" 2>/dev/null || true
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep '[.]opencode' | grep -v 'bash-language-server')

	# Also kill orphaned node launchers (parent of .opencode processes)
	while IFS= read -r line; do
		local pid tty etime rss cmd
		read -r pid tty etime rss cmd <<<"$line"

		[[ "$tty" != "?" && "$tty" != "??" ]] && continue
		# Use case instead of [[ =~ ]] with | alternation — zsh parse error. See GH#4904.
		case "$cmd" in
		*"/full-loop"* | *"/review-issue-pr"* | *"Supervisor Pulse"* | *"Strategic Review"* | *"language-server"* | *"eslintServer"*)
			continue
			;;
		esac

		# t2859: ${ORPHAN_MAX_AGE:-7200} fallback (2h) — see comment above.
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		[[ "$age_seconds" -lt "${ORPHAN_MAX_AGE:-7200}" ]] && continue

		kill "$pid" 2>/dev/null || true
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,tty,etime,rss,command | grep 'node.*opencode' | grep -v '[.]opencode')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed orphaned opencode processes (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}

cleanup_stale_opencode() {
	local killed=0
	local total_mb=0

	# Get our own PID tree to avoid killing the current session
	local my_pid="$$"
	local my_ppid
	my_ppid=$(ps -p "$my_pid" -o ppid= 2>/dev/null | tr -d ' ') || my_ppid=""

	while IFS= read -r line; do
		local pid cpu rss
		read -r pid cpu rss <<<"$line"

		# Skip our own process tree
		if [[ "$pid" == "$my_pid" || "$pid" == "$my_ppid" ]]; then
			continue
		fi

		# Skip interactive sessions — only kill headless workers.
		# Headless workers are launched via headless-runtime-helper.sh with
		# --format json in the command line. Interactive sessions (user typing
		# in a terminal) never have this flag. Without this guard, any idle
		# interactive session (user stepped away) gets killed along with its
		# parent shell, closing the terminal tab entirely.
		local proc_cmd
		proc_cmd=$(ps -p "$pid" -o command= 2>/dev/null) || proc_cmd=""
		if [[ "$proc_cmd" != *"--format json"* ]]; then
			continue
		fi

		# Skip young processes
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		if [[ "$age_seconds" -lt "$STALE_OPENCODE_MAX_AGE" ]]; then
			continue
		fi

		# Skip processes with significant CPU usage (actively working)
		# cpu is a float like "0.0" or "40.3" — compare integer part.
		# t2859: ${PULSE_IDLE_CPU_THRESHOLD:-2} fallback (2% CPU) — without
		# this, unbound expansion to "" treated as 0 would make every
		# process "active" (cpu >= 0) and skip every kill candidate.
		local cpu_int
		cpu_int="${cpu%%.*}"
		[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
		if [[ "$cpu_int" -ge "${PULSE_IDLE_CPU_THRESHOLD:-2}" ]]; then
			continue
		fi

		# This is a stale headless worker — kill it and its parent chain
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		local mb=$((rss / 1024))

		# Kill parent (node launcher) and grandparent (zsh tab) first
		local ppid
		ppid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || ppid=""
		if [[ -n "$ppid" && "$ppid" != "1" ]]; then
			local gppid
			gppid=$(ps -p "$ppid" -o ppid= 2>/dev/null | tr -d ' ') || gppid=""
			# Kill grandparent zsh (the terminal tab shell)
			if [[ -n "$gppid" && "$gppid" != "1" ]]; then
				local gp_cmd
				gp_cmd=$(ps -p "$gppid" -o command= 2>/dev/null) || gp_cmd=""
				# Only kill if it's a shell that launched opencode
				case "$gp_cmd" in
				*zsh* | *bash* | *sh*)
					kill "$gppid" 2>/dev/null || true
					;;
				esac
			fi
			# Kill parent node launcher
			kill "$ppid" 2>/dev/null || true
		fi

		# Kill the .opencode process — SIGTERM first, SIGKILL fallback.
		# OpenCode's file watcher may ignore SIGTERM.
		kill "$pid" 2>/dev/null || true
		sleep 1
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 "$pid" 2>/dev/null || true
		fi
		killed=$((killed + 1))
		total_mb=$((total_mb + mb))
	done < <(ps axwwo pid,%cpu,rss,command | awk '$0 ~ /[.]opencode/ && $0 !~ /bash-language-server/ { print $1, $2, $3 }')

	if [[ "$killed" -gt 0 ]]; then
		echo "[pulse-wrapper] Cleaned up $killed stale headless opencode workers (freed ~${total_mb}MB)" >>"$LOGFILE"
	fi
	return 0
}
