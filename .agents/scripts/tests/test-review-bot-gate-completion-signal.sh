#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-review-bot-gate-completion-signal.sh — Regression tests for t2139 (GH#19251)
#
# Verifies that bot_has_real_review() requires a positive completion signal
# and rejects:
#   1. CodeRabbit two-phase placeholder (created_at == updated_at, recent)
#   2. "Review failed" notices (closed-during-review)
#   3. "Review skipped" notices (auto-review label config)
#   4. "closed or merged during review" patterns
#   5. Provider retirement notices with no review content
#   6. Empty bodies
#
# And accepts:
#   7. Comments edited > min_lag after creation (Phase 2 settled)
#   8. Comments older than min_lag (no edit needed — bot had time to finish)
#   9. Real review content with no non-review-pattern match
#
# Plus unit tests on _comment_is_settled, is_non_review_comment, and
# _get_min_edit_lag direct invocations (no gh stubbing needed).
#
# Requires: bash, jq (matches helper requirements), date.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER_SCRIPT="${SCRIPT_DIR}/../review-bot-gate-helper.sh"

if [[ ! -f "$HELPER_SCRIPT" ]]; then
	echo "ERROR: helper not found at ${HELPER_SCRIPT}" >&2
	exit 2
fi

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'
readonly GEMINI_SUNSET_NOTICE='The consumer version of Gemini Code Assist on GitHub has been sunset. All code review activity has officially ceased.'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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
	mkdir -p "${TEST_ROOT}/config/aidevops"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export HOME="${TEST_ROOT}"
	# This suite exercises the legacy direct-query classifiers with narrow gh
	# stubs. Snapshot request counts and freshness have a dedicated regression.
	export REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE=1
	mkdir -p "${TEST_ROOT}/.config/aidevops"

	# Minimal repos.json for resolver tests
	cat >"${TEST_ROOT}/.config/aidevops/repos.json" <<'EOF'
{
  "initialized_repos": [
    {
      "path": "/tmp/testrepo",
      "slug": "testorg/testrepo",
      "pulse": true,
      "review_gate": {
        "min_edit_lag_seconds": 45,
        "tools": {
          "coderabbitai": { "min_edit_lag_seconds": 90 }
        }
      }
    },
    {
      "path": "/tmp/waitrepo",
      "slug": "testorg/waitrepo",
      "pulse": true,
      "review_gate": {
        "rate_limit_behavior": "wait"
      }
    },
    {
      "path": "/tmp/toolstrictrepo",
      "slug": "testorg/toolstrictrepo",
      "pulse": true,
      "review_gate": {
        "tools": {
          "coderabbitai": { "completion_behavior": "strict" }
        }
      }
    },
    {
      "path": "/tmp/retiredtoolstrictrepo",
      "slug": "testorg/retiredtoolstrictrepo",
      "pulse": true,
      "review_gate": {
        "tools": {
          "gemini-code-assist": {
            "rate_limit_behavior": "wait",
            "completion_behavior": "strict"
          }
        }
      }
    },
    {
      "path": "/tmp/otherrepo",
      "slug": "testorg/otherrepo",
      "pulse": true
    },
    {
      "path": "/tmp/strictrepo",
      "slug": "testorg/strictrepo",
      "pulse": true,
      "review_gate": {
        "completion_behavior": "strict"
      }
    }
  ]
}
EOF
	return 0
}

cleanup_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Run a function from the helper without invoking main(). Source it with
# main() short-circuited.
load_helper_functions() {
	# shellcheck disable=SC1090
	# Trick: source the helper but make main() a no-op so it doesn't error.
	# We strip the trailing 'main "$@"' invocation by sourcing in a subshell
	# alternative — actually, the helper has `main "$@"` at the end which
	# would execute. We override main BEFORE sourcing? No — sourcing runs
	# top-level immediately. Solution: source via a temp file with the last
	# `main "$@"` line removed.
	local tmpfile
	tmpfile=$(mktemp)
	# Drop the final main invocation line using grep for robustness.
	grep -v '^main "\$@"' "$HELPER_SCRIPT" >"$tmpfile"
	# shellcheck disable=SC1090
	source "$tmpfile"
	rm -f "$tmpfile"
	return 0
}

# ---------- Unit tests: pattern matching ----------

test_is_non_review_comment_matches_rate_limit() {
	if is_non_review_comment "Review skipped due to rate limit exceeded for this hour"; then
		print_result "is_non_review_comment matches 'rate limit exceeded'" 0
	else
		print_result "is_non_review_comment matches 'rate limit exceeded'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_review_failed() {
	if is_non_review_comment "Review failed — Pull request was closed or merged during review."; then
		print_result "is_non_review_comment matches 'Review failed'" 0
	else
		print_result "is_non_review_comment matches 'Review failed'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_review_skipped() {
	if is_non_review_comment "Review skipped — Auto reviews are limited based on label configuration."; then
		print_result "is_non_review_comment matches 'Review skipped'" 0
	else
		print_result "is_non_review_comment matches 'Review skipped'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_closed_during_review() {
	if is_non_review_comment "The pull request is closed or merged during review."; then
		print_result "is_non_review_comment matches 'closed or merged during review'" 0
	else
		print_result "is_non_review_comment matches 'closed or merged during review'" 1
	fi
	return 0
}

test_is_non_review_comment_matches_gemini_sunset_notice() {
	if is_non_review_comment "$GEMINI_SUNSET_NOTICE"; then
		print_result "is_non_review_comment matches Gemini Code Assist sunset notice" 0
	else
		print_result "is_non_review_comment matches Gemini Code Assist sunset notice" 1
	fi
	return 0
}

test_is_non_review_comment_rejects_real_review() {
	local body="## Walkthrough

This PR refactors the foo() function to handle the bar edge case.
Recommended changes: add a null check before line 42."
	if ! is_non_review_comment "$body"; then
		print_result "is_non_review_comment rejects real review body" 0
	else
		print_result "is_non_review_comment rejects real review body" 1
	fi
	return 0
}

test_event_check_accepts_trusted_inline_bot_review() {
	local output=""
	if output=$(REVIEW_GATE_EVENT_NAME=pull_request_review_comment \
		REVIEW_GATE_EVENT_ACTION=created \
		REVIEW_GATE_EVENT_ACTOR='gemini-code-assist[bot]' \
		REVIEW_GATE_EVENT_BODY='Thank you. The finding is resolved.' \
		REVIEW_GATE_EVIDENCE_HEAD_SHA='head-123' \
		REVIEW_GATE_EXPECTED_HEAD_SHA='head-123' \
		do_event_check); then
		[[ "$output" == "PASS" ]] && print_result "event-check accepts trusted inline bot evidence" 0 && return 0
	fi
	print_result "event-check accepts trusted inline bot evidence" 1 "output=${output}"
	return 0
}

