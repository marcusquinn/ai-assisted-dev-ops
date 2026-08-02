#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

# Keep disposable fixture repositories isolated from the developer's guarded
# Git shim, global hooks, and signing policy.
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REMOTE="${ROOT}/remote.git"
REPO="${ROOT}/repo"
LINKED="${ROOT}/release"
BIN="${ROOT}/bin"
RESOLVER_LOG="${ROOT}/resolver.log"
export RESOLVER_LOG
mkdir -p "$BIN"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" switch -q -c main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m seed
HISTORICAL_MERGE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m 'current source merge'
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main
MERGE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" worktree add -q --detach "$LINKED" origin/main

cat >"${BIN}/gh" <<STUB
#!/usr/bin/env bash
case "\${PROVENANCE_MODE:-merged}" in
	open) printf '%s\n' '{"state":"OPEN","mergedAt":null,"baseRefName":"main","headRefOid":"head123","mergeCommit":null}' ;;
	stale) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","baseRefName":"main","headRefOid":"head123","mergeCommit":{"oid":"${HISTORICAL_MERGE}"}}' ;;
	*) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-11T00:00:00Z","baseRefName":"main","headRefOid":"head123","mergeCommit":{"oid":"${MERGE_SHA}"}}' ;;
esac
exit 0
STUB
chmod +x "${BIN}/gh"

print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
export SCRIPT_DIR REPO_ROOT="$LINKED"
source "${SCRIPT_DIR}/version-manager-git.sh"
source "${SCRIPT_DIR}/version-manager-release.sh"

release_source_pr_required() { return 0; }
VERSION_MANAGER_SOURCE_PR=42
VERSION_MANAGER_SOURCE_MERGE_SHA="$MERGE_SHA"
tag_message=$(_release_tag_message 1.2.3) || {
	printf 'FAIL release tag provenance message was rejected\n'
	exit 1
}
for expected_trailer in \
	'Aidevops-Version: 1.2.3' \
	'Aidevops-Source-PR: 42' \
	"Aidevops-Source-Merge: ${MERGE_SHA}"; do
	if [[ "$tag_message" != *"$expected_trailer"* ]]; then
		printf 'FAIL release tag message lacks %s\n' "$expected_trailer"
		exit 1
	fi
done
printf 'PASS release tag message records immutable source provenance\n'

VERSION_MANAGER_SOURCE_PR=""
if _release_tag_message 1.2.3 >/dev/null 2>&1; then
	printf 'FAIL release tag message accepted missing source PR provenance\n'
	exit 1
fi
printf 'PASS release tag message rejects missing source PR provenance\n'
VERSION_MANAGER_SOURCE_PR=42

PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops || {
	printf 'FAIL merged source PR provenance was rejected\n'
	exit 1
}
printf 'PASS merged source PR provenance is accepted\n'

if PROVENANCE_MODE=open PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'FAIL open source PR was accepted\n'
	exit 1
fi
printf 'PASS open source PR is rejected\n'

if PROVENANCE_MODE=stale PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'FAIL stale historical source PR was accepted\n'
	exit 1
fi
printf 'PASS stale historical source PR is rejected\n'

cat >"${BIN}/aggregate-resolver.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"\${RESOLVER_LOG:?}"
expected_sources=""
while [[ \$# -gt 0 ]]; do
	case "\$1" in
	--expected-sources) expected_sources="\${2:-}"; shift 2 ;;
	*) shift ;;
	esac
done
[[ "\$expected_sources" == "42@${HISTORICAL_MERGE}" ]] || exit 1
printf '%s\n' '{"mode":"aggregate","requested_pr":42,"source_pr":99,"source_merge":"${MERGE_SHA}","aggregated_sources":[{"pr":42,"merge":"${HISTORICAL_MERGE}"}]}'
exit 0
STUB
chmod +x "${BIN}/aggregate-resolver.sh"
AIDEVOPS_RELEASE_SOURCE_RESOLVER="${BIN}/aggregate-resolver.sh" \
	verify_release_source_pr 42 main testorg/aidevops "42@${HISTORICAL_MERGE}" || {
	printf 'FAIL version manager rejected reviewed aggregate source metadata\n'
	exit 1
}
grep -qx "resolve-source --source-pr 42 --repo testorg/aidevops --branch main --expected-sources 42@${HISTORICAL_MERGE}" \
	"$RESOLVER_LOG"
