#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2218 # Test phases intentionally replace sourced helpers with state-specific stubs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export REPO_ROOT="$TEST_ROOT"
source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"

CHANNEL_MODE="absent"

_full_loop_recovery_verify_all_remote_tags_absent() {
	[[ "$CHANNEL_MODE" != "remote-tag" ]]
	return $?
}

gh() {
	if [[ " $* " == *" --include "* ]]; then
		if [[ "$CHANNEL_MODE" == "github-release" ]]; then
			printf 'HTTP/2.0 200 OK\n\n'
		else
			printf 'HTTP/2.0 404 Not Found\n\n'
		fi
		return 0
	fi
	if [[ "$CHANNEL_MODE" == "homebrew" ]]; then
		printf 'url "https://example.invalid/refs/tags/v1.2.3.tar.gz"\n'
	else
		printf 'url "https://example.invalid/refs/tags/v1.2.2.tar.gz"\n'
	fi
	return 0
}

npm() {
	if [[ "${2:-}" == "aidevops@1.2.3" ]]; then
		if [[ "$CHANNEL_MODE" == "npm" ]]; then
			printf '"1.2.3"\n'
			return 0
		fi
		printf 'npm error code E404\n' >&2
		return 1
	fi
	return 0
}

CHANNEL_MODE=absent
_full_loop_recovery_verify_channels_absent test/repo v1.2.3
printf 'PASS recovery accepts only confirmed absent remote channels\n'

for CHANNEL_MODE in remote-tag github-release npm homebrew; do
	if _full_loop_recovery_verify_channels_absent test/repo v1.2.3 >/dev/null 2>&1; then
		printf 'FAIL recovery accepted published channel mode %s\n' "$CHANNEL_MODE"
		exit 1
	fi
done
printf 'PASS recovery rejects remote tag, GitHub, npm, and Homebrew publication\n'

(
	git() {
		printf '1111111111111111111111111111111111111111\n'
		return 0
	}
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=1111111111111111111111111111111111111111
	CHANNEL_MODE=absent
	_full_loop_recovery_tag_rollback_safe test/repo v1.2.3
	CHANNEL_MODE=npm
	if _full_loop_recovery_tag_rollback_safe test/repo v1.2.3 >/dev/null 2>&1; then
		exit 1
	fi
)
printf 'PASS rollback requires every publication channel to remain absent\n'

_FULL_LOOP_PHASE_FAILED=failed
_FULL_LOOP_RELEASE_NOT_REQUESTED=not-requested
_full_loop_release_receipt_path() {
	printf '%s/release.status\n' "$TEST_ROOT"
	return 0
}
printf 'published\n' >"${TEST_ROOT}/release.status"
if _full_loop_recovery_validate_receipt test/repo 42 >/dev/null 2>&1; then
	printf 'FAIL recovery accepted a terminal release receipt\n'
	exit 1
fi
INTENT_MODE=match
INTERRUPTED_INTENT_MODE=mismatch
_full_loop_release_validate_published_reconciliation_intent() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local source_json="$4"
	[[ "$INTENT_MODE" == "match" && "$repo" == "test/repo" && "$source_pr" == "42" &&
		"$tag_name" == "v1.2.3" && "$source_json" == '{"source_pr":42}' ]]
	return $?
}
_full_loop_recovery_validate_interrupted_publication_intent() {
	local repo="$1"
	local source_pr="$2"
	local tag_name="$3"
	local source_json="$4"
	[[ "$INTERRUPTED_INTENT_MODE" == "match" && "$repo" == "test/repo" && "$source_pr" == "42" &&
		"$tag_name" == "v1.2.3" && "$source_json" == '{"source_pr":42}' ]]
	return $?
}
printf 'not-requested\n' >"${TEST_ROOT}/release.status"
_full_loop_recovery_validate_receipt test/repo 42 v1.2.3 '{"source_pr":42}'
INTENT_MODE=mismatch
INTERRUPTED_INTENT_MODE=match
_full_loop_recovery_validate_receipt test/repo 42 v1.2.3 '{"source_pr":42}'
INTERRUPTED_INTENT_MODE=mismatch
if _full_loop_recovery_validate_receipt test/repo 42 v1.2.3 '{"source_pr":42}' >/dev/null 2>&1; then
	printf 'FAIL recovery accepted release:not-requested without matching publication intent\n'
	exit 1
fi
_full_loop_recovery_validate_reserved_receipt test/repo 42
printf 'published\n' >"${TEST_ROOT}/release.status"
if _full_loop_recovery_validate_reserved_receipt test/repo 42 >/dev/null 2>&1; then
	printf 'FAIL reserved authorization migration accepted a published receipt\n'
	exit 1
fi
printf 'failed\n' >"${TEST_ROOT}/release.status"
_full_loop_recovery_validate_receipt test/repo 42
_full_loop_recovery_validate_reserved_receipt test/repo 42
printf 'PASS recovery distinguishes explicit pre-tag migration from terminal aggregate recovery\n'

STATE_LOG="${TEST_ROOT}/state.log"
: >"$STATE_LOG"
_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333"
_full_loop_read_release_authorization() {
	printf '42@2222222222222222222222222222222222222222\n'
	return 0
}
release_authorization_subset() { return 0; }
_full_loop_expand_release_authorization_for_aggregate() {
	printf 'expand\n' >>"$STATE_LOG"
	return 0
}
release_lane_read() { return 1; }
_full_loop_restore_release_authorization_after_aggregate() {
	printf 'restore-auth\n' >>"$STATE_LOG"
	return 0
}
if _full_loop_recovery_begin_state_transaction test/repo 42 v1.2.3; then
	printf 'FAIL lane read failure began aggregate recovery\n'
	exit 1
fi
[[ ! -s "$STATE_LOG" ]]
printf 'PASS lane uncertainty blocks authorization expansion before mutation\n'

