#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REMOTE="${TEST_ROOT}/remote.git"
REPO="${TEST_ROOT}/repo"
RECOVERY="${TEST_ROOT}/recovery"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" switch -q -c main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
printf '1.2.3\n' >"${REPO}/VERSION"
printf '{"name":"aidevops","version":"1.2.3"}\n' >"${REPO}/package.json"
git -C "$REPO" add VERSION package.json
git -C "$REPO" commit -q -m 'authorized source merge'
SOURCE_MERGE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m 'chore(release): bump version to 1.2.3'
git -C "$REPO" tag -a v1.2.3 -m "Release v1.2.3 - provisional

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 42
Aidevops-Source-Merge: ${SOURCE_MERGE}"
OLD_TAG_OBJECT=$(git -C "$REPO" rev-parse refs/tags/v1.2.3)
git -C "$REPO" reset -q --hard "$SOURCE_MERGE"
git -C "$REPO" commit -q --allow-empty -m "reviewed aggregate

Aidevops-Release-Aggregator-PR: 99
Aidevops-Release-Aggregates: 42@${SOURCE_MERGE}"
AGGREGATE_MERGE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" push -q -u origin main
git -C "$REPO" worktree add -q --detach "$RECOVERY" origin/main

print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
cd "$RECOVERY" || exit 1
source "${SCRIPT_DIR}/version-manager.sh"

assert_release_linked_worktree() { return 0; }
check_working_tree_clean() {
	git -C "$REPO_ROOT" diff --quiet && git -C "$REPO_ROOT" diff --cached --quiet
	return $?
}
verify_remote_sync() {
	[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$(git -C "$REPO_ROOT" rev-parse origin/main)" ]]
	return $?
}
verify_release_source_pr() {
	VERSION_MANAGER_SOURCE_PR=99
	VERSION_MANAGER_SOURCE_MERGE_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
	VERSION_MANAGER_AGGREGATED_SOURCES="42@${SOURCE_MERGE}"
	return 0
}
validate_version_consistency() { return 0; }
_verify_recovered_aggregate_tag() { return 0; }
release_source_pr_required() { return 0; }
_release_contains_efficiency_change() { return 1; }
push_changes() { return "${PUSH_RC:-8}"; }
git() {
	if [[ "${1:-}" == "verify-tag" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "tag" && "${2:-}" == "-s" ]]; then
		shift 2
		command git tag -a "$@"
		return $?
	fi
	command git "$@"
	return $?
}

tag_name=""
source_pr=""
expected_sources=""
old_tag_object=""
_parse_aggregate_recovery_args --tag v1.2.3 --source-pr 42 \
	--expected-sources "42@${SOURCE_MERGE}" --old-tag-object "$OLD_TAG_OBJECT"
_validate_aggregate_recovery_context "$tag_name" "$source_pr" "$expected_sources" "$old_tag_object"
recovery_rc=0
_execute_aggregate_recovery "$tag_name" "$old_tag_object" || recovery_rc=$?
[[ "$recovery_rc" -eq 8 ]]
NEW_TAG_OBJECT=$(git -C "$RECOVERY" rev-parse refs/tags/v1.2.3)
[[ "$NEW_TAG_OBJECT" != "$OLD_TAG_OBJECT" ]]
[[ "$(git -C "$RECOVERY" rev-parse "v1.2.3^")" == "$AGGREGATE_MERGE" ]]
[[ "$(git -C "$RECOVERY" show v1.2.3:VERSION)" == "1.2.3" ]]
git -C "$RECOVERY" for-each-ref --format='%(contents)' refs/tags/v1.2.3 | grep -q "Aidevops-Source-PR: 99"
printf 'PASS aggregate recovery replaces a local-only tag without incrementing the version\n'

restore_unpublished_aggregate_tag 1.2.3 "$OLD_TAG_OBJECT"
git -C "$RECOVERY" reset -q --hard "$AGGREGATE_MERGE"
PUSH_RC=1
failed_rc=0
_main_recover_aggregate --tag v1.2.3 --source-pr 42 \
	--expected-sources "42@${SOURCE_MERGE}" --old-tag-object "$OLD_TAG_OBJECT" || failed_rc=$?
[[ "$failed_rc" -eq 1 ]]
[[ "$(git -C "$RECOVERY" rev-parse refs/tags/v1.2.3)" == "$OLD_TAG_OBJECT" ]]
printf 'PASS failed aggregate recovery restores the exact provisional tag object\n'

exit 0
