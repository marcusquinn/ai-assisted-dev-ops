#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAYERS="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)/pulse-dispatch-dedup-layers.sh"
TEST_ROOT="$(mktemp -d)"
TESTS_RUN=0
TESTS_FAILED=0
trap 'rm -rf "$TEST_ROOT"' EXIT

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# shellcheck source=../pulse-dispatch-dedup-layers.sh
source "$LAYERS"
SCRIPT_DIR="${TEST_ROOT}/scripts"
LOGFILE="${TEST_ROOT}/pulse.log"
mkdir -p "$SCRIPT_DIR"
cat >"${SCRIPT_DIR}/dispatch-dedup-helper.sh" <<'DEDUP_STUB'
#!/usr/bin/env bash
if [[ "$1" == "is-assigned" ]]; then
	printf '%s\n' "${STUB_ASSIGNED_OUTPUT}"
	exit 1
fi
if [[ "$1" == "has-open-pr" ]]; then
	printf '%s\n' "${STUB_OPEN_PR_OUTPUT:-}"
	exit "${STUB_OPEN_PR_RC:-0}"
fi
exit 1
DEDUP_STUB
chmod +x "${SCRIPT_DIR}/dispatch-dedup-helper.sh"

export STUB_OPEN_PR_OUTPUT='PR_LOOKUP_RESULT=uncertain reason=timeout scope=open_siblings
PR_LOOKUP_UNCERTAIN: open_siblings lookup failed; dispatch is blocked'
export STUB_OPEN_PR_RC=0
LAYER4_OUTPUT=""
LAYER4_RC=0
LAYER4_OUTPUT=$(_dedup_layer4_pr_evidence "123" "owner/repo" "Fixture") || LAYER4_RC=$?
if [[ "$LAYER4_RC" -eq 0 && "$LAYER4_OUTPUT" == "pr_lookup_uncertain" ]] &&
	grep -q 'PR_LOOKUP_RESULT=uncertain reason=timeout' "$LOGFILE"; then
	print_result "Layer 4 preserves PR lookup uncertainty as a distinct block" 0
else
	print_result "Layer 4 preserves PR lookup uncertainty as a distinct block" 1
fi

export STUB_OPEN_PR_OUTPUT=''
export STUB_OPEN_PR_RC=1
LAYER4_OUTPUT=""
LAYER4_RC=0
LAYER4_OUTPUT=$(_dedup_layer4_pr_evidence "123" "owner/repo" "Fixture") || LAYER4_RC=$?
if [[ "$LAYER4_RC" -eq 1 && -z "$LAYER4_OUTPUT" ]]; then
	print_result "Layer 4 allows dispatch after a subsequent valid empty lookup" 0
else
	print_result "Layer 4 allows dispatch after a subsequent valid empty lookup" 1
fi

# Exercise the production router's event parsing/argument fence before replacing
# it with a counter stub for the Layer 6 return-semantics tests below.
ROUTE_ARGS_FILE="${TEST_ROOT}/route-args"
mkdir -p "${TEST_ROOT}/repo"
cat >"${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh" <<ROUTE_STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >"${ROUTE_ARGS_FILE}"
exit 0
ROUTE_STUB
chmod +x "${SCRIPT_DIR}/pr-checkpoint-continuation-helper.sh"
_pulse_merge_repo_path_for_slug() {
	local _repo_slug="$1"
	: "$_repo_slug"
	printf '%s\n' "${TEST_ROOT}/repo"
	return 0
}

PRODUCTION_ROUTER="_dispatch_stale_pr_checkpoint_continuation"
if "$PRODUCTION_ROUTER" "123" "owner/repo" \
	'STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation assignee=stale-runner' "runner" && \
	[[ "$(<"$ROUTE_ARGS_FILE")" == "dispatch owner/repo ${TEST_ROOT}/repo 42 123 stale-runner runner" ]]; then
	print_result "router binds continuation to stale and authenticated owners" 0
else
	print_result "router binds continuation to stale and authenticated owners" 1
fi

if ! "$PRODUCTION_ROUTER" "123" "owner/repo" \
	'STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation' "runner"; then
	print_result "router rejects continuation without exact stale assignee" 0
else
	print_result "router rejects continuation without exact stale assignee" 1
fi

