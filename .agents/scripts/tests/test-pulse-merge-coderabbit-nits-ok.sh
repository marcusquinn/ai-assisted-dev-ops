#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _pulse_merge_dismiss_coderabbit_nits() (t2179).
#
# When a maintainer applies the coderabbit-nits-ok label to a PR whose only
# CHANGES_REQUESTED reviewers are coderabbitai[bot], the pulse merge gate
# should auto-dismiss those reviews and fall through instead of skipping. If
# any human reviewer is also blocking, the label is ignored and the normal
# skip behaviour applies.
#
# These tests exercise the helper in isolation with a mock `gh` stub. No
# real repository is touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _pulse_merge_dismiss_coderabbit_nits was moved to pulse-merge-process.sh
# (GH#21595, t3030).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

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

# Reset review fixture to the default (two CR-only CHANGES_REQUESTED reviews).
reset_mock_state() {
	: >"$GH_LOG"
	export PR_HAS_NITS_LABEL=1
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[
  {"id": 1001, "user": {"login": "coderabbitai[bot]", "type": "Bot"}, "state": "CHANGES_REQUESTED", "commit_id": "1111111111111111111111111111111111111111", "submitted_at": "2026-07-26T10:00:00Z"},
  {"id": 1002, "user": {"login": "coderabbitai[bot]", "type": "Bot"}, "state": "CHANGES_REQUESTED", "commit_id": "2222222222222222222222222222222222222222", "submitted_at": "2026-07-26T10:01:00Z"}
]
EOF
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export AIDEVOPS_REVIEW_BOT_GATE_HELPER="${SCRIPT_DIR}/../review-bot-gate-helper.sh"
	: >"$LOGFILE"
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Mock gh: logs every call and returns canned data from TEST_ROOT fixtures.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

_all_args=("$@")

if [[ "${1:-}" == "api" ]]; then
	# Extract --jq filter if present.
	_jq_filter=""
	for _i in "${!_all_args[@]}"; do
		if [[ "${_all_args[$_i]}" == "--jq" ]]; then
			_jq_filter="${_all_args[$((_i + 1))]:-}"
			break
		fi
	done

	# GET /reviews
	if [[ "$*" == *"/pulls/"*"/reviews"* && "$*" != *"dismissals"* && "$*" != *"-X PUT"* ]]; then
		if [[ -n "$_jq_filter" ]]; then
			jq "$_jq_filter" <"${TEST_ROOT}/reviews.json"
		else
			cat "${TEST_ROOT}/reviews.json"
		fi
		exit 0
	fi

	# PUT /reviews/.../dismissals
	if [[ "$*" == *"dismissals"* || "$*" == *"-X PUT"* ]]; then
		exit 0
	fi

	# GET /pulls/<number> snapshot used for the pre-dismiss head-drift guard.
	if [[ "$*" == *"/pulls/"* && "$*" != *"/reviews"* ]]; then
		_labels='[]'
		[[ "${PR_HAS_NITS_LABEL:-0}" == "1" ]] && _labels='[{"name":"coderabbit-nits-ok"}]'
		printf '%s\n' "{\"state\":\"open\",\"head\":{\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"author_association\":\"CONTRIBUTOR\",\"labels\":${_labels}}"
		exit 0
	fi
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf '%s\n' '{"headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","reviewDecision":""}'
	exit 0
fi

exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract _pulse_merge_dismiss_coderabbit_nits from pulse-merge.sh.
define_helper_under_test() {
	local src
	src=$(awk '
		/^_pulse_merge_dismiss_coderabbit_nits\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src" ]]; then
		printf 'ERROR: could not extract _pulse_merge_dismiss_coderabbit_nits from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src"
	return 0
}

# =============================================================================
# Case A: no coderabbit-nits-ok label — caller-level; function always has
# CR-only reviews but the calling gate checks the label first. Test the
# helper directly: it should dismiss CR-only reviews when called.
# (The label check lives in _check_pr_merge_gates, not in the helper itself.)
# =============================================================================

test_case_a_cr_only_reviews_dismissed_returns_0() {
	reset_mock_state
	# Default fixture: two CR-only CHANGES_REQUESTED reviews.
	local result
	_pulse_merge_dismiss_coderabbit_nits "100" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case A: CR-only reviews — helper returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	# Verify dismissal API calls were made for both review IDs.
	if ! grep -q "dismissals" "$GH_LOG"; then
		print_result "Case A: CR-only reviews — dismiss API called" 1 \
			"Expected dismissals API call in log. Log: $(cat "$GH_LOG")"
		return 0
	fi
	# Verify log messages were written.
	if ! grep -qF "dismissed CodeRabbit review" "$LOGFILE"; then
		print_result "Case A: CR-only reviews — dismissal logged" 1 \
			"Expected dismissal log entry. Log: $(cat "$LOGFILE")"
		return 0
	fi
	print_result "Case A: CR-only reviews — dismissed and returns 0" 0
	return 0
}

# =============================================================================
# Case B: mixed reviewers (CR + human) — helper must return 1, no dismissals.
# =============================================================================

test_case_b_mixed_reviewers_returns_1_no_dismissals() {
	reset_mock_state
	# Override fixture: one CR review + one human review.
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[
  {"id": 2001, "user": {"login": "coderabbitai[bot]", "type": "Bot"}, "state": "CHANGES_REQUESTED", "commit_id": "1111111111111111111111111111111111111111", "submitted_at": "2026-07-26T10:00:00Z"},
  {"id": 2002, "user": {"login": "human-reviewer", "type": "User"}, "state": "CHANGES_REQUESTED", "commit_id": "2222222222222222222222222222222222222222", "submitted_at": "2026-07-26T10:01:00Z"}
]
EOF
	: >"$GH_LOG"

	local result
	_pulse_merge_dismiss_coderabbit_nits "200" "owner/repo" || result=$?
	result=${result:-0}

	if [[ "$result" -eq 0 ]]; then
		print_result "Case B: mixed reviewers — helper returns 1" 1 \
			"Expected exit 1 (human reviewer blocking), got exit 0"
		return 0
	fi
	# Verify no dismissal API calls were made.
	if grep -q "dismissals" "$GH_LOG"; then
		print_result "Case B: mixed reviewers — no dismissals called" 1 \
			"Expected zero dismissals calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case B: mixed reviewers — returns 1, no dismissals" 0
	return 0
}

# =============================================================================
# Case C: zero CHANGES_REQUESTED reviews — degenerate safe case, returns 0.
# =============================================================================

test_case_c_no_changes_requested_reviews_returns_0() {
	reset_mock_state
	# Override fixture: no CHANGES_REQUESTED reviews (e.g. already dismissed).
	cat >"${TEST_ROOT}/reviews.json" <<'EOF'
[
  {"id": 3001, "user": {"login": "coderabbitai[bot]", "type": "Bot"}, "state": "APPROVED", "commit_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "submitted_at": "2026-07-26T10:00:00Z"}
]
EOF
	: >"$GH_LOG"

	local result
	_pulse_merge_dismiss_coderabbit_nits "300" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case C: no CHANGES_REQUESTED reviews — returns 0" 1 \
			"Expected exit 0 (nothing to dismiss), got ${result}"
		return 0
	fi
	# No dismissal calls needed.
	if grep -q "dismissals" "$GH_LOG"; then
		print_result "Case C: no CHANGES_REQUESTED reviews — no API calls" 1 \
			"Expected zero dismissals calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case C: no CHANGES_REQUESTED reviews — returns 0, no API calls" 0
	return 0
}

# =============================================================================
# Case D: empty reviews array — returns 0, no API calls.
# =============================================================================

test_case_d_empty_reviews_array_returns_0() {
	reset_mock_state
	echo '[]' >"${TEST_ROOT}/reviews.json"
	: >"$GH_LOG"

	local result
	_pulse_merge_dismiss_coderabbit_nits "400" "owner/repo"
	result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case D: empty reviews array — returns 0" 1 \
			"Expected exit 0, got ${result}"
		return 0
	fi
	if grep -q "dismissals" "$GH_LOG"; then
		print_result "Case D: empty reviews array — no API calls" 1 \
			"Expected zero API calls. Log: $(cat "$GH_LOG")"
		return 0
	fi
	print_result "Case D: empty reviews array — returns 0, no API calls" 0
	return 0
}

# =============================================================================
# Case E: shared helper must enforce the explicit maintainer label itself.
# =============================================================================

test_case_e_missing_label_returns_1_no_dismissals() {
	reset_mock_state
	export PR_HAS_NITS_LABEL=0
	local result=0
	_pulse_merge_dismiss_coderabbit_nits "500" "owner/repo" || result=$?
	if [[ "$result" -ne 0 ]] && ! grep -q "dismissals" "$GH_LOG"; then
		print_result "Case E: missing nits label — returns 1, no dismissals" 0
	else
		print_result "Case E: missing nits label — returns 1, no dismissals" 1 \
			"Expected fail-closed result without dismissal. Log: $(cat "$GH_LOG")"
	fi
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_case_a_cr_only_reviews_dismissed_returns_0
	test_case_b_mixed_reviewers_returns_1_no_dismissals
	test_case_c_no_changes_requested_reviews_returns_0
	test_case_d_empty_reviews_array_returns_0
	test_case_e_missing_label_returns_1_no_dismissals

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
