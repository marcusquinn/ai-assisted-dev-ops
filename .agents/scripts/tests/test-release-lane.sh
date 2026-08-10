#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Release-lane ownership and setup coordination regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"

# shellcheck source=../release-lane-helper.sh
source "${SCRIPT_DIR}/release-lane-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0

assert_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" == "true" ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

run_competing_source_test() {
	local output=""
	local rc=0
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"remote-publication","tag":"v1.2.3","operation_token":"token-old"}'
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	output=$(release_lane_acquire test/repo 202 202 2>&1) || rc=$?
	[[ "$rc" -eq 75 && "$output" == *"source_pr=101"* && "$output" == *"aidevops release reconcile 101"* ]]
	return $?
}

run_same_source_adoption_test() {
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"remote-publication","tag":"v1.2.3","operation_token":"token-old"}'
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	release_lane_acquire test/repo 101 101 >/dev/null
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "adopted" ]]
	return $?
}

run_terminal_lane_reacquire_test() {
	local written=""
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":false,"source_pr":101,"phase":"terminal","tag":"v1.2.3","operation_token":"token-old"}'
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		[[ "$repo" == "test/repo" && "$expected_head" == "1111111111111111111111111111111111111111" ]] || return 1
		written="$state_json"
		[[ "$(jq -r '.active' <<<"$written")" == "true" && "$(jq -r '.source_pr' <<<"$written")" == "202" ]]
		return $?
	}
	release_lane_acquire test/repo 202 '202@2222222222222222222222222222222222222222' >/dev/null
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "acquired" ]]
	return $?
}

run_setup_guard_test() {
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"exact-tag-deployment","tag":"v1.2.3","operation_token":"token-old"}'
		return 0
	}
	if release_lane_setup_guard test/repo >/dev/null 2>&1; then
		return 1
	fi
	AIDEVOPS_RELEASE_LANE_SOURCE_PR=101 AIDEVOPS_RELEASE_LANE_TAG=v1.2.3 \
		release_lane_setup_guard test/repo
	return $?
}

run_http_classification_test() (
	local mode="missing"
	local rc=0
	gh() {
		if [[ " $* " != *" --include "* ]]; then
			return 1
		fi
		if [[ "$mode" == "missing" ]]; then
			printf 'HTTP/2.0 404 Not Found\n\n'
		else
			printf 'HTTP/2.0 401 Unauthorized\n\n'
		fi
		return 1
	}
	_release_lane_remote_head test/repo >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 2 ]] || return 1
	mode="unauthorized"
	rc=0
	_release_lane_remote_head test/repo >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 1 ]]
	return $?
)

run_legacy_and_api_failure_test() (
	local mode="absent"
	local rc=0
	release_lane_read() {
		[[ "$mode" == "absent" ]] && return 2
		return 1
	}
	release_lane_update_if_owned test/repo 101 exact-tag-deployment v1.2.3 || return 1
	mode="failure"
	release_lane_setup_guard test/repo >/dev/null 2>&1 || rc=$?
	[[ "$rc" -eq 75 ]]
	return $?
)

run_stale_same_source_recovery_test() (
	local written=""
	local recovered_state=""
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"reserved","tag":null,"updated_at":"2020-01-01T00:00:00Z","operation_token":"token-old"}'
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		written="$state_json"
		[[ "$repo" == "test/repo" && "$expected_head" == "1111111111111111111111111111111111111111" ]]
		return $?
	}
	AIDEVOPS_RELEASE_LANE_STALE_SECONDS=1 release_lane_acquire test/repo 101 101 >/dev/null || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "acquired" && "$(jq -r '.phase' <<<"$written")" == "reserved" &&
	"$(jq -r '.operation_token' <<<"$written")" != "token-old" ]] || return 1
	recovered_state="$written"
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$recovered_state"
		_AIDEVOPS_RELEASE_LANE_HEAD="2222222222222222222222222222222222222222"
		return 0
	}
	_AIDEVOPS_RELEASE_LANE_TOKEN="token-old"
	if release_lane_update test/repo 101 preparing; then
		return 1
	fi
	return 0
)

run_aggregate_recovery_rotation_test() (
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101","phase":"remote-publication","tag":"v1.2.3","updated_at":"2026-08-09T00:00:00Z","operation_token":"token-old"}'
	local old_state="$state"
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		[[ "$repo" == "test/repo" && "$expected_head" == "1111111111111111111111111111111111111111" ]] || return 1
		state="$state_json"
		return 0
	}
	release_lane_begin_aggregate_recovery test/repo 101 v1.2.3 101 \
		'101@1111111111111111111111111111111111111111,102@2222222222222222222222222222222222222222' \
		3333333333333333333333333333333333333333 || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-recovery" &&
	"$(jq -r '.expected_sources' <<<"$state")" == 101@1111111111111111111111111111111111111111,102@2222222222222222222222222222222222222222 &&
	"$(jq -r '.operation_token' <<<"$state")" != "token-old" &&
	"$(jq -r '.aggregate_recovery.provisional_tag_object' <<<"$state")" == 3333333333333333333333333333333333333333 &&
	"$(jq -c '.aggregate_recovery.previous_state' <<<"$state")" == "$old_state" ]] || return 1
	release_lane_restore_aggregate_recovery test/repo 101 "$old_state" || return 1
	[[ "$state" == "$old_state" ]]
	return $?
)

