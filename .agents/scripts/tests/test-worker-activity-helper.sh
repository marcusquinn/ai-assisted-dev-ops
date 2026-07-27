#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-activity-helper.sh — Fixture-driven tests for t3215.
#
# Verifies worker-activity-helper.sh aggregates the canonical sources
# (headless-runtime-metrics.jsonl + pulse-stats.json) correctly without
# touching the real ~/.aidevops files. Tests are offline (--no-pr-check).

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected not to find: $(printf '%q' "$needle")"
		echo "  in output:            $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $(printf '%q' "$expected")"
		echo "  got:      $(printf '%q' "$actual")"
	fi
	return 0
}

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

_test_process_start_token() {
	local test_pid="$1"
	local stat_content=""
	local stat_after_comm=""
	local start_token=""
	[[ "$test_pid" =~ ^[0-9]+$ ]] || return 1
	if [[ -r "/proc/${test_pid}/stat" ]]; then
		stat_content=$(<"/proc/${test_pid}/stat") || stat_content=""
		[[ -n "$stat_content" ]] || return 1
		stat_after_comm="${stat_content##*) }"
		start_token=$(printf '%s\n' "$stat_after_comm" | awk '{print $20}') || start_token=""
	else
		start_token=$(LC_ALL=C ps -p "$test_pid" -o lstart= 2>/dev/null | tr -s ' ') || start_token=""
		start_token="${start_token#"${start_token%%[![:space:]]*}"}"
		start_token="${start_token%"${start_token##*[![:space:]]}"}"
	fi
	[[ -n "$start_token" ]] || return 1
	printf '%s\n' "$start_token"
	return 0
}

# ---------------------------------------------------------------------------
# Setup: locate the helper, build temp fixtures.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/worker-activity-helper.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: $HELPER not found or not executable"
	exit 1
fi

FIXTURE_DIR="$(mktemp -d -t wah-test-XXXXXX)"
METRICS="$FIXTURE_DIR/headless-runtime-metrics.jsonl"
STATS="$FIXTURE_DIR/pulse-stats.json"
PR_CACHE="$FIXTURE_DIR/pr-cache.json"
OAUTH_POOL="$FIXTURE_DIR/oauth-pool.json"
BLOCKERS="$FIXTURE_DIR/worker-progress-blockers.jsonl"
LEDGER="$FIXTURE_DIR/dispatch-ledger.jsonl"
OBJECTIVE_EVIDENCE="$FIXTURE_DIR/objective-evidence.jsonl"

cleanup() {
	rm -rf "$FIXTURE_DIR"
	return 0
}
trap cleanup EXIT

NOW=$(date +%s)
T_5MIN_AGO=$((NOW - 300))
T_2H_AGO=$((NOW - 7200))
T_25H_AGO=$((NOW - 90000))
T_FUTURE_SENTINEL=4102444800
T_FUTURE_SENTINEL_MS=$((T_FUTURE_SENTINEL * 1000))
OWNER_PROCESS_START=$(_test_process_start_token "$$")

# Build metrics fixture covering every bucket and the regression cases that
# the original awk implementation handled correctly:
#   issue-1, issue-2 — success (terminal)
#   issue-3          — watchdog_stall_killed (terminal failure)
#   issue-4          — watchdog_stall_continue heartbeat (exit 0)
#   issue-5          — rate_limit
#   issue-6          — premature_exit-style unknown failure (exit != 0)
#   issue-7          — out-of-window success (must be excluded by --since 24h)
#   issue-8          — watchdog_stall_continue with NON-ZERO exit code; this
#                      is the t3215 of-bucket regression case. The bucket is
#                      result-name-based fallthrough, NOT exit-code-based —
#                      this record must count as wc, NOT as of.
#   issue-9          — synthetic future sentinel timestamp (year 2100); must
#                      be excluded from bounded-window metrics and examples.
#   issue-10         — missing timestamp; must not appear in bounded windows.
#   issue-11         — service_interruption_continue heartbeat, not terminal.
#   issue-12         — service_interruption_exhausted terminal failure after the
#                      dedicated continuation budget is spent.
#   issue-14         — local SIGTERM/kill marker; must group separately from
#                      provider/runtime stream interruptions.
#   issue-15         — false runtime_error_type sentinel; jq // treats false as
#                      missing, but historical != null and != "" semantics
#                      counted false as a non-empty runtime error marker.
{
	printf '{"ts":%d,"role":"worker","session_key":"issue-1","result":"success","exit_code":0,"duration_ms":1000,"load_1min":2.0,"load_per_cpu":0.25}\n' "$T_5MIN_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-2","result":"success","exit_code":0}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-3","session_id":"ses_3","issue_number":22349,"repo_slug":"marcusquinn/aidevops","work_dir":"/tmp/wt-3","output_file":"/tmp/excerpt-3.log","result":"watchdog_stall_killed","failure_reason":"watchdog_stall_killed","launch_failure_cause":"stall_hard_killed","kill_reason":"hard_kill_stall","next_action":"redispatch_worker","exit_code":79}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-4","result":"watchdog_stall_continue","exit_code":0}\n' "$T_5MIN_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-5","model":"openai/gpt-5.5","provider":"openai","result":"rate_limit","failure_reason":"rate_limit","provider_error_type":"rate_limit","provider_status":"429","classification_source":"output_pattern","classification_pattern":"rate_limit|rate_limit|429|too_many_requests|quota_exceeded","exit_code":1}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-6","model":"openai/gpt-5.5","provider":"openai","result":"provider_error","failure_reason":"provider_error","provider_error_type":"server_error","provider_status":"500","classification_source":"output_pattern","classification_pattern":"server_error|5xx|connection_failure|overloaded","launch_failure_cause":"provider_error","next_action":"inspect_failure_excerpt","exit_code":2}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-7","result":"success","exit_code":0}\n' "$T_25H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-8","result":"watchdog_stall_continue","exit_code":124}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-9","result":"success","exit_code":0}\n' "$T_FUTURE_SENTINEL"
	printf '{"role":"worker","session_key":"issue-10","result":"success","exit_code":0}\n'
	printf '{"ts":%d,"role":"worker","session_key":"issue-11","model":"openai/gpt-5.5","provider":"openai","result":"service_interruption_continue","failure_reason":"provider_error","provider_error_type":"server_error","provider_status":"503","exit_code":81}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-12","model":"openai/gpt-5.5","provider":"openai","result":"service_interruption_exhausted","failure_reason":"local_error","runtime_error_type":"sigterm","launch_failure_cause":"local_runtime_error","next_action":"inspect_failure_excerpt_and_retry_if_transient","exit_code":81}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-14","model":"openai/gpt-5.5","provider":"openai","result":"local_kill","failure_reason":"no_output_stall","runtime_error_type":"sigterm","classification_source":"worker_kill_reason_sentinel","classification_pattern":"no_output_stall","launch_failure_cause":"local_kill","kill_reason":"no_output_stall","next_action":"inspect_local_kill_source","exit_code":83}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-15","model":"openai/gpt-5.5","provider":"openai","result":"provider_error","runtime_error_type":false,"exit_code":82}\n' "$T_2H_AGO"
	# Historical duplicate sparse hard-kill row: must collapse into issue-3 and
	# preserve the richer row above rather than counting a second failure.
	printf '{"ts":%d,"role":"worker","session_key":"issue-3","model":"openai/gpt-5.5","provider":"openai","result":"watchdog_stall_killed","failure_reason":"watchdog_stall_killed","exit_code":79}\n' "$((T_2H_AGO + 1))"
	# One logical session with a resumable interruption followed by success.
	printf '{"ts":%d,"role":"worker","session_key":"issue-16","result":"signal_killed_continue","exit_code":78}\n' "$T_5MIN_AGO"
	printf '{"ts":%d,"role":"worker","session_key":"issue-16","result":"success","exit_code":0}\n' "$T_5MIN_AGO"
	# Identical session keys in different repositories are independent outcomes.
	printf '{"ts":%d,"role":"worker","repo_slug":"example/repo-a","session_key":"issue-17","result":"success","exit_code":0}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","repo_slug":"example/repo-b","session_key":"issue-17","result":"provider_error","exit_code":2}\n' "$T_2H_AGO"
	# A context-rich unscoped legacy event is not a sparse duplicate and must
	# remain distinct from a scoped event with the same session key.
	printf '{"ts":%d,"role":"worker","session_key":"issue-18","issue_number":18,"model":"openai/gpt-5.5","result":"success","exit_code":0}\n' "$T_2H_AGO"
	printf '{"ts":%d,"role":"worker","repo_slug":"example/repo-c","session_key":"issue-18","result":"provider_error","exit_code":2}\n' "$((T_2H_AGO + 1))"
} >"$METRICS"

