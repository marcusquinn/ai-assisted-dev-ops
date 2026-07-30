#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression tests for dispatch prompt comment metrics reuse and zero-output
# evidence pattern consistency.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dlw-comment-metrics-XXXXXX")"
FAKE_BIN="${TEST_TMP}/bin"
GH_CALLS_FILE="${TEST_TMP}/gh-calls"
mkdir -p "$FAKE_BIN" || exit 1

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
}

cat >"${FAKE_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"${GH_CALLS_FILE:?}"
case "$*" in
*'issues/123/comments'*'@tsv'*)
	printf '3\t0\t1\t120\n'
	;;
*'issues/123/comments'*)
	printf '1\n'
	;;
*)
	printf 'unexpected gh call: %s\n' "$*" >&2
	exit 1
	;;
esac
EOF
chmod +x "${FAKE_BIN}/gh" || fail "failed to make fake gh executable"

OBJECTIVE_HELPER="${FAKE_BIN}/objective-reconciliation-helper.sh"
cat >"$OBJECTIVE_HELPER" <<'EOF'
#!/usr/bin/env bash
if [[ "${RETRY_DISPOSITION:-failed}" == "success" ]]; then
	printf '%s\n' '{"source":"attempt_outcome","attempt_id":"attempt-success","effective_outcome":"success","raw_result":"post_pr_handoff","status":"recovered","classification":"worker_complete","next_action":"monitor_pr"}'
elif [[ "${RETRY_DISPOSITION:-failed}" == "sparse" ]]; then
	printf '%s\n' '{"source":"attempt_outcome","attempt_id":"attempt-sparse","effective_outcome":"failed","raw_result":"","status":"","classification":"","next_action":"narrow_redispatch"}'
else
	printf '%s\n' '{"source":"attempt_outcome","attempt_id":"attempt-prior","effective_outcome":"failed","raw_result":"premature_exit","status":"failed","classification":"unsafe prior model prose","next_action":"narrow_redispatch"}'
fi
EOF
chmod +x "$OBJECTIVE_HELPER" || fail "failed to make objective helper executable"

PATH="${FAKE_BIN}:${PATH}"
export GH_CALLS_FILE

LOGFILE="${TEST_TMP}/pulse.log" \
	CLEAN_ROOM_COMMENT_THRESHOLD=100 \
	CLEAN_ROOM_OPS_COMMENT_THRESHOLD=50 \
	CLEAN_ROOM_ZERO_OUTPUT_COMMENT_THRESHOLD=10 \
	CLEAN_ROOM_COMMENT_CHARS_THRESHOLD=50000 \
	ZERO_OUTPUT_URL_FALLBACK_THRESHOLD=1 \
	FAST_FAIL_STATE_FILE="" \
	ISSUE_BODY_SNAPSHOT_HELPER="/usr/bin/true" \
	_dlw_prepare_prompt_for_launch "123" "owner/repo" "Metric test" "original prompt" >"${TEST_TMP}/prompt"

if [[ "$(<"${TEST_TMP}/prompt")" != *"Previous dispatch attempts"* ]]; then
	fail "prepare prompt did not use precomputed zero-output evidence"
fi

gh_calls="$(wc -l <"$GH_CALLS_FILE" | tr -d '[:space:]')"
if [[ "$gh_calls" != "1" ]]; then
	fail "prepare prompt made ${gh_calls} GitHub calls instead of reusing one metrics fetch"
fi

if [[ "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"worker_noop_zero_output"* || "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"zero[- ]output"* ]]; then
	fail "shared zero-output evidence pattern lost expected alternatives"
fi

LOGFILE="${TEST_TMP}/pulse.log" \
	ISSUE_BODY_SNAPSHOT_HELPER="/usr/bin/false" \
	CLEAN_ROOM_COMMENT_THRESHOLD=1 \
	_dlw_prepare_prompt_for_launch "123" "owner/repo" "Metric test" "original composed prompt" $'1\t0\t0\t1' >"${TEST_TMP}/blocked-prompt"
if [[ "$(<"${TEST_TMP}/blocked-prompt")" != *"Do not implement from this prompt"* ]]; then
	fail "invalid clean-room snapshot did not produce a non-authorizing blocker"
fi
if [[ "$(<"${TEST_TMP}/blocked-prompt")" == *"original composed prompt"* ]]; then
	fail "clean-room blocker leaked the original composed prompt"
fi

retry_context=$(OBJECTIVE_RECONCILIATION_HELPER="$OBJECTIVE_HELPER" \
	AIDEVOPS_RETRY_CONTEXT_MAX_CHARS=512 _dlw_prior_attempt_context 123 owner/repo)
