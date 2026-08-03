#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-actions.sh — Per-issue action helpers and predicates
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21376) to keep the orchestrator
# file below the 2000-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined all PULSE_* configuration constants.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-actions.sh"
#
# Exports — parent-task child detection helpers:
#   _fetch_subissue_numbers       — fetch child issue numbers via GraphQL
#   _extract_children_section     — extract ## Children / ## Sub-tasks section
#   _extract_children_from_prose  — extract children from narrow prose patterns
#   _fetch_children_from_trusted_roadmap_comments — extract trusted roadmap refs
#   _compute_parent_nudge_age_hours — compute age of decomposition nudge comment
#   _post_parent_phases_unfiled_nudge — nudge when declared phases > filed children
#   _try_close_parent_tracker     — close parent if all children are resolved
#
# Exports — single-pass stage predicates:
#   _should_reconcile_persistent_issue — stage 0a non-task predicate
#   _should_reconcile_external_issue_gate — stage 0 trust predicate
#   _should_ciw   — stage 1 predicate (status:available)
#   _should_rsd   — stage 2 predicate (status:done)
#   _should_oimp  — stage 3 predicate (not a parent-task)
#   _should_cpt   — stage 4 predicate (parent-task)
#   _should_lia   — stage 5 predicate (labelless aidevops-shaped)
#
# Exports — single-pass per-issue action helpers:
#   _action_reconcile_persistent_issue_labels — stage 0a label hygiene
#   _action_reconcile_external_issue_gate — stage 0 trust repair/block
#   _action_ciw_single   — close issue with merged PR (stage 1)
#   _action_rsd_single   — reconcile stale-done issue (stage 2)
#   _action_oimp_single  — close open issue with merged PR (stage 3)
#   _action_cpt_single   — reconcile parent-task (stage 4)
#
# Note: _action_lia_single (stage 5) is over 100 lines and stays in
# pulse-issue-reconcile.sh to preserve its (file, fname) identity key.
# _post_parent_decomposition_nudge and _post_parent_decomposition_escalation
# are also over 100 lines and stay in the orchestrator.

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_ACTIONS_LOADED=1

#######################################
# Fetch mergedAt for a PR using the shared wrapper when available.
# The wrapper adds REST fallback, telemetry, and exact-output caching under
# GraphQL budget pressure. Raw gh remains as a fallback because this file is
# also sourced by isolated tests and partial deployments.
# Args: $1 = PR number, $2 = slug (owner/name)
# Stdout: mergedAt timestamp or empty
#######################################
_pir_pr_merged_at() {
	local pr_num="$1" slug="$2"
	[[ -n "$pr_num" && -n "$slug" ]] || return 1
	if declare -F gh_pr_view >/dev/null 2>&1; then
		gh_pr_view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null
		return $?
	fi
	gh pr view "$pr_num" --repo "$slug" --json mergedAt -q '.mergedAt // empty' 2>/dev/null
	return $?
}