ROUTE_CALLS=0
ROUTE_RESULT=0
LAST_ROUTE_ARGS=""
_dispatch_stale_pr_checkpoint_continuation() {
	local _issue_number="$1"
	local _repo_slug="$2"
	local _assigned_output="$3"
	local _self_login="$4"
	: "$_issue_number" "$_repo_slug" "$_assigned_output" "$_self_login"
	ROUTE_CALLS=$((ROUTE_CALLS + 1))
	LAST_ROUTE_ARGS="$*"
	return "$ROUTE_RESULT"
}

export STUB_ASSIGNED_OUTPUT='STALE_PR_CONTINUATION: issue #123 in owner/repo — PR #42 preserved for exact-head continuation assignee=stale-runner'
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 1 ]]; then
	print_result "stale draft continuation routes once and blocks issue redispatch" 0
else
	print_result "stale draft continuation routes once and blocks issue redispatch" 1
fi

ROUTE_RESULT=1
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 2 ]]; then
	print_result "continuation launch failure still blocks competing dispatch" 0
else
	print_result "continuation launch failure still blocks competing dispatch" 1
fi

export STUB_ASSIGNED_OUTPUT='STALE_RECHECK_BLOCKED: issue #123 in owner/repo — evidence changed before draft continuation'
if _dedup_layer6_assignee_and_stale "123" "owner/repo" "runner" && [[ "$ROUTE_CALLS" -eq 2 ]]; then
	print_result "changed stale evidence fails closed without continuation or redispatch" 0
else
	print_result "changed stale evidence fails closed without continuation or redispatch" 1
fi

STUB_ACTIVE_WORKER=0
has_worker_for_repo_issue() {
	local _issue_number="$1"
	local _repo_slug="$2"
	: "$_issue_number" "$_repo_slug"
	if [[ "$STUB_ACTIVE_WORKER" -eq 1 ]]; then
		return 0
	fi
	return 1
}

_dispatch_has_interactive_hold() {
	local issue_meta_json="$1"
	if printf '%s' "$issue_meta_json" | jq -e '
		(.labels // []) | map(.name) |
		((index("auto-dispatch") | not) and (index("status:in-review") or index("origin:interactive")))
	' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

checkpoint_meta='{"number":29507,"state":"OPEN","title":"Fixture","labels":[{"name":"origin:interactive"},{"name":"status:in-review"}],"assignees":[{"login":"stale-runner"}]}'
export STUB_OPEN_PR_OUTPUT='WORKER_DRAFT_CHECKPOINT: draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
export STUB_OPEN_PR_RC=0
ROUTE_CALLS=0
ROUTE_RESULT=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 1 && "$LAST_ROUTE_ARGS" == *"PR #29519"* ]] &&
	grep -q 'reason=worker_draft_checkpoint_continuation signal=checkpoint_routed' "$LOGFILE"; then
	print_result "#29507 interactive-provenance checkpoint routes exactly one continuation before hold" 0
else
	print_result "#29507 interactive-provenance checkpoint routes exactly one continuation before hold" 1
fi

ROUTE_CALLS=0
ROUTE_RESULT=1
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 1 ]] && grep -q 'reason=worker_draft_checkpoint_blocked' "$LOGFILE"; then
	print_result "verified checkpoint launch failure remains an explicit block" 0
else
	print_result "verified checkpoint launch failure remains an explicit block" 1
fi

export STUB_OPEN_PR_OUTPUT='draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
ROUTE_CALLS=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 0 ]] && grep -q 'reason=interactive_review_hold' "$LOGFILE"; then
	print_result "otherwise identical human draft remains a genuine interactive hold" 0
else
	print_result "otherwise identical human draft remains a genuine interactive hold" 1
fi

export STUB_OPEN_PR_OUTPUT='WORKER_DRAFT_CHECKPOINT: draft PR #29519 is a durable checkpoint for issue #29507; ordinary redispatch is blocked'
STUB_ACTIVE_WORKER=1
ROUTE_CALLS=0
: >"$LOGFILE"
if _dispatch_interactive_hold_gate "29507" "owner/repo" "Fixture" "runner" "$checkpoint_meta" &&
	[[ "$ROUTE_CALLS" -eq 0 ]] && grep -q 'reason=interactive_review_hold' "$LOGFILE"; then
	print_result "live worker keeps checkpoint under genuine interactive hold" 0
else
	print_result "live worker keeps checkpoint under genuine interactive hold" 1
fi

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf 'All %d tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%d / %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
