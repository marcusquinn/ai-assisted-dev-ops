#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# quality-feedback-findings-lib.sh - PR finding extraction for quality-feedback-helper.sh
#
# Contains functions for scanning individual PRs and extracting actionable
# review findings (inline comments and review bodies) with filtering.
#
# Usage: source "${SCRIPT_DIR}/quality-feedback-findings-lib.sh"
#
# Dependencies: shared-constants.sh, bash 3.2+, gh, jq
# Do not execute directly — this file is sourced by quality-feedback-helper.sh.

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_QF_FINDINGS_LIB_LOADED:-}" ]] && return 0
readonly _QF_FINDINGS_LIB_LOADED=1

# _build_inline_findings: extract actionable inline review comments from a
# JSON array of PR comments. Outputs a JSON array of finding objects.
# Arguments: $1=comments_json $2=pr_num $3=min_severity
_build_inline_findings() {
	local comments="$1"
	local pr_num="$2"
	local min_severity="$3"

	echo "$comments" | jq --arg pr "$pr_num" --arg min_sev "$min_severity" '
		def resolution_or_ack:
			test(
				"aidevops:review-thread-response|" +
				"\\baddressed in[[:space:]]+`?[0-9a-f]{7,64}\\b`?|" +
				"(?s:\\bthank you for verifying\\b.*\\blooks good\\b)|" +
				"(?s:\\bthank you for the verification\\b.*?\\badding the regression test\\b.*?\\bcorrectly address(es|ed)?\\b)|" +
				"(?s:\\bthank you for the update\\b.*?\\bnon-greedy quantifiers?\\b.*?\\bregression suite\\b.*?\\bcorrectly address(es|ed)?\\b)|" +
				"(?s:\\bthank you for the confirmation\\b.*?\\baddressing the feedback\\b.*?\\bcorrectly handles?\\b.*?\\bimproves?\\b.*?\\brobustness\\b)|" +
				"(?s:\\bthank you for the update\\b.*?\\bimplementation\\b.*?\\bcorrectly address(es|ed)?\\b.*?\\brobust (approach|validation|handling)\\b)|" +
				"(?s:\\bthank you for the update\\b.*?\\busing\\b.*?\\bconsistently\\b.*?\\bcorrect approach\\b.*?\\bverification steps\\b.*?\\bconfidence\\b)|" +
				"(?s:\\bthank you for the clarification\\b.*?\\byou are (absolutely )?correct\\b.*?\\bproperly managed\\b.*?\\bcleanup routines?\\b)|" +
				"(?s:\\bthank you for the clarification\\b.*?\\byou are (absolutely )?correct\\b.*?\\bissue is (indeed )?resolved\\b)|" +
				"(?s:\\bi agree\\b.*?\\bcan be deferred\\b.*?\\brefrain from further comments?\\b)|" +
				"\\bno further concerns?\\b|" +
				"\\bno further feedback\\b|" +
				"\\bno further recommendations?\\b|" +
				"\\bno further action (is )?(needed|required)\\b|" +
				"\\bthread is resolved\\b|" +
				"(?s:\\b(already )?incorporate[sd]?\\b.*\\bnecessary synchronization\\b)|" +
				"\\brace condition\\b.*\\b(is|was) indeed addressed\\b|" +
				"\\bimplementation[[:space:]]+((is|was|has[[:space:]]+been)[[:space:]]+)?(confirmed|verified)\\b|" +
				"\\bimplementation looks correct and address(es|ed)?\\b|" +
				"\\btests are passing\\b";
				"i"
			);

		# A positive reviewer reply is closure evidence for its parent finding.
		# Suppress both the acknowledgement and the resolved root comment so an
		# unverifiable stale snippet cannot recreate already-addressed debt.
		([.[] |
			select(.in_reply_to_id != null) |
			select((.body // "") | resolution_or_ack) |
			.in_reply_to_id
		]) as $resolved_parent_ids |

		[.[] |
		# Determine reviewer type
		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("augment"; "i")) then "augment"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 elif ($login | test("sonar"; "i")) then "sonarcloud"
		 else "human"
		 end) as $reviewer |

		# Extract body for acknowledgement filtering and severity detection.
		(.body) as $body |
		# Skip thread-resolution replies and positive acknowledgements that appear
		# as inline review comments. These are closure evidence from a review-thread
		# response worker, not new quality debt (GH#24939).
		($body | resolution_or_ack) as $resolution_or_ack |
		select($resolution_or_ack | not) |
		(.id // null) as $comment_id |
		select($comment_id == null or (($resolved_parent_ids | index($comment_id)) == null)) |

		# Extract severity from body
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		# Severity filter
		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Replaced PR lines retain original_line/position but clear line; suppress
		# that stale evidence while preserving file comments and legacy payloads.
		select(.subject_type == "file" or .line != null or
			((has("line") | not) and .position != null)) |

		{
			pr: ($pr | tonumber),
			type: "inline",
			reviewer: $reviewer,
			reviewer_login: $login,
			severity: $severity,
			file: .path,
			line: (.line // .original_line),
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .created_at
		}]
	' || echo "[]"
	return 0
}

# _prefilter_reviews: first-pass filter on review bodies.
# Adds reviewer, severity fields; removes summary-only bot reviews and
# reviews below min_severity. Outputs an intermediate JSON array.
# Arguments: $1=reviews_json $2=min_severity $3=inline_counts_json
#            $4=include_positive (true|false)
_prefilter_reviews() {
	local reviews="$1"
	local min_severity="$2"
	local inline_counts_json="$3"
	local include_positive="$4"

	printf '%s' "$reviews" | jq \
		--arg min_sev "$min_severity" \
		--argjson inline_counts "$inline_counts_json" \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		select(.body != null and .body != "" and (.body | length) > 50) |

		(.user.login) as $login |
		(if ($login | test("coderabbit"; "i")) then "coderabbit"
		 elif ($login | test("gemini|google"; "i")) then "gemini"
		 elif ($login | test("augment"; "i")) then "augment"
		 elif ($login | test("codacy"; "i")) then "codacy"
		 else "human"
		 end) as $reviewer |

		# Skip summary-only bot reviews: state=COMMENTED with no inline comments.
		# Legacy Gemini Code Assist (and similar bots) may post a high-level PR walkthrough as
		# a COMMENTED review with zero inline file comments. These are descriptive
		# summaries, not actionable findings — capturing them creates false-positive
		# quality-debt issues (see GH#4528, incident: issue #3744 / PR #1121).
		# Humans and CHANGES_REQUESTED reviews are never skipped by this rule.
		# When --include-positive is set, this filter is bypassed for debugging.
		(($inline_counts[$login] // 0) == 0 and .state == "COMMENTED" and $reviewer != "human" and ($include_positive | not)) as $summary_only |
		select($summary_only | not) |

		(.body) as $body |
		(if ($body | test("security-critical\\.svg|🔴.*critical|CRITICAL"; "i")) then "critical"
		 elif ($body | test("critical\\.svg|severity:.*critical"; "i")) then "critical"
		 elif ($body | test("high-priority\\.svg|severity:.*high|HIGH"; "i")) then "high"
		 elif ($body | test("medium-priority\\.svg|severity:.*medium|MEDIUM"; "i")) then "medium"
		 elif ($body | test("low-priority\\.svg|severity:.*low|LOW|nit"; "i")) then "low"
		 else "medium"
		 end) as $severity |

		({"critical":4,"high":3,"medium":2,"low":1}[$severity] // 2) as $sev_num |
		({"critical":4,"high":3,"medium":2,"low":1}[$min_sev] // 2) as $min_num |

		select($sev_num >= $min_num) |

		# Annotate with derived fields for second-pass filtering
		. + {_reviewer: $reviewer, _severity: $severity}]
	' || echo "[]"
	return 0
}

# _apply_positive_filter: second-pass filter — removes purely positive/approving
# reviews and annotates each item with _actionable flag for output shaping.
# Arguments: $1=prefiltered_json $2=include_positive (true|false)
_apply_positive_filter() {
	local prefiltered="$1"
	local include_positive="$2"

	printf '%s' "$prefiltered" | jq \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		(._reviewer) as $reviewer |
		(.body) as $body |

		# Detect purely positive/approving reviews with no actionable critique.
		# These are false positives — filing quality-debt issues for "LGTM" or
		# "no further comments" wastes worker time (GH#4604, incident: issue #3704 / PR #1484).
		# Applies to all reviewer types including humans.
		# When --include-positive is set, these filters are bypassed for debugging.
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

		# Exact-head fix/pass evidence is praise unless contrast or unresolved-work language remains.
		(($body | test("\\breviewed exact head\\b"; "i")) and ($body | test("\\b(corrects?|keeps?|preserves?|verif(y|ies|ied)|pass(es|ed)?)\\b"; "i")) and ($body | test("\\b(tests?|checks?|suites?)\\b"; "i")) and (($body | test("\\b(but|however|although|yet|except|still|remaining|unresolved)\\b"; "i")) | not)) as $exact_head_verification |

		# Review summaries often describe the bug the PR already fixed, e.g.
		# "corrects a broken URL". Do not treat those historic defect words as
		# new quality-debt findings when the same body is otherwise praise-only.
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

		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		select($include_positive or (((($approval_only or $no_actionable_recommendation or $no_actionable_suggestions or $no_actionable_sentiment or $summary_praise_only or $exact_head_verification or $merge_status_only) and ($actionable | not))) | not)) |

		. + {_actionable: $actionable}]
	' || echo "[]"
	return 0
}

# _shape_review_findings: final-pass — apply reviewer-type select and shape output objects.
# Arguments: $1=filtered_json $2=pr_num $3=include_positive (true|false)
_shape_review_findings() {
	local filtered="$1"
	local pr_num="$2"
	local include_positive="$3"

	printf '%s' "$filtered" | jq \
		--arg pr "$pr_num" \
		--argjson include_positive "$([[ "$include_positive" == "true" ]] && echo 'true' || echo 'false')" '
		[.[] |
		(._reviewer) as $reviewer |
		(._severity) as $severity |
		(._actionable) as $actionable |
		(.body) as $body |

		# Detect merge/CI-status comments (GH#5668)
		($body | test(
			"\\bmerging\\.?$|\\bmerge (this|the) pr\\b|" +
			"\\bci (checks? )?(green|pass(ed)?|ok)\\b|" +
			"\\ball (checks?|tests?) (green|pass(ed)?|ok)\\b|" +
			"\\breview.bot.gate (pass|ok)\\b|" +
			"\\bpulse supervisor\\b"; "i")) as $merge_status_only |

		select(
			if $include_positive then true
			elif .state == "CHANGES_REQUESTED" then true
			elif $reviewer == "human" then $actionable
			elif .state == "APPROVED" then $actionable
			else
				($actionable and ($body | test(
					"\\*\\*File\\*\\*|```\\s*(suggestion|diff)|" +
					"\\bline\\s+[0-9]+\\b|\\bL[0-9]+\\b"; "i")))
			end
		) |

		select($include_positive or ($merge_status_only | not)) |

		{
			pr: ($pr | tonumber),
			type: "review_body",
			reviewer: $reviewer,
			reviewer_login: .user.login,
			severity: $severity,
			file: null,
			line: null,
			body: (.body | split("\n") | map(select(length > 0)) | first // .body),
			body_full: .body,
			url: .html_url,
			created_at: .submitted_at
		}]
	' || echo "[]"
	return 0
}

# _build_review_findings: extract actionable top-level review bodies.
# Outputs a JSON array of finding objects.
# Arguments: $1=reviews_json $2=pr_num $3=min_severity
#            $4=inline_counts_json $5=include_positive (true|false)
_build_review_findings() {
	local reviews="$1"
	local pr_num="$2"
	local min_severity="$3"
	local inline_counts_json="$4"
	local include_positive="$5"

	# Pass 1: severity + summary-only filtering
	local prefiltered
	prefiltered=$(_prefilter_reviews "$reviews" "$min_severity" "$inline_counts_json" "$include_positive") || prefiltered="[]"

	# Pass 2: positive-filter detection
	local pos_filtered
	pos_filtered=$(_apply_positive_filter "$prefiltered" "$include_positive") || pos_filtered="[]"

	# Pass 3: reviewer-type select + output shaping
	_shape_review_findings "$pos_filtered" "$pr_num" "$include_positive"
	return $?
}

# _filter_findings_by_head_files: remove findings whose file no longer exists
# at HEAD. Findings with null file (review bodies) are always kept.
# Arguments: $1=repo_slug $2=findings_json
# Outputs filtered JSON array.
_filter_findings_by_head_files() {
	local repo_slug="$1"
	local findings="$2"

	local item_count
	item_count=$(printf '%s' "$findings" | jq 'length' || echo "0")

	if [[ "$item_count" -eq 0 ]]; then
		echo "[]"
		return 0
	fi

	local head_files
	head_files=$(gh api "repos/${repo_slug}/git/trees/HEAD?recursive=1" \
		--jq '[.tree[].path]') || head_files="[]"

	local head_files_file
	head_files_file=$(mktemp) || return 1
	printf '%s' "$head_files" >"$head_files_file" || {
		rm -f "$head_files_file"
		return 1
	}

	local jq_status
	printf '%s' "$findings" | jq --slurpfile head_files "$head_files_file" '
		($head_files[0] | if type == "array" then . else [.tree[].path] end) as $head_file_paths |
		(reduce $head_file_paths[] as $f ({}; .[$f] = true)) as $existing_files |
		[.[] |
		if .file == null then .  # review bodies without file refs — keep
		elif $existing_files[.file] then .  # file still exists
		else empty  # file was removed/renamed — skip
		end]
	'
	jq_status=$?
	rm -f "$head_files_file"
	return "$jq_status"
}

# _check_empty_review_guard: return 0 (skip) when the PR has zero inline
# comments AND every review body matches a negative-finding phrase (GH#18998).
# This prevents noise issues from "no feedback" bot summaries that survive the
# per-reviewer summary_only filter. Bypassed when include_positive is "true".
# Arguments: $1=comments_json $2=reviews_json $3=pr_num $4=repo_slug
# Returns: 0 if PR should be skipped, 1 if processing should continue
_check_empty_review_guard() {
	local comments="$1"
	local reviews="$2"
	local pr_num="$3"
	local repo_slug="$4"

	local total_inline_count
	total_inline_count=$(printf '%s' "$comments" | jq 'length') || total_inline_count=0
	[[ "$total_inline_count" -ne 0 ]] && return 1

	local all_negative
	all_negative=$(printf '%s' "$reviews" | jq '
		if length == 0 then true
		else
			[.[] |
			select(.body != null and (.body | length) > 0) |
			.body |
			test(
				"no feedback|no review comments|no issues found|lgtm|looks good to me|" +
				"nothing to flag|no further|no comments|nothing actionable|" +
				"i have no (feedback|issues|comments|concerns)|" +
				"no (issues|problems|concerns|suggestions|recommendations) (found|detected|identified)|" +
				"no suggestions? (at this time|for now|currently|for improvement)|" +
				"(found|identified|detected) no (issues|problems|concerns|suggestions)";
				"i")
			] | all
		end
	') || all_negative="false"

	if [[ "$all_negative" == "true" ]]; then
		echo "[quality-feedback] skip: empty-review PR#${pr_num} in ${repo_slug} (0 inline comments, all summaries negative)" >&2
		return 0
	fi
	return 1
}

# _log_debug_skipped_summaries: emit DEBUG-level lines for summary-only reviews
# skipped during processing. No-op unless AIDEVOPS_DEBUG=1.
# Arguments: $1=reviews_json $2=inline_counts_json
_log_debug_skipped_summaries() {
	local reviews="$1"
	local inline_counts_json="$2"

	[[ "${AIDEVOPS_DEBUG:-}" != "1" ]] && return 0

	local skipped_summaries
	skipped_summaries=$(printf '%s' "$reviews" | jq \
		--argjson inline_counts "$inline_counts_json" '
		[.[] |
		select(.body != null and .body != "" and (.body | length) > 50) |
		(.user.login) as $login |
		select(
			($inline_counts[$login] // 0) == 0 and
			.state == "COMMENTED" and
			($login | test("coderabbit|gemini|google|codacy|augment"; "i"))
		) |
		"[DEBUG] Skipped summary-only review: id=\(.id) login=\(.login // .user.login) state=\(.state) body_len=\(.body | length)"
		] | .[]
	' -r 2>/dev/null || true)
	[[ -n "$skipped_summaries" ]] && printf '%s\n' "$skipped_summaries" >&2
	return 0
}

#######################################
# Return database IDs for inline comments in resolved review threads.
# GitHub's REST review-comment response does not expose thread resolution, so
# use GraphQL as a best-effort supplement. API failures preserve the existing
# REST-only behaviour rather than aborting the scan.
# Arguments: $1=repo slug $2=PR number
# Output: JSON array of numeric comment IDs
_resolved_review_comment_ids() {
	local repo_slug="$1"
	local pr_num="$2"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"

	# shellcheck disable=SC2016 # GraphQL variables are expanded by GitHub, not the shell.
	gh api graphql \
		-f query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved comments(first:100){nodes{databaseId}}}}}}}' \
		-f owner="$owner" -f repo="$repo" -F pr="$pr_num" \
		--jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved) | .comments.nodes[].databaseId]' \
		2>/dev/null || printf '[]\n'
	return 0
}

#######################################
# Scan a single merged PR for review feedback
#
# Fetches both inline review comments and review bodies from all
# reviewers (bots and humans). Extracts severity from known patterns
# (Gemini SVG markers, CodeRabbit labels). Checks if affected files
# still exist on HEAD.
#
# Arguments:
#   $1 - repo slug
#   $2 - PR number
#   $3 - minimum severity (critical|high|medium)
#   $4 - include_positive (true|false) — when true, skip positive-review filters
#        (summary-only, approval-only, no-actionable-sentiment). Useful for
#        debugging false-positive suppression. Default: false.
# Output: JSON array of findings to stdout
# Returns: 0 on success
#######################################
_scan_single_pr() {
	local repo_slug="$1"
	local pr_num="$2"
	local min_severity="$3"
	local include_positive="${4:-false}"

	echo -e "  Scanning PR #${pr_num}..." >&2

	# --- Fetch inline review comments (file-level) ---
	local comments
	comments=$(gh api "repos/${repo_slug}/pulls/${pr_num}/comments" \
		--paginate --jq '.' | jq -s 'add // []') || comments="[]"
	local resolved_comment_ids
	resolved_comment_ids=$(_resolved_review_comment_ids "$repo_slug" "$pr_num")
	comments=$(printf '%s' "$comments" | jq --argjson resolved "$resolved_comment_ids" \
		'[.[] | select((.id as $id | $resolved | index($id)) == null)]') || comments="[]"

	# --- Fetch review bodies (top-level reviews) ---
	local reviews
	reviews=$(gh api "repos/${repo_slug}/pulls/${pr_num}/reviews" \
		--paginate --jq '.' | jq -s 'add // []') || reviews="[]"

	# Process inline comments
	local inline_findings
	inline_findings=$(_build_inline_findings "$comments" "$pr_num" "$min_severity") || inline_findings="[]"

	# Build a per-reviewer inline comment count map from the already-fetched comments.
	# Used below to detect summary-only reviews (state=COMMENTED, no inline comments).
	local inline_counts_json
	inline_counts_json=$(printf '%s' "$comments" | jq '
		group_by(.user.login) |
		map({key: .[0].user.login, value: length}) |
		from_entries
	') || inline_counts_json="{}"

	# GH#18998: PR-level empty-review guard — bail out early when the PR has
	# zero inline comments AND every review body matches a negative-finding phrase.
	# Bypassed when --include-positive is set.
	if [[ "$include_positive" != "true" ]]; then
		if _check_empty_review_guard "$comments" "$reviews" "$pr_num" "$repo_slug"; then
			echo "[]"
			return 0
		fi
	fi

	# Process review bodies (for substantive reviews with body content)
	local review_findings
	review_findings=$(_build_review_findings \
		"$reviews" "$pr_num" "$min_severity" \
		"$inline_counts_json" "$include_positive") || review_findings="[]"

	# Log skipped summary-only reviews at DEBUG level for traceability
	_log_debug_skipped_summaries "$reviews" "$inline_counts_json"

	# Merge and deduplicate
	local findings
	findings=$(printf '%s\n%s' "$inline_findings" "$review_findings" | jq -s '.[0] + .[1]')

	# Filter: check if affected files still exist on HEAD
	_filter_findings_by_head_files "$repo_slug" "$findings"
	return 0
}
