#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-engine.sh — High-level dispatch engine — worker launch check, ranked candidate build, dispatch_max, LLM supervisor gate, backlog snapshot, adaptive launch settle wait, utilization invariants, underfill recycler + re-fill during active cycle, pre-flight stages, initial underfill computation, early-exit recycle loop.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Public functions in this module (in source order):
#   - check_worker_launch
#   - build_ranked_dispatch_candidates_json
#   - dispatch_max
#   - _should_run_llm_supervisor
#   - _update_backlog_snapshot
#   - _adaptive_launch_settle_wait
#   - apply_dispatch_max
#   - enforce_utilization_invariants
#   - run_underfill_worker_recycler
#   - maybe_refill_underfilled_pool_during_active_pulse
#   - _run_preflight_stages
#   - _compute_initial_underfill
#   - _run_early_exit_recycle_loop
#
# Internal helpers (GH#18656 function decomposition):
#   _dispatch_*                 — helpers for dispatch_max
#   _preflight_*           — helpers for _run_preflight_stages
#
# Phase 9 origin: pure move from pulse-wrapper.sh, byte-identical bodies.
# GH#18656 split the two functions that still exceeded 100 lines
# (dispatch_max=202, _run_preflight_stages=134)
# into focused helpers while preserving byte-for-byte behavior.

