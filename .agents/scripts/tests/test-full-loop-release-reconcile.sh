#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Durable release reconciliation regression tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
REPO_ROOT="${SCRIPT_DIR}/../.."
_FULL_LOOP_SHA40_REGEX='^[0-9a-f]{40}$'
_FULL_LOOP_PHASE_FAILED="failed"
_FULL_LOOP_RELEASE_PUBLISHED="published"
_FULL_LOOP_RELEASE_SUPERSEDED="superseded"
_FULL_LOOP_RELEASE_NOT_REQUESTED="not-requested"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "${TEST_ROOT}/bin" "${TEST_ROOT}/receipts"

# shellcheck source=../full-loop-release-reconcile.sh
source "${SCRIPT_DIR}/full-loop-release-reconcile.sh"

_full_loop_release_tag_body() {
	local tag_name="$1"
	[[ "$tag_name" == "v1.2.3" ]] || return 1
	cat <<'BODY'
Release v1.2.3

Aidevops-Version: 1.2.3
Aidevops-Source-PR: 90
Aidevops-Source-Merge: 1111111111111111111111111111111111111111
Aidevops-Aggregated-Source: 89@2222222222222222222222222222222222222222
BODY
	return 0
}

source_json=$(_full_loop_release_source_json_from_tag v1.2.3)
if ! jq -e '.source_pr == 90
	and .source_merge == "1111111111111111111111111111111111111111"
	and .aggregated_sources == [{"pr":89,"merge":"2222222222222222222222222222222222222222"}]' \
	<<<"$source_json" >/dev/null; then
	printf 'FAIL signed tag trailers did not reconstruct release provenance\n'
	exit 1
fi
printf 'PASS signed tag trailers reconstruct release provenance\n'

cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" -f event=push "* ]]; then
	printf '%s\n' '{"workflow_runs":[{"id":10,"event":"push","head_sha":"3333333333333333333333333333333333333333","status":"completed","conclusion":"success","created_at":"2026-07-27T00:00:00Z","display_title":"push","html_url":"push-url"}]}'
	exit 0
fi
if [[ "$args" == *" -f event=workflow_dispatch "* ]]; then
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_sha":"4444444444444444444444444444444444444444","status":"queued","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3","html_url":"recovery-url"}]}'
	exit 0
fi
exit 1
STUB
chmod +x "${TEST_ROOT}/bin/gh"
PATH="${TEST_ROOT}/bin:${PATH}"

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "11" ]]; then
	printf 'FAIL recovery workflow was not correlated by exact release display title\n'
	exit 1
fi
printf 'PASS exact push and recovery workflow runs are correlated durably\n'

_full_loop_resolve_repo() {
	local requested_repo="$1"
	printf '%s\n' "${requested_repo:-test/repo}"
	return 0
}
_full_loop_release_receipt_path() {
	local repo="$1"
	local pr_number="$2"
	printf '%s/%s-%s.status\n' "${TEST_ROOT}/receipts" "${repo//\//_}" "$pr_number"
	return 0
}
_full_loop_release_find_tag_for_pr() {
	local repo="$1"
	local pr_number="$2"
	[[ -n "$repo" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	_FULL_LOOP_RELEASE_FOUND_TAG=v1.2.3
	return 0
}
_full_loop_release_latest_tag() {
	printf 'v1.2.3\n'
	return 0
}
_full_loop_release_inspect_remote() {
	local repo="$1"
	local tag_name="$2"
	[[ -n "$repo" && -n "$tag_name" ]] || return 1
	return "${INSPECT_RC:-3}"
}
_full_loop_release_dispatch_recovery() {
	local repo="$1"
	local tag_name="$2"
	printf '%s %s\n' "$repo" "$tag_name" >"${TEST_ROOT}/dispatch.log"
	return 8
}
_full_loop_release_finalize_reconciliation() {
	local repo="$1"
	local pr_number="$2"
	local tag_name="$3"
	printf '%s %s %s\n' "$repo" "$pr_number" "$tag_name" >"${TEST_ROOT}/finalize.log"
	return 0
}

reconcile_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || reconcile_rc=$?
if [[ "$reconcile_rc" -ne 8 ]] ||
	! grep -qx 'test/repo v1.2.3' "${TEST_ROOT}/dispatch.log"; then
	printf 'FAIL absent publication did not queue idempotent recovery\n'
	exit 1
fi
printf 'PASS absent publication queues idempotent recovery\n'

INSPECT_RC=8
rm -f "${TEST_ROOT}/dispatch.log"
pending_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || pending_rc=$?
if [[ "$pending_rc" -ne 8 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL pending publication was redundantly redispatched\n'
	exit 1
fi
printf 'PASS pending publication is not redundantly redispatched\n'

INSPECT_RC=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if ! grep -qx 'test/repo 90 v1.2.3' "${TEST_ROOT}/finalize.log"; then
	printf 'FAIL completed publication did not finalize durable release state\n'
	exit 1
fi
printf 'PASS completed publication finalizes durable release state\n'

printf 'published\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
rm -f "${TEST_ROOT}/finalize.log"
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 >/dev/null
if [[ -e "${TEST_ROOT}/finalize.log" ]]; then
	printf 'FAIL terminal published receipt was finalized twice\n'
	exit 1
fi
printf 'PASS published reconciliation is idempotent\n'

printf 'not-requested\n' >"${TEST_ROOT}/receipts/test_repo-90.status"
terminal_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || terminal_rc=$?
if [[ "$terminal_rc" -ne 1 ]]; then
	printf 'FAIL terminal not-requested evidence allowed publication recovery\n'
	exit 1
fi
printf 'PASS not-requested evidence remains an irreversible publication block\n'
rm -f "${TEST_ROOT}/receipts/test_repo-90.status"

_full_loop_release_latest_tag() {
	printf 'v1.2.4\n'
	return 0
}
stale_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || stale_rc=$?
if [[ "$stale_rc" -ne 1 ]]; then
	printf 'FAIL stale release tag was allowed to republish over a newer release\n'
	exit 1
fi
printf 'PASS stale release tags cannot downgrade public channels\n'

exit 0
