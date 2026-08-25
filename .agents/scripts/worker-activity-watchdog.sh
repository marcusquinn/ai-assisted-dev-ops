#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# worker-activity-watchdog.sh — Standalone activity watchdog for headless workers (GH#17648)
#
# Monitors a worker's output file for growth. Treats timing thresholds as
# recovery backstops: kills only when there is no evidence of live work, an
# explicit provider failure is visible, or a confirmed stall has crossed the
# hard elapsed threshold.
#
# This script runs as an INDEPENDENT process (launched via nohup) so it
# survives the worker subshell's lifecycle changes. The previous design
# used a backgrounded bash function inside the subshell — that watchdog
# died silently when nohup changed the process group context.
#
# Two-phase monitoring:
#   Phase 1 (fast, 0-30s): Any output at all. Zero bytes = dead runtime.
#   Phase 2 (continuous):   File growth. No growth for stall_timeout triggers
#                            classification (provider failure, CI wait,
#                            network-active, CPU-active, or no-progress) before
#                            any kill.
#
# On stall:
#   - Writes WATCHDOG_KILL marker to output file
#   - Creates .watchdog_killed sentinel (parent reads this)
#   - Kills worker process tree (TERM, then KILL after 10s)
#   - Writes exit code 124 to exit_code_file
#   - Posts CLAIM_RELEASED on GitHub issue (if session_key provided)
#
# On normal worker exit:
#   - Detects worker PID gone, exits cleanly
#
# Args:
#   --output-file PATH        Worker output file to monitor
#   --worker-pid PID          Worker PID to kill on stall
#   --exit-code-file PATH     File to write exit code 124 into
#   --session-key KEY         Session key for claim release (optional)
#   --repo-slug OWNER/REPO    GitHub repo slug for claim release (optional)
#   --stall-timeout SECS      Seconds without growth before recovery action
#                             (default: 600). CPU-active and CI-wait states
#                             defer the kill until the hard backstop.
#   --phase1-timeout SECS     Seconds for initial output (default: 30)
#   --poll-interval SECS      Seconds between checks (default: 10)
#   --hard-kill-seconds SECS  Total elapsed seconds before a confirmed output
#                             stall escalates to forced hard-kill (default: 1500
#                             = 25 min). Output growth resets stall detection and
#                             is never killed solely for crossing this threshold.
#                             The watchdog writes the .watchdog_stall_killed
#                             sentinel (in addition to .watchdog_killed) so the
#                             helper can classify the result as exit code 79
#                             (watchdog_stall_killed) instead of 78
#                             (watchdog_stall_continue) — no continuation, slot
#                             freed for re-dispatch. Override env var:
#                             WORKER_STALL_HARD_KILL_SECONDS. Set to 0 to
#                             disable the hard-kill branch (legacy behaviour).
#                             Issue #21231 / supersedes #21201.
#
# Usage:
#   nohup worker-activity-watchdog.sh \
#     --output-file /tmp/worker.out \
#     --worker-pid 12345 \
#     --exit-code-file /tmp/worker.exit \
#     --session-key "issue-marcusquinn-aidevops-17648" \
#     --repo-slug "marcusquinn/aidevops" \
#     </dev/null >/dev/null 2>&1 &

set -euo pipefail

# t3059 / GH#21787: Source shared lifecycle helpers for _get_descendant_pids.
# Avoids inline one-level `pgrep -P` BFS that previously lived in
# _watchdog_tree_cpu and undercounted CPU when the worker process tree
# was deeper than one level (e.g., bash → opencode → node → LSP).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"
if [[ -r "${SCRIPT_DIR}/shared-repo-state-guard.sh" ]]; then
	# shellcheck source=shared-repo-state-guard.sh
	source "${SCRIPT_DIR}/shared-repo-state-guard.sh"
fi

