#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for `_nmr_application_has_automation_signature` and
# `_nmr_application_is_circuit_breaker_trip` in pulse-nmr-approval.sh
# (GH#18671 / t2386).
#
# t2386 background: `_nmr_application_has_automation_signature` used to
# match BOTH creation-time defaults (source:review-scanner) AND
# circuit-breaker trip markers (stale-recovery-tick:escalated,
# cost-circuit-breaker:fired). That conflation meant
# `auto_approve_maintainer_issues` stripped NMR from breaker-tripped
# issues and re-dispatched the worker, producing the #19756 infinite
# loop (22 watchdog kills, 5 auto-approve cycles in one afternoon).
#
# Post-fix semantics:
#   - _nmr_application_has_automation_signature  →  matches ONLY trusted
#     automation defaults/provenance (scanner markers/labels and bounded
#     workflow reapplication markers). These can be auto-cleared after
#     reason, breaker, and security gates pass.
#   - _nmr_application_is_circuit_breaker_trip   →  matches ONLY
#     breaker trips (stale-recovery-tick:escalated,
#     cost-circuit-breaker:fired, dispatch-backoff:rate_limit_nmr,
#     dispatch-infrastructure-failure, circuit-breaker-escalated).
#     These MUST preserve NMR.

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

	# gh stub: serves comments from COMMENTS_FIXTURE, issue meta from
	# ISSUE_META_FIXTURE, and timeline events from TIMELINE_FIXTURE.
	# Handles the --jq filter by piping into real jq.
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
			--slurp) shift ;;
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
}
set_issue_meta() {
	local body="$1"
	printf '%s\n' "$body" >"$ISSUE_META_FIXTURE"
}
set_timeline() {
	local body="$1"
	printf '%s\n' "$body" >"$TIMELINE_FIXTURE"
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

# --- _nmr_application_has_automation_signature (creation defaults only) ---

test_signature_rejects_stale_recovery_marker() {
	# t2386: stale-recovery-tick:escalated is a BREAKER TRIP, not a
	# creation default. The signature function must return 1 so NMR is
	# preserved. Pre-t2386 this test asserted return 0 (the bug).
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature REJECTS stale-recovery:escalated marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS stale-recovery:escalated marker (t2386)" 0
	return 0
}

test_signature_rejects_cost_circuit_breaker_marker() {
	# t2386: same rationale as stale-recovery — breaker trip, not default.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\n🛑 Cost circuit breaker fired"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18640 marcusquinn/aidevops "2026-04-13T05:00:02Z"; then
		print_result "signature REJECTS cost-circuit-breaker:fired marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS cost-circuit-breaker:fired marker (t2386)" 0
	return 0
}

test_signature_rejects_circuit_breaker_escalated_marker() {
	# t2386: legacy fast-fail alias — also a breaker trip.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- circuit-breaker-escalated -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18641 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature REJECTS circuit-breaker-escalated marker (t2386)" 1 \
			"Expected exit 1 — breaker trip is not a creation-default signature"
		return 0
	fi
	print_result "signature REJECTS circuit-breaker-escalated marker (t2386)" 0
	return 0
}

test_signature_detects_source_review_scanner_comment_marker() {
	# The one comment marker that IS a creation default — scanner
	# posted this at issue creation, applying NMR by default.
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- source:review-scanner -->\nPost-merge review scan flagged potential regressions."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18622 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature detects source:review-scanner comment marker" 0
		return 0
	fi
	print_result "signature detects source:review-scanner comment marker" 1 \
		"Expected exit 0 — creation-default marker within window"
	return 0
}

test_signature_ignores_marker_outside_window() {
	# Comment 5 minutes after label event — outside the 60s window.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 18623 marcusquinn/aidevops "2026-04-13T05:05:00Z"; then
		print_result "signature ignores creation-default marker outside 60s window" 1 \
			"Expected exit 1 — comment is 5 minutes before label event"
		return 0
	fi
	print_result "signature ignores creation-default marker outside 60s window" 0
	return 0
}

test_signature_detects_review_followup_label_fallback() {
	# No adjacent comment — but the issue has review-followup label,
	# indicating bot-generated cleanup (GH#18538 default-NMR path).
	# GH#20758: created_at must be within 300s of label_at for the
	# co-temporality guard to pass.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"review-followup"},{"name":"auto-dispatch"}],"created_at":"2026-04-13T04:29:10Z"}'
	if _nmr_application_has_automation_signature 18539 marcusquinn/aidevops "2026-04-13T04:29:13Z"; then
		print_result "signature detects review-followup label as implicit default" 0
		return 0
	fi
	print_result "signature detects review-followup label as implicit default" 1
	return 0
}

test_signature_detects_source_review_scanner_label_fallback() {
	# GH#20758: created_at within 300s of label_at for co-temporality.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"source:review-scanner"}],"created_at":"2026-04-13T06:39:20Z"}'
	if _nmr_application_has_automation_signature 18621 marcusquinn/aidevops "2026-04-13T06:39:22Z"; then
		print_result "signature detects source:review-scanner label as implicit default" 0
		return 0
	fi
	print_result "signature detects source:review-scanner label as implicit default" 1
	return 0
}

test_signature_detects_source_review_feedback_label_fallback() {
	# t2686: quality-feedback-helper.sh emits source:review-feedback label,
	# NOT source:review-scanner. Before the fix the sig detector missed
	# this label entirely, stranding 10 issues on exampleorg/examplerepo.
	# GH#20758: created_at within 300s of label_at for co-temporality.
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"quality-debt"},{"name":"source:review-feedback"},{"name":"priority:high"}],"created_at":"2026-04-21T01:49:30Z"}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z"; then
		print_result "signature detects source:review-feedback label (t2686)" 0
		return 0
	fi
	print_result "signature detects source:review-feedback label (t2686)" 1 \
		"Expected exit 0 — source:review-feedback is a creation-default signature"
	return 0
}

