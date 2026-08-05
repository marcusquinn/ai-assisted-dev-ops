#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim quota test cases -- exact REST and GraphQL transport attribution
# =============================================================================
# Sourced by test-gh-shim.sh after the shared hermetic harness is initialized.
#
# Usage: source "${SCRIPT_DIR}/test-gh-shim-quota-cases.sh"

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_TEST_GH_SHIM_QUOTA_CASES_LOADED:-}" ]] && return 0
_TEST_GH_SHIM_QUOTA_CASES_LOADED=1

# Resolve SCRIPT_DIR defensively when sourced outside the orchestrator.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_module_path="${BASH_SOURCE[0]%/*}"
	[[ "$_module_path" == "${BASH_SOURCE[0]}" ]] && _module_path="."
	SCRIPT_DIR="$(cd "$_module_path" && pwd)"
	unset _module_path
fi

# =============================================================================
# Test 22: exact quota cost is limited to unambiguous successful REST requests
# =============================================================================
echo ""
echo "Test 22: conservative direct REST quota attribution"
quota_log="$TMP/quota-attribution.log"

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api --jq . /repos/owner/repo >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "1" ]]; then
	_pass "successful direct REST request records documented cost one"
else
	_fail "direct REST cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo/labels -f name=fixture >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "1" ]]; then
	_pass "successful direct REST write records documented cost one"
else
	_fail "direct REST write cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

: >"$quota_log"
AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api rate_limit >/dev/null 2>&1
if [[ "$(_read_attempt_quota "$quota_log")" == "0" ]]; then
	_pass "successful GET /rate_limit records documented cost zero"
else
	_fail "rate-limit endpoint cost attribution" "quota: $(_read_attempt_quota "$quota_log")"
fi

for ambiguous_case in conditional cache pagination enterprise graphql unknown-option failure; do
	: >"$quota_log"
	case "$ambiguous_case" in
	conditional)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo -H 'If-None-Match: fixture' >/dev/null 2>&1
		;;
	cache)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo --cache 1h >/dev/null 2>&1
		;;
	pagination)
		AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 AIDEVOPS_GH_API_LOG="$quota_log" \
			"$SHIM_RUN" api /repos/owner/repo --paginate >/dev/null 2>&1
		;;
	enterprise)
		GH_HOST=enterprise.example AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>&1
		;;
	graphql)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api graphql -f 'query={viewer{login}}' >/dev/null 2>&1
		;;
	unknown-option)
		AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo --future-option >/dev/null 2>&1
		;;
	failure)
		if STUB_GH_EXIT_CODE=1 AIDEVOPS_GH_API_LOG="$quota_log" "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>&1; then
			_fail "failed REST command status" "stub failure unexpectedly succeeded"
		fi
		;;
	esac
	if [[ "$(_read_attempt_quota "$quota_log")" == "unknown" ]]; then
		_pass "$ambiguous_case request keeps quota cost unknown"
	else
		_fail "$ambiguous_case quota fail-closed behavior" "quota: $(_read_attempt_quota "$quota_log")"
	fi
done

# =============================================================================
# Test 23: response-framed capture proves unit costs without leaking GH_DEBUG
# =============================================================================
echo ""
echo "Test 23: response-framed exact quota capture"
exact_temp="$TMP/exact-quota-temp"
mkdir -p "$exact_temp"

exact_log="$TMP/exact-graphql.log"
exact_err="$TMP/exact-graphql.err"
exact_state="$TMP/exact-graphql-state"
: >"$exact_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$exact_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$exact_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	STUB_GH_DIAGNOSTIC='unframed-private-trailing-fixture' \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>"$exact_err"
if [[ "$(_read_attempt_quota "$exact_log")" == "1" \
	&& "$(_read_last_attempt_field "$exact_log" 15)" == "200" \
	&& "$(grep -c $'\tattempt\t' "$exact_log")" == "2" ]]; then
	_pass "GraphQL unit delta records exact cost after zero-cost bootstrap"
else
	_fail "GraphQL exact quota capture" "log: $(cat "$exact_log" 2>/dev/null || true)"
fi
if [[ ! -s "$exact_err" ]]; then
	_pass "GH_DEBUG frames and unframed trailing content are fully suppressed"
