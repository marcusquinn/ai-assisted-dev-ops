#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Quality Feedback Approval Tests -- approval/sentiment detection tests
# =============================================================================
# Tests for the approval-detection jq filter used in _scan_single_pr:
# LGTM, positive summaries, no-further-comments, actionable review detection,
# --include-positive flag behaviour, merge/CI-status comment filtering.
#
# Usage: source "${SCRIPT_DIR}/test-quality-feedback-main-verification-approval.sh"
#
# Dependencies:
#   - Orchestrator (test-quality-feedback-main-verification.sh) must be sourced
#     first to provide: print_result, reset_mock_state, gh mock, GH_* globals
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_APPROVAL_TESTS_LOADED:-}" ]] && return 0
_QF_APPROVAL_TESTS_LOADED=1

# --- Helper Functions ---

# Helper: run the approval-detection jq filter against a review body.
# Returns "skip" if the review would be skipped, "keep" if it would be kept.
# Mirrors the $approval_only + $actionable logic in _scan_single_pr.
_test_approval_filter() {
	local body="$1"
	local state="${2:-COMMENTED}"
	local reviewer="${3:-coderabbit}"

	# Replicate the jq filter from _scan_single_pr review_findings block
	local result
	result=$(jq -rn \
		--arg body "$body" \
		--arg state "$state" \
		--arg reviewer "$reviewer" '
		($body | test(
			"^[\\s\\n]*(lgtm|looks good( to me)?|ship it|shipit|:shipit:|:\\+1:|👍|" +
			"approved?|great (work|job|change|pr|patch)|nice (work|job|change|pr|patch)|" +
			"good (work|job|change|pr|patch|catch|call|stuff)|well done|" +
			"no (further |more )?(comments?|issues?|concerns?|feedback|changes? (needed|required))|" +
			"nothing (further|else|more) (to (add|comment|say|note))?|" +
			"(all |everything )?(looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(this |the )?(pr|patch|change|diff|code) (looks?|seems?) (good|fine|correct|great|solid|clean)|" +
			"(i have )?no (objections?|issues?|concerns?|comments?)|" +
			"(thanks?|thank you)[,.]?\\s*(for the (pr|patch|fix|change|contribution))?[.!]?)[\\s\\n]*$"; "i")) as $approval_only |

		($body | test(
			"\\bno (further )?recommendations?\\b|" +
			"\\bno additional recommendations?\\b|" +
			"\\bnothing (further|more) to recommend\\b"; "i")) as $no_actionable_recommendation |

		($body | test(
			"\\bno (further |more )?suggestions?\\b|" +
			"\\bno additional suggestions?\\b|" +
			"\\bno suggestions? (at this time|for now|currently|for improvement)?\\b|" +
			"\\bwithout suggestions?\\b|" +
			"\\bhas no suggestions?\\b"; "i")) as $no_actionable_suggestions |

		($body | test(
			"\\blgtm\\b|\\blooks good( to me)?\\b|\\bgood work\\b|" +
			"\\bno (further |more )?(comments?|issues?|concerns?|feedback)\\b|" +
			"\\bfound no (issues?|problems?|concerns?)\\b|" +
			"\\bno (issues?|problems?|concerns?) (found|detected)\\b|" +
			"\\b(found|detected) nothing (to )?(fix|change|address)\\b|" +
			"\\beverything (looks?|seems?) (good|fine|correct|great|solid|clean)\\b"; "i")) as $no_actionable_sentiment |

		($body | test(
			"\\bsuccessfully addresses?\\b|\\beffectively\\b|\\bimproves?\\b|\\benhances?\\b|" +
			"\\bcorrectly (removes?|implements?|fixes?|handles?|addresses?)\\b|\\bvaluable change\\b|" +
			"\\bconsistent\\b|\\brobust(ness)?\\b|\\buser experience\\b|" +
			"\\breduces? (external )?requirements?\\b|\\bwell-implemented\\b"; "i")) as $summary_praise_only |

		(($body | test("\\breviewed exact head\\b"; "i")) and ($body | test("\\b(corrects?|keeps?|preserves?|verif(y|ies|ied)|pass(es|ed)?)\\b"; "i")) and ($body | test("\\b(tests?|checks?|suites?)\\b"; "i")) and (($body | test("\\b(but|however|although|yet|except|still|remaining|unresolved)\\b"; "i")) | not)) as $exact_head_verification |

		($body | test(
			"\\b(corrects?|fix(es|ed)?|replaces?|addresses?)\\b[^.\\n]*(\\bbroken\\b|\\bincorrect\\b|\\bwrong\\b|\\bbug\\b|\\berror\\b|\\bissue\\b)|" +
			"\\b(change|fix) is correct\\b|\\bcorrect and improves?\\b"; "i")) as $historic_fix_praise |

		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend(ed|ing)?\\b|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bbug\\b|\\berror\\b|\\bproblem\\b|\\bfail\\b|\\bincorrect\\b|\\bwrong\\b|\\bmissing\\b|\\bbroken\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $actionable_raw |

		($body | test(
			"\\bshould\\b|\\bconsider\\b|\\binstead\\b|\\bsuggest|\\brecommend(ed|ing)?\\b|" +
			"\\bwarning\\b|\\bcaution\\b|\\bavoid\\b|\\b(don ?'"'"'?t|do not)\\b|" +
			"\\bplease\\b|\\bneeds?\\b|\\bmust\\b|" +
			"\\bvulnerab|\\binsecure|\\binjection\\b|\\bxss\\b|\\bcsrf\\b|" +
			"\\bnit:|\\btodo:|\\bfixme|\\bhardcoded|\\bdeprecated|" +
			"\\brace.condition|\\bdeadlock|\\bleak|\\boverflow|" +
			"\\bworkaround\\b|\\bhack\\b|" +
			"```\\s*(suggestion|diff)"; "i")) as $strong_actionable |

		(($actionable_raw or $strong_actionable) and ($no_actionable_recommendation | not) and ($no_actionable_suggestions | not) and ($strong_actionable or (($historic_fix_praise and $summary_praise_only) | not)) and ($strong_actionable or ($exact_head_verification | not))) as $actionable |

		# GH#5668: merge/CI-status comments are not actionable review feedback
		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		# skip = approval-only/no-recommendation/no-suggestions/no-actionable sentiment
		# or summary praise with no actionable critique, or merge/CI-status comment
		if (($approval_only or $no_actionable_recommendation or $no_actionable_suggestions or $no_actionable_sentiment or $summary_praise_only or $exact_head_verification or $merge_status_only) and ($actionable | not)) then "skip"
		else "keep"
		end
	')
	echo "$result"
	return 0
}