test_signature_detects_quality_feedback_helper_comment_marker() {
	# t2686: the approval-instructions comment body contains the literal
	# string "quality-feedback-helper.sh" — defence-in-depth marker for
	# cases where the provenance label is stripped but the comment remains.
	# shellcheck disable=SC2016  # intentional: single quotes protect JSON literal with backticks
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- provenance:start — workers: skip this comment, it is for the maintainer not the implementer -->\nThis quality-debt issue was auto-generated by `quality-feedback-helper.sh scan-merged` from review feedback on PR #2391."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z"; then
		print_result "signature detects quality-feedback-helper.sh comment marker (t2686)" 0
		return 0
	fi
	print_result "signature detects quality-feedback-helper.sh comment marker (t2686)" 1 \
		"Expected exit 0 — approval-instructions marker within window"
	return 0
}

test_signature_detects_source_review_feedback_comment_marker() {
	# t2686: comment body contains source:review-feedback literally
	# (future-proofing — in case quality-feedback-helper.sh ever emits
	# a standalone marker comment like post-merge-review-scanner.sh does).
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- source:review-feedback -->\nQuality-debt batch from merged PR."}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z"; then
		print_result "signature detects source:review-feedback comment marker (t2686)" 0
		return 0
	fi
	print_result "signature detects source:review-feedback comment marker (t2686)" 1
	return 0
}

test_signature_detects_actions_label_protection_notice() {
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- label-protection-notice -->","user":{"login":"github-actions[bot]"}}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z" "github-actions[bot]"; then
		print_result "signature detects actions label-protection workflow residue" 0
		return 0
	fi
	print_result "signature detects actions label-protection workflow residue" 1
	return 0
}

test_signature_detects_actions_notice_on_later_page() {
	set_comments '[[{"created_at":"2026-04-21T01:49:38Z","body":"unrelated","user":{"login":"github-actions[bot]"}}],[{"created_at":"2026-04-21T01:49:40Z","body":"<!-- label-protection-notice -->","user":{"login":"github-actions[bot]"}}]]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z" "github-actions[bot]"; then
		print_result "signature detects workflow residue on later paginated page" 0
		return 0
	fi
	print_result "signature detects workflow residue on later paginated page" 1
	return 0
}

test_signature_rejects_external_label_protection_text() {
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- label-protection-notice -->","user":{"login":"external-contributor"}}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z" "github-actions[bot]"; then
		print_result "signature rejects attacker-copied label-protection text" 1
		return 0
	fi
	print_result "signature rejects attacker-copied label-protection text" 0
	return 0
}

test_signature_detects_same_actor_parent_escalation() {
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- parent-needs-decomposition-escalated -->","user":{"login":"runner"}}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z" runner; then
		print_result "signature detects historical same-actor parent escalation" 0
		return 0
	fi
	print_result "signature detects historical same-actor parent escalation" 1
	return 0
}

test_signature_rejects_other_actor_parent_escalation() {
	set_comments '[{"created_at":"2026-04-21T01:49:38Z","body":"<!-- parent-needs-decomposition-escalated -->","user":{"login":"external-contributor"}}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 2572 exampleorg/examplerepo "2026-04-21T01:49:36Z" runner; then
		print_result "signature rejects copied parent escalation from another actor" 1
		return 0
	fi
	print_result "signature rejects copied parent escalation from another actor" 0
	return 0
}