#######################################
# Configuration (from args, with defaults)
#######################################
OUTPUT_FILE=""
WORKER_PID=""
EXIT_CODE_FILE=""
SESSION_KEY=""
REPO_SLUG=""
WORKTREE_PATH=""
STALL_TIMEOUT="${WORKER_STALL_TIMEOUT:-600}"
PHASE1_TIMEOUT=30
POLL_INTERVAL=10
# t2956 / Issue #21231: Hard-kill threshold (default 1500s = 25 min).
# Env var WORKER_STALL_HARD_KILL_SECONDS overrides; --hard-kill-seconds CLI
# flag overrides the env var. Set to 0 to disable hard-kill (stall continues
# indefinitely up to the runtime's wall-clock cap — legacy behaviour).
HARD_KILL_SECONDS="${WORKER_STALL_HARD_KILL_SECONDS:-1500}"
# t3056 / GH#21781: CPU threshold below which a stalled worker is considered
# truly stuck (vs just not writing output). Process tree CPU >= this value
# defers the stall kill — the worker is alive but doing non-output work
# (API roundtrip, shellcheck, file read). Default 2% matches PULSE_IDLE_CPU_THRESHOLD.
STALL_CPU_THRESHOLD="${WORKER_STALL_CPU_THRESHOLD:-2}"
# t3056: Lifecycle log for structured kill-reason telemetry. Aggregatable
# across all workers. Default: pulse-dispatch.log (same file the pulse reads).
LIFECYCLE_LOG="${WORKER_LIFECYCLE_LOG:-${HOME}/.aidevops/logs/pulse-dispatch.log}"

