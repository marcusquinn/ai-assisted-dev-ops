#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# post-merge-review-scanner.sh — Scan merged PRs for unactioned review bot feedback
#
# Finds actionable suggestions from AI review bots (CodeRabbit, Gemini Code
# Assist, claude-review, gpt-review) on recently merged PRs and creates
# GitHub issues for follow-up. Idempotent — skips PRs with existing issues.
#
# Issue bodies are worker-actionable per the t1901 mandatory rule: each
# includes file:line refs, a Worker Guidance section, direct links to the
# inline review comments, and a `diff` code fence with the diffHunk tail
# so workers can see the flagged code without opening the file.
#
# Resolution filtering (t2052): the scanner queries GitHub's GraphQL
# `reviewThreads` connection and skips threads where `isResolved` or
# `isOutdated` is true. This is the canonical, bot-agnostic signal for
# "this finding no longer applies" — it works for CodeRabbit (which also
# writes "Addressed in commit X" per-comment), Gemini (which never self-
# marks), claude-review, gpt-review, and human reviewers uniformly.
#
# Usage: post-merge-review-scanner.sh {scan|dry-run|refresh|refresh-dry-run|help} [REPO]
# Env:   SCANNER_DAYS (default 7), SCANNER_MAX_ISSUES (default 10),
#        SCANNER_LABEL (default review-followup),
#        SCANNER_PR_LIMIT (default 1000),
#        SCANNER_MAX_COMMENTS (default 10) — cap per issue body,
#        SCANNER_DIFFHUNK_LINES (default 12) — tail lines of diffHunk to show,
#        SCANNER_REFRESH_LIMIT (default 200) — max issues per refresh run,
#        SCANNER_BUDGET_SECONDS (default 540) — cooperative wall-clock budget
#          for scan runs. When exceeded, write cursor state and exit 0 so the
#          pulse stage records a healthy yielded run instead of a hard timeout.
#        SCANNER_CURSOR_DIR (default ~/.aidevops/logs/post-merge-review-scanner)
#          — directory for per-repo resume cursors and fresh run logs.
#        SCANNER_HOLD_FOR_REVIEW (default false) — opt-in escape hatch to apply
#          hold-for-review at creation time. Normally the worker itself triages
#          (verify premise → implement / close-wontfix /
#          escalate-with-recommendation), so this should stay off. The legacy
#          SCANNER_NEEDS_REVIEW variable remains a compatibility alias.
#
# Subcommands:
#   scan             — scan recent merged PRs and create new review-followup issues
#   dry-run          — same as scan but only logs what would be created
#   refresh          — rewrite open review-followup issue bodies using the current
#                      template; close issues whose source PR has no unresolved
#                      threads. Heals stale backlog without close-and-recreate.
#   refresh-dry-run  — same as refresh but logs without editing/closing
#   help             — print usage
#
# Worker-is-triager philosophy (GH#18538, PR #18743):
#   A review-followup issue is not a human-only inbox item. The dispatched
#   worker IS the triager. It must:
#     1. Verify the bot's premise by reading the cited file:line.
#     2. If premise is falsified → close the issue with a rationale comment
#        explaining what the bot got wrong (this mentors the next session
#        reading the thread and trains the noise filter).
#     3. If premise is correct + fix is obvious → implement and open a PR
#        with `Resolves #NNN`.
#     4. ONLY if premise is correct but the approach requires a genuine
#        judgment call the worker cannot make (architecture / policy /
#        breaking change) → post a decision comment containing analysis,
#        a recommended path, and the specific question that needs input,
#        then apply hold-for-review. The human reads a ready-to-
#        approve recommendation, not a blank triage task.
#
#   This is the same rule as AGENTS.md "Reasoning responsibility":
#   the model does the thinking and delivers a recommendation. Applying
#   needs-maintainer-review unconditionally at creation time is that
#   anti-pattern at the dispatch layer — punting analysis to a human who
#   then just hands it back to an AI anyway. Original GH#18538 was caused
#   by a bot finding with a false premise (Gemini claimed TODO.md's
#   "## Ready" section is auto-generated; todo-ready.sh is read-only).
#   Under this model the worker reads the section header, greps the
#   helper, closes with "premise falsified — no write path exists" — done
#   in minutes, with zero human touches.

_pmrsc_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}
#
# Prior art for the false-premise risk: AGENTS.md "AI-Generated Issue Quality"
# (AI-generated issue quality, GH#17832-17835). The AGENTS.md
# principle "Reasoning responsibility" and AGENTS.md "origin:interactive
# implies maintainer approval" are both echoes of the same rule: humans
# approve decisions, they don't re-do analysis.
#
# t1386: https://github.com/marcusquinn/aidevops/issues/2785
# GH#18538: workers timed out on review-followup issues with truncated bodies.
# GH#18538 follow-up (PR #18743): worker-is-triager model replaces default-gate model.
# t2054 (PR #18736): GraphQL reviewThreads + diffHunk context + refresh backfill.
set -euo pipefail

# Source shared-constants for gh_create_issue wrapper (t1756). Use
# ${BASH_SOURCE[0]:-$0} so that sourcing from a subshell / bash -c context
# (where BASH_SOURCE may be unset under set -u) doesn't error out.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
SCANNER_CLAIM_HELPER="${SCANNER_CLAIM_HELPER:-${SCRIPT_DIR}/dispatch-claim-helper.sh}"
SCANNER_PREDISPATCH_HELPER="${SCANNER_PREDISPATCH_HELPER:-${SCRIPT_DIR}/pre-dispatch-validator-helper.sh}"
SCANNER_CREATED_ISSUE_NUMBER=""
SCANNER_EXISTING_ISSUE_NUMBER=""
SCANNER_FALSE="false"

SCANNER_DAYS="${SCANNER_DAYS:-7}"
SCANNER_MAX_ISSUES="${SCANNER_MAX_ISSUES:-10}"
SCANNER_LABEL="${SCANNER_LABEL:-review-followup}"
SCANNER_PR_LIMIT="${SCANNER_PR_LIMIT:-1000}"
SCANNER_MAX_COMMENTS="${SCANNER_MAX_COMMENTS:-10}"
SCANNER_DIFFHUNK_LINES="${SCANNER_DIFFHUNK_LINES:-12}"
SCANNER_REFRESH_LIMIT="${SCANNER_REFRESH_LIMIT:-200}"
SCANNER_HOLD_FOR_REVIEW="${SCANNER_HOLD_FOR_REVIEW:-${SCANNER_NEEDS_REVIEW:-false}}"
SCANNER_BUDGET_SECONDS="${SCANNER_BUDGET_SECONDS:-540}"
if [[ -z "${SCANNER_CURSOR_DIR:-}" ]]; then
	if [[ -n "${HOME:-}" ]]; then
		SCANNER_CURSOR_DIR="${HOME}/.aidevops/logs/post-merge-review-scanner"
	else
		SCANNER_TMP_USER="${USER:-${LOGNAME:-$(id -un || printf '%s' shared)}}"
		SCANNER_CURSOR_DIR="/tmp/.aidevops-${SCANNER_TMP_USER}/logs/post-merge-review-scanner"
	fi