{
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"recent","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":20,"repo_slug":"marcusquinn/aidevops","session_key":"issue-20","request_id":"perm-source"}\n' "$T_2H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"recent","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":20,"repo_slug":"marcusquinn/aidevops","session_key":"issue-20","request_id":"perm-other"}\n' "$((T_2H_AGO + 1))"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"recent","event":"permission_grant_applied","status":"resuming","reason":"scoped_permission_granted","blocking":false,"source":"test","issue_number":20,"repo_slug":"marcusquinn/aidevops","session_key":"issue-20","request_id":"perm-source"}\n' "$T_5MIN_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"recent","event":"permission_request_non_grantable","status":"blocked","reason":"permission_non_grantable","blocking":true,"source":"test","issue_number":21,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21","request_id":"perm-sensitive"}\n' "$T_5MIN_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"terminal","event":"issue_terminal_reconciled","status":"resolved","reason":"issue_closed_completed","blocking":false,"source":"test","issue_number":21,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21","request_id":"perm-sensitive"}\n' "$((T_5MIN_AGO + 1))"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_awaiting_approval","status":"blocked","reason":"needs_maintainer_permissions","blocking":true,"source":"test","issue_number":22,"repo_slug":"marcusquinn/aidevops","session_key":"issue-22","request_id":"perm-old"}\n' "$T_25H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-terminal","request_id":"perm-terminal"}\n' "$((T_25H_AGO - 2))"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"headless_session_terminal_reconciled","status":"resolved","reason":"success","blocking":false,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-terminal","request_id":"perm-terminal"}\n' "$((T_25H_AGO - 1))"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-retained","request_id":"perm-retained"}\n' "$T_25H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-live","request_id":"perm-live"}\n' "$T_25H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-pid-reuse","request_id":"perm-pid-reuse"}\n' "$T_25H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"older","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":null,"repo_slug":"marcusquinn/aidevops","session_key":"routine-legacy","request_id":"perm-legacy"}\n' "$T_25H_AGO"
	printf '{"schema":"aidevops-worker-blocker/v1","ts":%d,"timestamp":"future","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"test","issue_number":23,"repo_slug":"marcusquinn/aidevops","session_key":"issue-23","request_id":"perm-future"}\n' "$T_FUTURE_SENTINEL"
	printf 'malformed-jsonl-row\n'
} >"$BLOCKERS"

