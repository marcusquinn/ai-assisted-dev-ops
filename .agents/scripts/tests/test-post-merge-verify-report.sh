#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

PASS=0
FAIL=0
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${TEST_DIR}/../post-merge-verify-report-helper.sh"
WORKFLOW="${TEST_DIR}/../../../.github/workflows/post-merge-verify.yml"
PACKAGE_JSON="${TEST_DIR}/../../../package.json"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

pass() {
	local label="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$label"
	return 0
}

fail() {
	local label="$1"
	local detail="$2"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s — %s\n' "$label" "$detail"
	return 0
}

cat >"$TMPDIR/body.md" <<'BODY'
## Post-Merge Brief Verification

Underlying verification result.
BODY

cat >"$TMPDIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALL_LOG"
if [[ "${GH_STUB_FAIL:-0}" == "1" ]]; then
	printf 'Resource not accessible by integration\n' >&2
	exit 1
fi
exit 0
STUB
chmod +x "$TMPDIR/gh"
export PATH="$TMPDIR:$PATH"
export GH_CALL_LOG="$TMPDIR/gh-calls.log"

output=$(bash "$HELPER" publish-comment owner/repo 123 "$TMPDIR/body.md" 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && grep -qF -- '--method POST repos/owner/repo/issues/123/comments' "$GH_CALL_LOG"; then
	pass "PR comments use the REST issues endpoint"
else
	fail "REST comment publication" "rc=$rc output=$output"
fi

export GH_STUB_FAIL=1
export GITHUB_STEP_SUMMARY="$TMPDIR/step-summary.md"
printf 'Underlying verification result\n' >"$GITHUB_STEP_SUMMARY"
output=$(bash "$HELPER" publish-comment owner/repo 123 "$TMPDIR/body.md" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$output" == *"::warning::Unable to publish"* ]] &&
	grep -qF 'Underlying verification result' "$GITHUB_STEP_SUMMARY" &&
	grep -qF 'PR comment publication failed' "$GITHUB_STEP_SUMMARY"; then
	pass "comment permission failure is fail-soft and preserves the check summary"
else
	fail "comment permission fallback" "rc=$rc output=$output summary=$(<"$GITHUB_STEP_SUMMARY")"
fi

printf '%0100d' 0 >"$TMPDIR/large-output.txt"
output=$(bash "$HELPER" truncate-output "$TMPDIR/large-output.txt" 20 2>&1)
rc=$?
truncated_size=$(wc -c <"$TMPDIR/large-output.txt")
if [[ $rc -eq 0 && "$truncated_size" -lt 100 ]] &&
	grep -qF '[output truncated from 100 bytes to 20 bytes]' "$TMPDIR/large-output.txt"; then
	pass "verification output is bounded with an explicit truncation marker"
else
	fail "verification output truncation" "rc=$rc size=$truncated_size output=$output"
fi

if grep -qF 'oven-sh/setup-bun@0c5077e51419868618aeaa5fe8019c62421857d6' "$WORKFLOW" &&
	grep -qF 'bun install --frozen-lockfile --ignore-scripts' "$WORKFLOW" &&
	grep -qF '"ajv": "^8.18.0"' "$PACKAGE_JSON"; then
	pass "post-merge verification installs locked JavaScript dependencies without lifecycle scripts"
else
	fail "post-merge JavaScript dependency bootstrap" "missing direct Ajv dependency, pinned Bun setup, or locked install"
fi

if grep -qF 'sudo apt-get install --yes ripgrep' "$WORKFLOW"; then
	pass "post-merge verification installs ripgrep for repository checks"
else
	fail "post-merge ripgrep bootstrap" "missing ripgrep package installation"
fi

if grep -qF 'QLTY_VERSION: "0.636.0"' "$WORKFLOW" &&
	grep -qF 'qltysh/qlty-action/install@a19242102d17e497f437d7466aa01b528537e899' "$WORKFLOW"; then
	pass "post-merge verification installs the repository-pinned Qlty CLI"
else
	fail "post-merge Qlty bootstrap" "missing pinned Qlty version or install action"
fi

# shellcheck disable=SC2016 # Workflow expressions and shell variables are intentionally literal.
if grep -qF 'fetch-depth: 0' "$WORKFLOW" &&
	grep -qF 'BASE_REF: ${{ github.event.pull_request.base.ref }}' "$WORKFLOW" &&
	grep -qF 'BASE_SHA: ${{ github.event.pull_request.base.sha }}' "$WORKFLOW" &&
	grep -qF 'git update-ref "$REMOTE_BASE_REF" "$BASE_SHA"' "$WORKFLOW"; then
	pass "post-merge verification pins origin base ref to the pre-merge SHA"
else
	fail "post-merge base ref" "missing full-history checkout or pre-merge remote-ref pin"
fi

export MANAGED_ISSUE_CALL_LOG="$TMPDIR/managed-issue-calls.log"
gh_create_issue() {
	printf '%s\n' "$*" >>"$MANAGED_ISSUE_CALL_LOG"
	printf 'https://github.com/owner/repo/issues/456\n'
	return 0
}
export -f gh_create_issue

output=$(bash "$HELPER" create-follow-up owner/repo "t123: verification failed" "$TMPDIR/body.md" 2>&1)
rc=$?
managed_call=$(<"$MANAGED_ISSUE_CALL_LOG")
if [[ $rc -eq 0 && "$managed_call" == *"--body-file $TMPDIR/body.md"* ]] &&
	[[ "$managed_call" == *"--label quality-debt"* ]] &&
	[[ "$managed_call" == *"--label type:bug"* ]] &&
	[[ "$managed_call" == *"--label auto-dispatch"* ]] &&
	[[ "$managed_call" == *"--label origin:worker"* ]] &&
	[[ "$managed_call" == *"--label status:available"* ]]; then
	pass "failure follow-up issues use the managed wrapper with lifecycle metadata"
else
	fail "managed failure follow-up" "rc=$rc output=$output call=$managed_call"
fi

# shellcheck disable=SC2016 # Workflow shell variables are intentionally literal.
if grep -qF 'create-follow-up "$REPO" "$TITLE" "$ISSUE_BODY_FILE"' "$WORKFLOW" &&
	! grep -qE '^[[:space:]]+gh issue create ' "$WORKFLOW"; then
	pass "post-merge workflow contains no raw issue creation path"
else
	fail "managed workflow issue creation" "workflow does not route exclusively through create-follow-up"
fi

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