#######################################
# Fetch sub-issue numbers via GitHub GraphQL (t2138).
#
# Uses the native `subIssues` relationship on the issue node. Returns
# newline-separated child issue numbers on stdout. Empty output on any
# failure, empty graph, or feature-not-enabled. Callers must treat empty
# output as "fall back to body regex", NOT "no children" — the sub-issue
# feature is a recent GitHub addition and legacy parents may link
# children only via body text.
#
# Args: $1 = slug (owner/name), $2 = issue number
#######################################
_fetch_subissue_numbers() {
	local slug="$1" issue_num="$2"
	[[ "$slug" == */* ]] || return 0
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 0

	local owner="${slug%%/*}" name="${slug##*/}"
	# t2138: fetch pageInfo alongside nodes so we can fail-closed when
	# hasNextPage is true. Partial child lists would silently let the
	# reconciler close parents before the tail children are checked.
	# The jq filter returns `PAGINATED` (non-numeric) when hasNextPage=true,
	# which the caller treats as "empty" → falls back to body regex.
	local graphql_response="" graphql_result="" reported_cost=""
	# shellcheck disable=SC2016  # GraphQL variable markers ($owner/$name/$number) are intentional literals, not bash expansions
	graphql_response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-subissues-exact-cost" \
		gh api graphql \
		-f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){subIssues(first:50){nodes{number state}pageInfo{hasNextPage}}}}rateLimit{cost}}' \
		-F "owner=$owner" -F "name=$name" -F "number=$issue_num" \
		2>/dev/null) || return 0
	reported_cost=$(printf '%s' "$graphql_response" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || return 0
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 0
	graphql_result=$(printf '%s' "$graphql_response" | jq -r \
		'if (.data.repository.issue.subIssues.pageInfo.hasNextPage // false) then "PAGINATED" else (.data.repository.issue.subIssues.nodes // [] | .[] | .number) end' \
		2>/dev/null) || return 0

	# Fail-closed guard: if hasNextPage, pretend we got nothing so the
	# caller falls back to body regex (where pagination is not an issue).
	if [[ "$graphql_result" == "PAGINATED" ]]; then
		return 0
	fi
	printf '%s\n' "$graphql_result"
	return 0
}

# t2244: extract the ## Children / ## Sub-tasks / ## Child issues section from
# a parent issue body. Returns ONLY the text between that heading and the next
# ## heading (or EOF). Returns empty if no matching heading found — caller must
# treat empty as "no declared children in body" and skip the body-regex path.
# This prevents prose #NNN mentions (e.g., "triggered by #19708") from being
# misread as child references and causing premature parent close.
_extract_children_section() {
	local body="$1"
	printf '%s' "$body" | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ {
			in_section = 1; next
		}
		in_section && /^##[[:space:]]/ { exit }
		in_section { print }
	'
	return 0
}

#######################################
# t2442: extract child issue numbers from narrow prose patterns.
#
# DELIBERATELY narrow — t2244 (CodeRabbit review of PR #19810) explicitly
# disqualified "any #NNN mention = child" matching after the #19734
# incident where that logic closed parent trackers prematurely by
# mistaking context refs for children. This helper only matches four
# phrase shapes that unambiguously declare a child relationship:
#
#   1. `Phase N <anything> #NNNN` — e.g. "Phase 1 split out as #19996"
#   2. `filed as #NNNN`           — "Phase 2 was filed as #20001"
#   3. `tracks #NNNN`              — "tracks #19808 and #19858"
#   4. `[Bb]locked by:? #NNNN`     — "Blocked by: #42"
#
# Bare `#NNNN` mentions in prose (e.g. "triggered by #19708", "cf. #12345",
# "closes #17", "see #42") are intentionally NOT matched. The heuristic
# is: these four verbs-of-parenthood are rare in prose about ANYTHING
# ELSE, so the false-positive rate is low and the false-negative cost
# (parent stays open one more cycle until nudge fires, harmless) is
# acceptable.
#
# Called as a THIRD fallback in reconcile_completed_parent_tasks after
# the GraphQL subIssues graph AND the ## Children heading extraction
# both come back empty. Never mutates the parent body.
#
# Arguments:
#   arg1 - parent issue body text
# Outputs: one child issue number per line, deduplicated, sorted. Empty
#          output = no matches (caller must treat as "no children from
#          prose" and skip to the nudge/escalation path).
# Returns: always 0.
#######################################
_extract_children_from_prose() {
	local body="$1"
	[[ -n "$body" ]] || return 0

	# Four narrow patterns. POSIX ERE only (grep -E) so macOS bash 3.2 compat.
	# We collect matches then extract the numeric portion.
	#   - phase-ref:  "Phase 1 split out as #19996", "Phase 2 — #20001"
	#   - filed-as:   "filed as #N", "was filed as #N"
	#   - tracks:     "tracks #N"
	#   - blocked-by: "blocked by: #N", "Blocked by #N", "blocked-by: #N"
	#
	# Each pattern independently captures the #NNNN token; we union the
	# results via sort -u. Anchors `(^|[^a-zA-Z0-9_])` and `([^a-zA-Z0-9_]|$)`
	# prevent matches inside words (e.g. "hashtracks" or "#Nfiled").
	local patterns=(
		'(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Tt]racks[[:space:]]+#[0-9]+)'
		'(^|[^a-zA-Z0-9_])([Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)'
	)

	local all_matches=""
	local pat
	for pat in "${patterns[@]}"; do
		local hits
		hits=$(printf '%s' "$body" | grep -oE "$pat" 2>/dev/null || true)
		[[ -n "$hits" ]] || continue
		all_matches="${all_matches}${hits}"$'\n'
	done

	[[ -n "$all_matches" ]] || return 0

	# Extract the trailing #NNNN from each matched phrase, strip the `#`,
	# drop anything that isn't a clean positive integer, deduplicate.
	printf '%s' "$all_matches" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un
	return 0
}

#######################################
# Extract child issue numbers from trusted roadmap comments.
#
# Parent creation can publish a dependency roadmap as a maintainer comment
# while leaving the immutable original body unchanged. Reconciliation used to
# ignore that durable declaration and falsely report zero children. Restrict
# this source to trusted author associations and an explicit roadmap/children
# heading so arbitrary prose references cannot affect parent closure.
#
# Arguments:
#   arg1 - repository slug
#   arg2 - parent issue number
# Outputs: one child issue number per line, deduplicated and sorted.
# Returns: 0, including on API failure (no comment evidence).
#######################################
_fetch_children_from_trusted_roadmap_comments() {
	local slug="$1"
	local issue_num="$2"
	[[ -n "$slug" ]] || return 0
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 0

	gh api --paginate "repos/${slug}/issues/${issue_num}/comments" \
		--jq '.[] | select((.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") and (.body | test("(?im)^##[[:space:]]+(Dispatch roadmap|Children|Child issues|Sub-tasks)[[:space:]]*$"))) | .body' \
		2>/dev/null | awk '
		BEGIN { in_section = 0 }
		/^##[[:space:]]+(Dispatch roadmap|Children|Child [Ii]ssues|Sub-?[Tt]asks)[[:space:]]*$/ { in_section = 1; next }
		in_section && /^##[[:space:]]/ { in_section = 0 }
		in_section { print }
	' | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un || true
	return 0
}

#######################################
# t2442: Compute the age (in hours) of the existing nudge comment on a
# parent-task issue. Used by the escalation path to gate "nudge has sat
# unactioned for long enough that we escalate".
#
# Walks comments for the `<!-- parent-needs-decomposition -->` marker,
# returns the age in HOURS as an integer on stdout. Returns empty output
# (exit 0) if no such comment exists OR if the API call fails — the
# caller MUST treat empty as "do not escalate" (fail-closed — without a
# nudge there is no signal to escalate on, and API-unavailable should
# never open new comments).
#
# Arguments:
#   arg1 - repo slug
#   arg2 - parent issue number
# Outputs: integer hours (e.g. "168") or empty string on no-nudge/failure.
#######################################
_compute_parent_nudge_age_hours() {
	local slug="$1"
	local parent_num="$2"

	[[ -n "$slug" && "$parent_num" =~ ^[0-9]+$ ]] || return 0

	# t2572: streaming pattern — --paginate + --jq (no --slurp, which `gh api`
	# rejects). Per-page jq emits matching .created_at values; `head -n1`
	# yields the first match across all pages (chronological order = oldest,
	# which is what the 7-day escalation gate wants).
	local nudge_created_at
	nudge_created_at=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq '.[] | select(.body | contains("<!-- parent-needs-decomposition -->")) | .created_at' \
		2>/dev/null | head -n1) || nudge_created_at=""
	[[ -n "$nudge_created_at" ]] || return 0

	# Convert ISO-8601 to epoch. macOS `date` needs -j -f; GNU `date` uses -d.
	local nudge_epoch="" now_epoch=""
	if date --version >/dev/null 2>&1; then
		nudge_epoch=$(date -d "$nudge_created_at" +%s 2>/dev/null || echo "")
	else
		nudge_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$nudge_created_at" +%s 2>/dev/null || echo "")
	fi
	[[ "$nudge_epoch" =~ ^[0-9]+$ ]] || return 0

	now_epoch=$(date +%s)
	local age_seconds=$((now_epoch - nudge_epoch))
	[[ "$age_seconds" -ge 0 ]] || return 0

	printf '%d\n' "$((age_seconds / 3600))"
	return 0
}

_post_parent_phases_unfiled_nudge() {
	local slug="$1"
	local parent_num="$2"
	local declared_count="${3:-0}"
	local filed_count="${4:-0}"
	local unfiled_phases="${5:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-declared-phases-unfiled -->'

	# Idempotency check: skip if marker already present in any comment.
	# Pattern mirrors _post_parent_decomposition_nudge (t2572 fix: streaming
	# --paginate + --jq, no --slurp). Fail-closed on API error.
	# Use printf to build the jq filter to avoid a 3rd raw copy of the
	# .[] | select(.body | contains()) fragment (string-literal ratchet).
	local _jq_filter
	_jq_filter=$(printf '.[] | select(.body | contains("%s")) | .id' "$marker")
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq "$_jq_filter" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""

	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Phases nudge dedup: API/jq failure for #${parent_num} in ${slug} — skipping (fail-closed, t2786)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	[[ "$existing" -ge 1 ]] && return 1

	local unfiled_list=""
	if [[ -n "$unfiled_phases" ]]; then
		unfiled_list="

**Unfiled phases detected:**

$(printf '%s' "$unfiled_phases" | sed 's/^[[:space:]]*//' | sed 's/^/- /')"
	fi

	local comment_body="${marker}
## Parent Tracker: Declared Phases Not Yet Filed

This parent declares **${declared_count} phase(s)** in its \`## Phases\` section but only **${filed_count}** have been filed as child issues. Closing the parent now would be premature — the unfiled phases would be silently dropped.${unfiled_list}

**To proceed:** file the remaining phases as child issues and link them in a \`## Children\` section in the parent body. The parent will close automatically once all children are resolved.

_Detected by \`_try_close_parent_tracker\` (pulse-issue-reconcile.sh, t2786). Posted once per issue via the \`<!-- parent-declared-phases-unfiled -->\` marker; re-runs are no-ops._"

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: phases-unfiled nudge posted for #${parent_num} in ${slug} (declared=${declared_count}, filed=${filed_count}, t2786)" >>"${LOGFILE:-/dev/null}"
	return 0
}

# Machine-readable parent close-contract result. The predicate below resets
# these globals on every call so callers can explain and repair an incomplete
# contract without reparsing the body.
_PARENT_CLOSE_CONTRACT_REASON=""
_PARENT_CLOSE_CONTRACT_DECLARED=0
_PARENT_CLOSE_CONTRACT_UNFILED=""

_parent_comments_api_path() {
	local slug="$1" parent_num="$2"
	printf 'repos/%s/issues/%s/comments\n' "$slug" "$parent_num"
	return 0
}

#######################################
# Decide whether deterministic parent-body evidence blocks closure.
# Backward compatibility is deliberate: legacy parents with no contract and
# no unchecked criteria remain closable once every known child is terminal.
#
# Recognised contracts:
#   - canonical ## Phases rows (every row must contain a child reference)
#   - <!-- parent-close-contract: expected-children=N -->
#   - <!-- parent-close-contract: complete -->
#   - <!-- parent-close-contract: needs-decomposition|keep-open -->
# Unchecked Markdown task-list criteria also block closure.
#
# Args: $1=parent_body, $2=known_child_count
# Returns: 0=incomplete, 1=complete or legacy-unknown
#######################################
_parent_close_contract_incomplete() {
	local parent_body="$1"
	local known_child_count="${2:-0}"
	_PARENT_CLOSE_CONTRACT_REASON=""
	_PARENT_CLOSE_CONTRACT_DECLARED=0
	_PARENT_CLOSE_CONTRACT_UNFILED=""
	[[ -n "$parent_body" ]] || return 1

	local phases_section="" unfiled_count=0
	phases_section=$(_parse_phases_section "$parent_body")
	if [[ -n "$phases_section" ]]; then
		_PARENT_CLOSE_CONTRACT_DECLARED=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ { c++ } END { print c+0 }')
		_PARENT_CLOSE_CONTRACT_UNFILED=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { printf "Phase %s: %s\n", $1, $2 }')
		unfiled_count=$(printf '%s\n' "$phases_section" |
			awk -F'\t' '$1 ~ /^[0-9]+$/ && $4 == "" { c++ } END { print c+0 }')
		if [[ "$unfiled_count" -gt 0 ]]; then
			_PARENT_CLOSE_CONTRACT_REASON="unfiled-phases"
			return 0
		fi
	fi

	local expected_children=""
	expected_children=$(printf '%s\n' "$parent_body" |
		sed -nE 's/.*<!-- parent-close-contract: expected-children=([0-9]+) -->.*/\1/p' | head -n1)
	if [[ "$expected_children" =~ ^[0-9]+$ ]] && [[ "$known_child_count" -lt "$expected_children" ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="expected-children:${expected_children}"
		return 0
	fi

	if [[ "$parent_body" == *"<!-- parent-close-contract: phase-plan -->"* &&
		"$_PARENT_CLOSE_CONTRACT_DECLARED" -eq 0 ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="invalid-phase-plan"
		return 0
	fi
	if [[ "$parent_body" == *"<!-- parent-close-contract: needs-decomposition -->"* ||
		"$parent_body" == *"<!-- parent-close-contract: keep-open -->"* ]]; then
		_PARENT_CLOSE_CONTRACT_REASON="needs-decomposition"
		return 0
	fi
	if printf '%s\n' "$parent_body" | grep -qE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]'; then
		_PARENT_CLOSE_CONTRACT_REASON="unchecked-criteria"
		return 0
	fi

	return 1
}

#######################################
# Post a one-time worker-ready explanation for a non-phase close-contract
# failure. The caller supplies the marker so open-parent nudges and closed-
# parent repairs each remain independently idempotent.
# Args: $1=slug, $2=parent_num, $3=reason, $4=marker
# Returns: 0=posted, 1=already present or API/comment failure
#######################################
_post_parent_close_contract_nudge() {
	local slug="$1" parent_num="$2" reason="$3" marker="$4"
	local existing="" comments_api=""
	comments_api=$(_parent_comments_api_path "$slug" "$parent_num")
	existing=$(gh api --paginate "$comments_api" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""
	[[ "$existing" =~ ^[0-9]+$ ]] || return 1
	[[ "$existing" -eq 0 ]] || return 1

	local guidance="Complete the declared decomposition and update the parent close contract before closure."
	case "$reason" in
	expected-children:*)
		guidance="Link all ${reason#expected-children:} expected child issues, then rerun reconciliation."
		;;
	unchecked-criteria)
		guidance="Resolve or check every remaining parent acceptance criterion, then rerun reconciliation."
		;;
	invalid-phase-plan)
		guidance="Rewrite the phase plan in canonical list or bold phase form and link each filed child."
		;;
	esac

	local comment_body="${marker}
## Parent Tracker: Close Contract Incomplete

Reconciliation found deterministic evidence that this parent objective is not complete (${reason}). The parent remains open so declared work is not lost.

**Recovery:** ${guidance}

_Posted once by parent close-contract reconciliation._"
	gh_issue_comment "$parent_num" --repo "$slug" --body "$comment_body" >/dev/null 2>&1 || return 1
	return 0
}

_mark_parent_review_hold() {
	local slug="$1" parent_num="$2"
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$parent_num" --repo "$slug" \
			--add-label "hold-for-review" >/dev/null 2>&1 || true
	else
		gh issue edit "$parent_num" --repo "$slug" \
			--add-label "hold-for-review" >/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Reopen a recently closed parent only when deterministic close-contract
# evidence proves that closure was premature. The repair marker makes retries
# no-ops even if another automation closes the parent again.
# Args: $1=slug, $2=parent_num, $3=reason
# Returns: 0=reopened, 1=already repaired or API failure
#######################################
_repair_closed_parent_contract() {
	local slug="$1" parent_num="$2" reason="$3"
	local marker='<!-- parent-close-contract-repaired -->'
	local existing="" comments_api=""
	comments_api=$(_parent_comments_api_path "$slug" "$parent_num")
	existing=$(gh api --paginate "$comments_api" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""
	[[ "$existing" =~ ^[0-9]+$ ]] || return 1
	[[ "$existing" -eq 0 ]] || return 1

	gh issue reopen "$parent_num" --repo "$slug" >/dev/null 2>&1 || return 1
	_post_parent_close_contract_nudge "$slug" "$parent_num" "$reason" "$marker" || true
	_mark_parent_review_hold "$slug" "$parent_num"
	echo "[pulse-wrapper] Reconcile parent-task: reopened #${parent_num} in ${slug} — incomplete close contract (${reason})" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# t2138 / t3544: extract per-parent close logic. Keeps
# reconcile_completed_parent_tasks under the 100-line shell-complexity
# threshold and makes the close decision independently testable.
#
# Returns 0 if the parent was closed, 1 if skipped (no known children,
# any child still open, incomplete close contract, or close call failed).
_try_close_parent_tracker() {
	local slug="$1" parent_num="$2" child_nums="$3" child_source="$4" parent_body="${5:-}"
	local all_closed="true" child_summary="" child_count=0
	local child_num="" child_state="" child_title_line=""

	while IFS= read -r child_num; do
		[[ -n "$child_num" && "$child_num" =~ ^[0-9]+$ ]] || continue
		child_state=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.state // "unknown"' 2>/dev/null) || child_state="unknown"
		child_title_line=$(gh api "repos/${slug}/issues/${child_num}" \
			--jq '.title // ""' 2>/dev/null) || child_title_line=""

		# Skip references that aren't real child issues (PRs, external refs)
		[[ "$child_state" == "unknown" ]] && continue

		child_count=$((child_count + 1))
		if [[ "$child_state" == "closed" ]]; then
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ✅ CLOSED"
		else
			child_summary="${child_summary}
- #${child_num}: ${child_title_line} — ⏳ OPEN"
			all_closed="false"
		fi
	done <<<"$child_nums"

	# t3544: dropped the `child_count >= 2` heuristic that previously
	# short-circuited single-filed-child parents. Pre-union-extraction
	# (before GH#20872), a single ref was often a spurious mention rather
	# than a true child. The current union extractor (graph + body + prose)
	# only counts numeric IDs that survived `## Children` / `## Sub-tasks` /
	# sub-issue-graph filtering, so a single survivor is a legitimate child.
	# Filtering it out here meant single-child parents could never close
	# OR receive the declared-vs-filed nudge — they silently rotted (canonical:
	# #22371 / #22372 with one filed Phase 1 child closed for hours with
	# no action). The remaining gates (all_closed, child_count>0,
	# declared-vs-filed augmentation, gh issue close result) are sufficient.
	#
	# child_count > 0 is required: pre-t3544 the heuristic implicitly
	# guarded this, but with the heuristic gone, a parent whose only
	# refs are non-issue (PRs, external) would skip the per-child
	# accounting loop entirely (`continue` on `state == unknown`),
	# leave child_count=0, all_closed defaulting to "true" (no
	# child set it false), and produce the absurd close-comment
	# "All 0 filed child task(s) are resolved." Require at least
	# one real child issue (Gemini review of PR #22605, t3544).
	[[ "$all_closed" == "true" && "$child_count" -gt 0 ]] || return 1

	if _parent_close_contract_incomplete "$parent_body" "$child_count"; then
		if [[ "$_PARENT_CLOSE_CONTRACT_REASON" == "unfiled-phases" ]]; then
			_post_parent_phases_unfiled_nudge "$slug" "$parent_num" \
				"$_PARENT_CLOSE_CONTRACT_DECLARED" "$child_count" \
				"$_PARENT_CLOSE_CONTRACT_UNFILED" || true
		else
			_post_parent_close_contract_nudge "$slug" "$parent_num" \
				"$_PARENT_CLOSE_CONTRACT_REASON" \
				"<!-- parent-close-contract-incomplete:${_PARENT_CLOSE_CONTRACT_REASON} -->" || true
		fi
		_mark_parent_review_hold "$slug" "$parent_num"
		echo "[pulse-wrapper] Reconcile parent-task: kept #${parent_num} open in ${slug} — incomplete close contract (${_PARENT_CLOSE_CONTRACT_REASON})" >>"${LOGFILE:-/dev/null}"
		return 1
	fi

	# Child reads and close-contract checks can span several API round-trips.
	# Re-read the parent at the final mutation boundary so an NMR/persistent hold
	# added during that interval cannot race the earlier caller-side gate.
	_pir_parent_mutation_is_allowed "$slug" "$parent_num" || return 1
	gh issue close "$parent_num" --repo "$slug" \
		--comment "## All declared child tasks completed — closing parent tracker

${child_summary}

All ${child_count} declared child issue(s) are resolved and the parent close contract is complete. Parent tracker closed automatically.

_Detected by reconcile_completed_parent_tasks (pulse-issue-reconcile.sh)._" \
		>/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: closed #${parent_num} in ${slug} — all ${child_count} children closed (source=${child_source})" >>"$LOGFILE"
	return 0
}

# Exact comma-delimited label membership without substring matches.
# Args: $1=labels CSV, $2=label
_pir_labels_csv_contains() {
	local labels_csv="$1"
	local label="$2"
	case ",${labels_csv}," in
	*,"$label",*) return 0 ;;
	esac
	return 1
}

