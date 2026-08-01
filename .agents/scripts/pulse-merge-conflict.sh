#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-conflict.sh — Conflict handling + interactive PR handover + carry-forward diff for the deterministic merge pass.
#
# Extracted from pulse-merge.sh (GH#19836) to bring that file below the
# 2000-line simplification gate.
#
# This module contains the "downstream of merge" cluster — all functions
# that are called AFTER _check_pr_merge_gates detects a conflicting PR
# or when an idle origin:interactive PR needs handover. None of these
# functions call back into the merge core or pr-gates clusters, so the
# split is safe: bash's lazy function name resolution sees each module's
# symbols at call time, regardless of source order.
#
# This module is sourced by pulse-wrapper.sh AFTER pulse-merge.sh. It
# MUST NOT be executed directly — it relies on the orchestrator having
# sourced shared-constants.sh, worker-lifecycle-common.sh, and the merge
# core before any function is invoked.
#
# Functions in this module (in source order):
#   - _post_rebase_nudge_on_interactive_conflicting   (GH#18650 Fix 4)
#   - _post_rebase_nudge_on_contributor_conflicting   (GH#20485)
#   - _interactive_pr_is_stale                        (t2189)
#   - _interactive_pr_trigger_handover                (t2189)
#   - _is_planning_path_for_overlap                   (GH#18815)
#   - _verify_pr_overlaps_commit                      (GH#18815)
#   - _post_rebase_nudge_on_worker_conflicting        (GH#18815)
#   - _close_conflicting_pr_check_ownership_guard     (GH#20485, replaces _check_interactive_guard)
#   - _close_conflicting_pr_classify_landed           (t2438)
#   - _close_conflicting_pr_comment_landed            (t2438)
#   - _close_conflicting_pr_comment_not_landed        (t2438)
#   - _close_conflicting_pr                           (GH#17574 + GH#18815 + GH#20485)
#   - _carry_forward_pr_diff                          (t2118)
#
# All functions fail-open: missing helpers, API errors, or malformed
# state never block the merge pass — they log and return 0.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_CONFLICT_LOADED:-}" ]] && return 0
_PULSE_MERGE_CONFLICT_LOADED=1

# t2863: Module-level variable defaults (set -u guards).
# Ensures LOGFILE is safe to dereference in all functions when this module
# is sourced outside the pulse-wrapper.sh bootstrap context.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# GH#25780: shared branch-name fallbacks for conflict comments. Keep these
# centralised so string-literal ratchets do not penalise repeated safe defaults.
: "${_PULSE_MERGE_CONFLICT_UNKNOWN_HEAD_BRANCH:=<branch>}"
: "${_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH:=main}"

# t2948: Idle interactive PR handover threshold in seconds (default 4h).
# Override via AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS env var.
# See _interactive_pr_is_stale / _interactive_pr_trigger_handover.
: "${AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS:=${IDLE_INTERACTIVE_HANDOVER_SECONDS:-14400}}"

#######################################
# GH#18650 (Fix 4): Post a one-time rebase nudge on an origin:interactive
# CONFLICTING PR that the pulse is about to skip.
#
# Rationale: the merge pass correctly refuses to auto-close origin:interactive
# PRs (GH#18285 — maintainer session work is theirs to own), but without any
# counterforce the CONFLICTING state persists and the PR rots silently. The
# maintainer sees nothing in their inbox and only discovers the stuck PR
# when they manually check `gh pr list`. This nudge surfaces the stuck state
# on the PR itself, where GitHub's notification system will ping the author.
#
# Idempotent via _gh_idempotent_comment marker — posted once per PR lifetime.
# If the PR is updated and still conflicts, the nudge does NOT repeat. Workers
# and humans who care about the PR will see it in the timeline.
#
# Fail-open: missing helpers or API errors never block the merge pass. The
# nudge is best-effort operational plumbing.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#######################################
_get_pr_branch_refs_for_conflict_comment() {
	local pr_number="$1"
	local repo_slug="$2"
	local branch_refs=""
	local head_branch=""
	local base_branch=""

	branch_refs=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefName,baseRefName \
		--jq '[.headRefName // "", .baseRefName // ""] | @tsv' 2>/dev/null) || branch_refs=""
	if [[ -n "$branch_refs" ]]; then
		IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
	fi
	[[ -n "$head_branch" ]] || head_branch="$_PULSE_MERGE_CONFLICT_UNKNOWN_HEAD_BRANCH"
	[[ -n "$base_branch" ]] || base_branch="$_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH"

	printf '%s\t%s\n' "$head_branch" "$base_branch"
	return 0
}

#######################################
# GH#18650: Post a one-time rebase nudge on an origin:interactive PR
# that is CONFLICTING but must not be auto-closed.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#######################################
_post_rebase_nudge_on_interactive_conflicting() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	# _gh_idempotent_comment is defined in pulse-triage.sh which is sourced
	# after pulse-merge.sh; bash resolves function names at call time so
	# this works at runtime. Skip if for some reason the helper is absent
	# (e.g., out-of-order standalone execution).
	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-wrapper] _post_rebase_nudge_on_interactive_conflicting: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local branch_refs
	local head_branch
	local base_branch
	branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug")
	IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
	[[ -n "$head_branch" ]] || head_branch="$_PULSE_MERGE_CONFLICT_UNKNOWN_HEAD_BRANCH"
	[[ -n "$base_branch" ]] || base_branch="$_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH"

	local marker="<!-- pulse-rebase-nudge -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — branch has diverged from \`${base_branch}\`

