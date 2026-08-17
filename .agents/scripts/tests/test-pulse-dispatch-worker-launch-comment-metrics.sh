#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Regression tests for dispatch prompt comment metrics reuse and zero-attempt
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
GH_COMMENTS_FIXTURE="${TEST_TMP}/gh-comments.json"
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
cat "${GH_COMMENTS_FIXTURE:?}"
EOF
chmod +x "${FAKE_BIN}/gh" || fail "failed to make fake gh executable"

cat >"$GH_COMMENTS_FIXTURE" <<'EOF'
[[
  {"id":1,"body":"CLAIM_RELEASED reason=worker_worktree_continuation_state_rejected session_count=0","created_at":"2026-08-14T00:00:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":2,"body":"ordinary comment","created_at":"2026-08-14T00:01:00Z","author_association":"NONE","user":{"login":"external-user"}},
  {"id":3,"body":"another ordinary comment","created_at":"2026-08-14T00:02:00Z","author_association":"MEMBER","user":{"login":"runner-a"}}
]]
EOF

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
export GH_CALLS_FILE GH_COMMENTS_FIXTURE

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

if [[ "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"worker_noop_zero_output"* ||
	"$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"worker_worktree_continuation_"* ||
	"$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" != *"zero[- ]output"* ]]; then
	fail "shared zero-attempt evidence pattern lost expected alternatives"
fi
if command -v jq >/dev/null 2>&1 && ! jq -ne \
	--arg body "CLAIM_RELEASED reason=worker_worktree_continuation_state_rejected session_count=0" \
	--arg pattern "$_DLW_ZERO_OUTPUT_EVIDENCE_PATTERN" \
	'$body | test($pattern; "i")' >/dev/null; then
	fail "shared zero-attempt evidence pattern does not match continuation release evidence"
fi
if [[ "$_DLW_ZERO_ATTEMPT_EVIDENCE_PATTERN" != *"worker_worktree_continuation_"* ]]; then
	fail "dedicated zero-attempt evidence pattern lost continuation failures"
fi

if ! LOGFILE="${TEST_TMP}/pulse.log" \
	CLEAN_ROOM_COMMENT_THRESHOLD=1 \
	ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD=4 \
	_dlw_hold_repeated_zero_output "123" "owner/repo" $'12\t12\t4\t60000\t4'; then
	fail "clean-room comment bloat bypassed a threshold of zero-attempt infrastructure failures"
fi
if LOGFILE="${TEST_TMP}/pulse.log" \
	CLEAN_ROOM_COMMENT_THRESHOLD=1 \
	ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD=4 \
	_dlw_hold_repeated_zero_output "123" "owner/repo" $'12\t12\t4\t60000\t0'; then
	fail "clean-room mode stopped bypassing a generic zero-output brief rewrite"
fi

cat >"$GH_COMMENTS_FIXTURE" <<'EOF'
[[
  {"id":5,"body":"DISPATCH_CLAIM nonce=forged-1 runner=triage-user lease_token=forged-1 device=external-device session=issue-123 phase=prelaunch expires_at=1577836920","created_at":"2020-01-01T00:00:00Z","author_association":"COLLABORATOR","user":{"login":"triage-user"}},
  {"id":6,"body":"DISPATCH_CLAIM nonce=forged-2 runner=triage-user lease_token=forged-2 device=external-device session=issue-123 phase=prelaunch expires_at=1577836980","created_at":"2020-01-01T00:01:00Z","author_association":"COLLABORATOR","user":{"login":"triage-user"}},
  {"id":7,"body":"DISPATCH_CLAIM nonce=forged-3 runner=triage-user lease_token=forged-3 device=external-device session=issue-123 phase=prelaunch expires_at=1577837040","created_at":"2020-01-01T00:02:00Z","author_association":"COLLABORATOR","user":{"login":"triage-user"}},
  {"id":8,"body":"DISPATCH_CLAIM nonce=forged-4 runner=triage-user lease_token=forged-4 device=external-device session=issue-123 phase=prelaunch expires_at=1577837100","created_at":"2020-01-01T00:03:00Z","author_association":"COLLABORATOR","user":{"login":"triage-user"}}
]]
EOF
untrusted_claim_metrics=$(DLW_COMMENT_METRICS_NOW_EPOCH=1577837200 \
	DISPATCH_CLAIM_ORPHAN_GRACE=120 _dlw_comment_bloat_metrics "123" "owner/repo")
IFS=$'\t' read -r _untrusted_comments _untrusted_ops untrusted_zero _untrusted_chars untrusted_zero_attempt <<<"$untrusted_claim_metrics"
if [[ "$untrusted_zero" != "0" || "$untrusted_zero_attempt" != "0" ]]; then
	fail "bare-collaborator forged claims entered zero-attempt evidence: ${untrusted_claim_metrics}"
