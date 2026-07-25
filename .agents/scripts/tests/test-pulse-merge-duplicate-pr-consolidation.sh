#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-duplicate-pr-consolidation.sh — m-20260508-0e27c3 task 2.4 regression guards.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_DUPLICATE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge-duplicate-consolidation.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TEST_LINKED_ISSUES=""
TEST_PASSING_CHECKS=""
TEST_VERIFY_RC=0
TEST_ISSUE_LABELS=""

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_functions_under_test() {
	local fn_src
	_PMDC_REVIEW_NONE="NONE"
	_PMDC_DRAFT_TRUE="true"
	fn_src=$(awk '
		/^_pmp_pr_label_csv\(\) \{/,/^}$/ { print }
		/^_pmp_pr_is_worker_owned_for_consolidation\(\) \{/,/^}$/ { print }
		/^_pmp_normalize_mergeable_for_consolidation_into\(\) \{/,/^}$/ { print }
		/^_pmp_issue_blocks_pr_consolidation\(\) \{/,/^}$/ { print }
		/^_pmp_pr_consolidation_health_score\(\) \{/,/^}$/ { print }
		/^_pmp_pr_consolidation_candidate_is_healthy\(\) \{/,/^}$/ { print }
		/^_pmp_close_superseded_sibling_pr\(\) \{/,/^}$/ { print }
		/^_pmp_consolidate_duplicate_pr_group\(\) \{/,/^}$/ { print }
		/^_pmp_consolidate_duplicate_pr_groups\(\) \{/,/^}$/ { print }
	' "$MERGE_DUPLICATE_FILE")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract consolidation functions from %s\n' "$MERGE_DUPLICATE_FILE" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

install_stubs() {
	gh() {
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "$1" == "api" && "$2" == *"/issues/"* ]]; then
			if [[ "$*" == *"--jq"* ]]; then
				printf '%s\n' "$TEST_ISSUE_LABELS"
				return 0
			fi
			printf '%s\n' "$TEST_ISSUE_LABELS" | jq -R 'split(",") | map(select(length > 0)) | {labels: map({name: .})}'
			return 0
		fi
		return 0
	}
	_extract_linked_issue() {
		local pr_number="$1"
		local repo_slug="$2"
		printf '%s\n' "$TEST_LINKED_ISSUES" | awk -F'=' -v pr="$pr_number" '$1 == pr { print $2; found=1 } END { if (!found) exit 0 }'
		return 0
	}
	_pr_required_checks_pass() {
		local pr_number="$1"
		local repo_slug="$2"
		case ",$TEST_PASSING_CHECKS," in
		*,"$pr_number",*) return 0 ;;
		esac
		return 1
	}
	_verify_superseding_pr_for_issue() {
		local linked_issue="$1"
		local superseding_pr="$2"
		local repo_slug="$3"
		printf 'verify %s %s %s\n' "$linked_issue" "$superseding_pr" "$repo_slug" >>"$GH_CALL_LOG"
		return "$TEST_VERIFY_RC"
	}
	_pulse_merge_invalidate_pr_list_cache() {
		local repo_slug="$1"
		local reason="$2"
		printf 'invalidate %s %s\n' "$repo_slug" "$reason" >>"$GH_CALL_LOG"
		return 0
	}
	return 0
}

reset_case() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	TEST_LINKED_ISSUES=""
	TEST_PASSING_CHECKS=""
	TEST_VERIFY_RC=0
	TEST_ISSUE_LABELS=""
	return 0
}

assert_log_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label" "Expected pattern '$pattern' in $file"
	fi
	return 0
}

assert_log_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		fail "$label" "Unexpected pattern '$pattern' in $file"
	else
		pass "$label"
	fi
	return 0
}

