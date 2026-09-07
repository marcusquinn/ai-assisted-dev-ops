#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Real capture/bind/persistence helpers with an offline verified-resolver fixture.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
# shellcheck source=../full-loop-release-helper.sh
source "$SCRIPT_DIR/full-loop-release-helper.sh" help >/dev/null

FIRST=1111111111111111111111111111111111111111
SNAPSHOT=2222222222222222222222222222222222222222
BASE=0000000000000000000000000000000000000000
CASE_NUMBER=0
STATE='{}'
WRITES=0
READ_FAIL=0
BIND_FAIL=0
export SOURCE_JSON
SOURCE_JSON=$(jq -cn --arg first "$FIRST" --arg sha "$SNAPSHOT" --arg base "$BASE" \
	'{mode:"snapshot",requested_pr:41,source_pr:42,source_merge:$sha,snapshot_base:$base,
	expected_sources:[{pr:41,merge:$first},{pr:42,merge:$sha}]}')
cat >"$ROOT/resolver.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$SOURCE_JSON"
EOF

release_lane_read() {
	[[ "$READ_FAIL" == 0 ]] || return 1
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	_AIDEVOPS_RELEASE_LANE_HEAD="$FIRST"
	return 0
}
_release_lane_write() {
	[[ "$BIND_FAIL" == 0 && "$3" == "$FIRST" ]] || return 1
	WRITES=$((WRITES + 1))
	STATE="$2"
	_AIDEVOPS_RELEASE_LANE_JSON="$STATE"
	return 0
}
reset_case() {
	CASE_NUMBER=$((CASE_NUMBER + 1))
	export AIDEVOPS_FULL_LOOP_RECEIPT_DIR="$ROOT/receipts-$CASE_NUMBER"
	WRITES=0 READ_FAIL=0 BIND_FAIL=0
	_AIDEVOPS_RELEASE_LANE_TOKEN=fixture
	STATE=$(jq -cn --arg sha "$SNAPSHOT" --arg base "$BASE" \
		'{schema_version:1,repository:"test/repo",active:true,source_pr:41,phase:"reserved",
		tag:null,terminal_receipt:null,snapshot_sha:$sha,snapshot_base:$base,
		expected_sources:"41",operation_token:"fixture"}')
	_full_loop_persist_release_authorization test/repo 41 "41@$FIRST"
	return $?
}
capture_snapshot() {
	_full_loop_capture_release_authorization test/repo 41 "$ROOT" "$ROOT/resolver.sh" "${1:-}"
	return $?
}
refuse_capture() {
	local name="$1"
	local before="$STATE"
	if capture_snapshot "${2:-}" >/dev/null 2>&1; then
		printf 'FAIL: accepted %s\n' "$name"
		exit 1
	fi
	[[ "$STATE" == "$before" && "$WRITES" == 0 ]] || exit 1
	[[ "$(_full_loop_read_release_authorization test/repo 41)" == "41@$FIRST" ]] || exit 1
	printf 'PASS: rejects %s before mutation\n' "$name"
	return 0
}

reset_case
capture_snapshot
[[ "$(_full_loop_read_release_authorization test/repo 41)" == "41@$FIRST,42@$SNAPSHOT" ]]
_full_loop_read_release_authorization_recovery_snapshot test/repo 41 | jq -e '.expected_sources | length == 1' >/dev/null
capture_snapshot
printf 'PASS: implicit legacy subset expands lane-first with prior evidence and replay\n'

reset_case
refuse_capture 'explicit incomplete CLI assertion' 41
reset_case
refuse_capture 'explicit conflicting merge assertion' "41@$SNAPSHOT,42@$SNAPSHOT"
original_source="$SOURCE_JSON"
for change in '.expected_sources |= map(select(.pr != 41))' '.expected_sources[0].merge="3333333333333333333333333333333333333333"'; do
	reset_case
	SOURCE_JSON=$(jq -c "$change" <<<"$original_source")
	refuse_capture 'missing or conflicting prior source'
done
SOURCE_JSON="$original_source"
for change in '.phase="preparing"' '.tag="v1.2.3"' '.terminal_receipt="failed"' '.prepublication_recovery={}' '.aggregate_recovery={}' '.aggregate_successor={}' '.reserved_authorization_refresh={}' '.source_pr=99' '.snapshot_sha="3333333333333333333333333333333333333333"' '.expected_sources="99"' '.expected_sources="41@3333333333333333333333333333333333333333"'; do
	reset_case
	STATE=$(jq -c "$change" <<<"$STATE")
	refuse_capture "$change"
done
reset_case
READ_FAIL=1
refuse_capture 'unavailable publisher lane'
reset_case
BIND_FAIL=1
refuse_capture 'CAS conflict'
reset_case
_AIDEVOPS_RELEASE_LANE_TOKEN=other-owner
refuse_capture 'stale ownership token'

reset_case
original_writer=$(declare -f _full_loop_write_release_authorization_record)
_full_loop_write_release_authorization_record() { return 1; }
if capture_snapshot; then exit 1; fi
jq -e '.snapshot_manifest_bound == true' <<<"$STATE" >/dev/null
[[ "$(_full_loop_read_release_authorization test/repo 41)" == "41@$FIRST" ]]
eval "$original_writer"
capture_snapshot
[[ "$(_full_loop_read_release_authorization test/repo 41)" == "41@$FIRST,42@$SNAPSHOT" ]]
printf 'PASS: interrupted local persistence resumes the identical lane-bound snapshot\n'

reset_case
_full_loop_release_guard_competing_lane() { return 0; }
_full_loop_release_guard_existing() {
	[[ "$3" == "$EXPECTED_ARGUMENT" ]]
	return $?
}
EXPECTED_ARGUMENT=""
_full_loop_release_start_new test/repo 41 patch incremental ""
EXPECTED_ARGUMENT="41,42"
_full_loop_release_start_new test/repo 41 patch incremental "41,42"
printf 'PASS: start preserves explicit assertions without promoting an implicit legacy subset\n'
