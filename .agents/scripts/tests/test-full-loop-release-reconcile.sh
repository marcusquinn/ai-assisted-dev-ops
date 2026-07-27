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
case "${FAKE_RUN_SCHEMA_MODE:-valid}" in
api-failure) exit 1 ;;
empty) exit 0 ;;
object)
	printf '%s\n' '{}'
	exit 0
	;;
malformed)
	printf '%s\n' '{'
	exit 0
	;;
malformed-run)
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3"}]}'
	exit 0
	;;
no-runs)
	printf '%s\n' '{"workflow_runs":[]}'
	exit 0
	;;
esac
if [[ "$args" == *" -f event=push "* ]]; then
	printf '%s\n' '{"workflow_runs":[{"id":10,"event":"push","head_sha":"3333333333333333333333333333333333333333","status":"completed","conclusion":"success","created_at":"2026-07-27T00:00:00Z","display_title":"push","html_url":"push-url"}]}'
	exit 0
fi
if [[ "$args" == *" -f event=workflow_dispatch "* ]]; then
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","status":"queued","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3","html_url":"recovery-url"}]}'
	exit 0
fi
if [[ "$args" == *"releases/tags/v1.2.3"* ]]; then
	if [[ "${FAKE_RELEASE_DRAFT:-0}" == "1" ]]; then
		printf '%s\n' '{"tag_name":"v1.2.3","draft":true,"published_at":null}'
	else
		printf '%s\n' '{"tag_name":"v1.2.3","draft":false,"published_at":"2026-07-27T00:00:00Z"}'
	fi
	exit 0
fi
if [[ "$args" == *"homebrew-tap/contents/Formula/aidevops.rb"* ]]; then
	printf 'class Aidevops\n  url "https://github.com/test/repo/archive/refs/tags/v1.2.3.tar.gz"\n  sha256 "%s"\nend\n' \
		"${FAKE_FORMULA_SHA:?}"
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/npm" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" view aidevops@1.2.3 version --json "* ]]; then
	printf '"%s"\n' "${FAKE_NPM_VERSION:-1.2.3}"
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'tarball-fixture'
STUB
chmod +x "${TEST_ROOT}/bin/gh"
chmod +x "${TEST_ROOT}/bin/npm" "${TEST_ROOT}/bin/curl"
PATH="${TEST_ROOT}/bin:${PATH}"
export FAKE_RUN_SCHEMA_MODE=valid
export FAKE_RELEASE_DRAFT=0
export FAKE_NPM_VERSION=1.2.3
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "11" ]]; then
	printf 'FAIL recovery workflow was not correlated by exact release display title\n'
	exit 1
fi
printf 'PASS exact push and recovery workflow runs are correlated durably\n'

for schema_mode in empty object malformed malformed-run api-failure; do
	export FAKE_RUN_SCHEMA_MODE="$schema_mode"
	schema_rc=0
	_full_loop_release_find_workflow_run test/repo v1.2.3 \
		3333333333333333333333333333333333333333 >/dev/null 2>&1 || schema_rc=$?
	if [[ "$schema_rc" -ne 1 ]]; then
		printf 'FAIL %s workflow-run response did not fail closed\n' "$schema_mode"
		exit 1
	fi
done
export FAKE_RUN_SCHEMA_MODE=no-runs
absent_rc=0
_full_loop_release_find_workflow_run test/repo v1.2.3 \
	3333333333333333333333333333333333333333 >/dev/null 2>&1 || absent_rc=$?
if [[ "$absent_rc" -ne 3 ]]; then
	printf 'FAIL valid empty workflow-run arrays were not classified as absent\n'
	exit 1
fi
export FAKE_RUN_SCHEMA_MODE=valid
printf 'PASS workflow-run API and schema uncertainty fail closed\n'

channel_output=$(_full_loop_release_verify_channels test/repo v1.2.3) || {
	printf 'FAIL exact published channels did not converge\n'
	exit 1
}
if [[ "$channel_output" != *"HOMEBREW_SHA256=${FAKE_FORMULA_SHA}"* ]]; then
	printf 'FAIL channel verification omitted the exact Homebrew digest\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=1
export FAKE_RELEASE_DRAFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL draft GitHub release satisfied channel convergence\n'
	exit 1
fi
FAKE_RELEASE_DRAFT=0
FAKE_FORMULA_SHA=0000000000000000000000000000000000000000000000000000000000000000
export FAKE_RELEASE_DRAFT FAKE_FORMULA_SHA
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL mismatched Homebrew digest satisfied channel convergence\n'
	exit 1
fi
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA
printf 'PASS published channel verification binds release, package, formula, and digest\n'

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

INSPECT_RC=1
rm -f "${TEST_ROOT}/dispatch.log"
uncertain_rc=0
AIDEVOPS_FULL_LOOP_REPO=test/repo _full_loop_release_existing_command reconcile 90 \
	>/dev/null 2>&1 || uncertain_rc=$?
if [[ "$uncertain_rc" -ne 1 || -e "${TEST_ROOT}/dispatch.log" ]]; then
	printf 'FAIL remote-state uncertainty allowed a recovery dispatch\n'
	exit 1
fi
printf 'PASS remote-state uncertainty blocks recovery dispatch\n'

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
