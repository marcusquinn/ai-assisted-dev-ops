#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Process Guard Helper - Monitor and kill runaway aidevops processes (t1398)
# =============================================================================
# Replaces the concept from PR #2792 (memory-pressure-monitor.sh) with a
# script that monitors the RIGHT signals: individual process RSS, process
# runtime, process count, and session count — not kern.memorystatus_level.
#
# Usage:
#   process-guard-helper.sh scan              # One-shot scan and report
#   process-guard-helper.sh kill-runaways     # Kill processes exceeding limits
#   process-guard-helper.sh sessions          # Report interactive session count
#   process-guard-helper.sh status            # Full status report (JSON)
#   process-guard-helper.sh help
#
# Integration:
#   - pulse-wrapper.sh calls guard_child_processes() every 60s (inline)
#   - This script provides standalone/cron usage for the same logic
#   - Cron: */5 * * * * ~/.aidevops/agents/scripts/process-guard-helper.sh kill-runaways
#
# Configuration (environment variables):
#   CHILD_RSS_LIMIT_KB     - Max RSS per child process (default: 2097152 = 2GB)
#   CHILD_RUNTIME_LIMIT    - Max unmanaged runtime in seconds (default: 7200 = 2h)
#   SHELLCHECK_RSS_LIMIT_KB - ShellCheck-specific RSS limit (default: 1048576 = 1GB)
#   SHELLCHECK_RUNTIME_LIMIT - ShellCheck-specific runtime (default: 300 = 5min)
#   STALE_PLAYWRIGHT_LIST_AGE_LIMIT - Max aidevops Playwright --list age (default: 900 = 15min)
#   SESSION_COUNT_WARN     - Warn when >N interactive sessions (default: 5)
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared constants for print_* functions
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Validate integer config: prevents command injection via arithmetic expansion.
# Same pattern as pulse-wrapper.sh _validate_int.
_validate_int() {
	local name="$1" value="$2" default="$3" min="${4:-0}"
	if ! [[ "$value" =~ ^[0-9]+$ ]]; then
		echo "[process-guard] Invalid ${name}: ${value} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	local canonical
	canonical=$(printf '%d' "$((10#$value))")
	if ((canonical < min)); then
		echo "[process-guard] ${name}=${canonical} below minimum ${min} — using default ${default}" >&2
		printf '%s' "$default"
		return 0
	fi
	printf '%s' "$canonical"
	return 0
}

# Configuration defaults
CHILD_RSS_LIMIT_KB="${CHILD_RSS_LIMIT_KB:-2097152}"
CHILD_RUNTIME_LIMIT="${CHILD_RUNTIME_LIMIT:-7200}"
SHELLCHECK_RSS_LIMIT_KB="${SHELLCHECK_RSS_LIMIT_KB:-1048576}"
SHELLCHECK_RUNTIME_LIMIT="${SHELLCHECK_RUNTIME_LIMIT:-300}"
STALE_PLAYWRIGHT_LIST_AGE_LIMIT="${STALE_PLAYWRIGHT_LIST_AGE_LIMIT:-900}"
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"
readonly PROCESS_RUNTIME_OK="OK"
readonly PROCESS_RUNTIME_MANAGED="MANAGED"
readonly PROCESS_RUNTIME_OVER="OVER"
readonly PROCESS_CGROUP_UNKNOWN='unknown'

# Validate all numeric config to prevent command injection via arithmetic expansion
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 7200 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
STALE_PLAYWRIGHT_LIST_AGE_LIMIT=$(_validate_int STALE_PLAYWRIGHT_LIST_AGE_LIMIT "$STALE_PLAYWRIGHT_LIST_AGE_LIMIT" 900 60)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)

LOGFILE="${HOME}/.aidevops/logs/process-guard.log"

mkdir -p "$(dirname "$LOGFILE")" || true

_process_guard_timestamp() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' 'unknown'
	return 0
}