test_event_check_rejects_human_inline_reply() {
	local output="" status=0
	output=$(REVIEW_GATE_EVENT_NAME=pull_request_review_comment \
		REVIEW_GATE_EVENT_ACTION=created \
		REVIEW_GATE_EVENT_ACTOR='maintainer' \
		REVIEW_GATE_EVENT_BODY='Addressed in the latest commit.' \
		REVIEW_GATE_EVIDENCE_HEAD_SHA='head-123' \
		REVIEW_GATE_EXPECTED_HEAD_SHA='head-123' \
		do_event_check) || status=$?
	if [[ "$status" -eq 1 && "$output" == "NOT_APPLICABLE" ]]; then
		print_result "event-check rejects human inline replies" 0
	else
		print_result "event-check rejects human inline replies" 1 "status=${status} output=${output}"
	fi
	return 0
}

test_event_check_rejects_bot_failure_notice() {
	local output="" status=0
	output=$(REVIEW_GATE_EVENT_NAME=pull_request_review_comment \
		REVIEW_GATE_EVENT_ACTION=created \
		REVIEW_GATE_EVENT_ACTOR='coderabbitai' \
		REVIEW_GATE_EVENT_BODY='Review failed due to an internal error.' \
		REVIEW_GATE_EVIDENCE_HEAD_SHA='head-123' \
		REVIEW_GATE_EXPECTED_HEAD_SHA='head-123' \
		do_event_check) || status=$?
	if [[ "$status" -eq 1 && "$output" == "NOT_APPLICABLE" ]]; then
		print_result "event-check rejects bot failure notices" 0
	else
		print_result "event-check rejects bot failure notices" 1 "status=${status} output=${output}"
	fi
	return 0
}

test_event_check_rejects_bot_sunset_notice() {
	local output="" status=0
	output=$(REVIEW_GATE_EVENT_NAME=pull_request_review_comment \
		REVIEW_GATE_EVENT_ACTION=created \
		REVIEW_GATE_EVENT_ACTOR='gemini-code-assist[bot]' \
		REVIEW_GATE_EVENT_BODY="$GEMINI_SUNSET_NOTICE" \
		REVIEW_GATE_EVIDENCE_HEAD_SHA='head-123' \
		REVIEW_GATE_EXPECTED_HEAD_SHA='head-123' \
		do_event_check) || status=$?
	if [[ "$status" -eq 1 && "$output" == "NOT_APPLICABLE" ]]; then
		print_result "event-check rejects Gemini Code Assist sunset notices" 0
	else
		print_result "event-check rejects Gemini Code Assist sunset notices" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_event_check_rejects_stale_head_evidence() {
	local output="" status=0
	output=$(REVIEW_GATE_EVENT_NAME=pull_request_review_comment \
		REVIEW_GATE_EVENT_ACTION=created \
		REVIEW_GATE_EVENT_ACTOR='gemini-code-assist[bot]' \
		REVIEW_GATE_EVENT_BODY='A substantive inline finding.' \
		REVIEW_GATE_EVIDENCE_HEAD_SHA='old-head' \
		REVIEW_GATE_EXPECTED_HEAD_SHA='current-head' \
		do_event_check) || status=$?
	if [[ "$status" -eq 1 && "$output" == "NOT_APPLICABLE" ]]; then
		print_result "event-check rejects stale-head bot evidence" 0
	else
		print_result "event-check rejects stale-head bot evidence" 1 "status=${status} output=${output}"
	fi
	return 0
}

test_self_caller_uses_pr_head_helper_ref() {
	local caller="${SCRIPT_DIR}/../../../.github/workflows/review-bot-gate.yml"
	if grep -Fq "aidevops_ref: \${{ github.event.pull_request.head.sha || 'main' }}" "$caller"; then
		print_result "self-caller validates the PR-head helper revision" 0
	else
		print_result "self-caller validates the PR-head helper revision" 1 "caller=${caller}"
	fi
	return 0
}

test_callers_expose_explicit_ci_strict_opt_in() {
	local caller="${SCRIPT_DIR}/../../../.github/workflows/review-bot-gate.yml"
	local template="${SCRIPT_DIR}/../../templates/workflows/review-bot-gate-caller.yml"
	local policy_line="completion_behavior: \${{ vars.AIDEVOPS_REVIEW_GATE_COMPLETION_BEHAVIOR || 'fast' }}"
	if grep -Fq "$policy_line" "$caller" && grep -Fq "$policy_line" "$template"; then
		print_result "review-gate callers expose explicit CI strict opt-in" 0
	else
		print_result "review-gate callers expose explicit CI strict opt-in" 1
	fi
	return 0
}

test_infra_rate_limit_passes_trusted_default_policy() {
	local output
	output=$(classify_infra_rate_limit "MEMBER" "testorg/otherrepo")
	if [[ "$output" == "PASS_ADVISORY" ]]; then
		print_result "API exhaustion delegates to trusted advisory-default policy" 0
	else
		print_result "API exhaustion delegates to trusted advisory-default policy" 1 "output=${output}"
	fi
	return 0
}

test_infra_rate_limit_blocks_external_author() {
	local output
	output=$(classify_infra_rate_limit "CONTRIBUTOR" "testorg/otherrepo")
	if [[ "$output" == "INFRA_RATE_LIMITED" ]]; then
		print_result "API exhaustion fails closed for external authors" 0
	else
		print_result "API exhaustion fails closed for external authors" 1 "output=${output}"
	fi
	return 0
}

test_infra_rate_limit_blocks_explicit_wait_or_strict_policy() {
	local wait_output strict_output tool_strict_output
	wait_output=$(classify_infra_rate_limit "OWNER" "testorg/waitrepo")
	strict_output=$(classify_infra_rate_limit "OWNER" "testorg/strictrepo")
	tool_strict_output=$(classify_infra_rate_limit "OWNER" "testorg/toolstrictrepo")
	if [[ "$wait_output" == "INFRA_RATE_LIMITED" && "$strict_output" == "INFRA_RATE_LIMITED" && "$tool_strict_output" == "INFRA_RATE_LIMITED" ]]; then
		print_result "API exhaustion honors explicit wait and strict policies" 0
	else
		print_result "API exhaustion honors explicit wait and strict policies" 1 \
			"wait=${wait_output} strict=${strict_output} tool_strict=${tool_strict_output}"
	fi
	return 0
}

test_infra_rate_limit_ignores_retired_tool_policy() {
	local output
	output=$(classify_infra_rate_limit "OWNER" "testorg/retiredtoolstrictrepo")
	if [[ "$output" == "PASS_ADVISORY" ]]; then
		print_result "API exhaustion ignores retired per-tool wait/strict policy" 0
	else
		print_result "API exhaustion ignores retired per-tool wait/strict policy" 1 "output=${output}"
	fi
	return 0
}

# t2799: is_rate_limit_only_comment matches the narrow 6-entry rate-limit set
# only — NOT the broader non-review patterns ("Review failed", "Review
# skipped", etc.). Used by grace-period logic where the semantic distinction
# matters: a rate-limited bot may recover, a "Review skipped" bot will not.
test_is_rate_limit_only_matches_rate_limit() {
	if is_rate_limit_only_comment "Review skipped due to rate limit exceeded for this hour"; then
		print_result "is_rate_limit_only_comment matches 'rate limit exceeded'" 0
	else
		print_result "is_rate_limit_only_comment matches 'rate limit exceeded'" 1
	fi
	return 0
}

test_is_rate_limit_only_rejects_review_failed() {
	# "Review failed" is in NON_REVIEW_PATTERNS but NOT RATE_LIMIT_PATTERNS —
	# this is the whole point of the t2799 split.
	if ! is_rate_limit_only_comment "Review failed — Pull request was closed or merged during review."; then
		print_result "is_rate_limit_only_comment rejects 'Review failed'" 0
	else
		print_result "is_rate_limit_only_comment rejects 'Review failed'" 1
	fi
	return 0
}

test_is_rate_limit_only_rejects_review_skipped() {
	# Same: "Review skipped" / "Auto reviews are limited" are non-review but
	# not rate-limit. Misclassifying these as rate-limited would trigger the
	# grace-period retry path inappropriately.
	if ! is_rate_limit_only_comment "Review skipped — Auto reviews are limited based on label configuration."; then
		print_result "is_rate_limit_only_comment rejects 'Review skipped'" 0
	else
		print_result "is_rate_limit_only_comment rejects 'Review skipped'" 1
	fi
	return 0
}

test_is_rate_limit_only_rejects_gemini_sunset_notice() {
	if ! is_rate_limit_only_comment "$GEMINI_SUNSET_NOTICE"; then
		print_result "is_rate_limit_only_comment rejects Gemini Code Assist sunset notice" 0
	else
		print_result "is_rate_limit_only_comment rejects Gemini Code Assist sunset notice" 1
	fi
	return 0
}

test_is_rate_limit_only_rejects_real_review() {
	local body="## Walkthrough

This PR refactors the foo() function to handle the bar edge case."
	if ! is_rate_limit_only_comment "$body"; then
		print_result "is_rate_limit_only_comment rejects real review body" 0
	else
		print_result "is_rate_limit_only_comment rejects real review body" 1
	fi
	return 0
}

# ---------- Unit tests: settled-check ----------

test_settled_recent_unedited_placeholder_rejected() {
	# Created 5s ago, never edited, min_lag=30 → NOT settled (placeholder window).
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	updated="$created"
	if ! _comment_is_settled "$created" "$updated" 30; then
		print_result "settled rejects recent unedited placeholder" 0
	else
		print_result "settled rejects recent unedited placeholder" 1 \
			"created=${created} updated=${updated} now=${now}"
	fi
	return 0
}

test_settled_old_unedited_accepted() {
	# Created 120s ago, never edited, min_lag=30 → settled by age.
	local now created
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$created" 30; then
		print_result "settled accepts old unedited comment" 0
	else
		print_result "settled accepts old unedited comment" 1
	fi
	return 0
}

test_settled_recent_edited_accepted() {
	# Created 10s ago, edited 5s ago (delta = 5s < min_lag of 30) → not settled
	# by edit AND age 10s < min_lag 30 → NOT settled.
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	if ! _comment_is_settled "$created" "$updated" 30; then
		print_result "settled rejects edit-delta and age both under min_lag" 0
	else
		print_result "settled rejects edit-delta and age both under min_lag" 1
	fi
	return 0
}

test_settled_edit_delta_over_min_lag_accepted() {
	# Created 100s ago, edited 5s ago → edit_delta = 95s >= min_lag 30 → settled.
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 100))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 100))" +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$updated" 30; then
		print_result "settled accepts when edit_delta >= min_lag" 0
	else
		print_result "settled accepts when edit_delta >= min_lag" 1
	fi
	return 0
}

