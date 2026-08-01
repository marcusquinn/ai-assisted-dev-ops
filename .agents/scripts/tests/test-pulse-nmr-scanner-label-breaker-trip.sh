#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for GH#20758: scanner-label + circuit-breaker trip
# interaction in pulse-nmr-approval.sh.
#
# The bug: `_nmr_applied_by_maintainer` checked automation-signature
# BEFORE circuit-breaker-trip. The label-based branch of
# `_nmr_application_has_automation_signature` matched any issue with a
# scanner provenance label (source:review-feedback, source:review-scanner,
# review-followup) regardless of WHEN NMR was applied — these labels
# persist for the issue's lifetime. This short-circuited the breaker
# check for scanner-labelled issues that subsequently tripped a breaker,
# producing the ever-NMR trap: auto-approval strips NMR, ever-NMR flag
# blocks dispatch permanently.
#
# Fix (defense in depth):
#   1. Inverted check order: circuit-breaker first, then automation-sig.
#   2. Added co-temporality guard to label-based branch: only match
#      scanner labels when NMR was applied within 300s of issue creation.
#
# Acceptance criteria (from GH#20758):
#   AC1: scanner-label + breaker trip at +60s → preserve NMR (return 0)
#   AC2: scanner-label + NMR at creation (no breaker) → auto-approve (return 1)
#   AC3: scanner-label + NMR at +1h (no breaker, no creation-default) → preserve (return 0)
#   AC4: existing test suite passes (verified separately)
#   AC5: no_work_loop breaker on scanner-labelled issue → preserve NMR

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
ISSUE_META_FIXTURE=""
TIMELINE_FIXTURE=""

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
	export AIDEVOPS_NMR_REVALIDATION_STATE_FILE="${TEST_ROOT}/nmr-state.json"
	: >"$LOGFILE"
	COMMENTS_FIXTURE="${TEST_ROOT}/comments.json"
	ISSUE_META_FIXTURE="${TEST_ROOT}/issue-meta.json"
	TIMELINE_FIXTURE="${TEST_ROOT}/timeline.json"
	export COMMENTS_FIXTURE ISSUE_META_FIXTURE TIMELINE_FIXTURE

	# gh stub: identical to test-pulse-nmr-automation-signature.sh
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "api" ]]; then
	path="${2:-}"
	jq_filter=""
	shift 2 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--paginate) shift ;;
			--jq) jq_filter="$2"; shift 2 ;;
			*) shift ;;
		esac
	done
	if [[ "$path" == */timeline ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$TIMELINE_FIXTURE" 2>/dev/null || echo ""
		else
			cat "$TIMELINE_FIXTURE"
		fi
		exit 0
	fi
	if [[ "$path" == */comments ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$COMMENTS_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$COMMENTS_FIXTURE"
		fi
		exit 0
	fi
	# repos/OWNER/REPO/issues/NUM (no /comments or /timeline suffix) — issue meta
	if [[ "$path" == */issues/* ]]; then
		if [[ -n "$jq_filter" ]]; then
			jq -r "$jq_filter" <"$ISSUE_META_FIXTURE" 2>/dev/null || echo "0"
		else
			cat "$ISSUE_META_FIXTURE"
		fi
		exit 0
	fi
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
EOF
	chmod +x "${TEST_ROOT}/bin/gh"

	# Seed empty fixtures
	printf '[]\n' >"$COMMENTS_FIXTURE"
	printf '{"labels":[]}\n' >"$ISSUE_META_FIXTURE"
	printf '[]\n' >"$TIMELINE_FIXTURE"
	_notify_stale_recovery_resolved_by_pr() { return 0; }

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
set_issue_meta() {
	local body="$1"
	printf '%s\n' "$body" >"$ISSUE_META_FIXTURE"
	return 0
}
set_timeline() {
	local body="$1"
	printf '%s\n' "$body" >"$TIMELINE_FIXTURE"
	return 0
}

define_helpers_under_test() {
	unset _PULSE_NMR_APPROVAL_LOADED
	# shellcheck disable=SC1090
	source "$NMR_SCRIPT"
	_nmr_record_revalidation_state() { return 0; }
	_nmr_emit_decision_packet() { return 0; }
	_notify_stale_recovery_resolved_by_pr() { return 0; }
	_gh_actor_has_repo_write_authority() {
		local repo_slug="$1" actor="$2" association="${3:-}"
		[[ -n "$repo_slug" && -n "$association" ]] || return 2
		[[ "$actor" != "external-contributor" ]]
		return $?
	}
	return 0
}

# --- AC1: scanner-label + breaker trip → preserve NMR ---

test_ac1_scanner_label_with_stale_recovery_breaker_preserves_nmr() {
	# The canonical GH#20758 scenario: example-repo#2717.
	# Issue created with source:review-feedback label. Workers crash,
	# stale-recovery escalates, NMR applied +60s after creation.
	# The breaker trip must be detected regardless of the scanner label.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T05:07:24Z"}]'
	set_comments '[{"created_at":"2026-04-24T05:07:32Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"},{"name":"needs-maintainer-review"},{"name":"auto-dispatch"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_applied_by_maintainer 2717 exampleorg/examplerepo marcusquinn; then
		print_result "AC1: scanner-label + stale-recovery breaker → PRESERVE NMR" 0
		return 0
	fi
	print_result "AC1: scanner-label + stale-recovery breaker → PRESERVE NMR" 1 \
		"Expected exit 0 — breaker trip MUST preserve NMR even with scanner label"
	return 0
}

test_ac1_scanner_label_with_cost_breaker_preserves_nmr() {
	# Same scenario but with cost-circuit-breaker:fired instead of
	# stale-recovery. Both breaker types must override the scanner label.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T06:00:00Z"}]'
	set_comments '[{"created_at":"2026-04-24T06:00:05Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\nCost circuit breaker fired"}]'
	set_issue_meta '{"labels":[{"name":"source:review-scanner"},{"name":"needs-maintainer-review"}],"created_at":"2026-04-24T04:00:00Z"}'

	if _nmr_applied_by_maintainer 100 marcusquinn/aidevops marcusquinn; then
		print_result "AC1: scanner-label + cost breaker → PRESERVE NMR" 0
		return 0
	fi
	print_result "AC1: scanner-label + cost breaker → PRESERVE NMR" 1 \
		"Expected exit 0 — cost breaker must override scanner label"
	return 0
}

# --- AC2: scanner-label + NMR at creation (no breaker) → auto-approve ---

test_ac2_scanner_label_nmr_at_creation_auto_approves() {
	# Happy path: issue created with source:review-feedback label,
	# NMR applied at creation time (within 300s of created_at),
	# no breaker comments. Should auto-approve normally.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T04:06:55Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"},{"name":"needs-maintainer-review"},{"name":"auto-dispatch"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_applied_by_maintainer 2718 exampleorg/examplerepo marcusquinn; then
		print_result "AC2: scanner-label + NMR at creation → auto-approve OK" 1 \
			"Expected exit 1 — creation default should allow auto-approve"
		return 0
	fi
	print_result "AC2: scanner-label + NMR at creation → auto-approve OK" 0
	return 0
}

test_ac2_review_followup_label_nmr_at_creation_auto_approves() {
	# Same as above but with review-followup label instead.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T04:30:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"review-followup"},{"name":"needs-maintainer-review"}],"created_at":"2026-04-24T04:29:55Z"}'

	if _nmr_applied_by_maintainer 200 marcusquinn/aidevops marcusquinn; then
		print_result "AC2: review-followup + NMR at creation → auto-approve" 1 \
			"Expected exit 1 — creation default should allow auto-approve"
		return 0
	fi
	print_result "AC2: review-followup + NMR at creation → auto-approve" 0
	return 0
}

# --- AC3: scanner-label + NMR at +1h (manual hold, no breaker) → preserve ---

test_ac3_scanner_label_late_nmr_no_breaker_preserves() {
	# Issue created with source:review-feedback label. NMR applied 1 hour
	# later (3600s > 300s threshold) with no breaker marker. This is a
	# manual hold — must preserve NMR.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T05:06:53Z"}]'
	set_comments '[{"created_at":"2026-04-24T05:06:55Z","body":"Holding for architecture review — the proposed fix changes the scanner API."}]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"},{"name":"needs-maintainer-review"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_applied_by_maintainer 2719 exampleorg/examplerepo marcusquinn; then
		print_result "AC3: scanner-label + late NMR (no breaker) → PRESERVE" 0
		return 0
	fi
	print_result "AC3: scanner-label + late NMR (no breaker) → PRESERVE" 1 \
		"Expected exit 0 — manual hold must preserve NMR regardless of scanner label"
	return 0
}

test_ac3_label_only_check_rejects_late_nmr() {
	# Direct test of _nmr_application_has_automation_signature with a
	# scanner label but NMR applied 1 hour after creation. The co-
	# temporality guard must reject this.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_application_has_automation_signature 2719 exampleorg/examplerepo "2026-04-24T05:06:53Z"; then
		print_result "AC3: signature rejects scanner-label when NMR >300s from creation" 1 \
			"Expected exit 1 — NMR applied 3600s after creation is not a creation default"
		return 0
	fi
	print_result "AC3: signature rejects scanner-label when NMR >300s from creation" 0
	return 0
}

# --- AC5: no_work_loop breaker on scanner-labelled issue → preserve NMR ---

test_ac5_no_work_loop_breaker_with_scanner_label_preserves() {
	# t2769 no_work_loop breaker on a source:review-feedback issue.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T06:30:00Z"}]'
	set_comments '[{"created_at":"2026-04-24T06:30:05Z","body":"<!-- cost-circuit-breaker:no_work_loop issue=2720 repo=exampleorg/examplerepo -->\nPer-issue no_work loop breaker fired"}]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"},{"name":"needs-maintainer-review"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_applied_by_maintainer 2720 exampleorg/examplerepo marcusquinn; then
		print_result "AC5: no_work_loop breaker + scanner-label → PRESERVE NMR" 0
		return 0
	fi
	print_result "AC5: no_work_loop breaker + scanner-label → PRESERVE NMR" 1 \
		"Expected exit 0 — no_work_loop breaker must preserve NMR"
	return 0
}

# --- Order inversion verification ---

test_order_inversion_breaker_wins_over_scanner_comment_marker() {
	# Both a scanner comment marker AND a breaker marker exist in the
	# same window. The breaker must win because of the inverted check
	# order in _nmr_applied_by_maintainer.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-24T05:07:24Z"}]'
	set_comments '[{"created_at":"2026-04-24T05:07:26Z","body":"<!-- source:review-feedback -->\nQuality-debt batch from merged PR."},{"created_at":"2026-04-24T05:07:32Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\nStale recovery threshold reached"}]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"},{"name":"needs-maintainer-review"}],"created_at":"2026-04-24T04:06:53Z"}'

	if _nmr_applied_by_maintainer 2721 exampleorg/examplerepo marcusquinn; then
		print_result "Order inversion: breaker wins over scanner marker in same window" 0
		return 0
	fi
	print_result "Order inversion: breaker wins over scanner marker in same window" 1 \
		"Expected exit 0 — circuit breaker must take priority"
	return 0
}

# --- Co-temporality boundary tests ---

test_cotemporality_at_300s_boundary_passes() {
	# NMR applied exactly 300s after creation — should still match.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"}],"created_at":"2026-04-24T04:00:00Z"}'

	if _nmr_application_has_automation_signature 300 marcusquinn/aidevops "2026-04-24T04:05:00Z"; then
		print_result "Co-temporality: 300s boundary passes" 0
		return 0
	fi
	print_result "Co-temporality: 300s boundary passes" 1 \
		"Expected exit 0 — exactly 300s gap should match"
	return 0
}

test_cotemporality_at_301s_boundary_fails() {
	# NMR applied 301s after creation — should NOT match.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"}],"created_at":"2026-04-24T04:00:00Z"}'

	if _nmr_application_has_automation_signature 301 marcusquinn/aidevops "2026-04-24T04:05:01Z"; then
		print_result "Co-temporality: 301s boundary fails" 1 \
			"Expected exit 1 — 301s gap exceeds threshold"
		return 0
	fi
	print_result "Co-temporality: 301s boundary fails" 0
	return 0
}

test_cotemporality_missing_created_at_fails_safe() {
	# If created_at is missing from the API response, the co-temporality
	# guard cannot verify timing and should fail closed (not match).
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-feedback"}]}'

	if _nmr_application_has_automation_signature 400 marcusquinn/aidevops "2026-04-24T04:05:00Z"; then
		print_result "Co-temporality: missing created_at fails safe" 1 \
			"Expected exit 1 — cannot verify timing without created_at"
		return 0
	fi
	print_result "Co-temporality: missing created_at fails safe" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	printf '=== GH#20758 scanner-label + breaker-trip regression tests ===\n\n'

	# AC1: scanner-label + breaker trip → preserve NMR
	test_ac1_scanner_label_with_stale_recovery_breaker_preserves_nmr
	test_ac1_scanner_label_with_cost_breaker_preserves_nmr

	# AC2: scanner-label + NMR at creation (no breaker) → auto-approve
	test_ac2_scanner_label_nmr_at_creation_auto_approves
	test_ac2_review_followup_label_nmr_at_creation_auto_approves

	# AC3: scanner-label + late NMR (manual hold) → preserve
	test_ac3_scanner_label_late_nmr_no_breaker_preserves
	test_ac3_label_only_check_rejects_late_nmr

	# AC5: no_work_loop breaker on scanner-labelled issue → preserve
	test_ac5_no_work_loop_breaker_with_scanner_label_preserves

	# Order inversion verification
	test_order_inversion_breaker_wins_over_scanner_comment_marker

	# Co-temporality boundary tests
	test_cotemporality_at_300s_boundary_passes
	test_cotemporality_at_301s_boundary_fails
	test_cotemporality_missing_created_at_fails_safe

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
