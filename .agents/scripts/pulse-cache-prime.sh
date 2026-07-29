#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-cache-prime.sh (t2992) — pre-warm pulse caches before restart.
#
# When `aidevops update` deploys new code, the pulse restarts and its first
# cycle pays the full cold-cache cost, including ~210s prefetch_state. Before
# GH#28880, cross-repository label maintenance also held the first worker fill
# for ~144s; the initial fill now runs before that maintenance. This script
# still pre-warms the L3 per-owner JSON caches via
# pulse-batch-prefetch-helper.sh refresh, so the remaining cycle's
# prefetch_state finds warm state and runs the delta path (t1975 architecture —
# only fetches items with updatedAt > last_prefetch).
#
# Wired into pulse-lifecycle-helper.sh::_start so every restart path
# (aidevops update, setup.sh, manual restart, t2914 ensure-running)
# primes before the pulse boots. Early-return-if-running gate in
# _start makes this a no-op when pulse is already alive.
#
# Standalone use:   pulse-cache-prime.sh
# Skip:             AIDEVOPS_SKIP_CACHE_PRIME=1 pulse-cache-prime.sh
#
# Exit codes:
#   0 - Success or skipped via env opt-out
#   1 - Refresh failed (caller logs but should not abort restart)
#
# Logs to ~/.aidevops/logs/pulse-cache-prime.log.
# Sentinel file: ~/.aidevops/cache/pulse-cache-prime-last-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${HOME}/.aidevops/logs"
LOG_FILE="${LOG_DIR}/pulse-cache-prime.log"
CACHE_DIR="${HOME}/.aidevops/cache"
SENTINEL="${CACHE_DIR}/pulse-cache-prime-last-run"
PRIME_HELPER="${SCRIPT_DIR}/pulse-batch-prefetch-helper.sh"
STATS_HELPER="${SCRIPT_DIR}/pulse-stats-helper.sh"

mkdir -p "$LOG_DIR" "$CACHE_DIR" 2>/dev/null || true

_log() {
	local msg="$1"
	local timestamp; timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || timestamp="unknown"
	printf '[%s] %s\n' "$timestamp" "$msg" >>"$LOG_FILE" || true
	return 0
}

_increment_counter() {
	local counter_name="$1"
	[[ -f "$STATS_HELPER" ]] || return 0
	# shellcheck disable=SC1090
	source "$STATS_HELPER" 2>/dev/null || return 0
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "$counter_name" 2>/dev/null || true
	fi
	return 0
}

main() {
	if [[ "${AIDEVOPS_SKIP_CACHE_PRIME:-0}" == "1" ]]; then
		_log "AIDEVOPS_SKIP_CACHE_PRIME=1 — skipping cache prime"
		return 0
	fi

	if [[ ! -x "$PRIME_HELPER" ]]; then
		_log "ERROR: pulse-batch-prefetch-helper.sh not found or not executable: $PRIME_HELPER"
		_increment_counter "pulse_cache_prime_failures"
		return 1
	fi

	local start_t="" end_t="" duration=""
	start_t=$(date +%s 2>/dev/null) || start_t=0

	_log "Starting cache prime (t2992)..."

	if "$PRIME_HELPER" refresh >>"$LOG_FILE" 2>&1; then
		end_t=$(date +%s 2>/dev/null) || end_t=$start_t
		duration=$((end_t - start_t))
		_log "Cache prime succeeded in ${duration}s"
		date -u +'%Y-%m-%dT%H:%M:%SZ' >"$SENTINEL" 2>/dev/null || true
		_increment_counter "pulse_cache_prime_runs"
		return 0
	fi

	end_t=$(date +%s 2>/dev/null) || end_t=$start_t
	duration=$((end_t - start_t))
	_log "Cache prime FAILED after ${duration}s"
	_increment_counter "pulse_cache_prime_failures"
	return 1
}

main "$@"
