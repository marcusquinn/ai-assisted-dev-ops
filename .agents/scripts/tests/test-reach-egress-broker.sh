#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-reach-egress-broker.sh - Focused tests for Reach egress profiles.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../reach-helper.sh"

PASS=0
FAIL=0
TEST_WORKSPACE=""

cleanup() {
	if [[ -n "$TEST_WORKSPACE" && -d "$TEST_WORKSPACE" ]]; then
		rm -rf "$TEST_WORKSPACE"
	fi
	return 0
}
trap cleanup EXIT

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

assert_command_fails() {
	local description="$1"
	shift
	local output=""
	if output="$(run_helper "$@" 2>&1)"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s\n' "$description"
		printf '    Output: %s\n' "$output"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_command_fails_without() {
	local description="$1"
	local forbidden="$2"
	shift 2
	local output=""
	if output="$(run_helper "$@" 2>&1)"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (command succeeded)\n' "$description"
	elif grep -Fq -- "$forbidden" <<<"$output"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (forbidden value was printed)\n' "$description"
	else
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	fi
	return 0
}

assert_private_mode() {
	local file_path="$1"
	local description="$2"
	local mode=""
	mode="$(python3 - "$file_path" <<'PY'
import os
import stat
import sys

print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))
PY
)"
	if [[ "$mode" == "0o600" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS: %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL: %s (mode %s)\n' "$description" "$mode"
	fi
	return 0
}

run_helper() {
	if AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" "$@"; then
		return 0
	fi
	return 1
}

printf '=== Reach Egress Broker Tests ===\n\n'

test_temp_root="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$test_temp_root"
TEST_WORKSPACE="$(mktemp -d "${test_temp_root}/reach-egress-test.XXXXXX")"

register_output="$(run_helper egress register \
	--name account-us-east \
	--browser brave \
	--class residential \
	--scope account \
	--session-mode stable \
	--country us \
	--region NY \
	--city Testville \
	--timezone America/New_York \
	--locale en-US \
	--credential-ref REACH_PROXY_TEST \
	--format json)"
assert_json_valid "$register_output" "egress register emits valid JSON"
assert_contains "$register_output" '"profile_status":"configured"' "egress profile is configured"
assert_contains "$register_output" '"browser_class":"brave"' "Brave is a first-class browser"
assert_contains "$register_output" '"egress_class":"residential"' "residential egress class is recorded"
assert_contains "$register_output" '"usage_scope":"account"' "account scope is recorded"
assert_contains "$register_output" '"session_mode":"stable"' "account profile uses stable egress"
assert_contains "$register_output" '"country":"US"' "country is normalized"
assert_contains "$register_output" '"region_configured":true' "region presence is reported without its value"
assert_contains "$register_output" '"city_configured":true' "city presence is reported without its value"
assert_contains "$register_output" '"credential_ref_present":true' "credential-reference presence is reported"
assert_not_contains "$register_output" "REACH_PROXY_TEST" "credential-reference name is omitted from output"
assert_not_contains "$register_output" "credential_ref_hash" "credential-reference hashes are omitted from output"
assert_not_contains "$register_output" "Testville" "private city value is omitted from output"
assert_not_contains "$register_output" "$TEST_WORKSPACE" "private workspace path is omitted from output"

profile_file="${TEST_WORKSPACE}/egress-profiles/account-us-east.json"
assert_private_mode "$profile_file" "egress metadata uses mode 600"
profile_text="$(<"$profile_file")"
assert_contains "$profile_text" '"credential_ref": "REACH_PROXY_TEST"' "private metadata stores only the secret reference"

status_output="$(run_helper egress status --name account-us-east --format json)"
assert_json_valid "$status_output" "egress status emits valid JSON"
assert_contains "$status_output" '"profile_status":"configured"' "egress status finds the profile"
assert_not_contains "$status_output" "REACH_PROXY_TEST" "status omits credential-reference name"

assert_command_fails "unforced overwrite fails" egress register \
	--name account-us-east --class direct --country US --timezone America/New_York --locale en-US --format json
assert_command_fails "account scope rejects rotating egress" egress register \
	--name rotating-account --class vpn --scope account --session-mode rotating --country US --timezone America/New_York --locale en-US --format json
assert_command_fails "proxy class requires a secret reference" egress register \
	--name missing-ref --class mobile --country US --timezone America/New_York --locale en-US --format json
assert_command_fails "raw proxy URL is rejected as a credential reference" egress register \
	--name raw-url --class socks5 --country US --timezone America/New_York --locale en-US --credential-ref http://proxy.invalid:1080 --format json
assert_command_fails "direct egress rejects a credential reference" egress register \
	--name direct-ref --class direct --country US --timezone America/New_York --locale en-US --credential-ref REACH_PROXY_TEST --format json
assert_command_fails "direct egress cannot declare rotation" egress register \
	--name direct-rotating --class direct --session-mode rotating --country US --timezone America/New_York --locale en-US --format json
assert_command_fails_without "unknown egress options redact attached values" \
	"REACH_TRANSCRIPT_CANARY" egress register \
	"--credential-ref=REACH_TRANSCRIPT_CANARY"

rotating_output="$(run_helper egress register \
	--name public-mobile \
	--class mobile \
	--scope public \
	--session-mode rotating \
	--country GB \
	--timezone Europe/London \
	--locale en-GB \
	--credential-ref REACH_MOBILE_TEST \
	--format json)"
assert_contains "$rotating_output" '"session_mode":"rotating"' "public observations may use rotating egress"

concurrent_output_one="${TEST_WORKSPACE}/concurrent-egress-one.json"
concurrent_output_two="${TEST_WORKSPACE}/concurrent-egress-two.json"
AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" egress register \
	--name concurrent-public --class direct --country US \
	--timezone America/New_York --locale en-US --format json >"$concurrent_output_one" &
concurrent_pid_one=$!
AIDEVOPS_REACH_WORKSPACE="$TEST_WORKSPACE" "$HELPER" egress register \
	--name concurrent-public --class direct --country US \
	--timezone America/New_York --locale en-US --format json >"$concurrent_output_two" &
concurrent_pid_two=$!
if wait "$concurrent_pid_one"; then
	:
fi
if wait "$concurrent_pid_two"; then
	:
fi
concurrent_output="$(<"$concurrent_output_one")$(<"$concurrent_output_two")"
assert_contains "$concurrent_output" '"refused_overwrite":true' "parallel registration refuses one overwrite"
assert_private_mode "${TEST_WORKSPACE}/egress-profiles/concurrent-public.json" "parallel registration preserves mode 600"

clear_output="$(run_helper egress clear --name account-us-east --format json)"
assert_contains "$clear_output" '"cleared":true' "egress clear removes private metadata"

clear_sentinel="${TEST_WORKSPACE}/clear-sentinel.json"
printf '{"sentinel":true}\n' >"$clear_sentinel"
chmod 600 "$clear_sentinel"
ln -s "$clear_sentinel" "${TEST_WORKSPACE}/egress-profiles/symlink-profile.json"
assert_command_fails "egress clear rejects a symlinked profile file" \
	egress clear --name symlink-profile --format json
if [[ -f "$clear_sentinel" ]]; then
	PASS=$((PASS + 1))
	printf '  PASS: rejected symlink clear preserves the external file\n'
else
	FAIL=$((FAIL + 1))
	printf '  FAIL: rejected symlink clear removed the external file\n'
fi

mv "${TEST_WORKSPACE}/egress-profiles" "${TEST_WORKSPACE}/egress-profiles-real"
ln -s "egress-profiles-real" "${TEST_WORKSPACE}/egress-profiles"
unsafe_status="$(run_helper egress status --name public-mobile --format json)"
assert_contains "$unsafe_status" '"profile_status":"invalid"' "status rejects a symlinked egress directory"
assert_not_contains "$unsafe_status" '"country":"GB"' "unsafe storage is not read"
assert_command_fails "clear rejects a symlinked egress directory" \
	egress clear --name public-mobile --format json

printf '\nPassed: %d\nFailed: %d\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
	exit 1
fi
exit 0