[[ -n "${_PULSE_DISPATCH_ENGINE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_ENGINE_LOADED=1

# Resolve this module's dependencies relative to itself, not a caller-owned
# SCRIPT_DIR. Test harnesses and other sourced callers legitimately use that
# generic variable for their own directory (GH#27888).
_PULSE_DISPATCH_ENGINE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# t2863: Module-level variable defaults (set -u guards).
# These vars are normally set by pulse-wrapper.sh bootstrap and pulse-wrapper-config.sh.
# Guard them here so dispatch engine functions survive standalone sourcing (test
# harnesses, pulse-merge-routine.sh, or any caller that doesn't run the full bootstrap).
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PIDFILE:=${HOME}/.aidevops/logs/pulse.pid}"
: "${PRE_RUN_STAGE_TIMEOUT:=600}"
# t2989: per-candidate cap inside dispatch_max so a single
# hung dispatch_with_dedup call cannot consume the parent stage's full 600s
# budget. Canonical failure: preflight_early_dispatch 0/8 success rate after
# 07:00Z 2026-04-27 — single hung iter consumed the whole stage; cycle
# cadence collapsed from ~2min to ~40min. 30s is generous: dedup check +
# nohup worker spawn normally completes in <5s.
#
# t3015 back-compat: honour deprecated FILL_FLOOR_PER_CANDIDATE_TIMEOUT name.
# Operators who set the old name in their environment / launchd plist before
# upgrading should not silently lose their override. Emit a one-shot stderr
# warning and bridge the value into the new variable. Remove in v4.0.
if [[ -n "${FILL_FLOOR_PER_CANDIDATE_TIMEOUT:-}" && -z "${DISPATCH_PER_CANDIDATE_TIMEOUT:-}" ]]; then
	echo "[pulse-wrapper] WARNING: FILL_FLOOR_PER_CANDIDATE_TIMEOUT is deprecated — use DISPATCH_PER_CANDIDATE_TIMEOUT (t3015)" >&2
	DISPATCH_PER_CANDIDATE_TIMEOUT="$FILL_FLOOR_PER_CANDIDATE_TIMEOUT"
	export DISPATCH_PER_CANDIDATE_TIMEOUT
fi
: "${DISPATCH_PER_CANDIDATE_TIMEOUT:=30}"
# t3005/t3014/GH#29234: parallel dispatch concurrency for dispatch_max.
# Each successful dispatch takes ~30-180s (gh API ceremony + worktree-helper.sh
# add + worker spawn) so the previous serial loop capped throughput at ~1
# dispatch per pulse cycle.
#
# Default (GH#29234): unset or invalid → min(6, _effective_slots). Worker-slot
# capacity is not a safe proxy for simultaneous dispatch ceremony process trees;
# each candidate adds API, worktree, and runtime-start overhead before occupying
# its worker slot. Setting an explicit positive integer overrides the default,
# while the cap inside _dispatch_max_compute_parallel still prevents concurrency
# above _effective_slots. Set to 1 to retain the legacy serial behavior.
#
# A 24-way default overloaded a 16-CPU host before workers could settle; six-way
# dispatch restored bounded load and successful launches. Larger hosts can opt in
# to more concurrency with DISPATCH_MAX_PARALLEL.
#
# Intentionally left as soft default (`:-` form, no `:=` global default) so
# the variable stays unset for callers that read it for diagnostics.
: "${PULSE_ACTIVE_REFILL_INTERVAL:=120}"
: "${PULSE_ACTIVE_REFILL_IDLE_MIN:=60}"
: "${PULSE_ACTIVE_REFILL_STALL_MIN:=120}"
: "${PULSE_BACKFILL_MAX_ATTEMPTS:=3}"
: "${PULSE_LAUNCH_GRACE_SECONDS:=35}"
: "${PULSE_LAUNCH_SETTLE_BATCH_MAX:=5}"
: "${PULSE_LLM_DAILY_INTERVAL:=86400}"
: "${PULSE_LLM_FAILURE_RETRY_INTERVAL:=1800}"
: "${PULSE_LLM_STALL_THRESHOLD:=3600}"
: "${PULSE_RATE_LIMIT_FLAG:=${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}"
: "${PULSE_RUNNABLE_ISSUE_LIMIT:=1000}"
: "${PULSE_DISPATCH_AGE_BONUS_PER_DAY:=25}"
: "${PULSE_DISPATCH_AGE_BONUS_CAP:=900}"
: "${AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED:=0}"
: "${PULSE_CAMPAIGN_HORIZON:=10}"
: "${PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS:=3600}"
: "${PULSE_CAMPAIGN_TIMEOUT_SECONDS:=5}"
: "${AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING:=1}"

# t2690: Source rate-limit circuit breaker (proactive dispatch pause on GraphQL exhaustion).
# shellcheck source=pulse-rate-limit-circuit-breaker.sh
if [[ -f "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh" ]]; then
	# shellcheck disable=SC1091
	source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-rate-limit-circuit-breaker.sh"
fi

# t2781: Source per-issue rate_limit backoff helper (graduated cooldown by failure count).
# shellcheck source=dispatch-backoff-helper.sh
if [[ -f "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/dispatch-backoff-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/dispatch-backoff-helper.sh"
fi

# GH#21738: Source extracted helper sub-libraries (orchestrator + sub-library
# split per reference/large-file-split.md). The dispatch lib carries all
# `_dispatch_*` helpers + module-level _DISPATCH_ counters + pulse_dispatch_debug_log;
# the preflight lib carries all `_preflight_*` helpers. The orchestrator
# retains dispatch_max, _run_preflight_stages, and
# run_underfill_worker_recycler (>100-line bodies — moving them would
# re-register them as new function-complexity violations under their new
# (file, fname) identity keys).
# shellcheck source=./pulse-dispatch-lib.sh
# shellcheck disable=SC1091  # sub-library resolved from this module's path
source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-dispatch-lib.sh"
# shellcheck source=./pulse-dispatch-current-state-guardrails.sh
# shellcheck disable=SC1091  # sub-library resolved from this module's path
source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-dispatch-current-state-guardrails.sh"
# shellcheck source=./pulse-dispatch-preflight-lib.sh
# shellcheck disable=SC1091  # sub-library resolved from this module's path
source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-dispatch-preflight-lib.sh"
# shellcheck source=./pulse-campaign-shadow.sh
# shellcheck disable=SC1091  # adapter resolved from this module's path
if [[ -f "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-campaign-shadow.sh" ]]; then
	source "${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR}/pulse-campaign-shadow.sh"
else
	# Mixed-version deployment fallback: preserve the pre-campaign candidate path
	# if the new adapter has not reached this runner yet.
	pulse_campaign_shadow_candidates_json() {
		local repo_slug="$1"
		local repo_path="$2"
		local source_limit="${3:-1000}"
		local dependency_normalization_mode="${4:-normalize}"
		local candidates_json="[]"
		: "$repo_path"
		candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$source_limit" "" "" "$dependency_normalization_mode") || candidates_json='[]'
		_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates_json"
		return 0
	}
fi

# t1959: Module-level variable to communicate launch failure reason to callers.
# Set by check_worker_launch before each return 1; read by dispatch loop for
# per-round no_worker_process tracking and canary cache invalidation.
_PULSE_LAST_LAUNCH_FAILURE=""

#######################################
# Extract a trusted prelaunch failure reason from a worker log.
#
# Args:
#   $1 - worker log path
# Stdout: allowlisted reason token, or blank when unavailable.
# Returns: 0 always; diagnostics must never block dispatch cleanup.
#######################################
_pulse_worker_log_prelaunch_failure_reason() {
	local log_path="$1"
	local reason=""

	[[ -f "$log_path" ]] || { printf '\n'; return 0; }

	reason=$(awk '
		/\[systemd-launch\] classification=crash_during_startup/ {
			systemd_startup_failure = 1
		}
		/\[exit-trap\] using prelaunch failure reason:/ {
			line = $0
			sub(/^.*\[exit-trap\] using prelaunch failure reason:[[:space:]]*/, "", line)
			split(line, parts, /[[:space:]]+/)
			reason = parts[1]
		}
		/\[exit-trap\] session=/ && / reason=/ && reason == "" {
			line = $0
			sub(/^.* reason=/, "", line)
			split(line, parts, /[[:space:]]+/)
			reason = parts[1]
		}
		END {
			if (systemd_startup_failure) { print "crash_during_startup" }
			else if (reason != "") { print reason }
		}
	' "$log_path" 2>/dev/null) || reason=""

	case "$reason" in
	worker_worktree_live_owner | worker_worktree_continuation_* | \
		worker_worktree_owner_concurrent_mutation | crash_during_startup)
		printf '%s\n' "$reason"
		;;
	*)
		printf '\n'
		;;
	esac
	return 0
}

#######################################
# Launch validation gate for pulse dispatches (t1453)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional grace timeout in seconds
#
# Exit codes:
#   0 - worker launch appears valid (process remains alive after stability check)
#   1 - launch invalid (no process within grace window or usage output detected)
#######################################
check_worker_launch() {
	local issue_number="$1"
	local repo_slug="$2"
	local grace_seconds="${3:-$PULSE_LAUNCH_GRACE_SECONDS}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_worker_launch: invalid arguments issue='$issue_number' repo='$repo_slug'" >>"$LOGFILE"
		return 1
	fi
	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds="$PULSE_LAUNCH_GRACE_SECONDS"
	if [[ "$grace_seconds" -lt 1 ]]; then
		grace_seconds=1
	fi

	local -a log_candidates=()
	local _candidate=""
	while IFS= read -r _candidate; do
		[[ -n "$_candidate" ]] && log_candidates+=("$_candidate")
	done < <(aidevops_pulse_worker_log_candidates "$repo_slug" "$issue_number" 2>/dev/null || true)

	local elapsed=0
	local poll_seconds=2
	local stability_seconds="${PULSE_LAUNCH_STABILITY_SECONDS:-3}"
	local candidate=""
	local prelaunch_failure_reason=""
	[[ "$stability_seconds" =~ ^[0-9]+$ ]] || stability_seconds=3
	if [[ "$stability_seconds" -lt 1 ]]; then
		stability_seconds=1
	fi
	while [[ "$elapsed" -lt "$grace_seconds" ]]; do
		for candidate in "${log_candidates[@]}"; do
			prelaunch_failure_reason=$(_pulse_worker_log_prelaunch_failure_reason "$candidate")
			if [[ -n "$prelaunch_failure_reason" ]]; then
				recover_failed_launch_state "$issue_number" "$repo_slug" "$prelaunch_failure_reason"
				echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — prelaunch failure reason=${prelaunch_failure_reason} detected in ${candidate}" >>"$LOGFILE"
				_PULSE_LAST_LAUNCH_FAILURE="$prelaunch_failure_reason"
				return 1
			fi
		done
		if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
			for candidate in "${log_candidates[@]}"; do
				if [[ -f "$candidate" ]] && rg -q '^opencode run \[message\.\.\]|^run opencode with a message|^Options:' "$candidate"; then
					recover_failed_launch_state "$issue_number" "$repo_slug" "cli_usage_output"
					echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — CLI usage output detected in ${candidate}" >>"$LOGFILE"
					_PULSE_LAST_LAUNCH_FAILURE="cli_usage_output"
					return 1
				fi
			done
			# Launch confirmed — do NOT reset fast-fail counter here.
			# A successful launch does not mean successful completion.
			# The counter is reset only when the issue is closed or a PR
			# is confirmed. Resetting on launch defeated the counter
			# entirely — workers that launched but died during execution
			# were invisible. (GH#2076, GH#17378)
			sleep "$stability_seconds"
			elapsed=$((elapsed + stability_seconds))
			if has_worker_for_repo_issue "$issue_number" "$repo_slug"; then
				return 0
			fi
			echo "[pulse-wrapper] Launch validation transient for issue #${issue_number} (${repo_slug}) — process disappeared during ${stability_seconds}s stability check" >>"$LOGFILE"
		fi
		sleep "$poll_seconds"
		elapsed=$((elapsed + poll_seconds))
	done
	for candidate in "${log_candidates[@]}"; do
		prelaunch_failure_reason=$(_pulse_worker_log_prelaunch_failure_reason "$candidate")
		if [[ -n "$prelaunch_failure_reason" ]]; then
			recover_failed_launch_state "$issue_number" "$repo_slug" "$prelaunch_failure_reason"
			echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — prelaunch failure reason=${prelaunch_failure_reason} detected in ${candidate}" >>"$LOGFILE"
			_PULSE_LAST_LAUNCH_FAILURE="$prelaunch_failure_reason"
			return 1
		fi
	done

	recover_failed_launch_state "$issue_number" "$repo_slug" "no_worker_process"
	echo "[pulse-wrapper] Launch validation failed for issue #${issue_number} (${repo_slug}) — no active worker process within ${grace_seconds}s" >>"$LOGFILE"
	_PULSE_LAST_LAUNCH_FAILURE="no_worker_process"
	return 1
}

#######################################
# Score one repository's dispatch candidates and append JSONL records to the
# shared candidate file. Extracted so the cross-repository orchestrator stays
# below the function-complexity threshold.
# Arguments: candidates JSON, slug, path, priority, bonus/day, bonus cap,
#            current epoch, destination JSONL file
#######################################
_append_ranked_repo_candidates() {
	local repo_candidates_json="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local repo_priority="$4"
	local age_bonus_per_day="$5"
	local age_bonus_cap="$6"
	local current_epoch="$7"
	local tmp_candidates="$8"

	printf '%s' "$repo_candidates_json" | jq -c --arg slug "$repo_slug" --arg path "$repo_path" --arg priority "$repo_priority" --arg debt_label "${QUALITY_DEBT_LABEL:-quality-debt}" --argjson age_bonus_per_day "$age_bonus_per_day" --argjson age_bonus_cap "$age_bonus_cap" --argjson current_epoch "$current_epoch" '
		.[] |
		(try ((.createdAt // "") | fromdateiso8601) catch $current_epoch) as $created_epoch |
		((($current_epoch - $created_epoch) / 86400) | floor | if . < 0 then 0 else . end) as $age_days |
		($age_days * $age_bonus_per_day) as $uncapped_age_bonus |
		(if $uncapped_age_bonus > $age_bonus_cap then $age_bonus_cap else $uncapped_age_bonus end) as $age_bonus |
		((.labels // []) | map(.name? // .)) as $labels |
		(
			(if $priority == "tooling" then 2000 elif $priority == "product" then 1000 else 0 end) +
			# Mission m-20260504-1e325d feature 3.4: when capacity is
			# constrained, rank worker-ready/low-complexity issues above
			# broad raw backlog so pulse fills slots with solvable work first.
			(if (($labels | index("tier:simple")) != null or ($labels | index("low-complexity")) != null) then 2500
			 elif ($labels | index("tier:standard")) != null then 1200
			 else 0 end) +
			(if (($labels | index("worker-ready")) != null or ($labels | index("status:available")) != null) then 1000 else 0 end) +
			(if (($labels | index("good first issue")) != null or ($labels | index("quick-win")) != null) then 800 else 0 end) +
			(if ($labels | index("auto-dispatch")) != null then 300 else 0 end) -
			(if ($labels | index("tier:thinking")) != null then 1200 else 0 end) -
			(if (($labels | index("research")) != null or ($labels | index("needs-design")) != null) then 800 else 0 end) +
			(if (($labels | index($debt_label)) != null and ($labels | index("security")) != null) then 500 else 0 end) +
			(if ($labels | index("priority:critical")) != null then 10000
			 elif ($labels | index("priority:high")) != null then 9000
			 elif ($labels | index("priority:medium")) != null then 8000
			 elif ($labels | index("bug")) != null then 7000
			 elif ($labels | index("enhancement")) != null then 6000
			 elif ($labels | index($debt_label)) != null then 5000
			 elif (($labels | index("file-size-debt")) != null or ($labels | index("function-complexity-debt")) != null) then 4000
			 elif ($labels | index("priority:low")) != null then 3500
			 else 3000 end)
		) as $base_score |
		. + {
			repo_slug: $slug,
			repo_path: $path,
			repo_priority: $priority,
			base_score: $base_score,
			age_days: $age_days,
			age_bonus: $age_bonus,
			score: ($base_score + $age_bonus)
		}
	' >>"$tmp_candidates" 2>/dev/null || true
	return 0
}

#######################################
# Build ranked deterministic dispatch candidates across all pulse repos.
# Arguments:
#   $1 - max issues to fetch per repo (optional)
#   $2 - dependency normalization mode (optional: normalize or skip)
# Returns: JSON array sorted by score desc, createdAt asc, updatedAt asc
#######################################
build_ranked_dispatch_candidates_json() {
	local per_repo_limit="${1:-$PULSE_RUNNABLE_ISSUE_LIMIT}"
	local dependency_normalization_mode="${2:-normalize}"
	[[ "$per_repo_limit" =~ ^[0-9]+$ ]] || per_repo_limit="$PULSE_RUNNABLE_ISSUE_LIMIT"
	local age_bonus_per_day="${PULSE_DISPATCH_AGE_BONUS_PER_DAY:-25}"
	local age_bonus_cap="${PULSE_DISPATCH_AGE_BONUS_CAP:-900}"
	local current_epoch
	[[ "$age_bonus_per_day" =~ ^[0-9]+$ ]] || age_bonus_per_day=25
	[[ "$age_bonus_cap" =~ ^[0-9]+$ ]] || age_bonus_cap=900
	current_epoch=$(date +%s)
	[[ "$current_epoch" =~ ^[0-9]+$ ]] || current_epoch=0

	if [[ ! -f "$REPOS_JSON" ]]; then
		printf '[]\n'
		return 0
	fi

	local tmp_candidates
	tmp_candidates=$(mktemp 2>/dev/null || echo "/tmp/aidevops-pulse-candidates.$$")
	: >"$tmp_candidates"

	while IFS='|' read -r repo_slug repo_path repo_priority ph_start ph_end expires repo_interval; do
		[[ -n "$repo_slug" && -n "$repo_path" ]] || continue
		if ! check_repo_pulse_schedule "$repo_slug" "$ph_start" "$ph_end" "$expires" "$REPOS_JSON"; then
			continue
		fi
		# Per-repo interval throttle (GH#20660): skip if polled too recently
		if ! check_repo_pulse_interval "$repo_slug" "$repo_interval"; then
			continue
		fi
		# Record that we are polling this repo now (atomic write, non-fatal)
		update_repo_pulse_timestamp "$repo_slug"
		local repo_candidates_json
		repo_candidates_json=$(pulse_campaign_shadow_candidates_json "$repo_slug" "$repo_path" "$per_repo_limit" "$dependency_normalization_mode") || repo_candidates_json='[]'
		if [[ -z "$repo_candidates_json" || "$repo_candidates_json" == "[]" ]]; then
			continue
		fi

		_append_ranked_repo_candidates "$repo_candidates_json" "$repo_slug" "$repo_path" \
			"$repo_priority" "$age_bonus_per_day" "$age_bonus_cap" "$current_epoch" "$tmp_candidates"
	done < <(jq -r '
		def pulse_hour_start:
			if (.pulse_hours | type) == "array" then .pulse_hours[0]
			else .pulse_hours.start
			end;
		def pulse_hour_end:
			if (.pulse_hours | type) == "array" then .pulse_hours[1]
			else .pulse_hours.end
			end;
		.initialized_repos[] |
		select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "" and .path != "") |
		[
			.slug,
			.path,
			(.priority // "tooling"),
			(if .pulse_hours then (pulse_hour_start | tostring) else "" end),
			(if .pulse_hours then (pulse_hour_end | tostring) else "" end),
			(.pulse_expires // ""),
			(.pulse_interval // "")
		] | join("|")
	' "$REPOS_JSON" 2>/dev/null)

	if [[ ! -s "$tmp_candidates" ]]; then
		rm -f "$tmp_candidates"
		printf '[]\n'
		return 0
	fi

	jq -cs 'sort_by([
		-.score,
		(if (.createdAt // "") == "" then "9999-12-31T23:59:59Z" else .createdAt end),
		(if (.updatedAt // "") == "" then "9999-12-31T23:59:59Z" else .updatedAt end),
		(.repo_slug // ""),
		(.number // 0)
	])' "$tmp_candidates" 2>/dev/null || printf '[]\n'
	rm -f "$tmp_candidates"
	return 0
}

#######################################
# Keep trusted review-feedback debt within its fairness share while ordinary
# candidates remain. Excess debt stays at the tail so it can borrow capacity
# only after ordinary candidates have been attempted by the existing gates.
#
# Arguments:
#   $1 - ranked candidate JSON array
#   $2 - available implementation slots
# Returns: reordered JSON array
#######################################
_dispatch_order_idle_borrowing_candidates() {
	local candidates_json="$1"
	local available_slots="$2"
	local debt_cap_pct="${QUALITY_DEBT_CAP_PCT:-30}"

	[[ "$available_slots" =~ ^[0-9]+$ ]] || available_slots=0
	[[ "$debt_cap_pct" =~ ^[0-9]+$ ]] || debt_cap_pct=30
	if [[ "$debt_cap_pct" -gt 100 ]]; then
		debt_cap_pct=100
	fi

	printf '%s' "$candidates_json" | jq -c --argjson cap "$((available_slots * debt_cap_pct / 100))" --arg debt_label "${QUALITY_DEBT_LABEL:-quality-debt}" '
		def trusted_review_debt:
			((.labels // []) | index($debt_label)) != null and
			((.labels // []) | index("source:review-feedback")) != null;
		[.[] | select(trusted_review_debt)] as $debt |
		[.[] | select(trusted_review_debt | not)] as $ordinary |
		($debt[0:$cap] + $ordinary + $debt[$cap:])
	' 2>/dev/null || printf '%s\n' "$candidates_json"
	return 0
}

#######################################
# Dispatch_max for obvious backlog.
#
# This is intentionally narrow: it only materializes already-eligible issues
# and fills empty local slots. Ranking remains simple and auditable; judgment
# stays with the pulse LLM for merges, blockers, and unusual edge cases.
#
# t3005/t3014/GH#29234: Loop body extracted into _dispatch_floor_loop /
# _dispatch_max_loop — the orchestrator picks one based on
# DISPATCH_MAX_PARALLEL (default = min(6, effective_slots) when unset or invalid)
# and adaptive throttle state. Throttle mode forces serial (1 dispatch per round)
# to preserve the existing "test the waters" recovery semantics; otherwise
# bounded parallelism is preferred. Explicit positive overrides can raise the
# ceremony cap up to effective_slots.
#
# Arguments:
#   $1 - dependency normalization mode (optional: normalize or skip)
#
# Returns: dispatched worker count via stdout
#######################################
dispatch_max() {
	local dependency_normalization_mode="${1:-normalize}"
	local capacity_line
	capacity_line=$(_dispatch_compute_capacity) || {
		echo 0
		return 0
	}
	local max_workers active_workers available_slots
	read -r max_workers active_workers available_slots <<<"$capacity_line"
	# _dispatch_compute_capacity owns the pressure-aware floor decision so the
	# launch-throttle path cannot re-enable the floor after provider/load caps.
	[[ "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" =~ ^[0-9]+$ ]] || _DISPATCH_MIN_WORKER_FLOOR_ACTIVE=0
	if [[ "$available_slots" -le 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: no available worker slots (max=${max_workers}, active=${active_workers}, available=${available_slots})" >>"$LOGFILE"
		echo 0
		return 0
	fi

	# GH#29255: ranked candidates are the launch-path backlog source. Do not run
	# the broad all-repository issue+PR diagnostic counters before this snapshot.
	local candidates_json candidate_count
	candidates_json=$(_dispatch_ranked_candidates_json "$PULSE_RUNNABLE_ISSUE_LIMIT" "$dependency_normalization_mode") || candidates_json='[]'
	candidate_count=$(printf '%s' "$candidates_json" | jq 'length' 2>/dev/null) || candidate_count=0
	[[ "$candidate_count" =~ ^[0-9]+$ ]] || candidate_count=0
	if [[ "$candidate_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: no ranked candidates (available=${available_slots})" >>"$LOGFILE"
		echo 0
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$self_login" ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: unable to resolve GitHub login" >>"$LOGFILE"
		echo 0
		return 0
	fi

	echo "[pulse-wrapper] Dispatch_max: available=${available_slots}, candidates=${candidate_count}" >>"$LOGFILE"

	local prepass_line=""
	local triage_attempted=0 triage_infrastructure_failed=0
	if ! prepass_line=$(_dispatch_run_prepasses "$available_slots" 2>>"$LOGFILE"); then
		echo "[pulse-wrapper] Dispatch_max: _dispatch_run_prepasses returned non-zero — assuming 0 triage/enrichment, full slot budget" >>"$LOGFILE"
		prepass_line="${available_slots} 0 1"
	fi
	read -r available_slots triage_attempted triage_infrastructure_failed <<<"$prepass_line"
	[[ "$available_slots" =~ ^[0-9]+$ ]] || available_slots=0
	[[ "$triage_attempted" =~ ^[0-9]+$ ]] || triage_attempted=0
	[[ "$triage_infrastructure_failed" =~ ^[0-9]+$ ]] || triage_infrastructure_failed=0
	pulse_dispatch_debug_log "post-prepasses available_slots=${available_slots} triage_attempted=${triage_attempted} triage_infrastructure_failed=${triage_infrastructure_failed}"
	candidates_json=$(_dispatch_order_idle_borrowing_candidates "$candidates_json" "$available_slots")

	# Reset module-level round state before the dispatch loop (t1959).
	_DISPATCH_ROUND_DISPATCHED=0
	_DISPATCH_ROUND_NO_WORKER_FAILURES=0
	_DISPATCH_CONSECUTIVE_NO_WORKER=0
	_DISPATCH_THROTTLE_FILE="${HOME}/.aidevops/logs/dispatch-throttle"
	_DISPATCH_CANARY_CACHE="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}/canary-last-pass"
	local _dispatch_owns_benign_blocks_cycle=0
	if [[ -z "${_DISPATCH_BENIGN_BLOCKS_FILE:-}" ]]; then
		_dispatch_begin_benign_blocks_cycle >/dev/null
		_dispatch_owns_benign_blocks_cycle=1
	fi
	export _DISPATCH_BENIGN_BLOCKS_FILE

	# t3015: branch on dispatch path (max = parallel, floor = forced-serial).
	# t3418/t3558: if the minimum worker floor is active, runtime launch
	# throttling is a soft signal and must not collapse dispatch below the
	# floor. Explicit dispatch_floor() callers still force the floor path.
	# _dispatch_should_use_floor_path returns 0 when the runtime is degraded
	# (throttle file present) OR when an explicit caller invoked dispatch_floor
	# (which sets _DISPATCH_FORCE_FLOOR=1). The floor path preserves the
	# legacy "test the waters" behaviour as a regression escape hatch.
	local _effective_slots="$available_slots"
	local _dispatch_path="max"
	if [[ -n "${_DISPATCH_FORCE_FLOOR:-}" ]] || { _dispatch_should_use_floor_path && [[ "${_DISPATCH_MIN_WORKER_FLOOR_ACTIVE:-0}" != "1" ]]; }; then
		_effective_slots=1
		_dispatch_path="floor"
		if [[ -f "$_DISPATCH_THROTTLE_FILE" ]]; then
			echo "[pulse-wrapper] Dispatch floor path engaged (throttle file present): limiting implementation batch to 1 (runtime degraded)" >>"$LOGFILE"
		elif [[ -n "${_DISPATCH_FORCE_FLOOR:-}" ]]; then
			echo "[pulse-wrapper] Dispatch floor path engaged (forced via _DISPATCH_FORCE_FLOOR — explicit dispatch_floor() caller)" >>"$LOGFILE"
		fi
	fi

	# t3005/t3014: pick parallelism level (1 = serial, >1 = parallel via wait -n).
	# In floor mode _effective_slots is already 1 → parallelism resolves to 1.
	local _dispatch_max_parallel
	_dispatch_max_parallel=$(_dispatch_max_compute_parallel "$_effective_slots")

	echo "[pulse-wrapper] Dispatch_max: entering candidate loop with effective_slots=${_effective_slots}, max_parallel=${_dispatch_max_parallel}, candidates=${candidate_count}" >>"$LOGFILE"
	local _dispatch_first_candidate_preview
	_dispatch_first_candidate_preview=$(printf '%s' "$candidates_json" | jq -c '.[0]' 2>/dev/null || echo "<jq error>")
	echo "[pulse-wrapper] Dispatch_max: first candidate preview (240 bytes): ${_dispatch_first_candidate_preview:0:240}" >>"$LOGFILE"

	# GH#18804 follow-up: feed candidates from a tempfile rather than process substitution.
	local _dispatch_candidate_file=""
	_dispatch_candidate_file=$(mktemp 2>/dev/null || echo "/tmp/aidevops-dff-candidates.$$")
	if ! printf '%s' "$candidates_json" | jq -c '.[]' >"$_dispatch_candidate_file" 2>>"$LOGFILE"; then
		echo "[pulse-wrapper] Dispatch_max: jq failed to enumerate candidates_json — aborting loop with 0 dispatches" >>"$LOGFILE"
		rm -f "$_dispatch_candidate_file"
		if [[ "$_dispatch_owns_benign_blocks_cycle" == "1" ]]; then
			_dispatch_cleanup_benign_blocks_cycle
		fi
		_dispatch_maybe_engage_throttle
		echo "[pulse-wrapper] Dispatch_max complete: implementation_dispatched=0 triage_attempted=${triage_attempted} triage_infrastructure_failed=${triage_infrastructure_failed} processed=0/${candidate_count} simultaneous_worker_slots_targeted=${available_slots}" >>"$LOGFILE"
		echo 0
		return 0
	fi
	local _dispatch_line_count
	_dispatch_line_count=$(wc -l <"$_dispatch_candidate_file" 2>/dev/null | tr -d ' ' || echo 0)
	echo "[pulse-wrapper] Dispatch_max: candidate enumeration produced ${_dispatch_line_count} lines in ${_dispatch_candidate_file}" >>"$LOGFILE"

	# Branch: floor path (serial; throttle / forced) vs max path (parallel).
	# _dispatch_max_parallel <= 1 implies floor mode (effective_slots was clamped to 1
	# OR DISPATCH_MAX_PARALLEL=1 set explicitly as a regression escape hatch).
	local dispatched_count=0 processed_count=0 loop_output=""
	local _dispatch_outcomes_file=""
	if ((_dispatch_max_parallel <= 1)); then
		loop_output=$(_dispatch_floor_loop "$_dispatch_candidate_file" "$_effective_slots" "$available_slots" "$self_login")
	else
		_dispatch_outcomes_file=$(mktemp 2>/dev/null || echo "/tmp/aidevops-dispatch-outcomes.$$")
		: >"$_dispatch_outcomes_file"
		loop_output=$(_dispatch_max_loop "$_dispatch_candidate_file" "$_effective_slots" "$available_slots" "$self_login" "$_dispatch_max_parallel" "$_dispatch_outcomes_file")
		_dispatch_max_aggregate_outcomes "$_dispatch_outcomes_file"
		rm -f "$_dispatch_outcomes_file"
	fi
	read -r dispatched_count processed_count <<<"$loop_output"
	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	[[ "$processed_count" =~ ^[0-9]+$ ]] || processed_count=0
	rm -f "$_dispatch_candidate_file"
	if [[ "$_dispatch_owns_benign_blocks_cycle" == "1" ]]; then
		_dispatch_cleanup_benign_blocks_cycle
	fi

	echo "[pulse-wrapper] Dispatch path=${_dispatch_path}: loop body finished — processed=${processed_count} dispatched=${dispatched_count} mode=$( ((_dispatch_max_parallel <= 1)) && echo serial || echo "parallel(${_dispatch_max_parallel})")" >>"$LOGFILE"
	_dispatch_maybe_engage_throttle

	echo "[pulse-wrapper] Dispatch path=${_dispatch_path} complete: implementation_dispatched=${dispatched_count} triage_attempted=${triage_attempted} triage_infrastructure_failed=${triage_infrastructure_failed} processed=${processed_count}/${candidate_count} simultaneous_worker_slots_targeted=${available_slots}" >>"$LOGFILE"
	echo "$dispatched_count"
	return 0
}

#######################################
# t3015: Returns 0 (true) if the dispatch loop should take the floor path
# (forced-serial, "test the waters" semantics) rather than the max path
# (parallel saturation). Two triggers:
#   1. Adaptive throttle file present at $_DISPATCH_THROTTLE_FILE — runtime is
#      degraded (recent worker launch failures), so we want serial dispatch
#      to verify the runtime is healthy before saturating again.
#   2. _DISPATCH_FORCE_FLOOR=1 set by an explicit dispatch_floor() caller —
#      lets diagnostic / single-shot callers force the slow-and-careful path
#      without modifying the throttle file.
#
# Returns 1 (false) otherwise — the default max path dispatches in parallel.
#
# Caller contract: $_DISPATCH_THROTTLE_FILE must be set before this function
# is called. dispatch_max() sets it just before checking; dispatch_floor()
# inherits via export.
#######################################
_dispatch_should_use_floor_path() {
	[[ -n "${_DISPATCH_FORCE_FLOOR:-}" ]] && return 0
	[[ -f "${_DISPATCH_THROTTLE_FILE:-${HOME}/.aidevops/logs/dispatch-throttle}" ]] && return 0
	return 1
}

#######################################
# t3015: Public entry point for the forced-serial dispatch path.
#
# Thin wrapper around dispatch_max() that sets _DISPATCH_FORCE_FLOOR=1 so the
# orchestrator delegates to the serial (`floor`) loop regardless of whether the
# adaptive throttle file is present. Use this when an external caller wants
# the slow-and-careful "one at a time, verify it lands" behaviour — e.g. a
# diagnostic harness, a single-issue dispatch test, or a regression escape
# hatch for operators who want to bypass the parallel max loop without
# manually creating a throttle file.
#
# Pre-t3015 the only way to get serial behaviour was DISPATCH_MAX_PARALLEL=1,
# which is a runtime tuning knob, not a public API. dispatch_floor() is the
# named API for "force serial regardless of tuning".
#
# Arguments / return value: forwarded as-is to dispatch_max().
#######################################
dispatch_floor() {
	_DISPATCH_FORCE_FLOOR=1 dispatch_max "$@"
}

_pulse_read_epoch_file() {
	local file_path="$1"
	local epoch="0"
	if [[ -f "$file_path" ]]; then
		epoch=$(cat "$file_path" 2>/dev/null) || epoch="0"
	fi
	[[ "$epoch" =~ ^[0-9]+$ ]] || epoch="0"
	printf '%s\n' "$epoch"
	return 0
}

_pulse_write_trigger_mode() {
	local trigger_mode="$1"
	printf '%s\n' "$trigger_mode" >"${PULSE_DIR}/llm_trigger_mode" 2>/dev/null || return 1
	return 0
}

_pulse_llm_failure_cooldown_active() {
	local now_epoch="$1"
	local last_success_epoch="$2"
	local last_attempt_epoch="$3"
	local retry_interval="${PULSE_LLM_FAILURE_RETRY_INTERVAL:-1800}"
	[[ "$retry_interval" =~ ^[0-9]+$ ]] || retry_interval=1800

	if [[ "$last_attempt_epoch" -gt "$last_success_epoch" ]]; then
		local attempt_age=$((now_epoch - last_attempt_epoch))
		if [[ "$attempt_age" -lt "$retry_interval" ]]; then
			echo "[pulse-wrapper] LLM supervisor: previous attempt failed ${attempt_age}s ago; retry cooldown ${retry_interval}s" >>"$LOGFILE"
			return 0
		fi
	fi
	return 1
}

_should_run_llm_supervisor() {
	local now_epoch
	now_epoch=$(date +%s)

	# 1. Daily sweep: run when the last successful LLM completion is stale.
	# last_llm_run_epoch remains as the legacy success timestamp for older installs;
	# last_llm_attempt_epoch is separate so failed runs do not suppress retries for
	# a full daily interval.
	local last_llm_success_epoch="" last_llm_attempt_epoch=""
	last_llm_success_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_success_epoch")
	if [[ "$last_llm_success_epoch" -eq 0 ]]; then
		last_llm_success_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_run_epoch")
	fi
	last_llm_attempt_epoch=$(_pulse_read_epoch_file "${PULSE_DIR}/last_llm_attempt_epoch")

	local llm_age=$((now_epoch - last_llm_success_epoch))
	if [[ "$llm_age" -ge "$PULSE_LLM_DAILY_INTERVAL" ]]; then
		if _pulse_llm_failure_cooldown_active "$now_epoch" "$last_llm_success_epoch" "$last_llm_attempt_epoch"; then
			return 1
		fi
		echo "[pulse-wrapper] LLM supervisor: daily sweep due (last run ${llm_age}s ago)" >>"$LOGFILE"
		_pulse_write_trigger_mode "daily_sweep" || return 1
		return 0
	fi

	# 2. Backlog stall: check if issue+PR count has changed
	local snapshot_file="${PULSE_DIR}/backlog_snapshot.txt"
	if [[ ! -f "$snapshot_file" ]]; then
		# First run — take snapshot and run LLM
		_update_backlog_snapshot "$now_epoch"
		echo "[pulse-wrapper] LLM supervisor: first run (no snapshot)" >>"$LOGFILE"
		_pulse_write_trigger_mode "first_run" || return 1
		return 0
	fi

	local snap_epoch snap_issues snap_prs
	read -r snap_epoch snap_issues snap_prs <"$snapshot_file" 2>/dev/null || snap_epoch=0
	[[ "$snap_epoch" =~ ^[0-9]+$ ]] || snap_epoch=0
	[[ "$snap_issues" =~ ^[0-9]+$ ]] || snap_issues=0
	[[ "$snap_prs" =~ ^[0-9]+$ ]] || snap_prs=0

	# Get current counts (fast — single API call per repo, cached in prefetch)
	# t1890: exclude persistent/supervisor/contributor issues from stall detection.
	# These management issues never close, so including them inflates the count
	# and makes the backlog appear stalled even when all actionable work is done.
	local current_issues=0 current_prs=0
	while IFS='|' read -r slug _; do
		[[ -n "$slug" ]] || continue
		local ic pc
		ic=$(gh_issue_list --repo "$slug" --state open --json number,labels --limit 500 \
			--jq '[.[] | select(.labels | map(.name) | (index("persistent")) | not)] | length' 2>/dev/null) || ic=0
		pc=$(gh_pr_list --repo "$slug" --state open --json number --jq 'length' --limit 200 2>/dev/null) || pc=0
		[[ "$ic" =~ ^[0-9]+$ ]] || ic=0
		[[ "$pc" =~ ^[0-9]+$ ]] || pc=0
		current_issues=$((current_issues + ic))
		current_prs=$((current_prs + pc))
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	local snap_age=$((now_epoch - snap_epoch))
	local total_before=$((snap_issues + snap_prs))
	local total_now=$((current_issues + current_prs))

	# Backlog is progressing — update snapshot, skip LLM
	if [[ "$total_now" -lt "$total_before" ]]; then
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		return 1
	fi

	# Backlog unchanged — check if stalled long enough
	if [[ "$snap_age" -ge "$PULSE_LLM_STALL_THRESHOLD" ]]; then
		echo "[pulse-wrapper] LLM supervisor: backlog stalled for ${snap_age}s (issues=${current_issues} prs=${current_prs}, unchanged from ${snap_issues}+${snap_prs})" >>"$LOGFILE"
		_update_backlog_snapshot "$now_epoch" "$current_issues" "$current_prs"
		_pulse_write_trigger_mode "stall" || return 1
		return 0
	fi

	# Stalled but not long enough yet
	return 1
}

_update_backlog_snapshot() {
	local epoch="${1:-$(date +%s)}"
	local issues="${2:-0}"
	local prs="${3:-0}"
	printf '%s %s %s\n' "$epoch" "$issues" "$prs" >"${PULSE_DIR}/backlog_snapshot.txt"
	return 0
}

#######################################
# Compute and apply an adaptive launch-settle wait (t1887).
#
# Scales the wait from 0s (0 dispatches) to PULSE_LAUNCH_GRACE_SECONDS
# (PULSE_LAUNCH_SETTLE_BATCH_MAX or more dispatches) using linear
# interpolation. This avoids the static 35s wait when no workers were
# launched, saving ~35s per idle cycle.
#
# Formula: wait = ceil(dispatched / batch_max * grace_max)
# Examples (grace_max=35, batch_max=5):
#   0 dispatches → 0s
#   1 dispatch   → 7s
#   2 dispatches → 14s
#   3 dispatches → 21s
#   4 dispatches → 28s
#   5+ dispatches → 35s
#
# Arguments:
#   $1 - dispatched_count (integer, number of workers just launched)
#   $2 - context label for log (e.g. "dispatch_max", "recycle loop")
#######################################
_adaptive_launch_settle_wait() {
	local dispatched_count="${1:-0}"
	local context_label="${2:-dispatch}"

	[[ "$dispatched_count" =~ ^[0-9]+$ ]] || dispatched_count=0
	if [[ "$dispatched_count" -eq 0 ]]; then
		echo "[pulse-wrapper] Adaptive settle wait (${context_label}): 0 dispatches — skipping wait" >>"$LOGFILE"
		return 0
	fi

	local grace_max="$PULSE_LAUNCH_GRACE_SECONDS"
	local batch_max="$PULSE_LAUNCH_SETTLE_BATCH_MAX"
	[[ "$grace_max" =~ ^[0-9]+$ ]] || grace_max=35
	[[ "$batch_max" =~ ^[0-9]+$ ]] || batch_max=5
	[[ "$batch_max" -lt 1 ]] && batch_max=1

	# Clamp dispatched_count to batch_max ceiling
	local clamped="$dispatched_count"
	if [[ "$clamped" -gt "$batch_max" ]]; then
		clamped="$batch_max"
	fi

	# Linear interpolation: ceil(clamped / batch_max * grace_max)
	# Integer arithmetic: (clamped * grace_max + batch_max - 1) / batch_max
	local wait_seconds=$(((clamped * grace_max + batch_max - 1) / batch_max))
	[[ "$wait_seconds" -gt "$grace_max" ]] && wait_seconds="$grace_max"

	echo "[pulse-wrapper] Adaptive settle wait (${context_label}): ${dispatched_count} dispatch(es) → waiting ${wait_seconds}s (max ${grace_max}s at ${batch_max}+ dispatches)" >>"$LOGFILE"
	sleep "$wait_seconds"
	return 0
}

#######################################
# Return the async post-dispatch housekeeping lock directory path.
#
# Returns 0 always; emits path on stdout.
#######################################
_pulse_post_dispatch_housekeeping_lockdir() {
	printf '%s\n' "${HOME}/.aidevops/logs/pulse-post-dispatch-housekeeping.lock"
	return 0
}

#######################################
# Acquire the post-dispatch housekeeping lock.
#
# Args:
#   $1 - lock directory path
# Returns 0 if acquired, 1 if another live runner owns it.
#######################################
_pulse_acquire_post_dispatch_housekeeping_lock() {
	local lockdir="$1"
	local lock_parent
	lock_parent="$(dirname "$lockdir")"
	mkdir -p "$lock_parent" 2>/dev/null || return 1

	if mkdir "$lockdir" 2>/dev/null; then
		printf '%s\n' "${BASHPID:-$$}" >"${lockdir}/pid" 2>/dev/null || true
		return 0
	fi

	local lock_pid=""
	if [[ -f "${lockdir}/pid" ]]; then
		read -r lock_pid <"${lockdir}/pid" 2>/dev/null || lock_pid=""
	fi
	if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
		echo "[pulse-wrapper] Async post-dispatch housekeeping already running (pid=${lock_pid}) — skipping duplicate" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-wrapper] Async post-dispatch housekeeping: reclaiming stale lock (pid=${lock_pid:-missing})" >>"$LOGFILE"
	rm -rf "$lockdir" 2>/dev/null || true
	if mkdir "$lockdir" 2>/dev/null; then
		printf '%s\n' "${BASHPID:-$$}" >"${lockdir}/pid" 2>/dev/null || true
		return 0
	fi
	return 1
}

#######################################
# Release the post-dispatch housekeeping lock.
#
# Args:
#   $1 - lock directory path
# Returns 0 always.
#######################################
_pulse_release_post_dispatch_housekeeping_lock() {
	local lockdir="$1"
	rm -rf "$lockdir" 2>/dev/null || true
	return 0
}

#######################################
# Run non-dispatch post-dispatch housekeeping stages.
#
# These stages are intentionally after early dispatch and do not protect the
# immediate worker claim/ledger safety boundary. They can therefore run under a
# separate lock while the main pulse proceeds to prefetch + the next refill.
#
# Args:
#   $1 - per-stage timeout seconds
# Returns 0 always.
#######################################
_pulse_run_post_dispatch_housekeeping_stages() {
	local stage_timeout="${1:-${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}}"
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=600

	local lockdir
	lockdir="$(_pulse_post_dispatch_housekeeping_lockdir)"
	if ! _pulse_acquire_post_dispatch_housekeeping_lock "$lockdir"; then
		return 0
	fi

	echo "[pulse-wrapper] Async post-dispatch housekeeping: started (timeout=${stage_timeout}s)" >>"$LOGFILE"
	_pulse_run_optional_stage_with_timeout "coderabbit_review" "$stage_timeout" run_daily_codebase_review || true
	_pulse_run_optional_stage_with_timeout "post_merge_scanner" "$stage_timeout" _run_post_merge_review_scanner || true
	_pulse_run_optional_stage_with_timeout "pr_review_thread_response" "$stage_timeout" _run_pr_review_thread_response_scanner || true
	_pulse_run_optional_stage_with_timeout "auto_decomposer_scanner" "$stage_timeout" _run_auto_decomposer_scanner || true
	_pulse_run_optional_stage_with_timeout "dedup_cleanup" "$stage_timeout" run_simplification_dedup_cleanup || true
	_pulse_run_optional_stage_with_timeout "fast_fail_prune_expired" "$stage_timeout" fast_fail_prune_expired || true
	run_stage_with_timeout "preflight_ownership_reconcile" "$stage_timeout" \
		_preflight_ownership_reconcile || true
	echo "[pulse-wrapper] Async post-dispatch housekeeping: complete" >>"$LOGFILE"

	_pulse_release_post_dispatch_housekeeping_lock "$lockdir"
	return 0
}

#######################################
# Start post-dispatch housekeeping synchronously or asynchronously.
#
# Args:
#   $1 - per-stage timeout seconds
# Returns 0 always.
#######################################
_pulse_start_post_dispatch_housekeeping() {
	local stage_timeout="${1:-${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}}"
	[[ "$stage_timeout" =~ ^[0-9]+$ ]] || stage_timeout=600

	if [[ "${AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING:-1}" != "1" ]]; then
		_pulse_run_post_dispatch_housekeeping_stages "$stage_timeout"
		return 0
	fi

	(
		trap - EXIT INT TERM
		_pulse_run_post_dispatch_housekeeping_stages "$stage_timeout"
	) >>"$LOGFILE" 2>&1 &
	local housekeeping_pid=$!
	echo "[pulse-wrapper] Async post-dispatch housekeeping: launched pid=${housekeeping_pid}" >>"$LOGFILE"
	disown "$housekeeping_pid" 2>/dev/null || true
	return 0
}

#
# Dispatches dispatch_max, then waits adaptively based on
# how many workers were launched so they can appear in process lists
# before the next worker count.
#
# t2749: Two-phase fill floor. Phase 1 is the existing candidate loop.
# Phase 2 fires when _dispatch_issue_consolidation created a new child
# during Phase 1 (detected via a per-cycle sentinel file). The child is
# not in Phase 1's candidate list (enumeration ran before the loop), so
# Phase 2 re-enumerates and dispatches it in the same cycle. Without
# Phase 2, the child waits a minimum of one additional pulse cycle
# (3–7 min stable; 10–20 min when wrapper cycles are unstable).
#
# Arguments:
#   $1 - dependency normalization mode (optional: normalize or skip)
#######################################
apply_dispatch_max() {
	local dependency_normalization_mode="${1:-normalize}"
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Dispatch_max skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	_dispatch_begin_benign_blocks_cycle >/dev/null

	local apply_active_workers apply_max_workers
	apply_active_workers=$(count_active_workers)
	apply_max_workers=$(get_max_workers_target)
	[[ "$apply_active_workers" =~ ^[0-9]+$ ]] || apply_active_workers=0
	[[ "$apply_max_workers" =~ ^[0-9]+$ ]] || apply_max_workers=1

	local fill_dispatched
	fill_dispatched=$(dispatch_max "$dependency_normalization_mode") || fill_dispatched=0
	[[ "$fill_dispatched" =~ ^[0-9]+$ ]] || fill_dispatched=0

	_adaptive_launch_settle_wait "$fill_dispatched" "dispatch_max"
	_dispatch_min_worker_floor_refill "$apply_max_workers" "$((apply_active_workers + fill_dispatched))" "$dependency_normalization_mode"

	# t2749: Phase 2 — re-enumerate when consolidation created a child during
	# Phase 1. The sentinel is written by _dispatch_issue_consolidation in
	# pulse-triage.sh. Named with $$ (top-level PID) so it is cycle-scoped.
	# Consume it before checking worker slots to prevent double Phase 2 when
	# apply_dispatch_max is called again in the same cycle
	# (early dispatch pass + main dispatch both invoke this function).
	local _p2_sentinel="${HOME}/.aidevops/cache/pulse-cycle-$$-consolidation-fired"
	if [[ -f "$_p2_sentinel" && ! -f "$STOP_FLAG" ]]; then
		rm -f "$_p2_sentinel" 2>/dev/null || true
		local _p2_active _p2_max
		_p2_active=$(count_active_workers)
		_p2_max=$(get_max_workers_target)
		[[ "$_p2_active" =~ ^[0-9]+$ ]] || _p2_active=0
		[[ "$_p2_max" =~ ^[0-9]+$ ]] || _p2_max=1
		if [[ "$_p2_active" -lt "$_p2_max" ]]; then
			echo "[pulse-wrapper] Dispatch_max Phase 2: consolidation child created during Phase 1 (active=${_p2_active}, max=${_p2_max}) — re-enumerating candidates (t2749)" >>"$LOGFILE"
			_dispatch_invalidate_candidate_snapshot "consolidation_child_created" || true
			local fill_dispatched_p2
			fill_dispatched_p2=$(dispatch_max "$dependency_normalization_mode") || fill_dispatched_p2=0
			[[ "$fill_dispatched_p2" =~ ^[0-9]+$ ]] || fill_dispatched_p2=0
			_adaptive_launch_settle_wait "$fill_dispatched_p2" "dispatch_max phase 2"
			_dispatch_min_worker_floor_refill "$_p2_max" "$((_p2_active + fill_dispatched_p2))" "$dependency_normalization_mode"
		else
			echo "[pulse-wrapper] Dispatch_max Phase 2: consolidation child created but slots full (active=${_p2_active}, max=${_p2_max}) — skipping (t2749)" >>"$LOGFILE"
		fi
	fi
	_dispatch_cleanup_benign_blocks_cycle
	return 0
}

#######################################
# Re-run dispatch_max while the active-worker count is below the configured
# minimum floor and dispatch is still making progress.
#
# The floor is an active-worker floor, not merely a launch-throttle bypass:
# a partial launch/failure round can leave active workers below the floor even
# though dispatch_max attempted candidates. Hard stops remain hard because each
# dispatch_max call re-checks STOP_FLAG, GraphQL budget, candidate eligibility,
# and per-candidate blockers; a zero-dispatch round ends the refill.
#
# Returns 0 always; best-effort refill should not abort the pulse cycle.
#
# Args:
#   $1 - optional capped max-worker target
#   $2 - optional capped active-worker count
#   $3 - dependency normalization mode (optional: normalize or skip)
#######################################
_dispatch_min_worker_floor_refill() {
	local dependency_normalization_mode="${3:-normalize}"
	local min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
	if ! [[ "$min_worker_floor" =~ ^[0-9]+$ ]]; then
		min_worker_floor=6
	fi
	if ((min_worker_floor <= 0)); then
		return 0
	fi
	local capped_max_workers="${1:-}" capped_active_workers="${2:-}" capped_available_slots
	[[ -n "$capped_max_workers" ]] || capped_max_workers=$(get_max_workers_target)
	[[ -n "$capped_active_workers" ]] || capped_active_workers=$(count_active_workers)
	[[ "$capped_max_workers" =~ ^[0-9]+$ ]] || capped_max_workers=1
	[[ "$capped_active_workers" =~ ^[0-9]+$ ]] || capped_active_workers=0
	local refill_floor_active=0
	if declare -F pulse_apply_provider_load_capacity_cap >/dev/null 2>&1; then
		local capacity_cap_line=""
		capacity_cap_line=$(pulse_apply_provider_load_capacity_cap "$capped_max_workers" "$capped_active_workers" "$min_worker_floor") || capacity_cap_line="${capped_max_workers} 0"
		read -r capped_max_workers refill_floor_active <<<"$capacity_cap_line"
		[[ "$capped_max_workers" =~ ^[0-9]+$ ]] || capped_max_workers=1
		[[ "$refill_floor_active" =~ ^[0-9]+$ ]] || refill_floor_active=0
	elif ((min_worker_floor > 0 && capped_active_workers < min_worker_floor)); then
		refill_floor_active=1
		if ((capped_max_workers < min_worker_floor)); then
			capped_max_workers="$min_worker_floor"
		fi
	fi
	capped_available_slots=$((capped_max_workers - capped_active_workers))
	local guardrail_line=""
	guardrail_line=$(_dispatch_apply_current_state_guardrails "$capped_max_workers" "$capped_active_workers" "$capped_available_slots" "$refill_floor_active") || guardrail_line="${capped_max_workers} ${capped_active_workers} ${capped_available_slots}"
	read -r capped_max_workers capped_active_workers capped_available_slots <<<"$guardrail_line"
	[[ "$capped_max_workers" =~ ^[0-9]+$ ]] || capped_max_workers=1
	[[ "$capped_active_workers" =~ ^[0-9]+$ ]] || capped_active_workers=0
	[[ "$capped_available_slots" =~ ^-?[0-9]+$ ]] || capped_available_slots=0
	if ((capped_available_slots < 0)); then
		capped_available_slots=0
	fi
	if (( refill_floor_active <= 0 || capped_max_workers <= capped_active_workers || capped_available_slots <= 0 )); then
		return 0
	fi

	local refill_attempt=0
	local max_refill_attempts="$min_worker_floor"
	local active_workers="$capped_active_workers" active_workers_known=1 fill_dispatched
	while ((refill_attempt < max_refill_attempts)); do
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Minimum worker floor refill stopped: stop flag present" >>"$LOGFILE"
			return 0
		fi
		if ((active_workers_known <= 0)); then
			active_workers=$(count_active_workers)
			[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
		fi
		if ((active_workers >= min_worker_floor)); then
			return 0
		fi

		refill_attempt=$((refill_attempt + 1))
		echo "[pulse-wrapper] Minimum worker floor refill: active=${active_workers}/${min_worker_floor}, attempt=${refill_attempt}/${max_refill_attempts} — re-enumerating candidates" >>"$LOGFILE"
		fill_dispatched=$(dispatch_max "$dependency_normalization_mode") || fill_dispatched=0
		[[ "$fill_dispatched" =~ ^[0-9]+$ ]] || fill_dispatched=0
		if ((fill_dispatched <= 0)); then
			echo "[pulse-wrapper] Minimum worker floor refill stopped: dispatch_max returned ${fill_dispatched} (no eligible candidates or hard gate exhausted)" >>"$LOGFILE"
			return 0
		fi
		_adaptive_launch_settle_wait "$fill_dispatched" "minimum worker floor refill"
		active_workers_known=0
	done

	echo "[pulse-wrapper] Minimum worker floor refill stopped: reached attempt cap ${max_refill_attempts}" >>"$LOGFILE"
	return 0
}

#######################################
# Return the worker target that should be treated as filled for refill/recycle
# decisions, including the configured minimum active-worker floor.
#
# Args:
#   $1 - raw max-worker target
# Stdout: target >= 1
#######################################
_dispatch_floor_aware_worker_target() {
	local max_workers="$1"
	local min_worker_floor="${AIDEVOPS_MIN_WORKER_CONCURRENCY:-}"
	if [[ -z "$min_worker_floor" ]] && declare -F config_get >/dev/null 2>&1; then
		min_worker_floor=$(config_get "orchestration.min_worker_concurrency" "6")
	fi
	[[ -n "$min_worker_floor" ]] || min_worker_floor=6
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$min_worker_floor" =~ ^[0-9]+$ ]] || min_worker_floor=6
	if ((min_worker_floor > 0 && max_workers < min_worker_floor)); then
		max_workers="$min_worker_floor"
	fi
	((max_workers < 1)) && max_workers=1
	printf '%s\n' "$max_workers"
	return 0
}

#######################################
# Enforce utilization invariants post-pulse (DEPRECATED — t1453)
#
# The LLM pulse session now runs a monitoring loop (sleep 60s, check
# slots, backfill) for up to 60 minutes, making this wrapper-level
# backfill loop redundant. The function is kept as a no-op stub for
# backward compatibility (pulse.md sources this file).
#
# Previously: re-launched run_pulse() in a loop until active workers
# >= MAX_WORKERS or no runnable work remained. Each iteration paid
# the full LLM cold-start penalty (~125s). The monitoring loop inside
# the LLM session eliminates this overhead — each backfill iteration
# costs ~3K tokens instead of a full session restart.
#######################################
enforce_utilization_invariants() {
	echo "[pulse-wrapper] enforce_utilization_invariants is deprecated — LLM session handles continuous slot filling" >>"$LOGFILE"
	return 0
}

#######################################
# Recycle stale workers aggressively when underfill is severe
#
# During deep underfill, long-running workers can occupy slots while making
# no mergeable progress. Run worker-watchdog with stricter thresholds so
# stale workers are recycled before the next pulse dispatch attempt.
#
# Throttle (t1885): when runnable+queued candidates are scarce
# (<= UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD) and underfill is not severe
# (< UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT), skip the watchdog run if it was
# called within UNDERFILL_RECYCLE_THROTTLE_SECS (default 5 min). This avoids
# repeated no-op watchdog scans when there is little work to dispatch.
# Severe underfill (>= 75% deficit) always bypasses the throttle.
#
# Arguments:
#   $1 - max workers
#   $2 - active workers
#   $3 - runnable candidate count
#   $4 - queued_without_worker count
#######################################
run_underfill_worker_recycler() {
	local max_workers="$1"
	local active_workers="$2"
	local runnable_count="$3"
	local queued_without_worker="$4"

	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$runnable_count" =~ ^[0-9]+$ ]] || runnable_count=0
	[[ "$queued_without_worker" =~ ^[0-9]+$ ]] || queued_without_worker=0

	if [[ "$active_workers" -ge "$max_workers" ]]; then
		return 0
	fi

	if [[ "$runnable_count" -eq 0 && "$queued_without_worker" -eq 0 ]]; then
		return 0
	fi

	if [[ ! -x "$WORKER_WATCHDOG_HELPER" ]]; then
		echo "[pulse-wrapper] Underfill recycler skipped: worker-watchdog helper missing or not executable (${WORKER_WATCHDOG_HELPER})" >>"$LOGFILE"
		return 0
	fi

	local deficit_pct
	deficit_pct=$(((max_workers - active_workers) * 100 / max_workers))
	if [[ "$deficit_pct" -lt "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" ]]; then
		return 0
	fi

	# Time-based throttle (t1885): when runnable candidates are scarce and underfill
	# is not severe, avoid hammering worker-watchdog on every pulse cycle. Running
	# watchdog with few candidates produces no kills but still pays the process-scan
	# cost and generates noisy log entries. Bypass throttle for severe underfill
	# (>= UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT) so critical slot recovery is never delayed.
	local recycle_throttle_file="${HOME}/.aidevops/logs/underfill-recycle-last-run"
	local total_candidates=$((runnable_count + queued_without_worker))
	if [[ "$total_candidates" -le "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" &&
		"$deficit_pct" -lt "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" ]]; then
		local now_epoch
		now_epoch=$(date +%s)
		local last_run_epoch=0
		if [[ -f "$recycle_throttle_file" ]]; then
			last_run_epoch=$(cat "$recycle_throttle_file" 2>/dev/null || echo "0")
			[[ "$last_run_epoch" =~ ^[0-9]+$ ]] || last_run_epoch=0
		fi
		local secs_since_last=$((now_epoch - last_run_epoch))
		if [[ "$secs_since_last" -lt "$UNDERFILL_RECYCLE_THROTTLE_SECS" ]]; then
			echo "[pulse-wrapper] Underfill recycler throttled: candidates=${total_candidates} (threshold=${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD}), deficit=${deficit_pct}% (<${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT}% severe), last_run=${secs_since_last}s ago (throttle=${UNDERFILL_RECYCLE_THROTTLE_SECS}s)" >>"$LOGFILE"
			return 0
		fi
	fi

	local thrash_elapsed_threshold
	local thrash_message_threshold
	local progress_timeout
	local max_runtime
	if [[ "$deficit_pct" -ge 50 ]]; then
		thrash_elapsed_threshold=1800
		thrash_message_threshold=90
		progress_timeout=420
		max_runtime=7200
	else
		thrash_elapsed_threshold=3600
		thrash_message_threshold=120
		progress_timeout=480
		max_runtime=9000
	fi

	echo "[pulse-wrapper] Underfill recycler: running worker-watchdog (active ${active_workers}/${max_workers}, deficit ${deficit_pct}%, runnable=${runnable_count}, queued_without_worker=${queued_without_worker})" >>"$LOGFILE"

	if WORKER_WATCHDOG_NOTIFY=false \
		WORKER_THRASH_ELAPSED_THRESHOLD="$thrash_elapsed_threshold" \
		WORKER_THRASH_MESSAGE_THRESHOLD="$thrash_message_threshold" \
		WORKER_PROGRESS_TIMEOUT="$progress_timeout" \
		WORKER_MAX_RUNTIME="$max_runtime" \
		"$WORKER_WATCHDOG_HELPER" --check >>"$LOGFILE" 2>&1; then
		echo "[pulse-wrapper] Underfill recycler complete: worker-watchdog check finished" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Underfill recycler warning: worker-watchdog returned non-zero" >>"$LOGFILE"
	fi

	# Update throttle timestamp after each run (t1885)
	date +%s >"$recycle_throttle_file" 2>/dev/null || true

	return 0
}

#######################################
# Refill an underfilled worker pool while the pulse session is still alive.
#
# The pulse prompt asks the LLM to monitor every 60s, but the live session can
# still sleep or focus on a narrow thread while local slots sit idle. When the
# wrapper sees sustained idle/stall signals plus runnable work, it performs a
# bounded deterministic refill instead of waiting for the session to exit.
#
# Arguments:
#   $1 - last refill epoch (0 if never)
#   $2 - progress stall seconds
#   $3 - idle seconds
#   $4 - has_seen_progress (true/false)
#
# Returns: updated last refill epoch via stdout
#######################################
maybe_refill_underfilled_pool_during_active_pulse() {
	local last_refill_epoch="${1:-0}"
	local progress_stall_seconds="${2:-0}"
	local idle_seconds="${3:-0}"
	local has_seen_progress="${4:-false}"

	[[ "$last_refill_epoch" =~ ^[0-9]+$ ]] || last_refill_epoch=0
	[[ "$progress_stall_seconds" =~ ^[0-9]+$ ]] || progress_stall_seconds=0
	[[ "$idle_seconds" =~ ^[0-9]+$ ]] || idle_seconds=0
	[[ "$PULSE_ACTIVE_REFILL_INTERVAL" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_INTERVAL=120
	[[ "$PULSE_ACTIVE_REFILL_IDLE_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_IDLE_MIN=60
	[[ "$PULSE_ACTIVE_REFILL_STALL_MIN" =~ ^[0-9]+$ ]] || PULSE_ACTIVE_REFILL_STALL_MIN=120

	if [[ -f "$STOP_FLAG" || "$has_seen_progress" != "true" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	if [[ "$idle_seconds" -lt "$PULSE_ACTIVE_REFILL_IDLE_MIN" && "$progress_stall_seconds" -lt "$PULSE_ACTIVE_REFILL_STALL_MIN" ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	local now_epoch
	now_epoch=$(date +%s)
	if [[ "$last_refill_epoch" -gt 0 ]]; then
		local since_last_refill=$((now_epoch - last_refill_epoch))
		if [[ "$since_last_refill" -lt "$PULSE_ACTIVE_REFILL_INTERVAL" ]]; then
			echo "$last_refill_epoch"
			return 0
		fi
	fi

	local max_workers active_workers refill_target runnable_count queued_without_worker
	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	refill_target=$(_dispatch_floor_aware_worker_target "$max_workers")
	[[ "$refill_target" =~ ^[0-9]+$ ]] || refill_target="$max_workers"

	if [[ "$active_workers" -ge "$refill_target" || ("$runnable_count" -eq 0 && "$queued_without_worker" -eq 0) ]]; then
		echo "$last_refill_epoch"
		return 0
	fi

	echo "[pulse-wrapper] Active pulse refill: underfilled ${active_workers}/${refill_target} (raw_max=${max_workers}) with runnable=${runnable_count}, queued_without_worker=${queued_without_worker}, idle=${idle_seconds}s, stall=${progress_stall_seconds}s" >>"$LOGFILE"
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"
	local active_refill_dispatched
	active_refill_dispatched=$(dispatch_max) || active_refill_dispatched=0
	[[ "$active_refill_dispatched" =~ ^[0-9]+$ ]] || active_refill_dispatched=0
	_dispatch_min_worker_floor_refill "$max_workers" "$((active_workers + active_refill_dispatched))"

	echo "$now_epoch"
	return 0
}

#######################################
# Main
#
# Execution order (t1429, GH#4513, GH#5628):
#   0. Instance lock (mkdir-based atomic — prevents concurrent pulses on macOS+Linux)
#   1. Gate checks (consent, dedup)
#   2. Cleanup (orphans, worktrees, stashes)
#   2.5. Daily complexity scan — .sh functions + .md agent docs (creates function-complexity-debt issues)
#   3. Prefetch state (parallel gh API calls)
#   4. Run pulse (LLM session — dispatch workers, merge PRs)
#
# Statistics (quality sweep, health issues, person-stats) run in a
# SEPARATE process — stats-wrapper.sh — on its own cron schedule.
# They must never share a process with the pulse because they depend
# on GitHub Search API (30 req/min limit). When budget is exhausted,
# contributor-activity-helper.sh bails out with partial results, but
# even the API calls themselves add latency that delays dispatch.
#######################################

#######################################
# Run pre-flight stages: cleanup, calculations, normalization (GH#5627)
#
# Returns: 0 if prefetch succeeded, 1 if prefetch failed (abort cycle)
#######################################
_run_preflight_stages() {
	# t1425, t1482: Write SETUP sentinel during pre-flight stages.
	echo "SETUP:$$" >"$PIDFILE"

	# GH#20025 Phase B + t2443: Each preflight stage wrapped in
	# run_stage_with_timeout so overruns are killed without blocking
	# the entire pulse cycle. Daily scans (complexity, coderabbit,
	# post-merge, auto-decomposer, dedup, fast-fail prune) were
	# previously grouped in _preflight_daily_scans() with a shared
	# budget — t2443 promoted them to independent top-level stages
	# so one slow scanner cannot starve downstream scanners.
	local _pflt_timeout="${PREFLIGHT_GROUP_TIMEOUT:-${PRE_RUN_STAGE_TIMEOUT:-600}}"

	# GH#27853: start the existing lock-safe merge routine before any new
	# dispatch. It runs asynchronously while cleanup/capacity stages proceed;
	# dispatch never waits for merge, CI, review, or GitHub latency.
	_preflight_start_merge_first || true
	run_stage_with_timeout "preflight_cleanup_and_ledger" "$_pflt_timeout" \
		_preflight_cleanup_and_ledger || true
	run_stage_with_timeout "preflight_capacity" "$_pflt_timeout" \
		_preflight_capacity || true
	# t3054: dispatch passes do NOT use run_stage_with_timeout. Unlike other
	# preflight stages (single-step operations), each wraps apply_dispatch_max,
	# which iterates N candidates that are each
	# independently protected by run_stage_with_timeout "dispatch_candidate_*"
	# (600s per candidate). A 600s GROUP timeout killed in-progress candidates
	# that were still within their individual budgets (92 timeouts in 1079 runs =
	# 8.5% failure rate). The group timeout is redundant — per-candidate timeouts
	# provide the safety net. Timing is still logged for observability.
	local _pflt_ed_start=$SECONDS
	local _pflt_ed_rc=0
	_preflight_early_dispatch || _pflt_ed_rc=$?
	_log_substage_timing "preflight_early_dispatch" "$_pflt_ed_start" "$_pflt_ed_rc"
	# GH#28880: cross-repository label maintenance can take 3-5 minutes. Run it
	# after the initial fill so already-eligible workers boot in parallel. Then
	# normalize trusted-author NMR residue and refill once so every newly unblocked
	# candidate remains dispatchable this cycle.
	run_stage_with_timeout "preflight_label_maintenance" "$_pflt_timeout" \
		_preflight_label_maintenance || true
	_preflight_trusted_nmr_reconcile || true
	local _pflt_refill_start=$SECONDS
	local _pflt_refill_rc=0
	_preflight_post_label_refill || _pflt_refill_rc=$?
	_log_substage_timing "preflight_post_label_refill" "$_pflt_refill_start" "$_pflt_refill_rc"
	# t3055: Post-dispatch housekeeping runs under a separate async lock by
	# default. These stages do not protect the immediate worker claim/ledger
	# safety boundary, so blocking the dispatch lock on them lets a 24-worker
	# wave drain before the next refill can start. Set
	# AIDEVOPS_PULSE_ASYNC_POST_DISPATCH_HOUSEKEEPING=0 to restore the legacy
	# synchronous path for debugging.
	_pulse_start_post_dispatch_housekeeping "$_pflt_timeout"
	# t3027 (GH#21584): GraphQL budget gate.
	# prefetch_state is the largest single GraphQL consumer in the pulse
	# cycle (~170s avg, 3 calls per repo × 13 repos). When budget is
	# critically low (< AIDEVOPS_PULSE_PREFETCH_BUDGET_THRESHOLD points,
	# default 1250 = 25% of the 5000/hr GraphQL floor), defer prefetch
	# entirely and let the cycle proceed with stale STATE_FILE rather
	# than burn the remaining budget on what may be an idle cycle anyway.
	# Complementary to the t2690 dispatch breaker (5% floor): t2690 stops
	# new dispatches; this gate stops the prefetch that PRECEDES dispatch.
	# Bypass: AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE=1.
	# Counter incremented: _PULSE_HEALTH_PREFETCH_THROTTLED.
	local _budget_gate_skip=0
	if [[ "${AIDEVOPS_SKIP_PULSE_PREFETCH_BUDGET_GATE:-0}" != "1" ]]; then
		local _bg_threshold="${AIDEVOPS_PULSE_PREFETCH_BUDGET_THRESHOLD:-1250}"
		local _bg_remaining
		_bg_remaining=$(gh api rate_limit --jq '.resources.graphql.remaining' 2>/dev/null || echo "5000")
		[[ "$_bg_remaining" =~ ^[0-9]+$ ]] || _bg_remaining=5000
		if [[ "$_bg_remaining" -lt "$_bg_threshold" ]]; then
			echo "[pulse-wrapper] prefetch_budget_gate: GraphQL remaining=${_bg_remaining} < threshold=${_bg_threshold} — deferring prefetch_state, using stale STATE_FILE (t3027)" >>"$LOGFILE"
			_PULSE_HEALTH_PREFETCH_THROTTLED=$((_PULSE_HEALTH_PREFETCH_THROTTLED + 1))
			if declare -F pulse_stats_increment >/dev/null 2>&1; then
				pulse_stats_increment "pulse_prefetch_budget_throttled" 2>/dev/null || true
			fi
			_budget_gate_skip=1
		fi
	fi

	# prefetch_and_scope is the only preflight stage whose failure aborts
	# the cycle — preserve the non-zero return so main() skips run_pulse().
	# When the budget gate fires we skip the call but return 0; the cycle
	# proceeds with whatever STATE_FILE was written by the previous cycle.
	# If STATE_FILE is missing entirely (cold start + budget gate firing on
	# first cycle), downstream stages handle it gracefully (LLM session
	# sees empty state, deterministic merges/cleanup degrade quietly).
	if [[ "$_budget_gate_skip" -eq 0 ]]; then
		if ! run_stage_with_timeout "preflight_prefetch_and_scope" "$_pflt_timeout" \
			_preflight_prefetch_and_scope; then
			return 1
		fi
	fi
	return 0
}

#######################################
# Compute initial underfill state and run recycler (GH#5627)
#
# Outputs 2 lines: underfilled_mode, underfill_pct
#######################################
_compute_initial_underfill() {
	local max_workers active_workers underfilled_mode underfill_pct

	max_workers=$(get_max_workers_target)
	active_workers=$(count_active_workers)
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	underfilled_mode=0
	underfill_pct=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	fi

	local runnable_count queued_without_worker
	runnable_count=$(normalize_count_output "$(count_runnable_candidates)")
	queued_without_worker=$(normalize_count_output "$(count_queued_without_worker)")
	run_underfill_worker_recycler "$max_workers" "$active_workers" "$runnable_count" "$queued_without_worker"

	# Re-check after recycler
	active_workers=$(count_active_workers)
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	if [[ "$active_workers" -lt "$max_workers" ]]; then
		underfilled_mode=1
		underfill_pct=$(((max_workers - active_workers) * 100 / max_workers))
	else
		underfilled_mode=0
		underfill_pct=0
	fi

	printf '%s\n%s\n' "$underfilled_mode" "$underfill_pct" 2>/dev/null || return 0
	return 0
}

#######################################
# Early-exit recycle loop (GH#5627, extracted from main)
#
# If the LLM exited quickly (<5 min) and the pool is still underfilled
# with runnable work, restart the pulse. Capped at PULSE_BACKFILL_MAX_ATTEMPTS.
#
# GH#6453: A grace-period wait is inserted before re-counting workers.
# Workers dispatched by the LLM pulse take several seconds to appear in
# list_active_worker_processes (sandbox-exec + opencode startup latency).
# Without this wait, count_active_workers() returns the pre-dispatch count,
# making the pool appear underfilled and triggering a second LLM pass that
# re-dispatches the same issues — doubling compute cost and causing branch
# conflicts. The wait duration is PULSE_LAUNCH_GRACE_SECONDS (default 20s).
#
# Arguments:
#   $1 - initial pulse_duration in seconds
#######################################
_run_early_exit_recycle_loop() {
	local pulse_duration="$1"
	local recycle_attempt=0
	while [[ "$recycle_attempt" -lt "$PULSE_BACKFILL_MAX_ATTEMPTS" ]]; do
		# Only recycle if the pulse ran for less than 5 minutes
		if [[ "$pulse_duration" -ge 300 ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Stop flag set — skipping early-exit recycle" >>"$LOGFILE"
			break
		fi
		# GH#6453: Wait for newly-dispatched workers to appear in the process list
		# before re-counting. Workers dispatched by the LLM pulse take up to
		# PULSE_LAUNCH_GRACE_SECONDS to start (sandbox-exec + opencode startup).
		# Counting immediately after the LLM exits produces a false-negative
		# (workers running but not yet visible) that triggers duplicate dispatch.
		# t1887: LLM dispatch count is unknown here — use full grace to preserve
		# the GH#6453 safety guarantee.
		local grace_wait="$PULSE_LAUNCH_GRACE_SECONDS"
		[[ "$grace_wait" =~ ^[0-9]+$ ]] || grace_wait=35
		if [[ "$grace_wait" -gt 0 ]]; then
			echo "[pulse-wrapper] Early-exit recycle: waiting ${grace_wait}s for dispatched workers to appear (GH#6453)" >>"$LOGFILE"
			sleep "$grace_wait"
		fi

		# Re-check worker state
		local post_max post_active post_target post_runnable post_queued
		post_max=$(get_max_workers_target)
		post_active=$(count_active_workers)
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_max" =~ ^[0-9]+$ ]] || post_max=1
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		post_target=$(_dispatch_floor_aware_worker_target "$post_max")
		[[ "$post_target" =~ ^[0-9]+$ ]] || post_target="$post_max"

		if [[ "$post_active" -ge "$post_target" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi
		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Early-exit recycle: stop flag appeared before deterministic fill" >>"$LOGFILE"
			break
		fi

		local early_dispatched
		early_dispatched=$(dispatch_max) || early_dispatched=0
		[[ "$early_dispatched" =~ ^[0-9]+$ ]] || early_dispatched=0
		_dispatch_min_worker_floor_refill "$post_max" "$((post_active + early_dispatched))"
		post_active=$((post_active + early_dispatched))
		post_runnable=$(normalize_count_output "$(count_runnable_candidates)")
		post_queued=$(normalize_count_output "$(count_queued_without_worker)")
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		post_target=$(_dispatch_floor_aware_worker_target "$post_max")
		[[ "$post_target" =~ ^[0-9]+$ ]] || post_target="$post_max"
		if [[ "$post_active" -ge "$post_target" ]]; then
			break
		fi
		if [[ "$post_runnable" -eq 0 && "$post_queued" -eq 0 ]]; then
			break
		fi

		local post_deficit_pct=$(((post_target - post_active) * 100 / post_target))
		recycle_attempt=$((recycle_attempt + 1))
		echo "[pulse-wrapper] Early-exit recycle attempt ${recycle_attempt}/${PULSE_BACKFILL_MAX_ATTEMPTS}: pulse ran ${pulse_duration}s (<300s), pool underfilled (active ${post_active}/${post_target}, raw_max=${post_max}, deficit ${post_deficit_pct}%, runnable=${post_runnable}, queued=${post_queued})" >>"$LOGFILE"

		run_underfill_worker_recycler "$post_max" "$post_active" "$post_runnable" "$post_queued"

		if ! run_stage_with_timeout "prefetch_state" "$PRE_RUN_STAGE_TIMEOUT" prefetch_state; then
			echo "[pulse-wrapper] Early-exit recycle: prefetch_state failed — aborting recycle" >>"$LOGFILE"
			break
		fi

		# Recalculate underfill for the new pulse
		post_active=$(count_active_workers)
		[[ "$post_active" =~ ^[0-9]+$ ]] || post_active=0
		local recycle_underfilled_mode=0
		local recycle_underfill_pct=0
		if [[ "$post_active" -lt "$post_max" ]]; then
			recycle_underfilled_mode=1
			recycle_underfill_pct=$(((post_max - post_active) * 100 / post_max))
		fi

		local recycle_start_epoch
		recycle_start_epoch=$(date +%s)
		run_pulse "$recycle_underfilled_mode" "$recycle_underfill_pct"

		local recycle_end_epoch
		recycle_end_epoch=$(date +%s)
		pulse_duration=$((recycle_end_epoch - recycle_start_epoch))
	done

	if [[ "$recycle_attempt" -gt 0 ]]; then
		echo "[pulse-wrapper] Early-exit recycle completed after ${recycle_attempt} attempt(s)" >>"$LOGFILE"
	fi

	return 0
}