test_settled_missing_timestamps_conservative_pass() {
	# Empty created_at → conservative pass (don't block on missing data).
	if _comment_is_settled "" "" 30; then
		print_result "settled passes conservatively on missing created_at" 0
	else
		print_result "settled passes conservatively on missing created_at" 1
	fi
	return 0
}

test_settled_unparseable_timestamps_conservative_pass() {
	# Garbage timestamp → epoch=0 → conservative pass.
	if _comment_is_settled "not-a-date" "also-not-a-date" 30; then
		print_result "settled passes conservatively on unparseable timestamps" 0
	else
		print_result "settled passes conservatively on unparseable timestamps" 1
	fi
	return 0
}

# ---------- Unit tests: per-tool / per-repo lag resolution ----------

test_get_min_edit_lag_per_tool() {
	# coderabbitai on testorg/testrepo → 90 (per-tool override)
	local lag
	lag=$(_get_min_edit_lag "testorg/testrepo" "coderabbitai")
	if [[ "$lag" == "90" ]]; then
		print_result "get_min_edit_lag returns per-tool override (90)" 0
	else
		print_result "get_min_edit_lag returns per-tool override (90)" 1 \
			"got '${lag}', expected '90'"
	fi
	return 0
}

test_get_min_edit_lag_per_repo() {
	# gemini-code-assist on testorg/testrepo → 45 (per-repo default, no per-tool)
	local lag
	lag=$(_get_min_edit_lag "testorg/testrepo" "gemini-code-assist")
	if [[ "$lag" == "45" ]]; then
		print_result "get_min_edit_lag falls back to per-repo default (45)" 0
	else
		print_result "get_min_edit_lag falls back to per-repo default (45)" 1 \
			"got '${lag}', expected '45'"
	fi
	return 0
}

test_get_min_edit_lag_global_default() {
	# any bot on testorg/otherrepo → REVIEW_BOT_MIN_EDIT_LAG_SECONDS (30)
	local lag
	lag=$(_get_min_edit_lag "testorg/otherrepo" "coderabbitai")
	if [[ "$lag" == "30" ]]; then
		print_result "get_min_edit_lag falls back to global default (30)" 0
	else
		print_result "get_min_edit_lag falls back to global default (30)" 1 \
			"got '${lag}', expected '30'"
	fi
	return 0
}

test_get_min_edit_lag_unknown_repo_default() {
	# unknown repo → global default
	local lag
	lag=$(_get_min_edit_lag "nobody/nope" "coderabbitai")
	if [[ "$lag" == "30" ]]; then
		print_result "get_min_edit_lag returns global default for unknown repo" 0
	else
		print_result "get_min_edit_lag returns global default for unknown repo" 1 \
			"got '${lag}', expected '30'"
	fi
	return 0
}