run_aggregate_recovery_rejection_test() (
	local state_mode="competing"
	release_lane_read() {
		if [[ "$state_mode" == "terminal" ]]; then
			_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101","phase":"remote-publication","tag":"v1.2.3","updated_at":"2026-08-09T00:00:00Z","operation_token":"token-old","terminal_receipt":{"status":"published"}}'
		else
			_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":202,"expected_sources":"202","phase":"remote-publication","tag":"v1.2.3","updated_at":"2026-08-09T00:00:00Z","operation_token":"token-old"}'
		fi
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	if release_lane_begin_aggregate_recovery test/repo 101 v1.2.3 101 \
		'101@1111111111111111111111111111111111111111' \
		3333333333333333333333333333333333333333; then
		return 1
	fi
	state_mode="terminal"
	if release_lane_begin_aggregate_recovery test/repo 101 v1.2.3 101 \
		'101@1111111111111111111111111111111111111111' \
		3333333333333333333333333333333333333333; then
		return 1
	fi
	return 0
)

run_reserved_aggregate_authorization_test() (
	local old_state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101","phase":"reserved","tag":null,"updated_at":"2026-08-09T00:00:00Z","operation_token":"token-owned","terminal_receipt":null}'
	local state="$old_state"
	local expanded='101@1111111111111111111111111111111111111111,102@2222222222222222222222222222222222222222'
	local write_conflict=false
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		[[ "$repo" == "test/repo" && "$expected_head" == "1111111111111111111111111111111111111111" ]] || return 1
		[[ "$write_conflict" == "false" ]] || return 2
		state="$state_json"
		return 0
	}
	_AIDEVOPS_RELEASE_LANE_TOKEN="token-owned"
	release_lane_expand_reserved_authorization test/repo 101 \
		'101' "$expanded" || return 1
	[[ "$(jq -r '.expected_sources' <<<"$state")" == "$expanded" ]] || return 1
	release_lane_restore_reserved_authorization test/repo 101 "$expanded" "$old_state" || return 1
	[[ "$state" == "$old_state" ]] || return 1
	write_conflict=true
	if release_lane_expand_reserved_authorization test/repo 101 '101' "$expanded"; then
		return 1
	fi
	[[ "$state" == "$old_state" ]] || return 1
	write_conflict=false
	state=$(jq -c '.tag="v1.2.3"' <<<"$old_state") || return 1
	if release_lane_expand_reserved_authorization test/repo 101 \
		'101' "$expanded"; then
		return 1
	fi
	state=$(jq -c '.tag=null | .terminal_receipt={status:"published"}' <<<"$old_state") || return 1
	if release_lane_expand_reserved_authorization test/repo 101 \
		'101' "$expanded"; then
		return 1
	fi
	return 0
)

if run_competing_source_test; then assert_result 'competing source receives active lane and reconcile action' true; else assert_result 'competing source receives active lane and reconcile action' false; fi
if run_same_source_adoption_test; then assert_result 'same source adopts durable lane without another bump' true; else assert_result 'same source adopts durable lane without another bump' false; fi
if run_terminal_lane_reacquire_test; then assert_result 'terminal lane can be atomically reserved by a later source' true; else assert_result 'terminal lane can be atomically reserved by a later source' false; fi
if run_setup_guard_test; then assert_result 'exact-tag deployment blocks generic setup and permits matching owner' true; else assert_result 'exact-tag deployment blocks generic setup and permits matching owner' false; fi
if run_http_classification_test; then assert_result 'only verified HTTP 404 is classified as an absent lane' true; else assert_result 'only verified HTTP 404 is classified as an absent lane' false; fi
if run_legacy_and_api_failure_test; then assert_result 'legacy absent lane remains compatible while API uncertainty blocks setup' true; else assert_result 'legacy absent lane remains compatible while API uncertainty blocks setup' false; fi
if run_stale_same_source_recovery_test; then assert_result 'stale recovery rotates its token and fences the prior owner' true; else assert_result 'stale recovery rotates its token and fences the prior owner' false; fi
if run_aggregate_recovery_rotation_test; then assert_result 'reviewed aggregate recovery rotates and can restore its lane transaction' true; else assert_result 'reviewed aggregate recovery rotates and can restore its lane transaction' false; fi
if run_aggregate_recovery_rejection_test; then assert_result 'aggregate recovery rejects competing owners and terminal lanes' true; else assert_result 'aggregate recovery rejects competing owners and terminal lanes' false; fi
if run_reserved_aggregate_authorization_test; then assert_result 'reserved aggregate authorization uses owned CAS expansion and exact rollback' true; else assert_result 'reserved aggregate authorization uses owned CAS expansion and exact rollback' false; fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
