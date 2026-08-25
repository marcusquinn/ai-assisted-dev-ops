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

run_merge_guard_test() (
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"remote-publication","tag":"v1.2.3","operation_token":"token-old"}'
	local output=""
	local rc=0
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		return 0
	}
	gh() {
		local endpoint="${2:-}"
		case "$endpoint" in
		"repos/test/repo/pulls/404")
			jq -cn '{number:404,state:"open",base:{ref:"main",sha:("4" * 40)},
				head:{sha:("5" * 40)},body:(
				"Aidevops-Release-Aggregator-PR: 404\n"
				+ "Aidevops-Release-Aggregates: 101@" + ("1" * 40)
			)}'
			;;
		"repos/test/repo/pulls/404/files?per_page=1") printf '0\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	output=$(AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 202 main feature/ordinary 2>&1) || rc=$?
	[[ "$rc" -eq 75 && "$output" == *"source_pr=101"* && "$output" == *"phase=remote-publication"* ]] || return 1
	AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 101 main feature/release-owner || return 1
	AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 303 main chore/release-v1.2.3-provenance || return 1
	AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 404 main release/aggregate-recovery || return 1
	for recovery_phase in aggregation-recovery aggregation-recovery-refresh aggregate-publication-committing reserved-authorization-refresh aggregation-successor-preparing; do
		state=$(jq -cn --arg phase "$recovery_phase" \
			'{schema_version:1,repository:"test/repo",active:true,source_pr:101,phase:$phase,
			  tag:(if ($phase == "reserved-authorization-refresh" or $phase == "aggregation-successor-preparing") then null else "v1.2.3" end),
			  operation_token:"token-old"}')
		rc=0
		output=$(AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
			release_lane_merge_guard test/repo 202 main feature/ordinary 2>&1) || rc=$?
		[[ "$rc" -eq 75 && "$output" == *"phase=${recovery_phase}"* ]] || return 1
		rc=0
		AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
			release_lane_merge_guard test/repo 303 main chore/release-v1.2.3-provenance \
			>/dev/null 2>&1 || rc=$?
		if [[ "$recovery_phase" == "aggregate-publication-committing" ]]; then
			[[ "$rc" -eq 0 ]] || return 1
		else
			[[ "$rc" -eq 75 ]] || return 1
		fi
		rc=0
		AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
			release_lane_merge_guard test/repo 404 main release/aggregate-recovery \
			>/dev/null 2>&1 || rc=$?
		if [[ "$recovery_phase" == "aggregate-publication-committing" ||
			"$recovery_phase" == "reserved-authorization-refresh" ||
			"$recovery_phase" == "aggregation-successor-preparing" ]]; then
			[[ "$rc" -eq 75 ]] || return 1
		else
			[[ "$rc" -eq 0 ]] || return 1
		fi
	done
	state='{"schema_version":1,"repository":"test/repo","active":false,"source_pr":101,"phase":"terminal","tag":"v1.2.3","operation_token":"token-old","terminal_receipt":"superseded"}'
	AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 202 main feature/ordinary || return 1
	return 0
)

run_merge_guard_api_uncertainty_test() (
	release_lane_read() { return 1; }
	if AIDEVOPS_RELEASE_LANE_COORDINATED_REPO=test/repo \
		release_lane_merge_guard test/repo 202 main feature/ordinary >/dev/null 2>&1; then
		return 1
	fi
	return 0
)

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