#######################################
# List aidevops-related processes using pgrep (SC2009: avoids ps|grep)
# Output: ps fields (pid,ppid,tty,rss,etime,command) for matching processes
#######################################
_list_ai_processes() {
	# pgrep -f matches against the full command line; -d, separates PIDs with commas.
	# We use pgrep to find PIDs, then pass them directly to ps — no grep needed.
	local pids
	pids=$(pgrep -f 'opencode|shellcheck|node.*opencode|playwright[[:space:]]+test[[:space:]]+--list|pnpm .*playwright[[:space:]]+test[[:space:]]+--list' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
	if [[ -z "$pids" ]]; then
		return 0
	fi
	ps -p "$pids" -o pid=,ppid=,tty=,rss=,etime=,command= 2>/dev/null || true
	return 0
}

#######################################
# Return the process cwd when available (Linux /proc only).
# Arguments:
#   $1 - PID
# Output: cwd path or empty when unavailable
#######################################
_get_process_cwd() {
	local pid="$1"
	local cwd_path=""
	if [[ -e "/proc/${pid}/cwd" ]]; then
		cwd_path=$(readlink "/proc/${pid}/cwd" 2>/dev/null || true)
	fi
	printf '%s' "$cwd_path"
	return 0
}

#######################################
# Return the process's systemd or unified cgroup path when available.
# Arguments:
#   $1 - PID
# Output: cgroup path or "unknown"
#######################################
_get_process_cgroup_path() {
	local pid="$1"
	local proc_root="${AIDEVOPS_PROCESS_GUARD_PROC_ROOT:-/proc}"
	local cgroup_file="${proc_root%/}/${pid}/cgroup"
	local cgroup_line=""
	local cgroup_path=""
	local fallback_path=""

	if [[ -r "$cgroup_file" ]]; then
		while IFS= read -r cgroup_line || [[ -n "$cgroup_line" ]]; do
			cgroup_path="${cgroup_line#*:*:}"
			if [[ -z "$fallback_path" && -n "$cgroup_path" ]]; then
				fallback_path="$cgroup_path"
			fi
			case "$cgroup_line" in
			0::* | *:name=systemd:*)
				printf '%s' "$cgroup_path"
				return 0
				;;
			esac
		done <"$cgroup_file"
	fi
	if [[ -n "$fallback_path" ]]; then
		printf '%s' "$fallback_path"
		return 0
	fi

	printf '%s' "$PROCESS_CGROUP_UNKNOWN"
	return 0
}

#######################################
# Return whether a process belongs to a systemd-managed aidevops worker.
# All descendants of a transient worker service share its cgroup, so this
# verifies lifecycle ownership without relying on mutable command strings.
# Arguments:
#   $1 - PID
# Returns: 0 for managed worker lineage, 1 otherwise
#######################################
_is_managed_worker_process() {
	local pid="$1"
	local proc_root="${AIDEVOPS_PROCESS_GUARD_PROC_ROOT:-/proc}"
	local cgroup_file="${proc_root%/}/${pid}/cgroup"
	local cgroup_line=""
	local cgroup_path=""
	local worker_unit_regex='/aidevops-worker(-monitor|-observer)?-[0-9]+-[0-9]+-[0-9]+\.service(/|$)'

	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	[[ -r "$cgroup_file" ]] || return 1

	while IFS= read -r cgroup_line || [[ -n "$cgroup_line" ]]; do
		# cgroup v1: hierarchy:controllers:path; cgroup v2: 0::path.
		cgroup_path="${cgroup_line#*:*:}"
		if [[ "$cgroup_path" =~ $worker_unit_regex ]]; then
			return 0
		fi
	done <"$cgroup_file"

	return 1
}