else
	_fail "GH_DEBUG trailing-content privacy filtering" "stderr: $(cat "$exact_err" 2>/dev/null || true)"
fi

prefix_log="$TMP/exact-unframed-prefix.log"
prefix_err="$TMP/exact-unframed-prefix.err"
prefix_state="$TMP/exact-unframed-prefix-state"
: >"$prefix_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$prefix_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$prefix_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_PREFIX='unframed-private-prefix-fixture' \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>"$prefix_err"
if [[ "$(_read_attempt_quota "$prefix_log")" == "1" && ! -s "$prefix_err" ]]; then
	_pass "unframed content before a valid GH_DEBUG frame stays private"
else
	_fail "GH_DEBUG prefix privacy filtering" \
		"log: $(cat "$prefix_log" 2>/dev/null || true) stderr: $(cat "$prefix_err" 2>/dev/null || true)"
fi

mixed_debug="$TMP/exact-malformed-mixed.debug"
mixed_err="$TMP/exact-malformed-mixed.err"
cat >"$mixed_debug" <<'EOF'
unframed-private-prefix-fixture
* Request took 1ms
* Request at 2026-07-24 00:00:00 +0000 UTC
> Authorization: token private-fixture-token

< HTTP/2.0 200 Fixture
< X-Ratelimit-Resource: graphql
< X-Ratelimit-Used: 201
< X-Ratelimit-Remaining: 4799
< X-Ratelimit-Reset: 2000

{"private":"response-body-fixture"}
* Request took 12.5ms
unframed-private-trailing-fixture
* Request took 1ms
EOF
mixed_parsed=$(python3 "$TMP/scripts/gh-quota-debug-filter.py" \
	"$mixed_debug" 2>"$mixed_err")
if [[ "$(printf '%s\n' "$mixed_parsed" | grep -c $'^v1\t1$')" == "1" \
	&& "$(printf '%s\n' "$mixed_parsed" | grep -c $'^frame\t1\t1\t200\tgraphql\t201\t')" == "1" \
	&& ! -s "$mixed_err" ]]; then
	_pass "malformed mixed streams retain only structurally proven attempts"
else
	_fail "malformed mixed-stream attribution" \
		"parsed: $mixed_parsed stderr: $(cat "$mixed_err" 2>/dev/null || true)"
fi

failed_log="$TMP/exact-failed-rest.log"
failed_err="$TMP/exact-failed-rest.err"
failed_state="$TMP/exact-failed-rest-state"
: >"$failed_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$failed_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$failed_log" STUB_GH_DEBUG_RESPONSE=1 STUB_GH_EXIT_CODE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=403 STUB_GH_DEBUG_USED=101 STUB_GH_DEBUG_REMAINING=4899 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>"$failed_err"; then
	_fail "failed REST exact capture status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$failed_log")" == "1" \
	&& "$(_read_last_attempt_field "$failed_log" 14)" == "error" \
	&& "$(_read_last_attempt_field "$failed_log" 15)" == "403" ]]; then
	_pass "counter-proven failed REST response records exact unit cost and status"
else
	_fail "failed REST exact quota capture" "log: $(cat "$failed_log" 2>/dev/null || true)"
fi

zero_cost_log="$TMP/exact-zero-cost-rest.log"
zero_cost_state="$TMP/exact-zero-cost-rest-state"
: >"$zero_cost_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$zero_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$zero_cost_log" STUB_GH_DEBUG_RESPONSE=1 STUB_GH_EXIT_CODE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=403 STUB_GH_DEBUG_USED=100 STUB_GH_DEBUG_REMAINING=4900 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" api /repos/owner/repo >/dev/null 2>/dev/null; then
	_fail "zero-cost REST response status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$zero_cost_log")" == "0" \
	&& "$(_read_last_attempt_field "$zero_cost_log" 14)" == "error" \
	&& "$(_read_last_attempt_field "$zero_cost_log" 15)" == "403" ]]; then
	_pass "counter-proven zero-cost REST failure records exact zero quota"
else
	_fail "zero-cost REST response attribution" "log: $(cat "$zero_cost_log" 2>/dev/null || true)"
fi

