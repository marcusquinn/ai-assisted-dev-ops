#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-headless-runtime-failure-classification.sh — provider/runtime subtype fixtures.

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(mktemp -d -t hrf-classify-XXXXXX)"
STATE_DIR="$FIXTURE_DIR/state"
STATE_DB="$STATE_DIR/headless-runtime-state.sqlite3"
METRICS_DIR="$FIXTURE_DIR/metrics"
METRICS_FILE="$METRICS_DIR/headless-runtime-metrics.jsonl"
OPENCODE_AUTH_FILE="$FIXTURE_DIR/auth.json"
OAUTH_POOL_HELPER="$FIXTURE_DIR/oauth-pool-helper.sh"

cleanup() {
	rm -rf "$FIXTURE_DIR"
	return 0
}
trap cleanup EXIT

# shellcheck source=../headless-runtime-lib.sh
source "$SCRIPT_DIR/headless-runtime-lib.sh"

write_fixture() {
	local name="$1" body="$2"
	local path="$FIXTURE_DIR/$name.log"
	printf '%s\n' "$body" >"$path"
	printf '%s' "$path"
	return 0
}

check_classification() {
	local label="$1" body="$2" expected_reason="$3" expected_provider_type="$4"
	local expected_status="$5" expected_runtime_type="$6" expected_source="$7"
	local path reason reason_file
	path=$(write_fixture "$label" "$body")
	reason_file="$FIXTURE_DIR/$label.reason"
	classify_failure_reason "$path" >"$reason_file"
	reason=$(<"$reason_file")
	assert_eq "$label reason" "$expected_reason" "$reason"
	assert_eq "$label provider_error_type" "$expected_provider_type" "${_failure_provider_error_type:-}"
	assert_eq "$label provider_status" "$expected_status" "${_failure_provider_status:-}"
	assert_eq "$label runtime_error_type" "$expected_runtime_type" "${_failure_runtime_error_type:-}"
	assert_eq "$label classification_source" "$expected_source" "${_failure_classification_source:-}"
	return 0
}

echo "${TEST_BLUE}=== headless runtime failure classification tests ===${TEST_NC}"

check_classification \
	"openai_rate_limit" \
	'{"provider":"openai","error":{"type":"rate_limit","message":"Too many requests"},"status":429}' \
	"rate_limit" "rate_limit" "429" "" "trusted_provider"

check_classification \
	"untrusted_tool_output_mentions_rate_limit" \
	'{"type":"tool-result","part":{"tool":"Read","output":"Documentation says rate limit text appears here"}}' \
	"local_error" "" "" "" "default_local"

check_classification \
	"openai_server_error" \
	'{"provider":"openai","error":{"type":"server_error","message":"The server had an error"},"status":500}
session.processor error: undefined is not an object' \
	"provider_error" "server_error" "500" "" "trusted_provider"

check_classification \
	"openai_service_unavailable" \
	'{"provider":"openai","error":{"type":"server_error","message":"service unavailable"},"status":503}' \
	"provider_error" "server_error" "503" "" "trusted_provider"

check_classification \
	"auth_failure" \
	'OpenAI authentication failed: invalid API key; status 401 unauthorized' \
	"auth_error" "auth_error" "401" "" "trusted_provider"

check_classification \
	"gateway_forbidden" \
	'OpenAI provider error: Forbidden: request was blocked by a gateway or proxy' \
	"provider_error" "gateway_denied" "403" "" "trusted_provider"

check_classification \
	"opencode_html_gateway_denied" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Forbidden","statusCode":403,"isRetryable":false,"responseBody":"<!doctype html><title>Forbidden</title>"}}}' \
	"provider_error" "gateway_denied" "403" "" "trusted_provider"

check_classification \
	"opencode_json_access_denied" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Forbidden","statusCode":403,"isRetryable":false,"responseBody":"denied"}}}' \
	"access_denied" "access_denied" "403" "" "trusted_provider"

check_classification \
	"opencode_html_401_is_auth" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Unauthorized","statusCode":401,"isRetryable":false,"responseBody":"<!doctype html><title>Unauthorized</title>"}}}' \
	"auth_error" "auth_error" "401" "" "trusted_provider"

