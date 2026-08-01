#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR}/.."
REVIEW_HELPER="${SCRIPTS_DIR}/review-bot-gate-helper.sh"
TEST_ROOT=$(mktemp -d)
CURRENT_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STALE_HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
DRIFT_HEAD="cccccccccccccccccccccccccccccccccccccccc"
GH_LOG="${TEST_ROOT}/gh.log"
TESTS_RUN=0
TESTS_FAILED=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT
mkdir -p "${TEST_ROOT}/bin"

cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "gh $*" >>"$GH_LOG"

if [[ "${1:-}" == "api" && "$*" == *"dismissals"* ]]; then
	[[ "${DISMISS_FAIL:-0}" == "1" ]] && exit 1
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/pulls/"*"/reviews"* ]]; then
	cat "$REVIEWS_FILE"
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/issues/"*"/comments"* ]]; then
	cat "$COMMENTS_FILE"
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/commits/"*"/status"* ]]; then
	printf '{"sha":"%s","statuses":[{"context":"CodeRabbit","state":"%s","creator":%s}]}\n' "$CURRENT_HEAD" "$STATUS_STATE" "$STATUS_CREATOR_JSON"
	exit 0
fi
if [[ "${1:-}" == "api" && "$*" == *"/pulls/"* ]]; then
	count=0
	[[ -f "$SNAPSHOT_COUNT_FILE" ]] && count=$(<"$SNAPSHOT_COUNT_FILE")
	count=$((count + 1))
	printf '%s\n' "$count" >"$SNAPSHOT_COUNT_FILE"
	head_sha="$CURRENT_HEAD"
	if [[ "${HEAD_DRIFT:-0}" == "1" && "$count" -ge 2 ]]; then
		head_sha="$DRIFT_HEAD"
	fi
	printf '{"state":"open","head":{"sha":"%s"},"author_association":"%s"}\n' "$head_sha" "$AUTHOR_ASSOCIATION"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "checks" ]]; then
	printf '%s\n' '[{"name":"required-ci","state":"SUCCESS","bucket":"pass"}]'
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" && " $* " == *" --jq "* ]]; then
	printf '%s\n' "$CURRENT_HEAD"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" && "$*" == *"state,isDraft,reviewDecision,headRefOid,headRefName"* ]]; then
	review_decision="CHANGES_REQUESTED"
	if grep -q "dismissals" "$GH_LOG"; then
		review_decision=""
	fi
	printf '{"state":"OPEN","isDraft":false,"reviewDecision":"%s","headRefOid":"%s","headRefName":"remote-branch"}\n' "$review_decision" "$CURRENT_HEAD"
	exit 0
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf '{"headRefOid":"%s","reviewDecision":"%s"}\n' "$CURRENT_HEAD" "${POST_REVIEW_DECISION:-}"
	exit 0
fi
exit 1
GH_STUB
chmod +x "${TEST_ROOT}/bin/gh"

export PATH="${TEST_ROOT}/bin:/opt/homebrew/bin:/usr/bin:/bin"
export GH_LOG CURRENT_HEAD DRIFT_HEAD
export REVIEWS_FILE="${TEST_ROOT}/reviews.json"
export COMMENTS_FILE="${TEST_ROOT}/comments.json"
export SNAPSHOT_COUNT_FILE="${TEST_ROOT}/snapshot-count"