test_signature_ignores_unrelated_comment_in_window() {
	# Comment is in the window but has no automation marker.
	set_comments '[{"created_at":"2026-04-13T05:00:30Z","body":"Thanks for the heads up, I will take a look at this tomorrow morning."}]'
	set_issue_meta '{"labels":[{"name":"bug"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature ignores unrelated comment in window" 1 \
			"Expected exit 1 — no creation-default marker in body"
		return 0
	fi
	print_result "signature ignores unrelated comment in window" 0
	return 0
}

test_signature_detects_lower_bound_comment_before_label() {
	# Comment posted 3 seconds BEFORE the label event — within the -5s
	# lower bound. Covers the API-latency race where the comment goes
	# through faster than the label API call.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:03Z"; then
		print_result "signature detects creation-default 3s before label (lower bound)" 0
		return 0
	fi
	print_result "signature detects creation-default 3s before label (lower bound)" 1
	return 0
}

test_signature_empty_args_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[]}'
	if _nmr_application_has_automation_signature "" "" ""; then
		print_result "signature empty args returns exit 1" 1
		return 0
	fi
	print_result "signature empty args returns exit 1" 0
	return 0
}

test_signature_no_default_no_bot_label_returns_nonzero() {
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"bug"},{"name":"auto-dispatch"}]}'
	if _nmr_application_has_automation_signature 42 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "signature returns exit 1 on normal bug issue" 1
		return 0
	fi
	print_result "signature returns exit 1 on normal bug issue" 0
	return 0
}

# --- _nmr_application_is_circuit_breaker_trip (breaker trips only) ---

test_breaker_trip_detects_stale_recovery_escalation_marker() {
	# t2386: breaker-trip helper DOES match this — and the caller
	# routes it to "preserve NMR".
	set_comments '[{"created_at":"2026-04-13T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	if _nmr_application_is_circuit_breaker_trip 18623 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip detects stale-recovery:escalated marker" 0
		return 0
	fi
	print_result "breaker_trip detects stale-recovery:escalated marker" 1 \
		"Expected exit 0 — stale-recovery marker within window"
	return 0
}

test_breaker_trip_detects_cost_circuit_breaker_marker() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- cost-circuit-breaker:fired tier=standard spent=120000 budget=100000 -->\n🛑 Cost circuit breaker fired"}]'
	if _nmr_application_is_circuit_breaker_trip 18640 marcusquinn/aidevops "2026-04-13T05:00:02Z"; then
		print_result "breaker_trip detects cost-circuit-breaker:fired marker" 0
		return 0
	fi
	print_result "breaker_trip detects cost-circuit-breaker:fired marker" 1
	return 0
}

test_breaker_trip_detects_paginated_marker_on_later_page() {
	# GH paginates issue comments. Pre-fix, `gh api --paginate --jq` emitted one
	# count per page (for example "0\n1"), failed numeric coercion, and missed
	# breaker markers outside the first page — allowing repeated auto-approval
	# comments after a cost/no_work circuit breaker.
	set_comments '[[{"created_at":"2026-05-03T19:18:00Z","body":"regular earlier comment"}],[{"created_at":"2026-05-03T19:19:38Z","body":"<!-- cost-circuit-breaker:no_work_loop count=3 threshold=3 -->\nPer-issue no_work circuit breaker fired."}]]'
	if _nmr_application_is_circuit_breaker_trip 3778 exampleorg/examplerepo "2026-05-03T19:19:36Z"; then
		print_result "breaker_trip detects marker on later paginated page" 0
		return 0
	fi
	print_result "breaker_trip detects marker on later paginated page" 1 \
		"Expected exit 0 — paginated breaker marker within window must preserve NMR"
	return 0
}

test_breaker_trip_detects_legacy_escalated_marker() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- circuit-breaker-escalated -->"}]'
	if _nmr_application_is_circuit_breaker_trip 18641 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip detects circuit-breaker-escalated legacy alias" 0
		return 0
	fi
	print_result "breaker_trip detects circuit-breaker-escalated legacy alias" 1
	return 0
}

