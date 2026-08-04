#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#28997 and GH#29141: expected lifecycle transitions
# remain audited without hiding destructive changes or unavailable state reads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../gh-audit-anomaly-helper.sh"
LOG_HELPER="${SCRIPT_DIR}/../gh-audit-log-helper.sh"
SAFE_EDIT_HELPER="${SCRIPT_DIR}/../shared-gh-wrappers-safe-edit.sh"
TEST_ROOT=""

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

TEST_ROOT="$(mktemp -d -t aidevops-gh-anomaly-XXXXXX)"
LOG_FILE="${TEST_ROOT}/gh-audit.log"

cat >"$LOG_FILE" <<'EOF'
{"ts":"2026-07-31T00:00:00Z","op":"issue_edit","repo":"example/repo","number":1,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:01:00Z","op":"issue_edit","repo":"example/repo","number":2,"caller_script":"/workspace/.agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:02:00Z","op":"issue_edit","repo":"example/repo","number":3,"caller_script":"/tmp/close-issue.sh","caller_function":"main","before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:done"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-review"],"labels_added":["status:done"]},"suspicious":["protected_label_removed:status:in-review"]}
{"ts":"2026-07-31T00:03:00Z","op":"issue_edit","repo":"example/repo","number":4,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:04:00Z","op":"issue_edit","repo":"example/repo","number":5,"caller_script":42,"caller_function":"_approval_apply_issue_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:05:00Z","op":"issue_edit","repo":"example/repo","number":6,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_issue_lifecycle_updates","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:06:00Z","op":"pr_edit","repo":"example/repo","number":7,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_pr_lifecycle_updates","flags":{"approval_verified":"v2-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:07:00Z","op":"pr_edit","repo":"example/repo","number":8,"caller_script":"/runtime/agents/scripts/approval-helper.sh","caller_function":"_approval_apply_pr_lifecycle_updates","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:08:00Z","op":"issue_edit","repo":"example/repo","number":9,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:09:00Z","op":"issue_edit","repo":"example/repo","number":10,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:10:00Z","op":"issue_edit","repo":"example/repo","number":11,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":[]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:11:00Z","op":"issue_edit","repo":"example/repo","number":12,"caller_script":"/runtime/agents/scripts/routine-log-helper.sh","caller_function":"_update_tracking_issue","flags":{},"before":{"capture_status":"ok","title_len":27,"body_len":1822,"labels":["routines","routine-tracking"]},"after":{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null},"delta":{"comparable":false,"title_delta_pct":null,"body_delta_pct":null,"labels_removed":null,"labels_added":null},"suspicious":["state_capture_unavailable:after"]}
{"ts":"2026-07-31T00:12:00Z","op":"issue_edit","repo":"example/repo","number":13,"caller_script":"/runtime/agents/scripts/worker-permission-helper.sh","caller_function":"permission_apply_block","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-progress","status:in-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["status:in-review","needs-maintainer-permissions"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["status:in-progress"],"labels_added":["needs-maintainer-permissions"]},"suspicious":["protected_label_removed:status:in-progress"]}
{"ts":"2026-07-31T00:13:00Z","op":"issue_edit","repo":"example/repo","number":14,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:14:00Z","op":"issue_edit","repo":"example/repo","number":15,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":[]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
{"ts":"2026-07-31T00:15:00Z","op":"issue_edit","repo":"example/repo","number":16,"caller_script":"/runtime/agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":0,"labels":["auto-dispatch"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":-100,"labels_removed":["needs-maintainer-review"],"labels_added":["auto-dispatch"]},"suspicious":["protected_label_removed:needs-maintainer-review","body_delta_pct=-100"]}
{"ts":"2026-07-31T00:16:00Z","op":"issue_edit","repo":"example/repo","number":17,"caller_script":"/workspace/.agents/scripts/pulse-nmr-approval.sh","caller_function":"_nmr_edit_issue_labels","flags":{"trusted_author_nmr_verified":"v1-current-state"},"before":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]},"after":{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]},"delta":{"comparable":true,"title_delta_pct":0,"body_delta_pct":0,"labels_removed":["needs-maintainer-review"],"labels_added":["hold-for-review"]},"suspicious":["protected_label_removed:needs-maintainer-review"]}
EOF

output=$(GH_AUDIT_LOG_FILE="$LOG_FILE" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run)

[[ "$output" == *"**Anomalies found:** 11"* ]] || fail "expected transitions were not excluded exactly"
[[ "$output" == *"| #3 |"* ]] || fail "unexpected lifecycle transition was hidden"
[[ "$output" == *"| #4 |"* ]] || fail "approval transition with an additional signal was hidden"
[[ "$output" == *"| #5 |"* ]] || fail "malformed provenance was dropped instead of retained"
[[ "$output" == *"| #6 |"* ]] || fail "unverified approval provenance was trusted"
[[ "$output" == *"| #8 |"* ]] || fail "unverified PR approval provenance was trusted"
[[ "$output" == *"| #10 |"* ]] || fail "permission block with an additional signal was hidden"
[[ "$output" == *"| #11 |"* ]] || fail "permission block without its blocker label was hidden"
[[ "$output" == *"| #12 |"* ]] || fail "unavailable state capture was hidden"
[[ "$output" == *"| #13 |"* ]] || fail "permission block with a lingering active status was hidden"
[[ "$output" == *"| #15 |"* ]] || fail "unverified trusted-author NMR removal was hidden"
[[ "$output" == *"| #16 |"* ]] || fail "trusted-author NMR transition with an additional signal was hidden"
[[ "$output" == *"The audit log stores lengths, not content."* ]] || fail "recovery guidance overclaimed audit content"
[[ "$output" != *"| #1 |"* && "$output" != *"| #2 |"* && "$output" != *"| #7 |"* && "$output" != *"| #9 |"* &&
	"$output" != *"| #14 |"* && "$output" != *"| #17 |"* ]] ||
	fail "an exact expected transition remained actionable"

MALFORMED_LOG="${TEST_ROOT}/malformed-audit.log"
cat >"$MALFORMED_LOG" <<'EOF'
{"suspicious":[]}
not-json
{"ts":"2026-07-31T00:13:00Z","op":"issue_edit","repo":"example/repo","number":14,"caller_function":"main","suspicious":["body_delta_pct=-100"]}
EOF
malformed_rc=0
GH_AUDIT_LOG_FILE="$MALFORMED_LOG" GH_ANOMALY_STATE_FILE="${TEST_ROOT}/malformed-state.json" \
	GH_AUDIT_QUIET=true "$HELPER" scan --all --dry-run >/dev/null 2>&1 || malformed_rc=$?
[[ "$malformed_rc" -ne 0 ]] || fail "malformed NDJSON did not fail the scan closed"
[[ ! -e "${TEST_ROOT}/malformed-state.json" ]] || fail "malformed NDJSON advanced the scan checkpoint"

# shellcheck source=../shared-gh-wrappers-safe-edit.sh
source "$SAFE_EDIT_HELPER"
PROOF_LOG="${TEST_ROOT}/proof-audit.log"
export GH_AUDIT_LOG_FILE="$PROOF_LOG"
cmd_verify() {
	local target_type="${1:-}"
	local target_number="${2:-}"
	if [[ "$target_type" == "issue" && "$target_number" == "20" ]] ||
		[[ "$target_type" == "pr" && "$target_number" == "21" ]]; then
		printf 'VERIFIED\n'
		return 0
	fi
	printf 'WRONG_TARGET\n'
	return 1
}
_gh_audit_record_op \
	"issue_edit" "example/repo" "20" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_issue_lifecycle_updates" "1"
jq -e 'select(.number == 20) | .flags.approval_verified == "v2-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "successful current-state verification did not produce audit proof"
_gh_audit_record_op \
	"pr_edit" "example/repo" "21" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_pr_lifecycle_updates" "1"
jq -e 'select(.number == 21) | .flags.approval_verified == "v2-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "successful PR verification did not produce audit proof"

cmd_verify() {
	printf 'STALE_APPROVAL\n'
	return 4
}
_gh_audit_record_op \
	"pr_edit" "example/repo" "22" \
	'{"title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/approval-helper.sh" \
	"_approval_apply_pr_lifecycle_updates" "1"
jq -e -s 'map(select(.number == 22))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "failed approval verification produced trusted audit proof"

CURRENT_ACTOR="trusted-runner"
gh() {
	local command="$1"
	local resource="${2:-}"
	[[ "$command" == "api" ]] || return 1
	case "$resource" in
	repos/example/repo/issues/25 | repos/example/repo/issues/27)
		printf '%s\n' '{"user":{"login":"trusted-author","type":"User"},"author_association":"COLLABORATOR","labels":[{"name":"hold-for-review"}]}'
		;;
	repos/example/repo/issues/26)
		printf '%s\n' '{"user":{"login":"external-author","type":"User"},"author_association":"CONTRIBUTOR","labels":[]}'
		;;
	user)
		printf '%s\n' "$CURRENT_ACTOR"
		;;
	*) return 1 ;;
	esac
	return 0
}
_gh_actor_has_repo_write_authority() {
	local repo_slug="$1"
	local actor="$2"
	local association="${3:-NONE}"
	[[ "$repo_slug" == "example/repo" ]] || return 2
	[[ "$actor" == "trusted-runner" || ("$actor" == "trusted-author" && "$association" == "COLLABORATOR") ]]
	return $?
}
_gh_audit_record_op \
	"issue_edit" "example/repo" "25" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e 'select(.number == 25) | .flags.trusted_author_nmr_verified == "v1-current-state"' "$PROOF_LOG" >/dev/null ||
	fail "trusted-author NMR transition did not produce current-state audit proof"
