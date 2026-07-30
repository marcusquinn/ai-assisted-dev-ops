#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# orchestration-efficiency-collector.sh — Phase 1 deterministic data collector
# for the daily orchestration efficiency analysis routine (GH#15316).
#
# Collects metrics from pulse logs, worker logs, backoff DB, observability DB,
# pool state, and gh API, then writes a structured JSON report to:
#   ~/.aidevops/logs/efficiency-report-YYYY-MM-DD.json
#
# Designed to run zero-LLM — all collection is deterministic shell + SQLite.
# The LLM analysis phase (orchestration-analysis.md) reads this output.
#
# Usage:
#   orchestration-efficiency-collector.sh [--date YYYY-MM-DD] [--output FILE]
#   orchestration-efficiency-collector.sh --help
#
# Options:
#   --date YYYY-MM-DD   Collect for a specific date (default: today)
#   --output FILE       Write report to FILE (default: auto-named in logs dir)
#   --help              Show this help
#
# Exit codes:
#   0  Report written successfully
#   1  Fatal error (missing required tools, unwritable output)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

LOG_PREFIX="EFFICIENCY-COLLECTOR"

# =============================================================================
# Constants
# =============================================================================

readonly LOGS_DIR="${HOME}/.aidevops/logs"
readonly AGENT_WORKSPACE="${HOME}/.aidevops/.agent-workspace"
readonly OBS_DIR="${AGENT_WORKSPACE}/observability"
readonly OBS_METRICS="${OBS_DIR}/metrics.jsonl"
readonly OBS_DB="${OBS_DIR}/llm-requests.db"
readonly SUPERVISOR_DIR="${AGENT_WORKSPACE}/supervisor"
readonly SUPERVISOR_DB="${SUPERVISOR_DIR}/supervisor.db"
readonly CIRCUIT_BREAKER_STATE="${SUPERVISOR_DIR}/circuit-breaker.state"
readonly DISPATCH_LEDGER="${AGENT_WORKSPACE}/tmp/dispatch-ledger.jsonl"
readonly HEADLESS_METRICS="${LOGS_DIR}/headless-runtime-metrics.jsonl"
readonly RESOURCE_METRICS="${LOGS_DIR}/resource-metrics.jsonl"
readonly PULSE_LOG="${LOGS_DIR}/pulse.log"
readonly PULSE_HEALTH="${LOGS_DIR}/pulse-health.json"
readonly WORKTREE_REGISTRY="${AGENT_WORKSPACE}/worktree-registry.db"
readonly REPORT_RETENTION_DAYS=30

# =============================================================================
# Logging
# =============================================================================

log_info() {
	printf '[%s] [%s] [INFO] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1" >&2
	return 0
}

log_warn() {
	printf '[%s] [%s] [WARN] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1" >&2
	return 0
}

log_error() {
	printf '[%s] [%s] [ERROR] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_PREFIX" "$1" >&2
	return 0
}

# =============================================================================
# Argument parsing
# =============================================================================

TARGET_DATE=""
OUTPUT_FILE=""

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--date)
			TARGET_DATE="$2"
			shift 2
			;;
		--output)
			OUTPUT_FILE="$2"
			shift 2
			;;
		--help | -h)
			sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]:-$0}" | grep '^#' | sed 's/^# \?//'
			exit 0
			;;
		*)
			log_error "Unknown argument: $1"
			exit 1
			;;
		esac
	done
	return 0
}

# =============================================================================
# Date helpers
# =============================================================================

get_today() {
	date -u +%Y-%m-%d
	return 0
}

# Convert YYYY-MM-DD to epoch seconds (portable: works on Linux and macOS)
date_to_epoch() {
	local d="$1"
	if date --version >/dev/null 2>&1; then
		# GNU date (Linux)
		date -u -d "$d" +%s 2>/dev/null || echo "0"
	else
		# BSD date (macOS)
		date -u -j -f "%Y-%m-%d" "$d" +%s 2>/dev/null || echo "0"
	fi
	return 0
}

# =============================================================================
# Safe integer helpers
# =============================================================================

safe_int() {
	local val="$1"
	local default="${2:-0}"
	if [[ "$val" =~ ^[0-9]+$ ]]; then
		echo "$val"
	else
		echo "$default"
	fi
	return 0
}

