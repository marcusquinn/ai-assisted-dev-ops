#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-ledger-helper.sh — In-flight dispatch tracking ledger (GH#6696)
#
# Tracks workers between dispatch and PR creation to prevent duplicate
# dispatches. The pulse checks GitHub for open PRs to detect "already
# handled" targets, but workers take 10-15 minutes between dispatch and
# PR creation. During this window, the target appears unhandled and gets
# re-dispatched every pulse cycle.
#
# This ledger fills that gap: each dispatch registers an entry, and the
# pulse checks the ledger before dispatching. Entries expire after a
# configurable TTL (default 60 min) or are marked completed/failed by
# the worker on exit.
#
# Source shared-constants.sh for portable stat functions
#
# Storage: JSONL file at ~/.aidevops/.agent-workspace/tmp/dispatch-ledger.jsonl
# Each line is a JSON object with fields:
#   session_key  - unique worker session key (e.g., "issue-42")
#   issue_number - GitHub issue number (string, may be empty)
#   repo_slug    - owner/repo (may be empty for non-repo dispatches)
#   pid          - PID of the dispatching process
#   owner_process_start - stable process-start token when available
#   dispatched_at - ISO 8601 UTC timestamp
#   status       - "in-flight" | "completed" | "failed"
#   updated_at   - ISO 8601 UTC timestamp of last status change
#
# Concurrency: file-level flock for atomic reads/writes. Safe for
# concurrent pulse + worker access. Falls back to mkdir-based lock on
# systems without flock (macOS without util-linux). Lock acquisition
# fails closed — write operations abort if the lock cannot be obtained.
#
# Usage:
#   dispatch-ledger-helper.sh register --session-key KEY [--issue NUM] [--repo SLUG] [--pid PID] [--worktree PATH]
#     [--attempt-id ID --attempt-state-root DIR --attempt-state-file FILE --outcome-file FILE]
#   dispatch-ledger-helper.sh check --session-key KEY
#   dispatch-ledger-helper.sh check-issue --issue NUM [--repo SLUG]
#   dispatch-ledger-helper.sh check-issue NUM [SLUG]
#   dispatch-ledger-helper.sh complete --session-key KEY
#   dispatch-ledger-helper.sh fail --session-key KEY
#   dispatch-ledger-helper.sh record-recovery --session-key KEY --runner-key KEY --worktree PATH --branch BRANCH --changed-paths TEXT --recoverability STATE
#   dispatch-ledger-helper.sh expire [--ttl SECONDS]
#   dispatch-ledger-helper.sh count
#   dispatch-ledger-helper.sh status
#   dispatch-ledger-helper.sh help

set -euo pipefail

# shellcheck source=shared-constants.sh
_dlh_dir="${BASH_SOURCE[0]%/*}"
[[ -f "${_dlh_dir}/shared-constants.sh" ]] && source "${_dlh_dir}/shared-constants.sh"
# shellcheck source=worker-attempt-observability.sh
[[ -f "${_dlh_dir}/worker-attempt-observability.sh" ]] && source "${_dlh_dir}/worker-attempt-observability.sh"

LEDGER_DIR="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
LEDGER_FILE="${LEDGER_DIR}/dispatch-ledger.jsonl"
LEDGER_LOCK="${LEDGER_DIR}/dispatch-ledger.lock"
TIER_TELEMETRY_FILTER="${_dlh_dir}/dispatch-tier-telemetry.jq"
DEFAULT_TTL="${AIDEVOPS_DISPATCH_LEDGER_TTL:-3600}" # 60 minutes
PRELAUNCH_TTL="${AIDEVOPS_DISPATCH_PRELAUNCH_LEASE_TTL:-120}"
READY_TTL="${AIDEVOPS_DISPATCH_READY_LEASE_TTL:-7200}"
LEDGER_STATUS_ACTIVE="in-flight"
LEDGER_STATUS_COMPLETED="completed"
LEDGER_STATUS_FAILED="failed"
ATTEMPT_FINALIZATION_PENDING="awaiting-finalization"