{
	printf '{"session_key":"routine-live","issue_number":"","repo_slug":"marcusquinn/aidevops","pid":%d,"owner_process_start":"%s","status":"in-flight","updated_at":"2026-07-26T01:00:00Z"}\n' "$$" "$OWNER_PROCESS_START"
	printf '{"session_key":"routine-retained","issue_number":"","repo_slug":"marcusquinn/aidevops","pid":%d,"owner_process_start":"%s","status":"in-flight","updated_at":"2026-07-26T01:00:01Z"}\n' "$$" "$OWNER_PROCESS_START"
	printf '{"session_key":"routine-retained","issue_number":"","repo_slug":"marcusquinn/aidevops","pid":%d,"status":"completed","updated_at":"2026-07-26T01:00:02Z"}\n' "$$"
	printf '{"session_key":"routine-pid-reuse","issue_number":"","repo_slug":"marcusquinn/aidevops","pid":%d,"owner_process_start":"not-%s","status":"in-flight","updated_at":"2026-07-26T01:00:03Z"}\n' "$$" "$OWNER_PROCESS_START"
	printf '{"session_key":"routine-legacy","issue_number":"","repo_slug":"marcusquinn/aidevops","pid":%d,"status":"in-flight","updated_at":"2026-07-26T01:00:04Z"}\n' "$$"
} >"$LEDGER"

cat >"$OAUTH_POOL" <<EOF
{
  "openai": [
    {"status": "idle"},
    {"status": "active"},
    {"status": "auth-error"},
    {"status": "rate-limited", "cooldownUntil": $T_FUTURE_SENTINEL_MS}
  ],
  "anthropic": [
    {"status": "idle"}
  ]
}
EOF

# Build pulse-stats fixture: counter arrays with timestamps inside and outside window.
cat >"$STATS" <<EOF
{
  "counters": {
    "pulse_dispatch_circuit_broken": [$T_5MIN_AGO, $T_2H_AGO, $T_25H_AGO],
    "pulse_cycle_skipped_graphql_low": [$T_2H_AGO],
    "dispatch_backoff_skipped": [],
    "pulse_dispatch_no_work_breaker_tripped": [$T_5MIN_AGO]
  },
  "invocation_sources": {}
}
EOF

# Common env for the helper: point at fixtures, skip network.
RUN_ENV=(
	"WAH_METRICS_FILE=$METRICS"
	"WAH_PULSE_STATS_FILE=$STATS"
	"WAH_PR_CACHE_FILE=$PR_CACHE"
	"WAH_OAUTH_POOL_FILE=$OAUTH_POOL"
	"WAH_BLOCKER_LOG_FILE=$BLOCKERS"
	"WAH_DISPATCH_LEDGER_FILE=$LEDGER"
	"WAH_BLOCKER_OWNER_PROCESS_PATTERN=.*"
	"WAH_OBJECTIVE_EVIDENCE_FILE=$OBJECTIVE_EVIDENCE"
	"PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER=24"
)