safe_float() {
	local val="$1"
	local default="${2:-0.0}"
	if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "$val"
	else
		echo "$default"
	fi
	return 0
}

# =============================================================================
# Metric collection functions
# =============================================================================

# --- Token efficiency ---

collect_token_efficiency() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local supervisor_tokens_per_cycle=0
	local worker_tokens_per_issue=0
	local tokens_wasted_on_stalls=0
	local llm_skip_rate=0
	local total_cost=0
	local total_requests=0
	local total_tokens=0

	# Query observability DB for the target date
	if [[ -f "$OBS_DB" ]] && command -v sqlite3 &>/dev/null; then
		local db_result
		# worker_avg: restrict to rows where agent contains 'worker' (not just
		# "not supervisor") to avoid pulling pulse/other rows into the average.
		db_result=$(sqlite3 "$OBS_DB" \
			"SELECT
				COUNT(*) as requests,
				COALESCE(SUM(tokens_total), 0) as total_tokens,
				COALESCE(SUM(cost), 0) as total_cost,
				COALESCE(AVG(CASE WHEN agent LIKE '%supervisor%' OR agent LIKE '%pulse%' THEN tokens_total ELSE NULL END), 0) as supervisor_avg,
				COALESCE(AVG(CASE WHEN agent LIKE '%worker%' THEN tokens_total ELSE NULL END), 0) as worker_avg
			FROM llm_requests
			WHERE timestamp >= datetime($start_epoch, 'unixepoch')
			  AND timestamp < datetime($end_epoch, 'unixepoch');" 2>/dev/null || echo "0|0|0|0|0")

		IFS='|' read -r total_requests total_tokens total_cost supervisor_tokens_per_cycle worker_tokens_per_issue <<<"$db_result"
		total_requests=$(safe_int "$total_requests")
		total_tokens=$(safe_int "$total_tokens")
		supervisor_tokens_per_cycle=$(safe_int "$supervisor_tokens_per_cycle")
		worker_tokens_per_issue=$(safe_int "$worker_tokens_per_issue")
		total_cost=$(safe_float "$total_cost")
	fi

	# LLM skip rate: from headless metrics — ratio of skipped vs total dispatches
	local skipped_count=0
	local total_dispatched=0
	if [[ -f "$HEADLESS_METRICS" ]]; then
		skipped_count=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"result":"([^"]+)"/, res)
				if (ts[1]+0 >= s && ts[1]+0 < e) {
					total++
					if (res[1] == "skipped" || res[1] == "no_work") skipped++
				}
			}
			END { print skipped+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		total_dispatched=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				if (ts[1]+0 >= s && ts[1]+0 < e) total++
			}
			END { print total+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		skipped_count=$(safe_int "$skipped_count")
		total_dispatched=$(safe_int "$total_dispatched")
		if [[ "$total_dispatched" -gt 0 ]]; then
			llm_skip_rate=$(echo "scale=4; $skipped_count * 100 / $total_dispatched" | bc 2>/dev/null || echo "0")
		fi
	fi

	# Tokens wasted on stalls: from headless metrics — tokens in failed/killed sessions
	if [[ -f "$HEADLESS_METRICS" ]]; then
		tokens_wasted_on_stalls=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"result":"([^"]+)"/, res)
				match($0, /"tokens_total":([0-9]+)/, tok)
				if (ts[1]+0 >= s && ts[1]+0 < e &&
					(res[1] == "watchdog_killed" || res[1] == "stalled" || res[1] == "provider_error")) {
					wasted += tok[1]+0
				}
			}
			END { print wasted+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		tokens_wasted_on_stalls=$(safe_int "$tokens_wasted_on_stalls")
	fi

	cat <<EOF
"token_efficiency": {
    "supervisor_tokens_per_cycle": ${supervisor_tokens_per_cycle},
    "worker_tokens_per_issue": ${worker_tokens_per_issue},
    "tokens_wasted_on_stalls": ${tokens_wasted_on_stalls},
    "llm_skip_rate_pct": ${llm_skip_rate},
    "total_requests": ${total_requests},
    "total_tokens": ${total_tokens},
    "total_cost_usd": ${total_cost}
  }
EOF
	return 0
}

# --- Speed ---

