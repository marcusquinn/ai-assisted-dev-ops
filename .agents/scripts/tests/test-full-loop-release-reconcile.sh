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
	printf '%s\n' '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]"}]}'
	exit 0
	;;
no-runs)
	printf '%s\n' '{"workflow_runs":[]}'
	exit 0
	;;
esac
if [[ "$args" == *" workflow run publish-packages.yml "* ]]; then
	printf '%s\n' "$args" >"${FAKE_DISPATCH_LOG:?}"
	exit 0
fi
if [[ "$args" == *" -f event=push "* ]]; then
	printf '%s\n' '{"workflow_runs":[{"id":10,"event":"push","head_sha":"3333333333333333333333333333333333333333","status":"completed","conclusion":"success","created_at":"2026-07-27T00:00:00Z","display_title":"push","html_url":"push-url"}]}'
	exit 0
fi
if [[ "$args" == *" -f event=workflow_dispatch "* ]]; then
	correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.4444444444444444444444444444444444444444]'
	if [[ "${FAKE_RECOVERY_CORRELATION_MODE:-valid}" == "mismatch" ]]; then
		correlated_title='Publish v1.2.3 [3333333333333333333333333333333333333333.5555555555555555555555555555555555555555]'
	fi
	printf '{"workflow_runs":[{"id":11,"event":"workflow_dispatch","head_branch":"main","head_sha":"4444444444444444444444444444444444444444","status":"queued","conclusion":null,"created_at":"2026-07-27T00:01:00Z","display_title":"%s","html_url":"recovery-url"}]}\n' \
		"$correlated_title"
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
	if [[ "${FAKE_FORMULA_DRIFT:-0}" == "1" ]]; then
		printf '# unexpected drift\n'
	fi
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" rev-parse refs/tags/v1.2.3^{commit} "* ]]; then
	printf '%s\n' '3333333333333333333333333333333333333333'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/npm" <<'STUB'
#!/usr/bin/env bash
args=" $* "
if [[ "$args" == *" view aidevops@1.2.3 version dist --json "* ]]; then
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg integrity "${FAKE_NPM_INTEGRITY:?}" \
		--arg predicate "${FAKE_NPM_PREDICATE:-https://slsa.dev/provenance/v1}" '
		{version:$version,dist:{integrity:$integrity,shasum:"1111111111111111111111111111111111111111",
		attestations:{url:"registry-attestation",provenance:{predicateType:$predicate}}}}
	'
	exit 0
fi
if [[ "$args" == *" install "* ]]; then
	exit 0
fi
if [[ "$args" == *" audit signatures "* ]]; then
	invalid='[]'
	[[ "${FAKE_NPM_AUDIT_INVALID:-0}" == "1" ]] && invalid='[{"code":"invalid"}]'
	jq -cn --arg version "${FAKE_NPM_VERSION:-1.2.3}" \
		--arg payload "${FAKE_PROVENANCE_PAYLOAD_B64:?}" --argjson invalid "$invalid" '
		{invalid:$invalid,missing:[],verified:[{name:"aidevops",version:$version,
		attestations:{provenance:{predicateType:"https://slsa.dev/provenance/v1"}},
		attestationBundles:[{predicateType:"https://slsa.dev/provenance/v1",
		bundle:{dsseEnvelope:{payload:$payload}}}]}]}
	'
	exit 0
fi
exit 1
STUB
cat >"${TEST_ROOT}/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'tarball-fixture'
STUB
chmod +x "${TEST_ROOT}/bin/gh"
chmod +x "${TEST_ROOT}/bin/git" "${TEST_ROOT}/bin/npm" "${TEST_ROOT}/bin/curl"
PATH="${TEST_ROOT}/bin:${PATH}"
export FAKE_RUN_SCHEMA_MODE=valid
export FAKE_RECOVERY_CORRELATION_MODE=valid
export FAKE_RELEASE_DRAFT=0
export FAKE_NPM_VERSION=1.2.3
FAKE_NPM_DIGEST=$(printf '%0128d' 0)
FAKE_NPM_INTEGRITY=$(node -e \
	'process.stdout.write("sha512-" + Buffer.from(process.argv[1], "hex").toString("base64"))' \
	"$FAKE_NPM_DIGEST")
export FAKE_NPM_DIGEST FAKE_NPM_INTEGRITY
FAKE_FORMULA_SHA=$(printf 'tarball-fixture' | _full_loop_release_sha256_stream)
export FAKE_FORMULA_SHA