echo "${TEST_BLUE}=== t3215: worker-activity-helper.sh tests ===${TEST_NC}"
echo

# ---------------------------------------------------------------------------
# Section 1: argv & help.
# ---------------------------------------------------------------------------
echo "--- Section 1: argv parsing ---"

OUT=$("$HELPER" help 2>&1)
RC=$?
assert_rc "1a: help exits 0" 0 "$RC"
assert_contains "1b: help mentions canonical sources" "headless-runtime-metrics.jsonl" "$OUT"
assert_contains "1c: help mentions pulse-stats" "pulse-stats.json" "$OUT"
assert_contains "1d: help warns against worker-NNN.log mtime" "mtime" "$OUT"

# Bad subcommand exits 2.
OUT=$("$HELPER" frobnicate 2>&1)
RC=$?
assert_rc "1e: unknown command exits 2" 2 "$RC"

# Bad --since exits 2.
OUT=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 99x --no-pr-check 2>&1)
RC=$?
assert_rc "1f: bad --since exits 2" 2 "$RC"
assert_contains "1g: bad --since explains valid options" "1h|6h|24h|48h|7d" "$OUT"

# ---------------------------------------------------------------------------
# Section 2: 24h aggregation accuracy.
# ---------------------------------------------------------------------------
echo
echo "--- Section 2: 24h aggregation ---"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 24h --no-pr-check --json 2>&1)
RC=$?
assert_rc "2a: --json exits 0" 0 "$RC"

# Validate it's parseable JSON.
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$JSON" | jq . >/dev/null 2>&1; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 2b: output parses as JSON"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 2b: output is not valid JSON"
	echo "  output: $(printf '%q' "${JSON:0:300}")"
fi

# Assert exact terminal-session counts. Raw attempts collapse by session key;
# continuation-only sessions are reported separately and omitted from outcomes.
# issue-8 (watchdog_stall_continue with exit_code=124) tests the t3215
# regression case — must count as wc, not of, despite non-zero exit.
assert_eq "2c: raw event total remains backward compatible" "18" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "2c2: terminal session outcomes = 13" "13" "$(printf '%s' "$JSON" | jq -r '.metrics.terminal_session_total')"
assert_eq "2c2b: event_total aliases raw total" "18" "$(printf '%s' "$JSON" | jq -r '.metrics.event_total')"
assert_eq "2c3: continuation events = 4" "4" "$(printf '%s' "$JSON" | jq -r '.metrics.continuation_events')"
assert_eq "2d: runtime handoffs = 5" "5" "$(printf '%s' "$JSON" | jq -r '.metrics.runtime_handoffs')"
assert_eq "2d2: delivered success is unknown when GitHub check is skipped" "null" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.succeeded')"
assert_eq "2e: watchdog_killed = 1" "1" "$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_killed')"
assert_eq "2f: watchdog_continued = 2 (incl. nonzero-exit heartbeat)" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_continued')"
assert_eq "2f2: service_interrupted = 1 (heartbeat)" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.service_interrupted')"
assert_eq "2g: rate_limited = 1" "1" "$(printf '%s' "$JSON" | jq -r '.metrics.rate_limited')"
assert_eq "2h: other_failure = 6 (heartbeat excluded, scoped failures counted)" "6" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.other_failure')"
assert_eq "2h2: terminal result_counts includes success bucket" "5" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.result_counts.success')"
assert_eq "2h2b: raw result counts retain continuation evidence" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.event_result_counts.signal_killed_continue')"
assert_eq "2h3: timing summary includes terminal samples" "13" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.timing_ms.samples')"
assert_eq "2h4: recent example carries load context" "2.0" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.recent_examples[] | select(.session_key == "issue-1") | .load_1min')"
assert_eq "2h5: future sentinel excluded from examples" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-9")] | length')"
assert_eq "2h6: missing timestamp excluded from examples" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-10")] | length')"
assert_eq "2h7: failure groups carry issue evidence" "22349" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-3") | .issue_number')"
assert_eq "2h8: failure groups include repo evidence" "marcusquinn/aidevops" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-3") | .repo_slug')"
assert_eq "2h9: failure groups expose provider subtype" "server_error" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .provider_error_type')"
assert_eq "2h10: failure groups expose provider status" "500" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .provider_status')"
assert_eq "2h10b: failure groups expose classification pattern" "server_error|5xx|connection_failure|overloaded" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-6") | .classification_pattern')"
assert_eq "2h11: continuation-only session omitted from terminal failure groups" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.session_key == "issue-11")] | length')"
assert_eq "2h12: diagnostic focus counts stall-killed sessions" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.diagnostic_focus.stall_hard_killed')"
assert_eq "2h13: diagnostic focus counts terminal local runtime errors" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.diagnostic_focus.local_runtime_error')"
assert_eq "2h13b: failure groups preserve false runtime markers" "false" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_groups[] | select(.session_key == "issue-15") | .runtime_error_type')"
assert_eq "2h14: failure families carry next action for stall kills" "redispatch_worker" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_families[] | select(.launch_failure_cause == "stall_hard_killed") | .next_action')"
assert_eq "2h15: diagnostic focus groups local kills separately" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.diagnostic_focus.local_kill')"
assert_eq "2h16: failure families expose local kill next action" "inspect_local_kill_source" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.failure_families[] | select(.launch_failure_cause == "local_kill") | .next_action')"
# Pulse-stats counters (24h window: 25h-ago timestamp must be excluded).
assert_eq "2i: circuit_broken = 2" "2" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_circuit_broken')"
assert_eq "2j: gql_low = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_cycle_skipped_graphql_low')"
assert_eq "2k: missing key returns 0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.dispatch_backoff_skipped')"
assert_eq "2l: nwbreaker = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_no_work_breaker_tripped')"

