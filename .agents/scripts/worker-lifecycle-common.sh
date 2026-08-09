#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-lifecycle-common.sh — Shared process lifecycle functions
#
# Extracted from pulse-wrapper.sh (t1419) so that both pulse-wrapper.sh and
# worker-watchdog.sh can reuse the same battle-tested process management
# primitives without duplication.
#
# Functions provided:
#   _kill_tree()              Kill a process and all its children (SIGTERM)
#   _force_kill_tree()        Force kill a process tree (SIGKILL)
#   _get_process_age()        Get process age in seconds from ps etime
#   _get_pid_cpu()            Get integer CPU% for a single PID
#   _get_process_tree_cpu()   Get CPU% summed across a process tree (BFS)
#   _extract_session_title_from_cmd() Extract session title from opencode CLI args
#   _count_recent_opencode_messages() Count recent OpenCode messages by title match
#   _collect_worker_stall_evidence()  Summarise recent worker transcript/output tail
#   _sanitize_log_field()     Strip control characters from log fields
#   _sanitize_markdown()      Strip @ mentions and backticks from markdown
#   _validate_int()           Validate and sanitize integer config values
#   _worker_attempt_id_for_issue() Resolve the latest public attempt identity
#   _count_issue_comments_containing_marker() Pagination-safe comment marker count
#   _count_worker_commits()   Count commits in a worktree since elapsed seconds ago
#   _count_worker_messages()  Count session DB messages for a worker
#   _determine_struggle_flag() Determine struggle flag from ratio/commit/elapsed metrics
#   _compute_struggle_ratio() Compute messages/commits ratio for a worker
#   _format_duration()        Format seconds into human-readable duration
#
# Companion files:
#   session_tail_query.py              Session tail classification (GH#6428)
#   worker-lifecycle-verbose.sh        Verbose lifecycle checkpoint watcher
#   worker_lifecycle_extract_title.py  Extract --title from CLI args (GH#17561)
#   worker_lifecycle_stall_evidence.py Classify worker log tail (GH#17561)
#   worker_lifecycle_resolve_session.py Resolve session ID from title (GH#17561)
#   worker_lifecycle_count_messages.py Count session DB messages (GH#17561)
#   list_active_workers.awk            Deduplicate active worker processes (GH#17561)
#
# Usage: source worker-lifecycle-common.sh
#
# Include guard prevents double-loading (readonly errors, function redefinition).

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_LOADED=1
_WLC_STATUS_BLOCKED="blocked"

_ensure_worker_lineage() {
	local session_key="$1"
	local epoch=""
	epoch=$(date +%s 2>/dev/null || printf '0')
	if [[ -z "${AIDEVOPS_WORKER_ID:-}" ]]; then
		export AIDEVOPS_WORKER_ID="worker:${session_key:-session}:$$:${epoch}:${RANDOM:-0}"
	fi
	if [[ -z "${AIDEVOPS_ROOT_WORKER_ID:-}" ]]; then
		export AIDEVOPS_ROOT_WORKER_ID="${AIDEVOPS_PARENT_WORKER_ID:-$AIDEVOPS_WORKER_ID}"
	fi
	if [[ -z "${AIDEVOPS_CORRELATION_ID:-}" ]]; then
		export AIDEVOPS_CORRELATION_ID="correlation:${AIDEVOPS_ROOT_WORKER_ID}"
	fi
	: "${AIDEVOPS_PARENT_WORKER_ID:=}"
	: "${AIDEVOPS_CAUSATION_ID:=}"
	: "${AIDEVOPS_PARENT_EVENT_ID:=}"
	: "${AIDEVOPS_ROOT_EVENT_ID:=}"
	export AIDEVOPS_WORKER_ID AIDEVOPS_PARENT_WORKER_ID AIDEVOPS_ROOT_WORKER_ID AIDEVOPS_CORRELATION_ID
	export AIDEVOPS_CAUSATION_ID AIDEVOPS_PARENT_EVENT_ID AIDEVOPS_ROOT_EVENT_ID
	return 0
}

