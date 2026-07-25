#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for NMR approval notification helpers in pulse-nmr-approval.sh
# (GH#21752 / t3049).
#
# Verifies that the notification helper correctly:
#   a. Posts a notification when stale-recovery NMR + OWNER-authored approved
#      PR with origin:worker and all green CI exists
#   b. Does NOT post for non-collaborator PRs (contributor injection vector)
#   c. Does NOT post for COLLABORATOR PRs (mid-trust injection vector)
#   d. Does NOT post for origin:worker-takeover PRs (weaker provenance)
#   e. Posts when maintainer-gate is the only failing check
#   f. Does NOT post when a security/quality check fails
#   g. Does NOT post for cost-circuit-breaker:fired NMR
#   h. Does NOT post a duplicate when the marker already exists
#   i. Includes the repo slug in generated sudo approval commands

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
NMR_SCRIPT="${SCRIPT_DIR}/../pulse-nmr-approval.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
COMMENTS_FIXTURE=""
PR_LIST_FIXTURE=""
POSTED_COMMENT=""

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

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	COMMENTS_FIXTURE="${TEST_ROOT}/comments.json"
	PR_LIST_FIXTURE="${TEST_ROOT}/pr-list.json"
	# GH#21799: REST check-runs fixture, populated by build_pr_json per PR.
	CHECK_RUNS_FIXTURE="${TEST_ROOT}/check-runs.json"
	POSTED_COMMENT="${TEST_ROOT}/posted-comment.txt"
	export COMMENTS_FIXTURE PR_LIST_FIXTURE CHECK_RUNS_FIXTURE POSTED_COMMENT

	# gh stub: serves comments from COMMENTS_FIXTURE for 'gh api ...comments',
	# serves exact GraphQL PR-search data from PR_LIST_FIXTURE, serves REST
	# check-runs from CHECK_RUNS_FIXTURE for 'gh api ...commits/SHA/check-runs'
	# (GH#21799), and captures comment posts for 'gh issue comment'.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	if [[ "$path" == "graphql" ]]; then
		jq -c --argjson cost "${STUB_GRAPHQL_COST:-1}" \
			'{data:{search:{nodes:[.[] | .labels={nodes:(.labels // []),pageInfo:{hasNextPage:false}}]},rateLimit:{cost:$cost}}}' "$PR_LIST_FIXTURE"
		exit 0
	fi
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--paginate) shift ;;
			--jq) jq_filter="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == */comments ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$COMMENTS_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$COMMENTS_FIXTURE"
		fi
		exit 0
	fi
	# GH#21799: REST check-runs endpoint
	if [[ "$path" == */check-runs ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$CHECK_RUNS_FIXTURE" 2>/dev/null || echo "[]"
		else
			cat "$CHECK_RUNS_FIXTURE"
		fi
		exit 0
	fi
	# GH#21799: legacy combined-status endpoint — empty (modern repos use
	# check-runs exclusively).
	if [[ "$path" == */status ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <<<'{"statuses":[]}' 2>/dev/null || echo "[]"
		else
			echo '{"statuses":[]}'
		fi
		exit 0
	fi
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "comment" ]]; then
	shift 2
	issue_num=""
	body=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--repo) shift 2 ;;
			--body) body="$2"; shift 2 ;;
			*) issue_num="$1"; shift ;;
		esac
	done
	printf '%s\n' "$body" >"$POSTED_COMMENT"
	exit 0
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Seed empty fixtures
	printf '[]\n' >"$COMMENTS_FIXTURE"
	printf '[]\n' >"$PR_LIST_FIXTURE"
	printf '{"check_runs":[]}\n' >"$CHECK_RUNS_FIXTURE"
	: >"$POSTED_COMMENT"

	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_comments() {
	local body="$1"
	printf '%s\n' "$body" >"$COMMENTS_FIXTURE"
	return 0
}

set_pr_list() {
	local body="$1"
	printf '%s\n' "$body" >"$PR_LIST_FIXTURE"
	return 0
}

reset_posted_comment() {
	: >"$POSTED_COMMENT"
	return 0
}

was_comment_posted() {
	[[ -s "$POSTED_COMMENT" ]]
	return $?
}

