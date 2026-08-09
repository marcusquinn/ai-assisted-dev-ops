#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# stats-wrapper.sh - Separate process for statistics and health updates
#
# Runs quality sweep, health issue updates, and person-stats independently
# of the supervisor pulse. These operations depend on GitHub Search API
# (30 req/min limit) and can block for extended periods when rate-limited.
# Running them in-process with the pulse prevented dispatch and merge work
# from ever executing. See t1429 for the full root cause analysis.
#
# Called by cron/launchd every 15 minutes. Has its own PID dedup and hard timeout.

set -euo pipefail

#######################################
# PATH normalisation — same as pulse-wrapper.sh
#######################################
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
# in zsh (MCP shell environment). See GH#3931.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || return 2>/dev/null || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

#######################################
# Configuration
#######################################
STATS_TIMEOUT="${STATS_TIMEOUT:-600}" # 10 min hard ceiling
STATS_TIMEOUT=$(_validate_int STATS_TIMEOUT "$STATS_TIMEOUT" 600 60)

STATS_PIDFILE="${HOME}/.aidevops/logs/stats.pid"
STATS_LOGFILE="${HOME}/.aidevops/logs/stats.log"

mkdir -p "$(dirname "$STATS_PIDFILE")"

#######################################
# Portable elapsed-seconds lookup for a running PID
#
# Robustness notes:
# - The `ps` commands use `|| true` to prevent `set -euo pipefail` from
#   aborting the script if the process disappears. This allows the `etime`
#   fallback logic to execute.
# - The `awk` command substitution also uses `|| true`. `awk` is scripted to
#   `exit 1` on invalid input, and this guard prevents script termination.
#   The subsequent `^[0-9]+$` check handles the empty output case.
#######################################
_stats_process_elapsed_seconds() {
	local pid="$1"
	local elapsed=""

	elapsed=$(ps -p "$pid" -o etimes= 2>/dev/null | tr -d '[:space:]' || true)
	if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$elapsed"
		return 0
	fi

	local etime=""
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d '[:space:]' || true)
	if [[ -z "$etime" ]]; then
		return 1
	fi

	elapsed=$(awk -v value="$etime" '
		BEGIN {
			n = split(value, parts, /[-:]/)
			if (index(value, "-") > 0) {
				if (n != 4) { exit 1 }
				total = (parts[1] * 86400) + (parts[2] * 3600) + (parts[3] * 60) + parts[4]
			} else if (n == 3) {
				total = (parts[1] * 3600) + (parts[2] * 60) + parts[3]
			} else if (n == 2) {
				total = (parts[1] * 60) + parts[2]
			} else {
				exit 1
			}
			print total
		}
	' || true)

	if [[ "$elapsed" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$elapsed"
		return 0
	fi

	return 1
}

#######################################
# PID-based dedup — same pattern as pulse-wrapper check_dedup()
#######################################
check_stats_dedup() {
	if [[ ! -f "$STATS_PIDFILE" ]]; then
		return 0
	fi

	# PID file format: "PID EPOCH" (PID + start timestamp)
	local old_pid old_epoch
	read -r old_pid old_epoch <"$STATS_PIDFILE" 2>/dev/null || {
		rm -f "$STATS_PIDFILE"
		return 0
	}

	if [[ -z "$old_pid" ]]; then
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	if ! ps -p "$old_pid" >/dev/null 2>&1; then
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	# Prefer stored epoch, but validate it before use. Invalid epochs used to
	# compute huge elapsed values and incorrectly kill healthy stats workers.
	local now elapsed
	now=$(date +%s)
	if [[ "$old_epoch" =~ ^[0-9]+$ ]] && [[ "$old_epoch" -gt 0 ]] && [[ "$old_epoch" -le "$now" ]]; then
		elapsed=$((now - old_epoch))
	else
		elapsed=$(_stats_process_elapsed_seconds "$old_pid") || {
			if kill -0 "$old_pid" 2>/dev/null; then
				echo "[stats-wrapper] Unable to determine elapsed time for live PID $old_pid; preserving pidfile and skipping." >>"$STATS_LOGFILE"
				return 1
			fi
			rm -f "$STATS_PIDFILE"
			return 0
		}
	fi

	if [[ "$elapsed" -gt "$STATS_TIMEOUT" ]]; then
		echo "[stats-wrapper] Killing stale stats process $old_pid (${elapsed}s)" >>"$STATS_LOGFILE"
		_kill_tree "$old_pid" || true
		sleep 2
		if kill -0 "$old_pid" 2>/dev/null; then
			_force_kill_tree "$old_pid" || true
		fi
		rm -f "$STATS_PIDFILE"
		return 0
	fi

	echo "[stats-wrapper] Stats already running (PID $old_pid, ${elapsed}s). Skipping." >>"$STATS_LOGFILE"
	return 1
}

#######################################
# Exit trap handler — t2418 Phase B
#
# The pre-t2418 script only removed the pidfile on EXIT. Under
# `set -euo pipefail`, any failing command produced a silent non-zero exit
# with no operator-visible record of what broke. Dashboard staleness
# could persist for weeks (see #20016: 11-day gap on #10944). This trap
# emits HEALTH-DASHBOARD-FAIL with the exit code so
# `tail ~/.aidevops/logs/stats.log` surfaces the failure immediately.
#
# Defined at file scope (not inside main) so main() stays under the
# 100-line function-complexity gate and the trap can be tested directly.
#######################################
_stats_wrapper_on_exit() {
	local ec=$?
	_stats_wrapper_remove_own_pidfile
	if [[ "$ec" -ne 0 ]]; then
		echo "[stats-wrapper] HEALTH-DASHBOARD-FAIL exit=${ec} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
	fi
	return "$ec"
}

# A timed-out predecessor can finish its EXIT trap after a later scheduler
# invocation has replaced the PID file. Only remove the file when it still
# records this wrapper's PID, so that cleanup cannot disable deduplication for
# the healthy successor.
_stats_wrapper_remove_own_pidfile() {
	local pidfile_pid="" pidfile_epoch=""
	if [[ ! -f "$STATS_PIDFILE" ]]; then
		return 0
	fi
	read -r pidfile_pid pidfile_epoch <"$STATS_PIDFILE" 2>/dev/null || return 0
	if [[ "$pidfile_pid" == "$$" ]]; then
		rm -f "$STATS_PIDFILE" 2>/dev/null || true
	fi
	return 0
}

_stats_wrapper_run_health_update() {
	local update_ec=0
	update_health_issues || update_ec=$?
	case "$update_ec" in
	0)
		return 0
		;;
	75)
		# EX_TEMPFAIL is the GitHub cooldown/rate-limit path used by the gh
		# wrappers. Treat it as a successful scheduler tick: the routine did the
		# safe thing by preserving cached dashboards and backing off, so launchd
		# should not mark the job as broken or create failure streak noise.
		echo "[stats-wrapper] HEALTH-DASHBOARD-DEFERRED transient exit=${update_ec} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
		return 0
		;;
	*)
		return "$update_ec"
		;;
	esac
}