collect_speed() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local preflight_duration_avg=0
	# dispatch_to_first_output_avg: not yet instrumented — requires correlating
	# dispatch timestamps with first log output timestamps. Emitted as null
	# until a dedicated data source is available.
	local dispatch_to_first_output_avg="null"
	local worker_completion_p50=0
	local worker_completion_p90=0
	local worker_completion_p99=0

	# Worker completion times from headless metrics
	if [[ -f "$HEADLESS_METRICS" ]]; then
		local durations
		durations=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"result":"success"/, res)
				match($0, /"duration_ms":([0-9]+)/, dur)
				if (ts[1]+0 >= s && ts[1]+0 < e && res[0] != "" && dur[1]+0 > 0) {
					print dur[1]/1000
				}
			}' "$HEADLESS_METRICS" 2>/dev/null | sort -n)

		if [[ -n "$durations" ]]; then
			local count
			count=$(echo "$durations" | wc -l | tr -d ' ')
			count=$(safe_int "$count")
			if [[ "$count" -gt 0 ]]; then
				local p50_idx p90_idx p99_idx
				p50_idx=$(((count * 50 / 100) + 1))
				p90_idx=$(((count * 90 / 100) + 1))
				p99_idx=$(((count * 99 / 100) + 1))
				worker_completion_p50=$(echo "$durations" | sed -n "${p50_idx}p" | tr -d ' ')
				worker_completion_p90=$(echo "$durations" | sed -n "${p90_idx}p" | tr -d ' ')
				worker_completion_p99=$(echo "$durations" | sed -n "${p99_idx}p" | tr -d ' ')
				worker_completion_p50=$(safe_float "${worker_completion_p50:-0}")
				worker_completion_p90=$(safe_float "${worker_completion_p90:-0}")
				worker_completion_p99=$(safe_float "${worker_completion_p99:-0}")
			fi
		fi
	fi

	# Preflight duration from pulse log (grep for preflight timing lines)
	if [[ -f "$PULSE_LOG" ]]; then
		local preflight_times
		preflight_times=$(grep -a "preflight.*duration\|preflight.*seconds\|preflight.*elapsed" "$PULSE_LOG" |
			awk -v date="$date" '$0 ~ date {
				line = $0
				while (match(line, /[0-9][0-9.]*s/)) {
					value = substr(line, RSTART, RLENGTH - 1)
					if (value ~ /^[0-9]+([.][0-9]+)?$/) print value
					line = substr(line, RSTART + RLENGTH)
				}
			}' |
			sort -n || true)
		if [[ -n "$preflight_times" ]]; then
			local pf_count
			pf_count=$(echo "$preflight_times" | wc -l | tr -d ' ')
			pf_count=$(safe_int "$pf_count")
			if [[ "$pf_count" -gt 0 ]]; then
				preflight_duration_avg=$(echo "$preflight_times" | awk '{sum+=$1} END {printf "%.1f", sum/NR}' 2>/dev/null || echo "0")
			fi
		fi
	fi

	cat <<EOF
"speed": {
    "preflight_duration_avg_secs": ${preflight_duration_avg},
    "dispatch_to_first_output_avg_secs": ${dispatch_to_first_output_avg},
    "worker_completion_p50_secs": ${worker_completion_p50},
    "worker_completion_p90_secs": ${worker_completion_p90},
    "worker_completion_p99_secs": ${worker_completion_p99}
  }
EOF
	return 0
}

# --- Concurrency ---