# PR check skipped → null + state=skipped.
assert_eq "2m: pr count is null when skipped" "null" \
	"$(printf '%s' "$JSON" | jq -r '.worker_solved_issues.count')"
assert_eq "2n: pr check_state = skipped" "skipped" \
	"$(printf '%s' "$JSON" | jq -r '.worker_solved_issues.check_state')"
assert_eq "2n2: delivery stages are explicitly skipped" "skipped" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.check_state')"
assert_eq "2o: blocker events obey the 24h window" "5" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.event_total')"
assert_eq "2p: issue-scoped and live unscoped blockers remain proven current" "3" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.active_total')"
assert_eq "2q: grant clears only the exact request identity" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.active_blockers[] | select(.session_key == "issue-20" and .request_id == "perm-other")] | length')"
assert_eq "2q2: terminal issue event clears a stale blocker identity" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.active_blockers[] | select(.session_key == "issue-21")] | length')"
assert_eq "2r: malformed blocker rows fail open" "1" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.reason_counts.permission_non_grantable')"
assert_eq "2s: terminated null-issue session is absent from unresolved buckets" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.active_blockers[], .progress_blockers.retained_unverified[] | select(.session_key == "routine-terminal")] | length')"
assert_eq "2t: live null-issue session remains proven current" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.active_blockers[] | select(.session_key == "routine-live")] | length')"
assert_eq "2u: unowned null-issue records remain visible but unverified" "3" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.retained_unverified_total')"
assert_eq "2v: retained bucket preserves the unowned session identity" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.retained_unverified[] | select(.session_key == "routine-retained")] | length')"
assert_eq "2w: mismatched PID identity is not treated as a live owner" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.retained_unverified[] | select(.session_key == "routine-pid-reuse")] | length')"
assert_eq "2x: legacy PID-only ownership remains unverified" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.progress_blockers.retained_unverified[] | select(.session_key == "routine-legacy")] | length')"

# ---------------------------------------------------------------------------
# Section 3: 1h window narrows correctly.
# ---------------------------------------------------------------------------
echo
echo "--- Section 3: 1h window ---"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 1h --no-pr-check --json 2>&1)
# 1h window: issue-1 and resumed issue-16 are terminal successes; issue-4 is
# continuation-only and therefore excluded from the outcome denominator.
assert_eq "3a: 1h raw total = 4" "4" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "3a2: 1h terminal total = 2" "2" "$(printf '%s' "$JSON" | jq -r '.metrics.terminal_session_total')"
assert_eq "3b: 1h runtime handoffs = 2" "2" "$(printf '%s' "$JSON" | jq -r '.metrics.runtime_handoffs')"
assert_eq "3c: 1h watchdog_continued = 1" "1" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_continued')"
assert_eq "3d: 1h watchdog_killed = 0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.watchdog_killed')"
assert_eq "3e: 1h recent examples exclude future sentinel" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.recent_examples[] | select(.session_key == "issue-9")] | length')"
assert_eq "3f: 1h blocker event total is bounded" "3" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.event_total')"

# ---------------------------------------------------------------------------
# Section 4: missing files fail-open to zeros.
# ---------------------------------------------------------------------------
echo
echo "--- Section 4: missing-file resilience ---"