#######################################
# Return whether a process belongs to the OpenCode web server or its watchdog
# service. The service manager owns both long-running lifecycles; applying the
# generic two-hour process limit to either unit disrupts active web sessions.
# Arguments:
#   $1 - PID
# Returns: 0 for managed OpenCode web-service lineage, 1 otherwise
#######################################
_is_managed_opencode_web_process() {
	local pid="$1"
	local cgroup_path=""
	local service_regex='/opencode-web(-watchdog|@[^/]+)?\.service(/|$)'

	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	cgroup_path=$(_get_process_cgroup_path "$pid")
	[[ "$cgroup_path" != "$PROCESS_CGROUP_UNKNOWN" ]] || return 1
	if [[ "$cgroup_path" =~ $service_regex ]]; then
		return 0
	fi
	return 1
}

#######################################
# Describe the lifecycle owner that supersedes the generic runtime limit.
# Arguments:
#   $1 - PID
# Output: owner label, or empty when unmanaged
#######################################
_runtime_management_owner() {
	local pid="$1"
	if _is_managed_worker_process "$pid"; then
		printf '%s' "worker-service"
		return 0
	fi
	if _is_managed_opencode_web_process "$pid"; then
		printf '%s' "opencode-web-service"
		return 0
	fi
	return 0
}

#######################################
# Classify a process against the generic runtime limit.
# Managed services delegate runtime decisions to their lifecycle-aware service,
# watchdog, or sandbox controls. RSS limits remain independently enforced.
# Arguments:
#   $1 - PID
#   $2 - process age in seconds
#   $3 - generic runtime limit in seconds
# Output: OK, MANAGED, or OVER
#######################################
_classify_runtime_limit() {
	local pid="$1"
	local age_seconds="$2"
	local runtime_limit="$3"
	local management_owner=""

	if [[ ! "$age_seconds" =~ ^[0-9]+$ || ! "$runtime_limit" =~ ^[0-9]+$ ]]; then
		printf '%s' "$PROCESS_RUNTIME_OK"
		return 0
	fi
	if [[ "$age_seconds" -le "$runtime_limit" ]]; then
		printf '%s' "$PROCESS_RUNTIME_OK"
		return 0
	fi
	management_owner=$(_runtime_management_owner "$pid")
	if [[ -n "$management_owner" ]]; then
		printf '%s' "$PROCESS_RUNTIME_MANAGED"
		return 0
	fi

	printf '%s' "$PROCESS_RUNTIME_OVER"
	return 0
}

#######################################
# Determine whether a Playwright list command is aidevops-owned evidence.
# Arguments:
#   $1 - command line
#   $2 - cwd path (may be empty)
#######################################
_has_aidevops_playwright_evidence() {
	local cmd_full="$1"
	local cwd_path="$2"

	case "$cwd_path" in
	*/.aidevops/* | */Git/aidevops | */Git/aidevops-* | */Git/*/aidevops | */Git/*/aidevops-*)
		return 0
		;;
	esac

	case "$cmd_full" in
	*/.aidevops/* | */Git/aidevops/* | */Git/aidevops-* | *aidevops-feature-auto-* | *aidevops-issue-* | *WORKER_WORKTREE_PATH=*)
		return 0
		;;
	esac

	return 1
}

#######################################
# Classify stale aidevops Playwright `test --list` commands.
# Arguments:
#   $1 - age in seconds
#   $2 - tty
#   $3 - cwd path (may be empty)
#   $4 - command line
# Output: reason string
#######################################
_classify_stale_playwright_list() {
	local age_seconds="$1"
	local tty="$2"
	local cwd_path="$3"
	local cmd_full="$4"

	if [[ "$tty" != "?" && "$tty" != "??" ]]; then
		printf '%s' "SAFE interactive tty=${tty}"
		return 1
	fi

	if [[ ! "$age_seconds" =~ ^[0-9]+$ ]]; then
		printf '%s' "SAFE invalid age=${age_seconds}"
		return 1
	fi

	local playwright_regex
	playwright_regex='playwright[[:space:]]+test[[:space:]]+--list'
	if [[ ! "$cmd_full" =~ $playwright_regex ]]; then
		printf '%s' "SAFE not playwright test --list"
		return 1
	fi

	local grep_regex
	grep_regex='(^|[[:space:]])--grep([[:space:]]+|=)'
	if [[ ! "$cmd_full" =~ $grep_regex ]]; then
		printf '%s' "SAFE missing grep selector"
		return 1
	fi

	if ! _has_aidevops_playwright_evidence "$cmd_full" "$cwd_path"; then
		printf '%s' "SAFE no aidevops cwd/cmd evidence"
		return 1
	fi

	if [[ "$age_seconds" -le "$STALE_PLAYWRIGHT_LIST_AGE_LIMIT" ]]; then
		printf '%s' "SAFE age ${age_seconds}s <= ${STALE_PLAYWRIGHT_LIST_AGE_LIMIT}s"
		return 1
	fi

	printf '%s' "stale aidevops Playwright list process (age=${age_seconds}s, cwd=${cwd_path:-unknown})"
	return 0
}