test_breaker_trip_detects_rate_limit_nmr_marker() {
	# example-repo #4319/#4269: rate-limit NMR is a capacity breaker, not a
	# creation default. Auto-approval must preserve it until capacity recovers.
	set_comments '[{"created_at":"2026-05-06T11:42:06Z","body":"<!-- dispatch-backoff:rate_limit_nmr -->\n## Rate-Limit Backoff Circuit Breaker (t2781)"}]'
	if _nmr_application_is_circuit_breaker_trip 4319 exampleorg/examplerepo "2026-05-06T11:42:04Z"; then
		print_result "breaker_trip detects rate-limit NMR marker" 0
		return 0
	fi
	print_result "breaker_trip detects rate-limit NMR marker" 1 \
		"Expected exit 0 — rate-limit breaker must preserve NMR"
	return 0
}

test_breaker_trip_detects_dispatch_infrastructure_marker() {
	# example-repo #4246/#4248 class: repeated zero-output worker launches are an
	# infrastructure hold, not evidence that an actionable brief is bad.
	set_comments '[{"created_at":"2026-05-06T10:09:29Z","body":"<!-- dispatch-infrastructure-failure -->\n## Dispatch infrastructure failure detected"}]'
	if _nmr_application_is_circuit_breaker_trip 4246 exampleorg/examplerepo "2026-05-06T10:09:27Z"; then
		print_result "breaker_trip detects dispatch infrastructure marker" 0
		return 0
	fi
	print_result "breaker_trip detects dispatch infrastructure marker" 1 \
		"Expected exit 0 — infrastructure breaker must preserve NMR"
	return 0
}

test_breaker_trip_rejects_source_review_scanner_marker() {
	# Creation-default marker is NOT a breaker trip.
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- source:review-scanner -->"}]'
	if _nmr_application_is_circuit_breaker_trip 18621 marcusquinn/aidevops "2026-04-13T05:00:00Z"; then
		print_result "breaker_trip REJECTS source:review-scanner marker" 1 \
			"Expected exit 1 — creation default is not a breaker trip"
		return 0
	fi
	print_result "breaker_trip REJECTS source:review-scanner marker" 0
	return 0
}

test_breaker_trip_ignores_marker_outside_window() {
	set_comments '[{"created_at":"2026-04-13T05:00:00Z","body":"<!-- stale-recovery-tick:escalated -->"}]'
	if _nmr_application_is_circuit_breaker_trip 42 marcusquinn/aidevops "2026-04-13T05:05:00Z"; then
		print_result "breaker_trip ignores marker outside 60s window" 1 \
			"Expected exit 1 — comment is 5 minutes before label event"
		return 0
	fi
	print_result "breaker_trip ignores marker outside 60s window" 0
	return 0
}

test_breaker_trip_empty_args_returns_nonzero() {
	set_comments '[]'
	if _nmr_application_is_circuit_breaker_trip "" "" ""; then
		print_result "breaker_trip empty args returns exit 1" 1
		return 0
	fi
	print_result "breaker_trip empty args returns exit 1" 0
	return 0
}

test_breaker_history_detects_prior_worker_recovery_marker() {
	set_comments '[{"created_at":"2026-07-04T05:07:55Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n---\n[aidevops.sh](https://aidevops.sh) v3.31.49 automated scan."},{"created_at":"2026-07-04T13:50:31Z","body":"<!-- aidevops-signed-approval -->\nAuto-approved: maintainer is author, NMR applied by automation.\n---\n[aidevops.sh](https://aidevops.sh) v3.31.50 automated scan."}]'
	if _nmr_application_has_breaker_history 8337 exampleorg/examplerepo "2026-07-04T13:54:57Z"; then
		print_result "breaker_history detects prior worker_recovery_loop marker" 0
		return 0
	fi
	print_result "breaker_history detects prior worker_recovery_loop marker" 1 \
		"Expected exit 0 — marker-less NMR relabel still belongs to the breaker episode"
	return 0
}

test_breaker_history_ignores_future_marker() {
	set_comments '[{"created_at":"2026-07-04T14:00:00Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->"}]'
	if _nmr_application_has_breaker_history 8337 exampleorg/examplerepo "2026-07-04T13:00:00Z"; then
		print_result "breaker_history ignores marker after latest NMR" 1 \
			"Expected exit 1 — future markers must not classify an earlier NMR event"
		return 0
	fi
	print_result "breaker_history ignores marker after latest NMR" 0
	return 0
}

# --- _nmr_application_is_security_sensitive (security review boundary) ---

test_security_sensitive_detects_security_label() {
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"security"},{"name":"source:review-feedback"}]}'
	if _nmr_application_is_security_sensitive 24841 marcusquinn/aidevops; then
		print_result "security_sensitive detects security label" 0
		return 0
	fi
	print_result "security_sensitive detects security label" 1 \
		"Expected exit 0 — security label must preserve NMR"
	return 0
}

