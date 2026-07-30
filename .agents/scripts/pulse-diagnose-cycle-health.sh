#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse Diagnose Cycle Health — parsing and aggregation helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_DIAGNOSE_CYCLE_HEALTH_LOADED:-}" ]] && return 0
_PULSE_DIAGNOSE_CYCLE_HEALTH_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

_CMD_CH_WINDOW_SECS=3600
_CMD_CH_JSON_OUTPUT=0
_CMD_CH_VERBOSE=0
_CH_DEGRADED="DEGRADED"

_ch_parse_window_secs() {
	local raw="$1"
	case "$raw" in
		*m) printf '%d' "$(( ${raw%m} * 60 ))" ;;
		*h) printf '%d' "$(( ${raw%h} * 3600 ))" ;;
		*d) printf '%d' "$(( ${raw%d} * 86400 ))" ;;
		'') printf '%d' 3600 ;;
		*) printf '%d' "$raw" ;;
	esac
	return 0
}

# Return the current epoch, with a validated test-only clock override.
_ch_now_epoch() {
	local override="${PULSE_DIAGNOSE_NOW_EPOCH:-}"
	local now_epoch=""
	if [[ -n "$override" ]]; then
		if [[ "$override" =~ ^[0-9]+$ ]]; then
			printf '%s' "$override"
			return 0
		fi
		printf 'warning: ignoring invalid PULSE_DIAGNOSE_NOW_EPOCH override\n' >&2
	fi
	now_epoch=$(date '+%s' 2>/dev/null) || now_epoch=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	printf '%s' "$now_epoch"
	return 0
}

# Compute ISO 8601 UTC cutoff timestamp (window_secs ago from now).
# Tries macOS date -r syntax first; falls back to GNU date -d.
_ch_cutoff_ts() {
	local window_secs="${1:-3600}"
	local ts="" now_epoch="" cutoff_epoch=""
	[[ "$window_secs" =~ ^[0-9]+$ ]] || window_secs=3600
	now_epoch=$(_ch_now_epoch)
	cutoff_epoch=$(( now_epoch - window_secs ))
	if ts=$(date -u -r "$cutoff_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		printf '%s' "$ts"
		return 0
	fi
	if ts=$(date -u -d "@$cutoff_epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); then
		printf '%s' "$ts"
		return 0
	fi
	printf '1970-01-01T00:00:00Z'
	return 0
}

_ch_ts_ago() {
	local ts="$1"
	[[ -z "$ts" ]] && { printf 'never'; return 0; }
	local ts_epoch="" now_epoch="" diff=""
	ts_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null) ||
		ts_epoch=$(date -u -d "$ts" '+%s' 2>/dev/null) || { printf '%s' "$ts"; return 0; }
	now_epoch=$(_ch_now_epoch) || { printf '%s' "$ts"; return 0; }
	diff=$(( now_epoch - ts_epoch ))
	if [[ "$diff" -lt 60 ]]; then
		printf '%ds ago' "$diff"
	elif [[ "$diff" -lt 3600 ]]; then
		printf '%dm ago' "$(( diff / 60 ))"
	elif [[ "$diff" -lt 86400 ]]; then
		printf '%dh ago' "$(( diff / 3600 ))"
	else
		printf '%dd ago' "$(( diff / 86400 ))"
	fi
	return 0
}

_cmd_cycle_health_parse_args() {
	_CMD_CH_WINDOW_SECS=3600
	_CMD_CH_JSON_OUTPUT=0
	_CMD_CH_VERBOSE=0
	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--window)
				local raw="${2:-1h}"
				shift 2
				_CMD_CH_WINDOW_SECS=$(_ch_parse_window_secs "$raw")
				;;
			--json) _CMD_CH_JSON_OUTPUT=1; shift ;;
			--verbose) _CMD_CH_VERBOSE=1; shift ;;
			-*) print_error "unknown option: ${1}"; return 1 ;;
			*) shift ;;
		esac
	done
	return 0
}