#######################################
# Parse arguments
#######################################
_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--output-file)
			OUTPUT_FILE="$2"
			shift 2
			;;
		--worker-pid)
			WORKER_PID="$2"
			shift 2
			;;
		--exit-code-file)
			EXIT_CODE_FILE="$2"
			shift 2
			;;
		--session-key)
			SESSION_KEY="$2"
			shift 2
			;;
		--repo-slug)
			REPO_SLUG="$2"
			shift 2
			;;
		--worktree-path)
			WORKTREE_PATH="$2"
			shift 2
			;;
		--stall-timeout)
			STALL_TIMEOUT="$2"
			shift 2
			;;
		--phase1-timeout)
			PHASE1_TIMEOUT="$2"
			shift 2
			;;
		--poll-interval)
			POLL_INTERVAL="$2"
			shift 2
			;;
		--hard-kill-seconds)
			# t2956: assign via `local` so the bare-positional ratchet
			# (linters-local.sh::_ratchet_count_bare_positional) excludes
			# this line. The other case branches predate the ratchet and
			# remain in the pre-existing baseline.
			local _hard_kill_arg="$2"
			HARD_KILL_SECONDS="$_hard_kill_arg"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			return 1
			;;
		esac
	done

	# Validate required args
	if [[ -z "$OUTPUT_FILE" ]]; then
		echo "Error: --output-file is required" >&2
		return 1
	fi
	if [[ -z "$WORKER_PID" ]]; then
		echo "Error: --worker-pid is required" >&2
		return 1
	fi
	if [[ -z "$EXIT_CODE_FILE" ]]; then
		echo "Error: --exit-code-file is required" >&2
		return 1
	fi

	# Validate numeric args
	[[ "$STALL_TIMEOUT" =~ ^[0-9]+$ ]] || STALL_TIMEOUT=300
	[[ "$PHASE1_TIMEOUT" =~ ^[0-9]+$ ]] || PHASE1_TIMEOUT=30
	[[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || POLL_INTERVAL=10
	# t2956: HARD_KILL_SECONDS=0 disables the hard-kill branch (allowed).
	[[ "$HARD_KILL_SECONDS" =~ ^[0-9]+$ ]] || HARD_KILL_SECONDS=1500
	[[ "$WORKER_PID" =~ ^[0-9]+$ ]] || {
		echo "Error: --worker-pid must be numeric" >&2
		return 1
	}

	return 0
}

#######################################
# Check if the worker process is still alive
# Returns: 0 if alive, 1 if dead
#######################################
_worker_alive() {
	kill -0 "$WORKER_PID" 2>/dev/null
}

#######################################
# Parse a 'ps -o time=' cumulative CPU time string to integer seconds.
# Handles the two platform formats:
#   macOS BSD ps:   HH:MM:SS.ss  (decimal fraction after seconds)
#   Linux procps:   HH:MM:SS  or  DD-HH:MM:SS  (day prefix)
#
# Arguments:
#   $1 - time string from ps -o time=
# Output: integer seconds via stdout
#######################################
_parse_ps_cpu_time() {
	local t="$1"
	# Strip decimal fraction (.ss) — macOS BSD ps only
	t="${t%%.*}"
	# Strip leading DD- day prefix — Linux procps extended format
	local days=0
	if [[ "$t" == *-* ]]; then
		days="${t%%-*}"
		t="${t#*-}"
	fi
	# Split HH:MM:SS without relying on IFS changes
	local hours minutes seconds
	hours="${t%%:*}"
	t="${t#*:}"
	minutes="${t%%:*}"
	seconds="${t#*:}"
	[[ "$days"    =~ ^[0-9]+$ ]] || days=0
	[[ "$hours"   =~ ^[0-9]+$ ]] || hours=0
	[[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0
	echo $(( days * 86400 + hours * 3600 + minutes * 60 + seconds ))
	return 0
}

#######################################
# Get recent interval CPU usage for the worker's process tree (t3057 / GH#21785)
#
# Measures CPU consumed over a ~5-second window by sampling cumulative CPU
# time (ps -o time=) at T=0 and T=5, then computing the delta. This gives
# RECENT activity, not a lifetime average.
#
# Why NOT ps -o %cpu= (original t3056 / GH#21781 approach):
#   ps %cpu = total_cpu_time / total_elapsed_lifetime — a LIFETIME AVERAGE.
#   A worker hot for 10 min then frozen at 0% still reports ~30% lifetime CPU,
#   defeating the stall-defer check. The delta approach measures only the last
#   ~5 seconds, correctly detecting frozen workers regardless of history.
#
# Cross-platform: ps -o time= emits HH:MM:SS.ss on macOS BSD ps and
# HH:MM:SS or DD-HH:MM:SS on Linux procps. _parse_ps_cpu_time handles both.
#
# Arguments:
#   $1 - root PID to check
# Output: integer CPU percentage (recent ~5s interval, summed across tree)
#######################################
_watchdog_tree_cpu() {
	local root_pid="$1"
	[[ "$root_pid" =~ ^[0-9]+$ ]] || {
		echo "0"
		return 0
	}
	local sample_interval=5

	# t3059: Collect root + ALL descendants via BFS (not just direct children).
	# The previous one-level `pgrep -P` undercounted recent CPU on deeper
	# chains (bash → opencode → node → LSP). _get_descendant_pids walks the
	# full tree using the same primitive _get_process_tree_cpu uses.
	local pid_list=("$root_pid")
	local pid
	while IFS= read -r pid; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		pid_list+=("$pid")
	done < <(_get_descendant_pids "$root_pid")

	# Sample 1: record cumulative CPU seconds per PID into parallel arrays
	local t0_pids=() t0_secs_arr=()
	local t0_str t0_val
	for pid in "${pid_list[@]}"; do
		t0_str=$(ps -p "$pid" -o time= 2>/dev/null | tr -d ' ') || continue
		[[ -n "$t0_str" ]] || continue
		t0_val=$(_parse_ps_cpu_time "$t0_str")
		t0_pids+=("$pid")
		t0_secs_arr+=("$t0_val")
	done

	sleep "$sample_interval"

	# Sample 2: compute per-PID delta and accumulate
	local total_delta=0
	local idx=0
	local t5_str t5_val delta entry_pid entry_t0
	while [[ "$idx" -lt "${#t0_pids[@]}" ]]; do
		entry_pid="${t0_pids[$idx]}"
		entry_t0="${t0_secs_arr[$idx]}"
		idx=$(( idx + 1 ))
		t5_str=$(ps -p "$entry_pid" -o time= 2>/dev/null | tr -d ' ') || continue
		[[ -n "$t5_str" ]] || continue
		t5_val=$(_parse_ps_cpu_time "$t5_str")
		delta=$(( t5_val - entry_t0 ))
		[[ "$delta" -lt 0 ]] && delta=0
		total_delta=$(( total_delta + delta ))
	done

	# cpu_seconds_in_window / window_duration * 100 = recent CPU percentage
	echo $(( total_delta * 100 / sample_interval ))
	return 0
}

#######################################
# Return whether lsof sees an established HTTPS/API socket for the process tree.
#
# Fail-closed: if lsof is missing, lacks visibility, or returns no matching
# outbound remote port, this function returns 1 so the watchdog falls through to
# the CPU/no-progress logic. Matching only established TCP sockets whose remote
# endpoint is a common HTTPS/API port limits false positives from listeners or
# unrelated local sockets; the hard-kill threshold remains the absolute cap.
#
# Arguments:
#   $@ - PID list to inspect
# Returns: 0 when active network evidence exists, 1 otherwise
#######################################
_watchdog_lsof_network_active() {
	local pid_list=("$@")
	command -v lsof >/dev/null 2>&1 || return 1

	local pid="" pid_csv=""
	for pid in "${pid_list[@]}"; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		pid_csv="${pid_csv:+${pid_csv},}${pid}"
	done
	[[ -n "$pid_csv" ]] || return 1

	local lsof_output=""
	lsof_output=$(lsof -nP -a -p "$pid_csv" -iTCP -sTCP:ESTABLISHED 2>/dev/null || true)
	[[ -n "$lsof_output" ]] || return 1

	if printf '%s\n' "$lsof_output" | grep -Eq -- '->[^[:space:]]+:(443|8443)([[:space:]]|$)'; then
		return 0
	fi
	return 1
}

#######################################
# Return whether ss sees an established HTTPS/API socket for the process tree.
#
# Linux fallback for environments without lsof. `ss -p` may hide process
# metadata on restricted systems; that is treated as no evidence (fail-closed),
# not as a reason to keep a quiet worker alive indefinitely.
#
# Arguments:
#   $@ - PID list to inspect
# Returns: 0 when active network evidence exists, 1 otherwise
#######################################
_watchdog_ss_network_active() {
	local pid_list=("$@")
	command -v ss >/dev/null 2>&1 || return 1

	local ss_output=""
	ss_output=$(ss -Htanp state established 2>/dev/null || true)
	[[ -n "$ss_output" ]] || return 1

	local pid=""
	for pid in "${pid_list[@]}"; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		if printf '%s\n' "$ss_output" | grep -Eq -- "[[:space:]][^[:space:]]+:(443|8443)([[:space:]]|$).*pid=${pid},"; then
			return 0
		fi
	done
	return 1
}

#######################################
# Return whether the worker process tree has active HTTPS/API network evidence.
#
# This is deliberately semantic liveness, not a stderr heartbeat: it never writes
# to the monitored output file, it only defers no-output kills when a real
# process-tree socket is established, and the cumulative hard-kill backstop still
# frees slots for runaway/dead processes.
#
# Arguments:
#   $1 - root PID to inspect
# Returns: 0 when active network evidence exists, 1 otherwise
#######################################
_watchdog_tree_network_active() {
	local root_pid="${1:-}"
	[[ "$root_pid" =~ ^[0-9]+$ ]] || return 1

	local pid_list=("$root_pid")
	local pid=""
	while IFS= read -r pid; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		pid_list+=("$pid")
	done < <(_get_descendant_pids "$root_pid")

	if _watchdog_lsof_network_active "${pid_list[@]}"; then
		return 0
	fi
	if _watchdog_ss_network_active "${pid_list[@]}"; then
		return 0
	fi
	return 1
}

#######################################
# Get current size of the output file in bytes
# Output: size in bytes (0 if file doesn't exist)
#######################################
_get_output_size() {
	local size=0
	if [[ -f "$OUTPUT_FILE" ]]; then
		size=$(wc -c <"$OUTPUT_FILE" 2>/dev/null || echo "0")
		# wc -c may include leading spaces on some platforms
		size="${size##* }"
	fi
	[[ "$size" =~ ^[0-9]+$ ]] || size=0
	echo "$size"
	return 0
}

#######################################
# Return whether the output file contains a known rate-limit/provider-failure marker.
# Returns: 0 if a marker is present, 1 otherwise.
#######################################
_output_has_provider_rate_limit() {
	[[ -f "$OUTPUT_FILE" ]] || return 1
	grep -Eqi 'rate[ -]?limit|too many requests|http[[:space:]]*429|status[=: ][[:space:]]*429|quota exceeded|overloaded_error|provider.*(failed|unavailable)' "$OUTPUT_FILE" 2>/dev/null
}

#######################################
# Return whether the output file shows the worker is intentionally waiting on CI.
# Returns: 0 if a CI-wait marker is present, 1 otherwise.
#######################################
_output_has_ci_wait() {
	[[ -f "$OUTPUT_FILE" ]] || return 1
	grep -Eqi 'gh pr checks|review-bot-gate|pre-merge-gate|CI check|checks? (are )?(still )?(running|pending)|waiting (for|on) (CI|checks|review|merge)|merge (is )?(slow|pending)' "$OUTPUT_FILE" 2>/dev/null
}

#######################################
# Push any local-only WIP commits to origin before killing the worker.
# Best-effort, fail-open — never blocks the kill sequence.
#
# t2923: Ensures commits made before the stall are reachable on origin
# so the next worker dispatch can continue from the branch instead of
# rewriting the same code from scratch.
#
# Globals consumed:
#   WORKTREE_PATH        — set via --worktree-path arg
#   WORKER_NO_EXIT_PUSH  — escape hatch: set to "1" to disable push
#######################################
_push_wip_before_kill() {
	# Escape hatch
	[[ "${WORKER_NO_EXIT_PUSH:-0}" == "1" ]] && return 0

	local work_dir="$WORKTREE_PATH"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	# Get branch name — skip if detached HEAD or default branch
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	case "$branch_name" in
	HEAD | main | master | "")
		return 0
		;;
	esac

	# Count commits ahead of origin/main (or origin/master)
	local ahead_count=0
	ahead_count=$(git -C "$work_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || true)
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	if [[ "$ahead_count" -eq 0 ]]; then
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || true)
		[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	fi
	if [[ "$ahead_count" -eq 0 ]]; then
		return 0
	fi

	# Push best-effort — never block the kill sequence on push failure
	printf '[WATCHDOG_WIP_PUSH] timestamp=%s branch=%s ahead=%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch_name" "$ahead_count" \
		>>"$OUTPUT_FILE" 2>/dev/null || true
	git -C "$work_dir" push -u origin "$branch_name" 2>/dev/null || true
	printf '[WATCHDOG_WIP_PUSHED] branch=%s ahead=%s\n' \
		"$branch_name" "$ahead_count" \
		>>"$OUTPUT_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Kill the worker process tree and write markers
#
# Args:
#   $1 - reason string (logged in output file)
#   $2 - kill kind: "stall_killed" for hard-kill (writes additional
#        .watchdog_stall_killed sentinel), anything else (or empty) for the
#        legacy passive watchdog kill that classifies as 78
#        (watchdog_stall_continue) downstream. (t2956 / Issue #21231)
#######################################
_kill_worker() {
	local reason="$1"
	local kill_kind="${2:-}"

	# t3056 / GH#21781: Classify the kill reason for structured telemetry.
	# Maps the human-readable reason string to a machine-readable class.
	local reason_class="unknown"
	case "$reason" in
	phase1:*) reason_class="phase1_zero_output" ;;
	hard_kill:*) reason_class="hard_kill_stall" ;;
	provider_rate_limit:*) reason_class="provider_rate_limit" ;;
	stall:*) reason_class="no_output_stall" ;;
	*) reason_class="other" ;;
	esac

	# t3056: Emit structured lifecycle line for kill-reason telemetry.
	# Format matches the t3056 spec so aggregation scripts can classify kills.
	local _trigger_age=0
	local lifecycle_event=""
	_trigger_age=$(( $(date +%s) - _WATCHDOG_START_EPOCH ))
	printf -v lifecycle_event '[lifecycle] worker_killed pid=%s reason=%s trigger_age=%ss session=%s ts=%s' \
		"$WORKER_PID" "$reason_class" "$_trigger_age" "${SESSION_KEY:-none}" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	worker_attempt_observability_enrich lifecycle_event "$lifecycle_event"
	printf '%s\n' "$lifecycle_event" \
		>>"$LIFECYCLE_LOG" 2>/dev/null || true

	# t2923: Push WIP commits before killing so the work is reachable on origin.
	# Must happen before SIGTERM so git operations complete cleanly.
	_push_wip_before_kill

	# Write the .watchdog_killed sentinel BEFORE killing. The dying
	# subshell may overwrite exit_code_file with its own exit code
	# (race condition). The sentinel is authoritative.
	touch "${EXIT_CODE_FILE}.watchdog_killed"
	printf '%s\n' "no_output_stall" >"${EXIT_CODE_FILE}.kill_reason" 2>/dev/null || true

	# t2956 / Issue #21231: Hard-kill sentinel — distinguishes proactive
	# elapsed-time kills from passive no-output stall kills. The helper
	# (`headless-runtime-helper.sh::_handle_run_result`) reads this sentinel
	# and returns exit 79 (watchdog_stall_killed) instead of 78
	# (watchdog_stall_continue), short-circuiting the per-attempt
	# continuation loop and freeing the slot for re-dispatch. Without this
	# sentinel, exit 78 still fires (legacy continuation behaviour).
	if [[ "$kill_kind" == "stall_killed" ]]; then
		touch "${EXIT_CODE_FILE}.watchdog_stall_killed"
		printf '%s\n' "hard_kill_stall" >"${EXIT_CODE_FILE}.kill_reason" 2>/dev/null || true
	fi

	# Kill child processes first (pipeline members: opencode, tee),
	# then the subshell itself. pkill -P walks the process tree by PPID.
	# GH#20681: SIGTERM → 10s grace → SIGKILL (raised from 2s to give the
	# runtime a chance to flush buffers and release locks cleanly).
	pkill -P "$WORKER_PID" 2>/dev/null || true
	kill "$WORKER_PID" 2>/dev/null || true
	sleep 10
	# Force kill if still alive
	pkill -9 -P "$WORKER_PID" 2>/dev/null || true
	kill -9 "$WORKER_PID" 2>/dev/null || true

	# Write exit code 124 (timeout convention)
	printf '124' >"$EXIT_CODE_FILE"

	# Write WATCHDOG_KILL marker to output file
	printf '\n[WATCHDOG_KILL] timestamp=%s worker_pid=%s reason="%s"\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKER_PID" "$reason" \
		>>"$OUTPUT_FILE" 2>/dev/null || true

	# Release the dispatch claim so the issue is immediately available
	# for re-dispatch instead of waiting for the 30-min TTL.
	_release_claim "$reason"

	return 0
}