(
	transaction_log="${TEST_ROOT}/initial-transaction.log"
	old_authorization='42@2222222222222222222222222222222222222222'
	expanded_authorization="${old_authorization},43@3333333333333333333333333333333333333333"
	authorization="$old_authorization"
	lane_phase=remote-publication
	auth_write_mode=success
	: >"$transaction_log"
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$expanded_authorization"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT=1111111111111111111111111111111111111111
	_full_loop_read_release_authorization() {
		printf '%s\n' "$authorization"
		return 0
	}
	_full_loop_read_release_authorization_recovery_snapshot() { return 1; }
	release_authorization_subset() { return 0; }
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg phase "$lane_phase" \
			'{schema_version:1,active:true,source_pr:42,tag:"v1.2.3",phase:$phase,expected_sources:"42",operation_token:"lane-old"}')
		return 0
	}
	release_lane_begin_aggregate_recovery() {
		local repo="$1"
		local source_pr="$2"
		local tag_name="$3"
		local lane_sources="$4"
		local previous_sources="$5"
		local expected_sources="$6"
		local provisional="$7"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && "$tag_name" == "v1.2.3" ]] || return 1
		[[ "$lane_sources" == "42" && "$previous_sources" == "$old_authorization" ]] || return 1
		[[ "$expected_sources" == "$expanded_authorization" && "$provisional" == "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" ]] || return 1
		printf 'fence\n' >>"$transaction_log"
		lane_phase=aggregation-recovery-refresh
		_AIDEVOPS_RELEASE_LANE_TOKEN=lane-new
		_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT='{"phase":"remote-publication","operation_token":"lane-old"}'
		return 0
	}
	_full_loop_expand_release_authorization_for_aggregate() {
		[[ "$lane_phase" == "aggregation-recovery-refresh" ]] || return 1
		printf 'authorize\n' >>"$transaction_log"
		[[ "$auth_write_mode" == "success" ]] || return 1
		authorization="$expanded_authorization"
		return 0
	}
	release_lane_finish_aggregate_refresh() {
		[[ "$authorization" == "$expanded_authorization" ]] || return 1
		printf 'finish\n' >>"$transaction_log"
		lane_phase=aggregation-recovery
		return 0
	}
	release_lane_restore_aggregate_recovery() {
		printf 'restore-lane\n' >>"$transaction_log"
		lane_phase=remote-publication
		return 0
	}
	_full_loop_recovery_begin_state_transaction test/repo 42 v1.2.3
	[[ "$(tr '\n' ' ' <"$transaction_log")" == "fence authorize finish " ]]
	[[ "$authorization" == "$expanded_authorization" && "$lane_phase" == "aggregation-recovery" ]]

	authorization="$old_authorization"
	lane_phase=remote-publication
	auth_write_mode=failure
	: >"$transaction_log"
	if _full_loop_recovery_begin_state_transaction test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$transaction_log")" == "fence authorize restore-lane " ]]
	[[ "$authorization" == "$old_authorization" && "$lane_phase" == "remote-publication" ]]
)
printf 'PASS initial recovery fences the lane before authorization and restores pre-write failures\n'