run_default_stale_boundary_and_fencing_test() (
	local original_state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"reserved","tag":null,"updated_at":"2020-01-01T00:00:00Z","operation_token":"token-old","terminal_receipt":null}'
	local state="$original_state"
	local written=""
	export AIDEVOPS_TEST_NOW_EPOCH=1000000299
	local writes=0
	date() {
		if [[ "${1:-}" == "-u" && "${2:-}" == "-d" ]]; then
			printf '%s\n' 1000000000
		elif [[ "${1:-}" == "+%s" ]]; then
			printf '%s\n' "$AIDEVOPS_TEST_NOW_EPOCH"
		else
			command date "$@"
		fi
		return 0
	}
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD="1111111111111111111111111111111111111111"
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		written="$state_json"
		[[ "$repo" == "test/repo" && "$expected_head" == "1111111111111111111111111111111111111111" ]] || return 1
		state="$state_json"
		writes=$((writes + 1))
		return 0
	}
	release_lane_acquire test/repo 101 101 >/dev/null || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "adopted" && "$writes" -eq 0 &&
		"$_AIDEVOPS_RELEASE_LANE_TOKEN" == "token-old" ]] || return 1
	AIDEVOPS_TEST_NOW_EPOCH=1000000300
	release_lane_acquire test/repo 101 101 >/dev/null || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_RESULT" == "acquired" && "$(jq -r '.phase' <<<"$written")" == "reserved" &&
	"$(jq -r '.operation_token' <<<"$written")" != "token-old" && "$writes" -eq 1 ]] || return 1
	_AIDEVOPS_RELEASE_LANE_TOKEN="token-old"
	if release_lane_update test/repo 101 preparing; then
		return 1
	fi
	return 0
)

run_stale_reclamation_guard_test() (
	local base_state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"phase":"reserved","tag":null,"updated_at":"2020-01-01T00:00:00Z","operation_token":"token-old","terminal_receipt":null}'
	local state="$base_state"
	date() {
		if [[ "${1:-}" == "-u" && "${2:-}" == "-d" ]]; then
			printf '%s\n' 1000000000
		elif [[ "${1:-}" == "+%s" ]]; then
			printf '%s\n' 1000000300
		else
			command date "$@"
		fi
		return 0
	}
	state=$(jq -c '.phase="preparing"' <<<"$base_state") || return 1
	if _release_lane_stale_prepublication "$state"; then return 1; fi
	state=$(jq -c '.tag="v1.2.3"' <<<"$base_state") || return 1
	if _release_lane_stale_prepublication "$state"; then return 1; fi
	state=$(jq -c '.terminal_receipt={status:"published"}' <<<"$base_state") || return 1
	if _release_lane_stale_prepublication "$state"; then return 1; fi
	return 0
)