# ---------- Unit tests: two-phase bot behaviour (GH#20550) ----------

test_two_phase_coderabbitai_aged_unedited_not_settled() {
	# Two-phase bot: coderabbitai, created 120s ago but never edited (edit_delta=0).
	# Age alone is NOT sufficient for coderabbitai — requires edit_delta > 0.
	local now created
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ")
	if ! _comment_is_settled "$created" "$created" 30 "coderabbitai"; then
		print_result "two-phase: coderabbitai aged-unedited NOT settled (age alone insufficient)" 0
	else
		print_result "two-phase: coderabbitai aged-unedited NOT settled (age alone insufficient)" 1 \
			"created=${created} — expected NOT settled; age-derived branch must be skipped for coderabbitai"
	fi
	return 0
}

test_two_phase_coderabbitai_any_edit_settled() {
	# Two-phase bot: coderabbitai, created 10s ago, edited 5s ago (edit_delta=5).
	# Any positive edit_delta is authoritative for coderabbitai — settled immediately.
	# Under non-two-phase OR semantics this same input is NOT settled
	# (edit_delta=5 < min_lag=30 AND age=10 < min_lag=30).
	local now created updated
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 10))" +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(TZ=UTC date -u -r "$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 5))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$updated" 30 "coderabbitai"; then
		print_result "two-phase: coderabbitai edit_delta=5 settled (any positive edit is authoritative)" 0
	else
		print_result "two-phase: coderabbitai edit_delta=5 settled (any positive edit is authoritative)" 1 \
			"created=${created} updated=${updated} — expected settled; edit_delta > 0 should pass for coderabbitai"
	fi
	return 0
}

test_two_phase_unknown_bot_or_semantics_preserved() {
	# Non-two-phase bot with unknown login: aged 120s, never edited.
	# Should settle by age — OR semantics preserved for non-two-phase bots.
	local now created
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 120))" +"%Y-%m-%dT%H:%M:%SZ")
	if _comment_is_settled "$created" "$created" 30 "gemini-code-assist"; then
		print_result "non-two-phase: unknown bot aged-unedited settled by age (OR semantics preserved)" 0
	else
		print_result "non-two-phase: unknown bot aged-unedited settled by age (OR semantics preserved)" 1 \
			"created=${created} — expected settled by age for gemini-code-assist (non-two-phase)"
	fi
	return 0
}

test_two_phase_env_override_respected_non_two_phase() {
	# Non-two-phase bot: pass min_lag=60 (representing env override), age=40s.
	# age=40 < min_lag=60 and no edit → NOT settled.
	# Confirms env-derived min_lag is still applied for non-two-phase bots
	# (the two-phase path does not interfere with OR semantics + larger lag).
	local now created
	now=$(date +%s)
	created=$(TZ=UTC date -u -r "$((now - 40))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
		date -u -d "@$((now - 40))" +"%Y-%m-%dT%H:%M:%SZ")
	if ! _comment_is_settled "$created" "$created" 60 "gemini-code-assist"; then
		print_result "non-two-phase: env min_lag=60, age=40 → NOT settled (override respected)" 0
	else
		print_result "non-two-phase: env min_lag=60, age=40 → NOT settled (override respected)" 1 \
			"created=${created} — expected NOT settled; age=40 is below min_lag=60"
	fi
	return 0
}

# ---------- Unit/integration tests: opt-in strict completion (GH#23066) ----------

install_strict_completion_gh_stub() {
	local scenario="$1"
	local gh_stub="${TEST_ROOT}/bin/gh"

	cat >"$gh_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

scenario="${REVIEW_BOT_GATE_GH_SCENARIO:?}"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf '%s\n' 'abc123def456'
	exit 0
fi

if [[ "${1:-}" != "api" ]]; then
	exit 2
fi

endpoint="${2:-}"
case "$endpoint" in
	repos/testorg/strictrepo/pulls/123/reviews)
		;;
	repos/testorg/strictrepo/issues/123/comments)
		printf '%s\t%s\t%s\n' \
			'2026-05-07T00:00:00Z' \
			'2026-05-07T00:00:05Z' \
			'UmV2aWV3IGNvbXBsZXRlZC4gTG9va3MgZ29vZC4='
		;;
	repos/testorg/strictrepo/pulls/123/comments)
		;;
	repos/testorg/strictrepo/commits/abc123def456/status?per_page=100)
		if [[ "$scenario" == "strict-success" ]]; then
			printf '%s\n' 'CodeRabbit'
		fi
		;;
	repos/testorg/strictrepo/commits/abc123def456/check-runs?per_page=100)
		;;
	*)
		;;
esac
EOF
	chmod +x "$gh_stub"
	export REVIEW_BOT_GATE_GH_SCENARIO="$scenario"
	return 0
}

test_get_completion_behavior_strict_repo() {
	local behavior
	behavior=$(_get_completion_behavior 'testorg/strictrepo' 'coderabbitai')
	if [[ "$behavior" == "strict" ]]; then
		print_result "completion_behavior resolves strict repo preference" 0
	else
		print_result "completion_behavior resolves strict repo preference" 1 \
			"got '${behavior}', expected 'strict'"
	fi
	return 0
}

test_get_completion_behavior_defaults_fast() {
	local behavior
	behavior=$(_get_completion_behavior 'testorg/otherrepo' 'coderabbitai')
	if [[ "$behavior" == "fast" ]]; then
		print_result "completion_behavior defaults to fast throughput mode" 0
	else
		print_result "completion_behavior defaults to fast throughput mode" 1 \
			"got '${behavior}', expected 'fast'"
	fi
	return 0
}

test_trusted_default_does_not_require_completed_review() {
	if REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER _review_gate_requires_completed_review 'testorg/otherrepo'; then
		print_result "trusted fast default keeps add-on review advisory" 1
	else
		print_result "trusted fast default keeps add-on review advisory" 0
	fi
	return 0
}

test_owner_rest_association_does_not_require_completed_review() {
	gh() {
		if [[ "${1:-}" == "api" && "${2:-}" == "repos/testorg/otherrepo/pulls/123" ]]; then
			printf '%s\n' 'OWNER'
			return 0
		fi
		return 2
	}

	local association=""
	association=$(_resolve_pr_author_association 123 'testorg/otherrepo')
	unset -f gh
	if [[ "$association" == "OWNER" ]] &&
		! REVIEW_GATE_AUTHOR_ASSOCIATION="$association" _review_gate_requires_completed_review 'testorg/otherrepo'; then
		print_result "REST resolver restores trusted OWNER advisory behavior" 0
	else
		print_result "REST resolver restores trusted OWNER advisory behavior" 1 \
			"association=${association:-<empty>}"
	fi
	return 0
}