_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333"
_full_loop_read_release_authorization() {
	printf '%s\n' "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"
	return 0
}
_full_loop_read_release_authorization_recovery_snapshot() {
	printf '%s\n' '{"schema_version":1,"repository":"test/repo","requested_pr":42,"expected_sources":[{"pr":42,"merge":"2222222222222222222222222222222222222222"}],"recorded_at":"2026-08-09T00:00:00Z"}'
	return 0
}
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":42,"expected_sources":"42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333","phase":"aggregation-recovery","tag":"v1.2.3","operation_token":"lane-new","aggregate_recovery":{"provisional_tag_object":"1111111111111111111111111111111111111111","previous_state":{"schema_version":1,"repository":"test/repo","active":true,"source_pr":42,"expected_sources":"42","phase":"remote-publication","tag":"v1.2.3","operation_token":"lane-old"}}}'
	return 0
}
_full_loop_recovery_validate_interrupted_publication_intent() {
	release_lane_read
	return $?
}
_full_loop_recovery_load_existing_state_transaction test/repo 42 v1.2.3
[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" == "42@2222222222222222222222222222222222222222" ]]
[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" == 1111111111111111111111111111111111111111 ]]
[[ "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "lane-new" ]]
printf 'PASS interrupted recovery reloads exact authorization and lane snapshots\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	root_merge=2222222222222222222222222222222222222222
	current_merge=3333333333333333333333333333333333333333
	refreshed_merge=4444444444444444444444444444444444444444
	provisional=1111111111111111111111111111111111111111
	replacement=5555555555555555555555555555555555555555
	root_authorization="42@${root_merge}"
	test_current_authorization="${root_authorization},43@${current_merge}"
	test_refreshed_authorization="${test_current_authorization},44@${refreshed_merge}"
	root_record=$(jq -cn --arg merge "$root_merge" \
		'{schema_version:1,repository:"test/repo",requested_pr:42,expected_sources:[{pr:42,merge:$merge}],recorded_at:"2026-08-09T00:00:00Z"}')
	previous_lane=$(jq -cn \
		'{schema_version:1,repository:"test/repo",active:true,source_pr:42,expected_sources:"42",phase:"remote-publication",tag:"v1.2.3",operation_token:"lane-old",terminal_receipt:null}')
	lane_json=$(jq -cn --arg expected "$test_current_authorization" --arg provisional "$provisional" \
		--argjson previous "$previous_lane" \
		'{schema_version:1,repository:"test/repo",active:true,source_pr:42,expected_sources:$expected,phase:"aggregation-recovery",tag:"v1.2.3",operation_token:"lane-current",terminal_receipt:null,aggregate_recovery:{previous_state:$previous,provisional_tag_object:$provisional}}')
	current_source=$(jq -cn --arg merge "$root_merge" \
		'{source_pr:42,source_merge:$merge,aggregated_sources:[]}')
	_full_loop_read_release_authorization() {
		printf '%s\n' "$test_current_authorization"
		return 0
	}
	_full_loop_read_release_authorization_recovery_snapshot() {
		printf '%s\n' "$root_record"
		return 0
	}
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON="$lane_json"
		return 0
	}
	TAG_BOUND_MODE=match
	_full_loop_recovery_tag_is_bound_to_current_aggregate() {
		[[ "$TAG_BOUND_MODE" == "match" ]]
		return $?
	}
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$test_refreshed_authorization"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$provisional"
	_full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"
	lane_json=$(jq -cn --arg expected "$test_refreshed_authorization" \
		--arg refresh_previous "$test_current_authorization" --arg provisional "$provisional" \
		--argjson previous "$previous_lane" \
		'{schema_version:1,repository:"test/repo",active:true,source_pr:42,expected_sources:$expected,phase:"aggregation-recovery-refresh",tag:"v1.2.3",operation_token:"lane-refresh",terminal_receipt:null,aggregate_recovery:{previous_state:$previous,provisional_tag_object:$provisional,refresh:{previous_expected_sources:$refresh_previous,pending_expected_sources:$expected}}}')
	_full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"
	test_current_authorization="$test_refreshed_authorization"
	_full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"
	test_current_authorization="${root_authorization},43@${current_merge}"
	lane_json=$(jq -cn --arg expected "$test_current_authorization" --arg provisional "$provisional" \
		--argjson previous "$previous_lane" \
		'{schema_version:1,repository:"test/repo",active:true,source_pr:42,expected_sources:$expected,phase:"aggregation-recovery",tag:"v1.2.3",operation_token:"lane-current",terminal_receipt:null,aggregate_recovery:{previous_state:$previous,provisional_tag_object:$provisional}}')

	nested_root=$(jq -c '.aggregate_recovery={previous_authorization:.}' <<<"$root_record")
	root_record="$nested_root"
	if _full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"; then
		exit 1
	fi
	root_record=$(jq -cn --arg merge "$root_merge" \
		'{schema_version:1,repository:"test/repo",requested_pr:42,expected_sources:[{pr:42,merge:$merge}],recorded_at:"2026-08-09T00:00:00Z"}')

	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$test_current_authorization"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$replacement"
	current_source=$(jq -cn --arg root "$root_merge" --arg current "$current_merge" \
		'{source_pr:99,source_merge:"6666666666666666666666666666666666666666",aggregated_sources:[{pr:42,merge:$root},{pr:43,merge:$current}]}')
	_full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"
	TAG_BOUND_MODE=mismatch
	if _full_loop_recovery_validate_interrupted_publication_intent test/repo 42 v1.2.3 "$current_source"; then
		exit 1
	fi
)
printf 'PASS interrupted intent requires exact root snapshots and aggregate-bound replacement tags\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	test_authorization='42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333'
	_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON='{"source_pr":99,"source_merge":"4444444444444444444444444444444444444444","aggregated_sources":[{"pr":42,"merge":"2222222222222222222222222222222222222222"},{"pr":43,"merge":"3333333333333333333333333333333333333333"}]}'
	_full_loop_read_release_authorization_recovery_snapshot() {
		printf '%s\n' '{"schema_version":1}'
		return 0
	}
	_full_loop_read_release_authorization() {
		printf '%s\n' "$test_authorization"
		return 0
	}
	_full_loop_recovery_validate_receipt() { return 0; }
	load_mode=transaction
	_full_loop_recovery_load_existing_state_transaction() {
		[[ "$load_mode" == "transaction" ]]
		return $?
	}
	_full_loop_recovery_load_remote_publication_state() {
		[[ "$load_mode" == "remote" ]]
		return $?
	}
	_full_loop_recovery_prepare_existing_context test/repo 42 v1.2.3 43,42
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT" == "transaction" ]]
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED" == "$test_authorization" ]]
	[[ "$_FULL_LOOP_RESOLVED_SOURCE_PR" == "99" &&
		"$_FULL_LOOP_RESOLVED_SOURCE_MERGE" == "4444444444444444444444444444444444444444" ]]
	load_mode=remote
	_full_loop_recovery_prepare_existing_context test/repo 42 v1.2.3 42,43
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT" == "remote-publication" ]]
	if _full_loop_recovery_prepare_existing_context test/repo 42 v1.2.3 42; then
		exit 1
	fi
	if _full_loop_recovery_prepare_existing_context test/repo 42 v1.2.3 \
		'42@9999999999999999999999999999999999999999,43@3333333333333333333333333333333333333333'; then
		exit 1
	fi
)
printf 'PASS persisted recovery context can resume after main advances while preserving exact PR intent\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	root_merge=2222222222222222222222222222222222222222
	current_merge=3333333333333333333333333333333333333333
	refreshed_merge=4444444444444444444444444444444444444444
	provisional=1111111111111111111111111111111111111111
	root_authorization="42@${root_merge}"
	test_current_authorization="${root_authorization},43@${current_merge}"
	test_refreshed_authorization="${test_current_authorization},44@${refreshed_merge}"
	root_record=$(jq -cn --arg merge "$root_merge" \
		'{schema_version:1,repository:"test/repo",requested_pr:42,expected_sources:[{pr:42,merge:$merge}],recorded_at:"2026-08-09T00:00:00Z"}')
	test_current_record=$(jq -cn --arg root "$root_merge" --arg current "$current_merge" --argjson previous "$root_record" \
		'{schema_version:1,repository:"test/repo",requested_pr:42,expected_sources:[{pr:42,merge:$root},{pr:43,merge:$current}],recorded_at:"2026-08-09T00:01:00Z",aggregate_recovery:{previous_authorization:$previous}}')
	test_refreshed_record=$(jq -cn --arg root "$root_merge" --arg current "$current_merge" \
		--arg refreshed "$refreshed_merge" --argjson previous "$root_record" \
		'{schema_version:1,repository:"test/repo",requested_pr:42,expected_sources:[{pr:42,merge:$root},{pr:43,merge:$current},{pr:44,merge:$refreshed}],recorded_at:"2026-08-09T00:02:00Z",aggregate_recovery:{previous_authorization:$previous}}')
	test_lane_snapshot='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":42,"expected_sources":"42","phase":"remote-publication","tag":"v1.2.3","operation_token":"lane-old"}'
	test_authorization="$test_current_authorization"
	test_phase="aggregation-recovery"
	set_test_lane_json() {
		if [[ "$test_phase" == "aggregation-recovery-refresh" ]]; then
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$test_refreshed_authorization" \
				--arg current "$test_current_authorization" --argjson previous "$test_lane_snapshot" \
				'{phase:"aggregation-recovery-refresh",operation_token:"lane-refreshed",aggregate_recovery:{previous_state:$previous,refresh:{previous_expected_sources:$current,pending_expected_sources:$expected}}}')
		else
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg current "$test_current_authorization" \
				--argjson previous "$test_lane_snapshot" \
				'{phase:"aggregation-recovery",operation_token:"lane-current",expected_sources:$current,aggregate_recovery:{previous_state:$previous}}')
		fi
		return 0
	}
	set_test_lane_json
	_full_loop_read_release_authorization() {
		printf '%s\n' "$test_authorization"
		return 0
	}
	_full_loop_read_release_authorization_record() {
		if [[ "$test_authorization" == "$test_refreshed_authorization" ]]; then
			printf '%s\n' "$test_refreshed_record"
		else
			printf '%s\n' "$test_current_record"
		fi
		return 0
	}
	_full_loop_read_release_authorization_recovery_snapshot() {
		printf '%s\n' "$root_record"
		return 0
	}
	_full_loop_recovery_validate_interrupted_publication_intent() {
		set_test_lane_json
		return $?
	}
	REFRESH_LOG="${TEST_ROOT}/refresh.log"
	: >"$REFRESH_LOG"
	written_expected=""
	written_previous=""
	AUTH_WRITE_MODE=success
	_full_loop_write_release_authorization_record() {
		local repo="$1"
		local source_pr="$2"
		local expected="$3"
		local previous="$4"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" ]] || return 1
		written_expected="$expected"
		written_previous="$previous"
		printf 'write\n' >>"$REFRESH_LOG"
		[[ "$AUTH_WRITE_MODE" == "success" ]] || return 1
		test_authorization="$expected"
		return 0
	}
	BEGIN_MODE=success
	release_lane_begin_aggregate_refresh() {
		local repo="$1"
		local source_pr="$2"
		local tag_name="$3"
		local previous="$4"
		local expected="$5"
		local old_tag="$6"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && "$tag_name" == "v1.2.3" ]] || return 1
		[[ "$previous" == "$test_current_authorization" && "$expected" == "$test_refreshed_authorization" &&
			"$old_tag" == "$provisional" ]] || return 1
		printf 'begin\n' >>"$REFRESH_LOG"
		[[ "$BEGIN_MODE" == "success" ]] || return 1
		test_phase="aggregation-recovery-refresh"
		_AIDEVOPS_RELEASE_LANE_TOKEN=lane-refreshed
		return 0
	}
	FINISH_MODE=success
	release_lane_finish_aggregate_refresh() {
		local repo="$1"
		local source_pr="$2"
		local tag_name="$3"
		local previous="$4"
		local expected="$5"
		local old_tag="$6"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && "$tag_name" == "v1.2.3" ]] || return 1
		[[ "$previous" == "$test_current_authorization" && "$expected" == "$test_refreshed_authorization" &&
			"$old_tag" == "$provisional" ]] || return 1
		printf 'finish\n' >>"$REFRESH_LOG"
		[[ "$FINISH_MODE" == "success" ]] || return 1
		test_phase="aggregation-recovery"
		return 0
	}
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$test_refreshed_authorization"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$provisional"
	_FULL_LOOP_AGGREGATE_RECOVERY_TAG_SOURCE_JSON='{"source_pr":42}'
	_full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3
	[[ "$written_expected" == "$test_refreshed_authorization" && "$written_previous" == "$root_record" ]]
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" == "$root_authorization" ]]
	[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_LANE_SNAPSHOT" == "$test_lane_snapshot" ]]
	[[ "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "lane-refreshed" ]]
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "begin write finish " ]]

	test_authorization="$test_current_authorization"
	test_phase="aggregation-recovery"
	BEGIN_MODE=failure
	: >"$REFRESH_LOG"
	if _full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ "$test_authorization" == "$test_current_authorization" ]]
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "begin " ]]

	BEGIN_MODE=success
	AUTH_WRITE_MODE=failure
	: >"$REFRESH_LOG"
	if _full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ "$test_phase" == "aggregation-recovery-refresh" && "$test_authorization" == "$test_current_authorization" ]]
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "begin write " ]]
	AUTH_WRITE_MODE=success
	: >"$REFRESH_LOG"
	_full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3
	[[ "$test_authorization" == "$test_refreshed_authorization" && "$test_phase" == "aggregation-recovery" ]]
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "write finish " ]]

	test_phase="aggregation-recovery-refresh"
	FINISH_MODE=failure
	: >"$REFRESH_LOG"
	if _full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "finish " ]]
	FINISH_MODE=success
	: >"$REFRESH_LOG"
	_full_loop_recovery_refresh_state_transaction test/repo 42 v1.2.3
	[[ "$test_phase" == "aggregation-recovery" ]]
	[[ "$(tr '\n' ' ' <"$REFRESH_LOG")" == "finish " ]]
)
printf 'PASS refreshed recovery fences first and resumes every partial state without blind rollback\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	provisional=1111111111111111111111111111111111111111
	replacement=2222222222222222222222222222222222222222
	expected='42@3333333333333333333333333333333333333333'
	current_tag="$provisional"
	tag_bound=false
	main_reachable=true
	lane_phase="aggregate-publication-committing"
	update_mode=success
	transition_log="${TEST_ROOT}/transition.log"
	: >"$transition_log"
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$provisional"
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$expected"
	_AIDEVOPS_RELEASE_LANE_TOKEN=lane-owned
	git() {
		printf '%s\n' "$current_tag"
		return 0
	}
	_full_loop_recovery_tag_is_bound_to_current_aggregate() {
		[[ "$tag_bound" == "true" ]]
		return $?
	}
	_full_loop_recovery_release_commit_main_reachability() {
		[[ "$main_reachable" == "true" ]] && return 0
		return 2
	}
	_full_loop_read_release_authorization() {
		printf '%s\n' "$expected"
		return 0
	}
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$expected" --arg phase "$lane_phase" \
			'{active:true,source_pr:42,tag:"v1.2.3",operation_token:"lane-owned",phase:$phase,expected_sources:$expected,terminal_receipt:null,aggregate_recovery:{}}')
		return 0
	}
	release_lane_update() {
		local repo="$1"
		local source_pr="$2"
		local phase="$3"
		local tag_name="$4"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && "$phase" == "remote-publication" &&
			"$tag_name" == "v1.2.3" ]] || return 1
		printf 'update\n' >>"$transition_log"
		lane_phase="remote-publication"
		[[ "$update_mode" == "success" ]] || return 1
		return 0
	}
	if _full_loop_recovery_transition_durable_publication test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ ! -s "$transition_log" ]]
	current_tag="$replacement"
	if _full_loop_recovery_transition_durable_publication test/repo 42 v1.2.3; then
		exit 1
	fi
	[[ ! -s "$transition_log" ]]
	tag_bound=true
	main_reachable=false
	pending_rc=0
	_full_loop_recovery_transition_durable_publication test/repo 42 v1.2.3 || pending_rc=$?
	[[ "$pending_rc" -eq 8 && ! -s "$transition_log" ]]
	main_reachable=true
	_full_loop_recovery_transition_durable_publication test/repo 42 v1.2.3
	[[ "$(tr '\n' ' ' <"$transition_log")" == "update " ]]
	lane_phase="aggregate-publication-committing"
	update_mode=ambiguous
	: >"$transition_log"
	_full_loop_recovery_transition_durable_publication test/repo 42 v1.2.3
	[[ "$lane_phase" == "remote-publication" && "$(tr '\n' ' ' <"$transition_log")" == "update " ]]
)
printf 'PASS durable transition waits for main reachability and classifies ambiguous lane writes\n'