fi
# gemini-code-assist is legacy compatibility for findings on historical PRs.
BOT_RE="coderabbitai|gemini-code-assist|claude-review|gpt-review"
# ACT_RE is retained ONLY for top-level review summary filtering. For inline
# comments the thread-resolution filter is the canonical signal — every
# unresolved review thread is by definition a finding worth surfacing.
ACT_RE="should|consider|fix|change|update|refactor|missing|add"
# NOOP_RE matches review bodies that are LGTM/no-feedback/already-resolved
# statements even when they incidentally contain ACT_RE keywords. The canonical
# false-positive pattern
# (webapp#2349, Gemini on PR #2308): bot writes a PR description
# containing "refactors" (matches ACT_RE "refactor"), then concludes with "I have
# no feedback to provide." — the entire body is a description + LGTM, not an
# actionable suggestion. NOOP_RE is applied as a deny-list in
# fetch_review_summaries_md BEFORE the ACT_RE check.
#
# Tradeoff (updated to cite #20792 incident, 2026-04-24): the end-anchor was
# dropped deliberately. Gemini's exact phrasing on PR #20759 was "I have no
# feedback to provide as there were no review comments." — the mid-sentence
# continuation defeated the original end-anchored regex, causing a spurious
# followup issue (#20792). We now prefer the occasional false negative (a real
# review whose prose happens to include a noop substring mid-sentence loses its
# issue creation) over the more frequent false positive (an empty LGTM fires a
# dispatch cycle). Gemini's deterministic empty-review sentence makes the saving
# repeatable; losing a genuine finding to an incidental phrase match is rare.
NOOP_RE="(I have no feedback to provide|no feedback to provide|have no feedback|have no suggestions|no actionable feedback|no actionable suggestions|no further feedback|no issues to report|no suggestions to (add|provide|make)|no review comments|feedback was (already )?(provided|addressed|corrected)|addressed in commit|already (fixed|resolved|addressed)|has been (resolved|addressed|fixed))"

log() {
	echo "[scanner] $*" >&2
	return 0
}

scanner_run_log() {
	local repo="$1"
	mkdir -p "$SCANNER_CURSOR_DIR" 2>/dev/null || return 0
	local safe_repo
	safe_repo=$(printf '%s' "$repo" | tr '/: ' '___')
	printf '%s/%s.log' "$SCANNER_CURSOR_DIR" "$safe_repo"
	return 0
}

log_run_event() {
	local repo="$1" event="$2" detail="${3:-}"
	local ts line run_log
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	line="[scanner] run_${event} repo=${repo} ts=${ts}${detail:+ ${detail}}"
	printf '%s\n' "$line" >&2
	run_log=$(scanner_run_log "$repo")
	[[ -n "$run_log" ]] || return 0
	printf '%s\n' "$line" >>"$run_log" 2>/dev/null || true
	return 0
}

scanner_cursor_file() {
	local repo="$1"
	mkdir -p "$SCANNER_CURSOR_DIR" 2>/dev/null || return 0
	local safe_repo
	safe_repo=$(printf '%s' "$repo" | tr '/: ' '___')
	printf '%s/%s.cursor' "$SCANNER_CURSOR_DIR" "$safe_repo"
	return 0
}

scanner_budget_exhausted() {
	local start_epoch="$1"
	[[ "$SCANNER_BUDGET_SECONDS" =~ ^[0-9]+$ ]] || SCANNER_BUDGET_SECONDS=540
	local now_epoch elapsed
	now_epoch=$(date +%s)
	elapsed=$((now_epoch - start_epoch))
	[[ "$elapsed" -ge "$SCANNER_BUDGET_SECONDS" ]]
	return $?
}

write_scan_cursor() {
	local repo="$1" next_pr="$2" cursor_file
	cursor_file=$(scanner_cursor_file "$repo")
	[[ -n "$cursor_file" ]] || return 0
	jq -n --arg repo "$repo" --arg next_pr "$next_pr" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{repo: $repo, next_pr: $next_pr, updated_at: $ts}' \
		>"$cursor_file" 2>/dev/null || true
	return 0
}

read_scan_cursor_next_pr() {
	local repo="$1" cursor_file
	cursor_file=$(scanner_cursor_file "$repo")
	[[ -f "$cursor_file" ]] || return 0
	jq -r '.next_pr // empty' "$cursor_file" 2>/dev/null || true
	return 0
}

clear_scan_cursor() {
	local repo="$1" cursor_file
	cursor_file=$(scanner_cursor_file "$repo")
	[[ -n "$cursor_file" ]] || return 0
	rm -f "$cursor_file" 2>/dev/null || true
	return 0
}

get_lookback_date() {
	local days="$1"
	if date --version >/dev/null 2>&1; then
		date -d "${days} days ago" -u +%Y-%m-%dT%H:%M:%SZ
	else
		date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ
	fi
}

# Split a repo slug (owner/name) into its parts. Usage:
#   parse_repo_slug "owner/name" owner_var name_var
parse_repo_slug() {
	local slug="$1"
	local _owner_var="$2" _name_var="$3"
	local _owner="${slug%%/*}"
	local _name="${slug##*/}"
	printf -v "$_owner_var" '%s' "$_owner"
	printf -v "$_name_var" '%s' "$_name"
	return 0
}