test_trusted_strict_repo_requires_completed_review() {
	if REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER _review_gate_requires_completed_review 'testorg/strictrepo'; then
		print_result "trusted strict repo requires completed add-on review" 0
	else
		print_result "trusted strict repo requires completed add-on review" 1
	fi
	return 0
}

test_trusted_retired_tool_policy_does_not_require_completed_review() {
	if REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER _review_gate_requires_completed_review 'testorg/retiredtoolstrictrepo'; then
		print_result "trusted retired per-tool policy remains advisory" 1
	else
		print_result "trusted retired per-tool policy remains advisory" 0
	fi
	return 0
}

test_external_default_requires_completed_review() {
	if REVIEW_GATE_AUTHOR_ASSOCIATION=CONTRIBUTOR _review_gate_requires_completed_review 'testorg/otherrepo'; then
		print_result "external author preserves completed-review trust boundary" 0
	else
		print_result "external author preserves completed-review trust boundary" 1
	fi
	return 0
}

test_untrusted_association_matrix_requires_completed_review() {
	local association=""
	local failures=""
	for association in CONTRIBUTOR NONE FIRST_TIMER FIRST_TIME_CONTRIBUTOR FUTURE_ENUM ""; do
		if ! REVIEW_GATE_AUTHOR_ASSOCIATION="$association" _review_gate_requires_completed_review 'testorg/otherrepo'; then
			failures="${failures}${association:-<empty>} "
		fi
	done
	if [[ -z "$failures" ]]; then
		print_result "external, unknown, and empty associations fail closed" 0
	else
		print_result "external, unknown, and empty associations fail closed" 1 \
			"unexpected advisory associations: ${failures}"
	fi
	return 0
}

test_malformed_metadata_and_rest_failure_fail_closed() {
	gh() {
		return 42
	}

	local association=""
	association=$(_resolve_pr_author_association 123 'testorg/otherrepo' '{malformed-json')
	unset -f gh
	if [[ -z "$association" ]] &&
		REVIEW_GATE_AUTHOR_ASSOCIATION="$association" _review_gate_requires_completed_review 'testorg/otherrepo'; then
		print_result "malformed metadata plus REST failure remains unknown" 0
	else
		print_result "malformed metadata plus REST failure remains unknown" 1 \
			"association=${association:-<empty>}"
	fi
	return 0
}

test_strict_coderabbit_pending_status_blocks_edited_comment() {
	install_strict_completion_gh_stub "strict-pending"

	if ! bot_has_real_review 123 'testorg/strictrepo' 'coderabbitai' 2>/dev/null; then
		print_result "strict CodeRabbit edited comment waits for SUCCESS status" 0
	else
		print_result "strict CodeRabbit edited comment waits for SUCCESS status" 1 \
			"expected strict mode to reject edited-comment evidence without CodeRabbit SUCCESS status"
	fi
	return 0
}

test_strict_coderabbit_success_status_passes_edited_comment() {
	install_strict_completion_gh_stub "strict-success"

	if bot_has_real_review 123 'testorg/strictrepo' 'coderabbitai' 2>/dev/null; then
		print_result "strict CodeRabbit accepts edited comment with SUCCESS status" 0
	else
		print_result "strict CodeRabbit accepts edited comment with SUCCESS status" 1 \
			"expected strict mode to accept CodeRabbit SUCCESS status evidence"
	fi
	return 0
}

test_any_bot_success_status_reuses_provided_contexts() {
	TEST_STATUS_FETCHES=0
	_get_success_status_contexts() {
		TEST_STATUS_FETCHES=$((TEST_STATUS_FETCHES + 1))
		return 1
	}

	local contexts
	contexts=$'abc123def456\nCodeRabbit'
	if any_bot_has_success_status 123 'testorg/strictrepo' "$contexts" 2>/dev/null &&
		[[ "$TEST_STATUS_FETCHES" -eq 0 ]]; then
		print_result "status fallback reuses provided success contexts" 0
	else
		print_result "status fallback reuses provided success contexts" 1 \
			"fetches=${TEST_STATUS_FETCHES}"
	fi
	return 0
}

test_any_bot_success_status_reuses_prepared_contexts() {
	local prepare_calls=0
	_prepare_success_status_contexts() {
		prepare_calls=$((prepare_calls + 1))
		return 1
	}

	local contexts
	contexts=$'abc123def456\ncoderabbit'
	if any_bot_has_success_status 123 'testorg/strictrepo' "$contexts" true 2>/dev/null &&
		[[ "$prepare_calls" -eq 0 ]]; then
		print_result "status fallback reuses prepared success contexts" 0
	else
		print_result "status fallback reuses prepared success contexts" 1 \
			"prepare_calls=${prepare_calls}"
	fi
	return 0
}

# ---------- Integration tests: reviews endpoint submitted_at-only TSV (GH#26473) ----------

install_submitted_at_only_review_gh_stub() {
	local gh_stub="${TEST_ROOT}/bin/gh"

	cat >"$gh_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "api" ]]; then
	exit 2
fi

endpoint="${2:-}"
jq_filter=""
shift 2
while [[ "$#" -gt 0 ]]; do
	case "${1:-}" in
		--jq)
			jq_filter="${2:-}"
			shift 2
			;;
		*)
			shift
			;;
	esac
done

case "$endpoint" in
	repos/testorg/otherrepo/pulls/123/reviews)
		jq -r "$jq_filter" <<'JSON'
[
  {
    "user": {"login": "reviewbot"},
    "submitted_at": "2020-01-01T00:00:00Z",
    "body": "## Review\n\nLooks good. This is a real review body."
  }
]
JSON
		;;
	repos/testorg/otherrepo/issues/123/comments|repos/testorg/otherrepo/pulls/123/comments)
		jq -r "$jq_filter" <<'JSON'
[]
JSON
		;;
	*)
		jq -r "$jq_filter" <<'JSON'
[]
JSON
		;;
esac
EOF
	chmod +x "$gh_stub"
	return 0
}

test_bot_has_real_review_accepts_submitted_at_only_review() {
	install_submitted_at_only_review_gh_stub

	if bot_has_real_review 123 'testorg/otherrepo' 'reviewbot' 2>/dev/null; then
		print_result "bot_has_real_review accepts reviews endpoint submitted_at-only record" 0
	else
		print_result "bot_has_real_review accepts reviews endpoint submitted_at-only record" 1 \
			"expected submitted_at fallback to avoid leading TSV tab field shift"
	fi
	return 0
}