test_security_sensitive_detects_security_review_label() {
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"security-review"}]}'
	if _nmr_application_is_security_sensitive 24842 marcusquinn/aidevops; then
		print_result "security_sensitive detects security-review label" 0
		return 0
	fi
	print_result "security_sensitive detects security-review label" 1 \
		"Expected exit 0 — security-review label must preserve NMR"
	return 0
}

test_security_sensitive_uses_precomputed_issue_meta() {
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"quality-debt"}]}'
	if _nmr_application_is_security_sensitive 24842 marcusquinn/aidevops \
		'{"labels":[{"name":"needs-maintainer-review"},{"name":"security"}]}'; then
		print_result "security_sensitive uses precomputed issue metadata" 0
		return 0
	fi
	print_result "security_sensitive uses precomputed issue metadata" 1 \
		"Expected exit 0 — supplied issue metadata should avoid fixture/API fallback"
	return 0
}

test_security_sensitive_ignores_non_security_labels() {
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"source:review-feedback"},{"name":"quality-debt"}]}'
	if _nmr_application_is_security_sensitive 24843 marcusquinn/aidevops; then
		print_result "security_sensitive ignores non-security labels" 1 \
			"Expected exit 1 — normal review-feedback issues can still use creation-default auto-approval"
		return 0
	fi
	print_result "security_sensitive ignores non-security labels" 0
	return 0
}

# --- _nmr_applied_by_maintainer end-to-end (#19756 loop regression) ---