successful_zero_log="$TMP/exact-successful-zero-delta.log"
successful_zero_state="$TMP/exact-successful-zero-delta-state"
: >"$successful_zero_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$successful_zero_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$successful_zero_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=100 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_STATUS=200 STUB_GH_DEBUG_USED=100 STUB_GH_DEBUG_REMAINING=4900 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$successful_zero_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$successful_zero_log" 15)" == "200" ]]; then
	_pass "successful zero-delta response remains unknown instead of shifting quota cost"
else
	_fail "successful zero-delta fail-closed behavior" "log: $(cat "$successful_zero_log" 2>/dev/null || true)"
fi

redirect_log="$TMP/exact-redirect-rest.log"
redirect_state="$TMP/exact-redirect-rest-state"
: >"$redirect_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$redirect_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$redirect_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_TRAILING_RESPONSE=1 STUB_BOOTSTRAP_CORE_USED=100 \
	STUB_GH_DEBUG_RESOURCE=core STUB_GH_DEBUG_STATUS=302 STUB_GH_DEBUG_USED=101 \
	STUB_GH_DEBUG_REMAINING=4899 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api /repos/owner/repo/actions/jobs/1/logs >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$redirect_log")" == "1" \
	&& "$(_read_last_attempt_field "$redirect_log" 12)" == "1" \
	&& "$(_read_last_attempt_field "$redirect_log" 15)" == "302" ]]; then
	_pass "redirect frames select the single complete GitHub quota response"
else
	_fail "redirect response attribution" "log: $(cat "$redirect_log" 2>/dev/null || true)"
fi

native_multi_log="$TMP/exact-native-multi-rest.log"
native_multi_state="$TMP/exact-native-multi-rest-state"
: >"$native_multi_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$native_multi_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$native_multi_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_MULTI_FRAME=1 STUB_BOOTSTRAP_CORE_USED=100 \
	STUB_GH_DEBUG_RESOURCE=core STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" run view 123 --log >/dev/null 2>/dev/null
native_multi_summary=$(awk -F '\t' '$2 == "gh_run_view" && $9 == "attempt" {
	value = value (value ? "," : "") $3 ":" $12 ":" $14 ":" $17
} END { print value }' "$native_multi_log")
if [[ "$native_multi_summary" == "rest:1:success:1,rest:2:success:1,rest:3:success:1" ]]; then
	_pass "native multi-frame REST responses record exact per-frame costs"
else
	_fail "native multi-frame REST quota attribution" "summary: $native_multi_summary log: $(cat "$native_multi_log" 2>/dev/null || true)"
fi

native_single_log="$TMP/exact-native-auth-control.log"
: >"$native_single_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$native_single_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=200 STUB_GH_DEBUG_USED=107 STUB_GH_DEBUG_REMAINING=4893 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" auth status >/dev/null 2>/dev/null
if [[ ! -s "$native_single_log" ]]; then
	_pass "native auth control bypasses exact quota transport"
else
	_fail "native auth control quota bypass" "log: $(cat "$native_single_log" 2>/dev/null || true)"
fi

opaque_single_log="$TMP/exact-native-opaque-single-rest.log"
opaque_single_state="$TMP/exact-native-opaque-single-rest-state"
: >"$opaque_single_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$opaque_single_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$opaque_single_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_CORE_USED=100 STUB_GH_DEBUG_RESOURCE=core \
	STUB_GH_DEBUG_STATUS=200 STUB_GH_DEBUG_USED=101 STUB_GH_DEBUG_REMAINING=4899 \
	STUB_GH_DEBUG_RESET=2000 "$SHIM_RUN" api /repos/owner/repo --paginate >/dev/null 2>/dev/null
if [[ "$(_read_last_attempt_field "$opaque_single_log" 12)" == "1" \
	&& "$(_read_attempt_quota "$opaque_single_log")" == "1" ]]; then
	_pass "single complete native-pagination frame resolves to page one"
else
	_fail "single complete native-pagination page attribution" "log: $(cat "$opaque_single_log" 2>/dev/null || true)"
fi

incomplete_log="$TMP/exact-incomplete-rest.log"
incomplete_state="$TMP/exact-incomplete-rest-state"
: >"$incomplete_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$incomplete_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$incomplete_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_REQUEST_ONLY=1 STUB_GH_EXIT_CODE=1 \
	"$SHIM_RUN" api /repos/owner/repo >/dev/null 2>/dev/null; then
	_fail "incomplete REST response status" "stub failure unexpectedly succeeded"