CALL_LOG="${TEST_ROOT}/calls.log"
: >"$CALL_LOG"
_full_loop_recovery_validate_receipt() {
	printf 'receipt\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_validate_existing_tag() {
	_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="1111111111111111111111111111111111111111"
	printf 'tag\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_prepare_existing_context() {
	_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT=none
	return 0
}
_full_loop_recovery_verify_channels_absent() {
	printf 'channels\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_prepare_aggregate() {
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333"
	_FULL_LOOP_RESOLVED_SOURCE_JSON='{"mode":"aggregate","source_pr":99,"source_merge":"4444444444444444444444444444444444444444","aggregated_sources":[{"pr":42,"merge":"2222222222222222222222222222222222222222"},{"pr":43,"merge":"3333333333333333333333333333333333333333"}]}'
	printf 'aggregate\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_tag_sources() {
	printf '42@2222222222222222222222222222222222222222\n'
	return 0
}
_full_loop_recovery_begin_state_transaction() {
	printf 'begin\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_tag_rollback_safe() { return 0; }
_full_loop_recovery_write_evidence() {
	printf 'evidence\n' >>"$CALL_LOG"
	return 0
}
git() {
	printf '4444444444444444444444444444444444444444\n'
	return 0
}
TAG_BINDING_MODE=unbound
_full_loop_recovery_tag_is_bound_to_current_aggregate() {
	[[ "$TAG_BINDING_MODE" == "bound" ]]
	return $?
}
DURABLE_MODE=pending
_full_loop_recovery_transition_durable_publication() {
	printf 'durable\n' >>"$CALL_LOG"
	case "$DURABLE_MODE" in
	success) return 0 ;;
	pending) return 8 ;;
	*) return 1 ;;
	esac
}
REMOTE_MODE=success
_full_loop_recovery_load_remote_publication_state() {
	printf 'remote\n' >>"$CALL_LOG"
	[[ "$REMOTE_MODE" == "success" ]]
	return $?
}
_full_loop_recovery_run_version_manager() {
	printf 'version-manager\n' >>"$CALL_LOG"
	TAG_BINDING_MODE=bound
	return 8
}
success_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || success_rc=$?
[[ "$success_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt channels begin version-manager evidence durable " ]]
printf 'PASS queued recovery retains the committing fence until main reachability\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_sources() {
	printf '%s\n' "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"
	return 0
}
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 1
}
TAG_BINDING_MODE=unbound
same_sources_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || same_sources_rc=$?
[[ "$same_sources_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt load channels begin version-manager evidence durable " ]]
printf 'PASS fresh same-source aggregation still replaces the historical tag\n'