run_aggregate_recovery_rotation_test() (
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101","phase":"remote-publication","tag":"v1.2.3","updated_at":"2026-08-09T00:00:00Z","operation_token":"token-old"}'
	local old_state="$state"
	local first_recovery_token=""
	local refresh_token=""
	local initial_authorization='101@1111111111111111111111111111111111111111'
	local initial_expanded='101@1111111111111111111111111111111111111111,102@2222222222222222222222222222222222222222'
	local refreshed_expanded=""
	local claimed_state=""
	local write_mode="success"
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
		[[ "$write_mode" == "success" ]] || return 1
		return 0
	}
	write_mode="ambiguous"
	release_lane_begin_aggregate_recovery test/repo 101 v1.2.3 101 \
		"$initial_authorization" "$initial_expanded" \
		3333333333333333333333333333333333333333 || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-recovery-refresh" &&
	"$(jq -r '.expected_sources' <<<"$state")" == "$initial_expanded" &&
	"$(jq -r '.operation_token' <<<"$state")" != "token-old" &&
	"$(jq -r '.aggregate_recovery.provisional_tag_object' <<<"$state")" == 3333333333333333333333333333333333333333 &&
	"$(jq -r '.aggregate_recovery.refresh.previous_expected_sources' <<<"$state")" == "$initial_authorization" &&
	"$(jq -r '.aggregate_recovery.refresh.pending_expected_sources' <<<"$state")" == "$initial_expanded" &&
	"$(jq -c '.aggregate_recovery.previous_state' <<<"$state")" == "$old_state" ]] || return 1
	release_lane_finish_aggregate_refresh test/repo 101 v1.2.3 "$initial_authorization" \
		"$initial_expanded" 3333333333333333333333333333333333333333 || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-recovery" &&
	"$(jq -r '.aggregate_recovery.refresh // empty' <<<"$state")" == "" ]] || return 1
	first_recovery_token=$(jq -r '.operation_token' <<<"$state") || return 1
	refreshed_expanded="${initial_expanded},103@4444444444444444444444444444444444444444"
	write_mode="ambiguous"
	release_lane_begin_aggregate_refresh test/repo 101 v1.2.3 "$initial_expanded" \
		"$refreshed_expanded" 3333333333333333333333333333333333333333 || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-recovery-refresh" &&
	"$(jq -r '.expected_sources' <<<"$state")" == "$refreshed_expanded" &&
	"$(jq -r '.operation_token' <<<"$state")" != "$first_recovery_token" &&
	"$(jq -c '.aggregate_recovery.previous_state' <<<"$state")" == "$old_state" &&
	"$(jq -r '.aggregate_recovery.refresh.previous_expected_sources' <<<"$state")" == "$initial_expanded" &&
	"$(jq -r '.aggregate_recovery.refresh.pending_expected_sources' <<<"$state")" == "$refreshed_expanded" &&
	"$(jq -r '.aggregate_recovery.provisional_tag_object' <<<"$state")" == 3333333333333333333333333333333333333333 ]] || return 1
	refresh_token=$(jq -r '.operation_token' <<<"$state") || return 1
	write_mode="ambiguous"
	release_lane_finish_aggregate_refresh test/repo 101 v1.2.3 "$initial_expanded" \
		"$refreshed_expanded" 3333333333333333333333333333333333333333 || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-recovery" &&
	"$(jq -r '.operation_token' <<<"$state")" == "$refresh_token" &&
	"$(jq -r '.expected_sources' <<<"$state")" == "$refreshed_expanded" &&
	"$(jq -r '.aggregate_recovery.refresh // empty' <<<"$state")" == "" &&
	"$(jq -c '.aggregate_recovery.previous_state' <<<"$state")" == "$old_state" ]] || return 1
	write_mode="ambiguous"
	release_lane_claim_aggregate_publication test/repo 101 v1.2.3 "$refreshed_expanded" || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregate-publication-committing" &&
	"$(jq -r '.operation_token' <<<"$state")" == "$refresh_token" ]] || return 1
	release_lane_verify_aggregate_publication test/repo 101 v1.2.3 "$refreshed_expanded" || return 1
	claimed_state="$state"
	state=$(jq -c '.operation_token="lane-rotated"' <<<"$state") || return 1
	if release_lane_verify_aggregate_publication test/repo 101 v1.2.3 "$refreshed_expanded"; then
		return 1
	fi
	state="$claimed_state"
	write_mode="success"
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
		'101@1111111111111111111111111111111111111111' \
		3333333333333333333333333333333333333333; then
		return 1
	fi
	state_mode="terminal"
	if release_lane_begin_aggregate_recovery test/repo 101 v1.2.3 101 \
		'101@1111111111111111111111111111111111111111' \
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
	local first_token=""
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
	[[ "$(jq -r '.phase' <<<"$state")" == "reserved-authorization-refresh" &&
	"$(jq -r '.expected_sources' <<<"$state")" == "$expanded" &&
	"$(jq -r '.operation_token' <<<"$state")" != "token-owned" &&
	"$(jq -r '.reserved_authorization_refresh.previous_expected_sources' <<<"$state")" == "101" &&
	"$(jq -r '.reserved_authorization_refresh.pending_expected_sources' <<<"$state")" == "$expanded" &&
	"$(jq -c '.reserved_authorization_refresh.previous_state' <<<"$state")" == "$old_state" ]] || return 1
	first_token=$(jq -r '.operation_token' <<<"$state") || return 1
	_AIDEVOPS_RELEASE_LANE_TOKEN="token-owned"
	release_lane_expand_reserved_authorization test/repo 101 '101' "$expanded" || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "$first_token" ]] || return 1
	release_lane_finish_reserved_authorization test/repo 101 '101' "$expanded" || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "reserved" &&
	"$(jq -r '.expected_sources' <<<"$state")" == "$expanded" &&
	"$(jq -r '.reserved_authorization_refresh // empty' <<<"$state")" == "" ]] || return 1
	state="$old_state"
	_AIDEVOPS_RELEASE_LANE_TOKEN="token-owned"
	release_lane_expand_reserved_authorization test/repo 101 '101' "$expanded" || return 1
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