# Execute the potentially slow work in a child so the wrapper can enforce its
# own wall-clock ceiling rather than relying on the next scheduler tick to
# detect a stale PID file.
_stats_wrapper_run_work() {
	# Source stats-functions.sh for health dashboard and quality sweep functions.
	# After t1431, these functions live in their own file instead of pulse-wrapper.sh.
	# LOGFILE is set to STATS_LOGFILE so all function logging goes to stats.log.
	LOGFILE="$STATS_LOGFILE"
	# shellcheck source=stats-functions.sh
	source "${SCRIPT_DIR}/stats-functions.sh" || {
		echo "[stats-wrapper] Failed to source stats-functions.sh" >>"$STATS_LOGFILE"
		return 1
	}

	run_daily_quality_sweep || {
		local sweep_ec=$?
		echo "[stats-wrapper] QUALITY-SWEEP-FAIL exit=${sweep_ec} at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
	}
	_stats_wrapper_run_health_update
	return $?
}

_stats_wrapper_run_with_timeout() {
	local start_epoch="" now="" elapsed="" child_pid=""
	start_epoch=$(date +%s)
	_stats_wrapper_run_work &
	child_pid=$!

	while kill -0 "$child_pid" 2>/dev/null; do
		now=$(date +%s)
		elapsed=$((now - start_epoch))
		if [[ "$elapsed" -ge "$STATS_TIMEOUT" ]]; then
			echo "[stats-wrapper] STATS-TIMEOUT elapsed=${elapsed}s ceiling=${STATS_TIMEOUT}s pid=${child_pid}; killing process tree" >>"$STATS_LOGFILE"
			_kill_tree "$child_pid" || true
			sleep 2
			if kill -0 "$child_pid" 2>/dev/null; then
				_force_kill_tree "$child_pid" || true
			fi
			wait "$child_pid" 2>/dev/null || true
			return 124
		fi
		sleep 2
	done

	wait "$child_pid"
	return $?
}

