#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Asynchronously initialize branch-local CodeGraph indexes for worker worktrees.

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
_SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$_SCRIPT_PATH")"

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=disk-capacity-lib.sh
source "${SCRIPT_DIR}/disk-capacity-lib.sh"

: "${AIDEVOPS_CODEGRAPH_WORKTREE_INIT_ENABLED:=1}"
: "${AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS:=180}"
: "${AIDEVOPS_CODEGRAPH_INIT_QUEUE_TIMEOUT_SECONDS:=300}"
: "${AIDEVOPS_CODEGRAPH_INIT_LOCK_STALE_SECONDS:=600}"

_CODEGRAPH_LOG_DIR="${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}"
_CODEGRAPH_LOG_FILE="${AIDEVOPS_CODEGRAPH_LOG_FILE:-${_CODEGRAPH_LOG_DIR}/codegraph-worktree-init.log}"
_CODEGRAPH_STATE_DIR="${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}/codegraph-worktree-init"
_CODEGRAPH_WORKTREE_LOCK=""
_CODEGRAPH_GLOBAL_LOCK="${_CODEGRAPH_STATE_DIR}/global.lock"
_CODEGRAPH_WORKTREE_LOCK_HELD=0
_CODEGRAPH_GLOBAL_LOCK_HELD=0

_codegraph_log() {
	local message="$1"
	mkdir -p "$_CODEGRAPH_LOG_DIR" 2>/dev/null || return 0
	printf '[codegraph-worktree-init] %s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >>"$_CODEGRAPH_LOG_FILE" 2>/dev/null || true
	return 0
}

_codegraph_validate_positive_integer() {
	local value="$1"
	local fallback="$2"
	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$fallback"
	fi
	return 0
}