run_failed_prepublication_reopen_test() (
	local previous='101@1111111111111111111111111111111111111111'
	local failed_merge=2222222222222222222222222222222222222222
	local attempted_tag=v1.2.3
	local original_state=""
	local state=""
	local write_mode="ambiguous"
	local recovered_token=""
	original_state=$(jq -cn --arg expected "$previous" '
		{schema_version:1,repository:"test/repo",active:true,source_pr:101,
		 expected_sources:$expected,phase:"reconcile-required",tag:null,
		 updated_at:"2026-08-24T02:01:43Z",owner:"process-old",
		 operation_token:"token-owned",terminal_receipt:null}
	') || return 1
	state="$original_state"
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
		if [[ "$write_mode" == "conflict" ]]; then
			return 2
		fi
		state="$state_json"
		[[ "$write_mode" == "success" ]] && return 0
		return 2
	}
	_AIDEVOPS_RELEASE_LANE_TOKEN=token-owned
	release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null || return 1
	recovered_token=$(jq -er '.operation_token' <<<"$state") || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "reserved" && "$recovered_token" != "token-owned" &&
	"$_AIDEVOPS_RELEASE_LANE_TOKEN" == "$recovered_token" &&
	"$(jq -r '.prepublication_recovery.previous_phase' <<<"$state")" == "reconcile-required" &&
	"$(jq -r '.prepublication_recovery.previous_updated_at' <<<"$state")" == "2026-08-24T02:01:43Z" &&
	"$(jq -r '.prepublication_recovery.failed_source_pr' <<<"$state")" == "99" &&
	"$(jq -r '.prepublication_recovery.failed_source_merge' <<<"$state")" == "$failed_merge" &&
	"$(jq -r '.prepublication_recovery.attempted_tag' <<<"$state")" == "$attempted_tag" ]] || return 1
	state="$original_state"
	write_mode=conflict
	_AIDEVOPS_RELEASE_LANE_TOKEN=token-owned
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null 2>&1; then
		return 1
	fi
	[[ "$state" == "$original_state" ]] || return 1
	write_mode=success
	_AIDEVOPS_RELEASE_LANE_TOKEN=stale-token
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null 2>&1; then
		return 1
	fi
	_AIDEVOPS_RELEASE_LANE_TOKEN=token-owned
	state=$(jq -c '.tag="v1.2.3"' <<<"$original_state") || return 1
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null 2>&1; then
		return 1
	fi
	state=$(jq -c '.tag=null | .terminal_receipt="published"' <<<"$original_state") || return 1
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null 2>&1; then
		return 1
	fi
	state=$(jq -c '.terminal_receipt=null | .phase="preparing"' <<<"$original_state") || return 1
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null 2>&1; then
		return 1
	fi
	state="$original_state"
	_AIDEVOPS_RELEASE_LANE_TOKEN=token-owned
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "" \
		>/dev/null 2>&1; then
		return 1
	fi
	if release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" v1.2 \
		>/dev/null 2>&1; then
		return 1
	fi
	return 0
)

