#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Verify a protected-main rejection preserves immutable release provenance
# through an exact-head merge PR and idempotent tag reconciliation.

set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REAL_GIT=$(command -p -v git 2>/dev/null || command -v git)
REMOTE="${TEST_ROOT}/remote.git"
REPO="${TEST_ROOT}/release"
CONCURRENT="${TEST_ROOT}/concurrent"
MERGER="${TEST_ROOT}/merger"
BIN="${TEST_ROOT}/bin"
mkdir -p "$BIN"

"$REAL_GIT" init -q --bare "$REMOTE"
"$REAL_GIT" clone -q "$REMOTE" "$REPO"
"$REAL_GIT" -C "$REPO" switch -q -c main
"$REAL_GIT" -C "$REPO" config user.name Test
"$REAL_GIT" -C "$REPO" config user.email test@example.invalid
"$REAL_GIT" -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/fixture.txt"
"$REAL_GIT" -C "$REPO" add fixture.txt
"$REAL_GIT" -C "$REPO" commit -q -m seed
"$REAL_GIT" -C "$REPO" push -q -u origin main
"$REAL_GIT" --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main

printf '1.2.3\n' >"${REPO}/VERSION"
"$REAL_GIT" -C "$REPO" add VERSION
"$REAL_GIT" -C "$REPO" commit -q -m 'chore(release): bump version to 1.2.3'
"$REAL_GIT" -C "$REPO" tag -a v1.2.3 -m 'Release v1.2.3 fixture'
RELEASE_COMMIT=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
TAG_OBJECT=$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.3)

"$REAL_GIT" clone -q "$REMOTE" "$CONCURRENT"
"$REAL_GIT" -C "$CONCURRENT" config user.name Test
"$REAL_GIT" -C "$CONCURRENT" config user.email test@example.invalid
printf 'concurrent\n' >"${CONCURRENT}/concurrent.txt"
"$REAL_GIT" -C "$CONCURRENT" add concurrent.txt
"$REAL_GIT" -C "$CONCURRENT" commit -q -m 'concurrent main update'
"$REAL_GIT" -C "$CONCURRENT" push -q origin main
CURRENT_MAIN=$("$REAL_GIT" -C "$CONCURRENT" rev-parse HEAD)

cat >"${BIN}/git" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GIT_LOG:?}"
args=" $* "
if [[ "$args" == *" push --atomic origin HEAD:refs/heads/main --tags "* ]]; then
	count=0
	if [[ -f "${DIRECT_PUSH_COUNT:?}" ]]; then
		IFS= read -r count <"$DIRECT_PUSH_COUNT"
	fi
	printf '%s\n' "$((count + 1))" >"$DIRECT_PUSH_COUNT"
	printf '%s\n' \
		'remote: error: GH006: Protected branch update failed for refs/heads/main.' \
		'remote: error: Changes must be made through a pull request.' \
		'remote: error: 4 of 4 required status checks are expected.' >&2
	exit 1
fi
exec "${REAL_GIT:?}" "$@"
STUB
chmod +x "${BIN}/git"

cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_GH_LOG:?}"
if [[ "${1:-}" == "api" && " $* " == *" repos/test/repo/pulls "* ]]; then
	if [[ ! -f "${PR_CREATED_FILE:?}" ]]; then
		printf '[]\n'
		exit 0
	fi
	if [[ -f "${PR_MERGED_FILE:?}" ]]; then
		branch_sha="${RECOVERY_HEAD:?}"
	else
		branch_sha=$("${REAL_GIT:?}" ls-remote "${REMOTE:?}" \
			'refs/heads/chore/release-v1.2.3-provenance' | cut -f1)
	fi
	auto_merge=null
	pr_state=open
	merged_at=null
	if [[ -f "${PR_MERGED_FILE:?}" ]]; then
		pr_state=closed
		merged_at="${PR_MERGED_AT_JSON:-\"2026-08-03T00:00:00Z\"}"
	fi
	author_association="${PR_AUTHOR_ASSOCIATION:-OWNER}"
	[[ ! -f "${AUTO_MERGE_FILE:?}" ]] || auto_merge='{"merge_method":"merge"}'
	body="<!-- aidevops:release-provenance tag=v1.2.3 tag-object=${TAG_OBJECT:?} release-commit=${RELEASE_COMMIT:?} merge-method=merge -->"
	jq -nc --arg branch_sha "$branch_sha" --arg body "$body" \
		--arg pr_state "$pr_state" --arg author_association "$author_association" \
		--argjson merged_at "$merged_at" --argjson auto_merge "$auto_merge" '[{
			number: 77,
			state: $pr_state,
			merged_at: $merged_at,
			draft: false,
			auto_merge: $auto_merge,
			author_association: $author_association,
			user: {login: "test-owner"},
			body: $body,
			head: {ref: "chore/release-v1.2.3-provenance", sha: $branch_sha, repo: {full_name: "test/repo"}},
			base: {ref: "main", repo: {full_name: "test/repo"}}
		}]'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "create" ]]; then
	: >"${PR_CREATED_FILE:?}"
	printf 'created\n'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "merge" ]]; then
	: >"${AUTO_MERGE_FILE:?}"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "ready" ]]; then
	exit 0
