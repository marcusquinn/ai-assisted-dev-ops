#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-routines.sh — Recurring routine scheduler (repeat:/run:/agent: TODO entries).
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _routine_last_run_epoch
#   - _routine_update_state
#   - _routine_execute
#   - _routine_extract_section
#   - _routine_parse_line
#   - _routine_schedule_is_due
#   - evaluate_routines
#
# Keep behavioral changes in this module covered by the focused selector and
# lifecycle regression suites.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_ROUTINES_LOADED:-}" ]] && return 0
_PULSE_ROUTINES_LOADED=1
_ROUTINE_STATUS_SUCCESS="success"
_ROUTINE_STATUS_FAILURE="failure"
_ROUTINE_STATUS_DEFERRED="deferred"
_ROUTINE_TEMPFAIL_EXIT=75

_routine_now_epoch() {
	local configured="${AIDEVOPS_ROUTINE_NOW_EPOCH:-}"
	if [[ "$configured" =~ ^[0-9]+$ ]]; then
		printf '%s' "$configured"
		return 0
	fi
	date +%s
	return 0
}

_routine_epoch_to_iso() {
	local epoch="$1"
	date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
		date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
	return $?
}

_routine_deferred_until() {
	local routine_id="$1"
	local reset_epoch=""
	local now_epoch=0
	local jitter_max="${AIDEVOPS_ROUTINE_COOLDOWN_JITTER_MAX_SECONDS:-60}"
	local fallback_seconds="${AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS:-900}"
	local checksum=""
	local jitter=0
	now_epoch=$(_routine_now_epoch)
	reset_epoch="$(_gh_secondary_cooldown_expires_at 2>/dev/null || true)"
	[[ "$fallback_seconds" =~ ^[0-9]+$ ]] || fallback_seconds=900
	if ! [[ "$reset_epoch" =~ ^[0-9]+$ && "$reset_epoch" -gt "$now_epoch" ]]; then
		reset_epoch=$((now_epoch + fallback_seconds))
	fi
	[[ "$jitter_max" =~ ^[0-9]+$ ]] || jitter_max=60
	if [[ "$jitter_max" -gt 0 ]]; then
		checksum=$(printf '%s' "${routine_id}:${reset_epoch}" | cksum)
		checksum="${checksum%% *}"
		[[ "$checksum" =~ ^[0-9]+$ ]] || checksum=0
		jitter=$((checksum % (jitter_max + 1)))
	fi
	printf '%s' $((reset_epoch + jitter))
	return 0
}

#######################################
# Read last-run epoch for a routine ID from state file
# Arguments: $1 - routine ID (e.g., r001)
# Output: epoch (0 if never run)
#######################################
_routine_last_run_epoch() {
	local routine_id="$1"
	if [[ ! -f "$ROUTINE_STATE_FILE" ]]; then
		printf '0'
		return 0
	fi
	local epoch
	epoch=$(jq -r --arg id "$routine_id" '.[$id].last_run // ""' "$ROUTINE_STATE_FILE" 2>/dev/null) || epoch=""
	if [[ -z "$epoch" ]]; then
		printf '0'
		return 0
	fi
	# Convert ISO to epoch
	local epoch_num
	epoch_num=$(date -d "$epoch" +%s 2>/dev/null) || epoch_num=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$epoch" +%s 2>/dev/null) || epoch_num=0
	printf '%s' "$epoch_num"
	return 0
}