test_19756_loop_prevention_breaker_trip_preserves_nmr() {
	# The #19756 scenario: pulse applies NMR via stale-recovery breaker.
	# Timeline actor is the maintainer (pulse runs as maintainer token).
	# Without the t2386 fix, _nmr_applied_by_maintainer returned 1
	# (automation-applied → auto-approve OK), and auto_approve stripped
	# NMR + re-dispatched, producing the infinite loop. Post-fix:
	# breaker-trip signature routes to return 0 (preserve NMR).
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[{"created_at":"2026-04-19T05:00:02Z","body":"<!-- stale-recovery-tick:escalated (threshold=2) -->\n**Stale recovery threshold reached** (t2008)"}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"}]}'
	if _nmr_applied_by_maintainer 19756 marcusquinn/aidevops marcusquinn; then
		print_result "t2386 #19756 loop prevention: breaker trip preserves NMR" 0
		return 0
	fi
	print_result "t2386 #19756 loop prevention: breaker trip preserves NMR" 1 \
		"Expected exit 0 — circuit breaker trip MUST preserve NMR (auto-approve loop bug)"
	return 0
}

test_scanner_default_still_auto_approves() {
	# Positive control: creation defaults still get auto-approved so
	# scanner-filed issues can enter dispatch normally.
	# GH#20758: created_at within 300s of NMR label event for co-temporality.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"source:review-scanner"}],"created_at":"2026-04-19T04:59:55Z"}'
	if _nmr_applied_by_maintainer 18539 marcusquinn/aidevops marcusquinn; then
		print_result "scanner-default issue still auto-approves (no regression)" 1 \
			"Expected exit 1 — creation-default signature should allow auto-approve"
		return 0
	fi
	print_result "scanner-default issue still auto-approves (no regression)" 0
	return 0
}

test_security_review_feedback_preserves_nmr() {
	# Security-labelled review-feedback issues are still automation-created, but
	# the security label makes NMR a real approval boundary. Without this guard,
	# source:review-feedback would be treated as a creation default and cleared.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-06-15T18:00:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"source:review-feedback"},{"name":"security"}],"created_at":"2026-06-15T17:59:57Z"}'
	if _nmr_applied_by_maintainer 24841 marcusquinn/aidevops marcusquinn; then
		print_result "security review-feedback issue preserves NMR" 0
		return 0
	fi
	print_result "security review-feedback issue preserves NMR" 1 \
		"Expected exit 0 — security findings require cryptographic approval, not auto-clear"
	return 0
}

test_manual_hold_still_preserves_nmr() {
	# No signature of any kind — genuine manual hold. Must preserve NMR.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[{"created_at":"2026-04-19T05:00:30Z","body":"Holding this pending architecture discussion."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"bug"}]}'
	if _nmr_applied_by_maintainer 42 marcusquinn/aidevops marcusquinn; then
		print_result "manual maintainer hold still preserves NMR" 0
		return 0
	fi
	print_result "manual maintainer hold still preserves NMR" 1 \
		"Expected exit 0 — no automation signature, this is a manual hold"
	return 0
}

test_non_maintainer_label_actor_is_not_manual_maintainer_hold() {
	# This helper only classifies the latest NMR label event, not issue-author
	# trust. A non-maintainer label actor is not a manual hold by the configured
	# maintainer, so the helper returns 1. `auto_approve_maintainer_issues` still
	# separately requires the issue AUTHOR to be the maintainer (or a crypto
	# approval) before it can clear NMR.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"external-contributor"},"created_at":"2026-04-19T05:00:00Z"}]'
	set_comments '[]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"}]}'
	if _nmr_applied_by_maintainer 99 marcusquinn/aidevops marcusquinn; then
		print_result "non-maintainer label actor is not manual maintainer hold" 1 \
			"Expected exit 1 — non-maintainer actor is not a manual hold"
		return 0
	fi
	print_result "non-maintainer label actor is not manual maintainer hold" 0
	return 0
}

test_peer_runner_breaker_trip_preserves_nmr() {
	# Private-project incident pattern: a peer maintainer/member runner applies NMR as part
	# of a dispatch-infrastructure breaker. The actor is not the configured owner
	# token, but the breaker marker is authoritative and must prevent maintainer
	# auto-approval from clearing NMR and re-dispatching into the same loop.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"peer-runner"},"created_at":"2026-05-06T16:54:57Z"}]'
	set_comments '[{"created_at":"2026-05-06T16:54:59Z","body":"<!-- dispatch-infrastructure-failure -->\n## Dispatch infrastructure failure detected\nThis issue has accumulated 9 zero-output worker launches."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	if _nmr_applied_by_maintainer 4248 owner/repo owner-runner; then
		print_result "peer runner breaker trip preserves NMR" 0
		return 0
	fi
	print_result "peer runner breaker trip preserves NMR" 1 \
		"Expected exit 0 — breaker marker must preserve NMR regardless of actor"
	return 0
}

test_paginated_timeline_latest_nmr_event_preserves_breaker_trip() {
	# Long-lived issues can paginate timeline events. The latest NMR event can be on
	# a later page; _nmr_applied_by_maintainer must flatten slurped pages before
	# extracting nmr_at so breaker detection receives one valid ISO8601 timestamp.
	set_timeline '[[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-05-06T10:00:00Z"}],[{"event":"unlabeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-05-06T10:05:00Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"peer-runner"},"created_at":"2026-05-06T16:54:57Z"}]]'
	set_comments '[{"created_at":"2026-05-06T16:54:59Z","body":"<!-- dispatch-infrastructure-failure -->\n## Dispatch infrastructure failure detected"}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	if _nmr_applied_by_maintainer 4249 owner/repo owner-runner; then
		print_result "paginated timeline latest NMR event preserves breaker trip" 0
		return 0
	fi
	print_result "paginated timeline latest NMR event preserves breaker trip" 1 \
		"Expected exit 0 — slurped timeline pages must flatten before extracting latest NMR"
	return 0
}

test_release_upgrade_allows_rate_limit_breaker_retry() {
	# Outlier recovery: a rate-limit/capacity breaker from an older aidevops
	# release should be allowed one fresh retry after a newer release lands.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-05-07T21:26:05Z"}]'
	set_comments '[{"created_at":"2026-05-07T21:26:06Z","body":"<!-- dispatch-backoff:rate_limit_nmr -->\n## Rate-Limit Backoff Circuit Breaker (t2781)\n---\n[aidevops.sh](https://aidevops.sh) v3.14.91 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.14.94
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	if _nmr_applied_by_maintainer 4508 exampleorg/examplerepo marcusquinn; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "release upgrade allows automated rate-limit breaker retry" 1 \
			"Expected exit 1 — newer aidevops release should permit auto-approval retry"
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	print_result "release upgrade allows automated rate-limit breaker retry" 0
	return 0
}

test_same_release_preserves_rate_limit_breaker_nmr() {
	# The release gate must not defeat #19756-style breaker preservation when
	# no newer aidevops release is available and cooldown has not expired.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-05-07T21:26:05Z"}]'
	set_comments '[{"created_at":"2026-05-07T21:26:06Z","body":"<!-- dispatch-backoff:rate_limit_nmr -->\n## Rate-Limit Backoff Circuit Breaker (t2781)\n---\n[aidevops.sh](https://aidevops.sh) v3.14.94 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.14.94
	AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS=999999999
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	export AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
	if _nmr_applied_by_maintainer 4508 exampleorg/examplerepo marcusquinn; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		unset AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
		print_result "same release preserves rate-limit breaker NMR" 0
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	unset AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
	print_result "same release preserves rate-limit breaker NMR" 1 \
		"Expected exit 0 — same-version breaker still requires approval"
	return 0
}

test_rate_limit_cooldown_allows_retry() {
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"marcusquinn"},"created_at":"2026-05-07T21:26:05Z"}]'
	set_comments '[{"created_at":"2026-05-07T21:26:06Z","body":"<!-- dispatch-backoff:rate_limit_nmr -->\n## Rate-Limit Backoff Circuit Breaker (t2781)\n---\n[aidevops.sh](https://aidevops.sh) v3.14.94 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.14.94
	AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS=1
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	export AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
	if _nmr_applied_by_maintainer 4508 exampleorg/examplerepo marcusquinn; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		unset AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
		print_result "expired rate-limit cooldown allows retry" 1 \
			"Expected exit 1 — expired rate-limit cooldown should permit auto-approval retry"
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	unset AIDEVOPS_RATE_LIMIT_NMR_AUTO_RETRY_SECONDS
	print_result "expired rate-limit cooldown allows retry" 0
	return 0
}

