#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# objective-reconciliation-helper.sh — derive durable objective state and recovery.

set -uo pipefail

OBJECTIVE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=portable-stat.sh
source "${OBJECTIVE_SCRIPT_DIR}/portable-stat.sh"

OBJECTIVE_DEFAULT_TTL_SECS="${AIDEVOPS_OBJECTIVE_ASSUMPTION_TTL_SECS:-3600}"
OBJECTIVE_DEFAULT_MAX_REPAIRS="${AIDEVOPS_OBJECTIVE_MAX_REPAIRS:-25}"
OBJECTIVE_RECORD_ATTEMPT_OUTCOME="attempt_outcome"
OBJECTIVE_EVENT_COMPLETED="worker.completed"
OBJECTIVE_EVENT_FAILED="worker.failed"
OBJECTIVE_EVENT_DEFERRED="worker.deferred"
OBJECTIVE_OUTCOME_SUCCESS="success"
OBJECTIVE_OUTCOME_FAILED="failed"
OBJECTIVE_OUTCOME_DEFERRED="deferred"
OBJECTIVE_OUTCOME_UNKNOWN="unknown"
OBJECTIVE_OUTCOME_TERMINAL="terminal"
OBJECTIVE_SOURCE_NONE="none"
OBJECTIVE_SOURCE_LIFECYCLE="lifecycle_event"
OBJECTIVE_SOURCE_STATE="objective_state"
OBJECTIVE_STATE_COMPLETED="completed"
OBJECTIVE_STATE_CANCELLED="cancelled"
OBJECTIVE_STATE_IMPOSSIBLE="impossible"
OBJECTIVE_STATE_REVIEW="under review"
OBJECTIVE_JSON_TYPE_OBJECT="object"
OBJECTIVE_EMPTY_STATE='{"objectives":[]}'

_objective_usage() {
	cat <<'EOF'
Usage:
  objective-reconciliation-helper.sh derive [--input FILE] [--now EPOCH] [--ttl SECONDS]
  objective-reconciliation-helper.sh reconcile --repo OWNER/REPO [--input FILE]
      [--state-file FILE] [--now EPOCH] [--ttl SECONDS] [--max-repairs COUNT]
  objective-reconciliation-helper.sh summary [--state-file FILE]
  objective-reconciliation-helper.sh record-outcome --repo OWNER/REPO --issue NUM
      --attempt-id ID [--run-id ID] --raw-result RESULT --outcome OUTCOME
      [--status STATUS] [--classification CLASS] [--next-action ACTION]
      [--attempt-started-at EPOCH] [--timestamp EPOCH]
  objective-reconciliation-helper.sh disposition --repo OWNER/REPO --issue NUM
      [--attempt-id ID] [--state-file FILE]

Input is either an issue array or an object containing `issues`, `prs`, and an
optional pipe-delimited `merged_lookup`. Reconciliation is API-free: its
idempotent repair is a durable, bounded next-action ledger consumed by pulse.
EOF
	return 0
}

_objective_now() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

_objective_validate_uint() {
	local value="$1"
	local fallback="$2"
	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$fallback"
	fi
	return 0
}

_objective_read_input() {
	local input_file="$1"
	if [[ "$input_file" == "-" ]]; then
		jq -c '.'
	elif [[ -r "$input_file" ]]; then
		jq -c '.' "$input_file"
	else
		printf 'ERROR: objective input is not readable: %s\n' "$input_file" >&2
		return 2
	fi
	return $?
}

_objective_lock_age() {
	local lock_dir="$1"
	local now_epoch=""
	local mtime_epoch=""

	now_epoch=$(_objective_now)
	mtime_epoch=$(_file_mtime_epoch "$lock_dir")
	[[ "$now_epoch" =~ ^[0-9]+$ && "$mtime_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$mtime_epoch" ]] || {
		printf '0\n'
		return 0
	}
	printf '%s\n' "$((now_epoch - mtime_epoch))"
	return 0
}

