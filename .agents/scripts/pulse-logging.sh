#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-logging.sh — Pulse logging plumbing — log rotation, cycle index, and health file writer.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - cycle-state lifecycle and projection helpers
#   - rotate_pulse_log
#   - append_cycle_index
#   - write_pulse_health_file
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_LOGGING_LOADED:-}" ]] && return 0
_PULSE_LOGGING_LOADED=1

PULSE_CYCLE_STATE_SCHEMA="aidevops.pulse-cycle-state/v1"
PULSE_CYCLE_STATE_ARRAY_TYPE="array"
PULSE_CYCLE_STATE_BLOCKER_NONE="none"
PULSE_CYCLE_STATE_OBJECT_TYPE="object"
_PULSE_CYCLE_STATE_INITIALIZED=0
_PULSE_CYCLE_STATE_TERMINAL=0
_PULSE_CYCLE_ID=""
_PULSE_CYCLE_OWNER_EXECUTOR_PID=""
_PULSE_CYCLE_PHASE=""
_PULSE_CYCLE_OUTCOME=""
_PULSE_CYCLE_HEARTBEAT_AT=""
_PULSE_CYCLE_PROGRESS_LAST_AT=""
_PULSE_CYCLE_PROGRESS_KINDS_JSON="[]"
_PULSE_CYCLE_NO_PROGRESS_CYCLES=0
_PULSE_CYCLE_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
_PULSE_CYCLE_BLOCKER_FINGERPRINT=""
_PULSE_CYCLE_SAME_BLOCKER_CYCLES=0
_PULSE_CYCLE_PRIOR_PROGRESS_LAST_AT=""
_PULSE_CYCLE_PRIOR_PROGRESS_KINDS_JSON="[]"
_PULSE_CYCLE_PRIOR_NO_PROGRESS_CYCLES=0
_PULSE_CYCLE_PRIOR_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
_PULSE_CYCLE_PRIOR_BLOCKER_FINGERPRINT=""
_PULSE_CYCLE_PRIOR_SAME_BLOCKER_CYCLES=0

_pulse_cycle_state_now() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

_pulse_cycle_state_blocker_is_valid() {
	local kind="$1"
	case "$kind" in
	"$PULSE_CYCLE_STATE_BLOCKER_NONE" | session-gate | dedup | preflight-failed | stop-requested | \
		dispatch-no-work-rate | runner-health | merge-authority | review-gate | \
		review-bot-threads | required-review-threads | checks-active | \
		checks-failed | quiet-period | snapshot-unavailable | head-changed | interrupted | rest-core-quota)
		return 0
		;;
	esac
	return 1
}

_pulse_cycle_state_hash() {
	local value="$1"
	local digest=""
	if command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | sha256sum 2>/dev/null | awk '{print $1}') || digest=""
	elif command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$value" | shasum -a 256 2>/dev/null | awk '{print $1}') || digest=""
	fi
	if [[ "$digest" =~ ^[0-9a-f]{64}$ ]]; then
		printf 'sha256:%s\n' "$digest"
		return 0
	fi
	digest=$(printf '%s' "$value" | cksum 2>/dev/null | awk '{print $1}') || digest=""
	[[ "$digest" =~ ^[0-9]+$ ]] || return 1
	printf 'cksum:%s\n' "$digest"
	return 0
}