: >"$CALL_LOG"
DURABLE_MODE=success
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_resume_publication() {
	printf 'resume\n' >>"$CALL_LOG"
	return 8
}
TAG_BINDING_MODE=bound
resume_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || resume_rc=$?
[[ "$resume_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt load durable resume " ]]
printf 'PASS interrupted aggregate recovery resumes without another tag replacement\n'

: >"$CALL_LOG"
DURABLE_MODE=pending
_full_loop_release_prepare_tag_worktree() {
	printf 'prepare-worktree\n' >>"$CALL_LOG"
	return 0
}
pending_resume_rc=0
pending_resume_output=$(_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 2>&1) || pending_resume_rc=$?
[[ "$pending_resume_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt load durable prepare-worktree evidence version-manager durable " ]]
[[ "$pending_resume_output" == *"same recover-aggregate command"* ]]
printf 'PASS interrupted committing recovery idempotently repairs its protected queue\n'

: >"$CALL_LOG"
DURABLE_MODE=success
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 1
}
remote_resume_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || remote_resume_rc=$?
[[ "$remote_resume_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt load remote resume " ]]
printf 'PASS remote-publication recovery reruns enter normal reconciliation\n'

: >"$CALL_LOG"
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 0
}
TAG_BINDING_MODE=unbound
pre_mutation_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || pre_mutation_rc=$?
[[ "$pre_mutation_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt load channels begin version-manager evidence durable " ]]
printf 'PASS interrupted pre-mutation recovery completes the aggregate tag replacement\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_sources() {
	printf '42@2222222222222222222222222222222222222222\n'
	return 0
}
_full_loop_recovery_run_version_manager() {
	printf 'version-manager\n' >>"$CALL_LOG"
	return 1
}
_full_loop_recovery_resume_publication() {
	printf 'resume\n' >>"$CALL_LOG"
	return 1
}
DURABLE_MODE=failure
TAG_BINDING_MODE=unbound
if _full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 >/dev/null 2>&1; then
	printf 'FAIL failed recovery returned success\n'
	exit 1
fi
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt channels begin version-manager durable " ]]
printf 'PASS pre-tag failure retains its fenced transaction without non-atomic rollback\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_rollback_safe() { return 1; }
if _full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 >/dev/null 2>&1; then
	printf 'FAIL unsafe failed recovery returned success\n'
	exit 1
fi
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt channels begin version-manager durable " ]]
printf 'PASS uncertain tag rollback retains expanded state for reconciliation\n'

: >"$CALL_LOG"
_full_loop_recovery_resume_publication() {
	printf 'resume\n' >>"$CALL_LOG"
	return 8
}
DURABLE_MODE=pending
TAG_BINDING_MODE=bound
durable_queue_rc=0
durable_queue_output=$(_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 2>&1) || durable_queue_rc=$?
[[ "$durable_queue_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "tag aggregate receipt channels begin version-manager durable " ]]
[[ "$durable_queue_output" == *"aidevops release status 42"* ]]
[[ "$durable_queue_output" == *"same recover-aggregate command"* ]]
[[ "$durable_queue_output" != *"Aggregate recovery failed after tag state changed"* ]]
printf 'PASS protected-main queue remains exclusively fenced while its merge is pending\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	queue_log="${TEST_ROOT}/advanced-main-queue.log"
	release_checkout="${TEST_ROOT}/advanced-main-release"
	provisional=1111111111111111111111111111111111111111
	replacement=2222222222222222222222222222222222222222
	expected='42@3333333333333333333333333333333333333333'
	mkdir -p "$release_checkout/.agents/scripts"
	cat >"$release_checkout/.agents/scripts/version-manager.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$PWD" == "$RECOVERY_RELEASE_PATH" ]] || exit 1
