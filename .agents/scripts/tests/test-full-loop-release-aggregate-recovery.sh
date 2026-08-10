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
_full_loop_release_receipt_path() {
	printf '%s/release.status\n' "$TEST_ROOT"
	return 0
}
printf 'published\n' >"${TEST_ROOT}/release.status"
if _full_loop_recovery_validate_receipt test/repo 42 >/dev/null 2>&1; then
	printf 'FAIL recovery accepted a terminal release receipt\n'
	exit 1
fi
printf 'failed\n' >"${TEST_ROOT}/release.status"
_full_loop_recovery_validate_receipt test/repo 42
printf 'PASS recovery rejects terminal receipts and permits failed retries\n'

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
	printf 'FAIL lane read failure retained expanded authorization\n'
	exit 1
fi
[[ "$(tr '\n' ' ' <"$STATE_LOG")" == "expand restore-auth " ]]
printf 'PASS lane uncertainty restores the pre-transaction authorization\n'

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
_full_loop_recovery_load_existing_state_transaction test/repo 42 v1.2.3
[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_PREVIOUS_AUTH" == "42@2222222222222222222222222222222222222222" ]]
[[ "$_FULL_LOOP_AGGREGATE_RECOVERY_OLD_TAG_OBJECT" == 1111111111111111111111111111111111111111 ]]
[[ "$_AIDEVOPS_RELEASE_LANE_TOKEN" == "lane-new" ]]
printf 'PASS interrupted recovery reloads exact authorization and lane snapshots\n'

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
_full_loop_recovery_restore_state_transaction() {
	printf 'restore\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_tag_rollback_safe() { return 0; }
_full_loop_recovery_write_evidence() {
	printf 'evidence\n' >>"$CALL_LOG"
	return 0
}
release_lane_update() {
	printf 'lane\n' >>"$CALL_LOG"
	return 0
}
git() {
	printf '4444444444444444444444444444444444444444\n'
	return 0
}

_full_loop_recovery_run_version_manager() {
	printf 'version-manager\n' >>"$CALL_LOG"
	return 8
}
success_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || success_rc=$?
[[ "$success_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "receipt tag aggregate channels begin version-manager evidence lane " ]]
printf 'PASS queued recovery records evidence and retains the expanded transaction\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_sources() {
	printf '%s\n' "$_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED"
	return 0
}
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 1
}
_full_loop_recovery_tag_is_bound_to_current_aggregate() { return 1; }
same_sources_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || same_sources_rc=$?
[[ "$same_sources_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "receipt tag aggregate load channels begin version-manager evidence lane " ]]
printf 'PASS fresh same-source aggregation still replaces the historical tag\n'

: >"$CALL_LOG"
_full_loop_recovery_load_existing_state_transaction() {
	printf 'load\n' >>"$CALL_LOG"
	return 0
}
_full_loop_recovery_resume_publication() {
	printf 'resume\n' >>"$CALL_LOG"
	return 8
}
resume_rc=0
_full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 || resume_rc=$?
[[ "$resume_rc" -eq 8 ]]
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "receipt tag aggregate load resume " ]]
printf 'PASS interrupted aggregate recovery resumes without another tag replacement\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_sources() {
	printf '42@2222222222222222222222222222222222222222\n'
	return 0
}
_full_loop_recovery_run_version_manager() {
	printf 'version-manager\n' >>"$CALL_LOG"
	return 1
}
if _full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 >/dev/null 2>&1; then
	printf 'FAIL failed recovery returned success\n'
	exit 1
fi
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "receipt tag aggregate channels begin version-manager restore " ]]
printf 'PASS failed recovery restores authorization and release-lane state\n'

: >"$CALL_LOG"
_full_loop_recovery_tag_rollback_safe() { return 1; }
if _full_loop_release_recover_aggregate test/repo 42 v1.2.3 42,43 >/dev/null 2>&1; then
	printf 'FAIL unsafe failed recovery returned success\n'
	exit 1