[[ "$VERSION_MANAGER_SOURCE_PR" == "99" ]]
[[ "$VERSION_MANAGER_SOURCE_MERGE_SHA" == "$MERGE_SHA" ]]
[[ "$VERSION_MANAGER_AGGREGATED_SOURCES" == "42@${HISTORICAL_MERGE}" ]]
[[ "$VERSION_MANAGER_EXPECTED_SOURCES" == "42@${HISTORICAL_MERGE}" ]]
aggregate_tag_message=$(_release_tag_message 1.2.3)
[[ "$aggregate_tag_message" == *"Aidevops-Source-PR: 99"* ]]
[[ "$aggregate_tag_message" == *"Aidevops-Aggregated-Source: 42@${HISTORICAL_MERGE}"* ]]
printf 'PASS version manager carries aggregate source provenance into immutable tag trailers\n'
if AIDEVOPS_RELEASE_SOURCE_RESOLVER="${BIN}/aggregate-resolver.sh" \
	verify_release_source_pr 42 main testorg/aidevops "42@${MERGE_SHA}"; then
	printf 'FAIL version manager accepted a changed authorization set at the final boundary\n'
	exit 1
fi
printf 'PASS version manager forwards the exact trusted set at the final boundary\n'
VERSION_MANAGER_SOURCE_PR=42
VERSION_MANAGER_SOURCE_MERGE_SHA="$MERGE_SHA"
VERSION_MANAGER_AGGREGATED_SOURCES=""

git -C "$REPO" switch -q -c safety/release-test
printf 'canonical human work\n' >>"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m 'local canonical divergence'
printf 'uncommitted human work\n' >>"${REPO}/README.md"
if verify_remote_sync main >/dev/null 2>&1 &&
	PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" verify_release_source_pr 42 main testorg/aidevops; then
	printf 'PASS dirty diverged canonical checkout is irrelevant to detached release provenance\n'
else
	printf 'FAIL canonical checkout state blocked detached release provenance\n'
	exit 1
fi

if grep -qF 'verify_canonical_default_synced' "${SCRIPT_DIR}/version-manager.sh"; then
	printf 'FAIL release path still depends on canonical synchronization\n'
	exit 1
fi
printf 'PASS release path has no canonical synchronization dependency\n'

CONCURRENT="${ROOT}/concurrent"
git clone -q -b main "$REMOTE" "$CONCURRENT"
git -C "$CONCURRENT" config user.name Test
git -C "$CONCURRENT" config user.email test@example.invalid
git -C "$CONCURRENT" commit -q --allow-empty -m 'concurrent main update'
git -C "$CONCURRENT" push -q origin HEAD:main

printf '1.2.3\n' >"${LINKED}/VERSION"
git -C "$LINKED" add VERSION
git -C "$LINKED" commit -q -m 'chore(release): bump version to 1.2.3'
git -C "$LINKED" tag -a v1.2.3 -m "Release v1.2.3 - fixture

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 42
Aidevops-Source-Merge: ${MERGE_SHA}"
if push_changes 1.2.3 >/dev/null 2>&1; then
	printf 'FAIL concurrent main update was rebased into release publication\n'
	exit 1
fi
if git -C "$LINKED" show-ref --verify --quiet refs/tags/v1.2.3 ||
	git -C "$REMOTE" show-ref --verify --quiet refs/tags/v1.2.3; then
	printf 'FAIL concurrent main update left a release tag behind\n'
	exit 1
fi
printf 'PASS concurrent main update aborts without publishing a release tag\n'

exit 0
