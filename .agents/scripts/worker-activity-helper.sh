#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-activity-helper.sh — Canonical worker activity summary (t3215, GH#21949)
#
# One command that answers "are workers actually running and producing PRs?"
# by reading the canonical sources in precedence order:
#
#   1. ~/.aidevops/logs/headless-runtime-metrics.jsonl
#      Authoritative per-worker outcome record (success / watchdog_stall_killed /
#      watchdog_stall_continue / rate_limit / other failure).
#   2. ~/.aidevops/logs/pulse-stats.json
#      Pulse-level dispatch counters (each value is an array of unix-second
#      timestamps; query with `jq '.counters[<name>] // []'`).
#   3. Optional GitHub delivery-stage queries for worker PRs and solved issues.
#      External truth: did a runtime handoff become an opened PR, merged PR,
#      and closed solved task? Disabled by default because GitHub search uses
#      the GraphQL search path.
#
# Replaces the misdiagnosis-prone habit of reading worker-NNN.log mtimes,
# which was the exact mistake that triggered this task. mtime tells you when
# the file was touched, not whether work succeeded; canonical sources tell you
# the outcome.
#
# Usage:
#   worker-activity-helper.sh summary [--since 1h|6h|24h|48h|7d]
#                                     [--json]
#                                     [--pr-check|--no-pr-check]
#                                     [--repo OWNER/REPO]
#   worker-activity-helper.sh providers [--since 1h|6h|24h|48h|7d]
#                                      [--json]
#   worker-activity-helper.sh live-workers
#   worker-activity-helper.sh help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared-constants for color helpers, _file_mtime_epoch (stat portability),
# safe_grep_count (counter safety), and the bash-3.2 re-exec self-heal.
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Path overrides (testing).
WAH_METRICS_FILE="${WAH_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
WAH_PULSE_STATS_FILE="${WAH_PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
WAH_PR_CACHE_FILE="${WAH_PR_CACHE_FILE:-${HOME}/.aidevops/cache/worker-activity-prs.json}"
WAH_OAUTH_POOL_FILE="${WAH_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
WAH_BLOCKER_LOG_FILE="${WAH_BLOCKER_LOG_FILE:-${HOME}/.aidevops/logs/worker-progress-blockers.jsonl}"
WAH_DISPATCH_LEDGER_FILE="${WAH_DISPATCH_LEDGER_FILE:-${HOME}/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl}"
WAH_BLOCKER_OWNER_PROCESS_PATTERN="${WAH_BLOCKER_OWNER_PROCESS_PATTERN:-$FRAMEWORK_PROCESS_PATTERN}"
WAH_OBJECTIVE_EVIDENCE_FILE="${WAH_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
WAH_PR_CACHE_TTL="${WAH_PR_CACHE_TTL:-60}" # seconds
WAH_SERVICE_INTERRUPTION_RESULT="service_interruption_continue"
WAH_RESULT_WATCHDOG_STALL_KILLED="watchdog_stall_killed"
WAH_RESULT_LOCAL_KILL="local_kill"
WAH_RESULT_RATE_LIMIT="rate_limit"
WAH_DELIVERY_FAILED="failed"
WAH_JSON_NULL="null"
WAH_RUNTIME_ROLE="worker"
WAH_FAILURE_FAMILY_FILTER="${SCRIPT_DIR}/worker-activity-failure-families.jq"