# Fetch PR review threads via GraphQL. Returns the raw JSON response on
# stdout. Threads include isResolved, isOutdated, and the first comment's
# author, path, line, url, body, and diffHunk — everything needed to
# decide whether the finding still applies and to render it as actionable
# markdown.
#
# Exit codes:
#   0  — success (JSON response emitted to stdout)
#   2  — fetch/parse error (gh call failed or returned non-JSON).
#        Callers MUST distinguish rc 0 (fetch OK, possibly no threads) from
#        rc 2 (fetch failed) — the former means "no findings", the latter
#        means "we have no data and cannot decide". Collapsing them into a
#        single "no findings" outcome risks silently closing valid review-
#        followup issues on transient GitHub/jq errors (CodeRabbit CR #18736).
#
# Why GraphQL over REST /pulls/:pr/comments:
#   - REST does not expose thread state — we'd have to fall back to per-bot
#     marker detection (CodeRabbit "Addressed in commit X"), which misses
#     Gemini (no per-comment markers) and any future bot we add.
#   - GraphQL returns isResolved/isOutdated directly on PullRequestReviewThread.
#     These are canonical, uniform, and set by GitHub itself when the thread
#     is resolved (by a reviewer click, a re-push that invalidates the line,
#     or — for CodeRabbit — its own resolution automation).
fetch_review_threads_json() {
	local repo="$1" pr="$2"
	local owner name
	parse_repo_slug "$repo" owner name
	local resp rc=0
	local jq_array_type='array'
	# SC2016: the $owner/$name/$pr tokens inside this heredoc are GraphQL
	# variables, not bash variables. The single-quoting is required so
	# they reach the GraphQL server unexpanded.
	# shellcheck disable=SC2016
	resp=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="post-merge-review-threads-exact-cost" \
		_pmrsc_gh_read gh api graphql \
		-F owner="$owner" -F name="$name" -F pr="$pr" \
		-f query='
			query($owner: String!, $name: String!, $pr: Int!) {
				repository(owner: $owner, name: $name) {
					pullRequest(number: $pr) {
						reviewThreads(first: 100) {
							pageInfo { hasNextPage }
							nodes {
								isResolved
								isOutdated
								comments(first: 1) {
									nodes {
										author { login }
										pullRequestReview { databaseId }
										path
										line
										url
										body
										diffHunk
									}
								}
							}
						}
					}
				}
				rateLimit { cost }
			}
		') || rc=$?
	if [[ $rc -ne 0 ]]; then
		log "fetch_review_threads_json: gh graphql failed for ${repo}#${pr} (rc=${rc})"
		return 2
	fi
	# Validate response-owned quota evidence and reject partial thread sets. If
	# the API returned errors, malformed data, or more than the established
	# 100-thread bound, treat it as a fetch failure instead of silently deciding
	# from incomplete review evidence.
	if ! printf '%s' "$resp" | jq -e --arg array_type "$jq_array_type" '
		((.errors // []) | type) == $array_type and
		((.errors // []) | length) == 0 and
		(.data.rateLimit.cost | type) == "number" and
		(.data.rateLimit.cost > 0) and
		((.data.rateLimit.cost | floor) == .data.rateLimit.cost) and
		(.data.repository.pullRequest.reviewThreads.nodes | type) == $array_type and
		(.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false)
	' >/dev/null; then
		log "fetch_review_threads_json: malformed response for ${repo}#${pr}"
		return 2
	fi
	printf '%s' "$resp"
	return 0
}

# Fetch inline review comments and format each as a markdown block. Each
# block includes the bot login, file:line, a direct link to the comment,
# a `diff` fence with the tail of the diffHunk (so the worker sees the
# flagged code inline), and the full body (capped at 2000 chars) as a
# markdown blockquote.
#
# Filters:
#   - Thread must be unresolved (isResolved == false)
#   - Thread must not be outdated (isOutdated == false)
#   - First comment author must match BOT_RE
#
# Exit codes:
#   0  — success (stdout is markdown; empty string = no unresolved findings)
#   2  — fetch error (propagated from fetch_review_threads_json or jq failure)
fetch_inline_comments_md() {
	local repo="$1" pr="$2" threads_json="${3:-}"
	local json="$threads_json" rc=0
	if [[ $# -lt 3 ]]; then
		json=$(fetch_review_threads_json "$repo" "$pr") || rc=$?
		if [[ $rc -ne 0 ]]; then
			return 2
		fi
	fi
	local out
	out=$(printf '%s' "$json" | jq -r \
		--arg bots "$BOT_RE" \
		--argjson cap "$SCANNER_MAX_COMMENTS" \
		--argjson hunk "$SCANNER_DIFFHUNK_LINES" '
			[.data.repository.pullRequest.reviewThreads.nodes[]?
				| select((.isResolved // false) == false)
				| select((.isOutdated // false) == false)
				| .comments.nodes[0]?
				| select(. != null)
				| select(((.author.login // "")) | test($bots; "i"))
			]
			| if length == 0 then "" else
				.[:$cap] | map(
					"#### \(.author.login) on `\(.path // "<no path>"):\(.line // "?")`\n\n"
					+ "[View inline comment](\(.url // "#"))\n\n"
					+ (
						if ((.diffHunk // "") | length) > 0 then
							"```diff\n"
							+ ((.diffHunk // "")
								| split("\n")
								| (if length > $hunk then .[-$hunk:] else . end)
								| join("\n"))
							+ "\n```\n\n"
						else "" end
					)
					+ ((.body // "")[:2000] | split("\n") | map("> " + .) | join("\n"))
					+ "\n"
				) | join("\n")
			end
		') || {
		log "fetch_inline_comments_md: jq failed on ${repo}#${pr}"
		return 2
	}
	printf '%s' "$out"
	return 0
}

# Fetch top-level PR review summaries (Gemini's "Code Review" body, etc.)
# and format each as a markdown block. Same shape as inline comments but
# without file:line refs and without diffHunk (top-level reviews are not
# line-anchored).
#
# Filters:
#   - Review author must match BOT_RE
#   - Review body must be non-empty
#   - Body must NOT be a CodeRabbit metadata summary (e.g. "**Actionable
#     comments posted: 5**"). These are meta-comments about the per-thread
#     findings — the per-thread findings themselves appear via
#     fetch_inline_comments_md. Including the summary duplicates content
#     and adds <details> wrapper noise.
#   - Body must NOT match NOOP_RE (deny-list of no-feedback terminal phrases).
#     Applied before ACT_RE to catch Gemini's "PR description + I have no
#     feedback to provide." pattern, where the description accidentally
#     contains ACT_RE keywords (e.g. "refactors") even though the review
#     is a LGTM. See webapp#2349 for the canonical false-positive.
#   - Body must contain at least one ACT_RE keyword (cheap noise filter
#     against "LGTM"/"Reviewed" acks).
#   - Reviews whose associated inline bot threads are all resolved or outdated
#     are omitted. Bot summaries commonly recap those same findings, so keeping
#     the summary would recreate already-resolved feedback as a new issue.
#
# Exit codes:
#   0  — success (stdout is markdown; empty string = no bot summaries)
#   2  — fetch error (gh call failed or jq failure)
fetch_review_summaries_md() {
	local repo="$1" pr="$2" threads_json="${3:-}"
	local resp threads="$threads_json" resolved_review_ids rc=0 threads_rc=0
	resp=$(gh api "repos/${repo}/pulls/${pr}/reviews" --paginate) || rc=$?
	if [[ $rc -ne 0 ]]; then
		log "fetch_review_summaries_md: gh api failed for ${repo}#${pr} (rc=${rc})"
		return 2
	fi
	if [[ $# -lt 3 ]]; then
		threads=$(fetch_review_threads_json "$repo" "$pr") || threads_rc=$?
		if [[ $threads_rc -ne 0 ]]; then
			return 2
		fi
	fi
	resolved_review_ids=$(printf '%s' "$threads" | jq -c \
		--arg bots "$BOT_RE" '
			[.data.repository.pullRequest.reviewThreads.nodes[]?
				| . as $thread
				| .comments.nodes[0]?
				| select(. != null)
				| select(((.author.login // "")) | test($bots; "i"))
				| select(.pullRequestReview.databaseId != null)
				| {review_id: .pullRequestReview.databaseId, resolved: (($thread.isResolved // false) or ($thread.isOutdated // false))}
			]
			| group_by(.review_id)
			| map(select(all(.[]; .resolved)) | .[0].review_id)
		') || {
		log "fetch_review_summaries_md: resolved review mapping failed on ${repo}#${pr}"
		return 2
	}
	local out
	out=$(printf '%s' "$resp" | jq -r \
		--arg bots "$BOT_RE" \
		--arg noop "$NOOP_RE" \
		--arg acts "$ACT_RE" \
		--argjson resolved_review_ids "$resolved_review_ids" \
		--argjson cap "$SCANNER_MAX_COMMENTS" '
			[.[]?
				| select(((.user.login // "")) | test($bots; "i"))
				| .id as $review_id
				| select(($resolved_review_ids | index($review_id)) == null)
				| select(((.body // "")) | length > 0)
				# Drop CodeRabbit "Actionable comments posted: N" metadata
				# summary reviews. These add no information beyond the
				# per-thread findings and pollute the issue body with
				# boilerplate <details> wrappers.
				| select(((.body // "")) | test("^\\*\\*Actionable comments posted:|^Actionable comments posted:"; "i") | not)
				# Drop LGTM/no-feedback reviews even when they incidentally
				# contain ACT_RE keywords (e.g. Gemini "refactors X. I have
				# no feedback to provide." — "refactors" matches ACT_RE but
				# the review is a description + LGTM, not a suggestion).
				| select(((.body // "")) | test($noop; "i") | not)
				# Keep only bodies containing at least one actionable keyword
				| select(((.body // "")) | test($acts; "i"))
			]
			| if length == 0 then "" else
				.[:$cap] | map(
					"#### \(.user.login) review summary\n\n"
					+ "[View review](\(.html_url // "#"))\n\n"
					+ ((.body // "")[:2000] | split("\n") | map("> " + .) | join("\n"))
					+ "\n"
				) | join("\n")
			end
		') || {
		log "fetch_review_summaries_md: jq failed on ${repo}#${pr}"
		return 2
	}
	printf '%s' "$out"
	return 0
}

# Deduped list of `path:line` refs from unresolved inline comments,
# formatted as a markdown bullet list. Used in the Worker Guidance section
# so workers can see the full set of files to read at a glance.
#
# Uses the same GraphQL thread source as fetch_inline_comments_md so the
# file list stays in sync with the rendered comments (no phantom refs
# from resolved threads).
#
# Exit codes:
#   0  — success (stdout is markdown; empty string = no file refs)
#   2  — fetch error (propagated from fetch_review_threads_json or jq failure)
fetch_file_refs_md() {
	local repo="$1" pr="$2" threads_json="${3:-}"
	local json="$threads_json" rc=0
	if [[ $# -lt 3 ]]; then
		json=$(fetch_review_threads_json "$repo" "$pr") || rc=$?
		if [[ $rc -ne 0 ]]; then
			return 2
		fi
	fi
	local out
	out=$(printf '%s' "$json" | jq -r --arg bots "$BOT_RE" '
			[.data.repository.pullRequest.reviewThreads.nodes[]?
				| select((.isResolved // false) == false)
				| select((.isOutdated // false) == false)
				| .comments.nodes[0]?
				| select(. != null)
				| select(((.author.login // "")) | test($bots; "i"))
				| select(.path != null)
				| "- `\(.path):\(.line // "?")`"
			] | unique | .[]
		') || {
		log "fetch_file_refs_md: jq failed on ${repo}#${pr}"
		return 2
	}
	printf '%s' "$out"
	return 0
}

# Build a worker-actionable issue body for a PR's unaddressed bot feedback.
#
# Exit codes:
#   0  — success (body printed to stdout)
#   1  — no actionable content (all threads resolved/outdated, no bot
#        summaries). Sentinel that callers — notably do_refresh — use to
#        decide whether to close a follow-up issue as superseded.
#   2  — fetch error (one or more helpers failed). Callers MUST NOT treat
#        this as "no findings" — it means we do not have enough data to
#        decide, and proceeding risks closing valid follow-up issues.
#
# This 3-valued return is important for do_refresh correctness: a
# transient GitHub/jq failure would otherwise auto-close still-valid
# follow-up issues on the next refresh run. See PR #18736 CodeRabbit
# feedback for the original report.
# Render the header section of a PR follow-up body: overview, source
# PR link, and the worker-is-triager three-outcome rules (Outcomes
# A/B/C). Split out of build_pr_followup_body to keep every function
# under the 100-line complexity threshold (GH#18801). The header is
# static content driven only by ${repo}/${pr} — no findings data — so
# the split is a clean seam.
# Arguments: repo, pr
_emit_pr_followup_body_header() {
	local repo="$1" pr="$2"
	cat <<MD
<!-- aidevops:generator=review-followup source_pr=${pr} fingerprint=source-pr-${pr} -->
## Unaddressed review bot suggestions

PR #${pr} was merged with unaddressed review bot feedback. Each comment
below includes its file path, line number, a direct link to the inline
review comment, and a \`diff\` fence with the code context the bot was
flagging. Resolved and outdated threads are filtered out via GitHub's
GraphQL review-thread state. Read the relevant lines, decide whether
the suggestion is correct, and either apply the fix or close this issue
with a wontfix rationale.

**Source PR:** https://github.com/${repo}/pull/${pr}

---

### You are the triager (worker-is-triager rule)

This issue is **auto-created from review bot output** and dispatched
directly to you. Review bots can be wrong: hallucinated line refs, false
premises about codebase structure, template-driven sweeps without
measurements (see GH#17832-17835 for prior art and \`AGENTS.md\`
"AI-Generated Issue Quality"). **Do not assume the bot is correct.** Verify before acting.

You must end in exactly one of three outcomes — no fourth "hand it back
to the human" path exists. Humans approve decisions; they do not re-do
analysis.

#### Outcome A — Premise falsified → close the issue

1. Read the cited \`file:line\` (listed under *Files to modify* below).
2. If the bot's claim is factually wrong (file doesn't exist at that
   line, function doesn't behave as described, "auto-generated" section
   isn't actually auto-generated, etc.), **close the issue** with a
   comment in this shape:

   > **Premise falsified.** \<what the bot claimed\>. \<what the code
   > actually shows, with a \`file:line\` citation or one-line quote\>.
   > Not acting.

   No PR. No further dispatch. The closing comment trains the next
   session reading this thread and the noise filter.

#### Outcome B — Premise correct + fix is obvious → implement and PR

1. Verify the bot's premise as above.
2. Read the Worker Guidance section below, open a worktree, implement.
3. Open a PR with \`Resolves #<this-issue-number>\` in the body
   (use THIS issue's number, not the source PR's) so merge auto-closes it.
4. Follow the normal Lifecycle Gate (brief, tests, review-bot-gate,
   merge, postflight).

#### Outcome C — Premise correct but approach is a genuine judgment call

Only use this path if you reach it after Outcomes A and B don't apply:
the bot's finding is real, but the fix requires a decision that is
architectural, policy, breaking-change, or otherwise genuinely outside
what you can resolve autonomously. In that case, post a **decision
comment** with exactly these fields:

- **Premise check:** one line, confirming the finding is real.
- **Analysis:** 2-4 bullets on the trade-offs.
- **Recommended path:** the option you would take if the decision were
  yours, with rationale.
- **Specific question:** the single decision the human needs to make
  (yes/no or pick-one, not open-ended).

Then apply \`hold-for-review\` and stop. The human wakes up to a
ready-to-approve recommendation, not a blank task.

> **Ambiguity about scope or style is not Outcome C.** Per
> \`AGENTS.md\` "Reasoning responsibility", the model does the
> thinking and delivers a recommendation. Only escalate what is genuinely
> a maintainer-only decision.
MD
	return 0
}

# Render the Worker Guidance + findings section of a PR follow-up body
# (files to modify, implementation steps, verification, inline
# comments, review summaries). Split out of build_pr_followup_body to
# keep every function under the 100-line complexity threshold
# (GH#18801). All findings data flows through here.
# Arguments: refs_section, inline, review
_emit_pr_followup_body_findings() {
	local refs_section="$1" inline="$2" review="$3"
	cat <<MD

### Worker Guidance

**Files to modify:**

${refs_section}

**Implementation steps (Outcome B path):**

1. Read the \`diff\` block under each inline comment below — it shows the
   exact code the bot was flagging. Open the file only if you need
   surrounding context beyond what the diff tail shows.
2. Read the bot's full comment below the diff — it contains the rationale
   and any suggested change.
3. Verify the premise before implementing (see Outcome A). If the premise
   is wrong, switch to Outcome A instead of burning iterations trying to
   satisfy a wrong suggestion.
4. If multiple comments target the same file, group your edits into one
   logical commit.
5. Run \`shellcheck\` / \`markdownlint-cli2\` / project tests as appropriate.

**Verification:**

- Open the new PR with \`Resolves #<this-issue>\` so this followup is auto-closed on merge.
- If the bot's suggestion was incorrect, close this issue with a Outcome A comment — do not open a no-op PR.

### Inline comments

${inline:-_(none)_}

### PR review summaries

${review:-_(none)_}
MD
	return 0
}

# Build the full PR follow-up issue body by fetching inline comments,
# review summaries, and file refs, then composing the header and
# findings sections. Returns:
#   0  — body printed on stdout
#   1  — no unresolved findings (caller should close any existing issue)
#   2  — fetch error (caller must log + skip, NOT close)
# Arguments: repo, pr
build_pr_followup_body() {
	local repo="$1" pr="$2"
	local threads inline review file_refs refs_section
	local threads_rc=0 inline_rc=0 review_rc=0 refs_rc=0
	threads=$(fetch_review_threads_json "$repo" "$pr") || threads_rc=$?
	if [[ $threads_rc -ne 0 ]]; then
		log "build_pr_followup_body: fetch error for ${repo}#${pr} (threads=${threads_rc})"
		return 2
	fi
	inline=$(fetch_inline_comments_md "$repo" "$pr" "$threads") || inline_rc=$?
	review=$(fetch_review_summaries_md "$repo" "$pr" "$threads") || review_rc=$?
	file_refs=$(fetch_file_refs_md "$repo" "$pr" "$threads") || refs_rc=$?

	# Any fetch error → refuse to produce a body. Callers get rc=2 and
	# must log + skip (not close). This prevents closing valid issues on
	# transient errors.
	if [[ $inline_rc -ne 0 || $review_rc -ne 0 || $refs_rc -ne 0 ]]; then
		log "build_pr_followup_body: fetch error for ${repo}#${pr} (inline=${inline_rc} review=${review_rc} refs=${refs_rc})"
		return 2
	fi

	# Belt-and-braces zero-findings gate: even if NOOP_RE misses a new bot
	# phrasing, an empty inline+review pair will never create an issue.
	# Logging the skip makes the decision traceable in scanner output.
	if [[ -z "$inline" && -z "$review" ]]; then
		log "build_pr_followup_body: skip ${repo}#${pr} — zero findings (inline and review summaries both empty)"
		return 1
	fi

	if [[ -n "$file_refs" ]]; then
		refs_section="$file_refs"
	else
		refs_section="- _(No file paths in inline comments — see PR review summaries below for context)_"
	fi

	_emit_pr_followup_body_header "$repo" "$pr"
	_emit_pr_followup_body_findings "$refs_section" "$inline" "$review"
	return 0
}

issue_exists() {
	local repo="$1" pr="$2" existing_number="" rc=0
	local title_query="Review followup: PR #${pr} —"
	SCANNER_EXISTING_ISSUE_NUMBER=""
	existing_number=$(gh issue list --repo "$repo" --label "$SCANNER_LABEL" \
		--search "in:title \"${title_query}\"" --state all --limit 100 \
		--json number --jq '.[0].number // 0') || rc=$?
	if [[ "$rc" -ne 0 || ! "$existing_number" =~ ^[0-9]+$ ]]; then
		log "issue_exists: lookup failed for ${repo} source PR #${pr} (rc=${rc})"
		return 2
	fi
	if [[ "$existing_number" -gt 0 ]]; then
		SCANNER_EXISTING_ISSUE_NUMBER="$existing_number"
		return 0
	fi
	_creation_marker_issue_exists "$repo" "$pr"
	return $?
}

_creation_marker_issue_exists() {
	local repo="$1"
	local pr="$2"
	local raw_comments=""
	local marker_issue=""
	local marker_meta=""
	local stale_claim=""
	local comments_json=""
	raw_comments=$(gh api "repos/${repo}/issues/${pr}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 2
	comments_json=$(printf '%s' "$raw_comments" | jq -c '
		if type == "array" and (.[0]? | type) == "array" then [.[][]] else . end
	' 2>/dev/null) || return 2
	marker_issue=$(printf '%s' "$comments_json" | jq -r --arg source_pr "$pr" '
		[.[]
		 | select((.author_association // "") as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a))
		 | (.body // "")
		 | (capture("REVIEW_FOLLOWUP_CREATED source_pr=" + $source_pr + " issue=(?<issue>[0-9]+)")? | .issue)]
		| map(select(. != null)) | last // ""
	' 2>/dev/null) || return 2
	if [[ -z "$marker_issue" ]]; then
		stale_claim=$(printf '%s' "$comments_json" | jq -r --argjson now "$(date +%s)" '
			([.[] | select((.body // "") | ascii_downcase | contains("dispatch_claim nonce=")) | .created_at] | sort | last // "") as $claim
			| ([.[] | select((.body // "") | ascii_downcase | contains("claim_released")) | .created_at] | sort | last // "") as $release
			| if ($claim != "" and ($release == "" or $claim > $release) and ($now - ($claim | fromdateiso8601) > 120)) then "stale" else "" end
		' 2>/dev/null) || return 2
		if [[ "$stale_claim" == "stale" ]]; then
			log "PR #${pr}: unresolved stale creation claim — fail closed pending search or marker recovery"
			return 2
		fi
		return 1
	fi
	marker_meta=$(gh api "repos/${repo}/issues/${marker_issue}" \
		--jq '[.title // "", .body // ""] | @tsv' 2>/dev/null) || return 2
	if [[ "$marker_meta" == *"source_pr=${pr}"* \
		|| "$marker_meta" == *"Source PR**: #${pr}"* \
		|| "$marker_meta" == *"Review followup: PR #${pr}"* ]]; then
		log "PR #${pr}: durable creation marker references issue #${marker_issue}"
		return 0
	fi
	log "PR #${pr}: durable creation marker issue #${marker_issue} failed fingerprint verification"
	return 2
}

recover_creation_marker() {
	local repo="$1"
	local pr="$2"
	local dry_run="$3"
	local marker_rc=0
	local runner=""
	[[ "$SCANNER_EXISTING_ISSUE_NUMBER" =~ ^[1-9][0-9]*$ ]] || return 0
	_creation_marker_issue_exists "$repo" "$pr" || marker_rc=$?
	[[ "$marker_rc" -eq 1 ]] || return 0
	[[ "$dry_run" == "$SCANNER_FALSE" ]] || return 0
	runner=$(gh api user --jq '.login' 2>/dev/null) || runner=""
	[[ -n "$runner" ]] || return 0
	record_creation_marker "$repo" "$pr" "$runner" "$SCANNER_EXISTING_ISSUE_NUMBER" || true
	return 0
}

precreation_superseded() {
	local repo="$1"
	local pr="$2"
	local body="$3"
	local output="" rc=0
	if [[ ! -x "$SCANNER_PREDISPATCH_HELPER" ]]; then
		log "PR #${pr}: supersession helper unavailable — skip this scan cycle"
		return 20
	fi
	output=$(printf '%s' "$body" | "$SCANNER_PREDISPATCH_HELPER" \
		check-review-supersession "$repo" "$pr" 2>&1) || rc=$?
	if [[ "$rc" -eq 10 ]]; then
		log "PR #${pr}: findings already superseded (${output})"
		return 10
	fi
	if [[ "$rc" -ne 0 ]]; then
		log "PR #${pr}: supersession lookup uncertain (rc=${rc}) — skip this scan cycle"
		return 20
	fi
	return 0
}

acquire_creation_claim() {
	local repo="$1"
	local pr="$2"
	local runner="$3"
	local output="" rc=0
	if [[ ! -x "$SCANNER_CLAIM_HELPER" ]]; then
		log "PR #${pr}: creation claim helper unavailable"
		return 2
	fi
	output=$(DISPATCH_CLAIM_ASSIGNMENT_GUARD=disabled DISPATCH_CLAIM_MAX_AGE=120 \
		"$SCANNER_CLAIM_HELPER" claim "$pr" "$repo" "$runner" 2>&1) || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		log "PR #${pr}: creation claim not won (rc=${rc}): ${output}"
		return "$rc"
	fi
	log "PR #${pr}: creation claim won"
	return 0
}

release_creation_claim() {
	local repo="$1"
	local pr="$2"
	local runner="$3"
	local reason="$4"
	local body=""
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=review_followup_creation:${reason} runner=${runner} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
<!-- ops:end -->"
	if ! gh api "repos/${repo}/issues/${pr}/comments" --method POST --field body="$body" >/dev/null 2>&1; then
		log "PR #${pr}: failed to release creation claim (${reason})"
		return 1
	fi
	return 0
}

# Append the signature footer to a body. Uses gh-signature-helper.sh if
# available; otherwise returns the body unchanged.
append_sig_footer() {
	local body="$1"
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	local sig_footer=""
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi
	printf '%s%s' "$body" "$sig_footer"
	return 0
}

create_issue() {
	local repo="$1" pr="$2" pr_title="$3" body="$4" dry_run="$5"
	local title="Review followup: PR #${pr} — ${pr_title}"
	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] Would create: $title"
		log "[DRY-RUN] Body length: ${#body} chars"
		return 0
	fi
	gh label create "$SCANNER_LABEL" --repo "$repo" \
		--description "Unaddressed review bot feedback" --color "D4C5F9" || true
	gh label create "source:review-scanner" --repo "$repo" \
		--description "Auto-created by post-merge-review-scanner.sh" --color "C2E0C6" --force || true

	# GH#18538 follow-up: worker-is-triager model (see header comment).
	# The worker itself verifies the bot's premise and picks one of three
	# outcomes: close-as-falsified (Outcome A), implement-and-PR (B), or
	# escalate-with-recommendation (C). We do NOT apply
	# hold-for-review unconditionally — that would be the exact
	# "punt analysis to a human who hands it back to an AI" anti-pattern
	# this script is meant to avoid. SCANNER_HOLD_FOR_REVIEW is an opt-in
	# escape hatch; the worker guidance inside the issue body carries the
	# enforcement.
	#
	# GH#18670 (Fix 7): hardcode origin:worker here as defence in depth
	# against pulse-wrapper.sh forgetting to export AIDEVOPS_HEADLESS=true
	# OR against this script being invoked directly from a dev shell
	# (test runs, manual triage). gh_create_issue deduplicates labels
	# server-side so there is no harm if session_origin_label() also
	# produces origin:worker. The hardcoding is a source-of-truth
	# assertion: this scanner is by definition pulse-only output and
	# should never ship origin:interactive regardless of caller context.
	# GH#20631: tier:standard belongs in base labels so issues remain
	# dispatchable after a maintainer removes an explicit review hold.
	local label_list="$SCANNER_LABEL,source:review-scanner,origin:worker,tier:standard"
	if [[ "$SCANNER_HOLD_FOR_REVIEW" == "true" ]]; then
		gh label create "hold-for-review" --repo "$repo" \
			--description "Explicit maintainer review hold" \
			--color "B60205" || true
		label_list="${label_list},hold-for-review"
	else
		# GH#20530 (t2748): scanner-emitted issues are dispatchable by default.
		# Without auto-dispatch, pulse cannot pick them up and they sit unworked
		# indefinitely (observed: 9 issues stalled when this branch was missing).
		# Explicitly held issues skip this branch until a maintainer removes the
		# hold and deliberately restores dispatch intent.
		label_list="${label_list},auto-dispatch"
	fi

	local body_with_sig
	body_with_sig=$(append_sig_footer "$body")

	local create_output=""
	SCANNER_CREATED_ISSUE_NUMBER=""
	if ! create_output=$(gh_create_issue --repo "$repo" --title "$title" \
		--label "$label_list" \
		--body "$body_with_sig"); then
		log "PR #${pr}: issue create failed"
		return 1
	fi
	printf '%s\n' "$create_output"
	SCANNER_CREATED_ISSUE_NUMBER=$(printf '%s\n' "$create_output" | sed -En 's#.*issues/([0-9]+).*#\1#p' | tail -1)
	if [[ ! "$SCANNER_CREATED_ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
		log "PR #${pr}: issue created but number could not be parsed from wrapper output"
		return 1
	fi
	return 0
}

record_creation_marker() {
	local repo="$1"
	local pr="$2"
	local runner="$3"
	local issue_number="$4"
	local body=""
	local attempt=1
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
REVIEW_FOLLOWUP_CREATED source_pr=${pr} issue=${issue_number} fingerprint=source-pr-${pr} runner=${runner} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
<!-- ops:end -->"
	while [[ "$attempt" -le 3 ]]; do
		if gh api "repos/${repo}/issues/${pr}/comments" --method POST \
			--field body="$body" >/dev/null 2>&1; then
			return 0
		fi
		attempt=$((attempt + 1))
		[[ "$attempt" -le 3 ]] && sleep 2
	done
	log "PR #${pr}: failed to persist durable creation marker for issue #${issue_number}"
	return 1
}

_scan_one_pr() {
	local repo="$1"
	local pr="$2"
	local dry_run="$3"
	local exists_rc=0
	local build_rc=0
	local supersession_rc=0
	local body=""

	issue_exists "$repo" "$pr" || exists_rc=$?
	case "$exists_rc" in
	0)
		recover_creation_marker "$repo" "$pr" "$dry_run"
		log "PR #${pr}: issue exists, skip (use 'refresh' to rewrite)"
		return 1
		;;
	2)
		log "PR #${pr}: existing-issue lookup uncertain, skip this scan cycle"
		return 1
		;;
	esac

	body=$(build_pr_followup_body "$repo" "$pr") || build_rc=$?
	if [[ "$build_rc" -eq 1 ]]; then
		log "PR #${pr}: no actionable bot feedback, skip"
		return 1
	fi
	if [[ "$build_rc" -ne 0 || -z "$body" ]]; then
		log "PR #${pr}: fetch or body error, skip (will retry next scan)"
		return 1
	fi
	precreation_superseded "$repo" "$pr" "$body" || supersession_rc=$?
	if [[ "$supersession_rc" -ne 0 ]]; then
		return 1
	fi

	local pr_title=""
	pr_title=$(gh pr view "$pr" --repo "$repo" --json title --jq '.title' 2>/dev/null) || pr_title="Unknown"
	if [[ "$dry_run" == "true" ]]; then
		create_issue "$repo" "$pr" "$pr_title" "$body" "$dry_run"
		return $?
	fi

	local runner=""
	runner=$(gh api user --jq '.login' 2>/dev/null) || runner=""
	if [[ -z "$runner" ]]; then
		log "PR #${pr}: cannot resolve creation claimant — skip this scan cycle"
		return 1
	fi
	if ! acquire_creation_claim "$repo" "$pr" "$runner"; then
		return 1
	fi

	exists_rc=0
	issue_exists "$repo" "$pr" || exists_rc=$?
	if [[ "$exists_rc" -eq 0 ]]; then
		log "PR #${pr}: issue appeared after claim, skip creation"
		release_creation_claim "$repo" "$pr" "$runner" "post_claim_issue_exists" || true
		return 1
	fi
	if [[ "$exists_rc" -eq 2 ]]; then
		log "PR #${pr}: post-claim issue recheck uncertain, skip creation"
		release_creation_claim "$repo" "$pr" "$runner" "post_claim_lookup_uncertain" || true
		return 1
	fi

	log "PR #${pr}: creation claim winner creating issue"
	if ! create_issue "$repo" "$pr" "$pr_title" "$body" "$dry_run"; then
		release_creation_claim "$repo" "$pr" "$runner" "issue_create_failed" || true
		return 1
	fi
	if ! record_creation_marker "$repo" "$pr" "$runner" "$SCANNER_CREATED_ISSUE_NUMBER"; then
		# The issue exists, so do not report creation failure or release the
		# consistency claim. Search and the retained claim remain defensive
		# fallbacks while the marker write recovers on a later scan.
		log "PR #${pr}: issue #${SCANNER_CREATED_ISSUE_NUMBER} created without durable marker; retaining claim"
		return 0
	fi
	# Keep the winning 120-second claim active after creation. GitHub issue
	# search is eventually consistent. The durable source-PR marker is the
	# authoritative evidence after this bounded consistency window expires.
	log "PR #${pr}: issue created; creation claim retained for consistency window"
	return 0
}

do_scan() {
	local repo="$1" dry_run="$2" since_date
	local scan_start_epoch
	scan_start_epoch=$(date +%s)
	log_run_event "$repo" "start" "mode=scan dry_run=${dry_run} budget=${SCANNER_BUDGET_SECONDS}s"
	since_date=$(get_lookback_date "$SCANNER_DAYS")
	log "Scanning ${repo} since ${since_date} (${SCANNER_DAYS}d)"
	local pr_numbers
	pr_numbers=$(gh pr list --state merged --search "merged:>${since_date}" \
		--repo "$repo" --limit "$SCANNER_PR_LIMIT" --json number --jq '.[].number' || echo "")
	if [[ -z "$pr_numbers" ]]; then
		log "No merged PRs found"
		clear_scan_cursor "$repo"
		log_run_event "$repo" "finish" "status=complete issues_created=0"
		return 0
	fi
	local issues_created=0 cursor_next_pr="" resume_ready=1
	cursor_next_pr=$(read_scan_cursor_next_pr "$repo")
	if [[ -n "$cursor_next_pr" ]]; then
		if printf '%s\n' "$pr_numbers" | grep -qFx "$cursor_next_pr"; then
			resume_ready=0
			log_run_event "$repo" "resume" "next_pr=${cursor_next_pr}"
		else
			log "Cursor PR #${cursor_next_pr} not found in recent PR list; starting fresh scan"
			resume_ready=1
		fi
	fi
	while IFS= read -r pr; do
		[[ -z "$pr" ]] && continue
		if [[ "$resume_ready" -eq 0 ]]; then
			if [[ "$pr" == "$cursor_next_pr" ]]; then
				resume_ready=1
			else
				continue
			fi
		fi
		if scanner_budget_exhausted "$scan_start_epoch"; then
			write_scan_cursor "$repo" "$pr"
			log_run_event "$repo" "yield" "next_pr=${pr} issues_created=${issues_created}"
			return 0
		fi
		if [[ "$issues_created" -ge "$SCANNER_MAX_ISSUES" ]]; then
			log "Max issues reached (${SCANNER_MAX_ISSUES})"
			break
		fi
		if _scan_one_pr "$repo" "$pr" "$dry_run"; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$pr_numbers"
	clear_scan_cursor "$repo"
	log "Done. Issues created: ${issues_created}"
	log_run_event "$repo" "finish" "status=complete issues_created=${issues_created}"
	return 0
}

# Rewrite open review-followup issue bodies using the current template.
# Close issues whose source PR has zero unresolved findings (all resolved
# or outdated). Self-heals stale backlog from older scanner versions AND
# future template changes without the close-and-recreate dance.
#
# Why not just re-scan: issue_exists() in do_scan skips PRs that already
# have an issue (any state), so a re-scan leaves the old body in place.
# Refresh is the explicit path to rewrite existing bodies.
# Close a review-followup issue whose source PR has no unresolved
# findings (rc=1 from build_pr_followup_body). Split out of do_refresh
# to keep it under the 100-line complexity threshold (GH#18801). In
# dry-run mode, logs the intended close and returns 1 (=closed) so the
# caller's counter still ticks the "would-close" category. Returns:
#   1 — issue closed (or would be closed in dry-run)
#   3 — close failed (counts as skipped)
# Arguments: repo, issue_number, pr, dry_run
_refresh_close_resolved_issue() {
	local repo="$1" issue_number="$2" pr="$3" dry_run="$4"
	local close_comment="All review findings on PR #${pr} are now resolved or outdated according to GitHub's review-thread state (isResolved or isOutdated == true). Closing as superseded by the GraphQL resolution filter.

If any finding was missed, reopen this issue manually with a comment pointing at the specific thread — that feedback trains the next session on whether the filter needs tightening.

_Refreshed by \`post-merge-review-scanner.sh refresh\` (t2054)._"

	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] issue #${issue_number}: would close (PR #${pr} has no unresolved findings)"
		return 1
	fi
	if gh issue close "$issue_number" --repo "$repo" \
		--comment "$close_comment" >/dev/null; then
		log "issue #${issue_number}: closed (no unresolved findings on PR #${pr})"
		return 1
	fi
	log "issue #${issue_number}: close failed"
	return 3
}

# Process a single review-followup issue for refresh: extract source
# PR, rebuild body, then close / update / skip as appropriate. Split
# out of do_refresh to keep every function under the 100-line
# complexity threshold (GH#18801). Returns a category code the caller
# maps to counters:
#   0 — body updated (or would update in dry-run)
#   1 — issue closed (or would close in dry-run)
#   2 — body unchanged, no action
#   3 — skipped (malformed title, fetch error, empty body, edit failed)
# Arguments: repo, issue_number, title, old_body_b64, dry_run
_refresh_one_issue() {
	local repo="$1" issue_number="$2" title="$3" old_body_b64="$4" dry_run="$5"

	# Extract source PR number from title: "Review followup: PR #NNN — ..."
	local pr
	pr=$(printf '%s' "$title" | sed -n 's/^Review followup: PR #\([0-9][0-9]*\).*/\1/p')
	if [[ -z "$pr" ]]; then
		log "issue #${issue_number}: cannot extract PR number from title, skip"
		return 3
	fi

	local new_body=""
	local build_rc=0
	new_body=$(build_pr_followup_body "$repo" "$pr") || build_rc=$?

	# IMPORTANT (CodeRabbit CR on PR #18736): only close on the
	# explicit no-findings sentinel (rc=1). Any other non-zero is a
	# fetch error (rc=2) — log it and skip so we don't auto-close
	# still-valid follow-up issues on transient GitHub/jq failures.
	if [[ "$build_rc" -eq 2 ]]; then
		log "issue #${issue_number}: fetch error building body for PR #${pr}, skip (will retry next refresh)"
		return 3
	fi

	if [[ "$build_rc" -eq 1 ]]; then
		local close_rc=0
		_refresh_close_resolved_issue "$repo" "$issue_number" "$pr" "$dry_run" || close_rc=$?
		return "$close_rc"
	fi

	# Paranoid guard: rc=0 but empty body should never happen if
	# build_pr_followup_body is correct, but if it does, log it and
	# skip rather than silently closing or silently updating with
	# empty content.
	if [[ -z "$new_body" ]]; then
		log "issue #${issue_number}: inconsistent state (rc=0 but empty body) for PR #${pr}, skip"
		return 3
	fi

	# Append signature footer to match create_issue output.
	local new_body_with_sig
	new_body_with_sig=$(append_sig_footer "$new_body")

	# Decode old body for change detection.
	local old_body=""
	if [[ -n "$old_body_b64" ]]; then
		old_body=$(printf '%s' "$old_body_b64" | base64 --decode 2>/dev/null || echo "")
	fi

	# Strip signature footer from old body before comparison (the
	# footer embeds a timestamp / token count that changes every run,
	# so comparing with it would always report "changed"). The sig
	# helper emits a block starting with "<!-- aidevops:sig -->".
	local old_body_stripped="${old_body%%<!-- aidevops:sig -->*}"
	local new_body_stripped="${new_body_with_sig%%<!-- aidevops:sig -->*}"

	if [[ "$new_body_stripped" == "$old_body_stripped" ]]; then
		log "issue #${issue_number}: body unchanged, skip"
		return 2
	fi

	if [[ "$dry_run" == "true" ]]; then
		log "[DRY-RUN] issue #${issue_number}: would update body (old=${#old_body} new=${#new_body_with_sig} chars)"
		return 0
	fi

	# Use gh_issue_edit_safe (not bare `gh issue edit`) so the REST fallback
	# in shared-gh-wrappers-safe-edit.sh fires when GraphQL is rate-limited.
	# Bare `gh issue edit` always uses GraphQL and silently fails the body
	# update when the 5000/hr GraphQL budget is exhausted. PR #21733 model.
	if gh_issue_edit_safe "$issue_number" --repo "$repo" \
		--body "$new_body_with_sig" >/dev/null; then
		log "issue #${issue_number}: body updated"
		return 0
	fi
	log "issue #${issue_number}: edit failed"
	return 3
}

# Refresh all open review-followup issues in a repo: rebuild each
# body, update the issue when content changed, close when the source
# PR has no unresolved findings, skip on errors. Idempotent and safe
# under transient GitHub failures — see _refresh_one_issue for the
# per-issue state machine.
# Arguments: repo, dry_run
do_refresh() {
	local repo="$1" dry_run="$2"
	log "Refreshing open review-followup issues in ${repo} (dry_run=${dry_run})"

	local issues_json rc=0
	issues_json=$(gh issue list --repo "$repo" --label "$SCANNER_LABEL" \
		--state open --limit "$SCANNER_REFRESH_LIMIT" \
		--json number,title,body) || rc=$?
	if [[ "$rc" -ne 0 ]]; then
		log "do_refresh: gh issue list failed (rc=${rc})"
		return 2
	fi

	if [[ "$issues_json" == "[]" ]]; then
		log "No open review-followup issues found"
		return 0
	fi

	local count=0 updated=0 closed=0 unchanged=0 skipped=0

	# Stream issues as tab-separated records with base64-encoded body
	# (base64 survives newlines inside bash read loops).
	while IFS=$'\t' read -r issue_number title old_body_b64; do
		[[ -z "$issue_number" ]] && continue
		count=$((count + 1))

		local rc=0
		_refresh_one_issue "$repo" "$issue_number" "$title" \
			"$old_body_b64" "$dry_run" || rc=$?
		case "$rc" in
		0) updated=$((updated + 1)) ;;
		1) closed=$((closed + 1)) ;;
		2) unchanged=$((unchanged + 1)) ;;
		*) skipped=$((skipped + 1)) ;;
		esac
	done < <(printf '%s' "$issues_json" | jq -r '.[] | "\(.number)\t\(.title)\t\(.body // "" | @base64)"')

	log "Refresh done. Processed: ${count}, updated: ${updated}, closed: ${closed}, unchanged: ${unchanged}, skipped: ${skipped}"
	return 0
}

main() {
	local command="${1:-}" repo="${2:-}"
	if [[ -z "$command" ]]; then
		echo "Usage: $(basename "$0") {scan|dry-run|refresh|refresh-dry-run|help} [REPO]"
		return 2
	fi
	if [[ -z "$repo" ]] && [[ "$command" != "help" && "$command" != "-h" && "$command" != "--help" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
		[[ -z "$repo" ]] && {
			echo "ERROR: Cannot determine repo" >&2
			return 1
		}
	fi
	case "$command" in
	scan) do_scan "$repo" "$SCANNER_FALSE" ;;
	dry-run) do_scan "$repo" "true" ;;
	refresh) do_refresh "$repo" "$SCANNER_FALSE" ;;
	refresh-dry-run) do_refresh "$repo" "true" ;;
	-h | --help | help)
		echo "Usage: $(basename "$0") {scan|dry-run|refresh|refresh-dry-run|help} [REPO]"
		echo ""
		echo "  scan              Scan merged PRs and create new review-followup issues"
		echo "  dry-run           Same as scan but log what would be created"
		echo "  refresh           Rewrite open review-followup issue bodies; close issues"
		echo "                    whose source PR has zero unresolved findings"
		echo "  refresh-dry-run   Same as refresh but log what would be edited/closed"
		echo "  help              This message"
		;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		return 2
		;;
	esac
	return 0
}

# Source guard: only run main() when executed as a script, not when
# sourced (e.g. by the test harness). The `(return 0 2>/dev/null)`
# idiom is the canonical, portable check: `return` outside a function
# or sourced context errors, so if we CAN return 0, we're being sourced.
(return 0 2>/dev/null) || main "$@"