# Stage 0a predicate: persistent issues are monitoring/tracking surfaces, not
# implementation tasks. They must bypass task lifecycle reconciliation.
# Args: $1=labels CSV
_should_reconcile_persistent_issue() {
	local labels_csv="$1"
	_pir_labels_csv_contains "$labels_csv" "$_PIR_PERSISTENT_LABEL" && return 0
	return 1
}

#######################################
# Remove stale triage-failure residue from a persistent non-task issue. An NMR
# label is deliberately preserved: persistent blocks dispatch, but it must not
# become a bypass for the cryptographically protected NMR removal boundary.
#
# Args: $1=slug, $2=issue number, $3=labels CSV
# Returns: 0=labels repaired, 1=no repair needed or write failed
#######################################
_action_reconcile_persistent_issue_labels() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local -a edit_args=()

	if _pir_labels_csv_contains "$labels_csv" "$_PIR_TRIAGE_FAILED_LABEL"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_TRIAGE_FAILED_LABEL")
	fi
	[[ "${#edit_args[@]}" -gt 0 ]] || return 1

	#aidevops:trust-boundary -- persistent blocks dispatch but never authorizes NMR removal.
	local edit_rc=0
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	else
		gh issue edit "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	fi
	if [[ "$edit_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Persistent issue reconcile: label repair failed for #${issue_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Persistent issue reconcile: removed stale triage labels from #${issue_num} in ${slug}" >>"$LOGFILE"
	return 0
}

# Stage 0b predicate: cached metadata identifies a non-maintainer issue author,
# or metadata is unavailable and later lifecycle stages must remain blocked.
# Unknown rows are not relabeled because that could misclassify legacy trusted
# issues; live worker entry gates independently remain fail-closed.
# Args: $1=author association, $2=author type, $3=author is_bot boolean
_should_reconcile_external_issue_gate() {
	local author_association="$1"
	local author_type="$2"
	local author_is_bot="$3"
	if [[ "$author_type" == "Bot" || "$author_is_bot" == "true" ]]; then
		return 1
	fi
	case "$author_association" in
	OWNER | MEMBER) return 1 ;;
	esac
	return 0
}