#######################################
# Main
#######################################
main() {
	# GH#19913: declare this process as headless BEFORE anything else runs
	# so every child shell stage sees AIDEVOPS_HEADLESS and
	# detect_session_origin() returns "worker". Mirrors the GH#18670 fix in
	# pulse-wrapper.sh:1369. Without this, _sweep_review_scanner ->
	# quality-feedback-helper.sh -> _create_new_quality_debt_issue ->
	# gh_create_issue -> session_origin_label() defaults to
	# "origin:interactive" and _gh_wrapper_auto_assignee assigns the
	# runner, which trips GH#18352's dispatch-dedup guard and strands every
	# quality-debt issue the 15-min stats sweep creates. Scoped to main()
	# so callers sourcing stats-wrapper.sh for testing do not inherit the
	# env var (same scoping guarantee as pulse-wrapper.sh).
	export AIDEVOPS_HEADLESS=true

	#######################################
	# --self-check mode (t2044 Phase 0 -- plan section 5.2)
	#
	# Source stats-functions.sh and assert the public entry points plus a
	# representative private helper are defined. Used in CI gates and
	# post-merge validation. Does not create a PID file or run any stats.
	#######################################
	if [[ "${1:-}" == "--self-check" ]]; then
		LOGFILE="$STATS_LOGFILE"
		# shellcheck source=stats-functions.sh
		source "${SCRIPT_DIR}/stats-functions.sh" || {
			echo "stats-wrapper self-check FAILED: source failed"
			return 1
		}
		local fn
		for fn in update_health_issues run_daily_quality_sweep _validate_repo_slug \
			_get_runner_role _persist_role_cache _scan_active_workers \
			_ensure_quality_issue _run_sweep_tools; do
			declare -F "$fn" >/dev/null || {
				echo "stats-wrapper self-check FAILED: missing $fn"
				return 1
			}
		done
		echo "stats-wrapper self-check OK"
		return 0
	fi

	#######################################
	# --dry-run mode (t2044 Phase 0 -- plan section 5.3)
	#
	# Source everything and exercise the main flow with STATS_DRY_RUN=1.
	# The two public entry points (update_health_issues, run_daily_quality_sweep)
	# have sentinel early-returns that check this variable, so the call graph
	# executes end-to-end without making any gh/git API calls.
	#######################################
	if [[ "${1:-}" == "--dry-run" ]]; then
		export STATS_DRY_RUN=1
		LOGFILE="$STATS_LOGFILE"
		# shellcheck source=stats-functions.sh
		source "${SCRIPT_DIR}/stats-functions.sh" || {
			echo "stats-wrapper dry-run FAILED: source failed"
			return 1
		}
		echo "[stats-wrapper] Dry-run: calling run_daily_quality_sweep..." >>"$STATS_LOGFILE"
		run_daily_quality_sweep || true
		echo "[stats-wrapper] Dry-run: calling update_health_issues..." >>"$STATS_LOGFILE"
		update_health_issues || true
		echo "[stats-wrapper] Dry-run: complete (no API calls made)" >>"$STATS_LOGFILE"
		echo "stats-wrapper dry-run OK"
		return 0
	fi

	if ! check_stats_dedup; then
		return 0
	fi

	echo "$$ $(date +%s)" >"$STATS_PIDFILE"

	# t2418 Phase B: trap handler defined at file scope — see
	# _stats_wrapper_on_exit above for rationale.
	trap '_stats_wrapper_on_exit' EXIT

	echo "[stats-wrapper] Starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"

	_stats_wrapper_run_with_timeout

	echo "[stats-wrapper] Finished at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$STATS_LOGFILE"
	return 0
}

# Shell-portable source detection — same as pulse-wrapper (GH#3931)
_stats_is_sourced() {
	if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
		[[ "${BASH_SOURCE[0]}" != "${0}" ]]
	elif [[ -n "${ZSH_EVAL_CONTEXT:-}" ]]; then
		[[ ":${ZSH_EVAL_CONTEXT}:" == *":file:"* ]]
	else
		return 1
	fi
}
if ! _stats_is_sourced; then
	main "$@"
fi