_gh_audit_record_op \
	"issue_edit" "example/repo" "26" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":[]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e -s 'map(select(.number == 26))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "external-author NMR removal produced trusted-author audit proof"
CURRENT_ACTOR="read-only-runner"
_gh_audit_record_op \
	"issue_edit" "example/repo" "27" \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review","needs-maintainer-review"]}' \
	'{"capture_status":"ok","title_len":1,"body_len":1,"labels":["hold-for-review"]}' \
	"/runtime/agents/scripts/pulse-nmr-approval.sh" \
	"_nmr_edit_issue_labels" "1"
jq -e -s 'map(select(.number == 27))[0].flags == {}' "$PROOF_LOG" >/dev/null ||
	fail "read-only current actor produced trusted-author audit proof"
unset CURRENT_ACTOR
unset GH_AUDIT_LOG_FILE

gh() {
	local resource="${1:-}"
	if [[ "$resource" != "issue" && "$resource" != "pr" ]]; then
		return 1
	fi
	return 1
}
unavailable_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
unavailable_pr="$(_gh_audit_fetch_pr_state_json "9" "example/repo")"
jq -e '.capture_status == "unavailable" and .title_len == null and .body_len == null and .labels == null' \
	<<<"$unavailable_issue" >/dev/null || fail "failed issue read was encoded as an empty state"
