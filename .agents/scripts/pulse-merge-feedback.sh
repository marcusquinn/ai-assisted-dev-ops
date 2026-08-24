#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-feedback.sh — Worker-PR feedback routing for the deterministic merge pass.
#
# Extracted from pulse-merge.sh (GH#19836) to bring that file below the
# 2000-line simplification gate.
#
# This module contains the "route feedback to linked issue + close PR"
# cluster: the three dispatch helpers invoked by _check_pr_merge_gates
# when a worker-authored PR hits a dead-end state (CI red, conflicts
# unresolvable by update-branch, or CHANGES_REQUESTED review). Each
# helper appends a feedback section to the linked issue body (marker-
# guarded for idempotency), transitions the issue to status:available,
# and closes the PR so the dispatch queue can re-pick the work.
#
# None of these functions call back into the merge core or pr-gates
# clusters — they only call low-level `gh` commands, `set_issue_status`
# from shared-constants.sh, and the local `_build_review_feedback_section`
# helper. Safe to extract into its own module.
#
# This module is sourced by pulse-wrapper.sh AFTER pulse-merge.sh and
# pulse-merge-conflict.sh. It MUST NOT be executed directly — it relies
# on the orchestrator having sourced shared-constants.sh and having
# defined all PULSE_* configuration constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _build_review_feedback_section      (t2093)
#   - _append_feedback_to_issue           (GH#20057, shared helper)
#   - _transition_issue_for_redispatch    (GH#20057, shared helper)
#   - _finalize_feedback_route            (GH#29288, sourced state machine)
#   - _build_ci_feedback_section          (GH#20057, extracted builder)
#   - _dispatch_ci_fix_worker             (t2093 follow-up)
#   - _classify_conflicts_by_pattern      (t2987, pattern classifier)
#   - _emit_pattern_guidance_blocks       (t2987, guidance emitter)
#   - _build_conflict_feedback_section    (t2426, extracted builder)
#   - _dispatch_conflict_fix_worker       (t2093 follow-up)
#   - _dispatch_pr_fix_worker             (t2093)
#
# Routing failures remain isolated from unrelated PRs, but incomplete
# finalization returns a typed deferred/maintainer outcome to the merge loop.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_FEEDBACK_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# Ensures LOGFILE is safe to dereference in all functions when this module
# is sourced outside the pulse-wrapper.sh bootstrap context.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${PULSE_REVIEW_FEEDBACK_ITEM_LIMIT:=4000}"
: "${PULSE_REVIEW_FEEDBACK_SECTION_LIMIT:=12000}"
PULSE_REVIEW_REPAIR_SOURCE_LABEL="source:review-repair"

_CI_REPAIR_OUTCOME_SUMMARY=""

