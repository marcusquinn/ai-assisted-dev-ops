#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-consolidation-skip-resolved.sh — regression tests for t3050
#
# Covers the pre-flight resolved-parent gate added to
# _dispatch_issue_consolidation:
#   1. Gate 1: dispatch-blocked:committed-to-main label triggers skip
#   2. Gate 2: terminal completion labels trigger skip after accidental reopen
#   3. Gate 3: a structurally linked merged closing PR triggers skip
#   4. Gate 4: state=CLOSED + stateReason=NOT_PLANNED triggers skip
#   5. Gate 5a: ≥80% of #NNN refs in body are merged PRs triggers skip
#   6. Gate 5b: <80% of #NNN refs are merged PRs proceeds (returns 1)
#   7. Default proceed: no gate fires when parent is OPEN with no merged children
#   8. Fail-open: gh API error proceeds rather than skipping
#   9. Self-reference exclusion: parent's own #N not counted in Gate 5
#   10. Skip marker comment is posted via _gh_idempotent_comment
#
# Strategy: source pulse-triage.sh with a stubbed `gh` binary on PATH that
# records every invocation and returns canned responses driven by env vars.

set -euo pipefail

# NB: use a test-scoped variable name. pulse-triage.sh resolves its
# sub-libraries via $SCRIPT_DIR (post sub-library split, GH#21558). If we
# reuse that name in the test scope, sourcing pulse-triage.sh inherits
# our path and fails to locate pulse-triage-{cache,evaluation,dispatch}.sh.
TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)" || exit 1

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