collect_concurrency() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local avg_active=0
	local peak_active=0
	local min_active=0
	local fill_rate_pct=0
	local slots_lost_to_rate_limits=0
	local backoff_duration_total_secs=0
	local max_workers=0

	# Read max workers from pulse-health.json (most recent)
	if [[ -f "$PULSE_HEALTH" ]] && command -v jq &>/dev/null; then
		max_workers=$(jq -r '.workers_max // 0' "$PULSE_HEALTH" 2>/dev/null || echo "0")
		max_workers=$(safe_int "$max_workers")
	fi

	# Worker concurrency from headless metrics — count concurrent workers per minute
	if [[ -f "$HEADLESS_METRICS" ]] && [[ "$max_workers" -gt 0 ]]; then
		# Count dispatched workers in the date window
		local dispatched_count
		dispatched_count=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"role":"worker"/, role)
				if (ts[1]+0 >= s && ts[1]+0 < e && role[0] != "") count++
			}
			END { print count+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		dispatched_count=$(safe_int "$dispatched_count")

		# Estimate fill rate: dispatched / (max_workers * hours_in_day)
		# Each worker slot can handle ~1 issue/hour on average
		local available_slots=$((max_workers * 24))
		if [[ "$available_slots" -gt 0 ]]; then
			fill_rate_pct=$(echo "scale=1; $dispatched_count * 100 / $available_slots" | bc 2>/dev/null || echo "0")
		fi
	fi

	# Backoff duration from headless-runtime-helper backoff DB
	local backoff_db
	backoff_db=$(find "${HOME}/.aidevops/.agent-workspace" -name "*.db" -path "*/headless-runtime/*" 2>/dev/null | head -1 || echo "")
	if [[ -z "$backoff_db" ]]; then
		# Try the headless-runtime-helper's default DB path
		backoff_db="${HOME}/.aidevops/.agent-workspace/headless-runtime/headless-runtime.db"
	fi

	if [[ -f "$backoff_db" ]] && command -v sqlite3 &>/dev/null; then
		backoff_duration_total_secs=$(sqlite3 "$backoff_db" \
			"SELECT COALESCE(SUM(
				CAST(strftime('%s', retry_after) AS INTEGER) - CAST(strftime('%s', updated_at) AS INTEGER)
			), 0)
			FROM provider_backoff
			WHERE updated_at >= datetime($start_epoch, 'unixepoch')
			  AND updated_at < datetime($end_epoch, 'unixepoch')
			  AND CAST(strftime('%s', retry_after) AS INTEGER) > CAST(strftime('%s', updated_at) AS INTEGER);" \
			2>/dev/null || echo "0")
		backoff_duration_total_secs=$(safe_int "$backoff_duration_total_secs")
	fi

	# Slots lost to rate limits: estimate from backoff duration / avg_worker_duration
	local avg_worker_duration=1800 # 30 min default
	if [[ "$avg_worker_duration" -gt 0 && "$backoff_duration_total_secs" -gt 0 ]]; then
		slots_lost_to_rate_limits=$(echo "scale=1; $backoff_duration_total_secs / $avg_worker_duration" | bc 2>/dev/null || echo "0")
	fi

	# Peak active workers from pulse-health.json snapshots in logs
	if [[ -f "$PULSE_LOG" ]]; then
		peak_active=$(grep -a "workers=" "$PULSE_LOG" 2>/dev/null |
			awk -v date="$date" '$0 ~ date {
				match($0, /workers=([0-9]+)\//, w)
				if (w[1]+0 > peak) peak = w[1]+0
			}
			END { print peak+0 }' 2>/dev/null || echo "0")
		peak_active=$(safe_int "$peak_active")
	fi

	cat <<EOF
"concurrency": {
    "avg_active_workers": ${avg_active},
    "peak_active_workers": ${peak_active},
    "min_active_workers": ${min_active},
    "max_workers_cap": ${max_workers},
    "fill_rate_pct": ${fill_rate_pct},
    "slots_lost_to_rate_limits": ${slots_lost_to_rate_limits},
    "backoff_duration_total_secs": ${backoff_duration_total_secs}
  }
EOF
	return 0
}

# --- Resources ---