_pmf_gh_read() {
	local rc=0
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_feedback_finalizer_path="${BASH_SOURCE[0]%/*}/pulse-merge-feedback-finalizer.sh"
if [[ -r "$_feedback_finalizer_path" ]]; then
	# shellcheck source=./pulse-merge-feedback-finalizer.sh
	source "$_feedback_finalizer_path"
fi
unset _feedback_finalizer_path

#######################################
# Build the markdown "Review Feedback" section for routing to a linked
# issue (t2093).
#
# Reads already-fetched review + inline-comment JSON arrays and produces a
# human-readable section with file:line citations. The section is scoped
# to a single closing PR so the marker in `_dispatch_pr_fix_worker` can
# prevent duplicate appends if the merge pass re-encounters the same PR
# before the close propagates.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - reviews_json    (JSON array of {author,state,body,url})
#   $4 - inline_json     (JSON array of {author,path,line,body,url})
#
# Output: markdown section on stdout (empty string if no content).
#######################################
_build_review_feedback_section() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json="${3:-[]}"
	local inline_json="${4:-[]}"

	local reviews_count="" inline_count=""
	reviews_count=$(printf '%s' "$reviews_json" | jq 'length' 2>/dev/null) || reviews_count=0
	inline_count=$(printf '%s' "$inline_json" | jq 'length' 2>/dev/null) || inline_count=0
	[[ "$reviews_count" =~ ^[0-9]+$ ]] || reviews_count=0
	[[ "$inline_count" =~ ^[0-9]+$ ]] || inline_count=0

	if [[ "$reviews_count" -eq 0 && "$inline_count" -eq 0 ]]; then
		return 0
	fi

	local header
	header="## Review Feedback routed from PR #${pr_number} (t2093)

This section was auto-generated when the deterministic merge pass detected
\`reviewDecision=CHANGES_REQUESTED\` on the linked worker PR. A head-bound
finalizer is routing the issue for redispatch. The next worker should address
the findings below and open a fresh PR against this issue.

See the original PR for full context: https://github.com/${repo_slug}/pull/${pr_number}
"

	local reviews_md=""
	if [[ "$reviews_count" -gt 0 ]]; then
		reviews_md=$(printf '%s' "$reviews_json" | jq -r \
			--argjson item_limit "$PULSE_REVIEW_FEEDBACK_ITEM_LIMIT" '
			def quoted_body:
				((.body // "") | gsub("\r"; "") | .[0:$item_limit]) as $body
				| if $body == "" then "  > _(no review body provided)_"
				  else ($body | split("\n") | map("  > " + .) | join("\n")) end;
			.[] | "- **@\(.author)** (`\(.state)`)\n\(quoted_body)\n  [view review](\(.url // ""))"
		' 2>/dev/null) || reviews_md=""
	fi

	local inline_md=""
	if [[ "$inline_count" -gt 0 ]]; then
		inline_md=$(printf '%s' "$inline_json" | jq -r \
			--argjson item_limit "$PULSE_REVIEW_FEEDBACK_ITEM_LIMIT" '
			def quoted_body:
				((.body // "") | gsub("\r"; "") | .[0:$item_limit]) as $body
				| if $body == "" then "  > _(no inline comment body provided)_"
				  else ($body | split("\n") | map("  > " + .) | join("\n")) end;
			.[] | "- **@\(.author)** `\(.path)`:\(.line // "?")\n\(quoted_body)\n  [view comment](\(.url // ""))"
		' 2>/dev/null) || inline_md=""
	fi

	local section="$header"
	if [[ -n "$reviews_md" ]]; then
		section="${section}
### Top-level reviews

${reviews_md}
"
	fi
	if [[ -n "$inline_md" ]]; then
		section="${section}
### Inline comments (file:line citations)

${inline_md}
"
	fi
	printf '%s' "$section" | jq -Rs -r \
		--argjson section_limit "$PULSE_REVIEW_FEEDBACK_SECTION_LIMIT" '
		if length > $section_limit then
			.[0:$section_limit] + "\n\n_[Additional review feedback omitted by the bounded router; use the source links above for full context.]_\n"
		else . end
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Compute a stable fingerprint for the complete review evidence set.
# IDs establish immutable identity while update metadata and rendered fields
# ensure edited feedback on the same review/comment becomes a new generation.
# Args: $1=reviews JSON, $2=inline comments JSON.
#######################################
_review_feedback_evidence_fingerprint() {
	local reviews_json="$1"
	local inline_json="$2"
	local canonical=""
	local fingerprint=""

	canonical=$(printf '%s\n%s\n' "$reviews_json" "$inline_json" | jq -csS '
		.[0] as $reviews | .[1] as $inline |
		{
			version: 1,
			reviews: ($reviews | map({
				id: (.id // "" | tostring), author: (.author // ""),
				state: (.state // ""), body: (.body // ""), url: (.url // ""),
				submitted_at: (.submitted_at // ""), commit_id: (.commit_id // "")
			}) | sort_by(.id, .submitted_at, .commit_id)),
			inline: ($inline | map({
				id: (.id // "" | tostring), author: (.author // ""), path: (.path // ""),
				line: (.line // 0), body: (.body // ""), url: (.url // ""),
				updated_at: (.updated_at // ""), commit_id: (.commit_id // "")
			}) | sort_by(.id, .updated_at, .commit_id))
		}
		| select(all(.reviews[]; .id != "") and all(.inline[]; .id != ""))
	' 2>/dev/null) || return 1
	[[ -n "$canonical" ]] || return 1
	fingerprint=$(_ci_repair_hash_text "$canonical") || return 1
	[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$fingerprint"
	return 0
}

_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON="[]"
_PULSE_REVIEW_FEEDBACK_INLINE_JSON="[]"

_review_feedback_merge_paginated_arrays() {
	local pages_json="$1"

	printf '%s\n' "$pages_json" | jq -cs '
		if all(.[]; type == "array") then (add // [])
		else error("expected paginated JSON arrays") end
	' 2>/dev/null
	return $?
}

_review_feedback_fetch_evidence() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_rc=0
	local inline_rc=0
	local reviews_pages=""
	local inline_pages=""

	_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON=""
	_PULSE_REVIEW_FEEDBACK_INLINE_JSON=""
	reviews_pages=$(_gh_with_timeout read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/reviews" --paginate \
		--jq '[.[] | select(.state == "CHANGES_REQUESTED" or ((.body // "") | length) > 30)
			| {id: (.id // "" | tostring), author: (.user.login // "unknown"), state: .state,
			   body: (.body // ""), url: (.html_url // ""),
			   submitted_at: (.submitted_at // ""), commit_id: (.commit_id // "")}]' \
		2>/dev/null) || reviews_rc=$?
	inline_pages=$(_gh_with_timeout read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/comments" --paginate \
		--jq '[.[] | {id: (.id // "" | tostring), author: (.user.login // "unknown"),
			path: (.path // ""), line: (.line // .original_line // 0),
			body: (.body // ""), url: (.html_url // ""),
			updated_at: (.updated_at // ""), commit_id: (.commit_id // "")}]' \
		2>/dev/null) || inline_rc=$?
	if [[ "$reviews_rc" -eq 0 ]]; then
		_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON=$(_review_feedback_merge_paginated_arrays "$reviews_pages") || reviews_rc=$?
	fi
	if [[ "$inline_rc" -eq 0 ]]; then
		_PULSE_REVIEW_FEEDBACK_INLINE_JSON=$(_review_feedback_merge_paginated_arrays "$inline_pages") || inline_rc=$?
	fi
	[[ -n "$_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON" ]] || _PULSE_REVIEW_FEEDBACK_REVIEWS_JSON="[]"
	[[ -n "$_PULSE_REVIEW_FEEDBACK_INLINE_JSON" ]] || _PULSE_REVIEW_FEEDBACK_INLINE_JSON="[]"
	if [[ "$reviews_rc" -ne 0 || "$inline_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: review evidence unavailable for PR #${pr_number} in ${repo_slug} (reviews_rc=${reviews_rc}, inline_rc=${inline_rc}) — deferring without routing" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Append a feedback section to a linked issue body, guarded by a marker
# comment for idempotency and with a t2383 fail-safe against body
# clobbering when the issue fetch fails.
#
# Shared by _dispatch_ci_fix_worker, _dispatch_conflict_fix_worker, and
# _dispatch_pr_fix_worker.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - marker        (HTML comment marker string)
#   $4 - feedback_section (markdown to append)
#   $5 - caller        (calling function name, for log messages)
#
# Returns: 0 on success or skip (already present), 1 on failure.
#######################################
_append_feedback_to_issue() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local feedback_section="$4"
	local caller="$5"

	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to
	# prevent clobbering the issue body with only the routed-feedback section.
	local current_body="" fetch_rc=""
	fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] ${caller}: failed to fetch issue #${linked_issue} body (exit ${fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return 1
	fi

	if printf '%s' "$current_body" | grep -qF "$marker"; then
		# Keep the "routed feedback marker" phrase stable for operator log
		# greps and regression tests (GH#20057): the pre-split dispatch
		# functions all logged a variant of "already has … feedback …".
		echo "[pulse-wrapper] ${caller}: issue #${linked_issue} already has routed feedback marker for this PR — skipping" >>"$LOGFILE"
		return 0
	fi

	local new_body="${current_body}

${marker}
${feedback_section}"
	# Use gh_issue_edit_safe (not bare `gh issue edit`) so the REST fallback
	# in shared-gh-wrappers-safe-edit.sh fires when GraphQL is rate-limited.
	# Bare `gh issue edit` always uses GraphQL and silently fails the body
	# update when the 5000/hr GraphQL budget is exhausted. PR #21733 model.
	gh_issue_edit_safe "$linked_issue" --repo "$repo_slug" \
		--body "$new_body" >/dev/null 2>&1 || {
		echo "[pulse-wrapper] ${caller}: failed to update issue #${linked_issue} body — aborting" >>"$LOGFILE"
		return 1
	}
	return 0
}

#######################################
# Transition a linked issue to status:available and add a source label
# so the dispatch queue can re-pick the work.
#
# Uses set_issue_status when available (atomically clears other status
# labels), falls back to direct gh label ops in degraded environments.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - source_label  (e.g. "source:ci-feedback")
#   $4 - clear_hold    (optional: 1 removes hold-for-review on recovery)
#   $5 - companion_source_label (optional compatibility provenance)
#######################################
_transition_issue_for_redispatch() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"
	local clear_hold="${4:-0}"
	local companion_source_label="${5:-}"
	local _assignees=""
	_assignees=$(gh issue view "$linked_issue" --repo "$repo_slug" --json assignees --jq '.assignees[].login' 2>/dev/null) || _assignees=""

	local -a _redispatch_flags=(
		--add-label "origin:worker"
		--remove-label "origin:interactive"
		--remove-label "origin:worker-takeover"
	)
	if [[ -n "$companion_source_label" && "$companion_source_label" != "$source_label" ]]; then
		_redispatch_flags+=(--add-label "$companion_source_label")
	fi
	local _assignee
	while IFS= read -r _assignee; do
		[[ -n "$_assignee" ]] && _redispatch_flags+=(--remove-assignee "$_assignee")
	done <<<"$_assignees"
	if [[ "$clear_hold" == "1" ]]; then
		_redispatch_flags+=(--remove-label "hold-for-review")
	fi

	if declare -F set_issue_status >/dev/null 2>&1; then
		if ! set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "$source_label" "${_redispatch_flags[@]}" >/dev/null 2>&1; then
			echo "[pulse-wrapper] feedback finalizer: failed to transition issue #${linked_issue} in ${repo_slug} to status:available" >>"$LOGFILE"
			return 1
		fi
	else
		if ! _feedback_route_gh_write issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" --add-label "$source_label" \
			"${_redispatch_flags[@]}" \
			--remove-label "status:queued" --remove-label "status:in-progress" \
			--remove-label "status:in-review" --remove-label "status:claimed" \
			>/dev/null 2>&1; then
			echo "[pulse-wrapper] feedback finalizer: fallback transition failed for issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
			return 1
		fi
	fi
	return 0
}

#######################################
# Build the markdown "CI Failure Feedback" section for routing to a
# linked issue.
#
# Args:
#   $1 - pr_number
#   $2 - failing_checks       (markdown list of terminal failed check names/conclusions/URLs)
#   $3 - classification_output (optional, t3225 — multi-line "CLASS names";
#        triggers a Pattern-Specific Resolution Guidance subsection BEFORE
#        the generic worker guidance when any non-OTHER class is present)
#
# Output: markdown section on stdout.
#######################################
_build_ci_feedback_section() {
	local pr_number="$1"
	local failing_checks="$2"
	local classification_output="${3:-}"

	# Locate the ci-failure-patterns.conf registry (t3225) so the guidance
	# emitter can look up resolution commands per classification. Use
	# dirname (not cd+pwd) — t3225 string-literal ratchet avoidance.
	local conf_file
	conf_file="${BASH_SOURCE[0]%/*}/../configs/ci-failure-patterns.conf"

	# Lead with header + terminal failed checks list (always present).
	cat <<-EOF
		## CI Repair Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} had terminal failed CI checks. A head-bound
		finalizer is routing this issue for redispatch. The next worker should address these failures.

		### Terminal failed checks

		${failing_checks}
	EOF

	# Insert pattern-specific guidance blocks BEFORE the generic worker
	# guidance, so the auto-fix sequences are seen first (t3225).
	if [[ -n "$classification_output" ]]; then
		_emit_ci_failure_guidance_blocks "$classification_output" "$conf_file"
	fi

	# Generic worker guidance (always emitted as a fallback).
	cat <<-EOF
		### Worker guidance

		1. Recover the previous PR branch/commits and continue that work; do not restart from scratch.
		2. Read every terminal check URL above and preserve the accumulated evidence.
		3. Rebase the recovered work onto current \`origin/main\`, then fix the code rather than weakening CI.
		4. Run every listed local check and create the replacement PR from the recovered branch.

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF
	return 0
}

#######################################
# Return whether a failed check URL points at a GitHub Actions job whose failed
# log is an infrastructure failure rather than actionable code feedback.
#
# Args:
#   $1 - repo_slug
#   $2 - check URL
#
# Returns: 0=infrastructure failure detected, 1=not detected or unavailable.
#######################################
_ci_check_url_has_infra_failure_log() {
	local repo_slug="$1"
	local check_url="$2"

	[[ -n "$repo_slug" ]] || return 1
	[[ -n "$check_url" ]] || return 1

	local run_id="" job_id=""
	case "$check_url" in
	*"/actions/runs/"*"/job/"*) ;;
	*) return 1 ;;
	esac

	run_id="${check_url#*/actions/runs/}"
	run_id="${run_id%%/*}"
	job_id="${check_url#*/job/}"
	job_id="${job_id%%[/?#]*}"
	[[ "$run_id" =~ ^[0-9]+$ ]] || return 1
	[[ "$job_id" =~ ^[0-9]+$ ]] || return 1

	local failed_log=""
	failed_log=$(gh run view "$run_id" --repo "$repo_slug" --job "$job_id" --log-failed 2>/dev/null) || failed_log=""
	[[ -n "$failed_log" ]] || return 1

	if printf '%s\n' "$failed_log" | grep -Eiq '(Process completed with exit code (124|137|143)|timed out after|[[:space:]]Killed[[:space:]]+timeout|timeout --kill-after|The operation was canceled|cancelled due to timeout|API rate limit exceeded for (installation|user)|You have exceeded a secondary rate limit|toomanyrequests:.*(Rate exceeded|pull rate limit|reached your.*rate limit)|Error response from daemon:.*(429|Too Many Requests|Rate exceeded)|(failed to pull image|failed to resolve source metadata|failed to authorize).*(429|Too Many Requests|Rate exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|Service Unavailable)|(public\.ecr\.aws|docker\.io|ghcr\.io|registry[^[:space:]]*).*(429|Too Many Requests|Rate exceeded|TLS handshake timeout|i/o timeout|connection reset by peer|Service Unavailable))'; then
		return 0
	fi
	return 1
}

#######################################
# Filter required failed checks down to actionable code failures by excluding
# GitHub Actions jobs whose logs show infrastructure-failure signatures.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - checks_json (array of {name, conclusion, link})
#
# Output: markdown list of actionable checks.
#######################################
_ci_actionable_failed_checks_markdown() {
	local pr_number="$1"
	local repo_slug="$2"
	local checks_json="$3"

	local count=""
	count=$(printf '%s' "$checks_json" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$count" -gt 0 ]] || return 0

	local idx=0 name="" conclusion="" link="" evidence_role=""
	while [[ "$idx" -lt "$count" ]]; do
		name=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].name // empty' 2>/dev/null) || name=""
		conclusion=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].conclusion // empty' 2>/dev/null) || conclusion=""
		link=$(printf '%s' "$checks_json" | jq -r --argjson i "$idx" '.[$i].link // empty' 2>/dev/null) || link=""
		if _ci_check_url_has_infra_failure_log "$repo_slug" "$link"; then
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} check '${name}' classified as infrastructure failure from failed log — skipping code redispatch" >>"$LOGFILE"
			if ! declare -F _pmrc_rerun_infrastructure_check >/dev/null 2>&1; then
				echo "[pulse-wrapper] _dispatch_ci_fix_worker: bounded infrastructure rerun helper unavailable for PR #${pr_number} check '${name}' — preserving PR for a later merge pass" >>"$LOGFILE"
			elif ! _pmrc_rerun_infrastructure_check "$repo_slug" "$pr_number" "$name" "$link"; then
				echo "[pulse-wrapper] _dispatch_ci_fix_worker: bounded infrastructure rerun unavailable for PR #${pr_number} check '${name}' — preserving PR for a later merge pass" >>"$LOGFILE"
			fi
		else
			evidence_role=$(_ci_check_evidence_role "$name")
			printf -- '- **%s**: %s — [check URL](%s) — _%s_\n' \
				"$name" "$conclusion" "$link" "$evidence_role"
		fi
		idx=$((idx + 1))
	done
	return 0
}

#######################################
# Classify one failed check for feedback presentation only. This never changes
# whether a check blocks merge or qualifies for bounded repair.
#######################################
_ci_check_evidence_role() {
	local check_name="$1"
	local normalized_name=""
	normalized_name=$(printf '%s' "$check_name" | tr '[:upper:]' '[:lower:]')
	case "$normalized_name" in
	*qlty*threshold* | *qlty*absolute* | *qlty*baseline*)
		printf '%s' 'contextual repository-baseline evidence'
		;;
	*qlty*regression* | *qlty*new-file* | *qlty*new\ file* | *qlty*maintainability\ smells*)
		printf '%s' 'primary PR-delta/new-file evidence'
		;;
	*)
		printf '%s' 'primary failing-check evidence'
		;;
	esac
	return 0
}

#######################################
# Return terminal failed check details and names from one jq pass.
#
# Args:
#   $1 - checks_json (normalized exact-read array with name,bucket,state,link)
#   $2 - terminal_failed_check_filter (jq select expression)
#
# Output: first line is filtered checks JSON, followed by a marker and one
# check name per line. Callers split this without re-running jq over the same
# payload.
#######################################
_ci_terminal_failed_check_results() {
	local checks_json="$1"
	local terminal_failed_check_filter="$2"

	[[ -n "$checks_json" ]] || checks_json="[]"
	printf '%s' "$checks_json" | jq -r "([.[] | select(${terminal_failed_check_filter}) | {name, conclusion: ((.conclusion // .state // \"\") | ascii_downcase), link}] | tojson), \"__AIDEVOPS_CHECK_NAMES__\", (.[] | select(${terminal_failed_check_filter}) | .name)" 2>/dev/null || {
		printf '[]\n__AIDEVOPS_CHECK_NAMES__\n'
		return 0
	}
	return 0
}

_ci_merge_check_sets() {
	local primary_checks="$1"
	local all_checks="$2"
	printf '%s\n%s\n' "$primary_checks" "$all_checks" | jq -sc 'add | unique_by([.name, .link])' 2>/dev/null || printf '%s' "${primary_checks:-[]}"
	return 0
}

#######################################
# Normalize exact required-check output for CI repair evidence collection.
# Args: $1=repo slug, $2=PR number, $3=optional supplied checks JSON
# Stdout: checks JSON, defaulting to an empty array on indeterminate reads
#######################################
_ci_repair_required_checks_json() {
	local repo_slug="$1"
	local pr_number="$2"
	local supplied_checks_json="${3:-}"
	local checks_json="$supplied_checks_json"
	local checks_exit=0

	if [[ -z "$checks_json" ]]; then
		checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" required 2>/dev/null) || checks_exit=$?
		case "$checks_exit" in
		0 | 1 | 8) [[ -n "$checks_json" ]] || checks_json="[]" ;;
		*) checks_json="[]" ;;
		esac
	fi
	printf '%s\n' "$checks_json"
	return 0
}

#######################################
# Route CI failure feedback from a worker/trusted PR to a bounded repair worker
# on the existing PR branch. Fall back to issue redispatch only when the branch
# cannot be repaired in place.
#
# The repair worker sees failing check names, URLs, and current-head context.
# Its durable lease is keyed by repo + PR + head SHA so reordered or changing
# check evidence cannot launch overlapping workers against one branch head. A
# newly-pushed head can enter repair independently if it is still red.
#
# Same pattern as _dispatch_pr_fix_worker (t2093) but for CI failures
# instead of review CHANGES_REQUESTED.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=checks_json (optional)
#######################################
_dispatch_ci_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local supplied_checks_json="${4:-}" initial_head_sha=""
	_CI_REPAIR_OUTCOME_SUMMARY=""

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids CI repair dispatch and feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	initial_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" --json headRefOid --jq '.headRefOid // ""' 2>/dev/null) || initial_head_sha=""
	if [[ -z "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head snapshot unavailable before collecting CI evidence — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	# Collect actionable failed required checks first. Pending/queued/in-progress
	# checks are not actionable repair evidence and must not be routed into the
	# linked issue as stale worker guidance. Likewise, cancelled/timed_out checks
	# usually reflect CI capacity, superseded runs, or job-budget kills; routing
	# those as code-fix feedback creates duplicate PR churn instead of retrying or
	# escalating CI infrastructure. If required checks contain no actionable
	# failures. Advisory failures do not justify branch ownership or repair work.
	local terminal_failed_check_filter='(.bucket == "fail" or .bucket == "cancel") and (((.conclusion // .state // "") | ascii_downcase) | test("^(failure|action_required)$")) and ((.link // "") != "")'
	local checks_json="" result_marker=$'\n__AIDEVOPS_CHECK_NAMES__'
	local check_results="" failing_checks_json="" failing_checks="" failing_names="" classification_output=""
	checks_json=$(_ci_repair_required_checks_json "$repo_slug" "$pr_number" "$supplied_checks_json")
	check_results=$(_ci_terminal_failed_check_results "$checks_json" "$terminal_failed_check_filter")
	failing_checks_json="${check_results%%"$result_marker"*}"
	failing_names="${check_results#*"$result_marker"}"
	[[ "$failing_names" != "$check_results" ]] || failing_names=""
	failing_names="${failing_names#$'\n'}"
	failing_checks=$(_ci_actionable_failed_checks_markdown "$pr_number" "$repo_slug" "$failing_checks_json")

	if [[ -z "$failing_checks" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} in ${repo_slug} has no actionable failed checks with URLs — skipping CI repair routing" >>"$LOGFILE"
		return 0
	fi

	# t3225: Also collect raw failing check NAMES (one per line) for
	# pattern classification. Failure to collect names is non-fatal — we
	# fall back to the pre-t3225 behaviour (no pattern guidance block).
	if [[ -n "$failing_names" ]]; then
		classification_output=$(_classify_ci_failures_by_pattern "$failing_names" 2>/dev/null) || classification_output=""
	fi

	# Bind repair evidence to the current branch head. This refresh also proves
	# the branch is same-repository and writable before any worker is launched.
	local pr_info="" pr_head_sha="" pr_head_ref="" is_cross_repo="" maintainer_can_modify=""
	pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid,headRefName,isCrossRepository,maintainerCanModify \
		--jq '[(.headRefOid // ""),(.headRefName // ""),(.isCrossRepository // false),(.maintainerCanModify // false)] | @tsv' 2>/dev/null) || pr_info=""
	IFS=$'\t' read -r pr_head_sha pr_head_ref is_cross_repo maintainer_can_modify <<<"$pr_info"
	if [[ -n "$initial_head_sha" && "$pr_head_sha" != "$initial_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} head changed while collecting CI evidence (${initial_head_sha} -> ${pr_head_sha:-unknown}) — deferring repair routing" >>"$LOGFILE"
		return 0
	fi

	local failure_fingerprint=""
	failure_fingerprint=$(_ci_repair_hash_text "$(printf '%s\n' "$failing_checks_json" | jq -cS '.' 2>/dev/null)") || failure_fingerprint=""
	[[ -n "$failure_fingerprint" ]] || failure_fingerprint="unknown"

	# Build the CI Failure Feedback section (with optional pattern guidance).
	local feedback_section
	feedback_section=$(_build_ci_feedback_section "$pr_number" "$failing_checks" "$classification_output")

	local fallback_reason=""
	if [[ -z "$pr_head_sha" || -z "$pr_head_ref" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: current branch metadata unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif [[ "$is_cross_repo" == "true" ]]; then
		fallback_reason="the PR head is in a fork and is not an owned repair branch"
	elif ! declare -F _pulse_merge_repo_path_for_slug >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: repository-path resolver unavailable for PR #${pr_number} in ${repo_slug} — preserving PR for a later repair pass" >>"$LOGFILE"
		return 0
	elif _dispatch_ci_repair_session "$pr_number" "$repo_slug" "$linked_issue" \
		"$pr_head_sha" "$pr_head_ref" "$failure_fingerprint" "$failing_checks"; then
		if [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "active" ]]; then
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: in-place CI repair already active for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: dispatched in-place CI repair for PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} in ${repo_slug}" >>"$LOGFILE"
		fi
		return 0
	elif [[ "${_CI_REPAIR_DISPATCH_RESULT:-}" == "exhausted" ]]; then
		fallback_reason="the bounded PR-branch repair session exhausted its retry budget"
	else
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: retryable in-place repair launch failure for PR #${pr_number} head ${pr_head_sha} in ${repo_slug} (result=${_CI_REPAIR_DISPATCH_RESULT:-unknown}) — preserving PR for a later bounded attempt" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] _dispatch_ci_fix_worker: durable fallback authorized for PR #${pr_number} in ${repo_slug}: ${fallback_reason}" >>"$LOGFILE"
	local route_rc=0
	_route_ci_repair_fallback "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"$pr_head_ref" "$failure_fingerprint" "$fallback_reason" "$feedback_section" "$failing_checks" \
		"$_CI_REPAIR_OUTCOME_SUMMARY" || route_rc=$?
	return "$route_rc"
}

#######################################
# Route terminal CI evidence back to the issue when in-place repair is impossible.
#######################################
_route_ci_repair_fallback() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local fallback_reason="$7"
	local feedback_section="$8"
	local failing_checks="$9"
	local attempt_summary="${10:-}"
	local marker_prefix="<!-- ci-feedback-fallback:PR${pr_number}:SHA${pr_head_sha:-unknown}"
	local marker="${marker_prefix} -->"
	local legacy_match="<!-- ci-feedback-fallback:PR${pr_number}:SHA"
	: "$failure_fingerprint"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids CI feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi

	_feedback_route_gh_write label create "ci-feedback-routed" --repo "$repo_slug" --color "E4E669" \
		--description "Worker PR with failing CI routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:ci-feedback" --repo "$repo_slug" --color "FEF2C0" \
		--description "Issue carries CI failure feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true
	feedback_section="${feedback_section}

### In-place repair fallback

- Reason: ${fallback_reason}
- Retry: re-run the deterministic merge pass after restoring access to branch \`${pr_head_ref:-unknown}\`; keep PR #${pr_number} open until that retry is impossible."
	if [[ -n "$attempt_summary" ]]; then
		feedback_section="${feedback_section}

### In-place repair attempt outcomes

${attempt_summary}"
	fi
	local close_comment="## CI repair feedback routed to issue #${linked_issue}

This worker PR had terminal failed CI checks. The check details have been appended
to the linked issue body so the next worker can address them.

Terminal failed checks:
${failing_checks}

_Closed by deterministic merge pass (pulse-merge.sh)._"
	local finalize_rc=0
	_finalize_feedback_route "ci" "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"source:ci-feedback" "ci-feedback-routed" "$marker" "$feedback_section" \
		"_dispatch_ci_fix_worker" "$close_comment" "$legacy_match" || finalize_rc=$?
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: in-place repair impossible for PR #${pr_number}; routed fallback to issue #${linked_issue} in ${repo_slug}: ${fallback_reason}" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}

#######################################
# Return the dispatch-bound outcome identity for one bounded repair attempt.
#######################################
_ci_repair_outcome_id() {
	local session_key="$1"
	local attempt="$2"
	[[ -n "$session_key" && "$attempt" =~ ^[0-9]+$ ]] || return 1
	printf '%s-a%s' "$session_key" "$attempt"
	return 0
}

#######################################
# Write one CI repair state transition atomically.
#######################################
_ci_repair_write_state() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local worker_pid="$8"
	local pid_start="$9"
	local attempt="${10:-1}"
	local status="${11:-preparing}"
	local session_key="${12:-}"
	local tmp_file="${state_file}.tmp.$$"
	local updated_at="" started_at="" outcome_id=""
	local prior_state="" prior_attempt="" prior_started_at=""

	updated_at=$(date +%s 2>/dev/null) || updated_at=0
	started_at="$updated_at"
	if [[ -f "$state_file" ]]; then
		prior_state=$(jq -r '[.attempt // 0, .started_at // .updated_at // 0] | @tsv' "$state_file" 2>/dev/null) || prior_state=""
		IFS=$'\t' read -r prior_attempt prior_started_at <<<"$prior_state"
		if [[ "$prior_attempt" == "$attempt" && "$prior_started_at" =~ ^[0-9]+$ ]]; then
			started_at="$prior_started_at"
		fi
	fi
	outcome_id=$(_ci_repair_outcome_id "$session_key" "$attempt" 2>/dev/null) || outcome_id=""
	jq -nc \
		--arg repo "$repo_slug" --argjson pr "$pr_number" --arg head "$pr_head_sha" \
		--arg branch "$pr_head_ref" --arg fingerprint "$failure_fingerprint" \
		--arg worktree "$worktree_path" --argjson pid "$worker_pid" --arg pid_start "$pid_start" \
		--argjson attempt "$attempt" --arg status "$status" --arg session "$session_key" --arg outcome_id "$outcome_id" \
		--argjson started_at "$started_at" --argjson updated_at "$updated_at" \
		'{repo:$repo,pr:$pr,head:$head,branch:$branch,fingerprint:$fingerprint,
		worktree:$worktree,pid:$pid,pid_start:$pid_start,attempt:$attempt,status:$status,session:$session,
		outcome_id:$outcome_id,started_at:$started_at,updated_at:$updated_at,
		result:"",failure_reason:"",next_action:""}' \
		>"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	if ! mv "$tmp_file" "$state_file" 2>/dev/null; then
		rm -f "$tmp_file"
		return 1
	fi
	return 0
}

#######################################
# Return the trusted headless-runtime outcome file for one bounded attempt.
#######################################
_ci_repair_outcome_file() {
	local lease_dir="$1"
	local attempt="$2"
	printf '%s/outcome-attempt-%s.state' "$lease_dir" "$attempt"
	return 0
}

#######################################
# Read one exact key from a trusted headless-runtime outcome file.
#######################################
_ci_repair_outcome_value() {
	local outcome_file="$1"
	local expected_key="$2"
	local key="" value=""
	[[ -f "$outcome_file" && ! -L "$outcome_file" ]] || return 0
	while IFS='=' read -r key value; do
		if [[ "$key" == "$expected_key" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done <"$outcome_file"
	return 0
}

#######################################
# Bound one lifecycle value to a log/Markdown-safe token.
#######################################
_ci_repair_sanitize_outcome_value() {
	local raw_value="$1"
	local safe_value=""
	safe_value=$(printf '%s' "$raw_value" | tr -cd '[:alnum:]_.:-')
	printf '%.160s' "$safe_value"
	return 0
}

#######################################
# Project a trusted headless-runtime outcome into stable CI-repair fields.
# Output: result|failure_reason|next_action|retry_class|session_count|finished_at
#######################################
_ci_repair_project_outcome() {
	local state_file="$1"
	local outcome_file="$2"
	local status="" reason="" retry_class="" session_count="0" finished_at="0"
	local expected_outcome_id="" expected_session="" started_at="0" observed_outcome_id="" observed_session=""
	local now="0" outcome_present=0 outcome_valid=0 invalid_reason=""
	local failed_result="failed"
	local result="$failed_result" failure_reason="" next_action="inspect_terminal_outcome"

	status=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || status=""
	expected_outcome_id=$(jq -r '.outcome_id // empty' "$state_file" 2>/dev/null) || expected_outcome_id=""
	expected_session=$(jq -r '.session // empty' "$state_file" 2>/dev/null) || expected_session=""
	started_at=$(jq -r '.started_at // .updated_at // 0' "$state_file" 2>/dev/null) || started_at=0
	if [[ -f "$outcome_file" && ! -L "$outcome_file" && -O "$outcome_file" ]]; then
		outcome_present=1
		reason=$(_ci_repair_outcome_value "$outcome_file" reason)
		retry_class=$(_ci_repair_outcome_value "$outcome_file" retry_class)
		session_count=$(_ci_repair_outcome_value "$outcome_file" session_count)
		finished_at=$(_ci_repair_outcome_value "$outcome_file" finished_at)
		observed_outcome_id=$(_ci_repair_outcome_value "$outcome_file" outcome_id)
		observed_session=$(_ci_repair_outcome_value "$outcome_file" session_key)
	fi
	now=$(date +%s 2>/dev/null) || now=0
	if [[ -n "$expected_outcome_id" && "$observed_outcome_id" == "$expected_outcome_id" \
		&& -n "$expected_session" && "$observed_session" == "$expected_session" \
		&& -n "$reason" && "$session_count" =~ ^[0-9]+$ \
		&& "$started_at" =~ ^[0-9]+$ && "$finished_at" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ \
		&& "$finished_at" -ge "$started_at" && "$finished_at" -le $((now + 5)) ]]; then
		outcome_valid=1
	fi
	if [[ "$outcome_valid" -eq 1 ]]; then
		reason=$(_ci_repair_sanitize_outcome_value "$reason")
		retry_class=$(_ci_repair_sanitize_outcome_value "$retry_class")
	else
		[[ "$outcome_present" -eq 0 ]] || invalid_reason="headless_outcome_contract_mismatch"
		reason=""
		retry_class=""
		session_count=0
		finished_at=0
	fi

	if [[ -z "$reason" ]]; then
		case "$status" in
		worktree_failed)
			result="launch_failed"
			failure_reason="worktree_failed"
			next_action="retry_launch"
			;;
		preparing)
			result="launch_interrupted"
			failure_reason="headless_launch_interrupted"
			next_action="retry_launch"
			;;
		*)
			result="process_exit"
			failure_reason="${invalid_reason:-headless_outcome_missing}"
			next_action="inspect_terminal_outcome"
			;;
		esac
	else
		failure_reason="$reason"
		case "$reason" in
		worker_complete)
			result="success"
			failure_reason=""
			next_action="monitor_pr"
			;;
		worker_draft_checkpoint)
			result="deferred"
			next_action="continue_repair"
			;;
		*)
			case "$retry_class" in
			infrastructure)
				result="retryable"
				next_action="retry_infrastructure"
				;;
			maintainer_gate)
				result="blocked"
				next_action="await_maintainer"
				;;
			remediation)
				result="$failed_result"
				next_action="inspect_and_continue_repair"
				;;
			*)
				result="$failed_result"
				next_action="inspect_terminal_outcome"
				;;
			esac
			;;
		esac
	fi
	printf '%s|%s|%s|%s|%s|%s' "$result" "$failure_reason" "$next_action" \
		"$retry_class" "$session_count" "$finished_at"
	return 0
}

#######################################
# Archive one completed/dead attempt with sanitized terminal lifecycle fields.
#######################################
_ci_repair_archive_attempt() {
	local state_file="$1"
	local lease_dir="$2"
	local attempt="$3"
	local outcome_file="" archive_file="" projection="" tmp_file=""
	local result="" failure_reason="" next_action="" retry_class="" session_count="0" finished_at="0"

	[[ -f "$state_file" && "$attempt" =~ ^[0-9]+$ ]] || return 1
	outcome_file=$(_ci_repair_outcome_file "$lease_dir" "$attempt")
	archive_file="${lease_dir}/state-attempt-${attempt}.json"
	projection=$(_ci_repair_project_outcome "$state_file" "$outcome_file") || return 1
	IFS='|' read -r result failure_reason next_action retry_class session_count finished_at <<<"$projection"
	tmp_file="${state_file}.archive.tmp.$$"
	jq --arg result "$result" --arg failure_reason "$failure_reason" --arg next_action "$next_action" \
		--arg retry_class "$retry_class" --argjson session_count "$session_count" --argjson finished_at "$finished_at" \
		'. + {result:$result,failure_reason:$failure_reason,next_action:$next_action,retry_class:$retry_class,
		session_count:$session_count,finished_at:$finished_at}' "$state_file" >"$tmp_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	mv "$tmp_file" "$archive_file" 2>/dev/null || {
		rm -f "$tmp_file"
		return 1
	}
	rm -f "$state_file" "$outcome_file" 2>/dev/null || true
	return 0
}

#######################################
# Render bounded archived outcomes for durable fallback feedback.
#######################################
_ci_repair_attempt_summary() {
	local lease_dir="$1"
	local archived_state="" shown=0
	for archived_state in "${lease_dir}"/state-attempt-*.json; do
		[[ -f "$archived_state" ]] || continue
		shown=$((shown + 1))
		[[ "$shown" -le 10 ]] || break
		jq -r '"- Attempt \(.attempt // "unknown"): result=`\(.result // "unknown")`; failure_reason=`\(.failure_reason // "")`; next_action=`\(.next_action // "inspect_terminal_outcome")`"' \
			"$archived_state" 2>/dev/null || true
	done
	return 0
}

#######################################
# Return the stable process-start token used to reject reused PIDs.
#######################################
_ci_repair_process_start() {
	local worker_pid="$1"
	ps -p "$worker_pid" -o lstart= 2>/dev/null || true
	return 0
}

#######################################
# Return whether a recorded process identity is still live.
#######################################
_ci_repair_pid_is_live() {
	local worker_pid="$1"
	local expected_start="$2"
	local current_start=""

	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$expected_start" ]] || return 1
	kill -0 "$worker_pid" 2>/dev/null || return 1
	current_start=$(_ci_repair_process_start "$worker_pid")
	[[ -n "$current_start" && "$current_start" == "$expected_start" ]] || return 1
	return 0
}

#######################################
# Publish ownership for a newly acquired transition lock.
#######################################
_ci_repair_publish_lock_owner() {
	local lock_dir="$1"
	local owner_file="${lock_dir}/owner.json"
	local owner_tmp="${lock_dir}/owner.json.tmp.$$"
	local current_start=""

	current_start=$(_ci_repair_process_start "$$")
	[[ -n "$current_start" ]] || return 1
	jq -nc --argjson pid "$$" --arg pid_start "$current_start" \
		'{pid:$pid,pid_start:$pid_start}' >"$owner_tmp" 2>/dev/null || return 1
	mv "$owner_tmp" "$owner_file" 2>/dev/null || {
		rm -f "$owner_tmp"
		return 1
	}
	return 0
}

#######################################
# Return whether a claim is old enough to treat missing ownership as abandoned.
#######################################
_ci_repair_lock_is_stale() {
	local lock_dir="$1"
	local grace_seconds="${AIDEVOPS_CI_REPAIR_LOCK_GRACE_SECONDS:-2}"
	local now="" lock_mtime="" lock_age=""

	[[ "$grace_seconds" =~ ^[0-9]+$ ]] || grace_seconds=2
	now=$(date +%s 2>/dev/null) || now=0
	lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null) || lock_mtime="$now"
	[[ "$lock_mtime" =~ ^[0-9]+$ ]] || lock_mtime="$now"
	lock_age=$((now - lock_mtime))
	[[ "$lock_age" -ge "$grace_seconds" ]]
	return $?
}