fi
[[ "$(tr '\n' ' ' <"$CALL_LOG")" == "receipt tag aggregate channels begin version-manager " ]]
printf 'PASS uncertain tag rollback retains expanded state for reconciliation\n'

(
	unset _FULL_LOOP_RELEASE_AGGREGATE_RECOVERY_LOADED
	source "${SCRIPT_DIR}/full-loop-release-aggregate-recovery.sh"
	RESERVED_LOG="${TEST_ROOT}/reserved.log"
	: >"$RESERVED_LOG"
	old_manifest='42@2222222222222222222222222222222222222222'
	expanded_manifest="${old_manifest},43@3333333333333333333333333333333333333333"
	_full_loop_recovery_validate_receipt() { return 0; }
	_full_loop_release_find_tag_for_pr() { return 2; }
	_full_loop_recovery_prepare_aggregate() {
		_FULL_LOOP_AGGREGATE_RECOVERY_EXPECTED="$expanded_manifest"
		_FULL_LOOP_RESOLVED_SOURCE_JSON='{"mode":"aggregate"}'
		return 0
	}
	_full_loop_validate_release_candidates() {
		printf 'validate\n' >>"$RESERVED_LOG"
		return 0
	}
	_full_loop_release_reset_tag_worktree() { return 0; }
	_full_loop_read_release_authorization() {
		printf '%s\n' "$old_manifest"
		return 0
	}
	release_authorization_subset() { return 0; }
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg previous "$old_manifest" \
			'{active:true,source_pr:42,phase:"reserved",tag:null,expected_sources:$previous,terminal_receipt:null}')
		return 0
	}
	release_lane_acquire() {
		_AIDEVOPS_RELEASE_LANE_RESULT=acquired
		_AIDEVOPS_RELEASE_LANE_TOKEN=owned
		return 0
	}
	_full_loop_expand_release_authorization_for_aggregate() {
		printf 'expand-auth\n' >>"$RESERVED_LOG"
		return 0
	}
	release_lane_expand_reserved_authorization() {
		_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT='{"phase":"reserved"}'
		printf 'expand-lane\n' >>"$RESERVED_LOG"
		return 0
	}
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate expand-auth expand-lane " ]]
	printf 'PASS reserved recovery validates the reviewed aggregate before transactional expansion\n'

	: >"$RESERVED_LOG"
	_full_loop_read_release_authorization() {
		printf '%s\n' "$expanded_manifest"
		return 0
	}
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg expected "$expanded_manifest" \
			'{active:true,source_pr:42,phase:"reserved",tag:null,expected_sources:$expected,terminal_receipt:null}')
		return 0
	}
	_full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate " ]]
	printf 'PASS reserved recovery recognizes an already-converged authorization and lane\n'

	: >"$RESERVED_LOG"
	_full_loop_read_release_authorization() {
		printf '%s\n' "$old_manifest"
		return 0
	}
	release_lane_read() {
		_AIDEVOPS_RELEASE_LANE_JSON=$(jq -cn --arg previous "$old_manifest" \
			'{active:true,source_pr:42,phase:"reserved",tag:null,expected_sources:$previous,terminal_receipt:null}')
		return 0
	}
	release_lane_expand_reserved_authorization() {
		_AIDEVOPS_RELEASE_LANE_RECOVERY_SNAPSHOT='{"phase":"reserved"}'
		printf 'expand-lane\n' >>"$RESERVED_LOG"
		return 1
	}
	release_lane_restore_reserved_authorization() {
		printf 'restore-lane\n' >>"$RESERVED_LOG"
		return 0
	}
	_full_loop_restore_release_authorization_after_aggregate() {
		printf 'restore-auth\n' >>"$RESERVED_LOG"
		return 0
	}
	if _full_loop_recovery_expand_reserved_authorization test/repo 42 42,43 >/dev/null 2>&1; then
		exit 1
	fi
	[[ "$(tr '\n' ' ' <"$RESERVED_LOG")" == "validate expand-auth expand-lane restore-lane restore-auth " ]]
	printf 'PASS reserved recovery restores lane and authorization after a partial write\n'
)

exit 0
