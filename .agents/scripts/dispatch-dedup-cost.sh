#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-cost.sh — Cost-per-issue circuit breaker for dispatch dedup (t2007)
#
# Extracted from dispatch-dedup-helper.sh (GH#18917) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by dispatch-dedup-helper.sh. Depends on
# shared-constants.sh being sourced first (for set_issue_status).
# SCRIPT_DIR must be set by the sourcing script.
#
# Functions in this module (in source order):
#   - _get_cost_budget_for_tier
#   - _sum_issue_token_spend
#   - _issue_has_cost_breaker_comment
#   - _apply_cost_breaker_side_effects
#   - _check_cost_budget

[[ -n "${_DISPATCH_DEDUP_COST_LOADED:-}" ]] && return 0
_DISPATCH_DEDUP_COST_LOADED=1

#######################################
# Cost-per-issue circuit breaker (t2007)
# ─────────────────────────────────────────
# Tracks cumulative token spend across all worker attempts on an issue
# by parsing signature-footer patterns ("spent N tokens" / "has used N
# tokens") from comments. When spend exceeds the tier-appropriate budget,
# the breaker applies status:blocked, posts one explanatory comment per issue,
# and emits the COST_BUDGET_EXCEEDED signal.
#
# Design (paired with t1986 parent-task guard and t2008 stale escalation):
#   1. The breaker check runs in is_assigned() AFTER the parent-task
#      short-circuit (which is unconditional) but BEFORE the assignee
#      check. Cost-tripped issues should be blocked regardless of who
#      is assigned.
#   2. Aggregation parses ALL comments (not just the authenticated
#      user's) — multiple runners may have worked on the same issue,
#      and the budget is per-ISSUE, not per-runner.
#   3. Failure mode: fail-open. If we can't compute spend (gh failure,
#      no comments, jq error), allow dispatch. The breaker is a safety
#      net, not a hard gate. The other dedup layers still apply.
#   4. Side effects are idempotent through the status state machine and the
#      prior cost-circuit-breaker:fired marker.
#######################################

#######################################
# Look up the per-tier cost budget from .agents/configs/dispatch-cost-budgets.conf.
# Args: $1 = tier label or short name (simple|standard|thinking|tier:simple|...)
# Stdout: integer token budget
#######################################
_get_cost_budget_for_tier() {
	local tier="$1"
	local _conf="${SCRIPT_DIR}/../configs/dispatch-cost-budgets.conf"
	# Defaults match the documented tier sizing (see dispatch-cost-budgets.conf)
	local COST_BUDGET_SIMPLE=800000
	local COST_BUDGET_STANDARD=800000
	local COST_BUDGET_THINKING=800000
	local COST_BUDGET_DEFAULT=800000
	if [[ -f "$_conf" ]]; then
		# shellcheck source=/dev/null
		source "$_conf"
	fi

	# Strip "tier:" prefix if present
	tier="${tier#tier:}"

	case "$tier" in
	simple) printf '%s' "$COST_BUDGET_SIMPLE" ;;
	standard) printf '%s' "$COST_BUDGET_STANDARD" ;;
	thinking) printf '%s' "$COST_BUDGET_THINKING" ;;
	*) printf '%s' "$COST_BUDGET_DEFAULT" ;;
	esac
	return 0
}