#######################################
# Stage 0 action: repair a missing NMR gate from cached author metadata and
# prevent later reconciliation stages from acting on unapproved external input.
# Verified approvals and write-authorized collaborators continue normally.
#
# Args: $1=slug, $2=issue number, $3=labels CSV, $4=association, $5=login
# Returns: 0=block remaining stages, 1=trusted/approved and may continue
#######################################
_action_reconcile_external_issue_gate() {
	local slug="$1"
	local issue_num="$2"
	local labels_csv="$3"
	local author_association="$4"
	local author_login="$5"
	_PIR_EXTERNAL_GATE_MUTATED=0

	if _pir_labels_csv_contains "$labels_csv" "$_PIR_NMR_LABEL"; then
		return 0
	fi
	if [[ -z "$author_association" ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; author metadata unavailable, labels unchanged" >>"$LOGFILE"
		return 0
	fi

	local authority_rc=0
	if declare -F _gh_actor_has_repo_write_authority >/dev/null 2>&1; then
		_gh_actor_has_repo_write_authority "$slug" "$author_login" "$author_association" || authority_rc=$?
	else
		authority_rc=2
	fi
	if [[ "$authority_rc" -eq 0 ]]; then
		return 1
	fi
	if [[ "$authority_rc" -ne 1 ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; author authority lookup unavailable, labels unchanged" >>"$LOGFILE"
		return 0
	fi

	local approval_helper="${_PIR_SCRIPT_DIR}/approval-helper.sh"
	local verification=""
	if [[ ! -x "$approval_helper" ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; approval helper unavailable, labels unchanged" >>"$LOGFILE"
		return 0
	fi
	verification=$("$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || true
	if [[ "$verification" == "VERIFIED" ]]; then
		return 1
	fi
	if [[ -n "$verification" && "$verification" != "NO_APPROVAL" ]]; then
		echo "[pulse-wrapper] External issue trust reconcile: blocked #${issue_num} in ${slug}; approval verification=${verification}, labels unchanged" >>"$LOGFILE"
		return 0
	fi

	local -a edit_args=("$_PIR_ADD_LABEL_FLAG" "$_PIR_NMR_LABEL")
	if _pir_labels_csv_contains "$labels_csv" "$_PIR_AUTO_DISPATCH_LABEL"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_AUTO_DISPATCH_LABEL")
	fi
	if _pir_labels_csv_contains "$labels_csv" "$_PIR_STATUS_AVAILABLE"; then
		edit_args+=("$_PIR_REMOVE_LABEL_FLAG" "$_PIR_STATUS_AVAILABLE")
	fi

	#aidevops:trust-boundary -- cached metadata repairs labels; live gates remain authoritative.
	local edit_rc=0
	if declare -F gh_issue_edit_safe >/dev/null 2>&1; then
		gh_issue_edit_safe "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	else
		gh issue edit "$issue_num" --repo "$slug" "${edit_args[@]}" >/dev/null 2>&1 || edit_rc=$?
	fi
	if [[ "$edit_rc" -eq 0 ]]; then
		_PIR_EXTERNAL_GATE_MUTATED=1
		echo "[pulse-wrapper] External issue trust reconcile: applied ${_PIR_NMR_LABEL} to #${issue_num} in ${slug}" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] External issue trust reconcile: label repair failed for #${issue_num} in ${slug}; remaining stages blocked" >>"$LOGFILE"
	fi
	return 0
}

# Stage 1 predicate: issue has status:available (candidate for close-via-merged-PR).
# Args: $1 = labels_csv (comma-separated label names from pre-fetched JSON)
# Note: unquoted case patterns avoid adding to the string-literal ratchet count.
_should_ciw() {
	local labels_csv="$1"
	case "$labels_csv" in
	*status:available*) return 0 ;;
	esac
	return 1
}

# Stage 2 predicate: issue has status:done (candidate for stale-done reconcile).
# Args: $1 = labels_csv
_should_rsd() {
	local labels_csv="$1"
	case "$labels_csv" in
	*status:done*) return 0 ;;
	esac
	return 1
}

# Stage 3 predicate: issue is NOT a parent-task (candidate for open-with-merged-PR check).
# Issues handled by stages 1+2 via short-circuit never reach this predicate.
# Args:
#   $1 = issue_num
#   $2 = parent_task_nums (newline-delimited list of parent-task issue numbers)
_should_oimp() {
	local issue_num="$1"
	local parent_task_nums="$2"
	if [[ -n "$parent_task_nums" ]] && printf '%s\n' "$parent_task_nums" | grep -qx "$issue_num"; then
		return 1
	fi
	return 0
}

# Stage 4 predicate: issue carries the parent-task label without an automation
# hold. NMR and persistent labels are maintainer-owned barriers, not lifecycle
# states that parent automation may clear or work around.
# Args: $1 = labels_csv
_should_cpt() {
	local labels_csv="$1"
	local nmr_label="${_PIR_NMR_LABEL:-needs-maintainer-review}"
	local parent_label="${_PIR_PT_LABEL:-parent-task}"
	local persistent_label="${_PIR_PERSISTENT_LABEL:-persistent}"
	case ",${labels_csv}," in
	*,"${nmr_label}",* | *,"${persistent_label}",*) return 1 ;;
	*,"${parent_label}",*) return 0 ;;
	esac
	return 1
}

# Stage 5 predicate: issue is an aidevops-shaped labelless candidate.
# Title must match tNNN: or GH#NNN: AND no origin:/tier:/status: labels.
# Args: $1 = issue_title, $2 = labels_csv
_should_lia() {
	local issue_title="$1"
	local labels_csv="$2"
	# Title must match aidevops task shape
	if ! printf '%s' "$issue_title" | grep -qE '^(t[0-9]+(\.[0-9]+)*|GH#[0-9]+): '; then
		return 1
	fi
	# Must have no origin:/tier:/status: labels (unquoted patterns avoid ratchet)
	case "$labels_csv" in
	*origin:* | *tier:* | *status:*) return 1 ;;
	esac
	return 0
}

#######################################
# Extract issue numbers from explicit "Supersedes #N" prose.
#
# Kept narrow on purpose: the reconciler should only close a consolidated
# successor when the successor itself declares that it supersedes an issue
# already fixed by a merged PR. Generic "see #N"/"related #N" prose is not
# sufficient terminal evidence.
#
# Args: $1 = issue body
# Stdout: newline-delimited issue numbers, deduplicated
#######################################
_pir_extract_superseded_issue_nums() {
	local issue_body="$1"
	[[ -n "$issue_body" ]] || return 0

	printf '%s' "$issue_body" |
		grep -oiE 'supersedes[[:space:]]+#[0-9]+' 2>/dev/null |
		grep -oE '[0-9]+' | sort -un
	return 0
}

#######################################
# Lookup the merged PR number for an issue in the OIMP lookup string.
# Args: $1 = issue number, $2 = oimp lookup string
# Stdout: first matching PR number or empty
#######################################
_pir_lookup_oimp_pr_for_issue() {
	local issue_num="$1"
	local oimp_lookup="$2"
	[[ "$issue_num" =~ ^[0-9]+$ && -n "$oimp_lookup" ]] || return 0

	printf '%s' "$oimp_lookup" |
		grep -oE "\|${issue_num}=[0-9]+" 2>/dev/null |
		head -1 |
		cut -d= -f2
	return 0
}

##############################################
# t2776: Per-issue action helpers for reconcile_issues_single_pass.
# Each helper encapsulates the action logic for one reconcile sub-stage.
# Called once per qualifying issue; the outer loop and issue fetch live in
# reconcile_issues_single_pass — not here.
#
# Return conventions (consistent across helpers):
#   0 = action taken (issue closed / fixed / nudged / escalated)
#   1 = no action taken (skipped, guard fired, API failure, etc.)
#   2 = reset action taken (used by _action_rsd_single: reset to available)
##############################################

#######################################
# Stage 1 action: close an issue whose work is done via a merged PR.
# (Per-issue body of close_issues_with_merged_prs — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if issue was closed, 1 otherwise
#######################################
_action_ciw_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null) || return 1

	local pr_ref="" pr_num="" merged_at=""
	pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
	pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
	merged_at=""

	if [[ -n "$pr_num" ]]; then
		merged_at=$(_pir_pr_merged_at "$pr_num" "$slug") || merged_at=""
		if [[ -z "$merged_at" ]]; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Skipped auto-close #${issue_num} in ${slug} — PR #${pr_num} does not touch files from issue (GH#17372 guard)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup helper)"} (merged at ${merged_at:-unknown}). Issue was open but dedup guard was blocking re-dispatch." \
		>/dev/null 2>&1 || return 1

	fast_fail_reset "$issue_num" "$slug" || true
	unlock_issue_after_worker "$issue_num" "$slug"
	echo "[pulse-wrapper] Auto-closed #${issue_num} in ${slug} — merged PR evidence: ${dedup_output:-"found"}" >>"$LOGFILE"
	return 0
}

