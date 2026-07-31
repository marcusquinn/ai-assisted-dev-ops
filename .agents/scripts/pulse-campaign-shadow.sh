#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Default-off adapter between legacy Pulse candidate collection and the local
# repository campaign projection. Planner failures are diagnostic-only: this
# file always returns the exact legacy candidate JSON used by dispatch.

[[ -n "${_PULSE_CAMPAIGN_SHADOW_LOADED:-}" ]] && return 0
_PULSE_CAMPAIGN_SHADOW_LOADED=1

_pulse_campaign_shadow_enabled() {
	case "${AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED:-0}" in
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	*) return 1 ;;
	esac
}

_pulse_campaign_log() {
	local message="$1"
	local logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	mkdir -p "${logfile%/*}" 2>/dev/null || true
	printf '[pulse-wrapper] Campaign shadow: %s\n' "$message" >>"$logfile" 2>/dev/null || true
	return 0
}

_pulse_campaign_temp_file() {
	local label="$1"
	local root=""
	if declare -F aidevops_pulse_tmp_root >/dev/null 2>&1; then
		root=$(aidevops_pulse_tmp_root) || return 1
	else
		root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/pulse"
		mkdir -p "$root" 2>/dev/null || return 1
		chmod 700 "$root" 2>/dev/null || return 1
	fi
	local filepath=""
	filepath=$(mktemp "${root}/campaign-${label}.XXXXXX") || return 1
	chmod 600 "$filepath" 2>/dev/null || {
		rm -f "$filepath"
		return 1
	}
	printf '%s\n' "$filepath"
	return 0
}

_pulse_campaign_run_coordinator() {
	local timeout_seconds="$1"
	shift
	if declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec "$timeout_seconds" "$@"
		return $?
	fi
	if command -v timeout >/dev/null 2>&1; then
		timeout "$timeout_seconds" "$@"
		return $?
	fi
	if command -v gtimeout >/dev/null 2>&1; then
		gtimeout "$timeout_seconds" "$@"
		return $?
	fi
	"$@"
	return $?
}

_pulse_campaign_plan_shadow() {
	local repo_slug="$1"
	local repo_path="$2"
	local source_limit="$3"
	local raw_snapshot_file="$4"
	local ready_file="$5"
	local plan_file="$6"
	local snapshot_status_file="$7"
	local script_dir="${_PULSE_DISPATCH_ENGINE_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
	local coordinator="${script_dir}/pulse-campaign-coordinator.mjs"
	local checkpoint_root="${AIDEVOPS_PULSE_CAMPAIGN_CHECKPOINT_ROOT:-${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/repository-campaigns}"
	local peer_state_file="${AIDEVOPS_PEER_PRODUCTIVITY_STATE_FILE:-${HOME}/.aidevops/state/peer-productivity-state.json}"
	local device_id_file="${AIDEVOPS_DEVICE_ID_FILE:-${HOME}/.aidevops/state/device-id}"
	local self_login="${AIDEVOPS_PULSE_RUNNER_LOGIN:-${WORKER_GITHUB_LOGIN:-}}"
	local planner_status=0
	local source_succeeded=0
	if [[ -r "$snapshot_status_file" ]]; then
		source_succeeded=$(<"$snapshot_status_file")
	fi
	[[ "$source_succeeded" == "1" ]] || source_succeeded=0

	if [[ ! -f "$coordinator" ]] || ! command -v node >/dev/null 2>&1; then
		_pulse_campaign_log "planner unavailable repo=${repo_slug}; legacy candidates retained"
		return 1
	fi

	local -a command_args=(
		node "$coordinator" plan
		--repo "$repo_slug"
		--repo-path "$repo_path"
		--issues-file "$raw_snapshot_file"
		--ready-file "$ready_file"
		--repos-file "${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
		--peer-state-file "$peer_state_file"
		--device-id-file "$device_id_file"
		--checkpoint-root "$checkpoint_root"
		--horizon "${PULSE_CAMPAIGN_HORIZON:-10}"
		--ttl "${PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS:-3600}"
		--source-limit "$source_limit"
		--source-succeeded "$source_succeeded"
	)
	if [[ -n "$self_login" ]]; then
		command_args+=(--self-login "$self_login")
	fi

	_pulse_campaign_run_coordinator "${PULSE_CAMPAIGN_TIMEOUT_SECONDS:-5}" "${command_args[@]}" >"$plan_file" 2>/dev/null || planner_status=$?
	if [[ "$planner_status" -ne 0 ]]; then
		_pulse_campaign_log "planner failed repo=${repo_slug} status=${planner_status}; legacy candidates retained"
		return 1
	fi

	local summary=""
	summary=$(jq -r '"repo=" + (.repository.slug // "unknown") + " generation=" + ((.generation // 0) | tostring) + " frontier=" + ((.frontier // []) | length | tostring) + " lanes=" + ((.lanes // []) | length | tostring) + " complete=" + ((.source.complete // false) | tostring)' "$plan_file" 2>/dev/null) || summary="repo=${repo_slug} checkpoint=written"
	_pulse_campaign_log "$summary"
	return 0
}

pulse_campaign_shadow_candidates_json() {
	local repo_slug="$1"
	local repo_path="$2"
	local source_limit="${3:-1000}"
	local dependency_normalization_mode="${4:-normalize}"
	local candidates_json="[]"

	if ! _pulse_campaign_shadow_enabled; then
		candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$source_limit" "" "" "$dependency_normalization_mode") || candidates_json='[]'
		_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates_json"
		return 0
	fi

	local raw_snapshot_file="" ready_file="" plan_file="" snapshot_status_file=""
	raw_snapshot_file=$(_pulse_campaign_temp_file "raw") || raw_snapshot_file=""
	ready_file=$(_pulse_campaign_temp_file "ready") || ready_file=""
	plan_file=$(_pulse_campaign_temp_file "plan") || plan_file=""
	snapshot_status_file=$(_pulse_campaign_temp_file "status") || snapshot_status_file=""
	if [[ -z "$raw_snapshot_file" || -z "$ready_file" || -z "$plan_file" || -z "$snapshot_status_file" ]]; then
		rm -f "$raw_snapshot_file" "$ready_file" "$plan_file" "$snapshot_status_file"
		_pulse_campaign_log "temporary workspace unavailable repo=${repo_slug}; legacy candidates retained"
		candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$source_limit" "" "" "$dependency_normalization_mode") || candidates_json='[]'
		_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates_json"
		return 0
	fi

	candidates_json=$(list_dispatchable_issue_candidates_json "$repo_slug" "$source_limit" "$raw_snapshot_file" "$snapshot_status_file" "$dependency_normalization_mode") || candidates_json='[]'
	candidates_json=$(_dispatch_filter_repo_pr_backlog_candidates "$repo_slug" "$candidates_json")
	(
		umask 077
		printf '%s\n' "$candidates_json" >"$ready_file"
	) || {
		_pulse_campaign_log "ready snapshot write failed repo=${repo_slug}; legacy candidates retained"
		printf '%s\n' "$candidates_json"
		rm -f "$raw_snapshot_file" "$ready_file" "$plan_file" "$snapshot_status_file"
		return 0
	}

	_pulse_campaign_plan_shadow "$repo_slug" "$repo_path" "$source_limit" "$raw_snapshot_file" "$ready_file" "$plan_file" "$snapshot_status_file" || true
	printf '%s\n' "$candidates_json"
	rm -f "$raw_snapshot_file" "$ready_file" "$plan_file" "$snapshot_status_file"
	return 0
}