# Helper: run the approval-detection jq filter with include_positive=true.
# Returns "keep" for all reviews when include_positive bypasses filters.
_test_approval_filter_include_positive() {
	local body="$1"

	# With include_positive=true the filter always returns "keep"
	local result
	result=$(jq -rn \
		--arg body "$body" \
		--argjson include_positive 'true' '
		if $include_positive then "keep"
		else
			($body | test("\\bshould\\b|\\bconsider\\b"; "i")) as $actionable |
			if $actionable then "keep" else "skip" end
		end
	')
	echo "$result"
	return 0
}

# --- Test Functions ---

test_skips_lgtm_review() {
	local result
	result=$(_test_approval_filter "LGTM")
	if [[ "$result" == "skip" ]]; then
		print_result "skip LGTM review" 0
	else
		print_result "skip LGTM review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_comments_review() {
	local result
	result=$(_test_approval_filter "I've reviewed the changes and have no further comments. Good work.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further comments' review" 0
	else
		print_result "skip 'no further comments' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_feedback_review() {
	local result
	result=$(_test_approval_filter "The implementation is sound and I have no further feedback.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further feedback' review" 0
	else
		print_result "skip 'no further feedback' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_gemini_no_further_comments_summary_review() {
	local result
	result=$(_test_approval_filter '## Code Review

This pull request correctly adds blocked-by dependencies to subtasks in TODO.md, establishing a sequential chain t1120.1 -> t1120.2 -> t1120.4. This change prevents the subtasks from being dispatched in parallel, which could lead to wasted CI cycles. The modification is minimal, accurate, and adheres to the task dependency format used in the project. The implementation is sound and I have no further comments.')
	if [[ "$result" == "skip" ]]; then
		print_result "skip Gemini summary with 'no further comments'" 0
	else
		print_result "skip Gemini summary with 'no further comments'" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_looks_good_review() {
	local result
	result=$(_test_approval_filter "Looks good to me!")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'looks good to me' review" 0
	else
		print_result "skip 'looks good to me' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_good_work_review() {
	local result
	result=$(_test_approval_filter "Good work on this PR.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'good work' review" 0
	else
		print_result "skip 'good work' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_issues_review() {
	local result
	result=$(_test_approval_filter "No issues found. Everything looks good.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no issues' review" 0
	else
		print_result "skip 'no issues' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_found_no_issues_long_review() {
	local result
	result=$(_test_approval_filter "This pull request enhances the AI supervisor's reasoning capabilities by introducing self-improvement and efficiency analysis. It adds two new action types, create_improvement and escalate_model, along with corresponding analysis frameworks and examples in the system prompt. The updates to the prompt are clear and consistent with the stated goals. I've reviewed the changes and found no issues. The new capabilities are a strong step toward a more intelligent supervisor.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip long summary review with 'found no issues'" 0
	else
		print_result "skip long summary review with 'found no issues'" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_further_recommendations_review() {
	local result
	result=$(_test_approval_filter "The pull request is well-documented and the fixes are implemented correctly. I have no further recommendations.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no further recommendations' review" 0
	else
		print_result "skip 'no further recommendations' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_gemini_style_positive_summary_review() {
	local result
	result=$(_test_approval_filter "This pull request successfully addresses the issue by removing an external dependency and improves robustness. The addition of no-data messaging enhances user experience.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip Gemini-style positive summary review" 0
	else
		print_result "skip Gemini-style positive summary review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_no_suggestions_at_this_time_review() {
	local result
	result=$(_test_approval_filter "Review completed. No suggestions at this time.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no suggestions at this time' review" 0
	else
		print_result "skip 'no suggestions at this time' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_pr155_historic_broken_url_praise_review() {
	local result
	# shellcheck disable=SC2016  # literal review body includes Markdown backticks
	result=$(_test_approval_filter '## Code Review

This pull request corrects a broken placeholder URL for the `ultimate-multisite` plugin in the `wp-preferred.md` documentation file. The change is straightforward and accurate, replacing the incorrect link with the proper URL to the plugin page. The change is correct and improves the quality of the documentation.' "COMMENTED" "gemini")
	if [[ "$result" == "skip" ]]; then
		print_result "skip PR #155 historic broken-URL praise review" 0
	else
		print_result "skip PR #155 historic broken-URL praise review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_pr2166_unbound_variable_praise_review() {
	local result
	# shellcheck disable=SC2016  # literal review body includes Markdown backticks and array syntax
	result=$(_test_approval_filter '## Code Review

This pull request correctly addresses an `unbound variable` error in the `_run_generator` function that occurs under `set -u` when no extra arguments are provided. The use of the `${arr[@]+ "${arr[@]}"}` pattern is an effective and idiomatic solution for safe empty array expansion in bash, and it is consistent with other parts of the codebase. Additionally, the explicit `return 0` brings the function into compliance with the repository style guide, which requires all functions to have explicit return statements. The changes are well-implemented and improve the script robustness and quality.' "COMMENTED" "gemini")
	if [[ "$result" == "skip" ]]; then
		print_result "skip PR #2166 unbound-variable praise review" 0
	else
		print_result "skip PR #2166 unbound-variable praise review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_production_positive_filter_skips_pr26615_praise_patterns() {
	local prefiltered
	prefiltered=$(jq -cn '[{
		body: "The scanner detected nothing to fix. This pull request correctly removes stale suppression, and it is a valuable change for debuggability.",
		_reviewer: "gemini",
		_severity: "medium",
		state: "COMMENTED"
	}]')

	local filtered_count
	filtered_count=$(_apply_positive_filter "$prefiltered" "false" | jq 'length')
	if [[ "$filtered_count" -eq 0 ]]; then
		print_result "production filter skips PR #26615 praise-only review patterns" 0
	else
		print_result "production filter skips PR #26615 praise-only review patterns" 1 "expected 0 findings, got ${filtered_count}"
	fi
	return 0
}

test_keeps_historic_broken_url_with_actionable_critique_review() {
	local result
	# shellcheck disable=SC2016  # literal review body includes Markdown backticks
	result=$(_test_approval_filter '## Code Review

This pull request corrects a broken placeholder URL for the `ultimate-multisite` plugin in the `wp-preferred.md` documentation file. The change is correct and improves the quality of the documentation. However, you should also verify that the other links in this file are still valid.' "COMMENTED" "gemini")
	if [[ "$result" == "keep" ]]; then
		print_result "keep historic broken-URL with actionable critique review" 0
	else
		print_result "keep historic broken-URL with actionable critique review" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_skips_no_suggestions_for_improvement_review() {
	local result
	result=$(_test_approval_filter "The code is clear and consistent with the style guide. I have no suggestions for improvement.")
	if [[ "$result" == "skip" ]]; then
		print_result "skip 'no suggestions for improvement' review" 0
	else
		print_result "skip 'no suggestions for improvement' review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_skips_review_thread_response_inline_comment() {
	local comments result
	comments='[{"user":{"login":"marcusquinn"},"body":"<!-- aidevops:review-thread-response:PRRT_1 -->\nAddressed in 055c869cb by building a jq lookup map. Verified with bash -n and shellcheck.","path":".agents/scripts/quality-feedback-findings-lib.sh","line":329,"html_url":"https://example.invalid/review","created_at":"2026-06-16T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "24936" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip review-thread response inline comment" 0
	else
		print_result "skip review-thread response inline comment" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_coderabbit_confirmed_addressed_thread() {
	local comments result
	comments='[{"id":3687897930,"user":{"login":"coderabbitai[bot]"},"body":"Send branch-protection fields as a JSON body. Use --input - rather than individual fields.\n\n✅ Confirmed as addressed by @maintainer","path":".agents/tools/git/git-security.md","original_line":42,"html_url":"https://example.invalid/review-root","created_at":"2026-07-31T03:31:01Z"},{"id":3687908739,"in_reply_to_id":3687897930,"user":{"login":"maintainer"},"body":"Fixed in a62acc4ff. The example now sends one structured JSON document through --input -.","path":".agents/tools/git/git-security.md","original_line":42,"html_url":"https://example.invalid/review-reply","created_at":"2026-07-31T03:41:01Z"},{"id":3687909595,"in_reply_to_id":3687897930,"user":{"login":"coderabbitai[bot]"},"body":"Confirmed. The structured JSON body addresses the nested-object encoding issue.\n\n<!-- <review_comment_addressed> -->","path":".agents/tools/git/git-security.md","original_line":42,"html_url":"https://example.invalid/review-confirmation","created_at":"2026-07-31T03:42:01Z"}]'
	result=$(_build_inline_findings "$comments" "28983" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip CodeRabbit confirmed-addressed thread" 0
	else
		print_result "skip CodeRabbit confirmed-addressed thread" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_no_further_concerns_inline_ack() {
	local comments result
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. The lookup map implementation is the correct approach, and I have no further concerns regarding this implementation.","path":".agents/scripts/quality-feedback-findings-lib.sh","line":329,"html_url":"https://example.invalid/review","created_at":"2026-06-16T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "24936" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip no-further-concerns inline acknowledgement" 0
	else
		print_result "skip no-further-concerns inline acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_resolved_thread_inline_ack() {
	local comments result
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the verification. Since the implementation has been confirmed as correct and the thread is resolved, no further action is needed.","path":".agents/scripts/pulse-dispatch-engine.sh","line":868,"html_url":"https://example.invalid/review","created_at":"2026-06-18T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25009" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip resolved-thread inline acknowledgement" 0
	else
		print_result "skip resolved-thread inline acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26944_no_further_action_required_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update, marcusquinn. It is great to see that the `grep` option injection vulnerability has been addressed with the `--` separator and that the fix has been verified with the provided test suite. Since the issue is resolved, no further action is required.","path":".agents/scripts/profile-readme-helper.sh","line":329,"html_url":"https://example.invalid/review","created_at":"2026-07-10T00:00:00Z"},{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update, marcusquinn. It is excellent to see that the potential option injection vulnerability has been addressed with the `--` separator and that the fix has been verified through your test suite. Given that the issue is resolved, no further action is required on this thread.","path":".agents/scripts/profile-readme-helper.sh","line":357,"html_url":"https://example.invalid/review","created_at":"2026-07-10T00:00:00Z"},{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. No further action required.","path":".agents/scripts/profile-readme-helper.sh","line":380,"html_url":"https://example.invalid/review","created_at":"2026-07-10T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26944" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26944 no-further-action-required acknowledgements" 0
	else
		print_result "skip PR #26944 no-further-action-required acknowledgements" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_multispace_implementation_verified_inline_ack() {
	local comments result
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. The implementation\nhas   been verified and the tests are passing.","path":".agents/scripts/pulse-dispatch-engine.sh","line":1406,"html_url":"https://example.invalid/review","created_at":"2026-06-18T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25009" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip multispace implementation-verified inline acknowledgement" 0
	else
		print_result "skip multispace implementation-verified inline acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_verified_tests_passing_inline_ack() {
	local comments result
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. Since the implementation has been verified and the tests are passing, this thread is resolved.","path":".agents/scripts/pulse-dispatch-engine.sh","line":1406,"html_url":"https://example.invalid/review","created_at":"2026-06-18T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25009" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip verified-tests-passing inline acknowledgement" 0
	else
		print_result "skip verified-tests-passing inline acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr25362_race_condition_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update and for verifying the implementation. Since the current branch already incorporates the necessary synchronization using `serviceQueue` and the `servicesStopped` flag as discussed, the race condition is indeed addressed. I appreciate the thorough verification.","path":"packages/gui-desktop/scripts/install-macos-app.sh","line":848,"html_url":"https://example.invalid/review","created_at":"2026-06-23T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25362" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #25362 race-condition acknowledgement" 0
	else
		print_result "skip PR #25362 race-condition acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_incorporates_necessary_synchronization_ack_without_race_phrase() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. The current branch already\nincorporated the necessary synchronization using `serviceQueue` and the `servicesStopped` flag as discussed.","path":"packages/gui-desktop/scripts/install-macos-app.sh","line":848,"html_url":"https://example.invalid/review","created_at":"2026-06-23T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25362" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip incorporates necessary-synchronization acknowledgement" 0
	else
		print_result "skip incorporates necessary-synchronization acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr25504_verification_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for verifying the fix and adding the regression test. The updated logic correctly handles the `/tmp` edge case and ensures robust validation for the configuration home directory. This looks good.","path":".agents/scripts/config-helper.sh","line":71,"html_url":"https://example.invalid/review","created_at":"2026-06-26T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "25504" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #25504 verification acknowledgement" 0
	else
		print_result "skip PR #25504 verification acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26721_positive_implementation_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update, @maintainer. The implementation in `cf2ad85` correctly addresses the issue by preserving the `read` condition to handle files without trailing newlines while explicitly filtering empty lines before logging. This is a robust approach for parsing file paths in shell scripts.","path":".agents/scripts/file-size-regression-helper.sh","line":227,"html_url":"https://example.invalid/review","created_at":"2026-07-06T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26721" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26721 positive implementation acknowledgement" 0
	else
		print_result "skip PR #26721 positive implementation acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_positive_implementation_ack_with_address_variants() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. The implementation in `abc1234` correctly addressed the edge case by using explicit validation across a long review body with several clauses. This is a robust validation pattern for shell helpers.","path":".agents/scripts/example-helper.sh","line":42,"html_url":"https://example.invalid/review","created_at":"2026-07-06T00:00:00Z"},{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update. The implementation now correctly address the issue by preserving the intended branch behavior across a long review body with several clauses. This is a robust handling pattern for shell helpers.","path":".agents/scripts/example-helper.sh","line":43,"html_url":"https://example.invalid/review","created_at":"2026-07-06T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26733" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip positive implementation acknowledgement address variants" 0
	else
		print_result "skip positive implementation acknowledgement address variants" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26751_confirmation_feedback_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the confirmation and for addressing the feedback. The updated mock in `.agents/scripts/tests/test-approval-helper-sudo-gh-auth.sh` now correctly handles the argument count check and safely propagates the exit code, which improves the robustness of the test suite.","path":".agents/scripts/tests/test-approval-helper-sudo-gh-auth.sh","line":164,"html_url":"https://example.invalid/review","created_at":"2026-07-07T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26751" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26751 confirmation feedback acknowledgement" 0
	else
		print_result "skip PR #26751 confirmation feedback acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26877_regression_test_verification_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the verification and for adding the regression test. The inclusion of the guard clause and the updated process detection logic in `.agents/scripts/audit-worktree-removal-helper.sh` correctly addresses the potential false positive identified.","path":".agents/scripts/audit-worktree-removal-helper.sh","line":138,"html_url":"https://example.invalid/review","created_at":"2026-07-09T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26877" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26877 regression-test verification acknowledgement" 0
	else
		print_result "skip PR #26877 regression-test verification acknowledgement" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26892_nongreedy_quantifier_ack() {
	local comments result
	# shellcheck disable=SC2016  # literal inline-comment JSON includes Markdown backticks
	comments='[{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update and for confirming that the non-greedy quantifiers have been applied and verified by the regression suite. This change correctly addresses the potential for false positives in the regex matching logic.","path":".agents/scripts/quality-feedback-findings-lib.sh","line":50,"html_url":"https://example.invalid/review","created_at":"2026-07-09T00:00:00Z"},{"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the update and for confirming that the non-greedy quantifier has been applied and verified by the regression suite. This change correctly addresses the potential for false positives in the regex matching logic.","path":".agents/scripts/quality-feedback-findings-lib.sh","line":51,"html_url":"https://example.invalid/review","created_at":"2026-07-09T00:00:00Z"}]'
	result=$(_build_inline_findings "$comments" "26892" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26892 non-greedy-quantifier acknowledgements" 0
	else
		print_result "skip PR #26892 non-greedy-quantifier acknowledgements" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr26938_resolved_timeout_thread() {
	local comments result
	# shellcheck disable=SC2016  # literal review JSON includes a Markdown code span
	comments='[{"id":3559925333,"user":{"login":"gemini-code-assist[bot]"},"body":"If the modal is closed or unmounted within 3 seconds of clicking the terminal launch button, the timeout callback will still execute and attempt to call setLaunchStatus, which can cause a React state update on an unmounted component warning. It is best practice to store the timeout ID in a ref and clear it when the component unmounts.","path":"packages/gui-web/src/VaultAccessModal.tsx","original_line":67,"html_url":"https://example.invalid/review-root","created_at":"2026-07-10T15:05:49Z"},{"id":3560321224,"in_reply_to_id":3559925333,"user":{"login":"gemini-code-assist[bot]"},"body":"Thank you for the clarification, @maintainer. You are absolutely correct; the timeout logic has been moved to `useVaultAccessDialog.ts` and is now properly managed with cleanup routines. I appreciate you pointing out the current implementation details.","path":"packages/gui-web/src/VaultAccessModal.tsx","original_line":67,"html_url":"https://example.invalid/review-reply","created_at":"2026-07-10T16:06:22Z"}]'
	result=$(_build_inline_findings "$comments" "26938" "medium" | jq 'length')
	if [[ "$result" == "0" ]]; then
		print_result "skip PR #26938 resolved timeout thread" 0
	else
		print_result "skip PR #26938 resolved timeout thread" 1 "expected 0 findings, got ${result}"
	fi
	return 0
}

test_skips_pr27659_exact_head_verification_review() {
	local result
	# Exact source review from PR #27659: failure-related words describe the
	# verified fix and must not become a new quality-debt finding.
	# shellcheck disable=SC1112,SC2016  # exact review contains Unicode punctuation and Markdown code spans
	result=$(_test_approval_filter 'Reviewed exact head `492b3aace`.

- Corrects the maintainer gate’s unsupported `gh api --slurp --jq` combination.
- Keeps API and JSON parse failures fail-closed.
- Maintainer gate regression suites and the full local quality suite pass.' "APPROVED")
	if [[ "$result" == "skip" ]]; then
		print_result "skip PR #27659 exact-head verification review" 0
	else
		print_result "skip PR #27659 exact-head verification review" 1 "expected skip, got ${result}"
	fi
	return 0
}

test_keeps_exact_head_verification_with_remaining_concern() {
	local result
	# shellcheck disable=SC2016  # literal review body includes a Markdown code span
	result=$(_test_approval_filter 'Reviewed exact head `abcdef123`.

- The regression suites pass.
- However, this still needs error handling for malformed API output.' "APPROVED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep exact-head verification with remaining concern" 0
	else
		print_result "keep exact-head verification with remaining concern" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_actionable_approved_review() {
	# APPROVED review that also contains actionable critique — must be kept
	local result
	result=$(_test_approval_filter "Looks good overall, but you should consider adding error handling for the null case." "APPROVED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep APPROVED review with actionable critique" 0
	else
		print_result "keep APPROVED review with actionable critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_changes_requested_review() {
	# CHANGES_REQUESTED review — must always be kept
	local result
	result=$(_test_approval_filter "This looks wrong. The function is missing error handling." "CHANGES_REQUESTED")
	if [[ "$result" == "keep" ]]; then
		print_result "keep CHANGES_REQUESTED review with critique" 0
	else
		print_result "keep CHANGES_REQUESTED review with critique" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_bug_report() {
	# Review mentioning a bug — must be kept even if it starts positively
	local result
	result=$(_test_approval_filter "Good work overall, but there's a bug in the error handler — it fails when input is null.")
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with bug report despite positive opener" 0
	else
		print_result "keep review with bug report despite positive opener" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_suggestion_fence() {
	# Review with a suggestion code fence — must be kept
	local result
	result=$(_test_approval_filter 'Looks good, but consider this change:
```suggestion
return nil, fmt.Errorf("invalid input: %w", err)
```')
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with suggestion fence" 0
	else
		print_result "keep review with suggestion fence" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_keeps_review_with_strong_actionable_keyword_only() {
	# Strong actionable terms such as "needs" are intentionally outside
	# actionable_raw; they must still keep an otherwise positive review.
	local result
	result=$(_test_approval_filter "Looks good overall, but this needs a regression test.")
	if [[ "$result" == "keep" ]]; then
		print_result "keep review with strong actionable keyword only" 0
	else
		print_result "keep review with strong actionable keyword only" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_lgtm_review() {
	# With --include-positive, a pure LGTM review must be kept (not filtered)
	local result
	result=$(_test_approval_filter_include_positive "LGTM")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps LGTM review" 0
	else
		print_result "--include-positive keeps LGTM review" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_gemini_positive_summary() {
	# With --include-positive, a Gemini-style positive summary must be kept
	local result
	result=$(_test_approval_filter_include_positive "This pull request successfully addresses the issue by removing an external dependency and improves robustness.")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps Gemini positive summary" 0
	else
		print_result "--include-positive keeps Gemini positive summary" 1 "expected keep, got ${result}"
	fi
	return 0
}

test_include_positive_keeps_no_suggestions_review() {
	# With --include-positive, a "no suggestions" review must be kept
	local result
	result=$(_test_approval_filter_include_positive "Review completed. No suggestions at this time.")
	if [[ "$result" == "keep" ]]; then
		print_result "--include-positive keeps 'no suggestions' review" 0
	else
		print_result "--include-positive keeps 'no suggestions' review" 1 "expected keep, got ${result}"
	fi
	return 0
}