#######################################
# Stage 2 action: reconcile a status:done issue.
# (Per-issue body of reconcile_stale_done_issues — no slug loop.)
#
# Args: $1=slug, $2=issue_num, $3=issue_title, $4=dedup_helper, $5=verify_helper
# Returns: 0 if closed, 2 if reset to status:available, 1 if no action taken
#######################################
_action_rsd_single() {
	local slug="$1" issue_num="$2" issue_title="$3"
	local dedup_helper="$4" verify_helper="$5"

	local dedup_output=""
	if dedup_output=$("$dedup_helper" has-open-pr "$issue_num" "$slug" "$issue_title" 2>/dev/null); then
		local pr_ref="" pr_num="" merged_at=""
		pr_ref=$(printf '%s' "$dedup_output" | grep -o '#[0-9]*' | head -1) || pr_ref=""
		pr_num=$(printf '%s' "$pr_ref" | tr -d '#')
		merged_at=""

		if [[ -n "$pr_num" ]]; then
			merged_at=$(_pir_pr_merged_at "$pr_num" "$slug") || merged_at=""
			if [[ -z "$merged_at" ]]; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} is NOT merged (GH#17871 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		if [[ -n "$pr_num" ]] && [[ -x "$verify_helper" ]]; then
			if ! "$verify_helper" check "$issue_num" "$pr_num" "$slug" >/dev/null 2>&1; then
				echo "[pulse-wrapper] Reconcile done: skipped close #${issue_num} in ${slug} — PR #${pr_num} does not touch issue files (GH#17372 guard)" >>"$LOGFILE"
				set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
				return 2
			fi
		fi

		gh issue close "$issue_num" --repo "$slug" \
			--comment "Closing: work completed via merged PR ${pr_ref:-"(detected by dedup)"} (merged at ${merged_at:-unknown})." \
			>/dev/null 2>&1 || return 1

		fast_fail_reset "$issue_num" "$slug" || true
		unlock_issue_after_worker "$issue_num" "$slug"
		echo "[pulse-wrapper] Reconcile done: closed #${issue_num} in ${slug} — merged PR: ${dedup_output:-"found"}" >>"$LOGFILE"
		return 0
	else
		# No merged PR — reset for re-evaluation
		set_issue_status "$issue_num" "$slug" "available" >/dev/null 2>&1 || return 1
		echo "[pulse-wrapper] Reconcile done: reset #${issue_num} in ${slug} to status:available — no merged PR evidence" >>"$LOGFILE"
		return 2
	fi
}

