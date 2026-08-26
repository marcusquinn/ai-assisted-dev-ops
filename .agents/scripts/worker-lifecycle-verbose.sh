#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Verbose Checkpoints -- Checkpoint emission and log watcher
# =============================================================================
# Defines the opt-in lifecycle checkpoints used for fix-the-fixer diagnostics.
# Source worker-lifecycle-common.sh rather than sourcing this file directly.
#
# Dependencies:
#   - worker-lifecycle-common.sh (_emit_worker_runtime_event)
#
# Part of aidevops framework: https://aidevops.sh

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_WORKER_LIFECYCLE_VERBOSE_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_VERBOSE_LOADED=1

# Compose the sentinel directory for a session/PID. Created lazily.
_verbose_lifecycle_sentinel_dir() {
	local pid="${1:-$$}"
	local dir="${HOME}/.aidevops/cache/lifecycle-watch-${pid}"
	mkdir -p "$dir" 2>/dev/null || true
	printf '%s' "$dir"
	return 0
}

#######################################
# Emit one lifecycle marker, at most once for each PID and event.
# Arguments:
#   event - event name (alphanumeric + underscore)
#   remaining arguments - optional key=value metadata
# Returns: always 0
#######################################
_emit_verbose_checkpoint() {
	local event="$1"
	shift || true
	local runtime_event_type=""
	case "$event" in
	worker_started) runtime_event_type="worker.started" ;;
	opencode_session_created) runtime_event_type="worker.session_created" ;;
	first_tool_use) runtime_event_type="worker.tool_started" ;;
	first_commit_attempted) runtime_event_type="worker.commit_attempted" ;;
	first_push_attempted) runtime_event_type="worker.push_attempted" ;;
	esac
	if [[ -n "$runtime_event_type" ]]; then
		_emit_worker_runtime_event "$runtime_event_type" "$event"
	fi

	[[ "${AIDEVOPS_VERBOSE_LIFECYCLE:-0}" != "1" ]] && return 0
	[[ -z "$event" ]] && return 0

	local safe_event
	safe_event=$(printf '%s' "$event" | tr -c 'a-zA-Z0-9_' '_')

	local sentinel_dir
	sentinel_dir=$(_verbose_lifecycle_sentinel_dir "$$")
	local sentinel="${sentinel_dir}/${safe_event}.fired"
	[[ -f "$sentinel" ]] && return 0
	touch "$sentinel" 2>/dev/null || true

	local ts
	ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts=""

	local extra=""
	local lifecycle_event=""
	[[ $# -gt 0 ]] && extra=" $*"
	printf -v lifecycle_event '[lifecycle] %s ts=%s pid=%s session=%s%s' \
		"$safe_event" "$ts" "$$" "${WORKER_SESSION_KEY:-${AIDEVOPS_SESSION_KEY:-unknown}}" "$extra"
	worker_attempt_observability_enrich lifecycle_event "$lifecycle_event"
	printf '%s\n' "$lifecycle_event" >&2
	return 0
}

#######################################
# Watch a worker log and emit its first four progression checkpoints.
# Arguments:
#   worker_log - worker log path
#   worker_pid - OpenCode child PID
# Returns: watcher PID via stdout; always 0
#######################################
_start_verbose_lifecycle_watcher() {
	local worker_log="$1"
	local worker_pid="$2"

	[[ "${AIDEVOPS_VERBOSE_LIFECYCLE:-0}" != "1" ]] && return 0
	[[ -z "$worker_log" || -z "$worker_pid" ]] && return 0
	[[ ! -f "$worker_log" ]] && touch "$worker_log" 2>/dev/null

	local timeout="${AIDEVOPS_VERBOSE_LIFECYCLE_WATCH_TIMEOUT:-1800}"
	[[ "$timeout" =~ ^[0-9]+$ ]] || timeout=1800

	(
		local _w_start
		_w_start=$(date +%s)
		local _saw_session=0 _saw_tool=0 _saw_commit=0 _saw_push=0
		local _emit_meta="source=watcher worker_pid=${worker_pid}"

		while IFS= read -r line; do
			if [[ "$_saw_session" -eq 1 && "$_saw_tool" -eq 1 &&
				"$_saw_commit" -eq 1 && "$_saw_push" -eq 1 ]]; then
				break
			fi
			kill -0 "$worker_pid" 2>/dev/null || break

			local _now _elapsed
			_now=$(date +%s 2>/dev/null) || _now=0
			_elapsed=$((_now - _w_start))
			[[ "$_elapsed" -gt "$timeout" ]] && break

			if [[ "$_saw_session" -eq 0 ]] &&
				printf '%s' "$line" | grep -qE '"session(\.|_)created"|session_id|opencode session created' 2>/dev/null; then
				_emit_verbose_checkpoint opencode_session_created "$_emit_meta"
				_saw_session=1
			fi
			if [[ "$_saw_tool" -eq 0 ]] &&
				printf '%s' "$line" | grep -qE '"step\.start"|"tool_use"|tool=Bash|tool=Edit|tool=Write|tool=Read' 2>/dev/null; then
				_emit_verbose_checkpoint first_tool_use "$_emit_meta"
				_saw_tool=1
			fi
			if [[ "$_saw_commit" -eq 0 ]] &&
				printf '%s' "$line" | grep -qE 'git commit|git_commit|wip:.*commit' 2>/dev/null; then
				_emit_verbose_checkpoint first_commit_attempted "$_emit_meta"
				_saw_commit=1
			fi
			if [[ "$_saw_push" -eq 0 ]] &&
				printf '%s' "$line" | grep -qE 'git push|git_push' 2>/dev/null; then
				_emit_verbose_checkpoint first_push_attempted "$_emit_meta"
				_saw_push=1
			fi
		done < <(tail -F -n 0 "$worker_log" 2>/dev/null)
		return 0
	) &
	local watcher_pid=$!
	disown "$watcher_pid" 2>/dev/null || true

	local sentinel_dir
	sentinel_dir=$(_verbose_lifecycle_sentinel_dir "$worker_pid")
	printf '%s' "$watcher_pid" >"${sentinel_dir}/watcher.pid" 2>/dev/null || true
	printf '%s' "$watcher_pid"
	return 0
}

#######################################
# Stop a verbose lifecycle watcher and remove its sentinel directory.
# Arguments:
#   worker_pid - worker PID used to locate the sentinel directory
# Returns: always 0
#######################################
_cleanup_verbose_lifecycle_watcher() {
	local worker_pid="${1:-}"
	[[ -z "$worker_pid" ]] && return 0

	local sentinel_dir="${HOME}/.aidevops/cache/lifecycle-watch-${worker_pid}"
	[[ ! -d "$sentinel_dir" ]] && return 0

	if [[ -f "${sentinel_dir}/watcher.pid" ]]; then
		local watcher_pid
		watcher_pid=$(<"${sentinel_dir}/watcher.pid") || watcher_pid=""
		if [[ "$watcher_pid" =~ ^[0-9]+$ ]]; then
			kill -TERM "$watcher_pid" 2>/dev/null || true
		fi
	fi

	rm -rf "$sentinel_dir" 2>/dev/null || true
	return 0
}
