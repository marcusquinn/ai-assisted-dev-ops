#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-triage.sh — Triage dedup + consolidation orchestrator.
#
# Originally extracted from pulse-wrapper.sh in Phase 8 (parent: GH#18356,
# plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# Split into sub-libraries (GH#21146 / GH#21326) to comply with the 1500-line
# file-size-debt threshold. Sub-libraries:
#   - pulse-triage-cache.sh      — content-hash dedup cache, bot-skip, idempotent comment
#   - pulse-triage-evaluation.sh — consolidation/simplification label re-evaluation
#   - pulse-triage-dispatch.sh   — consolidation dispatch, locking, child issue creation
#
# This orchestrator retains:
#   - Module-level defaults
#   - _route_terminal_breaker_to_consolidation
#   - _issue_needs_consolidation (>100 lines — identity key preserved)
#   - _dispatch_issue_consolidation (>100 lines — identity key preserved)
#   - Source calls to the three sub-libraries
#
# Must be sourced from pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.

[[ -n "${_PULSE_TRIAGE_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_LOADED=1

# Defensive SCRIPT_DIR fallback (derived from BASH_SOURCE[0], matches
# the issue-sync-lib.sh pattern per reference/large-file-split.md §2.4).
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Module-level defaults — single source of truth for consolidation gate thresholds.
# := form: env overrides set before sourcing this module still take effect;
# these only apply when the variable is unset. Avoids duplicate-default drift
# between pulse-wrapper.sh and inline guards. Aligns all call sites to the same
# 500-char minimum and threshold=2, eliminating the 200-vs-500 mismatch.
: "${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD:=2}"
: "${ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS:=500}"

# t2151: Cross-runner advisory lock TTL for consolidation dispatch. If a
# `consolidation-in-progress` label stays applied longer than this many hours
# without being naturally released (by successful child creation + release,
# or by release-on-child-close), the backfill pass clears it. Prevents a
# crashed runner from permanently wedging the parent behind a stale lock.
#
# Default 6h: long enough to absorb GitHub API outages, slow runners, and
# operator intervention windows; short enough that a truly stuck lock gets
# cleared within one working day rather than accumulating.
#
# t2151: Grace period after lock acquisition during which a re-check of
# the comment-based tiebreaker is suppressed. The tiebreaker comment is
# posted immediately after the label; a tight re-read racing against the
# caller's own comment would see its own marker plus the competitor's and
# pick a winner before either runner has flushed its child-creation API
# call. 2s is comfortably longer than the single-writer path (label + comment
# + child-create = ~0.3-0.8s in normal conditions) and short enough that
# operator latency is imperceptible.
: "${CONSOLIDATION_LOCK_TTL_HOURS:=6}"
: "${CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC:=2}"

# --- Source sub-libraries ---

# shellcheck source=./pulse-triage-cache.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-triage-cache.sh"

# shellcheck source=./pulse-triage-evaluation.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-triage-evaluation.sh"

# shellcheck source=./pulse-triage-dispatch.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/pulse-triage-dispatch.sh"

# Route exhausted retry breakers through the existing idempotent consolidation
# workflow. This bridge deliberately adds no labels, comments, or child issues
# itself: _dispatch_issue_consolidation owns resolution checks, child dedup,
# cross-runner locking, request creation, and parent notification.
# Args: issue number, repo slug, breaker source, optional diagnostic detail.
_route_terminal_breaker_to_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local breaker_detail="${4:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" && -n "$breaker_source" ]] || return 1
	if ! declare -F _dispatch_issue_consolidation >/dev/null 2>&1; then
		echo "[pulse-wrapper] Terminal breaker consolidation deferred for #${issue_number} in ${repo_slug}: dispatcher unavailable" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-wrapper] Routing terminal breaker to consolidation: #${issue_number} in ${repo_slug} source=${breaker_source} detail=${breaker_detail:-none}" >>"$LOGFILE"
	if ! _dispatch_issue_consolidation "$issue_number" "$repo_slug" ""; then
		echo "[pulse-wrapper] Terminal breaker consolidation failed for #${issue_number} in ${repo_slug} source=${breaker_source}" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Terminal breaker consolidation created or reused for #${issue_number} in ${repo_slug} source=${breaker_source}" >>"$LOGFILE"
	return 0
}

# --- Functions retained in orchestrator (>100 lines, identity key preserved) ---