#######################################
# Check whether a generated file-size-debt issue still describes current debt.
# Historical merged-PR evidence is not sufficient to close a recurrent issue
# while its exact cited file is again at or above the recorded threshold.
#
# Args: $1=repo slug, $2=issue body
# Returns: 0=current debt exists, 1=not generated debt or debt is resolved,
#          2=current outcome could not be measured (caller must fail safe)
#######################################
_pir_file_size_debt_current_outcome() {
	local slug="$1"
	local issue_body="$2"
	local marker="" cited_file="" threshold="" repo_path="" full_path=""
	local line_count=0 repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

	marker=$(printf '%s\n' "$issue_body" | grep -m 1 '<!-- aidevops:generator=large-file-simplification-gate cited_file=.* threshold=[0-9][0-9]* -->' 2>/dev/null) || marker=""
	[[ -n "$marker" ]] || return 1
	cited_file="${marker#* cited_file=}"
	cited_file="${cited_file% threshold=*}"
	threshold="${marker##* threshold=}"
	threshold="${threshold%% *}"
	[[ -n "$cited_file" && "$threshold" =~ ^[0-9]+$ && "$threshold" -gt 0 ]] || return 2

	[[ -f "$repos_json" ]] || return 2
	repo_path=$(jq -r --arg slug "$slug" '.initialized_repos[] | select(.slug == $slug) | .path // empty' "$repos_json" 2>/dev/null | head -1) || repo_path=""
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 2

	for full_path in "${repo_path}/${cited_file}" "${repo_path}/.agents/${cited_file}" "${repo_path}/.${cited_file}"; do
		[[ -f "$full_path" ]] && break
		full_path=""
	done
	[[ -n "$full_path" ]] || return 2

	line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
	[[ "$line_count" =~ ^[0-9]+$ ]] || return 2
	if [[ "$line_count" -ge "$threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Stage 3 action: close an open issue whose linked PR has already merged.
# (Per-issue body of reconcile_open_issues_with_merged_prs — no slug loop.)
#
# t2985: looks up the merged PR via the per-repo prefetched lookup string
# (built once by _build_oimp_lookup_for_slug). Replaces the previous
# per-issue gh search + gh pr view body-recheck pair, which was the
# dominant cost driver in reconcile_issues_single_pass (~600s/cycle at
# steady-state, the t2984 budget threshold). Body-keyword filtering is
# built into the lookup builder itself, so the redundant body-grep is
# also gone.
#
# Args:
#   $1 = slug
#   $2 = issue_num
#   $3 = verify_helper (path to verify-issue-close-helper.sh)
#   $4 = oimp_lookup (pipe-delimited |num=pr|...| string from
#        _build_oimp_lookup_for_slug; may be empty if prefetch failed)
#   $5 = issue_body (optional; used to close consolidated successors whose
#        body declares `Supersedes #N` and PR lookup shows #N was fixed)
# Returns: 0 if closed, 1 otherwise
#######################################
_action_oimp_single() {
	local slug="$1" issue_num="$2" verify_helper="$3"
	local oimp_lookup="${4:-}"
	local issue_body="${5:-}"

	# t2985: lookup PR number locally instead of `gh pr list --search`.
	# Empty lookup → no merged PR found → return 1 (next-cycle retry).
	local merged_pr_num=""
	local close_comment=""
	merged_pr_num=$(_pir_lookup_oimp_pr_for_issue "$issue_num" "$oimp_lookup") || merged_pr_num=""
	if [[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]]; then
		close_comment="Closing: linked PR #${merged_pr_num} was already merged. Detected by reconcile pass."
	else
		local superseded_num=""
		while IFS= read -r superseded_num; do
			[[ "$superseded_num" =~ ^[0-9]+$ ]] || continue
			merged_pr_num=$(_pir_lookup_oimp_pr_for_issue "$superseded_num" "$oimp_lookup") || merged_pr_num=""
			if [[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]]; then
				close_comment="Closing: this consolidated issue supersedes #${superseded_num}, and merged PR #${merged_pr_num} already fixed that superseded issue. Detected by reconcile pass."
				break
			fi
		done < <(_pir_extract_superseded_issue_nums "$issue_body")
	fi
	[[ -n "$merged_pr_num" && "$merged_pr_num" =~ ^[0-9]+$ ]] || return 1

	local current_outcome_rc=0
	_pir_file_size_debt_current_outcome "$slug" "$issue_body" || current_outcome_rc=$?
	case "$current_outcome_rc" in
	0)
		echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — recurrent file-size debt still exceeds its threshold" >>"$LOGFILE"
		return 1
		;;
	2)
		echo "[pulse-wrapper] Reconcile merged-PR: deferred close #${issue_num} in ${slug} — recurrent file-size debt outcome unavailable" >>"$LOGFILE"
		return 1
		;;
	esac

	# Body keyword check is built into the lookup builder — the jq scan
	# only emits pairs from PR bodies actually containing
	# Resolves|Closes|Fixes #N. The previous `gh pr view ... body` re-grep
	# is now redundant and removed (t2985).

	if [[ -x "$verify_helper" ]]; then
		if ! "$verify_helper" check "$issue_num" "$merged_pr_num" "$slug" >/dev/null 2>&1; then
			echo "[pulse-wrapper] Reconcile merged-PR: skipped close #${issue_num} in ${slug} — PR #${merged_pr_num} does not touch issue files (GH#17372)" >>"$LOGFILE"
			return 1
		fi
	fi

	gh issue close "$issue_num" --repo "$slug" \
		--comment "$close_comment" \
		>/dev/null 2>&1 || return 1

	if declare -F fast_fail_reset >/dev/null 2>&1; then
		fast_fail_reset "$issue_num" "$slug" || true
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_num" "$slug"
	fi
	echo "[pulse-wrapper] Reconcile merged-PR: closed #${issue_num} in ${slug} — merged PR #${merged_pr_num}" >>"$LOGFILE"
	return 0
}

# t2776: globals set by _action_cpt_single to communicate multi-outcome results.
# Initialized to 0 before each call; set to 1 when the respective action fires.
_SP_CPT_CLOSED=0
_SP_CPT_NUDGED=0
_SP_CPT_ESCALATED=0
_SP_CPT_REOPENED=0
_PIR_CPT_CHILD_NUMS=""
_PIR_CPT_CHILD_SOURCE="none"
_PIR_CPT_KNOWN_CHILD_COUNT=0

_repair_recently_closed_parent() {
	local slug="$1" issue_num="$2" issue_body="$3" known_child_count="$4"
	local issue_state="$5"
	case "$issue_state" in
	CLOSED | closed) ;;
	*) return 1 ;;
	esac
	if _parent_close_contract_incomplete "$issue_body" "$known_child_count"; then
		if _repair_closed_parent_contract "$slug" "$issue_num" \
			"$_PARENT_CLOSE_CONTRACT_REASON"; then
			_SP_CPT_REOPENED=1
		fi
	fi
	return 0
}