_lease_device_id() {
	local id_file="${AIDEVOPS_DEVICE_ID_FILE:-${HOME}/.aidevops/state/device-id}"
	local id="${AIDEVOPS_DEVICE_ID:-}"
	if [[ -n "$id" && ! "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]]; then
		id=""
	fi
	if [[ -z "$id" && -r "$id_file" ]]; then
		id=$(tr -d '[:space:]' <"$id_file" 2>/dev/null || true)
		[[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || id=""
	fi
	if [[ -z "$id" ]]; then
		id="device-$(_now_epoch)-$$-${RANDOM:-0}"
		mkdir -p "${id_file%/*}" 2>/dev/null || true
		(umask 077; printf '%s\n' "$id" >"$id_file") 2>/dev/null || true
	fi
	printf '%s' "$id"
	return 0
}

_lease_latest_entry() {
	local session_key="$1"
	jq -sc --arg sk "$session_key" '[.[] | select(.session_key == $sk)] | last // empty' "$LEDGER_FILE" 2>/dev/null
	return $?
}

_lease_latest_entry_for_token() {
	local session_key="$1"
	local lease_token="$2"
	jq -sc --arg sk "$session_key" --arg token "$lease_token" \
		'[.[] | select(.session_key == $sk and (.lease_token // "") == $token)] | last // empty' \
		"$LEDGER_FILE" 2>/dev/null
	return $?
}

_lease_entry_is_active() {
	local entry="$1"
	local now_epoch="" expires_at="" phase="" status=""
	now_epoch=$(_now_epoch)
	expires_at=$(printf '%s' "$entry" | jq -r '.lease_expires_at // 0') || return 1
	phase=$(printf '%s' "$entry" | jq -r '.lease_phase // ""') || return 1
	status=$(printf '%s' "$entry" | jq -r '.status // ""') || return 1
	[[ "$status" == "$LEDGER_STATUS_ACTIVE" && "$phase" != "terminal" ]] || return 1
	[[ "$expires_at" =~ ^[0-9]+$ && "$expires_at" -ge "$now_epoch" ]] || return 1
	return 0
}

_lease_expiry() {
	local ttl="$1"
	local now_epoch=""
	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl=120
	now_epoch=$(_now_epoch)
	printf '%s' "$((now_epoch + ttl))"
	return 0
}

_append_tier_telemetry() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_tier="$3"
	local dispatch_model="$4"
	local now="$5"
	local session_key="$6"
	local attempt_id="$7"
	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"
	jq -cn --arg inum "$issue_number" --arg slug "$repo_slug" \
		--arg tier "$dispatch_tier" --arg model "$dispatch_model" --arg ts "$now" \
		--arg sk "$session_key" --arg aid "$attempt_id" \
		'{schema: 2, attempt_id: $aid, session_key: $sk, issue: $inum, repo: $slug, tier: $tier, model: $model, dispatched_at: $ts, outcome: "pending"}' \
		>>"$telemetry_file" 2>/dev/null || true
	return 0
}

#######################################
# Ensure ledger directory and file exist
#######################################
_ensure_ledger() {
	mkdir -p "$LEDGER_DIR" 2>/dev/null || true
	if [[ ! -f "$LEDGER_FILE" ]]; then
		touch "$LEDGER_FILE"
	fi
	return 0
}

#######################################
# Get the age in seconds of a directory's mtime.
# Args: $1 = directory path
# Returns: age in seconds via stdout (0 if directory absent or stat fails)
# Portable across BSD (macOS) and GNU (Linux) stat invocations.
#######################################
_lock_dir_age() {
	local dir="$1"
	local mtime=""
	local now=""
	if [[ ! -d "$dir" ]]; then
		echo "0"
		return 0
	fi
	mtime=$(_file_mtime_epoch "$dir")
	now=$(_now_epoch)
	echo "$((now - mtime))"
	return 0
}

#######################################
# Detect a stale ledger lock and clear it if so.
#
# Three-tier detection mirroring pulse-instance-lock.sh::_handle_existing_lock
# (GH#20025), but with ledger-appropriate semantics:
#   1. No valid PID in the lockdir → corrupt or pre-PID-file lock from
#      an older client. Use mtime as the staleness signal.
#   2. Owner PID dead → stale from SIGKILL/OOM/crash. Clear immediately.
#   3. Owner alive but lock age > AIDEVOPS_LEDGER_LOCK_MAX_AGE_S
#      (default 60s) → hung holder. Clear so we can re-acquire. Unlike
#      pulse-instance-lock we do NOT kill the owner — ledger ops should
#      complete in <100ms; a 60s+ hold means the holder is stuck and
#      the safe move is to steal the lock. Worst-case race outcome is a
#      single corrupted JSONL line, which the helper already tolerates
#      (registration failures are logged non-fatal upstream).
#
# Args:
#   $1 = lock directory path
#   $2 = pid file path (lock_dir/pid)
#   $3 = max age in seconds (threshold for force-reclaim)
# Returns: 0 if the lock was stale and was cleared, 1 if still live
#######################################
_ledger_lock_is_stale() {
	local lock_dir="$1"
	local pid_file="$2"
	local max_age="$3"
	local lock_pid=""
	local lock_age=""

	# Must still exist — race: another waiter may have just cleared it.
	if [[ ! -d "$lock_dir" ]]; then
		return 1
	fi

	if [[ -f "$pid_file" ]]; then
		lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
	fi

	# Tier 1: no valid PID file (corrupt, or pre-PID lock from old client)
	# Use mtime as the staleness signal.
	if [[ -z "$lock_pid" ]] || [[ ! "$lock_pid" =~ ^[0-9]+$ ]]; then
		lock_age=$(_lock_dir_age "$lock_dir")
		if [[ "$lock_age" -gt "$max_age" ]]; then
			rm -rf "$lock_dir" 2>/dev/null || true
			# Only return 0 if the directory was actually removed — if rm -rf
			# failed silently the caller would loop indefinitely via `continue`.
			[[ ! -d "$lock_dir" ]] && return 0
		fi
		return 1
	fi

	# Tier 2: owner PID is dead → stale (SIGKILL, OOM, crash)
	# Use kill -0 for consistency with cmd_check/cmd_check_issue/cmd_expire.
	if ! kill -0 "$lock_pid" 2>/dev/null; then
		rm -rf "$lock_dir" 2>/dev/null || true
		[[ ! -d "$lock_dir" ]] && return 0
		return 1
	fi

	# Tier 3: owner alive but lock too old → hung holder, steal lock
	lock_age=$(_lock_dir_age "$lock_dir")
	if [[ "$lock_age" -gt "$max_age" ]]; then
		rm -rf "$lock_dir" 2>/dev/null || true
		[[ ! -d "$lock_dir" ]] && return 0
		return 1
	fi

	return 1
}

#######################################
# Acquire file lock (fail-closed — aborts if lock cannot be obtained)
# Uses flock when available, falls back to mkdir-based lock.
#
# Stale-lock recovery (t2999): when the mkdir fallback path is used,
# each failed mkdir attempt checks whether the existing lock is stale
# (dead PID, corrupt PID file with old mtime, or hung-holder age
# ceiling) via _ledger_lock_is_stale. If stale, the lockdir is cleared
# and mkdir is retried. Without this, a worker killed mid-registration
# leaves a permanent lockdir that blocks all subsequent ledger writes.
# Canonical incident: marcusquinn/aidevops#21427 — a 24-day-old stale
# lockdir suppressed registration for the entire dispatch fleet.
#
# Returns: 0 on success, 1 on failure (caller must abort write)
#######################################
_acquire_lock() {
	if command -v flock &>/dev/null; then
		exec 8>"$LEDGER_LOCK"
		if ! flock -w 5 8 2>/dev/null; then
			echo "Error: could not acquire ledger lock: $LEDGER_LOCK" >&2
			return 1
		fi
		return 0
	fi

	# Portable fallback: mkdir is atomic on all POSIX systems
	local lock_dir="${LEDGER_LOCK}.d"
	local pid_file="${lock_dir}/pid"
	local max_age="${AIDEVOPS_LEDGER_LOCK_MAX_AGE_S:-60}"
	local attempts=0
	local max_attempts=50 # 50 × 0.1s = 5s timeout

	while ! mkdir "$lock_dir" 2>/dev/null; do
		# Stale-lock recovery (t2999): if the existing lock is stale,
		# clear it and retry mkdir immediately without burning an attempt.
		if _ledger_lock_is_stale "$lock_dir" "$pid_file" "$max_age"; then
			continue
		fi
		attempts=$((attempts + 1))
		if [[ "$attempts" -ge "$max_attempts" ]]; then
			echo "Error: could not acquire ledger lock (mkdir): $lock_dir" >&2
			return 1
		fi
		sleep 0.1
	done

	# Record holder PID inside the lockdir so future waiters can
	# detect a stale lock if we die before _release_lock runs.
	echo "$$" >"$pid_file" 2>/dev/null || true
	return 0
}

#######################################
# Release file lock
# Note: mkdir-based lock now contains a PID file (t2999), so we use
# `rm -rf` instead of `rmdir`. Backward-compatible — rm -rf also
# removes empty lockdirs left by older clients.
#######################################
_release_lock() {
	if command -v flock &>/dev/null; then
		flock -u 8 2>/dev/null || true
	else
		# Remove mkdir-based lock (and any PID file inside it)
		local lock_dir="${LEDGER_LOCK}.d"
		rm -rf "$lock_dir" 2>/dev/null || true
	fi
	return 0
}

#######################################
# Get current UTC timestamp in ISO 8601 format
#######################################
_now_utc() {
	date -u '+%Y-%m-%dT%H:%M:%SZ'
	return 0
}

#######################################
# Get current epoch seconds
#######################################
_now_epoch() {
	date -u '+%s'
	return 0
}

#######################################
# Parse ISO 8601 timestamp to epoch seconds
# Args: $1 = ISO timestamp
# Returns: epoch seconds via stdout
#######################################
_iso_to_epoch() {
	local ts="$1"
	# Try GNU date first (Linux), then BSD date (macOS)
	date -u -d "$ts" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null ||
		printf '%s' "0"
	return 0
}

_lease_registration_exists() {
	local session_key="$1"
	local lease_token="$2"
	[[ -s "$LEDGER_FILE" ]] || return 1
	local existing="" existing_token="" existing_status=""
	if [[ -n "$lease_token" ]]; then
		existing=$(_lease_latest_entry_for_token "$session_key" "$lease_token") || return 1
	else
		existing=$(_lease_latest_entry "$session_key") || return 1
	fi
	existing_token=$(printf '%s' "$existing" | jq -r '.lease_token // ""' 2>/dev/null) || return 1
	existing_status=$(printf '%s' "$existing" | jq -r '.status // ""' 2>/dev/null) || return 1
	if [[ -n "$lease_token" ]]; then
		[[ -n "$existing" && "$existing_token" == "$lease_token" ]] && _lease_entry_is_active "$existing"
		return $?
	fi
	[[ -n "$existing" && -z "$existing_token" && "$existing_status" == "$LEDGER_STATUS_ACTIVE" ]]
	return $?
}

_lease_terminal_registration_exists() {
	local session_key="$1"
	local lease_token="$2"
	[[ -n "$lease_token" && -s "$LEDGER_FILE" ]] || return 1
	local existing="" existing_token=""
	existing=$(_lease_latest_entry_for_token "$session_key" "$lease_token") || return 1
	existing_token=$(printf '%s' "$existing" | jq -r '.lease_token // ""' 2>/dev/null) || return 1
	[[ "$existing_token" == "$lease_token" ]] || return 1
	if _lease_entry_is_active "$existing"; then
		return 1
	fi
	return 0
}

_register_append_entry() {
	local session_key="$1"
	local attempt_id="$2"
	local attempt_state_root="$3"
	local attempt_state_file="$4"
	local outcome_file="$5"
	local issue_number="$6"
	local repo_slug="$7"
	local dispatch_pid="$8"
	local owner_process_start="$9"
	local now="${10}"
	local dispatch_tier="${11}"
	local dispatch_model="${12}"
	local worktree_path="${13}"
	local lease_token="${14}"
	local runner_device="${15}"
	local lease_expires_at="${16}"
	jq -cn \
		--arg sk "$session_key" --arg attempt "$attempt_id" \
		--arg attempt_state_root "$attempt_state_root" --arg attempt_state_file "$attempt_state_file" \
		--arg outcome_file "$outcome_file" --arg inum "$issue_number" --arg slug "$repo_slug" \
		--argjson pid "$dispatch_pid" --arg owner_process_start "$owner_process_start" --arg ts "$now" \
		--arg tier "$dispatch_tier" --arg model "$dispatch_model" --arg worktree "$worktree_path" \
		--arg token "$lease_token" --arg device "$runner_device" --argjson expires "$lease_expires_at" \
		--arg status "$LEDGER_STATUS_ACTIVE" \
		'{session_key: $sk, attempt_id: $attempt, attempt_state_root: $attempt_state_root, attempt_state_file: $attempt_state_file, outcome_file: $outcome_file, issue_number: $inum, repo_slug: $slug, pid: $pid, owner_process_start: $owner_process_start, dispatched_at: $ts, status: $status, updated_at: $ts, tier: $tier, model: $model, worktree_path: $worktree, lease_token:$token, runner_device:$device, lease_phase:"prelaunch", lease_expires_at:$expires}' \
		>>"$LEDGER_FILE"
	return $?
}

#######################################
# Register a new dispatch in the ledger
#
# Args (named):
#   --session-key KEY    (required) Unique session key
#   --issue NUM          (optional) GitHub issue number
#   --repo SLUG          (optional) owner/repo
#   --pid PID            (optional) PID of dispatch process, defaults to $$
#   --worktree PATH      (optional) worker worktree path
#
# Exit codes:
#   0 - registered successfully
#   1 - missing required args
#######################################
cmd_register() {
	local session_key=""
	local issue_number=""
	local repo_slug=""
	local dispatch_pid="$$"
	local dispatch_tier=""
	local dispatch_model=""
	local worktree_path=""
	local owner_process_start=""
	local lease_token="" attempt_id="" attempt_state_root="" attempt_state_file="" outcome_file=""
	local runner_device=""
	local lease_ttl="$PRELAUNCH_TTL"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--pid)
			dispatch_pid="${2:-$$}"
			shift 2
			;;
		--worktree) worktree_path="${2:-}"; shift 2 ;;
		--tier) dispatch_tier="${2:-}"; shift 2 ;;
		--model) dispatch_model="${2:-}"; shift 2 ;;
		--lease-token)
			lease_token="${2:-}"
			shift 2
			;;
		--attempt-id) attempt_id="${2:-}"; shift 2 ;;
		--attempt-state-root) attempt_state_root="${2:-}"; shift 2 ;;
		--attempt-state-file) attempt_state_file="${2:-}"; shift 2 ;;
		--outcome-file) outcome_file="${2:-}"; shift 2 ;;
		--device-id)
			runner_device="${2:-}"
			shift 2
			;;
		--lease-ttl)
			lease_ttl="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for register: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: register requires --session-key" >&2
		return 1
	fi
	if [[ -n "$attempt_state_root" || -n "$attempt_state_file" || -n "$outcome_file" ]]; then
		if [[ -z "$attempt_state_root" || -z "$attempt_state_file" || -z "$outcome_file" || -z "$attempt_id" ]] ||
			! declare -F worker_attempt_observability_binding_is_safe >/dev/null 2>&1 ||
			! worker_attempt_observability_binding_is_safe \
				"$attempt_state_root" "$attempt_state_file" "$outcome_file" "$attempt_id" "$session_key"; then
			echo "Error: register rejected unsafe or mismatched attempt-state binding" >&2
			return 1
		fi
	fi
	_ensure_ledger
	if ! _acquire_lock; then
		echo "Error: register aborted — could not acquire lock" >&2
		return 1
	fi
	if _lease_registration_exists "$session_key" "$lease_token"; then _release_lock; return 0; fi
	if _lease_terminal_registration_exists "$session_key" "$lease_token"; then
		_release_lock
		echo "Error: register refused terminal dispatch lease" >&2
		return 1
	fi
	local now
	now=$(_now_utc)
	owner_process_start=$(_process_start_token "$dispatch_pid" 2>/dev/null || true)

	[[ -n "$runner_device" ]] || runner_device=$(_lease_device_id)
	[[ "$lease_ttl" =~ ^[0-9]+$ ]] || lease_ttl="$PRELAUNCH_TTL"
	local lease_expires_at=""
	lease_expires_at=$(_lease_expiry "$lease_ttl")
	[[ -n "$attempt_id" ]] || attempt_id=$(aidevops_generate_execution_id "attempt")

	if ! _register_append_entry "$session_key" "$attempt_id" "$attempt_state_root" "$attempt_state_file" \
		"$outcome_file" "$issue_number" "$repo_slug" "$dispatch_pid" "$owner_process_start" "$now" \
		"$dispatch_tier" "$dispatch_model" "$worktree_path" "$lease_token" "$runner_device" "$lease_expires_at"; then
		_release_lock
		return 1
	fi
	_append_tier_telemetry "$issue_number" "$repo_slug" "$dispatch_tier" "$dispatch_model" "$now" "$session_key" "$attempt_id"
	_release_lock
	return 0
}

