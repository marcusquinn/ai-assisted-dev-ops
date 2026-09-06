#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#23605: GitHub secondary-rate-limit responses create a
# shared cooldown state and subsequent noncritical gh calls skip without
# invoking gh until the cooldown expires or an explicit override is present.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d)"
CALL_LOG="${TMP_HOME}/gh-calls.log"
ERR_LOG="${TMP_HOME}/stderr.log"
: >"$CALL_LOG"
: >"$ERR_LOG"

cleanup() {
	rm -rf "$TMP_HOME"
	return 0
}
trap cleanup EXIT

export HOME="$TMP_HOME"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${TMP_HOME}/.aidevops/cache/gh-secondary-cooldown.json"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="${TMP_HOME}/.aidevops/cache/gh-cooldown-events.jsonl"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_SECS=600
export AIDEVOPS_GH_READ_RAMP_STATE_FILE="${TMP_HOME}/.aidevops/cache/gh-read-ramp-state.tsv"

gh() {
	local gh_args="$*"
	printf 'GH %s\n' "$gh_args" >>"$CALL_LOG"
	case "$gh_args" in
	"api rate_limit --jq "*.resources.search*)
		if [[ -n "${GH_SEARCH_RATE_LIMIT_RESET:-}" ]]; then
			printf '%s\n' "$GH_SEARCH_RATE_LIMIT_RESET"
		else
			printf '\n'
		fi
		return 0
		;;
	"api rate_limit --jq "*)
		if [[ -n "${GH_CORE_RATE_LIMIT_RESET:-}" ]]; then
			printf '%s\n' "$GH_CORE_RATE_LIMIT_RESET"
		else
			printf '\n'
		fi
		return 0
		;;
	esac
	if [[ "${GH_SECONDARY_FAIL:-0}" == "1" ]]; then
		printf '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}\n' >&2
		return 1
	fi
	if [[ "${GH_REST_CORE_403_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 403\r\nX-GitHub-Request-Id: REQ-CORE\r\n\r\n{"message":"API rate limit exceeded for user ID 123."}\n'
		return 1
	fi
	if [[ "${GH_HEADER_LIMIT_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 429\r\nRetry-After: 42 \t\r\nX-RateLimit-Remaining: 0 \r\nX-GitHub-Request-Id: REQ-429\r\n\r\n{"message":"rate limit exceeded"}\n'
		return 1
	fi
	if [[ "${GH_GENERIC_403_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 5\r\nX-GitHub-Request-Id: REQ-403\r\n\r\n{"message":"Resource not accessible by integration"}\n'
		return 1
	fi
	if [[ "${GH_ABUSE_403_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 403\r\nRetry-After: 30\r\nX-RateLimit-Remaining: 5\r\nX-GitHub-Request-Id: REQ-ABUSE\r\n\r\n{"message":"You have triggered an abuse detection mechanism."}\n'
		return 1
	fi
	if [[ "${GH_PRIMARY_REMAINING_ZERO_FAIL:-0}" == "1" ]]; then
		printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\nX-RateLimit-Resource: graphql\r\nX-GitHub-Request-Id: REQ-PRIMARY\r\n\r\n{"message":"GraphQL: API rate limit already exceeded"}\n'
		return 1
	fi
	if [[ "${GH_PRIMARY_REMAINING_ZERO_SUCCESS:-0}" == "1" ]]; then
		printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 9999999999\r\nX-RateLimit-Resource: graphql\r\nX-GitHub-Request-Id: REQ-PRIMARY-SUCCESS\r\n\r\n{"ok":true}\n'
		return 0
	fi
	if [[ "${GH_LARGE_SUCCESS:-0}" == "1" ]]; then
		printf '{"payload":"'
		dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\000' x
		printf '"}\n'
		return 0
	fi
	printf '{"ok":true}\n'
	return 0
}

# shellcheck source=../shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"

reset_case() {
	: >"$CALL_LOG"
	: >"$ERR_LOG"
	rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
	rm -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-search"
	rm -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-core" "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-graphql" "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-code_search"
	rm -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE"
	rm -f "$AIDEVOPS_GH_READ_RAMP_STATE_FILE"
	unset GH_SECONDARY_FAIL GH_REST_CORE_403_FAIL GH_CORE_RATE_LIMIT_RESET GH_SEARCH_RATE_LIMIT_RESET GH_HEADER_LIMIT_FAIL GH_GENERIC_403_FAIL GH_ABUSE_403_FAIL GH_PRIMARY_REMAINING_ZERO_FAIL GH_PRIMARY_REMAINING_ZERO_SUCCESS GH_LARGE_SUCCESS AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_LINES AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_BYTES AIDEVOPS_GH_READ_RAMP_BUDGET AIDEVOPS_GH_READ_RAMP_BOOT_SECS AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS AIDEVOPS_GH_READ_RAMP_OVERRIDE AIDEVOPS_GH_AUTH_MODE AIDEVOPS_GH_AUTH_PRINCIPAL AIDEVOPS_GH_COOLDOWN_OPERATION AIDEVOPS_GH_COOLDOWN_WRAPPER AIDEVOPS_GH_COOLDOWN_STAGE AIDEVOPS_GH_API_POOL AIDEVOPS_GH_ROUTE_DECISION 2>/dev/null || true
	_GH_SECONDARY_COOLDOWN_LOGGED_ACTIVE=0
	_GH_SECONDARY_COOLDOWN_LOGGED_RAMP=0
	_gh_secondary_system_boot_ts() { return 1; }
	return 0
}

test_secondary_response_writes_cooldown() {
	reset_case
	export GH_SECONDARY_FAIL=1
	set +e
	_gh_with_timeout read gh api repos/owner/repo/issues >"${TMP_HOME}/out.json" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-secondary-rate-limit" and (.expires_at > .first_seen) and .diagnostic.decision_branch == "secondary-text" and .diagnostic.body_classification == "secondary-rate-limit"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS secondary response writes cooldown file\n'
		return 0
	fi
	printf 'FAIL cooldown file missing or malformed\n'
	return 1
}

test_header_response_writes_retry_after_cooldown() {
	reset_case
	export GH_HEADER_LIMIT_FAIL=1
	set +e
	_gh_with_timeout read gh api -i -X GET "/repos/owner/repo/issues?state=open&labels=bug,help&per_page=100" >"${TMP_HOME}/headers.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected header-limited wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-api-rate-limit-status-429" and .last_request_id == "REQ-429" and .diagnostic.cooldown_action == "created" and .diagnostic.decision_branch == "status-429" and .diagnostic.method == "GET" and .diagnostic.endpoint == "/repos/<owner>/<repo>/issues" and .diagnostic.query_shape == "state=<redacted>&labels=<redacted>&per_page=<redacted>" and .diagnostic.operation == "gh_api" and .diagnostic.wrapper == "_gh_with_timeout" and .diagnostic.auth_mode == "gh-pat" and .diagnostic.http_status == "429" and .diagnostic.headers.retry_after == "42" and .diagnostic.headers.x_github_request_id == "REQ-429" and ((.expires_at - .first_seen) >= 40) and ((.expires_at - .first_seen) <= 45)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null && \
		jq -e 'select(.cooldown_action == "created" and .cooldown_reason == "github-api-rate-limit-status-429" and .method == "GET" and .endpoint == "/repos/<owner>/<repo>/issues" and .recent_secondary_count_5m == 0)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE" >/dev/null; then
		printf 'PASS header response writes retry-after cooldown file\n'
		return 0
	fi
	printf 'FAIL header cooldown file missing or malformed\n'
	return 1
}

test_generic_403_diagnostic_distinguishes_forbidden() {
	reset_case
	export GH_GENERIC_403_FAIL=1
	set +e
	_gh_with_timeout read gh api -i "/repos/owner/repo/issues" >"${TMP_HOME}/generic-403.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected generic 403 wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE" ]] && \
		jq -e 'select(.cooldown_action == "diagnostic-only" and .cooldown_reason == "github-api-forbidden-status-403" and .decision_branch == "status-403-diagnostic-only" and .method == "GET" and .endpoint == "/repos/<owner>/<repo>/issues" and .body_message_class == "resource-not-accessible" and .recent_403_count_1m == 1)' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE" >/dev/null; then
		printf 'PASS generic 403 diagnostic records event without global cooldown\n'
		return 0
	fi
	printf 'FAIL generic 403 diagnostic event missing or cooldown was created\n'
	return 1
}

test_rest_core_403_uses_rate_limit_reset_and_skips_next_call() {
	reset_case
	local now=""
	now="$(_gh_secondary_cooldown_now)"
	export GH_REST_CORE_403_FAIL=1
	export GH_CORE_RATE_LIMIT_RESET=$((now + 1800))
	set +e
	_gh_with_timeout read gh api -i "/repos/owner/repo/issues" >"${TMP_HOME}/rest-core-403.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected REST core 403 wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if ! jq -e --argjson reset "$GH_CORE_RATE_LIMIT_RESET" '.reason == "github-api-rate-limit-status-403" and .last_request_id == "REQ-CORE" and .expires_at == $reset and .diagnostic.endpoint_family == "rest-core"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'FAIL REST core 403 cooldown did not use core reset timestamp\n'
		return 1
	fi
	set +e
	_gh_with_timeout read gh api -i "/repos/owner/repo/issues" >"${TMP_HOME}/rest-core-skip.out" 2>>"$ERR_LOG"
	rc=$?
	set -e
	if [[ "$rc" -eq 75 ]] && [[ "$(grep -c 'GH api -i /repos/owner/repo/issues' "$CALL_LOG" | tr -d ' ')" -eq 1 ]]; then
		printf 'PASS REST core 403 uses core reset and skips next REST call\n'
		return 0
	fi
	printf 'FAIL REST core cooldown did not suppress next REST call\n'
	return 1
}

test_rest_search_403_uses_search_rate_limit_reset() {
	reset_case
	local now=""
	now="$(_gh_secondary_cooldown_now)"
	export GH_REST_CORE_403_FAIL=1
	export GH_CORE_RATE_LIMIT_RESET=$((now + 1800))
	export GH_SEARCH_RATE_LIMIT_RESET=$((now + 900))
	set +e
	_gh_with_timeout read gh api -i "/search/issues?q=repo:owner/repo+state:open" >"${TMP_HOME}/rest-search-403.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected REST search 403 wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if jq -e --argjson reset "$GH_SEARCH_RATE_LIMIT_RESET" '.reason == "github-api-rate-limit-status-403" and .last_request_id == "REQ-CORE" and .expires_at == $reset and .diagnostic.endpoint_family == "rest-search"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS REST search 403 uses search reset timestamp\n'
		return 0
	fi
	printf 'FAIL REST search 403 cooldown did not use search reset timestamp\n'
	return 1
}

test_abuse_403_diagnostic_distinguishes_abuse_text() {
	reset_case
	export GH_ABUSE_403_FAIL=1
	set +e
	_gh_with_timeout read gh api -i repos/owner/repo/issues >"${TMP_HOME}/abuse-403.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected abuse 403 wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-api-rate-limit-status-403" and .last_request_id == "REQ-ABUSE" and .diagnostic.decision_branch == "status-403" and .diagnostic.body_classification == "abuse-detection" and .diagnostic.headers.retry_after == "30"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS abuse 403 diagnostic distinguishes abuse text\n'
		return 0
	fi
	printf 'FAIL abuse 403 diagnostic missing or malformed\n'
	return 1
}

test_remaining_zero_diagnostic_classifies_primary_quota() {
	reset_case
	export GH_PRIMARY_REMAINING_ZERO_FAIL=1
	set +e
	_gh_with_timeout read gh api -i graphql >"${TMP_HOME}/primary-quota.out" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -ne 1 ]]; then
		printf 'FAIL expected primary quota wrapped gh rc=1, got %s\n' "$rc"
		return 1
	fi
	if [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-api-rate-limit-remaining-zero" and .last_request_id == "REQ-PRIMARY" and .diagnostic.decision_branch == "remaining-zero" and .diagnostic.body_classification == "primary-rate-limit" and .diagnostic.headers.x_ratelimit_resource == "graphql"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS remaining-zero diagnostic classifies primary quota\n'
		return 0
	fi
	printf 'FAIL remaining-zero diagnostic missing or malformed\n'
	return 1
}

test_successful_include_preserves_remaining_zero_detection() {
	reset_case
	export GH_PRIMARY_REMAINING_ZERO_SUCCESS=1
	_gh_with_timeout read gh api -i graphql >"${TMP_HOME}/primary-quota-success.out" 2>"$ERR_LOG"
	local rc=$?
	if [[ "$rc" -eq 0 ]] && [[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] && \
		jq -e '.reason == "github-api-rate-limit-remaining-zero" and .last_request_id == "REQ-PRIMARY-SUCCESS" and .diagnostic.http_status == "200"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS successful include response preserves remaining-zero detection\n'
		return 0
	fi
	printf 'FAIL successful include response lost remaining-zero detection\n'
	return 1
}

test_large_success_response_skips_cooldown_scan() {
	reset_case
	export GH_LARGE_SUCCESS=1
	local output_file="${TMP_HOME}/large-success.out"
	local rc=0
	local output_bytes=0
	set +e
	_gh_run_bounded_function 5 _gh_with_timeout read gh api repos/owner/repo/check-runs >"$output_file" 2>"$ERR_LOG"
	rc=$?
	set -e
	output_bytes=$(wc -c <"$output_file" | tr -d ' ')
	if [[ "$rc" -eq 0 && "$output_bytes" -gt 500000 && ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]]; then
		printf 'PASS large successful response bypasses cooldown body scan\n'
		return 0
	fi
	printf 'FAIL large successful response stalled or created cooldown: rc=%s bytes=%s\n' "$rc" "$output_bytes"
	return 1
}

test_active_cooldown_skips_without_gh_call() {
	reset_case
	_gh_secondary_cooldown_write "test-secondary" "fixture" >/dev/null 2>&1
	set +e
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/skip.json" 2>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -eq 75 ]] && [[ ! -s "$CALL_LOG" ]] && grep -q 'secondary-rate-limit active=true skip=read' "$ERR_LOG"; then
		printf 'PASS active cooldown skips noncritical gh call\n'
		return 0
	fi
	printf 'FAIL active cooldown did not skip as expected\n'
	sed 's/^/  /' "$CALL_LOG"
	sed 's/^/  /' "$ERR_LOG"
	return 1
}

test_override_allows_audited_call() {
	reset_case
	_gh_secondary_cooldown_write "test-secondary" "fixture" >/dev/null 2>&1
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE=1
	_gh_with_timeout write gh issue comment 123 --repo owner/repo --body ok >"${TMP_HOME}/override.json" 2>"$ERR_LOG"
	if grep -q 'GH issue comment 123' "$CALL_LOG" && grep -q 'secondary-rate-limit override=true op=write' "$ERR_LOG"; then
		printf 'PASS explicit override allows audited critical call\n'
		return 0
	fi
	printf 'FAIL override did not invoke gh with audit log\n'
	return 1
}

test_default_path_without_home_is_user_scoped() {
	local default_path=""
	# shellcheck disable=SC2016 # $1 is expanded by the nested bash process.
	default_path=$(env -u HOME -u AIDEVOPS_GH_SECONDARY_COOLDOWN_HOME -u AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE USER=tester bash -c 'source "$1"; _gh_secondary_cooldown_file' bash "${SCRIPT_DIR}/shared-gh-secondary-cooldown.sh")
	if [[ "$default_path" == "/tmp/.aidevops-tester/.aidevops/cache/gh-secondary-cooldown.json" ]]; then
		printf 'PASS default cooldown path without HOME is user scoped\n'
		return 0
	fi
	printf 'FAIL default cooldown path without HOME was not user scoped: %s\n' "$default_path"
	return 1
}

test_no_jq_fallback_escapes_json_strings() {
	reset_case
	local nojq_bin="${TMP_HOME}/nojq-bin"
	local tool=""
	mkdir -p "$nojq_bin"
	for tool in date mkdir mv sed; do
		ln -sf "$(command -v "$tool")" "${nojq_bin}/${tool}"
	done
	PATH="$nojq_bin" _gh_secondary_cooldown_write 'quote " reason' 'request id: REQ-123' >/dev/null 2>&1
	if jq -e '.reason == "quote \" reason" and .last_request_id == "REQ-123" and (.expires_at > .first_seen) and .diagnostic.decision_branch == "quote \" reason" and .diagnostic.request_id == "REQ-123"' "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" >/dev/null; then
		printf 'PASS no-jq fallback escapes JSON strings\n'
		return 0
	fi
	printf 'FAIL no-jq fallback wrote malformed JSON\n'
	return 1
}

test_header_parsers_ignore_response_body() {
	local response_text=$'HTTP/2 200\r\nX-RateLimit-Remaining: 5\r\n\r\nX-RateLimit-Remaining: 0\nHTTP/2 429'
	local remaining=""
	local status=""

	remaining="$(_gh_secondary_cooldown_header_value "$response_text" "x-ratelimit-remaining")"
	status="$(_gh_secondary_cooldown_status "$response_text")"
	if [[ "$remaining" == "5" && "$status" == "200" ]]; then
		printf 'PASS header parsers ignore response body lookalikes\n'
		return 0
	fi
	printf 'FAIL header parsers read body lookalikes: status=%s remaining=%s\n' "$status" "$remaining"
	return 1
}

test_timeout_temp_cleanup_when_out_mktemp_fails() {
	reset_case
	local leaked_file="${TMP_HOME}/leaked.err"
	_GH_TEST_MKTEMP_CALLS=0
	mktemp() {
		local template="${1:-}"
		: "$template"
		_GH_TEST_MKTEMP_CALLS=$((_GH_TEST_MKTEMP_CALLS + 1))
		if [[ "$_GH_TEST_MKTEMP_CALLS" -eq 1 ]]; then
			: >"$leaked_file"
			printf '%s\n' "$leaked_file"
			return 0
		fi
		return 1
	}
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/mktemp-fail.out" 2>"$ERR_LOG"
	local rc=$?
	unset -f mktemp
	unset _GH_TEST_MKTEMP_CALLS
	if [[ "$rc" -eq 0 && ! -e "$leaked_file" ]] && grep -q 'GH issue list --repo owner/repo' "$CALL_LOG"; then
		printf 'PASS timeout wrapper cleans partial temp file on mktemp failure\n'
		return 0
	fi
	printf 'FAIL timeout wrapper leaked partial temp file or skipped command\n'
	return 1
}

test_event_trim_enforces_bytes_below_line_cap() {
	reset_case
	local file="$AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE"
	local dir="${file%/*}"
	local line_count="0"
	local byte_count="0"
	local first_line=""
	mkdir -p "$dir"
	printf '%s\n' \
		'{"event":"event-1","padding":"123456789012345678901234567890"}' \
		'{"event":"event-2","padding":"123456789012345678901234567890"}' \
		'{"event":"event-3","padding":"123456789012345678901234567890"}' \
		'{"event":"event-4","padding":"123456789012345678901234567890"}' \
		'{"event":"event-5","padding":"123456789012345678901234567890"}' >"$file"
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_LINES=100
	export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_MAX_BYTES=150
	_gh_secondary_cooldown_trim_events "$file"
	line_count=$(wc -l <"$file" | tr -d ' ')
	byte_count=$(wc -c <"$file" | tr -d ' ')
	first_line=$(sed -n '1p' "$file")
	if [[ "$line_count" -lt 5 && "$byte_count" -le 150 && "$first_line" != *event-1* ]]; then
		printf 'PASS event trim enforces bytes below line cap\n'
		return 0
	fi
	printf 'FAIL event trim did not enforce bytes below line cap: lines=%s bytes=%s first=%s\n' "$line_count" "$byte_count" "$first_line"
	return 1
}

test_boot_ramp_defers_after_per_minute_budget() {
	reset_case
	local now=""
	now="$(_gh_secondary_cooldown_now)"
	_gh_secondary_system_boot_ts() { printf '%s' "$((now - 10))"; return 0; }
	export AIDEVOPS_GH_READ_RAMP_BOOT_SECS=120
	export AIDEVOPS_GH_READ_RAMP_BUDGET=1
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/ramp-first.json" 2>"$ERR_LOG"
	set +e
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/ramp-second.json" 2>>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -eq 75 ]] && [[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" -eq 1 ]] && grep -q 'read-ramp active=true phase=boot' "$ERR_LOG"; then
		printf 'PASS boot ramp defers reads after per-minute budget\n'
		return 0
	fi
	printf 'FAIL boot ramp did not defer after budget\n'
	sed 's/^/  /' "$CALL_LOG"
	sed 's/^/  /' "$ERR_LOG"
	return 1
}

test_cooldown_recovery_ramp_defers_after_budget() {
	reset_case
	local now=""
	now="$(_gh_secondary_cooldown_now)"
	local dir="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE%/*}"
	mkdir -p "$dir"
	printf '{"reason":"test","first_seen":%s,"expires_at":%s,"last_request_id":""}\n' "$((now - 120))" "$((now - 10))" >"$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE"
	export AIDEVOPS_GH_READ_RAMP_RECOVERY_SECS=120
	export AIDEVOPS_GH_READ_RAMP_BUDGET=1
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/recovery-first.json" 2>"$ERR_LOG"
	set +e
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/recovery-second.json" 2>>"$ERR_LOG"
	local rc=$?
	set -e
	if [[ "$rc" -eq 75 ]] && [[ "$(wc -l <"$CALL_LOG" | tr -d ' ')" -eq 1 ]] && grep -q 'read-ramp active=true phase=cooldown-recovery' "$ERR_LOG"; then
		printf 'PASS cooldown recovery ramp defers reads after budget\n'
		return 0
	fi
	printf 'FAIL cooldown recovery ramp did not defer after budget\n'
	return 1
}

test_read_ramp_does_not_defer_writes() {
	reset_case
	local now=""
	now="$(_gh_secondary_cooldown_now)"
	_gh_secondary_system_boot_ts() { printf '%s' "$((now - 10))"; return 0; }
	export AIDEVOPS_GH_READ_RAMP_BOOT_SECS=120
	export AIDEVOPS_GH_READ_RAMP_BUDGET=1
	_gh_with_timeout read gh issue list --repo owner/repo >"${TMP_HOME}/write-ramp-first.json" 2>"$ERR_LOG"
	_gh_with_timeout write gh issue comment 123 --repo owner/repo --body ok >"${TMP_HOME}/write-ramp.json" 2>>"$ERR_LOG"
	if grep -q 'GH issue comment 123' "$CALL_LOG"; then
		printf 'PASS read ramp does not defer writes\n'
		return 0
	fi
	printf 'FAIL read ramp deferred write call\n'
	return 1
}

test_primary_search_isolation() {
	local now="" response="" status="" rc=0
	# Exercise both transport boundaries with the same persisted resource hold.
	# shellcheck source=../gh-transport-controls.sh
	source "${SCRIPT_DIR}/gh-transport-controls.sh"
	for status in 200 403; do
		reset_case
		now=$(_gh_secondary_cooldown_now)
		response=$(printf 'HTTP/2 %s\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Resource: search\r\nX-RateLimit-Reset: %s\r\n\r\n{}\n' "$status" "$((now + 30))")
		_gh_secondary_cooldown_record_if_needed 0 "$response" GET /search/issues
		[[ ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] || return 1
		[[ -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-search" ]] || return 1
		_gh_transport_preflight api repos/owner/repo || return 1
		_gh_transport_preflight api graphql || return 1
		rc=0
		_gh_transport_preflight search issues fixture >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 75 ]] || return 1
		rc=0
		_rest_api_call read gh api /search/issues >/dev/null 2>&1 || rc=$?
		[[ "$rc" -eq 75 && ! -s "$CALL_LOG" ]] || return 1
	done
	printf 'PASS primary Search 200/403 holds only search at both transport boundaries without HTTP\n'
	return 0
}

test_search_expiry_and_secondary_precedence() {
	local now="" response=""
	reset_case
	now=$(_gh_secondary_cooldown_now)
	response=$(printf 'HTTP/2 200\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Resource: search\r\nX-RateLimit-Reset: %s\r\n\r\n{}\n' "$((now - 1))")
	_gh_secondary_cooldown_record_if_needed 0 "$response" GET /search/issues
	[[ ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" && ! -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-search" ]] || return 1
	response=$(printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Resource: search\r\nX-RateLimit-Reset: %s\r\nRetry-After: 30\r\n\r\n{"message":"secondary rate limit"}\n' "$((now + 30))")
	_gh_secondary_cooldown_record_if_needed 1 "$response" GET /search/issues
	[[ -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] || return 1
	if _gh_transport_preflight api repos/owner/repo >/dev/null 2>&1; then return 1; fi
	printf 'PASS expired Search primary evidence cannot create global hold; genuine secondary remains global\n'
	return 0
}

test_all_primary_resources_remain_isolated() {
	local resource="" now="" response="" rc=0
	for resource in core graphql code_search; do
		reset_case
		now=$(_gh_secondary_cooldown_now)
		response=$(printf 'HTTP/2 403\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Resource: %s\r\nX-RateLimit-Reset: %s\r\n\r\n{}\n' "$resource" "$((now + 60))")
		_gh_secondary_cooldown_record_if_needed 1 "$response" GET unknown
		[[ ! -f "$AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE" ]] || return 1
		[[ -f "${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-${resource}" ]] || return 1
		_gh_transport_preflight api rate_limit || return 1
		_gh_transport_preflight api /search/issues || return 1
		rc=0
		case "$resource" in
		core) _gh_transport_preflight api -X GET user -q .login >/dev/null 2>&1 || rc=$? ;;
		graphql) _gh_transport_preflight api graphql -f query=fixture >/dev/null 2>&1 || rc=$? ;;
		code_search) _gh_transport_preflight search code fixture >/dev/null 2>&1 || rc=$? ;;
		esac
		[[ "$rc" == 75 ]] || return 1
	done
	printf 'PASS core, GraphQL and code-search primary limits leave other pools and recovery diagnostics usable\n'
	return 0
}

test_secondary_response_writes_cooldown
test_header_response_writes_retry_after_cooldown
test_generic_403_diagnostic_distinguishes_forbidden
test_rest_core_403_uses_rate_limit_reset_and_skips_next_call
test_rest_search_403_uses_search_rate_limit_reset
test_abuse_403_diagnostic_distinguishes_abuse_text
test_remaining_zero_diagnostic_classifies_primary_quota
test_successful_include_preserves_remaining_zero_detection
test_large_success_response_skips_cooldown_scan
test_active_cooldown_skips_without_gh_call
test_override_allows_audited_call
test_default_path_without_home_is_user_scoped
test_no_jq_fallback_escapes_json_strings
test_header_parsers_ignore_response_body
test_timeout_temp_cleanup_when_out_mktemp_fails
test_event_trim_enforces_bytes_below_line_cap
test_boot_ramp_defers_after_per_minute_budget
test_cooldown_recovery_ramp_defers_after_budget
test_read_ramp_does_not_defer_writes
test_primary_search_isolation
test_search_expiry_and_secondary_precedence
test_all_primary_resources_remain_isolated
