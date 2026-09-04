#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Cross-plane diagnosis and canary recovery for false-healthy GitHub Actions
# runner broker sessions. Diagnosis is read-only; repair is explicit and
# requires a locally configured restart adapter.

set -euo pipefail

BROKER_HEALTH_HELPER_DIR="${BROKER_HEALTH_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -r "${BROKER_HEALTH_HELPER_DIR}/shared-constants.sh" ]]; then
	source "${BROKER_HEALTH_HELPER_DIR}/shared-constants.sh" 2>/dev/null || true
fi

BROKER_HEALTH_REPO="${BROKER_HEALTH_REPO:-}"
BROKER_HEALTH_LABELS="${BROKER_HEALTH_LABELS:-self-hosted,Linux,X64,dind}"
BROKER_HEALTH_QUEUE_AGE_SECONDS="${BROKER_HEALTH_QUEUE_AGE_SECONDS:-900}"
BROKER_HEALTH_COOLDOWN_SECONDS="${BROKER_HEALTH_COOLDOWN_SECONDS:-1800}"
BROKER_HEALTH_VERIFY_DELAY_SECONDS="${BROKER_HEALTH_VERIFY_DELAY_SECONDS:-15}"
BROKER_HEALTH_CACHE_DIR="${BROKER_HEALTH_CACHE_DIR:-${HOME}/.aidevops/cache}"
BROKER_HEALTH_STATE_FILE="${BROKER_HEALTH_STATE_FILE:-${BROKER_HEALTH_CACHE_DIR}/github-runner-broker-health.json}"
BROKER_HEALTH_LOCK_DIR="${BROKER_HEALTH_LOCK_DIR:-${BROKER_HEALTH_CACHE_DIR}/github-runner-broker-health.lock}"
BROKER_HEALTH_RESTART_ADAPTER="${BROKER_HEALTH_RESTART_ADAPTER:-}"
BROKER_HEALTH_TEST_NOW_EPOCH="${BROKER_HEALTH_TEST_NOW_EPOCH:-}"
BROKER_HEALTH_ONLINE_STATUS="online"

