#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
set -euo pipefail

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../release-snapshot-helper.sh
source "$SCRIPT_DIR/release-snapshot-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
git init -q "$TEST_ROOT/repo"
cd "$TEST_ROOT/repo"
git config user.name Test
git config user.email test@example.invalid
git commit -q --allow-empty -m baseline
BASE=$(git rev-parse HEAD)
git commit -q --allow-empty -m first
FIRST=$(git rev-parse HEAD)
git commit -q --allow-empty -m second
SNAPSHOT=$(git rev-parse HEAD)
git commit -q --allow-empty -m later
LATER=$(git rev-parse HEAD)

gh() {
	local commit="${4:-}"
	local number=0
	if [[ "$1" == pr ]]; then
		case "$3" in
		1) commit="$FIRST" ;;
		2) commit="$SNAPSHOT" ;;
		3) commit="$LATER" ;;
		*) return 1 ;;
		esac
		jq -cn --arg sha "$commit" '{state:"MERGED",mergedAt:"2026-09-07T00:00:00Z",baseRefName:"main",headRefOid:$sha,mergeCommit:{oid:$sha}}'
		return $?
	fi
	case "$2" in
	repos/test/repo/git/ref/tags/v1.0.0)
		jq -cn --arg sha "$(git rev-parse refs/tags/v1.0.0)" '{object:{type:"tag",sha:$sha}}'
		return $?
		;;
	repos/test/repo/git/tags/*)
		jq -cn --arg sha "$BASE" '{tag:"v1.0.0",object:{type:"commit",sha:$sha},verification:{verified:true}}'
		return $?
		;;
	esac
	commit="${commit#repos/test/repo/commits/}"
	commit="${commit%%/*}"
	case "$commit" in
	"$FIRST") number=1 ;;
	"$SNAPSHOT") number=2 ;;
	"$LATER") number=3 ;;
	*) return 1 ;;
	esac
	[[ "${API_FAILURE:-false}" == false ]] || return 1
	case "${ASSOCIATION_MODE:-exact}" in
	rebase)
		number=2
		commit="$SNAPSHOT"
		;;
	future)
		number=3
		commit="$LATER"
		;;
	empty)
		printf '[[]]\n'
		return 0
		;;
	esac
	jq -cn --arg sha "$commit" --argjson number "$number" --arg branch "${PR_BRANCH:-main}" '
		[[{number:$number,state:"closed",merged_at:"2026-09-07T00:00:00Z",
		merge_commit_sha:$sha,base:{ref:$branch,repo:{full_name:"test/repo"}}}]]'
	return $?
}

actual=$(release_snapshot_sources test/repo main "$BASE" "$SNAPSHOT")
expected=$(jq -cn --arg first "$FIRST" --arg second "$SNAPSHOT" '[{pr:1,merge:$first},{pr:2,merge:$second}]')
[[ "$actual" == "$expected" ]]
printf 'PASS: frozen snapshot includes all earlier PRs, excludes concurrent later merge\n'
rebased=$(ASSOCIATION_MODE=rebase release_snapshot_sources test/repo main "$BASE" "$SNAPSHOT")
[[ "$rebased" == "$(jq -cn --arg sha "$SNAPSHOT" '[{pr:2,merge:$sha}]')" ]]
for invalid in future empty; do
	if ASSOCIATION_MODE="$invalid" release_snapshot_sources test/repo main "$BASE" "$SNAPSHOT" 2>/dev/null; then
		printf 'FAIL: invalid association %s accepted\n' "$invalid" >&2
		exit 1
	fi
done
printf 'PASS: rebase-merged PRs deduplicate while incomplete or future associations fail closed\n'
if API_FAILURE=true release_snapshot_sources test/repo main "$BASE" "$SNAPSHOT"; then
	printf 'FAIL: API uncertainty accepted\n' >&2
	exit 1
fi
if PR_BRANCH=other release_snapshot_sources test/repo main "$BASE" "$SNAPSHOT" 2>/dev/null; then
	printf 'FAIL: foreign base accepted\n' >&2
	exit 1
fi
if release_snapshot_sources test/repo main "$LATER" "$SNAPSHOT" 2>/dev/null; then
	printf 'FAIL: non-ancestor base accepted\n' >&2
	exit 1
fi
printf 'PASS: API uncertainty, foreign base and rewritten ancestry rejected\n'

# Exercise the actual resolver at a detached snapshot while remote main has
# already advanced, including the explicit complete-manifest integrity gate.
export BASE FIRST SNAPSHOT LATER
export -f gh
git tag -a v1.0.0 "$BASE" -m baseline
git update-ref refs/remotes/origin/main "$LATER"
git checkout -q --detach "$SNAPSHOT"
resolver="$SCRIPT_DIR/release-provenance-helper.sh"
resolved=$(bash "$resolver" resolve-source --snapshot --source-pr 1 --repo test/repo)
jq -e --arg sha "$SNAPSHOT" --arg base "$BASE" --argjson sources "$expected" '
	.mode == "snapshot" and .source_pr == 2 and .source_merge == $sha
	and .snapshot_base == $base and .expected_sources == $sources' <<<"$resolved" >/dev/null
if bash "$resolver" resolve-source --snapshot --source-pr 1 --repo test/repo --expected-sources 1 2>/dev/null; then
	printf 'FAIL: incomplete expected manifest accepted\n' >&2
	exit 1
fi
bash "$resolver" resolve-source --snapshot --source-pr 1 --repo test/repo --expected-sources 2,1 >/dev/null
if bash "$resolver" resolve-source --snapshot --source-pr 3 --repo test/repo 2>/dev/null; then
	printf 'FAIL: later PR entered frozen snapshot\n' >&2
	exit 1
fi
git update-ref refs/remotes/origin/main "$BASE"
if bash "$resolver" resolve-source --snapshot --source-pr 1 --repo test/repo 2>/dev/null; then
	printf 'FAIL: rewritten main accepted\n' >&2
	exit 1
fi
printf 'PASS: real snapshot resolver pins range, verifies complete manifest and rejects rewritten main\n'

# Verify the actual signed-tag publication path after main gains a distinct
# tree. Only the fixture's generated key and bare remote are used.
git init -q --bare "$TEST_ROOT/remote.git"
git remote add origin "$TEST_ROOT/remote.git"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/signing-key"
printf 'test@example.invalid %s\n' "$(cat "$TEST_ROOT/signing-key.pub")" >"$TEST_ROOT/allowed-signers"
git config gpg.format ssh
git config user.signingkey "$TEST_ROOT/signing-key"
git config gpg.ssh.allowedSignersFile "$TEST_ROOT/allowed-signers"
printf '1.0.1\n' >VERSION
git add VERSION
git commit -q -m 'chore(release): bump version to 1.0.1'
RELEASE=$(git rev-parse HEAD)
git tag -s v1.0.1 -m "Release snapshot

Aidevops-Version: 1.0.1
Aidevops-Source-PR: 2
Aidevops-Source-Merge: $SNAPSHOT
Aidevops-Snapshot-Base: $BASE
Aidevops-Aggregated-Source: 1@$FIRST
Aidevops-Aggregated-Source: 2@$SNAPSHOT"
git checkout -q --detach "$LATER"
printf 'later main content\n' >later.txt
git add later.txt
git commit -q -m 'later content'
git merge -q --no-ff --no-edit "$RELEASE"
git push -q origin HEAD:refs/heads/main
git checkout -q --detach "$RELEASE"
bash "$resolver" verify-local-source --tag v1.0.1 --repo test/repo >/dev/null
REPO_ROOT="$TEST_ROOT/repo"
# shellcheck source=../version-manager-git.sh
source "$SCRIPT_DIR/version-manager-git.sh"
AIDEVOPS_VERSION_MANAGER_REPO_SLUG=test/repo push_changes 1.0.1
[[ "$_VERSION_MANAGER_PROTECTED_RELEASE_RESULT" == tag-pushed ]]
[[ "$(git --git-dir="$TEST_ROOT/remote.git" rev-parse 'refs/tags/v1.0.1^{commit}')" == "$RELEASE" ]]
[[ "$(git rev-parse 'origin/main^{tree}')" != "$(git rev-parse 'v1.0.1^{tree}')" ]]
printf 'PASS: signed immutable snapshot publishes after concurrent main tree changes\n'

tag_authorization=$(bash "$resolver" resolve-tag-authorization --tag v1.0.1 --source-pr 2 --repo test/repo)
jq -e '.mode == "snapshot" and (.expected_sources | length) == 2' <<<"$tag_authorization" >/dev/null
if bash "$resolver" resolve-tag-authorization --tag v1.0.1 --source-pr 2 --repo test/repo --expected-sources 2 2>/dev/null; then
	printf 'FAIL: snapshot tag accepted a truncated explicit source set\n' >&2
	exit 1
fi
# shellcheck source=../full-loop-release-reconcile.sh
source "$SCRIPT_DIR/full-loop-release-reconcile.sh"
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
reconstructed=$(_full_loop_release_source_json_from_tag v1.0.1)
jq -e '.mode == "snapshot" and .source_pr == 2 and (.aggregated_sources | length) == 2' <<<"$reconstructed" >/dev/null
printf 'PASS: reconciliation reconstructs the full snapshot and explicit assertions cannot truncate it\n'

# Snapshot and manifest are bound by the publisher's CAS ownership, not by
# the continued absence of ordinary merges.
# shellcheck source=../release-lane-helper.sh
source "$SCRIPT_DIR/release-lane-helper.sh"
lane=$(jq -cn '{active:true,source_pr:1,phase:"reserved",tag:null,terminal_receipt:null,operation_token:"fixture",expected_sources:"1"}')
_AIDEVOPS_RELEASE_LANE_TOKEN=fixture
release_lane_read() {
	_AIDEVOPS_RELEASE_LANE_JSON="$lane"
	return 0
}
_release_lane_write() {
	lane="$2"
	return 0
}
release_lane_pin_snapshot test/repo 1 "$SNAPSHOT" "$BASE" v1.0.0 "$(git rev-parse refs/tags/v1.0.0)"
release_lane_bind_snapshot test/repo 1 "$resolved"
release_lane_bind_snapshot test/repo 1 "$resolved"
if release_lane_pin_snapshot test/repo 1 "$LATER" "$BASE" v1.0.0 "$(git rev-parse refs/tags/v1.0.0)"; then
	printf 'FAIL: retry replaced immutable snapshot\n' >&2
	exit 1
fi
_AIDEVOPS_RELEASE_LANE_TOKEN=stale-fixture
if release_lane_bind_snapshot test/repo 1 "$resolved"; then
	printf 'FAIL: stale publisher changed snapshot manifest\n' >&2
	exit 1
fi
printf 'PASS: lane pin and manifest are idempotent and reject drift or stale owners\n'