test_duplicate_group_closes_older_sibling() {
	reset_case
	TEST_LINKED_ISSUES=$'101=900\n102=900'
	TEST_PASSING_CHECKS="102"
	local pr_json
	pr_json='[
		{"number":101,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":102,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	assert_log_contains "$GH_CALL_LOG" "verify 900 102 owner/repo" "newest healthy candidate is verified"
	assert_log_contains "$GH_CALL_LOG" "pr close 101" "older duplicate sibling closes"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 102" "candidate remains open"
	return 0
}

test_healthiest_candidate_beats_newer_unhealthy_pr() {
	reset_case
	TEST_LINKED_ISSUES=$'201=901\n202=901'
	TEST_PASSING_CHECKS="201"
	local pr_json
	pr_json='[
		{"number":201,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":202,"mergeable":"MERGEABLE","reviewDecision":"NONE","isDraft":false,"createdAt":"2026-05-08T12:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	assert_log_contains "$GH_CALL_LOG" "verify 901 201 owner/repo" "healthiest candidate selected before newest tie-break"
	assert_log_contains "$GH_CALL_LOG" "pr close 202" "less healthy sibling closes"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 201" "healthiest candidate remains open"
	return 0
}

test_health_score_handles_precomputed_legacy_mergeable_values() {
	reset_case
	local lowercase_score="" true_score="" false_score="" observed_approval_score=""
	lowercase_score=$(_pmp_pr_consolidation_health_score "owner/repo" '{}' "501" "mergeable" "NONE" "false") || lowercase_score="0"
	true_score=$(_pmp_pr_consolidation_health_score "owner/repo" '{}' "502" "true" "NONE" "false") || true_score="0"
	false_score=$(_pmp_pr_consolidation_health_score "owner/repo" '{}' "503" "false" "NONE" "false") || false_score="0"
	observed_approval_score=$(_pmp_pr_consolidation_health_score "owner/repo" '{}' "504" "MERGEABLE" "OBSERVED_APPROVED" "false") || observed_approval_score="0"
	if [[ "$lowercase_score" -eq 250 ]]; then
		pass "lowercase mergeable keeps healthy score"
	else
		fail "lowercase mergeable keeps healthy score" "Expected 250, got ${lowercase_score}"
	fi
	if [[ "$true_score" -eq 250 ]]; then
		pass "boolean-string mergeable keeps healthy score"
	else
		fail "boolean-string mergeable keeps healthy score" "Expected 250, got ${true_score}"
	fi
	if [[ "$false_score" -eq 50 ]]; then
		pass "boolean-string conflicting value does not get mergeable score"
	else
		fail "boolean-string conflicting value does not get mergeable score" "Expected 50, got ${false_score}"
	fi
	if [[ "$observed_approval_score" -eq 250 ]]; then
		pass "observed REST approval does not receive policy-approval score"
	else
		fail "observed REST approval does not receive policy-approval score" \
			"Expected 250, got ${observed_approval_score}"
	fi
	return 0
}

test_health_score_uses_shared_mergeable_normalizer_when_available() {
	reset_case
	_pmp_normalize_mergeable_state_into() {
		local dest_var="$1"
		local raw_state="$2"
		[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
		if [[ "$raw_state" == "custom-ready" ]]; then
			printf -v "$dest_var" '%s' "MERGEABLE"
		else
			printf -v "$dest_var" '%s' "UNKNOWN"
		fi
		return 0
	}
	local shared_score=""
	shared_score=$(_pmp_pr_consolidation_health_score "owner/repo" '{}' "504" "custom-ready" "NONE" "false") || shared_score="0"
	unset -f _pmp_normalize_mergeable_state_into
	if [[ "$shared_score" -eq 250 ]]; then
		pass "shared mergeable normalizer is authoritative when available"
	else
		fail "shared mergeable normalizer is authoritative when available" "Expected 250, got ${shared_score}"
	fi
	return 0
}

test_noop_for_untrusted_gated_or_unverified_groups() {
	reset_case
	TEST_LINKED_ISSUES=$'301=902\n302=902\n303=902'
	TEST_PASSING_CHECKS="301,302,303"
	TEST_ISSUE_LABELS="needs-maintainer-review"
	local gated_json
	gated_json='[
		{"number":301,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":302,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":303,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T12:00:00Z","labels":[{"name":"origin:interactive"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$gated_json"
	assert_log_not_contains "$GH_CALL_LOG" "pr close" "maintainer-gated duplicate group is no-op"

	reset_case
	TEST_LINKED_ISSUES=$'401=903\n402=903'
	TEST_PASSING_CHECKS="401,402"
	TEST_VERIFY_RC=1
	local unverified_json
	unverified_json='[
		{"number":401,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":402,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$unverified_json"
	assert_log_contains "$GH_CALL_LOG" "verify 903 402 owner/repo" "unverified candidate is checked"
	assert_log_not_contains "$GH_CALL_LOG" "pr close" "verification failure leaves siblings open"
	return 0
}

test_noop_when_candidate_is_not_healthy_enough() {
	reset_case
	TEST_LINKED_ISSUES=$'601=905\n602=905'
	local weak_json
	weak_json='[
		{"number":601,"mergeable":"UNKNOWN","reviewDecision":"NONE","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":602,"mergeable":"MERGEABLE","reviewDecision":"NONE","isDraft":false,"createdAt":"2026-05-08T12:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$weak_json"
	assert_log_not_contains "$GH_CALL_LOG" "verify 905 602 owner/repo" "weak candidate is not scope-verified"
	assert_log_not_contains "$GH_CALL_LOG" "pr close" "weak candidate leaves sibling PRs open"
	assert_log_contains "$LOGFILE" "not healthy enough" "weak candidate reason is logged"
	return 0
}

test_close_is_comment_only_and_keeps_branch() {
	reset_case
	TEST_LINKED_ISSUES=$'701=906\n702=906'
	TEST_PASSING_CHECKS="702"
	local pr_json
	pr_json='[
		{"number":701,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":702,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	assert_log_contains "$GH_CALL_LOG" "pr close 701" "superseded PR close command is used"
	assert_log_contains "$GH_CALL_LOG" "invalidate owner/repo closed duplicate PR #701" "successful duplicate close invalidates repository PR-list caches"
	assert_log_contains "$GH_CALL_LOG" "--comment" "superseded close carries evidence comment"
	assert_log_not_contains "$GH_CALL_LOG" "--delete-branch" "superseded close does not delete branches"
	assert_log_not_contains "$GH_CALL_LOG" "issue close" "superseded duplicate consolidation never closes issues"
	return 0
}

test_group_parsing_vars_do_not_pollute_global_scope() {
	reset_case
	TEST_LINKED_ISSUES=$'801=907\n802=907'
	TEST_PASSING_CHECKS="802"
	local pr_json
	pr_json='[
		{"number":801,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T10:00:00Z","labels":[{"name":"origin:worker"}]},
		{"number":802,"mergeable":"MERGEABLE","reviewDecision":"APPROVED","isDraft":false,"createdAt":"2026-05-08T11:00:00Z","labels":[{"name":"origin:worker"}]}
	]'
	pr_number="sentinel-pr"
	_score="sentinel-score"
	_is_draft="sentinel-draft"
	_issue="sentinel-issue"
	_created="sentinel-created"
	_pmp_consolidate_duplicate_pr_groups "owner/repo" "$pr_json"
	if [[ "$pr_number" == "sentinel-pr" && "$_score" == "sentinel-score" && "$_is_draft" == "sentinel-draft" && "$_issue" == "sentinel-issue" && "$_created" == "sentinel-created" ]]; then
		pass "group parsing variables stay local"
	else
		fail "group parsing variables stay local" "Expected sentinel globals, got pr_number=${pr_number}, _score=${_score}, _is_draft=${_is_draft}, _issue=${_issue}, _created=${_created}"
	fi
	unset pr_number _score _is_draft _issue _created
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_functions_under_test
	install_stubs

	test_duplicate_group_closes_older_sibling
	test_healthiest_candidate_beats_newer_unhealthy_pr
	test_health_score_handles_precomputed_legacy_mergeable_values
	test_health_score_uses_shared_mergeable_normalizer_when_available
	test_noop_for_untrusted_gated_or_unverified_groups
	test_noop_when_candidate_is_not_healthy_enough
	test_close_is_comment_only_and_keeps_branch
	test_group_parsing_vars_do_not_pollute_global_scope

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