[[ "$AIDEVOPS_RELEASE_LANE_OPERATION_TOKEN" == "lane-owned" ]] || exit 1
[[ "$AIDEVOPS_RELEASE_LANE_EXPECTED_SOURCES" == "42@3333333333333333333333333333333333333333" ]] || exit 1
[[ "$*" == "recover-aggregate --tag v1.2.3 --source-pr 42 --expected-sources 42@3333333333333333333333333333333333333333 --old-tag-object 1111111111111111111111111111111111111111" ]] || exit 1
printf 'version-manager\n' >>"$RECOVERY_QUEUE_LOG"
exit 8
STUB
	export RECOVERY_QUEUE_LOG="$queue_log" RECOVERY_RELEASE_PATH="$release_checkout"
	: >"$queue_log"
	_full_loop_recovery_validate_existing_tag() {
		_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT="$provisional"
		printf 'tag\n' >>"$queue_log"
		return 0
	}
	_full_loop_recovery_prepare_existing_context() {
		_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$expected"
		_FULL_LOOP_RESOLVED_SOURCE_MERGE=3333333333333333333333333333333333333333
		_FULL_LOOP_AGGREGATE_RECOVERY_EXISTING_CONTEXT=transaction
		_AIDEVOPS_RELEASE_LANE_TOKEN=lane-owned
		return 0
	}
	_full_loop_recovery_tag_is_bound_to_current_aggregate() { return 0; }
	_full_loop_recovery_transition_durable_publication() {
		printf 'durable\n' >>"$queue_log"
		return 8
	}
	_full_loop_recovery_write_evidence() {
		printf 'evidence\n' >>"$queue_log"
		return 0
	}
	_full_loop_release_prepare_tag_worktree() {
		printf 'prepare-worktree\n' >>"$queue_log"
		_FULL_LOOP_RELEASE_PATH="$release_checkout"
		return 0
	}
	_full_loop_recovery_prepare_aggregate() {
		printf 'fresh-aggregate\n' >>"$queue_log"
		return 1
	}
	git() {
		printf '%s\n' "$replacement"
		return 0
	}
	queue_rc=0
	_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42 || queue_rc=$?
	[[ "$queue_rc" -eq 8 ]]
	[[ "$(tr '\n' ' ' <"$queue_log")" == "tag durable prepare-worktree evidence version-manager durable " ]]
)
printf 'PASS persisted replacement-tag recovery recreates its detached tag worktree before queue repair\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	failure_fixture_path="${TEST_ROOT}/failed-prepublication.json"
	requested_merge=2222222222222222222222222222222222222222
	second_merge=3333333333333333333333333333333333333333
	failed_merge=4444444444444444444444444444444444444444
	current_merge=5555555555555555555555555555555555555555
	old_manifest="42@${requested_merge},43@${second_merge}"
	trailer_mode=match
	ancestry_mode=match
	channel_mode=absent
	verified_pr_merge="$failed_merge"
	_FULL_LOOP_RESOLVED_REQUESTED_MERGE="$requested_merge"
	_FULL_LOOP_RESOLVED_SOURCE_MERGE="$current_merge"
	_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$old_manifest"
	_full_loop_release_evidence_path() {
		printf '%s\n' "$failure_fixture_path"
		return 0
	}
	git() {
		if [[ " $* " == *" cat-file -e "* ]]; then
			return 0
		fi
		if [[ " $* " == *" merge-base --is-ancestor "* ]]; then
			[[ "$ancestry_mode" == "match" ]]
			return $?
		fi
		return 1
	}
	gh() {
		jq -cn --arg merge "$verified_pr_merge" \
			'{state:"MERGED",mergedAt:"2026-08-24T02:00:00Z",baseRefName:"main",mergeCommit:{oid:$merge}}'
		return 0
	}
	_full_loop_release_expected_tag_at_commit() {
		local source_commit="$1"
		local release_type="$2"
		[[ "$source_commit" == "$failed_merge" || "$source_commit" == "$requested_merge" ]] || return 1
		case "$release_type" in
		patch) printf 'v1.2.3\n' ;;
		minor) printf 'v1.3.0\n' ;;
		major) printf 'v2.0.0\n' ;;
		*) return 1 ;;
		esac
		return 0
	}
	_full_loop_recovery_verify_channels_absent() {
		local repo="$1"
		local tag_name="$2"
		[[ "$repo" == "test/repo" && "$tag_name" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
			"$channel_mode" == "absent" ]]
		return $?
	}
	_full_loop_recovery_commit_trailer_values() {
		local commit_sha="$1"
		local trailer_key="$2"
		[[ "$commit_sha" == "$failed_merge" ]] || return 1
		case "$trailer_key" in
		Aidevops-Release-Aggregator-PR) printf '99\n' ;;
		Aidevops-Release-Aggregates)
			if [[ "$trailer_mode" == "match" ]]; then
				printf '42@%s\n43@%s\n' "$requested_merge" "$second_merge"
			else
				printf '42@%s\n' "$requested_merge"
			fi
			;;
		*) return 1 ;;
		esac
		return 0
	}
	write_failure_evidence() {
		local merge="$1"
		local release_source_pr="${2:-99}"
		local current_head="${3:-$failed_merge}"
		local attempted_tag="${4:-}"
		local release_type="${5:-}"
		jq -cn --arg requested_merge "$merge" --argjson release_source_pr "$release_source_pr" \
			--arg current_head "$current_head" --arg attempted_tag "$attempted_tag" \
			--arg release_type "$release_type" '
			{schema_version:1,status:"failed",repository:"test/repo",requested_pr:42,
			 requested_merge:$requested_merge,release_source_pr:$release_source_pr,current_head:$current_head,
			 attempted_tag:(if $attempted_tag == "" then null else $attempted_tag end),
			 release_type:(if $release_type == "" then null else $release_type end),
			 recorded_at:"2026-08-24T02:01:47Z"}
		' >"$failure_fixture_path"
		return 0
	}
	write_failure_evidence "$requested_merge"
	_full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch
	[[ "$(_full_loop_recovery_normalize_failed_prepublication_sources 42)" == "42@${requested_merge}" ]]
	if _full_loop_recovery_normalize_failed_prepublication_sources 44 >/dev/null 2>&1; then
		exit 1
	fi
	[[ "$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR" == "99" &&
		"$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE" == "$failed_merge" &&
		"$_FULL_LOOP_FAILED_PREPUBLICATION_TAG" == "v1.2.3" ]]
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" minor \
		>/dev/null 2>&1; then
		exit 1
	fi
	write_failure_evidence "$requested_merge" 99 "$failed_merge" v1.2.3 patch
	_full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch
	write_failure_evidence 6666666666666666666666666666666666666666
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	write_failure_evidence "$requested_merge"
	trailer_mode=mismatch
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	trailer_mode=match
	ancestry_mode=mismatch
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	ancestry_mode=match
	write_failure_evidence "$requested_merge" 99 "$failed_merge" v9.9.9 patch
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	write_failure_evidence "$requested_merge" 99 "$failed_merge" v1.2.3 minor
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	write_failure_evidence "$requested_merge" 99 "$failed_merge" v1.2.3 patch
	channel_mode=published
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
	channel_mode=absent
	verified_pr_merge="$requested_merge"
	write_failure_evidence "$requested_merge" 42 "$requested_merge" v1.2.3 patch
	_full_loop_recovery_validate_failed_prepublication_intent test/repo 42 \
		"42@${requested_merge}" patch
	[[ "$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR" == "42" &&
		"$_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE" == "$requested_merge" &&
		"$_FULL_LOOP_FAILED_PREPUBLICATION_TAG" == "v1.2.3" ]]
	rm -f "$failure_fixture_path"
	if _full_loop_recovery_validate_failed_prepublication_intent test/repo 42 "$old_manifest" patch \
		>/dev/null 2>&1; then
		exit 1
	fi
)
printf 'PASS failed pre-publication retry binds attempted version, absent channels, and direct or aggregate evidence\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT"
	test_resolved_mode=direct
	cleanup_release_worktree() { return 0; }
	git() { return 0; }
	_full_loop_resolve_requested_release_source() {
		local repo="$1"
		local source_pr="$2"
		local release_path="$3"
		local resolver="$4"
		local expected_sources="$5"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && -n "$release_path" &&
			-n "$resolver" && "$expected_sources" == "42" &&
			"${_FULL_LOOP_PRESERVE_PREPUBLICATION_FAILURE_EVIDENCE:-false}" == "true" ]] || return 1
		_FULL_LOOP_RESOLVED_SOURCE_JSON=$(jq -cn --arg mode "$test_resolved_mode" '{mode:$mode}') || return 1
		_FULL_LOOP_RESOLVED_EXPECTED_SOURCES=42@2222222222222222222222222222222222222222
		return 0
	}
	_full_loop_recovery_prepare_prepublication_source test/repo 42 42
	[[ "$(jq -r '.mode' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON")" == "direct" ]]
	test_resolved_mode=aggregate
	_full_loop_recovery_prepare_prepublication_source test/repo 42 42
	[[ "$(jq -r '.mode' <<<"$_FULL_LOOP_RESOLVED_SOURCE_JSON")" == "aggregate" ]]
	test_resolved_mode=invalid
	if _full_loop_recovery_prepare_prepublication_source test/repo 42 42 >/dev/null 2>&1; then
		exit 1
	fi
)
printf 'PASS failed pre-publication preparation admits only reviewed direct or aggregate sources\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED=reserved
	_AIDEVOPS_RELEASE_LANE_PHASE_RESERVED_REFRESH=reserved-authorization-refresh
	RESERVED_LOG="${TEST_ROOT}/reserved.log"
	: >"$RESERVED_LOG"
	old_manifest='42@2222222222222222222222222222222222222222'
	legacy_lane_intent='42'
	expanded_manifest="${old_manifest},43@3333333333333333333333333333333333333333"
	authorization="$old_manifest"
	lane_phase=reserved
	test_lane_sources="$legacy_lane_intent"
	finish_mode=success
	failure_mode=match
	prepublication_mode=aggregate
	prepublication_expected="$expanded_manifest"
	prepublication_marker=false
	prepublication_failed_sources="$legacy_lane_intent"
	refresh_previous_sources="$legacy_lane_intent"
	root_authorization_record=$(jq -cn --arg merge 2222222222222222222222222222222222222222 \
		'{schema_version:1,repository:"test/repo",requested_pr:42,
		  expected_sources:[{pr:42,merge:$merge}],recorded_at:"2026-08-09T00:00:00Z"}')
	printf 'not-requested\n' >"${TEST_ROOT}/release.status"
	_full_loop_release_find_tag_for_pr() { return 2; }
	_full_loop_recovery_prepare_aggregate() {
		_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$expanded_manifest"
		_FULL_LOOP_RESOLVED_SOURCE_JSON='{"mode":"aggregate"}'
		return 0
	}
	_full_loop_recovery_prepare_prepublication_source() {
		local repo="$1"
		local source_pr="$2"
		local expected_sources="$3"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" && -n "$expected_sources" ]] || return 1
		_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$prepublication_expected"
		_FULL_LOOP_RESOLVED_SOURCE_JSON="{\"mode\":\"${prepublication_mode}\"}"
		printf 'prepare-prepublication\n' >>"$RESERVED_LOG"
		return 0
	}
	_full_loop_validate_release_candidates() {
		printf 'validate\n' >>"$RESERVED_LOG"
		return 0
	}
	_full_loop_release_reset_tag_worktree() { return 0; }
	_full_loop_read_release_authorization() {
		printf '%s\n' "$authorization"
		return 0
	}
	_full_loop_read_release_authorization_recovery_snapshot() {
		printf '%s\n' "$root_authorization_record"
		return 0
	}
	release_lane_read() {
		if [[ "$lane_phase" == "reserved-authorization-refresh" ]]; then
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg previous "$refresh_previous_sources" \
				--arg expected "$expanded_manifest" \
				'{schema_version:1,active:true,source_pr:42,phase:"reserved-authorization-refresh",
				  tag:null,expected_sources:$expected,operation_token:"lane-refresh",terminal_receipt:null,
				  reserved_authorization_refresh:{previous_expected_sources:$previous,
				    pending_expected_sources:$expected,previous_state:{schema_version:1}}}')
		elif [[ "$lane_phase" == "reconcile-required" ]]; then
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$test_lane_sources" \
				'{schema_version:1,active:true,source_pr:42,phase:"reconcile-required",tag:null,
				  expected_sources:$expected,operation_token:"lane-failed",terminal_receipt:null}')
		else
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$test_lane_sources" \
				'{schema_version:1,active:true,source_pr:42,phase:"reserved",tag:null,
				  expected_sources:$expected,operation_token:"lane-old",terminal_receipt:null}')
		fi
		if [[ "$prepublication_marker" == "true" ]]; then
			_AIDEVOPS_RELEASE_LANE_JSON=$(jq -c --arg failed "$prepublication_failed_sources" '
				.prepublication_recovery={previous_phase:"reconcile-required",
				 previous_updated_at:"2026-08-24T02:01:43Z",failed_source_pr:99,
				 failed_source_merge:"4444444444444444444444444444444444444444",
				 attempted_tag:"v1.2.3",failed_expected_sources:$failed,
				 current_expected_sources:.expected_sources,recovered_at:"2026-08-24T02:02:00Z"}
			' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
		fi
		return 0
	}
	_full_loop_recovery_validate_failed_prepublication_intent() {
		local repo="$1"
		local source_pr="$2"
		local current_authorization="$3"
		local release_type="$4"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" &&
			"$current_authorization" == "$old_manifest" &&
			"$release_type" == "patch" ]] || return 1
		printf 'verify-failure\n' >>"$RESERVED_LOG"
		[[ "$failure_mode" == "match" ]] || return 1
		_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_PR=99
		_FULL_LOOP_FAILED_PREPUBLICATION_SOURCE_MERGE=4444444444444444444444444444444444444444
		_FULL_LOOP_FAILED_PREPUBLICATION_TAG=v1.2.3
		return 0
	}
	release_lane_acquire() {
		printf 'acquire\n' >>"$RESERVED_LOG"
		_AIDEVOPS_RELEASE_LANE_RESULT=adopted
		_AIDEVOPS_RELEASE_LANE_TOKEN=owned
		return 0
	}
	_full_loop_expand_release_authorization_for_aggregate() {
		[[ "$lane_phase" == "reserved-authorization-refresh" ]] || return 1
		printf 'expand-auth\n' >>"$RESERVED_LOG"
		authorization="$expanded_manifest"
		return 0
	}
	release_lane_expand_reserved_authorization() {
		[[ "$3" == "$legacy_lane_intent" || "$3" == "$old_manifest" ]] || return 1
		_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT='{"schema_version":1,"phase":"reserved"}'
		printf 'fence\n' >>"$RESERVED_LOG"
		refresh_previous_sources="$3"
		lane_phase=reserved-authorization-refresh
		test_lane_sources="$expanded_manifest"
		return 0
	}
	release_lane_reopen_failed_prepublication() {
		local repo="$1"
		local source_pr="$2"
		local failed_expected="$3"
		local failed_source_pr="$4"
		local failed_source_merge="$5"
		local attempted_tag="$6"
		[[ "$repo" == "test/repo" && "$source_pr" == "42" &&
			"$failed_expected" == "$prepublication_failed_sources" ]] || return 1
		[[ "$failed_source_pr" == "99" && "$failed_source_merge" == "4444444444444444444444444444444444444444" &&
			"$attempted_tag" == "v1.2.3" ]] || return 1
		printf 'reopen\n' >>"$RESERVED_LOG"
		if [[ "$lane_phase" == "reconcile-required" ]]; then
			lane_phase=reserved
			test_lane_sources="$failed_expected"
		fi
		prepublication_marker=true
		prepublication_failed_sources="$failed_expected"
		_AIDEVOPS_RELEASE_LANE_RESULT=acquired
		_AIDEVOPS_RELEASE_LANE_TOKEN=lane-reopened
		return 0
	}
	release_lane_finish_reserved_authorization() {
		[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved-authorization-refresh" ]] || return 1
		printf 'finish\n' >>"$RESERVED_LOG"
		[[ "$finish_mode" == "success" ]] || return 1
		lane_phase=reserved
		test_lane_sources="$expanded_manifest"
		return 0
	}
	release_lane_restore_reserved_authorization() {
		printf 'restore-lane\n' >>"$RESERVED_LOG"
		lane_phase=reserved
		test_lane_sources="$legacy_lane_intent"
		return 0
	}
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate acquire fence expand-auth finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" &&
		"$_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION" == "false" ]]
	printf 'PASS reserved recovery fences the lane before authorization expansion\n'

	: >"$RESERVED_LOG"
	authorization="$expanded_manifest"
	lane_phase=reserved
	test_lane_sources="$legacy_lane_intent"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate acquire fence finish " ]]
	[[ "$lane_phase" == "reserved" && "$test_lane_sources" == "$expanded_manifest" ]]
	printf 'PASS reserved recovery repairs an authorization-first interruption without skipping the stale lane\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reserved-authorization-refresh
	test_lane_sources="$expanded_manifest"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate acquire fence expand-auth finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" ]]
	printf 'PASS reserved recovery resumes an interruption between lane fencing and authorization\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reserved
	test_lane_sources="$legacy_lane_intent"
	finish_mode=failure
	if _full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null 2>&1; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate acquire fence expand-auth finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved-authorization-refresh" ]]
	finish_mode=success
	: >"$RESERVED_LOG"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate acquire fence finish " ]]
	[[ "$lane_phase" == "reserved" ]]
	printf 'PASS reserved recovery retains and resumes a fenced post-authorization interruption\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$legacy_lane_intent"
	prepublication_marker=false
	prepublication_failed_sources="$legacy_lane_intent"
	failure_mode=match
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen fence expand-auth finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" &&
		"$_FULL_LOOP_RESERVED_RECOVERY_FAILED_PREPUBLICATION" == "true" ]]
	printf 'PASS verified failed pre-publication recovery reopens before authorization expansion\n'

	: >"$RESERVED_LOG"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" && "$prepublication_marker" == "true" ]]
	printf 'PASS expanded pre-publication marker revalidates the original failed authorization\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$legacy_lane_intent"
	prepublication_marker=false
	prepublication_failed_sources="$legacy_lane_intent"
	finish_mode=failure
	if _full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null 2>&1; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen fence expand-auth finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved-authorization-refresh" &&
		"$prepublication_marker" == "true" ]]
	finish_mode=success
	: >"$RESERVED_LOG"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen fence finish " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" ]]
	printf 'PASS marked authorization-refresh recovery revalidates before resuming expansion\n'

	: >"$RESERVED_LOG"
	authorization="$expanded_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$expanded_manifest"
	prepublication_marker=false
	prepublication_failed_sources="$expanded_manifest"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen " ]]
	[[ "$authorization" == "$expanded_manifest" && "$lane_phase" == "reserved" ]]
	printf 'PASS verified same-manifest retry reopens without a redundant authorization write\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$old_manifest"
	prepublication_marker=false
	prepublication_failed_sources="$old_manifest"
	prepublication_mode=direct
	prepublication_expected="$old_manifest"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42 patch >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen " ]]
	[[ "$authorization" == "$old_manifest" && "$lane_phase" == "reserved" ]]
	prepublication_mode=aggregate
	prepublication_expected="$expanded_manifest"
	printf 'PASS verified failed pre-publication recovery reaches the direct-source retry path\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reserved
	test_lane_sources="$legacy_lane_intent"
	prepublication_marker=true
	prepublication_failed_sources="$legacy_lane_intent"
	prepublication_mode=direct
	prepublication_expected="$old_manifest"
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42 patch >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure acquire reopen " ]]
	[[ "$authorization" == "$old_manifest" && "$lane_phase" == "reserved" && "$prepublication_marker" == "true" ]]
	prepublication_mode=aggregate
	prepublication_expected="$expanded_manifest"
	printf 'PASS crash retry revalidates a recovered reserved lane before resuming\n'

	: >"$RESERVED_LOG"
	authorization="$old_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$legacy_lane_intent"
	prepublication_marker=false
	prepublication_failed_sources="$legacy_lane_intent"
	failure_mode=mismatch
	if _full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null 2>&1; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "prepare-prepublication validate verify-failure " && "$lane_phase" == "reconcile-required" ]]
	failure_mode=match
	printf 'PASS failed pre-publication recovery rejects missing or mismatched failure intent before lane mutation\n'

	prepublication_marker=false
	lane_phase=reserved
	test_lane_sources="$legacy_lane_intent"
	_full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"
	test_lane_sources="$expanded_manifest"
	if _full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"; then
		exit 1
	fi
	prepublication_marker=true
	_full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"
	prepublication_marker=false
	lane_phase=reserved-authorization-refresh
	_full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"
	lane_phase=reconcile-required
	test_lane_sources="$expanded_manifest"
	_full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"
	test_lane_sources="$legacy_lane_intent"
	if _full_loop_recovery_lane_requires_prepublication_transaction test/repo 42 "$expanded_manifest"; then
		exit 1
	fi
	printf 'PASS equal persisted PR sets still resume stale, fenced, marked, or exact failed pre-publication transactions\n'
)

