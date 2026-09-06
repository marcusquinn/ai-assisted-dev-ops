#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

export HOME="${TMP_DIR}/home"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/cache"

TIMEOUT_CALL_LOG="${TMP_DIR}/timeout-calls.log"
export TIMEOUT_CALL_LOG

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../pulse-rate-limit-circuit-breaker.sh"

_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '_gh_with_timeout %s %s\n' "$op_class" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ "$op_class" == "read" && "$*" == "gh api rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":4000,"limit":5000},"core":{"remaining":4999,"limit":5000}}}\n'
		return 0
	fi
	return 1
}

rate_json="$(_cb_rate_limit_json normal)"
if [[ "$rate_json" != *'"remaining":4000'* ]]; then
	printf 'FAIL: expected rate_limit JSON from _gh_with_timeout, got: %s\n' "$rate_json" >&2
	exit 1
fi
if ! grep -q '_gh_with_timeout read gh api rate_limit' "$TIMEOUT_CALL_LOG"; then
	printf 'FAIL: _cb_rate_limit_json did not call _gh_with_timeout read gh api rate_limit\n' >&2
	exit 1
fi

rm -f "$TIMEOUT_CALL_LOG" "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
unset -f _gh_with_timeout

timeout_sec() {
	local secs="$1"
	shift
	printf 'timeout_sec %s %s\n' "$secs" "$*" >>"$TIMEOUT_CALL_LOG"
	if [[ "$*" == "gh api rate_limit" ]]; then
		printf '{"resources":{"graphql":{"remaining":3000,"limit":5000},"core":{"remaining":4999,"limit":5000}}}\n'
		return 0
	fi
	return 1
}

rate_json="$(_cb_rate_limit_json normal)"
if [[ "$rate_json" != *'"remaining":3000'* ]]; then
	printf 'FAIL: expected rate_limit JSON from timeout_sec fallback, got: %s\n' "$rate_json" >&2
	exit 1
fi
if ! grep -q 'timeout_sec 15 gh api rate_limit' "$TIMEOUT_CALL_LOG"; then
	printf 'FAIL: _cb_rate_limit_json did not call timeout_sec fallback\n' >&2
	exit 1
fi

rm -f "$TIMEOUT_CALL_LOG" "${HOME}/.aidevops/cache/pulse-graphql-rate-limit.json"
unset -f timeout_sec
OLD_PATH="$PATH"
EMPTY_BIN="${TMP_DIR}/empty-bin"
mkdir -p "$EMPTY_BIN"
PATH="$EMPTY_BIN"
if _cb_gh_read gh api rate_limit >/dev/null 2>&1; then
	PATH="$OLD_PATH"
	printf 'FAIL: _cb_gh_read should fail closed when no timeout wrapper is available\n' >&2
	exit 1
fi
PATH="$OLD_PATH"

# A paced metadata probe must not hide fresh transport response-header evidence.
# No real credentials, transport database, or network requests enter this fixture.
export AIDEVOPS_GH_TRANSPORT_STATE_DIR="${TMP_DIR}/transport"
mkdir -p "$AIDEVOPS_GH_TRANSPORT_STATE_DIR"
touch "${AIDEVOPS_GH_TRANSPORT_STATE_DIR}/admission.sqlite3"
python3() {
	[[ "$*" == "${SCRIPT_DIR}/gh_transport_budget.py status" ]] || return 1
	printf '%s\n' "$LOCAL_STATUS"
	return 0
}
_cb_rest_core_probe() {
	printf 'probe\n' >>"$TIMEOUT_CALL_LOG"
	return 75
}
local_reset=$(($(date +%s) + 3600))
LOCAL_STATUS="{\"state\":\"available\",\"source\":\"local_response_headers\",\"remaining\":100,\"limit\":5000,\"reserved\":3,\"reset\":${local_reset},\"observation_age_seconds\":0,\"blocked_until\":${local_reset}}"
rm -f "$TIMEOUT_CALL_LOG"
observation=$(_cb_rest_core_observation 2) || {
	printf 'FAIL: paced probe hides fresh local response-header evidence\n' >&2
	exit 1
}
[[ "$observation" == "97 5000 ${local_reset}" && ! -f "$TIMEOUT_CALL_LOG" ]] || {
	printf 'FAIL: local observation must subtract reservations without probing\n' >&2
	exit 1
}

valid_status="$LOCAL_STATUS"
LOCAL_STATUS="${valid_status/\"available\"/\"cooldown\"}"
[[ "$(_cb_rest_core_observation 2)" == "0 5000 ${local_reset}" ]] || exit 1
# An active server cooldown outlives both the quota reset and header TTL.
LOCAL_STATUS="${LOCAL_STATUS/\"reset\":${local_reset}/\"reset\":1}"
LOCAL_STATUS="${LOCAL_STATUS/\"observation_age_seconds\":0/\"observation_age_seconds\":3600}"
[[ "$(_cb_rest_core_observation 2)" == "0 5000 ${local_reset}" ]] || exit 1
LOCAL_STATUS="${valid_status/\"reserved\":3/\"reserved\":101}"
LOCAL_STATUS="${LOCAL_STATUS/\"available\"/\"exhausted\"}"
[[ "$(_cb_rest_core_observation 2)" == "0 5000 ${local_reset}" ]] || exit 1
[[ ! -f "$TIMEOUT_CALL_LOG" ]] || exit 1
LOCAL_STATUS="$valid_status"

for invalid_status in \
	'{"state":"unknown"}' \
	"${LOCAL_STATUS/\"observation_age_seconds\":0/\"observation_age_seconds\":3}" \
	"${LOCAL_STATUS/\"local_response_headers\"/\"projection\"}" \
	"${LOCAL_STATUS/\"reserved\":3/\"reserved\":-1}" \
	"${LOCAL_STATUS/\"reset\":${local_reset}/\"reset\":1}" \
	'not-json'; do
	valid_status="$LOCAL_STATUS"
	LOCAL_STATUS="$invalid_status"
	rm -f "$TIMEOUT_CALL_LOG"
	if _cb_rest_core_observation 2 >/dev/null 2>&1; then
		printf 'FAIL: unusable local evidence granted an observation\n' >&2
		exit 1
	fi
	[[ -f "$TIMEOUT_CALL_LOG" ]] || exit 1
	LOCAL_STATUS="$valid_status"
done
export GH_HOST="example.invalid"
if _cb_rest_core_observation 2 >/dev/null 2>&1; then
	printf 'FAIL: github.com transport evidence reused for another host\n' >&2
	exit 1
fi
unset GH_HOST

printf 'PASS pulse-rate-limit-circuit-breaker-timeout\n'
