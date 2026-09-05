#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Dispatch Dedup Assignment -- Assignment and orphan dispatch guards
# =============================================================================
# Assignment-state, structural-blocker, and orphan-branch guard functions
# extracted from dispatch-dedup-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/dispatch-dedup-assignment.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_view)
#   - dispatch-dedup-cost.sh
#   - dispatch-dedup-stale.sh
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_DDH_ASSIGNMENT_LOADED:-}" ]] && return 0
_DDH_ASSIGNMENT_LOADED=1

_DDH_BOOL_TRUE="true"
_DDH_BOOL_FALSE="false"

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# shellcheck source=./infrastructure-advisory-lib.sh
# shellcheck disable=SC1091  # sibling library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/infrastructure-advisory-lib.sh"

# --- Functions ---
#######################################
# Get the repo owner from the slug.
# Args: $1 = repo slug (owner/repo)
# Returns: owner login on stdout (empty if invalid)
#######################################
_get_repo_owner() {
	local repo_slug="$1"

	if [[ -z "$repo_slug" || "$repo_slug" != */* ]]; then
		return 0
	fi

	printf '%s' "${repo_slug%%/*}"
	return 0
}

#######################################
# Look up the repo maintainer from repos.json.
# The maintainer is the repo owner/admin — not a runner account.
# Args: $1 = repo slug (owner/repo)
# Returns: maintainer login on stdout (empty if not found)
#######################################
_get_repo_maintainer() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local maintainer=""
	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null) || maintainer=""

	printf '%s' "$maintainer"
	return 0
}

# Stale assignment recovery functions are in dispatch-dedup-stale.sh (GH#18916).

#######################################
# Return "true" if the issue metadata represents an active claim that
# should override the owner/maintainer passive-assignee exemption in
# is_assigned(). An issue is actively claimed when EITHER:
#   - a lifecycle status label is set: status:queued, status:in-progress,
#     status:in-review, or status:claimed, OR
#   - the origin:interactive label is present without auto-dispatch (a live
#     human session is driving the work regardless of status label state), OR
#   - the consolidation-in-progress label is present (t2151 — a cross-
#     runner advisory lock held by a pulse runner that is mid-way through
#     creating a consolidation-task child issue; treat as an active claim
#     so unrelated dispatch paths can't sneak past during the write window)
#
# Extracted from is_assigned() to keep that function under the 100-line
# complexity cap after GH#18352 expanded the active-claim signal set
# (see t1961). Adding new active-state labels is a one-line change here.
#
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient:
#   - Label without assignee = degraded state (safe to reclaim after stale recovery)
#   - Assignee without active label = passive backlog bookkeeping (owner/maintainer
#     passive exemption applies; non-owner/maintainer still blocks)
#   - Label WITH non-self assignee = active claim (always blocks)
#   This function evaluates only the label half. is_assigned() enforces the
#   combined check by calling this only after an assignee is confirmed present.
#
# Args:
#   $1 = issue metadata JSON from `gh issue view --json labels` (at minimum
#        must contain a .labels array of {name: ...} objects)
# Stdout: "true" or "false"
#######################################
_has_active_claim() {
	local issue_meta_json="$1"
	local result
	result=$(printf '%s' "$issue_meta_json" | jq -r '
		.labels? // [] | map(.name) | (any(.[]; . == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed" or . == "consolidation-in-progress") or ((index("origin:interactive") != null) and (index("auto-dispatch") == null)))
	' 2>/dev/null) || result="$_DDH_BOOL_FALSE"
	[[ "$result" == "$_DDH_BOOL_TRUE" || "$result" == "$_DDH_BOOL_FALSE" ]] || result="$_DDH_BOOL_FALSE"
	printf '%s' "$result"
	return 0
}

#######################################
# Check if a GitHub issue is already assigned to another runner.
#
# This is the primary cross-machine dedup guard. Process-based checks
# (is_duplicate, has_worker_for_repo_issue) only see local processes —
# they miss workers running on other machines. The GitHub assignee is
# the single source of truth visible to all runners.
#
# Owner/maintainer assignment carries two different meanings:
#   1. passive backlog ownership / maintainer review bookkeeping
#   2. active worker claim (when paired with status:queued/in-progress)
#
# Treating all owner/maintainer assignees as active claims created a queue
# starvation bug: the pulse discovers unassigned issues by default, while
# several tooling pipelines auto-assigned newly created debt issues to the
# maintainer. The result was hundreds of open issues that looked "claimed"
# to the deterministic guard but had no worker, no queued state, and no PR.
#
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient.
#   See _has_active_claim() for the label-half definition.
#   This function enforces the combined check: it first checks whether an
#   assignee is present; if so, it calls _has_active_claim() to determine
#   if the passive exemption for owner/maintainer should be bypassed.
#
# Systemic rule:
# - self_login never blocks
# - owner/maintainer assignees are passive unless EITHER:
#     (a) the issue has an active claim status label — status:queued,
#         status:in-progress, status:in-review, or status:claimed
#         (full active lifecycle, not just the worker-set states), OR
#     (b) the issue has the origin:interactive label without auto-dispatch —
#         a human session is actively driving the work regardless of status
#         label state
#         (GH#18352 — closes the race where an interactive claim used
#         status:claimed, which was not recognised as an active state,
#         so the pulse dispatched a duplicate worker mid-flight)
# - auto-dispatch is an explicit handoff signal: origin:interactive remains
#   provenance but no longer bypasses owner/maintainer passive assignment.
# - any other assignee blocks dispatch — UNLESS the assignment is stale
#   (no active worker, dispatch claim >1h old, no recent progress).
#   Stale assignments are auto-recovered (GH#15060).
#
# Every dispatch decision site that emits a worker assignment MUST route
# through this function (or apply an equivalent inline combined check)
# before claiming. Any code path that checks only labels or only assignees
# is not safe in multi-operator conditions. (t1996 — audit confirmed that
# dispatch_with_dedup, apply_dispatch_max, and all implementation
# dispatch paths correctly route through check_dispatch_dedup which calls
# this function at Layer 6; normalize_active_issue_assignments was hardened
# in the same fix to also call this before self-assigning orphaned issues.)
#
# This preserves GH#10521 (maintainer assignment alone must not starve the
# queue) while still protecting GH#11141 (owner-assigned queued work must
# block other runners once a real claim is active) and GH#18352 (interactive
# sessions working on owner-assigned issues must not be raced by the pulse).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = (optional) current runner login — if assigned to self, not a dup
# Returns:
#   exit 0 if assigned to another login (do NOT dispatch), parent-task labeled,
#          no-auto-dispatch labeled, cost-budget exceeded, or guard cannot
#          determine safety (GUARD_UNCERTAIN)
#   exit 1 if unassigned or assigned only to self (safe to dispatch)
# Outputs: one of the following signals on stdout when blocking:
#   PARENT_TASK_BLOCKED (label=<name>)      — unconditional parent-task / meta block
#   PUBLICATION_PENDING_BLOCKED (label=...) — canonical planning publication has not landed
#   NO_AUTO_DISPATCH_BLOCKED (label=...)    — unconditional no-auto-dispatch block (t2832)
#   INFRASTRUCTURE_BLOCKED (label=...)      — infrastructure / billing / runner advisory block
#   COST_BUDGET_EXCEEDED (...)              — token spend circuit breaker
#   GUARD_UNCERTAIN (reason=...)            — internal error, cannot determine safety
#   <assignee info>                         — active claim by another runner
#
# FAIL-CLOSED CONTRACT (t2046):
#   When the guard cannot determine whether dispatch is safe due to an internal
#   error (gh API failure, jq error, helper failure), the function MUST block
#   dispatch and emit GUARD_UNCERTAIN. This is intentionally conservative:
#   a transient block clears in the next pulse cycle at zero cost; a wasted
#   worker dispatch burns ~20K tokens for zero output (GH#18458 incident).
#   The previous default (fail-open) allowed three workers to be dispatched
#   to a parent-task issue because a jq null-handling bug silently fell through
#   to the "allow dispatch" code path (see plan in todo/plans/parent-task-incident-hardening.md).
#######################################
#######################################
# is_assigned helper: check the parent-task / meta unconditional block.
#
# t1986: parent-task / meta label is an unconditional dispatch block.
# Any issue tagged as parent-only is plan-only work and must never
# receive a dispatched worker, regardless of assignees or status
# labels. Closes the dispatch loop observed on GH#18356 during
# t1962 Phase 3 (parent task dispatched twice with opus-4-6,
# burning ~20K tokens for zero productive output) and the
# same race reproduced on GH#18399 / GH#18400 while filing the
# follow-up issues for this very fix.
#
# Emits PARENT_TASK_BLOCKED on stdout for caller pattern matching
# (mirrors the STALE_RECOVERED token used by stale-recovery path).
#
# t2061: explicit jq failure capture — fail-closed. A jq failure here
# (type error, compile error, malformed labels field) would previously
# fall through to "no parent-task label found" via the || true pattern,
# silently skipping the unconditional dispatch block. Now emits
# GUARD_UNCERTAIN on any internal jq failure.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if parent-task label found or jq fails (prints signal),
#          exit 1 if no parent-task label and jq succeeds
#######################################
_is_assigned_check_parent_task() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	# t2061: explicit rc capture — fail-closed on jq failure.
	local _jq_rc=0
	local parent_task_hit
	parent_task_hit=$(printf '%s' "$meta_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' 2>/dev/null | head -n 1) || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=parent-task-check issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$parent_task_hit" ]]; then
		printf 'PARENT_TASK_BLOCKED (label=%s)\n' "$parent_task_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: block issues whose canonical planning publication has not
# landed on the default branch. The label is applied before an issue can exist
# ahead of its TODO.md row/brief and is removed only by exact-SHA reconciliation.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if publication:pending is present or jq fails (prints signal),
#          exit 1 if the label is absent and jq succeeds
#######################################
_is_assigned_check_publication_pending() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"publication:pending" "PUBLICATION_PENDING_BLOCKED" "publication-pending-check"
}

#######################################
# is_assigned helper: check an unconditional label block.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = issue number for traceable error output
#   $3 = repo slug for traceable error output
#   $4 = label name to check
#   $5 = block signal to emit when label is present
#   $6 = check name for GUARD_UNCERTAIN output
# Returns: exit 0 if label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_label_block() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	local label_name="$4"
	local block_signal="$5"
	local check_name="$6"
	local _jq_rc=0
	local label_hit
	label_hit=$(printf '%s' "$meta_json" |
		jq -r --arg label_name "$label_name" '(.labels // [])[].name | select(. == $label_name)' 2>/dev/null | head -n 1) || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=%s issue=%s repo=%s)\n' \
			"$check_name" "$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$label_hit" ]]; then
		printf '%s (label=%s)\n' "$block_signal" "$label_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: check the no-auto-dispatch unconditional block (t2832).
#
# t2832: no-auto-dispatch label is an unconditional dispatch block. The label
# was previously honoured by enrichment, decomposition, and backfill paths but
# NOT by the dispatch path itself — workers got dispatched to issues carrying
# the label, contradicting maintainer intent and the documented behaviour.
# Closes the dispatch hole observed on GH#20827 (t2821 policy issue): six
# worker dispatches over two hours despite the label being applied at issue
# creation, all failing in the dispatch-path tautology, ~30-50K opus tokens
# burned. The label now carries the same hard-block semantics as parent-task.
#
# Use cases this enables (post-fix):
#   - Maintainer-applied "do not auto-dispatch" hold without needing #parent
#     (which forces decomposition lifecycle on focused fixes that don't decompose)
#   - interactive-session-helper.sh lockdown — already applies this label;
#     the label now actually blocks dispatch end-to-end as documented
#   - Policy-level dispatch-path tasks (t2821) — sufficient as a focused-fix
#     blocker without combining with #parent
#
# Emits NO_AUTO_DISPATCH_BLOCKED on stdout for caller pattern matching
# (mirrors the PARENT_TASK_BLOCKED token used by parent-task check).
#
# Mirrors _is_assigned_check_parent_task structure:
#   - Same jq-failure fail-closed contract (t2061): GUARD_UNCERTAIN on jq error
#   - Same return-code contract: 0 = block (with signal printed), 1 = allow
#   - Same args shape for traceable error output
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if no-auto-dispatch label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_no_auto_dispatch() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"no-auto-dispatch" "NO_AUTO_DISPATCH_BLOCKED" "no-auto-dispatch-check"
}

_is_assigned_check_maintainer_permissions() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	#aidevops:trust-boundary -- only the request-specific signed grant flow may
	# clear this unconditional worker-dispatch hold.
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"needs-maintainer-permissions" "MAINTAINER_PERMISSIONS_BLOCKED" "maintainer-permissions-check"
}

#######################################
# is_assigned helper: check the infrastructure advisory block.
#
# CI failure-miner infrastructure advisories must remain visible for human
# operations rather than consume worker dispatch capacity. The generic
# infrastructure label alone describes valid code work in some repositories.
# Candidate enumeration and this race-window guard source one jq predicate.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if the advisory label pair is found or jq fails (prints signal),
#          exit 1 if the advisory label pair is absent and jq succeeds
#######################################
_is_assigned_check_infrastructure() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	local infrastructure_advisory_jq="" advisory_hit="" jq_rc=0

	infrastructure_advisory_jq=$(infrastructure_advisory_jq_definition) || jq_rc=$?
	if [[ "$jq_rc" -eq 0 ]]; then
		advisory_hit=$(printf '%s' "$meta_json" | jq -r "
			${infrastructure_advisory_jq}
			if ((.labels // []) | aidevops_infrastructure_advisory)
			then \"source:ci-failure-miner\" else empty end
		" 2>/dev/null) || jq_rc=$?
	fi
	if [[ "$jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=infrastructure-advisory-check issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$advisory_hit" ]]; then
		printf 'INFRASTRUCTURE_BLOCKED (label=infrastructure source=%s)\n' "$advisory_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: check the hold-for-review unconditional block.
#
# Maintainers use `hold-for-review` to pause automation while they inspect an
# issue or PR. PR auto-merge paths already honour the label; the issue dispatch
# path must treat it as a hard dispatch block too, without overloading
# `needs-maintainer-review` (which is the non-maintainer trust gate).
#
# Mirrors _is_assigned_check_no_auto_dispatch structure:
#   - Same jq-failure fail-closed contract: GUARD_UNCERTAIN on jq error
#   - Same return-code contract: 0 = block (with signal printed), 1 = allow
#   - Same args shape for traceable error output
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if hold-for-review label found or jq fails (prints signal),
#          exit 1 if label absent and jq succeeds
#######################################
_is_assigned_check_hold_for_review() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	_is_assigned_check_label_block "$meta_json" "$issue_number" "$repo_slug" \
		"hold-for-review" "HOLD_FOR_REVIEW_BLOCKED" "hold-for-review-check"
}

#######################################
# t3197: is_assigned helper — per-issue dispatch cooldown after launch failure.
#
# When `recover_failed_launch_state` records a `no_worker_process` failure,
# `_post_launch_cooldown_marker` (in pulse-cleanup.sh) writes an audit
# comment containing the marker:
#   <!-- dispatch-cooldown-until:<ISO8601-UTC> reason=no_worker_process runner=<login> -->
#
# This check fetches the issue's comments, authenticates an exact cooldown
# marker, and short-circuits dispatch with `DISPATCH_COOLDOWN_ACTIVE`.
# Closes the rapid-retry loop where a broken runtime burns ~5 worker
# spawns over 3-4 hours per issue with 95-99s lifespans each, repeating
# across many issues simultaneously when one runner is unhealthy.
#
# Complementary to:
#   - t2769 (per-issue 3-stack circuit breaker → status:blocked + meta-repair)
#   - t2897 (per-runner health breaker, 10 events / 6h → runner pause)
# This guard is per-issue and short (default 30 min), so it absorbs
# transient runner failures before the longer-horizon breakers fire.
#
# Gating:
#   - Skipped entirely when DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS=0
#     (saves one gh API call per dispatch decision when the feature is off).
#   - A marker is accepted only from an OWNER, MEMBER, or COLLABORATOR comment
#     whose nonempty authenticated `user.login` exactly matches `runner=`.
#   - The GitHub server `created_at` bounds marker lifetime: it cannot be in
#     the future, older than the configured cooldown, or claim an `until`
#     later than `created_at + cooldown`. This prevents a forged or stale
#     future timestamp from permanently poisoning dispatch.
#   - Fail-open on gh API or jq error — cooldown is an optimization, not a
#     security gate, so a flaky API call should not permanently block
#     dispatch the way GUARD_UNCERTAIN does for label/assignee checks.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if active cooldown found (prints DISPATCH_COOLDOWN_ACTIVE),
#          exit 1 if no cooldown / expired / fetch failure / parse failure
#######################################
_is_assigned_check_dispatch_cooldown() {
	local issue_number="$1"
	local repo_slug="$2"

	# Feature gate. 0 disables; any other non-numeric falls back to default.
	local cooldown_s="${DISPATCH_COOLDOWN_AFTER_LAUNCH_FAILURE_SECONDS:-1800}"
	[[ "$cooldown_s" =~ ^[0-9]+$ ]] || cooldown_s=1800
	[[ "$cooldown_s" -gt 0 ]] || return 1

	# Fetch comments across every page. Marker selection below explicitly orders
	# numeric GitHub comment IDs, rather than relying on endpoint page ordering.
	# Fail-open on API error — cooldown is an optimisation, not a guarantee.
	local comments_endpoint
	comments_endpoint=$(printf 'repos/%s/issues/%s/comments?per_page=100' "$repo_slug" "$issue_number")
	local comments_json
	comments_json=$(gh api --paginate --slurp "$comments_endpoint" 2>/dev/null) || return 1
	[[ -n "$comments_json" ]] || return 1

	local now_epoch
	now_epoch=$(date -u +%s 2>/dev/null) || return 1
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 1

	# Only exact marker lines from authenticated repository participants qualify.
	# Select candidates by numeric ID so equal-second server timestamps still have
	# deterministic newest-first precedence across paginated API responses.
	local _jq_rc=0
	local marker_rows
	marker_rows=$(printf '%s' "$comments_json" |
		jq -r '
			[.[][]
			| select((.id | type) == "number")
			#aidevops:trust-boundary
			| select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
			| . as $comment
			| (($comment.body // "") | capture("(?:^|\\n)<!-- dispatch-cooldown-until:(?<until>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z) reason=no_worker_process runner=(?<runner>[A-Za-z0-9][A-Za-z0-9-]{0,38}) -->(?:\\r?\\n|$)")?) as $marker
			| select($marker != null)
			| select(($comment.user.login? // "") | type == "string" and length > 0)
			| select($comment.user.login == $marker.runner)
			| select(($comment.created_at? // "") | type == "string" and length > 0)
			| {id: .id, until: $marker.until, created_at: $comment.created_at}
			]
			| sort_by(.id) | reverse[] | [.until, .created_at] | @tsv
		') || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		return 1
	fi
	[[ -n "$marker_rows" ]] || return 1

	local marker_iso="" created_at="" until_epoch="" created_epoch="" max_until_epoch=""
	while IFS=$'\t' read -r marker_iso created_at; do
		# Parse the exact UTC format enforced above. GNU date first, BSD fallback.
		until_epoch=$(date -u -d "$marker_iso" +%s 2>/dev/null) ||
			until_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$marker_iso" +%s 2>/dev/null) ||
			continue
		created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null) ||
			created_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" +%s 2>/dev/null) ||
			continue
		[[ "$until_epoch" =~ ^[0-9]+$ && "$created_epoch" =~ ^[0-9]+$ ]] || continue

		# A server-dated marker has at most one configured cooldown interval.
		[[ "$created_epoch" -le "$now_epoch" ]] || continue
		[[ $((now_epoch - created_epoch)) -le "$cooldown_s" ]] || continue
		max_until_epoch=$((created_epoch + cooldown_s))
		[[ "$until_epoch" -le "$max_until_epoch" && "$until_epoch" -gt "$now_epoch" ]] || continue

		printf 'DISPATCH_COOLDOWN_ACTIVE (until=%s reason=no_worker_process)\n' "$marker_iso"
		return 0
	done <<<"$marker_rows"
	return 1
}

#######################################
# Fetch paginated issue comments for orphan-branch checks.
#
# Args: $1 = issue number, $2 = repo slug
# Outputs: JSON from `gh api --paginate --slurp`
# Returns: gh api exit status
#######################################
_ddh_fetch_issue_comments() {
	local issue_number="$1"
	local repo_slug="$2"
	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_endpoint="${comments_post_endpoint}?per_page=100"

	gh api --paginate --slurp "$comments_endpoint" 2>/dev/null
	return $?
}

#######################################
# Count orphan markers matching an exact branch marker prefix.
#
# Args: $1 = comments JSON, $2 = marker prefix
# Outputs: numeric count
# Returns: 0 always (parse failures output 0)
#######################################
_ddh_count_orphan_marker_prefix() {
	local comments_json="$1"
	local orphan_marker_prefix="$2"
	local orphan_marker_count="0"

	orphan_marker_count=$(printf '%s' "$comments_json" |
		jq -r --arg marker "$orphan_marker_prefix" '
			[.[][]
			| (.body // "")
			| select(contains($marker))] | length
		' 2>/dev/null) || orphan_marker_count="0"
	[[ "$orphan_marker_count" =~ ^[0-9]+$ ]] || orphan_marker_count=0
	printf '%s' "$orphan_marker_count"
	return 0
}

#######################################
# Hold an orphan branch when recovery evidence is not actionable.
#
# Args: $1 issue, $2 repo, $3 branch, $4 worktree path, $5 base branch,
#       $6 comments endpoint, $7 comments JSON
# Returns: 0 if dispatch was held, 1 otherwise
#######################################
_ddh_hold_unrecoverable_orphan_branch_if_needed() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local worktree_path="$4"
	local pr_base_branch="$5"
	local comments_post_endpoint="$6"
	local comments_json="$7"
	local branch_state="" state_repo="" remote_probe="" remote_exists="" commit_count=""

	[[ -n "$worktree_path" ]] || return 1
	branch_state=$(_ddh_probe_orphan_branch_state "$repo_slug" "$branch_name" "$worktree_path" "$pr_base_branch")
	IFS='|' read -r state_repo remote_probe remote_exists commit_count <<<"$branch_state"
	: "${state_repo}"

	if [[ "$remote_exists" == "no" ]]; then
		_ddh_hold_unrecoverable_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"remote_branch_missing" "$remote_probe" "$remote_exists" "$commit_count" \
			"$comments_post_endpoint" "$comments_json"
		return 0
	fi
	if [[ "$commit_count" == "0" ]]; then
		if _ddh_auto_recover_zero_commit_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"$remote_probe" "$commit_count" "$comments_post_endpoint" "$comments_json"; then
			return 0
		fi
		_ddh_hold_unrecoverable_orphan_branch "$issue_number" "$repo_slug" "$branch_name" \
			"zero_commits" "$remote_probe" "$remote_exists" "$commit_count" \
			"$comments_post_endpoint" "$comments_json"
		return 0
	fi
	return 1
}

#######################################
# Count recent orphan markers and return the latest timestamp seen.
#
# Args: $1 = comments JSON, $2 = marker prefix, $3 = window seconds
# Outputs: count|latest_iso
# Returns: 0 on parse success, 1 on date/jq failure
#######################################
_ddh_recent_orphan_marker_summary() {
	local comments_json="$1"
	local orphan_marker_prefix="$2"
	local window_s="$3"
	local now_epoch="" marker_list="" count=0 latest_iso="" marker_iso=""

	now_epoch=$(date -u +%s 2>/dev/null) || return 1
	marker_list=$(printf '%s' "$comments_json" |
		jq -r --arg marker "$orphan_marker_prefix" '
			.[][]
			| (.body // "")
			| select(contains($marker))
			| (capture("WORKER_BRANCH_ORPHAN branch=[^ ]+ session=[^ ]+ ts=(?<ts>[^\\n ]+)")? // {})
			| .ts // empty
		' 2>/dev/null) || return 1

	while IFS= read -r marker_iso; do
		[[ -n "$marker_iso" ]] || continue
		local marker_epoch=""
		marker_epoch=$(date -u -d "$marker_iso" +%s 2>/dev/null) ||
			marker_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$marker_iso" +%s 2>/dev/null) ||
			continue
		[[ "$marker_epoch" =~ ^[0-9]+$ ]] || continue
		if [[ $((now_epoch - marker_epoch)) -le "$window_s" ]]; then
			count=$((count + 1))
			latest_iso="$marker_iso"
		fi
	done <<<"$marker_list"

	printf '%s|%s\n' "$count" "$latest_iso"
	return 0
}

#######################################
# Count existing orphan-loop diagnostic blocks for a branch.
#
# Args: $1 = comments JSON, $2 = branch name
# Outputs: numeric count
# Returns: 0 always (parse failures output 0)
#######################################
_ddh_count_orphan_loop_blocks() {
	local comments_json="$1"
	local branch_name="$2"
	local existing_block="0"

	existing_block=$(printf '%s' "$comments_json" |
		jq -r --arg branch "$branch_name" '
			[.[][] | (.body // "") | select(contains("worker-branch-orphan-loop:blocked branch=" + $branch + " "))] | length
		' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0
	printf '%s' "$existing_block"
	return 0
}

#######################################
# Resolve a human PR hint for an orphan branch.
#
# Args: $1 = repo slug, $2 = branch name
# Outputs: PR hint string
# Returns: 0 always
#######################################
_ddh_orphan_branch_pr_hint() {
	local repo_slug="$1"
	local branch_name="$2"
	local pr_line=""

	pr_line=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state all \
		--json number,state,url --jq '.[0] | select(.number != null) | "#\(.number) (\(.state)) \(.url)"' 2>/dev/null || true)
	if [[ -n "$pr_line" ]]; then
		printf '%s' "$pr_line"
		return 0
	fi
	printf '%s' "$_DDH_ORPHAN_PR_HINT_NONE"
	return 0
}

#######################################
# Post the repeated-orphan-loop diagnostic comment.
#
# Args: $1 issue, $2 repo, $3 branch, $4 count, $5 window seconds,
#       $6 latest ISO, $7 PR hint, $8 next action, $9 base branch,
#       $10 comments endpoint
# Returns: 0 always
#######################################
_ddh_post_orphan_loop_diagnostic() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local count="$4"
	local window_s="$5"
	local latest_iso="$6"
	local pr_hint="$7"
	local next_action="$8"
	local pr_base_branch="$9"
	local comments_post_endpoint="${10}"
	local diag=""

	# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
	diag=$(printf '<!-- ops:start -->\n<!-- worker-branch-orphan-loop:blocked branch=%s issue=%s count=%s window_s=%s -->\n## Dispatch held: repeated worker_branch_orphan\n\nThe dispatch path has seen `%s` `WORKER_BRANCH_ORPHAN` outcomes for issue #%s on branch `%s` within the last %s seconds. Dispatch is held for this same branch to avoid burning more worker attempts while preserving evidence.\n\n- Branch: `%s`\n- Latest orphan marker: `%s`\n- PR for branch: %s\n- Next action: %s\n- Next verification: `gh pr list --repo %s --head %s --state all --json number,state,url`\n\nIf no PR exists and the branch has commits, open the recovery PR against `%s`. If no commits exist to PR, remove/reset that worktree/branch so a fresh branch can dispatch.\n<!-- ops:end -->' \
		"$branch_name" "$issue_number" "$count" "$window_s" \
		"$count" "$issue_number" "$branch_name" "$window_s" \
		"$branch_name" "${latest_iso:-unknown}" "$pr_hint" "$next_action" "$repo_slug" "$branch_name" "$pr_base_branch")
	gh api "$comments_post_endpoint" \
		--method POST \
		--field body="$diag" \
		>/dev/null 2>&1 || true
	return 0
}

#######################################
# Check repeated worker_branch_orphan outcomes for a single issue+branch.
#
# This is a surgical dispatch-loop fuse for the branch-orphan class. The
# headless runtime posts structured WORKER_BRANCH_ORPHAN comments containing
# branch, session, and timestamp. When the same branch hits the threshold within
# the configured window, the dispatch path holds that branch before spawning yet
# another worker and posts one mentor-quality diagnostic comment for triage.
#
# Gating:
#   WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD  default 3, 0 disables
#   WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S   default 7200 seconds
#
# Fail-open on missing branch, gh/jq/date errors, or malformed comments. This is
# a blast-radius limiter, not a security gate; unrelated dispatch should not be
# starved by telemetry read failures.
#
# Args: $1 = issue number, $2 = repo slug, $3 = branch name,
#       $4 = TODO.md path (optional), $5 = worktree path (optional)
# Returns: exit 0 if loop threshold reached (prints ORPHAN_LOOP_BLOCKED),
#          exit 1 otherwise.
#######################################
check_worker_branch_orphan_loop() {
	local issue_number="$1"
	local repo_slug="$2"
	local branch_name="$3"
	local todo_file="${4:-}"
	local worktree_path="${5:-}"

	[[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$branch_name" != "HEAD" ]] || return 1

	local threshold="${WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD:-3}"
	local window_s="${WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S:-7200}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
	[[ "$window_s" =~ ^[0-9]+$ ]] || window_s=7200
	[[ "$threshold" -gt 0 && "$window_s" -gt 0 ]] || return 1

	if [[ -n "$todo_file" ]] && check_worker_orphan_remote_children "$issue_number" "$repo_slug" "$todo_file"; then
		return 0
	fi

	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_json=""
	comments_json=$(_ddh_fetch_issue_comments "$issue_number" "$repo_slug") || return 1
	[[ -n "$comments_json" ]] || return 1

	local orphan_marker_prefix="WORKER_BRANCH_ORPHAN branch=${branch_name} "
	local orphan_marker_count="0"
	orphan_marker_count=$(_ddh_count_orphan_marker_prefix "$comments_json" "$orphan_marker_prefix")

	local pr_base_branch=""
	pr_base_branch=$(_ddh_resolve_pr_base_branch "$repo_slug")
	if [[ "$orphan_marker_count" -gt 0 ]] && _ddh_hold_unrecoverable_orphan_branch_if_needed \
		"$issue_number" "$repo_slug" "$branch_name" "$worktree_path" "$pr_base_branch" \
		"$comments_post_endpoint" "$comments_json"; then
		return 0
	fi

	local summary="" count="0" latest_iso=""
	summary=$(_ddh_recent_orphan_marker_summary "$comments_json" "$orphan_marker_prefix" "$window_s") || return 1
	IFS='|' read -r count latest_iso <<<"$summary"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	[[ "$count" -ge "$threshold" ]] || return 1

	local existing_block=""
	existing_block=$(_ddh_count_orphan_loop_blocks "$comments_json" "$branch_name")

	local pr_hint="$_DDH_ORPHAN_PR_HINT_NONE"
	pr_hint=$(_ddh_orphan_branch_pr_hint "$repo_slug" "$branch_name")
	local next_action="Open recovery PR: \`gh pr create --repo ${repo_slug} --head ${branch_name} --base ${pr_base_branch}\`" # aidevops-allow: raw-gh-wrapper
	if [[ "$pr_hint" != "$_DDH_ORPHAN_PR_HINT_NONE" ]]; then
		next_action="Link, review, or merge the existing PR for this branch."
	fi

	if [[ "$existing_block" -eq 0 ]]; then
		_ddh_post_orphan_loop_diagnostic "$issue_number" "$repo_slug" "$branch_name" \
			"$count" "$window_s" "$latest_iso" "$pr_hint" "$next_action" \
			"$pr_base_branch" "$comments_post_endpoint"
	fi

	printf 'WORKER_BRANCH_ORPHAN_LOOP_BLOCKED (issue=%s repo=%s branch=%s count=%s threshold=%s window_s=%s latest=%s pr=%s)\n' \
		"$issue_number" "$repo_slug" "$branch_name" "$count" "$threshold" "$window_s" "${latest_iso:-unknown}" "$pr_hint"
	return 0
}

#######################################
# Hold orphan redispatch when remote child issues exist but local TODO lacks them.
#
# This is intentionally conservative: it does not import issue bodies or trust
# remote relationships. It only detects the dangerous retry state from GH#24565
# and posts one quarantine diagnostic so maintainers can reconcile or import the
# canonical child set before a retry allocates replacement task IDs.
#
# Args: $1 = parent issue number, $2 = repo slug, $3 = TODO.md path (optional)
# Returns: exit 0 if remote children require a hold, exit 1 otherwise.
#######################################
check_worker_orphan_remote_children() {
	local issue_number="$1"
	local repo_slug="$2"
	local todo_file="${3:-TODO.md}"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1

	local comments_post_endpoint=""
	comments_post_endpoint=$(_ddh_issue_comments_endpoint "$repo_slug" "$issue_number")
	local comments_endpoint="${comments_post_endpoint}?per_page=100"
	local comments_json=""
	comments_json=$(gh api --paginate --slurp "$comments_endpoint" 2>/dev/null) || return 1
	[[ -n "$comments_json" ]] || return 1

	local orphan_count="0"
	orphan_count=$(printf '%s' "$comments_json" |
		jq -r '[.[][] | (.body // empty) | select(contains("WORKER_BRANCH_ORPHAN"))] | length' 2>/dev/null) || orphan_count="0"
	[[ "$orphan_count" =~ ^[0-9]+$ ]] || orphan_count=0
	[[ "$orphan_count" -gt 0 ]] || return 1

	local children_json=""
	children_json=$(gh issue list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" \
		--json number,title,body,labels --limit 50 2>/dev/null) || return 1
	[[ -n "$children_json" ]] || return 1

	local candidate_rows=""
	candidate_rows=$(printf '%s' "$children_json" |
		jq -r --arg parent "${issue_number}" '
			.[]
			| select((.number | tostring) != $parent)
			| select(((.body // empty) + "\n" + (.title // empty))
				| test("(#|GH#|issue[[:space:]]+#?)" + $parent + "\\b"; "i"))
			| [.number, (.title // empty)] | @tsv
		' 2>/dev/null) || candidate_rows=""
	[[ -n "$candidate_rows" ]] || return 1

	local missing_count=0
	local candidate_count=0
	local missing_lines=""
	local child_number="" child_title=""
	while IFS=$'\t' read -r child_number child_title; do
		[[ "$child_number" =~ ^[0-9]+$ ]] || continue
		candidate_count=$((candidate_count + 1))
		if [[ ! -f "$todo_file" ]] || ! grep -qE "ref:GH#${child_number}([^0-9]|$)" "$todo_file" 2>/dev/null; then
			missing_count=$((missing_count + 1))
			missing_lines="${missing_lines}- #${child_number}: ${child_title}\n"
		fi
	done <<<"$candidate_rows"

	[[ "$candidate_count" -gt 0 && "$missing_count" -gt 0 ]] || return 1

	local existing_block="0"
	existing_block=$(printf '%s' "$comments_json" |
		jq -r '[.[][] | (.body // empty) | select(contains("worker-orphan-remote-children:blocked"))] | length' 2>/dev/null) || existing_block="0"
	[[ "$existing_block" =~ ^[0-9]+$ ]] || existing_block=0

	if [[ "$existing_block" -eq 0 ]]; then
		local diag=""
		# shellcheck disable=SC2016 # Backticks are literal Markdown in this printf template.
		diag=$(printf '<!-- ops:start -->\n<!-- worker-orphan-remote-children:blocked issue=%s missing=%s -->\n## Dispatch held: orphaned remote child issues need reconciliation\n\nThis parent has `WORKER_BRANCH_ORPHAN` telemetry and open child-like issues that reference #%s, but local TODO state does not contain `ref:GH#` entries for every candidate. Auto-dispatch is held to avoid allocating replacement task IDs and creating duplicate children.\n\nMissing local refs detected:\n%s\nNext verification:\n- Run `issue-sync pull` or manually reconcile the canonical child set.\n- Validate blocker relationships before trusting recovered issue bodies.\n- Re-run dispatch only after TODO/brief state exists or the duplicates are closed/quarantined.\n<!-- ops:end -->' \
			"$issue_number" "$missing_count" "$issue_number" "$missing_lines")
		gh api "$comments_post_endpoint" \
			--method POST \
			--field body="$diag" \
			>/dev/null 2>&1 || true
	fi

	printf 'WORKER_BRANCH_ORPHAN_REMOTE_CHILDREN_BLOCKED (issue=%s repo=%s candidates=%s missing_local_refs=%s)\n' \
		"$issue_number" "$repo_slug" "$candidate_count" "$missing_count"
	return 0
}

#######################################
# is_assigned helper: cost-per-issue circuit breaker (t2007).
#
# Aggregate token spend across all worker attempts; if the cumulative total
# exceeds the tier-appropriate budget, apply status:blocked and stop dispatch.
# Fail-open on aggregation errors so unrelated GitHub API
# hiccups don't starve the queue. Closes the cost-runaway hole that t1986
# (parent-task guard) and t2008 (stale-recovery escalation) leave open: an
# issue with a correct tier assignment that workers can never finish
# (loop, hidden blocker, scope).
#
# Args: $1 = issue number, $2 = repo slug, $3 = issue metadata JSON
# Returns: exit 0 if budget tripped (prints signal), exit 1 if under budget
#######################################
_is_assigned_check_cost_budget() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json="$3"

	local _t2007_tier
	_t2007_tier=$(printf '%s' "$meta_json" |
		jq -r '[(.labels // [])[].name] | map(select(. != null and startswith("tier:"))) | .[0] // "tier:standard"' 2>/dev/null)
	[[ -z "$_t2007_tier" || "$_t2007_tier" == "null" ]] && _t2007_tier="tier:standard"

	local _t2007_signal _t2007_rc=0
	_t2007_signal=$(_check_cost_budget "$issue_number" "$repo_slug" "$_t2007_tier" "$meta_json") || _t2007_rc=$?
	if [[ "$_t2007_rc" -eq 0 ]]; then
		printf '%s\n' "$_t2007_signal"
		return 0
	fi
	return 1
}

#######################################
# t2436: is_assigned helper — hydration window grace period (Approach B).
#
# Labels applied by the asynchronous issue-sync workflow (issue-sync.yml)
# may not yet be present on an issue that was just created. The window
# between issue creation and the subsequent TODO.md push + workflow run
# is adversarial in multi-runner fleets: a peer runner can see an issue
# missing parent-task (not yet synced) and dispatch a worker on it.
#
# This check adds a configurable grace period (default 30s) during which
# newly created issues are skipped. It is a secondary safety net — the
# primary fix is applying labels synchronously at creation time (see
# _scan_todo_labels_for_task in claim-task-id.sh and
# _gh_wrapper_derive_todo_labels in shared-gh-wrappers.sh).
#
# Fail-open:
#   - If DISPATCH_HYDRATION_WINDOW_S=0, the check is disabled.
#   - If createdAt is absent from meta_json (pre-fetched JSON may lack it),
#     the check returns 1 (allow dispatch to continue).
#   - If date parsing fails on either platform, fail-open.
#
# Env:
#   DISPATCH_HYDRATION_WINDOW_S  grace period in seconds (default 30, 0=off)
#
# Args: $1 = issue metadata JSON (must include createdAt field)
#        $2 = issue number (for log output)
#        $3 = repo slug (for log output)
# Returns: exit 0 (block) if issue is within grace period + prints signal,
#          exit 1 (allow) if old enough or data unavailable
#######################################
_is_assigned_check_hydration_window() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"

	local window="${DISPATCH_HYDRATION_WINDOW_S:-30}"
	[[ "$window" -le 0 ]] && return 1  # disabled

	local created_at _jq_rc=0
	created_at=$(printf '%s' "$meta_json" | jq -r '.createdAt // ""' 2>/dev/null) || _jq_rc=$?
	# Fail-open: missing or unparseable JSON → allow dispatch
	[[ "$_jq_rc" -ne 0 || -z "$created_at" ]] && return 1

	local now_epoch=0 created_epoch=0
	now_epoch=$(date -u '+%s' 2>/dev/null || echo "0")
	# Support both GNU date (-d) and BSD date (-j -f)
	created_epoch=$(date -u -d "$created_at" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%s' 2>/dev/null || echo "0")

	# Fail-open: cannot parse timestamps
	[[ "$now_epoch" -eq 0 || "$created_epoch" -eq 0 ]] && return 1

	local age_s=$(( now_epoch - created_epoch ))
	if [[ "$age_s" -lt "$window" ]]; then
		printf 'HYDRATION_WINDOW (issue=%s repo=%s age=%ss window=%ss — labels may not be synced yet)\n' \
			"$issue_number" "$repo_slug" "$age_s" "$window"
		return 0  # block dispatch
	fi
	return 1  # old enough — allow normal dispatch checks to continue
}

#######################################
# is_assigned helper: compute the blocking assignees set.
#
# Walks the assignees list and filters out:
#   - self_login when there is NO active claim (passive bookkeeping)
#   - owner/maintainer if no active claim state (GH#18352 / t1961)
#
# Owner/maintainer is passive UNLESS _has_active_claim returned "true".
# See _has_active_claim() for the full rule set.
#
# The self_login exemption is intentionally bypassed when active_claim
# is "true". In a single-user setup the interactive user and the pulse
# runner share the same GitHub login. Without this exception the pulse
# skips the assignee (it looks like self) and ignores origin:interactive,
# dispatching a duplicate worker. The exemption exists to prevent a runner
# from blocking its own re-dispatch on a passively-bookmarked issue — that
# use-case has no active claim label, so the guard is still satisfied.
# (GH#18956 incident root cause — fixed in t2091.)
#
# Args:
#   $1 = assignees (comma-separated login list)
#   $2 = repo_owner
#   $3 = repo_maintainer (may be empty)
#   $4 = active_claim ("true" or other)
#   $5 = self_login (may be empty)
# Output: comma-separated list of blocking assignees on stdout (may be empty)
#######################################
_is_assigned_compute_blocking() {
	local assignees="$1"
	local repo_owner="$2"
	local repo_maintainer="$3"
	local active_claim="$4"
	local self_login="$5"

	local -a assignee_array=()
	local saved_ifs="${IFS:-}"
	IFS=',' read -ra assignee_array <<<"$assignees"
	IFS="$saved_ifs"

	local blocking_assignees=""
	local assignee
	for assignee in "${assignee_array[@]}"; do
		# Self-login is passive UNLESS an active claim exists. When active_claim
		# is "true" (status label OR origin:interactive), the assignment is
		# intentional — skip the self-login exemption so the issue blocks
		# re-dispatch even in single-user setups. (t2091)
		if [[ -n "$self_login" && "$assignee" == "$self_login" && "$active_claim" != "$_DDH_BOOL_TRUE" ]]; then
			continue
		fi

		if [[ "$assignee" == "$repo_owner" || (-n "$repo_maintainer" && "$assignee" == "$repo_maintainer") ]]; then
			# Owner/maintainer is passive UNLESS _has_active_claim returned
			# "true" (GH#18352 / t1961).
			if [[ "$active_claim" != "$_DDH_BOOL_TRUE" ]]; then
				continue
			fi
		fi

		if [[ -n "$blocking_assignees" ]]; then
			blocking_assignees="${blocking_assignees},${assignee}"
		else
			blocking_assignees="$assignee"
		fi
	done
	printf '%s' "$blocking_assignees"
	return 0
}

#######################################
# Load issue metadata for assignment checks.
#
# Args: $1 = issue number, $2 = repo slug, $3 = gh rc output variable name
# Outputs: issue metadata JSON on stdout when available
# Returns: 0 always; caller inspects the named rc variable
#######################################
_is_assigned_load_issue_meta() {
	local issue_number="$1"
	local repo_slug="$2"
	local rc_var="$3"
	local issue_meta_json=""
	local gh_rc=0

	if [[ -n "${ISSUE_META_JSON:-}" ]] \
		&& printf '%s' "$ISSUE_META_JSON" | jq -e '.assignees and .labels' >/dev/null 2>&1; then
		issue_meta_json="$ISSUE_META_JSON"
	else
		# t2436: include createdAt for the hydration window check (Approach B safety net).
		# Existing callers that pass ISSUE_META_JSON without createdAt will skip that
		# check (fail-open), which is correct — the primary fix is label sync at creation.
		issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state,assignees,labels,createdAt 2>/dev/null) || gh_rc=$?
	fi

	printf -v "$rc_var" '%s' "$gh_rc"
	printf '%s' "$issue_meta_json"
	return 0
}

#######################################
# Extract assignees from issue metadata with explicit jq failure handling.
#
# Args: $1 = issue metadata JSON, $2 = issue number, $3 = repo slug
# Outputs: comma-separated assignee logins, or GUARD_UNCERTAIN on jq failure
# Returns: 0 on extracted assignees, 2 on jq failure
#######################################
_is_assigned_extract_assignees() {
	local issue_meta_json="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local jq_rc=0
	local assignees=""

	assignees=$(printf '%s' "$issue_meta_json" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null) || jq_rc=$?
	if [[ "$jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=assignees-extract issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 2
	fi

	printf '%s' "$assignees"
	return 0
}

#######################################
# Read a peer override/quarantine value for an assignee.
#
# Args: $1 = override config path, $2 = assignee login
# Outputs: override value, if configured
# Returns: 0 always
#######################################
_is_assigned_peer_override_value() {
	local override_conf="$1"
	local assignee="$2"
	local upper=""
	local override_val=""

	# Slug normalisation matches pulse-peer-quarantine-helper.sh's
	# _pq_login_to_var: dash/dot/@ → underscore, uppercase.
	upper="$(printf '%s' "$assignee" | tr 'a-z\-.@' 'A-Z___')"
	override_val=$(grep -E "^DISPATCH_OVERRIDE_${upper}=" "$override_conf" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")
	printf '%s' "$override_val"
	return 0
}

#######################################
# Check whether a peer quarantine override is still active.
#
# Args: $1 = override value, $2 = current epoch seconds
# Returns: 0 when quarantine is active, 1 otherwise
#######################################
_is_assigned_peer_quarantine_active() {
	local override_val="$1"
	local now_epoch="$2"
	local q_until=""
	local q_until_epoch=""

	if [[ "$override_val" != peer-quarantine-until=* ]]; then
		return 1
	fi

	q_until="${override_val#peer-quarantine-until=}"
	# BSD date (macOS) first, then GNU date (Linux). Both variants succeed;
	# one returns empty, and the OR keeps going.
	q_until_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$q_until" '+%s' 2>/dev/null || true)
	[[ -z "$q_until_epoch" ]] && q_until_epoch=$(date -u -d "$q_until" '+%s' 2>/dev/null || true)
	[[ -z "$q_until_epoch" ]] && q_until_epoch=0

	if [[ "$q_until_epoch" -gt "$now_epoch" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Append an assignee to a comma-separated list.
#
# Args: $1 = current list, $2 = assignee login
# Outputs: updated comma-separated list
# Returns: 0 always
#######################################
_is_assigned_append_assignee() {
	local current_list="$1"
	local assignee="$2"

	if [[ -n "$current_list" ]]; then
		printf '%s,%s' "$current_list" "$assignee"
	else
		printf '%s' "$assignee"
	fi
	return 0
}

#######################################
# Filter ignored/quarantined peer assignees from the blocking set.
#
# Args: $1 = assignees, $2 = self login
# Outputs: filtered comma-separated assignee logins
# Returns: 0 always
#######################################
_is_assigned_filter_override_assignees() {
	local assignees="$1"
	local self_login="$2"
	local override_conf="${HOME}/.config/aidevops/dispatch-override.conf"
	local filtered_assignees=""
	local saved_ifs="${IFS:-}"
	local -a override_array=()
	local assignee=""
	local override_val=""
	local now_epoch=""

	if [[ ! -f "$override_conf" ]]; then
		printf '%s' "$assignees"
		return 0
	fi

	now_epoch=$(date -u '+%s')
	IFS=',' read -ra override_array <<<"$assignees"
	IFS="$saved_ifs"
	for assignee in "${override_array[@]}"; do
		# Overrides and quarantine are peer-only. The current runner's own
		# assignment remains authoritative so a worker never ignores its own
		# in-flight claim state because its login appears in local override config.
		if [[ -n "$self_login" && "$assignee" == "$self_login" ]]; then
			filtered_assignees=$(_is_assigned_append_assignee "$filtered_assignees" "$assignee")
			continue
		fi

		override_val=$(_is_assigned_peer_override_value "$override_conf" "$assignee")
		[[ "$override_val" == "ignore" ]] && continue
		if _is_assigned_peer_quarantine_active "$override_val" "$now_epoch"; then
			continue
		fi
		filtered_assignees=$(_is_assigned_append_assignee "$filtered_assignees" "$assignee")
	done

	printf '%s' "$filtered_assignees"
	return 0
}

#######################################
# Run assignment guard checks that block before assignee interpretation.
#
# Args: $1 = issue metadata JSON, $2 = issue number, $3 = repo slug
# Returns: 0 when a guard blocked and emitted its signal, 1 otherwise
#######################################
_is_assigned_pre_assignee_guard_blocks() {
	local issue_meta_json="$1"
	local issue_number="$2"
	local repo_slug="$3"

	# Parent-task, pending publication, and no-auto-dispatch are unconditional blocks.
	if _is_assigned_check_parent_task "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_publication_pending "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_no_auto_dispatch "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_maintainer_permissions "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	# Advisory/review/cooldown/cost/hydration gates short-circuit before assignees.
	if _is_assigned_check_infrastructure "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_hold_for_review "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_dispatch_cooldown "$issue_number" "$repo_slug"; then
		return 0
	fi
	if _is_assigned_check_cost_budget "$issue_number" "$repo_slug" "$issue_meta_json"; then
		return 0
	fi
	if _is_assigned_check_hydration_window "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	return 1
}

_is_assigned_impl() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"
	local allow_stale_recovery="${4:-1}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		# Missing args — cannot check, allow dispatch
		return 1
	fi

	# Validate issue number is numeric
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	local issue_meta_json gh_rc=0
	issue_meta_json=$(_is_assigned_load_issue_meta "$issue_number" "$repo_slug" gh_rc)

	# t2046: fail-closed on gh API failure. When we cannot fetch issue metadata
	# (network error, auth failure, rate limit, issue not found), we cannot
	# determine whether dispatch is safe. Block and emit GUARD_UNCERTAIN so the
	# pulse skips this cycle rather than dispatching blindly.
	if [[ "$gh_rc" -ne 0 || -z "$issue_meta_json" ]]; then
		printf 'GUARD_UNCERTAIN (reason=gh-api-failure issue=%s repo=%s rc=%s)\n' \
			"$issue_number" "$repo_slug" "$gh_rc"
		return 0
	fi

	if _is_assigned_pre_assignee_guard_blocks "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	local assignees=""
	if ! assignees=$(_is_assigned_extract_assignees "$issue_meta_json" "$issue_number" "$repo_slug"); then
		printf '%s\n' "$assignees"
		return 0
	fi

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi

	assignees=$(_is_assigned_filter_override_assignees "$assignees" "$self_login")
	if [[ -z "$assignees" ]]; then
		return 1
	fi

	local repo_owner repo_maintainer
	repo_owner=$(_get_repo_owner "$repo_slug")
	repo_maintainer=$(_get_repo_maintainer "$repo_slug")
	# GH#18352 / t1961: owner/maintainer assignees are passive unless
	# _has_active_claim() reports an active lifecycle label (queued,
	# in-progress, in-review, claimed) or origin:interactive is present.
	# See _has_active_claim() above for the full rule set.
	# t2061: explicit helper rc capture — fail-closed.
	# _has_active_claim normalises output to "true"/"false" and always exits 0,
	# but explicit capture documents the contract and protects against future changes.
	local _hac_rc=0
	local active_claim
	active_claim=$(_has_active_claim "$issue_meta_json") || _hac_rc=$?
	if [[ "$_hac_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=helper-failure call=_has_active_claim issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi

	local blocking_assignees
	blocking_assignees=$(_is_assigned_compute_blocking \
		"$assignees" "$repo_owner" "$repo_maintainer" "$active_claim" "$self_login")

	if [[ -z "$blocking_assignees" ]]; then
		# Only passive assignees remain (self and/or owner/maintainer without
		# active claim state) — safe to dispatch.
		return 1
	fi

	# Stale assignment recovery (GH#15060): if the blocking assignee has no
	# active worker process AND the most recent dispatch/claim comment is >1h
	# old AND there's been no progress (no new comments) in the last hour,
	# treat the assignment as abandoned. Unassign the stale user, remove
	# queued/in-progress labels, and allow re-dispatch.
	#
	# Root cause: when a runner goes offline or a worker crashes without
	# cleanup, the issue stays assigned to that runner forever. The dedup
	# guard blocks all other runners from dispatching for it, creating a
	# permanent deadlock where 0 workers run despite available slots and
	# open issues. This was observed in production with 370 issues and 0
	# active workers — 100% dispatch failure rate.
	if [[ "$allow_stale_recovery" == "1" ]] \
		&& _is_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees"; then
		return 1
	fi

	printf 'ASSIGNED: issue #%s in %s is assigned to %s\n' "$issue_number" "$repo_slug" "$blocking_assignees"
	return 0
}

#######################################
# Dispatch assignment guard with stale recovery enabled.
# Args: $1 = issue number, $2 = repo slug, $3 = self login (optional)
# Returns: 0 when blocked, 1 when safe to dispatch
#######################################
is_assigned() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"

	_is_assigned_impl "$issue_number" "$repo_slug" "$self_login" 1
	return $?
}

#######################################
# Read-only assignment guard for inspection-only callers such as enrichment.
# Reuses all fail-closed and active-claim logic but never invokes stale recovery.
# Args: $1 = issue number, $2 = repo slug, $3 = self login (optional)
# Returns: 0 when blocked, 1 when no assignment/guard block exists
#######################################
is_assigned_read_only() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"

	_is_assigned_impl "$issue_number" "$repo_slug" "$self_login" 0
	return $?
}

#######################################
# enumerate_blockers — report ALL structural dispatch blockers for an issue.
#
# Unlike is_assigned() which short-circuits on the first match, this function
# runs every unconditional structural check (parent-task, pending publication,
# no-auto-dispatch, infrastructure, hold-for-review)
# and emits ALL matching signals as newline-separated tokens on stdout.
#
# Intentionally excludes cost-budget, hydration window, and assignee checks —
# those have nuanced interactive UX that the caller handles separately.
# GUARD_UNCERTAIN is emitted when the gh API call fails (fail-closed).
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = self_login (optional, reserved for future extension)
#
# Stdout: newline-separated blocker tokens; empty when no structural blockers.
# Returns:
#   0 — at least one blocker token was emitted
#   1 — no structural blockers found (safe to dispatch for label-based checks)
#
# t2894: used by _check_linked_issue_gate in full-loop-helper.sh to surface
# ALL label-based blockers in a single pass rather than stopping at the first.
#######################################
enumerate_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	# self_login reserved for future extension — not used by structural checks
	# local self_login="${3:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 1
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	# Re-use pre-fetched JSON when the caller has already loaded issue metadata.
	local issue_meta_json gh_rc=0
	if [[ -n "${ISSUE_META_JSON:-}" ]] \
		&& printf '%s' "$ISSUE_META_JSON" | jq -e '.assignees and .labels' >/dev/null 2>&1; then
		issue_meta_json="$ISSUE_META_JSON"
	else
		issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
			--json state,assignees,labels,createdAt 2>/dev/null) || gh_rc=$?
	fi

	if [[ "$gh_rc" -ne 0 || -z "$issue_meta_json" ]]; then
		printf 'GUARD_UNCERTAIN (reason=gh-api-failure issue=%s repo=%s rc=%s)\n' \
			"$issue_number" "$repo_slug" "$gh_rc"
		return 0
	fi

	local _found=false
	local _blocker_out

	# Check 1: parent-task / meta unconditional block (t1986).
	_blocker_out=$(_is_assigned_check_parent_task "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 2: canonical planning publication has not landed.
	_blocker_out=$(_is_assigned_check_publication_pending "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 3: no-auto-dispatch unconditional block (t2832).
	_blocker_out=$(_is_assigned_check_no_auto_dispatch "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 4: request-specific signed worker permission hold.
	_blocker_out=$(_is_assigned_check_maintainer_permissions "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 5: infrastructure advisory/operator block.
	_blocker_out=$(_is_assigned_check_infrastructure "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 6: hold-for-review unconditional maintainer hold.
	_blocker_out=$(_is_assigned_check_hold_for_review "$issue_meta_json" "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	# Check 7: t3197 dispatch cooldown after no_worker_process launch failure.
	_blocker_out=$(_is_assigned_check_dispatch_cooldown "$issue_number" "$repo_slug" 2>/dev/null) || true
	if [[ -n "$_blocker_out" ]]; then
		printf '%s\n' "$_blocker_out"
		_found=true
	fi

	if [[ "$_found" == "$_DDH_BOOL_TRUE" ]]; then
		return 0
	fi
	return 1
}