reset_fixture() {
	: >"$GH_LOG"
	rm -f "$SNAPSHOT_COUNT_FILE"
	export AUTHOR_ASSOCIATION="COLLABORATOR"
	export STATUS_STATE="success"
	export STATUS_CREATOR_JSON="null"
	export HEAD_DRIFT=0
	export DISMISS_FAIL=0
	export POST_REVIEW_DECISION=""
	cat >"$REVIEWS_FILE" <<EOF
[{"id":4782275476,"user":{"login":"coderabbitai[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","commit_id":"${STALE_HEAD}","submitted_at":"2026-07-26T17:52:52Z"}]
EOF
	cat >"$COMMENTS_FILE" <<EOF
[{"id":5084683322,"user":{"login":"coderabbitai[bot]","type":"Bot"},"created_at":"2026-07-26T17:53:09Z","body":"\`@maintainer\` Re-review of exact head \`${CURRENT_HEAD}\` complete — **no blocking findings**.\n<!-- <review_comment_addressed> -->"}]
EOF
	return 0
}

record_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

run_reconcile() {
	bash "$REVIEW_HELPER" reconcile-stale-coderabbit 42 owner/repo "$CURRENT_HEAD" >/dev/null 2>&1
	return $?
}

assert_blocked_without_dismissal() {
	local name="$1"
	local rc=0
	run_reconcile || rc=$?
	if [[ "$rc" -ne 0 ]] && ! grep -q "dismissals" "$GH_LOG"; then
		record_result "$name" 0
	else
		record_result "$name" 1
	fi
	return 0
}

test_valid_reconciliation() {
	reset_fixture
	local rc=0
	run_reconcile || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q "reviews/4782275476/dismissals" "$GH_LOG" \
		&& grep -q "$STALE_HEAD" "$GH_LOG" && grep -q "$CURRENT_HEAD" "$GH_LOG"; then
		record_result "stale CodeRabbit request reconciles with audited SHAs" 0
	else
		record_result "stale CodeRabbit request reconciles with audited SHAs" 1
	fi
	return 0
}

test_latest_review_state_reduction() {
	reset_fixture
	cat >"$REVIEWS_FILE" <<EOF
[{"id":1,"user":{"login":"coderabbitai[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","commit_id":"${STALE_HEAD}","submitted_at":"2026-07-26T17:52:52Z"},{"id":2,"user":{"login":"human-reviewer","type":"User"},"state":"CHANGES_REQUESTED","commit_id":"${STALE_HEAD}","submitted_at":"2026-07-26T17:52:53Z"},{"id":3,"user":{"login":"human-reviewer","type":"User"},"state":"APPROVED","commit_id":"${CURRENT_HEAD}","submitted_at":"2026-07-26T17:53:00Z"}]
EOF
	local rc=0
	run_reconcile || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q "reviews/1/dismissals" "$GH_LOG" \
		&& ! grep -q "reviews/2/dismissals" "$GH_LOG"; then
		record_result "latest state-changing review defines each active blocker" 0
	else
		record_result "latest state-changing review defines each active blocker" 1
	fi
	return 0
}

test_fail_closed_cases() {
	reset_fixture
	cat >"$REVIEWS_FILE" <<EOF
[{"id":1,"user":{"login":"coderabbitai[bot]","type":"Bot"},"state":"CHANGES_REQUESTED","commit_id":"${STALE_HEAD}","submitted_at":"2026-07-26T17:52:52Z"},{"id":2,"user":{"login":"human-reviewer","type":"User"},"state":"CHANGES_REQUESTED","commit_id":"${STALE_HEAD}","submitted_at":"2026-07-26T17:52:53Z"}]
EOF
	assert_blocked_without_dismissal "mixed human and bot blockers fail closed"

	reset_fixture
	jq --arg head "$CURRENT_HEAD" '.[0].commit_id = $head' "$REVIEWS_FILE" >"${REVIEWS_FILE}.new"
	mv "${REVIEWS_FILE}.new" "$REVIEWS_FILE"
	assert_blocked_without_dismissal "current-head CodeRabbit request fails closed"

	reset_fixture
	jq '.[0].user.type = "User"' "$REVIEWS_FILE" >"${REVIEWS_FILE}.new"
	mv "${REVIEWS_FILE}.new" "$REVIEWS_FILE"
	assert_blocked_without_dismissal "forged CodeRabbit actor fails closed"

	reset_fixture
	jq '.[0].body = "No issues found"' "$COMMENTS_FILE" >"${COMMENTS_FILE}.new"
	mv "${COMMENTS_FILE}.new" "$COMMENTS_FILE"
	assert_blocked_without_dismissal "ambiguous bot prose fails closed"

	local status=""
	for status in pending failure; do
		reset_fixture
		export STATUS_STATE="$status"
		assert_blocked_without_dismissal "CodeRabbit status ${status} fails closed"
	done

	reset_fixture
	export STATUS_CREATOR_JSON='{"login":"attacker","type":"User"}'
	assert_blocked_without_dismissal "forged CodeRabbit status creator fails closed"

	reset_fixture
	export HEAD_DRIFT=1
	assert_blocked_without_dismissal "head drift before dismissal fails closed"

	reset_fixture
	export AUTHOR_ASSOCIATION="CONTRIBUTOR"
	assert_blocked_without_dismissal "untrusted PR author fails closed"
	return 0
}

test_aggregate_reread() {
	reset_fixture
	export POST_REVIEW_DECISION="CHANGES_REQUESTED"
	local rc=0
	run_reconcile || rc=$?
	if [[ "$rc" -ne 0 ]] && grep -q "dismissals" "$GH_LOG"; then
		record_result "aggregate review state is re-read after dismissal" 0
	else
		record_result "aggregate review state is re-read after dismissal" 1
	fi
	return 0
}

test_full_loop_readiness_integration() {
	reset_fixture
	SCRIPT_DIR="$SCRIPTS_DIR"
	print_error() { return 0; }
	print_info() { return 0; }
	print_success() { return 0; }
	print_warning() { return 0; }
	# shellcheck source=../full-loop-helper-commit.sh
	source "${SCRIPTS_DIR}/full-loop-helper-commit.sh"
	gh_pr_checks_exact_json() {
		local repo_slug="$1"
		local pr_number="$2"
		local selection_mode="$3"
		printf 'exact-checks %s %s %s\n' "$repo_slug" "$pr_number" "$selection_mode" >>"$GH_LOG"
		printf '%s\n' '[{"name":"required-ci","state":"SUCCESS","bucket":"pass"}]'
		return 0
	}
	local rc=0
	_full_loop_verify_pr_readiness 42 owner/repo >/dev/null 2>&1 || rc=$?
	if [[ "$rc" -eq 0 ]] && grep -q "dismissals" "$GH_LOG" \
		&& grep -q "exact-checks owner/repo 42 required" "$GH_LOG"; then
		record_result "full-loop readiness reconciles before required checks" 0
	else
		record_result "full-loop readiness reconciles before required checks" 1
	fi
	return 0
}

main() {
	test_valid_reconciliation
	test_latest_review_state_reduction
	test_fail_closed_cases
	test_aggregate_reread
	test_full_loop_readiness_integration
	printf 'Ran %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