#######################################
# Release dispatch claim on the GitHub issue
#
# Posts a CLAIM_RELEASED comment so the pulse knows the issue
# is available for re-dispatch.
#
# Args:
#   $1 - reason string
#######################################
_release_claim() {
	local reason="$1"

	if [[ -z "$SESSION_KEY" ]]; then
		return 0
	fi

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$SESSION_KEY" | grep -oE '[0-9]+$' || true)

	# Use provided repo slug, or fall back to DISPATCH_REPO_SLUG env
	local repo_slug="${REPO_SLUG:-${DISPATCH_REPO_SLUG:-}}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi
	if declare -F aidevops_can_manage_repo_issue_state >/dev/null 2>&1; then
		if ! aidevops_can_manage_repo_issue_state "$repo_slug"; then
			return 0
		fi
	fi

	local comment_body
	comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=watchdog_kill:${reason} runner=$(whoami) ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
<!-- ops:end -->"

	# Best-effort — don't fail the watchdog if gh is unavailable
	if command -v gh >/dev/null 2>&1; then
		gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$comment_body" \
			>/dev/null 2>&1 || true
	fi

	return 0
}

#######################################
# Main monitoring loop
#
# Phase 1: Wait for any output (dead runtime detection)
# Phase 2: Monitor continuous growth (stall detection)
#
# t2956 / Issue #21231: Total elapsed time is also tracked while output is
# stalled. When HARD_KILL_SECONDS is non-zero, a confirmed stall that has
# crossed that threshold escalates to a hard-kill that emits the
# `.watchdog_stall_killed` sentinel — telling the helper to classify as exit 79
# (watchdog_stall_killed) instead of 78 (watchdog_stall_continue). Output-active
# workers are not stalls and must not be killed solely for reaching wall time.
#######################################
_monitor_init_state() {
	_MONITOR_PHASE1_PASSED=0
	_MONITOR_PHASE1_ELAPSED=0
	_MONITOR_LAST_SIZE=0
	_MONITOR_STALL_SECONDS=0
	_MONITOR_DEFERRED_STALL_SECONDS=0
	_MONITOR_START_EPOCH=$(date +%s)
	_WATCHDOG_START_EPOCH="$_MONITOR_START_EPOCH"
	return 0
}