_ensure_worker_attempt_identity() {
	if [[ -z "${AIDEVOPS_ATTEMPT_ID:-}" ]]; then
		AIDEVOPS_ATTEMPT_ID=$(aidevops_generate_execution_id "attempt")
	fi
	if [[ ! "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]+$ ]]; then
		AIDEVOPS_ATTEMPT_STARTED_AT=$(_worker_attempt_start_marker)
	fi
	export AIDEVOPS_ATTEMPT_ID AIDEVOPS_ATTEMPT_STARTED_AT
	return 0
}

# Return a high-resolution epoch marker so attempts dispatched within the same
# second retain deterministic chronology. Python is already a framework runtime
# dependency; the seconds fallback preserves a comparable 19-digit shape.
_worker_attempt_start_marker() {
	local marker=""
	marker=$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || true)
	if [[ ! "$marker" =~ ^[0-9]{19}$ ]]; then
		marker="$(date +%s 2>/dev/null || printf '0')000000000"
	fi
	printf '%s' "$marker"
	return 0
}

_begin_worker_runtime_run() {
	AIDEVOPS_RUN_ID=$(aidevops_generate_execution_id "run")
	export AIDEVOPS_RUN_ID
	return 0
}

_worker_attempt_id_for_issue() {
	local issue_number="$1"
	local repo_slug="$2"
	local attempt_id="${3:-${AIDEVOPS_ATTEMPT_ID:-}}"
	local ledger_dir="${AIDEVOPS_DISPATCH_LEDGER_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local ledger_file="${ledger_dir}/dispatch-ledger.jsonl"

	[[ "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" ]] || return 1
	if [[ -z "$attempt_id" && -s "$ledger_file" ]]; then
		attempt_id=$(jq -sr --arg issue "$issue_number" --arg repo "$repo_slug" '
			[.[] | select((.issue_number // "") == $issue and (.repo_slug // "") == $repo and (.attempt_id // "") != "")]
			| last | .attempt_id // empty
		' "$ledger_file" 2>/dev/null) || attempt_id=""
	fi
	[[ "$attempt_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || return 1
	printf '%s' "$attempt_id"
	return 0
}

_objective_disposition_json() {
	local issue_number="$1"
	local repo_slug="$2"
	local attempt_id="${3:-}"
	local helper="${BASH_SOURCE[0]%/*}/objective-reconciliation-helper.sh"
	local -a disposition_args=(disposition --repo "$repo_slug" --issue "$issue_number")

	[[ -x "$helper" && "$issue_number" =~ ^[1-9][0-9]*$ && -n "$repo_slug" ]] || return 1
	[[ -n "$attempt_id" ]] && disposition_args+=(--attempt-id "$attempt_id")
	"$helper" "${disposition_args[@]}" 2>/dev/null
	return $?
}

_objective_disposition_suppresses() {
	local suppression_field="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local attempt_id="${4:-}"
	local disposition=""

	case "$suppression_field" in
	suppress_fast_fail | suppress_retry | suppress_enrichment | suppress_failure_mining) ;;
	*) return 1 ;;
	esac
	disposition=$(_objective_disposition_json "$issue_number" "$repo_slug" "$attempt_id") || return 1
	printf '%s' "$disposition" | jq -e --arg field "$suppression_field" '.[$field] == true' >/dev/null 2>&1
	return $?
}

_emit_objective_recovery_evidence() {
	local event_type="$1"
	local status="$2"
	local classification="$3"
	local issue_number="${WORKER_ISSUE_NUMBER:-${ISSUE_NUMBER:-}}"
	local repo="${GITHUB_REPOSITORY:-${WORKER_REPO:-}}"
	[[ "$issue_number" =~ ^[0-9]+$ && -n "$repo" ]] || return 0
	local evidence_file="${AIDEVOPS_OBJECTIVE_EVIDENCE_FILE:-${HOME}/.aidevops/state/objective-evidence.jsonl}"
	local evidence_dir=""
	local evidence_timestamp="0"
	local branch_name=""
	local worktree_name=""
	local commit_sha=""
	local log_path="${WORKER_LOG_FILE:-${HEADLESS_RUNTIME_LOG:-}}"
	local next_action="monitor_worker"
	local execution_path_state="running"
	local recovery_attempt="${AIDEVOPS_RECOVERY_ATTEMPT:-0}"
	local attempt_started_at="${AIDEVOPS_ATTEMPT_STARTED_AT:-0}"
	local repair_pr_number="${AIDEVOPS_PR_REPAIR_NUMBER:-}"
	local repair_head_sha="${AIDEVOPS_PR_REPAIR_HEAD_SHA:-}"
	local repair_head_ref="${AIDEVOPS_PR_REPAIR_HEAD_REF:-}"
	local repair_fingerprint="${AIDEVOPS_PR_REPAIR_FINGERPRINT:-}"
	[[ "$recovery_attempt" =~ ^[0-9]+$ ]] || recovery_attempt=0
	[[ "$attempt_started_at" =~ ^[0-9]+$ ]] || attempt_started_at=0
	evidence_dir=$(dirname "$evidence_file")
	mkdir -p "$evidence_dir" 2>/dev/null || return 0
	evidence_timestamp=$(date +%s 2>/dev/null) || evidence_timestamp=0
	branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch_name=""
	commit_sha=$(git rev-parse HEAD 2>/dev/null) || commit_sha=""
	worktree_name=$(basename "${WORKER_WORKTREE_PATH:-$PWD}")
	case "$event_type" in
	worker.completed) next_action="monitor_pr"; execution_path_state="terminal" ;;
	worker.failed) next_action="retry_infrastructure"; execution_path_state="recovery" ;;
	worker.commit_attempted|worker.push_attempted) next_action="resume_session"; execution_path_state="checkpointed" ;;
	esac
	local evidence_record=""
	evidence_record=$(jq -nc \
		--arg event_type "$event_type" \
		--arg status "$status" \
		--arg classification "$classification" \
		--arg repo "$repo" \
		--argjson issue_number "$issue_number" \
		--argjson evidence_timestamp "$evidence_timestamp" \
		--arg worker_id "${AIDEVOPS_WORKER_ID:-}" \
		--arg attempt_id "${AIDEVOPS_ATTEMPT_ID:-}" \
		--arg run_id "${AIDEVOPS_RUN_ID:-}" \
		--argjson attempt_started_at "$attempt_started_at" \
		--arg branch "$branch_name" \
		--arg worktree "$worktree_name" \
		--arg commit "$commit_sha" \
		--arg next_action "$next_action" \
		--arg execution_path_state "$execution_path_state" \
		--argjson recovery_attempt "${recovery_attempt:-0}" \
		--arg repair_pr_number "$repair_pr_number" \
		--arg repair_head_sha "$repair_head_sha" \
		--arg repair_head_ref "$repair_head_ref" \
		--arg repair_fingerprint "$repair_fingerprint" \
		--argjson logs_preserved "$([[ -n "$log_path" && -s "$log_path" ]] && printf true || printf false)" \
		--argjson verification_preserved "$([[ -n "${AIDEVOPS_VERIFICATION_EVIDENCE:-}" ]] && printf true || printf false)" \
		'{event_type:$event_type,status:$status,classification:$classification,repo:$repo,
		issue_number:$issue_number,evidence_timestamp:$evidence_timestamp,worker_id:$worker_id,
		attempt_id:$attempt_id,run_id:$run_id,attempt_started_at:$attempt_started_at,
		branch:$branch,worktree:$worktree,commit:$commit,next_action:$next_action,
		execution_path_state:$execution_path_state,recovery_attempt:$recovery_attempt,
		branch_preserved:($branch != ""),worktree_preserved:($worktree != ""),
		commits_preserved:($commit != ""),logs_preserved:$logs_preserved,
		verification_preserved:$verification_preserved,subsequent_action_at:$evidence_timestamp,
		pr_repair:(if $repair_pr_number == "" then null else {pr_number:($repair_pr_number|tonumber),
		head_sha:$repair_head_sha,head_ref:$repair_head_ref,failure_fingerprint:$repair_fingerprint} end)}') || evidence_record=""
	[[ -n "$evidence_record" ]] && printf '%s\n' "$evidence_record" >>"$evidence_file" 2>/dev/null || true
	return 0
}

_emit_worker_runtime_event() {
	local event_type="$1"
	local status="${2:-}"
	local classification="${3:-}"
	local runtime_events="${BASH_SOURCE[0]%/*}/runtime-events.mjs"
	[[ -n "${AIDEVOPS_WORKER_ID:-}" ]] || return 0
	_emit_objective_recovery_evidence "$event_type" "$status" "$classification"
	case "$event_type" in
	worker.completed | worker.failed | worker.deferred)
		if [[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" && "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ && -n "${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}" ]]; then
			local lease_helper="${BASH_SOURCE[0]%/*}/dispatch-claim-helper.sh"
			"$lease_helper" transition terminal "$WORKER_ISSUE_NUMBER" \
				"${DISPATCH_REPO_SLUG:-$WORKER_REPO_SLUG}" "$AIDEVOPS_DISPATCH_LEASE_TOKEN" \
				"${_invoke_session_key:-issue-${WORKER_ISSUE_NUMBER}}" 0 >/dev/null 2>&1 || true
		fi
		;;
	esac
	[[ -f "$runtime_events" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local -a event_cmd=(node "$runtime_events" emit "$event_type" --source worker_self_reported)
	[[ -n "$status" ]] && event_cmd+=(--status "$status")
	[[ -n "$classification" ]] && event_cmd+=(--classification "$classification")
	"${event_cmd[@]}" >/dev/null 2>&1 || true
	return 0
}

_emit_supervisor_dispatch_event() {
	local worker_id="$1"
	local parent_worker_id="$2"
	local root_worker_id="$3"
	local correlation_id="$4"
	local runtime_events="${BASH_SOURCE[0]%/*}/runtime-events.mjs"
	local event_id=""
	[[ -n "$worker_id" && -f "$runtime_events" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0

	local -a event_cmd=(
		node "$runtime_events" emit worker.dispatched
		--subject "$worker_id"
		--worker "$worker_id"
		--root-worker "$root_worker_id"
		--correlation "$correlation_id"
		--source supervisor_observed
		--root-dispatch
		--print-id
	)
	if [[ -n "$parent_worker_id" ]]; then
		event_cmd+=(--parent-worker "$parent_worker_id")
	fi
	if [[ -n "${AIDEVOPS_ROOT_EVENT_ID:-}" ]]; then
		event_cmd+=(--root-event "$AIDEVOPS_ROOT_EVENT_ID")
	fi
	if [[ -n "${AIDEVOPS_PARENT_EVENT_ID:-}" ]]; then
		event_cmd+=(--parent-event "$AIDEVOPS_PARENT_EVENT_ID" --causation "$AIDEVOPS_PARENT_EVENT_ID")
	elif [[ -n "${AIDEVOPS_CAUSATION_ID:-}" ]]; then
		event_cmd+=(--causation "$AIDEVOPS_CAUSATION_ID")
	fi
	event_id=$("${event_cmd[@]}" 2>/dev/null) || event_id=""
	printf '%s' "$event_id"
	return 0
}

#######################################
# Resolve the OpenCode session DB path
# Returns: path via stdout
#######################################
_opencode_db_path() {
	local db_path="${OPENCODE_DB_PATH:-${HOME}/.local/share/opencode/opencode.db}"
	printf '%s' "$db_path"
	return 0
}

#######################################
# Extract session title from a worker command line
# Arguments:
#   cmd - command line string
# Returns: session title or empty string via stdout
#
# Logic extracted to worker_lifecycle_extract_title.py (GH#17561).
#######################################
_extract_session_title() {
	local cmd="$1"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/worker_lifecycle_extract_title.py"
	local session_title=""

	if [[ -f "$py_script" ]]; then
		session_title=$(SESSION_CMD="$cmd" python3 "$py_script" 2>/dev/null) || session_title=""
	fi

	printf '%s' "${session_title:-}"
	return 0
}

#######################################
# Validate preconditions for session tail evidence collection
# Arguments:
#   cmd - worker command line
# Outputs: "db_path|session_title" on success, or "none|<reason>" on failure
# Returns: 0 always (caller checks output prefix)
#######################################
_get_session_tail_preconditions() {
	local cmd="$1"
	local db_path session_title
	db_path=$(_opencode_db_path)
	session_title=$(_extract_session_title "$cmd")

	if [[ ! -f "$db_path" ]]; then
		printf '%s' 'none|OpenCode session DB unavailable'
		return 0
	fi

	if [[ -z "$session_title" ]]; then
		printf '%s' 'none|Worker command has no session title'
		return 0
	fi

	printf '%s|%s' "$db_path" "$session_title"
	return 0
}

#######################################
# Python script: query OpenCode DB and classify session tail.
# Reads env vars: SESSION_TAIL_DB_PATH, SESSION_TAIL_TITLE,
#   SESSION_TAIL_TIMEOUT, SESSION_TAIL_LIMIT
# Returns: "classification|summary" via stdout
#
# Logic extracted to session_tail_query.py for testability and to
# keep this function under the 100-line complexity threshold (GH#6428).
#######################################
_run_session_tail_python() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/session_tail_query.py"

	if [[ ! -f "$py_script" ]]; then
		echo "none|session_tail_query.py not found at ${py_script}" >&2
		printf '%s' "none|session_tail_query.py missing"
		return 1
	fi

	python3 "$py_script"
	return 0
}

#######################################
# Set env vars and invoke the session tail Python script
# Arguments:
#   db_path
#   session_title
#   timeout_seconds
#   part_limit
# Returns: "classification|summary" via stdout
#######################################
_query_session_tail() {
	local db_path="$1"
	local session_title="$2"
	local timeout_seconds="$3"
	local part_limit="$4"

	SESSION_TAIL_DB_PATH="$db_path" \
		SESSION_TAIL_TITLE="$session_title" \
		SESSION_TAIL_TIMEOUT="$timeout_seconds" \
		SESSION_TAIL_LIMIT="$part_limit" \
		_run_session_tail_python
	return 0
}

#######################################
# Summarise the recent OpenCode transcript tail for a worker session
# Arguments:
#   arg1 - worker command line
#   arg2 - recent activity timeout seconds
#   arg3 - maximum parts to inspect (optional, default: 8)
# Returns: "classification|summary" where classification is one of
#   active, provider-waiting, stalled, none
#######################################
_get_session_tail_evidence() {
	local cmd="$1"
	local timeout_seconds="$2"
	local part_limit="${3:-8}"

	local preconditions
	preconditions=$(_get_session_tail_preconditions "$cmd")

	# Early-exit if preconditions returned a "none|..." failure
	case "$preconditions" in
	none\|*)
		printf '%s' "$preconditions"
		return 0
		;;
	esac

	local db_path session_title
	db_path="${preconditions%%|*}"
	session_title="${preconditions#*|}"

	_query_session_tail "$db_path" "$session_title" "$timeout_seconds" "$part_limit"
	return 0
}

#######################################
# Kill a process and all its children (macOS-compatible)
# Arguments:
#   arg1 - PID to kill
#######################################
_kill_tree() {
	local pid="$1"
	# Find all child processes recursively (bash 3.2 compatible — no mapfile)
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Force kill a process and all its children
# Arguments:
#   arg1 - PID to kill
#######################################
_force_kill_tree() {
	local pid="$1"
	local child
	while IFS= read -r child; do
		[[ -n "$child" ]] && _force_kill_tree "$child"
	done < <(pgrep -P "$pid" 2>/dev/null || true)
	kill -9 "$pid" 2>/dev/null || true
	return 0
}

#######################################
# Get process age in seconds
# Arguments:
#   arg1 - PID
# Returns: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
	local etime
	# macOS ps etime format: MM:SS or HH:MM:SS or D-HH:MM:SS
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	# Parse D-HH:MM:SS format
	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	# Count colons to determine format
	local colon_count
	colon_count=$(echo "$etime" | tr -cd ':' | wc -c | tr -d ' ')

	if [[ "$colon_count" -eq 2 ]]; then
		# HH:MM:SS
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		# MM:SS
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	# Validate components are numeric before arithmetic expansion
	[[ "$days" =~ ^[0-9]+$ ]] || days=0
	[[ "$hours" =~ ^[0-9]+$ ]] || hours=0
	[[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0

	# Remove leading zeros to avoid octal interpretation
	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

#######################################
# Get integer CPU% for a single PID (helper for _get_process_tree_cpu)
#
# Extracts %CPU via ps, truncates to integer, validates numeric.
# Returns 0 if the process doesn't exist or ps fails.
#
# Arguments:
#   arg1 - PID
# Returns: integer CPU percentage via stdout
#######################################
_get_pid_cpu() {
	local pid="$1"
	local cpu_str
	cpu_str=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ') || cpu_str="0"
	# ps returns float like "12.3" — extract integer part
	local cpu_int="${cpu_str%%.*}"
	[[ "$cpu_int" =~ ^[0-9]+$ ]] || cpu_int=0
	echo "$cpu_int"
	return 0
}

#######################################
# Walk a process tree breadth-first and emit all descendant PIDs (t3059)
#
# Iteratively walks the full descendant tree using pgrep -P at each
# level. The root PID itself is NOT emitted — only its descendants
# (children, grandchildren, …). Output is one PID per line, deduped
# via sort -u. Returns nothing (zero lines) for a leaf process.
#
# pgrep -P only returns DIRECT children. A naive one-level pgrep
# undercounts when active processes are nested deeper than one level
# (e.g., parent shell → opencode wrapper → node runtime → language
# server). Walking BFS preserves the full tree.
#
# Used by:
#   _get_process_tree_cpu (t1398.3) — sum CPU% across whole tree
#   _watchdog_tree_cpu    (t3059)   — same primitive in worker-activity-watchdog.sh
#
# Arguments:
#   arg1 - root PID
# Returns: descendant PIDs, one per line, sorted+deduped, via stdout
#######################################
_get_descendant_pids() {
	local root_pid="$1"
	[[ "$root_pid" =~ ^[0-9]+$ ]] || return 0

	local pids_to_scan=("$root_pid")
	local descendants=()
	local i=0
	while [[ $i -lt ${#pids_to_scan[@]} ]]; do
		local current_pid="${pids_to_scan[$i]}"
		local child
		while IFS= read -r child; do
			if [[ -n "$child" ]]; then
				pids_to_scan+=("$child")
				descendants+=("$child")
			fi
		done < <(pgrep -P "$current_pid" 2>/dev/null || true)
		i=$((i + 1))
	done

	# Bash 3.2: guard against expanding an empty array under set -u.
	if [[ ${#descendants[@]} -gt 0 ]]; then
		printf "%s\n" "${descendants[@]}" | sort -u
	fi
	return 0
}

#######################################
# Get CPU usage percentage for a process tree (t1398.3, refactored t3059)
#
# Walks the full descendant tree (BFS) via _get_descendant_pids, then
# sums per-PID CPU% (root + descendants) via _get_pid_cpu. Previous
# inline-BFS implementation was duplicated in worker-activity-watchdog.sh's
# _watchdog_tree_cpu (one-level pgrep -P only); both now share the helper.
#
# Arguments:
#   arg1 - PID
# Returns: integer CPU percentage via stdout (0-N, summed across cores)
#######################################
_get_process_tree_cpu() {
	local pid="$1"
	local total_cpu
	total_cpu=$(_get_pid_cpu "$pid")

	local descendant
	while IFS= read -r descendant; do
		[[ -n "$descendant" ]] || continue
		local cpu
		cpu=$(_get_pid_cpu "$descendant")
		total_cpu=$((total_cpu + cpu))
	done < <(_get_descendant_pids "$pid")

	echo "$total_cpu"
	return 0
}

#######################################
# Extract the --title value from an opencode command line
# Arguments:
#   arg1 - command line string
# Returns: session title via stdout, or empty string if absent
#######################################
_extract_session_title_from_cmd() {
	local cmd="$1"
	_extract_session_title "$cmd"
	return 0
}

#######################################
# Resolve OpenCode session ID from a worker command line
# Arguments:
#   arg1 - command line string
# Returns: session id via stdout, or empty string
#######################################
_resolve_session_id_from_cmd() {
	local cmd="$1"
	local db_path
	db_path=$(_opencode_db_path)
	local session_id=""

	if [[ "$cmd" =~ --session[[:space:]]+([^[:space:]]+) ]] || [[ "$cmd" =~ --session=([^[:space:]]+) ]]; then
		session_id="${BASH_REMATCH[1]}"
		printf '%s' "$session_id"
		return 0
	fi

	[[ -f "$db_path" ]] || {
		printf '%s' ""
		return 0
	}

	local session_title
	session_title=$(_extract_session_title_from_cmd "$cmd")
	[[ -n "$session_title" ]] || {
		printf '%s' ""
		return 0
	}

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# Logic extracted to worker_lifecycle_resolve_session.py (GH#17561)
	session_id=$(
		DB_PATH="$db_path" TITLE="$session_title" \
			python3 "${script_dir}/worker_lifecycle_resolve_session.py"
	) 2>/dev/null || session_id=""

	printf '%s' "$session_id"
	return 0
}

#######################################
# Count recent OpenCode messages for sessions matching a title fragment
# Arguments:
#   arg1 - title fragment (task ID or session title)
#   arg2 - recent window in seconds
# Returns: integer count via stdout
#######################################
_count_recent_opencode_messages() {
	local session_match="$1"
	local recent_window="$2"
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	[[ -n "$session_match" ]] || {
		printf '%s' "0"
		return 0
	}
	[[ "$recent_window" =~ ^[0-9]+$ ]] || recent_window=180

	if [[ ! -f "$db_path" ]]; then
		printf '%s' "0"
		return 0
	fi

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local recent_count
	# Logic extracted to worker_lifecycle_count_messages.py (GH#17561)
	recent_count=$(
		DB_PATH="$db_path" MODE="recent" MATCH="$session_match" WINDOW="$recent_window" \
			python3 "${script_dir}/worker_lifecycle_count_messages.py"
	) 2>/dev/null || recent_count=0
	[[ "$recent_count" =~ ^[0-9]+$ ]] || recent_count=0

	printf '%s' "$recent_count"
	return 0
}

#######################################
# Summarise recent worker transcript/output evidence for stall diagnosis
# Arguments:
#   arg1 - session title fragment (task ID or exact title)
#   arg2 - log file path (optional)
#   arg3 - recent window in seconds
#   arg4 - number of log lines to inspect
# Returns: tab-separated "recent_count<TAB>classification<TAB>excerpt"
#######################################
_collect_worker_stall_evidence() {
	local session_match="$1"
	local log_file="${2:-}"
	local recent_window="${3:-180}"
	local tail_lines="${4:-8}"
	local recent_count
	recent_count=$(_count_recent_opencode_messages "$session_match" "$recent_window")
	[[ "$tail_lines" =~ ^[0-9]+$ ]] || tail_lines=8

	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local py_script="${script_dir}/worker_lifecycle_stall_evidence.py"

	local evidence
	# Logic extracted to worker_lifecycle_stall_evidence.py (GH#17561)
	evidence=$(python3 "$py_script" "$log_file" "$tail_lines" 2>/dev/null) || evidence=""

	local classification excerpt
	IFS=$'\t' read -r classification excerpt <<<"${evidence:-no_log$'\t'}"
	printf '%s\t%s\t%s\n' "$recent_count" "$classification" "$excerpt"
	return 0
}

# Sanitise untrusted strings before embedding in GitHub markdown comments.
# Strips @ mentions (prevents unwanted notifications) and backtick sequences
# (prevents markdown injection). Used for API response data that gets posted
# as issue/PR comments.
_sanitize_markdown() {
	local input="$1"
	# Remove @ mentions to prevent notification spam
	input="${input//@/}"
	# Remove backtick sequences that could break markdown fencing
	input="${input//\`/}"
	printf '%s' "$input"
	return 0
}

# Sanitise untrusted strings before writing to log files.
# Strips control characters (newlines, carriage returns, tabs, and non-printable
# chars) to prevent log injection attacks where a crafted process name could
# insert fake log entries or mislead administrators. (Gemini review, PR #2881)
_sanitize_log_field() {
	local input="$1"
	# Strip all control characters (ASCII 0x00-0x1F and 0x7F) except space.
	# The tr octal range is intentional (not a glob).
	# shellcheck disable=SC2060
	printf '%s' "$input" | tr -d '\000-\037\177'
	return 0
}

#######################################
# Validate numeric configuration values
#
# Prevents command injection via $(( )) expansion. Bash arithmetic
# evaluates variable contents as expressions, so unsanitised strings
# like "a[$(cmd)]" would execute arbitrary commands.
#
# Arguments:
#   arg1 - variable name (for error messages)
#   arg2 - value to validate
#   arg3 - default value if invalid
#   arg4 - minimum value (optional, default: 0)
# Returns: validated integer via stdout
#######################################
_validate_int() {
	local name="$1" value="$2" default="$3" min="${4:-0}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[worker-lifecycle] Invalid ${name}: ${value} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	# Canonicalize to base-10: strip leading zeros to prevent bash octal interpretation
	# e.g., "08" (invalid octal) or "01024" (octal 532) become "8" and "1024"
	local canonical
	canonical=$(printf '%d' "$((10#$value))")
	# Enforce minimum to prevent divide-by-zero for divisor-backed settings
	if ((canonical < min)); then
		echo "[worker-lifecycle] ${name}=${canonical} below minimum ${min} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	printf '%s' "$canonical"
	return 0
}

#######################################
# Count commits in a worktree since a given number of seconds ago (GH#17078)
# Arguments:
#   arg1 - worktree directory path
#   arg2 - elapsed seconds (time window for git log)
# Returns: integer commit count via stdout
#######################################
_count_worker_commits() {
	local worktree_dir="$1"
	local elapsed_seconds="$2"
	local commits=0

	if [[ -d "${worktree_dir}/.git" || -f "${worktree_dir}/.git" ]]; then
		# Use (cmd || true) pattern for set -e safety — ensures the pipeline
		# always succeeds and stderr remains visible for debugging (GH#4010)
		commits=$( (git -C "$worktree_dir" log --oneline --since="${elapsed_seconds} seconds ago" || true) | wc -l | tr -d ' ')
	fi

	echo "$commits"
	return 0
}

#######################################
# Count session messages from the OpenCode DB for a worker (GH#17078)
# Arguments:
#   arg1 - worker command line
#   arg2 - elapsed seconds (time window for message query)
# Output: "available|<count>" or "unavailable|0"
#   "available" means the DB was found and queried
#   "unavailable" means no DB — caller must return n/a (GH#11278)
#######################################
_count_worker_messages() {
	local cmd="$1"
	local elapsed_seconds="$2"
	local db_path="${HOME}/.local/share/opencode/opencode.db"

	# When neither DB is available, return unavailable — NEVER fabricate message
	# counts from elapsed time. The old heuristic (messages = elapsed_minutes × 2)
	# produced false positives: a 19-minute worker could be reported as "17h
	# with struggle_ratio: 48" when the process age was inherited from a
	# long-lived parent or stale worktree. See GH#11278.
	if [[ ! -f "$db_path" ]]; then
		echo "unavailable|0"
		return 0
	fi

	local session_id messages=0
	session_id=$(_resolve_session_id_from_cmd "$cmd")

	if [[ -n "$session_id" ]]; then
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		# Logic extracted to worker_lifecycle_count_messages.py (GH#17561)
		messages=$(
			DB_PATH="$db_path" MODE="session" MATCH="$session_id" WINDOW="$elapsed_seconds" \
				python3 "${script_dir}/worker_lifecycle_count_messages.py"
		) 2>/dev/null || messages=0
	fi

	echo "available|${messages}"
	return 0
}

#######################################
# Determine the struggle flag from ratio/commit/elapsed metrics (GH#17078)
# Arguments:
#   arg1 - ratio (messages / max(1, commits))
#   arg2 - commits count
#   arg3 - elapsed seconds
#   arg4 - min elapsed seconds threshold
#   arg5 - ratio threshold for "struggling"
# Returns: flag string ("", "struggling", or "thrashing") via stdout
#######################################
_determine_struggle_flag() {
	local ratio="$1"
	local commits="$2"
	local elapsed_seconds="$3"
	local min_elapsed_seconds="$4"
	local threshold="$5"
	local flag=""

	if [[ "$elapsed_seconds" -ge "$min_elapsed_seconds" ]]; then
		if [[ "$ratio" -gt 50 && "$elapsed_seconds" -ge 3600 ]]; then
			flag="thrashing"
		elif [[ "$ratio" -gt "$threshold" && "$commits" -eq 0 ]]; then
			flag="struggling"
		fi
	fi

	echo "$flag"
	return 0
}

#######################################
# Compute struggle ratio for a single worker (t1367)
#
# struggle_ratio = messages / max(1, commits)
# High ratio with elapsed time indicates a worker that is active but
# not producing useful output (thrashing). This is an informational
# signal — the supervisor LLM decides what to do with it.
#
# Arguments:
#   arg1 - worker PID
#   arg2 - worker elapsed seconds
#   arg3 - worker command line
# Output: "ratio|commits|messages|flag" to stdout
#   flag: "" (normal), "struggling", or "thrashing"
#######################################
_compute_struggle_ratio() {
	local pid="$1"
	local elapsed_seconds="$2"
	local cmd="$3"

	local threshold="${STRUGGLE_RATIO_THRESHOLD:-30}"
	local min_elapsed="${STRUGGLE_MIN_ELAPSED_MINUTES:-30}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=30
	[[ "$min_elapsed" =~ ^[0-9]+$ ]] || min_elapsed=30
	local min_elapsed_seconds=$((min_elapsed * 60))

	# Extract --dir from command line
	local worktree_dir=""
	if [[ "$cmd" =~ --dir[[:space:]]+([^[:space:]]+) ]]; then
		worktree_dir="${BASH_REMATCH[1]}"
	fi

	# No worktree — can't compute
	if [[ -z "$worktree_dir" || ! -d "$worktree_dir" ]]; then
		echo "n/a|0|0|"
		return 0
	fi

	# Count commits since worker start (elapsed_seconds is the time window).
	local commits
	commits=$(_count_worker_commits "$worktree_dir" "$elapsed_seconds")

	# Count messages from the session DB (runtime-aware).
	# Supports OpenCode (opencode.db). Returns "unavailable|0" when no DB found.
	local msg_result db_status messages
	msg_result=$(_count_worker_messages "$cmd" "$elapsed_seconds")
	db_status="${msg_result%%|*}"
	messages="${msg_result#*|}"

	# If no session DB is available (e.g., Claude Code runtime without
	# OpenCode DB), return n/a — do NOT fabricate counts (GH#11278).
	if [[ "$db_status" == "unavailable" ]]; then
		echo "n/a|${commits}|0|"
		return 0
	fi

	# Compute ratio and flag
	local denominator=$((commits > 0 ? commits : 1))
	local ratio=$((messages / denominator))
	local flag
	flag=$(_determine_struggle_flag "$ratio" "$commits" "$elapsed_seconds" "$min_elapsed_seconds" "$threshold")

	echo "${ratio}|${commits}|${messages}|${flag}"
	return 0
}

#######################################
# Format seconds into human-readable duration
# Arguments:
#   arg1 - seconds
# Returns: formatted string via stdout (e.g., "2h 15m", "45m 30s")
#######################################
_format_duration() {
	local total_seconds="$1"
	[[ "$total_seconds" =~ ^[0-9]+$ ]] || total_seconds=0

	local hours=$((total_seconds / 3600))
	local minutes=$(((total_seconds % 3600) / 60))
	local seconds=$((total_seconds % 60))

	if [[ "$hours" -gt 0 ]]; then
		echo "${hours}h ${minutes}m"
	elif [[ "$minutes" -gt 0 ]]; then
		echo "${minutes}m ${seconds}s"
	else
		echo "${seconds}s"
	fi
	return 0
}

#######################################
# List active worker processes (logical, deduplicated).
#
# Moved here from pulse-wrapper.sh so that both pulse-wrapper.sh and
# stats-functions.sh (via stats-wrapper.sh) use the same counting logic.
# Previously, stats-functions.sh had a simpler _scan_active_workers that
# missed headless-runtime-helper workers, didn't deduplicate process chains,
# and didn't filter zombie/stopped processes — producing wrong worker counts
# on the pinned health issue dashboards.
#
# t5072: Count logical workers (one per session/issue), not OS process tree nodes.
# A single opencode worker spawns a 3-process chain:
#   bash sandbox-exec-helper.sh run ... -- opencode run ...  (top-level launcher)
#   node /opt/homebrew/bin/opencode run ...                  (node child)
#   /path/to/.opencode run ...                               (binary grandchild)
# All three contain /full-loop (or /review-issue-pr) and opencode in their command line.
#
# GH#12361 / GH#14944: Workers may appear either as direct opencode
# processes or as headless-runtime-helper.sh wrappers around sandbox +
# opencode children. Counting must treat the whole wrapper/process tree as
# one logical worker.
#
# GH#6413: Process state filtering — exclude zombie (Z) and stopped (T)
# processes.
#
# Output: one line per logical worker: "pid etime command..."
#######################################
list_active_worker_processes() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local awk_script="${script_dir}/list_active_workers.awk"
	# Awk logic extracted to list_active_workers.awk (GH#17561)
	# t2190: use `axww` (unlimited line width) so Linux procps doesn't
	# truncate the command column to the detected terminal width (~80
	# cols when piped). Worker commands contain the full HEADLESS_
	# CONTINUATION_CONTRACT_V6 prompt (5000+ chars); without `ww`, the
	# awk match on `/full-loop`, `--role worker`, `--session-key issue-NNN`,
	# and `--dir <path>` all fail — has_worker_for_repo_issue returns
	# false within the 35s grace window, recover_failed_launch_state
	# unassigns the worker, and every dispatch cycle loops on the same
	# issue. macOS BSD ps already emits full commands; `ww` is harmless
	# there (and also supported).
	ps axwwo pid,stat,etime,command | awk -f "$awk_script"
	return 0
}

#######################################
# Detect auto-generated review-feedback issues that already carry bounded
# implementation context even when they do not name a concrete file path.
#
# Source PR + captured review body is enough context for a worker to verify
# whether the review is actionable, already fixed, or scanner noise. Treating
# these as "missing implementation context" strands historical quality-debt
# false positives such as GH#3343 before a higher-tier worker can inspect the
# source review.
#
# Arguments:
#   arg1 - issue body text
# Returns:
#   0 - body contains quality-feedback review context
#   1 - not a quality-feedback review-feedback issue body
#######################################
_escalate_body_has_review_feedback_context() {
	local issue_body="$1"

	case "$issue_body" in
	*"## Unactioned Review Feedback"*) ;;
	*) return 1 ;;
	esac

	case "$issue_body" in
	*"**Source PR**:"*"quality-feedback-helper.sh scan-merged"*) return 0 ;;
	esac

	return 1
}

#######################################
# Detect investigation-ready briefs whose exact write surface is intentionally
# unknown until the investigation runs. Require the complete evidence/plan/test
# shape plus at least one concrete file path and executable verification command;
# headings alone must not bypass the missing-context gate.
#
# Arguments:
#   arg1 - issue body text
# Returns:
#   0 - body contains bounded investigation context
#   1 - investigation context is absent or incomplete
#######################################
_escalate_body_has_investigation_context() {
	local issue_body="$1"
	local heading_pattern=""

	for heading_pattern in \
		'^#{1,6}[[:space:]]+Evidence[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Files to (inspect|review|investigate)( first)?[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Approach[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Acceptance criteria[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Verification[[:space:]]*:?[[:space:]]*$'; do
		printf '%s\n' "$issue_body" | grep -qiE "$heading_pattern" || return 1
	done

	# A bounded investigation still needs a concrete starting surface.
	printf '%s\n' "$issue_body" |
		grep -qE '[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)+\.[a-zA-Z0-9]+' || return 1
	# Verification must name something executable, not only a prose promise.
	# shellcheck disable=SC2016 # Backticks are literal Markdown delimiters in the regex.
	printf '%s\n' "$issue_body" |
		grep -qE '(^|[[:space:]`])((bash|shellcheck|pytest|python[0-9]*|node|npm|pnpm|yarn|bun|make)[[:space:]]|go[[:space:]]+test([[:space:]]|$)|cargo[[:space:]]+test([[:space:]]|$)|git[[:space:]]+diff([[:space:]]|$)|[.]/|[.][[:alnum:]_/-]+\.sh([[:space:]`]|$))' || return 1
	return 0
}

#######################################
# Body quality gate for escalate_issue_tier (GH#17561)
# Returns 0 if escalation should proceed, 1 if blocked (posts diagnostic comment).
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug
#   arg3 - failure count
#   arg4 - threshold
#   arg5 - issue body text
#######################################
_escalate_body_quality_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local threshold="$4"
	local issue_body="$5"

	# Empty body — no context to check, allow escalation
	[[ -n "$issue_body" ]] || return 0
	# Review-feedback issues carry Source PR provenance instead of target file
	# paths. Let the tier cascade continue so a stronger worker can verify the
	# source review instead of treating the issue as irreparably under-specified.
	if _escalate_body_has_review_feedback_context "$issue_body"; then
		return 0
	fi
	# Investigation briefs cannot know their final write surface yet. Accept the
	# bounded investigation contract rather than demanding fictional line ranges.
	if _escalate_body_has_investigation_context "$issue_body"; then
		return 0
	fi

	# Check for file path indicators: paths with extensions, EDIT:/NEW: prefixes,
	# backtick-quoted paths, or "Files to Modify" section headers.
	# shellcheck disable=SC2016 # pattern is literal regex; no variable expansion intended
	if echo "$issue_body" | grep -qE '(EDIT:|NEW:|`[a-zA-Z0-9_./-]+\.[a-z]+`|Files to Modify|## How|\.sh:|\.py:|\.ts:|\.js:|\.md:)'; then
		return 0
	fi

	# Body lacks implementation context — post diagnostic instead of escalating
	local diag_body="## Escalation Blocked: Missing Implementation Context

**Trigger:** ${failure_count} consecutive worker failures (threshold: ${threshold})
**Action:** Escalation **skipped** — issue body lacks file paths and implementation steps.

Workers fail when they must explore the entire codebase to find what to change. Adding explicit file paths, reference patterns, and verification commands to the issue body is more effective than escalating to a more expensive model.

**Required:** Update the issue body with one complete context shape:
- **Implementation work:** a \`## How\` section with files to modify, a reference pattern, and verification commands.
- **Investigation work:** \`## Evidence\`, \`## Files to inspect\`, \`## Approach\`, \`## Acceptance criteria\`, and \`## Verification\`, including concrete starting paths and executable checks. Exact modification paths may remain unknown until the investigation completes.

_Automated by \`escalate_issue_tier()\` body quality gate (t1900) in worker-lifecycle-common.sh_"
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$diag_body" 2>/dev/null || true
	return 1
}

#######################################
# Count issue comments containing a marker across all paginated comment pages.
#
# Root cause fixed for exampleorg/examplerepo#4007: long issue threads can push
# breaker markers onto page 2+. `gh api --paginate --jq ...` applies jq per
# page instead of across the full comment stream, so a page-local count can
# miss existing t2769 markers and re-file/noise a no_work breaker. Slurping
# all pages before jq keeps marker idempotency consistent with the stale
# activity detector's pagination fix.
#
# Args: $1=issue_number, $2=repo_slug, $3=marker substring
# Stdout: numeric count, or empty on gh/jq failure
# Returns: 0 on count success, 1 on gh/jq failure
#######################################
_count_issue_comments_containing_marker() {
	local issue_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local comments_pages=""
	local count=""

	comments_pages=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --slurp 2>/dev/null) || return 1
	count=$(printf '%s' "$comments_pages" | jq --arg marker "$marker" \
		'[.[] | .[]? | select((.body // "") | contains($marker))] | length' \
		2>/dev/null) || return 1
	printf '%s' "$count"
	return 0
}

#######################################
# t3076: file a root-cause meta-issue with forensics when the no_work
# breaker fires. Idempotent — second trip on the same original is a
# no-op (filer self-checks via marker comment). Best-effort: failures
# are swallowed; status:blocked remains the canonical block on the original.
#
# Args: $1=issue_number, $2=repo_slug, $3=failure_count, $4=reason
# Returns: 0 always
#######################################
_file_circuit_breaker_meta_no_work() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="$4"

	local filer="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/circuit-breaker-meta-filer.sh"
	[[ -x "$filer" ]] || return 0

	"$filer" file \
		--issue "$issue_number" --repo "$repo_slug" \
		--breaker no_work --failure-count "$failure_count" \
		--reason "$reason" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Post an idempotent diagnostic comment when tier escalation is skipped
# because the worker crashed with crash_type=no_work (infrastructure
# failure — FD exhaustion, plugin init crash, branch naming race, auth
# refresh race). Tier escalation is the wrong response to infra failures:
# a more expensive model cannot fix an FD leak. We keep the issue at its
# current tier, let the next retry attempt run cheaply after the infra
# issue resolves, and rely on the existing circuit breakers to apply
# machine-recoverable structural blocks if retries keep failing.
#
# Idempotent: checks for a prior comment with the marker
# <!-- no-work-escalation-skip --> and skips if present, so a cascade of
# consecutive no_work failures doesn't spam the issue with duplicates.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (for context)
#   arg4 - kill/failure reason (sanitised)
# Returns: 0 always (best-effort, never fatal)
#######################################
#######################################
# Apply the no_work lifecycle circuit breaker (t2769) when failure_count
# reaches the threshold: idempotent status:blocked state + comment with the
# backward-compatible `cost-circuit-breaker:no_work_loop` marker, then file the
# t3076 root-cause meta-issue.
#
# Args: $1=issue_number, $2=repo_slug, $3=failure_count,
#        $4=legacy-named threshold, $5=reason
# Returns: 0 always (best-effort, never fatal)
#######################################
_apply_no_work_nmr_breaker() {
	local issue_number="$1" repo_slug="$2" failure_count="$3"
	local nmr_threshold="$4" reason="$5"
	local nmr_marker='cost-circuit-breaker:no_work_loop'

	local existing_nmr=""
	existing_nmr=$(_count_issue_comments_containing_marker \
		"$issue_number" "$repo_slug" "$nmr_marker") || existing_nmr=""
	if [[ "$existing_nmr" =~ ^[1-9][0-9]*$ ]]; then
		printf '[worker-lifecycle][t2769] no_work circuit breaker already applied for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	set_issue_status "$issue_number" "$repo_slug" "$_WLC_STATUS_BLOCKED" 2>/dev/null || true

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ${nmr_marker} -->
## no_work Circuit Breaker Fired (t2769)

**Trigger:** ${failure_count} consecutive worker failure(s) classified as \`no_work\` (threshold: ${nmr_threshold}).
**Action:** Applied \`status:blocked\`. Further automated dispatch is suspended.
**Last failure reason:** ${safe_reason}

**Why this class of failure does not cascade tiers:** \`no_work\` usually means the worker crashed during runtime setup before reading any target files (FD exhaustion, plugin init failure, auth refresh race) or stale-recovery falsely concluded no progress. A more expensive model cannot fix an infrastructure problem it never reached.

**Possible causes:**
- Brief not yet merged or branch missing at dispatch time
- Auth token stale or missing
- Plugin init crash (FD exhaustion, env pollution)
- Branch naming race at dispatch time
- Stale-recovery false positive on long issue threads (check dispatch-dedup-stale comment pagination and recent-activity aggregation)

The linked root-cause meta-issue restores \`status:available\` after its fix merges. Manual recovery should requeue only after preserving any worker output.

_Per-issue no_work circuit breaker (t2769). The \`${nmr_marker}\` marker remains backward-compatible evidence for legacy NMR reconciliation._" 2>/dev/null || true

	printf '[worker-lifecycle][t2769] no_work circuit breaker fired for #%s (%s, count=%s)\n' \
		"$issue_number" "$repo_slug" "$failure_count" >&2 || true

	_file_circuit_breaker_meta_no_work "$issue_number" "$repo_slug" \
		"$failure_count" "$reason"
	return 0
}

#######################################
# Detect failures that happened before a worker launch or during launch
# preflight.
#
# These launch-control skips are not evidence that a worker reached the brief,
# so they must not participate in the t2769 per-issue no_work breaker.
# Legitimate post-launch no_work reasons (for example worker_noop_zero_output)
# still flow through the existing breaker path unchanged.
#
# Args: $1=reason
# Returns: 0 when reason is a pre-worker-launch/preflight skip, 1 otherwise.
#######################################
_worker_failure_reason_is_launch_preflight() {
	local reason="${1:-}"

	case "$reason" in
	worker_launch_rc_2 | \
	worker_worktree_live_owner | \
	worker_worktree_continuation_* | \
	worker_worktree_owner_concurrent_mutation | \
	worker_runtime_not_invoked | \
	worker_signing_unavailable | \
	worker_sensitive_temp_preflight_failed | \
	worker_ledger_ready_failed | \
	worker_claim_ready_transition_failed | \
	dispatch_aborted:worker_launch_rc_2 | \
	canary_preflight | \
	*"canary preflight failed"* | \
	*"before worktree pre-creation"* | \
	*"worktree pre-creation failed"* | \
	*"precreation failed"* | \
	*"predispatch_validator_closed"* | \
	*"eligibility_gate"* | \
	*"pre-worker-launch"* | \
	*"pre-launch"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Detect completion-path infrastructure failures where implementation may be
# checkpointed locally and the correct action is resume/completion, not an
# issue-level implementation fast-fail penalty.
# Args: $1=reason
# Returns: 0 for completion infrastructure failures, 1 otherwise.
#######################################
_worker_failure_reason_is_completion_infrastructure() {
	local reason="${1:-}"

	case "$reason" in
	github_api_timeout | command_policy_timeout | prepared_commit_push_blocked | completed_locally_remote_completion_blocked | \
		*"GitHub API timeout"* | *"github api timeout"* | \
		*"command-policy timeout"* | *"command policy timeout"* | \
		*"prepared commit"*"push"*"$_WLC_STATUS_BLOCKED"* | \
		*"completed locally"*"remote completion"*"$_WLC_STATUS_BLOCKED"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

_no_work_reason_is_prelaunch_skip() {
	local reason="${1:-}"
	_worker_failure_reason_is_launch_preflight "$reason"
	return $?
}

_log_no_work_skip_escalation() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-worker_exited_before_reading_brief}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local nmr_threshold="${NO_WORK_NMR_THRESHOLD:-3}"

	if _no_work_reason_is_prelaunch_skip "$reason"; then
		printf '[worker-lifecycle][t2769] no_work breaker skipped for pre-launch reason on #%s (%s, count=%s): %s\n' \
			"$issue_number" "$repo_slug" "$failure_count" "$reason" >&2 || true
		return 0
	fi

	# Circuit-breaker path (t2769): when failure_count >= threshold,
	# apply status:blocked + file a root-cause meta-issue.
	if [[ "$failure_count" -ge "$nmr_threshold" ]]; then
		_apply_no_work_nmr_breaker "$issue_number" "$repo_slug" \
			"$failure_count" "$nmr_threshold" "$reason"
		return 0
	fi

	# Below threshold: idempotent diagnostic comment (existing t2387 behaviour).
	local marker='<!-- no-work-escalation-skip -->'

	# Idempotency check: skip if a prior comment already carries the marker.
	# Best-effort — if gh api fails, fall through and post (better to repeat
	# once than to lose the diagnostic entirely).
	local existing=""
	existing=$(_count_issue_comments_containing_marker \
		"$issue_number" "$repo_slug" "$marker") || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		# Already posted once — nothing more to do. Still emit a one-line
		# log so operators can track the skip rate if they're tailing logs.
		printf '[worker-lifecycle][t2387] no_work skip-escalation already recorded for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")

	local comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${marker}
## Tier Escalation Skipped: Infrastructure Failure (no_work)

**Trigger:** ${failure_count} worker failure(s) classified as \`no_work\` — the worker exited during setup without reading any target files.
**Action:** Tier escalation **skipped**. The issue stays at its current tier so the next retry can succeed cheaply once the infrastructure issue resolves.
**Reason:** ${safe_reason}

**Why no cascade:** \`no_work\` means the worker never produced reliable implementation evidence — it crashed during runtime setup (FD exhaustion, plugin init failure, branch naming race, auth refresh race) or stale-recovery falsely concluded no progress. A more expensive model cannot fix an infrastructure problem it never reached. Cascading to \`tier:thinking\` would waste capacity on a problem the mapped standard or simple model can handle once the infrastructure clears.

After ${nmr_threshold} consecutive \`no_work\` failures the per-issue no_work circuit breaker (t2769) applies \`status:blocked\` and files a machine-recoverable root-cause meta-issue.

_Automated by \`escalate_issue_tier()\` no_work skip (t2387) in worker-lifecycle-common.sh_
<!-- ops:end -->"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	printf '[worker-lifecycle][t2387] no_work skip-escalation posted for #%s (%s, count=%s)\n' \
		"$issue_number" "$repo_slug" "$failure_count" >&2 || true
	return 0
}

#######################################
# Escalate issue model tier after repeated worker failures.
#
# Cascade escalation: tier:simple → tier:standard → tier:thinking.
# Crash-type-aware thresholds determine when escalation fires:
#   - "overwhelmed": model read files, attempted work, but couldn't complete
#     → escalate immediately (threshold=1). Retrying at the same tier wastes
#     tokens on the same complexity the model already failed on.
#   - "no_work": infrastructure failure (FD exhaustion, plugin init crash,
#     auth refresh race). **Short-circuits BEFORE tier cascade** (t2387) —
#     a more expensive model cannot fix infrastructure. Keeps the issue
#     at its current tier and posts a diagnostic comment via
#     _log_no_work_skip_escalation; existing circuit breakers apply structural
#     status blocks on cost/staleness thresholds if retries persist.
#   - "partial" / other: default threshold (2). Model got partway, may
#     succeed with a continuation or fresh attempt.
#
# If already at tier:thinking, no further escalation — the issue stays
# for the needs-human path.
#
# Each escalation posts a structured report to the issue so the next
# tier starts with accumulated context, not from zero.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (current fast-fail count AFTER increment)
#   arg4 - kill/failure reason (for the comment)
#   arg5 - crash type: "overwhelmed" | "no_work" | "partial" | "" (optional)
# Returns: 0 always (best-effort, never fatal)
#######################################
ESCALATION_FAILURE_THRESHOLD="${ESCALATION_FAILURE_THRESHOLD:-2}"
ESCALATION_OVERWHELMED_THRESHOLD="${ESCALATION_OVERWHELMED_THRESHOLD:-1}"
NO_WORK_NMR_THRESHOLD="${NO_WORK_NMR_THRESHOLD:-3}"
# t2820: maximum log-file age (seconds) under which a `worker_failed` event
# with no tool-call markers in the log tail will be reclassified as `no_work`.
# Workers that ran for longer are likely real coding failures (worker engaged,
# read files, attempted edits) where escalation IS appropriate. The default
# (180s) is conservative — most real coding work produces tool-call frames in
# the first minute. Override via env when investigating specific incidents.
NO_WORK_RECLASS_ELAPSED_MAX="${NO_WORK_RECLASS_ELAPSED_MAX:-180}"

#######################################
# _maybe_reclassify_worker_failed_as_no_work — Phase 5 reclassification (t2820)
#
# When `escalate_issue_tier` is called with `crash_type == ""` and a
# `worker_failed`-class reason, inspect the worker log tail to decide whether
# this is a genuine coding failure (escalate) or a late infra failure that the
# pulse currently mis-classifies (`worker_failed` is the catch-all bucket — see
# issue body for the false-merge background).
#
# Reclassification rules (in order of precedence):
#
#   1. Log tail contains canary diagnostics OR `[t2814:early_exit]` marker
#      → reclassify as `no_work` with subtype `canary_post_spawn_failure`.
#      The worker spawned but died before any real work — opus cannot help.
#
#   2. Log file age <= NO_WORK_RECLASS_ELAPSED_MAX AND log tail contains no
#      tool-use markers → reclassify as `no_work` with subtype
#      `no_tool_calls_in_log`. The worker was alive long enough to run, but
#      never reached implementation. Same opus-cannot-help reasoning.
#
#   3. Otherwise (real_coding signals, log too old, or log missing) → no
#      reclassification. Caller's existing escalation logic runs unchanged.
#
# When a rule fires, the helper invokes `_log_no_work_skip_escalation` with
# the subtype embedded in the `reason` arg so the diagnostic comment explains
# which rule fired. Returns 0 to signal "reclassified, skip cascade"; returns
# 1 to signal "fall through to normal escalation".
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - failure_count
#   $4 - original reason (e.g. worker_failed, premature_exit)
#
# Returns: 0 on reclassification (caller MUST short-circuit), 1 otherwise.
#######################################
_maybe_reclassify_worker_failed_as_no_work() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local original_reason="$4"

	# Only reclassify worker_failed-class reasons. Rate-limit and explicit
	# crash_type cases are handled elsewhere; we should not touch them.
	#
	# Reasons that map to "spawned but produced no useful output":
	#   - worker_failed             (catch-all from headless-runtime-helper)
	#   - premature_exit            (watchdog-detected early exit)
	#   - worker_noop_zero_output   (post-completion zero-output check)
	case "$original_reason" in
	worker_failed | premature_exit | worker_noop_zero_output) ;;
	*) return 1 ;;
	esac

	# Need the shared log-tail reader. If not loaded, fall through — better
	# to escalate normally than to mis-classify on missing tooling.
	if ! declare -F _read_worker_log_tail_classified >/dev/null 2>&1; then
		return 1
	fi

	# Reset caller-scope vars (the reader resets them too, but be explicit).
	_WORKER_LOG_TAIL_FILE=""
	_WORKER_LOG_TAIL_CONTENT=""
	_WORKER_LOG_TAIL_CLASS="unknown"
	_WORKER_LOG_TAIL_AGE_SECS=""

	_read_worker_log_tail_classified "$issue_number" "$repo_slug"

	# Design constraint (per issue body): if Phase 3's log-tail data is
	# absent (older dispatch records, log file rotated away), fall through
	# to existing worker_failed → escalation behaviour unchanged. No
	# regression on pre-Phase 3 records.
	[[ -n "${_WORKER_LOG_TAIL_FILE:-}" ]] || return 1
	[[ "${_WORKER_LOG_TAIL_CLASS:-unknown}" != "unknown" ]] || return 1

	local subtype=""
	case "$_WORKER_LOG_TAIL_CLASS" in
	canary_post_spawn)
		# Highest-precedence rule: explicit infra-failure markers in the
		# log tail. Fire regardless of runtime — a canary-failure tail
		# 10 minutes after spawn is still a canary failure.
		subtype="canary_post_spawn_failure"
		;;
	no_tool_calls)
		# Runtime-bounded rule: only reclassify when the log file is
		# young enough that "no tool calls" credibly means "didn't get
		# to coding". For longer runtimes, the worker may have legitimately
		# coded and only the tail visible (a 20-line tail at 30 minutes
		# of runtime can easily miss the implementation phase).
		local age="${_WORKER_LOG_TAIL_AGE_SECS:-}"
		if [[ -n "$age" && "$age" =~ ^[0-9]+$ \
			&& "$age" -le "$NO_WORK_RECLASS_ELAPSED_MAX" ]]; then
			subtype="no_tool_calls_in_log"
		fi
		;;
	real_coding)
		# Worker did real implementation work. Original escalation is
		# the right response.
		return 1
		;;
	esac

	# No subtype assigned → no reclassification (e.g. no_tool_calls but
	# log too old). Fall through to normal escalation.
	[[ -n "$subtype" ]] || return 1

	# Compose the reason that will appear in the skip-escalation comment.
	# Prefix with the subtype so operators can grep for the specific rule
	# that fired (auditable per the issue's verification example).
	local reclass_reason="no_work:${subtype} (reclassified from ${original_reason} via log-tail at ${_WORKER_LOG_TAIL_FILE})"

	# Single-line audit log for log tailers — keeps the reclassification
	# observable even when the GH comment fails to post.
	printf '[worker-lifecycle][t2820] reclassified worker_failed→no_work for #%s (%s) subtype=%s age=%ss class=%s\n' \
		"$issue_number" "$repo_slug" "$subtype" \
		"${_WORKER_LOG_TAIL_AGE_SECS:-?}" "${_WORKER_LOG_TAIL_CLASS}" >&2 || true

	_log_no_work_skip_escalation "$issue_number" "$repo_slug" \
		"$failure_count" "$reclass_reason"
	return 0
}

escalate_issue_tier() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-repeated_failure}"
	local crash_type="${5:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	# Validate failure_count is numeric (CodeRabbit review)
	[[ "$failure_count" =~ ^[0-9]+$ ]] || return 0

	# t2820 (Phase 5): when crash_type is empty AND reason looks like a
	# generic worker-failure bucket, try to reclassify as no_work using the
	# Phase 3 log-tail signal. The reclassification rule fires only when the
	# log tail provides positive evidence of an infra-class failure (canary
	# diagnostics, t2814:early_exit marker) OR no implementation evidence
	# combined with short runtime. Otherwise the reason is treated as a real
	# coding failure and falls through to the normal cascade.
	#
	# This must run BEFORE the existing no_work short-circuit so that the
	# reclassification path can call the skip-escalation helper with a
	# descriptive subtype-aware reason instead of the original generic
	# bucket name. (See _maybe_reclassify_worker_failed_as_no_work above
	# for the full rule list and reference-pattern fixture coverage.)
	if [[ -z "$crash_type" ]]; then
		if _maybe_reclassify_worker_failed_as_no_work \
			"$issue_number" "$repo_slug" "$failure_count" "$reason"; then
			return 0
		fi
	fi

	# Select threshold based on crash type:
	# - "overwhelmed" = model attempted real work but couldn't complete.
	#   Immediate escalation (threshold=1) because retrying at the same
	#   tier reproduces the same failure mode.
	# - "no_work" / other = transient/infra failures. Use default (2).
	local threshold="$ESCALATION_FAILURE_THRESHOLD"
	if [[ "$crash_type" == "overwhelmed" ]]; then
		threshold="$ESCALATION_OVERWHELMED_THRESHOLD"
	fi
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$threshold" -ge 1 ]] || threshold=2

	# t2387: no_work crashes are infrastructure failures (FD exhaustion,
	# plugin init crash, branch naming race, auth refresh race — see t2116
	# session memory). Tier escalation is the wrong response: a more
	# expensive model cannot fix an FD leak or an auth race. Skip the
	# cascade entirely and keep the issue at its current tier so the
	# next retry can succeed cheaply once the infra issue resolves. If
	# retries keep failing, the existing circuit-breaker helpers
	# (cost-circuit-breaker, dispatch-dedup-stale, stale-recovery) apply
	# NMR on their own thresholds using markers that t2386
	# _nmr_application_is_circuit_breaker_trip recognises, so auto-approval
	# preserves the NMR correctly. This early return also subsumes the
	# t2119 body-quality-gate skip — the later gate call becomes
	# unreachable on no_work crashes, so the original inline != guard is
	# no longer needed there.
	if [[ "$crash_type" == "no_work" ]]; then
		_log_no_work_skip_escalation "$issue_number" "$repo_slug" \
			"$failure_count" "$reason"
		return 0
	fi

	# Only escalate at the threshold boundary (not on every subsequent failure)
	if [[ "$failure_count" -ne "$threshold" ]]; then
		return 0
	fi

	# Determine current tier and next tier in cascade
	local current_labels
	current_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""

	local current_tier="standard"
	local next_tier=""
	local next_label=""
	local remove_label=""

	# Thinking is the terminal workload tier. Runtime routing selects the best
	# currently available model and provider reasoning level for that tier.
	case ",$current_labels," in
	*,tier:thinking,*)
		return 0
		;;
	*,tier:standard,*)
		current_tier="standard"
		next_tier="thinking"
		next_label="tier:thinking"
		remove_label="tier:standard"
		;;
	*,tier:simple,*)
		current_tier="simple"
		next_tier="standard"
		next_label="tier:standard"
		remove_label="tier:simple"
		;;
	*)
		# No tier label — treat as standard, escalate to thinking
		current_tier="standard"
		next_tier="thinking"
		next_label="tier:thinking"
		remove_label=""
		;;
	esac

	# Body quality gate (t1900): check if the issue body has implementation
	# context before escalating. If the body lacks file paths, the root cause
	# is a vague issue — not model capability. Escalating wastes a more
	# expensive model on the same exploration problem.
	#
	# Note: t2119 originally added an inline `crash_type != "no_work"` guard
	# here so no_work crashes would bypass the body-gate. That guard was
	# removed by t2387 when the entire function gained an earlier
	# `crash_type == "no_work"` short-circuit that returns before reaching
	# this point — so only overwhelmed / partial / unclassified reach here,
	# and every path through the function that gets here wants the gate
	# evaluated.
	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	_escalate_body_quality_gate "$issue_number" "$repo_slug" \
		"$failure_count" "$threshold" "$issue_body" || return 0

	# Create next tier label (creates label if needed)
	local label_desc=""
	local label_color=""
	case "$next_label" in
	tier:thinking)
		label_desc="Route at the thinking workload tier"
		label_color="7057FF"
		;;
	tier:standard)
		label_desc="Route at the standard workload tier"
		label_color="0E8A16"
		;;
	esac

	gh label create "$next_label" \
		--repo "$repo_slug" \
		--description "$label_desc" \
		--color "$label_color" \
		--force 2>/dev/null || true

	# Swap tier labels
	local edit_args="--add-label $next_label"
	if [[ -n "$remove_label" ]]; then
		edit_args="$edit_args --remove-label $remove_label"
	fi
	# shellcheck disable=SC2086
	gh issue edit "$issue_number" --repo "$repo_slug" \
		$edit_args 2>/dev/null || {
		return 0
	}

	# Post escalation comment (sanitize reason to prevent markdown injection)
	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")
	local crash_type_label=""
	case "$crash_type" in
	overwhelmed)
		crash_type_label="**Crash type:** \`overwhelmed\` — model read target files and attempted implementation but could not produce commits. Immediate escalation triggered (threshold=1)."
		;;
	partial)
		crash_type_label="**Crash type:** \`partial\` — worker produced commits but could not complete the PR lifecycle."
		;;
	esac
	# Note: t2387 removed the `no_work` case here because that crash_type
	# short-circuits at the top of escalate_issue_tier and never reaches
	# the comment-posting path. Infrastructure failures get their own
	# diagnostic comment via _log_no_work_skip_escalation instead.
	local comment_body="## Cascade Tier Escalation: tier:${current_tier} → tier:${next_tier}

**Trigger:** ${failure_count} consecutive worker failures at \`tier:${current_tier}\` (threshold: ${threshold})
**Action:** Added \`${next_label}\` label — next dispatch will use ${next_tier}-tier model.
**Reason:** ${safe_reason}
${crash_type_label:+${crash_type_label}
}
Previous attempts at \`tier:${current_tier}\` failed to produce a PR. Escalating to a more capable model with accumulated context from prior attempts.

The next worker should review prior attempt comments on this issue for context on what was tried and where it got stuck.

_Automated by \`escalate_issue_tier()\` cascade dispatch in worker-lifecycle-common.sh_"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	# Record escalation in tier telemetry
	local ledger_helper="${HOME}/.aidevops/agents/scripts/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" record-outcome \
			--issue "$issue_number" --repo "$repo_slug" \
			--session-key "issue-${issue_number}" \
			--outcome "escalated" --tier "$current_tier" \
			--reason "$safe_reason" 2>/dev/null || true
	fi

	return 0
}

#######################################
# Emit one stdout line where an early-closing consumer is expected.
# Arguments:
#   value - line content to emit
# Returns: always 0 for EPIPE-safe data-return helpers
#######################################
_emit_stdout_line_safely() {
	local value="$1"
	printf '%s\n' "$value" 2>/dev/null || return 0
	return 0
}

#######################################
# Count active worker processes
# Returns: count via stdout
#######################################
count_active_workers() {
	local count
	count=$(list_active_worker_processes | wc -l | tr -d ' ') || count=0
	_emit_stdout_line_safely "$count"
	return 0
}

#######################################
# Count interactive AI sessions (t1398)
#
# Counts opencode/claude processes with a real TTY (interactive sessions).
# Shared between pulse-wrapper.sh and stats-functions.sh.
#
# Arguments: none
# Returns: session count via stdout
#######################################
check_session_count() {
	local interactive_count=0

	# Count opencode processes with a real TTY (interactive sessions).
	# Filter both '?' (Linux) and '??' (macOS) headless TTY entries.
	# t2190: ps axwwo so the awk regex isn't defeated by Linux procps truncation.
	interactive_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || interactive_count=0

	_emit_stdout_line_safely "$interactive_count"
	return 0
}

# Resolve this library's own directory instead of trusting a caller's SCRIPT_DIR.
_worker_lifecycle_common_path="${BASH_SOURCE[0]%/*}"
[[ "$_worker_lifecycle_common_path" == "${BASH_SOURCE[0]}" ]] && _worker_lifecycle_common_path="."
_worker_lifecycle_common_dir="$(cd "$_worker_lifecycle_common_path" && pwd)" || return 1
unset _worker_lifecycle_common_path

# shellcheck source=./worker-lifecycle-verbose.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime from this file's directory
source "${_worker_lifecycle_common_dir}/worker-lifecycle-verbose.sh"
unset _worker_lifecycle_common_dir
