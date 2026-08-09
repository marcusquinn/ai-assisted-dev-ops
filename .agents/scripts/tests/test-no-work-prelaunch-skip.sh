#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#4044 / GH#22752.
#
# A canary or worktree-precreation launch-control skip can be reported as a
# no_work reason before a worker process reaches the issue brief. That reason
# must not trip the t2769 no_work structural breaker, while genuine post-launch no_work
# failures still use the existing threshold behaviour.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

# shellcheck source=../worker-lifecycle-common.sh
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=../pulse-fast-fail.sh
source "${SCRIPTS_DIR}/pulse-fast-fail.sh"

TESTS_RUN=0
TESTS_FAILED=0
BREAKER_CALLS=0
COMMENT_CALLS=0
LAST_BREAKER_PAYLOAD=""
TMP_DIR="$(mktemp -d -t no-work-prelaunch.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT
export LOGFILE="${TMP_DIR}/pulse.log"
export FAST_FAIL_STATE_FILE="${TMP_DIR}/fast-fail-counter.json"

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

reset_observations() {
	BREAKER_CALLS=0
	COMMENT_CALLS=0
	LAST_BREAKER_PAYLOAD=""
	return 0
}

_count_issue_comments_containing_marker() {
	local issue_number="$1"
	local repo_slug="$2"
	local marker="$3"
	: "$issue_number" "$repo_slug" "$marker"
	printf '0'
	return 0
}

_apply_no_work_nmr_breaker() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local nmr_threshold="$4"
	local reason="$5"
	BREAKER_CALLS=$((BREAKER_CALLS + 1))
	LAST_BREAKER_PAYLOAD="${issue_number}|${repo_slug}|${failure_count}|${nmr_threshold}|${reason}"
	return 0
}

gh_issue_comment() {
	COMMENT_CALLS=$((COMMENT_CALLS + 1))
	return 0
}

test_prelaunch_reason_skips_breaker() {
	reset_observations
	local output=""
	output=$(_log_no_work_skip_escalation \
		"4003" "exampleorg/examplerepo" "3" \
		"worker canary preflight failed before worktree pre-creation; will retry next cycle" 2>&1)

	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "prelaunch no_work skip does not apply structural blocker" "breaker payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	if [[ "$COMMENT_CALLS" -ne 0 ]]; then
		fail "prelaunch no_work skip does not post diagnostic comment" "comment calls: ${COMMENT_CALLS}"
		return 0
	fi
	if [[ "$output" != *"no_work breaker skipped for pre-launch reason"* ]]; then
		fail "prelaunch no_work skip logs audit line" "output: ${output}"
		return 0
	fi
	pass "prelaunch no_work skip bypasses structural breaker"
	return 0
}

test_worker_launch_rc_2_skips_breaker() {
	reset_observations
	local output=""
	output=$(_log_no_work_skip_escalation \
		"4003" "exampleorg/examplerepo" "3" \
		"dispatch_aborted:worker_launch_rc_2" 2>&1)

	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "worker_launch_rc_2 skip does not apply structural blocker" "breaker payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	if [[ "$output" != *"no_work breaker skipped for pre-launch reason"* ]]; then
		fail "worker_launch_rc_2 skip logs audit line" "output: ${output}"
		return 0
	fi
	pass "worker_launch_rc_2 bypasses no_work structural breaker"
	return 0
}