collect_resources() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local peak_worker_memory_mb=0
	local total_pulse_cpu_pct=0
	local idle_worker_cpu_waste_pct=0
	local cpu_seconds_per_success=0
	local peak_rss_mb=0
	local avg_rss_mb=0
	local top_resource_consumers='[]'

	# Memory from ps snapshots in pulse log
	if [[ -f "$PULSE_LOG" ]]; then
		peak_worker_memory_mb=$(grep -a "RSS\|rss\|memory.*MB\|MB.*memory" "$PULSE_LOG" 2>/dev/null |
			awk -v date="$date" '$0 ~ date {
				match($0, /([0-9]+)MB/, m)
				if (m[1]+0 > peak) peak = m[1]+0
			}
			END { print peak+0 }' 2>/dev/null || echo "0")
		peak_worker_memory_mb=$(safe_int "$peak_worker_memory_mb")
	fi

	if [[ -f "$RESOURCE_METRICS" ]]; then
		local resource_summary
		resource_summary=$(RESOURCE_METRICS_PATH="$RESOURCE_METRICS" START_EPOCH="$start_epoch" END_EPOCH="$end_epoch" python3 - <<'PY' 2>/dev/null || printf '{}'
import json
import os

path = os.environ["RESOURCE_METRICS_PATH"]
start = int(os.environ["START_EPOCH"])
end = int(os.environ["END_EPOCH"])
records = []
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        ts = int(rec.get("ts") or 0)
        if start <= ts < end:
            records.append(rec)

total_cpu = sum(float(r.get("cpu_seconds") or 0) for r in records)
successes = [r for r in records if str(r.get("result") or "") in {"success", "completed", "merged"}]
success_count = len(successes)
peak_rss_kb = max([int(r.get("peak_rss_kb") or r.get("rss_kb") or 0) for r in records] or [0])
avg_rss_values = [int(r.get("avg_rss_kb") or r.get("rss_kb") or 0) for r in records]
avg_rss_kb = int(sum(avg_rss_values) / len(avg_rss_values)) if avg_rss_values else 0
top = sorted(records, key=lambda r: (float(r.get("cpu_seconds") or 0), int(r.get("peak_rss_kb") or 0)), reverse=True)[:5]
print(json.dumps({
    "cpu_seconds_per_success": round(total_cpu / success_count, 3) if success_count else 0,
    "peak_rss_mb": round(peak_rss_kb / 1024, 2),
    "avg_rss_mb": round(avg_rss_kb / 1024, 2),
    "top_resource_consumers": [
        {
            "role": r.get("role", ""),
            "session_key": r.get("session_key", ""),
            "repo": r.get("repo", ""),
            "issue": r.get("issue", ""),
            "result": r.get("result", ""),
            "cpu_seconds": round(float(r.get("cpu_seconds") or 0), 3),
            "peak_rss_mb": round(int(r.get("peak_rss_kb") or 0) / 1024, 2),
            "elapsed_s": int(r.get("elapsed_s") or 0),
        }
        for r in top
    ],
}))
PY
		)
		cpu_seconds_per_success=$(printf '%s' "$resource_summary" | jq -r '.cpu_seconds_per_success // 0' 2>/dev/null || printf '0')
		peak_rss_mb=$(printf '%s' "$resource_summary" | jq -r '.peak_rss_mb // 0' 2>/dev/null || printf '0')
		avg_rss_mb=$(printf '%s' "$resource_summary" | jq -r '.avg_rss_mb // 0' 2>/dev/null || printf '0')
		top_resource_consumers=$(printf '%s' "$resource_summary" | jq -c '.top_resource_consumers // []' 2>/dev/null || printf '[]')
	fi

	cat <<EOF
"resources": {
    "peak_worker_memory_mb": ${peak_worker_memory_mb},
    "total_pulse_cpu_overhead_pct": ${total_pulse_cpu_pct},
    "idle_worker_cpu_waste_pct": ${idle_worker_cpu_waste_pct},
    "cpu_seconds_per_success": ${cpu_seconds_per_success},
    "peak_rss_mb": ${peak_rss_mb},
    "avg_rss_mb": ${avg_rss_mb},
    "top_resource_consumers": ${top_resource_consumers}
  }
EOF
	return 0
}

# --- Errors ---

collect_errors() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local launch_failure_count=0
	local launch_total=0
	local launch_failure_rate=0
	local watchdog_kills_activity=0
	local watchdog_kills_stalled=0
	local false_backoff_count=0
	local auth_rotation_events=0
	local provider_error_count=0

	# From headless metrics
	if [[ -f "$HEADLESS_METRICS" ]]; then
		launch_failure_count=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"result":"([^"]+)"/, res)
				if (ts[1]+0 >= s && ts[1]+0 < e) {
					total++
					if (res[1] == "launch_failed" || res[1] == "failed") failed++
				}
			}
			END { print failed+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		launch_total=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				if (ts[1]+0 >= s && ts[1]+0 < e) total++
			}
			END { print total+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		provider_error_count=$(awk -v s="$start_epoch" -v e="$end_epoch" \
			'$0 ~ "\"ts\"" {
				match($0, /"ts":([0-9]+)/, ts)
				match($0, /"result":"provider_error"/, res)
				if (ts[1]+0 >= s && ts[1]+0 < e && res[0] != "") count++
			}
			END { print count+0 }' "$HEADLESS_METRICS" 2>/dev/null || echo "0")
		launch_failure_count=$(safe_int "$launch_failure_count")
		launch_total=$(safe_int "$launch_total")
		provider_error_count=$(safe_int "$provider_error_count")
		if [[ "$launch_total" -gt 0 ]]; then
			launch_failure_rate=$(echo "scale=4; $launch_failure_count * 100 / $launch_total" | bc 2>/dev/null || echo "0")
		fi
	fi

	# Watchdog kills from pulse log — filter by date prefix in log lines
	if [[ -f "$PULSE_LOG" ]]; then
		watchdog_kills_activity=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			grep -ac "activity.*kill\|idle.*kill\|CPU.*kill" 2>/dev/null || echo "0")
		watchdog_kills_stalled=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			grep -ac "stall.*kill\|progress.*stall.*kill\|stalled.*kill" 2>/dev/null || echo "0")
		auth_rotation_events=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			grep -ac "auth.*rotat\|pool.*rotat\|credential.*rotat" 2>/dev/null || echo "0")
		watchdog_kills_activity=$(safe_int "$watchdog_kills_activity")
		watchdog_kills_stalled=$(safe_int "$watchdog_kills_stalled")
		auth_rotation_events=$(safe_int "$auth_rotation_events")
	fi

	cat <<EOF