fi
exit 1
STUB
chmod +x "${BIN}/gh"

export REAL_GIT REMOTE RELEASE_COMMIT TAG_OBJECT
export FAKE_GIT_LOG="${TEST_ROOT}/git.log"
export FAKE_GH_LOG="${TEST_ROOT}/gh.log"
export DIRECT_PUSH_COUNT="${TEST_ROOT}/direct-push-count"
export PR_CREATED_FILE="${TEST_ROOT}/pr-created"
export AUTO_MERGE_FILE="${TEST_ROOT}/auto-merge"
export PR_MERGED_FILE="${TEST_ROOT}/pr-merged"
export PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export AIDEVOPS_VERSION_MANAGER_REPO_SLUG=test/repo

print_error() {
	printf 'ERROR %s\n' "$*"
	return 0
}
print_info() {
	printf 'INFO %s\n' "$*"
	return 0
}
print_warning() {
	printf 'WARNING %s\n' "$*"
	return 0
}
print_success() {
	printf 'SUCCESS %s\n' "$*"
	return 0
}

export REPO_ROOT="$REPO"
# shellcheck source=../version-manager-git.sh
source "${SCRIPT_DIR}/version-manager-git.sh"

push_rc=0
push_output=$(push_changes 1.2.3 2>&1) || push_rc=$?
if [[ "$push_rc" -ne 8 ]]; then
	printf 'FAIL protected-main fallback returned rc=%s: %s\n' "$push_rc" "$push_output"
	exit 1
fi
[[ "$(<"$DIRECT_PUSH_COUNT")" == "1" ]]
[[ "$push_output" == *'GH006 Changes must be made through a pull request'* ]]
printf 'PASS permanent PR-required rejection stops after one direct push\n'

