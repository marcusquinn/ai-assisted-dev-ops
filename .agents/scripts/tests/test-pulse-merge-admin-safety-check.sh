#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _pulse_merge_admin_safety_check() (t2934).
#
# This is the defense-in-depth gate evaluated immediately before the
# `gh pr merge --admin` invocation in _process_single_ready_pr. It restates
# the external-contributor gate at the call site so the safety property
# becomes local to the bypass operation. The 2026-04-07 incident (#17671,
# #17685, #3846) merged external-contributor PRs because the
# maintainer-gate.yml workflow's Check 0 only inspected the linked-issue
# label. PR #17868 hardened the workflow; this gate exists so that any
# future regression in upstream gate ordering, label-application timing,
# or new code paths cannot re-open the same threat.
#
# Cases covered:
#   A — collaborator PR (no external-contributor label, not a fork)        → return 0
#   B — external-contributor label, no closing keyword in PR body          → return 1
#   C — external-contributor label, linked issue, no crypto approval       → return 1
#   D — external-contributor label, linked issue + current PR V2 approval → return 0
#   E — unlabeled fork PR (isCrossRepository=true), no crypto approval     → return 1
#   F — unlabeled fork PR (isCrossRepository=true), crypto approval        → return 0
#   I — unlabeled non-collaborator, no current PR authority                 → return 1
#   J — cached positive review evidence, live outcome no longer permitted  → return 1
#   K — stale cached evidence, refreshed exact-head positive evidence      → return 0
#   M-Q — metadata and linked-issue lookup failures are logged              → return 1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _extract_linked_issue still lives in pulse-merge.sh; the three other
# helpers (_external_pr_has_linked_issue, _external_pr_linked_issue_crypto_approved,
# _pulse_merge_admin_safety_check) were moved to pulse-merge-gates.sh by
# GH#21595, t3030.
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
GATES_SCRIPT="${SCRIPT_DIR}/../pulse-merge-gates.sh"
# shellcheck source=../pulse-merge-required-checks.sh
source "${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Set fixture state for one case: labels, isCrossRepository, body, approval.
set_fixture() {
	local labels_json="$1"
	local is_cross_repo="$2"
	local body="$3"
	local issue_approval_result="$4"
	local pr_approval_result="${5:-$issue_approval_result}"
	local pr_author="${6:-}"
	if [[ -z "$pr_author" ]]; then
		if [[ "$labels_json" == *"external-contributor"* || "$is_cross_repo" == "true" ]]; then
			pr_author="external-contributor"
		else
			pr_author="trusted-contributor"
		fi
	fi

	cat >"${TEST_ROOT}/labels.json" <<EOF
{"author":{"login":"${pr_author}"},"labels": ${labels_json}, "isCrossRepository": ${is_cross_repo}, "headRefOid": "head-current"}
EOF

	# PR title / body fixtures used by _extract_linked_issue.
	printf 'test-pr-title' >"${TEST_ROOT}/title.txt"
	printf '%s' "$body" >"${TEST_ROOT}/body.txt"

	# approval-helper.sh stub outputs distinguish development from merge authority.
	printf '%s' "$issue_approval_result" >"${TEST_ROOT}/issue-approval-result.txt"
	printf '%s' "$pr_approval_result" >"${TEST_ROOT}/pr-approval-result.txt"
	printf '%s' '' >"${TEST_ROOT}/linked-labels.txt"
	cat >"${TEST_ROOT}/review-evidence.json" <<EOF
{"schema":"aidevops.review-gate-evidence/v1","repo":"owner/repo","pr":"${body##*#}","head_sha":"head-current","status":"PASS","author":{"login":"${pr_author}","association":"MEMBER","class":"trusted"},"permitted":true,"reason":"test","state":"pass","merge_gate":"clear","exit_code":0}
EOF
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	mkdir -p "${TEST_ROOT}/agents/scripts"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Mock gh: handles the response-metered GraphQL metadata read plus the two
	# remaining `gh pr view` shapes used by delegates. Other calls exit 0.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# Response-metered final-authority metadata read.
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ -f "${TEST_ROOT}/pr-meta-fail" ]]; then
		exit 1
	fi
	if [[ -f "${TEST_ROOT}/pr-meta-empty" ]]; then
		exit 0
	fi
	has_next_page=false
	[[ -f "${TEST_ROOT}/pr-meta-partial-labels" ]] && has_next_page=true
	response=$(jq -c --argjson has_next_page "$has_next_page" '
		{data: {
			repository: {pullRequest: {
				author: .author,
				labels: {nodes: .labels, pageInfo: {hasNextPage: $has_next_page}},
				isCrossRepository: .isCrossRepository,
				headRefOid: .headRefOid
			}},
			rateLimit: {cost: 1}
		}}
	' "${TEST_ROOT}/labels.json") || exit 1
	if [[ -f "${TEST_ROOT}/pr-meta-missing-cost" ]]; then
		printf '%s' "$response" | jq -c 'del(.data.rateLimit)'
	else
		printf '%s\n' "$response"
	fi
	exit 0
fi

# Linked issue label snapshot used by the final NMR gate.
if [[ "${1:-}" == "api" && "$*" == *"repos/owner/repo/issues/"* && "$*" == *"--jq"* ]]; then
	cat "${TEST_ROOT}/linked-labels.txt"
	exit 0
fi

# gh pr view N --repo R --json title --jq ...
if [[ "$*" == *"--json title"* ]]; then
	cat "${TEST_ROOT}/title.txt"
	exit 0
fi

# gh pr view N --repo R --json body --jq ...
if [[ "$*" == *"--json body"* ]]; then
	cat "${TEST_ROOT}/body.txt"
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

# Mock approval-helper.sh — PR V2 authority is distinct from issue authority.
	export AGENTS_DIR="${TEST_ROOT}/agents"
	cat >"${TEST_ROOT}/agents/scripts/approval-helper.sh" <<'AHEOF'
#!/usr/bin/env bash
if [[ "$*" == *"verify pr"* ]]; then
	cat "${TEST_ROOT}/pr-approval-result.txt"
else
	cat "${TEST_ROOT}/issue-approval-result.txt"
fi
AHEOF
	chmod +x "${TEST_ROOT}/agents/scripts/approval-helper.sh"
	cat >"${TEST_ROOT}/agents/scripts/review-bot-gate-helper.sh" <<'RBEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "status-json" ]] || exit 1
cat "${TEST_ROOT}/review-evidence.json"
exit 0
RBEOF
	chmod +x "${TEST_ROOT}/agents/scripts/review-bot-gate-helper.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the function under test plus its delegates. After GH#21595, the
# functions live in two modules:
#   - _extract_linked_issue                       → pulse-merge.sh ($MERGE_SCRIPT)
#   - _external_pr_has_linked_issue              → pulse-merge-gates.sh ($GATES_SCRIPT)
#   - _external_pr_linked_issue_crypto_approved  → pulse-merge-gates.sh ($GATES_SCRIPT)
#   - _pulse_merge_admin_safety_check            → pulse-merge-gates.sh ($GATES_SCRIPT)
# All four are pure functions — no module-level state.
define_helpers_under_test() {
	local merge_src gates_src final_src
	gh_pr_view() {
		gh pr view "$@"
		return $?
	}
	merge_src=$(awk '
		/^_extract_linked_issue\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	gates_src=$(awk '
		/^_pulse_merge_admin_pr_json_graphql\(\) \{/,/^}$/ { print }
		/^_external_pr_has_linked_issue\(\) \{/,/^}$/ { print }
		/^_external_pr_linked_issue_crypto_approved\(\) \{/,/^}$/ { print }
		/^_external_pr_current_head_crypto_approved\(\) \{/,/^}$/ { print }
		/^_pulse_merge_admin_safety_check\(\) \{/,/^}$/ { print }
	' "$GATES_SCRIPT")
	final_src=$(awk '
		/^_pulse_merge_refresh_review_gate_evidence\(\) \{/,/^}$/ { print }
		/^_pulse_merge_final_trust_gate\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$merge_src" ]]; then
		printf 'ERROR: could not extract _extract_linked_issue from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$gates_src" ]]; then
		printf 'ERROR: could not extract gates helpers from %s\n' "$GATES_SCRIPT" >&2
		return 1
	fi
	if [[ -z "$final_src" ]]; then
		printf 'ERROR: could not extract final trust helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	_is_collaborator_author() {
		local author="$1"
		local repo_slug="$2"
		[[ -n "$repo_slug" ]] || return 2
		[[ "$author" == "external-contributor" ]] && return 1
		return 0
	}
	_is_trusted_dependabot_update_pr() {
		return 1
	}
	# shellcheck disable=SC1090
	eval "$merge_src"
	# shellcheck disable=SC1090
	eval "$gates_src"
	# shellcheck disable=SC1090
	eval "$final_src"
	PULSE_REVIEW_EVIDENCE_SCHEMA="aidevops.review-gate-evidence/v1"
	PULSE_UNKNOWN_STATE="UNKNOWN"
	_PULSE_PREFLIGHT_CALLS=0
	_pulse_merge_preflight_snapshot_gate() {
		local repo_slug="$1"
		local pr_number="$2"
		local expected_head_sha="$3"
		_PULSE_PREFLIGHT_CALLS=$((_PULSE_PREFLIGHT_CALLS + 1))
		_pmrc_review_evidence_permits_advisory "${_PULSE_REVIEW_GATE_EVIDENCE:-}" "$repo_slug" "$pr_number" "$expected_head_sha"
		return $?
	}
	return 0
}

# =============================================================================
# Case A: collaborator PR — no external-contributor label, not a fork.
# Expected: returns 0 (safe to merge).
# =============================================================================

test_case_a_collaborator_pr_returns_0() {
	set_fixture '[{"name":"bug"},{"name":"tier:standard"}]' 'false' \
		'## Summary\n\nResolves #100' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "100" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case A: collaborator PR returns 0" 1 \
			"Expected 0, got ${result}"
		return 0
	fi
	# No log message expected (function exits silently on collaborator path).
	if grep -q "DEFENSE-IN-DEPTH" "$LOGFILE"; then
		print_result "Case A: collaborator PR no log message" 1 \
			"Unexpected DEFENSE-IN-DEPTH log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case A: collaborator PR — returns 0, no log" 0
	return 0
}

test_case_l_collaborator_linked_issue_nmr_blocks_final_gate() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' \
		'## Summary\n\nResolves #930' 'VERIFIED' 'VERIFIED' 'trusted-contributor'
	printf '%s' 'needs-maintainer-review' >"${TEST_ROOT}/linked-labels.txt"

	local result=0
	_pulse_merge_admin_safety_check "930" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "linked issue #930 is unavailable or carries needs-maintainer-review" "$LOGFILE"; then
		print_result "Case L: collaborator linked-issue NMR blocks at final gate" 0
		return 0
	fi
	print_result "Case L: collaborator linked-issue NMR blocks at final gate" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_m_pr_metadata_command_failure_is_logged() {
	: >"$LOGFILE"
	touch "${TEST_ROOT}/pr-meta-fail"
	local result=0
	_pulse_merge_admin_safety_check "940" "owner/repo" "head-current" || result=$?
	rm -f "${TEST_ROOT}/pr-meta-fail"
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #940 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case M: PR metadata command failure is logged" 0
		return 0
	fi
	print_result "Case M: PR metadata command failure is logged" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_n_empty_pr_metadata_is_logged() {
	: >"$LOGFILE"
	touch "${TEST_ROOT}/pr-meta-empty"
	local result=0
	_pulse_merge_admin_safety_check "941" "owner/repo" "head-current" || result=$?
	rm -f "${TEST_ROOT}/pr-meta-empty"
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #941 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case N: empty PR metadata is logged" 0
		return 0
	fi
	print_result "Case N: empty PR metadata is logged" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_o_malformed_pr_metadata_is_logged() {
	: >"$LOGFILE"
	printf '%s' '{not-json' >"${TEST_ROOT}/labels.json"
	local result=0
	_pulse_merge_admin_safety_check "942" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #942 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case O: malformed PR metadata is logged" 0
		return 0
	fi
	print_result "Case O: malformed PR metadata is logged" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_p_missing_pr_identity_is_logged() {
	: >"$LOGFILE"
	printf '%s' '{"author":null,"labels":[],"isCrossRepository":false,"headRefOid":""}' >"${TEST_ROOT}/labels.json"
	local result=0
	_pulse_merge_admin_safety_check "943" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #943 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case P: missing PR identity is logged" 0
		return 0
	fi
	print_result "Case P: missing PR identity is logged" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_q_linked_issue_extraction_failure_is_logged() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' '## Summary\n\nResolves #944' 'VERIFIED'
	_extract_linked_issue() {
		return 1
	}
	local result=0
	_pulse_merge_admin_safety_check "944" "owner/repo" "head-current" || result=$?
	define_helpers_under_test >/dev/null
	if [[ "$result" -eq 1 ]] && grep -qF "linked issue extraction failed for PR #944 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case Q: linked issue extraction failure is logged" 0
		return 0
	fi
	print_result "Case Q: linked issue extraction failure is logged" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_r_missing_response_cost_fails_closed() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' '## Summary\n\nResolves #945' 'VERIFIED'
	touch "${TEST_ROOT}/pr-meta-missing-cost"
	local result=0
	_pulse_merge_admin_safety_check "945" "owner/repo" "head-current" || result=$?
	rm -f "${TEST_ROOT}/pr-meta-missing-cost"
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #945 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case R: missing response cost fails closed" 0
		return 0
	fi
	print_result "Case R: missing response cost fails closed" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_s_partial_label_connection_fails_closed() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' '## Summary\n\nResolves #946' 'VERIFIED'
	touch "${TEST_ROOT}/pr-meta-partial-labels"
	local result=0
	_pulse_merge_admin_safety_check "946" "owner/repo" "head-current" || result=$?
	rm -f "${TEST_ROOT}/pr-meta-partial-labels"
	if [[ "$result" -eq 1 ]] && grep -qF "exact GraphQL metadata read failed for PR #946 in owner/repo — failing closed" "$LOGFILE"; then
		print_result "Case S: partial label connection fails closed" 0
		return 0
	fi
	print_result "Case S: partial label connection fails closed" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

# =============================================================================
# Case B: external-contributor labeled, no closing keyword in body.
# Expected: returns 1 (refused — no linked issue).
# =============================================================================

test_case_b_external_no_linked_issue_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nFor #200 (parent reference, not closing)' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "200" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case B: external no linked issue returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	if ! grep -qF "REFUSING --admin merge" "$LOGFILE"; then
		print_result "Case B: refusal logged" 1 \
			"Expected REFUSING log entry. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "no linked issue" "$LOGFILE"; then
		print_result "Case B: no-linked-issue reason logged" 1 \
			"Expected 'no linked issue' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case B: external no linked issue — returns 1, refusal logged" 0
	return 0
}

# =============================================================================
# Case C: external-contributor labeled, linked issue, no crypto approval.
# Expected: returns 1 (refused — issue lacks approval).
# =============================================================================

test_case_c_external_no_approval_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nResolves #300' 'NOT_VERIFIED'

	local result
	_pulse_merge_admin_safety_check "300" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case C: external no approval returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	if ! grep -qF "lacks crypto approval" "$LOGFILE"; then
		print_result "Case C: lacks-crypto-approval reason logged" 1 \
			"Expected 'lacks crypto approval' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case C: external no approval — returns 1, refusal logged" 0
	return 0
}

# =============================================================================
# Case D: external-contributor labeled, linked issue, crypto approval present.
# Expected: returns 0 (allowed — gate satisfied).
# =============================================================================

test_case_d_external_with_approval_returns_0() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nResolves #400' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "400" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case D: external with approval returns 0" 1 \
			"Expected 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if grep -q "REFUSING" "$LOGFILE"; then
		print_result "Case D: no refusal logged" 1 \
			"Unexpected REFUSING log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case D: external with approval — returns 0, no refusal" 0
	return 0
}

test_case_g_issue_approval_without_pr_v2_is_blocked() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"}]' 'false' \
		'## Summary\n\nResolves #700' 'VERIFIED' 'LEGACY_APPROVAL'

	local result=0
	_pulse_merge_admin_safety_check "700" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "lacks V2 authority" "$LOGFILE"; then
		print_result "Case G: issue approval alone cannot authorize external PR merge" 0
		return 0
	fi
	print_result "Case G: issue approval alone is blocked" 1 \
		"Expected current-head V2 refusal. rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_h_live_nmr_blocks_even_with_v2_approval() {
	: >"$LOGFILE"
	set_fixture '[{"name":"external-contributor"},{"name":"needs-maintainer-review"}]' 'false' \
		'## Summary\n\nResolves #800' 'VERIFIED' 'VERIFIED'

	local result=0
	_pulse_merge_admin_safety_check "800" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "PR carries needs-maintainer-review" "$LOGFILE"; then
		print_result "Case H: live PR NMR blocks current V2 authority" 0
		return 0
	fi
	print_result "Case H: live PR NMR is blocked" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_i_unlabeled_non_collaborator_is_external() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' \
		'## Summary\n\nResolves #900' 'VERIFIED' 'NO_APPROVAL' 'external-contributor'

	local result=0
	_pulse_merge_admin_safety_check "900" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 ]] && grep -qF "non-collaborator PR missing external-contributor label" "$LOGFILE"; then
		print_result "Case I: unlabeled non-collaborator is treated as external" 0
		return 0
	fi
	print_result "Case I: unlabeled non-collaborator is blocked" 1 "rc=${result}; log=$(cat "$LOGFILE")"
	return 0
}

test_case_j_final_gate_rejects_stale_cached_review_evidence() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' \
		'## Summary\n\nResolves #910' 'VERIFIED' 'VERIFIED' 'trusted-contributor'
	cat >"${TEST_ROOT}/review-evidence.json" <<'EOF'
{"schema":"aidevops.review-gate-evidence/v1","repo":"owner/repo","pr":"910","head_sha":"head-current","status":"WAITING","author":{"login":"trusted-contributor","association":"MEMBER","class":"trusted"},"permitted":false,"reason":"waiting","state":"waiting","merge_gate":"blocked","exit_code":1}
EOF
	_PULSE_REVIEW_GATE_EVIDENCE='{"schema":"aidevops.review-gate-evidence/v1","repo":"owner/repo","pr":"910","head_sha":"head-current","status":"PASS","author":{"login":"trusted-contributor","association":"MEMBER","class":"trusted"},"permitted":true,"reason":"stale","state":"pass","merge_gate":"clear","exit_code":0}'
	_PULSE_PREFLIGHT_CALLS=0
	local result=0
	_pulse_merge_final_trust_gate "910" "owner/repo" "head-current" || result=$?
	if [[ "$result" -eq 1 && "$_PULSE_PREFLIGHT_CALLS" -eq 0 ]]; then
		print_result "Case J: final gate rejects stale cached review evidence" 0
		return 0
	fi
	print_result "Case J: stale cached review evidence is rejected" 1 "rc=${result}; preflight_calls=${_PULSE_PREFLIGHT_CALLS}"
	return 0
}