_objective_acquire_append_lock() {
	local lock_dir="$1"
	local attempts=0
	local owner_pid=""
	local lock_age="0"
	local orphan_age="${AIDEVOPS_OBJECTIVE_LOCK_ORPHAN_AGE_SECS:-30}"
	[[ "$orphan_age" =~ ^[0-9]+$ && "$orphan_age" -ge 5 ]] || orphan_age=30
	while ! mkdir "$lock_dir" 2>/dev/null; do
		attempts=$((attempts + 1))
		owner_pid=$(tr -d '[:space:]' "${lock_dir}/owner.pid" 2>/dev/null || true)
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		if [[ -z "$owner_pid" && "$attempts" -ge 20 ]]; then
			lock_age=$(_objective_lock_age "$lock_dir")
			if [[ "$lock_age" -ge "$orphan_age" ]]; then
				rmdir "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		[[ "$attempts" -lt 100 ]] || return 1
		sleep 0.05
	done
	printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null || true
	return 0
}

_objective_release_append_lock() {
	local lock_dir="$1"
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_objective_record_outcome() {
	local repo="$1"
	local issue_number="$2"
	local attempt_id="$3"
	local run_id="$4"
	local raw_result="$5"
	local outcome="$6"
	local status="$7"
	local classification="$8"
	local next_action="$9"
	local evidence_timestamp="${10}"
	local attempt_started_at="${11}"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_dir=""
	local lock_dir="${evidence_file}.lockdir"
	local event_type="$OBJECTIVE_EVENT_FAILED"
	local execution_path_state="recovery"

	[[ -n "$repo" && "$issue_number" =~ ^[1-9][0-9]*$ && -n "$attempt_id" ]] || {
		printf 'ERROR: record-outcome requires --repo, --issue, and --attempt-id\n' >&2
		return 2
	}
	case "$outcome" in
	success) event_type="$OBJECTIVE_EVENT_COMPLETED"; execution_path_state="$OBJECTIVE_OUTCOME_TERMINAL" ;;
	failed) event_type="$OBJECTIVE_EVENT_FAILED"; execution_path_state="recovery" ;;
	deferred) event_type="$OBJECTIVE_EVENT_DEFERRED"; execution_path_state="$OBJECTIVE_OUTCOME_DEFERRED" ;;
	escalated) event_type="$OBJECTIVE_EVENT_FAILED"; execution_path_state="escalated" ;;
	*) printf 'ERROR: unsupported reconciled outcome: %s\n' "$outcome" >&2; return 2 ;;
	esac
	[[ "$evidence_timestamp" =~ ^[0-9]+$ ]] || evidence_timestamp=$(_objective_now)
	[[ "$attempt_started_at" =~ ^[0-9]+$ ]] || attempt_started_at="$evidence_timestamp"
	evidence_dir=$(dirname "$evidence_file")
	mkdir -p "$evidence_dir" 2>/dev/null || return 1
	touch "$evidence_file" 2>/dev/null || return 1
	_objective_acquire_append_lock "$lock_dir" || return 1
	if jq -Rse --arg repo "$repo" --argjson issue "$issue_number" --arg aid "$attempt_id" \
		--arg record_type "$OBJECTIVE_RECORD_ATTEMPT_OUTCOME" \
		'split("\n") | any(.[]; (try fromjson catch {}) as $row |
			$row.record_type == $record_type and $row.repo == $repo and
			(($row.issue_number // 0) | tonumber? // 0) == $issue and ($row.attempt_id // "") == $aid)' \
		"$evidence_file" >/dev/null 2>&1; then
		_objective_release_append_lock "$lock_dir"
		return 0
	fi
	jq -cn --argjson schema_version 2 --arg record_type "$OBJECTIVE_RECORD_ATTEMPT_OUTCOME" \
		--arg event_type "$event_type" --arg repo "$repo" --argjson issue_number "$issue_number" \
		--arg attempt_id "$attempt_id" --arg run_id "$run_id" --arg raw_result "$raw_result" \
		--arg effective_outcome "$outcome" --arg status "$status" --arg classification "$classification" \
		--arg next_action "$next_action" --arg execution_path_state "$execution_path_state" \
		--arg worker_id "${AIDEVOPS_WORKER_ID:-}" --argjson evidence_timestamp "$evidence_timestamp" \
		--arg attempt_started_at "$attempt_started_at" \
		'{schema_version:$schema_version,record_type:$record_type,event_type:$event_type,
		repo:$repo,issue_number:$issue_number,attempt_id:$attempt_id,run_id:$run_id,
		attempt_started_at:$attempt_started_at,
		raw_result:$raw_result,effective_outcome:$effective_outcome,status:$status,
		classification:$classification,next_action:$next_action,
		execution_path_state:$execution_path_state,worker_id:$worker_id,
		evidence_timestamp:$evidence_timestamp,terminal:true,process_active:false,
		subsequent_action_at:$evidence_timestamp}' >>"$evidence_file" 2>/dev/null || {
		_objective_release_append_lock "$lock_dir"
		return 1
	}
	_objective_release_append_lock "$lock_dir"
	return 0
}