_issue_needs_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	# t2996: optional pre-fetched issue JSON. When dispatch_with_dedup calls
	# this helper it has already fetched `.labels` (and the rest of the
	# canonical bundle); threading it through saves one gh call per dispatch
	# candidate. When omitted (re-evaluation paths in pulse-triage.sh that
	# may have stale labels), fall back to a fresh fetch so the helper
	# remains self-sufficient.
	local pre_fetched_json="${3:-}"

	local issue_labels
	if [[ -n "$pre_fetched_json" ]] \
		&& printf '%s' "$pre_fetched_json" | jq -e '.labels' >/dev/null 2>&1; then
		issue_labels=$(printf '%s' "$pre_fetched_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
	else
		issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
	fi
	# Skip if consolidation was already done (label removed = consolidated)
	if [[ ",$issue_labels," == *",consolidated,"* ]]; then
		return 1
	fi
	# t1982: Skip if an open consolidation-task child already references this
	# parent. Prevents double-dispatch during the race window between the
	# child being created and _reevaluate_consolidation_labels re-checking.
	if _consolidation_child_exists "$issue_number" "$repo_slug"; then
		return 1
	fi
	# If already labeled, re-evaluate with the current (tighter) filter.
	# If the issue no longer triggers, auto-clear the label so it becomes
	# dispatchable without manual intervention. This handles the case where
	# a filter improvement makes previously-flagged issues pass.
	local was_already_labeled=false
	if [[ ",$issue_labels," == *",needs-consolidation,"* ]]; then
		was_already_labeled=true
	fi

	# t2161: Defence-in-depth — if an open PR already resolves this parent
	# (closing keyword + #N), the work is in flight. Skip consolidation
	# regardless of substantive-comment count. This catches the cascade
	# vector where version drift on a contributor runner re-introduces a
	# stale filter (root cause of GH#19448 → #19469 → #19471). Auto-clear
	# any pre-existing needs-consolidation label so the issue can close
	# cleanly when the PR merges.
	if _consolidation_resolving_pr_exists "$issue_number" "$repo_slug"; then
		[[ "$was_already_labeled" == "true" ]] &&
			_clear_needs_consolidation_label "$issue_number" "$repo_slug" \
				"in-flight resolving PR exists (t2161)"
		return 1
	fi

	# Count substantive comments (>MIN_CHARS, not from bots or dispatch machinery).
	# Only human-authored scope-changing comments should count. Operational
	# comments (dispatch claims, kill notices, crash reports, stale recovery,
	# triage reviews, provenance metadata) are noise — workers generate dozens
	# of these on issues that fail repeatedly, falsely triggering consolidation.
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments_json="[]"

	local substantive_count=0
	# Defaults are set at module level (: "${VAR:=value}" block above).
	# Bare $VAR reference is safe; the module-level block guarantees non-empty.
	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"
	substantive_count=$(printf '%s' "$comments_json" | jq -s --argjson min "$min_chars" '
		add as $comments |
		# Combine all operational-noise patterns into a single regex for efficiency
		# (1 test() invocation per comment instead of 15).
		#
		# t2144: Added ^<!-- WORKER_SUPERSEDED and ^<!-- stale-recovery-tick
		# patterns. Real recovery comment bodies start with these HTML comment
		# markers, then contain "**Stale assignment recovered**" later in the
		# body. The ^(\\*\\*)?Stale... anchor was therefore a no-op — 528-char
		# recovery comments passed the filter, and two of them on any stuck
		# issue falsely tripped the ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2 gate.
		(
			"DISPATCH_CLAIM nonce="
			+ "|^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker"
			+ "|^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)"
			+ "|^<!-- WORKER_SUPERSEDED"
			+ "|^<!-- stale-recovery-tick"
			+ "|^<!-- cost-circuit-breaker:fired"
			+ "|^<!-- triage-escalation"
			+ "|CLAIM_RELEASED reason="
			+ "|^(Worker failed:|## Worker Watchdog Kill)"
			+ "|^(\\*\\*)?Stale assignment recovered"
			+ "|^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Issue Consolidation Dispatched|Additional Review Feedback|Cascade Tier Escalation)"
			+ "|^## Review: Recommendation:"
			+ "|^This quality-debt issue was auto-generated by"
			+ "|<!-- MERGE_SUMMARY -->"
			+ "|^Closing:"
			+ "|^Worker failed: orphan worktree"
			+ "|sudo aidevops approve"
			+ "|^_Automated by"
		) as $patterns |
		[$comments[] | select(
			(.body | length) >= $min
			and .user.type != "Bot"
			and (.body | test($patterns) | not)
		)] | length
	' 2>/dev/null) || substantive_count=0

	if [[ "$substantive_count" -ge "$ISSUE_CONSOLIDATION_COMMENT_THRESHOLD" ]]; then
		return 0
	fi

	# Auto-clear: if the issue was previously labeled but no longer triggers
	# (e.g., filter improvement excluded operational comments that were false
	# positives), remove the label so it becomes dispatchable immediately.
	[[ "$was_already_labeled" == "true" ]] &&
		_clear_needs_consolidation_label "$issue_number" "$repo_slug" \
			"substantive_count=${substantive_count} below threshold=${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD}"
	return 1
}

#######################################
# t1982/t2151: Dispatch a consolidation task for an issue with accumulated
# substantive comments. Creates a self-contained consolidation-task child
# issue that the pulse will pick up on the next cycle. The child's body
# contains the parent's title, body, and substantive comments inline so
# the worker never needs to read the parent.
#
# Idempotent: returns 0 without creating anything if a child already exists
# or if the cross-runner advisory lock is held by another runner.
#
# t2151 cross-runner coordination:
#   Phase A (t2144) closed single-runner cascade vectors. This path adds
#   the cross-runner guard: acquire `consolidation-in-progress` before
#   creating the child, release on any exit path (success or failure).
#   See `_consolidation_lock_acquire` for the full protocol.
#
# Reference pattern: `_issue_targets_large_files` at pulse-dispatch-core.sh:685-757
# which creates file-size-debt child issues the same way.
#######################################
_dispatch_issue_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Ensure labels exist on this repo up front. Idempotent (--force).
	_ensure_consolidation_labels "$repo_slug"

	# t3050: pre-flight skip when parent work already resolved. Fail-open.
	_consolidation_skip_if_resolved "$issue_number" "$repo_slug" && return 0

	# t2161: skip if a resolving PR already exists — defence-in-depth vs
	# cross-runner version drift; cheaper than child_exists, runs first.
	if _consolidation_resolving_pr_exists "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Consolidation: in-flight resolving PR exists for #${issue_number} in ${repo_slug}; skipping dispatch (t2161)" >>"$LOGFILE"
		return 0
	fi

	# Dedup: child already exists (t2151: lock label also returns 0, blocking
	# competing runners before they reach the acquire path).
	if _consolidation_child_exists "$issue_number" "$repo_slug"; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		echo "[pulse-wrapper] Consolidation: child already exists for #${issue_number} in ${repo_slug}; flagged parent and returning" >>"$LOGFILE"
		return 0
	fi

	# t2151: acquire advisory lock before any visible state changes;
	# if we lose, flag the parent and yield.
	if ! _consolidation_lock_acquire "$issue_number" "$repo_slug"; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		echo "[pulse-wrapper] Consolidation: lock held by another runner for #${issue_number} in ${repo_slug}; flagged parent and yielding" >>"$LOGFILE"
		return 0
	fi

	# From this point on, every exit path MUST call _consolidation_lock_release.
	local self_login
	self_login=$(_consolidation_lock_self_login)

	# Fetch parent metadata.
	local parent_title parent_body parent_labels
	parent_title=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json title --jq '.title' 2>/dev/null) || parent_title=""
	parent_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || parent_body=""
	parent_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || parent_labels=""

	# Fetch substantive comments via the shared filter helper.
	local substantive_json
	substantive_json=$(_consolidation_substantive_comments "$issue_number" "$repo_slug")
	[[ -n "$substantive_json" ]] || substantive_json="[]"

	# Build the Contributors cc line (unique, @-prefixed).
	local authors_csv
	authors_csv=$(printf '%s' "$substantive_json" | jq -r '
		[.[] | .login] | unique | map("@" + .) | join(" ")
	' 2>/dev/null) || authors_csv=""

	# Compose the self-contained child body.
	local child_body
	child_body=$(_compose_consolidation_child_body \
		"$issue_number" "$repo_slug" "$parent_title" "$parent_body" \
		"$substantive_json" "$authors_csv" "$parent_labels")

	# File the child issue via a temp body file.
	local child_num
	child_num=$(_create_consolidation_child_issue "$repo_slug" "$issue_number" "$child_body")

	if [[ -z "$child_num" || ! "$child_num" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] ERROR: consolidation child creation FAILED for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		# Still flag parent so it doesn't keep firing every cycle.
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		# t2151: release the lock on failure too — otherwise TTL is the only
		# way it clears, and another runner would be blocked for 6h.
		_consolidation_lock_release "$issue_number" "$repo_slug" "$self_login"
		return 1
	fi

	# Flag parent and post the idempotent pointer comment.
	_post_consolidation_dispatch_comment "$issue_number" "$repo_slug" "$child_num" "$authors_csv"
	# t2749: Signal to apply_dispatch_max that a consolidation child
	# was created this cycle. The sentinel triggers a Phase 2 re-enumeration so
	# the child is dispatched in the same cycle without waiting for the next pulse
	# cycle (3–7 min latency when wrapper cycles are stable; 10–20 min when unstable).
	# Named with $$ (top-level PID) so each pulse run has a unique sentinel file.
	mkdir -p "${HOME}/.aidevops/cache" 2>/dev/null || true
	touch "${HOME}/.aidevops/cache/pulse-cycle-$$-consolidation-fired" 2>/dev/null || true
	# t2151: release the lock — the child now exists on GitHub and
	# `_consolidation_child_exists` will block subsequent dispatches on
	# its own, making the lock unnecessary past this point.
	_consolidation_lock_release "$issue_number" "$repo_slug" "$self_login"
	echo "[pulse-wrapper] Consolidation: flagged #${issue_number} in ${repo_slug}, dispatched child #${child_num}" >>"$LOGFILE"
	return 0
}
