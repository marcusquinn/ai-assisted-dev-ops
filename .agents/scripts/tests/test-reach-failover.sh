#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-failover.sh - Focused tests for reach failure classification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PASS=0
FAIL=0

assert_contains() {
	local output="$1"
	local expected="$2"
	local description="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Expected output to contain: %s\n' "$expected"
		printf '    Output: %s\n' "$output"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local description="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Unexpected output: %s\n' "$unexpected"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_json_valid() {
	local output="$1"
	local description="$2"

	if python3 -m json.tool >/dev/null 2>&1 <<<"$output"; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Invalid JSON: %s\n' "$output"
	fi
	return 0
}

run_classifier() {
	"$HELPER" classify-failure "$@" --format json
	return $?
}

printf '=== Reach Failover Tests ===\n\n'

network_output="$(AIDEVOPS_REACH_TEST_FORCE_MISSING=1 "$HELPER" network doctor --format json)"
assert_json_valid "$network_output" "network doctor emits valid JSON"
assert_contains "$network_output" '"doctor":"network"' "network doctor identifies itself"
assert_contains "$network_output" '"contacted_targets":false' "network doctor does not contact targets"
assert_not_contains "$network_output" "user:pass" "network doctor omits proxy credentials"
assert_not_contains "$network_output" "$ROOT_DIR" "network doctor omits private paths"

isolated_network_doctor() {
	local temp_dir=""
	local temp_bin=""
	local test_temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
	local reach_lib=""
	mkdir -p "$test_temp_root"
	temp_dir="$(mktemp -d "${test_temp_root}/reach-failover-test.XXXXXX")"
	temp_bin="${temp_dir}/bin"
	mkdir -p "$temp_bin"
	cp "$HELPER" "${temp_dir}/reach-helper.sh"
	for reach_lib in "${SCRIPT_DIR}/../reach-"*-lib.sh; do
		cp "$reach_lib" "$temp_dir/"
	done
	printf '#!/usr/bin/env bash\nexit 0\n' >"${temp_dir}/anti-detect-helper.sh"
	chmod +x "${temp_dir}/anti-detect-helper.sh"
	ln -s /usr/bin/dirname "${temp_bin}/dirname"
	PATH="$temp_bin" /bin/bash "${temp_dir}/reach-helper.sh" network doctor --format json
	rm -rf "$temp_dir"
	return 0
}

mixed_network_output="$(isolated_network_doctor)"
assert_json_valid "$mixed_network_output" "network doctor emits valid JSON with mixed readiness"
assert_contains "$mixed_network_output" '{"key":"proxy_vpn","available":true,"status":"ready"}' "network doctor reports proxy readiness independently"
assert_contains "$mixed_network_output" '{"key":"vpn","available":false,"status":"missing_helper"}' "network doctor preserves missing VPN status independently"

fingerprint_output="$(AIDEVOPS_REACH_TEST_FORCE_MISSING=1 "$HELPER" fingerprint doctor --format json)"
assert_json_valid "$fingerprint_output" "fingerprint doctor emits valid JSON"
assert_contains "$fingerprint_output" '"doctor":"fingerprint"' "fingerprint doctor identifies itself"
assert_contains "$fingerprint_output" '"contacted_targets":false' "fingerprint doctor does not contact targets"
assert_not_contains "$fingerprint_output" "$HOME" "fingerprint doctor omits home path"

timeout_output="$(run_classifier --timeout true)"
assert_contains "$timeout_output" '"failure_class":"network_timeout"' "timeout maps to network_timeout"
assert_contains "$timeout_output" '"temporary":true' "timeout is temporary"
assert_contains "$timeout_output" '"safe_to_failover":true' "timeout can fail over safely"

captcha_output="$(run_classifier --has-captcha true)"
assert_contains "$captcha_output" '"failure_class":"captcha_required"' "CAPTCHA maps to captcha_required"
assert_contains "$captcha_output" '"temporary":true' "CAPTCHA is temporary"
assert_contains "$captcha_output" '"safe_to_failover":true' "CAPTCHA can use authorized failover"

login_output="$(run_classifier --has-login-wall true)"
assert_contains "$login_output" '"failure_class":"auth_required"' "login wall maps to auth_required"
assert_contains "$login_output" '"requires_authorization":true' "login wall requires authorization"
assert_contains "$login_output" '"safe_to_failover":false' "login wall cannot fail over"

forbidden_output="$(run_classifier --http-status 403)"
assert_contains "$forbidden_output" '"failure_class":"scope_forbidden"' "403 maps to scope_forbidden"
assert_contains "$forbidden_output" '"requires_authorization":true' "403 requires authorization"
assert_contains "$forbidden_output" '"safe_to_failover":false' "403 cannot fail over"

rate_output="$(run_classifier --http-status 429)"
assert_contains "$rate_output" '"failure_class":"rate_limited"' "429 maps to rate_limited"
assert_contains "$rate_output" '"retry_after_seconds":300' "429 recommends backoff"

selector_output="$(run_classifier --selector-drift true)"
assert_contains "$selector_output" '"failure_class":"selector_drift"' "selector drift is classified"
assert_contains "$selector_output" '"safe_to_failover":false' "selector drift needs repair, not failover"

empty_output="$(run_classifier --content-empty true)"
assert_contains "$empty_output" '"failure_class":"content_empty"' "empty content is classified"
assert_contains "$empty_output" '"safe_to_failover":true' "empty content can use authorized failover"

unknown_output="$(run_classifier --http-status 520)"
assert_contains "$unknown_output" '"failure_class":"unknown"' "unknown status remains unknown"
assert_contains "$unknown_output" '"safe_to_failover":false' "unknown status does not fail over by default"

route_output="$($HELPER route --objective "proxy capture https://user:pass@example.invalid ${ROOT_DIR}" --format json)"
assert_json_valid "$route_output" "route with failover fields emits valid JSON"
assert_contains "$route_output" '"failure_policy":' "route includes failure policy"
assert_contains "$route_output" '"failover_order":[' "route includes failover order"
assert_not_contains "$route_output" "user:pass" "route output omits objective credentials"
assert_not_contains "$route_output" "example.invalid" "route output omits raw target"
assert_not_contains "$route_output" "$ROOT_DIR" "route output omits private local path"

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
