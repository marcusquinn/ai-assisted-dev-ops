#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Verify Pulse's early merge gate recognizes only exact-head Issue Sync automation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
TEST_ROOT="$(mktemp -d)"
LOGFILE="${TEST_ROOT}/pulse.log"
AGENTS_DIR="${TEST_ROOT}/agents"
TRUST_CALLS="${TEST_ROOT}/trust-calls.log"
TESTS_RUN=0
TESTS_FAILED=0
FIXTURE_TRUSTED=0
FIXTURE_LABELS=""
PULSE_UNKNOWN_STATE="UNKNOWN"
PULSE_REVIEW_EVIDENCE_SCHEMA="aidevops.review-gate-evidence/v1"
export LOGFILE AGENTS_DIR
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "${AGENTS_DIR}/scripts"
: >"${AGENTS_DIR}/scripts/review-bot-gate-helper.sh"

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s' "$name"
	[[ -n "$detail" ]] && printf ': %s' "$detail"
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

gate_src=$(awk '/^_check_pr_merge_gates\(\) \{/,/^}$/ { print }' "$MERGE_SCRIPT")
[[ -n "$gate_src" ]] || {
	printf 'FAIL could not extract _check_pr_merge_gates\n' >&2
	exit 1
}

_handle_changes_requested_review_gate() { return 0; }
_pulse_is_trusted_issue_sync_pr() {
	printf '%s %s %s\n' "$1" "$2" "$3" >>"$TRUST_CALLS"
	[[ "$FIXTURE_TRUSTED" -eq 1 && "$3" == "head-current" ]]
}
_is_collaborator_author() {
	_PULSE_AUTHOR_PERMISSION_VALUE="none"
	return 1
}
_is_trusted_dependabot_update_pr() { return 1; }
_has_maintainer_crypto_approval() { return 1; }
check_permission_failure_pr() { return 0; }
check_pr_modifies_workflows() { return 1; }
check_gh_workflow_scope() { return 0; }
_pm_issue_api() { printf 'repos/%s/issues/%s\n' "$1" "$2"; }
_attempt_worker_briefed_auto_merge() { return 0; }
_check_interactive_pr_gates() { return 0; }
gh() { return 0; }
gh_pr_view() {
	if [[ "$*" == *"labels,isDraft"* ]]; then
		if [[ "$FIXTURE_LABELS" == "external-contributor" ]]; then
			printf '%s\n' '{"labels":[{"name":"external-contributor"}],"isDraft":false}'
		else
			printf '%s\n' '{"labels":[],"isDraft":false}'
		fi
	else
		printf '%s\n' "$FIXTURE_LABELS"
	fi
	return 0
}
bash() {
	printf '%s\n' '{"schema":"aidevops.review-gate-evidence/v1","repo":"owner/repo","pr":"950","head_sha":"head-current","status":"PASS_ADVISORY","author":{"login":"github-actions[bot]","association":"COLLABORATOR","class":"trusted"},"permitted":true,"reason":"trusted_advisory_default","state":"pass","merge_gate":"clear","exit_code":0}'
	return 0
}

# shellcheck disable=SC1090
eval "$gate_src"

run_gate() {
	local expected_head="${1:-head-current}"
	local rc=0
	_check_pr_merge_gates 950 owner/repo app/github-actions APPROVED "" \
		"$FIXTURE_LABELS" "$expected_head" merge || rc=$?
	printf '%s\n' "$rc"
}

FIXTURE_TRUSTED=1
FIXTURE_LABELS="external-contributor"
: >"$TRUST_CALLS"
result=$(run_gate)
if [[ "$result" -eq 0 ]] && grep -q '^950 owner/repo head-current$' "$TRUST_CALLS"; then
	print_result "exact-head Issue Sync automation passes Pulse's early authority gate" 0
else
	print_result "exact-head Issue Sync automation passes Pulse's early authority gate" 1 \
		"rc=${result} calls=$(cat "$TRUST_CALLS") log=$(cat "$LOGFILE")"
fi

FIXTURE_TRUSTED=0
FIXTURE_LABELS=""
: >"$TRUST_CALLS"
: >"$LOGFILE"
result=$(run_gate)
if [[ "$result" -eq 1 ]] && grep -qF "author app/github-actions is not a collaborator" "$LOGFILE"; then
	print_result "unverified Actions automation remains blocked as external" 0
else
	print_result "unverified Actions automation remains blocked as external" 1 \
		"rc=${result} log=$(cat "$LOGFILE")"
fi

FIXTURE_TRUSTED=1
FIXTURE_LABELS=""
: >"$TRUST_CALLS"
: >"$LOGFILE"
result=$(run_gate stale-head)
if [[ "$result" -eq 1 ]] && grep -q '^950 owner/repo stale-head$' "$TRUST_CALLS"; then
	print_result "stale-head Issue Sync trust evidence fails closed" 0
else
	print_result "stale-head Issue Sync trust evidence fails closed" 1 \
		"rc=${result} calls=$(cat "$TRUST_CALLS")"
fi

printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