check_classification \
	"opencode_html_502_is_server_error" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Bad Gateway","statusCode":502,"isRetryable":true,"responseBody":"<!doctype html><title>Bad Gateway</title>"}}}' \
	"provider_error" "server_error" "502" "" "trusted_provider"

check_classification \
	"opencode_403_rate_text_remains_access_denied" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Rate limit policy forbids this model","statusCode":403,"isRetryable":false,"responseBody":"denied"}}}' \
	"access_denied" "access_denied" "403" "" "trusted_provider"

check_classification \
	"opencode_last_structured_error_is_authoritative" \
	'{"type":"error","error":{"name":"APIError","data":{"message":"Forbidden","statusCode":403,"isRetryable":false,"responseBody":"denied"}}}
{"type":"error","error":{"name":"APIError","data":{"message":"Bad Gateway","statusCode":502,"isRetryable":true,"responseBody":"upstream unavailable"}}}' \
	"provider_error" "server_error" "502" "" "trusted_provider"

check_classification \
	"untrusted_provider_note_mentions_403" \
	'Provider documentation note: clients can receive 403 Forbidden responses.' \
	"local_error" "" "" "" "default_local"

check_classification \
	"opencode_sqlite_crash" \
	'failed to list snapshot files in /tmp/opencode/snapshot
fatal: not a git repository
SQLiteError: disk I/O error' \
	"local_error" "" "" "opencode_sqlite_io" "opencode_runtime"

check_classification \
	"local_runtime_missing_command" \
	'Error: spawn opencode ENOENT' \
	"local_error" "" "" "runtime_command_missing" "local_runtime"

check_classification \
	"local_runtime_missing_command_reversed_spawn_order" \
	'ENOENT: no such file or directory, spawn opencode' \
	"local_error" "" "" "runtime_command_missing" "local_runtime"

check_classification \
	"local_runtime_permission_denied" \
	'bash: /tmp/aidevops-worker/run.sh: Permission denied' \
	"local_error" "" "" "runtime_permission_denied" "local_runtime"

check_classification \
	"local_runtime_storage_full" \
	'OSError: [Errno 28] No space left on device while writing worker log' \
	"local_error" "" "" "runtime_storage_full" "local_runtime"

mkdir -p "$METRICS_DIR"
append_runtime_metric "worker" "issue-22379" "openai/gpt-5.5" "openai" \
	"provider_error" "1" "provider_error" "1" "1234" "22379" "marcusquinn/aidevops" \
	"$FIXTURE_DIR/work" "$FIXTURE_DIR/openai_server_error.log" "ses_test" \
	"server_error" "500" "" "output_pattern"

assert_eq "metric provider_error_type persisted" "server_error" \
	"$(jq -r '.provider_error_type' "$METRICS_FILE")"
assert_eq "metric provider_status persisted" "500" \
	"$(jq -r '.provider_status' "$METRICS_FILE")"
assert_eq "metric classification_source persisted" "output_pattern" \
	"$(jq -r '.classification_source' "$METRICS_FILE")"
assert_eq "access denied is retryable infrastructure without provider rotation" \
	"$_HRFF_RETRY_CLASS_INFRASTRUCTURE" "$(_hrff_retry_class_for_reason "access_denied" "0")"
assert_eq "access denied remains infrastructure after session creation" \
	"$_HRFF_RETRY_CLASS_INFRASTRUCTURE" "$(_hrff_retry_class_for_reason "access_denied" "1")"
assert_eq "terminated worker remains retryable infrastructure after session creation" \
	"$_HRFF_RETRY_CLASS_INFRASTRUCTURE" "$(_hrff_retry_class_for_reason "signal_terminated_continue" "1")"
assert_eq "watchdog hard kill remains retryable infrastructure after session creation" \
	"$_HRFF_RETRY_CLASS_INFRASTRUCTURE" "$(_hrff_retry_class_for_reason "watchdog_stall_killed" "1")"
