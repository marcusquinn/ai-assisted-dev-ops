#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../pulse-dispatch-lib.sh
source "$SCRIPT_DIR/../pulse-dispatch-lib.sh"

TMP_DIR=$(mktemp -d)
cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

return_three() {
	return 3
}

return_seven() {
	return 7
}

dispatch_with_dedup() {
	return 3
}

run_stage_with_timeout() {
	local stage_name="$1"
	local timeout_seconds="$2"
	shift 2

	local stage_rc=0
	"$@" || stage_rc=$?
	if [[ "$stage_rc" -ne 0 ]]; then
		printf '[pulse-wrapper] Stage failed: %s exited with %s (%ss)\n' "$stage_name" "$stage_rc" "$timeout_seconds" >>"$LOGFILE"
		return "$stage_rc"
	fi
	return 0
}

assert_adapter_rc() {
	local expected_rc="$1"
	local rc_file="$2"
	shift 2

	local actual_rc=0
	_dispatch_stage_rc_adapter "$rc_file" "$@" || actual_rc=$?
	if [[ "$actual_rc" -ne "$expected_rc" ]]; then
		printf 'FAIL expected adapter rc=%s actual=%s rc_file=%s\n' "$expected_rc" "$actual_rc" "$rc_file" >&2
		return 1
	fi
	return 0
}

assert_file_content() {
	local expected="$1"
	local file_path="$2"
	local actual

	actual=$(<"$file_path")
	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL expected %s in %s actual=%s\n' "$expected" "$file_path" "$actual" >&2
		return 1
	fi
	return 0
}

benign_rc_file="$TMP_DIR/benign.rc"
assert_adapter_rc 0 "$benign_rc_file" return_three
assert_file_content 3 "$benign_rc_file"

failure_rc_file="$TMP_DIR/failure.rc"
assert_adapter_rc 7 "$failure_rc_file" return_seven
assert_file_content 7 "$failure_rc_file"

unwritable_rc_file="/dev/null/dispatch.rc"
assert_adapter_rc 3 "$unwritable_rc_file" return_three

LOGFILE="$TMP_DIR/pulse.log"
DISPATCH_PER_CANDIDATE_TIMEOUT=1
DISPATCH_PER_CANDIDATE_TIMEOUT_FLOOR=1
DISPATCH_TIMING_ADAPTIVE=0
_dispatch_with_timeout "123" "owner/repo" "Issue #123" "Assigned issue" "runner" "/tmp/repo" "/full-loop Implement issue #123" "issue-123" "" || dispatch_timeout_rc=$?
dispatch_timeout_rc="${dispatch_timeout_rc:-0}"
if [[ "$dispatch_timeout_rc" -ne 3 ]]; then
	printf 'FAIL expected dispatch timeout rc=3 actual=%s\n' "$dispatch_timeout_rc" >&2
	exit 1
fi
if grep -q 'Stage failed: dispatch_candidate_123' "$LOGFILE" 2>/dev/null; then
	printf 'FAIL benign dispatch rc=3 emitted Stage failed log\n' >&2
	exit 1
fi

DISPATCH_COUNTERS=""
pulse_stats_increment() {
	local counter_name="$1"
	DISPATCH_COUNTERS="${DISPATCH_COUNTERS}${counter_name}"$'\n'
	return 0
}
printf '[dispatch_with_dedup] Launch failed for #123 in owner/repo: worker_launch_rc_1\n' >>"$LOGFILE"
_dispatch_record_nonzero_dispatch_result "123" "owner/repo" 1
if [[ "$DISPATCH_COUNTERS" != *$'dispatch_worker_launch_failed\n'* ]]; then
	printf 'FAIL worker launch failure did not record launch-validation evidence\n' >&2
	exit 1
fi
if [[ "$DISPATCH_COUNTERS" != *$'dispatch_candidate_failed_reason_launch_error\n'* ]]; then
	printf 'FAIL worker launch failure did not record the launch-error reason\n' >&2
	exit 1
fi

printf 'PASS pulse-dispatch-stage-rc-adapter\n'