JSON=$(env \
	"WAH_METRICS_FILE=/nonexistent/metrics.jsonl" \
	"WAH_PULSE_STATS_FILE=/nonexistent/stats.json" \
	"WAH_PR_CACHE_FILE=$PR_CACHE" \
	"WAH_BLOCKER_LOG_FILE=/nonexistent/blockers.jsonl" \
	"$HELPER" summary --since 24h --no-pr-check --json 2>&1)
RC=$?
assert_rc "4a: missing files exits 0 (fail-open)" 0 "$RC"
assert_eq "4b: missing metrics → total=0" "0" "$(printf '%s' "$JSON" | jq -r '.metrics.total')"
assert_eq "4c: missing stats → counter=0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.pulse_stats.pulse_dispatch_circuit_broken')"
assert_eq "4d: missing blocker log → active=0" "0" \
	"$(printf '%s' "$JSON" | jq -r '.progress_blockers.active_total')"

# A concurrent or interrupted writer can leave valid JSON followed by malformed
# trailing data. jq may print a valid count before returning failure; the helper
# must discard that partial output and emit one safe zero.
printf 'malformed-trailing-data\n' >>"$STATS"
OUT=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 24h --no-pr-check 2>&1)
RC=$?
assert_rc "4e: malformed trailing stats exits 0" 0 "$RC"
assert_contains "4f: malformed trailing stats counter falls back to 0" \
	"pulse_dispatch_circuit_broken:           0" "$OUT"
assert_not_contains "4g: malformed trailing stats has no invalid-number diagnostic" \
	"invalid number" "$OUT"

# Restore the fixture for later sections that assert the valid counters.
cat >"$STATS" <<EOF
{
  "counters": {
    "pulse_dispatch_circuit_broken": [$T_5MIN_AGO, $T_2H_AGO, $T_25H_AGO],
    "pulse_cycle_skipped_graphql_low": [$T_2H_AGO],
    "dispatch_backoff_skipped": [],
    "pulse_dispatch_no_work_breaker_tripped": [$T_5MIN_AGO]
  },
  "invocation_sources": {}
}
EOF

# ---------------------------------------------------------------------------
# Section 5: human-output legibility.
# ---------------------------------------------------------------------------
echo
echo "--- Section 5: human-readable output ---"

OUT=$(env "${RUN_ENV[@]}" "$HELPER" summary --since 24h --no-pr-check 2>&1)
assert_contains "5a: human output names canonical jsonl source" \
	"headless-runtime-metrics.jsonl" "$OUT"
assert_contains "5b: human output names pulse-stats" "pulse-stats.json" "$OUT"
assert_contains "5c: human output shows runtime handoff count" "Runtime handoffs:            5" "$OUT"
assert_contains "5d: human output shows watchdog continued is heartbeat" \
	"heartbeat" "$OUT"
assert_contains "5d2: human output shows service interruption resumes" \
	"Service interruption resumed" "$OUT"
assert_contains "5e: human output shows pr-check opt-in note" "use --pr-check" "$OUT"
assert_contains "5f: human output shows timing summary" "Timing ms" "$OUT"
assert_contains "5g: human output shows failure groups" "Failure groups" "$OUT"
assert_contains "5h: human output shows diagnostic focus" "Diagnostic focus" "$OUT"
assert_contains "5i: human output shows failure families" "Failure families" "$OUT"
assert_contains "5j: human output shows bounded blocker evidence" "worker-progress-blockers.jsonl" "$OUT"
assert_contains "5k: human output shows proven current blocker count" "Proven current:              3" "$OUT"
assert_contains "5l: human output separates retained blocker count" "Retained/unverified:         3" "$OUT"

# ---------------------------------------------------------------------------
# Section 6: provider/account diagnostics expose redacted capacity slots.
# ---------------------------------------------------------------------------
echo
echo "--- Section 6: provider/account diagnostics ---"

printf '{"ts":%d,"role":"worker","session_key":"issue-13","model":"openai/gpt-5.5","provider":"openai","result":"success","exit_code":9}\n' "$T_5MIN_AGO" >>"$METRICS"

JSON=$(env "${RUN_ENV[@]}" "$HELPER" providers --since 24h --json 2>&1)
RC=$?
assert_rc "6a: providers --json exits 0" 0 "$RC"
assert_eq "6b: openai available accounts exclude auth-error/rate-limited" "2" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.account_pool[] | select(.provider == "openai") | .available')"
assert_eq "6c: openai capacity_slots uses redacted multiplier" "48" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.account_pool[] | select(.provider == "openai") | .capacity_slots')"
assert_eq "6c2: provider diagnostics retain raw duplicate/attempt evidence" "7" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.provider_model_usage[] | select(.provider == "openai" and .model == "openai/gpt-5.5") | .other_failure')"
assert_eq "6c2b: provider diagnostics name runtime handoffs without calling them success" "0" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.provider_model_usage[] | select(.provider == "openai" and .model == "openai/gpt-5.5") | .runtime_handoffs')"