This \`origin:interactive\` PR has merge conflicts against \`${base_branch}\`. The pulse merge pass skips auto-close on maintainer session work (GH#18285), but there is no automated path to resolve conflicts on behalf of a human author — this PR needs your attention.

### To resolve

From a terminal (not a chat session):

\`\`\`bash
wt switch ${head_branch}
git pull --rebase origin ${base_branch}
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough for GitHub's web merger.

### Why you're seeing this

Every pulse cycle the deterministic merge pass evaluates open PRs and auto-closes \`CONFLICTING\` ones that have no clear owner. \`origin:interactive\` PRs are explicitly protected from that path, which is correct for active maintainer work but left them to rot silently in the queue. This nudge is posted exactly once per PR so the stuck state surfaces in your inbox. If the PR still conflicts after you think you've rebased, the nudge will NOT repeat — re-check manually via \`gh pr view ${pr_number}\`.

<sub>Posted automatically by \`pulse-merge-conflict.sh\` (GH#18650 / Fix 4 of the 2026-04-13 dispatch-unblocker pass).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# GH#20485: Post a one-time rebase nudge on a conflicting contributor PR
# that the deterministic merge pass has left open because the pulse does
# not own the work.
#
# Rationale: the merge pass must never auto-close work it didn't create.
# For contributor PRs (non-bot author, no origin:worker / origin:interactive
# label), the correct action is: leave the PR open and post a visible signal
# so the contributor knows their branch needs rebasing. Without this nudge
# the stuck state would be invisible in the contributor's inbox.
#
# Idempotent via _gh_idempotent_comment marker — posted once per PR lifetime.
# Fail-open: missing helpers or API errors never block the merge pass.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#######################################
_post_rebase_nudge_on_contributor_conflicting() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-wrapper] _post_rebase_nudge_on_contributor_conflicting: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local branch_refs
	local head_branch
	local base_branch
	branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug")
	IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
	[[ -n "$head_branch" ]] || head_branch="$_PULSE_MERGE_CONFLICT_UNKNOWN_HEAD_BRANCH"
	[[ -n "$base_branch" ]] || base_branch="$_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH"

	local marker="<!-- pulse-rebase-nudge-contributor -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — branch has diverged from \`${base_branch}\`

This PR has merge conflicts against \`${base_branch}\`. The pulse merge pass does not auto-close contributor PRs (GH#20485) — this PR is kept open so your work is not lost.

### To resolve

From a terminal:

\`\`\`bash
git fetch origin
git rebase origin/${base_branch}
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough for GitHub's web merger.

### Why you're seeing this

Every pulse cycle the deterministic merge pass evaluates open PRs with merge conflicts. Contributor PRs (without \`origin:worker\` or \`origin:interactive\` labels) are always left open — the pulse will not close work it did not create. This nudge is posted once per PR to surface the conflict state in your notifications. If the PR still conflicts after rebasing, re-check manually via \`gh pr view ${pr_number}\`.

<sub>Posted automatically by \`pulse-merge-conflict.sh\` (GH#20485).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# t2189: Detect whether an origin:interactive PR is idle enough to hand
# over to the worker pipeline.
#
# The existing rebase-nudge (_post_rebase_nudge_on_interactive_conflicting)
# covers CONFLICTING state passively — it comments once and leaves the PR
# untouched. Interactive PRs with failing required checks (like a complexity
# regression) have no automated rescue path because the three routing gates
# at pulse-merge.sh:840, :1121, :1154 all require `origin:worker`.
#
# This helper is the staleness detector. When it returns 0, the caller
# triggers handover (add `origin:worker-takeover` label + explanation
# comment) and then routes through the existing worker-PR pipelines.
#
# Combined signal — ALL must hold for a stale handover-eligible PR:
#   1. PR has origin:interactive label
#   2. Linked issue has NO active status label (status:queued, in-progress,
#      in-review, claimed) — an active status means a human is driving it
#   3. No live claim stamp file in $CLAIM_STAMP_DIR for the linked issue
#      (session is gone; no interactive-session-helper.sh claim active)
#   4. PR updatedAt older than AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS (default 14400 = 4h)
#   5. Linked issue is open (don't touch PRs whose issue was already closed)
#
# Env controls:
#   AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE — off | detect | enforce (default: detect)
#     off:     returns 1 unconditionally (feature disabled)
#     detect:  evaluates signal and logs would-handover decisions; still returns signal
#     enforce: evaluates signal and returns it; caller acts
#   AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS — age threshold seconds, default 14400 (4h; t2948)
#
# Args: $1 = pr_number, $2 = repo_slug, $3 = updated_at (optional),
#       $4 = head_ref_oid (optional), $5 = head_commit_at (optional)
# Returns: 0 if stale (handover-eligible), 1 otherwise
# Side effect: logs "would-handover" line to $LOGFILE when mode=detect and stale
#######################################
_interactive_pr_is_stale() {
	local pr_number="$1"
	local repo_slug="$2"
	local precomputed_updated_at="${3:-}"
	local precomputed_head_ref_oid="${4:-}"
	local precomputed_head_commit_at="${5:-}"
	local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
	[[ "$mode" == "off" ]] && return 1
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1

	# Fetch PR metadata once. updatedAt can prove staleness without an extra
	# commit lookup; fresh updatedAt still falls through to the head commit
	# timestamp because automated comments/labels can mask an idle branch.
	local pr_meta=""
	pr_meta=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels,updatedAt,headRefOid 2>/dev/null) || return 1

	# Gate 1: must have origin:interactive
	printf '%s' "$pr_meta" | jq -e \
		'.labels | map(.name) | index("origin:interactive")' \
		>/dev/null 2>&1 || return 1

	# Gate 1b (GH#19864): honor no-takeover label — opt-out for maintainers
	# who want to keep an idle PR out of the worker pipeline.
	if printf '%s' "$pr_meta" | jq -e \
		'.labels | map(.name) | index("no-takeover")' \
		>/dev/null 2>&1; then
		echo "[pulse-merge-conflict] _interactive_pr_is_stale: PR #${pr_number} has no-takeover label — skipping handover (GH#19864)" >>"$LOGFILE"
		return 1
	fi

	# Gate 4: age threshold (check updatedAt before commit lookup — cheapest filter)
	local threshold_secs="${AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS:-${IDLE_INTERACTIVE_HANDOVER_SECONDS:-14400}}"  # default 4h (t2948; was 24h)
	local activity_at="" activity_source="updatedAt" now_epoch=0 updated_epoch=0 pr_age_secs=0
	# t2383 Fix 2: validate threshold is a positive integer before arithmetic.
	# A non-numeric value (e.g. "4h", empty, negative) triggers bash
	# "value too great for base" and silently breaks stale detection.
	if [[ ! "$threshold_secs" =~ ^[0-9]+$ ]] || [[ "$threshold_secs" -eq 0 ]]; then
		echo "[pulse-wrapper] _interactive_pr_is_stale: invalid AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS='${threshold_secs}' — must be a positive integer, returning not-stale (t2383)" >>"$LOGFILE"
		return 1
	fi
	local updated_at=""
	updated_at="$precomputed_updated_at"
	if [[ -z "$updated_at" ]]; then
		updated_at=$(printf '%s' "$pr_meta" | jq -r '.updatedAt // empty')
	fi
	[[ -z "$updated_at" ]] && return 1
	now_epoch=$(date +%s)
	# Portable epoch parse — GNU date first (Linux CI), BSD date fallback (macOS)
	updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null) || \
		updated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null) || \
		return 1
	pr_age_secs=$(( now_epoch - updated_epoch ))
	if [[ "$pr_age_secs" -ge "$threshold_secs" ]]; then
		activity_at="$updated_at"
		activity_source="updatedAt"
	else
		pr_age_secs=0
	fi

	local head_ref_oid=""
	if [[ -z "$activity_at" ]]; then
		head_ref_oid="$precomputed_head_ref_oid"
		if [[ -z "$head_ref_oid" ]]; then
			head_ref_oid=$(printf '%s' "$pr_meta" | jq -r '.headRefOid // empty')
		fi
	fi
	if [[ -n "$head_ref_oid" ]]; then
		if [[ -z "$activity_at" && -n "$precomputed_head_commit_at" ]]; then
			activity_at="$precomputed_head_commit_at"
			activity_source="head_commit"
		fi
		if [[ -z "$activity_at" ]]; then
			activity_at=$(gh api "repos/${repo_slug}/commits/${head_ref_oid}" \
				--jq '.commit.committer.date // .commit.author.date // empty' 2>/dev/null) || activity_at=""
			[[ -n "$activity_at" ]] && activity_source="head_commit"
		fi
	fi
	[[ -z "$activity_at" ]] && return 1
	if [[ "$activity_at" != "$updated_at" ]]; then
		updated_epoch=$(date -d "$activity_at" +%s 2>/dev/null) || \
			updated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$activity_at" +%s 2>/dev/null) || \
			return 1
	fi
	pr_age_secs=$(( now_epoch - updated_epoch ))
	[[ "$pr_age_secs" -lt "$threshold_secs" ]] && return 1

	# Gate 2 + 5: resolve linked issue, verify open, check status labels
	local linked_issue
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
	[[ -z "$linked_issue" ]] && return 1
	local issue_meta
	issue_meta=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
		--jq '{state, labels: [.labels[].name]}' 2>/dev/null) || return 1
	printf '%s' "$issue_meta" | jq -e '.state == "open"' >/dev/null 2>&1 || return 1
	printf '%s' "$issue_meta" | jq -e \
		'.labels | any(. == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed")' \
		>/dev/null 2>&1 && return 1

	# Gate 3: no live claim stamp (session gone)
	# Stamp path: $CLAIM_STAMP_DIR/${flattened_slug}-${issue}.json
	# See interactive-session-helper.sh:91 for the canonical pattern.
	local slug_flat stamp_path
	slug_flat="${repo_slug//\//-}"
	stamp_path="${CLAIM_STAMP_DIR:-$HOME/.aidevops/.agent-workspace/interactive-claims}/${slug_flat}-${linked_issue}.json"
	[[ -f "$stamp_path" ]] && return 1

	# All gates passed — PR is stale. Log in detect mode.
	if [[ "$mode" == "detect" ]]; then
		echo "[pulse-wrapper] would-handover: PR #${pr_number} in ${repo_slug} (idle $((pr_age_secs / 3600))h via ${activity_source} >= $((threshold_secs / 3600))h, linked issue #${linked_issue})" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t2189: Trigger handover of an idle interactive PR to the worker pipeline.
#
# Idempotent — applies the `origin:worker-takeover` label and posts ONE
# marker-guarded comment. Second call short-circuits on the existing label.
# The `origin:interactive` label is NOT removed (origin history is append-only;
# worker-takeover is an additive routing signal).
#
# Mode gating:
#   off | detect: no-op (caller is expected to guard too, but belt+braces)
#   enforce:      apply label + post comment
#
# Fail closed: return success only when worker-takeover metadata was already
# present or is confirmed after application. Callers must not route otherwise.
#
# Args: $1 = pr_number, $2 = repo_slug
# Returns: 0 if takeover is confirmed, 1 otherwise
#######################################
_interactive_pr_trigger_handover() {
	local pr_number="$1"
	local repo_slug="$2"
	local mode="${AIDEVOPS_INTERACTIVE_PR_HANDOVER_MODE:-detect}"
	local takeover_label="origin:worker-takeover"
	[[ "$mode" == "enforce" ]] || return 1
	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 1

	# Idempotence short-circuit: label already present → nothing to do
	# Fail CLOSED on label fetch failure — if we can't verify labels, we might
	# miss a no-takeover opt-out. Consistent with _close_conflicting_pr (t2383).
	local pr_labels_json label_fetch_rc
	label_fetch_rc=0
	pr_labels_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name]' 2>/dev/null) || label_fetch_rc=$?
	if [[ $label_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: failed to fetch labels for PR #${pr_number} in ${repo_slug} (exit ${label_fetch_rc}) — skipping handover to honor potential no-takeover label (t2383)" >>"$LOGFILE"
		return 1
	fi
	[[ -n "$pr_labels_json" ]] || pr_labels_json="[]"

	if printf '%s' "$pr_labels_json" | jq -e --arg label "$takeover_label" 'index($label)' >/dev/null 2>&1; then
		return 0
	fi

	# t2383 Fix 1: honour no-takeover opt-out label before applying handover.
	# The handover comment promises "Add the no-takeover label to this PR at
	# any time. The routing gates will skip it." — enforce that promise here.
	if printf '%s' "$pr_labels_json" | jq -e 'index("no-takeover")' >/dev/null 2>&1; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: PR #${pr_number} in ${repo_slug} has no-takeover label — skipping handover (t2383)" >>"$LOGFILE"
		return 1
	fi

	# Apply the label, then prove the remote metadata reflects the transition.
	if ! gh issue edit "$pr_number" --repo "$repo_slug" \
		--add-label "$takeover_label" >/dev/null 2>&1; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: failed to add ${takeover_label} on PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 1
	fi
	if ! pr_labels_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name]' 2>/dev/null) \
		|| ! printf '%s' "$pr_labels_json" | jq -e --arg label "$takeover_label" 'index($label)' >/dev/null 2>&1; then
		echo "[pulse-wrapper] _interactive_pr_trigger_handover: ${takeover_label} was not confirmed after update for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# Post one-time handover comment via _gh_idempotent_comment
	if declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		local marker="<!-- pulse-interactive-handover -->"
		local threshold_h=$(( ${AIDEVOPS_IDLE_INTERACTIVE_HANDOVER_SECONDS:-${IDLE_INTERACTIVE_HANDOVER_SECONDS:-14400}} / 3600 ))
		local body
		body="${marker}
## Worker takeover — no interactive session activity for ${threshold_h}h

This \`origin:interactive\` PR has been idle past the handover threshold. The pulse is now routing it through the worker pipeline to drive it to merge:

- CI failures → routed to linked issue for worker re-dispatch
- Merge conflicts → routed to linked issue for worker re-dispatch
- Review feedback → routed to linked issue for worker re-dispatch
- Once all required checks pass: auto-approved + admin-merged (collaborator author only)

### Reclaiming interactively

If you return and want to drive this PR yourself, run in a terminal (not a chat session):

\`\`\`bash
gh issue edit ${pr_number} --repo ${repo_slug} --remove-label origin:worker-takeover
interactive-session-helper.sh claim <linked-issue-number> ${repo_slug}
\`\`\`

Any worker mid-flight will self-terminate on the next pulse cycle (combined assignee + status signal via \`dispatch-dedup-helper.sh\`).

### Opting out permanently

Add the \`no-takeover\` label to this PR at any time. The routing gates will skip it.

<sub>Posted once per PR by \`pulse-merge-conflict.sh\` (t2189).</sub>"
		_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$body" "pr" || true
	fi

	echo "[pulse-wrapper] handover: PR #${pr_number} in ${repo_slug} handed over to worker pipeline (t2189)" >>"$LOGFILE"
	return 0
}

#######################################
# Detect whether a path is a planning-only file that should NOT be used
# as evidence of "implementation work landed on main".
#
# GH#18815: The deterministic merge pass had a false-positive in PR #18760
# where a planning-brief PR (`plan(t2059, t2060): file follow-ups`) was
# mistaken for an implementation PR because the task-ID grep matched the
# planning commit's subject. Planning paths are excluded from the file
# overlap check so a planning-only commit cannot satisfy the duplicate-work
# heuristic on its own.
#
# Returns 0 (true) if the path is planning-only, 1 (false) if it is an
# implementation file.
#
# Args: $1 = path
#######################################
_is_planning_path_for_overlap() {
	local path="$1"
	case "$path" in
	TODO.md | README.md | CHANGELOG.md | VERSION) return 0 ;;
	todo/* | .agents/configs/simplification-state.json) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Verify that the closing PR and the matching commit on main share at
# least one non-planning file path.
#
# GH#18815: This is the file-overlap gate that distinguishes a genuine
# duplicate (where the same implementation files were touched on both
# sides) from a false positive (where the task ID appeared in a planning
# commit's subject but no implementation work landed).
#
# Returns 0 if the intersection contains at least one implementation file
# → genuine duplicate, safe to close as "already landed".
#
# Returns 1 if:
#   - The intersection is empty (planning-only match → false positive)
#   - File lookup failed (network error, missing API permissions, etc.)
#
# In all "return 1" cases the caller MUST NOT auto-close the PR. The
# function fails CLOSED on lookup errors because the cost of leaving a
# stuck PR open is far less than the cost of discarding real work.
#
# Args: $1 = closing PR number, $2 = repo slug, $3 = matching commit SHA
#######################################
_verify_pr_overlaps_commit() {
	local pr_number="$1"
	local repo_slug="$2"
	local commit_sha="$3"

	local pr_files commit_files
	pr_files=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json files --jq '.files[].path' 2>/dev/null) || return 1
	[[ -n "$pr_files" ]] || return 1

	commit_files=$(gh api "repos/${repo_slug}/commits/${commit_sha}" \
		--jq '.files[].filename' 2>/dev/null) || return 1
	[[ -n "$commit_files" ]] || return 1

	# Compute intersection, excluding planning paths. Iterate the closing
	# PR's files (typically smaller set) and check membership in the
	# matching commit's files via grep -Fxq for exact line match.
	local file
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		if _is_planning_path_for_overlap "$file"; then
			continue
		fi
		if printf '%s\n' "$commit_files" | grep -Fxq -- "$file"; then
			return 0
		fi
	done <<<"$pr_files"

	return 1
}

#######################################
# Post a one-time rebase nudge on a conflicting worker PR that the
# deterministic merge pass left open due to a false-positive task-ID
# match (GH#18815).
#
# Modelled on _post_rebase_nudge_on_interactive_conflicting. Idempotent
# via the marker `<!-- pulse-rebase-nudge-worker -->` — posted exactly
# once per PR lifetime.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug (owner/repo)
#   $3 - task_id (e.g., "t2060" or "GH#18746")
#   $4 - matching_pr (optional — the PR number from the false-positive match)
#######################################
_post_rebase_nudge_on_worker_conflicting() {
	local pr_number="$1"
	local repo_slug="$2"
	local task_id="$3"
	local matching_pr="${4:-}"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-wrapper] _post_rebase_nudge_on_worker_conflicting: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local branch_refs
	local head_branch
	local base_branch
	branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug")
	IFS=$'\t' read -r head_branch base_branch <<<"$branch_refs"
	[[ -n "$head_branch" ]] || head_branch="$_PULSE_MERGE_CONFLICT_UNKNOWN_HEAD_BRANCH"
	[[ -n "$base_branch" ]] || base_branch="$_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH"

	local matching_pr_clause=""
	if [[ -n "$matching_pr" ]]; then
		matching_pr_clause=" The matching commit was from PR #${matching_pr}, which only touches planning files (briefs, TODO.md). The implementation in this PR has not landed."
	fi

	local marker="<!-- pulse-rebase-nudge-worker -->"
	local nudge_body
	nudge_body="${marker}
## Rebase needed — task-ID heuristic detected a planning-only match

This worker PR has merge conflicts against \`${base_branch}\`. The deterministic merge pass found a recent commit on ${base_branch} mentioning task ID \`${task_id}\`, but its file footprint does not overlap with this PR's implementation files.${matching_pr_clause}

To prevent value loss, the merge pass left this PR open instead of auto-closing it. The implementation work in this branch needs to be rebased and re-validated.

### To resolve

From a terminal:

\`\`\`bash
gh pr checkout ${pr_number}
git pull --rebase origin ${base_branch}
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough for GitHub's web merger.

### Why you're seeing this

Earlier versions of \`_close_conflicting_pr\` would have auto-closed this PR with a false 'already landed on main' claim — the task-ID grep alone matched the planning commit's subject and concluded the implementation had landed. The fix added file-overlap verification: when the task ID matches a commit but the file footprints do not intersect on any non-planning path, the heuristic is treated as a false positive and the PR is preserved.

<sub>Posted automatically by \`pulse-merge-conflict.sh\` (GH#18815).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$nudge_body" "pr" || true
	return 0
}

#######################################
# Helpers for _close_conflicting_pr (t2438, GH#20060).
#
# The orchestrator `_close_conflicting_pr` below is composed of these
# helpers to keep every piece under the 100-line function-complexity
# threshold. Module-level globals use the `_CCPR_*` prefix — bash 3.2
# has no `local -n` namerefs, so helpers that need to return multiple
# values do so by side effect on shared state. The orchestrator resets
# the globals before each invocation.
#
# _CCPR_MATCHING_SHA / _CCPR_MATCHING_SUBJECT  — set by
#   _find_task_id_match_on_main. Empty on no-match or fetch error.
# _CCPR_WORK_ON_MAIN / _CCPR_MERGING_PR         — set by
#   _close_conflicting_pr_classify_landed. The orchestrator reads them
#   after the classifier returns to choose the close path.
#######################################

#######################################
# Parse the trailing `(#NNN)` squash-merge suffix from a commit subject.
# Outputs the PR number to stdout. Emits nothing (exit 0) if no match —
# non-squash merges and direct pushes legitimately have no suffix, so
# this is not an error condition.
#
# Args: $1 = commit subject line
#######################################
_parse_squash_merge_pr() {
	local subject="$1"
	[[ -n "$subject" ]] || return 0
	printf '%s' "$subject" |
		grep -oE '\(#[0-9]+\)$' |
		grep -oE '[0-9]+' | head -1 || true
	return 0
}

#######################################
# Verify that a merged PR is safe to treat as superseding a linked issue.
#
# Uses the existing GH#17372 pre-close helper so conflict/empty-branch duplicate
# detection shares the same file-overlap guard as issue-close automation. A
# missing linked issue or missing merged PR is not enough evidence to close the
# issue; the caller may still close the duplicate PR but must not close the
# issue as fixed.
#
# Args: $1 = linked_issue, $2 = superseding_pr, $3 = repo_slug
# Returns: 0 = verified, 1 = not verified / cannot verify
#######################################
_verify_superseding_pr_for_issue() {
	local linked_issue="$1"
	local superseding_pr="$2"
	local repo_slug="$3"

	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 1
	[[ "$superseding_pr" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	local verify_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/verify-issue-close-helper.sh"
	if [[ ! -x "$verify_helper" ]]; then
		verify_helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/verify-issue-close-helper.sh"
	fi
	if [[ ! -x "$verify_helper" ]]; then
		echo "[pulse-wrapper] Superseded duplicate check: verify-issue-close-helper.sh unavailable — cannot verify issue #${linked_issue} against PR #${superseding_pr}" >>"$LOGFILE"
		return 1
	fi

	local verify_output
	if verify_output=$("$verify_helper" check "$linked_issue" "$superseding_pr" "$repo_slug" 2>&1); then
		echo "[pulse-wrapper] Superseded duplicate check: verified issue #${linked_issue} against merged PR #${superseding_pr}: ${verify_output//$'\n'/ }" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] Superseded duplicate check: could not verify issue #${linked_issue} against merged PR #${superseding_pr}: ${verify_output//$'\n'/ }" >>"$LOGFILE"
	return 1
}

#######################################
# Comment/close the linked issue when a duplicate PR is superseded by a verified
# merged fix.
#
# Parent/research issues receive a status comment only; the comment deliberately
# avoids GitHub closing keywords so roadmap/research tasks are not completed by a
# duplicate-PR cleanup.
#
# Args: $1=duplicate_pr, $2=repo_slug, $3=linked_issue, $4=superseding_pr,
#       $5=pr_labels_csv
# Returns: 0 always
#######################################
_close_superseded_duplicate_issue_if_verified() {
	local duplicate_pr="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local superseding_pr="$4"
	local pr_labels_csv="$5"

	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	[[ "$superseding_pr" =~ ^[0-9]+$ ]] || return 0
	if ! _verify_superseding_pr_for_issue "$linked_issue" "$superseding_pr" "$repo_slug"; then
		return 0
	fi

	local issue_api issue_labels parent_or_research=0
	issue_api="repos/${repo_slug}/issues/${linked_issue}"
	if ! issue_labels=$(gh api "$issue_api" --jq '[.labels[]?.name] | join(",")'); then
		echo "[pulse-wrapper] Superseded duplicate check: failed to fetch labels for issue #${linked_issue} — skipping issue closure to be safe" >>"$LOGFILE"
		return 0
	fi
	case ",${issue_labels}," in
	*,parent-task,* | *,research,* | *,research-task,*) parent_or_research=1 ;;
	esac

	local comment_body
	comment_body="Superseded by merged PR #${superseding_pr}.

Pulse verified that PR #${superseding_pr} touches files cited by this issue, then closed duplicate PR #${duplicate_pr} as obsolete."
	if [[ "$parent_or_research" -eq 1 ]]; then
		comment_body="${comment_body}

This issue is labelled as parent/research work, so pulse is leaving it open and avoiding closing keywords."
		gh issue comment "$linked_issue" --repo "$repo_slug" --body "$comment_body" 2>/dev/null || true
		echo "[pulse-wrapper] Superseded duplicate check: commented on parent/research issue #${linked_issue} for duplicate PR #${duplicate_pr}, left open" >>"$LOGFILE"
		return 0
	fi

	gh issue comment "$linked_issue" --repo "$repo_slug" --body "$comment_body" 2>/dev/null || true
	local solved_actor="interactive"
	case ",${pr_labels_csv}," in
	*,origin:worker,* | *,origin:worker-takeover,*) solved_actor="worker" ;;
	esac
	set_solved_label "$linked_issue" "$repo_slug" "$solved_actor" || true
	gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null || true
	fast_fail_reset "$linked_issue" "$repo_slug" || true
	unlock_issue_after_worker "$linked_issue" "$repo_slug"
	echo "[pulse-wrapper] Superseded duplicate check: closed issue #${linked_issue} against merged PR #${superseding_pr} after closing duplicate PR #${duplicate_pr}" >>"$LOGFILE"
	return 0
}