_pulse_cycle_state_resolve_executor_pid() {
	local executor_pid="${BASHPID:-}"
	if [[ -z "$executor_pid" ]]; then
		# Bash 3.2 has no BASHPID and $$ remains the parent PID in subshells.
		# This command-substitution child reports the actual calling shell as PPID.
		executor_pid="$(exec sh -c 'printf "%s" "$PPID"')" || return 1
	fi
	[[ "$executor_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	_PULSE_CYCLE_STATE_EXECUTOR_PID="$executor_pid"
	return 0
}

_pulse_cycle_state_executor_is_owner() {
	local owner_pid="${_PULSE_CYCLE_OWNER_EXECUTOR_PID:-}"
	[[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
	_pulse_cycle_state_resolve_executor_pid || return 1
	[[ "$_PULSE_CYCLE_STATE_EXECUTOR_PID" == "$owner_pid" ]]
	return $?
}

_pulse_cycle_state_start() {
	local now=""
	local owner_pid=""
	local previous_fields=""
	local prior_progress_last_at=""
	local prior_progress_kinds_json="[]"
	local prior_no_progress="0"
	local prior_blocker_kind="$PULSE_CYCLE_STATE_BLOCKER_NONE"
	local prior_blocker_fingerprint=""
	local prior_same_blocker="0"
	_PULSE_CYCLE_STATE_INITIALIZED=0
	_PULSE_CYCLE_OWNER_EXECUTOR_PID=""
	_pulse_cycle_state_resolve_executor_pid || return 1
	owner_pid="$_PULSE_CYCLE_STATE_EXECUTOR_PID"
	now=$(_pulse_cycle_state_now)
	if [[ -f "${PULSE_HEALTH_FILE:-}" ]]; then
		previous_fields=$(jq -r --arg schema "$PULSE_CYCLE_STATE_SCHEMA" \
			--arg array_type "$PULSE_CYCLE_STATE_ARRAY_TYPE" \
			--arg object_type "$PULSE_CYCLE_STATE_OBJECT_TYPE" '
			.cycle_state as $state
			| select(
				($state | type) == $object_type
				and $state.schema == $schema
				and ($state.progress | type) == $object_type
				and ($state.progress.kinds | type) == $array_type
				and all($state.progress.kinds[]; type == "string")
				and ($state.progress.consecutive_no_progress_cycles | type) == "number"
				and $state.progress.consecutive_no_progress_cycles >= 0
				and ($state.blocker | type) == $object_type
				and ($state.blocker.kind | type) == "string"
				and ($state.blocker.consecutive_same_cycles | type) == "number"
				and $state.blocker.consecutive_same_cycles >= 0
			)
			| [
				($state.progress.last_at // ""),
				($state.progress.kinds | tojson),
				($state.progress.consecutive_no_progress_cycles | tostring),
				$state.blocker.kind,
				($state.blocker.fingerprint // ""),
				($state.blocker.consecutive_same_cycles | tostring)
			]
			| join("\u001f")
		' "$PULSE_HEALTH_FILE" 2>/dev/null) || previous_fields=""
	fi
	if [[ -n "$previous_fields" ]]; then
		IFS=$'\x1f' read -r prior_progress_last_at prior_progress_kinds_json \
			prior_no_progress prior_blocker_kind prior_blocker_fingerprint \
			prior_same_blocker <<<"$previous_fields"
	fi
	printf '%s' "$prior_progress_kinds_json" \
		| jq -e --arg array_type "$PULSE_CYCLE_STATE_ARRAY_TYPE" 'type == $array_type' \
			>/dev/null 2>&1 || prior_progress_kinds_json="[]"
	[[ "$prior_no_progress" =~ ^[0-9]+$ ]] || prior_no_progress=0
	[[ "$prior_same_blocker" =~ ^[0-9]+$ ]] || prior_same_blocker=0
	if ! _pulse_cycle_state_blocker_is_valid "$prior_blocker_kind"; then
		prior_blocker_kind="$PULSE_CYCLE_STATE_BLOCKER_NONE"
		prior_blocker_fingerprint=""
		prior_same_blocker=0
	fi
	if [[ "$prior_blocker_kind" == "$PULSE_CYCLE_STATE_BLOCKER_NONE" ]]; then
		prior_blocker_fingerprint=""
		prior_same_blocker=0
	elif [[ ! "$prior_blocker_fingerprint" =~ ^(sha256:[0-9a-f]{64}|cksum:[0-9]+)$ ]]; then
		prior_blocker_kind="$PULSE_CYCLE_STATE_BLOCKER_NONE"
		prior_blocker_fingerprint=""
		prior_same_blocker=0
	fi

	_PULSE_CYCLE_STATE_INITIALIZED=1
	_PULSE_CYCLE_STATE_TERMINAL=0
	_PULSE_CYCLE_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
	_PULSE_CYCLE_OWNER_EXECUTOR_PID="$owner_pid"
	_PULSE_CYCLE_PHASE="admitted"
	_PULSE_CYCLE_OUTCOME="running"
	_PULSE_CYCLE_HEARTBEAT_AT="$now"
	_PULSE_CYCLE_PRIOR_PROGRESS_LAST_AT="$prior_progress_last_at"
	_PULSE_CYCLE_PRIOR_PROGRESS_KINDS_JSON="$prior_progress_kinds_json"
	_PULSE_CYCLE_PRIOR_NO_PROGRESS_CYCLES="$prior_no_progress"
	_PULSE_CYCLE_PRIOR_BLOCKER_KIND="$prior_blocker_kind"
	_PULSE_CYCLE_PRIOR_BLOCKER_FINGERPRINT="$prior_blocker_fingerprint"
	_PULSE_CYCLE_PRIOR_SAME_BLOCKER_CYCLES="$prior_same_blocker"
	_PULSE_CYCLE_PROGRESS_LAST_AT="$prior_progress_last_at"
	_PULSE_CYCLE_PROGRESS_KINDS_JSON="$prior_progress_kinds_json"
	_PULSE_CYCLE_NO_PROGRESS_CYCLES="$prior_no_progress"
	_PULSE_CYCLE_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
	_PULSE_CYCLE_BLOCKER_FINGERPRINT=""
	_PULSE_CYCLE_SAME_BLOCKER_CYCLES=0
	return 0
}

_pulse_cycle_state_transition() {
	local phase="$1"
	[[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" == "1" ]] || return 1
	[[ "${_PULSE_CYCLE_STATE_TERMINAL:-0}" != "1" ]] || return 0
	case "$phase" in
	admitted | preflight | deterministic | supervising) ;;
	*) return 1 ;;
	esac
	_PULSE_CYCLE_PHASE="$phase"
	_PULSE_CYCLE_OUTCOME="running"
	_PULSE_CYCLE_HEARTBEAT_AT=$(_pulse_cycle_state_now)
	return 0
}

_pulse_cycle_state_set_blocker() {
	local kind="$1"
	local fingerprint="${2:-}"
	local candidate=""
	local current=""
	_pulse_cycle_state_blocker_is_valid "$kind" || return 1
	if [[ "$kind" == "$PULSE_CYCLE_STATE_BLOCKER_NONE" ]]; then
		_PULSE_CYCLE_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
		_PULSE_CYCLE_BLOCKER_FINGERPRINT=""
		return 0
	fi
	[[ "$fingerprint" =~ ^(sha256:[0-9a-f]{64}|cksum:[0-9]+)$ ]] || return 1
	candidate="${kind}:${fingerprint}"
	current="${_PULSE_CYCLE_BLOCKER_KIND:-$PULSE_CYCLE_STATE_BLOCKER_NONE}:${_PULSE_CYCLE_BLOCKER_FINGERPRINT:-}"
	if [[ "${_PULSE_CYCLE_BLOCKER_KIND:-$PULSE_CYCLE_STATE_BLOCKER_NONE}" == "$PULSE_CYCLE_STATE_BLOCKER_NONE" \
		|| "$candidate" < "$current" ]]; then
		_PULSE_CYCLE_BLOCKER_KIND="$kind"
		_PULSE_CYCLE_BLOCKER_FINGERPRINT="$fingerprint"
	fi
	return 0
}

_pulse_cycle_state_note_blocker() {
	local kind="$1"
	local scope="${2:-global}"
	local subject="${3:-pulse}"
	local fingerprint=""
	fingerprint=$(_pulse_cycle_state_hash "${kind}|${scope}|${subject}") || return 1
	_pulse_cycle_state_set_blocker "$kind" "$fingerprint"
	return $?
}

_pulse_cycle_state_finalize() {
	local outcome="$1"
	local progress_kinds_json="${2:-[]}"
	local now=""
	local same_blocker=0
	[[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" == "1" ]] || return 1
	_pulse_cycle_state_executor_is_owner || return 1
	case "$outcome" in
	progressed | idle | blocked | interrupted) ;;
	*) return 1 ;;
	esac
	printf '%s' "$progress_kinds_json" | jq -e \
		--arg array_type "$PULSE_CYCLE_STATE_ARRAY_TYPE" '
		type == $array_type
		and all(.[]; . == "pr-merged" or . == "pr-closed-conflicting" or . == "worker-dispatched")
	' >/dev/null 2>&1 || return 1
	now=$(_pulse_cycle_state_now)
	if [[ "$outcome" == "progressed" ]]; then
		_PULSE_CYCLE_PROGRESS_LAST_AT="$now"
		_PULSE_CYCLE_PROGRESS_KINDS_JSON="$progress_kinds_json"
		_PULSE_CYCLE_NO_PROGRESS_CYCLES=0
		_PULSE_CYCLE_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
		_PULSE_CYCLE_BLOCKER_FINGERPRINT=""
		_PULSE_CYCLE_SAME_BLOCKER_CYCLES=0
	else
		_PULSE_CYCLE_PROGRESS_LAST_AT="${_PULSE_CYCLE_PRIOR_PROGRESS_LAST_AT:-}"
		_PULSE_CYCLE_PROGRESS_KINDS_JSON="${_PULSE_CYCLE_PRIOR_PROGRESS_KINDS_JSON:-[]}"
		_PULSE_CYCLE_NO_PROGRESS_CYCLES=$((${_PULSE_CYCLE_PRIOR_NO_PROGRESS_CYCLES:-0} + 1))
		if [[ "$outcome" == "blocked" || "$outcome" == "interrupted" ]]; then
			if [[ "${_PULSE_CYCLE_BLOCKER_KIND:-$PULSE_CYCLE_STATE_BLOCKER_NONE}" == "${_PULSE_CYCLE_PRIOR_BLOCKER_KIND:-$PULSE_CYCLE_STATE_BLOCKER_NONE}" \
				&& "${_PULSE_CYCLE_BLOCKER_FINGERPRINT:-}" == "${_PULSE_CYCLE_PRIOR_BLOCKER_FINGERPRINT:-}" ]]; then
				same_blocker=$((${_PULSE_CYCLE_PRIOR_SAME_BLOCKER_CYCLES:-0} + 1))
			else
				same_blocker=1
			fi
			_PULSE_CYCLE_SAME_BLOCKER_CYCLES="$same_blocker"
		else
			_PULSE_CYCLE_BLOCKER_KIND="$PULSE_CYCLE_STATE_BLOCKER_NONE"
			_PULSE_CYCLE_BLOCKER_FINGERPRINT=""
			_PULSE_CYCLE_SAME_BLOCKER_CYCLES=0
		fi
	fi
	_PULSE_CYCLE_PHASE="completed"
	_PULSE_CYCLE_OUTCOME="$outcome"
	_PULSE_CYCLE_HEARTBEAT_AT="$now"
	_PULSE_CYCLE_STATE_TERMINAL=1
	return 0
}

_pulse_cycle_state_json() {
	if [[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" != "1" ]]; then
		if [[ -f "${PULSE_HEALTH_FILE:-}" ]]; then
			jq -ce --arg schema "$PULSE_CYCLE_STATE_SCHEMA" \
				--arg object_type "$PULSE_CYCLE_STATE_OBJECT_TYPE" \
				'.cycle_state | select(type == $object_type and .schema == $schema)' \
				"$PULSE_HEALTH_FILE" 2>/dev/null && return 0
		fi
		printf 'null\n'
		return 0
	fi
	jq -cn \
		--arg schema "$PULSE_CYCLE_STATE_SCHEMA" \
		--arg cycle_id "$_PULSE_CYCLE_ID" \
		--arg phase "$_PULSE_CYCLE_PHASE" \
		--arg outcome "$_PULSE_CYCLE_OUTCOME" \
		--arg heartbeat_at "$_PULSE_CYCLE_HEARTBEAT_AT" \
		--arg progress_last_at "$_PULSE_CYCLE_PROGRESS_LAST_AT" \
		--argjson progress_kinds "$_PULSE_CYCLE_PROGRESS_KINDS_JSON" \
		--argjson no_progress_cycles "$_PULSE_CYCLE_NO_PROGRESS_CYCLES" \
		--arg blocker_kind "$_PULSE_CYCLE_BLOCKER_KIND" \
		--arg blocker_fingerprint "$_PULSE_CYCLE_BLOCKER_FINGERPRINT" \
		--argjson same_blocker_cycles "$_PULSE_CYCLE_SAME_BLOCKER_CYCLES" '
		{
			schema: $schema,
			cycle_id: $cycle_id,
			phase: $phase,
			outcome: $outcome,
			heartbeat_at: $heartbeat_at,
			progress: {
				last_at: (if $progress_last_at == "" then null else $progress_last_at end),
				kinds: $progress_kinds,
				consecutive_no_progress_cycles: $no_progress_cycles
			},
			blocker: {
				kind: $blocker_kind,
				fingerprint: (if $blocker_fingerprint == "" then null else $blocker_fingerprint end),
				consecutive_same_cycles: $same_blocker_cycles
			}
		}'
	return $?
}

_pulse_cycle_state_publish() {
	local phase="$1"
	_pulse_cycle_state_transition "$phase" || return 1
	write_pulse_health_file
	return $?
}

_pulse_cycle_state_health_is_current() {
	local current_cycle_id=""
	[[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" == "1" ]] || return 1
	[[ -f "${PULSE_HEALTH_FILE:-}" ]] || return 1
	current_cycle_id=$(jq -r --arg schema "$PULSE_CYCLE_STATE_SCHEMA" \
		--arg object_type "$PULSE_CYCLE_STATE_OBJECT_TYPE" '
		if (.cycle_state | type) == $object_type and .cycle_state.schema == $schema
		then .cycle_state.cycle_id // ""
		else ""
		end
	' "$PULSE_HEALTH_FILE" 2>/dev/null) || current_cycle_id=""
	[[ -n "$current_cycle_id" && "$current_cycle_id" == "${_PULSE_CYCLE_ID:-}" ]]
}

_pulse_cycle_state_commit_legacy_outcome() {
	if declare -F _pulse_commit_legacy_cycle_outcome >/dev/null 2>&1; then
		_pulse_commit_legacy_cycle_outcome || true
	fi
	return 0
}

_pulse_cycle_state_write_terminal_if_current() {
	[[ "${_PULSE_CYCLE_STATE_TERMINAL:-0}" == "1" ]] || return 1
	if ! _pulse_cycle_state_executor_is_owner; then
		printf '[pulse-wrapper] Cycle state: skipped terminal publish for cycle %s because executor does not own the cycle\n' \
			"${_PULSE_CYCLE_ID:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
		return 0
	fi
	if [[ "${_LOCK_OWNED:-false}" == "true" ]]; then
		_pulse_cycle_state_commit_legacy_outcome
		write_pulse_health_file
		return $?
	fi
	if ! declare -F acquire_instance_lock >/dev/null 2>&1 \
		|| ! declare -F release_instance_lock >/dev/null 2>&1; then
		printf '[pulse-wrapper] Cycle state: skipped terminal publish for cycle %s because instance lock functions are unavailable\n' \
			"${_PULSE_CYCLE_ID:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
		return 0
	fi
	if ! acquire_instance_lock; then
		printf '[pulse-wrapper] Cycle state: skipped terminal publish for cycle %s because a newer cycle owns the instance lock\n' \
			"${_PULSE_CYCLE_ID:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
		return 0
	fi
	if _pulse_cycle_state_health_is_current; then
		_pulse_cycle_state_commit_legacy_outcome
		write_pulse_health_file || true
	else
		printf '[pulse-wrapper] Cycle state: skipped stale terminal publish for cycle %s because current health belongs to another cycle\n' \
			"${_PULSE_CYCLE_ID:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
	fi
	release_instance_lock
	return 0
}

_pulse_cycle_state_finish_if_needed() {
	local outcome="${1:-interrupted}"
	[[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" == "1" ]] || return 0
	_pulse_cycle_state_executor_is_owner || return 0
	[[ "${_PULSE_CYCLE_STATE_TERMINAL:-0}" != "1" ]] || return 0
	if [[ "$outcome" == "interrupted" \
		&& "${_PULSE_CYCLE_BLOCKER_KIND:-$PULSE_CYCLE_STATE_BLOCKER_NONE}" == "$PULSE_CYCLE_STATE_BLOCKER_NONE" ]]; then
		_pulse_cycle_state_note_blocker interrupted pulse-wrapper exit || true
	fi
	_pulse_cycle_state_finalize "$outcome" "[]" || return 0
	_pulse_cycle_state_write_terminal_if_current || true
	return 0
}

_pulse_cycle_state_finish_interrupted() {
	_pulse_cycle_state_finish_if_needed interrupted
	return 0
}

#######################################
# _rotate_single_log — gzip-compress and truncate a single log file.
# Extracted from rotate_pulse_log to keep function complexity under 100 lines.
#
# Arguments:
#   $1 — source log file path
#   $2 — archive file basename (e.g. "pulse-20260429-123456.log.gz")
#   $3 — label for log messages (e.g. "hot log", "wrapper")
# Returns: 0 (always — non-fatal on any error)
#######################################
_rotate_single_log() {
	local source_file="$1"
	local archive_name="$2"
	local label="$3"

	local archive_path="${PULSE_LOG_ARCHIVE_DIR}/${archive_name}"
	local source_size=0
	source_size=$(_file_size_bytes "$source_file")

	local tmp_archive=""
	# t2997: XXXXXX must be at end for BSD mktemp.
	tmp_archive=$(mktemp "${PULSE_LOG_ARCHIVE_DIR}/.pulse-archive-XXXXXX") || {
		echo "[pulse-wrapper] rotate_pulse_log: mktemp failed for ${label} archive" >>"$WRAPPER_LOGFILE"
		return 0
	}

	if gzip -c "$source_file" >"$tmp_archive" 2>/dev/null; then
		mv "$tmp_archive" "$archive_path" 2>/dev/null || {
			rm -f "$tmp_archive"
			echo "[pulse-wrapper] rotate_pulse_log: mv failed for ${archive_name}" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Truncate (not delete — preserves file descriptor for concurrent writers)
		: >"$source_file" 2>/dev/null || true
		echo "[pulse-wrapper] rotate_pulse_log: rotated ${label} ${source_size}B → ${archive_name}" >>"$WRAPPER_LOGFILE"
	else
		rm -f "$tmp_archive"
		echo "[pulse-wrapper] rotate_pulse_log: gzip failed for ${label} (${source_file})" >>"$WRAPPER_LOGFILE"
	fi

	return 0
}

#######################################
# _prune_cold_archive — remove oldest archives until total size <= cap.
# Extracted from rotate_pulse_log to keep function complexity under 100 lines.
#
# Arguments: none (uses PULSE_LOG_ARCHIVE_DIR, PULSE_LOG_COLD_MAX_BYTES globals)
# Returns: 0
#######################################
_prune_cold_archive() {
	local total_cold=0
	local archive_file="" archive_size=0
	# Build sorted list (oldest first via lexicographic sort on timestamp-named files)
	local -a archive_files=()
	while IFS= read -r archive_file; do
		archive_files+=("$archive_file")
	done < <(ls -1 "${PULSE_LOG_ARCHIVE_DIR}"/pulse-*.log.gz 2>/dev/null | sort)

	for archive_file in "${archive_files[@]}"; do
		archive_size=$(_file_size_bytes "$archive_file")
		total_cold=$((total_cold + archive_size))
	done

	if [[ "$total_cold" -gt "$PULSE_LOG_COLD_MAX_BYTES" ]]; then
		for archive_file in "${archive_files[@]}"; do
			[[ "$total_cold" -le "$PULSE_LOG_COLD_MAX_BYTES" ]] && break
			archive_size=$(_file_size_bytes "$archive_file")
			rm -f "$archive_file" && {
				total_cold=$((total_cold - archive_size))
				echo "[pulse-wrapper] rotate_pulse_log: pruned cold archive $(basename "$archive_file") (${archive_size}B)" >>"$WRAPPER_LOGFILE"
			}
		done
	fi

	return 0
}

#######################################
# rotate_pulse_log — hot/cold log sharding (t1886)
#
# Called once per cycle, before any log writes. If pulse.log exceeds
# PULSE_LOG_HOT_MAX_BYTES, it is gzip-compressed and moved to the cold
# archive directory. The cold archive is then pruned to stay within
# PULSE_LOG_COLD_MAX_BYTES by removing the oldest archives first.
# GH#21756: also rotates WRAPPER_LOGFILE (pulse-wrapper.log) and
# stage-timings log when over their respective caps.
#
# Design constraints:
#   - Atomic: uses a tmp file + mv to avoid partial archives.
#   - Non-fatal: any failure is logged to WRAPPER_LOGFILE and silently
#     ignored so the pulse cycle is never blocked by log housekeeping.
#   - Cross-platform: uses _file_size_bytes from portable-stat.sh.
#   - No external deps beyond gzip (standard on macOS and Linux).
#######################################
rotate_pulse_log() {
	# Ensure archive directory exists
	mkdir -p "$PULSE_LOG_ARCHIVE_DIR" 2>/dev/null || {
		echo "[pulse-wrapper] rotate_pulse_log: cannot create archive dir ${PULSE_LOG_ARCHIVE_DIR}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	local ts=""
	ts=$(date -u +%Y%m%d-%H%M%S)

	# Rotate LOGFILE (pulse.log) if over cap
	local hot_size=0
	if [[ -f "$LOGFILE" ]]; then
		hot_size=$(_file_size_bytes "$LOGFILE")
	fi
	if [[ "$hot_size" -ge "$PULSE_LOG_HOT_MAX_BYTES" ]]; then
		_rotate_single_log "$LOGFILE" "pulse-${ts}.log.gz" "hot log"
		_prune_cold_archive
	fi

	# GH#20025: Rotate stage timings log (1MB cap).
	if [[ -n "${PULSE_STAGE_TIMINGS_LOG:-}" ]] && [[ -f "$PULSE_STAGE_TIMINGS_LOG" ]]; then
		local timings_size=0
		timings_size=$(_file_size_bytes "$PULSE_STAGE_TIMINGS_LOG")
		if [[ "$timings_size" -gt 1048576 ]]; then
			_rotate_single_log "$PULSE_STAGE_TIMINGS_LOG" "pulse-stage-timings-${ts}.log.gz" "stage-timings"
		fi
	fi

	# GH#21756: Rotate WRAPPER_LOGFILE (pulse-wrapper.log) — same cap as hot log.
	# This was the gap that allowed GH#21729's 6GB runaway.
	if [[ -n "${WRAPPER_LOGFILE:-}" ]] && [[ -f "$WRAPPER_LOGFILE" ]]; then
		local wrapper_size=0
		wrapper_size=$(_file_size_bytes "$WRAPPER_LOGFILE")
		if [[ "$wrapper_size" -gt "$PULSE_LOG_HOT_MAX_BYTES" ]]; then
			_rotate_single_log "$WRAPPER_LOGFILE" "pulse-wrapper-${ts}.log.gz" "wrapper"
		fi
	fi

	return 0
}

#######################################
# append_cycle_index — write one JSONL record to the cycle index (t1886)
#
# Called once per cycle after write_pulse_health_file(). Captures the
# per-cycle counters already computed by the health file writer plus
# timing and utilisation data. The index is append-only and capped at
# PULSE_CYCLE_INDEX_MAX_LINES lines; oldest lines are pruned in-place
# using a tmp-file swap when the cap is exceeded.
#
# Fields written per cycle:
#   ts          — ISO-8601 UTC timestamp
#   duration_s  — cycle wall-clock duration in seconds (0 if unknown)
#   workers     — "active/max" string
#   dispatched  — issues dispatched this cycle
#   merged      — PRs merged this cycle
#   closed      — conflicting PRs closed this cycle
#   killed      — stalled workers killed this cycle
#   prefetch_errors — prefetch failures this cycle
#######################################
append_cycle_index() {
	local duration_s="${1:-0}"

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	local workers_active=0 workers_max=0
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	local issues_dispatched=0
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
	fi

	# Append record — use printf for portability (no echo -e needed)
	printf '{"ts":"%s","duration_s":%s,"workers":"%s/%s","dispatched":%s,"merged":%s,"closed":%s,"killed":%s,"prefetch_errors":%s}\n' \
		"$ts" \
		"$duration_s" \
		"$workers_active" \
		"$workers_max" \
		"$issues_dispatched" \
		"$_PULSE_HEALTH_PRS_MERGED" \
		"$_PULSE_HEALTH_PRS_CLOSED_CONFLICTING" \
		"$_PULSE_HEALTH_STALLED_KILLED" \
		"$_PULSE_HEALTH_PREFETCH_ERRORS" \
		>>"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
		echo "[pulse-wrapper] append_cycle_index: write failed to ${PULSE_CYCLE_INDEX_FILE}" >>"$WRAPPER_LOGFILE"
		return 0
	}

	# Prune index to PULSE_CYCLE_INDEX_MAX_LINES lines when exceeded
	local line_count
	line_count=$(wc -l <"$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || echo "0")
	line_count="${line_count//[[:space:]]/}"
	[[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0

	if [[ "$line_count" -gt "$PULSE_CYCLE_INDEX_MAX_LINES" ]]; then
		local excess=$((line_count - PULSE_CYCLE_INDEX_MAX_LINES))
		local tmp_index
		# t2997: drop .jsonl — XXXXXX must be at end for BSD mktemp.
		tmp_index=$(mktemp "${HOME}/.aidevops/logs/.pulse-cycle-index-XXXXXX") || {
			echo "[pulse-wrapper] append_cycle_index: mktemp failed for index prune" >>"$WRAPPER_LOGFILE"
			return 0
		}
		# Keep only the last PULSE_CYCLE_INDEX_MAX_LINES lines
		tail -n "$PULSE_CYCLE_INDEX_MAX_LINES" "$PULSE_CYCLE_INDEX_FILE" >"$tmp_index" 2>/dev/null &&
			mv "$tmp_index" "$PULSE_CYCLE_INDEX_FILE" 2>/dev/null || {
			rm -f "$tmp_index"
			echo "[pulse-wrapper] append_cycle_index: prune failed (excess=${excess})" >>"$WRAPPER_LOGFILE"
		}
	fi

	return 0
}

#######################################
# Write pulse-health.json — structured status snapshot for instant diagnosis.
#
# Fields (GH#15107):
#   workers_active          — current live worker count
#   workers_max             — configured max worker slots
#   prs_merged_this_cycle   — PRs squash-merged by deterministic merge pass
#   prs_closed_conflicting  — conflicting PRs closed this cycle
#   issues_dispatched       — workers launched this cycle (from dispatch ledger)
#   prefetch_errors         — prefetch_state failures this cycle
#   stalled_workers_killed  — stalled workers killed by cleanup_stalled_workers
#   models_backed_off       — active backoff entries in provider_backoff DB
#
# Historical note (GH#18668): the deadlock_* fields were removed along with
# the flock layer they reported on. The lock is now mkdir-only and cannot
# deadlock in the way flock FD inheritance did. See reference/bash-fd-locking.md.
#
# Atomic write: write to tmp file then mv to avoid partial reads.
# Non-fatal: any failure is logged and silently ignored.
#######################################
write_pulse_health_file() {
	if [[ "${_PULSE_CYCLE_STATE_INITIALIZED:-0}" == "1" &&
		"${_PULSE_CYCLE_STATE_TERMINAL:-0}" == "1" ]] &&
		! _pulse_cycle_state_executor_is_owner; then
		printf '[pulse-wrapper] Cycle state: skipped terminal health write for cycle %s because executor does not own the cycle\n' \
			"${_PULSE_CYCLE_ID:-unknown}" >>"${WRAPPER_LOGFILE:-/dev/null}"
		return 0
	fi
	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local cycle_state_json=null
	cycle_state_json=$(_pulse_cycle_state_json) || cycle_state_json=null
	printf '%s' "$cycle_state_json" | jq empty >/dev/null 2>&1 || cycle_state_json=null

	# t3032: declare ledger helper once — used for both workers reconciliation
	# and issues_dispatched. The ledger is written synchronously at dispatch
	# time so it reliably reflects workers just launched, while the process
	# list (list_active_worker_processes via count_active_workers) has a brief
	# race window after nohup launch before the process appears in ps.
	local _ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	local workers_active=0 workers_max=0
	workers_active=$(count_active_workers 2>/dev/null || echo "0")
	[[ "$workers_active" =~ ^[0-9]+$ ]] || workers_active=0
	workers_max=$(get_max_workers_target 2>/dev/null || echo "1")
	[[ "$workers_max" =~ ^[0-9]+$ ]] || workers_max=1

	# issues_dispatched: in-flight worker count from dispatch ledger
	local issues_dispatched=0
	if [[ -x "$_ledger_helper" ]]; then
		local _ledger_count
		_ledger_count=$("$_ledger_helper" count 2>/dev/null || echo "0")
		[[ "$_ledger_count" =~ ^[0-9]+$ ]] && issues_dispatched="$_ledger_count"
		# Reconcile workers_active with ledger count (t3032): the
		# _adaptive_launch_settle_wait is skipped when the dispatched
		# counter is 0 (C2 stdout-pollution bug), so workers just
		# dispatched via nohup may not yet appear in ps when the health
		# file is written. Use the higher of the two counts — process
		# list is more accurate for long-running workers; ledger is more
		# accurate immediately post-dispatch.
		if [[ "$_ledger_count" =~ ^[0-9]+$ ]] && [[ "$_ledger_count" -gt "$workers_active" ]]; then
			workers_active="$_ledger_count"
		fi
	fi

	# models_backed_off: count active backoff entries in provider_backoff DB
	local models_backed_off=0
	if [[ -x "$HEADLESS_RUNTIME_HELPER" ]]; then
		local _backoff_rows
		_backoff_rows=$("$HEADLESS_RUNTIME_HELPER" backoff status 2>/dev/null | grep -c '|' || echo "0")
		[[ "$_backoff_rows" =~ ^[0-9]+$ ]] && models_backed_off="$_backoff_rows"
	fi

	local health_dir="${PULSE_HEALTH_FILE%/*}"
	[[ "$health_dir" != "$PULSE_HEALTH_FILE" ]] || health_dir="."
	mkdir -p "$health_dir" 2>/dev/null || {
		echo "[pulse-wrapper] write_pulse_health_file: cannot create health directory ${health_dir}" >>"$LOGFILE"
		return 0
	}
	local tmp_health
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	tmp_health=$(mktemp "${health_dir}/.pulse-health-XXXXXX") || {
		echo "[pulse-wrapper] write_pulse_health_file: mktemp failed — skipping health write" >>"$LOGFILE"
		return 0
	}
	chmod 0600 "$tmp_health" 2>/dev/null || true

	cat >"$tmp_health" <<EOF
{
  "timestamp": "${ts}",
  "workers_active": ${workers_active},
  "workers_max": ${workers_max},
  "prs_merged_this_cycle": ${_PULSE_HEALTH_PRS_MERGED},
  "prs_closed_conflicting": ${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING},
  "issues_dispatched": ${issues_dispatched},
  "prefetch_errors": ${_PULSE_HEALTH_PREFETCH_ERRORS},
  "stalled_workers_killed": ${_PULSE_HEALTH_STALLED_KILLED},
  "models_backed_off": ${models_backed_off},
  "idle_repo_skips": ${_PULSE_HEALTH_IDLE_REPO_SKIPS:-0},
  "batch_search_calls": ${_PULSE_HEALTH_BATCH_SEARCH_CALLS:-0},
  "batch_cache_hits": ${_PULSE_HEALTH_BATCH_CACHE_HITS:-0},
  "events_tickle_fresh": ${_PULSE_HEALTH_EVENTS_TICKLE_FRESH:-0},
  "events_tickle_stale": ${_PULSE_HEALTH_EVENTS_TICKLE_STALE:-0},
  "prefetch_conditional_304": ${_PULSE_HEALTH_CONDITIONAL_304:-0},
  "prefetch_conditional_refreshes": ${_PULSE_HEALTH_CONDITIONAL_REFRESHES:-0},
  "prefetch_conditional_misses": ${_PULSE_HEALTH_CONDITIONAL_MISSES:-0},
  "prefetch_throttled": ${_PULSE_HEALTH_PREFETCH_THROTTLED:-0},
  "idle_cycle_skipped": ${_PULSE_HEALTH_IDLE_CYCLE_SKIPPED:-0},
  "cycle_state": ${cycle_state_json}
}
EOF
	if ! jq empty "$tmp_health" >/dev/null 2>&1; then
		rm -f "$tmp_health"
		echo "[pulse-wrapper] write_pulse_health_file: JSON validation failed — preserving prior health file" >>"$LOGFILE"
		return 0
	fi

	mv "$tmp_health" "$PULSE_HEALTH_FILE" || {
		rm -f "$tmp_health"
		echo "[pulse-wrapper] write_pulse_health_file: mv failed — skipping health write" >>"$LOGFILE"
		return 0
	}

	echo "[pulse-wrapper] pulse-health.json written: workers=${workers_active}/${workers_max} merged=${_PULSE_HEALTH_PRS_MERGED} closed_conflicting=${_PULSE_HEALTH_PRS_CLOSED_CONFLICTING} dispatched=${issues_dispatched} stalled_killed=${_PULSE_HEALTH_STALLED_KILLED} backed_off=${models_backed_off} idle_skips=${_PULSE_HEALTH_IDLE_REPO_SKIPS:-0} batch_search=${_PULSE_HEALTH_BATCH_SEARCH_CALLS:-0} batch_hits=${_PULSE_HEALTH_BATCH_CACHE_HITS:-0} tickle_fresh=${_PULSE_HEALTH_EVENTS_TICKLE_FRESH:-0} tickle_stale=${_PULSE_HEALTH_EVENTS_TICKLE_STALE:-0} conditional_304=${_PULSE_HEALTH_CONDITIONAL_304:-0} conditional_refreshes=${_PULSE_HEALTH_CONDITIONAL_REFRESHES:-0} conditional_misses=${_PULSE_HEALTH_CONDITIONAL_MISSES:-0} prefetch_throttled=${_PULSE_HEALTH_PREFETCH_THROTTLED:-0} idle_skipped=${_PULSE_HEALTH_IDLE_CYCLE_SKIPPED:-0}" >>"$LOGFILE"
	return 0
}