fi
if [[ "$(_read_attempt_quota "$incomplete_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$incomplete_log" 12)" == "1" \
	&& "$(_read_last_attempt_field "$incomplete_log" 14)" == "error" ]]; then
	_pass "one incomplete request frame preserves exact caller-owned page"
else
	_fail "incomplete request page attribution" "log: $(cat "$incomplete_log" 2>/dev/null || true)"
fi

incomplete_multi_log="$TMP/exact-incomplete-multi-rest.log"
incomplete_multi_state="$TMP/exact-incomplete-multi-rest-state"
: >"$incomplete_multi_log"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$incomplete_multi_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$incomplete_multi_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_MULTI_FRAME=1 STUB_GH_DEBUG_REQUEST_ONLY=1 STUB_GH_EXIT_CODE=1 \
	"$SHIM_RUN" api /repos/owner/repo --paginate >/dev/null 2>/dev/null; then
	_fail "incomplete multi-frame response status" "stub failure unexpectedly succeeded"
fi
incomplete_multi_summary=$(awk -F '\t' '$2 == "gh_api_rest" && $9 == "attempt" {
	count++
	pages = pages (pages ? "," : "") $12
	unknown_quota += ($17 == "")
	known_elapsed += ($16 ~ /^[0-9]+$/)
} END { print count "|" pages "|" unknown_quota "|" known_elapsed }' "$incomplete_multi_log")
if [[ "$incomplete_multi_summary" == "3|1,2,3|3|3" ]]; then
	_pass "incomplete native pagination preserves every recognized frame and page"
else
	_fail "incomplete multi-frame page attribution" \
		"summary: $incomplete_multi_summary log: $(cat "$incomplete_multi_log" 2>/dev/null || true)"
fi

gap_log="$TMP/exact-counter-gap.log"
gap_state="$TMP/exact-counter-gap-state"
: >"$gap_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$gap_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$gap_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=202 STUB_GH_DEBUG_REMAINING=4798 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$gap_log")" == "unknown" ]]; then
	_pass "counter gaps and higher-cost ambiguity remain fail-closed"
else
	_fail "counter-gap fail-closed behavior" "quota: $(_read_attempt_quota "$gap_log")"
fi

drift_log="$TMP/exact-format-drift.log"
drift_err="$TMP/exact-format-drift.err"
drift_state="$TMP/exact-format-drift-state"
: >"$drift_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$drift_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$drift_log" \
	STUB_GH_UNFRAMED_PRIVATE_STDERR='unframed-private-response-fixture' \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>"$drift_err"
if [[ "$(_read_attempt_quota "$drift_log")" == "unknown" \
	&& "$(_read_last_attempt_field "$drift_log" 12)" == "0" \
	&& ! -s "$drift_err" ]]; then
	_pass "debug framing drift stays private and makes attempt exactness fail closed"
else
	_fail "debug framing drift handling" "log: $(cat "$drift_log" 2>/dev/null || true) stderr: $(cat "$drift_err" 2>/dev/null || true)"
fi

zero_frame_log="$TMP/exact-zero-frame.log"
zero_frame_state="$TMP/exact-zero-frame-state"
: >"$zero_frame_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$zero_frame_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$zero_frame_log" "$SHIM_RUN" repo view owner/repo >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tgh-quota-bootstrap\t.*\tattempt\t' "$zero_frame_log" || true)" == "1" \
	&& "$(grep -c $'\tgh_repo_view\t.*\tattempt\t' "$zero_frame_log" || true)" == "0" ]]; then
	_pass "valid zero-response capture adds no synthetic transport attempt"
else
	_fail "zero-response exact capture" "log: $(cat "$zero_frame_log" 2>/dev/null || true)"
fi