#######################################
# Find the most recent commit on the default branch whose subject
# contains the given task ID as a word-boundary-delimited token.
#
# Sets module globals:
#   _CCPR_MATCHING_SHA      - full SHA of the matching commit, or empty
#   _CCPR_MATCHING_SUBJECT  - subject line of the matching commit, or empty
#
# Fail-open: any fetch failure or missing match leaves both globals
# empty and returns 0. The caller distinguishes no-match from match via
# the globals, not the return code.
#
# Args: $1 = repo_slug, $2 = task_id
#######################################
_find_task_id_match_on_main() {
	local repo_slug="$1"
	local task_id="$2"

	_CCPR_MATCHING_SHA=""
	_CCPR_MATCHING_SUBJECT=""

	[[ -n "$repo_slug" && -n "$task_id" ]] || return 0

	# GH#18815: Fetch (sha, subject) pairs as JSON instead of subjects
	# only, so the file-overlap verification step can look up the
	# matching commit's files via `gh api repos/.../commits/SHA`.
	local commits_json
	commits_json=$(gh api "repos/${repo_slug}/commits" \
		--method GET -f per_page=50 \
		--jq '[.[] | {sha: .sha, subject: (.commit.message | split("\n")[0])}]' \
		2>/dev/null) || commits_json=""
	[[ -n "$commits_json" && "$commits_json" != "null" ]] || return 0

	# Use jq with a regex test for word-boundary matching on the
	# subject. `first // empty` returns the first match or an empty
	# string when nothing matches — distinguishable from a malformed
	# JSON response.
	local matching_obj
	matching_obj=$(printf '%s' "$commits_json" |
		jq -c --arg tid "$task_id" '
			[.[] | select(.subject | test("(^|[^a-zA-Z0-9])" + $tid + "([^a-zA-Z0-9]|$)"; "i"))] | first // empty
		' 2>/dev/null) || matching_obj=""
	[[ -n "$matching_obj" && "$matching_obj" != "null" ]] || return 0

	_CCPR_MATCHING_SHA=$(printf '%s' "$matching_obj" | jq -r '.sha // empty' 2>/dev/null) || _CCPR_MATCHING_SHA=""
	_CCPR_MATCHING_SUBJECT=$(printf '%s' "$matching_obj" | jq -r '.subject // empty' 2>/dev/null) || _CCPR_MATCHING_SUBJECT=""
	return 0
}

#######################################
# Gate 1 of _close_conflicting_pr: ownership protection.
#
# Enforces the invariant "the pulse only auto-closes PRs it owns".
# A PR is owned by the pulse when it carries origin:worker or
# origin:worker-takeover. PRs that are interactive-session work
# (origin:interactive) or external-contributor work (non-bot author,
# no pulse origin label) must never be auto-closed.
#
# Fetches labels + author with fail-CLOSED semantics.
# If the metadata fetch fails, the caller must NOT close the PR.
#
# GH#18285: origin:interactive PRs are maintainer session work — pulse
# must not auto-close them.
# GH#20485: external contributor PRs carry neither origin:worker nor
# origin:interactive — the old guard fell through to close them, which
# destroys contributor work. The fix extends the guard to the full
# "only close PRs the pulse owns" invariant.
#
# t2383 Fix 3: fail CLOSED on metadata fetch failure. Use grep -Fxq
# (exact line match) so labels like "origin:interactive-fork" don't
# false-match "origin:interactive".
#
# Args: $1 = pr_number, $2 = repo_slug
# Returns:
#   0 — caller must return 0 without closing (fetch failed, or PR is
#       protected: origin:interactive or external contributor)
#   1 — safe to proceed with close logic (pulse owns this PR)
# Side effects:
#   Posts _post_rebase_nudge_on_interactive_conflicting for interactive PRs.
#   Posts _post_rebase_nudge_on_contributor_conflicting for contributor PRs.
#######################################
_close_conflicting_pr_check_ownership_guard() {
	local pr_number="$1"
	local repo_slug="$2"

	# Fetch labels + author metadata in one call. Fail CLOSED if the
	# fetch fails — if we can't determine ownership, do nothing.
	local pr_meta meta_fetch_rc
	meta_fetch_rc=0
	pr_meta=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json labels,author 2>/dev/null) || meta_fetch_rc=$?
	if [[ $meta_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _close_conflicting_pr: failed to fetch metadata for PR #${pr_number} in ${repo_slug} (exit ${meta_fetch_rc}) — skipping close to protect potential origin:interactive or contributor PR (t2383, GH#20485)" >>"$LOGFILE"
		return 0
	fi

	local pr_labels
	pr_labels=$(printf '%s' "$pr_meta" | jq -r '.labels[].name' 2>/dev/null) || pr_labels=""

	# Guard 1: origin:interactive — never auto-close maintainer session work.
	# GH#18285 + GH#18650 Fix 4: post a one-time rebase nudge so the
	# maintainer has a visible signal that their CONFLICTING PR needs
	# manual attention.
	if printf '%s\n' "$pr_labels" | grep -Fxq 'origin:interactive'; then
		echo "[pulse-wrapper] Deterministic merge: skipping auto-close of origin:interactive PR #${pr_number} — maintainer session work is never auto-closed" >>"$LOGFILE"
		_post_rebase_nudge_on_interactive_conflicting "$pr_number" "$repo_slug"
		return 0
	fi

	# Guard 2: origin:worker or origin:worker-takeover — pulse owns these
	# PRs; close is safe and correct.
	if printf '%s\n' "$pr_labels" | grep -Fxq 'origin:worker' ||
		printf '%s\n' "$pr_labels" | grep -Fxq 'origin:worker-takeover'; then
		return 1
	fi

	# Guard 3: bot authors (login ends with "[bot]") — no human contributor
	# is losing work. Close is safe.
	local author_login
	author_login=$(printf '%s' "$pr_meta" | jq -r '.author.login // ""' 2>/dev/null) || author_login=""
	if [[ "$author_login" == *'[bot]' ]]; then
		return 1
	fi

	# Guard 4: non-bot author with no pulse origin label — this is an
	# external contributor PR. The pulse never auto-closes work it didn't
	# create. Leave the PR open and post a rebase nudge so the contributor
	# has a visible signal. (GH#20485)
	echo "[pulse-wrapper] Deterministic merge: skipping auto-close of PR #${pr_number} in ${repo_slug} — non-bot author @${author_login} without pulse origin label; contributor work is never auto-closed (GH#20485)" >>"$LOGFILE"
	_post_rebase_nudge_on_contributor_conflicting "$pr_number" "$repo_slug"
	return 0
}

#######################################
# Fast pre-close guard for CONFLICTING PRs that are clearly protected.
#
# Uses the PR object already fetched by the merge pass, before the heavier
# _close_conflicting_pr ownership metadata path. This avoids repeated noisy
# metadata fetches for draft / interactive / contributor PRs that are never
# eligible for auto-close.
#
# Args: $1=pr_number, $2=repo_slug, $3=pr_obj JSON from gh pr list
# Returns:
#   0 — caller must skip close-conflict handling
#   1 — no protected signal found; caller may continue normal conflict flow
#######################################
_close_conflicting_pr_skip_protected_precheck() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_obj="${3:-}"

	local labels_csv=""
	local is_draft="false"
	if [[ -n "$pr_obj" ]]; then
		labels_csv=$(printf '%s' "$pr_obj" \
			| jq -r '[.labels[]?.name] | join(",")' 2>/dev/null) || labels_csv=""
		is_draft=$(printf '%s' "$pr_obj" \
			| jq -r '(.isDraft // false | tostring)' 2>/dev/null) || is_draft="false"
	fi

	if [[ "$is_draft" == "true" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — draft PR is protected before close-conflict metadata fetch (GH#23371)" >>"$LOGFILE"
		return 0
	fi

	case ",${labels_csv}," in
	*,origin:interactive,*)
		echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — origin:interactive PR is protected before close-conflict metadata fetch (GH#23371)" >>"$LOGFILE"
		return 0
		;;
	*,no-auto-dispatch,*)
		echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — no-auto-dispatch PR is protected before close-conflict metadata fetch (GH#23371)" >>"$LOGFILE"
		return 0
		;;
	*,external-contributor,*)
		echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — external-contributor PR is protected before close-conflict metadata fetch (GH#23371)" >>"$LOGFILE"
		return 0
		;;
	esac

	return 1
}

#######################################
# Gate 2 of _close_conflicting_pr: classify whether the work has
# already landed on main.
#
# Uses the task ID extracted from the PR title to search recent
# commits on the default branch, then verifies file overlap before
# concluding the work is a genuine duplicate.
#
# Sets module globals:
#   _CCPR_WORK_ON_MAIN  - "true" or "false"
#   _CCPR_MERGING_PR    - squash-merge PR number (empty when unparseable)
#
# Return codes:
#   0 — classification complete; caller consults _CCPR_WORK_ON_MAIN
#   2 — false-positive detected (task-ID match without file overlap, or
#       file-lookup failure). Rebase nudge already posted; caller must
#       return 0 without closing the PR.
#
# GH#18815: The task-ID grep alone produced a false positive in PR
# #18760 where a planning PR (`plan(t2059, t2060): file follow-ups`)
# was mistaken for an implementation PR. File-overlap verification is
# the guard against that class of error.
#
# Args: $1 = pr_number, $2 = repo_slug, $3 = task_id (may be empty),
#       $4 = linked_issue (may be empty)
#######################################
_close_conflicting_pr_classify_landed() {
	local pr_number="$1"
	local repo_slug="$2"
	local task_id="$3"
	local linked_issue="${4:-}"

	_CCPR_WORK_ON_MAIN="false"
	_CCPR_MERGING_PR=""

	[[ -n "$task_id" ]] || return 0

	_find_task_id_match_on_main "$repo_slug" "$task_id"
	[[ -n "$_CCPR_MATCHING_SHA" ]] || return 0

	# GH#18815: Verify the matching commit and the closing PR share
	# at least one non-planning file. The task-ID grep alone produced
	# false positives when a planning PR (e.g., 'plan(t2060): file
	# follow-ups') was merged before the implementation PR — the
	# regex matched the planning subject and the implementation PR
	# was wrongly auto-closed (PR #18760 incident, 2026-04-14).
	if _verify_pr_overlaps_commit "$pr_number" "$repo_slug" "$_CCPR_MATCHING_SHA"; then
		# Parse trailing "(#NNN)" from the matching commit's
		# subject. Non-squash merges won't have this suffix — that's
		# fine for PR closure, but linked-issue closure requires a
		# concrete superseding PR that verify-issue-close-helper can
		# validate against the issue body.
		_CCPR_MERGING_PR=$(_parse_squash_merge_pr "$_CCPR_MATCHING_SUBJECT") || _CCPR_MERGING_PR=""
		if [[ -n "$linked_issue" && -n "$_CCPR_MERGING_PR" ]]; then
			if ! _verify_superseding_pr_for_issue "$linked_issue" "$_CCPR_MERGING_PR" "$repo_slug"; then
				echo "[pulse-wrapper] Deterministic merge: task ID/file overlap for PR #${pr_number} could not be verified against linked issue #${linked_issue} via merged PR #${_CCPR_MERGING_PR} — routing for conflict repair instead of closing as superseded (GH#23105)" >>"$LOGFILE"
				return 2
			fi
		fi
		_CCPR_WORK_ON_MAIN="true"
		return 0
	fi

	# Task ID matched but file footprints don't overlap, OR file
	# lookup failed (network error, missing API permissions). Fail
	# CLOSED — leave the PR open and post a one-time rebase nudge.
	# Better to leave a stuck PR than to discard real work.
	local matching_pr_for_nudge
	matching_pr_for_nudge=$(_parse_squash_merge_pr "$_CCPR_MATCHING_SUBJECT") || matching_pr_for_nudge=""

	echo "[pulse-wrapper] Deterministic merge: task ID match for ${task_id} in commit ${_CCPR_MATCHING_SHA:0:8} has no implementation file overlap with PR #${pr_number} — false-positive heuristic, leaving PR open for rebase (GH#18815)" >>"$LOGFILE"
	_post_rebase_nudge_on_worker_conflicting "$pr_number" "$repo_slug" "$task_id" "$matching_pr_for_nudge"
	return 2
}

#######################################
# Close the PR with the "work has already landed on main" wording.
# Cites the merging PR via `(via PR #NNN)` when one was parsed from
# the matching commit's squash-merge suffix; otherwise omits the
# parenthetical.
#
# GH#17642: Does NOT close the linked issue — closing a conflicting
# PR is safe (PRs are cheap), but closing the ISSUE based on a commit
# search has too many false positives. The issue stays open for
# re-dispatch with a fresh branch.
#
# Args: $1 = pr_number, $2 = repo_slug, $3 = pr_title, $4 = task_id,
#       $5 = merging_pr (may be empty), $6 = linked_issue (may be empty),
#       $7 = pr_labels_csv
#######################################
_close_conflicting_pr_comment_landed() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title="$3"
	local task_id="$4"
	local merging_pr="$5"
	local linked_issue="${6:-}"
	local pr_labels_csv="${7:-}"

	local branch_refs
	local _head_branch
	local base_branch
	branch_refs=$(_get_pr_branch_refs_for_conflict_comment "$pr_number" "$repo_slug")
	IFS=$'\t' read -r _head_branch base_branch <<<"$branch_refs"
	[[ -n "$base_branch" ]] || base_branch="$_PULSE_MERGE_CONFLICT_DEFAULT_BASE_BRANCH"

	local landed_via=""
	if [[ -n "$merging_pr" ]]; then
		landed_via=" (via PR #${merging_pr})"
	fi
	if gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "Closing — this PR has merge conflicts with the base branch. The work for this task (\`${task_id}\`) has already landed on ${base_branch}${landed_via}, so no re-attempt is needed.

_Closed by deterministic merge pass (pulse-wrapper.sh, GH#17574)._" 2>/dev/null; then
		if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
			_pulse_merge_invalidate_pr_list_cache "$repo_slug" "closed conflicting PR #${pr_number}"
		fi
	fi

	# GH#17642: Do NOT auto-close the linked issue. Closing a
	# conflicting PR is safe (PRs are cheap), but closing the ISSUE
	# based on a commit search has too many false positives. The
	# issue is now closed only when GH#23105 verification proves the
	# merged PR overlaps files cited by the linked issue.
	_close_superseded_duplicate_issue_if_verified \
		"$pr_number" "$repo_slug" "$linked_issue" "$merging_pr" "$pr_labels_csv"

	echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title} (work already on ${base_branch})" >>"$LOGFILE"
	return 0
}

#######################################
# Carry the PR diff forward to the linked issue body (t2118) and
# close the PR with the "re-attempt with a fresh branch" wording.
#
# Fail-open: the carry-forward call is best-effort. The close still
# proceeds even if the diff append fails.
#
# Args: $1 = pr_number, $2 = repo_slug, $3 = pr_title
#######################################
_close_conflicting_pr_comment_not_landed() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title="$3"

	# Work NOT on main — carry forward the diff to the linked issue
	# so the next worker can rebase/cherry-pick instead of
	# re-deriving from scratch (t2118). Fail-open: any failure is
	# logged and the close still proceeds.
	local linked_issue_for_diff
	linked_issue_for_diff=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue_for_diff=""
	if [[ -n "$linked_issue_for_diff" && "$linked_issue_for_diff" =~ ^[0-9]+$ ]]; then
		_carry_forward_pr_diff "$pr_number" "$repo_slug" "$linked_issue_for_diff" || true
	fi

	# Use standard message but without the misleading
	# "remains open for re-attempt" phrasing (GH#17574).
	if gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "Closing — this PR has merge conflicts with the base branch. If the linked issue is still open, a worker will be dispatched to re-attempt with a fresh branch.

_Closed by deterministic merge pass (pulse-wrapper.sh)._" 2>/dev/null; then
		if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
			_pulse_merge_invalidate_pr_list_cache "$repo_slug" "closed conflicting PR #${pr_number}"
		fi
	fi

	echo "[pulse-wrapper] Deterministic merge: closed conflicting PR #${pr_number} in ${repo_slug}: ${pr_title}" >>"$LOGFILE"
	return 0
}

#######################################
# Close a conflicting PR with audit comment.
#
# GH#17574: Before saying "remains open for re-attempt", check if
# the work has already landed on main (via the linked issue's task
# ID in recent commits). If yes, close the PR with a message
# referencing the audit trail.
#
# GH#18815: The task-ID grep alone produced a false positive in PR
# #18760, where a planning PR (`plan(t2059, t2060): file
# follow-ups`) was mistaken for an implementation PR. The fix
# requires file overlap between the closing PR and the matching
# commit before claiming the work landed. On overlap miss or
# lookup failure, the PR is left open and a one-time rebase nudge
# is posted.
#
# GH#20485: External contributor PRs (non-bot author, no pulse origin
# label) are now protected by the ownership guard (Gate 1). The pulse
# must not auto-close work it didn't create.
#
# t2438 / GH#20060: decomposed into helpers to keep this function
# under the 100-line function-complexity threshold. The orchestrator
# below is a thin driver — each gate is its own helper so the
# control flow reads top-to-bottom without nested conditionals.
#
# Args: $1=PR number, $2=repo slug, $3=PR title
#######################################
_close_conflicting_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title="$3"

	# Gate 1: ownership protection — only auto-close PRs the pulse owns.
	# Protects: origin:interactive (maintainer session work),
	#           non-bot PRs without origin:worker (external contributors).
	# Returns 0 (action taken / skipped) means the caller must NOT close.
	# GH#18285, GH#20485
	if _close_conflicting_pr_check_ownership_guard "$pr_number" "$repo_slug"; then
		return 0
	fi

	# Gate 2: classify whether the work has already landed on main.
	# GH#17574 / t2032: Check if the work is already on the default
	# branch. Extract task ID from PR title (e.g., "t153: add dark
	# mode" → "t153") so the classifier can search recent commits
	# with a word-boundary-safe regex.
	local task_id_from_pr
	task_id_from_pr=$(printf '%s' "$pr_title" | grep -oE '^(t[0-9]+|GH#[0-9]+)' | head -1) || task_id_from_pr=""
	local linked_issue_for_supersession
	linked_issue_for_supersession=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue_for_supersession=""

	local classify_rc=0
	_close_conflicting_pr_classify_landed "$pr_number" "$repo_slug" "$task_id_from_pr" "$linked_issue_for_supersession" || classify_rc=$?
	# Return code 2 means a false-positive was detected and the
	# rebase nudge was already posted or supersession could not be
	# verified. Route to a conflict-fix worker when a linked issue is
	# available; otherwise leave the PR open with the nudge.
	if [[ $classify_rc -eq 2 ]]; then
		if [[ -n "$linked_issue_for_supersession" ]]; then
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue_for_supersession" "conflict" "" "$pr_title" || true
		fi
		return 0
	fi

	# Gate 3: close the PR with the wording appropriate to the
	# classified state.
	if [[ "$_CCPR_WORK_ON_MAIN" == "true" ]]; then
		local pr_labels_csv
		pr_labels_csv=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[]?.name] | join(",")') || pr_labels_csv=""
		_close_conflicting_pr_comment_landed \
			"$pr_number" "$repo_slug" "$pr_title" \
			"$task_id_from_pr" "$_CCPR_MERGING_PR" \
			"$linked_issue_for_supersession" "$pr_labels_csv"
	else
		_close_conflicting_pr_comment_not_landed \
			"$pr_number" "$repo_slug" "$pr_title"
	fi
	return 0
}