test_case_k_final_gate_refreshes_current_review_evidence() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'false' \
		'## Summary\n\nResolves #920' 'VERIFIED' 'VERIFIED' 'trusted-contributor'
	_PULSE_REVIEW_GATE_EVIDENCE='{"schema":"aidevops.review-gate-evidence/v1","repo":"owner/repo","pr":"920","head_sha":"old-head","status":"PASS","author":{"login":"trusted-contributor","association":"MEMBER","class":"trusted"},"permitted":true,"reason":"stale","state":"pass","merge_gate":"clear","exit_code":0}'
	_PULSE_PREFLIGHT_CALLS=0
	local result=0 evidence_observed_at=""
	_pulse_merge_final_trust_gate "920" "owner/repo" "head-current" || result=$?
	evidence_observed_at=$(jq -r '.observed_at // ""' <<<"${_PULSE_REVIEW_GATE_EVIDENCE:-}" 2>/dev/null) || evidence_observed_at=""
	if [[ "$result" -eq 0 && "$_PULSE_PREFLIGHT_CALLS" -eq 1 && -n "$evidence_observed_at" ]]; then
		print_result "Case K: final gate refreshes exact-head review evidence" 0
		return 0
	fi
	print_result "Case K: current timestamped review evidence reaches preflight" 1 "rc=${result}; preflight_calls=${_PULSE_PREFLIGHT_CALLS}; observed_at=${evidence_observed_at:-missing}"
	return 0
}