#######################################
# Return whether an append-only attempt claim is still active.
#######################################
_ci_repair_claim_dir_is_active() {
	local claim_dir="$1"
	local owner_file="${claim_dir}/owner.json"
	local owner_pid="" owner_start=""

	if [[ -f "$owner_file" ]]; then
		owner_pid=$(jq -r '.pid // empty' "$owner_file" 2>/dev/null) || owner_pid=""
		owner_start=$(jq -r '.pid_start // empty' "$owner_file" 2>/dev/null) || owner_start=""
		if _ci_repair_pid_is_live "$owner_pid" "$owner_start"; then
			return 0
		fi
	fi
	_ci_repair_lock_is_stale "$claim_dir" && return 1
	return 0
}

_ci_repair_status_preparing() {
	printf 'preparing'
	return 0
}

_ci_repair_status_dispatched() {
	printf 'dispatched'
	return 0
}

_ci_repair_result_active() {
	printf 'active'
	return 0
}

_ci_repair_result_exhausted() {
	printf 'exhausted'
	return 0
}

_ci_repair_result_retryable() {
	printf 'retryable'
	return 0
}

#######################################
# Atomically claim the first unconsumed bounded repair attempt.
#######################################
_ci_repair_claim_next_attempt() {
	local lease_dir="$1"
	local first_attempt="$2"
	local max_attempts="$3"
	local attempt="$first_attempt"
	local claim_dir="" active_result="" exhausted_result=""

	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	while [[ "$attempt" -le "$max_attempts" ]]; do
		claim_dir="${lease_dir}/attempt-${attempt}.claim"
		if mkdir "$claim_dir" 2>/dev/null; then
			_ci_repair_publish_lock_owner "$claim_dir" || return 1
			printf '%s' "$attempt"
			return 0
		fi
		if _ci_repair_claim_dir_is_active "$claim_dir"; then
			printf '%s' "$active_result"
			return 0
		fi
		attempt=$((attempt + 1))
	done
	printf '%s' "$exhausted_result"
	return 0
}