"errors": {
    "launch_failure_count": ${launch_failure_count},
    "launch_failure_rate_pct": ${launch_failure_rate},
    "watchdog_kills_activity": ${watchdog_kills_activity},
    "watchdog_kills_stalled": ${watchdog_kills_stalled},
    "false_backoff_count": ${false_backoff_count},
    "auth_rotation_events": ${auth_rotation_events},
    "provider_error_count": ${provider_error_count}
  }
EOF
	return 0
}

# --- Clash protection ---

collect_clash_protection() {
	local date="$1"

	local worktree_conflicts=0
	local auth_mutations=0
	local duplicate_dispatch_blocked=0

	# Worktree conflicts from registry DB
	if [[ -f "$WORKTREE_REGISTRY" ]] && command -v sqlite3 &>/dev/null; then
		worktree_conflicts=$(sqlite3 "$WORKTREE_REGISTRY" \
			"SELECT COUNT(*) FROM worktree_owners
			 WHERE created_at >= '${date}T00:00:00Z'
			   AND created_at < '${date}T23:59:59Z';" \
			2>/dev/null || echo "0")
		worktree_conflicts=$(safe_int "$worktree_conflicts")
	fi

	# Duplicate dispatch blocked from dispatch ledger
	if [[ -f "$DISPATCH_LEDGER" ]]; then
		duplicate_dispatch_blocked=$(grep -c "\"status\":\"blocked\"\|\"status\":\"dedup\"" "$DISPATCH_LEDGER" 2>/dev/null || echo "0")
		duplicate_dispatch_blocked=$(safe_int "$duplicate_dispatch_blocked")
	fi

	# Auth mutations from pulse log — filter by date prefix in log lines
	if [[ -f "$PULSE_LOG" ]]; then
		auth_mutations=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			grep -ac "auth.*mutate\|auth.*file.*change\|credential.*change" 2>/dev/null || echo "0")
		auth_mutations=$(safe_int "$auth_mutations")
	fi

	cat <<EOF
"clash_protection": {
    "worktree_conflicts_detected": ${worktree_conflicts},
    "auth_file_mutations": ${auth_mutations},
    "duplicate_dispatch_blocked": ${duplicate_dispatch_blocked}
  }
EOF
	return 0
}

# --- Audit trails ---