posted_comment_contains() {
	local pattern="$1"
	grep -q "$pattern" "$POSTED_COMMENT" 2>/dev/null
	return $?
}

# Also stub gh_issue_comment to the same captured output (the function
# may be called instead of bare gh issue comment)
gh_issue_comment() {
	local issue_num=""
	local body=""
	local repo=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--repo) repo="$2"; shift 2 ;;
			--body) body="$2"; shift 2 ;;
			*) issue_num="$1"; shift ;;
		esac
	done
	printf '%s\n' "$body" >"$POSTED_COMMENT"
	return 0
}
export -f gh_issue_comment

# Keep the finder test isolated from any ambient gh_pr_list wrapper loaded by
# the developer shell; this fixture wants the local gh stub above.
gh_pr_list() {
	gh pr list "$@"
	return $?
}
export -f gh_pr_list

# Extract the functions under test from the source file.
define_helper_under_test() {
	# GH#21799: source the REST check-runs helper sub-library so the extracted
	# `_find_qualifying_pr_for_stale_recovery` can call `gh_pr_check_runs_rest`.
	local checks_lib="${SCRIPT_DIR}/../shared-gh-wrappers-checks.sh"
	if [[ ! -f "$checks_lib" ]]; then
		printf 'ERROR: shared-gh-wrappers-checks.sh not found at %s\n' \
			"$checks_lib" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	source "$checks_lib"

	local finder_src notify_src ever_notify_src
	finder_src=$(awk '
		/^_find_qualifying_pr_for_stale_recovery\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	notify_src=$(awk '
		/^_notify_stale_recovery_resolved_by_pr\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	ever_notify_src=$(awk '
		/^notify_ever_nmr_without_approval\(\) \{/,/^}$/ { print }
	' "$NMR_SCRIPT")
	if [[ -z "$finder_src" || -z "$notify_src" || -z "$ever_notify_src" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$NMR_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$finder_src"
	# shellcheck disable=SC1090
	eval "$notify_src"
	# shellcheck disable=SC1090
	eval "$ever_notify_src"
	return 0
}

issue_was_ever_nmr() {
	local issue_num="$1"
	local repo_slug="$2"
	[[ -n "$issue_num" && -n "$repo_slug" ]]
	return $?
}
export -f issue_was_ever_nmr

issue_has_required_approval() {
	local issue_num="$1"
	local repo_slug="$2"
	local known_status="${3:-}"
	[[ -n "$issue_num" && -n "$repo_slug" && -n "$known_status" ]] || return 0
	return 1
}
export -f issue_has_required_approval

# --- Helper: build a PR JSON object for the fixture ---
# GH#21799: PR JSON now carries headRefOid (not statusCheckRollup); the
# corresponding check-run states are written to CHECK_RUNS_FIXTURE so the
# mocked `gh api .../check-runs` call returns them.
build_pr_json() {
	local num="${1:-100}"
	local review="${2:-APPROVED}"
	local author_assoc="${3:-OWNER}"
	local created_at="${4:-2026-04-29T10:00:00Z}"
	local origin_label="${5:-origin:worker}"
	local ci_status="${6:-SUCCESS}"
	local maintainer_gate_status="${7:-FAILURE}"

	local labels_json
	labels_json=$(jq -n --arg l "$origin_label" '[{"name": $l}]')

	# GH#21799: write check-runs to the REST fixture file. Wrapped under
	# `check_runs` to mirror the real REST response shape; the helper's
	# `--jq '[.check_runs[]? | {...}]'` filter will unwrap it.
	jq -n \
		--arg ci "$ci_status" \
		--arg mg "$maintainer_gate_status" \
		'{check_runs: [
			{"name": "quality / ShellCheck", "conclusion": $ci, "status": "completed"},
			{"name": "quality / Codacy", "conclusion": $ci, "status": "completed"},
			{"name": "gate / Maintainer Review & Assignee Gate", "conclusion": $mg, "status": "completed"}
		]}' >"$CHECK_RUNS_FIXTURE"

	# Synthetic SHA derived from PR number — shape mirrors a real OID.
	local pr_sha
	pr_sha=$(printf 'sha%036d' "$num")

	jq -n \
		--argjson num "$num" \
		--arg review "$review" \
		--arg assoc "$author_assoc" \
		--arg created "$created_at" \
		--argjson labels "$labels_json" \
		--arg sha "$pr_sha" \
		'{
			number: $num,
			reviewDecision: $review,
			authorAssociation: $assoc,
			createdAt: $created,
			labels: $labels,
			headRefOid: $sha
		}'
	return 0
}

# ============================================================
# Test cases
# ============================================================

# Case A: stale-recovery NMR + OWNER-authored OPEN approved PR (origin:worker,
# green CI) -> notification posted
test_a_stale_recovery_with_approved_pr_posts_notification() {
	reset_posted_comment
	# Comments: stale-recovery-tick:escalated marker, no prior notification
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached**"}]'
	# PR: OWNER, APPROVED, origin:worker, all CI green, created after NMR
	local pr_data
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted && posted_comment_contains "nmr-stale-recovery-resolution-notice"; then
		print_result "Case A: stale-recovery + approved OWNER PR -> notification posted" 0
	else
		print_result "Case A: stale-recovery + approved OWNER PR -> notification posted" 1 \
			"Expected notification comment to be posted"
	fi
	if posted_comment_contains "sudo aidevops approve issue 21699 marcusquinn/aidevops"; then
		print_result "Case A2: stale-recovery notification includes repo slug" 0
	else
		print_result "Case A2: stale-recovery notification includes repo slug" 1 \
			"Expected sudo command to include repo slug"
	fi
	return 0
}

# Case B: stale-recovery NMR + non-collaborator PR with APPROVED state -> no notification
test_b_non_collaborator_pr_no_notification() {
	reset_posted_comment
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	local pr_data
	pr_data=$(build_pr_json 200 "APPROVED" "NONE" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case B: non-collaborator PR -> no notification" 1 \
			"Notification should NOT be posted for non-collaborator PRs"
	else
		print_result "Case B: non-collaborator PR -> no notification" 0
	fi
	return 0
}

# Case C: stale-recovery NMR + COLLABORATOR PR with APPROVED state -> no notification
test_c_collaborator_pr_no_notification() {
	reset_posted_comment
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	local pr_data
	pr_data=$(build_pr_json 201 "APPROVED" "COLLABORATOR" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case C: COLLABORATOR PR -> no notification" 1 \
			"Notification should NOT be posted for COLLABORATOR PRs"
	else
		print_result "Case C: COLLABORATOR PR -> no notification" 0
	fi
	return 0
}

# Case D: stale-recovery NMR + origin:worker-takeover PR -> no notification
test_d_worker_takeover_pr_no_notification() {
	reset_posted_comment
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	local pr_data
	pr_data=$(build_pr_json 202 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker-takeover" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case D: origin:worker-takeover PR -> no notification" 1 \
			"Notification should NOT be posted for worker-takeover PRs"
	else
		print_result "Case D: origin:worker-takeover PR -> no notification" 0
	fi
	return 0
}

# Case E: stale-recovery NMR + PR with maintainer-gate as only failing check -> notification posted
test_e_maintainer_gate_only_failure_posts_notification() {
	reset_posted_comment
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	# PR with all quality checks SUCCESS, only maintainer gate FAILURE
	local pr_data
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted && posted_comment_contains "nmr-stale-recovery-resolution-notice"; then
		print_result "Case E: maintainer-gate only failing check -> notification posted" 0
	else
		print_result "Case E: maintainer-gate only failing check -> notification posted" 1 \
			"Expected notification when maintainer-gate is the only failing check"
	fi
	return 0
}

# Case F: stale-recovery NMR + PR with a failing security/quality check -> no notification
test_f_failing_quality_check_no_notification() {
	reset_posted_comment
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"}]'
	# PR with shellcheck FAILURE
	local pr_data
	pr_data=$(build_pr_json 203 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "FAILURE" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case F: failing quality check -> no notification" 1 \
			"Notification should NOT be posted when quality/security checks fail"
	else
		print_result "Case F: failing quality check -> no notification" 0
	fi
	return 0
}

# Case G: cost-circuit-breaker:fired NMR + green approved PR -> no notification
test_g_cost_breaker_no_notification() {
	reset_posted_comment
	# Comments: cost-circuit-breaker:fired marker (no stale-recovery)
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->"}]'
	local pr_data
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case G: cost-circuit-breaker:fired NMR -> no notification" 1 \
			"Notification should NOT be posted for cost-circuit-breaker trips"
	else
		print_result "Case G: cost-circuit-breaker:fired NMR -> no notification" 0
	fi
	return 0
}

# Case H: duplicate invocation with marker already present -> no second comment
test_h_idempotency_no_duplicate() {
	reset_posted_comment
	# Comments: stale-recovery marker + EXISTING notification marker
	set_comments '[{"created_at":"2026-04-29T09:14:00Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->"},{"created_at":"2026-04-29T09:20:00Z","body":"<!-- nmr-stale-recovery-resolution-notice -->\nPR #21716 is APPROVED"}]'
	local pr_data
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	_notify_stale_recovery_resolved_by_pr 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z"

	if was_comment_posted; then
		print_result "Case H: idempotency -> no duplicate comment" 1 \
			"Should NOT post a second notification when marker already exists"
	else
		print_result "Case H: idempotency -> no duplicate comment" 0
	fi
	return 0
}

# Case I: missing NMR timestamp -> no jq date parse error and no candidate PR
test_i_empty_nmr_timestamp_no_candidate() {
	reset_posted_comment
	local pr_data candidate
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"

	candidate=$(_find_qualifying_pr_for_stale_recovery 21699 "marcusquinn/aidevops" "")

	if [[ -n "$candidate" ]]; then
		print_result "Case I: empty NMR timestamp -> no candidate" 1 \
			"Expected no candidate when NMR timestamp is empty, got: ${candidate}"
	else
		print_result "Case I: empty NMR timestamp -> no candidate" 0
	fi
	return 0
}

# Case J: ever-NMR remediation comments include the target repo slug in the
# sudo command so the maintainer can approve from outside the target repo.
test_j_ever_nmr_remediation_includes_repo_slug() {
	reset_posted_comment
	set_comments '[]'

	notify_ever_nmr_without_approval 3733 "exampleorg/examplerepo"

	if was_comment_posted && posted_comment_contains "sudo aidevops approve issue 3733 exampleorg/examplerepo"; then
		print_result "Case J: ever-NMR remediation includes repo slug" 0
	else
		print_result "Case J: ever-NMR remediation includes repo slug" 1 \
			"Expected ever-NMR remediation sudo command to include repo slug"
	fi
	return 0
}

# Case K: calibrated GraphQL cost drift must fail closed rather than treating
# an unmetered policy-level review decision as authoritative.
test_k_graphql_cost_drift_no_candidate() {
	reset_posted_comment
	local pr_data candidate
	pr_data=$(build_pr_json 21716 "APPROVED" "OWNER" "2026-04-29T09:19:00Z" "origin:worker" "SUCCESS" "FAILURE")
	set_pr_list "[${pr_data}]"
	export STUB_GRAPHQL_COST=2
	candidate=$(_find_qualifying_pr_for_stale_recovery 21699 "marcusquinn/aidevops" "2026-04-29T09:14:00Z")
	unset STUB_GRAPHQL_COST

	if [[ -z "$candidate" ]]; then
		print_result "Case K: GraphQL cost drift fails closed" 0
	else
		print_result "Case K: GraphQL cost drift fails closed" 1 \
			"Expected no candidate when cost contract changes, got: ${candidate}"
	fi
	return 0
}

# ============================================================
# Main
# ============================================================

main() {
	setup_test_env
	trap teardown_test_env EXIT

	define_helper_under_test || {
		printf 'FATAL: could not define helper under test\n' >&2
		exit 1
	}

	test_a_stale_recovery_with_approved_pr_posts_notification
	test_b_non_collaborator_pr_no_notification
	test_c_collaborator_pr_no_notification
	test_d_worker_takeover_pr_no_notification
	test_e_maintainer_gate_only_failure_posts_notification
	test_f_failing_quality_check_no_notification
	test_g_cost_breaker_no_notification
	test_h_idempotency_no_duplicate
	test_i_empty_nmr_timestamp_no_candidate
	test_j_ever_nmr_remediation_includes_repo_slug
	test_k_graphql_cost_drift_no_candidate

	printf '\n%d tests run, %d failures\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	return 0
}

main "$@"