_ch_stage_stats() {
	local timings_file="$1"
	local cutoff_ts="$2"
	[[ -f "$timings_file" ]] || return 0
	awk -v cutoff="$cutoff_ts" '
	{
		nf=split($0, f, "\t")
		if (nf < 5 || f[1] < cutoff) next
		# Fields 1-5 are the legacy schema. Field 6 optionally identifies the
		# executor, but field 5 remains the cycle-owner aggregation key.
		ts=f[1]; stage=f[2]; dur=f[3]+0; rc=f[4]+0
		cnt[stage]++
		if (rc==124) to[stage]++
		if (rc==0 && ts > last_ok[stage]) last_ok[stage]=ts
		n=cnt[stage]; d[stage,n]=dur
	}
	END {
		for (stage in cnt) {
			n=cnt[stage]
			for (i=2;i<=n;i++) {
				key=d[stage,i]; j=i-1
				while (j>=1 && d[stage,j]>key) { d[stage,j+1]=d[stage,j]; j-- }
				d[stage,j+1]=key
			}
			p50_i=int(n*0.50)+1; if(p50_i>n)p50_i=n
			p95_i=int(n*0.95)+1; if(p95_i>n)p95_i=n
			t=(to[stage]+0)
			deg=(n>0 && (t/n)>0.50) ? "DEGRADED" : "ok"
			printf "%s\t%d\t%d\t%d\t%d\t%s\t%s\n", stage, n, t, d[stage,p50_i], d[stage,p95_i], (last_ok[stage]?last_ok[stage]:"-"), deg
		}
	}' "$timings_file" 2>/dev/null | sort -t"	" -k1,1
	return 0
}

_ch_cycle_stats() {
	local timings_file="$1"
	local cutoff_ts="$2"
	if [[ ! -f "$timings_file" ]]; then
		printf 'cycles_started=0\nfill_floor_cycles=0\ncycles_since_ff=0\nlast_ff_ts=\n'
		return 0
	fi
	awk -v cutoff="$cutoff_ts" '
	{
		nf=split($0, f, "\t")
		if (nf < 5 || f[1] < cutoff) next
		ts=f[1]; stage=f[2]; rc=f[4]+0; owner_pid=f[5]
		owners[owner_pid]=1
		if (!owner_first[owner_pid] || ts < owner_first[owner_pid]) owner_first[owner_pid]=ts
		if (stage=="preflight_early_dispatch" && rc==0) {
			ff[owner_pid]=1
			if (ts > last_ff_ts) { last_ff_ts=ts; last_ff_owner=owner_pid }
		}
	}
	END {
		total=0; ff_count=0; since_ff=0
		for (owner_pid in owners) total++
		for (owner_pid in ff) ff_count++
		if (last_ff_ts) {
			for (owner_pid in owners) if (!(owner_pid in ff) && owner_first[owner_pid]>last_ff_ts) since_ff++
		} else since_ff=total
		printf "cycles_started=%d\nfill_floor_cycles=%d\ncycles_since_ff=%d\nlast_ff_ts=%s\n", total, ff_count, since_ff, last_ff_ts
	}' "$timings_file" 2>/dev/null
	return 0
}

_ch_wrapper_churn() {
	local wrapper_log="$1"
	if [[ ! -f "$wrapper_log" ]]; then
		printf 'acquired=0\nexited_early=0\nchurn_pct=0\n'
		return 0
	fi
	local acquired="0" exited_early="0" total="0" churn_pct="0"
	acquired=$(grep -c -- 'Instance lock acquired via mkdir' "$wrapper_log" 2>/dev/null) || acquired=0
	exited_early=$(grep -c -- 'Another pulse instance holds the mkdir lock' "$wrapper_log" 2>/dev/null) || exited_early=0
	total=$(( acquired + exited_early ))
	[[ "$total" -gt 0 ]] && churn_pct=$(( exited_early * 100 / total ))
	printf 'acquired=%d\nexited_early=%d\nchurn_pct=%d\n' "$acquired" "$exited_early" "$churn_pct"
	return 0
}
