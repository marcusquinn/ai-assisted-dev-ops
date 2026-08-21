#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression coverage for GH#23916/GH#28705: _run_triage_review_worker must
# validate launch paths and must not inherit implementation-worker authority.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/triage-review-worker-contract-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

write_headless_helper() {
	cat >"${TEST_TMP}/headless-runtime-helper.sh" <<'EOS'
#!/usr/bin/env bash
printf 'HEADLESS=%s WORKER_ISSUE_NUMBER=%s WORKER_REPO_SLUG=%s WORKER_WORKTREE_PATH=%s LEASE_TOKEN=%s WORKER_ID=%s OWNER_PID=%s %s\n' \
	"${HEADLESS:-<unset>}" "${WORKER_ISSUE_NUMBER:-<unset>}" "${WORKER_REPO_SLUG:-<unset>}" "${WORKER_WORKTREE_PATH:-<unset>}" \
	"${AIDEVOPS_DISPATCH_LEASE_TOKEN:-<unset>}" "${AIDEVOPS_WORKER_ID:-<unset>}" "${AIDEVOPS_WORKTREE_OWNER_PID:-<unset>}" "$*"
exit "${TRIAGE_CONTRACT_RUNTIME_EXIT:-0}"
EOS
	chmod +x "${TEST_TMP}/headless-runtime-helper.sh" || fail "failed to chmod headless helper"
	return 0
}

write_headless_helper
mkdir -p "${TEST_TMP}/home/.aidevops/logs" "${TEST_TMP}/repo" || fail "failed to create test directories"
HOME="${TEST_TMP}/home"
LOGFILE="${TEST_TMP}/pulse.log"
HEADLESS_RUNTIME_HELPER="${TEST_TMP}/headless-runtime-helper.sh"

# shellcheck source=../pulse-ancillary-dispatch.sh
source "${SCRIPTS_DIR}/pulse-ancillary-dispatch.sh"

prefetch_file="${TEST_TMP}/prefetch.md"
printf '%s\n' 'prefetched issue context' >"$prefetch_file"

missing_output_stderr="${TEST_TMP}/missing-output.stderr"
missing_output_status=0
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "$prefetch_file" "" 2>"$missing_output_stderr" || \
	missing_output_status=$?
[[ "$missing_output_status" -ne 0 ]] || fail "missing output file path did not fail closed"
if ! grep -q 'triage worker output file missing' "$missing_output_stderr"; then
	fail "missing output file path did not produce an auditable stderr error"
fi

missing_prefetch_output="${TEST_TMP}/missing-prefetch.out"
missing_prefetch_status=0
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "" "$missing_prefetch_output" || \
	missing_prefetch_status=$?
[[ "$missing_prefetch_status" -ne 0 ]] || fail "missing prefetch file did not fail closed"
if ! grep -q 'triage worker env contract missing' "$missing_prefetch_output"; then
	fail "missing prefetch file did not write the env contract failure"
fi
if grep -q 'WORKER_ISSUE_NUMBER' "$missing_prefetch_output"; then
	fail "missing prefetch file launched the headless runtime"
fi

valid_output="${TEST_TMP}/valid.out"
export WORKER_ISSUE_NUMBER="999"
export WORKER_REPO_SLUG="wrong/repo"
export WORKER_WORKTREE_PATH="${TEST_TMP}/wrong-worktree"
export WORKER_GITHUB_LOGIN="wrong-runner"
export AIDEVOPS_DISPATCH_LEASE_TOKEN="stale-lease"
export AIDEVOPS_WORKER_ID="stale-worker-id"
export AIDEVOPS_WORKTREE_OWNER_PID="999"
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" "$prefetch_file" "$valid_output" "thinking" || \
	fail "valid worker launch should not fail the caller"
unset WORKER_ISSUE_NUMBER WORKER_REPO_SLUG WORKER_WORKTREE_PATH WORKER_GITHUB_LOGIN \
	AIDEVOPS_DISPATCH_LEASE_TOKEN AIDEVOPS_WORKER_ID AIDEVOPS_WORKTREE_OWNER_PID
if ! grep -q 'HEADLESS=1' "$valid_output"; then
	fail "valid worker launch did not export headless diagnostic mode"
fi
if ! grep -q 'WORKER_ISSUE_NUMBER=<unset> WORKER_REPO_SLUG=<unset> WORKER_WORKTREE_PATH=<unset>' "$valid_output"; then
	fail "triage launch retained implementation-worker authority"
fi
if ! grep -q 'LEASE_TOKEN=<unset> WORKER_ID=<unset> OWNER_PID=<unset>' "$valid_output"; then
	fail "triage launch retained worker lease or worktree-owner authority"
fi
if ! grep -q -- '--role triage' "$valid_output"; then
	fail "valid triage launch did not invoke the headless runtime"
fi
if ! grep -q -- '--session-key triage-review-42' "$valid_output"; then
	fail "triage launch lost issue correlation in the session key"
fi
if ! grep -q -- '--tier thinking' "$valid_output"; then
	fail "triage launch lost canonical thinking-tier attribution"
fi
if ! grep -q -- '--prompt-file' "$valid_output"; then
	fail "valid worker launch did not pass the prompt file flag"
fi

runtime_failure_output="${TEST_TMP}/runtime-failure.out"
export TRIAGE_CONTRACT_RUNTIME_EXIT=86
runtime_failure_status=0
_run_triage_review_worker "42" "owner/repo" "${TEST_TMP}/repo" "" \
	"$prefetch_file" "$runtime_failure_output" || runtime_failure_status=$?
unset TRIAGE_CONTRACT_RUNTIME_EXIT
[[ "$runtime_failure_status" -eq 86 ]] || \
	fail "triage worker discarded runtime status: ${runtime_failure_status}"

TRIAGE_AGENT_FILE="${SCRIPTS_DIR}/../workflows/triage-review.md"
grep -q '^  "\*": false$' "$TRIAGE_AGENT_FILE" || \
	fail "triage-review agent does not deny every built-in and plugin tool"
grep -q '^mode: primary$' "$TRIAGE_AGENT_FILE" || \
	fail "triage-review agent is not selectable as the isolated primary agent"
grep -q '^  "\*": deny$' "$TRIAGE_AGENT_FILE" || \
	fail "triage-review agent does not deny every permission request"

printf '%s\n' 'PASS triage review worker validates paths, tools, and worker authority'
