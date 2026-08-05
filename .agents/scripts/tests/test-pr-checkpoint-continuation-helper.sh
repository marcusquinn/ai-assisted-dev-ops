#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pr-checkpoint-continuation-helper.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT

export HOME="${TEST_ROOT}/home"
export AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR="${TEST_ROOT}/state"
mkdir -p "${HOME}" "${TEST_ROOT}/bin" "${TEST_ROOT}/repo" "$AIDEVOPS_PR_CHECKPOINT_CONTINUATION_STATE_DIR"

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s%s\n' "$name" "${detail:+ — $detail}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
	printf '%s\n' "${STUB_PR_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123" ]]; then
	printf '%s\n' "${STUB_ISSUE_JSON:-}"
	exit 0
fi
if [[ "$1" == "api" && "$2" == "repos/owner/repo/issues/123/comments?per_page=100" ]]; then
	printf '%s\n' "${STUB_COMMENTS_JSON:-[]}"
	exit 0
fi
exit 1
GH_STUB
chmod +x "${TEST_ROOT}/bin/gh"
export PATH="${TEST_ROOT}/bin:${PATH}"

# shellcheck source=../pr-checkpoint-continuation-helper.sh
source "$HELPER"

valid_pr_json() {
	local body="${1:-Resolves #123}"
	local labels="${2:-}"
	local closing_refs="${3:-}"
	local author="${4:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"origin:worker"}]'
	[[ -n "$closing_refs" ]] || closing_refs='[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}}]'
	printf '{"number":42,"state":"OPEN","title":"Continue existing work","body":"%s","closingIssuesReferences":%s,"isDraft":true,"isCrossRepository":false,"labels":%s,"headRefName":"worker/issue-123","headRefOid":"1111111111111111111111111111111111111111","author":{"login":"%s"}}\n' \
		"$body" "$closing_refs" "$labels" "$author"
	return 0
}

valid_issue_json() {
	local labels="${1:-}"
	local assignee="${2:-worker-bot}"
	[[ -n "$labels" ]] || labels='[{"name":"status:in-review"}]'
	printf '{"number":123,"state":"open","labels":%s,"assignees":[{"login":"%s"}]}\n' "$labels" "$assignee"
	return 0
}

valid_checkpoint_comments() {
	local runner="worker-bot"
	printf '[[{"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=%s ts=2026-08-04T22:29:36Z"}]]\n' "$runner"
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'
export STUB_PR_JSON STUB_ISSUE_JSON STUB_COMMENTS_JSON
if row=$(_pcc_target_row "owner/repo" "42" "123") && \
	[[ "$row" == $'Continue existing work\tworker/issue-123\t1111111111111111111111111111111111111111\tworker-bot\tin-review\tworker-bot' ]]; then
	print_result "accepts exact open worker draft linked to issue" 0
else
	print_result "accepts exact open worker draft linked to issue" 1 "row=${row:-missing}"
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #1234' '' '[{"number":1234,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects issue-number prefix collisions" 0
else
	print_result "rejects issue-number prefix collisions" 1
fi

STUB_PR_JSON="$(valid_pr_json 'unresolved #123' '' '[]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects bare issue references" 0
else
	print_result "rejects bare issue references" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123 and resolves #456' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"owner"}}},{"number":456,"repository":{"name":"repo","owner":{"login":"owner"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects ambiguous closing identities" 0
else
	print_result "rejects ambiguous closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves other/repo#123' '' '[{"number":123,"repository":{"name":"repo","owner":{"login":"other"}}}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository closing identities" 0
else
	print_result "rejects cross-repository closing identities" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_PR_JSON="${STUB_PR_JSON/\"isCrossRepository\":false/\"isCrossRepository\":true}"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects cross-repository checkpoint heads" 0
else
	print_result "rejects cross-repository checkpoint heads" 1
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '[{"name":"origin:worker"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects held worker drafts" 0
else
	print_result "rejects held worker drafts" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"needs-maintainer-review"}]')"
if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
	print_result "rejects continuation after linked issue hold" 0
else
	print_result "rejects continuation after linked issue hold" 1
fi

for conflicting_status in status:blocked status:done status:in-progress; do
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:in-review\"},{\"name\":\"${conflicting_status}\"}]")"
	if ! _pcc_target_row "owner/repo" "42" "123" >/dev/null; then
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 0
	else
		print_result "rejects contradictory linked issue lifecycle ${conflicting_status}" 1
	fi