cmd_ready() {
	local session_key="" lease_token="" lease_ttl="$READY_TTL"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key) session_key="${2:-}"; shift 2 ;;
		--lease-token) lease_token="${2:-}"; shift 2 ;;
		--lease-ttl) lease_ttl="${2:-}"; shift 2 ;;
		*) echo "Error: Unknown option for ready: $1" >&2; return 1 ;;
		esac
	done
	[[ -n "$session_key" && -n "$lease_token" ]] || { echo "Error: ready requires --session-key and --lease-token" >&2; return 1; }
	_lease_append_transition "$session_key" "$lease_token" "ready" "$LEDGER_STATUS_ACTIVE" "$lease_ttl"
	return $?
}

_lease_append_transition() {
	local session_key="$1"
	local lease_token="$2"
	local lease_phase="$3"
	local status="$4"
	local lease_ttl="$5"
	local terminal_reason="${6:-}"
	_ensure_ledger
	_acquire_lock || return 1
	local current=""
	current=$(_lease_latest_entry_for_token "$session_key" "$lease_token") || current=""
	if [[ -z "$current" || "$(printf '%s' "$current" | jq -r '.lease_token // ""')" != "$lease_token" ]]; then
		_release_lock
		return 1
	fi
	local current_phase=""
	current_phase=$(printf '%s' "$current" | jq -r '.lease_phase // ""') || current_phase=""
	if ! _lease_entry_is_active "$current"; then
		_release_lock
		return 1
	fi
	if [[ "$lease_phase" == "ready" && "$current_phase" != "prelaunch" ]]; then
		_release_lock
		return 1
	fi
	if [[ "$lease_phase" == "terminal" && "$current_phase" != "prelaunch" && "$current_phase" != "ready" ]]; then
		_release_lock
		return 1
	fi
	local now="" expires=""
	now=$(_now_utc)
	expires=$(_lease_expiry "$lease_ttl")
	printf '%s' "$current" | jq -c --arg phase "$lease_phase" --arg status "$status" --arg ts "$now" --arg reason "$terminal_reason" --argjson expires "$expires" \
		'.lease_phase=$phase | .status=$status | .updated_at=$ts | .lease_expires_at=$expires | if $reason != "" then .terminal_reason=$reason else . end' >>"$LEDGER_FILE"
	_release_lock
	return 0
}

