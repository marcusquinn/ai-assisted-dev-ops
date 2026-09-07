#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home"
export AIDEVOPS_WORKTREE_BASE_DIR="$TEST_ROOT/worktrees"
mkdir -p "$HOME" "$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42"
printf '1.2.4\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION"

# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"
# shellcheck source=../full-loop-release-aggregate-recovery.sh
source "$SCRIPT_DIR/full-loop-release-aggregate-recovery.sh"

REPO_ROOT="$TEST_ROOT/repo"
mkdir -p "$REPO_ROOT"
SNAPSHOT=2222222222222222222222222222222222222222
EXPECTED='101@1111111111111111111111111111111111111111'
BASE_STATE='{"schema_version":1,"repository":"test/repo","active":true,"source_pr":101,"expected_sources":"101@1111111111111111111111111111111111111111","phase":"preparing","tag":null,"owner":"process-42","operation_token":"token-old","updated_at":"2020-01-01T00:00:00Z","terminal_receipt":null,"reservation_contract":"fenced-prepublication/v1","executor":{"host_id":"local","pid":42,"started_at":"old"},"snapshot_sha":"2222222222222222222222222222222222222222","snapshot_base":"1111111111111111111111111111111111111111","snapshot_base_tag":"v1.2.3","snapshot_base_object":"3333333333333333333333333333333333333333","snapshot_manifest_bound":true}'
STATE="$BASE_STATE"
AUTHORIZATION="$EXPECTED"
CHANNELS_ABSENT=true
SURVIVING_PROCESS=false
PROTECTED_BRANCH=false
PERMISSION=true
LANE_ABSENT=false
RECOVERY_CALLS=0
CAPTURED_EVIDENCE=""

release_lane_read() {
	[[ "$LANE_ABSENT" == "false" ]] || return 2
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	_AIDEVOPS_RELEASE_LANE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	return 0
}

_full_loop_read_release_authorization() {
	printf '%s\n' "$AUTHORIZATION"
	return 0
}

_full_loop_release_expected_tag_at_commit() {
	[[ "$1" == "$SNAPSHOT" && "$2" == "patch" ]] || return 1
	printf 'v1.2.4\n'
	return 0
}

_full_loop_recovery_verify_channels_absent() {
	[[ "$1" == "test/repo" && "$2" == "v1.2.4" && "$CHANNELS_ABSENT" == "true" ]]
	return $?
}

_full_loop_recovery_process_uses_path() {
	[[ "$SURVIVING_PROCESS" == "false" ]]
	return $?
}

git() {
	local args="$*"
	case "$args" in
	*"rev-parse HEAD"*) printf '%s\n' "$SNAPSHOT" ;;
	*"symbolic-ref -q HEAD"*) return 1 ;;
	*"show-ref --verify --quiet refs/tags/v1.2.4"*) return 1 ;;
	*"ls-remote --heads origin refs/heads/chore/release-v1.2.4-provenance"*)
		[[ "$PROTECTED_BRANCH" == "false" ]] && return 0
		printf '%s\t%s\n' 4444444444444444444444444444444444444444 refs/heads/chore/release-v1.2.4-provenance
		;;
	*) return 1 ;;
	esac
	return 0
}

release_lane_recover_dead_preparing() {
	[[ "$1" == "test/repo" && "$2" == "101" && "$3" == "$EXPECTED" && "$4" == "v1.2.4" ]] || return 1
	RECOVERY_CALLS=$((RECOVERY_CALLS + 1))
	CAPTURED_EVIDENCE="$5"
	return 0
}

gh() {
	[[ "$*" == 'api repos/test/repo --jq '* ]] || return 1
	printf '%s\n' "$PERMISSION"
	return 0
}

reset_fixture() {
	STATE="$BASE_STATE"
	AUTHORIZATION="$EXPECTED"
	CHANNELS_ABSENT=true
	SURVIVING_PROCESS=false
	PROTECTED_BRANCH=false
	PERMISSION=true
	LANE_ABSENT=false
	RECOVERY_CALLS=0
	CAPTURED_EVIDENCE=""
	printf '1.2.4\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION"
	return 0
}

reset_fixture
_full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null
[[ "$RECOVERY_CALLS" -eq 1 ]] || exit 1
jq -e '.attempted_tag == "v1.2.4" and .worktree_state == "isolated"
	and .remote_tag == "absent" and .github_release == "absent"
	and .npm == "absent" and .homebrew == "absent" and .protected_branch == "absent"' \
	<<<"$CAPTURED_EVIDENCE" >/dev/null
printf 'PASS dead preparing recovery proves isolated worktree and absent channels before one CAS\n'

reset_fixture
LANE_ABSENT=true
absent_rc=0
_full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null 2>&1 || absent_rc=$?
[[ "$absent_rc" -eq 2 && "$RECOVERY_CALLS" -eq 0 ]] || exit 1
printf 'PASS absent lane falls through to the ordinary release path\n'

for refusal in authorization channels process permission branch version; do
	reset_fixture
	case "$refusal" in
	authorization) AUTHORIZATION='101@9999999999999999999999999999999999999999' ;;
	channels) CHANNELS_ABSENT=false ;;
	process) SURVIVING_PROCESS=true ;;
	permission) PERMISSION=false ;;
	branch) PROTECTED_BRANCH=true ;;
	version) printf '1.2.5\n' >"$AIDEVOPS_WORKTREE_BASE_DIR/aidevops-release-101-42/VERSION" ;;
	esac
	if _full_loop_recovery_dead_preparing test/repo 101 "$EXPECTED" patch >/dev/null 2>&1; then
		printf 'FAIL unsafe %s state was recovered\n' "$refusal" >&2
		exit 1
	fi
	[[ "$RECOVERY_CALLS" -eq 0 ]] || exit 1
done
printf 'PASS preparing recovery refuses authorization, channel, process, branch, and worktree uncertainty\n'