test_classify_bot_state_accepts_submitted_at_only_review() {
	install_submitted_at_only_review_gh_stub

	local state
	state=$(_classify_bot_state 123 'testorg/otherrepo' 'reviewbot')
	if [[ "$state" == "real-review" ]]; then
		print_result "_classify_bot_state accepts reviews endpoint submitted_at-only record" 0
	else
		print_result "_classify_bot_state accepts reviews endpoint submitted_at-only record" 1 \
			"state=${state}; expected real-review"
	fi
	return 0
}

install_head_bound_review_gh_stub() {
	local review_commit="$1"
	local review_time="$2"
	local gh_stub="${TEST_ROOT}/bin/gh"
	cat >"$gh_stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint="\${2:-}"
jq_filter=""
shift 2
while [[ "\$#" -gt 0 ]]; do
	if [[ "\${1:-}" == "--jq" ]]; then jq_filter="\${2:-}"; shift 2; else shift; fi
done
case "\$endpoint" in
	repos/testorg/otherrepo/pulls/123/reviews)
		jq -r "\$jq_filter" <<'JSON'
[{"user":{"login":"reviewbot"},"commit_id":"${review_commit}","submitted_at":"${review_time}","body":"Looks good on this revision."}]
JSON
		;;
	*) jq -r "\$jq_filter" <<'JSON'
[]
JSON
		;;
esac
EOF
	chmod +x "$gh_stub"
	return 0
}

test_current_head_evidence_rejects_historical_review() {
	install_head_bound_review_gh_stub "old-head" "2026-07-14T12:00:00Z"
	export REVIEW_GATE_EXPECTED_HEAD_SHA="new-head"
	if bot_has_real_review 123 'testorg/otherrepo' 'reviewbot' 2>/dev/null; then
		print_result "current-head evidence rejects a review bound to an older head" 1
	else
		print_result "current-head evidence rejects a review bound to an older head" 0
	fi
	unset REVIEW_GATE_EXPECTED_HEAD_SHA
	return 0
}

test_current_head_evidence_accepts_exact_head_review() {
	install_head_bound_review_gh_stub "new-head" "2026-07-14T14:00:00Z"
	export REVIEW_GATE_EXPECTED_HEAD_SHA="new-head"
	if bot_has_real_review 123 'testorg/otherrepo' 'reviewbot' 2>/dev/null; then
		print_result "current-head evidence accepts a review bound to the exact head" 0
	else
		print_result "current-head evidence accepts a review bound to the exact head" 1
	fi
	unset REVIEW_GATE_EXPECTED_HEAD_SHA
	return 0
}

# ---------- Unit tests: notice category classification (GH#22855) ----------

install_notice_category_gh_stub() {
	local scenario="$1"
	local gh_stub="${TEST_ROOT}/bin/gh"

	cat >"$gh_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

count_file="${REVIEW_BOT_GATE_GH_COUNT_FILE:?}"
scenario="${REVIEW_BOT_GATE_GH_SCENARIO:?}"
count="0"
if [[ -f "$count_file" ]]; then
	IFS= read -r count <"$count_file" || count="0"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

if [[ "${1:-}" != "api" ]]; then
	exit 2
fi

endpoint="${2:-}"
case "$scenario:$endpoint" in
	precedence:repos/testorg/otherrepo/pulls/123/reviews)
		printf '%s\n' 'UmV2aWV3IHNraXBwZWQgZHVlIHRvIHJhdGUgbGltaXQgZXhjZWVkZWQ='
		;;
	precedence:repos/testorg/otherrepo/issues/123/comments)
		;;
	precedence:repos/testorg/otherrepo/pulls/123/comments)
		printf '%s\n' 'UmV2aWV3IGZhaWxlZCDigJQgUHVsbCByZXF1ZXN0IHdhcyBjbG9zZWQgb3IgbWVyZ2VkIGR1cmluZyByZXZpZXcu'
		;;
	none:*)
		;;
	failure:*)
		exit 42
		;;
	*)
		;;
esac
EOF
	chmod +x "$gh_stub"
	printf '0\n' >"${TEST_ROOT}/gh-count"
	export REVIEW_BOT_GATE_GH_COUNT_FILE="${TEST_ROOT}/gh-count"
	export REVIEW_BOT_GATE_GH_SCENARIO="$scenario"
	return 0
}

read_notice_category_gh_count() {
	local count="0"
	if [[ -f "${TEST_ROOT}/gh-count" ]]; then
		IFS= read -r count <"${TEST_ROOT}/gh-count" || count="0"
	fi
	printf '%s\n' "$count"
	return 0
}

test_notice_category_single_pass_prefers_non_rate_limit() {
	install_notice_category_gh_stub "precedence"

	local output status calls
	if output=$(bot_get_notice_category 123 'testorg/otherrepo' 'coderabbitai'); then
		status=0
	else
		status=$?
	fi
	calls=$(read_notice_category_gh_count)

	if [[ "$status" -eq 0 && "$output" == "non-rate-limit" && "$calls" == "3" ]]; then
		print_result "notice category uses one pass and prefers non-rate-limit" 0
	else
		print_result "notice category uses one pass and prefers non-rate-limit" 1 \
			"status=${status} output=${output} calls=${calls}"
	fi
	return 0
}

test_notice_category_none_is_successful_default() {
	install_notice_category_gh_stub "none"

	local output status calls
	if output=$(bot_get_notice_category 123 'testorg/otherrepo' 'coderabbitai'); then
		status=0
	else
		status=$?
	fi
	calls=$(read_notice_category_gh_count)

	if [[ "$status" -eq 0 && "$output" == "none" && "$calls" == "3" ]]; then
		print_result "notice category returns successful none default" 0
	else
		print_result "notice category returns successful none default" 1 \
			"status=${status} output=${output} calls=${calls}"
	fi
	return 0
}

test_notice_category_propagates_api_failure() {
	install_notice_category_gh_stub "failure"

	local output status
	if output=$(bot_get_notice_category 123 'testorg/otherrepo' 'coderabbitai'); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 42 && -z "$output" ]]; then
		print_result "notice category propagates API failure" 0
	else
		print_result "notice category propagates API failure" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

# ---------- Integration tests: do_check decision buckets (GH#22802) ----------