# Shared jq definitions keep terminal-session semantics identical in the scalar
# and rich aggregators without duplicating a long filter in both functions.
# shellcheck disable=SC2016 # jq variables are evaluated by jq, not the shell
WAH_SESSION_OUTCOME_JQ='
	def _wah_nonterminal:
		((.result // "") | endswith("_continue")) or (.result == "brief_recovery");
	def _wah_known_effective_outcome:
		. == "success" or . == $outcome_failed or . == "deferred" or . == "escalated";
	def _wah_nonempty_string:
		type == "string" and length > 0;
	def _wah_reconcile_outcome:
		. as $row
		| ([$objective_outcomes[] | select(
			(.attempt_id | _wah_nonempty_string) and .attempt_id == ($row.attempt_id // null) and
			((($row.repo_slug // null) | _wah_nonempty_string | not) or (.repo // null) == $row.repo_slug) and
			(($row.issue_number // null) == null or ((.issue_number // 0) | tostring) == (($row.issue_number // "") | tostring))
		)] | sort_by(.evidence_timestamp // 0) | last // null) as $outcome
		| ($outcome.effective_outcome // "") as $effective
		| if $outcome == null or (($effective | _wah_known_effective_outcome) | not) then . else
			. + {raw_result:(.result // "unknown"), effective_outcome:$effective, outcome_source:"attempt_outcome"}
			| if .effective_outcome == "success" then .result = "success" | .exit_code = 0 else . end
		end;
	def _wah_effective_failure:
		(.effective_outcome // "") as $effective
		| if ($effective | _wah_known_effective_outcome) then $effective == $outcome_failed
		else ((.result // "") != "success" or (.exit_code // 1) != 0) end;
	def _wah_session_outcomes:
		map(_wah_reconcile_outcome) as $all
		| $all
		| to_entries
		| map(. as $entry | select(
			(($entry.value.repo_slug // "") | length) > 0
			or (($entry.value.issue_number // null) != null)
			or (($entry.value.session_id // "") | length) > 0
			or (($entry.value.work_dir // "") | length) > 0
			or (($entry.value.output_file // "") | length) > 0
			or (($entry.value.launch_failure_cause // "") | length) > 0
			or (($entry.value.kill_reason // "") | length) > 0
			or (($entry.value.next_action // "") | length) > 0
			or ([$all[] | select(
				((.repo_slug // "") | length) > 0
				and .session_key == $entry.value.session_key
				and ([((.ts // 0) - ($entry.value.ts // 0)), (($entry.value.ts // 0) - (.ts // 0))] | max) <= 2
				and .result == $entry.value.result
				and .exit_code == $entry.value.exit_code
			)] | length) == 0
		))
		| group_by(
			(if ((.value.repo_slug // "") | length) > 0 then .value.repo_slug else "legacy" end)
			+ "|" + (if ((.value.session_key // "") | length) > 0 then .value.session_key else "__event_\(.key)" end)
		)
		| map(sort_by([(.value.ts // 0), (if (.value.issue_number // null) != null then 1 else 0 end), .key]) | last.value)
		| map(select(_wah_nonterminal | not));
'

# Keep failure-family classification outside the shell function body so the
# rich metric aggregator stays below the function-complexity gate.
WAH_FAILURE_FAMILY_JQ=""
if [[ -f "$WAH_FAILURE_FAMILY_FILTER" ]]; then
	WAH_FAILURE_FAMILY_JQ=$(<"$WAH_FAILURE_FAMILY_FILTER")
fi

# Keep the rich details projection outside the shell function body so adding
# output fields does not turn jq data-shaping into shell function complexity.
# shellcheck disable=SC2016 # jq variables are evaluated by jq, not the shell
WAH_METRIC_DETAILS_JQ=$WAH_SESSION_OUTCOME_JQ$WAH_FAILURE_FAMILY_JQ'
	[inputs | select(
		.role == $worker_role
		and (.ts // 0) >= $cutoff
		and (.ts // 0) <= $now
	)] as $window_events
	| ($window_events | map(select(
		$repo_slug == "" or (((.repo_slug // "") | ascii_downcase) == ($repo_slug | ascii_downcase))
	))) as $events
	| ($events | _wah_session_outcomes) as $w
	| ($w | map(.duration_ms // 0)) as $durations
	| ($w | map(select(_wah_effective_failure))) as $failures
	| {
		event_total: ($events | length),
		unscoped_event_total: (if $repo_slug == "" then 0 else ([$window_events[] | select((.repo_slug // "") == "")] | length) end),
		excluded_event_total: (($window_events | length) - ($events | length)),
		continuation_events: ($events | map(select(_wah_nonterminal)) | length),
		result_counts: (reduce $w[] as $row ({}; .[$row.result // "unknown"] += 1)),
		event_result_counts: (reduce $events[] as $row ({}; .[$row.result // "unknown"] += 1)),
		diagnostic_focus: {
			premature_exit: ($failures | map(select(.result == "premature_exit" or .launch_failure_cause == "model_stopped_before_completion")) | length),
			local_runtime_error: ($failures | map(select(.result != $local_kill_result and .launch_failure_cause != $local_kill_result and (.failure_reason == "local_error" or .launch_failure_cause == "local_runtime_error" or (.runtime_error_type // "") != ""))) | length),
			local_kill: ($failures | map(select(.result == $local_kill_result or .launch_failure_cause == $local_kill_result or (.kill_reason != null and .kill_reason != "unknown" and .kill_reason != "natural"))) | length),
			stall_hard_killed: ($failures | map(select(.result == $watchdog_killed_result or .launch_failure_cause == "stall_hard_killed" or .kill_reason == "hard_kill_stall")) | length)
		},
		timing_ms: {
			samples: ($durations | length),
			avg: (if ($durations | length) > 0 then (($durations | add) / ($durations | length) | floor) else 0 end),
			max: (if ($durations | length) > 0 then ($durations | max) else 0 end)
		},
		recent_examples: ($w | sort_by(.ts // 0) | reverse | .[0:5] | map({
			ts, session_key, session_id, issue_number, repo_slug, model, provider,
			result, exit_code, failure_reason, provider_error_type, provider_status,
			runtime_error_type, classification_source, classification_pattern,
			launch_failure_cause, kill_reason, next_action, attempt_id, run_id,
			raw_result, effective_outcome, outcome_source, duration_ms, work_dir,
			output_file, load_1min, load_per_cpu
		})),
		failure_groups: (
			$failures
			| group_by([.result // "unknown", .failure_reason // "", .provider_error_type // "", .provider_status // "", (.runtime_error_type | _wah_empty_if_null), .classification_source // "", .classification_pattern // "", .launch_failure_cause // "", .kill_reason // "", .next_action // "", .provider // "", .model // "", .session_key // "", (.issue_number // "" | tostring), .repo_slug // ""])
			| map({
				result: (.[0].result // "unknown"), failure_reason: (.[0].failure_reason // ""),
				provider_error_type: (.[0].provider_error_type // ""), provider_status: (.[0].provider_status // ""),
				runtime_error_type: (.[0].runtime_error_type | _wah_empty_if_null), classification_source: (.[0].classification_source // ""),
				classification_pattern: (.[0].classification_pattern // ""), launch_failure_cause: (.[0].launch_failure_cause // ""),
				kill_reason: (.[0].kill_reason // ""), next_action: (.[0].next_action // ""), provider: (.[0].provider // ""),
				model: (.[0].model // ""), session_key: (.[0].session_key // ""), issue_number: (.[0].issue_number // null),
				repo_slug: (.[0].repo_slug // ""), count: length,
				examples: (sort_by(.ts // 0) | reverse | .[0:3] | map({ts, session_id, work_dir, output_file, exit_code, duration_ms, provider_error_type, provider_status, runtime_error_type, classification_source, classification_pattern, launch_failure_cause, kill_reason, next_action}))
			})
			| sort_by(.count) | reverse | .[0:10]),
		failure_families: ($failures | _wah_failure_family_summary)
	}'

#######################################
# Convert short window spec to seconds. Caller owns the cutoff math.
# $1 — one of 1h | 6h | 24h | 48h | 7d
# stdout — integer seconds, or empty + return 1 on bad input.
#######################################
_wah_parse_since() {
	local spec="$1"
	case "$spec" in
	1h) printf '3600\n' ;;
	6h) printf '21600\n' ;;
	24h) printf '86400\n' ;;
	48h) printf '172800\n' ;;
	7d) printf '604800\n' ;;
	*) return 1 ;;
	esac
	return 0
}

_wah_objective_outcomes_json() {
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	if [[ ! -s "$WAH_OBJECTIVE_EVIDENCE_FILE" ]]; then
		printf '[]'
		return 0
	fi
	tail -n "$evidence_limit" "$WAH_OBJECTIVE_EVIDENCE_FILE" 2>/dev/null |
		jq -sc '[.[] | select(.record_type == "attempt_outcome")]' 2>/dev/null || printf '[]'
	return 0
}

#######################################
# Aggregate worker outcomes from headless-runtime-metrics.jsonl.
# Single jq streaming pass: filter by ts cutoff, bucket by result + exit_code.
# Bucketing lives entirely in jq (not awk) so we don't need positional
# field references in shell. `inputs` avoids reading unrelated old entries into
# memory before filtering the append-only jsonl.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# $2 — optional now_epoch (entries with ts > now are dropped).
# $3 — optional repository slug; excludes unscoped and other-repo events.
# stdout — eight space-separated integers:
#   raw_total terminal_total succeeded watchdog_killed watchdog_continued service_interrupted rate_limited other_failure
#######################################
_wah_aggregate_metrics() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local repo_slug="${3:-}"
	local now_epoch

	if [[ ! -f "$metrics" ]]; then
		printf '0 0 0 0 0 0 0 0\n'
		return 0
	fi
	now_epoch="${2:-$(date +%s)}"

	# Bucket semantics (must match the original awk fallthrough chain):
	#   succ — result=="success" AND exit_code==0 (runtime handoff, not delivery)
	#   wk   — result=="watchdog_stall_killed"   (terminal)
	#   wc   — result=="watchdog_stall_continue" (heartbeat, NOT terminal)
	#   sic  — result=="service_interruption_continue" (heartbeat, NOT terminal)
	#   rl   — result=="rate_limit"
	#   of   — everything else (catches "premature_exit" and any new
	#          failure result-name not yet enumerated; explicitly excludes
	#          watchdog_stall_continue and service_interruption_continue
	#          heartbeats even when their exit_code
	#          is nonzero)
	# Fail-open to zeros if jq fails (stale/corrupt jsonl).
	local result service_result watchdog_killed_result rate_limit_result objective_outcomes
	service_result="$WAH_SERVICE_INTERRUPTION_RESULT"
	watchdog_killed_result="$WAH_RESULT_WATCHDOG_STALL_KILLED"
	rate_limit_result="$WAH_RESULT_RATE_LIMIT"
	objective_outcomes=$(_wah_objective_outcomes_json)
	local jq_program
	# shellcheck disable=SC2016 # jq variables are evaluated by jq, not the shell
	jq_program=$WAH_SESSION_OUTCOME_JQ'
		[inputs | select(
			.role == $worker_role
			and (.ts // 0) >= $cutoff
			and (.ts // 0) <= $now
			and ($repo_slug == "" or (((.repo_slug // "") | ascii_downcase) == ($repo_slug | ascii_downcase)))
		)] as $events
		| ($events | _wah_session_outcomes) as $w | {
			total:  ($events | length),
			terminal: ($w | length),
			succ:   ([$w[] | select(.result == "success" and .exit_code == 0)] | length),
			wk:     ([$w[] | select(.result == $watchdog_killed_result and _wah_effective_failure)] | length),
			wc:     ([$events[] | select(.result == "watchdog_stall_continue")] | length),
			sic:    ([$events[] | select(.result == $service_result)] | length),
			rl:     ([$w[] | select(.result == $rate_limit_result and _wah_effective_failure)] | length),
			of:     ([$w[] | select(
				_wah_effective_failure
				and .result != $watchdog_killed_result
				and .result != "watchdog_stall_continue"
				and .result != $service_result
				and .result != $rate_limit_result
			)] | length)
		} | "\(.total) \(.terminal) \(.succ) \(.wk) \(.wc) \(.sic) \(.rl) \(.of)"
	'
	result=$(jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --argjson objective_outcomes "$objective_outcomes" --arg worker_role "$WAH_RUNTIME_ROLE" --arg outcome_failed "$WAH_DELIVERY_FAILED" --arg service_result "$service_result" --arg watchdog_killed_result "$watchdog_killed_result" --arg rate_limit_result "$rate_limit_result" --arg repo_slug "$repo_slug" "$jq_program" <"$metrics" 2>/dev/null) || result="0 0 0 0 0 0 0 0"

	[[ -n "$result" ]] || result="0 0 0 0 0 0 0 0"
	printf '%s\n' "$result"
	return 0
}

#######################################
# Emit richer metric detail for JSON consumers.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# $2 — optional now_epoch (entries with ts > now are dropped).
# $3 — optional repository slug; excludes unscoped and other-repo events.
# stdout — JSON object containing result counts, duration summary, and examples.
#######################################
_wah_metric_details_json() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local repo_slug="${3:-}"
	local now_epoch

	if [[ ! -f "$metrics" ]]; then
		printf '{"event_total":0,"unscoped_event_total":0,"excluded_event_total":0,"result_counts":{},"diagnostic_focus":{},"timing_ms":{"avg":0,"max":0,"samples":0},"recent_examples":[],"failure_groups":[],"failure_families":[]}'
		return 0
	fi
	now_epoch="${2:-$(date +%s)}"

	local objective_outcomes
	objective_outcomes=$(_wah_objective_outcomes_json)
	jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --argjson objective_outcomes "$objective_outcomes" --arg worker_role "$WAH_RUNTIME_ROLE" --arg outcome_failed "$WAH_DELIVERY_FAILED" --arg watchdog_killed_result "$WAH_RESULT_WATCHDOG_STALL_KILLED" --arg local_kill_result "$WAH_RESULT_LOCAL_KILL" --arg repo_slug "$repo_slug" "$WAH_METRIC_DETAILS_JQ" <"$metrics" 2>/dev/null ||
		printf '{"event_total":0,"unscoped_event_total":0,"excluded_event_total":0,"result_counts":{},"diagnostic_focus":{},"timing_ms":{"avg":0,"max":0,"samples":0},"recent_examples":[],"failure_groups":[],"failure_families":[]}'
	return 0
}

#######################################
# Return bounded session identities whose dispatch ledger owner PID is live.
# This is local/offline evidence and never performs per-blocker GitHub queries.
# Args: optional_repo_slug
#######################################
_wah_live_blocker_sessions_json() {
	local repo_slug="${1:-}"
	local ledger="$WAH_DISPATCH_LEDGER_FILE"
	local live_sessions='[]'
	local session_key="" event_repo="" owner_pid="" owner_argv_hash="" owner_process_start=""
	if [[ ! -f "$ledger" ]]; then
		printf '%s\n' "$live_sessions"
		return 0
	fi
	while IFS=$'\x1f' read -r session_key event_repo owner_pid owner_argv_hash owner_process_start; do
		[[ -n "$session_key" && "$owner_pid" =~ ^[0-9]+$ && -n "$owner_process_start" ]] || continue
		if _is_process_alive_and_matches "$owner_pid" "$WAH_BLOCKER_OWNER_PROCESS_PATTERN" "$owner_argv_hash" "$owner_process_start"; then
			live_sessions=$(jq -cn \
				--argjson current "$live_sessions" \
				--arg session "$session_key" \
				--arg repo "$event_repo" \
				'$current + [{session_key:$session, repo_slug:$repo}]')
		fi
	done < <(jq -sr --arg repo "$repo_slug" --arg empty '' '
		to_entries
		| map(.value + {__wah_index: .key})
		| map(select((.session_key // $empty) != $empty)
			| select(($repo == $empty) or (((.repo_slug // $empty) | ascii_downcase) == ($repo | ascii_downcase))))
		| group_by([(.repo_slug // $empty), .session_key])
		| map(max_by(.__wah_index))
		| map(select((.status // $empty) == "in-flight"))
		| sort_by(.updated_at // .dispatched_at // $empty) | reverse
		| .[0:200][]
		| [(.session_key // $empty), (.repo_slug // $empty), ((.pid // $empty) | tostring), (.owner_argv_hash // $empty), (.owner_process_start // $empty)]
		| join("\u001f")' "$ledger" 2>/dev/null)
	printf '%s\n' "$live_sessions"
	return 0
}

#######################################
# Summarise bounded worker progress-blocker events and current blocker state.
# Event counts obey the requested window; current blockers use the latest
# retained event for each repo/issue/session/request identity. Null-issue identities
# require a live local dispatch owner; otherwise they remain visible as retained
# and unverified rather than being labelled a current worker stall.
# Args: cutoff_epoch now_epoch optional_repo_slug live_sessions_json
#######################################
_wah_blocker_details_json() {
	local cutoff_epoch="$1"
	local now_epoch="$2"
	local repo_slug="${3:-}"
	local live_sessions_json="${4:-[]}"
	local blocker_log="$WAH_BLOCKER_LOG_FILE"
	if [[ ! -f "$blocker_log" ]]; then
		printf '{"event_total":0,"active_total":0,"retained_unverified_total":0,"retained_supervisor_permission_total":0,"event_counts":{},"reason_counts":{},"active_blockers":[],"retained_unverified":[],"recent_blockers":[]}'
		return 0
	fi
	jq -Rsc --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --arg repo "$repo_slug" --arg empty '' --argjson live_sessions "$live_sessions_json" '
		def scoped:
			select(.schema == "aidevops-worker-blocker/v1")
			| select(($repo == $empty) or (((.repo_slug // $empty) | ascii_downcase) == ($repo | ascii_downcase)))
			| select((.ts // 0) <= $now);
		def identity:
			(.repo_slug // $empty) + "|" + ((.issue_number // $empty) | tostring) + "|"
			+ (if ((.session_key // $empty) | length) > 0 then .session_key else "unknown" end) + "|"
			+ (if ((.request_id // $empty) | length) > 0 then .request_id else "unknown" end);
		def has_issue_scope:
			if (.issue_number | type) == "number" then .issue_number > 0
			elif (.issue_number | type) == "string" then (.issue_number | test("^[1-9][0-9]*$"))
			else false end;
		def has_live_owner:
			. as $row
			| any($live_sessions[];
				((.repo_slug // $empty) | ascii_downcase) == (($row.repo_slug // $empty) | ascii_downcase)
				and (.session_key // $empty) == ($row.session_key // $empty));
		def proven_current: has_issue_scope or has_live_owner;
		[split("\n")[] | fromjson? | scoped] as $all
		| [$all[] | select((.ts // 0) >= $cutoff)] as $window
		| ($all | group_by(identity) | map(sort_by(.ts // 0) | last) | map(select(.blocking == true))) as $unresolved
		| ($unresolved | map(select(proven_current))) as $active
		| ($unresolved | map(select(proven_current | not))) as $retained
		| {
			event_total: ($window | length),
			active_total: ($active | length),
			retained_unverified_total: ($retained | length),
			retained_supervisor_permission_total: ([$retained[]
				| select(((.reason // "") | contains("permission"))
					and ((((.session_key // "") | startswith("supervisor-pulse")))
						or (((.source // "") | contains("supervisor-pulse")))))] | length),
			event_counts: (reduce $window[] as $row ({}; .[$row.event // "unknown"] += 1)),
			reason_counts: (reduce $window[] as $row ({}; .[$row.reason // "unknown"] += 1)),
			active_blockers: ($active | sort_by(.ts // 0) | reverse | .[0:10] | map({ts, timestamp, issue_number, repo_slug, session_key, request_id, event, reason, status, source, permission, tool, risk_level, grantable, detail})),
			retained_unverified: ($retained | sort_by(.ts // 0) | reverse | .[0:10] | map({ts, timestamp, issue_number, repo_slug, session_key, request_id, event, reason, status, source})),
			recent_blockers: ($window | sort_by(.ts // 0) | reverse | .[0:10] | map({ts, timestamp, issue_number, repo_slug, session_key, request_id, event, reason, status, blocking, source}))
		}' "$blocker_log" 2>/dev/null ||
		printf '{"event_total":0,"active_total":0,"retained_unverified_total":0,"retained_supervisor_permission_total":0,"event_counts":{},"reason_counts":{},"active_blockers":[],"retained_unverified":[],"recent_blockers":[]}'
	return 0
}

#######################################
# Emit bounded provider/model/account-pool usage from canonical metrics.
# This is the narrow diagnostic path for recent worker provider questions; it
# intentionally avoids recursive searches over logs or OpenCode storage.
#
# $1 — cutoff_epoch (entries with ts < cutoff are dropped).
# stdout — JSON object containing provider/model counts, recent worker samples,
#          and redacted OAuth pool aggregate counts (no emails/tokens).
#######################################
_wah_provider_usage_json() {
	local cutoff_epoch="$1"
	local metrics="$WAH_METRICS_FILE"
	local pool="$WAH_OAUTH_POOL_FILE"
	local now_epoch input_file account_multiplier

	now_epoch=$(date +%s)
	input_file="/dev/null"
	[[ -f "$metrics" ]] && input_file="$metrics"
	account_multiplier="${WAH_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-${PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-}}"
	if [[ -z "$account_multiplier" ]]; then
		# shellcheck source=config-helper.sh
		source "${SCRIPT_DIR}/config-helper.sh"
		account_multiplier=$(config_get "orchestration.provider_account_slot_multiplier" "24")
	fi
	[[ "$account_multiplier" =~ ^[0-9]+$ ]] || account_multiplier=24
	((account_multiplier < 1)) && account_multiplier=1

	if [[ -f "$pool" ]]; then
		jq -rn --slurpfile pool "$pool" --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --argjson account_multiplier "$account_multiplier" --arg rate_limit_result "$WAH_RESULT_RATE_LIMIT" --arg worker_role "$WAH_RUNTIME_ROLE" --arg status_empty '' --arg status_auth_error 'auth-error' --arg status_rate_limited 'rate-limited' --arg status_active 'active' --arg status_idle 'idle' '
			def account_status: .status // $status_empty;
			def available_account:
				(account_status) as $status
				| $status != $status_auth_error
				and (($status != $status_rate_limited) or ((.cooldownUntil // 0) <= ($now * 1000)));
			def active_or_idle:
				(.status // $status_idle) as $status
				| $status == $status_active or $status == $status_idle;
			($pool[0] // {}) as $pool_data
			| [inputs | select(.role == $worker_role and (.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w
			| {
				provider_model_usage: (
					$w
					| group_by([.provider // "unknown", .model // "unknown"])
					| map({
						provider: (.[0].provider // "unknown"),
						model: (.[0].model // "unknown"),
						count: length,
						runtime_handoffs: (map(select(.result == "success" and (.exit_code // 1) == 0)) | length),
						rate_limited: (map(select(.result == $rate_limit_result or .provider_error_type == $rate_limit_result or .provider_status == "429")) | length),
						other_failure: (map(select((.result != "success" or (.exit_code // 1) != 0) and .result != $rate_limit_result and .provider_error_type != $rate_limit_result and .provider_status != "429")) | length),
						latest_ts: (map(.ts // 0) | max)
					})
					| sort_by(.count, .latest_ts) | reverse | .[0:12]
				),
				recent_events: (
					$w | sort_by(.ts // 0) | reverse | .[0:10]
					| map({ts, provider, model, result, exit_code, issue_number, session_key})
				),
				account_pool: (
					$pool_data
					| to_entries
					| map(select(.key == "anthropic" or .key == "openai" or .key == "cursor" or .key == "google"))
					| map({
						provider: .key,
						total: (.value | length),
						available: (.value | map(select(available_account)) | length),
						capacity_slots: ((.value | map(select(available_account)) | length) * $account_multiplier),
						active_idle: (.value | map(select(active_or_idle)) | length),
						rate_limited: (.value | map(select(account_status == $status_rate_limited and ((.cooldownUntil // 0) > ($now * 1000)))) | length),
						auth_errors: (.value | map(select(account_status == $status_auth_error)) | length),
						latest_last_used: (.value | map(.lastUsed // empty) | max // "")
					})
					| sort_by(.provider)
				)
			}' <"$input_file" 2>/dev/null || printf '{"provider_model_usage":[],"recent_events":[],"account_pool":[]}'
	else
		jq -rn --argjson cutoff "$cutoff_epoch" --argjson now "$now_epoch" --arg rate_limit_result "$WAH_RESULT_RATE_LIMIT" --arg worker_role "$WAH_RUNTIME_ROLE" '
			[inputs | select(.role == $worker_role and (.ts // 0) >= $cutoff and (.ts // 0) <= $now)] as $w
			| {
				provider_model_usage: ($w | group_by([.provider // "unknown", .model // "unknown"]) | map({provider: (.[0].provider // "unknown"), model: (.[0].model // "unknown"), count: length, runtime_handoffs: (map(select(.result == "success" and (.exit_code // 1) == 0)) | length), rate_limited: (map(select(.result == $rate_limit_result or .provider_error_type == $rate_limit_result or .provider_status == "429")) | length), other_failure: (map(select((.result != "success" or (.exit_code // 1) != 0) and .result != $rate_limit_result and .provider_error_type != $rate_limit_result and .provider_status != "429")) | length), latest_ts: (map(.ts // 0) | max)}) | sort_by(.count, .latest_ts) | reverse | .[0:12]),
				recent_events: ($w | sort_by(.ts // 0) | reverse | .[0:10] | map({ts, provider, model, result, exit_code, issue_number, session_key})),
				account_pool: []
			}' <"$input_file" 2>/dev/null || printf '{"provider_model_usage":[],"recent_events":[],"account_pool":[]}'
	fi
	return 0
}

#######################################
# Count pulse-stats counter entries since cutoff.
# Counter values in pulse-stats.json are arrays of unix-second timestamps.
# Reading via `// []` handles missing keys without masking real counts.
#
# $1 — counter name
# $2 — cutoff_epoch
# stdout — integer count (0 on missing file/key/jq failure).
#######################################
_wah_count_stats_counter() {
	local key="$1" cutoff_epoch="$2"
	local file="$WAH_PULSE_STATS_FILE"
	local count=""

	if [[ ! -f "$file" ]]; then
		printf '0\n'
		return 0
	fi

	if count=$(jq -r --arg key "$key" --argjson cutoff "$cutoff_epoch" \
		'(.counters[$key] // []) | map(select(. >= $cutoff)) | length' \
		"$file" 2>/dev/null) && [[ "$count" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$count"
	else
		printf '0\n'
	fi
	return 0
}

#######################################
# Count one bounded GitHub list query.
#
# $1 — resource (`pr` or `issue`)
# $2 — state (`all`, `merged`, or `closed`)
# $3 — GitHub search expression
# $4 — repo_slug (optional; empty = current repo)
# stdout — integer count, or `null` on query/parse failure.
#######################################
_wah_gh_list_count() {
	local resource="$1"
	local state="$2"
	local search_query="$3"
	local repo_slug="${4:-}"
	local -a gh_args=("$resource" list --search "$search_query" --state "$state" --limit 1000 --json number)
	[[ -n "$repo_slug" ]] && gh_args+=(--repo "$repo_slug")

	local payload count
	if ! payload=$(gh "${gh_args[@]}" 2>/dev/null); then
		printf 'null\n'
		return 1
	fi
	count=$(printf '%s' "$payload" | jq -r 'if type == "array" then length else empty end' 2>/dev/null) || count=""
	if [[ ! "$count" =~ ^[0-9]+$ ]]; then
		printf 'null\n'
		return 1
	fi
	printf '%s\n' "$count"
	return 0
}

#######################################
# Get worker delivery-stage counts since `since_iso`.
# Caches the combined result for $WAH_PR_CACHE_TTL seconds so one summary run
# does not turn into repeated GitHub search traffic.
#
# `delivered_successes` uses closed `solved:worker` issues as the authoritative
# task-delivery signal. That label is applied by merge completion paths only
# after a worker-owned PR has been merged and its linked issue is closed.
#
# $1 — since_iso (YYYY-MM-DDTHH:MM:SSZ)
# $2 — repo_slug (optional; empty = current repo)
# $3 — stable window label for the cache key (optional; defaults to since_iso)
# stdout — JSON object with nullable stage counts and check_state.
#######################################
_wah_delivery_stages_json() {
	local since_iso="$1"
	local repo_slug="${2:-}"
	local cache_window="${3:-$since_iso}"
	local cache="$WAH_PR_CACHE_FILE"
	local cache_key="delivery-stages|${repo_slug:-current}|${cache_window}"

	# Check cache freshness (portable mtime via shared-constants).
	if [[ -f "$cache" ]]; then
		local mtime now age cached_key cached_delivery
		mtime=$(_file_mtime_epoch "$cache" 2>/dev/null) || mtime=0
		now=$(date +%s)
		age=$((now - mtime))
		if [[ $age -lt $WAH_PR_CACHE_TTL ]]; then
			cached_key=$(jq -r '.key // ""' "$cache" 2>/dev/null) || cached_key=""
			if [[ "$cached_key" == "$cache_key" ]]; then
				cached_delivery=$(jq -c '.delivery // empty' "$cache" 2>/dev/null) || cached_delivery=""
				if [[ -n "$cached_delivery" ]]; then
					printf '%s\n' "$cached_delivery"
					return 0
				fi
			fi
		fi
	fi

	local pr_opened="$WAH_JSON_NULL" pr_merged="$WAH_JSON_NULL" issue_solved="$WAH_JSON_NULL" check_state="ok"
	pr_opened=$(_wah_gh_list_count "pr" "all" "created:>=${since_iso} label:origin:worker" "$repo_slug") || check_state="$WAH_DELIVERY_FAILED"
	pr_merged=$(_wah_gh_list_count "pr" "merged" "merged:>=${since_iso} label:origin:worker" "$repo_slug") || check_state="$WAH_DELIVERY_FAILED"
	issue_solved=$(_wah_gh_list_count "issue" "closed" "closed:>=${since_iso} label:solved:worker" "$repo_slug") || check_state="$WAH_DELIVERY_FAILED"

	local delivery_json
	delivery_json=$(jq -n \
		--argjson pr_opened "$pr_opened" \
		--argjson pr_merged "$pr_merged" \
		--argjson issue_solved "$issue_solved" \
		--arg check_state "$check_state" \
		'{
			pr_opened: $pr_opened,
			pr_merged: $pr_merged,
			issue_solved: $issue_solved,
			delivered_successes: (if $check_state == "ok" then $issue_solved else null end),
			check_state: $check_state,
			success_basis: "closed issue labelled solved:worker after merged worker PR"
		}')

	# Best-effort cache write.
	mkdir -p "$(dirname "$cache")" 2>/dev/null || true
	if [[ "$check_state" == "ok" ]]; then
		local cache_ts
		cache_ts=$(date +%s)
		jq -n --arg key "$cache_key" --argjson delivery "$delivery_json" --argjson ts "$cache_ts" \
			'{key: $key, delivery: $delivery, ts: $ts}' >"$cache" 2>/dev/null || true
	fi
	printf '%s\n' "$delivery_json"
	return 0
}

#######################################
# Render summary in human-readable form.
# All inputs are pre-formatted strings/integers from cmd_summary.
#######################################
_wah_emit_human() {
	local since_label="$1" cutoff_iso="$2"
	local total="$3" terminal_total="$4" succ="$5" wk="$6" wc="$7" sic="$8" rl="$9" of="${10}"
	local cb="${11}" gqlow="${12}" db_skip="${13}" nwbreaker="${14}"
	local delivery_json="${15}" repo_label="${16}"
	local details_json="${17}"
	local blocker_json="${18}"

	local divider="==========================================================="

	# Runtime handoff rate excludes continuation heartbeats. It is intentionally
	# not called success: external delivery requires a merged PR and closed issue.
	local terminal=$((succ + wk + rl + of))
	local handoff_rate_pct="n/a"
	if [[ $terminal -gt 0 ]]; then
		handoff_rate_pct=$(awk -v s="$succ" -v t="$terminal" 'BEGIN{printf "%.0f%%", (s/t)*100}')
	fi
	local delivery_state pr_opened pr_merged issue_solved delivered_successes
	delivery_state=$(printf '%s' "$delivery_json" | jq -r --arg failed "$WAH_DELIVERY_FAILED" '.check_state // $failed' 2>/dev/null || printf '%s' "$WAH_DELIVERY_FAILED")
	pr_opened=$(printf '%s' "$delivery_json" | jq -r '.pr_opened // "?"' 2>/dev/null || printf '?')
	pr_merged=$(printf '%s' "$delivery_json" | jq -r '.pr_merged // "?"' 2>/dev/null || printf '?')
	issue_solved=$(printf '%s' "$delivery_json" | jq -r '.issue_solved // "?"' 2>/dev/null || printf '?')
	delivered_successes=$(printf '%s' "$delivery_json" | jq -r '.delivered_successes // "?"' 2>/dev/null || printf '?')

	printf '%s\n' "$divider"
	printf 'Worker activity reporting window: previous %s (cutoff: %s; observation only, not a worker runtime limit)\n' "$since_label" "$cutoff_iso"
	if [[ -n "$repo_label" ]]; then
		printf 'Repo: %s (repository-scoped metrics; unscoped legacy events excluded: %s)\n' "$repo_label" \
			"$(printf '%s' "$details_json" | jq -r '.unscoped_event_total // 0' 2>/dev/null || printf '0')"
	else
		printf 'Repo scope: global (all repositories and unscoped legacy events)\n'
	fi
	printf '%s\n' "$divider"
	printf '\n'
	printf 'headless-runtime-metrics.jsonl (canonical worker outcomes; scope: %s):\n' "$(if [[ -n "$repo_label" ]]; then printf 'repository'; else printf 'global'; fi)"
	printf '  Raw attempt/events:          %d\n' "$total"
	printf '  Terminal session outcomes:   %d\n' "$terminal_total"
	printf '  Runtime handoffs:            %d  (%s of terminal)\n' "$succ" "$handoff_rate_pct"
	printf '  Watchdog stall-killed:       %d\n' "$wk"
	printf '  Watchdog stall-continued:    %d  (heartbeat, not terminal)\n' "$wc"
	printf '  Service interruption resumed:%d  (heartbeat, not terminal)\n' "$sic"
	printf '  Rate-limited:                %d\n' "$rl"
	printf '  Other failure:               %d\n' "$of"
	printf '  Result classes:              %s\n' "$(printf '%s' "$details_json" | jq -c '.result_counts' 2>/dev/null || printf '{}')"
	printf '  Diagnostic focus:            %s\n' "$(printf '%s' "$details_json" | jq -c '.diagnostic_focus // {}' 2>/dev/null || printf '{}')"
	printf '  Timing ms (avg/max/samples): %s/%s/%s\n' \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.avg // 0' 2>/dev/null || printf '0')" \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.max // 0' 2>/dev/null || printf '0')" \
		"$(printf '%s' "$details_json" | jq -r '.timing_ms.samples // 0' 2>/dev/null || printf '0')"
	printf '  Provider/model usage:        worker-activity-helper.sh providers --since %s\n' "$since_label"
	printf '  Failure groups:             %s\n' "$(printf '%s' "$details_json" | jq -c '.failure_groups // []' 2>/dev/null || printf '[]')"
	printf '  Failure families:           %s\n' "$(printf '%s' "$details_json" | jq -c '.failure_families // []' 2>/dev/null || printf '[]')"
	[[ -n "$repo_label" ]] && printf '  Excluded events:            %s (unscoped: %s)\n' \
		"$(printf '%s' "$details_json" | jq -r '.excluded_event_total // 0' 2>/dev/null || printf '0')" \
		"$(printf '%s' "$details_json" | jq -r '.unscoped_event_total // 0' 2>/dev/null || printf '0')"
	printf '\n'
	printf 'worker-progress-blockers.jsonl (bounded progress holds; scope: %s):\n' "$(if [[ -n "$repo_label" ]]; then printf 'repository'; else printf 'global'; fi)"
	printf '  Events in window:            %s\n' "$(printf '%s' "$blocker_json" | jq -r '.event_total // 0' 2>/dev/null || printf '0')"
	printf '  Proven current:              %s\n' "$(printf '%s' "$blocker_json" | jq -r '.active_total // 0' 2>/dev/null || printf '0')"
	printf '  Retained/unverified:         %s\n' "$(printf '%s' "$blocker_json" | jq -r '.retained_unverified_total // 0' 2>/dev/null || printf '0')"
	printf '  Retained supervisor perms:   %s\n' "$(printf '%s' "$blocker_json" | jq -r '.retained_supervisor_permission_total // 0' 2>/dev/null || printf '0')"
	printf '  Reasons:                     %s\n' "$(printf '%s' "$blocker_json" | jq -c '.reason_counts // {}' 2>/dev/null || printf '{}')"
	printf '  Active blockers:             %s\n' "$(printf '%s' "$blocker_json" | jq -c '.active_blockers // []' 2>/dev/null || printf '[]')"
	printf '  Retained blockers:           %s\n' "$(printf '%s' "$blocker_json" | jq -c '.retained_unverified // []' 2>/dev/null || printf '[]')"
	printf '\n'
	printf 'pulse-stats.json (global dispatch-side counters; scope: global):\n'
	printf '  pulse_dispatch_circuit_broken:           %d\n' "$cb"
	printf '  pulse_cycle_skipped_graphql_low:         %d\n' "$gqlow"
	printf '  dispatch_backoff_skipped:                %d\n' "$db_skip"
	printf '  pulse_dispatch_no_work_breaker_tripped:  %d\n' "$nwbreaker"
	printf '\n'
	printf 'GitHub delivery stages (external truth; scope: %s):\n' "$(if [[ -n "$repo_label" ]]; then printf 'repository'; else printf 'global'; fi)"
	printf '  PRs opened:                  %s\n' "$pr_opened"
	printf '  PRs merged:                  %s\n' "$pr_merged"
	printf '  Issues solved and closed:    %s\n' "$issue_solved"
	printf '  Delivered successes:         %s\n' "$delivered_successes"
	printf '  Check state:                 %s' "$delivery_state"
	[[ "$delivery_state" == "skipped" ]] && printf '  (use --pr-check)'
	[[ "$delivery_state" == "$WAH_DELIVERY_FAILED" ]] && printf '  (one or more gh queries failed)'
	printf '\n'
	printf '%s\n' "$divider"
	return 0
}

#######################################
# Render provider/model/account-pool usage in human-readable form.
# Args: since_label cutoff_iso usage_json
#######################################
_wah_emit_providers_human() {
	local since_label="$1" cutoff_iso="$2" usage_json="$3"
	local divider="==========================================================="

	printf '%s\n' "$divider"
	printf 'Worker provider/model/account usage since %s (cutoff: %s)\n' "$since_label" "$cutoff_iso"
	printf '%s\n' "$divider"
	printf '\n'
	printf 'Provider/model usage (from headless-runtime-metrics.jsonl):\n'
	printf '%s' "$usage_json" | jq -r '
		(.provider_model_usage // []) as $rows
		| if ($rows | length) == 0 then "  (no worker metric events in window)"
		else $rows[] | "  \(.provider)/\(.model): count=\(.count) runtime_handoffs=\(.runtime_handoffs) rate_limited=\(.rate_limited) other_failure=\(.other_failure) latest_ts=\(.latest_ts)"
		end' 2>/dev/null || printf '  (provider/model usage unavailable)\n'
	printf '\n'
	printf 'OAuth account pool aggregate (redacted; no emails/tokens):\n'
	printf '%s' "$usage_json" | jq -r '
		(.account_pool // []) as $rows
		| if ($rows | length) == 0 then "  (no oauth-pool.json account summary available)"
		else $rows[] | "  \(.provider): total=\(.total) available=\(.available) capacity_slots=\(.capacity_slots // 0) active_idle=\(.active_idle) rate_limited=\(.rate_limited) auth_errors=\(.auth_errors) latest_last_used=\(.latest_last_used // "")"
		end' 2>/dev/null || printf '  (account pool summary unavailable)\n'
	printf '\n'
	printf 'Recent worker samples (bounded to 10):\n'
	printf '%s' "$usage_json" | jq -r '
		(.recent_events // []) as $rows
		| if ($rows | length) == 0 then "  (no recent samples)"
		else $rows[] | "  ts=\(.ts) provider=\(.provider // "") model=\(.model // "") result=\(.result // "") issue=\(.issue_number // "") session=\(.session_key // "")"
		end' 2>/dev/null || printf '  (recent samples unavailable)\n'
	printf '%s\n' "$divider"
	return 0
}

#######################################
# Render summary in JSON. All inputs are pre-formatted scalars.
#######################################
_wah_emit_json() {
	local since_label="$1" cutoff_iso="$2" cutoff_epoch="$3"
	local total="$4" terminal_total="$5" succ="$6" wk="$7" wc="$8" sic="$9" rl="${10}" of="${11}"
	local cb="${12}" gqlow="${13}" db_skip="${14}" nwbreaker="${15}"
	local delivery_json="${16}" repo_label="${17}"
	local details_json="${18}"
	local blocker_json="${19}"

	jq -n \
		--arg since "$since_label" \
		--arg cutoff_iso "$cutoff_iso" \
		--argjson cutoff_epoch "$cutoff_epoch" \
		--argjson total "$total" \
		--argjson terminal_total "$terminal_total" \
		--argjson succ "$succ" \
		--argjson wk "$wk" \
		--argjson wc "$wc" \
		--argjson sic "$sic" \
		--argjson rl "$rl" \
		--argjson of "$of" \
		--argjson cb "$cb" \
		--argjson gqlow "$gqlow" \
		--argjson db_skip "$db_skip" \
		--argjson nwbreaker "$nwbreaker" \
		--argjson delivery "$delivery_json" \
		--argjson details "$details_json" \
		--argjson blockers "$blocker_json" \
		--arg repo "$repo_label" \
		'{
			window: { since: $since, cutoff_iso: $cutoff_iso, cutoff_epoch: $cutoff_epoch, semantics: "historical_observation_only", worker_runtime_limit: null },
			repo: (if $repo == "" then null else $repo end),
			metrics: {
				scope: (if $repo == "" then "global" else "repository" end),
				total: $total,
				terminal_session_total: $terminal_total,
				event_total: ($details.event_total // $total),
				unscoped_event_total: ($details.unscoped_event_total // 0),
				excluded_event_total: ($details.excluded_event_total // 0),
				continuation_events: ($details.continuation_events // 0),
				runtime_handoffs: $succ,
				succeeded: ($delivery.delivered_successes // null),
				success_basis: $delivery.success_basis,
				watchdog_killed: $wk,
				watchdog_continued: $wc,
				service_interrupted: $sic,
				rate_limited: $rl,
				other_failure: $of,
				result_counts: $details.result_counts,
				event_result_counts: ($details.event_result_counts // $details.result_counts),
				diagnostic_focus: ($details.diagnostic_focus // {}),
				timing_ms: $details.timing_ms,
				recent_examples: $details.recent_examples,
				failure_groups: ($details.failure_groups // []),
				failure_families: ($details.failure_families // [])
			},
			pulse_stats: {
				scope: "global",
				pulse_dispatch_circuit_broken: $cb,
				pulse_cycle_skipped_graphql_low: $gqlow,
				dispatch_backoff_skipped: $db_skip,
				pulse_dispatch_no_work_breaker_tripped: $nwbreaker
			},
			progress_blockers: ($blockers + {scope: (if $repo == "" then "global" else "repository" end)}),
			delivery_stages: ($delivery + {scope: (if $repo == "" then "global" else "repository" end)}),
			worker_solved_issues: { count: $delivery.issue_solved, check_state: $delivery.check_state, deprecated: true },
			worker_prs: { count: $delivery.pr_opened, merged_count: $delivery.pr_merged, check_state: $delivery.check_state, deprecated: true }
		}'
	return 0
}

#######################################
# Orchestrate one summary run. Parses args, calls aggregators, dispatches
# to the right emitter.
#######################################
cmd_summary() {
	local since_label="24h" emit_json=0 do_pr_check=0 repo_label=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--since)
			since_label="${2:-}"
			shift 2
			;;
		--json)
			emit_json=1
			shift
			;;
		--pr-check)
			do_pr_check=1
			shift
			;;
		--no-pr-check)
			do_pr_check=0
			shift
			;;
		--repo)
			repo_label="${2:-}"
			shift 2
			;;
		-h | --help)
			cmd_help
			return 0
			;;
		*)
			printf 'unknown flag: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done

	local since_seconds
	since_seconds=$(_wah_parse_since "$since_label") || {
		printf 'invalid --since value: %s (use 1h|6h|24h|48h|7d)\n' "$since_label" >&2
		return 2
	}

	local now_epoch cutoff_epoch cutoff_iso
	now_epoch=$(date +%s)
	cutoff_epoch=$((now_epoch - since_seconds))
	cutoff_iso=$(date -u -r "$cutoff_epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso=$(date -u -d "@${cutoff_epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso="(unknown)"

	# Aggregate metrics (single jq+awk pass).
	local agg total terminal_total succ wk wc sic rl of details_json blocker_json live_blocker_sessions_json
	agg=$(_wah_aggregate_metrics "$cutoff_epoch" "$now_epoch" "$repo_label")
	read -r total terminal_total succ wk wc sic rl of <<<"$agg"
	details_json=$(_wah_metric_details_json "$cutoff_epoch" "$now_epoch" "$repo_label")
	live_blocker_sessions_json=$(_wah_live_blocker_sessions_json "$repo_label")
	blocker_json=$(_wah_blocker_details_json "$cutoff_epoch" "$now_epoch" "$repo_label" "$live_blocker_sessions_json")

	# Pulse-stats counters.
	local cb gqlow db_skip nwbreaker
	cb=$(_wah_count_stats_counter "pulse_dispatch_circuit_broken" "$cutoff_epoch")
	gqlow=$(_wah_count_stats_counter "pulse_cycle_skipped_graphql_low" "$cutoff_epoch")
	db_skip=$(_wah_count_stats_counter "dispatch_backoff_skipped" "$cutoff_epoch")
	nwbreaker=$(_wah_count_stats_counter "pulse_dispatch_no_work_breaker_tripped" "$cutoff_epoch")

	# Delivery-stage counts (optional, network-dependent).
	local delivery_json
	if [[ $do_pr_check -eq 1 ]]; then
		delivery_json=$(_wah_delivery_stages_json "$cutoff_iso" "$repo_label" "$since_label")
	else
		delivery_json='{"pr_opened":null,"pr_merged":null,"issue_solved":null,"delivered_successes":null,"check_state":"skipped","success_basis":"closed issue labelled solved:worker after merged worker PR"}'
	fi

	if [[ $emit_json -eq 1 ]]; then
		_wah_emit_json "$since_label" "$cutoff_iso" "$cutoff_epoch" \
			"$total" "$terminal_total" "$succ" "$wk" "$wc" "$sic" "$rl" "$of" \
			"$cb" "$gqlow" "$db_skip" "$nwbreaker" \
			"$delivery_json" "$repo_label" "$details_json" "$blocker_json"
	else
		_wah_emit_human "$since_label" "$cutoff_iso" \
			"$total" "$terminal_total" "$succ" "$wk" "$wc" "$sic" "$rl" "$of" \
			"$cb" "$gqlow" "$db_skip" "$nwbreaker" \
			"$delivery_json" "$repo_label" "$details_json" "$blocker_json"
	fi
	return 0
}

#######################################
# Orchestrate bounded provider/model/account-pool diagnostics.
#######################################
cmd_providers() {
	local since_label="24h" emit_json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--since)
			since_label="${2:-}"
			shift 2
			;;
		--json)
			emit_json=1
			shift
			;;
		-h | --help)
			cmd_help
			return 0
			;;
		*)
			printf 'unknown flag: %s\n' "$arg" >&2
			return 2
			;;
		esac
	done

	local since_seconds
	since_seconds=$(_wah_parse_since "$since_label") || {
		printf 'invalid --since value: %s (use 1h|6h|24h|48h|7d)\n' "$since_label" >&2
		return 2
	}

	local now_epoch cutoff_epoch cutoff_iso usage_json
	now_epoch=$(date +%s)
	cutoff_epoch=$((now_epoch - since_seconds))
	cutoff_iso=$(date -u -r "$cutoff_epoch" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso=$(date -u -d "@${cutoff_epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
		cutoff_iso="(unknown)"
	usage_json=$(_wah_provider_usage_json "$cutoff_epoch")

	if [[ $emit_json -eq 1 ]]; then
		jq -n \
			--arg since "$since_label" \
			--arg cutoff_iso "$cutoff_iso" \
			--argjson cutoff_epoch "$cutoff_epoch" \
			--argjson usage "$usage_json" \
			'{window: {since: $since, cutoff_iso: $cutoff_iso, cutoff_epoch: $cutoff_epoch}, provider_diagnostics: $usage}'
	else
		_wah_emit_providers_human "$since_label" "$cutoff_iso" "$usage_json"
	fi
	return 0
}

#######################################
# Print the current logical worker count using the canonical, portable
# process-tree detector shared with Pulse.
#######################################
cmd_live_workers() {
	# shellcheck source=worker-lifecycle-common.sh
	source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
	local count=""
	count=$(count_active_workers 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

#######################################
# Help text.
#######################################
cmd_help() {
	cat <<'EOF'
worker-activity-helper.sh — Canonical worker activity summary

Usage:
  worker-activity-helper.sh summary [OPTIONS]
  worker-activity-helper.sh providers [OPTIONS]
  worker-activity-helper.sh live-workers
  worker-activity-helper.sh help

Options:
  --since 1h|6h|24h|48h|7d   Lookback window (default: 24h)
  --json                     Emit machine-readable JSON
  --pr-check                 Query opened/merged worker PRs and solved issues
                             (three GitHub search calls; disabled by default)
  --no-pr-check              Explicitly keep delivery-stage queries skipped (default)
  --repo OWNER/REPO           Scope repo-attributable metrics, blockers, and
                              delivery-stage queries to a single repo; legacy
                              unscoped metric events are excluded and disclosed
                              while Pulse counters remain explicitly global

Sources read (in canonical-precedence order):
  1. ~/.aidevops/logs/headless-runtime-metrics.jsonl  (worker outcomes)
  2. ~/.aidevops/logs/pulse-stats.json                (dispatch counters)
  3. ~/.aidevops/logs/worker-progress-blockers.jsonl  (bounded progress holds)
  4. gh pr/issue list worker delivery stages          (optional external truth)

Examples:
  # Last 24 hours, human-readable.
  worker-activity-helper.sh summary

  # Last 6 hours as JSON.
  worker-activity-helper.sh summary --since 6h --json

  # Bounded provider/model/account-pool diagnostics; no recursive log search.
  worker-activity-helper.sh providers --since 1h

  # Last 7 days, single repo, no network call.
  worker-activity-helper.sh summary --since 7d --repo marcusquinn/aidevops --no-pr-check

  # Include PR-opened, PR-merged, and solved-issue stages when API budget is healthy.
  worker-activity-helper.sh summary --since 24h --pr-check

  # Current logical worker count (portable across macOS and Linux).
  worker-activity-helper.sh live-workers

NOT a substitute for:
  - worker-NNN.log mtime → file touch time, not outcome.
  - recursive grep over ~/.aidevops/logs or OpenCode storage → unbounded noise.
  - pulse-runner-health-helper.sh diagnose → per-runner zero-attempt breaker.

Filed under: t3215 / GH#21949
EOF
	return 0
}

#######################################
# main — dispatch on subcommand.
#######################################
main() {
	local cmd="${1:-help}"
	[[ $# -gt 0 ]] && shift
	case "$cmd" in
	summary) cmd_summary "$@" ;;
	providers | provider-usage) cmd_providers "$@" ;;
	live-workers | worker-count) cmd_live_workers ;;
	help | -h | --help) cmd_help ;;
	*)
		printf 'unknown command: %s\n' "$cmd" >&2
		cmd_help >&2
		return 2
		;;
	esac
}

main "$@"
