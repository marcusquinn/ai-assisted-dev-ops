#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-helper.sh - Focused tests for reach-helper.sh.

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

assert_exit_failure() {
	local description="$1"
	shift

	if "$@" >/tmp/reach-helper-test.out 2>/tmp/reach-helper-test.err; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

printf '=== Reach Helper Tests ===\n\n'

help_output="$($HELPER help)"
assert_contains "$help_output" "capabilities --format json" "help lists capabilities command"
assert_contains "$help_output" "route --objective" "help lists route command"
assert_contains "$help_output" "egress register|status|clear" "help lists egress broker command"
assert_contains "$help_output" "observation record --input" "help lists observation recorder command"

capabilities_output="$($HELPER capabilities --format json)"
assert_json_valid "$capabilities_output" "capabilities emits valid JSON"
assert_contains "$capabilities_output" '"key":"fetch"' "registry includes fetch capability"
assert_contains "$capabilities_output" '"key":"crawler"' "registry includes crawler capability"
assert_contains "$capabilities_output" '"key":"browser"' "registry includes browser capability"
assert_contains "$capabilities_output" '"key":"persistent_profile"' "registry includes persistent profile capability"
assert_contains "$capabilities_output" '"key":"cookie_session"' "registry includes cookie capability"
assert_contains "$capabilities_output" '"key":"proxy_vpn"' "registry includes proxy capability"
assert_contains "$capabilities_output" '"key":"inbox_capture"' "registry includes inbox capability"
assert_contains "$capabilities_output" '"key":"knowledge_staging"' "registry includes knowledge capability"
assert_contains "$capabilities_output" '"key":"performance_logging"' "registry includes performance capability"
assert_contains "$capabilities_output" '"key":"feedback_mining"' "registry includes feedback capability"

doctor_output="$(AIDEVOPS_REACH_TEST_FORCE_MISSING=1 $HELPER doctor --format json)"
assert_json_valid "$doctor_output" "doctor emits valid JSON with missing tools"
assert_contains "$doctor_output" '"contacted_targets":false' "doctor does not contact targets"
assert_contains "$doctor_output" '"available":false' "doctor reports missing local readiness"

route_output="$($HELPER route --objective "capture public documentation" --scope public --format json)"
assert_json_valid "$route_output" "route emits valid JSON"
assert_contains "$route_output" '"backend":"crawler"' "public documentation routes to crawler"
assert_contains "$route_output" '"agency_level":2' "public documentation uses crawler agency level"
assert_contains "$route_output" '"capture_destination":"_inbox"' "capture objective selects inbox destination"

private_output="$($HELPER route --objective "private dashboard" --scope private --format json)"
assert_contains "$private_output" '"backend":"manual_review"' "private unauthenticated route blocks"
assert_contains "$private_output" '"blocked_reason":"private scope requires auth cookie, profile, or manual approval"' "blocked reason is explicit"

sanitized_output="$($HELPER route --objective "capture https://user:pass@example.invalid private docs ${ROOT_DIR}" --scope private --format json)"
assert_not_contains "$sanitized_output" "user:pass" "route output omits credential-like objective details"
assert_not_contains "$sanitized_output" "$ROOT_DIR" "route output omits private local path"
assert_not_contains "$sanitized_output" "example.invalid" "route output omits raw private target"

assert_exit_failure "unknown command fails" "$HELPER" unknown-command

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
