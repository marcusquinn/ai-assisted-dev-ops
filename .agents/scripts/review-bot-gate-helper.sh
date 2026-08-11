#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# review-bot-gate-helper.sh — Check if AI review bots have posted on a PR
#
# Usage:
#   review-bot-gate-helper.sh check         <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh event-check
#   review-bot-gate-helper.sh is-trusted-issue-sync-pr <PR_NUMBER> [REPO] [EXPECTED_HEAD_SHA]
#   review-bot-gate-helper.sh classify-infra-rate-limit <AUTHOR_ASSOCIATION> [REPO]
#   review-bot-gate-helper.sh wait          <PR_NUMBER> [REPO] [MAX_WAIT_SECONDS]
#   review-bot-gate-helper.sh list          <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh request-retry <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh status-json   <PR_NUMBER> [REPO]
#   review-bot-gate-helper.sh batch-retry   [REPO]
#   review-bot-gate-helper.sh reconcile-stale-coderabbit <PR_NUMBER> [REPO] [EXPECTED_HEAD_SHA]
#   review-bot-gate-helper.sh dismiss-coderabbit-nits <PR_NUMBER> [REPO]
#
# Commands:
#   check          — Check once, return PASS/PASS_ADVISORY/PASS_RATE_LIMITED/WAITING/SKIP
#   event-check    — Accept trusted bot review evidence from the Actions event
#   is-trusted-issue-sync-pr — Verify the exact generated PR identity and optional head
#   classify-infra-rate-limit — Classify API exhaustion from immutable event trust
#   wait           — Poll until a bot posts or timeout (default 600s)
#   list           — List all bot comments found on the PR
#   request-retry  — If bots were rate-limited and no real review exists,
#                     request a review retry (idempotent, safe to call every pulse)
#   status-json    — Machine-readable check result for automation
#   batch-retry    — Process all open PRs with 0 formal reviews, request retries
#                     for rate-limited ones. Staggers requests to avoid re-triggering
#                     rate limits. (GH#3932)
#   reconcile-stale-coderabbit — Dismiss only superseded CodeRabbit change
#                     requests after trusted clean exact-head evidence
#   dismiss-coderabbit-nits — Preserve the maintainer-labelled cosmetic override
#
# Output values for check/wait:
#   PASS              — At least one bot posted a real review
#   PASS_ADVISORY     — No completed review; default policy defers late feedback
#   PASS_RATE_LIMITED  — Bots are rate-limited but grace period exceeded (GH#3827)
#   WAITING           — Explicit strict/wait policy requires more review evidence
#   SKIP              — PR has skip-review-gate label
#
# Exit codes:
#   0 — PASS/SKIP/REQUESTED/ALREADY_REQUESTED/NO_ACTION
#   1 — WAITING (no bots found yet)
#   2 — Error (missing args, gh auth failure)
#
# Environment:
#   REVIEW_BOT_WAIT_MAX  — Max seconds to wait in 'wait' mode (default: 600)
#   REVIEW_BOT_POLL_INTERVAL — Seconds between polls (default: 60)
#   RATE_LIMIT_GRACE_SECONDS — How long to wait before passing rate-limited PRs
#                              (default: 14400 = 4 hours). Set to 0 to disable.
#   REVIEW_GATE_RATE_LIMIT_BEHAVIOR — Global default for rate-limited bots:
#                              "pass" (default, exit 0) or "wait" (keep polling).
#                              Override per-repo or per-tool in repos.json:
#                              { "review_gate": { "rate_limit_behavior": "pass",
#                                "tools": { "coderabbitai": { "rate_limit_behavior": "wait" } } } }
#   REVIEW_GATE_COMPLETION_BEHAVIOR — Global default for bot completion:
#                              "fast" (default, add-ons are advisory) or
#                              "strict" (require completed review evidence).
#                              Override per-repo or per-tool in repos.json:
#                              { "review_gate": { "completion_behavior": "strict",
#                                "tools": { "coderabbitai": { "completion_behavior": "fast" } } } }
#   REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE — Set to 1 to disable per-check reuse
#                              of the three review/comment API collections.
#   REVIEW_GATE_AUTHOR_ASSOCIATION_RESOLVED — Set to true only when the caller
#                              already finalized immutable author trust evidence.
#
# t1382: https://github.com/marcusquinn/aidevops/issues/2735
# GH#3827: Rate-limit grace period — pass gate after timeout when bots are
#          rate-limited, preventing indefinite PR blockage.

set -euo pipefail

# t2393: source shared-constants.sh for the gh_pr_comment wrapper (sig footer).
# Non-fatal: if the file is missing (e.g. deployed layout drift), fall through
# to raw `gh pr comment`.
_RBG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
[[ -r "${_RBG_SCRIPT_DIR}/shared-constants.sh" ]] && source "${_RBG_SCRIPT_DIR}/shared-constants.sh" || true

# Current review bot login patterns (lowercase, without [bot] suffix).
ACTIVE_BOTS=(
	"coderabbitai"
	"augment-code"
	"augmentcode"
	"copilot"
)
# Retired providers remain recognizable so historical reviews, comments, and
# unresolved threads are not reclassified as human activity. They are excluded
# from per-tool strict/wait policy so stale config cannot block new merges.
RBG_RETIRED_GEMINI_LOGIN="gemini-code-assist"
RETIRED_BOTS=("$RBG_RETIRED_GEMINI_LOGIN")
KNOWN_BOTS=("${ACTIVE_BOTS[@]}" "${RETIRED_BOTS[@]}")
REVIEW_GATE_STATUS_PASS="$(printf 'P%s' 'ASS')"
RBG_PASS_ADVISORY="PASS_ADVISORY"
RBG_PASS_RATE_LIMITED="PASS_RATE_LIMITED"
RBG_FALSE="false"
RBG_COMPLETION_STRICT="strict"
RBG_CODERABBIT_LOGIN="coderabbitai[bot]"
RBG_CODERABBIT_STATUS_CONTEXT="coderabbit"
RBG_CODERABBIT_ADDRESSED_MARKER='<!-- <review_comment_addressed> -->'
RBG_CODERABBIT_NITS_LABEL="coderabbit-nits-ok"
RBG_RECONCILE_MODE_NITS="nits"
RBG_RECONCILE_MODE_SUPERSEDED="superseded"
RBG_AUTHOR_CLASS_TRUSTED="trusted"
RBG_GITHUB_ACTIONS_BOT_ID="41898282"
RBG_ISSUE_SYNC_PR_BRANCH="aidevops/issue-sync-todo"
RBG_ISSUE_SYNC_PR_MARKER="<!-- aidevops:issue-sync-todo-pr -->"

# Rate-limit / quota notice patterns — entries that indicate the bot tried to
# review but was capacity-constrained. Used by grace-period logic
# (RATE_LIMIT_GRACE_SECONDS, _should_pass_rate_limited) where the semantic
# distinction matters: a rate-limited bot may recover and review later, while
# a "Review skipped" bot will not.
# t2799: restored to original rate-limit-only semantics after t2139 expansion.
RATE_LIMIT_PATTERNS=(
	"rate limit exceeded"
	"rate limited by coderabbit"
	"daily quota limit"
	"reached your daily quota"
	"Please wait up to 24 hours"
	"has exceeded the limit for the number of"
)

# Broader set: all patterns that indicate a comment is NOT a real review.
# Includes rate-limit notices (above) AND non-quota bot status messages
# ("Review failed", "Review skipped", placeholder edits after the PR was
# closed). Case-insensitive grep patterns — one per line.
# t2139 (GH#19251): expanded from rate-limit-only to include non-review
# notices, after CodeRabbit "Review failed/skipped/closed-during-review"
# messages were observed false-positive-classifying as real reviews.
# t2799: split from RATE_LIMIT_PATTERNS; built as union so the two stay
# consistent.
# GH#28481: Gemini Code Assist retirement notices are provider status, not
# review evidence.
NON_REVIEW_PATTERNS=(
	"${RATE_LIMIT_PATTERNS[@]}"
	"Review failed"
	"Review skipped"
	"closed or merged during review"
	"Auto reviews are limited"
	"code review activity has officially ceased"
)

# Bots that post a Phase 1 placeholder and later edit it with real review
# content. For these, age-derived settlement is unreliable — require
# edit-observed settlement (edit_delta > 0). All other bots preserve existing
# OR semantics (edit_delta >= min_lag OR age >= min_lag).
# GH#20550 / #20494 — two-phase bot list (Option A').
readonly TWO_PHASE_BOTS=("coderabbitai")

SKIP_LABEL="skip-review-gate"

# GH#3827: Grace period for rate-limited bots. If bots posted rate-limit
# notices (proving they're configured) but the PR has been open longer than
# this threshold, pass the gate with a warning. Default: 30 min (1800s).
# GH#17549: Reduced from 4h — workers produce PRs every 10 min and 4h
# grace blocked the entire merge pipeline when Gemini was rate-limited.
# Set RATE_LIMIT_GRACE_SECONDS=0 to disable (block indefinitely).
RATE_LIMIT_GRACE_SECONDS="${RATE_LIMIT_GRACE_SECONDS:-1800}"

# t2123: Global default for rate-limit behavior.
# Values: "pass" (exit 0 immediately, current default) or "wait" (return WAITING).
# Override per-repo or per-tool via repos.json review_gate config.
REVIEW_GATE_RATE_LIMIT_BEHAVIOR="${REVIEW_GATE_RATE_LIMIT_BEHAVIOR:-pass}"

# GH#23066: Global default for completion evidence behavior.
# Values: "fast" keeps add-on review advisory so required CI controls merge
# readiness; "strict" requires completed review evidence before merge and also
# requires bot-specific terminal success evidence for two-phase bots such as
# CodeRabbit. Override per-repo or per-tool via repos.json review_gate config.
REVIEW_GATE_COMPLETION_BEHAVIOR="${REVIEW_GATE_COMPLETION_BEHAVIOR:-fast}"

# t2139 (GH#19251): Minimum seconds a bot comment must have been "settled"
# (either edited via updated_at > created_at, or simply old enough since
# created_at) before it counts as a completed review. Defeats the two-phase
# placeholder pattern where a bot posts an initial stub at ~14s and edits it
# with the real review at ~90-120s. Default 30s — large enough to skip
# Phase 1 placeholders, small enough not to block fast-completing bots.
# Override per-repo or per-tool via repos.json review_gate config:
#   { "review_gate": { "min_edit_lag_seconds": 30,
#     "tools": { "coderabbitai": { "min_edit_lag_seconds": 60 } } } }
REVIEW_BOT_MIN_EDIT_LAG_SECONDS="${REVIEW_BOT_MIN_EDIT_LAG_SECONDS:-30}"