_pir_collect_parent_child_evidence() {
	local slug="$1"
	local issue_num="$2"
	local issue_body="$3"
	local graph_nums=""
	local body_nums=""
	local prose_nums=""
	local comment_nums=""
	local source_parts=""
	local children_section=""

	graph_nums=$(_fetch_subissue_numbers "$slug" "$issue_num" | sort -un | grep -v "^${issue_num}$" | grep -v '^$' || true)
	[[ -n "$graph_nums" ]] && source_parts="${source_parts:+${source_parts}+}graph"
	children_section=$(_extract_children_section "$issue_body")
	if [[ -n "$children_section" ]]; then
		body_nums=$(printf '%s' "$children_section" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -un | grep -v "^${issue_num}$" || true)
		[[ -n "$body_nums" ]] && source_parts="${source_parts:+${source_parts}+}body"
	fi
	prose_nums=$(_extract_children_from_prose "$issue_body" | grep -v "^${issue_num}$" || true)
	[[ -n "$prose_nums" ]] && source_parts="${source_parts:+${source_parts}+}prose"
	comment_nums=$(_fetch_children_from_trusted_roadmap_comments "$slug" "$issue_num" | grep -v "^${issue_num}$" || true)
	[[ -n "$comment_nums" ]] && source_parts="${source_parts:+${source_parts}+}comments"
	_PIR_CPT_CHILD_NUMS=$(printf '%s\n%s\n%s\n%s\n' "$graph_nums" "$body_nums" "$prose_nums" "$comment_nums" |
		grep -E '^[0-9]+$' | sort -un | grep -v "^${issue_num}$" || true)
	_PIR_CPT_CHILD_SOURCE="${source_parts:-none}"
	_PIR_CPT_KNOWN_CHILD_COUNT=$(printf '%s\n' "$_PIR_CPT_CHILD_NUMS" |
		awk '$0 ~ /^[0-9]+$/ { c++ } END { print c+0 }')
	return 0
}

