#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || exit 1
HELPER="${REPO_ROOT}/.agents/scripts/release-candidate-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message"
	exit 1
}

pass() {
	local message="$1"
	printf 'PASS %s\n' "$message"
	return 0
}

FIXTURE_REPO="${TEST_ROOT}/repo"
mkdir -p "$FIXTURE_REPO"
git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name Test
git -C "$FIXTURE_REPO" config user.email test@example.invalid
git -C "$FIXTURE_REPO" config commit.gpgsign false
git -C "$FIXTURE_REPO" config core.hooksPath /dev/null
printf '1.2.3\n' >"${FIXTURE_REPO}/VERSION"
cat >"${FIXTURE_REPO}/package.json" <<'JSON'
{
  "name": "aidevops",
  "version": "1.2.3",
  "files": ["VERSION", "payload.txt"]
}
JSON
printf 'candidate payload\n' >"${FIXTURE_REPO}/payload.txt"
git -C "$FIXTURE_REPO" add VERSION package.json payload.txt
git -C "$FIXTURE_REPO" commit -q -m 'test: candidate fixture'
FIXTURE_COMMIT=$(git -C "$FIXTURE_REPO" rev-parse HEAD)

MANIFEST="${TEST_ROOT}/candidate.json"
ARCHIVE="${TEST_ROOT}/aidevops-1.2.3.tgz"
AIDEVOPS_TEMP_DIR="$TEST_ROOT" bash "$HELPER" verify \
	--repo "$FIXTURE_REPO" \
	--expected-commit "$FIXTURE_COMMIT" \
	--expected-version 1.2.3 \
	--manifest "$MANIFEST" \
	--archive "$ARCHIVE" >/dev/null

if ! jq -e --arg commit "$FIXTURE_COMMIT" '
	.schema == "aidevops.release-candidate/v1"
	and .commit == $commit
	and .name == "aidevops"
	and .version == "1.2.3"
	and .entryCount == (.files | length)
	and (.archive_sha256 | test("^[0-9a-f]{64}$"))
	and ([.files[].path] | index("payload.txt")) != null
' "$MANIFEST" >/dev/null; then
	fail "candidate manifest binds the exact commit, version, and archive"
fi
if [[ ! -s "$ARCHIVE" ]] || ! tar -tzf "$ARCHIVE" | grep -qx 'package/payload.txt'; then
	fail "candidate archive contains the declared payload"
fi
pass "candidate helper builds and verifies an exact distributable"

if AIDEVOPS_TEMP_DIR="$TEST_ROOT" bash "$HELPER" verify \
	--repo "$FIXTURE_REPO" \
	--expected-commit 0000000000000000000000000000000000000000 \
	--expected-version 1.2.3 >/dev/null 2>&1; then
	fail "candidate helper accepted a mismatched commit"
fi
pass "candidate helper rejects a mismatched commit before packaging"

printf 'dirty\n' >>"${FIXTURE_REPO}/payload.txt"
if AIDEVOPS_TEMP_DIR="$TEST_ROOT" bash "$HELPER" verify \
	--repo "$FIXTURE_REPO" \
	--expected-commit "$FIXTURE_COMMIT" \
	--expected-version 1.2.3 >/dev/null 2>&1; then
	fail "candidate helper accepted a dirty worktree"
fi
pass "candidate helper rejects a dirty worktree before packaging"

exit 0