test_markerless_relabel_after_recovery_breaker_preserves_same_release() {
	# Incident class: a recovery-loop breaker posts the marker, an auto-approval
	# retry relaunches a worker, then the issue is relabeled NMR without reposting
	# the breaker marker. The latest label actor may be a peer runner, so actor-only
	# logic would auto-clear NMR again and burn another worker.
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T05:07:53Z"},{"event":"unlabeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-b"},"created_at":"2026-07-04T13:50:33Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T13:54:57Z"}]'
	set_comments '[{"created_at":"2026-07-04T05:07:55Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n---\n[aidevops.sh](https://aidevops.sh) v3.31.54 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.31.54
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	if _nmr_applied_by_maintainer 8337 exampleorg/examplerepo maintainer; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "marker-less recovery relabel preserves same-release NMR" 0
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	print_result "marker-less recovery relabel preserves same-release NMR" 1 \
		"Expected exit 0 — prior recovery breaker must preserve NMR even when latest label lacks a marker"
	return 0
}

test_markerless_relabel_after_recovery_breaker_allows_upgrade_retry() {
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T05:07:53Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T13:54:57Z"}]'
	set_comments '[{"created_at":"2026-07-04T05:07:55Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n---\n[aidevops.sh](https://aidevops.sh) v3.31.49 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.31.54
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	if _nmr_applied_by_maintainer 8337 exampleorg/examplerepo maintainer; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "marker-less recovery relabel allows one upgraded retry" 1 \
			"Expected exit 1 — newer aidevops release should permit exactly one retry"
		return 0
	fi
	if [[ "${_NMR_AUTO_APPROVAL_REASON_OVERRIDE:-}" != *"3.31.49 -> 3.31.54"* ]]; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "marker-less recovery relabel records upgraded retry reason" 1 \
			"Expected override reason to mention the breaker and current versions"
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	print_result "marker-less recovery relabel allows one upgraded retry" 0
	return 0
}

test_markerless_relabel_after_recovery_breaker_retry_is_once_per_release() {
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T05:07:53Z"},{"event":"unlabeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-b"},"created_at":"2026-07-04T13:50:33Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T13:54:57Z"}]'
	set_comments '[{"created_at":"2026-07-04T05:07:55Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n---\n[aidevops.sh](https://aidevops.sh) v3.31.49 automated scan."},{"created_at":"2026-07-04T13:50:31Z","body":"<!-- aidevops-signed-approval -->\nAuto-approved: automated breaker retry allowed after aidevops upgrade 3.31.49 -> 3.31.54.\n---\n[aidevops.sh](https://aidevops.sh) v3.31.54 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.31.54
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	if _nmr_applied_by_maintainer 8337 exampleorg/examplerepo maintainer; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "marker-less recovery relabel retry is once per release" 0
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	print_result "marker-less recovery relabel retry is once per release" 1 \
		"Expected exit 0 — same release already retried after the breaker marker"
	return 0
}