#######################################
# Persist runner-local dirty-worktree recovery metadata.
# Repeated updates replace the same session entry, making dirty markers
# idempotent while retaining the private worktree path off public threads.
#######################################
cmd_record_recovery() {
	local session_key=""
	local runner_key=""
	local worktree_path=""
	local branch_name=""
	local changed_paths=""
	local recoverability=""

	while [[ $# -gt 0 ]]; do
		local option="${1:-}"
		case "$option" in
		--session-key | --runner-key | --worktree | --branch | --changed-paths | --recoverability)
			[[ $# -ge 2 ]] || { echo "Error: $option requires an argument" >&2; return 1; }
			local option_value="$2"
			case "$option" in
			--session-key) session_key="$option_value" ;;
			--runner-key) runner_key="$option_value" ;;
			--worktree) worktree_path="$option_value" ;;
			--branch) branch_name="$option_value" ;;
			--changed-paths) changed_paths="$option_value" ;;
			--recoverability) recoverability="$option_value" ;;
			esac
			shift 2
			;;
		*) echo "Error: Unknown option for record-recovery: $option" >&2; return 1 ;;
		esac
	done

	[[ -n "$session_key" ]] || { echo "Error: record-recovery requires --session-key" >&2; return 1; }
	_ensure_ledger
	_acquire_lock || return 1
	local now=""
	now=$(_now_utc)
	local tmp_file=""
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX") || { _release_lock; return 1; }
	jq -c \
		--arg sk "$session_key" \
		--arg runner "$runner_key" \
		--arg worktree "$worktree_path" \
		--arg branch "$branch_name" \
		--arg paths "$changed_paths" \
		--arg recovery "$recoverability" \
		--arg ts "$now" \
		'if .session_key == $sk then
			.runner_key = $runner |
			.worktree_path = $worktree |
			.branch = $branch |
			.changed_paths = ($paths | split("\n") | map(select(length > 0))) |
			.recoverability = $recovery |
			.recovery_attempts = ((.recovery_attempts // 0) + 1) |
			.status = (if $recovery == "checkpointed" then "checkpointed" else "dirty-recovery" end) |
			.updated_at = $ts
		else . end' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null || cp "$LEDGER_FILE" "$tmp_file"
	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock
	return 0
}

#######################################
# Check if a session key has an in-flight entry
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - in-flight entry exists (do NOT dispatch)
#   1 - no in-flight entry (safe to dispatch)
# Output: entry JSON on stdout if found
#######################################
cmd_check() {
	local session_key=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for check: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: check requires --session-key" >&2
		return 1
	fi

	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		return 1
	fi

	local match
	match=$(_lease_latest_entry "$session_key") || match=""

	if [[ -z "$match" ]]; then
		return 1
	fi
	[[ "$(printf '%s' "$match" | jq -r '.status // ""')" == "$LEDGER_STATUS_ACTIVE" ]] || return 1
	if [[ -n "$(printf '%s' "$match" | jq -r '.lease_token // ""')" ]] && ! _lease_entry_is_active "$match"; then
		return 1
	fi

	# PID exit is only a local hint. Lease-aware entries remain protected until
	# explicit terminal evidence or expiry; legacy entries retain old behaviour.
	local entry_pid
	entry_pid=$(printf '%s' "$match" | jq -r '.pid // 0') || entry_pid=0
	if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
		if ! kill -0 "$entry_pid" 2>/dev/null && [[ "$(printf '%s' "$match" | jq -r '.lease_token // ""')" == "" ]]; then
			# PID is dead — mark as failed and return "safe to dispatch"
			cmd_fail --session-key "$session_key" 2>/dev/null || true
			return 1
		fi
	fi

	printf '%s\n' "$match"
	return 0
}

#######################################
# Check if an issue number has an in-flight entry
#
# Args:
#   --issue NUM          (required)
#   --repo SLUG          (optional) restrict to specific repo
#   Positional form also supported: check-issue NUM [SLUG]
#
# Exit codes:
#   0 - in-flight entry exists for this issue (do NOT dispatch)
#   1 - no in-flight entry (safe to dispatch)
# Output: entry JSON on stdout if found
#######################################
cmd_check_issue() {
	local issue_number=""
	local repo_slug=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--*)
			echo "Error: Unknown option for check-issue: $1" >&2
			return 1
			;;
		*)
			if [[ -z "$issue_number" ]]; then
				issue_number="$1"
			elif [[ -z "$repo_slug" ]]; then
				repo_slug="$1"
			else
				echo "Error: Unexpected positional arg for check-issue: $1" >&2
				return 1
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue_number" ]]; then
		echo "Error: check-issue requires --issue" >&2
		return 1
	fi

	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		return 1
	fi

	local match
	if [[ -n "$repo_slug" ]]; then
		match=$(jq -sc --arg inum "$issue_number" --arg slug "$repo_slug" --arg active "$LEDGER_STATUS_ACTIVE" \
			'[.[] | select(.issue_number == $inum and .repo_slug == $slug)] | last | select(.status == $active)' \
			"$LEDGER_FILE" 2>/dev/null) || match=""
	else
		match=$(jq -sc --arg inum "$issue_number" --arg active "$LEDGER_STATUS_ACTIVE" \
			'[.[] | select(.issue_number == $inum)] | last | select(.status == $active)' \
			"$LEDGER_FILE" 2>/dev/null) || match=""
	fi

	if [[ -z "$match" ]]; then
		return 1
	fi
	if [[ -n "$(printf '%s' "$match" | jq -r '.lease_token // ""')" ]] && ! _lease_entry_is_active "$match"; then
		return 1
	fi

	# Verify PID is still alive
	local entry_pid
	entry_pid=$(printf '%s' "$match" | jq -r '.pid // 0') || entry_pid=0
	if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
		if ! kill -0 "$entry_pid" 2>/dev/null && [[ "$(printf '%s' "$match" | jq -r '.lease_token // ""')" == "" ]]; then
			local sk
			sk=$(printf '%s' "$match" | jq -r '.session_key // ""') || sk=""
			if [[ -n "$sk" ]]; then
				cmd_fail --session-key "$sk" 2>/dev/null || true
			fi
			return 1
		fi
	fi

	printf '%s\n' "$match"
	return 0
}

#######################################
# Mark a session key as completed
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - marked completed (or entry not found — idempotent)
#######################################
cmd_complete() {
	local session_key=""
	local lease_token=""
	local attempt_id=""
	local reason=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--lease-token)
			lease_token="${2:-}"
			shift 2
			;;
		--attempt-id)
			attempt_id="${2:-}"
			shift 2
			;;
		--reason)
			reason="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for complete: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: complete requires --session-key" >&2
		return 1
	fi

	if [[ -n "$lease_token" ]]; then
		_lease_append_transition "$session_key" "$lease_token" "terminal" "$LEDGER_STATUS_COMPLETED" "0" "$reason"
		return $?
	else
		_update_status "$session_key" "$LEDGER_STATUS_COMPLETED" "" "$attempt_id"
	fi
	return 0
}

#######################################
# Read the typed terminal reason for an exact dispatch lease.
# Args: --session-key KEY --lease-token TOKEN
# Returns: 0 with a non-empty reason, 1 when absent or mismatched.
#######################################
cmd_terminal_reason() {
	local session_key=""
	local lease_token=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key) session_key="${2:-}"; shift 2 ;;
		--lease-token) lease_token="${2:-}"; shift 2 ;;
		*) echo "Error: Unknown option for terminal-reason: $1" >&2; return 1 ;;
		esac
	done
	[[ -n "$session_key" && -n "$lease_token" ]] || return 1
	_ensure_ledger
	local entry=""
	entry=$(_lease_latest_entry "$session_key") || entry=""
	[[ -n "$entry" ]] || return 1
	[[ "$(printf '%s' "$entry" | jq -r '.lease_token // ""')" == "$lease_token" ]] || return 1
	local reason=""
	reason=$(printf '%s' "$entry" | jq -r 'select(.lease_phase == "terminal") | .terminal_reason // ""') || reason=""
	[[ -n "$reason" ]] || return 1
	printf '%s\n' "$reason"
	return 0
}