if [[ "$retry_context" != *"Validated prior-attempt state"* || "$retry_context" != *"attempt-prior"* ]]; then
	fail "failed prior attempt did not produce deterministic retry context"
fi
if [[ "$retry_context" == *"unsafe prior model prose"* || "$retry_context" != *"classification: unknown"* ]]; then
	fail "retry context admitted non-machine prior prose"
fi
if [[ "${#retry_context}" -gt 512 ]]; then
	fail "retry context exceeded configured bound: ${#retry_context}"
fi
success_context=$(OBJECTIVE_RECONCILIATION_HELPER="$OBJECTIVE_HELPER" RETRY_DISPOSITION=success \
	_dlw_prior_attempt_context 123 owner/repo)
if [[ -n "$success_context" ]]; then
	fail "successful prior outcome produced unnecessary retry context"
fi
sparse_context=$(OBJECTIVE_RECONCILIATION_HELPER="$OBJECTIVE_HELPER" RETRY_DISPOSITION=sparse \
	_dlw_prior_attempt_context 123 owner/repo)
if [[ "$sparse_context" != *"attempt_id: attempt-sparse"* || \
	"$sparse_context" != *"raw_result: unknown"* || \
	"$sparse_context" != *"status: unknown"* || \
	"$sparse_context" != *"next_action: narrow_redispatch"* ]]; then
	fail "sparse retry disposition shifted empty machine fields: ${sparse_context}"
fi

LEDGER_CALLS_FILE="${TEST_TMP}/ledger-calls"
export LEDGER_CALLS_FILE
cat >"${TEST_TMP}/dispatch-ledger-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LEDGER_CALLS_FILE:?}"
exit "${TEST_LEDGER_RC:-0}"
EOF
chmod +x "${TEST_TMP}/dispatch-ledger-helper.sh" || fail "failed to make dispatch ledger stub executable"

STATUS_MUTATIONS=""
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status_name="$3"
	shift 3
	STATUS_MUTATIONS="${issue_number}|${repo_slug}|${status_name}|$*"
	return 0
}

transition_owned_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local owner_login="$3"
	local source_status="$4"
	local target_status="$5"
	STATUS_MUTATIONS="${issue_number}|${repo_slug}|${owner_login}|${source_status}|${target_status}"
	return 0
}

original_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$TEST_TMP"
_claim_comment_id="77"
_claim_lease_token="lease-123"
_claim_lease_device="device-a"
PULSE_DISPATCH_STAGGER_SECONDS=0
export TEST_LEDGER_RC=0
LOGFILE="${TEST_TMP}/pulse.log" _dlw_post_launch_hooks \
	"123" "owner/repo" "runner-a" "$$" "issue-123" "standard" "test-model" "${TEST_TMP}/worktree" "attempt-123"
if [[ "$STATUS_MUTATIONS" != "123|owner/repo|runner-a|queued|in-progress" ]]; then
	fail "successful worker registration did not transition queued issue to in-progress: ${STATUS_MUTATIONS:-none}"
fi
if ! grep -Fq 'aidevops:dispatch lease_token=lease-123 device=device-a session=issue-123 attempt_id=attempt-123 claim_id=77' "$GH_CALLS_FILE"; then
	fail "dispatch comment did not publish its exact lease and attempt identity"
fi

STATUS_MUTATIONS=""
export TEST_LEDGER_RC=1
LOGFILE="${TEST_TMP}/pulse.log" _dlw_post_launch_hooks \
	"123" "owner/repo" "runner-a" "$$" "issue-123-failed" "standard" "test-model" "${TEST_TMP}/worktree" "attempt-124"
if [[ -n "$STATUS_MUTATIONS" ]]; then
	fail "failed worker registration transitioned issue lifecycle: ${STATUS_MUTATIONS}"
fi

STATUS_MUTATIONS=""
if LOGFILE="${TEST_TMP}/pulse.log" _dlw_mark_worker_in_progress \
	"123" "owner/repo" "runner-a" "2147483647"; then
	fail "dead worker PID transitioned issue lifecycle"
fi
if [[ -n "$STATUS_MUTATIONS" ]]; then
	fail "dead worker PID emitted status mutation: ${STATUS_MUTATIONS}"
fi
SCRIPT_DIR="$original_script_dir"

printf 'PASS: dispatch prompt reuses comment metrics for zero-output fallback\n'
printf 'PASS: zero-output evidence detection uses one shared pattern\n'
printf 'PASS: invalid clean-room snapshots cannot authorize implementation\n'
printf 'PASS: retry context is bounded, deterministic, and excludes prior prose\n'
printf 'PASS: registered live workers transition queued issues to in-progress\n'
printf 'PASS: failed registrations and dead workers preserve queued lifecycle state\n'
exit 0