# _write_gh_stub: write a `gh` stub that responds to:
#   - issue view --json state,stateReason,labels,body
#       returns JSON from $GH_ISSUE_JSON
#   - api repos/<slug>/pulls/<n> --jq .merged_at
#       returns merged_at from $GH_PR_<n>_MERGED_AT (per-PR)
#   - issue comment / issue edit / label-create / api graphql
#       no-op (records call only)
_write_gh_stub() {
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` stub for t3050 pre-flight gate tests.
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"

case "${1:-}-${2:-}" in
issue-view)
	# Drives off GH_ISSUE_JSON. Honours --jq if used.
	prev="" jq=""
	for arg in "$@"; do
		[[ "$prev" == "--jq" ]] && jq="$arg"
		prev="$arg"
	done
	if [[ -n "${GH_ISSUE_VIEW_FAIL:-}" ]]; then
		printf 'API error: stub forced failure\n' >&2
		exit 1
	fi
	if [[ -n "$jq" ]]; then
		printf '%s\n' "${GH_ISSUE_JSON:-{\}}" | jq -r "$jq"
	else
		printf '%s\n' "${GH_ISSUE_JSON:-{\}}"
	fi
	;;
api-*)
	# Two endpoint families:
	#   repos/<slug>/pulls/<n>          → merged_at lookup (Gate 3)
	#   repos/<slug>/issues/<n>/comments → existing comments list (idempotent comment)
	endpoint="$2"
	prev="" jq=""
	for arg in "$@"; do
		[[ "$prev" == "--jq" ]] && jq="$arg"
		prev="$arg"
	done
	case "$endpoint" in
	*/comments)
		# Empty array → no existing marker → idempotent comment will post.
		printf '[]\n'
		;;
	*/pulls/*)
		pr_num=$(printf '%s' "$endpoint" | grep -oE '[0-9]+$')
		var_name="GH_PR_${pr_num}_MERGED_AT"
		merged_at="${!var_name:-}"
		if [[ -n "$jq" ]]; then
			printf '%s\n' "$merged_at"
		else
			printf '{"merged_at": "%s"}\n' "$merged_at"
		fi
		;;
	*)
		printf '\n'
		;;
	esac
	;;
issue-comment | issue-edit | label-create)
	# No-op. Recorded in GH_LOG above.
	;;
*)
	printf 'gh stub: unhandled: %s\n' "$*" >&2
	exit 1
	;;
esac
exit 0
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

setup_stub() {
	TEST_ROOT=$(mktemp -d -t t3050-skipres.XXXXXX)
	GH_LOG="${TEST_ROOT}/gh.log"
	: >"$GH_LOG"
	_write_gh_stub
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_LOG
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"

	# Minimal globals expected by pulse-triage.sh / pulse-triage-dispatch.sh.
	export TRIAGE_CACHE_DIR="${TEST_ROOT}/triage-cache"
	mkdir -p "$TRIAGE_CACHE_DIR"
	export ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS=50
	export ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2

	# shellcheck disable=SC1091
	source "${REPO_ROOT}/.agents/scripts/pulse-triage.sh"

	# Stub the gh_issue_comment wrapper (defined in shared-gh-wrappers.sh,
	# not sourced here) so _gh_idempotent_comment actually reaches the
	# stubbed `gh` binary on PATH. Mirrors the gh_create_issue stub in
	# tests/test-consolidation-dispatch.sh.
	gh_issue_comment() {
		gh issue comment "$@"
	}
	gh_pr_comment() {
		gh pr comment "$@"
	}
	return 0
}

teardown_stub() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	GH_LOG=""
	unset GH_ISSUE_JSON GH_ISSUE_VIEW_FAIL
	# Clear any per-PR merged_at fixtures from prior tests.
	# bash 3.2 compatible — use compgen.
	for var in $(compgen -v | grep -E '^GH_PR_[0-9]+_MERGED_AT$' || true); do
		unset "$var"
	done
	return 0
}

# Helper: build a parent-issue JSON response for the gh stub.
_make_issue_json() {
	local state="$1"
	local state_reason="$2"
	local labels_csv="$3"
	local body="$4"
	local closing_pr="${5:-}"
	# Build labels array from CSV.
	local labels_json
	labels_json=$(printf '%s' "$labels_csv" | jq -Rc 'split(",") | map(select(length > 0) | {name: .})')
	jq -n --arg state "$state" --arg sr "$state_reason" --arg closing_pr "$closing_pr" \
		--argjson labels "$labels_json" --arg body "$body" \
		'{state: $state, stateReason: $sr, labels: $labels, body: $body,
		  closedByPullRequestsReferences: (if $closing_pr == "" then [] else [{number: ($closing_pr | tonumber)}] end)}'
	return 0
}

test_gate2_terminal_completion_label() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" \
		"auto-dispatch,solved:worker,file-size-debt" "Solved issue accidentally reopened.")
	export GH_ISSUE_JSON

	local rc=0
	_consolidation_skip_if_resolved 150 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'terminal completion label' "$LOGFILE" 2>/dev/null; then
		print_result "Gate 2: solved label on reopened issue → skip" 0
	else
		print_result "Gate 2: solved label on reopened issue → skip" 1 \
			"rc=$rc; pulse log: $(cat "$LOGFILE")"
	fi
	teardown_stub
	return 0
}

test_gate3_merged_closing_pr() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" "auto-dispatch,file-size-debt" \
		"No narrative PR references." "29702")
	export GH_ISSUE_JSON GH_PR_29702_MERGED_AT="2026-08-07T08:21:59Z"

	local rc=0
	_consolidation_skip_if_resolved 151 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'merged closing PR #29702' "$LOGFILE" 2>/dev/null; then
		print_result "Gate 3: structurally linked merged closing PR → skip" 0
	else
		print_result "Gate 3: structurally linked merged closing PR → skip" 1 \
			"rc=$rc; pulse log: $(cat "$LOGFILE")"
	fi
	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: Gate 1 — committed-to-main label triggers skip
# -----------------------------------------------------------------------------
test_gate1_committed_to_main_label() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" \
		"bug,dispatch-blocked:committed-to-main,tier:standard" \
		"Some body without #refs.")
	export GH_ISSUE_JSON

	local rc=0
	_consolidation_skip_if_resolved 100 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'dispatch-blocked:committed-to-main' "$LOGFILE" 2>/dev/null \
		&& grep -q 't3050' "$LOGFILE" 2>/dev/null; then
		print_result "Gate 1: committed-to-main label → skip + log line" 0
	else
		print_result "Gate 1: committed-to-main label → skip + log line" 1 \
			"rc=$rc, expected 0; pulse log: $(cat "$LOGFILE")"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 2: Gate 2 — CLOSED + NOT_PLANNED triggers skip
# -----------------------------------------------------------------------------
test_gate2_closed_not_planned() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "CLOSED" "NOT_PLANNED" \
		"bug,tier:standard" "Closed as won't fix.")
	export GH_ISSUE_JSON

	local rc=0
	_consolidation_skip_if_resolved 200 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -q 'CLOSED/NOT_PLANNED' "$LOGFILE" 2>/dev/null; then
		print_result "Gate 2: CLOSED/NOT_PLANNED → skip + log line" 0
	else
		print_result "Gate 2: CLOSED/NOT_PLANNED → skip + log line" 1 \
			"rc=$rc, expected 0; pulse log: $(cat "$LOGFILE")"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 3: Gate 2 — CLOSED but stateReason=COMPLETED does NOT skip
# -----------------------------------------------------------------------------
test_gate2_closed_completed_proceeds() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "CLOSED" "COMPLETED" \
		"bug" "Closed because we shipped it.")
	export GH_ISSUE_JSON

	local rc=0
	_consolidation_skip_if_resolved 201 "owner/repo" || rc=$?

	# Closed/completed has no merged refs → Gate 3 also doesn't fire → proceed (rc=1).
	if [[ "$rc" -eq 1 ]]; then
		print_result "Gate 2: CLOSED/COMPLETED → proceed (no skip)" 0
	else
		print_result "Gate 2: CLOSED/COMPLETED → proceed (no skip)" 1 \
			"rc=$rc, expected 1"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 4: Gate 3 — ≥80% of body #refs are merged PRs triggers skip
# Body references #501, #502, #503, #504, #505 (5 total). 4 merged = 80%.
# -----------------------------------------------------------------------------
test_gate3_high_merge_rate_skips() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" "bug" \
		"Tracking child PRs: #501, #502, #503, #504, #505 should resolve this.")
	export GH_ISSUE_JSON GH_PR_501_MERGED_AT="2026-04-28T10:00:00Z"
	export GH_PR_502_MERGED_AT="2026-04-28T11:00:00Z"
	export GH_PR_503_MERGED_AT="2026-04-28T12:00:00Z"
	export GH_PR_504_MERGED_AT="2026-04-28T13:00:00Z"
	# #505 not merged (no env var → empty merged_at).

	local rc=0
	_consolidation_skip_if_resolved 500 "owner/repo" || rc=$?

	if [[ "$rc" -eq 0 ]] && grep -qE '4/5 child PRs merged' "$LOGFILE" 2>/dev/null; then
		print_result "Gate 3: 4/5 (80%) merged → skip + ratio in log" 0
	else
		print_result "Gate 3: 4/5 (80%) merged → skip + ratio in log" 1 \
			"rc=$rc, expected 0; pulse log: $(cat "$LOGFILE")"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 5: Gate 3 — <80% merged proceeds (rc=1)
# Body references #601-#605 (5 total). 3 merged = 60%.
# -----------------------------------------------------------------------------
test_gate3_low_merge_rate_proceeds() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" "bug" \
		"Tracking: #601 #602 #603 #604 #605")
	export GH_ISSUE_JSON GH_PR_601_MERGED_AT="2026-04-28T10:00:00Z"
	export GH_PR_602_MERGED_AT="2026-04-28T11:00:00Z"
	export GH_PR_603_MERGED_AT="2026-04-28T12:00:00Z"
	# #604, #605 not merged.

	local rc=0
	_consolidation_skip_if_resolved 600 "owner/repo" || rc=$?

	if [[ "$rc" -eq 1 ]]; then
		print_result "Gate 3: 3/5 (60%) merged → proceed" 0
	else
		print_result "Gate 3: 3/5 (60%) merged → proceed" 1 \
			"rc=$rc, expected 1"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 6: Default proceed — no gate fires when OPEN with no merged children
# -----------------------------------------------------------------------------
test_default_proceeds() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" "bug,tier:standard" \
		"Pure narrative body. No #refs at all.")
	export GH_ISSUE_JSON

	local rc=0
	_consolidation_skip_if_resolved 700 "owner/repo" || rc=$?

	if [[ "$rc" -eq 1 ]]; then
		print_result "Default: OPEN, no refs, no triggering label → proceed" 0
	else
		print_result "Default: OPEN, no refs, no triggering label → proceed" 1 \
			"rc=$rc, expected 1"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 7: Fail-open — gh API error proceeds (rc=1)
# -----------------------------------------------------------------------------
test_api_error_fails_open() {
	setup_stub
	export GH_ISSUE_VIEW_FAIL=1

	local rc=0
	_consolidation_skip_if_resolved 800 "owner/repo" || rc=$?

	if [[ "$rc" -eq 1 ]] && grep -q 'API error' "$LOGFILE" 2>/dev/null; then
		print_result "Fail-open: gh API error → proceed (rc=1) + log line" 0
	else
		print_result "Fail-open: gh API error → proceed (rc=1) + log line" 1 \
			"rc=$rc, expected 1; pulse log: $(cat "$LOGFILE")"
	fi

	unset GH_ISSUE_VIEW_FAIL
	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 8: Self-reference exclusion — parent's own #N not counted in Gate 3
# Parent #900 body says "see #900 for context, plus #901 #902" — only #901, #902 count.
# Both merged → 2/2 = 100% merged → skip.
# -----------------------------------------------------------------------------
test_self_reference_excluded() {
	setup_stub
	GH_ISSUE_JSON=$(_make_issue_json "OPEN" "" "bug" \
		"See #900 for full context. Resolved by #901 and #902.")
	export GH_ISSUE_JSON GH_PR_901_MERGED_AT="2026-04-28T10:00:00Z"
	export GH_PR_902_MERGED_AT="2026-04-28T11:00:00Z"

	local rc=0
	_consolidation_skip_if_resolved 900 "owner/repo" || rc=$?

	# 2/2 = 100% (≥80%) → skip. If self-ref leaked, we'd get 2/3 = 66% → proceed.
	if [[ "$rc" -eq 0 ]] && grep -qE '2/2 child PRs merged' "$LOGFILE" 2>/dev/null; then
		print_result "Self-reference exclusion: parent #N not counted in Gate 3" 0
	else
		print_result "Self-reference exclusion: parent #N not counted in Gate 3" 1 \
			"rc=$rc; pulse log: $(cat "$LOGFILE")"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Test 9: _consolidation_count_merged_children — direct unit test
# -----------------------------------------------------------------------------
test_count_merged_children_direct() {
	setup_stub
	export GH_PR_1001_MERGED_AT="2026-04-28T10:00:00Z"
	export GH_PR_1003_MERGED_AT="2026-04-28T12:00:00Z"
	# #1002 not merged.

	local out merged total
	out=$(_consolidation_count_merged_children 1000 "owner/repo" \
		"Refs: #1001, #1002, #1003")
	merged=$(printf '%s' "$out" | awk '{print $1}')
	total=$(printf '%s' "$out" | awk '{print $2}')

	if [[ "$merged" == "2" && "$total" == "3" ]]; then
		print_result "_consolidation_count_merged_children: 2/3 merged" 0
	else
		print_result "_consolidation_count_merged_children: 2/3 merged" 1 \
			"got merged=$merged total=$total, expected 2/3"
	fi

	teardown_stub
	return 0
}

# -----------------------------------------------------------------------------
# Run all tests
# -----------------------------------------------------------------------------
main() {
	printf 'Running t3050 consolidator pre-flight gate tests\n\n'
	test_gate1_committed_to_main_label
	test_gate2_terminal_completion_label
	test_gate3_merged_closing_pr
	test_gate2_closed_not_planned
	test_gate2_closed_completed_proceeds
	test_gate3_high_merge_rate_skips
	test_gate3_low_merge_rate_proceeds
	test_default_proceeds
	test_api_error_fails_open
	test_self_reference_excluded
	test_count_merged_children_direct

	printf '\n----\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