#######################################
# Mark a session key as failed
#
# Args:
#   --session-key KEY    (required)
#
# Exit codes:
#   0 - marked failed (or entry not found — idempotent)
#######################################
cmd_fail() {
	local session_key=""
	local lease_token=""
	local attempt_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--lease-token)
			lease_token="${2:-}"
			shift 2
			;;
		--attempt-id)
			attempt_id="${2:-}"
			shift 2
			;;
		*)
			echo "Error: Unknown option for fail: $1" >&2
			return 1
			;;
		esac
	done

	if [[ -z "$session_key" ]]; then
		echo "Error: fail requires --session-key" >&2
		return 1
	fi

	_update_status "$session_key" "$LEDGER_STATUS_FAILED" "$lease_token" "$attempt_id"
	return 0
}

#######################################
# Record dispatch outcome in the tier telemetry log
#
# Appends one correlated terminal outcome to tier-telemetry.jsonl. The first
# terminal event for an attempt wins, making retries and repeated cleanup safe.
#
# Args:
#   --issue NUM          issue number
#   --repo SLUG          repo slug
#   --outcome OUTCOME    "success" | "escalated" | "failed" | "timeout"
#   --reason REASON      escalation reason code (optional)
#   --tokens NUM         tokens used (optional)
#   --tier TIER          tier at dispatch time (optional, for context)
#   --session-key KEY    worker session key (preferred correlation fallback)
#   --lease-token TOKEN  dispatch lease token (preferred exact correlation)
#   --attempt-id ID      explicit telemetry attempt ID
#
# Exit codes: 0 always (best-effort, never fatal)
#######################################
_find_pending_telemetry_attempt() {
	local telemetry_file="$1"
	local attempt_id="$2"
	local session_key="$3"
	local issue_number="$4"
	local repo_slug="$5"

	jq -sc -f "$TIER_TELEMETRY_FILTER" --arg operation find \
		--arg aid "$attempt_id" --arg sk "$session_key" \
		--arg inum "$issue_number" --arg slug "$repo_slug" "$telemetry_file" 2>/dev/null
	return 0
}