done

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:in-review"},{"name":"origin:interactive"}]')"
STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
if _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 0
else
	print_result "accepts interactive-provenance issue with current trusted checkpoint release" 1
fi

STUB_COMMENTS_JSON='[]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects interactive-provenance issue without checkpoint release" 0
else
	print_result "rejects interactive-provenance issue without checkpoint release" 1
fi

STUB_COMMENTS_JSON='[[
  {"id":10,"created_at":"2026-08-04T22:29:37Z","author_association":"COLLABORATOR","body":"CLAIM_RELEASED reason=worker_draft_checkpoint runner=worker-bot ts=2026-08-04T22:29:36Z"},
  {"id":11,"created_at":"2026-08-04T22:30:37Z","author_association":"MEMBER","body":"Interactive session claimed this issue"}
]]'
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects replayed checkpoint release after a newer human claim" 0
else
	print_result "rejects replayed checkpoint release after a newer human claim" 1
fi

STUB_COMMENTS_JSON="$(valid_checkpoint_comments)"
STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'foreign-runner')"
if ! _pcc_target_row "owner/repo" "42" "123" "worker-bot" "worker-bot" >/dev/null; then
	print_result "rejects foreign-authored worker checkpoint" 0
else
	print_result "rejects foreign-authored worker checkpoint" 1
fi

STUB_PR_JSON="$(valid_pr_json)"
STUB_ISSUE_JSON="$(valid_issue_json)"
STUB_COMMENTS_JSON='[]'

DISPATCH_ARGS=""
DISPATCH_RESULT=0
_prrts_dispatch_guarded() {
	local repo_slug="$1"
	local pr_number="$3"
	local head_ref="${11}"
	local head_oid="${12}"
	DISPATCH_ARGS="$*"
	_prrts_prelaunch_target_fence "$repo_slug" "$pr_number" "$head_ref" "$head_oid" || return 1
	return "$DISPATCH_RESULT"
}

STATUS_CALLS=""
set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local status="$3"
	local add_assignee=""
	local flag=""
	shift 3
	STATUS_CALLS="${STATUS_CALLS}${STATUS_CALLS:+$'\n'}${issue_number} ${repo_slug} ${status} $*"
	while [[ $# -gt 0 ]]; do
		flag="$1"
		case "$flag" in
		--add-assignee)
			add_assignee="${2:-}"
			shift 2
			;;
		--remove-assignee)
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	[[ -n "$add_assignee" ]] || return 1
	STUB_ISSUE_JSON="$(valid_issue_json "[{\"name\":\"status:${status}\"}]" "$add_assignee")"
	export STUB_ISSUE_JSON
	return 0
}

STUB_PR_JSON="$(valid_pr_json)"
output_file="${TEST_ROOT}/dispatch-output"
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot" >"$output_file"; then
	output="$(<"$output_file")"
else
	output="$(<"$output_file")"
fi
if [[ "$output" == *PR_CHECKPOINT_CONTINUATION_DISPATCHED* ]] && \
	[[ "$DISPATCH_ARGS" == *"draft-checkpoint:1111111111111111111111111111111111111111:contract-3"* ]] && \
	[[ "$DISPATCH_ARGS" == *"continue-pr worker/issue-123 1111111111111111111111111111111111111111 worker-bot"* ]]; then
	print_result "dispatch binds continuation to exact PR branch and head" 0
else
	print_result "dispatch binds continuation to exact PR branch and head" 1 "output=${output:-missing} args=${DISPATCH_ARGS:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_DISPATCH_DEFERRED"
if output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_DEDUPLICATED* ]]; then
	print_result "active exact-head continuation is deduplicated as handled" 0
else
	print_result "active exact-head continuation is deduplicated as handled" 1 "output=${output:-missing}"
fi

DISPATCH_RESULT="$PRRTS_RC_MAINTAINER_ATTENTION"
if ! output=$(_pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "worker-bot") &&
	[[ "$output" == *PR_CHECKPOINT_CONTINUATION_EXHAUSTED* ]]; then
	print_result "bounded retry exhaustion is explicit" 0
else
	print_result "bounded retry exhaustion is explicit" 1 "output=${output:-missing}"
fi