# =============================================================================
# Case E: unlabeled fork PR (isCrossRepository=true, no external label),
# no crypto approval. Tests the label-system-failure detection path.
# Expected: returns 1 (refused — fork detected, no approval).
# =============================================================================

test_case_e_unlabeled_fork_no_approval_returns_1() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'true' \
		'## Summary\n\nResolves #500' 'NOT_VERIFIED'

	local result
	_pulse_merge_admin_safety_check "500" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -ne 1 ]]; then
		print_result "Case E: unlabeled fork no approval returns 1" 1 \
			"Expected 1, got ${result}"
		return 0
	fi
	# Verify the label-system-failure log was emitted.
	if ! grep -qF "fork PR missing external-contributor label" "$LOGFILE"; then
		print_result "Case E: label-system-failure logged" 1 \
			"Expected 'fork PR missing external-contributor label' in log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if ! grep -qF "REFUSING --admin merge" "$LOGFILE"; then
		print_result "Case E: refusal logged" 1 \
			"Expected REFUSING log entry. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case E: unlabeled fork no approval — returns 1, label-failure detected" 0
	return 0
}

# =============================================================================
# Case F: unlabeled fork PR with crypto approval — verifies the fork-detection
# path doesn't over-block legitimate approved external work.
# Expected: returns 0 (allowed — fork detected, but approved).
# =============================================================================