# Re-read the parent immediately before each mutating action. Cached issue lists
# are only an initial filter; missing metadata, label removal, NMR, or persistent
# state all fail closed for this cycle.
_pir_parent_mutation_is_allowed() {
	local slug="$1"
	local issue_num="$2"
	local live_issue_json=""
	local nmr_label="${_PIR_NMR_LABEL:-needs-maintainer-review}"
	local parent_label="${_PIR_PT_LABEL:-parent-task}"
	local persistent_label="${_PIR_PERSISTENT_LABEL:-persistent}"

	[[ "$slug" == */* && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	live_issue_json=$(gh api "repos/${slug}/issues/${issue_num}" 2>/dev/null) || return 1
	#aidevops:trust-boundary -- live NMR/persistent labels stop all parent mutations.
	printf '%s' "$live_issue_json" | jq -e --argjson issue "$issue_num" \
		--arg nmr "$nmr_label" --arg parent "$parent_label" \
		--arg persistent "$persistent_label" '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		(.number == $issue) and
		(names | index($parent) != null) and
		(names | index($nmr) == null) and
		(names | index($persistent) == null)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Stage 4 action: reconcile a parent-task issue (close/nudge/escalate).
# (Per-issue body of reconcile_completed_parent_tasks — no slug loop.)
#
# Sets _SP_CPT_CLOSED / _SP_CPT_NUDGED / _SP_CPT_ESCALATED /
# _SP_CPT_REOPENED globals (each 0|1)
# to communicate which actions were taken. Caller reads and resets these.
#
# Args:
#   $1=slug, $2=issue_num, $3=issue_title, $4=issue_body
#   $5=can_close (1|0), $6=can_nudge (1|0), $7=can_escalate (1|0)
#   $8=escalation_threshold_hours, $9=issue_state (OPEN|CLOSED), $10=labels CSV
# Returns: 0 always (action outcomes via globals)
#######################################
_action_cpt_single() {
	local slug="$1" issue_num="$2" issue_title="$3" issue_body="$4"
	local can_close="${5:-0}" can_nudge="${6:-0}" can_escalate="${7:-0}"
	local escalation_threshold_hours="${8:-168}"
	local issue_state="${9:-OPEN}"
	local labels_csv="${10:-}"
	_SP_CPT_CLOSED=0
	_SP_CPT_NUDGED=0
	_SP_CPT_ESCALATED=0
	_SP_CPT_REOPENED=0
	if _pir_labels_csv_contains "$labels_csv" "${_PIR_NMR_LABEL:-needs-maintainer-review}" ||
		_pir_labels_csv_contains "$labels_csv" "${_PIR_PERSISTENT_LABEL:-persistent}"; then
		return 0
	fi

	# Child evidence is the union of graph, body, prose, and trusted roadmap
	# comments; no single incomplete source may mask another.
	_pir_collect_parent_child_evidence "$slug" "$issue_num" "$issue_body"
	local child_nums="$_PIR_CPT_CHILD_NUMS"
	local child_source="$_PIR_CPT_CHILD_SOURCE"
	local known_child_count="$_PIR_CPT_KNOWN_CHILD_COUNT"

	# Recently closed parents are repair candidates only when deterministic
	# body evidence proves that the close contract remains incomplete.
	if [[ "$issue_state" == "CLOSED" || "$issue_state" == "closed" ]]; then
		_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
		if _repair_recently_closed_parent "$slug" "$issue_num" "$issue_body" \
			"$known_child_count" "$issue_state"; then
			return 0
		fi
	fi

	if [[ -z "$child_nums" ]]; then
		# No children — try phase extractor, then nudge/escalate (t2771/t2388/t2442)
		local _phase_extractor="${_PIR_SCRIPT_DIR}/parent-task-phase-extractor.sh"
		if [[ -x "$_phase_extractor" ]]; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if PHASE_EXTRACTOR_DRY_RUN="${PHASE_EXTRACTOR_DRY_RUN:-0}" \
				"$_phase_extractor" run "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase-extractor filed children for #${issue_num} in ${slug} (t2771)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if declare -F auto_file_next_unfiled_parent_phase >/dev/null 2>&1; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if auto_file_next_unfiled_parent_phase "$issue_num" "$slug" >>"${LOGFILE:-/dev/null}" 2>&1; then
				echo "[pulse-wrapper] Reconcile parent-task: phase bootstrap filed next child for #${issue_num} in ${slug} (GH#22534)" >>"${LOGFILE:-/dev/null}"
				return 0
			fi
		fi
		if [[ "$can_nudge" == "1" ]]; then
			_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
			if _post_parent_decomposition_nudge "$slug" "$issue_num" "$issue_title"; then
				_SP_CPT_NUDGED=1
			fi
		fi
		if [[ "$can_escalate" == "1" ]]; then
			local _nudge_age_hours
			_nudge_age_hours=$(_compute_parent_nudge_age_hours "$slug" "$issue_num")
			if [[ "$_nudge_age_hours" =~ ^[0-9]+$ ]] &&
				[[ "$_nudge_age_hours" -ge "$escalation_threshold_hours" ]]; then
				_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
				if _post_parent_decomposition_escalation "$slug" "$issue_num" "$issue_title"; then
					_SP_CPT_ESCALATED=1
				fi
			fi
		fi
		return 0
	fi

	if [[ "$can_close" == "1" ]]; then
		_pir_parent_mutation_is_allowed "$slug" "$issue_num" || return 0
		if _try_close_parent_tracker "$slug" "$issue_num" "$child_nums" "$child_source" "$issue_body"; then
			_SP_CPT_CLOSED=1
		fi
	fi
	return 0
}