test_do_check_passes_true_rate_limit_only() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai'
		return 0
	}
	_get_success_status_contexts() { return 1; }
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "rate-limit"
		return 0
	}
	any_bot_has_success_status() { return 1; }

	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 0 && "$output" == "PASS_RATE_LIMITED" ]]; then
		print_result "do_check passes true rate-limit notices by default" 0
	else
		print_result "do_check passes true rate-limit notices by default" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_advises_non_rate_limit_non_review_states_by_default() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai'
		return 0
	}
	_get_success_status_contexts() { return 1; }
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "non-rate-limit"
		return 0
	}
	any_bot_has_success_status() { return 1; }

	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 0 && "$output" == "PASS_ADVISORY" ]]; then
		print_result "do_check treats non-review provider states as advisory by default" 0
	else
		print_result "do_check treats non-review provider states as advisory by default" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_blocks_non_review_states_in_strict_mode() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai'
		return 0
	}
	_get_success_status_contexts() { return 1; }
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "non-rate-limit"
		return 0
	}
	any_bot_has_success_status() { return 1; }

	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER do_check 123 'testorg/strictrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 1 && "$output" == "WAITING" ]]; then
		print_result "do_check blocks non-review states after strict opt-in" 0
	else
		print_result "do_check blocks non-review states after strict opt-in" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_blocks_external_non_review_states() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai'
		return 0
	}
	_get_success_status_contexts() { return 1; }
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "non-rate-limit"
		return 0
	}
	any_bot_has_success_status() { return 1; }

	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=CONTRIBUTOR do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 1 && "$output" == "WAITING" ]]; then
		print_result "do_check preserves external-author review trust boundary" 0
	else
		print_result "do_check preserves external-author review trust boundary" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_advises_when_no_bots_are_present() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() { return 0; }
	_get_success_status_contexts() { return 1; }

	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 0 && "$output" == "PASS_ADVISORY" ]]; then
		print_result "do_check does not wait for an absent add-on under default policy" 0
	else
		print_result "do_check does not wait for an absent add-on under default policy" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_honors_skip_for_trusted_author() {
	check_for_skip_label() { return 0; }
	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=MEMBER do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi
	if [[ "$status" -eq 0 && "$output" == "SKIP" ]]; then
		print_result "do_check honors skip label for trusted author" 0
	else
		print_result "do_check honors skip label for trusted author" 1 "status=${status} output=${output}"
	fi
	return 0
}

test_do_check_denies_skip_for_external_author() {
	check_for_skip_label() { return 0; }
	local output status
	if output=$(REVIEW_GATE_AUTHOR_ASSOCIATION=CONTRIBUTOR do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi
	if [[ "$status" -eq 1 && "$output" == "WAITING" ]]; then
		print_result "do_check denies skip label for external author" 0
	else
		print_result "do_check denies skip label for external author" 1 "status=${status} output=${output}"
	fi
	return 0
}

test_do_check_accepts_non_review_with_success_status() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai'
		return 0
	}
	_get_success_status_contexts() {
		printf '%s\n' 'abc123def456' 'CodeRabbit'
		return 0
	}
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "non-rate-limit"
		return 0
	}
	any_bot_has_success_status() { return 0; }

	local output status
	if output=$(do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi

	if [[ "$status" -eq 0 && "$output" == "PASS" ]]; then
		print_result "do_check accepts non-review state with success status" 0
	else
		print_result "do_check accepts non-review state with success status" 1 \
			"status=${status} output=${output}"
	fi
	return 0
}

test_do_check_fetches_success_status_contexts_once() {
	check_for_skip_label() { return 1; }
	get_all_bot_commenters() {
		printf '%s\n' 'coderabbitai gemini-code-assist'
		return 0
	}
	bot_has_real_review() { return 1; }
	bot_get_notice_category() {
		echo "non-rate-limit"
		return 0
	}
	_get_success_status_contexts() {
		local pr_number="$1"
		local repo="$2"
		local count="0"
		if [[ -f "${TEST_ROOT}/status-fetch-count" ]]; then
			IFS= read -r count <"${TEST_ROOT}/status-fetch-count" || count="0"
		fi
		count=$((count + 1))
		printf '%s\n' "$count" >"${TEST_ROOT}/status-fetch-count"
		printf '%s\n%s\n' "abc123def456" "CodeRabbit"
		return 0
	}

	printf '0\n' >"${TEST_ROOT}/status-fetch-count"
	local output status calls
	if output=$(do_check 123 'testorg/otherrepo' 2>/dev/null); then
		status=0
	else
		status=$?
	fi
	IFS= read -r calls <"${TEST_ROOT}/status-fetch-count" || calls="0"

	if [[ "$status" -eq 0 && "$output" == "PASS" && "$calls" == "1" ]]; then
		print_result "do_check fetches success status contexts once" 0
	else
		print_result "do_check fetches success status contexts once" 1 \
			"status=${status} output=${output} calls=${calls}"
	fi
	return 0
}

test_status_json_denies_external_rate_limit_grace() {
	do_check() {
		printf 'PASS_RATE_LIMITED\n'
		return 0
	}
	gh() {
		printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"external"},"author_association":"CONTRIBUTOR"}'
		return 0
	}
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.schema == "aidevops.review-gate-evidence/v1" and .status == "PASS_RATE_LIMITED" and .author.class == "external" and .permitted == false and .merge_gate == "blocked"' <<<"$output" >/dev/null; then
		print_result "status-json denies external rate-limit grace" 0
	else
		print_result "status-json denies external rate-limit grace" 1 "output=${output}"
	fi
	return 0
}

test_status_json_allows_trusted_advisory_default() {
	do_check() {
		printf 'PASS_ADVISORY\n'
		return 0
	}
	gh() {
		printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"maintainer"},"author_association":"MEMBER"}'
		return 0
	}
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.status == "PASS_ADVISORY" and .head_sha == "head-123" and .author.class == "trusted" and .permitted == true and .reason == "trusted_advisory_default" and .merge_gate == "clear"' <<<"$output" >/dev/null; then
		print_result "status-json permits trusted current-head advisory default" 0
	else
		print_result "status-json permits trusted current-head advisory default" 1 "output=${output}"
	fi
	return 0
}

test_status_json_denies_external_advisory_default() {
	do_check() {
		printf 'PASS_ADVISORY\n'
		return 0
	}
	gh() {
		printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"external"},"author_association":"CONTRIBUTOR"}'
		return 0
	}
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.status == "PASS_ADVISORY" and .author.class == "external" and .permitted == false and .reason == "external_advisory_denied" and .merge_gate == "blocked"' <<<"$output" >/dev/null; then
		print_result "status-json denies external advisory outcome" 0
	else
		print_result "status-json denies external advisory outcome" 1 "output=${output}"
	fi
	return 0
}

test_status_json_allows_trusted_skip() {
	do_check() {
		printf 'SKIP\n'
		return 0
	}
	gh() {
		printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"maintainer"},"author_association":"MEMBER","labels":[{"name":"skip-review-gate"}]}'
		return 0
	}
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.status == "SKIP" and .head_sha == "head-123" and .author.class == "trusted" and .permitted == true and .merge_gate == "clear"' <<<"$output" >/dev/null; then
		print_result "status-json permits trusted current-head skip" 0
	else
		print_result "status-json permits trusted current-head skip" 1 "output=${output}"
	fi
	return 0
}