#######################################
# Handle phase 1 initial-output detection.
#
# Arguments:
#   $1 - current output file size in bytes
# Returns:
#   0 when phase 1 handled this loop and caller should continue
#   1 when phase 1 has already passed and caller should run phase 2
#######################################
_monitor_handle_phase1() {
	local current_size="$1"
	if [[ "$_MONITOR_PHASE1_PASSED" -ne 0 ]]; then
		return 1
	fi

	if [[ "$current_size" -gt 0 ]]; then
		_MONITOR_PHASE1_PASSED=1
		_MONITOR_LAST_SIZE="$current_size"
		_MONITOR_STALL_SECONDS=0
	else
		_MONITOR_PHASE1_ELAPSED=$((_MONITOR_PHASE1_ELAPSED + POLL_INTERVAL))
		if [[ "$_MONITOR_PHASE1_ELAPSED" -ge "$PHASE1_TIMEOUT" ]]; then
			_kill_worker "phase1: zero output in ${PHASE1_TIMEOUT}s — runtime failed to start"
			return 0
		fi
	fi

	sleep "$POLL_INTERVAL"
	return 0
}

#######################################
# Update phase 2 output-growth counters.
#
# Arguments:
#   $1 - current output file size in bytes
#######################################
_monitor_track_output_growth() {
	local current_size="$1"
	if [[ "$current_size" -gt "$_MONITOR_LAST_SIZE" ]]; then
		# File is growing — worker is output-active.
		_MONITOR_LAST_SIZE="$current_size"
		_MONITOR_STALL_SECONDS=0
	else
		_MONITOR_STALL_SECONDS=$((_MONITOR_STALL_SECONDS + POLL_INTERVAL))
	fi
	return 0
}