test_launch_preflight_reason_skips_fast_fail_state() {
	reset_observations
	: >"$LOGFILE"
	printf '{"exampleorg/examplerepo/4003":{"count":2,"ts":1,"reason":"prior","retry_after":1,"backoff_secs":600}}\n' >"$FAST_FAIL_STATE_FILE"

	_fast_fail_record_locked "4003" "exampleorg/examplerepo" \
		"worker_launch_rc_2" "anthropic" "no_work"

	local count=""
	count=$(jq -r '."exampleorg/examplerepo/4003".count' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || count=""
	if [[ "$count" != "2" ]]; then
		fail "launch/preflight fast-fail skip preserves counter" "count: ${count:-unset}"
		return 0
	fi
	if ! grep -q 'skipped launch/preflight reason=worker_launch_rc_2' "$LOGFILE" 2>/dev/null; then
		fail "launch/preflight fast-fail skip logs reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "launch/preflight failures do not accrue fast-fail state"
	return 0
}

test_sensitive_temp_preflight_skips_fast_fail_state() {
	reset_observations
	: >"$LOGFILE"
	printf '{"exampleorg/examplerepo/4004":{"count":2,"ts":1,"reason":"prior","retry_after":1,"backoff_secs":600}}\n' >"$FAST_FAIL_STATE_FILE"

	_fast_fail_record_locked "4004" "exampleorg/examplerepo" \
		"worker_sensitive_temp_preflight_failed" "anthropic" "no_work"
	_log_no_work_skip_escalation "4004" "exampleorg/examplerepo" "3" \
		"worker_sensitive_temp_preflight_failed" >/dev/null 2>&1

	local count=""
	count=$(jq -r '."exampleorg/examplerepo/4004".count' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || count=""
	if [[ "$count" != "2" ]]; then
		fail "sensitive-temp preflight skip preserves counter" "count: ${count:-unset}"
		return 0
	fi
	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "sensitive-temp preflight skip avoids tier escalation" \
			"breaker payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	if ! grep -q 'skipped launch/preflight reason=worker_sensitive_temp_preflight_failed' "$LOGFILE" 2>/dev/null; then
		fail "sensitive-temp preflight skip logs reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "sensitive-temp preflight failures do not accrue fast-fail state"
	return 0
}

test_signing_preflight_skips_fast_fail_state() {
	reset_observations
	: >"$LOGFILE"
	printf '{"exampleorg/examplerepo/4005":{"count":2,"ts":1,"reason":"prior","retry_after":1,"backoff_secs":600}}\n' >"$FAST_FAIL_STATE_FILE"

	_fast_fail_record_locked "4005" "exampleorg/examplerepo" \
		"worker_signing_unavailable" "anthropic" "no_work"
	_log_no_work_skip_escalation "4005" "exampleorg/examplerepo" "3" \
		"worker_signing_unavailable" >/dev/null 2>&1

	local count=""
	count=$(jq -r '."exampleorg/examplerepo/4005".count' "$FAST_FAIL_STATE_FILE" 2>/dev/null) || count=""
	if [[ "$count" != "2" ]]; then
		fail "signing preflight skip preserves counter" "count: ${count:-unset}"
		return 0
	fi
	if [[ "$BREAKER_CALLS" -ne 0 ]]; then
		fail "signing preflight skip avoids tier escalation" \
			"breaker payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	if ! grep -q 'skipped launch/preflight reason=worker_signing_unavailable' "$LOGFILE" 2>/dev/null; then
		fail "signing preflight skip logs reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "signing preflight failures do not accrue fast-fail state"
	return 0
}

test_postlaunch_noop_still_applies_structural_breaker() {
	reset_observations
	_log_no_work_skip_escalation \
		"4003" "exampleorg/examplerepo" "3" \
		"worker_noop_zero_output" >/dev/null 2>&1

	if [[ "$BREAKER_CALLS" -ne 1 ]]; then
		fail "postlaunch no_work still applies structural blocker" "breaker calls: ${BREAKER_CALLS}"
		return 0
	fi
	if [[ "$LAST_BREAKER_PAYLOAD" != "4003|exampleorg/examplerepo|3|3|worker_noop_zero_output" ]]; then
		fail "postlaunch no_work breaker payload is preserved" "payload: ${LAST_BREAKER_PAYLOAD}"
		return 0
	fi
	pass "postlaunch no_work still applies structural breaker"
	return 0
}

test_prelaunch_reason_skips_breaker
test_worker_launch_rc_2_skips_breaker
test_launch_preflight_reason_skips_fast_fail_state
test_sensitive_temp_preflight_skips_fast_fail_state
test_signing_preflight_skips_fast_fail_state
test_postlaunch_noop_still_applies_structural_breaker

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