test_status_json_denies_skip_removed_during_decision() {
	do_check() {
		printf 'SKIP\n'
		return 0
	}
	local gh_count_file="${TEST_ROOT}/status-json-skip-gh-count"
	printf '0\n' >"$gh_count_file"
	gh() {
		local gh_calls=0
		IFS= read -r gh_calls <"$gh_count_file" || gh_calls=0
		gh_calls=$((gh_calls + 1))
		printf '%s\n' "$gh_calls" >"$gh_count_file"
		if [[ "$gh_calls" -eq 1 ]]; then
			printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"maintainer"},"author_association":"MEMBER","labels":[{"name":"skip-review-gate"}]}'
		else
			printf '%s\n' '{"head":{"sha":"head-123"},"user":{"login":"maintainer"},"author_association":"MEMBER","labels":[]}'
		fi
		return 0
	}
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.status == "SKIP" and .author.class == "trusted" and .permitted == false and .merge_gate == "blocked"' <<<"$output" >/dev/null; then
		print_result "status-json denies a skip label removed during the decision" 0
	else
		print_result "status-json denies a skip label removed during the decision" 1 "output=${output}"
	fi
	return 0
}

test_status_json_fails_closed_without_pr_metadata() {
	do_check() {
		printf 'PASS\n'
		return 0
	}
	gh() { return 1; }
	local output=""
	output=$(do_status_json 123 'testorg/otherrepo')
	if jq -e '.status == "PASS" and .head_sha == "" and .permitted == false and .merge_gate == "blocked"' <<<"$output" >/dev/null; then
		print_result "status-json fails closed on missing PR metadata" 0
	else
		print_result "status-json fails closed on missing PR metadata" 1 "output=${output}"
	fi
	return 0
}

run_completion_requirement_tests() {
	test_trusted_default_does_not_require_completed_review
	test_owner_rest_association_does_not_require_completed_review
	test_trusted_strict_repo_requires_completed_review
	test_trusted_retired_tool_policy_does_not_require_completed_review
	test_external_default_requires_completed_review
	test_untrusted_association_matrix_requires_completed_review
	test_malformed_metadata_and_rest_failure_fail_closed
	return 0
}

run_status_json_tests() {
	test_status_json_denies_external_rate_limit_grace
	test_status_json_allows_trusted_advisory_default
	test_status_json_denies_external_advisory_default
	test_status_json_allows_trusted_skip
	test_status_json_denies_skip_removed_during_decision
	test_status_json_fails_closed_without_pr_metadata
	return 0
}

# ---------- Run ----------

main() {
	setup_test_env
	trap cleanup_test_env EXIT

	# Source the helper (with main() invocation stripped) so its functions
	# are callable in this shell.
	load_helper_functions

	echo "=== Pattern matching ==="
	test_is_non_review_comment_matches_rate_limit
	test_is_non_review_comment_matches_review_failed
	test_is_non_review_comment_matches_review_skipped
	test_is_non_review_comment_matches_closed_during_review
	test_is_non_review_comment_matches_gemini_sunset_notice
	test_is_non_review_comment_rejects_real_review
	test_event_check_accepts_trusted_inline_bot_review
	test_event_check_rejects_human_inline_reply
	test_event_check_rejects_bot_failure_notice
	test_event_check_rejects_bot_sunset_notice
	test_event_check_rejects_stale_head_evidence
	test_self_caller_uses_pr_head_helper_ref
	test_callers_expose_explicit_ci_strict_opt_in
	test_infra_rate_limit_passes_trusted_default_policy
	test_infra_rate_limit_blocks_external_author
	test_infra_rate_limit_blocks_explicit_wait_or_strict_policy
	test_infra_rate_limit_ignores_retired_tool_policy
	test_is_rate_limit_only_matches_rate_limit
	test_is_rate_limit_only_rejects_review_failed
	test_is_rate_limit_only_rejects_review_skipped
	test_is_rate_limit_only_rejects_gemini_sunset_notice
	test_is_rate_limit_only_rejects_real_review

	echo ""
	echo "=== Settled check ==="
	test_settled_recent_unedited_placeholder_rejected
	test_settled_old_unedited_accepted
	test_settled_recent_edited_accepted
	test_settled_edit_delta_over_min_lag_accepted
	test_settled_missing_timestamps_conservative_pass
	test_settled_unparseable_timestamps_conservative_pass

	echo ""
	echo "=== Min-edit-lag resolver ==="
	test_get_min_edit_lag_per_tool
	test_get_min_edit_lag_per_repo
	test_get_min_edit_lag_global_default
	test_get_min_edit_lag_unknown_repo_default

	echo ""
	echo "=== Two-phase bot behaviour (GH#20550) ==="
	test_two_phase_coderabbitai_aged_unedited_not_settled
	test_two_phase_coderabbitai_any_edit_settled
	test_two_phase_unknown_bot_or_semantics_preserved
	test_two_phase_env_override_respected_non_two_phase

	echo ""
	echo "=== Opt-in strict completion (GH#23066) ==="
	test_get_completion_behavior_strict_repo
	test_get_completion_behavior_defaults_fast
	run_completion_requirement_tests
	test_strict_coderabbit_pending_status_blocks_edited_comment
	test_strict_coderabbit_success_status_passes_edited_comment
	test_any_bot_success_status_reuses_provided_contexts
	test_any_bot_success_status_reuses_prepared_contexts

	echo ""
	echo "=== Reviews endpoint submitted_at fallback (GH#26473) ==="
	test_bot_has_real_review_accepts_submitted_at_only_review
	test_classify_bot_state_accepts_submitted_at_only_review
	test_current_head_evidence_rejects_historical_review
	test_current_head_evidence_accepts_exact_head_review

	echo ""
	echo "=== Notice category classification (GH#22855) ==="
	test_notice_category_single_pass_prefers_non_rate_limit
	test_notice_category_none_is_successful_default
	test_notice_category_propagates_api_failure

	echo ""
	echo "=== do_check decision buckets (GH#22802) ==="
	test_do_check_passes_true_rate_limit_only
	test_do_check_advises_non_rate_limit_non_review_states_by_default
	test_do_check_blocks_non_review_states_in_strict_mode
	test_do_check_blocks_external_non_review_states
	test_do_check_advises_when_no_bots_are_present
	test_do_check_accepts_non_review_with_success_status
	test_do_check_fetches_success_status_contexts_once
	test_do_check_honors_skip_for_trusted_author
	test_do_check_denies_skip_for_external_author

	echo ""
	echo "=== Typed current-head evidence ==="
	run_status_json_tests

	echo ""
	echo "Tests run: ${TESTS_RUN}, failed: ${TESTS_FAILED}"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