STUB_PR_JSON="$(valid_pr_json 'Resolves #123' '' '' 'stale-runner')"
STUB_ISSUE_JSON="$(valid_issue_json '' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=0
if _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == '123 owner/repo in-review --add-assignee current-runner --remove-assignee stale-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "current-runner" ]] &&
	[[ "$(_prrts_worker_login 42)" == "current-runner" ]]; then
	print_result "cross-runner continuation transfers exact issue ownership before launch" 0
else
	print_result "cross-runner continuation transfers exact issue ownership before launch" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi

STUB_ISSUE_JSON="$(valid_issue_json '[{"name":"status:queued"}]' 'stale-runner')"
STATUS_CALLS=""
DISPATCH_RESULT=1
if ! _pcc_dispatch "owner/repo" "${TEST_ROOT}/repo" "42" "123" "stale-runner" "current-runner" >/dev/null &&
	[[ "$STATUS_CALLS" == $'123 owner/repo in-review --add-assignee current-runner --remove-assignee stale-runner\n123 owner/repo queued --add-assignee stale-runner --remove-assignee current-runner' ]] &&
	[[ "$PCC_ISSUE_ASSIGNEE" == "stale-runner" && "$PCC_OWNERSHIP_TRANSFERRED" -eq 0 ]] &&
	printf '%s' "$STUB_ISSUE_JSON" | jq -e '
		.assignees[0].login == "stale-runner" and
		([.labels[].name] | index("status:queued") != null)
	' >/dev/null; then
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 0
else
	print_result "failed cross-runner launch restores prior assignee and lifecycle" 1 \
		"calls=${STATUS_CALLS:-missing} assignee=${PCC_ISSUE_ASSIGNEE:-missing}"
fi
DISPATCH_RESULT=0

STUB_PR_JSON="$(valid_pr_json)"
PCC_LINKED_ISSUE="123"
PCC_HEAD_REF="worker/issue-123"
PCC_HEAD_OID="1111111111111111111111111111111111111111"
PCC_ISSUE_ASSIGNEE="worker-bot"
PCC_EXPECTED_ASSIGNEE="worker-bot"
PCC_AUTHENTICATED_LOGIN="worker-bot"
PCC_CHECKPOINT_ASSIGNEE="worker-bot"
PCC_ORIGINAL_STATUS="in-review"
PCC_OWNERSHIP_TRANSFERRED=0
if [[ "$(_prrts_worker_task_id 42)" == "123" ]] &&
	[[ "$(_prrts_worker_login 42)" == "worker-bot" ]] &&
	_prrts_apply_expected_worktree_owner owner/repo 42 "${TEST_ROOT}/repo" \
		9999 issue-worker batch-1 123 2026-08-01T00:00:00Z "" &&
	[[ "$PRRTS_WORKTREE_EXPECTED_OWNER_TASK" == "123" ]]; then
	print_result "continuation preserves the linked issue worktree task identity" 0
else
	print_result "continuation preserves the linked issue worktree task identity" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json '' 'replacement-owner')"
if ! _prrts_prelaunch_target_fence "owner/repo" "42" "$PCC_HEAD_REF" "$PCC_HEAD_OID" && \
	[[ "$PRRTS_WORKTREE_FAILURE_REASON" == "pr_checkpoint_eligibility_changed_before_launch" ]]; then
	print_result "prelaunch fence rejects one-for-one issue reassignment" 0
else
	print_result "prelaunch fence rejects one-for-one issue reassignment" 1
fi
STUB_ISSUE_JSON="$(valid_issue_json)"
prompt_file=$(_prrts_write_prompt_file "owner/repo" "${TEST_ROOT}/repo" "42" "Continue existing work" "0" "fingerprint" "preview")
if [[ -f "$prompt_file" ]] && \
	grep -q 'verify-pr-checkpoint-target' "$prompt_file" && \
	grep -q 'PR_CHECKPOINT_TARGET_VALID' "$prompt_file" && \
	grep -Fq "\$AIDEVOPS_PR_REPAIR_LINKED_ISSUE" "$prompt_file" && \
	grep -Fq "\$AIDEVOPS_PR_REPAIR_ISSUE_ASSIGNEE" "$prompt_file" && \
	grep -Fq '"worker-bot"`' "$prompt_file" && \
	grep -q "HEAD:\$AIDEVOPS_PR_REPAIR_HEAD_REF" "$prompt_file" && \
	grep -q 'Do not create another branch' "$prompt_file"; then
	print_result "continuation prompt preserves exact-target ownership contract" 0
else
	print_result "continuation prompt preserves exact-target ownership contract" 1
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