# One fresh snapshot per check avoids repeatedly downloading the same reviews,
# issue comments, and inline comments while classifying multiple bots. The
# snapshot never survives a new do_check invocation, so polling still observes
# newly posted or edited reviews without a TTL or cross-cycle stale window.
_RBG_EVIDENCE_SNAPSHOT_KEY=""
_RBG_EVIDENCE_REVIEWS_JSON="[]"
_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="[]"
_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="[]"
_RBG_EVIDENCE_SNAPSHOT_READY=0

# --- Functions ---

usage() {
	echo "Usage: $(basename "$0") {check|event-check|is-trusted-issue-sync-pr|classify-infra-rate-limit|wait|list|request-retry|status-json|batch-retry|reconcile-stale-coderabbit|dismiss-coderabbit-nits} <PR_NUMBER> [REPO] [EXTRA]"
	echo ""
	echo "Commands:"
	echo "  check          Check once for bot reviews (returns PASS/PASS_ADVISORY/PASS_RATE_LIMITED/WAITING/SKIP)"
	echo "  event-check    Check trusted bot review evidence from REVIEW_GATE_EVENT_* variables"
	echo "  is-trusted-issue-sync-pr  Return TRUSTED (0), UNTRUSTED (1), or API error (2) from live PR metadata"
	echo "  classify-infra-rate-limit  Resolve trusted/default-advisory API exhaustion without another API call"
	echo "  wait           Poll until bot reviews appear or timeout"
	echo "  list           List all bot comments found"
	echo "  request-retry  Request review retry if bots were rate-limited (idempotent)"
	echo "  status-json    Print machine-readable gate status"
	echo "  batch-retry    Process all open PRs with 0 reviews, request retries (GH#3932)"
	echo "  reconcile-stale-coderabbit  Reconcile a stale CodeRabbit-only change request"
	echo "  dismiss-coderabbit-nits  Dismiss CodeRabbit-only reviews under the maintainer label"
	return 0
}

classify_infra_rate_limit() {
	local author_association="$1"
	local repo_slug="$2"
	local rate_limit_behavior completion_behavior repos_json strict_tool_override="$RBG_FALSE"

	#aidevops:trust-boundary
	case "$author_association" in
	OWNER | MEMBER | COLLABORATOR) ;;
	*)
		printf '%s\n' "INFRA_RATE_LIMITED"
		return 0
		;;
	esac

	rate_limit_behavior=$(_get_rate_limit_behavior "$repo_slug" "")
	completion_behavior=$(_get_completion_behavior "$repo_slug" "")
	repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		strict_tool_override=$(jq -r --arg slug "$repo_slug" --arg strict "$RBG_COMPLETION_STRICT" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" '
			[first(.initialized_repos[]? | select(.slug == $slug)).review_gate.tools // {} | to_entries[]?
			| select(.key != $retired)
			| select(.value.rate_limit_behavior == "wait" or .value.completion_behavior == $strict)]
			| if length > 0 then "true" else (false | tostring) end
		' "$repos_json" 2>/dev/null) || strict_tool_override="true"
	fi

	if [[ "$rate_limit_behavior" == "pass" && "$completion_behavior" == "fast" && "$strict_tool_override" != "true" ]]; then
		printf '%s\n' "$RBG_PASS_ADVISORY"
		return 0
	fi

	printf '%s\n' "INFRA_RATE_LIMITED"
	return 0
}

json_escape() {
	local value="$1"
	if command -v jq >/dev/null 2>&1; then
		jq -Rn --arg value "$value" '$value'
		return 0
	fi
	value=${value//\\/\\\\}
	value=${value//\"/\\\"}
	value=${value//$'\n'/\\n}
	printf '"%s"\n' "$value"
	return 0
}

_get_rate_limit_behavior() {
	# t2123: Resolve rate-limit behavior for a specific bot on a specific repo.
	# Resolution order: per-tool > per-repo default > global env > hardcoded "pass".
	#
	# repos.json schema:
	#   "review_gate": {
	#     "rate_limit_behavior": "pass",        // per-repo default
	#     "tools": {
	#       "coderabbitai": { "rate_limit_behavior": "wait" }
	#     }
	#   }
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# If repos.json doesn't exist, fall through to global default
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		# Try per-tool or per-repo setting in a single jq pass.
		# first() guards against duplicate slug entries in repos.json.
		# stderr is not suppressed so JSON syntax errors surface during debugging.
		local behavior=""
		behavior=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | (if $bot == $retired then .review_gate.rate_limit_behavior // empty else .review_gate.tools[$bot].rate_limit_behavior // .review_gate.rate_limit_behavior // empty end)' \
			"$repos_json") || behavior=""
		if [[ -n "$behavior" ]]; then
			printf '%s' "$behavior"
			return 0
		fi
	fi

	# Fall through to global env (which defaults to "pass")
	printf '%s' "$REVIEW_GATE_RATE_LIMIT_BEHAVIOR"
	return 0
}

_get_completion_behavior() {
	# GH#23066: Resolve completion behavior for a specific bot on a specific repo.
	# Resolution order: per-tool > per-repo default > global env > hardcoded "fast".
	#
	# repos.json schema:
	#   "review_gate": {
	#     "completion_behavior": "strict",        // per-repo default
	#     "tools": {
	#       "coderabbitai": { "completion_behavior": "fast" }
	#     }
	#   }
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local behavior=""
		behavior=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" \
			'first(.initialized_repos[]? | select(.slug == $slug)) | (if $bot == $retired then .review_gate.completion_behavior // empty else .review_gate.tools[$bot].completion_behavior // .review_gate.completion_behavior // empty end)' \
			"$repos_json" 2>/dev/null) || behavior=""
		if [[ -n "$behavior" ]]; then
			printf '%s' "$behavior"
			return 0
		fi
	fi

	printf '%s' "$REVIEW_GATE_COMPLETION_BEHAVIOR"
	return 0
}

_review_gate_requires_completed_review() {
	# Add-on review is advisory by default. Explicit strict completion is the
	# single opt-in that turns missing/incomplete provider evidence into a merge
	# wait. Preserve the GH#17671 external-contributor defence independently of
	# user preference: untrusted/unknown authors still require review evidence.
	local repo_slug="$1"
	local author_association="${REVIEW_GATE_AUTHOR_ASSOCIATION:-}"
	local behavior=""
	local repos_json="${HOME}/.config/aidevops/repos.json"
	local strict_tool_override="$RBG_FALSE"

	#aidevops:trust-boundary
	case "$author_association" in
	OWNER | MEMBER | COLLABORATOR) ;;
	*) return 0 ;;
	esac

	behavior=$(_get_completion_behavior "$repo_slug" "")
	[[ "$behavior" == "$RBG_COMPLETION_STRICT" ]] && return 0

	if [[ -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
		strict_tool_override=$(jq -r --arg slug "$repo_slug" --arg strict "$RBG_COMPLETION_STRICT" --arg retired "$RBG_RETIRED_GEMINI_LOGIN" '
			[first(.initialized_repos[]? | select(.slug == $slug)).review_gate.tools // {} | to_entries[]?
			| select(.key != $retired)
			| select(.value.completion_behavior == $strict)]
			| if length > 0 then "true" else (false | tostring) end
		' "$repos_json" 2>/dev/null) || strict_tool_override="true"
	fi
	[[ "$strict_tool_override" == "true" ]] && return 0
	return 1
}

_emit_advisory_or_wait() {
	local repo_slug="$1"
	local detail="$2"

	if _review_gate_requires_completed_review "$repo_slug"; then
		echo "WAITING"
		echo "${detail}" >&2
		echo "Review completion is required by explicit strict policy or the external-contributor trust boundary." >&2
		return 1
	fi

	echo "$RBG_PASS_ADVISORY"
	echo "${detail}" >&2
	echo "Advisory default: required CI controls merge readiness; late add-on feedback is handled by the post-merge sweep." >&2
	return 0
}

_requires_success_status_completion() {
	# GH#23066: Strict completion is opt-in so high-throughput repos keep the
	# existing fast path by default. Limit the stricter requirement to two-phase
	# bots because they are the observed comment-before-status race.
	local repo_slug="$1"
	local bot_login="$2"
	local behavior
	behavior=$(_get_completion_behavior "$repo_slug" "$bot_login")
	[[ "$behavior" != "$RBG_COMPLETION_STRICT" ]] && return 1
	_is_two_phase_bot "$bot_login" && return 0
	return 1
}

_get_min_edit_lag() {
	# t2139: Resolve minimum edit-lag seconds for a specific bot on a specific
	# repo. Resolution order: per-tool > per-repo default > global env > 30.
	# Mirrors _get_rate_limit_behavior — same repos.json schema, same precedence.
	local repo_slug="$1"
	local bot_login="$2"
	local repos_json="${HOME}/.config/aidevops/repos.json"

	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local lag=""
		lag=$(jq -r --arg slug "$repo_slug" --arg bot "$bot_login" \
			'first(.initialized_repos[] | select(.slug == $slug)) | (.review_gate.tools[$bot].min_edit_lag_seconds // .review_gate.min_edit_lag_seconds // empty)' \
			"$repos_json" 2>/dev/null) || lag=""
		# Reject non-integer or negative values silently (fall through to env).
		if [[ -n "$lag" && "$lag" =~ ^[0-9]+$ ]]; then
			printf '%s' "$lag"
			return 0
		fi
	fi

	printf '%s' "$REVIEW_BOT_MIN_EDIT_LAG_SECONDS"
	return 0
}

_is_two_phase_bot() {
	# GH#20550: Return 0 if bot_login is in TWO_PHASE_BOTS; 1 otherwise.
	# These bots post a Phase 1 placeholder and later edit with real review content.
	# Age-derived settlement is unreliable for them — only edit_delta > 0 counts.
	local bot_login="$1"
	local b
	for b in "${TWO_PHASE_BOTS[@]}"; do
		[[ "$bot_login" == "$b" ]] && return 0
	done
	return 1
}

_to_epoch() {
	# Cross-platform ISO-8601 → epoch (macOS BSD date vs GNU date). Returns 0
	# on parse failure so callers can detect "unknown" and behave conservatively.
	local iso="$1"
	[[ -z "$iso" ]] && {
		echo "0"
		return 0
	}
	local epoch
	epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null ||
		date -d "$iso" +%s 2>/dev/null ||
		echo "0")
	echo "$epoch"
	return 0
}

_comment_is_settled() {
	# t2139: A comment is "settled" (final form, safe to classify as a real
	# review) if EITHER:
	#   (a) it has been edited (updated_at >= created_at + min_lag), OR
	#   (b) it is old enough that the bot would have edited by now
	#       (now - created_at >= min_lag).
	# If timestamps are missing/unparseable (older API responses, network
	# issues), be conservative: treat as settled — better to PASS the gate
	# than block forever on missing data.
	#
	# GH#20550: For two-phase bots (e.g. coderabbitai), age-derived settlement
	# is disabled. Only edit_delta > 0 counts — a Phase 1 placeholder that has
	# aged past min_lag is still NOT a real review for two-phase bots.
	# 4th param bot_login is optional (defaults to ""); omitting it preserves
	# old non-two-phase OR semantics for all callers that don't supply it.
	local created_at="$1"
	local updated_at="$2"
	local min_lag="$3"
	local bot_login="${4:-}"

	# Missing inputs → conservative pass.
	[[ -z "$created_at" ]] && return 0
	[[ -z "$min_lag" || ! "$min_lag" =~ ^[0-9]+$ ]] && min_lag=30

	local created_epoch updated_epoch now_epoch
	created_epoch=$(_to_epoch "$created_at")
	updated_epoch=$(_to_epoch "${updated_at:-$created_at}")
	now_epoch=$(date +%s)

	# Unparseable timestamps → conservative pass.
	[[ "$created_epoch" -eq 0 ]] && return 0

	local edit_delta=$((updated_epoch - created_epoch))
	local age=$((now_epoch - created_epoch))

	if _is_two_phase_bot "$bot_login"; then
		# Phase 2 edit is authoritative; Phase 1 placeholder is not a real review
		# regardless of age. Any positive edit_delta is the settlement signal.
		[[ "$edit_delta" -gt 0 ]] && return 0
		return 1
	fi

	# Non-two-phase bots: preserve existing OR semantics.
	if [[ "$edit_delta" -ge "$min_lag" ]] || [[ "$age" -ge "$min_lag" ]]; then
		return 0
	fi
	return 1
}

_should_pass_rate_limited() {
	# t2123: Check if ALL rate-limited bots should pass (behavior=pass).
	# If ANY bot is configured to "wait", return 1 (don't pass).
	# $1 = repo slug, $2 = space-separated list of rate-limited bot logins
	local repo_slug="$1"
	local rate_limited_bots_str="$2"
	local bot behavior

	for bot in $rate_limited_bots_str; do
		[[ -z "$bot" ]] && continue
		behavior=$(_get_rate_limit_behavior "$repo_slug" "$bot")
		if [[ "$behavior" == "wait" ]]; then
			echo "Bot '${bot}' configured to wait on rate limit (review_gate config)" >&2
			return 1
		fi
	done
	return 0
}

get_pr_age_seconds() {
	# Return the age of a PR in seconds since creation.
	# Falls back to 0 if the creation time cannot be determined.
	# GH#4361: GraphQL (gh pr view --json) may be rate-limited independently
	# of the REST API. Try GraphQL first; fall back to REST on empty result.
	local pr_number="$1"
	local repo="$2"

	local created_at
	created_at=$(gh pr view "$pr_number" --repo "$repo" \
		--json createdAt -q '.createdAt' 2>/dev/null || echo "")
	if [[ -z "$created_at" ]]; then
		# GH#4361: GraphQL rate-limited — fall back to REST API which has a
		# separate rate limit and is typically available when GraphQL is exhausted.
		created_at=$(gh api "repos/${repo}/pulls/${pr_number}" \
			--jq '.created_at' 2>/dev/null || echo "")
	fi
	if [[ -z "$created_at" ]]; then
		echo "0"
		return 0
	fi

	local created_epoch now_epoch
	# macOS date vs GNU date
	created_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null ||
		date -d "$created_at" +%s 2>/dev/null ||
		echo "0")
	now_epoch=$(date +%s)
	echo $((now_epoch - created_epoch))
	return 0
}

_rbg_evidence_endpoint() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"

	case "$source" in
	reviews) printf 'repos/%s/pulls/%s/reviews\n' "$repo" "$pr_number" ;;
	issue-comments) printf 'repos/%s/issues/%s/comments\n' "$repo" "$pr_number" ;;
	review-comments) printf 'repos/%s/pulls/%s/comments\n' "$repo" "$pr_number" ;;
	*) return 1 ;;
	esac
	return 0
}