collect_audit_trails() {
	local date="$1"
	local start_epoch end_epoch
	start_epoch=$(date_to_epoch "${date}")
	end_epoch=$((start_epoch + 86400))

	local issues_closed_without_pr=0
	local prs_merged_without_closing_comment=0
	local prs_without_merge_summary=0
	local orphaned_branches=0

	# Query GitHub API for issues closed today without a linked PR
	if command -v gh &>/dev/null; then
		local repos_json
		repos_json="${HOME}/.config/aidevops/repos.json"
		if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
			local pulse_repos
			pulse_repos=$(jq -r '.initialized_repos[]? | select(.maintenance != false and .pulse == true and .local_only != true) | .slug' "$repos_json" 2>/dev/null || echo "")
			while IFS= read -r repo_slug; do
				[[ -z "$repo_slug" ]] && continue
				# Issues closed today
				local closed_issues
				closed_issues=$(gh issue list --repo "$repo_slug" \
					--state closed \
					--json number,closedAt,body \
					--jq "[.[] | select(.closedAt >= \"${date}T00:00:00Z\" and .closedAt < \"${date}T23:59:59Z\") | select(.body | test(\"PR #|pull request|#[0-9]+\"; \"i\") | not)] | length" \
					2>/dev/null || echo "0")
				issues_closed_without_pr=$((issues_closed_without_pr + $(safe_int "$closed_issues")))

				# PRs merged today without MERGE_SUMMARY comment
				local merged_prs_no_summary
				merged_prs_no_summary=$(gh pr list --repo "$repo_slug" \
					--state merged \
					--json number,mergedAt,body \
					--jq "[.[] | select(.mergedAt >= \"${date}T00:00:00Z\" and .mergedAt < \"${date}T23:59:59Z\") | select(.body | test(\"MERGE_SUMMARY\"; \"i\") | not)] | length" \
					2>/dev/null || echo "0")
				prs_without_merge_summary=$((prs_without_merge_summary + $(safe_int "$merged_prs_no_summary")))
			done <<<"$pulse_repos"
		fi
	fi

	cat <<EOF
"audit_trails": {
    "issues_closed_without_pr_link": ${issues_closed_without_pr},
    "prs_merged_without_closing_comment": ${prs_merged_without_closing_comment},
    "prs_without_merge_summary": ${prs_without_merge_summary},
    "orphaned_branches": ${orphaned_branches}
  }
EOF
	return 0
}

# --- Throughput ---

collect_throughput() {
	local date="$1"

	local issues_opened=0
	local issues_closed=0
	local prs_opened=0
	local prs_merged=0
	local prs_closed_conflicting=0
	local net_backlog_delta=0

	# Aggregate from pulse log for the target date (date-filtered, not snapshot)
	if [[ -f "$PULSE_LOG" ]]; then
		local day_merged day_conflicting day_dispatched
		day_merged=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			awk '{
				match($0, /merged=([0-9]+)/, m)
				if (m[1]+0 > 0) sum += m[1]+0
			}
			END { print sum+0 }' 2>/dev/null || echo "0")
		day_conflicting=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			awk '{
				match($0, /closed_conflicting=([0-9]+)/, m)
				if (m[1]+0 > 0) sum += m[1]+0
			}
			END { print sum+0 }' 2>/dev/null || echo "0")
		day_dispatched=$(grep -a "\[${date}" "$PULSE_LOG" 2>/dev/null |
			awk '{
				match($0, /dispatched=([0-9]+)/, m)
				if (m[1]+0 > 0) sum += m[1]+0
			}
			END { print sum+0 }' 2>/dev/null || echo "0")
		prs_merged=$(safe_int "$day_merged")
		prs_closed_conflicting=$(safe_int "$day_conflicting")
		issues_opened=$(safe_int "$day_dispatched")
	fi

	# Issues closed: from dispatch ledger — count completed entries for the date
	if [[ -f "$DISPATCH_LEDGER" ]]; then
		issues_closed=$(awk -v date="$date" \
			'$0 ~ "\"status\":\"completed\"" {
				match($0, /"updated_at":"([^"]+)"/, ts)
				if (ts[1] ~ date) count++
			}
			END { print count+0 }' "$DISPATCH_LEDGER" 2>/dev/null || echo "0")
		issues_closed=$(safe_int "$issues_closed")
	fi

	net_backlog_delta=$((issues_opened - issues_closed))

	cat <<EOF
"throughput": {
    "issues_opened": ${issues_opened},
    "issues_closed": ${issues_closed},
    "prs_opened": ${prs_opened},
    "prs_merged": ${prs_merged},
    "prs_closed_conflicting": ${prs_closed_conflicting},
    "net_backlog_delta": ${net_backlog_delta}
  }
EOF
	return 0
}

# --- Historical comparison ---

