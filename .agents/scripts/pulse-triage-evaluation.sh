#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Triage Evaluation -- Consolidation and simplification label
# re-evaluation, child/PR existence checks, and comment filtering.
# =============================================================================
# Extracted from pulse-triage.sh as part of the file-size-debt split
# (parent: GH#21146, child: GH#21326).
#
# Functions in this sub-library:
#   - _clear_needs_consolidation_label
#   - _reevaluate_consolidation_labels
#   - _post_simplification_gate_cleared_comment
#   - _reevaluate_stale_continuations
#   - _reevaluate_simplification_labels
#   - _consolidation_child_exists
#   - _consolidation_resolving_pr_exists
#   - _consolidation_substantive_comments
#   - _format_consolidation_comments_section
#
# Usage: source "${SCRIPT_DIR}/pulse-triage-evaluation.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - pulse-triage-cache.sh (_gh_idempotent_comment)
#   - pulse-triage-dispatch.sh (_consolidation_lock_label_present — lazy resolution)
#   - LOGFILE, REPOS_JSON, ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS,
#     ISSUE_CONSOLIDATION_COMMENT_THRESHOLD (set by orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_TRIAGE_EVALUATION_LIB_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_EVALUATION_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

# t2161: Idempotently remove the `needs-consolidation` label from an issue
# and log the reason. Used by `_issue_needs_consolidation`'s two auto-clear
# branches (in-flight resolving PR + post-filter substantive_count drop).
# Extracted to keep the parent function under the per-function complexity
# threshold. Args: $1=issue_number $2=repo_slug $3=reason (free-text).
_clear_needs_consolidation_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "needs-consolidation" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Consolidation gate cleared for #${issue_number} (${repo_slug}) — ${reason}" >>"$LOGFILE"
	return 0
}