#######################################
# Log and defer a confirmed stall for a live-work reason.
#
# Arguments:
#   $1 - reason token
#   $2 - formatted detail segment for the lifecycle line
#######################################
_monitor_defer_stall() {
	local reason="$1"
	local detail="$2"
	local lifecycle_event=""
	# Legacy variable names for structural regression tests:
	# deferred_stall_seconds=$((deferred_stall_seconds + stall_seconds))
	# Expected labels: reason=ci_wait reason=network_active reason=cpu_active.
	_MONITOR_DEFERRED_STALL_SECONDS=$((_MONITOR_DEFERRED_STALL_SECONDS + _MONITOR_STALL_SECONDS))
	printf -v lifecycle_event '[lifecycle] worker_stall_deferred pid=%s reason=%s %sstall_seconds=%ss deferred_total=%ss ts=%s' \
		"$WORKER_PID" "$reason" "$detail" "$_MONITOR_STALL_SECONDS" \
		"$_MONITOR_DEFERRED_STALL_SECONDS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	worker_attempt_observability_enrich lifecycle_event "$lifecycle_event"
	printf '%s\n' "$lifecycle_event" \
		>>"$LIFECYCLE_LOG" 2>/dev/null || true
	_MONITOR_STALL_SECONDS=0
	sleep "$POLL_INTERVAL"
	return 0
}