run_failed_prepublication_resume_guard_test() (
	local previous='101@1111111111111111111111111111111111111111'
	local failed_merge=2222222222222222222222222222222222222222
	local attempted_tag=v1.2.3
	local recovered_at=2026-08-24T02:02:00Z
	local expanded='101@1111111111111111111111111111111111111111,102@2222222222222222222222222222222222222222'
	local state=""
	local resumed_token=""
	local stale_state=""
	local write_mode=ambiguous
	state=$(jq -cn --arg expected "$previous" --arg failed_merge "$failed_merge" \
		--arg attempted_tag "$attempted_tag" --arg recovered_at "$recovered_at" '
		{schema_version:1,repository:"test/repo",active:true,source_pr:101,
		 expected_sources:$expected,phase:"reserved",tag:null,
		 updated_at:"2026-08-24T02:02:00Z",owner:"process-recovered",
		 operation_token:"token-recovered",terminal_receipt:null,
			 prepublication_recovery:{previous_phase:"reconcile-required",
		  previous_updated_at:"2026-08-24T02:01:43Z",failed_source_pr:99,
		  failed_source_merge:$failed_merge,attempted_tag:$attempted_tag,recovered_at:$recovered_at}}
	') || return 1
	state=$(jq -c --arg expected "$previous" '
		.prepublication_recovery.failed_expected_sources=$expected
		| .prepublication_recovery.current_expected_sources=$expected
	' <<<"$state") || return 1
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
		[[ "$write_mode" == "success" ]] && return 0
		return 2
	}
	_AIDEVOPS_RELEASE_LANE_TOKEN=token-recovered
	release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null || return 1
	resumed_token=$(jq -er '.operation_token' <<<"$state") || return 1
	[[ "$resumed_token" != "token-recovered" && "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "$resumed_token" &&
		"$(jq -r '.prepublication_recovery.recovered_at' <<<"$state")" == "$recovered_at" &&
		-n "$(jq -r '.prepublication_recovery.revalidated_at // ""' <<<"$state")" ]] || return 1
	stale_state=$(jq -c '.updated_at="2020-01-01T00:00:00Z"' <<<"$state") || return 1
	export AIDEVOPS_RELEASE_LANE_STALE_SECONDS=1
	if _release_lane_stale_prepublication "$stale_state"; then
		return 1
	fi
	release_lane_expand_reserved_authorization test/repo 101 "$previous" "$expanded" || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "reserved-authorization-refresh" &&
	"$(jq -r '.prepublication_recovery.current_expected_sources' <<<"$state")" == "$expanded" ]] || return 1
	resumed_token="$_AIDEVOPS_RELEASE_LANE_TOKEN"
	release_lane_reopen_failed_prepublication test/repo 101 "$previous" 99 "$failed_merge" "$attempted_tag" \
		>/dev/null || return 1
	[[ "$(jq -r '.phase' <<<"$state")" == "reserved-authorization-refresh" &&
	"$_AIDEVOPS_RELEASE_LANE_TOKEN" != "$resumed_token" ]] || return 1
	release_lane_finish_reserved_authorization test/repo 101 "$previous" "$expanded" || return 1
	write_mode=success
	release_lane_update test/repo 101 preparing || return 1
	jq -e '.phase == "preparing" and ((.prepublication_recovery // null) == null)' \
		<<<"$state" >/dev/null || return 1
	return 0
)