JSONC_DEFAULTS="$FIXTURE_DIR/aidevops.defaults.jsonc"
JSONC_USER="$FIXTURE_DIR/config.jsonc"
printf '{"orchestration":{"provider_account_slot_multiplier":11}}\n' >"$JSONC_DEFAULTS"
printf '{"orchestration":{"provider_account_slot_multiplier":7}}\n' >"$JSONC_USER"

JSON=$(env \
	"WAH_METRICS_FILE=$METRICS" \
	"WAH_PULSE_STATS_FILE=$STATS" \
	"WAH_PR_CACHE_FILE=$PR_CACHE" \
	"WAH_OAUTH_POOL_FILE=$OAUTH_POOL" \
	"JSONC_DEFAULTS=$JSONC_DEFAULTS" \
	"JSONC_USER=$JSONC_USER" \
	"$HELPER" providers --since 24h --json 2>&1)
RC=$?
assert_rc "6c3: providers reads config multiplier when env unset" 0 "$RC"
assert_eq "6c4: config multiplier overrides defaults" "14" \
	"$(printf '%s' "$JSON" | jq -r '.provider_diagnostics.account_pool[] | select(.provider == "openai") | .capacity_slots')"

OUT=$(env "${RUN_ENV[@]}" "$HELPER" providers --since 24h 2>&1)
assert_contains "6d: human provider output shows capacity slots" "capacity_slots=48" "$OUT"
assert_contains "6e: human provider output names runtime handoffs" "runtime_handoffs=" "$OUT"

# ---------------------------------------------------------------------------
# Section 7: runtime handoff and GitHub delivery stages remain distinct.
# ---------------------------------------------------------------------------
echo
echo "--- Section 7: delivery-stage attribution queries ---"

GH_STUB_DIR="$FIXTURE_DIR/bin"
mkdir -p "$GH_STUB_DIR"
GH_CALL_LOG="$FIXTURE_DIR/gh-calls.log"
cat >"$GH_STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALL_LOG}"
if [[ "$1" == "pr" && "$2" == "list" && " $* " == *" --state merged "* ]]; then
	printf '[{"number":201},{"number":202}]\n'
	exit 0
fi
if [[ "$1" == "pr" && "$2" == "list" ]]; then
	printf '[{"number":201},{"number":202},{"number":203}]\n'
	exit 0
fi
if [[ "$1" == "issue" && "$2" == "list" ]]; then
	printf '[{"number":101},{"number":102}]\n'
	exit 0
fi
printf '[]\n'
EOF
chmod +x "$GH_STUB_DIR/gh"

JSON=$(env "${RUN_ENV[@]}" "GH_CALL_LOG=$GH_CALL_LOG" "PATH=$GH_STUB_DIR:$PATH" \
	"$HELPER" summary --since 24h --repo marcusquinn/aidevops --pr-check --json 2>&1)
RC=$?
assert_rc "7a: solved attribution query exits 0" 0 "$RC"
assert_eq "7b: worker PR opened count = 3" "3" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.pr_opened')"
assert_eq "7c: worker PR merged count = 2" "2" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.pr_merged')"
assert_eq "7d: solved worker issue count = 2" "2" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.issue_solved')"
assert_eq "7e: delivered success uses solved closed issues" "2" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.delivered_successes')"
assert_eq "7f: metrics succeeded means delivered success" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.succeeded')"
assert_eq "7g: runtime handoffs remain distinct from delivery" "5" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.runtime_handoffs')"
assert_contains "7h: issue query uses solved:worker label" "label:solved:worker" \
	"$(<"$GH_CALL_LOG")"
assert_contains "7i: PR queries use origin:worker attribution" "label:origin:worker" \
	"$(<"$GH_CALL_LOG")"
assert_eq "7j: delivery check performs three stage queries" "3" \
	"$(wc -l <"$GH_CALL_LOG" | tr -d ' ')"

JSON=$(env "${RUN_ENV[@]}" "GH_CALL_LOG=$GH_CALL_LOG" "PATH=$GH_STUB_DIR:$PATH" \
	"$HELPER" summary --since 24h --repo marcusquinn/aidevops --pr-check --json 2>&1)
assert_eq "7k: combined delivery-stage cache prevents repeated GitHub queries" "3" \
	"$(wc -l <"$GH_CALL_LOG" | tr -d ' ')"
assert_eq "7l: cached delivery stages preserve delivered success" "2" \
	"$(printf '%s' "$JSON" | jq -r '.delivery_stages.delivered_successes')"