assert_eq "permission request remains a maintainer gate" \
	"$_HRFF_RETRY_CLASS_MAINTAINER_GATE" "$(_hrff_retry_class_for_reason "permission_required" "1")"
assert_eq "unknown session-bearing failure remains remediation" \
	"$_HRFF_RETRY_CLASS_REMEDIATION" "$(_hrff_retry_class_for_reason "context_exhausted" "1")"

write_retry_fixture() {
	local name="$1"
	local body="$2"
	local path="$FIXTURE_DIR/$name.retry.log"
	printf '%s\n' "$body" >"$path"
	printf '%s' "$path"
	return 0
}

check_pool_retry_seconds() {
	local label="$1"
	local body="$2"
	local reason="$3"
	local expected_seconds="$4"
	local path
	path=$(write_retry_fixture "$label" "$body")
	: >"$FIXTURE_DIR/oauth-pool-helper.calls"
	attempt_pool_recovery "anthropic" "$reason" "$path" >/dev/null 2>&1
	assert_eq "$label pool retry seconds" "$expected_seconds" \
		"$(awk '{print $4}' "$FIXTURE_DIR/oauth-pool-helper.calls")"
	return 0
}

cat >"$OAUTH_POOL_HELPER" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FIXTURE_DIR}/oauth-pool-helper.calls"
exit 0
STUB
chmod +x "$OAUTH_POOL_HELPER"
export FIXTURE_DIR OAUTH_POOL_HELPER
HOME="$FIXTURE_DIR/home"
mkdir -p "$HOME/.aidevops"
export HOME

check_pool_retry_seconds "missing_retry_after" "status 429 with no retry hint" "rate_limit" "60"
check_pool_retry_seconds "short_retry_after" "retry after 120 seconds" "rate_limit" "120"
check_pool_retry_seconds "over_max_retry_after" "retry after 2 days" "rate_limit" "21600"
check_pool_retry_seconds "auth_error_fallback" "authentication failed" "auth_error" "3600"

OUTCOME_FILE="$FIXTURE_DIR/prrts.outcome"
_WORKER_EXTERNAL_OUTCOME_FILE="$OUTCOME_FILE"
_WORKER_EXTERNAL_OUTCOME_ID="dispatch-29376"
_hrff_write_external_outcome "pr-review-thread-response-owner-repo-1" "worker_noop_zero_output" "0"
assert_eq "external outcome dispatch identity persisted" "dispatch-29376" \
	"$(awk -F= '$1 == "outcome_id" { print $2 }' "$OUTCOME_FILE")"
assert_eq "external outcome reason persisted" "worker_noop_zero_output" \
	"$(awk -F= '$1 == "reason" { print $2 }' "$OUTCOME_FILE")"
assert_eq "external outcome session count persisted" "0" \
	"$(awk -F= '$1 == "session_count" { print $2 }' "$OUTCOME_FILE")"
assert_eq "external outcome retry class persisted" "retryable_infrastructure" \
	"$(awk -F= '$1 == "retry_class" { print $2 }' "$OUTCOME_FILE")"
assert_eq "external outcome has numeric completion time" "true" \
	"$(awk -F= '$1 == "finished_at" && $2 ~ /^[0-9]+$/ { print "true" }' "$OUTCOME_FILE")"
OUTCOME_TARGET="$FIXTURE_DIR/outcome-target"
printf 'unchanged\n' >"$OUTCOME_TARGET"
rm -f "$OUTCOME_FILE"
ln -s "$OUTCOME_TARGET" "$OUTCOME_FILE"
OUTCOME_WRITE_RC=0
_hrff_write_external_outcome "pr-review-thread-response-owner-repo-1" "worker_noop_zero_output" "0" || OUTCOME_WRITE_RC=$?
assert_eq "external outcome rejects destination symlink" "1" "$OUTCOME_WRITE_RC"
assert_eq "external outcome symlink target remains unchanged" "unchanged" "$(<"$OUTCOME_TARGET")"
unset _WORKER_EXTERNAL_OUTCOME_FILE _WORKER_EXTERNAL_OUTCOME_ID

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