(
	real_git=$(type -P git)
	source "${SCRIPT_DIR}/release-authorization-manifest-helper.sh"
	git() {
		"$real_git" "$@"
		return $?
	}
	stale_body='Release aggregation

Aidevops-Release-Aggregator-PR: 99
Aidevops-Release-Aggregates: 42@2222222222222222222222222222222222222222'
	manifest=$(_full_loop_successor_manifest_from_body 99 "$stale_body")
	[[ "$manifest" == '42@2222222222222222222222222222222222222222' ]]
	if _full_loop_successor_manifest_from_body 100 "$stale_body" >/dev/null 2>&1; then
		exit 1
	fi
	gh() {
		local endpoint="$2"
		if [[ "$endpoint" == *'/compare/'* ]]; then
			printf '%s\n' 3333333333333333333333333333333333333333
			return 0
		fi
		if [[ "$endpoint" == *'/commits/3333333333333333333333333333333333333333/pulls' ]]; then
			printf '%s\n' '[{"number":43,"merged_at":"2026-08-24T00:00:00Z","base":{"ref":"main"},"merge_commit_sha":"3333333333333333333333333333333333333333"}]'
			return 0
		fi
		return 1
	}
	complete=$(_full_loop_successor_complete_manifest test/repo \
		1111111111111111111111111111111111111111 "$manifest" "$manifest")
	[[ "$complete" == '42@2222222222222222222222222222222222222222,43@3333333333333333333333333333333333333333' ]]
)
printf 'PASS successor manifest preserves stale sources and adds uniquely mapped main merges\n'

exit 0