# ---------------------------------------------------------------------------
# Section 8: reconciled outcomes override routing summaries, not raw evidence.
# ---------------------------------------------------------------------------
echo
echo "--- Section 8: objective outcome reconciliation ---"

RECON_METRICS="$FIXTURE_DIR/reconciled-metrics.jsonl"
cat >"$RECON_METRICS" <<EOF
{"ts":$T_5MIN_AGO,"role":"worker","session_key":"issue-601","issue_number":601,"repo_slug":"owner/repo","attempt_id":"attempt-success","run_id":"run-a","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$T_5MIN_AGO,"role":"worker","session_key":"issue-602","issue_number":602,"repo_slug":"owner/repo","attempt_id":"attempt-failed","run_id":"run-b","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$T_5MIN_AGO,"role":"worker","session_key":"issue-603","issue_number":603,"repo_slug":"owner/repo","attempt_id":"attempt-unknown","run_id":"run-c","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$T_5MIN_AGO,"role":"worker","session_key":"issue-604","issue_number":604,"repo_slug":"owner/repo","attempt_id":"attempt-latest-failed","run_id":"run-d","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$T_5MIN_AGO,"role":"worker","session_key":"issue-605","issue_number":605,"repo_slug":"owner/repo","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$((T_5MIN_AGO - 20)),"role":"worker","session_key":"issue-606","issue_number":606,"repo_slug":"","attempt_id":"attempt-unscoped","run_id":"run-e","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
{"ts":$((T_5MIN_AGO - 20)),"role":"worker","session_key":"issue-607","issue_number":607,"repo_slug":"owner/repo","attempt_id":"","run_id":"run-f","result":"premature_exit","failure_reason":"premature_exit","exit_code":77}
EOF
cat >"$OBJECTIVE_EVIDENCE" <<EOF
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":601,"attempt_id":"attempt-success","run_id":"run-a","effective_outcome":"success","evidence_timestamp":$T_5MIN_AGO}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":602,"attempt_id":"attempt-failed","run_id":"run-b","effective_outcome":"failed","evidence_timestamp":$T_5MIN_AGO}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":603,"attempt_id":"attempt-unknown","run_id":"run-c","effective_outcome":"unknown","evidence_timestamp":$T_5MIN_AGO}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":604,"attempt_id":"attempt-latest-failed","run_id":"run-d","effective_outcome":"success","evidence_timestamp":$((T_5MIN_AGO - 10))}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":604,"attempt_id":"attempt-latest-failed","run_id":"run-d","effective_outcome":"failed","evidence_timestamp":$T_5MIN_AGO}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":606,"attempt_id":"attempt-unscoped","run_id":"run-e","effective_outcome":"success","evidence_timestamp":$((T_5MIN_AGO - 20))}
{"record_type":"attempt_outcome","repo":"owner/repo","issue_number":607,"attempt_id":"","run_id":"run-f","effective_outcome":"success","evidence_timestamp":$((T_5MIN_AGO - 20))}
EOF

JSON=$(env "${RUN_ENV[@]}" "WAH_METRICS_FILE=$RECON_METRICS" \
	"$HELPER" summary --since 1h --no-pr-check --json 2>&1)
assert_eq "8a: raw events remain queryable" "7" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.event_result_counts.premature_exit')"
assert_eq "8b: reconciled success becomes an effective runtime handoff" "2" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.runtime_handoffs')"
assert_eq "8c: validated failures and raw fallbacks remain in failure totals" "5" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.other_failure')"
assert_eq "8d: successful attempt is absent from failure groups" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 601)] | length')"
assert_eq "8e: failed attempt remains in failure groups" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 602)] | length')"
assert_eq "8f: effective examples retain the raw parser result" "premature_exit" \
	"$(printf '%s' "$JSON" | jq -r '.metrics.recent_examples[] | select(.issue_number == 601) | .raw_result')"
assert_eq "8g: unknown reconciled outcomes fall back to raw failure" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 603)] | length')"
assert_eq "8h: latest terminal evidence wins for duplicate attempt records" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 604)] | length')"
assert_eq "8i: legacy rows without attempt identity remain readable" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 605)] | length')"
assert_eq "8j: empty repo slug remains an unscoped attempt match" "0" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 606)] | length')"
assert_eq "8k: empty attempt identities never reconcile with each other" "1" \
	"$(printf '%s' "$JSON" | jq -r '[.metrics.failure_groups[] | select(.issue_number == 607)] | length')"

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo
echo "${TEST_BLUE}=== Summary ===${TEST_NC}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -eq 0 ]]; then
	echo "${TEST_GREEN}All tests passed.${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}$TESTS_FAILED test(s) failed.${TEST_NC}"
	exit 1
fi