collect_historical_context() {
	local date="$1"
	local report_dir="$2"

	local yesterday_report=""
	local week_ago_report=""
	local has_yesterday=false
	local has_week_ago=false

	# Find yesterday's report
	local yesterday
	if date --version >/dev/null 2>&1; then
		yesterday=$(date -u -d "${date} -1 day" +%Y-%m-%d 2>/dev/null || echo "")
	else
		yesterday=$(date -u -v-1d -j -f "%Y-%m-%d" "$date" +%Y-%m-%d 2>/dev/null || echo "")
	fi

	if [[ -n "$yesterday" && -f "${report_dir}/efficiency-report-${yesterday}.json" ]]; then
		has_yesterday=true
		yesterday_report="${report_dir}/efficiency-report-${yesterday}.json"
	fi

	# Find 7-day-ago report
	local week_ago
	if date --version >/dev/null 2>&1; then
		week_ago=$(date -u -d "${date} -7 days" +%Y-%m-%d 2>/dev/null || echo "")
	else
		week_ago=$(date -u -v-7d -j -f "%Y-%m-%d" "$date" +%Y-%m-%d 2>/dev/null || echo "")
	fi

	if [[ -n "$week_ago" && -f "${report_dir}/efficiency-report-${week_ago}.json" ]]; then
		has_week_ago=true
		week_ago_report="${report_dir}/efficiency-report-${week_ago}.json"
	fi

	cat <<EOF
"historical_context": {
    "has_yesterday_report": ${has_yesterday},
    "yesterday_report_path": "${yesterday_report}",
    "has_week_ago_report": ${has_week_ago},
    "week_ago_report_path": "${week_ago_report}"
  }
EOF
	return 0
}

# =============================================================================
# Report retention cleanup
# =============================================================================

cleanup_old_reports() {
	local report_dir="$1"
	local retention_days="$2"

	if date --version >/dev/null 2>&1; then
		# GNU find with -mtime
		find "$report_dir" -name "efficiency-report-*.json" -mtime "+${retention_days}" -delete 2>/dev/null || true
	else
		# macOS find
		find "$report_dir" -name "efficiency-report-*.json" -mtime "+${retention_days}" -delete 2>/dev/null || true
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	parse_args "$@"

	local target_date="${TARGET_DATE:-$(get_today)}"
	local report_dir="$LOGS_DIR"
	local output_file="${OUTPUT_FILE:-${report_dir}/efficiency-report-${target_date}.json}"

	log_info "Collecting orchestration efficiency metrics for ${target_date}"

	# Ensure output directory exists
	mkdir -p "$report_dir" 2>/dev/null || true

	# Collect all metric categories
	log_info "Collecting token efficiency..."
	local token_efficiency
	token_efficiency=$(collect_token_efficiency "$target_date")

	log_info "Collecting speed metrics..."
	local speed
	speed=$(collect_speed "$target_date")

	log_info "Collecting concurrency metrics..."
	local concurrency
	concurrency=$(collect_concurrency "$target_date")

	log_info "Collecting resource metrics..."
	local resources
	resources=$(collect_resources "$target_date")

	log_info "Collecting error metrics..."
	local errors
	errors=$(collect_errors "$target_date")

	log_info "Collecting clash protection metrics..."
	local clash_protection
	clash_protection=$(collect_clash_protection "$target_date")

	log_info "Collecting audit trail metrics..."
	local audit_trails
	audit_trails=$(collect_audit_trails "$target_date")

	log_info "Collecting throughput metrics..."
	local throughput
	throughput=$(collect_throughput "$target_date")

	log_info "Collecting historical context..."
	local historical_context
	historical_context=$(collect_historical_context "$target_date" "$report_dir")

	# Assemble the full JSON report
	local report_json
	report_json=$(
		cat <<EOF
{
  "report_date": "${target_date}",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "collector_version": "1.0.0",
  ${token_efficiency},
  ${speed},
  ${concurrency},
  ${resources},
  ${errors},
  ${clash_protection},
  ${audit_trails},
  ${throughput},
  ${historical_context}
}
EOF
	)

	# Validate JSON if jq is available
	if command -v jq &>/dev/null; then
		if ! echo "$report_json" | jq . >/dev/null 2>&1; then
			log_error "Generated report is not valid JSON — check metric collection functions"
			# Write raw output for debugging
			echo "$report_json" >"${output_file}.invalid"
			exit 1
		fi
		# Pretty-print the validated JSON
		echo "$report_json" | jq . >"$output_file"
	else
		echo "$report_json" >"$output_file"
	fi

	log_info "Report written to: ${output_file}"

	# Cleanup old reports
	cleanup_old_reports "$report_dir" "$REPORT_RETENTION_DAYS"
	log_info "Cleaned up reports older than ${REPORT_RETENTION_DAYS} days"

	echo "$output_file"
	return 0
}

main "$@"