test_markerless_relabel_after_recovery_breaker_retry_is_once_per_episode() {
	set_timeline '[{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T05:07:53Z"},{"event":"unlabeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-b"},"created_at":"2026-07-04T13:50:33Z"},{"event":"labeled","label":{"name":"needs-maintainer-review"},"actor":{"login":"runner-a"},"created_at":"2026-07-04T13:54:57Z"}]'
	set_comments '[{"created_at":"2026-07-04T05:07:55Z","body":"<!-- dispatch-circuit-breaker:worker_recovery_loop -->\n## Dispatch paused: repeated worker recovery failures\n---\n[aidevops.sh](https://aidevops.sh) v3.31.49 automated scan."},{"created_at":"2026-07-04T13:50:31Z","body":"<!-- aidevops-signed-approval -->\nAuto-approved: automated breaker retry allowed after aidevops upgrade 3.31.49 -> 3.31.54.\n---\n[aidevops.sh](https://aidevops.sh) v3.31.54 automated scan."}]'
	set_issue_meta '{"labels":[{"name":"needs-maintainer-review"},{"name":"origin:worker"},{"name":"auto-dispatch"}]}'
	AIDEVOPS_CURRENT_VERSION_OVERRIDE=3.31.62
	export AIDEVOPS_CURRENT_VERSION_OVERRIDE
	if _nmr_applied_by_maintainer 8337 exampleorg/examplerepo maintainer; then
		unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
		print_result "marker-less recovery relabel retry is once per breaker episode" 0
		return 0
	fi
	unset AIDEVOPS_CURRENT_VERSION_OVERRIDE
	print_result "marker-less recovery relabel retry is once per breaker episode" 1 \
		"Expected exit 0 — a later unrelated patch release must not retry the same unresolved breaker episode"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	if ! define_helpers_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	# _nmr_application_has_automation_signature (trusted automation only)
	test_signature_rejects_stale_recovery_marker
	test_signature_rejects_cost_circuit_breaker_marker
	test_signature_rejects_circuit_breaker_escalated_marker
	test_signature_detects_source_review_scanner_comment_marker
	test_signature_ignores_marker_outside_window
	test_signature_detects_review_followup_label_fallback
	test_signature_detects_source_review_scanner_label_fallback
	test_signature_detects_source_review_feedback_label_fallback
	test_signature_detects_quality_feedback_helper_comment_marker
	test_signature_detects_source_review_feedback_comment_marker
	test_signature_detects_actions_label_protection_notice
	test_signature_detects_actions_notice_on_later_page
	test_signature_rejects_external_label_protection_text
	test_signature_detects_same_actor_parent_escalation
	test_signature_rejects_other_actor_parent_escalation
	test_signature_ignores_unrelated_comment_in_window
	test_signature_detects_lower_bound_comment_before_label
	test_signature_empty_args_returns_nonzero
	test_signature_no_default_no_bot_label_returns_nonzero

	# _nmr_application_is_circuit_breaker_trip (breaker trips only)
	test_breaker_trip_detects_stale_recovery_escalation_marker
	test_breaker_trip_detects_cost_circuit_breaker_marker
	test_breaker_trip_detects_paginated_marker_on_later_page
	test_breaker_trip_detects_legacy_escalated_marker
	test_breaker_trip_detects_rate_limit_nmr_marker
	test_breaker_trip_detects_dispatch_infrastructure_marker
	test_breaker_trip_rejects_source_review_scanner_marker
	test_breaker_trip_ignores_marker_outside_window
	test_breaker_trip_empty_args_returns_nonzero
	test_breaker_history_detects_prior_worker_recovery_marker
	test_breaker_history_ignores_future_marker

	# _nmr_application_is_security_sensitive (security review boundary)
	test_security_sensitive_detects_security_label
	test_security_sensitive_detects_security_review_label
	test_security_sensitive_uses_precomputed_issue_meta
	test_security_sensitive_ignores_non_security_labels

	# _nmr_applied_by_maintainer end-to-end (#19756 loop regression)
	test_19756_loop_prevention_breaker_trip_preserves_nmr
	test_scanner_default_still_auto_approves
	test_security_review_feedback_preserves_nmr
	test_manual_hold_still_preserves_nmr
	test_non_maintainer_label_actor_is_not_manual_maintainer_hold
	test_peer_runner_breaker_trip_preserves_nmr
	test_paginated_timeline_latest_nmr_event_preserves_breaker_trip
	test_release_upgrade_allows_rate_limit_breaker_retry
	test_same_release_preserves_rate_limit_breaker_nmr
	test_rate_limit_cooldown_allows_retry
	test_markerless_relabel_after_recovery_breaker_preserves_same_release
	test_markerless_relabel_after_recovery_breaker_allows_upgrade_retry
	test_markerless_relabel_after_recovery_breaker_retry_is_once_per_release
	test_markerless_relabel_after_recovery_breaker_retry_is_once_per_episode

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
