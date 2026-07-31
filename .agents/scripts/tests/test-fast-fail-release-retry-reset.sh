#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n "${2:-}" ]] && printf '     %s\n' "$2"
	return 0
}

TMP=$(mktemp -d -t fast-fail-release-reset.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

LOGFILE="${TMP}/pulse.log"
FAST_FAIL_STATE_FILE="${TMP}/fast-fail-counter.json"
AGENTS_DIR="${TMP}/agents"
export LOGFILE FAST_FAIL_STATE_FILE AGENTS_DIR
mkdir -p "$AGENTS_DIR"
printf '3.14.64\n' >"${AGENTS_DIR}/VERSION"

export FAST_FAIL_SKIP_THRESHOLD=5
export FAST_FAIL_EXPIRY_SECS=604800
export FAST_FAIL_INITIAL_BACKOFF_SECS=600
export FAST_FAIL_MAX_BACKOFF_SECS=604800

print_info() { :; return 0; }
print_warning() { :; return 0; }
print_error() { :; return 0; }
print_success() { :; return 0; }
log_verbose() { :; return 0; }
export -f print_info print_warning print_error print_success log_verbose

gh() { return 0; }
export -f gh

escalate_issue_tier() { return 0; }
export -f escalate_issue_tier

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true
# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source pulse-fast-fail.sh\n'
	exit 1
}
# shellcheck source=../headless-runtime-failure.sh
source "${SCRIPTS_DIR}/headless-runtime-failure.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source headless-runtime-failure.sh\n'
	exit 1
}
# shellcheck source=../worker-watchdog-ff.sh
source "${SCRIPTS_DIR}/worker-watchdog-ff.sh" >/dev/null 2>&1 || {
	printf 'FATAL Could not source worker-watchdog-ff.sh\n'
	exit 1
}

aidevops_find_version() {
	printf '3.14.64\n'
	return 0
}

write_entry() {
	local issue="$1"
	local count="$2"
	local retry_after="$3"
	local version="$4"
	printf '{"owner/repo/%s":{"count":%s,"ts":1,"reason":"worker_launch_failed","retry_after":%s,"backoff_secs":600,"crash_type":"","aidevops_version":"%s","release_reset_policy":"release-sensitive"}}\n' \
		"$issue" "$count" "$retry_after" "$version" >"$FAST_FAIL_STATE_FILE"
	return 0
}

future=$(( $(date +%s) + 3600 ))

if (
	cd "$SCRIPTS_DIR"
	export PATH="${SCRIPTS_DIR}:${PATH}"
	unset SCRIPT_DIR _WORKER_WATCHDOG_FF_LOADED
	unset -f aidevops_find_version
	# shellcheck source=../worker-watchdog-ff.sh
	source worker-watchdog-ff.sh
	declare -F aidevops_find_version >/dev/null 2>&1 && \
		[[ "$(aidevops_find_version)" != "unknown" ]]
); then
	pass "watchdog loads version metadata when sourced through PATH"
else
	fail "watchdog loads version metadata when sourced through PATH"
fi

printf '{"owner/repo/129":{"count":1,"ts":1,"reason":"permission_grant_unverified","retry_after":%s,"backoff_secs":600,"crash_type":"","aidevops_version":"3.14.63","release_reset_policy":"source-state-required"}}\n' \
	"$future" >"$FAST_FAIL_STATE_FILE"
if fast_fail_is_skipped 129 owner/repo && [[ "$(jq -r '."owner/repo/129".count' "$FAST_FAIL_STATE_FILE")" == "1" ]]; then
	pass "source-state failure survives aidevops version upgrades"
else
	fail "source-state failure survives aidevops version upgrades"
fi

printf '{"owner/repo/130":{"count":1,"ts":1,"reason":"unknown","retry_after":%s,"backoff_secs":600,"crash_type":"","aidevops_version":"3.14.63"}}\n' \
	"$future" >"$FAST_FAIL_STATE_FILE"
if fast_fail_is_skipped 130 owner/repo && [[ "$(jq -r '."owner/repo/130".count' "$FAST_FAIL_STATE_FILE")" == "1" ]]; then
	pass "legacy entries without reset policy fail closed"
else
	fail "legacy entries without reset policy fail closed"
fi

if _ff_version_gt "v3.14.64" "3.14.63" && ! _ff_version_gt "3.14.64" "3.14.64" && ! _ff_version_gt "3.14.63" "v3.14.64"; then
	pass "pure bash version comparison handles prefixed aidevops versions"
else
	fail "pure bash version comparison handles prefixed aidevops versions"
fi

write_entry 123 1 "$future" "3.14.63"
reset_rc=0
fast_fail_is_skipped 123 owner/repo || reset_rc=$?
reset_count=$(jq -r '."owner/repo/123".count' "$FAST_FAIL_STATE_FILE")
reset_retry=$(jq -r '."owner/repo/123".retry_after' "$FAST_FAIL_STATE_FILE")
reset_version=$(jq -r '."owner/repo/123".release_retry_reset_version' "$FAST_FAIL_STATE_FILE")
release_reset_count=$(jq -r '."owner/repo/123".release_retry_reset_count' "$FAST_FAIL_STATE_FILE")
if [[ "$reset_rc" -eq 1 && "$reset_count" == "0" && "$reset_retry" == "0" && "$reset_version" == "3.14.64" && "$release_reset_count" == "1" && ! -d "${FAST_FAIL_STATE_FILE}.lockdir" ]]; then
	pass "new aidevops version clears old-version backoff once"