set_fake_provenance_payload() {
	local repository="$1"
	local workflow_ref="$2"
	local subject_digest="${3:-$FAKE_NPM_DIGEST}"
	local payload=""

	payload=$(jq -cn --arg repository "$repository" --arg ref "$workflow_ref" \
		--arg digest "$subject_digest" '
		{"_type":"https://in-toto.io/Statement/v1","predicateType":"https://slsa.dev/provenance/v1",
		"subject":[{"name":"pkg:npm/aidevops@1.2.3","digest":{"sha512":$digest}}],
		"predicate":{"buildDefinition":{
		"buildType":"https://slsa-framework.github.io/github-actions-buildtypes/workflow/v1",
		"externalParameters":{"workflow":{"repository":$repository,
		"path":".github/workflows/publish-packages.yml","ref":$ref}}},
		"runDetails":{"builder":{"id":"https://github.com/actions/runner/github-hosted"}}}}
	') || return 1
	FAKE_PROVENANCE_PAYLOAD_B64=$(node -e \
		'process.stdout.write(Buffer.from(process.argv[1]).toString("base64"))' "$payload") || return 1
	export FAKE_PROVENANCE_PAYLOAD_B64
	return 0
}

_full_loop_release_expected_homebrew_formula() {
	local repo="$1"
	local tag_name="$2"
	local expected_sha="$3"
	printf 'class Aidevops\n  url "https://github.com/%s/archive/refs/tags/%s.tar.gz"\n  sha256 "%s"\nend\n' \
		"$repo" "$tag_name" "$expected_sha"
	return 0
}

set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "11" ]]; then
	printf 'FAIL recovery workflow was not correlated by exact release display title\n'
	exit 1
fi
printf 'PASS exact push and recovery workflow runs are correlated durably\n'

export FAKE_RECOVERY_CORRELATION_MODE=mismatch
_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333
if [[ "$(jq -r '.id' <<<"$_FULL_LOOP_RELEASE_RUN_JSON")" != "10" ]]; then
	printf 'FAIL recovery workflow with mismatched commit correlation was accepted\n'
	exit 1
fi
export FAKE_RECOVERY_CORRELATION_MODE=valid
printf 'PASS recovery workflow correlation binds tag and workflow commits\n'

saved_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="${TEST_ROOT}/no-audit-helper"
FAKE_DISPATCH_LOG="${TEST_ROOT}/dispatch-command.log"
export FAKE_DISPATCH_LOG
dispatch_rc=0
_full_loop_release_dispatch_recovery test/repo v1.2.3 >/dev/null || dispatch_rc=$?
SCRIPT_DIR="$saved_script_dir"
if [[ "$dispatch_rc" -ne 8 ]] ||
	! grep -qF ' -f tag=v1.2.3 -f correlation=3333333333333333333333333333333333333333 ' \
		"$FAKE_DISPATCH_LOG"; then
	printf 'FAIL recovery dispatch did not carry the exact verified tag commit\n'
	exit 1
fi
printf 'PASS recovery dispatch carries the exact tag while run identity records the workflow commit\n'

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

_full_loop_release_find_workflow_run test/repo v1.2.3 3333333333333333333333333333333333333333

_full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3 || {
	printf 'FAIL valid npm provenance did not verify\n'
	exit 1
}
if [[ "$_FULL_LOOP_RELEASE_NPM_INTEGRITY" != "$FAKE_NPM_INTEGRITY" ]]; then
	printf 'FAIL npm provenance verification omitted exact package integrity\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/attacker/repo" "refs/heads/main"
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL foreign npm provenance repository was accepted\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
FAKE_NPM_AUDIT_INVALID=1
export FAKE_NPM_AUDIT_INVALID
if _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL invalid npm provenance signature was accepted\n'
	exit 1
fi
FAKE_NPM_AUDIT_INVALID=0
export FAKE_NPM_AUDIT_INVALID
set_fake_provenance_payload "https://github.com/test/repo" "refs/tags/v1.2.3"
if ! _full_loop_release_verify_npm_provenance test/repo v1.2.3 1.2.3; then
	printf 'FAIL recovery rejected an exact package published by the original tag run\n'
	exit 1
fi
set_fake_provenance_payload "https://github.com/test/repo" "refs/heads/main"
printf 'PASS npm package integrity and signed workflow provenance are bound exactly\n'
printf 'PASS recovery accepts immutable npm provenance from tag or main publication\n'

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
FAKE_FORMULA_DRIFT=1
export FAKE_FORMULA_DRIFT
if _full_loop_release_verify_channels test/repo v1.2.3 >/dev/null 2>&1; then
	printf 'FAIL drifted Homebrew formula satisfied exact channel convergence\n'
	exit 1
fi
FAKE_FORMULA_DRIFT=0
export FAKE_FORMULA_DRIFT
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
