#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

# Keep disposable fixture repositories isolated from the developer Git shim,
# hooks, signing policy, and global branch defaults.
PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/release-provenance-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
REMOTE="${TEST_ROOT}/remote.git"
REPO="${TEST_ROOT}/repo"
BIN="${TEST_ROOT}/bin"

mkdir -p "$BIN"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" switch -q -c main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" commit -q --allow-empty -m 'historical merge'
HISTORICAL_MERGE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" commit -q --allow-empty -m 'source merge'
SOURCE_MERGE=$(git -C "$REPO" rev-parse HEAD)
printf '1.2.3\n' >"${REPO}/VERSION"
printf '{"name":"fixture","version":"1.2.3"}\n' >"${REPO}/package.json"
git -C "$REPO" add VERSION package.json
git -C "$REPO" commit -q -m 'chore(release): bump version to 1.2.3'
TAG_COMMIT=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" tag -a v1.2.3 -m "Release v1.2.3 - fixture

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 42
Aidevops-Source-Merge: ${SOURCE_MERGE}"
git -C "$REPO" push -q -u origin main --tags

cat >"${BIN}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "pr" ]]; then
	case "\${PROVENANCE_MODE:-valid}" in
	pr-mismatch) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-25T00:00:00Z","baseRefName":"main","headRefOid":"head","mergeCommit":{"oid":"0000000000000000000000000000000000000000"}}' ;;
	stale-source) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-25T00:00:00Z","baseRefName":"main","headRefOid":"head","mergeCommit":{"oid":"${HISTORICAL_MERGE}"}}' ;;
	*) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-25T00:00:00Z","baseRefName":"main","headRefOid":"head","mergeCommit":{"oid":"${SOURCE_MERGE}"}}' ;;
	esac
	exit 0
fi
case "\${2:-}" in
repos/test/repo/git/ref/tags/v1.2.3)
	if [[ "\${PROVENANCE_MODE:-valid}" == "tag-object-mismatch" ]]; then
		printf '%s\n' '{"object":{"type":"tag","sha":"0000000000000000000000000000000000000000"}}'
	else
		printf '{"object":{"type":"tag","sha":"%s"}}\n' "\$(git -C "${REPO}" rev-parse refs/tags/v1.2.3)"
	fi
	;;