cache_hit_log="$TMP/exact-native-cache-hit.log"
cache_hit_state="$TMP/exact-native-cache-hit-state"
: >"$cache_hit_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$cache_hit_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$cache_hit_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=200 STUB_GH_DEBUG_REMAINING=4800 STUB_GH_DEBUG_RESET=2000 \
	STUB_GH_DEBUG_HOST=api.github.com STUB_GH_DEBUG_CACHE_TTL=24h0m0s \
	STUB_GH_DEBUG_DATE='Thu, 23 Jul 2026 23:00:00 GMT' \
	STUB_GH_DEBUG_DURATION=2ms "$SHIM_RUN" pr checks 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tgh-quota-bootstrap\t.*\tattempt\t' "$cache_hit_log" || true)" == "1" \
	&& "$(grep -c $'\tgh_pr_checks\t.*\tattempt\t' "$cache_hit_log" || true)" == "0" ]]; then
	_pass "proven GitHub CLI cache hits add no synthetic transport attempt"
else
	_fail "native cache-hit attribution" "log: $(cat "$cache_hit_log" 2>/dev/null || true)"
fi

cache_miss_log="$TMP/exact-native-cache-miss.log"
cache_miss_state="$TMP/exact-native-cache-miss-state"
: >"$cache_miss_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$cache_miss_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$cache_miss_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_BOOTSTRAP_GRAPHQL_RESET=2000000000 \
	STUB_GH_DEBUG_RESOURCE=graphql STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 \
	STUB_GH_DEBUG_RESET=2000000000 \
	STUB_GH_DEBUG_HOST=api.github.com STUB_GH_DEBUG_CACHE_TTL=24h0m0s \
	STUB_GH_DEBUG_DATE='Thu, 23 Jul 2026 23:00:00 GMT' \
	STUB_GH_DEBUG_DURATION='500µs' "$SHIM_RUN" pr checks 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tgh_pr_checks\t.*\tattempt\t' "$cache_miss_log" || true)" == "1" \
	&& "$(_read_attempt_quota "$cache_miss_log")" == "1" ]]; then
	_pass "cache-enabled network responses remain transport attempts"
else
	_fail "cache-miss fail-closed attribution" "log: $(cat "$cache_miss_log" 2>/dev/null || true)"
fi

malformed_date_log="$TMP/exact-native-cache-malformed-date.log"
malformed_date_state="$TMP/exact-native-cache-malformed-date-state"
: >"$malformed_date_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$malformed_date_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$malformed_date_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	STUB_GH_DEBUG_HOST=api.github.com STUB_GH_DEBUG_CACHE_TTL=24h0m0s \
	STUB_GH_DEBUG_DATE=$'Thu, 23 Jul 2026 23:00:00 GMT\377' \
	STUB_GH_DEBUG_DURATION='500µs' "$SHIM_RUN" pr checks 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tgh_pr_checks\t.*\tattempt\t' "$malformed_date_log" || true)" == "1" \
	&& "$(_read_attempt_quota "$malformed_date_log")" == "1" ]]; then
	_pass "malformed cache response dates cannot prove synthetic zero-attempt hits"
else
	_fail "malformed cache-date attribution" "log: $(cat "$malformed_date_log" 2>/dev/null || true)"
fi

naive_date_log="$TMP/exact-native-cache-naive-date.log"
naive_date_state="$TMP/exact-native-cache-naive-date-state"
naive_date_err="$TMP/exact-native-cache-naive-date.err"
: >"$naive_date_log"
: >"$naive_date_err"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$naive_date_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$naive_date_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	STUB_GH_DEBUG_HOST=api.github.com STUB_GH_DEBUG_CACHE_TTL=24h0m0s \
	STUB_GH_DEBUG_DATE='Thu, 23 Jul 2026 23:00:00' \
	STUB_GH_DEBUG_DURATION='500µs' "$SHIM_RUN" pr checks 123 --repo owner/repo \
	>/dev/null 2>"$naive_date_err"
if [[ "$(grep -c $'\tgh_pr_checks\t.*\tattempt\t' "$naive_date_log" || true)" == "1" \
	&& "$(_read_attempt_quota "$naive_date_log")" == "1" \
	&& ! -s "$naive_date_err" ]]; then
	_pass "timezone-free cache response dates fail closed without parser diagnostics"
else
	_fail "timezone-free cache-date attribution" \
		"log: $(cat "$naive_date_log" 2>/dev/null || true) stderr: $(cat "$naive_date_err" 2>/dev/null || true)"
fi

interleaved_debug="$TMP/exact-interleaved-cache.debug"
interleaved_err="$TMP/exact-interleaved-cache.err"
cat >"$interleaved_debug" <<'EOF'
* Request at 2026-07-24 00:00:00 +0000 UTC
> Host: api.github.com
> X-Gh-Cache-Ttl: 24h0m0s
> Authorization: token private-fixture-token