test_case_f_unlabeled_fork_with_approval_returns_0() {
	: >"$LOGFILE"
	set_fixture '[{"name":"bug"}]' 'true' \
		'## Summary\n\nResolves #600' 'VERIFIED'

	local result
	_pulse_merge_admin_safety_check "600" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case F: unlabeled fork with approval returns 0" 1 \
			"Expected 0, got ${result}. Log: $(cat "$LOGFILE")"
		return 0
	fi
	# Label-failure log expected (fork detected without label) but no refusal.
	if ! grep -qF "fork PR missing external-contributor label" "$LOGFILE"; then
		print_result "Case F: label-failure detected" 1 \
			"Expected fork-detection log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	if grep -q "REFUSING" "$LOGFILE"; then
		print_result "Case F: no refusal logged" 1 \
			"Unexpected REFUSING log. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case F: unlabeled fork with approval — returns 0, fork detected but allowed" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_case_a_collaborator_pr_returns_0
	test_case_b_external_no_linked_issue_returns_1
	test_case_c_external_no_approval_returns_1
	test_case_d_external_with_approval_returns_0
	test_case_e_unlabeled_fork_no_approval_returns_1
	test_case_f_unlabeled_fork_with_approval_returns_0
	test_case_g_issue_approval_without_pr_v2_is_blocked
	test_case_h_live_nmr_blocks_even_with_v2_approval
	test_case_i_unlabeled_non_collaborator_is_external
	test_case_j_final_gate_rejects_stale_cached_review_evidence
	test_case_k_final_gate_refreshes_current_review_evidence
	test_case_l_collaborator_linked_issue_nmr_blocks_final_gate
	test_case_m_pr_metadata_command_failure_is_logged
	test_case_n_empty_pr_metadata_is_logged
	test_case_o_malformed_pr_metadata_is_logged
	test_case_p_missing_pr_identity_is_logged
	test_case_q_linked_issue_extraction_failure_is_logged
	test_case_r_missing_response_cost_fails_closed
	test_case_s_partial_label_connection_fails_closed

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