#######################################
# Return the latest archived attempt and its preserved worktree.
#######################################
_ci_repair_latest_archive() {
	local lease_dir="$1"
	local archived_state=""
	local archived_attempt="0"
	local candidate_attempt="0"
	local worktree_path=""

	for archived_state in "${lease_dir}"/state-attempt-*.json; do
		[[ -f "$archived_state" ]] || continue
		candidate_attempt=$(jq -r '.attempt // 0' "$archived_state" 2>/dev/null) || candidate_attempt="0"
		[[ "$candidate_attempt" =~ ^[0-9]+$ ]] || candidate_attempt=0
		if [[ "$candidate_attempt" -ge "$archived_attempt" ]]; then
			archived_attempt="$candidate_attempt"
			worktree_path=$(jq -r '.worktree // empty' "$archived_state" 2>/dev/null) || worktree_path=""
		fi
	done
	printf '%s|%s' "$archived_attempt" "$worktree_path"
	return 0
}

#######################################
# Publish dispatcher ownership for one attempt while the transition lock is held.
#######################################
_ci_repair_prepare_attempt() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local attempt="$8"
	local session_key="$9"
	local process_start=""
	local preparing_status=""

	process_start=$(_ci_repair_process_start "$$")
	preparing_status=$(_ci_repair_status_preparing)
	_ci_repair_write_state "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$$" "$process_start" "$attempt" "$preparing_status" "$session_key"
	return $?
}

#######################################
# Adopt a live native headless session after an interrupted dispatcher handoff.
#######################################
_ci_repair_adopt_live_session() {
	local state_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local worktree_path="$7"
	local attempt="$8"
	local session_key="$9"
	local session_identity=""
	local worker_pid=""
	local process_start=""
	local dispatched_status=""

	session_identity=$(_ci_repair_session_identity "$session_key" 2>/dev/null) || return 1
	worker_pid="${session_identity%%|*}"
	process_start="${session_identity#*|}"
	dispatched_status=$(_ci_repair_status_dispatched)
	_ci_repair_write_state "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$worker_pid" "$process_start" "$attempt" "$dispatched_status" "$session_key" || return 1
	echo "[pulse-wrapper] _dispatch_ci_repair_session: adopted live native session ${session_key} after interrupted lease handoff (pid ${worker_pid})" >>"$LOGFILE"
	return 0
}

#######################################
# Claim or recover the durable lease for one CI repair tuple.
#
# Output: "launch|ATTEMPT|WORKTREE", "active", or "exhausted".
#######################################
_ci_repair_claim_lease() {
	local lease_dir="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local pr_head_sha="$4"
	local failure_fingerprint="$5"
	local max_attempts="$6"
	local pr_head_ref="$7"
	local session_key="$8"
	local state_file="${lease_dir}/state.json"
	local existing_pid="" existing_pid_start="" existing_attempt="1"
	local existing_worktree="" next_attempt="" archive_payload="" archived_attempt="0" claim_result=""
	local existing_status="" updated_at="0" now="0" launch_grace="${AIDEVOPS_CI_REPAIR_LAUNCH_GRACE_SECONDS:-}"
	local canary_timeout="${CANARY_TIMEOUT_SECONDS:-180}"
	local active_result="" exhausted_result=""

	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	[[ "$max_attempts" =~ ^[0-9]+$ ]] || max_attempts=2
	[[ "$max_attempts" -gt 0 ]] || max_attempts=2
	[[ "$canary_timeout" =~ ^[0-9]+$ ]] || canary_timeout=180
	[[ "$launch_grace" =~ ^[0-9]+$ ]] || launch_grace=$((canary_timeout + 60))
	[[ -d "$lease_dir" ]] || return 1

	if [[ ! -f "$state_file" ]]; then
		archive_payload=$(_ci_repair_latest_archive "$lease_dir")
		archived_attempt="${archive_payload%%|*}"
		existing_worktree="${archive_payload#*|}"
		next_attempt=$((archived_attempt + 1))
		if _ci_repair_adopt_live_session "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key"; then
			printf '%s' "$active_result"
			return 0
		fi
		claim_result=$(_ci_repair_claim_next_attempt "$lease_dir" "$next_attempt" "$max_attempts") || return 1
		case "$claim_result" in
		"$active_result" | "$exhausted_result")
			printf '%s' "$claim_result"
			return 0
			;;
		*) [[ "$claim_result" =~ ^[0-9]+$ ]] || return 1 ;;
		esac
		next_attempt="$claim_result"
		_ci_repair_prepare_attempt "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key" || return 1
		echo "[pulse-wrapper] _dispatch_ci_repair_session: recovered incomplete lease state for ${repo_slug} PR #${pr_number} as attempt ${next_attempt}/${max_attempts}" >>"$LOGFILE"
		printf 'launch|%s|%s' "$next_attempt" "$existing_worktree"
		return 0
	fi
	existing_pid=$(jq -r '.pid // empty' "$state_file" 2>/dev/null) || existing_pid=""
	existing_pid_start=$(jq -r '.pid_start // empty' "$state_file" 2>/dev/null) || existing_pid_start=""
	existing_attempt=$(jq -r '.attempt // 1' "$state_file" 2>/dev/null) || existing_attempt="1"
	existing_status=$(jq -r '.status // empty' "$state_file" 2>/dev/null) || existing_status=""
	updated_at=$(jq -r '.updated_at // 0' "$state_file" 2>/dev/null) || updated_at="0"
	[[ "$existing_attempt" =~ ^[0-9]+$ ]] || existing_attempt=1
	[[ "$updated_at" =~ ^[0-9]+$ ]] || updated_at=0
	if _ci_repair_pid_is_live "$existing_pid" "$existing_pid_start"; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: repair already active for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} (pid ${existing_pid}, attempt ${existing_attempt})" >>"$LOGFILE"
		printf '%s' "$active_result"
		return 0
	fi
	existing_worktree=$(jq -r '.worktree // empty' "$state_file" 2>/dev/null) || existing_worktree=""
	if _ci_repair_adopt_live_session "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$existing_worktree" "$existing_attempt" "$session_key"; then
		printf '%s' "$active_result"
		return 0
	fi
	now=$(date +%s 2>/dev/null) || now=0
	if [[ "$existing_status" == "$(_ci_repair_status_preparing)" && $((now - updated_at)) -lt "$launch_grace" ]]; then
		printf '%s' "$active_result"
		return 0
	fi
	next_attempt=$((existing_attempt + 1))
	claim_result=$(_ci_repair_claim_next_attempt "$lease_dir" "$next_attempt" "$max_attempts") || return 1
	if [[ "$claim_result" == "$active_result" ]]; then
		printf '%s' "$active_result"
		return 0
	fi
	if [[ "$claim_result" == "$exhausted_result" ]]; then
		if ! _ci_repair_archive_attempt "$state_file" "$lease_dir" "$existing_attempt"; then
			printf '%s' "$active_result"
			return 0
		fi
		echo "[pulse-wrapper] _dispatch_ci_repair_session: stale repair exhausted ${max_attempts} attempts for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint}" >>"$LOGFILE"
		printf '%s' "$exhausted_result"
		return 0
	fi
	[[ "$claim_result" =~ ^[0-9]+$ ]] || return 1
	next_attempt="$claim_result"
	if ! _ci_repair_archive_attempt "$state_file" "$lease_dir" "$existing_attempt"; then
		printf '%s' "$active_result"
		return 0
	fi
	_ci_repair_prepare_attempt "$state_file" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$existing_worktree" "$next_attempt" "$session_key" || return 1
	echo "[pulse-wrapper] _dispatch_ci_repair_session: recovering stale repair for ${repo_slug} PR #${pr_number} head ${pr_head_sha} fingerprint ${failure_fingerprint} as attempt ${next_attempt}/${max_attempts}" >>"$LOGFILE"
	printf 'launch|%s|%s' "$next_attempt" "$existing_worktree"
	return 0
}