* Request at 2026-07-24 00:00:00 +0000 UTC
> Host: api.github.com
> Authorization: token private-fixture-token

< HTTP/2.0 200 Fixture
< Date: Thu, 23 Jul 2026 23:00:00 GMT
< X-Ratelimit-Resource: graphql
< X-Ratelimit-Used: 200
< X-Ratelimit-Remaining: 4800
< X-Ratelimit-Reset: 2000

{"private":"cached-response-fixture"}
* Request took 500µs
< HTTP/2.0 200 Fixture
< Date: Fri, 24 Jul 2026 00:00:00 GMT
< X-Ratelimit-Resource: graphql
< X-Ratelimit-Used: 201
< X-Ratelimit-Remaining: 4799
< X-Ratelimit-Reset: 2000000000

{"private":"network-response-fixture"}
* Request took 12.5ms
EOF
interleaved_parsed=$(python3 "$TMP/scripts/gh-quota-debug-filter.py" \
	"$interleaved_debug" 2>"$interleaved_err")
if [[ "$(printf '%s\n' "$interleaved_parsed" | grep -c $'^v1\t1$')" == "1" \
	&& "$(printf '%s\n' "$interleaved_parsed" | grep -c $'^frame\t1\t1\t200\tgraphql\t201\t')" == "1" \
	&& ! -s "$interleaved_err" ]]; then
	_pass "interleaved cache completions do not hide the concurrent network response"
else
	_fail "interleaved cache attribution" "parsed: $interleaved_parsed"
fi

local_log="$TMP/exact-local-command.log"
local_state="$TMP/exact-local-command-state"
: >"$local_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$local_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$local_log" "$SHIM_RUN" --version >/dev/null 2>/dev/null
if [[ "$(grep -c $'\tattempt\t' "$local_log" || true)" == "0" && ! -e "$local_state" ]]; then
	_pass "known local-only gh commands avoid quota bootstrap and transport attempts"
else
	_fail "local-only exact-capture bypass" "log: $(cat "$local_log" 2>/dev/null || true)"
fi

# Successful managed writes with debug output unset still run capture cleanup.
# Keep this path nounset-safe and preserve the wrapped commands' success status.
write_success_state="$TMP/exact-write-success-state"
write_success_log="$TMP/exact-write-success.log"
write_success_err="$TMP/exact-write-success.err"
: >"$write_success_log"
: >"$write_success_err"
if GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$write_success_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$write_success_log" "$SHIM_RUN" pr reopen 123 --repo owner/repo \
	>/dev/null 2>"$write_success_err" && \
	GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$write_success_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$write_success_log" "$SHIM_RUN" issue edit 123 --repo owner/repo \
	>/dev/null 2>>"$write_success_err" && \
	! grep -q 'debug_file: unbound variable' "$write_success_err"; then
	_pass "successful PR and issue writes with unset debug output preserve status without nounset diagnostics"
else
	_fail "successful write cleanup with unset debug output" \
		"stderr: $(cat "$write_success_err" 2>/dev/null || true)"
fi

# =============================================================================
# Test 24: response-owned GraphQL cost is recorded after reading the response
# =============================================================================
echo ""
echo "Test 24: response-metered GraphQL quota attribution"
response_cost_log="$TMP/response-cost-graphql.log"
response_cost_out="$TMP/response-cost-graphql.out"
response_cost_state="$TMP/response-cost-graphql-state"
: >"$response_cost_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"rateLimit":{"cost":2},"viewer":{"login":"fixture"}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_cost_log" "$SHIM_RUN" api graphql \
	-f 'query={viewer{login} rateLimit{cost}}' >"$response_cost_out"
if [[ "$(_read_attempt_quota "$response_cost_log")" == "2" \
	&& "$(_read_last_attempt_field "$response_cost_log" 12)" == "1" \
	&& "$(jq -r '.data.rateLimit.cost' "$response_cost_out")" == "2" ]]; then
	_pass "GraphQL response-owned cost records the returned value on page one"
else
	_fail "response-metered GraphQL attribution" "log: $(cat "$response_cost_log" 2>/dev/null || true) output: $(cat "$response_cost_out" 2>/dev/null || true)"