else
	fail "new aidevops version clears old-version backoff once" \
		"rc=${reset_rc}; count=${reset_count}; retry=${reset_retry}; reset_version=${reset_version}; lockdir=$([[ -d "${FAST_FAIL_STATE_FILE}.lockdir" ]] && printf present || printf absent)"
fi

if ! _ff_release_retry_reset_if_newer 123 owner/repo "$(<"$FAST_FAIL_STATE_FILE")" "3.14.65" && \
	[[ "$(jq -r '."owner/repo/123".release_retry_reset_count' "$FAST_FAIL_STATE_FILE")" == "1" ]]; then
	pass "cumulative release reset ceiling survives later versions"
else
	fail "cumulative release reset ceiling survives later versions"
fi

skip_rc=0
fast_fail_is_skipped 123 owner/repo || skip_rc=$?
if [[ "$skip_rc" -eq 1 ]]; then
	pass "release retry reset is not repeatedly reapplied after reset marker"
else
	fail "release retry reset is not repeatedly reapplied after reset marker" "rc=${skip_rc}"
fi

write_entry 124 1 "$future" "3.14.64"
same_rc=0
fast_fail_is_skipped 124 owner/repo || same_rc=$?
if [[ "$same_rc" -eq 0 ]]; then
	pass "same-version backoff remains respected"
else
	fail "same-version backoff remains respected" "rc=${same_rc}"
fi

fast_fail_record 125 owner/repo worker_noop_zero_output anthropic no_work
recorded_version=$(jq -r '."owner/repo/125".aidevops_version' "$FAST_FAIL_STATE_FILE")
recorded_policy=$(jq -r '."owner/repo/125".release_reset_policy' "$FAST_FAIL_STATE_FILE")
if [[ "$recorded_version" == "3.14.64" && "$recorded_policy" == "source-state-required" ]]; then
	pass "fast_fail_record stores version and explicit reset policy"
else
	fail "fast_fail_record stores version and explicit reset policy" \
		"version=${recorded_version}; policy=${recorded_policy}"
fi

now=$(date +%s)
printf '{"owner/repo/126":{"count":1,"ts":%s,"reason":"old","retry_after":0,"backoff_secs":600,"crash_type":"","aidevops_version":"3.14.63","release_retry_reset_version":"3.14.64","release_retry_reset_ts":42,"custom_field":"keep"}}\n' \
	"$now" >"$FAST_FAIL_STATE_FILE"
_fast_fail_record_locked 126 owner/repo worker_noop_zero_output anthropic no_work
if jq -e '."owner/repo/126" | .count == 2 and .aidevops_version == "3.14.64" and .release_retry_reset_version == "3.14.64" and .release_retry_reset_ts == 42 and .custom_field == "keep"' \
	"$FAST_FAIL_STATE_FILE" >/dev/null 2>&1; then
	pass "pulse fast-fail writer preserves release-reset metadata"
else
	fail "pulse fast-fail writer preserves release-reset metadata" \
		"entry=$(jq -c '.\"owner/repo/126\"' "$FAST_FAIL_STATE_FILE")"
fi

worker_state="${TMP}/worker-fast-fail.json"
printf '{"owner/repo/127":{"count":1,"ts":1,"reason":"old","retry_after":0,"backoff_secs":600,"crash_type":"","aidevops_version":"3.14.63","release_retry_reset_version":"3.14.64","release_retry_reset_from":"3.14.63","custom_field":"keep"}}\n' >"$worker_state"
_fast_fail_write_state "$worker_state" "$TMP" "owner/repo/127" 2 "$now" worker_failed "$future" 1200 no_work
if jq -e '."owner/repo/127" | .count == 2 and .crash_type == "no_work" and .release_reset_policy == "source-state-required" and .aidevops_version == "3.14.64" and .release_retry_reset_version == "3.14.64" and .release_retry_reset_from == "3.14.63" and .custom_field == "keep"' \
	"$worker_state" >/dev/null 2>&1; then
	pass "worker fast-fail writer preserves version and reset metadata"
else
	fail "worker fast-fail writer preserves version and reset metadata" \
		"entry=$(jq -c '.\"owner/repo/127\"' "$worker_state")"
fi

watchdog_state="${TMP}/watchdog-fast-fail.json"
watchdog_lock="${watchdog_state}.lockdir"
mkdir "$watchdog_lock"
printf '{"owner/repo/128":{"count":1,"ts":1,"reason":"old","retry_after":0,"backoff_secs":600,"crash_type":"","aidevops_version":"3.14.63","release_retry_reset_version":"3.14.64","release_retry_reset_ts":84,"custom_field":"keep"}}\n' >"$watchdog_state"
watchdog_json=$(<"$watchdog_state")
_ff_write_state_entry "$watchdog_json" "$watchdog_state" "$TMP" "$watchdog_lock" \
	"owner/repo/128" 2 "$now" stall "$future" 1200 overwhelmed
rmdir "$watchdog_lock"
if jq -e '."owner/repo/128" | .count == 2 and .crash_type == "overwhelmed" and .release_reset_policy == "source-state-required" and .aidevops_version == "3.14.64" and .release_retry_reset_version == "3.14.64" and .release_retry_reset_ts == 84 and .custom_field == "keep"' \
	"$watchdog_state" >/dev/null 2>&1; then
	pass "watchdog fast-fail writer preserves version and reset metadata"
else
	fail "watchdog fast-fail writer preserves version and reset metadata" \
		"entry=$(jq -c '.\"owner/repo/128\"' "$watchdog_state")"
fi

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