#######################################
# Create a linked repair worktree at the exact PR head SHA.
#
# Output: absolute worktree path.
#######################################
_ci_repair_create_worktree() {
	local repo_path="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_number="$4"
	local pr_head_sha="$5"
	local pr_head_ref="$6"
	local failure_fingerprint="$7"
	local attempt="$8"
	local worktree_helper="${AIDEVOPS_WORKTREE_HELPER:-${_PULSE_MERGE_DIR:-${BASH_SOURCE[0]%/*}}/worktree-helper.sh}"
	local worktree_base="${AIDEVOPS_CI_REPAIR_WORKTREE_BASE_DIR:-${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME}/Git/_worktrees}}"
	local repo_name=""
	local repo_hash=""
	local repair_branch=""
	local worktree_path=""
	local actual_head=""

	[[ -x "$worktree_helper" ]] || return 1
	[[ "$pr_head_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 1
	[[ -n "$pr_head_ref" ]] || return 1
	if ! git -C "$repo_path" cat-file -e "${pr_head_sha}^{commit}" 2>/dev/null; then
		git -C "$repo_path" fetch --no-tags --quiet origin "$pr_head_ref" >/dev/null 2>&1 || return 1
	fi
	git -C "$repo_path" cat-file -e "${pr_head_sha}^{commit}" 2>/dev/null || return 1

	repo_name=$(basename "$repo_path")
	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	repair_branch="repair/${repo_hash}-pr-${pr_number}-${pr_head_sha:0:12}-${failure_fingerprint:0:12}-a${attempt}"
	worktree_path="${worktree_base}/${repo_name}-${repo_hash}-ci-repair-pr${pr_number}-${pr_head_sha:0:12}-${failure_fingerprint:0:12}-a${attempt}"
	mkdir -p "$worktree_base" 2>/dev/null || return 1
	if ! (cd "$repo_path" && AIDEVOPS_SKIP_AUTO_CLAIM=1 AIDEVOPS_WORKTREE_BASE_DIR="$worktree_base" "$worktree_helper" add "$repair_branch" "$worktree_path" \
		--base "$pr_head_sha" --issue "$linked_issue") >>"$LOGFILE" 2>&1; then
		return 1
	fi
	actual_head=$(git -C "$worktree_path" rev-parse HEAD 2>/dev/null) || actual_head=""
	if [[ "$actual_head" != "$pr_head_sha" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: repair worktree head mismatch for PR #${pr_number}: expected ${pr_head_sha}, got ${actual_head:-unknown}" >>"$LOGFILE"
		(cd "$repo_path" && "$worktree_helper" remove "$worktree_path" --force) >>"$LOGFILE" 2>&1 || true
		return 1
	fi
	printf '%s' "$worktree_path"
	return 0
}

#######################################
# Return a live headless runtime session lock as PID|process-start.
#######################################
_ci_repair_session_identity() {
	local session_key="$1"
	local state_dir="${AIDEVOPS_HEADLESS_RUNTIME_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	local safe_key=""
	local lock_file=""
	local lock_value=""
	local worker_pid=""
	local stored_hash=""
	local process_start=""
	local process_pattern="${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}|headless-runtime-helper"

	safe_key=$(printf '%s' "$session_key" | tr '/ ' '__')
	lock_file="${state_dir}/locks/${safe_key}.pid"
	[[ -f "$lock_file" ]] || return 1
	lock_value=$(sed -n '1p' "$lock_file" 2>/dev/null) || lock_value=""
	worker_pid="${lock_value%%|*}"
	stored_hash="${lock_value#*|}"
	[[ "$stored_hash" == "$worker_pid" ]] && stored_hash=""
	[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
	declare -F _is_process_alive_and_matches >/dev/null 2>&1 || return 1
	_is_process_alive_and_matches "$worker_pid" "$process_pattern" "$stored_hash" || return 1
	process_start=$(_ci_repair_process_start "$worker_pid")
	[[ -n "$process_start" ]] || return 1
	printf '%s|%s' "$worker_pid" "$process_start"
	return 0
}

#######################################
# Resolve CI repair identity from the active gh credential context.
# Caller-provided environment identity is never accepted as authority.
#######################################
_ci_repair_resolve_runner_login() {
	local runner_login=""

	# #aidevops:trust-boundary — bind worker ownership to authenticated GitHub
	# identity rather than a mutable environment variable.
	runner_login=$(gh api user --jq '.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	runner_login=$(_pmf_gh_read gh api graphql \
		-f 'query=query { viewer { login } }' \
		--jq '.data.viewer.login // ""' 2>/dev/null || true)
	if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	return 1
}

#######################################
# Launch through the runtime's native detach path and publish its process identity.
#######################################
_ci_repair_launch_worker() {
	local lease_dir="$1"
	local helper="$2"
	local repo_slug="$3"
	local pr_number="$4"
	local linked_issue="$5"
	local pr_head_sha="$6"
	local pr_head_ref="$7"
	local failure_fingerprint="$8"
	local worktree_path="$9"
	local attempt="${10:-1}"
	local session_key="${11:-}"
	local prompt_file="${12:-}"
	local launch_output=""
	local worker_pid=""
	local process_start=""
	local session_identity=""
	local dispatched_status=""
	local runner_login=""
	local wait_count=0
	local wait_max="${AIDEVOPS_CI_REPAIR_SESSION_LOCK_WAIT_STEPS:-200}"
	local process_pattern="${WORKER_PROCESS_PATTERN:-opencode|claude|Claude}|headless-runtime-helper"
	local outcome_file="" outcome_id=""

	[[ "$wait_max" =~ ^[0-9]+$ ]] || wait_max=200
	outcome_file=$(_ci_repair_outcome_file "$lease_dir" "$attempt")
	outcome_id=$(_ci_repair_outcome_id "$session_key" "$attempt") || return 1
	rm -f "$outcome_file" 2>/dev/null || true
	runner_login=$(_ci_repair_resolve_runner_login) || {
		printf '%s\n' "[pulse-wrapper] _ci_repair_launch_worker: authenticated GitHub runner identity unavailable for ${repo_slug} PR #${pr_number}; launch blocked" >>"$LOGFILE"
		return 1
	}
	launch_output=$(env \
		HEADLESS=1 WORKER_ISSUE_NUMBER="$linked_issue" WORKER_REPO_SLUG="$repo_slug" \
		WORKER_WORKTREE_PATH="$worktree_path" GITHUB_REPOSITORY="$repo_slug" \
		WORKER_NO_EXIT_PUSH=1 WORKER_PROCESS_PATTERN="$process_pattern" AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER=1 \
		WORKER_GITHUB_LOGIN="$runner_login" \
		AIDEVOPS_PR_REPAIR_NUMBER="$pr_number" AIDEVOPS_PR_REPAIR_HEAD_SHA="$pr_head_sha" \
		AIDEVOPS_PR_REPAIR_HEAD_REF="$pr_head_ref" AIDEVOPS_PR_REPAIR_FINGERPRINT="$failure_fingerprint" \
		AIDEVOPS_PR_REPAIR_OWNERSHIP_MODE="linked-issue" \
		AIDEVOPS_HEADLESS_OUTCOME_FILE="$outcome_file" AIDEVOPS_HEADLESS_OUTCOME_ID="$outcome_id" \
		"$helper" run --role worker --session-key "$session_key" --dir "$worktree_path" \
		--title "PR #${pr_number}: CI repair" --prompt-file "$prompt_file" --detach \
		</dev/null 2>&1) || {
		printf '%s\n' "$launch_output" >>"$LOGFILE"
		return 1
	}
	printf '%s\n' "$launch_output" >>"$LOGFILE"
	worker_pid=$(printf '%s\n' "$launch_output" | sed -n 's/.*Dispatched PID: \([0-9][0-9]*\).*/\1/p' | sed -n '$p')
	while [[ "$wait_count" -lt "$wait_max" ]]; do
		session_identity=$(_ci_repair_session_identity "$session_key" 2>/dev/null) || session_identity=""
		[[ -n "$session_identity" ]] && break
		sleep 0.05
		wait_count=$((wait_count + 1))
	done
	if [[ -n "$session_identity" ]]; then
		worker_pid="${session_identity%%|*}"
		process_start="${session_identity#*|}"
	else
		[[ "$worker_pid" =~ ^[0-9]+$ ]] || return 1
		process_start=$(_ci_repair_process_start "$worker_pid")
		_ci_repair_pid_is_live "$worker_pid" "$process_start" || return 1
	fi
	dispatched_status=$(_ci_repair_status_dispatched)
	if ! _ci_repair_write_state "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$worker_pid" "$process_start" "$attempt" "$dispatched_status" "$session_key"; then
		return 1
	fi
	return 0
}

#######################################
# Write the bounded repair prompt for the existing PR branch.
#######################################
_ci_repair_write_prompt() {
	local prompt_file="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local linked_issue="$4"
	local pr_head_sha="$5"
	local pr_head_ref="$6"
	local failure_fingerprint="$7"
	local failing_checks="$8"

	cat >"$prompt_file" <<-EOF
		[effort:thinking] Repair terminal CI failures on the existing PR branch.

		Repository: ${repo_slug}
		PR: #${pr_number}
		Linked issue: #${linked_issue}
		Expected head SHA: ${pr_head_sha}
		Existing head branch: ${pr_head_ref}
		Failure fingerprint: ${failure_fingerprint}

		Terminal failed checks:
		${failing_checks}

		Your linked worktree was created from the expected PR head SHA and may contain preserved
		changes from an interrupted repair attempt. Inspect and continue valuable existing work.
		Verify PR #${pr_number} still has remote head SHA ${pr_head_sha} before editing; if it
		changed, stop without pushing. Diagnose the cited logs, make only the CI repair, run focused
		checks, commit, and push HEAD back to remote branch ${pr_head_ref}. Do not open or close a
		PR, create another implementation branch, merge, or bypass trust or required checks.
	EOF
	return 0
}

#######################################
# Return whether a legacy fingerprint-scoped lease still owns a live worker.
#######################################
_ci_repair_legacy_lease_is_active() {
	local legacy_dir="$1"
	local expected_repo="$2"
	local expected_pr="$3"
	local expected_head="$4"
	local state_file="${legacy_dir}/state.json"
	local state_identity="" state_repo="" state_pr="" state_head="" state_fingerprint="" state_status=""
	local legacy_session_key="" legacy_session_identity=""

	[[ -f "$state_file" ]] || return 1
	state_identity=$(jq -r '[.repo // "", (.pr // "" | tostring), .head // "", .fingerprint // "", .status // ""] | @tsv' "$state_file" 2>/dev/null) || return 1
	IFS=$'\t' read -r state_repo state_pr state_head state_fingerprint state_status <<<"$state_identity"
	[[ "$state_repo" == "$expected_repo" && "$state_pr" == "$expected_pr" && "$state_head" == "$expected_head" ]] || return 1
	[[ "$state_status" == "$(_ci_repair_status_dispatched)" && -n "$state_fingerprint" ]] || return 1
	legacy_session_key="ci-repair-${expected_pr}-${expected_head:0:12}-${state_fingerprint:0:12}"
	legacy_session_identity=$(_ci_repair_session_identity "$legacy_session_key" 2>/dev/null) || return 1
	[[ -n "$legacy_session_identity" ]]
	return $?
}

_ci_repair_hash_text() {
	local input_text="$1"
	local content_hash=""

	if command -v sha256sum >/dev/null 2>&1; then
		content_hash=$(printf '%s' "$input_text" | sha256sum 2>/dev/null | cut -d ' ' -f 1) || return 1
	elif command -v shasum >/dev/null 2>&1; then
		content_hash=$(printf '%s' "$input_text" | shasum -a 256 2>/dev/null | cut -d ' ' -f 1) || return 1
	else
		return 1
	fi
	[[ "$content_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s' "$content_hash"
	return 0
}

_ci_repair_session_key() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_head_sha="$3"
	local repo_hash=""

	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	printf 'ci-repair-%s-%s-%s' "$repo_hash" "$pr_number" "${pr_head_sha:0:12}"
	return 0
}

#######################################
# Launch one bounded repair session for a repository/PR/head tuple.
# The state directory is the cross-pulse dedup lease. A dead worker may be
# retried once; repeated terminal attempts take the durable fallback.
#######################################
_dispatch_ci_repair_session() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_head_sha="$4"
	local pr_head_ref="$5"
	local failure_fingerprint="$6"
	local failing_checks="$7"
	local repo_path="" helper="" state_root="" state_key="" legacy_state_key="" lease_dir="" prompt_file="" session_key="" legacy_dir="" repo_hash=""
	local lease_action=""
	local max_attempts="${AIDEVOPS_CI_REPAIR_MAX_ATTEMPTS:-2}"
	local attempt=""
	local worktree_path=""
	local launch_payload=""
	local active_result=""
	local exhausted_result=""
	local retryable_result=""
	local dispatched_status=""
	active_result=$(_ci_repair_result_active)
	exhausted_result=$(_ci_repair_result_exhausted)
	retryable_result=$(_ci_repair_result_retryable)
	dispatched_status=$(_ci_repair_status_dispatched)
	_CI_REPAIR_DISPATCH_RESULT="$retryable_result"

	repo_path=$(_pulse_merge_repo_path_for_slug "$repo_slug" 2>/dev/null) || repo_path=""
	helper="${AIDEVOPS_HEADLESS_RUNTIME_HELPER:-${_PULSE_MERGE_DIR:-${BASH_SOURCE[0]%/*}}/headless-runtime-helper.sh}"
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 1
	[[ -x "$helper" ]] || return 1

	state_root="${AIDEVOPS_CI_REPAIR_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/ci-pr-repair}"
	repo_hash=$(_ci_repair_hash_text "$repo_slug") || return 1
	state_key="${repo_hash}-${pr_number}-${pr_head_sha}"
	legacy_state_key=$(printf '%s-%s-%s' "$repo_slug" "$pr_number" "$pr_head_sha" | tr '/:' '__')
	lease_dir="${state_root}/${state_key}"
	for legacy_dir in "${state_root}/${legacy_state_key}-"*; do
		[[ -d "$legacy_dir" ]] || continue
		if _ci_repair_legacy_lease_is_active "$legacy_dir" "$repo_slug" "$pr_number" "$pr_head_sha"; then
			echo "[pulse-wrapper] _dispatch_ci_repair_session: legacy repair lease remains active for ${repo_slug} PR #${pr_number} head ${pr_head_sha}" >>"$LOGFILE"
			_CI_REPAIR_DISPATCH_RESULT="$active_result"
			return 0
		fi
	done
	session_key=$(_ci_repair_session_key "$repo_slug" "$pr_number" "$pr_head_sha")
	mkdir -p "$lease_dir" 2>/dev/null || return 1
	lease_action=$(_ci_repair_claim_lease "$lease_dir" "$repo_slug" "$pr_number" "$pr_head_sha" \
		"$failure_fingerprint" "$max_attempts" "$pr_head_ref" "$session_key") || return 1
	case "$lease_action" in
	"$active_result")
		_CI_REPAIR_DISPATCH_RESULT="$active_result"
		return 0
		;;
	"$exhausted_result")
		_CI_REPAIR_OUTCOME_SUMMARY=$(_ci_repair_attempt_summary "$lease_dir")
		_CI_REPAIR_DISPATCH_RESULT="$exhausted_result"
		return 1
		;;
	launch\|*)
		launch_payload="${lease_action#launch|}"
		attempt="${launch_payload%%|*}"
		worktree_path="${launch_payload#*|}"
		if [[ ! "$attempt" =~ ^[0-9]+$ ]]; then
			return 1
		fi
		;;
	*)
		return 1
		;;
	esac

	if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_repair_session: resuming stale repair worktree ${worktree_path} for ${repo_slug} PR #${pr_number} attempt ${attempt}/${max_attempts}" >>"$LOGFILE"
	else
		worktree_path=$(_ci_repair_create_worktree "$repo_path" "$repo_slug" "$linked_issue" "$pr_number" "$pr_head_sha" \
			"$pr_head_ref" "$failure_fingerprint" "$attempt") || worktree_path=""
	fi
	if [[ -z "$worktree_path" || ! -d "$worktree_path" ]]; then
		_ci_repair_write_state "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
			"$failure_fingerprint" "" "0" "" "$attempt" "worktree_failed" "$session_key" || true
		return 1
	fi
	_ci_repair_prepare_attempt "${lease_dir}/state.json" "$repo_slug" "$pr_number" "$pr_head_sha" "$pr_head_ref" \
		"$failure_fingerprint" "$worktree_path" "$attempt" "$session_key" || return 1

	prompt_file="${lease_dir}/prompt.md"
	_ci_repair_write_prompt "$prompt_file" "$repo_slug" "$pr_number" "$linked_issue" "$pr_head_sha" \
		"$pr_head_ref" "$failure_fingerprint" "$failing_checks" || return 1
	if ! _ci_repair_launch_worker "$lease_dir" "$helper" "$repo_slug" "$pr_number" "$linked_issue" \
		"$pr_head_sha" "$pr_head_ref" "$failure_fingerprint" "$worktree_path" "$attempt" "$session_key" "$prompt_file"; then
		return 1
	fi
	_CI_REPAIR_DISPATCH_RESULT="$dispatched_status"
	return 0
}

#######################################
# Build a whole-token lookup set for add/add conflict paths (t3199).
#
# Args:
#   $1 - (optional) path to a git repo with an in-flight rebase/merge.
#
# Output: space-padded path set suitable for `[[ "$set" == *" $path "* ]]`.
#######################################
_conflict_add_add_path_set() {
	local repo_path="${1:-}"
	local add_add_files=""

	if [[ -n "$repo_path" ]] && [[ -d "$repo_path/.git" || -f "$repo_path/.git" ]]; then
		add_add_files=$(git -C "$repo_path" status --porcelain 2>/dev/null \
			| awk '/^AA / {print $2}' | tr '\n' ' ')
		add_add_files="${add_add_files% }"
	fi

	if [[ -n "$add_add_files" ]]; then
		printf ' %s ' "$add_add_files"
	else
		printf ' '
	fi
	return 0
}

#######################################
# Check whether a path is present in a space-padded lookup set.
#
# Args:
#   $1 - file path
#   $2 - space-padded lookup set
#######################################
_conflict_path_in_set() {
	local fpath="$1"
	local lookup_set="$2"

	[[ "$lookup_set" == *" ${fpath} "* ]] || return 1
	return 0
}

#######################################
# Match one conflicting path against the conflict pattern registry.
#
# Args:
#   $1 - file path
#   $2 - conflict-patterns.conf path
#
# Output: matching classification, or CODE.
#######################################
_conflict_registry_class_for_path() {
	local fpath="$1"
	local conf_file="$2"
	local fname
	fname="${fpath##*/}"
	local matched_class=""

	while IFS='|' read -r class_raw glob_raw _rest; do
		local class="" glob=""
		class="${class_raw#"${class_raw%%[![:space:]]*}"}"
		class="${class%"${class##*[![:space:]]}"}"
		glob="${glob_raw#"${glob_raw%%[![:space:]]*}"}"
		glob="${glob%"${glob##*[![:space:]]}"}"

		[[ -n "$class" && -n "$glob" ]] || continue
		[[ "$class" == \#* ]] && continue
		[[ "$class" == "ADD_ADD_NEW_FILE" ]] && continue

		local did_match=0
		# shellcheck disable=SC2254  # dynamic glob is intentional
		case "$fpath" in
			$glob) did_match=1 ;;
		esac
		if [[ $did_match -eq 0 ]]; then
			# shellcheck disable=SC2254  # dynamic glob is intentional
			case "$fname" in
				$glob) did_match=1 ;;
			esac
		fi

		if [[ $did_match -eq 1 ]]; then
			matched_class="$class"
			break
		fi
	done < <(grep -v '^[[:space:]]*#' "$conf_file" | grep -v '^[[:space:]]*$')

	printf '%s\n' "${matched_class:-CODE}"
	return 0
}

#######################################
# Group `CLASS:path` rows into conflict-pattern output lines.
#
# Args:
#   $1 - classified rows, one `CLASS:path` entry per line
#
# Output: multi-line classification string.
#######################################
_emit_grouped_conflict_classifications() {
	local classified_lines="$1"
	local all_classes="ADD_ADD_NEW_FILE DRIZZLE_MIGRATION LOCKFILE I18N_JSON GENERATED CODE"
	local class

	for class in $all_classes; do
		local paths_for_class=""
		while IFS= read -r entry; do
			[[ "$entry" == "${class}:"* ]] || continue
			local p="${entry#*:}"
			paths_for_class="${paths_for_class}${p} "
		done < <(printf '%s\n' "$classified_lines")
		paths_for_class="${paths_for_class% }"
		if [[ -n "$paths_for_class" ]]; then
			printf '%s %s\n' "$class" "$paths_for_class"
		fi
	done
	return 0
}

#######################################
# Classify a list of conflicting file paths against the conflict-patterns.conf
# registry and return a multi-line classification string (t2987).
#
# Each output line has the form:
#   CLASSIFICATION path/to/file1 path/to/file2 ...
#
# Patterns are matched in conf order. CODE is the catch-all fallback.
# Files that match a non-CODE pattern are collected per-classification.
# Unmatched files fall through to the CODE bucket.
#
# add/add detection (t3199): when a repo_path is supplied AND it contains
# an in-progress rebase/merge with `AA` rows in `git status --porcelain`,
# those files are pre-classified as ADD_ADD_NEW_FILE — independent of
# filename glob. add/add conflicts can occur on any path, so glob matching
# is not a reliable signal. The pulse caller (`_dispatch_conflict_fix_worker`)
# does not have a local checkout and passes no repo_path, so its existing
# classification path is preserved. Worker / test contexts that DO have a
# checkout pass repo_path to enable the structural detection.
#
# Args:
#   $1 - newline-separated list of conflicting file paths
#   $2 - (optional) path to conflict-patterns.conf; defaults to the conf
#        in the same directory as this script's parent configs/ dir.
#   $3 - (optional, t3199) path to a git repo with an in-flight rebase/merge.
#        When set and valid, files marked `AA` by `git status --porcelain`
#        are classified as ADD_ADD_NEW_FILE before glob matching.
#
# Output: multi-line classification on stdout (empty if no files given).
#######################################
_classify_conflicts_by_pattern() {
	local file_list="$1"
	local conf_file="${2:-}"
	local repo_path="${3:-}"

	# Locate conf file relative to this script if not supplied.
	if [[ -z "$conf_file" ]]; then
		local script_dir
		script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
		conf_file="${script_dir}/../configs/conflict-patterns.conf"
	fi

	[[ -n "$file_list" ]] || return 0
	[[ -f "$conf_file" ]] || {
		# Fallback: classify everything as CODE if conf is missing.
		printf 'CODE %s\n' "$file_list"
		return 0
	}

	local add_add_set
	add_add_set="$(_conflict_add_add_path_set "$repo_path")"

	local classified_lines=""
	local class

	while IFS= read -r fpath; do
		[[ -n "$fpath" ]] || continue

		if _conflict_path_in_set "$fpath" "$add_add_set"; then
			class="ADD_ADD_NEW_FILE"
		else
			class="$(_conflict_registry_class_for_path "$fpath" "$conf_file")"
		fi
		classified_lines="${classified_lines}${class}:${fpath}"$'\n'
	done < <(printf '%s\n' "$file_list")

	_emit_grouped_conflict_classifications "$classified_lines"
	return 0
}

#######################################
# Emit markdown guidance blocks for each non-CODE conflict pattern (t2987).
#
# Called by _build_conflict_feedback_section after classification to append
# a ### Pattern-Specific Resolution Guidance subsection per detected class.
#
# Args:
#   $1 - classification_output  (multi-line: "CLASS file1 file2 ...")
#   $2 - default_branch         (e.g. "main", "develop")
#   $3 - conf_file              (path to conflict-patterns.conf)
#
# Output: markdown guidance blocks on stdout (nothing if all CODE or empty).
#######################################
_emit_pattern_guidance_blocks() {
	local classification_output="$1"
	local default_branch="$2"
	local conf_file="$3"

	[[ -n "$classification_output" ]] || return 0

	# Check if any non-CODE class is present.
	local has_non_code=0
	while IFS= read -r cls_line; do
		[[ "$cls_line" == CODE\ * ]] || has_non_code=1
	done < <(printf '%s\n' "$classification_output")
	[[ $has_non_code -eq 1 ]] || return 0

	printf '\n### Pattern-Specific Resolution Guidance\n\n'
	printf 'The conflicting files match known patterns with deterministic resolution paths.\n'
	printf 'Follow the per-pattern guidance below before falling back to the generic\n'
	printf 'cherry-pick instructions in the Worker guidance section above.\n\n'

	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		local class="${cls_line%% *}"
		local files="${cls_line#* }"
		[[ "$class" == "CODE" ]] && continue

		# Look up first matching guidance record in conf for this class.
		local resolution_cmd="" guidance=""
		if [[ -f "$conf_file" ]]; then
			while IFS='|' read -r cr _gr rr guide_raw; do
				# Trim whitespace.
				local cn="${cr#"${cr%%[![:space:]]*}"}"
				cn="${cn%"${cn##*[![:space:]]}"}"
				[[ "$cn" == "$class" ]] || continue
				rr="${rr#"${rr%%[![:space:]]*}"}"; rr="${rr%"${rr##*[![:space:]]}"}"
				guide_raw="${guide_raw#"${guide_raw%%[![:space:]]*}"}"
				guide_raw="${guide_raw%"${guide_raw##*[![:space:]]}"}"
				resolution_cmd="$rr"; guidance="$guide_raw"
				break
			done < <(grep -v '^[[:space:]]*#' "$conf_file" \
				| grep -v '^[[:space:]]*$')
		fi

		printf '#### Pattern: %s\n\n' "$class"
		# shellcheck disable=SC2016  # backticks are literal markdown, not expansion
		printf 'Affected files: `%s`\n\n' "${files// /, }"
		if [[ -n "$guidance" ]]; then
			local expanded="${guidance//\{default_branch\}/${default_branch}}"
			expanded="${expanded//\\n/$'\n'}"
			printf '%s\n\n' "$expanded"
		fi
		if [[ -n "$resolution_cmd" ]]; then
			local rcmd="${resolution_cmd//\{default_branch\}/${default_branch}}"
			# shellcheck disable=SC2016  # backticks are literal markdown, not expansion
			printf 'Quick resolution command: `%s`\n\n' "$rcmd"
		fi
	done < <(printf '%s\n' "$classification_output")
	return 0
}

#######################################
# Classify a list of failing CI check names against ci-failure-patterns.conf
# (t3225). Mirror of _classify_conflicts_by_pattern but operates on check
# names (newline-separated) instead of file paths.
#
# Each output line has the form:
#   CLASSIFICATION name1|name2|...
# (note: separator inside the names list is `|` not space, because check
# names commonly contain spaces e.g. "ShellCheck (ubuntu-latest)").
#
# Patterns are matched in conf order. OTHER is the catch-all fallback.
# Names that match a non-OTHER pattern are collected per-classification.
# Unmatched names fall through to the OTHER bucket.
#
# Args:
#   $1 - newline-separated list of failing CI check names
#   $2 - (optional) path to ci-failure-patterns.conf; defaults to
#        configs/ci-failure-patterns.conf relative to this script.
#
# Output: multi-line classification on stdout (empty if no names given).
#######################################
_classify_ci_failures_by_pattern() {
	local name_list="$1"
	local conf_file="${2:-}"

	if [[ -z "$conf_file" ]]; then
		# Resolve via dirname (no symlink resolution needed for -f / read).
		conf_file="${BASH_SOURCE[0]%/*}/../configs/ci-failure-patterns.conf"
	fi

	[[ -n "$name_list" ]] || return 0
	[[ -f "$conf_file" ]] || {
		printf 'OTHER %s\n' "${name_list//$'\n'/|}"
		return 0
	}

	local classified_lines=
	while IFS= read -r cname; do
		[[ -n "$cname" ]] || continue

		local matched_class=
		while IFS='|' read -r class_raw glob_raw _rest; do
			# Both vars initialised to empty for set -u safety (t2863).
			local class='' glob=''
			class="${class_raw#"${class_raw%%[![:space:]]*}"}"
			class="${class%"${class##*[![:space:]]}"}"
			glob="${glob_raw#"${glob_raw%%[![:space:]]*}"}"
			glob="${glob%"${glob##*[![:space:]]}"}"

			[[ -n "$class" && -n "$glob" ]] || continue
			[[ "$class" == \#* ]] && continue

			# shellcheck disable=SC2254  # dynamic glob is intentional
			case "$cname" in
				$glob)
					matched_class="$class"
					break
					;;
			esac
		done < <(grep -v '^[[:space:]]*#' "$conf_file" | grep -v '^[[:space:]]*$')

		[[ -n "$matched_class" ]] || matched_class="OTHER"
		classified_lines="${classified_lines}${matched_class}::${cname}"$'\n'
	done < <(printf '%s\n' "$name_list")

	# Group by classification, preserving conf-file priority order.
	local all_classes="FORMAT_FAILURE LINT_FAILURE EXTERNAL_STATIC_ANALYSIS TYPECHECK_FAILURE TEST_FAILURE TIMEOUT_NO_OUTPUT OTHER"
	for class in $all_classes; do
		local names_for_class=
		while IFS= read -r entry; do
			[[ "$entry" == "${class}::"* ]] || continue
			local n="${entry#*::}"
			if [[ -z "$names_for_class" ]]; then
				names_for_class="$n"
			else
				names_for_class="${names_for_class}|${n}"
			fi
		done < <(printf '%s\n' "$classified_lines")
		if [[ -n "$names_for_class" ]]; then
			printf '%s %s\n' "$class" "$names_for_class"
		fi
	done
	return 0
}

#######################################
# Emit markdown guidance blocks for each non-OTHER CI failure pattern (t3225).
#
# Mirror of _emit_pattern_guidance_blocks but for CI check names. Reads the
# RESOLUTION_COMMAND and GUIDANCE_TEXT for each detected classification from
# ci-failure-patterns.conf.
#
# Args:
#   $1 - classification_output  (multi-line: "CLASS name1|name2|...")
#   $2 - conf_file              (path to ci-failure-patterns.conf)
#
# Output: markdown guidance blocks on stdout (nothing if all OTHER or empty).
#######################################
_emit_ci_failure_guidance_blocks() {
	local classification_output="$1"
	local conf_file="$2"

	[[ -n "$classification_output" ]] || return 0

	local has_actionable=0
	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		[[ "$cls_line" == OTHER\ * ]] || has_actionable=1
	done < <(printf '%s\n' "$classification_output")
	[[ $has_actionable -eq 1 ]] || return 0

	printf '\n### Pattern-Specific Resolution Guidance\n\n'
	printf 'The failing checks match known patterns with deterministic resolution paths.\n'
	printf 'Try the auto-fix sequence(s) below FIRST, before falling back to the\n'
	printf 'generic worker guidance further down.\n\n'

	while IFS= read -r cls_line; do
		[[ -n "$cls_line" ]] || continue
		local class="${cls_line%% *}"
		local names="${cls_line#* }"
		[[ "$class" == "OTHER" ]] && continue

		local resolution_cmd="" guidance=""
		local fallback_resolution_cmd="" fallback_guidance="" cr="" gr="" rr="" guide_raw=""
		if [[ -f "$conf_file" ]]; then
			while IFS='|' read -r cr gr rr guide_raw; do
				local cn="${cr#"${cr%%[![:space:]]*}"}"
				cn="${cn%"${cn##*[![:space:]]}"}"
				[[ "$cn" == "$class" ]] || continue
				local glob="${gr#"${gr%%[![:space:]]*}"}"
				glob="${glob%"${glob##*[![:space:]]}"}"
				rr="${rr#"${rr%%[![:space:]]*}"}"; rr="${rr%"${rr##*[![:space:]]}"}"
				guide_raw="${guide_raw#"${guide_raw%%[![:space:]]*}"}"
				guide_raw="${guide_raw%"${guide_raw##*[![:space:]]}"}"
				if [[ -z "$fallback_resolution_cmd" && -z "$fallback_guidance" ]]; then
					fallback_resolution_cmd="$rr"; fallback_guidance="$guide_raw"
				fi

				local name=""
				while IFS= read -r name; do
					[[ -n "$name" ]] || continue
					# shellcheck disable=SC2254  # dynamic glob is intentional
					case "$name" in
						$glob)
							resolution_cmd="$rr"; guidance="$guide_raw"
							break 2
							;;
					esac
				done < <(printf '%s\n' "${names//|/$'\n'}")
			done < <(grep -v '^[[:space:]]*#' "$conf_file" \
				| grep -v '^[[:space:]]*$')
		fi
		if [[ -z "$resolution_cmd" && -n "$fallback_resolution_cmd" ]]; then
			resolution_cmd="$fallback_resolution_cmd"; guidance="$fallback_guidance"
		fi

		printf '#### Pattern: %s\n\n' "$class"
		# shellcheck disable=SC2016  # backticks are literal markdown
		printf 'Affected checks: `%s`\n\n' "${names//|/, }"
		if [[ -n "$guidance" ]]; then
			local expanded="${guidance//\\n/$'\n'}"
			printf '%s\n\n' "$expanded"
		fi
		if [[ -n "$resolution_cmd" ]]; then
			# shellcheck disable=SC2016  # backticks are literal markdown
			printf 'Quick resolution command: `%s`\n\n' "$resolution_cmd"
		fi
	done < <(printf '%s\n' "$classification_output")
	return 0
}

#######################################
# Build the conflict-feedback Markdown section for a closed-conflict PR.
#
# Produces the "## Merge Conflict Feedback" block appended to the linked
# issue body. Leads with cherry-pick-first guidance (t2426) — the prior
# worker's commit is usually correct-but-stale, so cherry-picking onto a
# fresh branch off current default branch is ~10x cheaper than rewriting.
#
# Scope-leak heuristic (t2802): if the prior PR touched more files than a
# focused fix should, that's a signal the BRANCH BASE was wrong, not that
# the semantic conflict is real. Rebuilding from the issue body is then
# cheaper than cherry-picking a scope-leaked branch. Canonical failure:
# example-repo#2716 / PR #2733 (100 files for a 2-line fix). Successive
# workers burned opus tokens trying to cherry-pick the monster.
#
# Extracted from _dispatch_conflict_fix_worker to keep that function under
# the 100-line threshold (function-complexity gate).
#
# Args: $1=pr_number, $2=pr_title, $3=pr_files, $4=pr_head_sha,
#       $5=default_branch (e.g. "main", "develop"),
#       $6=pr_file_count (integer, may be empty)
# Stdout: the rendered section
#######################################
_build_conflict_feedback_section() {
	local pr_number="$1"
	local pr_title="$2"
	local pr_files="$3"
	local pr_head_sha="$4"
	local default_branch="${5:-main}"
	local pr_file_count="${6:-}"

	# Locate the conflict-patterns.conf registry (t2987).
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local conf_file="${script_dir}/../configs/conflict-patterns.conf"

	# Classify conflicting files for pattern-aware guidance (t2987).
	local classification_output=""
	if [[ -n "$pr_files" ]]; then
		classification_output=$(_classify_conflicts_by_pattern "$pr_files" "$conf_file")
	fi

	# Scope-leak detection (t2802). If prior PR touched >20 files, the
	# base was probably wrong (canonical HEAD stale). Cherry-picking a
	# scope-leaked branch is expensive and usually fails the same way
	# the first attempt did. Surface the signal upfront so the worker
	# rebuilds from the issue body instead of chasing a ghost diff.
	#
	# Build as plain quoted string (not heredoc-in-$()) so bash 3.2 accepts it.
	local scope_leak_warning=""
	if [[ -n "$pr_file_count" ]] && [[ "$pr_file_count" =~ ^[0-9]+$ ]] && ((pr_file_count > 20)); then
		scope_leak_warning="> ⚠ **Scope-leak signal**: the prior PR touched **${pr_file_count} files**. For most
> conflict-feedback loops the touch-count should be 1-5. A high count usually means
> the prior worker's branch was created off a stale canonical HEAD (not \`origin/${default_branch}\`),
> so the diff = \"everything ${default_branch} has that the stale base doesn't\" + the actual fix.
>
> **If the file list below looks unrelated to the original issue scope, skip the
> cherry-pick entirely** and rebuild from the issue body onto a fresh branch explicitly
> based on \`origin/${default_branch}\`. Cherry-picking a scope-leaked branch will fail
> the same way — that is why the prior attempt was closed.
>
> Framework fix in-flight: t2802 makes \`worktree-helper.sh add\` base new branches
> on \`origin/<default>\` explicitly instead of inheriting canonical HEAD."
	fi

	# Build scope-warning block separately to avoid interpolating empty lines.
	local scope_block=""
	if [[ -n "$scope_leak_warning" ]]; then
		scope_block=$'\n'"${scope_leak_warning}"$'\n'
	fi

	cat <<-EOF
		## Merge Conflict Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} (\`${pr_title}\`) developed merge conflicts with
		\`${default_branch}\` that could not be resolved by \`gh pr update-branch\` (server-side fast-forward).
		The conflicts are semantic — the same files were modified on both branches${pr_file_count:+ (${pr_file_count} files touched)}.${scope_block}

		### Files in the conflicting PR

		\`\`\`
		${pr_files}
		\`\`\`

		### Worker guidance

		The prior PR's head commit is \`${pr_head_sha:-<lookup via gh pr view ${pr_number} --json headRefOid>}\`. Choose the cheapest path that works:

		1. **Cherry-pick onto a fresh branch off current \`origin/${default_branch}\`** (~10x cheaper than rewriting, works when the prior implementation was correct-but-stale):

		   \`\`\`bash
		   git fetch origin pull/${pr_number}/head:recovered-${pr_number}
		   # Explicit base on origin/${default_branch} — NOT canonical HEAD (t2802).
		   git worktree add -b fresh-branch ../fresh-worktree origin/${default_branch}
		   cd ../fresh-worktree
		   git cherry-pick ${pr_head_sha:-<head-sha>}
		   # run tests — if clean, proceed to PR
		   \`\`\`

		2. **If cherry-pick surfaces conflicts**, resolve them. The conflict surface IS the semantic overlap between the two branches — resolve those specific hunks rather than rewriting untouched logic.

		3. **If the scope-leak warning above fired** (prior PR >20 files but the issue describes a focused fix), **skip cherry-pick entirely** and rebuild from scratch using the issue body as the spec. Do NOT try to cherry-pick-then-drop-files — too error-prone. A clean rewrite from the 2-line spec is cheaper than surgery on a 100-file branch.

		4. **Only rewrite from scratch (scope-OK case)** if the prior approach was rejected in review. Check PR #${pr_number}'s review comments for \`CHANGES_REQUESTED\` or rejection keywords before assuming the approach was wrong.

		Do NOT reuse the old PR's branch directly — always cherry-pick onto a fresh branch off current \`origin/${default_branch}\`.

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF

	# Append pattern-specific guidance block for non-CODE patterns (t2987).
	_emit_pattern_guidance_blocks "$classification_output" "$default_branch" "$conf_file"
	return 0
}

#######################################
# Route merge conflict context from a worker PR to its linked issue, close
# the PR, and set the issue to status:available for re-dispatch.
#
# Called when `gh pr update-branch` fails (true semantic conflict) on a
# worker PR. The next worker gets the conflict context and the list of
# conflicting files in its prompt.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_title
#######################################
_dispatch_conflict_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_title="$4"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids conflict feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi

	# Create labels (idempotent, --force)
	_feedback_route_gh_write label create "conflict-feedback-routed" --repo "$repo_slug" --color "D4C5F9" \
		--description "Worker PR with merge conflicts routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:conflict-feedback" --repo "$repo_slug" --color "E6D8FA" \
		--description "Issue carries conflict context routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true

	# Get the list of files changed in the PR (these are the conflict candidates).
	# Prefer the operation-owned REST helper from the PR gates module; retain an
	# exact REST path for isolated module callers.
	local pr_files
	local fetch_failure="(could not fetch)"
	if declare -F _pulse_merge_pr_file_paths_rest >/dev/null 2>&1; then
		pr_files=$(_pulse_merge_pr_file_paths_rest "$pr_number" "$repo_slug" 2>/dev/null) || pr_files="$fetch_failure"
	else
		pr_files=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-pr-files-rest" \
			gh api --paginate "repos/${repo_slug}/pulls/${pr_number}/files?per_page=100" \
				--jq '.[].filename' 2>/dev/null) || pr_files="$fetch_failure"
	fi

	# File count for scope-leak heuristic (t2802). Rely on the already-fetched
	# file list rather than a second API call — a line count of the joined
	# output matches the files array length when pr_files fetched cleanly.
	local pr_file_count=""
	if [[ -n "$pr_files" ]] && [[ "$pr_files" != "$fetch_failure" ]]; then
		pr_file_count=$(printf '%s\n' "$pr_files" | grep -c '^.' || true)
	fi

	# Snapshot the PR head before finalization so every later write is generation-bound.
	local pr_head_sha
	pr_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_head_sha=""

	# Default branch for the repo. Use gh for the authoritative answer (the
	# pulse may run from a repo path that differs from repo_slug). Fall back
	# to "main" if detection fails — matches pre-t2802 behaviour.
	local default_branch
	default_branch=$(gh repo view "$repo_slug" \
		--json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || default_branch=""
	[[ -n "$default_branch" ]] || default_branch="main"

	local feedback_section
	feedback_section=$(_build_conflict_feedback_section \
		"$pr_number" "$pr_title" "$pr_files" "$pr_head_sha" \
		"$default_branch" "$pr_file_count")

	local marker="<!-- conflict-feedback:PR${pr_number} -->"
	local close_comment="## Merge conflict feedback routed to issue #${linked_issue}

This worker PR had semantic merge conflicts with \`${default_branch}\` that \`update-branch\` could not resolve. The conflict context and file list have been appended to the linked issue body so the next worker can re-implement on top of current \`${default_branch}\`.

_Closed by deterministic merge pass (pulse-merge.sh)._"
	local finalize_rc=0
	_finalize_feedback_route "conflict" "$pr_number" "$repo_slug" "$linked_issue" "$pr_head_sha" \
		"source:conflict-feedback" "conflict-feedback-routed" "$marker" "$feedback_section" \
		"_dispatch_conflict_fix_worker" "$close_comment" || finalize_rc=$?
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: routed conflict feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}

#######################################
# Route review feedback from a stuck worker PR to its linked issue and
# close the PR so the dispatch queue can re-pick the task (t2093).
#
# Called by `_check_pr_merge_gates` when `reviewDecision=CHANGES_REQUESTED`
# on a worker-authored PR with a linked issue. Before this helper existed,
# such PRs accumulated indefinitely: the merge pass skipped them (correctly,
# since they can't pass the review gate as-is), but nothing dispatched a
# fresh worker to address the feedback. The PR author is the headless
# worker account, so no human was notified; the review-followup pipeline
# only fires on *merged* PRs; and the dispatch-dedup guard treated the
# open PR as an active claim on the linked issue.
#
# This function closes that loop:
#   1. Fetches bot reviews + inline comments from the stuck PR.
#   2. Appends a "Review Feedback" section to the linked issue body
#      (marker-guarded so re-runs are idempotent).
#   3. Transitions the linked issue to `status:available` and tags it
#      `source:review-feedback` so the next dispatch cycle picks it up
#      with the feedback in the prompt.
#   4. Closes the stuck PR with an explanatory comment and tags it
#      `review-routed-to-issue` as a belt-and-suspenders idempotency flag.
#
# Interactive, external-contributor, no-takeover, and maintainer-held PRs are
# filtered by `_route_pr_to_fix_worker` before this helper is called.
#
# Partial finalization returns a typed deferred or maintainer outcome. The
# merge-loop boundary logs that outcome and continues processing unrelated PRs.
#
# Reference patterns:
#   - `quality-feedback-helper.sh` — bot review comment extraction
#   - `_close_conflicting_pr`      — close-with-comment boilerplate
#   - `draft-response-helper.sh`   — issue body append pattern
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug  (owner/repo)
#   $3 - linked_issue  (the issue the PR resolves/fixes/closes)
#######################################
_dispatch_pr_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids review feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local route_snapshot=""
	local route_state=""
	local expected_head=""
	local route_labels=""
	route_snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "initial review-route PR snapshot unavailable"
		return $?
	}
	IFS=$'\t' read -r route_state expected_head route_labels <<<"$route_snapshot"

	# Ensure the idempotency + origin labels exist on the repo (idempotent,
	# --force, swallowed failures). quality-feedback-helper.sh also creates
	# source:review-feedback — redundant creation is harmless.
	_feedback_route_gh_write label create "review-routed-to-issue" --repo "$repo_slug" --color "D93F0B" \
		--description "Worker PR with CHANGES_REQUESTED routed to linked issue for re-dispatch (t2093)" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:review-feedback" --repo "$repo_slug" --color "C2E0C6" \
		--description "Issue carries review feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "$PULSE_REVIEW_REPAIR_SOURCE_LABEL" --repo "$repo_slug" --color "C2E0C6" \
		--description "Verified head-bound PR review repair" \
		--force >/dev/null 2>&1 || true

	if ! _review_feedback_fetch_evidence "$pr_number" "$repo_slug"; then
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local reviews_json="$_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON"
	local inline_json="$_PULSE_REVIEW_FEEDBACK_INLINE_JSON"

	# --- Build the Review Feedback markdown section ---
	local feedback_section=""
	feedback_section=$(_build_review_feedback_section \
		"$pr_number" "$repo_slug" "$reviews_json" "$inline_json") || feedback_section=""
	if [[ -z "$feedback_section" ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: PR #${pr_number} in ${repo_slug} has CHANGES_REQUESTED but no substantive review content — leaving PR open without routing (t2093)" >>"$LOGFILE"
		return 0
	fi

	local evidence_fingerprint=""
	evidence_fingerprint=$(_review_feedback_evidence_fingerprint "$reviews_json" "$inline_json") || {
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: review evidence identity unavailable for PR #${pr_number} in ${repo_slug} — deferring without routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	}
	local marker="<!-- t2093:review-feedback:PR${pr_number}:EVIDENCE${evidence_fingerprint} -->"
	local legacy_match="<!-- t2093:review-feedback:PR${pr_number} -->"
	local close_comment
	close_comment="## Review feedback routed to linked issue #${linked_issue} (t2093)

This worker-authored PR had \`reviewDecision=CHANGES_REQUESTED\`. Rather than let it sit
indefinitely (no human owns worker PRs and the dispatch-dedup guard treats an open worker
PR as an active claim), the deterministic merge pass has:

1. Extracted the review feedback (top-level reviews + file:line inline comments) and
   appended it to the linked issue body as a \"Review Feedback\" section.
2. Closed this PR so the dispatch queue can re-pick the linked issue.
3. Transitioned issue #${linked_issue} to \`status:available\` and tagged it with
   verified \`source:review-repair\` provenance plus \`source:review-feedback\`.
   The next pulse cycle can dispatch a fresh worker with the feedback in its prompt.

The next worker will see the updated issue body, address the review findings, and
open a fresh PR against issue #${linked_issue}.

_Closed by deterministic merge pass (pulse-merge.sh, t2093)._"
	local finalize_rc=0
	_finalize_feedback_route "review" "$pr_number" "$repo_slug" "$linked_issue" "$expected_head" \
		"$PULSE_REVIEW_REPAIR_SOURCE_LABEL" "review-routed-to-issue" "$marker" "$feedback_section" \
		"_dispatch_pr_fix_worker" "$close_comment" "$legacy_match" "$evidence_fingerprint" \
		"source:review-feedback" || finalize_rc=$?
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: routed review feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (t2093)" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}
