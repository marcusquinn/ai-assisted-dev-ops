#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Mock-only recovery/ownership regression coverage (GH#31305).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../pulse-merge-feedback-finalizer.sh
source "${SCRIPT_DIR}/pulse-merge-feedback-finalizer.sh"

local_owner=1
mock_comments='[]'
mock_metadata='{"state":"open","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-review"}]}'
_interactive_claim_fence_blocks_dispatch() { return "$local_owner"; }
gh() {
	case "$*" in
	*comments*) printf '%s\n' "$mock_comments" ;;
	*) printf '%s\n' "$mock_metadata" ;;
	esac
	return 0
}
_feedback_route_owner_allows 31265 owner/repo
local_owner=0
if _feedback_route_owner_allows 31265 owner/repo; then
	printf 'FAIL: live local repair owner was displaced\n' >&2
	exit 1
fi
local_owner=1
mock_comments=$(jq -nc '{user:{login:"owner"}, author_association:"OWNER", created_at:(now | todateiso8601), body:"Interactive session claimed by @owner"} | [.]')
if _feedback_route_owner_allows 31265 owner/repo; then
	printf 'FAIL: remote interactive repair owner was displaced\n' >&2
	exit 1
fi
mock_comments=$(jq '.[0].author_association = "NONE"' <<<"$mock_comments")
_feedback_route_owner_allows 31265 owner/repo
mock_comments=$(jq '.[0].author_association = "OWNER" | .[0].user.login = "foreign"' <<<"$mock_comments")
_feedback_route_owner_allows 31265 owner/repo
printf 'PASS: local and remote owners fenced; foreign claims do not manufacture ownership\n'

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "$HOME"
export WORKER_ISSUE_NUMBER=31265 WORKER_SESSION_KEY=issue-31265
export DISPATCH_REPO_SLUG=owner/repo AIDEVOPS_ATTEMPT_ID=fixture-attempt
mock_metadata='{"number":31265,"state":"open","author_association":"OWNER","title":"Checkpoint integration","body":"## Files Scope\n- src/caller.sh","assignees":[],"labels":[]}'
mock_prs='[{"number":31269,"headRefOid":"2222222222222222222222222222222222222222","isCrossRepository":false,"closingIssuesReferences":[{"number":31265}]}]'
ownership_rc=0
gh() {
	case "$*" in
	"pr list "*) printf '%s\n' "$mock_prs" ;;
	*) printf '%s\n' "$mock_metadata" ;;
	esac
	return 0
}
git() {
	case "$*" in
	*symbolic-ref*) printf 'worker/issue-31265\n' ;;
	*) printf '%040d\n' 1 ;;
	esac
	return 0
}
_hrw_verify_dispatch_ownership() { return "$ownership_rc"; }
print_info() { return 0; }
print_warning() { return 0; }
_headless_private_workload_enabled() { return 1; }
output_has_completion_signal() { return 0; }
output_has_blocked_signal() { return 0; }
output_has_post_pr_handoff_signal() { return 1; }
output_has_missing_context_blocked_signal() { return 1; }
output_has_capability_blocked_signal() { return 1; }
# shellcheck source=../headless-runtime-result.sh
source "${SCRIPT_DIR}/headless-runtime-result.sh"
# These are dynamic caller-scoped inputs to the runtime result classifier.
# shellcheck disable=SC2034
role=worker session_key=issue-31265 discovered_session="" selected_model=fixture work_dir="$TEST_ROOT"
output_file="${TEST_ROOT}/output.jsonl"
write_request() {
	local reason="${1:-adjacent_integration}"
	jq -nc --arg reason "$reason" '
		{schema:1,issue:31265,pr:31269,reason:$reason,files:["src/claim.sh"],
		evidence:"actual caller requires shared claim integration",verification:["bash existing-checkpoint-fixture.sh"]} |
		{type:"text",part:{text:("BLOCKED: integration needs correction\nINTEGRATION_RECOVERY_REQUEST=" + tojson)}}
	' >"$output_file"
	return 0
}
write_request
result_rc=0
_handle_run_result_success_output || result_rc=$?
[[ "$result_rc" == 88 && ! -f "$output_file" ]]
write_request
result_rc=0
_handle_run_result_success_output || result_rc=$?
[[ "$result_rc" == 83 ]]
records=$(python3 "${SCRIPT_DIR}/integration_recovery.py" pending)
jq -e 'length == 1 and .[0].owner == "pulse" and .[0].pr == 31269 and .[0].head != .[0].pr_head' <<<"$records" >/dev/null
write_request
ownership_rc=1
if integration_recovery_capture "$output_file" "$work_dir"; then
	printf 'FAIL: foreign ownership was accepted\n' >&2
	exit 1
fi
ownership_rc=0
mock_metadata=$(jq '.author_association="NONE"' <<<"$mock_metadata")
if integration_recovery_capture "$output_file" "$work_dir"; then
	printf 'FAIL: foreign actor manufactured recovery delegation\n' >&2
	exit 1
fi
# shellcheck source=../headless-runtime-run.sh
source "${SCRIPT_DIR}/headless-runtime-run.sh"
attempt_exit=88
_CMD_RUN_DISPOSITION_CONTINUE="continue"
_cmd_run_disposition="" prompt=""
_handle_cmd_run_continuation_attempt
[[ "$_cmd_run_disposition" == continue && "$prompt" == *"grants no authority"* ]]
finish_calls=0
_cmd_run_finish() { finish_calls=$((finish_calls + 1)); return 0; }
_CMD_RUN_DISPOSITION_RETURN="return"
completion_state="complete"
_handle_cmd_run_continuation_attempt
[[ "$_cmd_run_disposition" == return && "$finish_calls" == 1 ]]
printf 'PASS: runtime producer resumes once, queues before release and rejects foreign ownership/authority\n'

(
	# shellcheck source=../interactive-session-helper.sh
	source "${SCRIPT_DIR}/interactive-session-helper.sh"
	fixture_origin="" fixture_claim='{"state":"OPEN","assignees":[{"login":"owner"}],"labels":[{"name":"status:in-review"}]}'
	writes=0
	git() {
		case "$*" in
		*"remote get-url"*) printf '%s\n' "$fixture_origin" ;;
		*) printf 'worker/issue-31265\n' ;;
		esac
		return 0
	}
	_isc_can_manage_issue_state() { return 0; }
	_isc_read_claim_metadata() { printf '%s\n' "$fixture_claim"; return 0; }
	gh() {
		case "$*" in
		"pr list "*) printf '%s\n' "$mock_prs" ;;
		"pr edit "*) writes=$((writes + 1)) ;;
		*) return 1 ;;
		esac
		return 0
	}
	for fixture_origin in https://github.com/owner/repo.git git@github.com:owner/repo.git ssh://git@github.com/owner/repo.git ssh://git@github.com:22/owner/repo.git; do
		_isc_normalize_owned_pr 31265 owner/repo "$TEST_ROOT" owner
	done
	[[ "$writes" == 4 ]]
	fixture_origin=https://github.com/foreign/repo.git
	if _isc_cmd_claim 31265 owner/repo --implementing --worktree "$TEST_ROOT"; then
		printf 'FAIL: wrong-origin claim passed pre-mutation validation\n' >&2
		exit 1
	fi
	[[ "$writes" == 4 ]]
)
printf 'PASS: HTTPS and SSH takeover normalization; wrong origin fails before claim writes\n'