#######################################
# Carry the diff of a closed-CONFLICTING PR forward to its linked issue
# body so the next dispatched worker can rebase/cherry-pick instead of
# re-deriving the solution from scratch (t2118).
#
# Idempotent: guarded by an HTML comment marker unique to each PR number.
# Size-capped at 20KB — diffs above this are truncated with a note.
# Fail-open: any gh API failure is logged and the function returns 0 so
# the caller (_close_conflicting_pr) always proceeds with the close.
#
# Does NOT fire in the "work on main" path — only called from the
# "work NOT on main" branch.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug  (owner/repo)
#   $3 - linked_issue  (numeric issue number)
#######################################
_carry_forward_pr_diff() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# --- Fetch the PR diff ---
	local diff_content
	diff_content=$(gh pr diff "$pr_number" --repo "$repo_slug" 2>/dev/null) || diff_content=""
	if [[ -z "$diff_content" ]]; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: PR #${pr_number} diff is empty or unavailable — skipping (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Size-cap at 20KB (20480 bytes) ---
	local size_cap=20480
	local truncation_note=""
	if [[ ${#diff_content} -gt $size_cap ]]; then
		diff_content="${diff_content:0:$size_cap}"
		truncation_note="
... (truncated, full diff at PR #${pr_number})"
	fi

	# --- Fetch current issue body ---
	# --- Fetch current issue body (fail-safe: skip on API error to prevent data loss) ---
	local current_body fetch_rc
	fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: failed to fetch issue #${linked_issue} body (exit ${fetch_rc}) — skipping to avoid data loss (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Idempotency guard ---
	# Marker format: <!-- t2118:prior-worker-diff:PR<N> -->
	local marker="<!-- t2118:prior-worker-diff:PR${pr_number} -->"
	if printf '%s' "$current_body" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: issue #${linked_issue} already has diff marker for PR #${pr_number} — skipping (t2118)" >>"$LOGFILE"
		return 0
	fi

	# --- Build the append section ---
	# t2383 Fix 4: compute dynamic fence length. PR diffs can contain triple
	# backticks (markdown/docs changes). A fixed ``` fence would break rendering
	# and corrupt the worker handoff. Scan for the longest backtick run in the
	# diff and use one more than that.
	local fence_len=3
	local longest_run
	longest_run=$(printf '%s' "$diff_content" | grep -oE '\`{3,}' | awk '{ if (length > max) max = length } END { print max+0 }') || longest_run=0
	[[ "$longest_run" =~ ^[0-9]+$ ]] || longest_run=0
	if [[ "$longest_run" -ge "$fence_len" ]]; then
		fence_len=$((longest_run + 1))
	fi
	local fence=""
	local _i
	for (( _i=0; _i<fence_len; _i++ )); do
		fence="${fence}\`"
	done

	local new_section
	new_section="${marker}
## Prior worker attempt (PR #${pr_number}, closed CONFLICTING)

The following diff was produced by the prior worker before the PR was closed
due to merge conflicts. The next worker should review this diff and
rebase/apply it rather than re-deriving the solution from scratch.

<details><summary>Diff from PR #${pr_number} (click to expand)</summary>

${fence}diff
${diff_content}${truncation_note}
${fence}

</details>"

	local new_body
	new_body="${current_body}

${new_section}"

	# Use gh_issue_edit_safe (not bare `gh issue edit`) so the REST fallback
	# in shared-gh-wrappers-safe-edit.sh fires when GraphQL is rate-limited.
	# Bare `gh issue edit` always uses GraphQL and silently fails the body
	# update when the 5000/hr GraphQL budget is exhausted. PR #21733 model.
	if gh_issue_edit_safe "$linked_issue" --repo "$repo_slug" \
		--body "$new_body" >/dev/null 2>&1; then
		echo "[pulse-wrapper] _carry_forward_pr_diff: appended diff from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (t2118)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] _carry_forward_pr_diff: failed to update issue #${linked_issue} body in ${repo_slug} — continuing with close (t2118)" >>"$LOGFILE"
	fi
	return 0
}
