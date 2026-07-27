#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-todo-sync-workspace.sh — Owned lifecycle for isolated TODO-sync clones.

[[ -n "${_PULSE_TODO_SYNC_WORKSPACE_LOADED:-}" ]] && return 0
_PULSE_TODO_SYNC_WORKSPACE_LOADED=1

_PTSW_OWNER_MARKER=".aidevops-pulse-todo-sync-owner"
_PTSW_MARKER_VERSION="v1"
_PTSW_OUTCOME_SKIPPED="skipped"
_PTSW_OWNER_STALE="stale"
_PTSW_VALIDATION_REASON=""
_PTSW_OWNER_PID=""
_PTSW_OWNER_START=""
_PTSW_OWNER_CREATED=""
_PTSW_OWNER_STATE=""
_PULSE_TODO_SYNC_WORKSPACE=""
_PULSE_TODO_SYNC_WORKSPACE_ROOT=""
_PULSE_TODO_SYNC_OWNER_PID=""
_PULSE_TODO_SYNC_OWNER_START=""

_ptsw_process_start_fingerprint() {
	local process_pid="$1"
	local process_start=""
	local stat_content=""
	local stat_after_comm=""
	[[ "$process_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	if [[ -r "/proc/${process_pid}/stat" ]]; then
		stat_content=$(<"/proc/${process_pid}/stat") || return 1
		stat_after_comm="${stat_content##*) }"
		process_start=$(printf '%s\n' "$stat_after_comm" | awk '{print $20}') || return 1
	else
		process_start=$(LC_ALL=C ps -p "$process_pid" -o lstart= 2>/dev/null) || return 1
	fi
	process_start="${process_start#"${process_start%%[![:space:]]*}"}"
	process_start="${process_start%"${process_start##*[![:space:]]}"}"
	[[ -n "$process_start" ]] || return 1
	printf '%s\n' "$process_start"
	return 0
}

_ptsw_resolve_temp_root() {
	local create_root="${1:-0}"
	local temp_root="${AIDEVOPS_TEMP_DIR:-}"
	if [[ -z "$temp_root" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		temp_root="${HOME}/.aidevops/.agent-workspace/tmp"
	fi
	[[ -n "$temp_root" && "$temp_root" == /* ]] || return 1
	if [[ "$create_root" == "1" ]]; then
		mkdir -p "$temp_root" 2>/dev/null || return 1
	fi
	[[ -d "$temp_root" ]] || return 1
	(cd "$temp_root" 2>/dev/null && pwd -P)
	return $?
}

_ptsw_safe_identity() {
	local candidate="$1"
	local identity="${candidate%/}"
	identity="${identity##*/}"
	printf '%s' "$identity" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
	return 0
}

_ptsw_validate_workspace_path() {
	local candidate="$1"
	local require_marker="${2:-1}"
	local temp_root=""
	local candidate_parent=""
	local resolved_parent=""
	local resolved_candidate=""
	local identity=""
	local marker_path=""
	_PTSW_VALIDATION_REASON="invalid-path"
	[[ -n "$candidate" && "$candidate" == /* ]] || return 1
	candidate="${candidate%/}"
	identity="${candidate##*/}"
	if [[ ! "$identity" =~ ^pulse-todo-sync\.[A-Za-z0-9]{6}$ ]]; then
		_PTSW_VALIDATION_REASON="malformed-name"
		return 1
	fi
	if [[ -L "$candidate" ]]; then
		_PTSW_VALIDATION_REASON="symlink"
		return 1
	fi
	if [[ ! -d "$candidate" ]]; then
		_PTSW_VALIDATION_REASON="not-directory"
		return 1
	fi
	temp_root=$(_ptsw_resolve_temp_root 0) || {
		_PTSW_VALIDATION_REASON="temp-root-unavailable"
		return 1
	}
	candidate_parent="${candidate%/*}"
	resolved_parent=$(cd "$candidate_parent" 2>/dev/null && pwd -P) || {
		_PTSW_VALIDATION_REASON="parent-unavailable"
		return 1
	}
	if [[ "$resolved_parent" != "$temp_root" ]]; then
		_PTSW_VALIDATION_REASON="outside-temp-root"
		return 1
	fi
	resolved_candidate=$(cd "$candidate" 2>/dev/null && pwd -P) || {
		_PTSW_VALIDATION_REASON="workspace-unavailable"
		return 1
	}
	if [[ "$resolved_candidate" != "${temp_root}/${identity}" ]]; then
		_PTSW_VALIDATION_REASON="path-mismatch"
		return 1
	fi
	if [[ "$require_marker" == "1" ]]; then
		marker_path="${candidate}/${_PTSW_OWNER_MARKER}"
		if [[ -L "$marker_path" ]]; then
			_PTSW_VALIDATION_REASON="owner-marker-symlink"
			return 1
		fi
		if [[ ! -f "$marker_path" ]]; then
			_PTSW_VALIDATION_REASON="missing-owner-marker"
			return 1
		fi
	fi
	_PTSW_VALIDATION_REASON=""
	return 0
}

_ptsw_read_owner_marker() {
	local workspace_root="$1"
	local marker_path="${workspace_root}/${_PTSW_OWNER_MARKER}"
	local marker_record=""
	local marker_version=""
	local owner_pid=""
	local owner_created=""
	local owner_start=""
	local extra_field=""
	_PTSW_OWNER_PID=""
	_PTSW_OWNER_START=""
	_PTSW_OWNER_CREATED=""
	[[ -f "$marker_path" && ! -L "$marker_path" ]] || return 1
	marker_record=$(<"$marker_path") || return 1
	[[ "$marker_record" != *$'\n'* ]] || return 1
	IFS=$'\t' read -r marker_version owner_pid owner_created owner_start extra_field <<<"$marker_record"
	[[ "$marker_version" == "$_PTSW_MARKER_VERSION" ]] || return 1
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ "$owner_created" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ -n "$owner_start" && -z "$extra_field" ]] || return 1
	_PTSW_OWNER_PID="$owner_pid"
	_PTSW_OWNER_START="$owner_start"
	_PTSW_OWNER_CREATED="$owner_created"
	return 0
}

_ptsw_create_workspace() {
	local remote_url="$1"
	local temp_root=""
	local workspace_root=""
	local marker_path=""
	local marker_tmp=""
	local owner_pid="${BASHPID:-}"
	local owner_start=""
	local owner_created=""
	_PULSE_TODO_SYNC_WORKSPACE=""
	_PULSE_TODO_SYNC_WORKSPACE_ROOT=""
	_PULSE_TODO_SYNC_OWNER_PID=""
	_PULSE_TODO_SYNC_OWNER_START=""
	[[ -n "$remote_url" ]] || return 1
	if [[ -z "$owner_pid" ]]; then
		# Bash 3.2 has no BASHPID and $$ remains the ancestor shell PID inside
		# a subshell. The command-substitution child sees this workspace owner
		# as its PPID, so exec avoids reporting an intermediate shell instead.
		owner_pid="$(exec sh -c 'printf "%s" "$PPID"')" || return 1
	fi
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	owner_start=$(_ptsw_process_start_fingerprint "$owner_pid") || return 1
	owner_created=$(date +%s 2>/dev/null) || return 1
	[[ "$owner_created" =~ ^[1-9][0-9]*$ ]] || return 1
	temp_root=$(_ptsw_resolve_temp_root 1) || return 1
	workspace_root=$(mktemp -d "${temp_root}/pulse-todo-sync.XXXXXX") || return 1
	workspace_root=$(cd "$workspace_root" 2>/dev/null && pwd -P) || return 1
	if ! _ptsw_validate_workspace_path "$workspace_root" 0; then
		rmdir "$workspace_root" 2>/dev/null || true
		return 1
	fi
	marker_path="${workspace_root}/${_PTSW_OWNER_MARKER}"
	marker_tmp="${marker_path}.tmp.${owner_pid}"
	if ! printf '%s\t%s\t%s\t%s\n' "$_PTSW_MARKER_VERSION" "$owner_pid" \
		"$owner_created" "$owner_start" >"$marker_tmp" 2>/dev/null; then
		rm -f "$marker_tmp" 2>/dev/null || true
		rmdir "$workspace_root" 2>/dev/null || true
		return 1
	fi
	if ! mv "$marker_tmp" "$marker_path" 2>/dev/null; then
		rm -f "$marker_tmp" 2>/dev/null || true
		rmdir "$workspace_root" 2>/dev/null || true
		return 1
	fi
	_PULSE_TODO_SYNC_WORKSPACE_ROOT="$workspace_root"
	_PULSE_TODO_SYNC_WORKSPACE="${workspace_root}/repo"
	_PULSE_TODO_SYNC_OWNER_PID="$owner_pid"
	_PULSE_TODO_SYNC_OWNER_START="$owner_start"
	git clone --quiet --no-tags "$remote_url" "$_PULSE_TODO_SYNC_WORKSPACE" >/dev/null 2>&1 || return 1
	return 0
}

_ptsw_remove_owned_workspace() {
	local workspace_root="$1"
	local expected_pid="$2"
	local expected_start="$3"
	local current_start=""
	[[ -n "$workspace_root" ]] || return 0
	[[ -e "$workspace_root" || -L "$workspace_root" ]] || return 0
	_ptsw_validate_workspace_path "$workspace_root" 1 || return 1
	_ptsw_read_owner_marker "$workspace_root" || return 1
	[[ "$_PTSW_OWNER_PID" == "$expected_pid" ]] || return 1
	[[ "$_PTSW_OWNER_START" == "$expected_start" ]] || return 1
	current_start=$(_ptsw_process_start_fingerprint "$expected_pid") || return 1
	[[ "$current_start" == "$expected_start" ]] || return 1
	rm -rf "$workspace_root" 2>/dev/null || return 1
	[[ ! -e "$workspace_root" && ! -L "$workspace_root" ]] || return 1
	return 0
}

_ptsw_process_visibility_available() {
	local self_pid="${BASHPID:-$$}"
	local observed_pid=""
	observed_pid=$(LC_ALL=C ps -p "$self_pid" -o pid= 2>/dev/null) || return 1
	observed_pid="${observed_pid//[[:space:]]/}"
	[[ "$observed_pid" == "$self_pid" ]] || return 1
	return 0
}

_ptsw_classify_owner() {
	local owner_pid="$1"
	local owner_start="$2"
	local current_start=""
	local observed_pid=""
	local ps_rc=0
	local kill_error=""
	local kill_rc=0
	_PTSW_OWNER_STATE="unknown"
	if current_start=$(_ptsw_process_start_fingerprint "$owner_pid"); then
		if [[ "$current_start" == "$owner_start" ]]; then
			_PTSW_OWNER_STATE="active"
		else
			_PTSW_OWNER_STATE="$_PTSW_OWNER_STALE"
		fi
		return 0
	fi
	_ptsw_process_visibility_available || return 0
	kill_error=$(LC_ALL=C kill -0 "$owner_pid" 2>&1) || kill_rc=$?
	# A successful signal probe proves the PID is live. If its generation token
	# cannot be observed, fail closed instead of treating degraded ps output as
	# evidence that the owner disappeared.
	[[ "$kill_rc" -eq 0 ]] && return 0
	case "$kill_error" in
	*"Operation not permitted"* | *"operation not permitted"*) return 0 ;;
	esac
	observed_pid=$(LC_ALL=C ps -p "$owner_pid" -o pid= 2>/dev/null) || ps_rc=$?
	observed_pid="${observed_pid//[[:space:]]/}"
	if [[ "$ps_rc" -eq 1 && -z "$observed_pid" ]]; then
		_PTSW_OWNER_STATE="$_PTSW_OWNER_STALE"
	fi
	return 0
}

_ptsw_workspace_grace_secs() {
	local stage_timeout="${PRE_RUN_STAGE_TIMEOUT:-600}"
	local grace_secs="${PULSE_TODO_SYNC_WORKSPACE_GRACE_SECS:-}"
	[[ "$stage_timeout" =~ ^[1-9][0-9]*$ ]] || stage_timeout=600
	if [[ ! "$grace_secs" =~ ^[1-9][0-9]*$ ]]; then
		grace_secs=$((stage_timeout + 300))
	fi
	if [[ "$grace_secs" -le "$stage_timeout" ]]; then
		grace_secs=$((stage_timeout + 1))
	fi
	printf '%s\n' "$grace_secs"
	return 0
}

_ptsw_log_sweep_outcome() {
	local outcome="$1"
	local reason="$2"
	local identity="$3"
	local detail="${4:-}"
	local log_file="${WRAPPER_LOGFILE:-${LOGFILE:-/dev/null}}"
	printf '[pulse-wrapper] TODO ref sync stale cleanup outcome=%s reason=%s workspace=%s%s\n' \
		"$outcome" "$reason" "$identity" "${detail:+ ${detail}}" >>"$log_file" 2>/dev/null || true
	return 0
}

_ptsw_move_to_recoverable_trash() {
	local workspace_root="$1"
	local identity="$2"
	local trash_root="${AIDEVOPS_TODO_SYNC_TRASH_ROOT:-${AIDEVOPS_ORPHAN_TRASH_ROOT:-}}"
	local resolved_trash_root=""
	local destination=""
	local move_epoch=""
	if [[ -z "$trash_root" ]]; then
		[[ -n "${HOME:-}" ]] || return 1
		trash_root="${HOME}/.Trash"
	fi
	[[ -n "$trash_root" && "$trash_root" == /* ]] || return 1
	mkdir -p "$trash_root" 2>/dev/null || return 1
	resolved_trash_root=$(cd "$trash_root" 2>/dev/null && pwd -P) || return 1
	case "$resolved_trash_root" in
	"$workspace_root" | "$workspace_root"/*) return 1 ;;
	esac
	move_epoch=$(date +%s 2>/dev/null) || return 1
	destination="${resolved_trash_root}/aidevops-pulse-todo-sync-${identity}-${move_epoch}-${BASHPID:-$$}-${RANDOM}"
	[[ ! -e "$destination" && ! -L "$destination" ]] || return 1
	mv "$workspace_root" "$destination" 2>/dev/null || return 1
	[[ ! -e "$workspace_root" && ! -L "$workspace_root" ]] || return 1
	return 0
}

_ptsw_sweep_stale_workspaces() {
	local temp_root=""
	local now_epoch=""
	local grace_secs=""
	local max_recoveries="${PULSE_TODO_SYNC_MAX_RECOVERIES_PER_RUN:-5}"
	local workspace_root=""
	local identity=""
	local safe_identity=""
	local age_secs=0
	local removed=0
	local owner_pid=""
	local owner_start=""
	local owner_created=""
	local owner_detail=""
	[[ "$max_recoveries" =~ ^[1-9][0-9]*$ ]] || max_recoveries=5
	temp_root=$(_ptsw_resolve_temp_root 0) || {
		printf '0\n'
		return 0
	}
	now_epoch=$(date +%s 2>/dev/null) || {
		printf '0\n'
		return 0
	}
	grace_secs=$(_ptsw_workspace_grace_secs) || {
		printf '0\n'
		return 0
	}
	for workspace_root in "$temp_root"/pulse-todo-sync.*; do
		[[ -e "$workspace_root" || -L "$workspace_root" ]] || continue
		safe_identity=$(_ptsw_safe_identity "$workspace_root")
		if ! _ptsw_validate_workspace_path "$workspace_root" 1; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "${_PTSW_VALIDATION_REASON:-invalid-candidate}" "$safe_identity"
			continue
		fi
		identity="${workspace_root##*/}"
		if ! _ptsw_read_owner_marker "$workspace_root"; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "malformed-owner-marker" "$identity"
			continue
		fi
		owner_pid="$_PTSW_OWNER_PID"
		owner_start="$_PTSW_OWNER_START"
		owner_created="$_PTSW_OWNER_CREATED"
		owner_detail="owner_pid=${owner_pid}"
		age_secs=$((now_epoch - owner_created))
		if [[ "$age_secs" -lt 0 ]]; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "future-owner-marker" "$identity"
			continue
		fi
		if [[ "$age_secs" -lt "$grace_secs" ]]; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "grace-period" "$identity" "age=${age_secs}s grace=${grace_secs}s"
			continue
		fi
		_ptsw_classify_owner "$owner_pid" "$owner_start"
		case "$_PTSW_OWNER_STATE" in
		active)
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "active-owner" "$identity" "$owner_detail"
			continue
			;;
		unknown)
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "owner-visibility-unknown" "$identity" "$owner_detail"
			continue
			;;
		esac
		if [[ "$removed" -ge "$max_recoveries" ]]; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "recovery-cap" "$identity" "cap=${max_recoveries}"
			continue
		fi
		# Recheck the mutable ownership record immediately before the move.
		if ! _ptsw_validate_workspace_path "$workspace_root" 1 ||
			! _ptsw_read_owner_marker "$workspace_root" ||
			[[ "$_PTSW_OWNER_PID" != "$owner_pid" || "$_PTSW_OWNER_START" != "$owner_start" ||
				"$_PTSW_OWNER_CREATED" != "$owner_created" ]]; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "owner-marker-changed" "$identity"
			continue
		fi
		_ptsw_classify_owner "$owner_pid" "$owner_start"
		if [[ "$_PTSW_OWNER_STATE" != "$_PTSW_OWNER_STALE" ]]; then
			_ptsw_log_sweep_outcome "$_PTSW_OUTCOME_SKIPPED" "owner-state-changed" "$identity"
			continue
		fi
		if _ptsw_move_to_recoverable_trash "$workspace_root" "$identity"; then
			removed=$((removed + 1))
			_ptsw_log_sweep_outcome "removed" "dead-owner" "$identity" "age=${age_secs}s owner_pid=${owner_pid} mode=trash"
		else
			_ptsw_log_sweep_outcome "failure" "trash-move-failed" "$identity" "$owner_detail"
		fi
	done
	printf '%s\n' "$removed"
	return 0
}
