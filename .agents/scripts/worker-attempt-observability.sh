#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Worker-attempt log correlation and durable last-stage checkpoints.

[[ -n "${_WORKER_ATTEMPT_OBSERVABILITY_LOADED:-}" ]] && return 0
_WORKER_ATTEMPT_OBSERVABILITY_LOADED=1

_wao_script_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=shared-constants.sh
source "${_wao_script_dir}/shared-constants.sh"
unset _wao_script_dir

_WAO_LIFECYCLE_MARKER='[lifecycle]'
_WAO_EXIT_MARKER='[exit-trap]'
_WAO_FIELD_SEPARATOR=$'\034'
_WAO_UNKNOWN='unknown'
_WAO_EXIT_PATH_RUNNING='running'
_WAO_STATE_SCHEMA='aidevops-worker-attempt/v1'
_WAO_LOCK_RETRIES=20
_WAO_LOCK_STALE_SECONDS=30

_wao_timestamp() {
	date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown'
	return 0
}

_wao_start_marker() {
	local marker=""
	marker=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || true)
	if [[ ! "$marker" =~ ^[0-9]{19}$ ]]; then
		marker="$(date +%s 2>/dev/null || printf '0')000000000"
	fi
	printf '%s' "$marker"
	return 0
}

_wao_ensure_identity() {
	local epoch=""
	if [[ ! "${AIDEVOPS_ATTEMPT_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]]; then
		if declare -F aidevops_generate_execution_id >/dev/null 2>&1; then
			AIDEVOPS_ATTEMPT_ID=$(aidevops_generate_execution_id attempt)
		else
			epoch=$(date +%s 2>/dev/null || printf '0')
			AIDEVOPS_ATTEMPT_ID="attempt:${epoch}:$$:${RANDOM:-0}"
		fi
	fi
	if [[ ! "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]+$ ]]; then
		AIDEVOPS_ATTEMPT_STARTED_AT=$(_wao_start_marker)
	fi
	export AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT
	return 0
}

_wao_safe_token() {
	local value="$1"
	local fallback="${2:-$_WAO_UNKNOWN}"
	if [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9._:-]{0,159}$ ]]; then
		printf '%s' "$value"
	else
		printf '%s' "$fallback"
	fi
	return 0
}

_wao_acquire_state_lock() {
	local output_var="$1"
	local state_file="$2"
	local candidate_lock_dir="${state_file}.lock"
	local attempt=0
	while [[ "$attempt" -lt "$_WAO_LOCK_RETRIES" ]]; do
		if mkdir "$candidate_lock_dir" 2>/dev/null; then
			chmod 700 "$candidate_lock_dir" 2>/dev/null || true
			printf -v "$output_var" '%s' "$candidate_lock_dir"
			return 0
		fi
		_wao_reclaim_stale_state_lock "$candidate_lock_dir" || true
		attempt=$((attempt + 1))
		sleep 0.01
	done
	return 1
}

_wao_reclaim_stale_state_lock() {
	local lock_dir="$1"
	local modified_at=""
	local now_epoch=""
	local lock_age=""
	[[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
	declare -F _file_mtime_epoch >/dev/null 2>&1 || return 1
	modified_at=$(_file_mtime_epoch "$lock_dir" 2>/dev/null) || modified_at=""
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=""
	[[ "$modified_at" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ ]] || return 1
	lock_age=$((now_epoch - modified_at))
	[[ "$lock_age" -ge "$_WAO_LOCK_STALE_SECONDS" ]] || return 1
	rmdir "$lock_dir" 2>/dev/null || return 1
	return 0
}

_wao_release_state_lock() {
	local lock_dir="$1"
	[[ -n "$lock_dir" ]] || return 0
	rmdir "$lock_dir" 2>/dev/null || true
	return 0
}

_wao_state_path() {
	local state_file="${AIDEVOPS_ATTEMPT_STATE_FILE:-}"
	local state_root="${AIDEVOPS_ATTEMPT_STATE_ROOT:-${HOME}/.aidevops/.agent-workspace/pr-review-thread-response}"
	local state_parent=""
	local resolved_root=""
	local resolved_parent=""

	[[ -n "$state_file" && "$state_file" == /* && "$state_root" == /* ]] || return 1
	case "${state_file##*/}" in
	*.attempt.json) ;;
	*) return 1 ;;
	esac
	case "$state_file" in
	"$state_root"/*) ;;
	*) return 1 ;;
	esac
	state_parent="${state_file%/*}"
	[[ -d "$state_root" && -d "$state_parent" && ! -L "$state_file" ]] || return 1
	resolved_root=$(cd "$state_root" 2>/dev/null && pwd -P) || return 1
	resolved_parent=$(cd "$state_parent" 2>/dev/null && pwd -P) || return 1
	case "$resolved_parent" in
	"$resolved_root" | "$resolved_root"/*) ;;
	*) return 1 ;;
	esac
	if [[ -e "$state_file" && ! -f "$state_file" ]]; then
		return 1
	fi
	printf '%s' "$state_file"
	return 0
}

_wao_read_previous_state() {
	local state_file="$1"
	local previous_line=""
	_WAO_PREVIOUS_LIFECYCLE="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_COMPLETED="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_SESSION="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_EXIT_PATH="$_WAO_EXIT_PATH_RUNNING"
	_WAO_PREVIOUS_REASON="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_LOGGED_PID="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_STATUS="$_WAO_UNKNOWN"
	_WAO_PREVIOUS_ATTEMPT_ID="$_WAO_UNKNOWN"
	[[ -s "$state_file" ]] || return 0
	previous_line=$(jq -r --arg unknown "$_WAO_UNKNOWN" --arg running "$_WAO_EXIT_PATH_RUNNING" '
		[
			(.last_lifecycle_stage // $unknown),
			(.last_completed_stage // $unknown),
			(.session_key // $unknown),
			(.exit_path // $running),
			(.reason // $unknown),
			(.logged_pid // $unknown),
			(.status // $unknown),
			(.attempt_id // $unknown)
		] | join("\u001c")
	' "$state_file" 2>/dev/null) || return 0
	IFS="$_WAO_FIELD_SEPARATOR" read -r \
		_WAO_PREVIOUS_LIFECYCLE _WAO_PREVIOUS_COMPLETED _WAO_PREVIOUS_SESSION \
		_WAO_PREVIOUS_EXIT_PATH _WAO_PREVIOUS_REASON _WAO_PREVIOUS_LOGGED_PID \
		_WAO_PREVIOUS_STATUS _WAO_PREVIOUS_ATTEMPT_ID <<<"$previous_line"
	return 0
}

_wao_parse_event() {
	local message="$1"
	local payload=""
	_WAO_EVENT_CATEGORY=""
	_WAO_EVENT_STAGE="$_WAO_UNKNOWN"
	_WAO_EVENT_SESSION=""
	_WAO_EVENT_REASON=""
	_WAO_EVENT_LOGGED_PID=""
	_WAO_EVENT_STATUS=""

	if [[ "$message" == "${_WAO_LIFECYCLE_MARKER}"* ]]; then
		_WAO_EVENT_CATEGORY='lifecycle'
		payload="${message#"$_WAO_LIFECYCLE_MARKER"}"
	elif [[ "$message" == "${_WAO_EXIT_MARKER}"* ]]; then
		_WAO_EVENT_CATEGORY='exit-trap'
		payload="${message#"$_WAO_EXIT_MARKER"}"
	else
		return 1
	fi
	payload="${payload# }"
	_WAO_EVENT_STAGE="${payload%% *}"
	[[ -n "$_WAO_EVENT_STAGE" ]] || _WAO_EVENT_STAGE="$_WAO_UNKNOWN"
	if [[ "$message" =~ session=([^[:space:]]+) ]]; then
		_WAO_EVENT_SESSION="${BASH_REMATCH[1]}"
	fi
	if [[ "$message" =~ reason=([^[:space:]]+) ]]; then
		_WAO_EVENT_REASON="${BASH_REMATCH[1]}"
	fi
	if [[ "$message" =~ pid=([0-9]+) ]]; then
		_WAO_EVENT_LOGGED_PID="${BASH_REMATCH[1]}"
	fi
	if [[ "$message" =~ rc=([0-9]+) ]]; then
		_WAO_EVENT_STATUS="${BASH_REMATCH[1]}"
	elif [[ "$message" =~ exit=([0-9]+) ]]; then
		_WAO_EVENT_STATUS="${BASH_REMATCH[1]}"
	elif [[ "$message" =~ wait_status=([0-9]+) ]]; then
		_WAO_EVENT_STATUS="${BASH_REMATCH[1]}"
	fi
	_WAO_EVENT_STAGE=$(_wao_safe_token "$_WAO_EVENT_STAGE")
	[[ -z "$_WAO_EVENT_SESSION" ]] || _WAO_EVENT_SESSION=$(_wao_safe_token "$_WAO_EVENT_SESSION")
	[[ -z "$_WAO_EVENT_REASON" ]] || _WAO_EVENT_REASON=$(_wao_safe_token "$_WAO_EVENT_REASON")
	return 0
}

_wao_stage_is_completed() {
	local stage="$1"
	case "$stage" in
	prrts_dispatch_ready | post_* | *_done | worker_start | invoke_returned | exit_code_read | worker_exited | \
		calling_handle_run_result | handle_run_result_returned | rate_limit_fast_exit | \
		worker_failure_evidence)
		return 0
		;;
	esac
	return 1
}

_wao_checkpoint() {
	local message="$1"
	local timestamp="$2"
	local state_file=""
	local last_lifecycle=""
	local last_completed=""
	local session_key=""
	local exit_path=""
	local reason=""
	local logged_pid=""
	local status=""
	local run_id=""
	local temp_file=""
	local previous_umask=""
	local lock_dir=""

	state_file=$(_wao_state_path 2>/dev/null) || return 0
	command -v jq >/dev/null 2>&1 || return 0
	_wao_parse_event "$message" || return 0
	_wao_acquire_state_lock lock_dir "$state_file" || return 0
	_wao_read_previous_state "$state_file"
	if [[ "$_WAO_PREVIOUS_ATTEMPT_ID" != "$_WAO_UNKNOWN" && \
		"$_WAO_PREVIOUS_ATTEMPT_ID" != "${AIDEVOPS_ATTEMPT_ID:-}" ]]; then
		_wao_release_state_lock "$lock_dir"
		return 0
	fi
	last_lifecycle="$_WAO_PREVIOUS_LIFECYCLE"
	last_completed="$_WAO_PREVIOUS_COMPLETED"
	session_key="${_WAO_EVENT_SESSION:-$_WAO_PREVIOUS_SESSION}"
	exit_path="$_WAO_PREVIOUS_EXIT_PATH"
	reason="${_WAO_EVENT_REASON:-$_WAO_PREVIOUS_REASON}"
	logged_pid="${_WAO_EVENT_LOGGED_PID:-$_WAO_PREVIOUS_LOGGED_PID}"
	status="${_WAO_EVENT_STATUS:-$_WAO_PREVIOUS_STATUS}"
	run_id=$(_wao_safe_token "${AIDEVOPS_RUN_ID:-}" "$_WAO_UNKNOWN")
	if [[ "$_WAO_EVENT_CATEGORY" == 'lifecycle' ]]; then
		last_lifecycle="$_WAO_EVENT_STAGE"
		if _wao_stage_is_completed "$_WAO_EVENT_STAGE"; then
			last_completed="$_WAO_EVENT_STAGE"
		fi
	elif [[ "$_WAO_EVENT_CATEGORY" == 'exit-trap' ]]; then
		exit_path="${_WAO_EVENT_REASON:-$_WAO_EVENT_STAGE}"
	fi

	previous_umask=$(umask)
	umask 077
	temp_file=$(mktemp "${state_file}.tmp.XXXXXX" 2>/dev/null) || temp_file=""
	umask "$previous_umask"
	if [[ -z "$temp_file" ]]; then
		_wao_release_state_lock "$lock_dir"
		return 0
	fi
	if ! jq -nc \
		--arg schema "$_WAO_STATE_SCHEMA" \
		--arg attempt_id "${AIDEVOPS_ATTEMPT_ID:-$_WAO_UNKNOWN}" \
		--arg run_id "$run_id" \
		--arg attempt_started_at "${AIDEVOPS_ATTEMPT_STARTED_AT:-0}" \
		--arg updated_at "$timestamp" \
		--arg last_event_category "$_WAO_EVENT_CATEGORY" \
		--arg last_event "$_WAO_EVENT_STAGE" \
		--arg last_lifecycle_stage "$last_lifecycle" \
		--arg last_completed_stage "$last_completed" \
		--arg emitter_pid "$$" \
		--arg logged_pid "$logged_pid" \
		--arg status "$status" \
		--arg session_key "$session_key" \
		--arg exit_path "$exit_path" \
		--arg reason "$reason" \
		'{schema:$schema,attempt_id:$attempt_id,run_id:$run_id,attempt_started_at:$attempt_started_at,updated_at:$updated_at,last_event_category:$last_event_category,last_event:$last_event,last_lifecycle_stage:$last_lifecycle_stage,last_completed_stage:$last_completed_stage,emitter_pid:$emitter_pid,logged_pid:$logged_pid,status:$status,session_key:$session_key,exit_path:$exit_path,reason:$reason}' \
		>"$temp_file" 2>/dev/null; then
		rm -f "$temp_file"
		_wao_release_state_lock "$lock_dir"
		return 0
	fi
	if ! mv -f "$temp_file" "$state_file" 2>/dev/null; then
		rm -f "$temp_file"
		_wao_release_state_lock "$lock_dir"
		return 0
	fi
	chmod 600 "$state_file" 2>/dev/null || true
	_wao_release_state_lock "$lock_dir"
	return 0
}

worker_attempt_observability_enrich() {
	local output_var="$1"
	local input_message="$2"
	local enriched_message="$input_message"
	local timestamp=""

	_wao_parse_event "$input_message" || {
		printf -v "$output_var" '%s' "$input_message"
		return 0
	}
	_wao_ensure_identity
	timestamp=$(_wao_timestamp)
	if [[ "$enriched_message" != *' ts='* ]]; then
		enriched_message="${enriched_message} ts=${timestamp}"
	fi
	if [[ "$enriched_message" != *' attempt_id='* ]]; then
		enriched_message="${enriched_message} attempt_id=${AIDEVOPS_ATTEMPT_ID}"
	fi
	_wao_checkpoint "$enriched_message" "$timestamp" || true
	printf -v "$output_var" '%s' "$enriched_message"
	return 0
}

worker_attempt_observability_print() {
	local level="$1"
	local message="$2"
	local enriched=""
	worker_attempt_observability_enrich enriched "$message"
	case "$level" in
	error)
		if declare -F print_shared_error >/dev/null 2>&1; then
			print_shared_error "$enriched"
		else
			printf '[ERROR] %s\n' "$enriched" >&2
		fi
		;;
	warning)
		if declare -F print_shared_warning >/dev/null 2>&1; then
			print_shared_warning "$enriched"
		else
			printf '[WARNING] %s\n' "$enriched" >&2
		fi
		;;
	*)
		if declare -F print_shared_info >/dev/null 2>&1; then
			print_shared_info "$enriched"
		else
			printf '[INFO] %s\n' "$enriched" >&2
		fi
		;;
	esac
	return 0
}

worker_attempt_observability_initialize() (
	local state_root="$1"
	local state_file="$2"
	local attempt_id="$3"
	local session_key="$4"
	local ignored=""
	[[ "$attempt_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
	export AIDEVOPS_ATTEMPT_ID="$attempt_id"
	export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
	export AIDEVOPS_ATTEMPT_STATE_FILE="$state_file"
	unset AIDEVOPS_RUN_ID AIDEVOPS_ATTEMPT_STARTED_AT 2>/dev/null || true
	worker_attempt_observability_enrich ignored \
		"[lifecycle] prrts_dispatch_ready session=${session_key} pid=$$"
	[[ -s "$state_file" ]] || return 1
	worker_attempt_observability_state_matches_identity \
		"$state_root" "$state_file" "$attempt_id" || return 1
	return 0
)

worker_attempt_observability_state_matches_identity() (
	local state_root="$1"
	local state_file="$2"
	local attempt_id="$3"
	local resolved_state=""
	[[ "$attempt_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
	export AIDEVOPS_ATTEMPT_STATE_ROOT="$state_root"
	export AIDEVOPS_ATTEMPT_STATE_FILE="$state_file"
	resolved_state=$(_wao_state_path 2>/dev/null) || return 1
	[[ -s "$resolved_state" ]] || return 1
	jq -e --arg schema "$_WAO_STATE_SCHEMA" --arg attempt_id "$attempt_id" \
		'.schema == $schema and .attempt_id == $attempt_id' \
		"$resolved_state" >/dev/null 2>&1 || return 1
	return 0
)

worker_attempt_observability_binding_is_safe() (
	local state_root="$1"
	local state_file="$2"
	local outcome_file="$3"
	local attempt_id="$4"
	local session_key="$5"
	local outcome_parent=""
	local resolved_root=""
	local resolved_parent=""
	local value=""

	for value in "$state_root" "$state_file" "$outcome_file" "$attempt_id" "$session_key"; do
		[[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* && \
			"$value" != *$'\t'* && "$value" != *"$_WAO_FIELD_SEPARATOR"* ]] || return 1
	done
	[[ "$state_root" == /* && "$outcome_file" == /* && ! -L "$state_root" && ! -L "$outcome_file" ]] || return 1
	[[ -O "$state_root" && -O "$state_file" ]] || return 1
	case "${outcome_file##*/}" in
	*.outcome) ;;
	*) return 1 ;;
	esac
	case "$outcome_file" in
	"$state_root"/*) ;;
	*) return 1 ;;
	esac
	outcome_parent="${outcome_file%/*}"
	[[ -d "$outcome_parent" && ! -L "$outcome_parent" && -O "$outcome_parent" ]] || return 1
	resolved_root=$(cd "$state_root" 2>/dev/null && pwd -P) || return 1
	resolved_parent=$(cd "$outcome_parent" 2>/dev/null && pwd -P) || return 1
	case "$resolved_parent" in
	"$resolved_root" | "$resolved_root"/*) ;;
	*) return 1 ;;
	esac
	if [[ -e "$outcome_file" && (! -f "$outcome_file" || ! -O "$outcome_file") ]]; then
		return 1
	fi
	worker_attempt_observability_state_matches_identity \
		"$state_root" "$state_file" "$attempt_id" || return 1
	jq -e --arg session_key "$session_key" \
		'(.session_key // "") == $session_key' "$state_file" >/dev/null 2>&1 || return 1
	return 0
)

_wao_outcome_value() {
	local outcome_file="$1"
	local expected_key="$2"
	local key=""
	local value=""
	[[ -f "$outcome_file" ]] || return 0
	while IFS='=' read -r key value; do
		if [[ "$key" == "$expected_key" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done <"$outcome_file"
	return 0
}

worker_attempt_observability_finalize_abandoned() (
	local state_root="$1"
	local state_file="$2"
	local outcome_file="$3"
	local attempt_id="$4"
	local session_key="$5"
	local reason="$6"
	local lock_dir=""
	local exit_path=""
	local observed_outcome_id=""
	local observed_reason=""
	local timestamp=""
	local finished_at=""
	local state_tmp=""
	local outcome_tmp=""
	local previous_umask=""

	worker_attempt_observability_binding_is_safe \
		"$state_root" "$state_file" "$outcome_file" "$attempt_id" "$session_key" || return 1
	reason=$(_wao_safe_token "$reason" "dispatch_process_unavailable")
	_wao_acquire_state_lock lock_dir "$state_file" || return 1
	worker_attempt_observability_state_matches_identity \
		"$state_root" "$state_file" "$attempt_id" || {
		_wao_release_state_lock "$lock_dir"
		return 1
	}
	exit_path=$(jq -r --arg running "$_WAO_EXIT_PATH_RUNNING" '.exit_path // $running' "$state_file" 2>/dev/null) || exit_path=""
	if [[ -z "$exit_path" || "$exit_path" != "$_WAO_EXIT_PATH_RUNNING" ]]; then
		_wao_release_state_lock "$lock_dir"
		return 0
	fi

	if [[ -s "$outcome_file" ]]; then
		observed_outcome_id=$(_wao_outcome_value "$outcome_file" "outcome_id")
		[[ "$observed_outcome_id" == "$attempt_id" ]] || {
			_wao_release_state_lock "$lock_dir"
			return 1
		}
		observed_reason=$(_wao_outcome_value "$outcome_file" "reason")
		[[ -n "$observed_reason" ]] && reason=$(_wao_safe_token "$observed_reason" "$reason")
	else
		finished_at=$(date +%s 2>/dev/null || printf '0')
		[[ "$finished_at" =~ ^[0-9]+$ ]] || finished_at=0
		previous_umask=$(umask)
		umask 077
		outcome_tmp=$(mktemp "${outcome_file}.tmp.XXXXXX" 2>/dev/null) || outcome_tmp=""
		umask "$previous_umask"
		if [[ -z "$outcome_tmp" ]] || ! {
			printf 'session_key=%s\n' "$session_key"
			printf 'outcome_id=%s\n' "$attempt_id"
			printf 'reason=%s\n' "$reason"
			printf 'session_count=0\n'
			printf 'retry_class=retryable_infrastructure\n'
			printf 'finished_at=%s\n' "$finished_at"
		} >"$outcome_tmp"; then
			rm -f "$outcome_tmp" 2>/dev/null || true
			_wao_release_state_lock "$lock_dir"
			return 1
		fi
		if ! ln "$outcome_tmp" "$outcome_file" 2>/dev/null; then
			rm -f "$outcome_tmp" 2>/dev/null || true
			observed_outcome_id=$(_wao_outcome_value "$outcome_file" "outcome_id")
			[[ "$observed_outcome_id" == "$attempt_id" ]] || {
				_wao_release_state_lock "$lock_dir"
				return 1
			}
		else
			rm -f "$outcome_tmp" 2>/dev/null || true
			chmod 600 "$outcome_file" 2>/dev/null || true
		fi
	fi

	timestamp=$(_wao_timestamp)
	previous_umask=$(umask)
	umask 077
	state_tmp=$(mktemp "${state_file}.tmp.XXXXXX" 2>/dev/null) || state_tmp=""
	umask "$previous_umask"
	if [[ -z "$state_tmp" ]] || ! jq \
		--arg updated_at "$timestamp" \
		--arg emitter_pid "$$" \
		--arg reason "$reason" \
		'.updated_at = $updated_at |
		 .last_event_category = "supervisor" |
		 .last_event = "dispatch_reaper_finalized" |
		 .emitter_pid = $emitter_pid |
		 .status = "1" |
		 .exit_path = "supervisor_finalized" |
		 .reason = $reason' "$state_file" >"$state_tmp" 2>/dev/null; then
		rm -f "$state_tmp" 2>/dev/null || true
		_wao_release_state_lock "$lock_dir"
		return 1
	fi
	if ! mv -f "$state_tmp" "$state_file" 2>/dev/null; then
		rm -f "$state_tmp" 2>/dev/null || true
		_wao_release_state_lock "$lock_dir"
		return 1
	fi
	chmod 600 "$state_file" 2>/dev/null || true
	_wao_release_state_lock "$lock_dir"
	return 0
)

_wao_state_field() {
	local field="$1"
	local state_file=""
	case "$field" in
	last_lifecycle_stage | last_completed_stage) ;;
	*) return 1 ;;
	esac
	state_file=$(_wao_state_path 2>/dev/null) || return 0
	[[ -s "$state_file" ]] || return 0
	jq -r --arg field "$field" --arg attempt_id "${AIDEVOPS_ATTEMPT_ID:-}" \
		'select(.attempt_id == $attempt_id) | .[$field] // empty' \
		"$state_file" 2>/dev/null || true
	return 0
}

worker_attempt_observability_last_stage() {
	_wao_state_field last_lifecycle_stage
	return 0
}

worker_attempt_observability_last_completed_stage() {
	_wao_state_field last_completed_stage
	return 0
}