#######################################
# Enforce the total elapsed hard-kill cap.
#
# Arguments:
#   $1 - current output file size in bytes
# Returns:
#   0 when caller should continue monitoring
#   1 when caller should exit because the worker was killed
#######################################
_monitor_enforce_hard_kill() {
	local current_size="$1"
	local now_epoch elapsed_total
	now_epoch=$(date +%s)
	elapsed_total=$((now_epoch - _MONITOR_START_EPOCH))

	if [[ "$HARD_KILL_SECONDS" -le 0 || "$elapsed_total" -lt "$HARD_KILL_SECONDS" ]]; then
		return 0
	fi

	_kill_worker \
		"hard_kill: total elapsed ${elapsed_total}s ≥ hard-kill threshold ${HARD_KILL_SECONDS}s (current output ${current_size}b, stall=${_MONITOR_STALL_SECONDS}s, deferred=${_MONITOR_DEFERRED_STALL_SECONDS}s) — slot freed for re-dispatch" \
		"stall_killed"
	return 1
}

#######################################
# Handle a confirmed phase 2 stall.
#
# Arguments:
#   $1 - current output file size in bytes
# Returns:
#   0 when caller should continue monitoring
#   1 when caller should exit because the worker was killed
#######################################
_monitor_handle_confirmed_stall() {
	local current_size="$1"
	local now_epoch elapsed_total tree_cpu
	now_epoch=$(date +%s)
	elapsed_total=$((now_epoch - _MONITOR_START_EPOCH))

	if ! _monitor_enforce_hard_kill "$current_size"; then
		return 1
	fi

	if _output_has_provider_rate_limit; then
		_kill_worker "provider_rate_limit: provider/rate-limit marker visible after ${_MONITOR_STALL_SECONDS}s stall (stuck at ${current_size}b, total elapsed ${elapsed_total}s)"
		return 1
	fi

	if _output_has_ci_wait; then
		_monitor_defer_stall "ci_wait" ""
		return 0
	fi

	if _watchdog_tree_network_active "$WORKER_PID"; then
		_monitor_defer_stall "network_active" "signal=established_https "
		return 0
	fi

	tree_cpu=$(_watchdog_tree_cpu "$WORKER_PID")
	local stall_cpu_threshold="$STALL_CPU_THRESHOLD"
	[[ "$stall_cpu_threshold" =~ ^[0-9]+$ ]] || stall_cpu_threshold=2
	if [[ "$tree_cpu" -ge "$stall_cpu_threshold" ]]; then
		_monitor_defer_stall "cpu_active" "cpu=${tree_cpu}% "
		return 0
	fi

	_kill_worker "stall: no output growth for ${STALL_TIMEOUT}s (stuck at ${current_size}b, total elapsed ${elapsed_total}s, cpu=${tree_cpu}%, deferred=${_MONITOR_DEFERRED_STALL_SECONDS}s)"
	return 1
}

_monitor() {
	_monitor_init_state

	while true; do
		# Worker exited on its own — watchdog not needed
		if ! _worker_alive; then
			return 0
		fi

		local current_size
		current_size=$(_get_output_size)

		# Phase 1: any output at all
		if _monitor_handle_phase1 "$current_size"; then
			continue
		fi

		# Phase 2: continuous growth monitoring. Output growth is the cheapest
		# live-work signal and therefore always resets the stall counter.
		_monitor_track_output_growth "$current_size"

		if [[ "$_MONITOR_STALL_SECONDS" -ge "$STALL_TIMEOUT" ]]; then
			if ! _monitor_handle_confirmed_stall "$current_size"; then
				return 0
			fi
			continue
		fi

		sleep "$POLL_INTERVAL"
	done
}

#######################################
# Main
#######################################
main() {
	_parse_args "$@" || return 1

	# Verify the worker PID exists at startup
	if ! _worker_alive; then
		return 0
	fi

	# t3056: Initialize start epoch for lifecycle line trigger_age.
	# Set here (not in _monitor) so _kill_worker can reference it
	# from any context.
	_WATCHDOG_START_EPOCH=$(date +%s)

	_monitor
	return 0
}

main "$@"