repos/test/repo/git/tags/*)
	if [[ "\${PROVENANCE_MODE:-valid}" == "unverified" ]]; then
		printf '%s\n' '{"tag":"v1.2.3","object":{"type":"commit","sha":"${TAG_COMMIT}"},"verification":{"verified":false}}'
	else
		printf '%s\n' '{"tag":"v1.2.3","object":{"type":"commit","sha":"${TAG_COMMIT}"},"verification":{"verified":true}}'
	fi
	;;
*) exit 1 ;;
esac
STUB
chmod +x "${BIN}/gh"

run_helper() {
	local mode="${1:-valid}"
	(
		cd "$REPO" || exit 1
		export PROVENANCE_MODE="$mode"
		PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
			bash "$HELPER" verify --tag v1.2.3 --repo test/repo
	)
	return $?
}

assert_rejected() {
	local name="$1"
	local mode="$2"
	if run_helper "$mode" >/dev/null 2>&1; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

run_helper >/dev/null || {
	printf 'FAIL valid release provenance was rejected\n'
	exit 1
}
printf 'PASS valid release provenance is accepted\n'

assert_rejected "unverified GitHub tag is rejected" "unverified"
assert_rejected "local and GitHub tag-object mismatch is rejected" "tag-object-mismatch"
assert_rejected "source PR merge mismatch is rejected" "pr-mismatch"

printf '1.2.4\n' >"${REPO}/VERSION"
if run_helper >/dev/null 2>&1; then
	printf 'FAIL version drift was accepted\n'
	exit 1
fi
printf 'PASS version drift is rejected\n'
printf '1.2.3\n' >"${REPO}/VERSION"

git -C "$REPO" push -q --force origin "${SOURCE_MERGE}:main"
if run_helper >/dev/null 2>&1; then
	printf 'FAIL non-main release commit was accepted\n'
	exit 1
fi
printf 'PASS non-main release commit is rejected\n'
git -C "$REPO" push -q --force origin "${TAG_COMMIT}:main"

git -C "$REPO" tag -d v1.2.3 >/dev/null
git -C "$REPO" tag -a v1.2.3 -m "Release v1.2.3 - fixture

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 42
Aidevops-Source-Merge: ${HISTORICAL_MERGE}"
assert_rejected "historical source PR ancestor is rejected" "stale-source"

git -C "$REPO" tag -a v1.2.4 -m 'Release without provenance'
if (
	cd "$REPO" || exit 1
	PATH="${BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$HELPER" verify --tag v1.2.4 --repo test/repo
) >/dev/null 2>&1; then
	printf 'FAIL malformed tag was accepted\n'
	exit 1
fi
printf 'PASS malformed tag is rejected\n'

AGG_REMOTE="${TEST_ROOT}/aggregate-remote.git"
AGG_REPO="${TEST_ROOT}/aggregate-repo"
AGG_BIN="${TEST_ROOT}/aggregate-bin"
mkdir -p "$AGG_BIN"
git init -q --bare "$AGG_REMOTE"
git clone -q "$AGG_REMOTE" "$AGG_REPO"
git -C "$AGG_REPO" switch -q -c main
git -C "$AGG_REPO" config user.name Test
git -C "$AGG_REPO" config user.email test@example.invalid
git -C "$AGG_REPO" commit -q --allow-empty -m seed
git -C "$AGG_REPO" commit -q --allow-empty -m 'authorized source merge'
AGG_ORIGINAL=$(git -C "$AGG_REPO" rev-parse HEAD)
git -C "$AGG_REPO" commit -q --allow-empty -m 'unreviewed automated synchronization'
git -C "$AGG_REPO" commit -q --allow-empty -m "reviewed aggregate source

Aidevops-Release-Aggregator-PR: 99
Aidevops-Release-Aggregates: 42@${AGG_ORIGINAL}"
AGGREGATE_MERGE=$(git -C "$AGG_REPO" rev-parse HEAD)
git -C "$AGG_REPO" push -q -u origin main

cat >"${AGG_BIN}/gh" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "pr" ]]; then
	case "\${3:-}" in
	42) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-26T00:00:00Z","baseRefName":"main","headRefOid":"source-head","mergeCommit":{"oid":"${AGG_ORIGINAL}"}}' ;;
	99) printf '%s\n' '{"state":"MERGED","mergedAt":"2026-07-27T00:00:00Z","baseRefName":"main","headRefOid":"aggregate-head","mergeCommit":{"oid":"${AGGREGATE_MERGE}"}}' ;;
	*) exit 1 ;;
	esac
	exit 0
fi
case "\${2:-}" in
repos/test/aggregate/git/ref/tags/v2.0.0)
	printf '{"object":{"type":"tag","sha":"%s"}}\n' "\$(git -C "${AGG_REPO}" rev-parse refs/tags/v2.0.0)"
	;;
repos/test/aggregate/git/tags/*)
	printf '{"tag":"v2.0.0","object":{"type":"commit","sha":"%s"},"verification":{"verified":true}}\n' "\${AGG_TAG_COMMIT:-pending}"
	;;
*) exit 1 ;;
esac
STUB
chmod +x "${AGG_BIN}/gh"

aggregate_json=$(
	cd "$AGG_REPO" || exit 1
	PATH="${AGG_BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$HELPER" resolve-source --source-pr 42 --repo test/aggregate
)
jq -e --arg merge "$AGGREGATE_MERGE" --arg original "$AGG_ORIGINAL" '
	.mode == "aggregate" and .source_pr == 99 and .source_merge == $merge
	and .aggregated_sources == [{pr:42,merge:$original}]
' <<<"$aggregate_json" >/dev/null
printf 'PASS reviewed aggregation manifest recovers an authorized historical source\n'

git -C "$AGG_REPO" switch -q --detach "$AGG_ORIGINAL"
git -C "$AGG_REPO" commit -q --allow-empty -m 'unreviewed direct commit'
if (
	cd "$AGG_REPO" || exit 1
	PATH="${AGG_BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$HELPER" resolve-source --source-pr 42 --repo test/aggregate
) >/dev/null 2>&1; then
	printf 'FAIL unreviewed direct commit was accepted as an aggregate source\n'
	exit 1
fi
printf 'PASS unreviewed direct commit cannot aggregate release authority\n'
git -C "$AGG_REPO" switch -q --detach "$AGGREGATE_MERGE"

printf '2.0.0\n' >"${AGG_REPO}/VERSION"
printf '{"name":"fixture","version":"2.0.0"}\n' >"${AGG_REPO}/package.json"
git -C "$AGG_REPO" add VERSION package.json
git -C "$AGG_REPO" commit -q -m 'chore(release): bump version to 2.0.0'
AGG_TAG_COMMIT=$(git -C "$AGG_REPO" rev-parse HEAD)
export AGG_TAG_COMMIT
git -C "$AGG_REPO" tag -a v2.0.0 -m "Release v2.0.0 - aggregate fixture

Aidevops-Version: 2.0.0
Aidevops-Source-PR: 99
Aidevops-Source-Merge: ${AGGREGATE_MERGE}
Aidevops-Aggregated-Source: 42@${AGG_ORIGINAL}"
git -C "$AGG_REPO" push -q origin HEAD:main --tags
(
	cd "$AGG_REPO" || exit 1
	PATH="${AGG_BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$HELPER" verify --tag v2.0.0 --repo test/aggregate >/dev/null
)
printf 'PASS immutable tag provenance verifies the reviewed aggregate and every included source\n'

git -C "$AGG_REPO" tag -d v2.0.0 >/dev/null
git -C "$AGG_REPO" tag -a v2.0.0 -m "Release v2.0.0 - tampered aggregate fixture

Aidevops-Version: 2.0.0
Aidevops-Source-PR: 99
Aidevops-Source-Merge: ${AGGREGATE_MERGE}"
if (
	cd "$AGG_REPO" || exit 1
	PATH="${AGG_BIN}:/opt/homebrew/bin:/usr/bin:/bin" \
		bash "$HELPER" verify --tag v2.0.0 --repo test/aggregate
) >/dev/null 2>&1; then
	printf 'FAIL tag omitted the reviewed aggregate sources\n'
	exit 1
fi
printf 'PASS tag tampering cannot omit reviewed aggregate sources\n'

exit 0