#######################################
# Sum token spend across all signature footers in an issue's comments.
# Aggregates ALL workers (no author filter) — the breaker is per-issue,
# not per-runner.
#
# Args: $1 = issue number, $2 = repo slug
# Stdout: "spent_tokens|attempt_count"
# Returns: 0 on success, 1 on fetch/parse failure (caller fail-open)
#######################################
_sum_issue_token_spend() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate 2>/dev/null) || return 1
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Extract comment bodies, excluding interactive-session signature footers and
	# comments predating the latest maintainer approval / cost reset marker.
	# Interactive footers are maintainer triage/review activity that should
	# NOT count toward the per-issue worker cost budget — including them
	# produces false-positive circuit-breaker trips every time a maintainer
	# comments on an active issue (t2425 / GH#20047). Comments without either
	# marker (historical or non-standard footers) are kept: worker is the
	# fail-open default, matching the function's existing fail-open posture.
	#
	# t3077: a signed maintainer approval is also a budget reset boundary. Without
	# this, approving/removing NMR after a cost trip immediately re-trips on the
	# same historical worker footers and no new dispatch can occur.
	local bodies
	bodies=$(printf '%s' "$comments_json" | jq -r '
		def epoch: try ((.created_at // "") | fromdateiso8601) catch 0;
		(map(select(
				((.body // "") | contains("<!-- aidevops-signed-approval -->"))
				or ((.body // "") | contains("<!-- cost-circuit-breaker:reset"))
			) | epoch) | max // 0) as $reset_epoch
		|
		.[]
		| select((.body // "") | contains("with the user in an interactive session") | not)
		| select(($reset_epoch == 0) or (epoch > $reset_epoch))
		| .body // empty
	' 2>/dev/null) || return 1
	if [[ -z "$bodies" ]]; then
		# No countable comments — zero spend, zero attempts (fail-open via 0|0 not 1)
		printf '0|0'
		return 0
	fi

	# Match signature footer patterns. The footer can take several shapes:
	#   "spent 30,000 tokens"                  (no time)
	#   "spent 4m and 30,000 tokens"           (with session time)
	#   "spent 1h 30m and 30,000 tokens"       (with hours+minutes)
	#   "spent 2d 3h 15m and 30,000 tokens"    (with days+hours+minutes)
	#   "has used 30,000 tokens"               (historical wording)
	#
	# Strategy: collapse the optional "<time> and " infix so all variants
	# reduce to "(spent|has used) N tokens", then extract N. The cumulative
	# "N total tokens on this issue." line is intentionally NOT matched —
	# it's the running aggregate of prior comments and would double-count
	# every time a new worker reports its own per-comment spend.
	local raw_vals
	raw_vals=$(printf '%s' "$bodies" |
		sed -E 's/(spent|has used) (.* and )?([0-9,]+ tokens)/\1 \3/g' |
		grep -oE '(spent|has used) [0-9,]+ tokens' |
		grep -oE '[0-9,]+' |
		tr -d ',' || true)

	local total_tokens=0 attempts=0
	if [[ -n "$raw_vals" ]]; then
		local v
		while IFS= read -r v; do
			[[ -z "$v" ]] && continue
			[[ "$v" =~ ^[0-9]+$ ]] || continue
			total_tokens=$((total_tokens + v))
			attempts=$((attempts + 1))
		done <<<"$raw_vals"
	fi

	printf '%s|%s' "$total_tokens" "$attempts"
	return 0
}

#######################################
# Check whether a cost-breaker explanatory comment already exists.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#
# Returns:
#   0 = prior cost-circuit-breaker:fired marker found
#   1 = no marker found or comments could not be inspected (fail-open)
#######################################
_issue_has_cost_breaker_comment() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate --slurp 2>/dev/null) || return 1
	if [[ -z "$comments_json" || "$comments_json" == "null" ]]; then
		return 1
	fi

	local marker_count
	marker_count=$(printf '%s' "$comments_json" | jq -r '
		(if type == "array" and (.[0]? | type) == "array" then [.[][]]
		elif type == "array" then .
		else [] end)
		| [.[] | select((.body // "") | test("cost-circuit-breaker:fired"))]
		| length
	' 2>/dev/null) || return 1
	if ! [[ "$marker_count" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ "$marker_count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

#######################################
# Apply cost-breaker side effects: structural block + one explanatory comment.
# The root-cause meta-issue provides the machine-recoverable release path.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = spent (tokens, integer)
#   $4 = budget (tokens, integer)
#   $5 = tier short name (simple|standard|thinking)
#   $6 = attempts count (integer)
#######################################
_apply_cost_breaker_side_effects() {
	local issue_number="$1"
	local repo_slug="$2"
	local spent="$3"
	local budget="$4"
	local tier="$5"
	local attempts="$6"
	# NMR is an external-author trust gate, not a circuit breaker. Preserve any
	# independently valid trust gate while recording the budget stop as lifecycle state.
	set_issue_status "$issue_number" "$repo_slug" "blocked" 2>/dev/null || true

	local _spent_k=$((spent / 1000))
	local _budget_k=$((budget / 1000))

	local already_commented="false"
	if _issue_has_cost_breaker_comment "$issue_number" "$repo_slug"; then
		already_commented="true"
	fi

	if [[ "$already_commented" != "true" ]]; then
		gh_issue_comment "$issue_number" --repo "$repo_slug" \
			--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- cost-circuit-breaker:fired tier=${tier} spent=${spent} budget=${budget} -->
🛑 **Cost circuit breaker fired** (t2007)

Cumulative spend **${_spent_k}K tokens** across **${attempts}** worker attempt(s) exceeds \`tier:${tier}\` budget of **${_budget_k}K tokens**.

Further automated dispatch is suspended with \`status:blocked\` while a root-cause meta-issue is investigated.

Maintainer review required before further dispatch. Possible causes:
- Brief is unimplementable as written (refine scope or split the task)
- Hidden blocker (missing dependency, environment issue, design conflict)
- Worker stuck in a loop (model can't decompose the task — escalate tier)
- Wrong tier assigned (downgrade a tier:thinking task to standard, or vice versa)

The circuit-breaker meta flow restores \`status:available\` automatically after its fix merges. Manual recovery should requeue only after the root cause is fixed.

_This is the cost-runaway fail-safe from t2007 (paired with t1986 parent-task guard and t2008 stale-recovery escalation)._
<!-- ops:end -->" 2>/dev/null || true
	fi

	# t3076: file root-cause meta-issue with forensics and dispatch a
	# tier:thinking worker against it. Idempotent — second trip on the
	# same original is a no-op. Best-effort: failures are logged but
	# never propagate (status:blocked is canonical; the meta-issue is the
	# self-healing channel).
	local _cb_meta_filer="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/circuit-breaker-meta-filer.sh"
	if [[ -x "$_cb_meta_filer" ]]; then
		"$_cb_meta_filer" file \
			--issue "$issue_number" --repo "$repo_slug" \
			--breaker cost --tier "$tier" \
			--spent "$spent" --budget "$budget" \
			--failure-count "$attempts" >/dev/null 2>&1 || true
	fi

	return 0
}

#######################################
# Check whether the cost-per-issue circuit breaker should fire for an issue.
#
# Aggregates token spend from all signature footers on the issue's comments
# and compares against the tier-appropriate budget. If over budget, applies
# the side effects (idempotent) and emits the COST_BUDGET_EXCEEDED signal.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = (optional) tier label or short name (default: standard)
#   $4 = (optional) issue_meta_json — used for has-label idempotency check
#
# Stdout: COST_BUDGET_EXCEEDED line on block, nothing on allow.
# Returns:
#   0 = breaker fired (block dispatch)
#   1 = under budget OR aggregation failed (fail-open: allow dispatch)
#
# t2061 audit (2026-04-14):
#
# Error path classification for _check_cost_budget:
#
#   Invalid args (non-numeric issue_number, empty repo_slug):
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: guard cannot operate without valid inputs.
#       Cannot enforce a budget we can't identify the issue for.
#
#   _get_cost_budget_for_tier failure or non-numeric budget:
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot enforce a budget we can't determine.
#
#   _sum_issue_token_spend failure (gh API error, sed/grep error):
#     → || return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot enforce a budget we can't measure.
#       Transient GitHub API failures should not permanently block dispatch.
#
#   Non-numeric spent/attempts values from _sum_issue_token_spend:
#     → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: defensive guard against malformed aggregation.
#
#   jq label_hit extraction failure (idempotency check on over-budget path):
#     → || label_hit="false" → has_label="false" → side effects re-applied
#     → _apply_cost_breaker_side_effects is idempotent (gh label ops are
#       idempotent), so re-application is harmless.
#     → FAIL-OPEN INTENTIONAL for idempotency check only; the COST_BUDGET_EXCEEDED
#       signal and return 0 (block) still fire correctly.
#
# t2007 design intent: the cost budget is a secondary safety measure for
# runaway spending. Fail-open prevents spending limits from becoming permanent
# dispatch deadlocks. The critical safety gates (parent-task GUARD_UNCERTAIN,
# gh-api-failure GUARD_UNCERTAIN) sit above this function in is_assigned() and
# do not tolerate errors. This is confirmed by the docstring:
# "1 = under budget OR aggregation failed (fail-open: allow dispatch)".
# ALREADY CONFIRMED FAIL-OPEN BY DESIGN — no hardening needed (t2061).
#######################################
_check_cost_budget() {
	local issue_number="$1"
	local repo_slug="$2"
	local tier="${3:-standard}"
	local issue_meta_json="${4:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# GH#29691: assignment inspection can run while completion reconciliation is
	# still removing a task from the dispatch projection.  A completed worker's
	# footer may exceed the budget, but terminal work cannot consume another
	# dispatch and must not be relabelled or spawn a root-cause meta-issue.  Check
	# the metadata already fetched by is_assigned() before the side-effectful cost
	# path.  The direct diagnostic command omits metadata and retains its existing
	# aggregation behaviour.
	if [[ -n "$issue_meta_json" ]] && printf '%s' "$issue_meta_json" |
		jq -e '((.state // "" | ascii_downcase) == "closed") or any(.labels[]?.name; . == "status:done" or . == "status:resolved")' \
			>/dev/null 2>&1; then
		return 1
	fi

	local budget
	budget=$(_get_cost_budget_for_tier "$tier")
	if [[ -z "$budget" ]] || ! [[ "$budget" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	local spend_data
	spend_data=$(_sum_issue_token_spend "$issue_number" "$repo_slug") || return 1

	local spent attempts
	spent="${spend_data%%|*}"
	attempts="${spend_data##*|}"

	if ! [[ "$spent" =~ ^[0-9]+$ ]] || ! [[ "$attempts" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ "$spent" -le "$budget" ]]; then
		# Under budget — allow dispatch
		return 1
	fi

	local _cost_trip_msg
	_cost_trip_msg="cost-circuit-breaker:fired issue=#${issue_number} repo=${repo_slug} tier=${tier#tier:} spent=${spent} budget=${budget} attempts=${attempts}"
	if [[ -n "${LOGFILE:-}" ]]; then
		printf '[pulse-wrapper] %s\n' "$_cost_trip_msg" >>"$LOGFILE" 2>/dev/null || true
	fi
	local _audit_log_helper="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/audit-log-helper.sh"
	if [[ -x "$_audit_log_helper" ]]; then
		"$_audit_log_helper" log cost-circuit-breaker "$_cost_trip_msg" >/dev/null 2>&1 || true
	fi

	# Apply the structural block and marker-idempotent diagnostics.
	_apply_cost_breaker_side_effects "$issue_number" "$repo_slug" \
		"$spent" "$budget" "${tier#tier:}" "$attempts"

	# Emit signal for caller pattern matching (mirrors PARENT_TASK_BLOCKED)
	printf 'COST_BUDGET_EXCEEDED (spent=%dK budget=%dK tier=%s attempts=%d)\n' \
		"$((spent / 1000))" "$((budget / 1000))" "${tier#tier:}" "$attempts"
	return 0
}