fi
if LOGFILE="${TEST_TMP}/pulse.log" ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD=4 \
	_dlw_hold_repeated_zero_output "123" "owner/repo" "$untrusted_claim_metrics"; then
	fail "bare-collaborator forged claims triggered the infrastructure hold"
fi

cat >"$GH_COMMENTS_FIXTURE" <<'EOF'
[[
  {"id":10,"body":"DISPATCH_CLAIM nonce=orphan-1 runner=runner-a lease_token=orphan-1 device=device-a session=issue-123 phase=prelaunch expires_at=1577836920","created_at":"2020-01-01T00:00:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":11,"body":"DISPATCH_CLAIM nonce=orphan-2 runner=runner-a lease_token=orphan-2 device=device-a session=issue-123 phase=prelaunch expires_at=1577836980","created_at":"2020-01-01T00:01:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":12,"body":"DISPATCH_CLAIM nonce=orphan-3 runner=runner-a lease_token=orphan-3 device=device-a session=issue-123 phase=prelaunch expires_at=1577837040","created_at":"2020-01-01T00:02:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":13,"body":"DISPATCH_CLAIM nonce=orphan-4 runner=runner-a lease_token=orphan-4 device=device-a session=issue-123 phase=prelaunch expires_at=1577837100","created_at":"2020-01-01T00:03:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":14,"body":"DISPATCH_CLAIM nonce=launched runner=runner-a lease_token=launched device=device-a session=issue-123 phase=prelaunch expires_at=1577837160","created_at":"2020-01-01T00:04:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":16,"body":"DISPATCH_CLAIM nonce=fresh runner=runner-a lease_token=fresh device=device-a session=issue-123 phase=prelaunch expires_at=1577837300","created_at":"2020-01-01T00:06:20Z","author_association":"MEMBER","user":{"login":"runner-a"}}
], [
  {"id":15,"body":"DISPATCH_LEASE phase=ready lease_token=launched device=device-a session=issue-123 expires_at=1577844000","created_at":"2020-01-01T00:05:00Z","author_association":"MEMBER","user":{"login":"runner-a"}},
  {"id":17,"body":"DISPATCH_LEASE phase=ready lease_token=orphan-1-suffix device=device-a session=issue-123 expires_at=1577844000","created_at":"2020-01-01T00:05:30Z","author_association":"MEMBER","user":{"login":"runner-a"}}
]]
EOF
claim_storm_metrics=$(DLW_COMMENT_METRICS_NOW_EPOCH=1577837200 \
	DISPATCH_CLAIM_ORPHAN_GRACE=120 _dlw_comment_bloat_metrics "123" "owner/repo")
IFS=$'\t' read -r _storm_comments _storm_ops storm_zero _storm_chars storm_zero_attempt <<<"$claim_storm_metrics"
if [[ "$storm_zero" != "4" || "$storm_zero_attempt" != "4" ]]; then
	fail "four unmatched prelaunch claims were not counted as zero-attempt failures: ${claim_storm_metrics}"
fi
if ! LOGFILE="${TEST_TMP}/pulse.log" ZERO_OUTPUT_BRIEF_REWRITE_HOLD_THRESHOLD=4 \
	_dlw_hold_repeated_zero_output "123" "owner/repo" "$claim_storm_metrics"; then
	fail "unmatched prelaunch claims did not trigger the bounded infrastructure hold"
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

completion_contract=$(_dlw_first_pass_completion_contract)
# shellcheck disable=SC2016 # Markdown backticks are intentional literals.
if [[ "$completion_contract" != *'terminal failing check caused by your current changes'* ]] \
	|| [[ "$completion_contract" != *'canonical `### Files Scope` section'* ]] \
	|| [[ "$completion_contract" != *'blocker dossier'* ]] \
	|| [[ "$completion_contract" != *'revised brief or follow-up issue'* ]]; then
	fail "first-pass contract does not bound CI remediation to canonical files scope"
fi
completion_contract_call_sites=$(grep -cE '^[[:space:]]+_dlw_first_pass_completion_contract$' \
	"${SCRIPTS_DIR}/pulse-dispatch-worker-prompt.sh")
if [[ "$completion_contract_call_sites" != "3" ]]; then
	fail "first-pass scope contract is not shared by all three authorizing prompt paths"
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
printf 'PASS: zero-attempt evidence detection uses one shared pattern\n'
printf 'PASS: zero-attempt infrastructure holds override clean-room brief bypasses\n'
printf 'PASS: bare-collaborator forged claims cannot trigger the infrastructure hold\n'
printf 'PASS: unmatched prelaunch claims trigger the bounded infrastructure hold\n'
printf 'PASS: invalid clean-room snapshots cannot authorize implementation\n'
printf 'PASS: retry context is bounded, deterministic, and excludes prior prose\n'
printf 'PASS: registered live workers transition queued issues to in-progress\n'
printf 'PASS: failed registrations and dead workers preserve queued lifecycle state\n'
exit 0