RECOVERY_BRANCH='chore/release-v1.2.3-provenance'
RECOVERY_HEAD=$("$REAL_GIT" ls-remote "$REMOTE" "refs/heads/${RECOVERY_BRANCH}" | cut -f1)
export RECOVERY_HEAD
[[ "$RECOVERY_HEAD" =~ ^[0-9a-f]{40}$ ]]
[[ "$("$REAL_GIT" -C "$REPO" rev-parse "${RECOVERY_HEAD}^1")" == "$CURRENT_MAIN" ]]
[[ "$("$REAL_GIT" -C "$REPO" rev-parse "${RECOVERY_HEAD}^2")" == "$RELEASE_COMMIT" ]]
"$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$RELEASE_COMMIT" "$RECOVERY_HEAD"
[[ "$("$REAL_GIT" -C "$REPO" rev-parse refs/tags/v1.2.3)" == "$TAG_OBJECT" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
if grep -Eq ' rebase | commit --amend| tag -(d|s) ' "$FAKE_GIT_LOG"; then
	printf 'FAIL recovery rewrote the release commit or tag\n'
	exit 1
fi
printf 'PASS recovery branch preserves the original release commit and tag object\n'

grep -q '^pr create .*--head chore/release-v1.2.3-provenance .*--base main ' "$FAKE_GH_LOG"
grep -q "^pr merge 77 --repo test/repo --auto --merge --match-head-commit ${RECOVERY_HEAD}$" "$FAKE_GH_LOG"
printf 'PASS recovery queues merge topology against the exact PR head\n'

printf 'unreviewed descendant\n' >"${REPO}/unsafe.txt"
"$REAL_GIT" -C "$REPO" add unsafe.txt
"$REAL_GIT" -C "$REPO" commit -q -m 'unreviewed recovery descendant'
UNSAFE_HEAD=$("$REAL_GIT" -C "$REPO" rev-parse HEAD)
"$REAL_GIT" -C "$REPO" push -q origin "${UNSAFE_HEAD}:refs/heads/fixture-unsafe"
"$REAL_GIT" --git-dir="$REMOTE" update-ref "refs/heads/${RECOVERY_BRANCH}" "$UNSAFE_HEAD"
"$REAL_GIT" --git-dir="$REMOTE" update-ref -d refs/heads/fixture-unsafe
merge_calls_before=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
reconcile_unsafe_rc=0
reconcile_unsafe_output=$(_version_manager_reconcile_protected_release_tag \
	test/repo v1.2.3 reconcile 2>&1) || reconcile_unsafe_rc=$?
unsafe_rc=0
unsafe_output=$(_version_manager_queue_protected_main_release 1.2.3 2>&1) || unsafe_rc=$?
merge_calls_after=$(grep -c '^pr merge ' "$FAKE_GH_LOG")
[[ "$reconcile_unsafe_rc" -ne 0 ]]
[[ "$reconcile_unsafe_output" == *'outside the required merge topology'* ]]
[[ "$unsafe_rc" -ne 0 ]]
[[ "$unsafe_output" == *'outside the required merge topology'* ]]
[[ "$merge_calls_after" -eq "$merge_calls_before" ]]
"$REAL_GIT" --git-dir="$REMOTE" update-ref "refs/heads/${RECOVERY_BRANCH}" "$RECOVERY_HEAD"
"$REAL_GIT" -C "$REPO" update-ref "refs/remotes/origin/${RECOVERY_BRANCH}" "$RECOVERY_HEAD"
"$REAL_GIT" -C "$REPO" checkout -q --detach "$RECOVERY_HEAD"
printf 'PASS incompatible recovery descendants fail closed before merge queueing\n'

export PR_AUTHOR_ASSOCIATION=NONE
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1; then
	printf 'FAIL untrusted protected release PR authorized tag reconciliation\n'
	exit 1
fi
unset PR_AUTHOR_ASSOCIATION
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS protected release reconciliation requires a trusted PR author\n'

"$REAL_GIT" -C "$REPO" tag -f -a v1.2.3 -m 'replacement tag object' "$RELEASE_COMMIT"
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1; then
	printf 'FAIL replacement local tag object matched protected release evidence\n'
	exit 1
fi
"$REAL_GIT" -C "$REPO" update-ref refs/tags/v1.2.3 "$TAG_OBJECT"
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS protected release reconciliation binds the exact preserved tag object\n'

_version_manager_reconcile_protected_release_tag test/repo v1.2.3 status >/dev/null
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "pr-pending" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS final tag publication remains blocked while the recovery PR is open\n'

"$REAL_GIT" clone -q "$REMOTE" "$MERGER"
"$REAL_GIT" -C "$MERGER" config user.name Test
"$REAL_GIT" -C "$MERGER" config user.email test@example.invalid
"$REAL_GIT" -C "$MERGER" merge -q --no-ff --no-edit "origin/${RECOVERY_BRANCH}"
"$REAL_GIT" -C "$MERGER" push -q origin main
MERGED_MAIN=$("$REAL_GIT" -C "$MERGER" rev-parse HEAD)
: >"$PR_MERGED_FILE"
"$REAL_GIT" --git-dir="$REMOTE" update-ref -d "refs/heads/${RECOVERY_BRANCH}"

tag_pushes_before=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
_version_manager_reconcile_protected_release_tag test/repo v1.2.3 status >/dev/null
tag_pushes_after=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "tag-ready" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
printf 'PASS merged protected release status remains read-only after branch deletion\n'

export PR_MERGED_AT_JSON='"not-a-timestamp"'
tag_pushes_before=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 status \
	>/dev/null 2>&1 || _version_manager_reconcile_protected_release_tag \
	test/repo v1.2.3 reconcile >/dev/null 2>&1; then
	printf 'FAIL malformed protected PR merge evidence authorized reconciliation\n'
	exit 1
fi
tag_pushes_after=$({ grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG" || true; })
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
unset PR_MERGED_AT_JSON
printf 'PASS malformed protected PR merge evidence cannot publish a tag\n'

"$REAL_GIT" --git-dir="$REMOTE" update-ref refs/heads/main "$CURRENT_MAIN"
if _version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile \
	>/dev/null 2>&1; then
	printf 'FAIL merged PR metadata bypassed release ancestry verification\n'
	exit 1
fi
[[ -z "$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3)" ]]
"$REAL_GIT" --git-dir="$REMOTE" update-ref refs/heads/main "$MERGED_MAIN"
printf 'PASS merged protected release still requires exact main ancestry\n'

_version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile >/dev/null
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "tag-pushed" ]]
REMOTE_TAG_OBJECT=$("$REAL_GIT" ls-remote --tags "$REMOTE" refs/tags/v1.2.3 | cut -f1)
REMOTE_TAG_COMMIT=$("$REAL_GIT" ls-remote --tags "$REMOTE" 'refs/tags/v1.2.3^{}' | cut -f1)
[[ "$REMOTE_TAG_OBJECT" == "$TAG_OBJECT" ]]
[[ "$REMOTE_TAG_COMMIT" == "$RELEASE_COMMIT" ]]
"$REAL_GIT" -C "$REPO" fetch -q origin main --tags
"$REAL_GIT" -C "$REPO" merge-base --is-ancestor "$RELEASE_COMMIT" origin/main
[[ "$("$REAL_GIT" -C "$REPO" rev-list --count --grep='^chore(release): bump version to 1.2.3$' origin/main)" == "1" ]]
printf 'PASS merged recovery publishes the original tag object without a second bump\n'

tag_pushes_before=$(grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG")
_version_manager_reconcile_protected_release_tag test/repo v1.2.3 reconcile >/dev/null
tag_pushes_after=$(grep -c 'push origin refs/tags/v1.2.3:refs/tags/v1.2.3' "$FAKE_GIT_LOG")
[[ "$tag_pushes_after" -eq "$tag_pushes_before" ]]
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == "remote-tag-present" ]]
printf 'PASS repeated reconciliation is idempotent\n'

exit 0