#######################################
# Update routine state after execution
# Arguments:
#   $1 - routine ID
#   $2 - status (success|failure)
#######################################
_routine_update_state() {
	local routine_id="$1"
	local status="$2"
	local deferred_until="${3:-0}"
	local now_epoch=0
	local now_iso
	now_epoch=$(_routine_now_epoch)
	now_iso=$(_routine_epoch_to_iso "$now_epoch") || now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	[[ "$deferred_until" =~ ^[0-9]+$ ]] || deferred_until=0

	mkdir -p "$(dirname "$ROUTINE_STATE_FILE")" 2>/dev/null || true

	local existing="{}"
	if [[ -f "$ROUTINE_STATE_FILE" ]]; then
		existing=$(cat "$ROUTINE_STATE_FILE" 2>/dev/null) || existing="{}"
		echo "$existing" | jq empty 2>/dev/null || existing="{}"
	fi

	local tmp_file
	tmp_file=$(mktemp "$(dirname "$ROUTINE_STATE_FILE")/.routine-state.XXXXXX")
	if echo "$existing" | jq --arg id "$routine_id" --arg ts "$now_iso" --arg st "$status" \
		--arg success "$_ROUTINE_STATUS_SUCCESS" --arg deferred "$_ROUTINE_STATUS_DEFERRED" \
		--argjson deferred_until "$deferred_until" '
		.[$id] = ((.[$id] // {}) + {"last_attempt": $ts, "last_status": $st})
		| if $st == $success then .[$id].last_run = $ts else . end
		| if $st == $deferred then
			.[$id].deferred_until = ([.[$id].deferred_until // 0, $deferred_until] | max)
		  else del(.[$id].deferred_until)
		  end
	' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$ROUTINE_STATE_FILE"
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _routine_update_state: failed to write state for ${routine_id}" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Block duplicate active executions and apply an explicit short failure retry
# cooldown without moving the successful calendar boundary marker.
#######################################
_routine_retry_blocked() {
	local routine_id="$1"
	local retry_seconds="${AIDEVOPS_ROUTINE_FAILURE_RETRY_SECONDS:-900}"
	local running_seconds="${AIDEVOPS_ROUTINE_RUNNING_TIMEOUT_SECONDS:-21600}"
	local status=""
	local attempt_iso=""
	local attempt_epoch=0
	local now_epoch=0
	local deferred_until=0
	[[ "$retry_seconds" =~ ^[0-9]+$ ]] || retry_seconds=900
	[[ "$running_seconds" =~ ^[0-9]+$ ]] || running_seconds=21600
	[[ -f "$ROUTINE_STATE_FILE" ]] || return 1
	status=$(jq -r --arg id "$routine_id" '.[$id].last_status // empty' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
	attempt_iso=$(jq -r --arg id "$routine_id" '.[$id].last_attempt // empty' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
	[[ -n "$attempt_iso" ]] || return 1
	attempt_epoch=$(date -d "$attempt_iso" +%s 2>/dev/null) || attempt_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$attempt_iso" +%s 2>/dev/null) || return 1
	now_epoch=$(_routine_now_epoch)
	case "$status" in
	running) [[ $((now_epoch - attempt_epoch)) -lt "$running_seconds" ]] ;;
	failure) [[ $((now_epoch - attempt_epoch)) -lt "$retry_seconds" ]] ;;
	deferred)
		deferred_until=$(jq -r --arg id "$routine_id" '.[$id].deferred_until // 0' "$ROUTINE_STATE_FILE" 2>/dev/null || true)
		[[ "$deferred_until" =~ ^[0-9]+$ && "$now_epoch" -lt "$deferred_until" ]]
		;;
	*) return 1 ;;
	esac
	return $?
}

_routine_record_lifecycle() {
	local routine_id="$1"
	local status="$2"
	local duration="$3"
	local session_key="${4:-}"
	local -a args=(update "$routine_id" --status "$status" --duration "$duration")
	[[ -z "$session_key" ]] || args+=(--session-key "$session_key")
	if [[ -x "$ROUTINE_LOG_HELPER" ]]; then
		"$ROUTINE_LOG_HELPER" "${args[@]}" 2>/dev/null || true
	fi
	return 0
}

_routine_finalize_terminal() {
	local routine_id="$1"
	local status="$2"
	local started_epoch="$3"
	local session_key="${4:-}"
	local deferred_until="${5:-0}"
	local ended_epoch=0
	local duration=0
	ended_epoch=$(date +%s)
	duration=$((ended_epoch - started_epoch))
	[[ "$duration" -ge 0 ]] || duration=0
	_routine_update_state "$routine_id" "$status" "$deferred_until"
	_routine_record_lifecycle "$routine_id" "$status" "$duration" "$session_key"
	return 0
}

_routine_dispatch_agent() {
	local routine_id="$1"
	local description="$2"
	local agent_name="$3"
	local dispatch_dir="$4"
	local session_key="routine-${routine_id}"
	local started_epoch=0
	[[ -n "$agent_name" ]] || agent_name="Build+"
	started_epoch=$(date +%s)
	_routine_update_state "$routine_id" "running"
	_routine_record_lifecycle "$routine_id" "running" 0 "$session_key"
	if [[ ! -x "$HEADLESS_RUNTIME_HELPER" ]]; then
		echo "[pulse-wrapper] routine ${routine_id}: headless runtime helper unavailable" >>"$LOGFILE"
		_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch" "$session_key"
		return 1
	fi
	echo "[pulse-wrapper] routine ${routine_id}: dispatching agent '${agent_name}' for '${description}'" >>"$LOGFILE"
	(
		local exit_code=0
		local status="$_ROUTINE_STATUS_SUCCESS"
		"$HEADLESS_RUNTIME_HELPER" run \
			--role worker \
			--session-key "$session_key" \
			--dir "$dispatch_dir" \
			--agent "$agent_name" \
			--title "Routine ${routine_id}: ${description}" \
			--prompt "Execute routine ${routine_id}: ${description}" >>"$LOGFILE" 2>&1 || exit_code=$?
		if [[ "$exit_code" -ne 0 ]]; then
			status="$_ROUTINE_STATUS_FAILURE"
			echo "[pulse-wrapper] routine ${routine_id}: agent exited with code ${exit_code}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] routine ${routine_id}: agent completed successfully" >>"$LOGFILE"
		fi
		_routine_finalize_terminal "$routine_id" "$status" "$started_epoch" "$session_key"
		return 0
	) &
	return 0
}

#######################################
# Execute a single routine. Script routines finish synchronously; agent
# routines detach a wrapper that waits for the headless process before logging
# a terminal result.
#######################################
_routine_execute() {
	local routine_id="$1"
	local description="$2"
	local run_script="$3"
	local agent_name="$4"
	local repo_path="$5"
	local agents_dir="${HOME}/.aidevops/agents"
	local status="$_ROUTINE_STATUS_SUCCESS"
	local started_epoch=0
	local exit_code=0
	local deferred_until=0
	started_epoch=$(date +%s)

	if [[ -n "$run_script" ]]; then
		local run_parts=()
		IFS=' ' read -r -a run_parts <<<"$run_script"
		local script_path="${agents_dir}/${run_parts[0]}"
		if [[ ! -x "$script_path" ]]; then
			echo "[pulse-wrapper] routine ${routine_id}: script not found or not executable: ${script_path}" >>"$LOGFILE"
			_routine_finalize_terminal "$routine_id" "$_ROUTINE_STATUS_FAILURE" "$started_epoch"
			return 1
		fi
		# Bash 3.2 with nounset treats expansion of an empty array as an unbound
		# variable. Keep the zero-argument path separate instead of expanding it.
		if [[ "${#run_parts[@]}" -gt 1 ]]; then
			local script_args=("${run_parts[@]:1}")
			echo "[pulse-wrapper] routine ${routine_id}: executing script ${script_path} ${script_args[*]}" >>"$LOGFILE"
			"$script_path" "${script_args[@]}" >>"$LOGFILE" 2>&1 || exit_code=$?
		else
			echo "[pulse-wrapper] routine ${routine_id}: executing script ${script_path}" >>"$LOGFILE"
			"$script_path" >>"$LOGFILE" 2>&1 || exit_code=$?
		fi
		if [[ "$exit_code" -eq "$_ROUTINE_TEMPFAIL_EXIT" ]]; then
			status="$_ROUTINE_STATUS_DEFERRED"
			deferred_until=$(_routine_deferred_until "$routine_id")
			echo "[pulse-wrapper] routine ${routine_id}: deferred by GitHub API cooldown until epoch ${deferred_until}" >>"$LOGFILE"
		elif [[ "$exit_code" -ne 0 ]]; then
			status="$_ROUTINE_STATUS_FAILURE"
			echo "[pulse-wrapper] routine ${routine_id}: script exited with code ${exit_code}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] routine ${routine_id}: script completed successfully" >>"$LOGFILE"
		fi
		_routine_finalize_terminal "$routine_id" "$status" "$started_epoch" "" "$deferred_until"
		return 0
	fi

	local custom_script="${agents_dir}/custom/scripts/${routine_id}.sh"
	if [[ -z "$agent_name" && -x "$custom_script" ]]; then
		echo "[pulse-wrapper] routine ${routine_id}: executing custom script ${custom_script}" >>"$LOGFILE"
		"$custom_script" >>"$LOGFILE" 2>&1 || exit_code=$?
		[[ "$exit_code" -eq 0 ]] || status="$_ROUTINE_STATUS_FAILURE"
		_routine_finalize_terminal "$routine_id" "$status" "$started_epoch"
		return 0
	fi

	_routine_dispatch_agent "$routine_id" "$description" "${agent_name:-Build+}" "${repo_path:-$PULSE_DIR}"
	return $?
}

# Module-scope variables set by _routine_parse_line (prefixed to avoid collision).
# These are intentionally module-scope rather than nameref — avoids bash 4.3+ requirement
# for the re-exec guard fallback path, and matches the existing pattern in pulse-wrapper.sh.
_RPL_ID=""
_RPL_REPEAT=""
_RPL_RUN=""
_RPL_AGENT=""
_RPL_DESC=""
_RPL_TIMEZONE=""

#######################################
# Normalize one Markdown line before registry parsing.
#
# Fenced content is opaque, HTML comments are removed, and indented code is
# excluded. Parser state is held in _RML_* globals so updates survive the call.
#
# Arguments: $1 - raw Markdown line
# Output: none; _RML_ACTIVE_LINE and _RML_TRIMMED_LINE contain active content
# Returns: 0 for active content, 1 when the line must be ignored
#######################################
_routine_normalize_markdown_line() {
	local line="$1"
	local comment_prefix="" leading_spaces="" fence_remainder=""
	local current_fence_length=0
	_RML_ACTIVE_LINE=""
	_RML_TRIMMED_LINE=""

	if [[ -n "$_RML_FENCE_CHAR" ]]; then
		leading_spaces="${line%%[! ]*}"
		_RML_TRIMMED_LINE="${line#"$leading_spaces"}"
		if [[ "${#leading_spaces}" -le 3 && "${_RML_TRIMMED_LINE:0:1}" == "$_RML_FENCE_CHAR" ]]; then
			while [[ "${_RML_TRIMMED_LINE:${current_fence_length}:1}" == "$_RML_FENCE_CHAR" ]]; do
				current_fence_length=$((current_fence_length + 1))
			done
			fence_remainder="${_RML_TRIMMED_LINE:${current_fence_length}}"
			if [[ "$current_fence_length" -ge "$_RML_FENCE_LENGTH" && "$fence_remainder" =~ ^[[:space:]]*$ ]]; then
				_RML_FENCE_CHAR=""
				_RML_FENCE_LENGTH=0
			fi
		fi
		return 1
	fi

	_RML_ACTIVE_LINE="$line"
	while true; do
		if [[ "$_RML_IN_COMMENT" -eq 1 ]]; then
			if [[ "$_RML_ACTIVE_LINE" == *"-->"* ]]; then
				_RML_ACTIVE_LINE="${_RML_ACTIVE_LINE#*-->}"
				_RML_IN_COMMENT=0
				continue
			fi
			_RML_ACTIVE_LINE="$comment_prefix"
			break
		fi
		if [[ "$_RML_ACTIVE_LINE" == *"<!--"* ]]; then
			comment_prefix="${comment_prefix}${_RML_ACTIVE_LINE%%<!--*}"
			_RML_ACTIVE_LINE="${_RML_ACTIVE_LINE#*<!--}"
			_RML_IN_COMMENT=1
			continue
		fi
		_RML_ACTIVE_LINE="${comment_prefix}${_RML_ACTIVE_LINE}"
		break
	done

	leading_spaces="${_RML_ACTIVE_LINE%%[! ]*}"
	_RML_TRIMMED_LINE="${_RML_ACTIVE_LINE#"$leading_spaces"}"
	[[ "${#leading_spaces}" -le 3 ]] || return 1
	if [[ "$_RML_TRIMMED_LINE" == '```'* || "$_RML_TRIMMED_LINE" == '~~~'* ]]; then
		_RML_FENCE_CHAR="${_RML_TRIMMED_LINE:0:1}"
		while [[ "${_RML_TRIMMED_LINE:${_RML_FENCE_LENGTH}:1}" == "$_RML_FENCE_CHAR" ]]; do
			_RML_FENCE_LENGTH=$((_RML_FENCE_LENGTH + 1))
		done
		return 1
	fi
	return 0
}

#######################################
# Validate and advance a dedicated routines-repository subsection heading.
#
# Arguments: $1 - current phase, $2 - active heading
# Output: next phase and section-open flag, separated by a colon
# Returns: 0 for the next expected heading, 1 otherwise
#######################################
_routine_dedicated_heading_transition() {
	local current_phase="$1"
	local heading="$2"
	case "${current_phase}:${heading}" in
	"0:## Core Routines (framework-managed)") printf '1:1' ;;
	"1:## User Routines") printf '2:1' ;;
	"2:## Tasks") printf '3:0' ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Extract active Markdown content from one supported routine registry shape.
#
# The complete file is validated before output so duplicate headings, unclosed
# structures, or malformed dedicated layouts cannot partially dispatch. General
# TODO files use `## Routines`; the generated routines repository uses its
# controlled `# Routines` document and ordered core/user/tasks subsections.
#
# Arguments: $1 - path to TODO.md
# Output: active, non-indented lines inside the routine registry
# Returns: 0 for one supported registry, 1 for missing/duplicate/malformed input
#######################################
_routine_extract_section() {
	local todo_file="$1"
	[[ -f "$todo_file" ]] || return 1
	local line="" section_content="" section_style="" heading_transition=""
	local dedicated_style="dedicated" project_style="project"
	local in_section=0 section_count=0 structure_error=0 dedicated_phase=0 pre_registry_heading=0
	_RML_ACTIVE_LINE="" _RML_TRIMMED_LINE="" _RML_FENCE_CHAR="" _RML_FENCE_LENGTH=0 _RML_IN_COMMENT=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		if ! _routine_normalize_markdown_line "$line"; then
			continue
		fi

		if [[ "$_RML_TRIMMED_LINE" =~ ^(##|#)[[:space:]]+Routines[[:space:]]*$ ]]; then
			section_count=$((section_count + 1))
			if [[ -n "$section_style" ]]; then
				structure_error=1
			elif [[ "${BASH_REMATCH[1]}" == "##" ]]; then
				section_style="$project_style"
				in_section=1
			else
				section_style="$dedicated_style"
				in_section=0
				[[ "$pre_registry_heading" -eq 0 ]] || structure_error=1
			fi
			continue
		fi

		if [[ -z "$section_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			pre_registry_heading=1
			continue
		fi

		if [[ "$section_style" == "$dedicated_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			if heading_transition=$(_routine_dedicated_heading_transition "$dedicated_phase" "$_RML_TRIMMED_LINE"); then
				dedicated_phase="${heading_transition%%:*}"
				in_section="${heading_transition#*:}"
			else
				structure_error=1
				in_section=0
			fi
			continue
		fi

		# Level-one and level-two headings close a general-project registry.
		if [[ "$section_style" == "$project_style" ]] &&
			[[ "$_RML_TRIMMED_LINE" =~ ^#[[:space:]]+ || "$_RML_TRIMMED_LINE" =~ ^##[[:space:]]+ ]]; then
			in_section=0
			continue
		fi
		if [[ "$in_section" -eq 1 ]]; then
			section_content="${section_content}${_RML_ACTIVE_LINE}"$'\n'
		fi
	done <"$todo_file"

	if [[ "$section_style" == "$dedicated_style" && "$dedicated_phase" -ne 3 ]]; then
		structure_error=1
	fi
	if [[ "$section_count" -ne 1 || "$structure_error" -ne 0 || -n "$_RML_FENCE_CHAR" || "$_RML_IN_COMMENT" -ne 0 ]]; then
		return 1
	fi
	printf '%s' "$section_content"
	return 0
}

#######################################
# Return success when a routine run target would invoke the supervisor that is
# currently evaluating routines. This protects existing generated TODO files
# that still carry the pre-GH#28544 cron-form r901 entry.
#######################################
_routine_targets_supervisor() {
	local run_script="$1"
	local run_command="${run_script%% *}"
	if [[ "$run_command" == "scripts/pulse-wrapper.sh" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Parse a single routine TODO line into its component fields.
#
# Extracts routine_id, repeat expression, run script, agent name, and
# optional timezone from a TODO.md routine line. Sets module-scope variables
# (_RPL_ID, _RPL_REPEAT, _RPL_RUN, _RPL_AGENT, _RPL_DESC, _RPL_TIMEZONE) on
# success.
#
# Arguments: $1 - a TODO.md line matching the routine pattern
# Returns: 0 if the line was successfully parsed, 1 if it should be skipped
#######################################
_routine_parse_line() {
	local line="$1"
	_RPL_ID=""
	_RPL_REPEAT=""
	_RPL_RUN=""
	_RPL_AGENT=""
	_RPL_DESC=""
	_RPL_TIMEZONE=""

	# Live routine definitions are top-level Markdown list items. Four-space
	# indentation is a code block and must not become scheduler input.
	local leading_spaces="${line%%[! ]*}"
	[[ "${#leading_spaces}" -le 3 ]] || return 1

	# Extract a stable r-prefixed routine ID immediately after [x]. IDs may be
	# numeric (r040) or descriptive (r-gh-audit-scan), but must be a complete
	# whitespace-delimited token so task prose cannot create a false match.
	local _re_routine_id='^[ ]*-[[:space:]]*\[x\][[:space:]]+(r([[:alnum:]][[:alnum:]_-]*|-[[:alnum:]][[:alnum:]_-]*))[[:space:]]'
	if [[ "$line" =~ $_re_routine_id ]]; then
		_RPL_ID="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Extract repeat: field
	# Use a variable to hold the regex so bash does not misparse the
	# literal ')' inside the character class [^)] as the closing '))'
	# of the [[ ]] compound.  The alternation handles cron(min hr …)
	# which contains spaces inside the parentheses — a plain
	# [^[:space:]]+ regex truncates at the first space (bug t2160).
	local _re_repeat='repeat:(cron\([^)]*\)|[^[:space:]]+)'
	if [[ "$line" =~ $_re_repeat ]]; then
		_RPL_REPEAT="${BASH_REMATCH[1]}"
	else
		return 1
	fi

	# Persistent: lifecycle-managed externally (launchd/systemd/supervisor).
	# The pulse never schedules these — skip silently (bug t2175).
	if [[ "$_RPL_REPEAT" == "persistent" ]]; then
		return 1
	fi

	# Extract optional run: field — captures script path and any trailing
	# space-separated argument tokens. Field keywords (agent:, repeat:,
	# timezone:, started:, blocked-by:) always contain a colon, so we stop when
	# we encounter a token with a colon embedded.
	if [[ "$line" =~ run:([^[:space:]]+) ]]; then
		_RPL_RUN="${BASH_REMATCH[1]}"
		# Append optional argument tokens that follow the script path.
		# Stop when a token contains ':' (field keyword) or starts with '#'.
		local _run_rest="${line#*run:"${_RPL_RUN}"}"
		local _arg_token
		while [[ "$_run_rest" =~ ^[[:space:]]+([^[:space:]]+)(.*)$ ]]; do
			_arg_token="${BASH_REMATCH[1]}"
			[[ "$_arg_token" == *:* || "$_arg_token" == "#"* || "$_arg_token" == "~"* || "$_arg_token" == "@"* ]] && break
			_RPL_RUN="${_RPL_RUN} ${_arg_token}"
			_run_rest="${BASH_REMATCH[2]}"
		done
	fi

	# Extract optional agent: field
	if [[ "$line" =~ agent:([^[:space:]]+) ]]; then
		_RPL_AGENT="${BASH_REMATCH[1]}"
	fi

	# Per-routine timezone tokens are intentionally data-only. The scheduler
	# receives the value through one environment assignment, never interpolation.
	local _re_timezone='(^|[[:space:]])timezone:([^[:space:]]*)'
	local _re_timezone_token='^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$'
	if [[ "$line" =~ $_re_timezone ]]; then
		_RPL_TIMEZONE="${BASH_REMATCH[2]}"
		if [[ -z "$_RPL_TIMEZONE" ]] || ! [[ "$_RPL_TIMEZONE" =~ $_re_timezone_token ]]; then
			printf 'ERROR: routine %s has malformed timezone field\n' "$_RPL_ID" >&2
			_RPL_TIMEZONE=""
			return 1
		fi
	fi

	# Extract description (text between ID and first field tag).
	local description_tail="${line#*"${_RPL_ID}"}"
	_RPL_DESC=$(printf '%s' "$description_tail" | sed -E 's/^[[:space:]]*//' | sed -E 's/[[:space:]]*(repeat:|run:|agent:|timezone:|#|~|@|started:|blocked-by:).*//')

	return 0
}

#######################################
# Check one routine schedule with an optional timezone override.
# Arguments: $1 - expression, $2 - last-run epoch, $3 - timezone or empty
# Returns: schedule helper status
#######################################
_routine_schedule_is_due() {
	local expression="$1"
	local last_run_epoch="$2"
	local timezone="$3"
	if [[ -n "$timezone" ]]; then
		AIDEVOPS_SCHEDULE_TIMEZONE="$timezone" "$ROUTINE_SCHEDULE_HELPER" is-due "$expression" "$last_run_epoch"
		return $?
	fi
	"$ROUTINE_SCHEDULE_HELPER" is-due "$expression" "$last_run_epoch"
	return $?
}

#######################################
# Return whether another deferrable routine work unit may start.
#######################################
_routine_rest_core_allows_next() {
	local context="$1"
	local budget_rc=0
	if declare -F pulse_rest_core_priority_allows_next >/dev/null 2>&1; then
		pulse_rest_core_priority_allows_next deferrable "$context" || budget_rc=$?
	elif declare -F pulse_rest_core_priority_allows >/dev/null 2>&1; then
		pulse_rest_core_priority_allows deferrable || budget_rc=$?
	else
		return 0
	fi
	[[ "$budget_rc" -eq 0 ]] && return 0
	echo "[pulse-wrapper] evaluate_routines: REST-core reserve reached at ${context}; remaining routine work deferred (GH#29742)" >>"$LOGFILE"
	return 1
}

#######################################
# Evaluate the framework-managed session miner through the same deterministic
# calendar, retry, lifecycle, and REST-budget path as repository routines.
#######################################
_evaluate_session_miner_routine() {
	local routine_id="r-session-miner"
	local schedule="${AIDEVOPS_SESSION_MINER_SCHEDULE:-daily(@04:40)}"
	local last_epoch=0
	if _routine_retry_blocked "$routine_id"; then
		return 0
	fi
	last_epoch=$(_routine_last_run_epoch "$routine_id")
	if ! _routine_schedule_is_due "$schedule" "$last_epoch" ""; then
		return 0
	fi
	if ! _routine_rest_core_allows_next "routine_execute:${routine_id}"; then
		return 0
	fi
	echo "[pulse-wrapper] routine ${routine_id} is due (expr=${schedule}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
	_routine_execute "$routine_id" "Incremental session insight mining" \
		"scripts/session-miner-pulse.sh --create-issues" "" "$PULSE_DIR"
	return $?
}

#######################################
# Evaluate routines across all pulse-enabled repos
#
# Reads TODO.md from each pulse-enabled repo, extracts enabled routines
# ([x] lines with repeat: fields), checks if due, and dispatches.
#######################################
evaluate_routines() {
	local publication_worker="${SCRIPT_DIR}/task-publication-worker-helper.sh"
	if [[ -x "$publication_worker" ]]; then
		if ! _routine_rest_core_allows_next "routine_publication_worker"; then
			return 0
		fi
		"$publication_worker" run >>"$LOGFILE" 2>&1 || echo "[pulse-wrapper] publication worker pass failed" >>"$LOGFILE"
	fi
	if [[ ! -x "$ROUTINE_SCHEDULE_HELPER" ]]; then
		echo "[pulse-wrapper] evaluate_routines: schedule helper not found at ${ROUTINE_SCHEDULE_HELPER} — skipping" >>"$LOGFILE"
		return 0
	fi

	local repos_json="$REPOS_JSON"
	if [[ ! -f "$repos_json" ]]; then
		echo "[pulse-wrapper] evaluate_routines: repos.json not found — skipping" >>"$LOGFILE"
		return 0
	fi
	_evaluate_session_miner_routine

	local routines_dispatched=0
	local _routine_slug repo_path

	while IFS='|' read -r _routine_slug repo_path; do
		[[ -z "$repo_path" ]] && continue
		local todo_file="${repo_path}/TODO.md"
		[[ -f "$todo_file" ]] || continue

		# Validate and buffer the complete canonical Markdown section before any
		# routine dispatch. This prevents fenced examples, other TODO sections,
		# and malformed/duplicate boundaries from becoming scheduler input.
		local routine_section=""
		if ! routine_section=$(_routine_extract_section "$todo_file"); then
			echo "[pulse-wrapper] evaluate_routines: ${_routine_slug} TODO.md has a missing, duplicate, or malformed routines registry — skipping" >>"$LOGFILE"
			continue
		fi

		local line
		while IFS= read -r line; do
			if ! _routine_parse_line "$line"; then
				continue
			fi

			# The supervisor is launched by launchd/systemd and must never be
			# invoked synchronously from its own evaluator. Keep this runtime
			# guard for stale generated TODO files that predate GH#28544.
			if _routine_targets_supervisor "$_RPL_RUN"; then
				echo "[pulse-wrapper] routine ${_RPL_ID}: skipping self-recursive supervisor target ${_RPL_RUN%% *} (GH#28544)" >>"$LOGFILE"
				continue
			fi

			# Active runs and recent failures have their own bounded retry policy;
			# only successful runs advance the calendar boundary marker.
			if _routine_retry_blocked "$_RPL_ID"; then
				continue
			fi

			# Check if due
			local last_epoch
			local timezone_context=""
			last_epoch=$(_routine_last_run_epoch "$_RPL_ID")
			timezone_context="${_RPL_TIMEZONE:-inherited}"

			if _routine_schedule_is_due "$_RPL_REPEAT" "$last_epoch" "$_RPL_TIMEZONE"; then
				if ! _routine_rest_core_allows_next "routine_execute:${_RPL_ID}"; then
					return 0
				fi
				echo "[pulse-wrapper] routine ${_RPL_ID} is due (expr=${_RPL_REPEAT}, timezone=${timezone_context}, last_run_epoch=${last_epoch})" >>"$LOGFILE"
				_routine_execute "$_RPL_ID" "$_RPL_DESC" "$_RPL_RUN" "$_RPL_AGENT" "$repo_path"
				routines_dispatched=$((routines_dispatched + 1))
			fi
		done <<<"$routine_section"

	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false) | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null || true)

	if [[ "$routines_dispatched" -gt 0 ]]; then
		echo "[pulse-wrapper] evaluate_routines: dispatched ${routines_dispatched} routine(s)" >>"$LOGFILE"
	fi

	return 0
}
