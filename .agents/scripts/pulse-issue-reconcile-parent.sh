#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-parent.sh — Parent-task reconciliation helpers
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21286) to keep the orchestrator
# file below the 1500-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, REPOS_JSON, and
# PULSE_QUEUED_SCAN_LIMIT.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-parent.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, gh_issue_comment, etc.)
#   - shared-phase-filing.sh (_parse_phases_section)
#   - pulse-issue-reconcile-actions.sh (_action_cpt_single, _fetch_subissue_numbers, etc.)
#
# Exports:
#   _post_parent_decomposition_nudge       — nudge undecomposed parent-task issues
#   _post_parent_decomposition_escalation  — escalate long-unactioned parent nudges
#   reconcile_completed_parent_tasks       — close parents when all children resolved
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_ISSUE_RECONCILE_PARENT_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_PARENT_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Module-level variable defaults (set -u guards)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${REPOS_JSON:=${HOME}/.config/aidevops/repos.json}"
: "${PULSE_QUEUED_SCAN_LIMIT:=1000}"

# Module-level label constant (from orchestrator)
[[ -n "${_PIR_PT_LABEL+x}" ]] || _PIR_PT_LABEL="parent-task"

#######################################
# t2388: post an idempotent decomposition-nudge comment on a parent-task
# issue that has zero filed children. Without this, undecomposed parents
# sit silently forever — the parent-task label blocks dispatch, no
# children exist to do the work, and no signal surfaces to the maintainer.
#
# Idempotent via the <!-- parent-needs-decomposition --> marker: re-runs
# skip any parent already nudged. The marker is checked via the issue
# comments API before posting; if already present, returns 1 (no-op).
#
# Arguments:
#   arg1 - repo slug (owner/repo)
#   arg2 - parent issue number
#   arg3 - parent title (for the comment body)
# Returns: 0 if the nudge was posted, 1 if skipped (marker present or
# comment failed).
#######################################
_post_parent_decomposition_nudge() {
	local slug="$1"
	local parent_num="$2"
	local parent_title="${3:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-needs-decomposition -->'

	# GH#20219 Factor 2: max-nudge cap. Concurrent pulse runners can race
	# the idempotency check (both read 0 markers, both post). A hard cap
	# bounds the damage: if MAX_PARENT_NUDGE_COUNT nudges already exist,
	# stop posting regardless of race timing. Default 3 — enough to surface
	# the nudge to a maintainer, bounded enough to prevent the 19-comment
	# spam observed on #20161.
	local max_nudge_count="${MAX_PARENT_NUDGE_COUNT:-3}"

	# Idempotency check: skip if marker already present in any comment.
	#
	# t2572 + GH#20219: the original --slurp+--jq query was rejected by `gh
	# api` ("the --slurp option is not supported with --jq or --template"),
	# silently returning empty and defeating the dedup check — every pulse
	# cycle posted a fresh nudge (23 on #20001, 19+ on #20161, 4 on
	# webapp#2546 from two runners in minutes).
	#
	# Fix (t2572): streaming --paginate + --jq (no --slurp). Per-page jq
	# emits matching .id values; wc -l counts across all pages.
	#
	# Defence-in-depth (GH#20219): fail-CLOSED on API error (skip the cycle
	# rather than post) + MAX_PARENT_NUDGE_COUNT cap bounds total nudges
	# even if the dedup query somehow returns 0 on a populated thread. The
	# nudge is advisory, not safety-critical; missing a cycle is harmless,
	# duplicating is not.
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""

	# Fail-closed: if we cannot determine the count, skip this cycle.
	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Nudge dedup: API/jq failure for #${parent_num} in ${slug} — skipping nudge (fail-closed, GH#20219)" >>"$LOGFILE"
		return 1
	fi

	# Block if any nudge already exists OR if count exceeds the cap.
	if [[ "$existing" -ge 1 ]]; then
		if [[ "$existing" -ge "$max_nudge_count" ]]; then
			echo "[pulse-wrapper] Nudge dedup: #${parent_num} in ${slug} has ${existing} nudges (cap=${max_nudge_count}) — suppressing (GH#20219)" >>"$LOGFILE"
		fi
		return 1
	fi

	# Sanitise title for safe markdown embed.
	local safe_title="$parent_title"
	safe_title="${safe_title//\`/}"

	local comment_body="${marker}
## Parent Task Needs Decomposition

This issue carries the \`parent-task\` label, which unconditionally blocks pulse dispatch (see \`dispatch-dedup-helper.sh\` → \`PARENT_TASK_BLOCKED\`). It also has **zero filed children** — no \`## Children\`, \`## Sub-tasks\`, or \`## Child issues\` section with \`#NNNN\` references, and no GraphQL sub-issue graph.

Under these two conditions the issue cannot make progress on its own. Workers won't pick it up (dispatch blocked), no completion sweep can fire (no children to check), and nothing else nudges it forward. Without decomposition it will sit here silently forever.

**Two paths forward — pick one:**

1. **Decompose into children.** File the specific implementation tasks as separate issues, then edit this parent body to include a section like:

   \`\`\`
   ## Children

   - t2XXX / #NNNN — first specific task
   - t2YYY / #MMMM — second specific task
   \`\`\`

   The next pulse cycle will detect the children via \`reconcile_completed_parent_tasks\` and auto-close this parent once all listed children are closed.

2. **Drop the parent-task label.** If this issue is actually a single unit of work (not a roadmap tracker), remove the \`parent-task\` label so the pulse can dispatch it directly:

   \`\`\`
   gh issue edit ${parent_num} --repo ${slug} --remove-label parent-task
   \`\`\`

See \`.agents/AGENTS.md\` → \"Parent / meta tasks\" (t1986 / t2211) for the full rule. Parent-task is for epics and roadmap trackers that will never be implemented as a single unit — only their children will.

_Automated by \`_post_parent_decomposition_nudge\` in \`pulse-issue-reconcile-parent.sh\` (t2388). Posted once per issue via the \`<!-- parent-needs-decomposition -->\` marker; re-runs are no-ops._"

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: nudge posted for #${parent_num} in ${slug} (no children filed)" >>"$LOGFILE"
	return 0
}


#######################################
# t2442: post an escalation comment on a parent-task issue whose nudge
# has sat unactioned for >=7 days AND no auto-decomposer child issue is
# tracking the work. This closes the "nudge black hole" — without this
# step, a parent with a prior nudge would sit blocked forever because
# the nudge marker-idempotency keeps firing no-op forever.
#
# Behaviour:
#   1. Idempotency — if the <!-- parent-needs-decomposition-escalated -->
#      marker is already present in any comment, returns 1 (no-op).
#   2. Applies `needs-maintainer-review` so the issue surfaces in the
#      maintainer's review queue on next interactive session start.
#   3. The comment body must explicitly list the four paths forward
#      (decompose / drop label / close / file children). This is the
#      final AI-advisory touch before the maintainer decides.
#
# Argument contract matches _post_parent_decomposition_nudge so the
# two helpers are drop-in compatible in the reconcile call site.
#
# Arguments:
#   arg1 - repo slug
#   arg2 - parent issue number
#   arg3 - parent title
# Returns: 0 if escalation posted, 1 if skipped (marker present, missing
# args, or API failure).
#######################################
_post_parent_decomposition_escalation() {
	local slug="$1"
	local parent_num="$2"
	local parent_title="${3:-}"

	[[ -n "$slug" ]] || return 1
	[[ "$parent_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-needs-decomposition-escalated -->'

	# GH#20219 Factor 2: fail-closed + max-count cap (same pattern as nudge).
	# Escalation is rarer than nudging but the same TOCTOU race applies in
	# multi-runner fleets. Fail-closed: if we cannot determine the count,
	# skip this cycle (escalation is advisory, not safety-critical).
	#
	# t2572: streaming --paginate + --jq (no --slurp — gh api rejects the
	# combination). See _post_parent_decomposition_nudge for the full story.
	local max_escalation_count="${MAX_PARENT_ESCALATION_COUNT:-2}"
	local existing=""
	existing=$(gh api --paginate "repos/${slug}/issues/${parent_num}/comments" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" \
		2>/dev/null | wc -l | tr -d ' ') || existing=""
	if [[ ! "$existing" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Escalation dedup: API/jq failure for #${parent_num} in ${slug} — skipping (fail-closed, GH#20219)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$existing" -ge 1 ]]; then
		if [[ "$existing" -ge "$max_escalation_count" ]]; then
			echo "[pulse-wrapper] Escalation dedup: #${parent_num} in ${slug} has ${existing} escalations (cap=${max_escalation_count}) — suppressing (GH#20219)" >>"$LOGFILE"
		fi
		return 1
	fi

	local safe_title="$parent_title"
	safe_title="${safe_title//\`/}"

	local comment_body="${marker}
## Parent Task Decomposition — Escalation

The decomposition nudge on this issue has been open for **7+ days** with no action. This issue still carries \`parent-task\` (dispatch blocked), still has zero filed children, and no auto-decompose worker issue is tracking it. Applying \`needs-maintainer-review\` so it surfaces in the maintainer queue.

**Paths forward — pick one:**

1. **Decompose into children.** File the specific implementation tasks as separate issues, then edit this parent body to add a \`## Children\` section listing them. Next pulse cycle will detect them via \`reconcile_completed_parent_tasks\`.

2. **Drop the parent-task label.** If this is actually a single unit of work (not a roadmap tracker):

   \`\`\`
   gh issue edit ${parent_num} --repo ${slug} --remove-label parent-task
   \`\`\`

3. **Close the issue.** If the work is no longer needed or has been superseded.

4. **Let the auto-decomposer handle it.** If you want a \`tier:thinking\` worker to propose a decomposition plan automatically, remove the \`needs-maintainer-review\` label — the next pulse cycle will file a \`<!-- aidevops:generator=auto-decompose -->\` issue that dispatches a worker to decompose this parent.

See \`.agents/AGENTS.md\` → \"Parent / meta tasks\" (t1986 / t2211 / t2442) for the full rule.

_Automated by \`_post_parent_decomposition_escalation\` in \`pulse-issue-reconcile-parent.sh\` (t2442). Posted once per issue via the \`<!-- parent-needs-decomposition-escalated -->\` marker; re-runs are no-ops._"

	# Apply needs-maintainer-review label. Non-fatal — if it fails we still
	# want the comment posted so the maintainer sees the escalation.
	gh issue edit "$parent_num" --repo "$slug" \
		--add-label "needs-maintainer-review" >/dev/null 2>&1 || true

	gh_issue_comment "$parent_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	echo "[pulse-wrapper] Reconcile parent-task: escalation posted for #${parent_num} in ${slug} (nudge >=7d unactioned)" >>"$LOGFILE"
	return 0
}

#######################################
# t2786 / GH#20871: phase-section parsing for the declared-vs-filed close
# guard now delegates to the structured parser in shared-phase-filing.sh
# (sourced indirectly via pulse-merge.sh which loads before this module
# in pulse-wrapper.sh). The structured parser emits one tab-separated row
# per *declared* phase:
#
#   <phase_num>\t<description>\t<marker>\t<child_ref>
#
# matching only the canonical list-form (`- Phase N - desc`) and bold-form
# (`**Phase N — desc**`) declarations. Subsection headings like
# `### Phase 1 detail` and prose mentions of "Phase N" are correctly
# ignored — the over-count that GH#20871 surfaced (the very issue that
# established this auto-close path was its own first victim).
#
# Previously this module redefined `_parse_phases_section` locally as a
# raw section extractor. That local override has been removed; rows are
# now counted by line-count over the structured parser's output. See
# `_try_close_parent_tracker` for the count and unfiled-phase extraction
# logic.
#######################################

#######################################
# t2786: post an idempotent "declared phases not yet filed" nudge comment.
# Called by _try_close_parent_tracker when the parent body's ## Phases
# section declares more phases than have been filed as child issues.
# Prevents premature parent close when unfiled phases exist.
#
# Idempotent via the <!-- parent-declared-phases-unfiled --> marker:
# re-runs skip any parent already nudged. Fail-closed on API errors.
#
# Arguments:
#   arg1 - repo slug (owner/repo)
#   arg2 - parent issue number
#   arg3 - declared phase count (from ## Phases section)
#   arg4 - filed child count (child_count already verified via gh api)
#   arg5 - unfiled phase text (lines without #NNN, for nudge body listing)
# Returns: 0 if nudge posted, 1 if skipped (marker present, API error,
#          or comment call failed).
#######################################

_recent_closed_parent_cutoff() {
	if date --version >/dev/null 2>&1; then
		date -u -d '7 days ago' +%Y-%m-%d
	else
		date -u -v-7d +%Y-%m-%d
	fi
	return 0
}

_fetch_recently_closed_parent_tasks() {
	local slug="$1" parent_label="$2"
	local cutoff=""
	cutoff=$(_recent_closed_parent_cutoff) || return 1
	gh_issue_list --repo "$slug" --state closed \
		--label "$parent_label" --search "closed:>=${cutoff}" \
		--json number,title,body,state,labels --limit 10 2>/dev/null || return 1
	return 0
}

reconcile_completed_parent_tasks() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_closed=0
	local max_closes=5
	local total_nudged=0
	local max_nudges=5
	# t2442: escalation is rarer than nudging — bound tighter. 3 per cycle
	# is enough to avoid review-queue spam while still making progress.
	local total_escalated=0
	local max_escalations=3
	local total_reopened=0
	local max_reopens=5
	local _open_state="OPEN"
	# t2442: parent-task escalation threshold — nudge must have sat for
	# at least this many hours with zero children before we escalate.
	# 7 days = 168 hours. Override via env for tests / incident response.
	local escalation_threshold_hours="${PARENT_DECOMPOSITION_ESCALATION_HOURS:-168}"

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$total_closed" -lt "$max_closes" || "$total_nudged" -lt "$max_nudges" || "$total_escalated" -lt "$max_escalations" || "$total_reopened" -lt "$max_reopens" ]] || break

		# t2773: prefer prefetch cache (now includes body field); fall back to gh_issue_list.
		# Use module-level _PIR_PT_LABEL to avoid a second literal (string-literal ratchet).
		local _cpt_lbl="$_PIR_PT_LABEL"
		local issues_json="" open_issues_json="" closed_issues_json="" _cache_issues_cpt=""
		if _cache_issues_cpt=$(_read_cache_issues_for_slug "$slug" 2>/dev/null); then
			open_issues_json=$(printf '%s' "$_cache_issues_cpt" | \
				jq -c --arg lbl "$_cpt_lbl" --arg state "$_open_state" \
				'[.[] | select(.labels | map(.name) | index($lbl)) | . + {state:$state}] | .[0:10]' \
				2>/dev/null) || open_issues_json="[]"
		else
			open_issues_json=$(gh_issue_list --repo "$slug" --state open \
				--label "$_cpt_lbl" \
				--json number,title,body,state,labels --limit 10 2>/dev/null) || open_issues_json="[]"
		fi
		closed_issues_json=$(_fetch_recently_closed_parent_tasks "$slug" "$_cpt_lbl") || closed_issues_json="[]"
		issues_json=$(printf '%s\n%s\n' "$open_issues_json" "$closed_issues_json" | \
			jq -sc 'add | unique_by(.number) | .[0:20]' 2>/dev/null) || issues_json="[]"
		[[ -n "$issues_json" && "$issues_json" != "null" ]] || continue

		local issue_count
		issue_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || issue_count=0
		[[ "$issue_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$issue_count" ]] && [[ "$total_closed" -lt "$max_closes" || "$total_nudged" -lt "$max_nudges" || "$total_escalated" -lt "$max_escalations" || "$total_reopened" -lt "$max_reopens" ]]; do
			local issue_num="" issue_body="" issue_title="" issue_state="" issue_labels=""
			issue_num=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number // ""') || true
			issue_body=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].body // ""') || true
			issue_title=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].title // ""') || true
			issue_state=$(printf '%s' "$issues_json" | \
				jq -r --argjson i "$i" --arg state "$_open_state" '.[$i].state // $state') || issue_state="$_open_state"
			issue_labels=$(printf '%s' "$issues_json" | \
				jq -r --argjson i "$i" '[.[$i].labels[]?.name] | join(",")') || issue_labels=""
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# t2776: delegate per-issue action to shared helper (_action_cpt_single).
			local _can_close=0 _can_nudge=0 _can_escalate=0
			[[ "$total_closed" -lt "$max_closes" ]] && _can_close=1
			[[ "$total_nudged" -lt "$max_nudges" ]] && _can_nudge=1
			[[ "$total_escalated" -lt "$max_escalations" ]] && _can_escalate=1
			# Arithmetic check avoids repeated == "1" pattern (string-literal ratchet)
			[[ $((_can_close + _can_nudge + _can_escalate)) -gt 0 ]] || continue

			_action_cpt_single "$slug" "$issue_num" "$issue_title" "$issue_body" \
				"$_can_close" "$_can_nudge" "$_can_escalate" "$escalation_threshold_hours" "$issue_state" "$issue_labels"
			[[ "$_SP_CPT_CLOSED" -eq 1 ]] && total_closed=$((total_closed + 1))
			[[ "$_SP_CPT_NUDGED" -eq 1 ]] && total_nudged=$((total_nudged + 1))
			[[ "$_SP_CPT_ESCALATED" -eq 1 ]] && total_escalated=$((total_escalated + 1))
			[[ "$_SP_CPT_REOPENED" -eq 1 ]] && total_reopened=$((total_reopened + 1))
		done
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	if [[ "$total_closed" -gt 0 || "$total_nudged" -gt 0 || "$total_escalated" -gt 0 || "$total_reopened" -gt 0 ]]; then
		echo "[pulse-wrapper] Reconcile completed parent tasks: closed=${total_closed} reopened=${total_reopened} nudged=${total_nudged} escalated=${total_escalated}" >>"$LOGFILE"
	fi

	return 0
}