#######################################
# Get process age in seconds (portable macOS + Linux)
# Arguments:
#   $1 - PID
# Output: elapsed seconds via stdout
#######################################
_get_process_age() {
	local pid="$1"
	local etime
	etime=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ') || etime=""

	if [[ -z "$etime" ]]; then
		echo "0"
		return 0
	fi

	local days=0 hours=0 minutes=0 seconds=0

	if [[ "$etime" == *-* ]]; then
		days="${etime%%-*}"
		etime="${etime#*-}"
	fi

	local colons_only="${etime//[!:]/}"
	local colon_count="${#colons_only}"

	if [[ "$colon_count" -eq 2 ]]; then
		IFS=':' read -r hours minutes seconds <<<"$etime"
	elif [[ "$colon_count" -eq 1 ]]; then
		IFS=':' read -r minutes seconds <<<"$etime"
	else
		seconds="$etime"
	fi

	[[ "$days" =~ ^[0-9]+$ ]] || days=0
	[[ "$hours" =~ ^[0-9]+$ ]] || hours=0
	[[ "$minutes" =~ ^[0-9]+$ ]] || minutes=0
	[[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0

	days=$((10#${days}))
	hours=$((10#${hours}))
	minutes=$((10#${minutes}))
	seconds=$((10#${seconds}))

	echo $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
	return 0
}

#######################################
# Scan all aidevops-related processes and report status
# Output: human-readable report to stdout
#######################################
cmd_scan() {
	echo "=== Process Guard Scan ==="
	echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo ""

	# Find all opencode/node processes related to aidevops
	local total_rss_kb=0
	local process_count=0
	local violations=0

	echo "--- AI Processes ---"
	printf "%-8s %-6s %-6s %-10s %-5s %-12s %-8s %s\n" "PID" "PPID" "RSS_MB" "RUNTIME" "TTY" "COMMAND" "STATUS" "DETAIL"

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"

		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		# Extract basename for limit selection (e.g., /usr/bin/shellcheck → shellcheck)
		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		local rss_mb=$((rss / 1024))
		total_rss_kb=$((total_rss_kb + rss))
		process_count=$((process_count + 1))

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		local runtime_status
		local cwd_path
		cwd_path=$(_get_process_cwd "$pid")

		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi
		runtime_status=$(_classify_runtime_limit "$pid" "$age_seconds" "$runtime_limit")

		local status="OK"
		local detail=""
		# TTY-attached processes are interactive — report but don't flag as violations
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			status="INTERACTIVE"
			detail="TTY=$tty (protected)"
		elif [[ "$rss" -gt "$rss_limit" ]]; then
			status="OVER_RSS"
			detail="RSS ${rss_mb}MB > $((rss_limit / 1024))MB"
			violations=$((violations + 1))
		elif [[ "$runtime_status" == "$PROCESS_RUNTIME_OVER" ]]; then
			status="OVER_TIME"
			detail="runtime ${age_seconds}s > ${runtime_limit}s"
			violations=$((violations + 1))
		elif [[ "$runtime_status" == "$PROCESS_RUNTIME_MANAGED" ]]; then
			status="MANAGED"
			detail="runtime delegated to $(_runtime_management_owner "$pid") lifecycle controls"
		elif [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				status="ORPHAN"
				detail="ppid=1, age=${age_seconds}s (no consumer)"
				violations=$((violations + 1))
			fi
		else
			local playwright_detail
			if playwright_detail=$(_classify_stale_playwright_list "$age_seconds" "$tty" "$cwd_path" "$cmd_full"); then
				status="STALE"
				detail="$playwright_detail"
				violations=$((violations + 1))
			fi
		fi

		printf "%-8s %-6s %-6s %-10s %-5s %-12s %-8s %s\n" "$pid" "$ppid" "${rss_mb}MB" "$etime" "$tty" "$cmd_base" "$status" "$detail"
	done < <(_list_ai_processes)

	echo ""
	echo "Total: ${process_count} processes, $((total_rss_kb / 1024))MB RSS, ${violations} violation(s)"

	# Session count
	echo ""
	echo "--- Interactive Sessions ---"
	local session_count
	# t2190: ps axwwo to avoid Linux procps command truncation defeating the awk regex.
	session_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0
	echo "Interactive sessions: ${session_count} (threshold: ${SESSION_COUNT_WARN})"
	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "WARNING: Session count exceeds threshold. Each session uses 100-440MB + language servers."
	fi

	return 0
}

#######################################
# Kill processes exceeding RSS or runtime limits
# Output: report of killed processes
#######################################
cmd_kill_runaways() {
	local killed=0
	local total_freed_mb=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"

		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0

		# Skip TTY-attached processes — these are interactive user sessions
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"

		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		local runtime_status
		local cwd_path
		cwd_path=$(_get_process_cwd "$pid")

		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi
		runtime_status=$(_classify_runtime_limit "$pid" "$age_seconds" "$runtime_limit")

		local violation=""
		if [[ "$rss" -gt "$rss_limit" ]]; then
			local rss_mb=$((rss / 1024))
			violation="RSS ${rss_mb}MB > $((rss_limit / 1024))MB"
		elif [[ "$runtime_status" == "$PROCESS_RUNTIME_OVER" ]]; then
			violation="runtime ${age_seconds}s > ${runtime_limit}s"
		fi

		# Managed service trees have dedicated activity, health, sandbox, service,
		# or lease controls. Do not apply generic age-based cleanup to them.
		if [[ -z "$violation" && "$runtime_status" == "$PROCESS_RUNTIME_MANAGED" ]]; then
			continue
		fi

		# Orphan shellcheck reaper: if parent is PID 1 (reparented because the
		# language server that spawned it exited) and alive >120s, kill it.
		# Nobody is reading the output, so the work is wasted CPU.
		if [[ -z "$violation" ]] && [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				violation="orphan (ppid=1, age=${age_seconds}s)"
			fi
		fi

		if [[ -z "$violation" ]] && _classify_stale_playwright_list "$age_seconds" "$tty" "$cwd_path" "$cmd_full" >/dev/null; then
			violation=$(_classify_stale_playwright_list "$age_seconds" "$tty" "$cwd_path" "$cmd_full")
		fi

		if [[ -n "$violation" ]]; then
			local rss_mb=$((rss / 1024))
			local process_class killed_at cgroup_path
			process_class='other'
			case "$cmd_base" in
			shellcheck) process_class='lint' ;;
			node)
				if [[ $cmd_full == *playwright* && $cmd_full == *--list* ]]; then
					process_class='playwright-list'
				else
					process_class='node'
				fi
				;;
			opencode | opencode-ai | claude | claude-ai) process_class='ai-runtime' ;;
			esac
			killed_at=$(_process_guard_timestamp)
			cgroup_path=$(_get_process_cgroup_path "$pid")
			echo "Killing PID $pid ($cmd_base) — $violation"
			printf '[process-guard] %s action=kill pid=%s ppid=%s class=%s cmd=%s rss_mb=%s age_seconds=%s runtime_limit_seconds=%s cgroup=%s reason=%s\n' \
				"$killed_at" "$pid" "$ppid" "$process_class" "$cmd_base" "$rss_mb" "$age_seconds" "$runtime_limit" "$cgroup_path" "$violation" >>"$LOGFILE"
			kill "$pid" 2>/dev/null || true
			sleep 1
			if kill -0 "$pid" 2>/dev/null; then
				kill -9 "$pid" 2>/dev/null || true
			fi
			killed=$((killed + 1))
			total_freed_mb=$((total_freed_mb + rss_mb))
		fi
	done < <(_list_ai_processes)

	if [[ "$killed" -gt 0 ]]; then
		echo "Killed $killed process(es), freed ~${total_freed_mb}MB"
		printf '[process-guard] %s Killed %s process(es), freed ~%sMB\n' "$(_process_guard_timestamp)" "$killed" "$total_freed_mb" >>"$LOGFILE"
	else
		echo "No runaway processes found"
	fi
	return 0
}

#######################################
# Report interactive session count
#######################################
cmd_sessions() {
	local session_count
	# t2190: ps axwwo to avoid Linux procps command truncation.
	session_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0

	echo "$session_count"

	if [[ "$session_count" -gt "$SESSION_COUNT_WARN" ]]; then
		echo "WARNING: $session_count sessions open (threshold: $SESSION_COUNT_WARN)" >&2
		echo "Each session consumes 100-440MB + language servers (~50-100MB each)." >&2
		echo "Consider closing unused terminal tabs." >&2
		return 1
	fi
	return 0
}

#######################################
# Full status report in JSON format
#######################################
cmd_status() {
	local total_rss_kb=0
	local process_count=0
	local violations=0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		# Fields: pid, ppid, tty, rss, etime, command (command is last — may contain spaces)
		local pid ppid tty rss etime cmd_full
		read -r pid ppid tty rss etime cmd_full <<<"$line"
		[[ "$rss" =~ ^[0-9]+$ ]] || rss=0
		total_rss_kb=$((total_rss_kb + rss))
		process_count=$((process_count + 1))

		# Skip TTY-attached processes — interactive user sessions
		if [[ "$tty" != "?" && "$tty" != "??" ]]; then
			continue
		fi

		local cmd_base="${cmd_full%% *}"
		cmd_base="${cmd_base##*/}"
		local age_seconds
		age_seconds=$(_get_process_age "$pid")
		local runtime_status
		local cwd_path
		cwd_path=$(_get_process_cwd "$pid")
		local rss_limit="$CHILD_RSS_LIMIT_KB"
		local runtime_limit="$CHILD_RUNTIME_LIMIT"
		if [[ "$cmd_base" == "shellcheck" ]]; then
			rss_limit="$SHELLCHECK_RSS_LIMIT_KB"
			runtime_limit="$SHELLCHECK_RUNTIME_LIMIT"
		fi
		runtime_status=$(_classify_runtime_limit "$pid" "$age_seconds" "$runtime_limit")
		if [[ "$rss" -gt "$rss_limit" ]] || [[ "$runtime_status" == "$PROCESS_RUNTIME_OVER" ]]; then
			violations=$((violations + 1))
		elif [[ "$runtime_status" == "$PROCESS_RUNTIME_MANAGED" ]]; then
			continue
		elif [[ "$cmd_base" == "shellcheck" ]]; then
			[[ "$ppid" =~ ^[0-9]+$ ]] || ppid=0
			if [[ "$ppid" -eq 1 ]] && [[ "$age_seconds" -gt 120 ]]; then
				violations=$((violations + 1))
			fi
		elif _classify_stale_playwright_list "$age_seconds" "$tty" "$cwd_path" "$cmd_full" >/dev/null; then
			violations=$((violations + 1))
		fi
	done < <(_list_ai_processes)

	local session_count
	# t2190: ps axwwo to avoid Linux procps command truncation.
	session_count=$(ps axwwo tty,command | awk '
		/(\.(opencode|claude)|opencode-ai|claude-ai)/ && !/awk/ && $1 != "?" && $1 != "??" { count++ }
		END { print count + 0 }
	') || session_count=0

	# Available memory (Linux)
	local mem_avail_mb="unknown"
	if [[ -f /proc/meminfo ]]; then
		mem_avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "unknown")
	elif [[ "$(uname)" == "Darwin" ]]; then
		local page_size vm_free vm_inactive
		page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo "16384")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		[[ "$page_size" =~ ^[0-9]+$ ]] || page_size=16384
		[[ "$vm_free" =~ ^[0-9]+$ ]] || vm_free=0
		[[ "$vm_inactive" =~ ^[0-9]+$ ]] || vm_inactive=0
		mem_avail_mb=$(((vm_free + vm_inactive) * page_size / 1048576))
	fi

	printf '{"timestamp":"%s","process_count":%d,"total_rss_mb":%d,"violations":%d,"session_count":%d,"session_warn_threshold":%d,"mem_available_mb":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$process_count" \
		"$((total_rss_kb / 1024))" \
		"$violations" \
		"$session_count" \
		"$SESSION_COUNT_WARN" \
		"$mem_avail_mb"
	return 0
}

#######################################
# Dry-run matcher for stale Playwright list command lines.
#######################################
cmd_match_playwright_list() {
	local age_seconds="${1:-}"
	local tty="${2:-?}"
	local cwd_path="${3:-}"
	shift 3 2>/dev/null || true
	local cmd_full="$*"

	if [[ -z "$age_seconds" || -z "$cmd_full" ]]; then
		echo "Usage: process-guard-helper.sh match-playwright-list <age-seconds> <tty> <cwd> <command...>" >&2
		return 1
	fi

	local reason
	if reason=$(_classify_stale_playwright_list "$age_seconds" "$tty" "$cwd_path" "$cmd_full"); then
		printf 'MATCH %s\n' "$reason"
		return 0
	fi

	printf 'NO_MATCH %s\n' "$reason"
	return 1
}

#######################################
# Help
#######################################
cmd_help() {
	echo "process-guard-helper.sh — Monitor and kill runaway aidevops processes (t1398)"
	echo ""
	echo "Usage:"
	echo "  process-guard-helper.sh scan              One-shot scan and report"
	echo "  process-guard-helper.sh kill-runaways     Kill processes exceeding limits"
	echo "  process-guard-helper.sh match-playwright-list <age> <tty> <cwd> <command...>"
	echo "  process-guard-helper.sh sessions          Report interactive session count"
	echo "  process-guard-helper.sh status            Full status report (JSON)"
	echo "  process-guard-helper.sh help              Show this help"
	echo ""
	echo "Configuration (environment variables):"
	echo "  CHILD_RSS_LIMIT_KB=${CHILD_RSS_LIMIT_KB} ($((CHILD_RSS_LIMIT_KB / 1024))MB)"
	echo "  CHILD_RUNTIME_LIMIT=${CHILD_RUNTIME_LIMIT}s"
	echo "  SHELLCHECK_RSS_LIMIT_KB=${SHELLCHECK_RSS_LIMIT_KB} ($((SHELLCHECK_RSS_LIMIT_KB / 1024))MB)"
	echo "  SHELLCHECK_RUNTIME_LIMIT=${SHELLCHECK_RUNTIME_LIMIT}s"
	echo "  STALE_PLAYWRIGHT_LIST_AGE_LIMIT=${STALE_PLAYWRIGHT_LIST_AGE_LIMIT}s"
	echo "  SESSION_COUNT_WARN=${SESSION_COUNT_WARN}"
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local command="${1:-help}"

	case "$command" in
	scan) cmd_scan ;;
	kill-runaways) cmd_kill_runaways ;;
	match-playwright-list)
		shift
		cmd_match_playwright_list "$@"
		;;
	sessions) cmd_sessions ;;
	status) cmd_status ;;
	help | --help | -h) cmd_help ;;
	*)
		echo "Unknown command: $command" >&2
		cmd_help >&2
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