#######################################
# Re-evaluate all needs-consolidation labeled issues across pulse repos.
# Issues filtered out by list_dispatchable_issue_candidates_json (needs-*
# exclusion) never reach dispatch_with_dedup, so the auto-clear logic in
# _issue_needs_consolidation can't fire. This pass runs them through the
# current filter and removes the label if they no longer trigger.
# Lightweight: one gh issue list per repo + one _issue_needs_consolidation
# call per labeled issue. Runs every cycle before the early fill floor.
#######################################
_reevaluate_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local issues_json
		issues_json=$(gh_issue_list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"

		while IFS= read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# _issue_needs_consolidation returns 1 (no consolidation needed)
			# AND auto-clears the label when was_already_labeled=true
			if ! _issue_needs_consolidation "$num" "$slug"; then
				total_cleared=$((total_cleared + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[]?.number // ""')
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation re-evaluation: cleared ${total_cleared} stale needs-consolidation label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Post a "Large File Simplification Gate — CLEARED" follow-up comment
# on an issue whose `needs-simplification` label was just removed. This
# annotates the prior "Held from dispatch" comment as superseded so
# readers (workers, supervisors, humans) don't act on stale state.
#
# Idempotent: uses _gh_idempotent_comment with a per-issue marker so it
# only posts once per clearing event even if the re-eval loop visits the
# same issue across multiple cycles.
#
# t2042: addresses the misleading-comment failure mode where #18418
# carried a "Held from dispatch" comment from a pre-t2024 gate
# evaluation while dispatch was already proceeding under the
# scoped-range bypass.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
# Returns: 0 always (best-effort, never blocks)
#######################################
_post_simplification_gate_cleared_comment() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local _scoped_threshold="${SCOPED_RANGE_THRESHOLD:-300}"
	local _large_threshold="${LARGE_FILE_LINE_THRESHOLD:-2000}"
	local _marker="<!-- simplification-gate-cleared:${issue_number} -->"
	local _body="${_marker}
## Large File Simplification Gate — CLEARED

The previous \"Held from dispatch\" comment on this issue no longer
applies. On re-evaluation, the cited file references either fall within
the scoped-range bypass (≤ ${_scoped_threshold} lines per range) or the
target file has been simplified below ${_large_threshold} lines.

The \`needs-simplification\` label has been removed and the issue is
open for dispatch.

_Automated by \`_post_simplification_gate_cleared_comment()\` in pulse-triage.sh (t2042)_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"$_marker" "$_body" || true
	return 0
}

#######################################
# t2170 Fix E (secondary): Check if ALL continuation citations in the
# large-file gate sticky comment are stale. Called when
# _issue_targets_large_files returned 0 (file still targeted) to detect
# deadlocked issues where phantom continuations prevent fresh gate
# re-evaluation.
#
# A continuation citation is stale when:
#   - The cited issue is CLOSED, AND one of:
#     (a) it carries `simplification-incomplete` (Fix D, t2169) — file
#         never simplified; short-circuits the wc -l check.
#     (b) _large_file_gate_verify_prior_reduced_size confirms file is
#         still over threshold.
#   - If the cited issue is OPEN → valid (work in progress), preserve.
#   - If the issue or its path is unresolvable → conservative: preserve.
#
# When ALL citations are stale the label is removed so the next dispatch
# cycle re-fires the gate fresh (which, post-Fix-A/B, files a new debt
# issue instead of re-citing the phantom).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - repo_path
# Returns: 0 (cleared label), 1 (preserved label)
#######################################
_reevaluate_stale_continuations() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Fetch gate sticky comment. map+.[0] preserves the full multi-line body
	# (.[]+head-1 would truncate to the heading line, losing the issue refs).
	local gate_comment
	gate_comment=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--comments --json comments \
		--jq '.comments | map(select(.body | contains("## Large File Simplification Gate"))) | .[0].body // empty' \
		2>/dev/null) || gate_comment=""
	[[ -n "$gate_comment" ]] || return 1

	# Extract only the "recently-closed — continuation" issue numbers; open
	# "existing"/"new" entries don't cause the deadlock this fix targets.
	local continuation_nums
	continuation_nums=$(printf '%s' "$gate_comment" |
		grep -oE '#[0-9]+ \(recently-closed' |
		grep -oE '[0-9]+') || continuation_nums=""
	[[ -n "$continuation_nums" ]] || return 1

	local all_stale="true"
	local cont_num
	while IFS= read -r cont_num; do
		[[ "$cont_num" =~ ^[0-9]+$ ]] || continue

		local cont_info cont_state cont_labels
		cont_info=$(gh issue view "$cont_num" --repo "$repo_slug" \
			--json state,labels,title 2>/dev/null) || cont_info=""
		if [[ -z "$cont_info" ]]; then
			all_stale="false"
			break # Unresolvable → conservative
		fi

		cont_state=$(printf '%s' "$cont_info" | jq -r '.state // "OPEN"' 2>/dev/null)
		cont_state_upper=$(printf '%s' "$cont_state" | tr '[:lower:]' '[:upper:]')
		if [[ "$cont_state_upper" != "CLOSED" ]]; then
			all_stale="false"
			break # Open → work in progress
		fi

		# Closed — short-circuit via simplification-incomplete (Fix D, t2169)
		# or verify via file-size check.
		cont_labels=$(printf '%s' "$cont_info" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || cont_labels=""
		if [[ ",$cont_labels," == *",simplification-incomplete,"* ]]; then
			continue # definite stale, no wc -l needed
		fi

		# Parse path from title: "file-size-debt: <path> exceeds N lines"
		# Also handles legacy "simplification-debt: <path> exceeds N lines" titles
		# for backward compat during the label migration period.
		local cont_title cont_file_path
		cont_title=$(printf '%s' "$cont_info" | jq -r '.title // ""' 2>/dev/null) || cont_title=""
		cont_file_path=$(printf '%s' "$cont_title" |
			sed 's/^file-size-debt: //;s/^simplification-debt: //;s/ exceeds [0-9]* lines$//' 2>/dev/null) || cont_file_path=""
		if [[ -z "$cont_file_path" || "$cont_file_path" == "$cont_title" ]]; then
			all_stale="false"
			break # Path unresolvable → conservative
		fi

		# Guard: function is in pulse-dispatch-large-file-gate.sh (sourced first)
		if ! declare -F _large_file_gate_verify_prior_reduced_size >/dev/null 2>&1; then
			all_stale="false"
			break # Function unavailable → conservative
		fi

		# Returns 0 = file under threshold (valid), 1 = still over (stale)
		if _large_file_gate_verify_prior_reduced_size \
			"$cont_num" "$cont_file_path" "$repo_path"; then
			all_stale="false"
			break # Prior work was effective → valid citation
		fi
	done < <(printf '%s\n' "$continuation_nums")

	if [[ "$all_stale" == "true" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-simplification" >/dev/null 2>&1 || true
		echo "[pulse-triage] Cleared stale needs-simplification on #${issue_number} (all cited continuations phantom; next dispatch will re-evaluate the gate)" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Backfill auto-dispatch metadata onto open simplification-debt issues that are
# already available and not explicitly blocked. Simplification scanners can
# create maintainer-review-shaped issues; after approval/normalization they may
# retain status:available + function-complexity-debt without auto-dispatch,
# leaving real work visible but unreachable by the pulse queue scanner.
#
# Arguments:
#   $1 - repo slug
# Outputs: number of issues updated
# Returns: 0 always (best-effort; label repair must not break pulse)
#######################################
_backfill_simplification_auto_dispatch_labels() {
	local slug="$1"
	local issues_json="[]"
	local updated=0

	[[ -n "$slug" ]] || {
		printf '0\n'
		return 0
	}

	issues_json=$(gh_issue_list --repo "$slug" --state open \
		--label "function-complexity-debt" --label "status:available" \
		--json number,labels --limit 100 2>/dev/null) || issues_json="[]"

	local num="" labels_to_add=""
	while IFS=$'\t' read -r num labels_to_add; do
		[[ "$num" =~ ^[0-9]+$ ]] || continue
		[[ -n "$labels_to_add" ]] || labels_to_add="auto-dispatch"
		if gh issue edit "$num" --repo "$slug" \
			--add-label "$labels_to_add" >/dev/null 2>&1; then
			updated=$((updated + 1))
		fi
	done < <(printf '%s' "$issues_json" | jq -r '
		.[]?
		| (.labels | map(.name)) as $labels
		| select(($labels | index("auto-dispatch")) == null)
		| select(($labels | index("no-auto-dispatch")) == null)
		| select(($labels | index("needs-maintainer-review")) == null)
		| select(($labels | index("parent-task")) == null)
		| select(($labels | index("status:blocked")) == null)
		| select(($labels | index("status:queued")) == null)
		| select(($labels | index("status:in-progress")) == null)
		| select(($labels | index("status:in-review")) == null)
		| [(.number // empty), (if any($labels[]; startswith("tier:")) then "auto-dispatch" else "auto-dispatch,tier:standard" end)]
		| @tsv
	' 2>/dev/null)

	printf '%s\n' "$updated"
	return 0
}

#######################################
# Re-evaluate needs-simplification labeled issues across pulse repos.
# Same pattern as _reevaluate_consolidation_labels: issues filtered out
# by the needs-* exclusion never reach dispatch_with_dedup, so the
# auto-clear at the end of _issue_targets_large_files can't fire.
# This pass re-evaluates them and clears the label when the file is
# now excluded (lockfile, JSON config) or below threshold.
#
# t2170 Fix E (secondary): also runs _reevaluate_stale_continuations when
# _issue_targets_large_files returns 0 (file still targeted). This covers
# the deadlock where phantom continuation citations block the gate from
# re-firing and creating a fresh (accurate) debt issue.
#######################################
_reevaluate_simplification_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	local total_backfilled=0
	while IFS='|' read -r slug rpath; do
		[[ -n "$slug" && -n "$rpath" ]] || continue

		# t2433/GH#20071: Pull repo to latest remote state before measuring
		# file sizes. Without this, a stale local copy causes
		# _issue_targets_large_files to use pre-split line counts, keeping
		# needs-simplification labels on issues that have already been resolved.
		# Sentinel in _pulse_refresh_repo prevents redundant pulls if both
		# the dispatch loop and triage loop hit the same repo in one cycle.
		_pulse_refresh_repo "$rpath"

		local backfilled_count=0
		backfilled_count=$(_backfill_simplification_auto_dispatch_labels "$slug") || backfilled_count=0
		[[ "$backfilled_count" =~ ^[0-9]+$ ]] || backfilled_count=0
		total_backfilled=$((total_backfilled + backfilled_count))

		local issues_json
		issues_json=$(gh_issue_list --repo "$slug" --state open \
			--label "needs-simplification" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"

		while IFS= read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			local body
			body=$(gh issue view "$num" --repo "$slug" \
				--json body --jq '.body // ""' 2>/dev/null) || body=""
			# _issue_targets_large_files returns 1 (no large files) AND
			# auto-clears the label when was_already_labeled.
			# t1998: pass force_recheck=true to bypass the
			# skip-if-already-labeled short-circuit at pulse-dispatch-core.sh:592.
			# Without this flag, the re-eval loop never sees a cleared case
			# because the function returns 0 immediately on any already-labeled
			# issue, keeping stale needs-simplification labels forever.
			if ! _issue_targets_large_files "$num" "$slug" "$body" "$rpath" "true"; then
				total_cleared=$((total_cleared + 1))
				# t2042: post follow-up "CLEARED" comment so the original
				# "Held from dispatch" comment doesn't mislead readers.
				_post_simplification_gate_cleared_comment "$num" "$slug"
			else
				# t2170 Fix E (secondary): file still targets large files but
				# check if ALL cited continuation issues are stale/phantom.
				# Clears the label so the next dispatch cycle re-evaluates
				# the gate fresh — breaking the deadlock where a phantom
				# continuation blocks new accurate debt issue creation.
				if _reevaluate_stale_continuations "$num" "$slug" "$rpath"; then
					total_cleared=$((total_cleared + 1))
				fi
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[]?.number // ""')
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: cleared ${total_cleared} stale needs-simplification label(s)" >>"$LOGFILE"
	fi
	if [[ "$total_backfilled" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: backfilled auto-dispatch on ${total_backfilled} function-complexity-debt issue(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t1982/t2144/t2151: Check whether a consolidation-task child issue currently
# "owns" this parent. Used by both _issue_needs_consolidation (as a
# pre-filter) and _dispatch_issue_consolidation (as an idempotency guard)
# so that repeat calls on the same parent do not create duplicate children.
#
# A child "owns" the parent if ANY of:
#   (a) a consolidation-task child is currently open, OR
#   (b) a consolidation-task child closed within the grace window
#       (CONSOLIDATION_RECENT_CLOSE_GRACE_MIN minutes, default 30), OR
#   (c) (t2151) the parent carries the `consolidation-in-progress` label —
#       another pulse runner is mid-way through creating a child right now.
#
# (a) and (b) cover single-runner cascades (t1982 / t2144).
# (c) covers the cross-runner race window between "about to create child"
# and "child exists on GitHub". See `_consolidation_lock_acquire` for the
# lock protocol.
#
# The grace window exists because closing the consolidation-task child
# and applying the `consolidated` label to the parent are separate steps —
# the worker closes the child first, then updates the parent. Between
# those two API calls the state is {child: closed, parent: still needs-
# consolidation, no open child}. `_backfill_stale_consolidation_labels`
# previously saw this as "no child, dispatch a new one" and re-fired,
# cascading indefinitely (observed: #19321 → #19341 + #19367 cascade on
# 2026-04-16 across two pulse runners). The grace window collapses that
# race to a single cycle.
#
# Uses GitHub's `in:body` search over the consolidation-task label scope.
# The child body always contains the literal token "Consolidation target: #NNN"
# (see _compose_consolidation_child_body) which is the searchable anchor.
#
# Args: $1=parent_num $2=repo_slug [$3=grace_minutes_override]
# Returns: 0 if an open-or-recently-closed child exists OR lock label is
#          present, 1 otherwise.
#######################################
_consolidation_dispatch_comment_exists() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	local marker_count
	marker_count=$(set -o pipefail; gh api "repos/${repo_slug}/issues/${parent_num}/comments?per_page=100" \
		--paginate --slurp | jq -r '
			[ (if (type == "array" and ((.[0]? | type) == "array")) then .[] else . end)[]
			| select((.body // "") | contains("## Issue Consolidation Dispatched")) ] | length
	') || return 1
	[[ "$marker_count" =~ ^[0-9]+$ ]] || marker_count=0
	if [[ "$marker_count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

_consolidation_child_exists() {
	local parent_num="$1"
	local repo_slug="$2"
	local grace_minutes="${3:-${CONSOLIDATION_RECENT_CLOSE_GRACE_MIN:-30}}"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	# t3565: Parent pointer comments are an idempotency signal too. Search API
	# can time out or lag on large repos; a previously posted dispatch comment
	# means a child was already created, so block repeat child creation.
	if _consolidation_dispatch_comment_exists "$parent_num" "$repo_slug"; then
		return 0
	fi

	# Fast path: any open child immediately owns the parent.
	local open_count open_exit=0
	open_count=$(gh_issue_list --repo "$repo_slug" --state open \
		--label "consolidation-task" \
		--search "in:body \"Consolidation target: #${parent_num}\"" \
		--json number --jq 'length' --limit 5 2>/dev/null) || open_exit=$?
	if [[ "$open_exit" -ne 0 ]]; then
		# Fail closed: creating a duplicate consolidation child is worse than
		# retrying after a transient GitHub search/API issue.
		return 0
	fi
	[[ "$open_count" =~ ^[0-9]+$ ]] || open_count=0
	if [[ "$open_count" -gt 0 ]]; then
		return 0
	fi

	# t2151: lock label is a third blocking condition. A competing runner
	# that has acquired (or is acquiring) the lock owns the parent for the
	# duration of its critical section. Cheap — one label-read, no search.
	if _consolidation_lock_label_present "$parent_num" "$repo_slug"; then
		return 0
	fi

	# No open child — check for a recently-closed one within the grace
	# window. grace_minutes=0 disables the window (test hook).
	[[ "$grace_minutes" =~ ^[0-9]+$ ]] || grace_minutes=30
	if [[ "$grace_minutes" -eq 0 ]]; then
		return 1
	fi

	# Prefer GNU date -d (Linux, coreutils); fall back to BSD date -v (macOS).
	local cutoff_iso=""
	cutoff_iso=$(date -u -d "${grace_minutes} minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || cutoff_iso=""
	if [[ -z "$cutoff_iso" ]]; then
		cutoff_iso=$(date -u -v-"${grace_minutes}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || cutoff_iso=""
	fi
	# If both date variants failed (highly unusual), fall back to open-only
	# behaviour. This preserves pre-t2144 semantics rather than risking
	# false negatives from a broken cutoff.
	[[ -n "$cutoff_iso" ]] || return 1

	local recent_closed_count
	recent_closed_count=$(gh_issue_list --repo "$repo_slug" --state closed \
		--label "consolidation-task" \
		--search "in:body \"Consolidation target: #${parent_num}\" closed:>${cutoff_iso}" \
		--json number --jq 'length' --limit 5 2>/dev/null) || recent_closed_count=0
	[[ "$recent_closed_count" =~ ^[0-9]+$ ]] || recent_closed_count=0
	[[ "$recent_closed_count" -gt 0 ]]
}

#######################################
# t2161: Check whether an open PR with a GitHub-native closing keyword
# referencing this parent issue is currently in-flight. Used as a safety
# net by `_issue_needs_consolidation` and `_dispatch_issue_consolidation`
# to prevent the cascade observed in GH#19448 → GH#19469 → GH#19471, where
# version drift on a contributor runner caused a stale filter to falsely
# trigger consolidation while a fix PR was already mergeable.
#
# Why this is needed AT ALL given t2144's filter fix:
#   The substantive-comment filter is the right primary defence (it solves
#   the cause: noise comments). This helper is a defence-in-depth safety
#   net that holds even when:
#     (a) a contributor runner is running pre-t2144 code,
#     (b) a future filter regression slips through,
#     (c) a new operational comment shape ships and drifts past the regex.
#   In all three cases, the existence of an in-flight PR resolving the
#   parent is a strong, runtime-checkable "the work is in progress, do
#   not file a planning task on top of it" signal.
#
# Why "in-flight PR" is a stronger signal than "open PR":
#   GitHub only auto-closes the issue when the PR MERGES, so an open PR
#   with a closing keyword has not yet resolved the issue — but the work
#   is committed, reviewable, and a consolidation child filed now would
#   become noise the moment the PR merges (the issue closes within
#   seconds of merge). Asymmetric cost: skipping consolidation when there
#   is an in-flight fix is cheap and reversible (the next pulse cycle
#   fires if the PR closes without merging); filing a duplicate child
#   issue burns a worker session and pollutes the issue thread.
#
# Closing-keyword regex sourced from `_extract_linked_issue` in
# pulse-merge.sh:1173 — matches GitHub's full close keyword list:
# close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved
# (case-insensitive). Bare `#NNN` references and `For #NNN` / `Ref #NNN`
# references do NOT match — those are intentionally non-closing.
#
# Args: $1=parent_num $2=repo_slug
# Returns: 0 if an open PR with a closing keyword referencing the parent
#          exists, 1 otherwise (including network/parse errors — fail open
#          so a misbehaving search never blocks legitimate consolidation).
#######################################
_consolidation_resolving_pr_exists() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	# Fast prefilter: GitHub search for open PRs that mention the parent
	# anywhere in body. Cheap (one search hit, capped at 10 results) and
	# scopes the regex match below to the small candidate set.
	local prs_json
	prs_json=$(gh_pr_list --repo "$repo_slug" --state open \
		--search "in:body #${parent_num}" \
		--json number,body --limit 10 2>/dev/null) || prs_json="[]"
	[[ -n "$prs_json" ]] || prs_json="[]"

	# Filter for GitHub-native closing keyword + #N (case-insensitive).
	# Word boundary on the trailing # is enforced via the look-ahead
	# `[^0-9]` (or end of string) so #${parent_num} does not match
	# #${parent_num}1 / #${parent_num}99 etc.
	local match_count
	match_count=$(printf '%s' "$prs_json" | jq --arg n "$parent_num" '
		[.[] | select(
			(.body // "")
			| test("(?i)\\b(close[ds]?|fix(es|ed)?|resolve[ds]?)[ \\t]+#" + $n + "\\b")
		)] | length
	' 2>/dev/null) || match_count=0
	[[ "$match_count" =~ ^[0-9]+$ ]] || match_count=0
	if [[ "$match_count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

#######################################
# t1982: Fetch and filter substantive comments on an issue using the same
# predicate as the substantive_count in _issue_needs_consolidation. Returns
# a JSON array of {login, created_at, body} objects on stdout.
#
# Kept in its own helper so the dispatch path can reuse the filter without
# re-implementing it, and so future filter tweaks live in one place.
#######################################
_consolidation_substantive_comments() {
	local issue_number="$1"
	local repo_slug="$2"

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments_json="[]"

	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"

	# t2144: Added ^<!-- WORKER_SUPERSEDED and ^<!-- stale-recovery-tick
	# patterns here too — this helper is used by the dispatch path to compose
	# the child issue body, so it must stay in lockstep with the predicate in
	# _issue_needs_consolidation above. Divergence between the two filters
	# would mean the child ISSUE shows WORKER_SUPERSEDED comments as
	# "substantive" even though they can no longer trigger dispatch.
	printf '%s' "$comments_json" | jq -s --argjson min "$min_chars" '
		add as $comments |
		[$comments[] | select(
			(.body | length) >= $min
			and (.user.type != "Bot")
			and (.body | test("DISPATCH_CLAIM nonce=") | not)
			and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
			and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
			and (.body | test("^<!-- WORKER_SUPERSEDED") | not)
			and (.body | test("^<!-- stale-recovery-tick") | not)
			and (.body | test("^<!-- cost-circuit-breaker:fired") | not)
			and (.body | test("^<!-- triage-escalation") | not)
			and (.body | test("CLAIM_RELEASED reason=") | not)
			and (.body | test("^(Worker failed:|## Worker Watchdog Kill)") | not)
			and (.body | test("^(\\*\\*)?Stale assignment recovered") | not)
			and (.body | test("^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Issue Consolidation Dispatched|Additional Review Feedback|Cascade Tier Escalation)") | not)
			and (.body | test("^## Review: Recommendation:") | not)
			and (.body | test("^This quality-debt issue was auto-generated by") | not)
			and (.body | test("<!-- MERGE_SUMMARY -->") | not)
			and (.body | test("^Closing:") | not)
			and (.body | test("^Worker failed: orphan worktree") | not)
			and (.body | test("sudo aidevops approve") | not)
			and (.body | test("^_Automated by") | not)
		) | {login: .user.login, created_at: .created_at, body: .body}]
	' 2>/dev/null || printf '[]'
	return 0
}

#######################################
# t1982: Format substantive comments JSON into a readable Markdown section.
# Returns formatted text to stdout. Called by _compose_consolidation_child_body.
#
# Args: $1=substantive_json
#######################################
_format_consolidation_comments_section() {
	local substantive_json="$1"
	local result
	result=$(printf '%s' "$substantive_json" | jq -r '
		if (. | length) == 0 then
			"_No substantive comments captured — the filter excluded everything. If this seems wrong, inspect the filter in _consolidation_substantive_comments._"
		else
			to_entries | map(
				"### Comment " + ((.key + 1) | tostring) + " — @" + .value.login + " at " + .value.created_at +
				"\n\n" + .value.body + "\n"
			) | join("\n---\n\n")
		end
	' 2>/dev/null) || result="_Comment fetch failed._"
	printf '%s' "$result"
	return 0
}
