#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../review-evidence-helper.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-evidence-test.XXXXXX")"
GIT_BIN="${AIDEVOPS_TEST_GIT_BIN:-/usr/bin/git}"

git() {
	"$GIT_BIN" "$@"
	return $?
}
export -f git
export GIT_BIN

cleanup() {
	local test_root="$TEST_ROOT"
	rm -rf "$test_root"
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

assert_contains() {
	local file="$1"
	local expected="$2"
	local label="$3"
	grep -Fq -- "$expected" "$file" || fail "${label}: missing ${expected}"
	return 0
}

REPO="${TEST_ROOT}/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
printf 'one\n' >"${REPO}/tracked.txt"
git -C "$REPO" add tracked.txt
git -C "$REPO" -c user.name='Review Test' -c user.email='review@example.invalid' commit -qm 'initial'
INITIAL_SHA=$(git -C "$REPO" rev-parse HEAD)

printf 'one\ntwo\n' >"${REPO}/tracked.txt"
printf 'new\n' >"${REPO}/untracked.txt"
LOCAL_BUNDLE="${TEST_ROOT}/local.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local --output "$LOCAL_BUNDLE" >/dev/null)
assert_contains "$LOCAL_BUNDLE" 'schema: aidevops.review-evidence/v1' 'local schema'
assert_contains "$LOCAL_BUNDLE" 'target: local' 'local target'
assert_contains "$LOCAL_BUNDLE" '+two' 'tracked patch'
assert_contains "$LOCAL_BUNDLE" 'untracked.txt' 'untracked patch'
if grep -Fq "$TEST_ROOT" "$LOCAL_BUNDLE"; then
	fail 'bundle exposed host test path'
fi

git -C "$REPO" add tracked.txt untracked.txt
git -C "$REPO" -c user.name='Review Test' -c user.email='review@example.invalid' commit -qm 'change'
BRANCH_BUNDLE="${TEST_ROOT}/branch.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle branch --base "$INITIAL_SHA" --output "$BRANCH_BUNDLE" >/dev/null)
assert_contains "$BRANCH_BUNDLE" 'target: branch' 'branch target'
assert_contains "$BRANCH_BUNDLE" 'A' 'branch name-status'

COMMIT_BUNDLE="${TEST_ROOT}/commit.md"
(cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle commit --commit HEAD --output "$COMMIT_BUNDLE" >/dev/null)
assert_contains "$COMMIT_BUNDLE" 'target: commit' 'commit target'
assert_contains "$COMMIT_BUNDLE" 'Commit:' 'commit metadata'

gh() {
	local resource="$1"
	local action="$2"
	case "${resource}:${action}" in
	issue:view)
		printf '%s\n' '{"number":42,"title":"Issue fixture","body":"Observed failure","comments":[]}'
		;;
	pr:view)
		printf '%s\n' '{"number":43,"title":"PR fixture","body":"Fix","files":[{"path":"src/app.sh"}],"comments":[]}'
		;;
	pr:diff)
		printf '%s\n' 'diff --git a/src/app.sh b/src/app.sh' '+return 0'
		;;
	*) return 1 ;;
	esac
	return 0
}
export -f gh

ISSUE_BUNDLE="${TEST_ROOT}/issue.md"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle issue 42 --repo owner/repo --output "$ISSUE_BUNDLE" >/dev/null
assert_contains "$ISSUE_BUNDLE" 'target: issue' 'issue target'
assert_contains "$ISSUE_BUNDLE" 'Issue fixture' 'issue metadata'

PR_BUNDLE="${TEST_ROOT}/pr.md"
AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle pr 43 --repo owner/repo --output "$PR_BUNDLE" >/dev/null
assert_contains "$PR_BUNDLE" 'target: pr' 'PR target'
assert_contains "$PR_BUNDLE" 'src/app.sh' 'PR changed path'
assert_contains "$PR_BUNDLE" '+return 0' 'PR patch'

mkdir -p "${REPO}/config"
printf 'unsafe\n' >"${REPO}/config/.env"
if (cd "$REPO" && AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp" "$HELPER" bundle local >/dev/null 2>&1); then
	fail 'security-sensitive untracked path was bundled'
fi

printf 'PASS review evidence helper builds bounded target bundles\n'