_bh_now_epoch() {
	if [[ "${BROKER_HEALTH_TEST_NOW_EPOCH}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$BROKER_HEALTH_TEST_NOW_EPOCH"
	else
		date -u '+%s'
	fi
	return 0
}

_bh_require_tools() {
	local tool
	for tool in jq mktemp; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			printf 'UNKNOWN_LOCAL: required tool unavailable\n' >&2
			return 1
		fi
	done
	return 0
}

_bh_labels_json() {
	printf '%s' "$BROKER_HEALTH_LABELS" | tr ',' '\n' | jq -Rsc 'split("\n") | map(select(length > 0))'
	return 0
}

_bh_redacted_api() {
	local endpoint="$1"
	local output_file="$2"
	local error_file="$3"
	local jq_filter="${4:-.}"
	local pages_file="${output_file}.pages"
	if gh api --paginate --slurp "$endpoint" >"$pages_file" 2>"$error_file"; then
		if jq "$jq_filter" "$pages_file" >"$output_file" 2>"$error_file"; then
			rm -f "$pages_file"
			return 0
		fi
	fi
	rm -f "$pages_file"
	if grep -Eqi '403|forbidden|permission|resource not accessible|authentication' "$error_file"; then
		printf 'permission\n'
	else
		printf 'network\n'
	fi
	return 1
}

_bh_collect_jobs_live() {
	local output_file="$1"
	local work_dir="$2"
	local runs_file="${work_dir}/runs.json"
	local queued_runs_file="${work_dir}/runs-queued.json"
	local active_runs_file="${work_dir}/runs-active.json"
	local error_file="${work_dir}/runs.err"
	local failure=""
	local run_id
	[[ "$BROKER_HEALTH_REPO" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || {
		printf 'permission\n'
		return 1
	}
	failure=$(_bh_redacted_api "repos/${BROKER_HEALTH_REPO}/actions/runs?status=queued&per_page=100" "$queued_runs_file" "$error_file" '{workflow_runs: map(.workflow_runs[]) }' || true)
	[[ -z "$failure" ]] || {
		printf '%s\n' "$failure"
		return 1
	}
	failure=$(_bh_redacted_api "repos/${BROKER_HEALTH_REPO}/actions/runs?status=in_progress&per_page=100" "$active_runs_file" "$error_file" '{workflow_runs: map(.workflow_runs[]) }' || true)
	[[ -z "$failure" ]] || {
		printf '%s\n' "$failure"
		return 1
	}
	jq -n --slurpfile queued "$queued_runs_file" --slurpfile active "$active_runs_file" \
		'{workflow_runs: (($queued[0].workflow_runs + $active[0].workflow_runs) | unique_by(.id))}' >"$runs_file"
	printf '{"jobs":[' >"$output_file"
	local first=1
	while IFS= read -r run_id; do
		local jobs_file="${work_dir}/jobs-${run_id}.json"
		local jobs_error="${work_dir}/jobs-${run_id}.err"
		failure=$(_bh_redacted_api "repos/${BROKER_HEALTH_REPO}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" "$jobs_file" "$jobs_error" '{jobs: map(.jobs[]) }' || true)
		[[ -z "$failure" ]] || {
			printf '%s\n' "$failure"
			return 1
		}
		while IFS= read -r job; do
			[[ "$first" -eq 1 ]] || printf ',' >>"$output_file"
			printf '%s' "$job" >>"$output_file"
			first=0
		done < <(jq -c '.jobs[] | select(.status == "queued") | {id, status, labels, runner_id, runner_name, created_at}' "$jobs_file")
	done < <(jq -r '.workflow_runs[].id' "$runs_file")
	printf ']}\n' >>"$output_file"
	return 0
}

_bh_collect_runners_live() {
	local output_file="$1"
	local work_dir="$2"
	local error_file="${work_dir}/runners.err"
	local failure=""
	failure=$(_bh_redacted_api "repos/${BROKER_HEALTH_REPO}/actions/runners?per_page=100" "$output_file" "$error_file" '{runners: map(.runners[]) }' || true)
	[[ -z "$failure" ]] || {
		printf '%s\n' "$failure"
		return 1
	}
	return 0
}

_bh_collect_local_live() {
	local output_file="$1"
	local units=""
	if ! command -v systemctl >/dev/null 2>&1; then
		printf 'local\n'
		return 1
	fi
	units=$(systemctl list-units --type=service --all --no-legend --no-pager 'github-runner*' 2>/dev/null || true)
	printf '%s\n' "$units" | jq -Rsc '
		{runners: (split("\n") | map(select(length > 0)) | map(
			(split(" ") | map(select(length > 0))) as $f |
			{name: ($f[0] | sub("\\.service$"; "") | sub("@"; "-")), service: $f[0], active: ($f[2] == "active"), listener: ($f[3] == "running")}
		))}' >"$output_file"
	return 0
}

_bh_collect() {
	local phase="$1"
	local output_dir="$2"
	local jobs_source="${BROKER_HEALTH_JOBS_FILE:-}"
	local runners_source="${BROKER_HEALTH_RUNNERS_FILE:-}"
	local local_source="${BROKER_HEALTH_LOCAL_FILE:-}"
	if [[ "$phase" == "post" ]]; then
		jobs_source="${BROKER_HEALTH_POST_JOBS_FILE:-$jobs_source}"
		runners_source="${BROKER_HEALTH_POST_RUNNERS_FILE:-$runners_source}"
		local_source="${BROKER_HEALTH_POST_LOCAL_FILE:-$local_source}"
	fi
	mkdir -p "$output_dir"
	if [[ -n "$jobs_source" ]]; then
		cp "$jobs_source" "${output_dir}/jobs.json"
	else
		local failure=""
		failure=$(_bh_collect_jobs_live "${output_dir}/jobs.json" "$output_dir" || true)
		[[ -z "$failure" ]] || {
			printf 'UNKNOWN_%s\n' "$(printf '%s' "$failure" | tr '[:lower:]' '[:upper:]')"
			return 1
		}
	fi
	if [[ -n "$runners_source" ]]; then
		cp "$runners_source" "${output_dir}/runners.json"
	else
		local failure=""
		failure=$(_bh_collect_runners_live "${output_dir}/runners.json" "$output_dir" || true)
		[[ -z "$failure" ]] || {
			printf 'UNKNOWN_%s\n' "$(printf '%s' "$failure" | tr '[:lower:]' '[:upper:]')"
			return 1
		}
	fi
	if [[ -n "$local_source" ]]; then
		cp "$local_source" "${output_dir}/local.json"
	else
		local failure=""
		failure=$(_bh_collect_local_live "${output_dir}/local.json" || true)
		[[ -z "$failure" ]] || {
			printf 'UNKNOWN_LOCAL\n'
			return 1
		}
	fi
	return 0
}

_bh_evidence() {
	local input_dir="$1"
	local output_file="$2"
	local now labels
	now=$(_bh_now_epoch)
	labels=$(_bh_labels_json)
	jq -n \
		--slurpfile jobs "${input_dir}/jobs.json" \
		--slurpfile runners "${input_dir}/runners.json" \
		--slurpfile local "${input_dir}/local.json" \
		--argjson required "$labels" \
		--arg online "$BROKER_HEALTH_ONLINE_STATUS" \
		--argjson now "$now" \
		--argjson age "$BROKER_HEALTH_QUEUE_AGE_SECONDS" '
		def names($labels): [$labels[]? | if type == "object" then .name else . end];
		[$jobs[0].jobs[]? | select(.status == "queued") |
		 . + {label_names: names(.labels), created_epoch: (.created_at | fromdateiso8601? // 0)} |
		 select(($required - .label_names | length) == 0) |
		 select(.created_epoch > 0 and ($now - .created_epoch) >= $age) |
		 select((.runner_id // 0) == 0 and (.runner_name // "") == "")] as $old_jobs |
		[$runners[0].runners[]? | . + {label_names: names(.labels)} |
		 select(($required - .label_names | length) == 0)] as $configured |
		[$configured[] | . as $runner |
		 select(any($old_jobs[]; .label_names as $job_labels |
			($job_labels - $runner.label_names | length) == 0))] as $matching |
		[$matching[] | select(.status == $online and .busy == true)] as $busy |
		[$matching[] | select(.status == $online and .busy == false)] as $idle |
		[$local[0].runners[]? | select(.active == true and .listener == true)] as $local_active |
		[$idle[] as $r | $local_active[] | select(.name == $r.name or .runner_name == $r.name) |
		 {name: $r.name, runner_id: ($r.id // 0), service: (.service // "")}] as $candidates |
		{old_jobs: $old_jobs, runners: $configured, matching: $matching, busy: $busy, idle: $idle,
		 local_active: $local_active, candidates: ($candidates | unique_by(.name)),
		 queue_moving: (($jobs[0].queue_moving // false) == true)}' >"$output_file"
	return 0
}

_bh_classify() {
	local evidence_file="$1"
	local old_count matching_count busy_count candidate_count queue_moving
	old_count=$(jq '.old_jobs | length' "$evidence_file")
	matching_count=$(jq '.matching | length' "$evidence_file")
	busy_count=$(jq '.busy | length' "$evidence_file")
	candidate_count=$(jq '.candidates | length' "$evidence_file")
	queue_moving=$(jq -r '.queue_moving' "$evidence_file")
	if [[ "$old_count" -eq 0 || "$queue_moving" == "true" ]]; then
		printf 'HEALTHY\n'
	elif [[ "$matching_count" -eq 0 ]]; then
		printf 'NO_MATCHING_RUNNER\n'
	elif [[ "$busy_count" -eq "$matching_count" ]]; then
		printf 'BUSY_CAPACITY\n'
	elif [[ "$candidate_count" -gt 0 ]]; then
		printf 'STALE_BROKER_SUSPECTED\n'
	else
		printf 'UNKNOWN_LOCAL\n'
	fi
	return 0
}

_bh_emit() {
	local finding="$1"
	local evidence_file="${2:-}"
	local json="${3:-0}"
	local action="none"
	case "$finding" in
	STALE_BROKER_SUSPECTED) action="run repair only with an approved local restart adapter" ;;
	BUSY_CAPACITY) action="add capacity or wait for active jobs; do not restart" ;;
	NO_MATCHING_RUNNER) action="check labels and runner registration; do not restart" ;;
	UNKNOWN_PERMISSION) action="grant read access to Actions jobs and runners; do not restart" ;;
	UNKNOWN_NETWORK) action="restore GitHub API access; do not restart" ;;
	UNKNOWN_LOCAL) action="restore local runner visibility; do not restart" ;;
	COOLDOWN) action="wait for the recovery cooldown; do not restart" ;;
	LOCKED) action="another recovery owns the host lock; do not restart" ;;
	RECOVERED) action="queue movement verified after one fresh runner registration" ;;
	FAILED_CANARY) action="inspect the canary; do not restart another runner" ;;
	esac
	if [[ "$json" -eq 1 ]]; then
		local summary='{}'
		[[ -n "$evidence_file" && -f "$evidence_file" ]] && summary=$(jq '{old_jobs:(.old_jobs|length), matching_runners:(.matching|length), busy_runners:(.busy|length), idle_candidates:(.candidates|length)}' "$evidence_file")
		jq -n --arg finding "$finding" --arg action "$action" --argjson evidence "$summary" '{finding:$finding, action:$action, evidence:$evidence}'
	else
		printf 'finding: %s\naction: %s\n' "$finding" "$action"
		if [[ -n "$evidence_file" && -f "$evidence_file" ]]; then
			jq -r '"evidence: old_jobs=\(.old_jobs|length) matching_runners=\(.matching|length) busy_runners=\(.busy|length) idle_candidates=\(.candidates|length)"' "$evidence_file"
		fi
	fi
	return 0
}

_bh_diagnose_into() {
	local phase="$1"
	local work_dir="$2"
	local evidence_file="$3"
	local failure=""
	failure=$(_bh_collect "$phase" "${work_dir}/${phase}" || true)
	if [[ -n "$failure" ]]; then
		printf '%s\n' "$failure"
		return 1
	fi
	_bh_evidence "${work_dir}/${phase}" "$evidence_file"
	_bh_classify "$evidence_file"
	return 0
}

_bh_in_cooldown() {
	local now last
	[[ -f "$BROKER_HEALTH_STATE_FILE" ]] || return 1
	now=$(_bh_now_epoch)
	last=$(jq -r '.last_restart_epoch // 0' "$BROKER_HEALTH_STATE_FILE" 2>/dev/null || printf '0')
	[[ "$last" =~ ^[0-9]+$ ]] || last=0
	if [[ $((now - last)) -lt "$BROKER_HEALTH_COOLDOWN_SECONDS" ]]; then
		return 0
	fi
	return 1
}

_bh_write_state() {
	local candidate="$1"
	local outcome="$2"
	local now tmp
	now=$(_bh_now_epoch)
	mkdir -p "$BROKER_HEALTH_CACHE_DIR"
	tmp="${BROKER_HEALTH_STATE_FILE}.tmp.$$"
	jq -n --argjson epoch "$now" --arg candidate "$candidate" --arg outcome "$outcome" \
		'{schema:1,last_restart_epoch:$epoch,candidate:$candidate,outcome:$outcome}' >"$tmp"
	mv "$tmp" "$BROKER_HEALTH_STATE_FILE"
	return 0
}

_bh_verify_canary() {
	local before="$1"
	local after="$2"
	local candidate="$3"
	local old_id new_id old_jobs new_jobs
	old_id=$(jq -r --arg name "$candidate" '.runners[] | select(.name == $name) | .id // 0' "$before" | sed -n '1p')
	new_id=$(jq -r --arg name "$candidate" --arg online "$BROKER_HEALTH_ONLINE_STATUS" \
		'.runners[] | select(.name == $name and .status == $online) | .id // 0' "$after" | sed -n '1p')
	old_jobs=$(jq '.old_jobs | length' "$before")
	new_jobs=$(jq '.old_jobs | length' "$after")
	if [[ "${old_id:-0}" != "${new_id:-0}" && "${new_id:-0}" != "0" && "$new_jobs" -lt "$old_jobs" ]]; then
		return 0
	fi
	return 1
}

cmd_diagnose() {
	local json="${1:-0}"
	local work_dir evidence finding
	work_dir=$(mktemp -d -t broker-health-XXXXXX)
	evidence="${work_dir}/evidence.json"
	finding=$(_bh_diagnose_into pre "$work_dir" "$evidence" || true)
	_bh_emit "$finding" "$evidence" "$json"
	rm -rf "$work_dir"
	[[ "$finding" == "HEALTHY" ]] && return 0
	return 1
}

cmd_repair() {
	local json="${1:-0}"
	local work_dir before after finding candidate
	work_dir=$(mktemp -d -t broker-health-XXXXXX)
	before="${work_dir}/before.json"
	after="${work_dir}/after.json"
	finding=$(_bh_diagnose_into pre "$work_dir" "$before" || true)
	if [[ "$finding" != "STALE_BROKER_SUSPECTED" ]]; then
		_bh_emit "$finding" "$before" "$json"
		rm -rf "$work_dir"
		return 1
	fi
	mkdir -p "$BROKER_HEALTH_CACHE_DIR"
	if ! mkdir "$BROKER_HEALTH_LOCK_DIR" 2>/dev/null; then
		_bh_emit LOCKED "$before" "$json"
		rm -rf "$work_dir"
		return 1
	fi
	trap 'rmdir "$BROKER_HEALTH_LOCK_DIR" 2>/dev/null || true; rm -rf "$work_dir"' EXIT
	if _bh_in_cooldown; then
		_bh_emit COOLDOWN "$before" "$json"
		return 1
	fi
	# Re-read both planes after taking the host lock.
	finding=$(_bh_diagnose_into pre "$work_dir" "$before" || true)
	if [[ "$finding" != "STALE_BROKER_SUSPECTED" ]]; then
		_bh_emit "$finding" "$before" "$json"
		return 1
	fi
	candidate=$(jq -r '.candidates | sort_by(.name) | .[0].name // empty' "$before")
	if [[ -z "$candidate" || -z "$BROKER_HEALTH_RESTART_ADAPTER" || ! -x "$BROKER_HEALTH_RESTART_ADAPTER" ]]; then
		_bh_emit UNKNOWN_LOCAL "$before" "$json"
		return 1
	fi
	_bh_write_state "$candidate" "started"
	if ! "$BROKER_HEALTH_RESTART_ADAPTER" "$candidate" >/dev/null 2>&1; then
		_bh_write_state "$candidate" "restart_failed"
		_bh_emit FAILED_CANARY "$before" "$json"
		return 1
	fi
	if [[ "$BROKER_HEALTH_VERIFY_DELAY_SECONDS" -gt 0 ]]; then
		sleep "$BROKER_HEALTH_VERIFY_DELAY_SECONDS"
	fi
	finding=$(_bh_diagnose_into post "$work_dir" "$after" || true)
	if [[ "$finding" == UNKNOWN_* ]] || ! _bh_verify_canary "$before" "$after" "$candidate"; then
		_bh_write_state "$candidate" "verification_failed"
		_bh_emit FAILED_CANARY "$after" "$json"
		return 1
	fi
	_bh_write_state "$candidate" "recovered"
	_bh_emit RECOVERED "$after" "$json"
	return 0
}

usage() {
	cat <<'EOF'
Usage: github-runner-broker-health-helper.sh diagnose [--json]
       github-runner-broker-health-helper.sh repair [--json]

Diagnosis correlates old compatible unassigned jobs, GitHub runner state, and
local active listener state. Repair requires BROKER_HEALTH_RESTART_ADAPTER to
name an executable that accepts exactly one runner name. At most one candidate
is restarted, followed by fresh-registration and queue-movement verification.
EOF
	return 0
}

main() {
	local command="${1:-diagnose}"
	local option="${2:-}"
	local json=0
	[[ "$option" == "--json" ]] && json=1
	_bh_require_tools || return 1
	case "$command" in
	diagnose) cmd_diagnose "$json" ;;
	repair) cmd_repair "$json" ;;
	help | --help | -h) usage ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