_objective_disposition() {
	local repo="$1"
	local issue_number="$2"
	local attempt_id="$3"
	local state_file="$4"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	local evidence_json='[]'
	local state_json="$OBJECTIVE_EMPTY_STATE"

	[[ -n "$repo" && "$issue_number" =~ ^[1-9][0-9]*$ ]] || {
		printf 'ERROR: disposition requires --repo and --issue\n' >&2
		return 2
	}
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	if [[ -s "$evidence_file" ]]; then
		evidence_json=$(tail -n "$evidence_limit" "$evidence_file" 2>/dev/null | jq -sc \
			--arg object_type "$OBJECTIVE_JSON_TYPE_OBJECT" '[.[] | select(type == $object_type)]') || evidence_json='[]'
	fi
	if [[ -s "$state_file" ]]; then
		state_json=$(jq -c '.' "$state_file" 2>/dev/null) || state_json="$OBJECTIVE_EMPTY_STATE"
	fi
	jq -nc --arg repo "$repo" --argjson issue "$issue_number" --arg aid "$attempt_id" \
		--slurpfile evidence_file <(printf '%s\n' "$evidence_json") \
		--slurpfile state_file <(printf '%s\n' "$state_json") \
		--arg record_type "$OBJECTIVE_RECORD_ATTEMPT_OUTCOME" \
		--arg event_completed "$OBJECTIVE_EVENT_COMPLETED" --arg event_failed "$OBJECTIVE_EVENT_FAILED" --arg event_deferred "$OBJECTIVE_EVENT_DEFERRED" \
		--arg outcome_success "$OBJECTIVE_OUTCOME_SUCCESS" --arg outcome_failed "$OBJECTIVE_OUTCOME_FAILED" --arg outcome_deferred "$OBJECTIVE_OUTCOME_DEFERRED" \
		--arg outcome_unknown "$OBJECTIVE_OUTCOME_UNKNOWN" --arg outcome_terminal "$OBJECTIVE_OUTCOME_TERMINAL" \
		--arg source_lifecycle "$OBJECTIVE_SOURCE_LIFECYCLE" --arg source_state "$OBJECTIVE_SOURCE_STATE" --arg source_none "$OBJECTIVE_SOURCE_NONE" \
		--arg state_completed "$OBJECTIVE_STATE_COMPLETED" --arg state_cancelled "$OBJECTIVE_STATE_CANCELLED" \
		--arg state_impossible "$OBJECTIVE_STATE_IMPOSSIBLE" --arg state_review "$OBJECTIVE_STATE_REVIEW" '
		($evidence_file[0] // []) as $evidence |
		($state_file[0] // {objectives:[]}) as $state |
		def timestamp: ((.evidence_timestamp // .timestamp // .ts // 0) | tonumber? // 0);
		def epoch_key:
			((.attempt_started_at // timestamp) | tostring) as $raw |
			if ($raw | test("^[0-9]+$")) then
				if ($raw | length) >= 19 then $raw[0:19]
				else ($raw + "0000000000000000000")[0:19] end
			else "0000000000000000000" end;
		def terminal_event: .event_type == $event_completed or .event_type == $event_failed or .event_type == $event_deferred;
		def output($source; $record; $effective):
			($effective == $outcome_success or $effective == "handoff" or $effective == $outcome_terminal or $effective == "escalated") as $stop_retry |
			($effective != $outcome_unknown and $effective != $outcome_failed) as $nonfailure |
			{
				schema_version:2, source:$source, repo:$repo, issue_number:$issue,
				attempt_id:($record.attempt_id // $aid), run_id:($record.run_id // ""),
				attempt_started_at:($record.attempt_started_at // null),
				effective_outcome:$effective, raw_result:($record.raw_result // ""),
				status:($record.status // ""), classification:($record.classification // ""),
				next_action:($record.next_action // ""), evidence_timestamp:($record | timestamp),
				terminal:($effective != $outcome_unknown), suppress_fast_fail:$nonfailure,
				suppress_retry:$stop_retry, suppress_enrichment:$nonfailure,
				suppress_failure_mining:$nonfailure
			};
		[$evidence[] | select(.repo == $repo and ((.issue_number // 0) | tonumber? // 0) == $issue)] as $rows |
		[$rows[] | select(.record_type == $record_type)] as $outcomes |
		(if $aid == "" then $outcomes else [$outcomes[] | select((.attempt_id // "") == $aid)] end |
			sort_by([epoch_key, timestamp]) | last // null) as $exact |
		([$rows[] | select((.record_type // "") != $record_type and terminal_event) |
			select($aid == "" or (.attempt_id // "") == $aid or
				((.attempt_id // "") == "" and ($outcomes | length) == 0))] |
			sort_by([epoch_key, timestamp]) | last // null) as $lifecycle |
		([$state.objectives[]? | select(.repo == $repo and ((.number // .issue_number // 0) | tonumber? // 0) == $issue)] |
			last // null) as $objective |
		if $exact != null then output($record_type; $exact; ($exact.effective_outcome // $outcome_unknown))
		elif $lifecycle != null then
			if $lifecycle.event_type == $event_completed then output($source_lifecycle; $lifecycle; $outcome_success)
			elif $lifecycle.event_type == $event_deferred then output($source_lifecycle; $lifecycle; $outcome_deferred)
			else output($source_lifecycle; $lifecycle; $outcome_failed) end
		elif $objective != null then
			if $objective.objective_state == $state_completed then output($source_state; $objective; $outcome_success)
			elif $objective.objective_state == $state_review then output($source_state; $objective; "handoff")
			elif $objective.objective_state == $state_cancelled or $objective.objective_state == $state_impossible then output($source_state; $objective; $outcome_terminal)
			elif $objective.objective_state == "authority-blocked" or $objective.objective_state == "dependency-blocked" then output($source_state; $objective; $outcome_deferred)
			else output($source_none; {}; $outcome_unknown) end
		else output($source_none; {}; $outcome_unknown) end'
	return $?
}

_objective_attach_durable_evidence() {
	local input_json="$1"
	local repo="$2"
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_limit="${AIDEVOPS_OBJECTIVE_EVIDENCE_LIMIT:-2000}"
	[[ "$evidence_limit" =~ ^[1-9][0-9]*$ ]] || evidence_limit=2000
	if [[ ! -s "$evidence_file" ]]; then
		printf '%s\n' "$input_json"
		return 0
	fi
	local evidence_json="[]"
	evidence_json=$(tail -n "$evidence_limit" "$evidence_file" 2>/dev/null | jq -sc \
		--arg object_type "$OBJECTIVE_JSON_TYPE_OBJECT" '[.[] | select(type == $object_type)]') || evidence_json="[]"
	jq -nc --arg repo "$repo" --argjson input "$input_json" --argjson evidence "$evidence_json" \
		--arg event_completed "$OBJECTIVE_EVENT_COMPLETED" --arg event_failed "$OBJECTIVE_EVENT_FAILED" \
		--arg event_deferred "$OBJECTIVE_EVENT_DEFERRED" '
		def evidence_epoch: (.evidence_timestamp // .timestamp // .ts // 0) | tonumber? // 0;
		def epoch_key:
			((.attempt_started_at // evidence_epoch) | tostring) as $raw |
			if ($raw | test("^[0-9]+$")) then
				if ($raw | length) >= 19 then $raw[0:19]
				else ($raw + "0000000000000000000")[0:19] end
			else "0000000000000000000" end;
		(if ($input | type) == "array" then {issues:$input, prs:[], merged_lookup:""} else $input end) |
		.issues = [(.issues // [])[] | . as $issue |
			([$evidence[] | select(.repo == ($issue.repo // $repo) and
				((.issue_number // 0) | tonumber? // 0) == (($issue.number // 0) | tonumber? // 0))] |
				sort_by([epoch_key, evidence_epoch]) | last // {}) as $event |
			if ($event | length) == 0 then $issue else
				$issue + {
					evidence_timestamp: $event.evidence_timestamp,
					lease_active: (($event.terminal // false) != true and $event.event_type != $event_completed and $event.event_type != $event_failed and $event.event_type != $event_deferred),
					process_active: (($event.terminal // false) != true and $event.event_type != $event_completed and $event.event_type != $event_failed and $event.event_type != $event_deferred),
					execution_path_state: $event.execution_path_state,
					attempt_id: ($event.attempt_id // ""),
					run_id: ($event.run_id // ""),
					raw_result: ($event.raw_result // ""),
					terminal_outcome: ($event.effective_outcome // ""),
					reconciled_next_action: ($event.next_action // ""),
					branch_exists: ($event.branch_preserved // false),
					worktree_exists: ($event.worktree_preserved // false),
					commits_preserved: ($event.commits_preserved // false),
					logs_preserved: ($event.logs_preserved // false),
					verification_preserved: ($event.verification_preserved // false),
					subsequent_action_at: ($event.subsequent_action_at // 0),
					recovery_attempt: ($event.recovery_attempt // ($issue.recovery_attempt // 0))
				}
			end
		]'
	return $?
}

_objective_derive_json() {
	local input_json="$1" repo="$2" now_epoch="$3" ttl_secs="$4"
	printf '%s' "$input_json" | jq -c --arg repo "$repo" --argjson now "$now_epoch" --argjson ttl "$ttl_secs" \
		--arg state_completed "$OBJECTIVE_STATE_COMPLETED" --arg state_cancelled "$OBJECTIVE_STATE_CANCELLED" --arg state_impossible "$OBJECTIVE_STATE_IMPOSSIBLE" --arg state_review "$OBJECTIVE_STATE_REVIEW" --arg action_none "$OBJECTIVE_SOURCE_NONE" --arg outcome_failed "$OBJECTIVE_OUTCOME_FAILED" --arg object_type "$OBJECTIVE_JSON_TYPE_OBJECT" '
		def labels: [(.labels // [])[] | if type == $object_type then .name else . end] | map(select(type == "string"));
		def has_label($name): labels | index($name) != null;
		def has_status($name): has_label("status:" + $name);
		def action_resume: "resume_session"; def action_recover_branch: "recover_branch"; def action_repair_pr: "repair_pr"; def action_redispatch: "narrow_redispatch";
		def evidence_epoch:
			(.evidence_timestamp // .evidence_at // .updatedAt // .updated_at // $now) as $value |
			if ($value | type) == "number" then $value elif ($value | type) == "string"
			then (($value | fromdateiso8601?) // ($value | tonumber?) // $now) else $now end;
		def issue_number: (.number // .issue_number // 0) | tonumber;
		def matching_pr($prs):
			issue_number as $number |
			("(^|[^0-9])#?" + ($number | tostring) + "([^0-9]|$)") as $number_pattern |
			first($prs[]? | select(((.issue_number // 0) | tonumber) == $number or
				((.title // "") | test($number_pattern)) or
				((.headRefName // .head_ref_name // "") | test($number_pattern)))) // {};
		def ladder($attempt; $authority):
			if $attempt <= 0 then "retry_infrastructure"
			elif $attempt <= 4 then [action_resume, action_recover_branch, action_repair_pr, action_redispatch][$attempt - 1]
			elif $attempt == 5 then "model_escalation"
			elif $attempt == 6 then "diagnostic_worker"
			elif $authority then "decision_ready_human_packet"
			else "diagnostic_worker" end;
		def owner_for($action):
			if $action == "monitor_worker" or $action == action_resume then "worker-supervisor" elif $action == "monitor_pr" or $action == action_repair_pr then "pr-repair"
			elif $action == "reverify_dependency" then "dependency-monitor"
			elif $action == "decision_ready_human_packet" then "maintainer-gate"
			elif $action == "close_issue" then "issue-reconciler"
			elif $action == $action_none then $action_none
			else "pulse-dispatch" end;
		(.issues // (if type == "array" then . else [] end)) as $issues | (.prs // []) as $prs | (.merged_lookup // "") as $merged_lookup |
		[$issues[] |
			. as $issue |
			labels as $labels |
			issue_number as $number |
			evidence_epoch as $evidence |
			matching_pr($prs) as $pr |
			(($issue.pr // {}) + $pr) as $pr_evidence |
			(($pr_evidence | length) > 0 or has_status("in-review")) as $has_pr_assumption |
			(($pr_evidence.merged // false) == true or ($merged_lookup | contains("|" + ($number | tostring) + "="))) as $merged |
			(($pr_evidence.checks // $pr_evidence.check_status // "") | ascii_downcase) as $checks |
			(($issue.authority_required // false) == true or has_label("needs-maintainer-review")) as $authority |
			(($issue.dependency_blocked // false) == true or has_label("blocked") or has_label("status:blocked")) as $dependency_blocked |
			(($issue.dependency_resolved // false) == true) as $dependency_resolved |
			(($issue.lease_active // false) == true or (($issue.assignees // []) | length) > 0 or has_status("active")) as $lease |
			(($issue.process_active // false) == true) as $process |
			(($issue.recovery_attempt // 0) | tonumber) as $attempt |
			(($issue.recovery_comment_at // 0) | tonumber) as $recovery_comment |
			(($issue.subsequent_action_at // 0) | tonumber) as $subsequent_action |
			(if ($issue.state // "open" | ascii_downcase) == "closed" or $merged or has_status("done") then $state_completed
			 elif ($issue.cancelled // false) == true or has_label("status:cancelled") then $state_cancelled
			 elif ($issue.impossible // false) == true or has_label("status:impossible") then $state_impossible
			 elif $authority then "authority-blocked"
			 elif $dependency_blocked and ($dependency_resolved | not) then "dependency-blocked"
			 elif $has_pr_assumption then $state_review
			 elif $lease and $process then "actively owned"
			 else "actionable" end) as $objective_state |
			(if $merged and (($issue.state // "open" | ascii_downcase) != "closed") then "close_issue"
			 elif [$state_completed, $state_cancelled, $state_impossible] | index($objective_state) then $action_none
			 elif $authority then ladder($attempt; true)
			 elif $dependency_blocked and ($dependency_resolved | not) then "reverify_dependency"
			 elif $dependency_resolved then action_redispatch
			 elif $recovery_comment > 0 and $subsequent_action <= $recovery_comment then ladder($attempt; false)
			 elif $has_pr_assumption and (($pr_evidence | length) == 0) then action_recover_branch
			 elif ($checks == "fail" or $checks == $outcome_failed or $checks == "failure") and (($issue.repair_active // false) | not) then action_repair_pr
			 elif $lease and ($process | not) and (($issue.worktree_exists // false) == true) then action_resume
			 elif $lease and ($process | not) and (($issue.branch_exists // false) == true) then action_recover_branch
			 elif $lease and ($process | not) then action_redispatch
			 elif $objective_state == $state_review then "monitor_pr"
			 elif $objective_state == "actively owned" then "monitor_worker"
			 else "dispatch_objective" end) as $next_action |
			($evidence + $ttl) as $expiry |
			{
				repo: ($issue.repo // $repo),
				number: $number,
				objective_state: $objective_state,
				execution_path_state: ($issue.execution_path_state // (if $process then "running" elif $lease then "leased" elif $has_pr_assumption then "review" else "idle" end)),
				evidence_timestamp: $evidence,
				assumption_expires_at: $expiry,
				assumption_expired: (([$state_completed, $state_cancelled, $state_impossible] | index($objective_state) | not) and $expiry <= $now),
				next_action: $next_action,
				trigger_at: (if $next_action == $action_none then null else $expiry end),
				responsible_component: owner_for($next_action),
				recovery_attempt: $attempt,
				attempt_id: ($issue.attempt_id // ""),
				run_id: ($issue.run_id // ""),
				raw_result: ($issue.raw_result // ""),
				effective_outcome: ($issue.terminal_outcome // ""),
				preservation: {commits: ($issue.commits_preserved // false), logs: ($issue.logs_preserved // false),
					verification: ($issue.verification_preserved // false)}
			} |
			.unattended = (([$state_completed, $state_cancelled, $state_impossible] | index($objective_state) | not) and
				((.next_action == "" or .next_action == $action_none or .trigger_at == null or .responsible_component == "") or .assumption_expired))
		]'
	return $?
}

_objective_merge_state() {
	local derived_json="$1"
	local state_file="$2"
	local repo="$3"
	local now_epoch="$4"
	local max_repairs="$5"
	local state_dir=""
	local previous="$OBJECTIVE_EMPTY_STATE"
	local tmp_file=""
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || return 1
	if [[ -s "$state_file" ]]; then
		previous=$(jq -c '.' "$state_file" 2>/dev/null) || previous="$OBJECTIVE_EMPTY_STATE"
	fi
	tmp_file=$(mktemp "${state_file}.tmp.XXXXXX") || return 1
	jq -n \
		--arg repo "$repo" \
		--argjson now "$now_epoch" \
		--argjson max "$max_repairs" \
		--argjson previous "$previous" \
		--argjson current "$derived_json" '
		def plan: {objective_state, execution_path_state, evidence_timestamp, assumption_expires_at, next_action, trigger_at, responsible_component, attempt_id, run_id, raw_result, effective_outcome, preservation};
		($previous.objectives // []) as $old |
		[$current[] | . as $item | select(([$old[] | select(.repo == $item.repo and .number == $item.number) | plan] | first // null) != ($item | plan))] as $changed |
		{
			schema_version: 1,
			updated_at: $now,
			objectives: ([
				($old[] | select(.repo != $repo)),
				$current[]
			] | unique_by([.repo, .number]) | sort_by(.repo, .number)),
			repairs_applied: ($changed[:$max] | map({repo, number, next_action, responsible_component})),
			repairs_deferred: ([$changed[$max:][]? | {repo, number, next_action, responsible_component}])
		}' >"$tmp_file" || { rm -f "$tmp_file"; return 1; }
	mv "$tmp_file" "$state_file" || { rm -f "$tmp_file"; return 1; }
	return 0
}

_objective_summary() {
	local state_file="$1"
	if [[ ! -s "$state_file" ]]; then
		printf '{"total":0,"nonterminal":0,"objectives_without_next_action":0,"expired_assumptions":0,"oldest_unverified_assumption":null}\n'
		return 0
	fi
	jq -c --arg state_completed "$OBJECTIVE_STATE_COMPLETED" --arg state_cancelled "$OBJECTIVE_STATE_CANCELLED" \
		--arg state_impossible "$OBJECTIVE_STATE_IMPOSSIBLE" --arg action_none "$OBJECTIVE_SOURCE_NONE" '
		(.objectives // []) as $items |
		[$items[] | .objective_state as $state | select(([$state_completed, $state_cancelled, $state_impossible] | index($state)) == null)] as $open |
		{
			total: ($items | length),
			nonterminal: ($open | length),
			objectives_without_next_action: ([$open[] | select((.next_action // "") == "" or .next_action == $action_none or .trigger_at == null)] | length),
			expired_assumptions: ([$open[] | select(.assumption_expired == true)] | length),
			oldest_unverified_assumption: ([$open[] | select(.assumption_expired == true)] | sort_by(.evidence_timestamp) | first // null)
		}' "$state_file"
	return $?
}

main() {
	local command_name="${1:-help}"
	[[ $# -gt 0 ]] && shift
	local input_file="-"
	local repo=""
	local state_file="${AIDEVOPS_OBJECTIVE_STATE_FILE:-${HOME}/.aidevops/state/objective-reconciliation.json}"
	local now_epoch=""
	local ttl_secs="$OBJECTIVE_DEFAULT_TTL_SECS"
	local max_repairs="$OBJECTIVE_DEFAULT_MAX_REPAIRS"
	local issue_number=""
	local attempt_id=""
	local run_id=""
	local raw_result=""
	local outcome=""
	local status=""
	local classification=""
	local next_action=""
	local outcome_timestamp=""
	local attempt_started_at=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		shift
		case "$arg" in
		--input) [[ $# -gt 0 ]] || return 2; input_file="$1"; shift ;;
		--repo) [[ $# -gt 0 ]] || return 2; repo="$1"; shift ;;
		--state-file) [[ $# -gt 0 ]] || return 2; state_file="$1"; shift ;;
		--now) [[ $# -gt 0 ]] || return 2; now_epoch="$1"; shift ;;
		--ttl) [[ $# -gt 0 ]] || return 2; ttl_secs="$1"; shift ;;
		--max-repairs) [[ $# -gt 0 ]] || return 2; max_repairs="$1"; shift ;;
		--issue) [[ $# -gt 0 ]] || return 2; issue_number="$1"; shift ;;
		--attempt-id) [[ $# -gt 0 ]] || return 2; attempt_id="$1"; shift ;;
		--run-id) [[ $# -gt 0 ]] || return 2; run_id="$1"; shift ;;
		--raw-result) [[ $# -gt 0 ]] || return 2; raw_result="$1"; shift ;;
		--outcome) [[ $# -gt 0 ]] || return 2; outcome="$1"; shift ;;
		--status) [[ $# -gt 0 ]] || return 2; status="$1"; shift ;;
		--classification) [[ $# -gt 0 ]] || return 2; classification="$1"; shift ;;
		--next-action) [[ $# -gt 0 ]] || return 2; next_action="$1"; shift ;;
		--timestamp) [[ $# -gt 0 ]] || return 2; outcome_timestamp="$1"; shift ;;
		--attempt-started-at) [[ $# -gt 0 ]] || return 2; attempt_started_at="$1"; shift ;;
		--help | -h) _objective_usage; return 0 ;;
		*) printf 'ERROR: unknown option: %s\n' "$arg" >&2; return 2 ;;
		esac
	done
	[[ -n "$now_epoch" ]] || now_epoch=$(_objective_now)
	now_epoch=$(_objective_validate_uint "$now_epoch" 0)
	ttl_secs=$(_objective_validate_uint "$ttl_secs" 3600)
	max_repairs=$(_objective_validate_uint "$max_repairs" 25)
	case "$command_name" in
	help) _objective_usage; return 0 ;;
	summary) _objective_summary "$state_file"; return $? ;;
	record-outcome)
		[[ -n "$outcome_timestamp" ]] || outcome_timestamp="$now_epoch"
		[[ -n "$attempt_started_at" ]] || attempt_started_at="$outcome_timestamp"
		_objective_record_outcome "$repo" "$issue_number" "$attempt_id" "$run_id" \
			"$raw_result" "$outcome" "$status" "$classification" "$next_action" "$outcome_timestamp" "$attempt_started_at"
		return $?
		;;
	disposition)
		_objective_disposition "$repo" "$issue_number" "$attempt_id" "$state_file"
		return $?
		;;
	derive|reconcile)
		local input_json="" derived_json=""
		input_json=$(_objective_read_input "$input_file") || return $?
		input_json=$(_objective_attach_durable_evidence "$input_json" "$repo") || return $?
		derived_json=$(_objective_derive_json "$input_json" "$repo" "$now_epoch" "$ttl_secs") || return $?
		if [[ "$command_name" == "derive" ]]; then
			printf '%s\n' "$derived_json"
			return 0
		fi
		[[ -n "$repo" ]] || { printf 'ERROR: reconcile requires --repo\n' >&2; return 2; }
		_objective_merge_state "$derived_json" "$state_file" "$repo" "$now_epoch" "$max_repairs" || return $?
		_objective_summary "$state_file"
		return $?
		;;
	*) printf 'ERROR: unknown command: %s\n' "$command_name" >&2; _objective_usage >&2; return 2 ;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