_codegraph_resolve_bin() {
	local configured_bin="${AIDEVOPS_CODEGRAPH_BIN:-}"
	local candidate=""
	if [[ -n "$configured_bin" && -x "$configured_bin" ]]; then
		printf '%s\n' "$configured_bin"
		return 0
	fi
	candidate=$(command -v codegraph 2>/dev/null || true)
	if [[ -n "$candidate" && -x "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	for candidate in \
		"${HOME:-}/.bun/bin/codegraph" \
		"${HOME:-}/.local/bin/codegraph" \
		"${HOME:-}/.aidevops/bin/codegraph"; do
		if [[ -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

_codegraph_resolve_worktree() {
	local worktree_path="$1"
	local git_dir=""
	local common_dir=""
	local resolved_path=""
	[[ -n "$worktree_path" && -d "$worktree_path" ]] || return 1
	resolved_path=$(cd "$worktree_path" && pwd -P) || return 1
	git_dir=$(git -C "$resolved_path" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	common_dir=$(git -C "$resolved_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	[[ "$git_dir" != "$common_dir" ]] || return 1
	printf '%s\n' "$resolved_path"
	return 0
}

_codegraph_worktree_key() {
	local worktree_path="$1"
	printf '%s' "$worktree_path" | cksum | awk '{ print $1 }'
	return 0
}

_codegraph_lock_is_stale() {
	local lock_dir="$1"
	local max_age="$2"
	local pid_file="${lock_dir}/pid"
	local lock_pid=""
	local lock_mtime=0
	local now_epoch=0

	if [[ -f "$pid_file" ]]; then
		read -r lock_pid <"$pid_file" || lock_pid=""
		if [[ "$lock_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
			return 1
		fi
	fi
	lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || printf '0')
	now_epoch=$(date +%s)
	[[ "$lock_mtime" =~ ^[0-9]+$ ]] || lock_mtime=0
	if [[ -n "$lock_pid" || $((now_epoch - lock_mtime)) -ge "$max_age" ]]; then
		return 0
	fi
	return 1
}

_codegraph_lock_acquire_once() {
	local lock_dir="$1"
	local stale_seconds="$2"
	if mkdir "$lock_dir" 2>/dev/null; then
		printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
		return 0
	fi
	if _codegraph_lock_is_stale "$lock_dir" "$stale_seconds"; then
		rm -rf "$lock_dir" 2>/dev/null || return 1
		if mkdir "$lock_dir" 2>/dev/null; then
			printf '%s\n' "$$" >"${lock_dir}/pid" 2>/dev/null || true
			return 0
		fi
	fi
	return 1
}

_codegraph_release_locks() {
	if [[ "$_CODEGRAPH_GLOBAL_LOCK_HELD" -eq 1 ]]; then
		rm -rf "$_CODEGRAPH_GLOBAL_LOCK" 2>/dev/null || true
		_CODEGRAPH_GLOBAL_LOCK_HELD=0
	fi
	if [[ "$_CODEGRAPH_WORKTREE_LOCK_HELD" -eq 1 && -n "$_CODEGRAPH_WORKTREE_LOCK" ]]; then
		rm -rf "$_CODEGRAPH_WORKTREE_LOCK" 2>/dev/null || true
		_CODEGRAPH_WORKTREE_LOCK_HELD=0
	fi
	return 0
}

_codegraph_signal_exit() {
	local exit_code="$1"
	trap - EXIT INT TERM
	_codegraph_release_locks
	exit "$exit_code"
	return 1
}

_codegraph_install_traps() {
	trap '_codegraph_release_locks' EXIT
	trap '_codegraph_signal_exit 130' INT
	trap '_codegraph_signal_exit 143' TERM
	return 0
}

_codegraph_wait_for_global_lock() {
	local queue_timeout="$1"
	local stale_seconds="$2"
	local elapsed=0
	while ! _codegraph_lock_acquire_once "$_CODEGRAPH_GLOBAL_LOCK" "$stale_seconds"; do
		if [[ "$elapsed" -ge "$queue_timeout" ]]; then
			return 1
		fi
		sleep 1
		elapsed=$((elapsed + 1))
	done
	_CODEGRAPH_GLOBAL_LOCK_HELD=1
	return 0
}

_codegraph_run_init() {
	local codegraph_bin="$1"
	local worktree_path="$2"
	local timeout_seconds="$3"
	local -a init_command=("$codegraph_bin" init "$worktree_path")
	if command -v ionice >/dev/null 2>&1; then
		init_command=(ionice -c 3 "${init_command[@]}")
	fi
	if command -v nice >/dev/null 2>&1; then
		init_command=(nice -n 10 "${init_command[@]}")
	fi
	(cd "$worktree_path" && timeout_sec "$timeout_seconds" "${init_command[@]}") >>"$_CODEGRAPH_LOG_FILE" 2>&1
	return $?
}

_codegraph_run() {
	local requested_path="$1"
	local issue_number="${2:-unknown}"
	local codegraph_bin=""
	local worktree_path=""
	local worktree_key=""
	local init_timeout=""
	local queue_timeout=""
	local stale_seconds=""
	local init_rc=0

	[[ "$AIDEVOPS_CODEGRAPH_WORKTREE_INIT_ENABLED" == "1" ]] || return 0
	codegraph_bin=$(_codegraph_resolve_bin) || return 0
	worktree_path=$(_codegraph_resolve_worktree "$requested_path") || {
		_codegraph_log "status=skipped reason=invalid-linked-worktree issue=${issue_number}"
		return 0
	}
	worktree_key=$(_codegraph_worktree_key "$worktree_path")
	init_timeout=$(_codegraph_validate_positive_integer "$AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS" 180)
	queue_timeout=$(_codegraph_validate_positive_integer "$AIDEVOPS_CODEGRAPH_INIT_QUEUE_TIMEOUT_SECONDS" 300)
	stale_seconds=$(_codegraph_validate_positive_integer "$AIDEVOPS_CODEGRAPH_INIT_LOCK_STALE_SECONDS" 600)

	mkdir -p "$_CODEGRAPH_STATE_DIR" "$_CODEGRAPH_LOG_DIR" || return 1
	_CODEGRAPH_WORKTREE_LOCK="${_CODEGRAPH_STATE_DIR}/worktree-${worktree_key}.lock"
	if ! _codegraph_lock_acquire_once "$_CODEGRAPH_WORKTREE_LOCK" "$stale_seconds"; then
		_codegraph_log "status=skipped reason=worktree-init-active issue=${issue_number} key=${worktree_key}"
		return 0
	fi
	_CODEGRAPH_WORKTREE_LOCK_HELD=1
	_codegraph_install_traps

	if ! _codegraph_wait_for_global_lock "$queue_timeout" "$stale_seconds"; then
		_codegraph_log "status=skipped reason=global-queue-timeout issue=${issue_number} key=${worktree_key}"
		return 0
	fi
	if ! aidevops_worktree_capacity_check "$worktree_path"; then
		_codegraph_log "status=skipped reason=${AIDEVOPS_DISK_CAPACITY_REASON:-capacity-unknown} issue=${issue_number} key=${worktree_key}"
		return 0
	fi

	_codegraph_log "status=started issue=${issue_number} key=${worktree_key}"
	if _codegraph_run_init "$codegraph_bin" "$worktree_path" "$init_timeout"; then
		_codegraph_log "status=completed issue=${issue_number} key=${worktree_key}"
	else
		init_rc=$?
		_codegraph_log "status=failed rc=${init_rc} issue=${issue_number} key=${worktree_key}"
	fi
	return 0
}

_codegraph_systemd_available() {
	[[ "${AIDEVOPS_CODEGRAPH_FORCE_NO_SYSTEMD:-0}" == "1" ]] && return 1
	[[ "$(uname -s 2>/dev/null || printf '%s' unknown)" == "Linux" ]] || return 1
	command -v systemd-run >/dev/null 2>&1 || return 1
	command -v systemctl >/dev/null 2>&1 || return 1
	systemctl --user show-environment >/dev/null 2>&1 || return 1
	return 0
}

_codegraph_launch() {
	local requested_path="$1"
	local issue_number="${2:-unknown}"
	local codegraph_bin=""
	local worktree_path=""
	local worktree_key=""
	local init_timeout=""
	local queue_timeout=""
	local runtime_max=""
	local unit_name=""
	local env_bin=""
	local -a child_env=()

	[[ "$AIDEVOPS_CODEGRAPH_WORKTREE_INIT_ENABLED" == "1" ]] || return 0
	codegraph_bin=$(_codegraph_resolve_bin) || return 0
	worktree_path=$(_codegraph_resolve_worktree "$requested_path") || return 0
	worktree_key=$(_codegraph_worktree_key "$worktree_path")
	init_timeout=$(_codegraph_validate_positive_integer "$AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS" 180)
	queue_timeout=$(_codegraph_validate_positive_integer "$AIDEVOPS_CODEGRAPH_INIT_QUEUE_TIMEOUT_SECONDS" 300)
	runtime_max=$((init_timeout + queue_timeout + 30))
	mkdir -p "$_CODEGRAPH_LOG_DIR" "$_CODEGRAPH_STATE_DIR" || return 0

	child_env=(
		"AIDEVOPS_CODEGRAPH_BIN=${codegraph_bin}"
		"AIDEVOPS_CODEGRAPH_WORKTREE_INIT_ENABLED=1"
		"AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS=${init_timeout}"
		"AIDEVOPS_CODEGRAPH_INIT_QUEUE_TIMEOUT_SECONDS=${queue_timeout}"
		"AIDEVOPS_CODEGRAPH_INIT_LOCK_STALE_SECONDS=${AIDEVOPS_CODEGRAPH_INIT_LOCK_STALE_SECONDS}"
		"AIDEVOPS_CODEGRAPH_LOG_FILE=${_CODEGRAPH_LOG_FILE}"
		"AIDEVOPS_LOG_DIR=${_CODEGRAPH_LOG_DIR}"
		"AIDEVOPS_TEMP_DIR=${AIDEVOPS_TEMP_DIR:-${HOME:-}/.aidevops/.agent-workspace/tmp}"
	)

	if _codegraph_systemd_available; then
		env_bin=$(command -v env 2>/dev/null || true)
		unit_name="aidevops-codegraph-${issue_number}-${worktree_key}"
		if [[ -n "$env_bin" ]] && systemd-run --user --unit="$unit_name" --collect --quiet --no-block \
			--description="aidevops CodeGraph worktree init ${issue_number}" \
			--property=Type=exec \
			--property="RuntimeMaxSec=${runtime_max}" \
			--property=TimeoutStopSec=10 \
			--property=KillMode=control-group \
			--property=Nice=10 \
			--property=IOSchedulingClass=idle \
			--property="StandardOutput=append:${_CODEGRAPH_LOG_FILE}" \
			--property="StandardError=append:${_CODEGRAPH_LOG_FILE}" \
			"$env_bin" "${child_env[@]}" "$_SCRIPT_PATH" run "$worktree_path" "$issue_number" </dev/null >/dev/null 2>>"$_CODEGRAPH_LOG_FILE"; then
			_codegraph_log "status=submitted mode=systemd issue=${issue_number} key=${worktree_key}"
			return 0
		fi
		_codegraph_log "status=submit-fallback reason=systemd-failed issue=${issue_number} key=${worktree_key}"
	fi

	if command -v setsid >/dev/null 2>&1; then
		setsid nohup env "${child_env[@]}" "$_SCRIPT_PATH" run "$worktree_path" "$issue_number" </dev/null >>"$_CODEGRAPH_LOG_FILE" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	else
		nohup env "${child_env[@]}" "$_SCRIPT_PATH" run "$worktree_path" "$issue_number" </dev/null >>"$_CODEGRAPH_LOG_FILE" 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &
	fi
	local child_pid=$!
	disown "$child_pid" 2>/dev/null || true
	_codegraph_log "status=submitted mode=nohup pid=${child_pid} issue=${issue_number} key=${worktree_key}"
	return 0
}

_codegraph_usage() {
	printf 'Usage: %s launch|run <linked-worktree> [issue-number]\n' "$(basename "$_SCRIPT_PATH")"
	return 0
}

main() {
	local action="${1:-help}"
	local worktree_path="${2:-}"
	local issue_number="${3:-unknown}"
	case "$action" in
	launch)
		[[ -n "$worktree_path" ]] || {
			_codegraph_usage
			return 1
		}
		_codegraph_launch "$worktree_path" "$issue_number"
		;;
	run)
		[[ -n "$worktree_path" ]] || {
			_codegraph_usage
			return 1
		}
		_codegraph_run "$worktree_path" "$issue_number"
		;;
	help | --help | -h)
		_codegraph_usage
		;;
	*)
		_codegraph_usage >&2
		return 1
		;;
	esac
	return $?
}

main "$@"