_resolve_attempt_id_from_lease() {
	local lease_token="$1"
	local session_key="$2"
	local issue_number="$3"
	local repo_slug="$4"

	[[ -n "$lease_token" && -s "$LEDGER_FILE" ]] || return 0
	jq -rs --arg token "$lease_token" --arg sk "$session_key" \
		--arg inum "$issue_number" --arg slug "$repo_slug" \
		'[.[] | select(
			(.lease_token // "") == $token and
			($sk == "" or (.session_key // "") == $sk) and
			($inum == "" or (.issue_number // "") == $inum) and
			($slug == "" or (.repo_slug // "") == $slug)
		)] | last | .attempt_id // empty' "$LEDGER_FILE" 2>/dev/null
	return 0
}

_append_terminal_telemetry() {
	local telemetry_file="$1"
	local attempt_id="$2"
	local session_key="$3"
	local issue_number="$4"
	local repo_slug="$5"
	local tier="$6"
	local model="$7"
	local outcome="$8"
	local reason="$9"
	local tokens="${10}"
	local now=""
	now=$(_now_utc)

	jq -cn --argjson schema 2 --arg aid "$attempt_id" --arg sk "$session_key" \
		--arg inum "$issue_number" --arg slug "$repo_slug" --arg tier "$tier" \
		--arg model "$model" --arg outcome "$outcome" --arg reason "$reason" \
		--argjson tokens "$tokens" --arg ts "$now" \
		'{schema: $schema, attempt_id: $aid, session_key: $sk, issue: $inum, repo: $slug, tier: $tier, model: $model, outcome: $outcome, reason: $reason, tokens: $tokens, completed_at: $ts}' \
		>>"$telemetry_file" 2>/dev/null || true
	return 0
}

cmd_record_outcome() {
	local issue_number=""
	local repo_slug=""
	local outcome=""
	local reason=""
	local tokens="0"
	local tier=""
	local session_key=""
	local lease_token=""
	local attempt_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--issue)
			issue_number="${2:-}"
			shift 2
			;;
		--repo)
			repo_slug="${2:-}"
			shift 2
			;;
		--outcome)
			outcome="${2:-}"
			shift 2
			;;
		--reason)
			reason="${2:-}"
			shift 2
			;;
		--tokens)
			tokens="${2:-0}"
			shift 2
			;;
		--tier)
			tier="${2:-}"
			shift 2
			;;
		--session-key)
			session_key="${2:-}"
			shift 2
			;;
		--lease-token)
			lease_token="${2:-}"
			shift 2
			;;
		--attempt-id)
			attempt_id="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	[[ -n "$outcome" ]] || return 0
	[[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"
	_ensure_ledger
	touch "$telemetry_file" 2>/dev/null || return 0
	if ! _acquire_lock; then
		return 0
	fi

	if [[ -z "$attempt_id" && -n "$lease_token" ]]; then
		attempt_id=$(_resolve_attempt_id_from_lease "$lease_token" "$session_key" \
			"$issue_number" "$repo_slug" || true)
	fi
	local pending=""
	pending=$(_find_pending_telemetry_attempt "$telemetry_file" "$attempt_id" \
		"$session_key" "$issue_number" "$repo_slug" || true)

	if [[ -n "$pending" ]]; then
		attempt_id=$(printf '%s' "$pending" | jq -r '.attempt_id')
		[[ -n "$session_key" ]] || session_key=$(printf '%s' "$pending" | jq -r '.session_key // ""')
		[[ -n "$issue_number" ]] || issue_number=$(printf '%s' "$pending" | jq -r '.issue // ""')
		[[ -n "$repo_slug" ]] || repo_slug=$(printf '%s' "$pending" | jq -r '.repo // ""')
		tier=$(printf '%s' "$pending" | jq -r '.tier // ""')
		local model=""
		model=$(printf '%s' "$pending" | jq -r '.model // ""')
	else
		local model=""
		if [[ -z "$attempt_id" ]]; then
			_release_lock
			return 0
		fi
	fi

	if [[ -n "$attempt_id" ]] && jq -ne --arg aid "$attempt_id" \
		'any(inputs; .outcome != "pending" and (.attempt_id // "") == $aid)' \
		"$telemetry_file" >/dev/null; then
		_release_lock
		return 0
	fi

	_append_terminal_telemetry "$telemetry_file" "$attempt_id" "$session_key" \
		"$issue_number" "$repo_slug" "$tier" "$model" "$outcome" "$reason" "$tokens"
	_release_lock

	return 0
}

#######################################
# Report tier telemetry summary
#
# Reads tier-telemetry.jsonl and outputs aggregate stats.
# Used by the pulse sweep and /optimize-tiers command.
#
# Exit codes: 0 always
#######################################
cmd_tier_report() {
	local telemetry_file="${LEDGER_DIR}/tier-telemetry.jsonl"

	if [[ ! -s "$telemetry_file" ]]; then
		echo "No tier telemetry data yet."
		return 0
	fi

	local summary=""
	summary=$(jq -sc -f "$TIER_TELEMETRY_FILTER" --arg operation report \
		--arg aid "" --arg sk "" --arg inum "" --arg slug "" \
		"$telemetry_file" 2>/dev/null) || summary='{}'

	local total success escalated failed deferred pending_unknown unmatched
	total=$(printf '%s' "$summary" | jq -r '.total // 0')
	success=$(printf '%s' "$summary" | jq -r '.success // 0')
	escalated=$(printf '%s' "$summary" | jq -r '.escalated // 0')
	failed=$(printf '%s' "$summary" | jq -r '.failed // 0')
	deferred=$(printf '%s' "$summary" | jq -r '.deferred // 0')
	pending_unknown=$(printf '%s' "$summary" | jq -r '.pending_unknown // 0')
	unmatched=$(printf '%s' "$summary" | jq -r '.unmatched // 0')

	echo "=== Tier Dispatch Telemetry ==="
	echo "Total dispatches: $total"
	echo "Success: $success"
	echo "Escalated: $escalated"
	echo "Failed: $failed"
	echo "Deferred/timeout: $deferred"
	echo "Pending/unknown: $pending_unknown"
	echo "Legacy/unmatched terminal events: $unmatched"
	echo ""
	echo "By tier:"
	printf '%s' "$summary" | jq -r '.by_tier[] | "\(.count | tostring | if length < 6 then (" " * (6 - length)) + . else . end) \(.tier)"'
	echo ""
	echo "Escalation reasons:"
	printf '%s' "$summary" | jq -r '.reasons[] | "\(.count | tostring | if length < 6 then (" " * (6 - length)) + . else . end) \(.reason)"'
	echo ""
	echo "Pass rate by tier:"
	printf '%s' "$summary" | jq -r '.pass_rates[] | select(.tier != "" and .total > 0) | [.tier, .success, .total] | @tsv' |
		while IFS=$'\t' read -r tier_name tier_success tier_total; do
			local pct=""
			pct=$(awk "BEGIN {printf \"%.1f\", ${tier_success}/${tier_total}*100}")
			printf '  tier:%s — %s/%s (%s%%)\n' "$tier_name" "$tier_success" "$tier_total" "$pct"
		done

	return 0
}

#######################################
# Update the status of a ledger entry
# Args: $1 = session_key, $2 = new status
#######################################
_update_status() {
	local session_key="$1"
	local new_status="$2"
	local lease_token="${3:-}"
	local attempt_id="${4:-}"
	if [[ -n "$lease_token" ]]; then
		_lease_append_transition "$session_key" "$lease_token" "terminal" "$new_status" "0"
		return $?
	fi

	_ensure_ledger
	if ! _acquire_lock; then
		echo "Error: _update_status aborted — could not acquire lock for session_key=${session_key}" >&2
		return 1
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		return 0
	fi

	local now
	now=$(_now_utc)
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	# Only transition entries that are still "in-flight" — terminal statuses
	# ("completed", "failed") are immutable. A late fail from dead-PID cleanup
	# must not overwrite a genuinely completed dispatch.
	jq -c --arg sk "$session_key" --arg aid "$attempt_id" --arg st "$new_status" --arg ts "$now" --arg active "$LEDGER_STATUS_ACTIVE" \
		'if .session_key == $sk and .status == $active and ($aid == "" or (.attempt_id // "") == $aid)
			then .status = $st | .updated_at = $ts
			else .
		end' \
		"$LEDGER_FILE" >"$tmp_file" 2>/dev/null || cp "$LEDGER_FILE" "$tmp_file"

	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock
	return 0
}

#######################################
# Expire old in-flight entries
# Parse expire command options and print a validated TTL.
# Args: expire command args
#######################################
_cmd_expire_parse_ttl() {
	local ttl="$DEFAULT_TTL"
	local option=""
	local ttl_arg=""

	while [[ $# -gt 0 ]]; do
		option="${1:-}"
		case "$option" in
		--ttl)
			if [[ $# -lt 2 ]]; then
				echo "Error: --ttl requires an argument" >&2
				return 1
			fi

			ttl_arg="${2:-}"
			ttl="$ttl_arg"
			shift 2
			;;
		*)
			echo "Error: Unknown option for expire: $option" >&2
			return 1
			;;
		esac
	done

	[[ "$ttl" =~ ^[0-9]+$ ]] || ttl="$DEFAULT_TTL"
	printf '%s\n' "$ttl"
	return 0
}

#######################################
# Collect ledger line indices that should be expired.
# Args: $1 = ttl seconds, $2 = current epoch seconds
# Output: newline-separated zero-based ledger indices
#######################################
_cmd_expire_collect_indices() {
	local ttl="$1"
	local now_epoch="$2"
	local tsv_data=""
	local idx=""
	local status=""
	local dispatched_at=""
	local entry_pid=""
	local owner_process_start=""
	local current_process_start=""
	local lease_expires_at=""
	local dispatch_epoch=""
	local age=""
	local -i should_expire=0

	# GH#21105: single-pass jq extraction. The previous loop forked jq up to
	# 3x per line (status, dispatched_at, pid) — for 600+ ledger entries this
	# was ~10s per cycle. One jq invocation produces all needed metadata as TSV;
	# bash then performs the kill -0 liveness checks (which jq cannot do) and
	# decides which entries to expire. Final rewrite uses a single jq pass too.
	tsv_data=$(jq -nr '
		[inputs] | to_entries
		| group_by([.value.session_key, .value.lease_token, .value.attempt_id] | map(. // ""))[]
		| max_by(.key)
		| .key as $idx | .value as $v
		| [$idx, $v.status, $v.dispatched_at, $v.pid, $v.owner_process_start, $v.lease_expires_at]
		| map(. // "") | join("\u001c")
	' "$LEDGER_FILE" 2>/dev/null) || tsv_data=""

	while IFS=$'\034' read -r idx status dispatched_at entry_pid owner_process_start lease_expires_at; do
		[[ -z "$idx" ]] && continue
		[[ "$status" != "$LEDGER_STATUS_ACTIVE" ]] && continue

		should_expire=0
		if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
			if ! kill -0 "$entry_pid" 2>/dev/null; then
				should_expire=1
			elif [[ -n "$owner_process_start" ]]; then
				current_process_start=$(_process_start_token "$entry_pid" 2>/dev/null || true)
				[[ -n "$current_process_start" && "$current_process_start" != "$owner_process_start" ]] && should_expire=1
			fi
		fi
		if ((!should_expire)) && [[ "$lease_expires_at" =~ ^[0-9]+$ ]] && [[ "$lease_expires_at" -gt 0 ]]; then
			[[ "$lease_expires_at" -lt "$now_epoch" ]] && should_expire=1
		elif ((!should_expire)) && [[ -n "$dispatched_at" ]]; then
			dispatch_epoch=$(_iso_to_epoch "$dispatched_at")
			if [[ "$dispatch_epoch" =~ ^[0-9]+$ ]] && [[ "$dispatch_epoch" -gt 0 ]]; then
				age=$((now_epoch - dispatch_epoch))
				[[ "$age" -gt "$ttl" ]] && should_expire=1
			fi
		fi

		if ((should_expire)); then
			printf '%s\n' "$idx"
		fi
	done <<<"$tsv_data"

	return 0
}

#######################################
# Rewrite the ledger, marking selected indices failed.
# Args: $1 = comma-separated indices, $2 = updated_at timestamp,
#       $3 = current epoch seconds, $4 = tmp file
#######################################
_cmd_expire_rewrite_failed() {
	local indices_csv="$1"
	local now_ts="$2"
	local now_epoch="$3"
	local tmp_file="$4"

	# Two subtleties learned the hard way during GH#21105:
	#   1. -n is REQUIRED: without it, jq consumes the first JSON line as
	#      its initial input, then `[inputs]` collects only entries 2..N.
	#      Indices in $exp (assigned by the matching -n TSV pass above)
	#      become off-by-one, and the first ledger entry is silently
	#      dropped from the rewritten file.
	#   2. .key MUST be bound to $k BEFORE the pipe into $exp. Writing
	#      `$exp | index(.key)` evaluates `.key` against $exp (an array)
	#      and jq raises "Cannot index array with string 'key'", which
	#      `2>/dev/null` would swallow into the cp fallback path.
	jq -nc --arg ts "$now_ts" --arg failed "$LEDGER_STATUS_FAILED" --arg finalization_pending "$ATTEMPT_FINALIZATION_PENDING" --argjson now "$now_epoch" --argjson exp "[${indices_csv}]" '
		def present: . != null and . != "";
		[inputs] | to_entries[]
		| .key as $k
		| if (($exp | index($k)) != null)
		  then .value |
			.status = $failed |
			.updated_at = $ts |
			.terminal_reason = (
				if ((.lease_expires_at // 0) < $now and (.lease_phase // "") == "prelaunch")
				then "prelaunch_lease_expired"
				elif ((.lease_expires_at // 0) < $now and (.lease_phase // "") == "ready")
				then "ready_lease_expired"
				else "dispatch_process_unavailable_or_ttl"
				end
			) |
			.attempt_finalization_status = (
				if ([.attempt_id, .attempt_state_root, .attempt_state_file, .outcome_file] | all(present))
				then $finalization_pending else "not-required" end
			)
		  else .value
		  end
	' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null
	return $?
}

_cmd_expire_collect_pending_finalizations() {
	local limit="${AIDEVOPS_DISPATCH_FINALIZATION_RETRY_LIMIT:-20}"
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=20
	jq -nr --argjson limit "$limit" --arg finalization_pending "$ATTEMPT_FINALIZATION_PENDING" '
		[inputs]
		| group_by([.session_key, .lease_token, .attempt_id] | map(. // ""))
		| map(last)
		| map(select(.attempt_finalization_status == $finalization_pending))
		| .[0:$limit][]
		| [.attempt_state_root, .attempt_state_file, .outcome_file, .attempt_id, .session_key]
		  + [(.terminal_reason // "dispatch_process_unavailable")]
		| map(. // "")
		| join("\u001c")
	' "$LEDGER_FILE" 2>/dev/null
	return $?
}

_cmd_expire_mark_finalization_completed() {
	local attempt_id="$1"
	local attempt_state_file="$2"
	local now_ts=""
	local tmp_file=""
	_ensure_ledger
	_acquire_lock || return 1
	now_ts=$(_now_utc)
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX") || {
		_release_lock
		return 1
	}
	if ! jq -c --arg attempt "$attempt_id" --arg state_file "$attempt_state_file" --arg ts "$now_ts" --arg finalization_pending "$ATTEMPT_FINALIZATION_PENDING" '
		if .attempt_id == $attempt and
			.attempt_state_file == $state_file and
			.attempt_finalization_status == $finalization_pending
		then .attempt_finalization_status = "finalized" | .attempt_finalized_at = $ts
		else . end
	' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null; then
		rm -f "$tmp_file"
		_release_lock
		return 1
	fi
	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock
	return 0
}

_cmd_expire_reconcile_pending() {
	local pending_records=""
	local state_root=""
	local state_file=""
	local outcome_file=""
	local attempt_id=""
	local session_key=""
	local reason=""
	declare -F worker_attempt_observability_finalize_abandoned >/dev/null 2>&1 || return 0
	pending_records=$(_cmd_expire_collect_pending_finalizations) || pending_records=""
	while IFS=$'\034' read -r state_root state_file outcome_file attempt_id session_key reason; do
		[[ -n "$state_root" ]] || continue
		if worker_attempt_observability_finalize_abandoned \
			"$state_root" "$state_file" "$outcome_file" "$attempt_id" "$session_key" "$reason"; then
			_cmd_expire_mark_finalization_completed "$attempt_id" "$state_file" ||
				printf 'Warning: attempt finalization succeeded but ledger acknowledgement failed for attempt=%s\n' "$attempt_id" >&2
		else
			printf 'Warning: deferred unsafe or unavailable attempt finalization for attempt=%s\n' "$attempt_id" >&2
		fi
	done <<<"$pending_records"
	return 0
}

#######################################
# Expire old in-flight entries
#
# Entries older than TTL seconds are marked "failed" (assumed dead).
# Entries with dead PIDs are also marked "failed" regardless of age.
#
# Args:
#   --ttl SECONDS    (optional, default: $DEFAULT_TTL)
#
# Exit codes:
#   0 - always (best-effort cleanup)
# Output: count of expired entries
#######################################
cmd_expire() {
	local ttl=""
	ttl=$(_cmd_expire_parse_ttl "$@") || return 1

	_ensure_ledger
	if ! _acquire_lock; then
		printf '%s\n' "0"
		return 0 # Best-effort cleanup
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		printf '%s\n' "0"
		return 0
	fi

	local now_epoch
	now_epoch=$(_now_epoch)
	local now_ts
	now_ts=$(_now_utc)
	local expired_count=0
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")
	local expire_indices=""
	expire_indices=$(_cmd_expire_collect_indices "$ttl" "$now_epoch")

	if [[ -n "$expire_indices" ]]; then
		local indices_csv=""
		local expire_index=""
		while IFS= read -r expire_index; do
			[[ -z "$expire_index" ]] && continue
			expired_count=$((expired_count + 1))
			if [[ -z "$indices_csv" ]]; then
				indices_csv="$expire_index"
			else
				indices_csv="${indices_csv},${expire_index}"
			fi
		done <<<"$expire_indices"
		# Single jq pass rewrites the file: entries at the listed indices have
		# their status flipped to "failed" with a fresh updated_at timestamp.
		if ! _cmd_expire_rewrite_failed "$indices_csv" "$now_ts" "$now_epoch" "$tmp_file"; then
			# jq failure: preserve original file rather than risk corruption.
			cp "$LEDGER_FILE" "$tmp_file"
			expired_count=0
		fi
		mv "$tmp_file" "$LEDGER_FILE"
	else
		rm -f "$tmp_file"
	fi

	_release_lock
	_cmd_expire_reconcile_pending

	printf '%s\n' "$expired_count"
	return 0
}

#######################################
# Count in-flight entries (with PID liveness check)
#
# Exit codes: 0 always
# Output: count of live in-flight entries
#######################################
cmd_count() {
	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		printf '%s\n' "0"
		return 0
	fi

	local count=0
	local inflight_pids
	# GH#22289: keep this as one jq pass. The previous implementation first
	# selected in-flight JSON lines, then forked jq once per entry to extract
	# pid. On a 1200-entry synthetic ledger that made `count` take ~2.4s.
	# A single jq pass emits just the PIDs; bash keeps the kill -0 liveness
	# checks because jq cannot query process state.
	inflight_pids=$(jq -sr --arg active "$LEDGER_STATUS_ACTIVE" '
		group_by([.session_key, (.lease_token // ""), (.attempt_id // "")])
		| map(last)
		| .[]
		| select(.status == $active and (.lease_phase // "prelaunch") != "terminal")
		| (.pid // 0)
	' "$LEDGER_FILE" 2>/dev/null) || inflight_pids=""

	if [[ -z "$inflight_pids" ]]; then
		printf '%s\n' "0"
		return 0
	fi

	local entry_pid
	while IFS= read -r entry_pid; do
		[[ -z "$entry_pid" ]] && continue
		if [[ "$entry_pid" =~ ^[0-9]+$ ]] && [[ "$entry_pid" -gt 0 ]]; then
			if kill -0 "$entry_pid" 2>/dev/null; then
				count=$((count + 1))
			fi
		else
			# No valid PID — count it (conservative; expire will clean up)
			count=$((count + 1))
		fi
	done <<<"$inflight_pids"

	printf '%s\n' "$count"
	return 0
}

#######################################
# Show ledger status (all entries, human-readable)
#
# Exit codes: 0 always
# Output: formatted status table
#######################################
cmd_status() {
	_ensure_ledger

	if [[ ! -s "$LEDGER_FILE" ]]; then
		echo "Dispatch ledger is empty"
		return 0
	fi

	local total inflight completed failed status_counts
	# GH#22289: compute all status counts in one jq process instead of three
	# jq+wc pipelines. The win is modest compared with cmd_count, but this is
	# still a hot diagnostic path and preserves the single-pass ledger pattern.
	status_counts=$(jq -nr --arg active "$LEDGER_STATUS_ACTIVE" '
		[inputs.status // ""] as $statuses
		| [
			($statuses | length),
			($statuses | map(select(. == $active)) | length),
			($statuses | map(select(. == "completed")) | length),
			($statuses | map(select(. == "failed")) | length)
		]
		| @tsv
	' "$LEDGER_FILE" 2>/dev/null) || status_counts=$'0\t0\t0\t0'
	IFS=$'\t' read -r total inflight completed failed <<<"$status_counts"
	[[ "$total" =~ ^[0-9]+$ ]] || total=0
	[[ "$inflight" =~ ^[0-9]+$ ]] || inflight=0
	[[ "$completed" =~ ^[0-9]+$ ]] || completed=0
	[[ "$failed" =~ ^[0-9]+$ ]] || failed=0

	echo "Dispatch Ledger Status"
	echo "  Total entries: ${total}"
	echo "  In-flight:     ${inflight}"
	echo "  Completed:     ${completed}"
	echo "  Failed:        ${failed}"
	echo ""

	if [[ "$inflight" -gt 0 ]]; then
		echo "In-flight entries:"
		jq -r --arg active "$LEDGER_STATUS_ACTIVE" 'select(.status == $active) | "  \(.session_key) | issue=\(.issue_number) | repo=\(.repo_slug) | pid=\(.pid) | since=\(.dispatched_at)"' "$LEDGER_FILE" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Prune completed/failed entries older than 24h
# Keeps the ledger file from growing indefinitely.
#
# Exit codes: 0 always
# Output: count of pruned entries
#######################################
cmd_prune() {
	_ensure_ledger
	if ! _acquire_lock; then
		printf '%s\n' "0"
		return 0 # Best-effort cleanup — skip if locked
	fi

	if [[ ! -s "$LEDGER_FILE" ]]; then
		_release_lock
		printf '%s\n' "0"
		return 0
	fi

	local now_epoch prune_threshold pruned_count orig_count new_count
	now_epoch=$(_now_epoch)
	prune_threshold=86400 # 24 hours
	pruned_count=0
	local tmp_file
	tmp_file=$(mktemp "${LEDGER_DIR}/dispatch-ledger.XXXXXX")

	# GH#21105: single-pass jq filter. Previously this loop forked jq up to 2x
	# per line (status, updated_at) — for 600+ ledger entries this was ~7s per
	# cycle. The new filter processes all entries in one jq invocation:
	# in-flight entries are always kept; completed/failed entries are kept only
	# when updated_at is within the prune threshold (default 24h). Empty/
	# unparseable updated_at values are kept (fail-open) to avoid silent loss.
	#
	# fromdateiso8601 in jq parses RFC 3339 / ISO 8601 with the 'Z' suffix
	# directly; the try/catch falls back to "$now" so unparseable timestamps
	# keep the entry rather than dropping it.
	if ! jq -c --argjson now "$now_epoch" --argjson threshold "$prune_threshold" --arg active "$LEDGER_STATUS_ACTIVE" '
		select(
			(.status == $active)
			or
			(((.updated_at // "") | length) == 0)
			or
			(($now - ((.updated_at) | try fromdateiso8601 catch $now)) <= $threshold)
		)
	' "$LEDGER_FILE" >"$tmp_file" 2>/dev/null; then
		# jq failure: preserve original ledger rather than risk corruption.
		cp "$LEDGER_FILE" "$tmp_file"
	fi

	# Pruned count = original line count - kept line count.
	orig_count=$(wc -l <"$LEDGER_FILE" | tr -d ' ')
	new_count=$(wc -l <"$tmp_file" | tr -d ' ')
	[[ "$orig_count" =~ ^[0-9]+$ ]] || orig_count=0
	[[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
	pruned_count=$((orig_count - new_count))
	[[ "$pruned_count" -lt 0 ]] && pruned_count=0

	mv "$tmp_file" "$LEDGER_FILE"
	_release_lock

	printf '%s\n' "$pruned_count"
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-ledger-helper.sh — In-flight dispatch tracking ledger (GH#6696)

Tracks workers between dispatch and PR creation to prevent duplicate
dispatches during the 10-15 minute window before a worker creates its PR.

Usage:
  dispatch-ledger-helper.sh register --session-key KEY [--issue NUM] [--repo SLUG] [--pid PID]
    [--attempt-id ID --attempt-state-root DIR --attempt-state-file FILE --outcome-file FILE]
    Register a new dispatch. Optional attempt bindings let verified expiry
    finalize the exact durable attempt and typed outcome.

  dispatch-ledger-helper.sh check --session-key KEY
    Check if session key has an in-flight entry. Exit 0=in-flight, 1=safe.

  dispatch-ledger-helper.sh check-issue --issue NUM [--repo SLUG]
    Check if issue has an in-flight entry. Exit 0=in-flight, 1=safe.

  dispatch-ledger-helper.sh complete --session-key KEY [--lease-token TOKEN] [--reason REASON]
    Mark dispatch as completed (worker finished successfully).

  dispatch-ledger-helper.sh terminal-reason --session-key KEY --lease-token TOKEN
    Read the typed terminal reason for an exact dispatch generation.

  dispatch-ledger-helper.sh fail --session-key KEY
    Mark dispatch as failed (worker errored or timed out).

  dispatch-ledger-helper.sh record-outcome --outcome OUTCOME [--session-key KEY]
    Record one correlated terminal tier-telemetry event. First outcome wins.

  dispatch-ledger-helper.sh tier-report
    Report logical dispatch attempts, terminal outcomes, and pass rates by tier.

  dispatch-ledger-helper.sh expire [--ttl SECONDS]
    Expire stale in-flight entries (default TTL: 3600s / 60 min).
    Also expires entries with dead PIDs or expired generation leases and
    retries bounded pending attempt finalization.

  dispatch-ledger-helper.sh count
    Count live in-flight entries (with PID liveness check).

  dispatch-ledger-helper.sh status
    Show human-readable ledger status.

  dispatch-ledger-helper.sh prune
    Remove completed/failed entries older than 24h.

  dispatch-ledger-helper.sh help
    Show this help.

Environment:
  AIDEVOPS_DISPATCH_LEDGER_DIR   Override ledger directory
  AIDEVOPS_DISPATCH_LEDGER_TTL   Override default TTL in seconds (default: 3600)
  AIDEVOPS_DISPATCH_FINALIZATION_RETRY_LIMIT  Bound pending finalizers per expiry (default: 20)

Examples:
  # Register before dispatching a worker
  dispatch-ledger-helper.sh register --session-key "issue-42" --issue 42 --repo owner/repo --pid $!

  # Check before dispatching (in pulse dedup)
  if dispatch-ledger-helper.sh check-issue --issue 42 --repo owner/repo; then
    echo "Already in-flight — skip dispatch"
  fi

  # Worker marks completion on exit
  dispatch-ledger-helper.sh complete --session-key "issue-42"

  # Pulse runs expire at start of each cycle
  dispatch-ledger-helper.sh expire --ttl 3600
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	register)
		cmd_register "$@"
		;;
	ready)
		cmd_ready "$@"
		;;
	check)
		cmd_check "$@"
		;;
	check-issue)
		cmd_check_issue "$@"
		;;
	complete)
		cmd_complete "$@"
		;;
	terminal-reason)
		cmd_terminal_reason "$@"
		;;
	fail)
		cmd_fail "$@"
		;;
	record-recovery)
		cmd_record_recovery "$@"
		;;
	record-outcome)
		cmd_record_outcome "$@"
		;;
	tier-report)
		cmd_tier_report
		;;
	expire)
		cmd_expire "$@"
		;;
	count)
		cmd_count
		;;
	status)
		cmd_status
		;;
	prune)
		cmd_prune
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