run_aggregate_successor_transaction_test() {
	local state='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101@1111111111111111111111111111111111111111","phase":"reserved","tag":null,"operation_token":"lane-old","updated_at":"2026-08-24T00:00:00Z","terminal_receipt":null}'
	local first_token=""
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$state"
		_AIDEVOPS_RELEASE_LANE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
		return 0
	}
	_release_lane_write() {
		local repo="$1"
		local state_json="$2"
		local expected_head="$3"
		[[ "$repo" == "test/repo" && "$expected_head" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || return 1
		state="$state_json"
		return 0
	}
	release_lane_begin_aggregate_successor test/repo 202 \
		bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
		'101@1111111111111111111111111111111111111111,203@3333333333333333333333333333333333333333' \
		release/aggregate-successor-202-bbbbbbbbbbbb || return 1
	first_token="$_AIDEVOPS_RELEASE_LANE_TOKEN"
	[[ "$(jq -r '.phase' <<<"$state")" == "aggregation-successor-preparing" ]] || return 1
	release_lane_begin_aggregate_successor test/repo 202 \
		bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
		'101@1111111111111111111111111111111111111111,203@3333333333333333333333333333333333333333' \
		release/aggregate-successor-202-bbbbbbbbbbbb || return 1
	[[ "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "$first_token" ]] || return 1
	if release_lane_begin_aggregate_successor test/repo 202 \
		cccccccccccccccccccccccccccccccccccccccc \
		'101@1111111111111111111111111111111111111111,203@3333333333333333333333333333333333333333' \
		release/aggregate-successor-202-cccccccccccc; then
		return 1
	fi
	release_lane_bind_aggregate_successor_pr test/repo 204 || return 1
	release_lane_finish_aggregate_successor test/repo 204 dddddddddddddddddddddddddddddddddddddddd || return 1
	jq -e --arg token "$first_token" '
		.phase == "reserved" and .operation_token == $token
		and .aggregate_successor.status == "ready" and .aggregate_successor.pr == 204
		and .aggregate_successor.head_sha == "dddddddddddddddddddddddddddddddddddddddd"
		and ((.aggregate_successor.previous_state // null) == null)
	' <<<"$state" >/dev/null
	return $?
}

if run_competing_source_test; then assert_result 'competing source receives active lane and reconcile action' true; else assert_result 'competing source receives active lane and reconcile action' false; fi
if run_same_source_adoption_test; then assert_result 'same source adopts durable lane without another bump' true; else assert_result 'same source adopts durable lane without another bump' false; fi
if run_terminal_lane_reacquire_test; then assert_result 'terminal lane can be atomically reserved by a later source' true; else assert_result 'terminal lane can be atomically reserved by a later source' false; fi
if run_setup_guard_test; then assert_result 'exact-tag deployment blocks generic setup and permits matching owner' true; else assert_result 'exact-tag deployment blocks generic setup and permits matching owner' false; fi
if run_merge_guard_test; then assert_result 'exact-tip lane blocks ordinary merges while preserving release ownership and terminal recovery' true; else assert_result 'exact-tip lane blocks ordinary merges while preserving release ownership and terminal recovery' false; fi
if run_merge_guard_api_uncertainty_test; then assert_result 'merge coordination fails closed when lane state is unavailable' true; else assert_result 'merge coordination fails closed when lane state is unavailable' false; fi
if run_http_classification_test; then assert_result 'only verified HTTP 404 is classified as an absent lane' true; else assert_result 'only verified HTTP 404 is classified as an absent lane' false; fi
if run_legacy_and_api_failure_test; then assert_result 'legacy absent lane remains compatible while API uncertainty blocks setup' true; else assert_result 'legacy absent lane remains compatible while API uncertainty blocks setup' false; fi
if run_default_stale_boundary_and_fencing_test; then assert_result 'default stale recovery adopts at 299s, reclaims at 300s, and fences the prior owner' true; else assert_result 'default stale recovery adopts at 299s, reclaims at 300s, and fences the prior owner' false; fi
if run_stale_reclamation_guard_test; then assert_result 'preparing, tagged, and receipted lanes remain reconcile-only' true; else assert_result 'preparing, tagged, and receipted lanes remain reconcile-only' false; fi
if run_aggregate_recovery_rotation_test; then assert_result 'reviewed aggregate recovery rotates and can restore its lane transaction' true; else assert_result 'reviewed aggregate recovery rotates and can restore its lane transaction' false; fi
if run_aggregate_recovery_rejection_test; then assert_result 'aggregate recovery rejects competing owners and terminal lanes' true; else assert_result 'aggregate recovery rejects competing owners and terminal lanes' false; fi
if run_reserved_aggregate_authorization_test; then assert_result 'reserved aggregate authorization rotates through a resumable lane-first transaction' true; else assert_result 'reserved aggregate authorization rotates through a resumable lane-first transaction' false; fi
if run_failed_prepublication_reopen_test; then assert_result 'verified failed pre-publication lane recovery rotates ownership and rejects unsafe states' true; else assert_result 'verified failed pre-publication lane recovery rotates ownership and rejects unsafe states' false; fi
if run_failed_prepublication_resume_guard_test; then assert_result 'recovered pre-publication markers revalidate fenced refreshes and clear only at preparing' true; else assert_result 'recovered pre-publication markers revalidate fenced refreshes and clear only at preparing' false; fi
if run_aggregate_successor_transaction_test; then assert_result 'successor aggregation retries converge through one lane CAS transaction' true; else assert_result 'successor aggregation retries converge through one lane CAS transaction' false; fi

printf '\nTests run: %s, Failures: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