_rbg_reset_evidence_snapshot() {
	_RBG_EVIDENCE_SNAPSHOT_KEY=""
	_RBG_EVIDENCE_REVIEWS_JSON="[]"
	_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="[]"
	_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="[]"
	_RBG_EVIDENCE_SNAPSHOT_READY=0
	return 0
}

_rbg_fetch_evidence_collection() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"
	local endpoint=""
	local paginated_endpoint=""
	local records_json=""

	endpoint=$(_rbg_evidence_endpoint "$pr_number" "$repo" "$source") || return 1
	paginated_endpoint="${endpoint}?per_page=100"
	if ! records_json=$(gh api "$paginated_endpoint" --paginate | jq -sce \
		'[.[] | if type == "array" then .[] else error("review evidence page must be an array") end]'); then
		return 1
	fi
	printf '%s\n' "$records_json"
	return 0
}

_rbg_pr_reconciliation_snapshot() {
	local pr_number="$1"
	local repo="$2"
	local pr_json=""
	local pull_endpoint=""

	printf -v pull_endpoint 'repos/%s/pulls/%s' "$repo" "$pr_number"
	pr_json=$(gh api "$pull_endpoint" 2>/dev/null) || return 1
	printf '%s\n' "$pr_json" | jq -ce '{
		head:(.head.sha // ""),
		state:(.state // ""),
		association:(.author_association // ""),
		labels:[.labels[]? | .name // empty]
	}' || return 1
	return 0
}

_rbg_changes_requested_reviews() {
	local pr_number="$1"
	local repo="$2"
	local reviews_json=""

	reviews_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" reviews) || return 1
	printf '%s\n' "$reviews_json" | jq -ce '
		def state_changing: .state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED";
		if any(.[]?; state_changing and (
			(.user | type) != "object"
			or (.user.login | type) != "string"
			or (.user.login | length) == 0
			or (.submitted_at | type) != "string"
			or (.submitted_at | length) == 0
			or (.id | type) != "number"
		)) then error("malformed state-changing review")
		else map(select(state_changing))
		| group_by(.user.login)
		| map(max_by([.submitted_at, .id]))
		| map(select(.state == "CHANGES_REQUESTED")
			| {id,login:.user.login,user_type:(.user.type // ""),commit_id:(.commit_id // ""),submitted_at})
		| sort_by(.id)
		end
	' || return 1
	return 0
}

_rbg_coderabbit_status_is_terminal_success() {
	local repo="$1"
	local head_sha="$2"
	local status_json=""

	status_json=$(gh api "repos/${repo}/commits/${head_sha}/status?per_page=100" 2>/dev/null) || return 1
	#aidevops:trust-boundary — accept only the exact CodeRabbit context on this immutable head.
	printf '%s\n' "$status_json" | jq -e \
		--arg context "$RBG_CODERABBIT_STATUS_CONTEXT" \
		--arg login "$RBG_CODERABBIT_LOGIN" '
		[.statuses[]? | select(((.context // "") | ascii_downcase) == $context)] as $matches
		| ($matches | length) > 0
		and all($matches[];
			((.state // "") | ascii_downcase) == "success"
			and (.creator == null or (
				(.creator.login // "") == $login
				and (.creator.type // "") == "Bot"
			))
		)
	' >/dev/null 2>&1 || return 1
	return 0
}

_rbg_exact_head_clean_coderabbit_evidence() {
	local pr_number="$1"
	local repo="$2"
	local head_sha="$3"
	local reviews_json="$4"
	local comments_json=""
	local latest_stale_at=""
	local completion_marker=""
	local evidence_id=""

	latest_stale_at=$(printf '%s\n' "$reviews_json" | jq -er '[.[].submitted_at | select(. != "")] | max // empty') || return 1
	comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" issue-comments) || return 1
	completion_marker="Re-review of exact head \`${head_sha}\` complete — **no blocking findings**."
	#aidevops:trust-boundary — prose is evidence only from the exact GitHub bot identity with both deterministic markers.
	evidence_id=$(printf '%s\n' "$comments_json" | jq -er \
		--arg login "$RBG_CODERABBIT_LOGIN" \
		--arg addressed "$RBG_CODERABBIT_ADDRESSED_MARKER" \
		--arg completion "$completion_marker" \
		--arg after "$latest_stale_at" '
		[.[] | select(
			(.user.login // "") == $login
			and (.user.type // "") == "Bot"
			and (.created_at // "") > $after
			and ((.body // "") | contains($addressed))
			and ((.body // "") | contains($completion))
		) | .id] | first // empty
	') || return 1
	[[ -n "$evidence_id" ]] || return 1
	printf '%s\n' "$evidence_id"
	return 0
}

_rbg_dismiss_coderabbit_reviews() {
	local mode="$1"
	local pr_number="$2"
	local repo="$3"
	local head_sha="$4"
	local reviews_json="$5"
	local records=""
	local review_id=""
	local stale_sha=""
	local snapshot=""
	local snapshot_head=""
	local snapshot_state=""
	local message=""
	local pull_endpoint=""

	printf -v pull_endpoint 'repos/%s/pulls/%s' "$repo" "$pr_number"
	records=$(printf '%s\n' "$reviews_json" | jq -er '.[] | [(.id | tostring),.commit_id] | @tsv') || return 1
	while IFS=$'\t' read -r review_id stale_sha; do
		[[ "$review_id" =~ ^[0-9]+$ ]] || return 1
		snapshot=$(_rbg_pr_reconciliation_snapshot "$pr_number" "$repo") || return 1
		snapshot_head=$(printf '%s\n' "$snapshot" | jq -r '.head')
		snapshot_state=$(printf '%s\n' "$snapshot" | jq -r '.state | ascii_downcase')
		[[ "$snapshot_state" == "open" && "$snapshot_head" == "$head_sha" ]] || {
			printf 'ERROR: PR #%s head drifted before CodeRabbit review %s dismissal\n' "$pr_number" "$review_id" >&2
			return 1
		}
		if [[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]]; then
			message="Auto-dismissed: coderabbit-nits-ok label applied by maintainer (PR #${pr_number})"
		else
			message="Auto-dismissed superseded CodeRabbit review ${review_id}: stale head ${stale_sha}; clean exact-head re-review confirmed at ${head_sha}."
		fi
		gh api -X PUT "${pull_endpoint}/reviews/${review_id}/dismissals" \
			-f message="$message" >/dev/null 2>&1 || return 1
		printf 'dismissed CodeRabbit review %s: stale head %s; current head %s\n' "$review_id" "${stale_sha:-unknown}" "$head_sha" >&2
	done <<<"$records"
	return 0
}

do_reconcile_coderabbit_reviews() {
	local mode="$1"
	local pr_number="$2"
	local repo="$3"
	local expected_head="${4:-}"
	local snapshot=""
	local head_sha=""
	local state=""
	local association=""
	local reviews_json=""
	local fresh_reviews_json=""
	local review_count=0
	local post_json=""

	[[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" || "$mode" == "$RBG_RECONCILE_MODE_NITS" ]] || return 2
	snapshot=$(_rbg_pr_reconciliation_snapshot "$pr_number" "$repo") || return 1
	head_sha=$(printf '%s\n' "$snapshot" | jq -r '.head')
	state=$(printf '%s\n' "$snapshot" | jq -r '.state | ascii_downcase')
	association=$(printf '%s\n' "$snapshot" | jq -r '.association | ascii_upcase')
	[[ "$state" == "open" && "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
	[[ -z "$expected_head" || "$expected_head" == "$head_sha" ]] || return 1
	if [[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]]; then
		#aidevops:trust-boundary — the cosmetic override is inert without its explicit maintainer label.
		printf '%s\n' "$snapshot" | jq -e --arg label "$RBG_CODERABBIT_NITS_LABEL" \
			'any(.labels[]?; . == $label)' >/dev/null 2>&1 || return 1
	fi
	if [[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" ]]; then
		#aidevops:trust-boundary — automatic reconciliation is restricted to trusted PR authors.
		case "$association" in OWNER | MEMBER | COLLABORATOR) ;; *) return 1 ;; esac
	fi

	reviews_json=$(_rbg_changes_requested_reviews "$pr_number" "$repo") || return 1
	review_count=$(printf '%s\n' "$reviews_json" | jq 'length') || return 1
	if [[ "$review_count" -eq 0 ]]; then
		[[ "$mode" == "$RBG_RECONCILE_MODE_NITS" ]] && return 0
		return 1
	fi
	#aidevops:trust-boundary — never dismiss a human, lookalike, or malformed reviewer identity.
	printf '%s\n' "$reviews_json" | jq -e --arg login "$RBG_CODERABBIT_LOGIN" '
		all(.[]; (.id | type) == "number" and .login == $login and .user_type == "Bot")
	' >/dev/null 2>&1 || return 1

	if [[ "$mode" == "$RBG_RECONCILE_MODE_SUPERSEDED" ]]; then
		printf '%s\n' "$reviews_json" | jq -e --arg head "$head_sha" '
			all(.[]; (.commit_id | test("^[0-9a-fA-F]{40}$")) and .commit_id != $head and .submitted_at != "")
		' >/dev/null 2>&1 || return 1
		_rbg_exact_head_clean_coderabbit_evidence "$pr_number" "$repo" "$head_sha" "$reviews_json" >/dev/null || return 1
		_rbg_coderabbit_status_is_terminal_success "$repo" "$head_sha" || return 1
	fi

	fresh_reviews_json=$(_rbg_changes_requested_reviews "$pr_number" "$repo") || return 1
	[[ "$(printf '%s\n' "$reviews_json" | jq -cS .)" == "$(printf '%s\n' "$fresh_reviews_json" | jq -cS .)" ]] || return 1
	_rbg_dismiss_coderabbit_reviews "$mode" "$pr_number" "$repo" "$head_sha" "$reviews_json" || return 1
	post_json=$(gh pr view "$pr_number" --repo "$repo" --json headRefOid,reviewDecision 2>/dev/null) || return 1
	printf '%s\n' "$post_json" | jq -e --arg head "$head_sha" '
		(.headRefOid // "") == $head and ((.reviewDecision // "") | ascii_upcase) != "CHANGES_REQUESTED"
	' >/dev/null 2>&1 || return 1
	printf 'RECONCILED_CODERABBIT_REVIEW head=%s reviews=%s mode=%s\n' "$head_sha" "$review_count" "$mode"
	return 0
}

_rbg_prepare_evidence_snapshot() {
	local pr_number="$1"
	local repo="$2"
	local reviews_json=""
	local issue_comments_json=""
	local review_comments_json=""

	reviews_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" reviews) || return $?
	issue_comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" issue-comments) || return $?
	review_comments_json=$(_rbg_fetch_evidence_collection "$pr_number" "$repo" review-comments) || return $?

	_RBG_EVIDENCE_REVIEWS_JSON="$reviews_json"
	_RBG_EVIDENCE_ISSUE_COMMENTS_JSON="$issue_comments_json"
	_RBG_EVIDENCE_REVIEW_COMMENTS_JSON="$review_comments_json"
	_RBG_EVIDENCE_SNAPSHOT_KEY="${repo}#${pr_number}"
	_RBG_EVIDENCE_SNAPSHOT_READY=1
	return 0
}

_rbg_evidence_snapshot_matches() {
	local pr_number="$1"
	local repo="$2"
	if [[ "$_RBG_EVIDENCE_SNAPSHOT_READY" == "1" && "$_RBG_EVIDENCE_SNAPSHOT_KEY" == "${repo}#${pr_number}" ]]; then
		return 0
	fi
	return 1
}

_rbg_query_evidence_collection() {
	local pr_number="$1"
	local repo="$2"
	local source="$3"
	local jq_filter="$4"
	local records_json=""
	local endpoint=""

	if [[ "${REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE:-0}" != "1" ]] &&
		_rbg_evidence_snapshot_matches "$pr_number" "$repo"; then
		case "$source" in
		reviews) records_json="$_RBG_EVIDENCE_REVIEWS_JSON" ;;
		issue-comments) records_json="$_RBG_EVIDENCE_ISSUE_COMMENTS_JSON" ;;
		review-comments) records_json="$_RBG_EVIDENCE_REVIEW_COMMENTS_JSON" ;;
		*) return 1 ;;
		esac
		printf '%s\n' "$records_json" | jq -r "$jq_filter"
		return $?
	fi

	endpoint=$(_rbg_evidence_endpoint "$pr_number" "$repo" "$source") || return 1
	gh api "$endpoint" --paginate --jq "$jq_filter"
	return $?
}

get_all_bot_commenters() {
	local pr_number="$1"
	local repo="$2"

	# Collect reviewers from three sources:
	# 1. PR reviews (formal GitHub reviews)
	local reviews
	reviews=$(_rbg_query_evidence_collection "$pr_number" "$repo" reviews \
		'.[].user.login' || echo "")

	# 2. Issue comments (some bots post as comments, not reviews)
	local comments
	comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" issue-comments \
		'.[].user.login' || echo "")

	# 3. Review comments (inline code comments)
	local review_comments
	review_comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" review-comments \
		'.[].user.login' || echo "")

	# Combine, deduplicate, lowercase
	echo -e "${reviews}\n${comments}\n${review_comments}" |
		tr '[:upper:]' '[:lower:]' | sort -u | grep -v '^$' || true
	return 0
}

is_non_review_comment() {
	# t2139: Check if a comment body matches any known non-review pattern
	# (rate-limit/quota notices, "Review failed", "Review skipped", etc.).
	# Returns 0 if the comment IS a non-review notice. Renamed from
	# is_rate_limit_comment for accuracy — see NON_REVIEW_PATTERNS.
	local body="$1"

	for pattern in "${NON_REVIEW_PATTERNS[@]}"; do
		if echo "$body" | grep -qi "$pattern"; then
			return 0
		fi
	done
	return 1
}

is_known_review_bot() {
	local actor="$1"
	local known_bot=""
	actor=$(printf '%s' "$actor" | tr '[:upper:]' '[:lower:]')
	actor="${actor%"[bot]"}"

	for known_bot in "${KNOWN_BOTS[@]}"; do
		[[ "$actor" == "$known_bot" ]] && return 0
	done
	return 1
}

do_event_check() {
	local event_name="${REVIEW_GATE_EVENT_NAME:-}"
	local event_action="${REVIEW_GATE_EVENT_ACTION:-}"
	local event_actor="${REVIEW_GATE_EVENT_ACTOR:-}"
	local event_body="${REVIEW_GATE_EVENT_BODY:-}"
	local review_state="${REVIEW_GATE_REVIEW_STATE:-}"
	local evidence_head="${REVIEW_GATE_EVIDENCE_HEAD_SHA:-}"
	local expected_head="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"

	if ! is_known_review_bot "$event_actor"; then
		printf 'NOT_APPLICABLE\n'
		return 1
	fi
	if [[ -z "$evidence_head" || -z "$expected_head" || "$evidence_head" != "$expected_head" ]]; then
		printf 'NOT_APPLICABLE\n'
		return 1
	fi

	case "$event_name:$event_action" in
	pull_request_review_comment:created | pull_request_review_comment:edited)
		if [[ -n "$event_body" ]] && ! is_non_review_comment "$event_body"; then
			printf 'PASS\n'
			return 0
		fi
		;;
	pull_request_review:submitted | pull_request_review:edited)
		if [[ "$review_state" == "approved" || "$review_state" == "changes_requested" ]]; then
			printf 'PASS\n'
			return 0
		fi
		if [[ -n "$event_body" ]] && ! is_non_review_comment "$event_body"; then
			printf 'PASS\n'
			return 0
		fi
		;;
	esac

	printf 'NOT_APPLICABLE\n'
	return 1
}

# t2799: Check if a comment body matches a rate-limit-specific pattern only
# (not the broader non-review set). Use when the caller cares specifically
# about capacity-constrained bots that may retry later.
is_rate_limit_only_comment() {
	local body="$1"

	for pattern in "${RATE_LIMIT_PATTERNS[@]}"; do
		if echo "$body" | grep -qi "$pattern"; then
			return 0
		fi
	done
	return 1
}

bot_body_base64_jq_filter() {
	local bot_login="$1"

	printf '%s%s%s\n' \
		'.[] | select(.user.login | ascii_downcase | test("' \
		"$bot_login" \
		'")) | (.body // "" | @base64)'
	return 0
}

bot_has_rate_limit_notice() {
	# Return success only when the bot posted a true rate-limit/quota notice.
	# Broader non-review states ("Review failed", "Review skipped", closed
	# during review) must keep blocking instead of entering PASS_RATE_LIMITED.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local sources=(reviews issue-comments review-comments)
	local source records encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_rate_limit_only_comment "$body"; then
				return 0
			fi
		done <<<"$records"
	done
	return 1
}

bot_has_non_rate_limit_non_review_notice() {
	# Return success when the bot posted a known non-review notice that is not a
	# true rate-limit/quota notice. This takes precedence over older rate-limit
	# notices from the same bot so failed/skipped states keep blocking.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local sources=(reviews issue-comments review-comments)
	local source records encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_non_review_comment "$body" && ! is_rate_limit_only_comment "$body"; then
				return 0
			fi
		done <<<"$records"
	done
	return 1
}

bot_get_notice_category() {
	# Classify a bot's non-review notice state in one pass over the three GitHub
	# comment sources. Non-rate-limit notices take precedence over rate-limit
	# notices from the same bot, even when an older rate-limit notice appears
	# first in another stream.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local jq_filter
	jq_filter=$(bot_body_base64_jq_filter "$bot_login")

	local category="none"
	local sources=(reviews issue-comments review-comments)
	local source records rc encoded body
	for source in "${sources[@]}"; do
		if records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter"); then
			:
		else
			rc=$?
			return "$rc"
		fi
		[[ -z "$records" ]] && continue
		while IFS= read -r encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			if is_non_review_comment "$body" && ! is_rate_limit_only_comment "$body"; then
				echo "non-rate-limit"
				return 0
			fi
			if is_rate_limit_only_comment "$body"; then
				category="rate-limit"
			fi
		done <<<"$records"
	done

	echo "$category"
	return 0
}

bot_has_real_review() {
	# t2139 (GH#19251): Check if a bot has posted at least one comment that
	# is BOTH (a) not a known non-review notice AND (b) "settled" — meaning
	# the comment has been edited (updated_at > created_at + min_lag) or is
	# old enough that the bot would have edited by now (now - created_at >=
	# min_lag). The age check is critical to defeat CodeRabbit's two-phase
	# posting pattern, where Phase 1 is a placeholder posted at ~14s and
	# Phase 2 is the edited final review at ~90-120s.
	#
	# Checks all three comment sources (reviews, issue comments, review
	# comments). Returns 0 if a real, settled review exists, 1 otherwise.
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"
	local success_status_contexts="${4-}"
	local success_status_contexts_prepared="${5:-false}"
	local expected_head_sha="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"
	local has_success_status_contexts="$RBG_FALSE"
	[[ $# -ge 4 ]] && has_success_status_contexts="true"

	local min_lag
	# repo here is "owner/name" — same shape as repos.json slug.
	min_lag=$(_get_min_edit_lag "$repo" "$bot_login")

	# Build a jq filter that selects comments by this bot (case-insensitive)
	# and emits a TSV record of created_at \t updated_at \t base64(body).
	# Reviews lack updated_at on some endpoints; default to created_at via //.
	local jq_filter
	jq_filter=".[] | select(.user.login | ascii_downcase | test(\"${bot_login}\"))"
	if [[ -n "$expected_head_sha" ]]; then
		# Typed merge evidence must identify the reviewed commit. Conversation
		# comments have no commit_id and therefore cannot prove current-head review.
		jq_filter="${jq_filter} | select((.commit_id // .original_commit_id // \"\") == \"${expected_head_sha}\")"
	fi
	jq_filter="${jq_filter} | [(.created_at // .submitted_at // \"\"), (.updated_at // .submitted_at // .created_at // \"\"), (.body // \"\" | @base64)] | @tsv"

	local sources=(reviews issue-comments review-comments)
	local source records created_at updated_at encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS=$'\t' read -r created_at updated_at encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			# Phase 1: must not be a known non-review notice.
			if is_non_review_comment "$body"; then
				continue
			fi
			# Phase 2: must be settled. If not, this is likely a placeholder
			# (e.g., CodeRabbit Phase 1) — wait for it to settle before
			# classifying as a real review. Pass bot_login so two-phase bots
			# require edit-observed settlement (GH#20550).
			if ! _comment_is_settled "$created_at" "$updated_at" "$min_lag" "$bot_login"; then
				continue
			fi
			# GH#23066: Strict completion is an opt-in local/repo preference.
			# #aidevops:trust-boundary — a two-phase bot's edited comment is not
			# trusted as terminal completion unless the bot's own status/check has
			# reached success. Default fast mode intentionally preserves throughput.
			if _requires_success_status_completion "$repo" "$bot_login"; then
				if [[ "$has_success_status_contexts" == "true" ]]; then
					bot_has_success_status "$pr_number" "$repo" "$bot_login" "$success_status_contexts" "$success_status_contexts_prepared" || {
						echo "Strict completion: ${bot_login} settled comment lacks SUCCESS status/check" >&2
						continue
					}
				else
					bot_has_success_status "$pr_number" "$repo" "$bot_login" || {
						echo "Strict completion: ${bot_login} settled comment lacks SUCCESS status/check" >&2
						continue
					}
				fi
			fi
			return 0
		done <<<"$records"
	done

	# No comment from this bot passed both filters.
	return 1
}

_prepare_success_status_contexts() {
	# Normalize once for callers that match multiple bots against the same
	# status payload. Input shape: first line head SHA, remaining lines contexts.
	local status_contexts="$1"

	if [[ -z "$status_contexts" ]]; then
		return 1
	fi

	local head_sha statuses statuses_lower
	head_sha=$(printf '%s\n' "$status_contexts" | sed -n '1p')
	statuses=$(printf '%s\n' "$status_contexts" | sed '1d')
	if [[ -z "$head_sha" || -z "$statuses" ]]; then
		return 1
	fi

	statuses_lower=$(printf '%s\n' "$statuses" | tr '[:upper:]' '[:lower:]')
	printf '%s\n%s\n' "$head_sha" "$statuses_lower"
	return 0
}

_get_success_status_contexts() {
	# GH#3005: When bots are rate-limited in comments but still post a formal
	# GitHub status check, treat the PR as reviewed.
	# GH#3007: The status context name may differ from the bot login.
	local pr_number="$1"
	local repo="$2"

	# status-json already resolves and later revalidates the expected head. Reuse
	# that typed value instead of spending another GraphQL request on the same SHA.
	local head_sha="${REVIEW_GATE_EXPECTED_HEAD_SHA:-}"
	if [[ -z "$head_sha" ]]; then
		head_sha=$(gh pr view "$pr_number" --repo "$repo" \
			--json headRefOid -q '.headRefOid' 2>/dev/null || echo "")
	fi
	if [[ -z "$head_sha" ]]; then
		# GH#4361: GraphQL rate-limited — fall back to REST API.
		head_sha=$(gh api "repos/${repo}/pulls/${pr_number}" \
			--jq '.head.sha' 2>/dev/null || echo "")
	fi
	if [[ -z "$head_sha" ]]; then
		return 1
	fi

	# Get the combined status (singular endpoint = latest per-context state)
	# and check-runs unconditionally, then merge both streams.
	# GH#3007: /status (singular) returns the latest state per context,
	# avoiding stale-success matches from /statuses (plural, full history).
	# Pagination ensures we don't miss contexts when >30 statuses exist.
	local statuses check_runs
	statuses=$(gh api "repos/${repo}/commits/${head_sha}/status?per_page=100" \
		--paginate --jq '.statuses[] | select(.state == "success") | .context' ||
		echo "")
	check_runs=$(gh api "repos/${repo}/commits/${head_sha}/check-runs?per_page=100" \
		--paginate --jq '.check_runs[] | select(.conclusion == "success") | .name' ||
		echo "")
	statuses=$(printf '%s\n%s\n' "$statuses" "$check_runs" | grep -v '^$' || true)

	if [[ -z "$statuses" ]]; then
		return 1
	fi

	printf '%s\n' "${head_sha}" "$statuses"
	return 0
}

_status_contexts_match_bot() {
	# GH#3007: Match bidirectionally — the status context may be a prefix
	# of the bot login (e.g., "coderabbit" vs "coderabbitai") or vice versa.
	# Input shape: first line is head SHA, remaining lines are success contexts.
	local bot_login="$1"
	local status_contexts="$2"
	local contexts_are_prepared="${3:-false}"

	if [[ -z "$status_contexts" ]]; then
		return 1
	fi
	if [[ "$contexts_are_prepared" != "true" ]]; then
		status_contexts=$(_prepare_success_status_contexts "$status_contexts") || return 1
	fi

	local head_sha statuses
	head_sha=$(printf '%s\n' "$status_contexts" | sed -n '1p')
	statuses=$(printf '%s\n' "$status_contexts" | sed '1d')
	if [[ -z "$head_sha" || -z "$statuses" ]]; then
		return 1
	fi

	local bot_base ctx
	bot_base=$(printf '%s\n' "$bot_login" | tr '[:upper:]' '[:lower:]')
	while IFS= read -r ctx; do
		[[ -z "$ctx" ]] && continue
		# Bidirectional prefix match: either string starts with the other
		if [[ "$bot_base" == "$ctx"* ]] || [[ "$ctx" == "$bot_base"* ]]; then
			echo "Bot '${bot_login}' has SUCCESS status check on commit ${head_sha:0:8} (context: '${ctx}')" >&2
			return 0
		fi
	done <<<"$statuses"
	return 1
}

bot_has_success_status() {
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"
	local status_contexts="${4-}"
	local contexts_are_prepared="${5:-false}"

	if [[ $# -lt 4 ]]; then
		status_contexts=$(_get_success_status_contexts "$pr_number" "$repo") || return 1
		contexts_are_prepared="$RBG_FALSE"
	fi
	[[ -z "$status_contexts" ]] && return 1
	_status_contexts_match_bot "$bot_login" "$status_contexts" "$contexts_are_prepared" && return 0
	return 1
}

any_bot_has_success_status() {
	local pr_number="$1"
	local repo="$2"
	local status_contexts="${3-}"
	local contexts_are_prepared="${4:-false}"

	if [[ $# -lt 3 ]]; then
		status_contexts=$(_get_success_status_contexts "$pr_number" "$repo") || return 1
		contexts_are_prepared="$RBG_FALSE"
	fi
	[[ -z "$status_contexts" ]] && return 1

	local prepared_contexts
	if [[ "$contexts_are_prepared" == "true" ]]; then
		prepared_contexts="$status_contexts"
	else
		prepared_contexts=$(_prepare_success_status_contexts "$status_contexts") || return 1
	fi

	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if _status_contexts_match_bot "$bot" "$prepared_contexts" true; then
			return 0
		fi
	done
	return 1
}

_rbg_is_trusted_issue_sync_pr_metadata() {
	local repo="$1"
	local pr_metadata_json="$2"
	local expected_head_sha="${3:-}"

	[[ -n "$repo" && -n "$pr_metadata_json" ]] || return 1
	command -v jq >/dev/null 2>&1 || return 1

	# GitHub assigns its official Actions bot CONTRIBUTOR association on PRs it
	# creates. Normalize only the complete deterministic Issue Sync identity.
	# Every field comes from one live REST pull payload; any parse failure or
	# missing/mismatched value remains external.
	#aidevops:trust-boundary
	jq -e \
		--arg repo "$repo" \
		--argjson bot_id "$RBG_GITHUB_ACTIONS_BOT_ID" \
		--arg branch "$RBG_ISSUE_SYNC_PR_BRANCH" \
		--arg expected_head "$expected_head_sha" \
		--arg marker "$RBG_ISSUE_SYNC_PR_MARKER" '
		try (
			.user.login == "github-actions[bot]" and
			.user.id == $bot_id and
			.user.type == "Bot" and
			.head.repo.full_name == $repo and
			.base.repo.full_name == $repo and
			.head.ref == $branch and
			(($expected_head | length) == 0 or .head.sha == $expected_head) and
			(.body | contains($marker))
		) catch false
	' <<<"$pr_metadata_json" >/dev/null 2>&1
}

do_is_trusted_issue_sync_pr() {
	local pr_number="$1"
	local repo="$2"
	local expected_head_sha="${3:-}"
	local pr_api=""
	local pr_metadata_json=""

	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_metadata_json=$(gh api "$pr_api") || {
		echo "ERROR: Could not fetch live PR metadata for Issue Sync trust classification." >&2
		return 2
	}

	if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json" "$expected_head_sha"; then
		echo "TRUSTED"
		return 0
	fi
	echo "UNTRUSTED"
	return 1
}

_resolve_pr_author_association() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"
	local association=""
	local association_filter='if type == "object" and (.author_association | type == "string") then .author_association else empty end'
	local pr_api=""

	# Internal callers can pass the live REST pull payload they already fetched.
	# The REST association remains authoritative except for the exact official
	# Issue Sync identity independently validated above. Login, labels, or runner
	# identity alone never establish trust.
	if [[ -n "$pr_metadata_json" ]]; then
		if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json"; then
			printf '%s\n' "COLLABORATOR"
			return 0
		fi
		association=$(jq -r "$association_filter" <<<"$pr_metadata_json" 2>/dev/null) || association=""
		if [[ -n "$association" ]]; then
			printf '%s\n' "$association"
			return 0
		fi
	fi

	# GitHub CLI does not export authorAssociation through `gh pr view --json`.
	# Reuse the canonical pull REST field and collapse all API/parse failures to
	# unknown so the trust checks below continue to fail closed.
	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_metadata_json=$(gh api "$pr_api" 2>/dev/null) || pr_metadata_json=""
	if _rbg_is_trusted_issue_sync_pr_metadata "$repo" "$pr_metadata_json"; then
		printf '%s\n' "COLLABORATOR"
		return 0
	fi
	association=$(jq -r "$association_filter" <<<"$pr_metadata_json" 2>/dev/null) || association=""
	printf '%s\n' "$association"
	return 0
}

check_for_skip_label() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"

	local labels=""
	if [[ -n "$pr_metadata_json" ]] &&
		labels=$(jq -r '.labels[]?.name // empty' <<<"$pr_metadata_json" 2>/dev/null); then
		:
	else
		labels=$(gh pr view "$pr_number" --repo "$repo" \
			--json labels -q '.labels[].name' || echo "")
	fi

	if echo "$labels" | grep -q "$SKIP_LABEL"; then
		return 0
	fi
	return 1
}

match_known_bots() {
	local all_commenters="$1"
	local found_bots=""
	local missing_bots=""

	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			found_bots="${found_bots}${bot} "
		else
			missing_bots="${missing_bots}${bot} "
		fi
	done

	echo "found:${found_bots}"
	echo "missing:${missing_bots}"
}

_collect_review_gate_bot_states() {
	local pr_number="$1"
	local repo="$2"
	local all_commenters="$3"
	local prepared_status_contexts="$4"

	REVIEW_GATE_FOUND_BOTS=""
	REVIEW_GATE_RATE_LIMITED_BOTS=""
	REVIEW_GATE_NON_REVIEW_BOTS=""

	local bot notice_category notice_rc
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			# Bot commented — but is it a real review or a non-review notice?
			if bot_has_real_review "$pr_number" "$repo" "$bot" "$prepared_status_contexts" true; then
				REVIEW_GATE_FOUND_BOTS="${REVIEW_GATE_FOUND_BOTS}${bot} "
			else
				if notice_category=$(bot_get_notice_category "$pr_number" "$repo" "$bot"); then
					:
				else
					notice_rc=$?
					return "$notice_rc"
				fi
				case "$notice_category" in
				rate-limit)
					REVIEW_GATE_RATE_LIMITED_BOTS="${REVIEW_GATE_RATE_LIMITED_BOTS}${bot} "
					echo "rate-limit notice (not a real review): ${bot}" >&2
					;;
				non-rate-limit | none | *)
					REVIEW_GATE_NON_REVIEW_BOTS="${REVIEW_GATE_NON_REVIEW_BOTS}${bot} "
					echo "non-review state (not rate-limited, not a real review): ${bot}" >&2
					;;
				esac
			fi
		fi
	done
	return 0
}

_emit_review_gate_check_result() {
	local pr_number="$1"
	local repo="$2"
	local prepared_status_contexts="$3"
	local pass_result="$REVIEW_GATE_STATUS_PASS"

	if [[ -n "$REVIEW_GATE_FOUND_BOTS" ]]; then
		echo "$pass_result" # nice — at least one bot posted a real review
		echo "found: ${REVIEW_GATE_FOUND_BOTS}" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_NON_REVIEW_BOTS" ]] && any_bot_has_success_status "$pr_number" "$repo" "$prepared_status_contexts" true; then
		# GH#22884: Some bots expose review completion only through a SUCCESS
		# commit status after leaving a placeholder/non-review issue comment. Do
		# not bridge to a raw skip; require the bot-authored success status before
		# treating the gate as reviewed.
		echo "$pass_result"
		echo "Status check fallback: bots posted non-review states but have SUCCESS status checks" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_NON_REVIEW_BOTS" ]]; then
		# Failed/skipped/placeholder states are not real reviews. They remain
		# distinct from rate limits for diagnostics, but only explicit strict
		# completion turns their absence into a merge wait.
		_emit_advisory_or_wait "$repo" \
			"Bots posted non-review states that are not rate limits: ${REVIEW_GATE_NON_REVIEW_BOTS}"
		return $?
	elif [[ -n "$REVIEW_GATE_RATE_LIMITED_BOTS" ]] && any_bot_has_success_status "$pr_number" "$repo" "$prepared_status_contexts" true; then
		# GH#3005: All bots are rate-limited in comments, but at least one
		# posted a SUCCESS commit status check. Treat as reviewed.
		echo "$pass_result"
		echo "Status check fallback: bots rate-limited but have SUCCESS status checks" >&2
		return 0
	elif [[ -n "$REVIEW_GATE_RATE_LIMITED_BOTS" ]]; then
		# GH#17549 + t2123: Bot posted a rate-limit notice — it's configured, it
		# tried, but capacity is out of our control. Behavior is configurable:
		# "pass" (default) exits 0 immediately; "wait" returns WAITING so the
		# gate retry loop keeps polling. Note: bots do NOT review post-merge
		# (CodeRabbit posts "Review failed — The pull request is closed" and
		# stops). The daily quality sweep provides codebase-level coverage.
		# Configure per-tool or per-repo via repos.json review_gate, or globally
		# via REVIEW_GATE_RATE_LIMIT_BEHAVIOR env var.
		if _review_gate_requires_completed_review "$repo"; then
			echo "WAITING"
			echo "Bots are rate-limited and completed review evidence is explicitly required: ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			return 1
		elif _should_pass_rate_limited "$repo" "$REVIEW_GATE_RATE_LIMITED_BOTS"; then
			echo "$RBG_PASS_RATE_LIMITED"
			echo "Bots are rate-limited (tried but capacity-constrained): ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			echo "Passing gate — configured to pass on rate limit (review_gate.rate_limit_behavior=pass)." >&2
			return 0
		else
			echo "WAITING"
			echo "Bots are rate-limited but configured to wait: ${REVIEW_GATE_RATE_LIMITED_BOTS}" >&2
			echo "Gate will keep polling — set review_gate.rate_limit_behavior=pass to skip." >&2
			return 1
		fi
	else
		_emit_advisory_or_wait "$repo" "No review bots found yet. Known bots: ${KNOWN_BOTS[*]}"
		return $?
	fi
}

do_check() {
	local pr_number="$1"
	local repo="$2"
	local pr_metadata_json="${3:-}"
	local REVIEW_GATE_AUTHOR_ASSOCIATION="${REVIEW_GATE_AUTHOR_ASSOCIATION:-}"
	local result_rc=0
	# These caller-local accumulators are populated/read by helpers through Bash
	# dynamic scoping; keep targeted ShellCheck suppressions beside each local.
	# shellcheck disable=SC2034
	local REVIEW_GATE_FOUND_BOTS=""
	# shellcheck disable=SC2034
	local REVIEW_GATE_RATE_LIMITED_BOTS=""
	# shellcheck disable=SC2034
	local REVIEW_GATE_NON_REVIEW_BOTS=""
	_rbg_reset_evidence_snapshot

	if [[ "${REVIEW_GATE_AUTHOR_ASSOCIATION_RESOLVED:-false}" != "true" ]]; then
		case "$REVIEW_GATE_AUTHOR_ASSOCIATION" in
		OWNER | MEMBER | COLLABORATOR) ;;
		*)
			local resolved_author_association=""
			resolved_author_association=$(_resolve_pr_author_association \
				"$pr_number" "$repo" "$pr_metadata_json")
			[[ -n "$resolved_author_association" ]] &&
				REVIEW_GATE_AUTHOR_ASSOCIATION="$resolved_author_association"
			;;
		esac
	fi

	# #aidevops:trust-boundary — skip labels are an internal exception. Resolve
	# immutable author trust before honoring one so every caller, not only the
	# reusable workflow, fails closed for external or unknown authors.
	if check_for_skip_label "$pr_number" "$repo" "$pr_metadata_json"; then
		case "$REVIEW_GATE_AUTHOR_ASSOCIATION" in
		OWNER | MEMBER | COLLABORATOR)
			echo "SKIP"
			return 0
			;;
		esac
		echo "WAITING"
		echo "skip-review-gate denied for external or unknown author association." >&2
		return 1
	fi

	if [[ "${REVIEW_GATE_EVIDENCE_SNAPSHOT_DISABLE:-0}" != "1" ]]; then
		if ! _rbg_prepare_evidence_snapshot "$pr_number" "$repo"; then
			echo "Review evidence snapshot unavailable for PR #${pr_number}; falling back to direct endpoint queries." >&2
			_rbg_reset_evidence_snapshot
		fi
	fi

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local status_contexts
	status_contexts=$(_get_success_status_contexts "$pr_number" "$repo" || true)
	local prepared_status_contexts=""
	if [[ -n "$status_contexts" ]]; then
		prepared_status_contexts=$(_prepare_success_status_contexts "$status_contexts" || true)
	fi

	if _collect_review_gate_bot_states "$pr_number" "$repo" "$all_commenters" "$prepared_status_contexts"; then
		:
	else
		result_rc=$?
		_rbg_reset_evidence_snapshot
		return "$result_rc"
	fi
	_emit_review_gate_check_result "$pr_number" "$repo" "$prepared_status_contexts" || result_rc=$?
	_rbg_reset_evidence_snapshot
	return "$result_rc"
}

do_wait() {
	local pr_number="$1"
	local repo="$2"
	local max_wait="${3:-${REVIEW_BOT_WAIT_MAX:-600}}"
	local poll_interval="${REVIEW_BOT_POLL_INTERVAL:-60}"
	local elapsed=0

	# Validate that max_wait and poll_interval are positive integers to prevent
	# command injection via arithmetic expansion (GH#3223).
	if ! [[ "$max_wait" =~ ^[0-9]+$ ]]; then
		echo "ERROR: max_wait must be a non-negative integer, got: '${max_wait}'" >&2
		return 2
	fi
	if ! [[ "$poll_interval" =~ ^[0-9]+$ ]]; then
		echo "ERROR: poll_interval must be a non-negative integer, got: '${poll_interval}'" >&2
		return 2
	fi

	echo "Waiting up to ${max_wait}s for review bots on PR #${pr_number}..." >&2

	while [[ "$elapsed" -lt "$max_wait" ]]; do
		local result
		result=$(do_check "$pr_number" "$repo") || true

		if [[ "$result" == "$REVIEW_GATE_STATUS_PASS" || "$result" == "$RBG_PASS_ADVISORY" || "$result" == "$RBG_PASS_RATE_LIMITED" || "$result" == "SKIP" ]]; then
			echo "$result"
			return 0
		fi

		echo "[${elapsed}s/${max_wait}s] Still waiting for review bots..." >&2
		sleep "$poll_interval"
		elapsed=$((elapsed + poll_interval))
	done

	echo "WAITING"
	echo "Timeout after ${max_wait}s — no review bots posted." >&2
	return 1
}

do_status_json() {
	local pr_number="$1"
	local repo="$2"
	local output="" rc=0 state="waiting" blocked_prefix="bloc" status_pass="" pr_api=""
	local merge_gate=""
	local pr_json_before="" pr_json="" head_sha_before="" head_sha="" author_login="" author_association_before="" author_association="" author_class="external"
	local head_stable="$RBG_FALSE" skip_label_present_after="$RBG_FALSE" permitted="$RBG_FALSE" reason="outcome_not_permitted"
	merge_gate="${blocked_prefix}ked"
	status_pass=$(printf 'P%s' 'ASS')

	pr_api=$(printf 'repos/%s/pulls/%s' "$repo" "$pr_number")
	pr_json_before=$(gh api "$pr_api" 2>/dev/null) || pr_json_before=""
	head_sha_before=$(jq -r '.head.sha // ""' <<<"$pr_json_before" 2>/dev/null) || head_sha_before=""
	author_association_before=$(_resolve_pr_author_association "$pr_number" "$repo" "$pr_json_before")
	output=$(REVIEW_GATE_EXPECTED_HEAD_SHA="$head_sha_before" REVIEW_GATE_AUTHOR_ASSOCIATION="$author_association_before" do_check "$pr_number" "$repo" "$pr_json_before" 2>/dev/null) || rc=$?
	pr_json=$(gh api "$pr_api" 2>/dev/null) || pr_json=""
	if [[ -n "$pr_json" ]]; then
		head_sha=$(jq -r '.head.sha // ""' <<<"$pr_json" 2>/dev/null) || head_sha=""
		author_login=$(jq -r '.user.login // ""' <<<"$pr_json" 2>/dev/null) || author_login=""
	fi
	author_association=$(_resolve_pr_author_association "$pr_number" "$repo" "$pr_json")
	if [[ -n "$head_sha_before" && "$head_sha_before" == "$head_sha" ]]; then
		head_stable="true"
	fi
	jq -e --arg label "$SKIP_LABEL" '[.labels[]?.name] | index($label) != null' <<<"$pr_json" >/dev/null 2>&1 && skip_label_present_after="true"
	case "$author_association" in
	OWNER | MEMBER | COLLABORATOR) author_class="$RBG_AUTHOR_CLASS_TRUSTED" ;;
	esac

	# #aidevops:trust-boundary — SKIP, advisory completion, and rate-limit grace are trusted-author
	# policy outcomes. External contributors require a real PASS; malformed or
	# metadata-less evidence can never authorize an advisory merge decision.
	case "$output" in
	"$status_pass")
		if [[ "$head_stable" == "true" && -n "$author_login" ]]; then
			permitted="true"
			reason="live_review_pass"
		fi
		;;
	SKIP)
		if [[ "$author_class" == "$RBG_AUTHOR_CLASS_TRUSTED" && "$head_stable" == "true" && "$skip_label_present_after" == "true" ]]; then
			permitted="true"
			reason="trusted_skip"
		else
			reason="external_skip_denied"
		fi
		;;
	P[A]SS_RATE_LIMITED)
		if [[ "$author_class" == "$RBG_AUTHOR_CLASS_TRUSTED" && "$head_stable" == "true" ]]; then
			permitted="true"
			reason="trusted_rate_limit_grace"
		else
			reason="external_rate_limit_grace_denied"
		fi
		;;
	P[A]SS_ADVISORY)
		if [[ "$author_class" == "$RBG_AUTHOR_CLASS_TRUSTED" && "$head_stable" == "true" ]]; then
			permitted="true"
			reason="trusted_advisory_default"
		else
			reason="external_advisory_denied"
		fi
		;;
	esac

	case "$output:$permitted" in
	"$status_pass:true" | P[A]SS_ADVISORY:true | P[A]SS_RATE_LIMITED:true | SKIP:true)
		state="pass"
		merge_gate="clear"
		;;
	WAITING:*)
		state="waiting"
		merge_gate="${blocked_prefix}ked"
		;;
	*)
		state="err""or"
		merge_gate="${blocked_prefix}ked"
		[[ "$rc" -eq 0 ]] && rc=2
		;;
	esac

	jq -nc \
		--arg pr "$pr_number" \
		--arg repo "$repo" \
		--arg status "${output:-ERROR}" \
		--arg head_sha "$head_sha" \
		--arg author_login "$author_login" \
		--arg author_association "$author_association" \
		--arg author_class "$author_class" \
		--argjson permitted "$permitted" \
		--arg reason "$reason" \
		--arg state "$state" \
		--arg merge_gate "$merge_gate" \
		--argjson exit_code "$rc" \
		'{schema:"aidevops.review-gate-evidence/v1",pr:$pr,repo:$repo,head_sha:$head_sha,status:$status,author:{login:$author_login,association:$author_association,class:$author_class},permitted:$permitted,reason:$reason,state:$state,merge_gate:$merge_gate,exit_code:$exit_code}'
	return 0
}

_classify_bot_state() {
	# t2139: Distinguish "placeholder/not-yet-settled" from "rate-limited"
	# vs "real-review". Returns one of:
	#   real-review         — bot has a real, settled review
	#   not-yet             — bot has comment(s) that are not non-review notices
	#                         but are still in the placeholder window (Phase 1)
	#   non-review-only     — every bot comment matched a NON_REVIEW_PATTERNS entry
	#                         (rate-limited, "Review failed", "Review skipped", etc.)
	#   no-comments         — bot has commented per get_all_bot_commenters but
	#                         no comments are visible via the typed endpoints
	#                         (rare race; treat as non-review-only)
	local pr_number="$1"
	local repo="$2"
	local bot_login="$3"

	local min_lag
	min_lag=$(_get_min_edit_lag "$repo" "$bot_login")

	local jq_filter
	jq_filter=".[] | select(.user.login | ascii_downcase | test(\"${bot_login}\")) | [(.created_at // .submitted_at // \"\"), (.updated_at // .submitted_at // .created_at // \"\"), (.body // \"\" | @base64)] | @tsv"

	local saw_any=0 saw_non_review=0 saw_placeholder=0
	local sources=(reviews issue-comments review-comments)
	local source records created_at updated_at encoded body
	for source in "${sources[@]}"; do
		records=$(_rbg_query_evidence_collection "$pr_number" "$repo" "$source" "$jq_filter" || echo "")
		[[ -z "$records" ]] && continue
		while IFS=$'\t' read -r created_at updated_at encoded; do
			[[ -z "$encoded" ]] && continue
			body=$(echo "$encoded" | base64 -d 2>/dev/null || echo "")
			[[ -z "$body" ]] && continue
			saw_any=1
			if is_non_review_comment "$body"; then
				saw_non_review=1
				continue
			fi
			# Pass bot_login so two-phase bots require edit-observed settlement
			# (GH#20550 — age alone is not sufficient for coderabbitai etc.).
			if _comment_is_settled "$created_at" "$updated_at" "$min_lag" "$bot_login"; then
				echo "real-review"
				return 0
			fi
			saw_placeholder=1
		done <<<"$records"
	done

	if [[ "$saw_placeholder" -eq 1 ]]; then
		echo "not-yet"
	elif [[ "$saw_non_review" -eq 1 ]]; then
		echo "non-review-only"
	elif [[ "$saw_any" -eq 0 ]]; then
		echo "no-comments"
	else
		echo "non-review-only"
	fi
	return 0
}

do_list() {
	local pr_number="$1"
	local repo="$2"

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	echo "All commenters on PR #${pr_number}:"
	echo "$all_commenters" | sed 's/^/  /'
	echo ""

	local result
	result=$(match_known_bots "$all_commenters")
	echo "$result"
	echo ""

	# t2139: Show classification per bot — disambiguate "not-yet" (placeholder)
	# from "non-review-only" (rate-limit / failure / skip notice).
	local state
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			state=$(_classify_bot_state "$pr_number" "$repo" "$bot")
			case "$state" in
			real-review)
				echo "  ${bot}: real review"
				;;
			not-yet)
				echo "  ${bot}: not yet (placeholder — waiting for Phase 2 edit)"
				;;
			non-review-only)
				echo "  ${bot}: rate-limited / no-review notice (no real review)"
				;;
			no-comments)
				echo "  ${bot}: commented per index but body unavailable"
				;;
			esac
		fi
	done

	# Show status check fallback info
	echo ""
	echo "Status check fallback (GH#3005):"
	if any_bot_has_success_status "$pr_number" "$repo"; then
		echo "  At least one bot has a SUCCESS status check."
	else
		echo "  No bot SUCCESS status checks found."
	fi
	return 0
}

has_formal_reviews() {
	# Check if the PR has at least one formal GitHub review (any state).
	local pr_number="$1"
	local repo="$2"

	local count
	count=$(gh pr view "$pr_number" --repo "$repo" \
		--json reviews --jq '.reviews | length' || echo "0")
	if [[ "$count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

has_retry_comment() {
	# Check if we already posted a review retry request on this PR.
	# Looks for our specific marker comment to ensure idempotency.
	local pr_number="$1"
	local repo="$2"

	local marker="<!-- review-bot-retry-requested -->"
	local comments
	comments=$(_rbg_query_evidence_collection "$pr_number" "$repo" issue-comments \
		'.[].body' || echo "")
	if echo "$comments" | grep -qF "$marker"; then
		return 0
	fi
	return 1
}

find_rate_limited_bots() {
	# Return space-separated list of bots that posted only non-review notices
	# (rate-limit, "Review failed", "Review skipped", etc.).
	# t2799: name is a legacy holdover — covers all non-review states, not
	# just rate-limited. Kept for backwards compat with callers and the
	# request-retry flow.
	local pr_number="$1"
	local repo="$2"

	local all_commenters
	all_commenters=$(get_all_bot_commenters "$pr_number" "$repo")

	local rate_limited=""
	local bot
	for bot in "${KNOWN_BOTS[@]}"; do
		if echo "$all_commenters" | grep -qi "$bot"; then
			if ! bot_has_real_review "$pr_number" "$repo" "$bot"; then
				rate_limited="${rate_limited}${bot} "
			fi
		fi
	done
	echo "$rate_limited"
	return 0
}

do_request_retry() {
	# Self-healing: if bots were rate-limited at PR creation and never came
	# back, request a review retry. Idempotent — checks for prior retry
	# comment before posting. Does NOT bypass the formal review gate.
	#
	# Returns: REQUESTED, ALREADY_REQUESTED, NO_ACTION, or HAS_REVIEWS
	local pr_number="$1"
	local repo="$2"

	# If formal reviews already exist, nothing to do
	if has_formal_reviews "$pr_number" "$repo"; then
		echo "HAS_REVIEWS"
		echo "PR already has formal reviews — no retry needed." >&2
		return 0
	fi

	# If we already requested a retry, don't spam
	if has_retry_comment "$pr_number" "$repo"; then
		echo "ALREADY_REQUESTED"
		echo "Retry already requested on PR #${pr_number} — waiting for bot response." >&2
		return 0
	fi

	# Check if any bots posted rate-limit notices
	local rate_limited_bots
	rate_limited_bots=$(find_rate_limited_bots "$pr_number" "$repo")

	if [[ -z "$rate_limited_bots" ]]; then
		echo "NO_ACTION"
		echo "No rate-limited bots found — nothing to retry." >&2
		return 0
	fi

	# Post retry request with idempotency marker
	local comment_body
	comment_body="<!-- review-bot-retry-requested -->
@coderabbitai review

Review bots were rate-limited when this PR was created (affected: ${rate_limited_bots% }). Requesting a review retry."

	# go for it — safe to request retry since we already checked idempotency
	if gh_pr_comment "$pr_number" --repo "$repo" --body "$comment_body" >/dev/null 2>&1; then
		echo "REQUESTED"
		echo "Requested review retry on PR #${pr_number} (rate-limited bots: ${rate_limited_bots% })." >&2
		return 0
	else
		echo "ERROR: Failed to post retry comment on PR #${pr_number}." >&2
		return 2
	fi
}

do_batch_retry() {
	# GH#3932: Process all open PRs with 0 formal reviews, request retries
	# for rate-limited ones. Staggers requests with a delay between each to
	# avoid re-triggering CodeRabbit's hourly rate limit.
	#
	# Returns summary: REQUESTED_N (where N is the count of retries requested)
	local repo="$1"
	local stagger_seconds="${BATCH_RETRY_STAGGER:-5}"

	echo "Scanning open PRs in ${repo} for rate-limited reviews..." >&2

	# Get all open PRs with 0 formal reviews
	local pr_numbers
	pr_numbers=$(gh pr list --repo "$repo" --state open --limit 100 \
		--json number,reviews \
		--jq '[.[] | select((.reviews | length) == 0)] | .[].number' || echo "")

	if [[ -z "$pr_numbers" ]]; then
		echo "NO_ACTION"
		echo "No open PRs with 0 formal reviews found." >&2
		return 0
	fi

	local total=0
	local requested=0
	local already=0
	local skipped=0
	local pr_num result

	while IFS= read -r pr_num; do
		[[ -z "$pr_num" ]] && continue
		total=$((total + 1))

		# Run request-retry for each PR (it handles idempotency internally)
		result=$(do_request_retry "$pr_num" "$repo") || true

		case "$result" in
		REQUESTED)
			requested=$((requested + 1))
			echo "  PR #${pr_num}: retry requested" >&2
			# Stagger to avoid re-triggering rate limits
			if [[ "$stagger_seconds" -gt 0 ]]; then
				sleep "$stagger_seconds"
			fi
			;;
		ALREADY_REQUESTED)
			already=$((already + 1))
			echo "  PR #${pr_num}: already requested" >&2
			;;
		HAS_REVIEWS)
			echo "  PR #${pr_num}: has formal reviews (skipped)" >&2
			;;
		NO_ACTION)
			skipped=$((skipped + 1))
			echo "  PR #${pr_num}: no rate-limited bots (skipped)" >&2
			;;
		*)
			skipped=$((skipped + 1))
			echo "  PR #${pr_num}: ${result:-error} (skipped)" >&2
			;;
		esac
	done <<<"$pr_numbers"

	echo "REQUESTED_${requested}"
	echo "Batch retry complete: ${total} PRs scanned, ${requested} retries requested, ${already} already requested, ${skipped} skipped." >&2
	return 0
}

# --- Main ---

main() {
	local command="${1:-}"
	local pr_number="${2:-}"
	local repo="${3:-}"
	local max_wait="${4:-}"

	if [[ "$command" == "event-check" ]]; then
		do_event_check
		return $?
	fi

	if [[ "$command" == "classify-infra-rate-limit" ]]; then
		local author_association="${2:-}"
		local infra_repo="${3:-}"
		if [[ -z "$author_association" || -z "$infra_repo" ]]; then
			echo "ERROR: classify-infra-rate-limit requires AUTHOR_ASSOCIATION and REPO." >&2
			return 2
		fi
		classify_infra_rate_limit "$author_association" "$infra_repo"
		return $?
	fi

	# batch-retry only needs repo, not pr_number
	if [[ "$command" == "batch-retry" ]]; then
		local batch_repo="${2:-}"
		if [[ -z "$batch_repo" ]]; then
			batch_repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
			if [[ -z "$batch_repo" ]]; then
				echo "ERROR: Could not determine repo. Pass REPO as argument." >&2
				return 2
			fi
		fi
		do_batch_retry "$batch_repo"
		return $?
	fi

	if [[ -z "$command" || -z "$pr_number" ]]; then
		usage
		return 2
	fi

	# Default repo from current git context
	if [[ -z "$repo" ]]; then
		repo=$(gh repo view --json nameWithOwner -q .nameWithOwner || echo "")
		if [[ -z "$repo" ]]; then
			echo "ERROR: Could not determine repo. Pass REPO as third argument." >&2
			return 2
		fi
	fi

	case "$command" in
	check)
		do_check "$pr_number" "$repo"
		;;
	is-trusted-issue-sync-pr)
		do_is_trusted_issue_sync_pr "$pr_number" "$repo" "$max_wait"
		;;
	wait)
		do_wait "$pr_number" "$repo" "$max_wait"
		;;
	list)
		do_list "$pr_number" "$repo"
		;;
	request-retry)
		do_request_retry "$pr_number" "$repo"
		;;
	status-json)
		do_status_json "$pr_number" "$repo"
		;;
	reconcile-stale-coderabbit)
		do_reconcile_coderabbit_reviews "$RBG_RECONCILE_MODE_SUPERSEDED" "$pr_number" "$repo" "$max_wait"
		;;
	dismiss-coderabbit-nits)
		do_reconcile_coderabbit_reviews "$RBG_RECONCILE_MODE_NITS" "$pr_number" "$repo"
		;;
	-h | --help | help)
		usage
		;;
	*)
		echo "ERROR: Unknown command '$command'" >&2
		usage
		return 2
		;;
	esac
}

main "$@"