fi

response_followup_log="$TMP/response-cost-followup.log"
: >"$response_followup_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_followup_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=300 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=301 STUB_GH_DEBUG_REMAINING=4699 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$response_followup_log")" == "1" ]]; then
	_pass "response-metered GraphQL invalidates cumulative state before exact follow-up"
else
	_fail "response-metered state invalidation" "log: $(cat "$response_followup_log" 2>/dev/null || true)"
fi

transformed_cost_log="$TMP/response-cost-transformed.log"
transformed_cost_state="$TMP/response-cost-transformed-state"
: >"$transformed_cost_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"rateLimit":{"cost":1}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$transformed_cost_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$transformed_cost_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_GH_DEBUG_BODY='{"data":{"rateLimit":{"cost":1}}}' \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=200 STUB_GH_DEBUG_REMAINING=4800 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api graphql -f 'query={rateLimit{cost}}' --jq '.data.rateLimit.cost' >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$transformed_cost_log")" == "1" \
	&& "$(_read_last_attempt_field "$transformed_cost_log" 6)" != "graphql-response-metered" ]]; then
	_pass "output-transformed GraphQL queries use response-owned exact transport cost"
else
	_fail "transformed GraphQL response-meter guard" "log: $(cat "$transformed_cost_log" 2>/dev/null || true)"
fi

response_missing_log="$TMP/response-cost-missing.log"
response_missing_out="$TMP/response-cost-missing.out"
response_missing_state="$TMP/response-cost-missing-state"
: >"$response_missing_log"
GH_TOKEN=fixture-token STUB_GRAPHQL_RESPONSE_JSON='{"data":{"viewer":{"login":"fixture"}}}' \
	AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 \
	AIDEVOPS_GH_QUOTA_STATE_DIR="$response_missing_state" AIDEVOPS_TEMP_DIR="$exact_temp" \
	AIDEVOPS_GH_API_LOG="$response_missing_log" STUB_GH_DEBUG_RESPONSE=1 \
	STUB_BOOTSTRAP_GRAPHQL_USED=200 STUB_GH_DEBUG_RESOURCE=graphql \
	STUB_GH_DEBUG_USED=201 STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" api graphql -f 'query={viewer{login}}' >"$response_missing_out" 2>/dev/null
if [[ "$(_read_attempt_quota "$response_missing_log")" == "1" \
	&& "$(_read_last_attempt_field "$response_missing_log" 6)" != "graphql-response-metered" \
	&& "$(jq -r '.data.viewer.login' "$response_missing_out")" == "fixture" ]]; then
	_pass "GraphQL queries without rateLimit.cost use exact transport capture"
else
	_fail "missing response-cost transport fallback" "log: $(cat "$response_missing_log" 2>/dev/null || true) output: $(cat "$response_missing_out" 2>/dev/null || true)"
fi

native_meter_log="$TMP/response-cost-native-command.log"
native_meter_state="$TMP/response-cost-native-command-state"
: >"$native_meter_log"
GH_TOKEN=fixture-token AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
	AIDEVOPS_GH_EXACT_QUOTA_CAPTURE=1 AIDEVOPS_GH_QUOTA_STATE_DIR="$native_meter_state" \
	AIDEVOPS_TEMP_DIR="$exact_temp" AIDEVOPS_GH_API_LOG="$native_meter_log" \
	STUB_GH_DEBUG_RESPONSE=1 STUB_BOOTSTRAP_GRAPHQL_USED=200 \
	STUB_GH_DEBUG_RESOURCE=graphql STUB_GH_DEBUG_USED=201 \
	STUB_GH_DEBUG_REMAINING=4799 STUB_GH_DEBUG_RESET=2000 \
	"$SHIM_RUN" pr view 123 --repo owner/repo >/dev/null 2>/dev/null
if [[ "$(_read_attempt_quota "$native_meter_log")" == "1" \
	&& "$(_read_last_attempt_field "$native_meter_log" 6)" != "graphql-response-metered" ]]; then
	_pass "global response-meter flag cannot intercept native GraphQL commands"
else
	_fail "native GraphQL response-meter guard" "log: $(cat "$native_meter_log" 2>/dev/null || true)"
fi