jq -e '.capture_status == "unavailable" and .title_len == null and .body_len == null and .labels == null' \
	<<<"$unavailable_pr" >/dev/null || fail "failed PR read was encoded as an empty state"

gh() {
	local resource="${1:-}"
	if [[ "$resource" != "issue" && "$resource" != "pr" ]]; then
		return 1
	fi
	printf '%s\n' '{"title":"Protected title","body":"Protected body","labels":[{"name":"monitoring"}]}'
	return 0
}
available_issue="$(_gh_audit_fetch_issue_state_json "8" "example/repo")"
jq -e '.capture_status == "ok" and .title_len == 15 and .body_len == 14 and .labels == ["monitoring"]' \
	<<<"$available_issue" >/dev/null || fail "successful issue read was not marked comparable"

CAPTURE_LOG="${TEST_ROOT}/capture-audit.log"
GH_AUDIT_LOG_FILE="$CAPTURE_LOG" GH_AUDIT_QUIET=true "$LOG_HELPER" record \
	--op issue_edit --repo example/repo --number 23 \
	--before-json '{"capture_status":"ok","title_len":1,"body_len":1,"labels":["monitoring"]}' \
	--after-json '{"capture_status":"unavailable","title_len":null,"body_len":null,"labels":null}' \
	--caller-script routine-log-helper.sh --caller-function _update_tracking_issue --caller-line 1
jq -e '
	.delta.comparable == false
	and .delta.title_delta_pct == null
	and .delta.body_delta_pct == null
	and .delta.labels_removed == null
	and .delta.labels_added == null
	and .suspicious == ["state_capture_unavailable:after"]
' "$CAPTURE_LOG" >/dev/null || fail "unavailable capture produced a destructive delta"

MISSING_CAPTURE_LOG="${TEST_ROOT}/missing-capture-audit.log"
GH_AUDIT_LOG_FILE="$MISSING_CAPTURE_LOG" GH_AUDIT_QUIET=true "$LOG_HELPER" record \
	--op issue_edit --repo example/repo --number 24 \
	--caller-script unknown.sh --caller-function main --caller-line 1
jq -e '
	.before.capture_status == "unavailable"
	and .after.capture_status == "unavailable"
	and .delta.comparable == false
	and .suspicious == ["state_capture_unavailable:before", "state_capture_unavailable:after"]
' "$MISSING_CAPTURE_LOG" >/dev/null || fail "omitted snapshots became synthetic empty state"

printf 'PASS: expected approval transitions are retained in the log but excluded from alerts\n'
