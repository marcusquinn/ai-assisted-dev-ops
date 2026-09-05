#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge.sh — Co-extracted pr-gates + merge clusters (2-cycle) — PR gate checks (external contributor, permission, workflow scope) and merge-ready PR processing + linked-issue extraction.
#
# Extracted from pulse-wrapper.sh in Phase 4 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# NOTE: This module contains TWO clusters (pr-gates + merge) that form a
# dependency cycle. They must be co-located in the same module so bash's
# lazy function name resolution can see both sides of the cycle after a
# single source. Splitting them would require defining stubs or ordering
# sources against call graphs — the plan chose co-extraction as simpler.
#
# GH#21301: further split — PR gate functions into pulse-merge-gates.sh,
# merge processing helpers into pulse-merge-process.sh. Functions over
# 100 lines stay here to preserve (file, fname) identity keys for the
# complexity scanners. Bash's lazy function resolution handles all
# cross-module calls at invocation time.
#
# In GH#19836 the module was further trimmed by extracting two downstream
# clusters that are called after the gate checks fire. They are sourced
# by pulse-wrapper.sh AFTER pulse-merge.sh so they can use shared merge
# helpers such as _extract_linked_issue, while Bash lazy resolution keeps
# the runtime cross-module calls safe. The dependency is one-way only
# (downstream → core); merge-core/pr-gates do not require the downstream
# modules at source time:
#   - pulse-merge-conflict.sh — conflict handling, interactive handover,
#     carry-forward diff, rebase nudges
#   - pulse-merge-feedback.sh — CI/conflict/review feedback routing to
#     linked issues with PR close
# Example cross-module call: _check_pr_merge_gates (merge-core) →
# _dispatch_pr_fix_worker (feedback) is resolved at invocation time.
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order):
#   - _pm_issue_api                          (module-level helper)
#   Functions delegated to sub-libraries:
#   - pulse-merge-gates.sh: check_external_contributor_pr, _external_pr_has_linked_issue,
#     _external_pr_linked_issue_crypto_approved, _pulse_merge_admin_safety_check,
#     check_permission_failure_pr, approve_collaborator_pr, check_pr_modifies_workflows,
#     check_gh_workflow_scope, check_workflow_merge_guard
#   - pulse-merge-process.sh: merge_ready_prs_all_repos, _merge_ready_prs_for_repo,
#     _attempt_pr_update_branch, _resolve_pr_mergeable_status,
#     _pulse_merge_dismiss_coderabbit_nits, _pr_required_checks_pass,
#     _attempt_pr_ci_rebase_retry, _route_pr_to_fix_worker,
#     _retarget_stacked_children, _attempt_worker_briefed_auto_merge,
#     _attempt_green_behind_update_branch, _check_required_checks_passing
#   - pulse-merge-author-checks.sh: _is_collaborator_author,
#     _is_owner_or_member_author, _check_interactive_pr_gates
#   Functions kept here (>100 lines — identity-key preservation):
#   - _check_pr_merge_gates                  (166 lines)
#   - _handle_post_merge_actions             (107 lines)
#   - _process_single_ready_pr               (211 lines)
#   Extraction utilities (used by downstream modules):
#   - _extract_linked_issue
#   - _extract_merge_summary
#
# This was originally a pure move from pulse-wrapper.sh. Later additions
# (rebase nudges GH#18650/GH#18815, review-feedback routing t2093, the
# GH#19836 split, GH#21301 sub-library split) preserve that call site.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_LOADED:-}" ]] && return 0
_PULSE_MERGE_LOADED=1
PULSE_REVIEW_EVIDENCE_SCHEMA="aidevops.review-gate-evidence/v1"
PULSE_UNKNOWN_STATE="UNKNOWN"
# Keep synchronized with the targeted exit contract in the response scanner.
PULSE_REVIEW_REMEDIATION_DEFERRED_RC=10
PULSE_REVIEW_REMEDIATION_NO_MATCH_RC=11
PULSE_REVIEW_REMEDIATION_MAINTAINER_ATTENTION_RC=12
PULSE_REVIEW_REMEDIATION_RETRYABLE_FAILURE_RC=13
PULSE_REVIEW_REMEDIATION_REPEAT_EXHAUSTED="repeat_exhausted"
PULSE_MERGE_BOOL_TRUE="true"
_PULSE_MERGE_REMEDIATION_OUTCOME=""
PULSE_REVIEW_DECISION_CHANGES_REQUESTED="CHANGES_REQUESTED"
PULSE_REVIEW_GATE_MODE_CI_REBASE_ONLY="ci-rebase-only"
PULSE_REVIEW_GATE_MODE_CI_REPAIR_ONLY="ci-repair-only"

# t2863: Module-level variable defaults (set -u guards).
# When this module is sourced standalone (e.g. pulse-merge-routine.sh, test
# harnesses), the pulse-wrapper.sh bootstrap has NOT run. Guard each bare var
# used across this module's functions so set -u does not abort them.
# The :=default form sets the var only when unset or empty; pre-existing values
# from the orchestrator bootstrap are preserved.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${STOP_FLAG:=${HOME}/.aidevops/logs/pulse-session.stop}"
: "${PULSE_MERGE_BATCH_LIMIT:=50}"
: "${PULSE_MERGE_CLOSE_CONFLICTING:=true}"

if [[ -f "${BASH_SOURCE[0]%/*}/pulse-merge-dirty-queue.sh" ]]; then
	# shellcheck source=./pulse-merge-dirty-queue.sh
	source "${BASH_SOURCE[0]%/*}/pulse-merge-dirty-queue.sh"
fi

# Comma-delimited label pattern constant — avoids matching "origin:worker-takeover"
# when checking for "origin:worker" in comma-joined label strings. (t2449)
_OW_LABEL_PAT=",origin:worker,"

# Build issue API path from repo slug and issue number. Module-level helper
# avoids repeating the path literal across multiple function scopes.
_pm_issue_api() {
	local slug="$1"
	local issue_num="$2"
	printf 'repos/%s/issues/%s' "$slug" "$issue_num"
	return 0
}

_pulse_merge_repo_path_for_slug() {
	local repo_slug="$1"
	local repos_json="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local repo_path=""
	[[ -n "$repo_slug" && -f "$repos_json" ]] || return 1
	repo_path=$(jq -r --arg slug "$repo_slug" '
		.initialized_repos[]?
		| select(((.slug // "") | ascii_downcase) == ($slug | ascii_downcase))
		| .path // empty
	' "$repos_json" 2>/dev/null | sed -n '1p') || repo_path=""
	[[ -n "$repo_path" ]] || return 1
	printf '%s\n' "${repo_path/#\~/$HOME}"
	return 0
}

_pulse_merge_review_thread_repeat_exhausted() {
	local repo_slug="$1"
	local pr_number="$2"
	local state_dir="${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR:-${HOME}/.aidevops/.agent-workspace/pr-review-thread-response}"
	local safe_slug=""
	local state_file=""
	local analysis_complete=""
	local maintainer_attention=""
	local blocker_reason=""
	local key=""
	local value=""

	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
	safe_slug="${repo_slug//\//-}"
	safe_slug="${safe_slug//:/-}"
	state_file="${state_dir}/${safe_slug}-${pr_number}.state"
	[[ -f "$state_file" ]] || return 1
	while IFS='=' read -r key value; do
		case "$key" in
		analysis_complete) analysis_complete="$value" ;;
		maintainer_attention) maintainer_attention="$value" ;;
		blocker_reason) blocker_reason="$value" ;;
		esac
	done <"$state_file"
	if [[ "$analysis_complete" == "$PULSE_MERGE_BOOL_TRUE" && "$maintainer_attention" == "$PULSE_MERGE_BOOL_TRUE" &&
		"$blocker_reason" == "same_unresolved_thread_fingerprint" ]]; then
		return 0
	fi
	return 1
}

_pulse_merge_dispatch_review_thread_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local repo_path="" scanner="${_PULSE_MERGE_DIR:-}/pr-review-thread-response-scanner.sh"
	local scanner_rc=0
	_PULSE_MERGE_REMEDIATION_OUTCOME=""

	if [[ ! -x "$scanner" ]]; then
		echo "[pulse-merge] review-thread remediation skipped for PR #${pr_number} in ${repo_slug}: scanner missing or not executable (${scanner})" >>"$LOGFILE"
		return 1
	fi
	if ! repo_path="$(_pulse_merge_repo_path_for_slug "$repo_slug")"; then
		echo "[pulse-merge] review-thread remediation skipped for PR #${pr_number} in ${repo_slug}: repo path not found in configured repos" >>"$LOGFILE"
		return 1
	fi
	PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true "$scanner" dispatch-pr "$repo_slug" "$repo_path" "$pr_number" >>"$LOGFILE" 2>&1 || scanner_rc=$?
	if [[ "$scanner_rc" -eq "$PULSE_REVIEW_REMEDIATION_DEFERRED_RC" ]]; then
		_PULSE_MERGE_REMEDIATION_OUTCOME="deferred"
		echo "[pulse-merge] review-thread remediation deferred for PR #${pr_number} in ${repo_slug} — response dispatch active or recently deduplicated ${reason}" >>"$LOGFILE"
		return 0
	fi
	if [[ "$scanner_rc" -eq "$PULSE_REVIEW_REMEDIATION_NO_MATCH_RC" ]]; then
		_PULSE_MERGE_REMEDIATION_OUTCOME="converged"
		echo "[pulse-merge] review-thread remediation converged for PR #${pr_number} in ${repo_slug} — no matching unresolved thread remained ${reason}" >>"$LOGFILE"
		return 0
	fi
	if [[ "$scanner_rc" -eq "$PULSE_REVIEW_REMEDIATION_MAINTAINER_ATTENTION_RC" ]]; then
		if _pulse_merge_review_thread_repeat_exhausted "$repo_slug" "$pr_number"; then
			_PULSE_MERGE_REMEDIATION_OUTCOME="$PULSE_REVIEW_REMEDIATION_REPEAT_EXHAUSTED"
			echo "[pulse-merge] review-thread remediation exhausted the same unresolved thread fingerprint for PR #${pr_number} in ${repo_slug} ${reason}" >>"$LOGFILE"
		else
			_PULSE_MERGE_REMEDIATION_OUTCOME="maintainer_attention"
			echo "[pulse-merge] review-thread remediation reached terminal maintainer attention for PR #${pr_number} in ${repo_slug} ${reason}" >>"$LOGFILE"
		fi
		return 0
	fi
	if [[ "$scanner_rc" -eq "$PULSE_REVIEW_REMEDIATION_RETRYABLE_FAILURE_RC" ]]; then
		_PULSE_MERGE_REMEDIATION_OUTCOME="failed"
		echo "[pulse-merge] review-thread remediation scan/launch failed for PR #${pr_number} in ${repo_slug} ${reason} (scanner_rc=${scanner_rc}); retry remains available" >>"$LOGFILE"
		return 1
	fi
	if [[ "$scanner_rc" -ne 0 ]]; then
		_PULSE_MERGE_REMEDIATION_OUTCOME="failed"
		echo "[pulse-merge] review-thread remediation returned unexpected outcome for PR #${pr_number} in ${repo_slug} ${reason} (scanner_rc=${scanner_rc})" >>"$LOGFILE"
		return 1
	fi
	_PULSE_MERGE_REMEDIATION_OUTCOME="queued"
	echo "[pulse-merge] review-thread remediation queued for PR #${pr_number} in ${repo_slug} ${reason}" >>"$LOGFILE"
	return 0
}

_pulse_merge_maybe_dispatch_review_thread_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	local merge_output="$3"

	[[ "$merge_output" == *"A conversation must be resolved"* ]] || return 0
	_pulse_merge_dispatch_review_thread_remediation "$pr_number" "$repo_slug" "after unresolved conversation merge blocker" || true
	return 0
}

_pulse_merge_maybe_dispatch_preflight_remediation() {
	local pr_number="$1"
	local repo_slug="$2"
	local blocker_kind="${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-}"
	local reason=""

	if [[ -n "$blocker_kind" ]] && declare -F _pulse_cycle_state_note_blocker >/dev/null 2>&1; then
		_pulse_cycle_state_note_blocker "$blocker_kind" "$repo_slug" "$pr_number" || true
	fi
	# Consume the marker before any dispatch attempt so a failed or deduplicated
	# repair cannot leak into an unrelated later final-gate failure.
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""
	[[ "${DRY_RUN:-0}" != "1" ]] || return 0
	case "$blocker_kind" in
	"$PMRC_BLOCKER_REVIEW_BOT_THREADS") reason="after unresolved review-bot thread preflight blocker" ;;
	"$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS") reason="after required unresolved review-thread preflight blocker" ;;
	*) return 0 ;;
	esac
	_pulse_merge_dispatch_review_thread_remediation "$pr_number" "$repo_slug" "$reason" || true
	return 0
}

_pulse_merge_changes_requested_thread_remediation_first_enabled() {
	[[ "${AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST:-0}" == "1" ]] || return 1
	return 0
}

# REST-safe PR list fields consumed by _process_single_ready_pr. Exact
# mergeability, active review state, and check status are enriched separately
# from bounded REST endpoints before any classification or write decision.
_pulse_merge_ready_pr_json_fields() {
	printf '%s' 'number,state,author,title,isDraft,labels,updatedAt,headRefOid,headRefName,baseRefName,createdAt'
	return 0
}

# Source shared claim-lifecycle helpers (t2429). The _release_interactive_claim_on_merge
# function was extracted to shared-claim-lifecycle.sh so that both pulse-merge.sh and
# full-loop-helper.sh can call it after a successful PR merge. SCRIPT_DIR may not be set
# when this module is sourced by pulse-wrapper.sh; resolve from BASH_SOURCE.
_PULSE_MERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_PULSE_MERGE_DIR}/shared-claim-lifecycle.sh"

# Final duplicate-implementation fence for live interactive issue owners.
# shellcheck source=interactive-claim-fence.sh
source "${_PULSE_MERGE_DIR}/interactive-claim-fence.sh"

# Source shared phase-filing helpers (t2740). auto_file_next_phase is called
# from _handle_post_merge_actions to auto-file the next phase child issue
# when a phase child PR merges for a parent-task issue.
source "${_PULSE_MERGE_DIR}/shared-phase-filing.sh"

# Source terminal dispatch-label cleanup (GH#24012). Close paths strip
# auto-dispatch and active status labels before closing resolved issues so
# stale closed issues cannot poison dispatch caches/candidate scans.
# shellcheck source=shared-dispatch-label-cleanup.sh
source "${_PULSE_MERGE_DIR}/shared-dispatch-label-cleanup.sh"

# Source shared supersession helpers (GH#24399). Merge-ready PRs that use a
# closing keyword against an issue already closed by a different merged PR are
# duplicate worker outputs and must be closed before any merge attempt.
# shellcheck source=pr-supersession-helper.sh
source "${_PULSE_MERGE_DIR}/pr-supersession-helper.sh"

# Targeted remediation for stale GitHub CLI HTTP cache entries that can make
# `gh pr merge` return a cached 401 even after live gh auth succeeds (GH#24656).
# shellcheck source=gh-merge-cache-remediation-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/gh-merge-cache-remediation-lib.sh"

# shellcheck source=./release-lane-helper.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/release-lane-helper.sh"

readonly _PM_PARENT_TASK_LABEL_NEEDLE=",parent-task,"

# Source author permission check helpers (GH#21426 — extracted to bring
# pulse-merge.sh below the 2000-line file-size-debt threshold).
# shellcheck source=./pulse-merge-author-checks.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-author-checks.sh"

# Source PR gate checking functions (GH#21301 — extracted to bring
# pulse-merge.sh below the 1500-line file-size-debt threshold).
# shellcheck source=./pulse-merge-gates.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-gates.sh"

# Source fail-closed Dependabot worker intake for bot PRs that cannot use the
# narrow automatic merge policy or the linked worker-issue feedback router.
# shellcheck source=./pulse-dependabot-intake.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-dependabot-intake.sh"

# Source merge processing helpers (GH#21301 — extracted to bring
# pulse-merge.sh below the 1500-line file-size-debt threshold).
# shellcheck source=./pulse-merge-process.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-process.sh"

# shellcheck source=./pulse-merge-required-checks.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _PULSE_MERGE_DIR
source "${_PULSE_MERGE_DIR}/pulse-merge-required-checks.sh"

# _release_interactive_claim_on_merge is now provided by shared-claim-lifecycle.sh
# (sourced at the top of this module, t2429/GH#20067). The backward-compatible
# underscore-prefixed alias is defined there so all existing call sites
# (including _handle_post_merge_actions below) continue to work unchanged.

#######################################
# Handle terminal CHANGES_REQUESTED review state for a PR.
#
# Security invariant: this helper never marks a PR mergeable and never bypasses
# collaborator, maintainer, review-bot, or branch-protection gates. A blocking
# review either remains a skip/repair-route, or the existing maintainer-labeled
# CodeRabbit-only dismissal path clears stale bot nits before normal gates run.
#
# Returns 0 if the caller may keep evaluating merge gates.
# Returns 1 if the PR remains review-blocked. A converged remediation may also
# set review_gate_mode_dest_var=ci-repair-only for an explicit repair-only path.
# Args: $1=pr_number, $2=repo_slug, $3=pr_review, $4=linked_issue, $5=pr_labels (optional),
#       $6=dismissed_dest_var (optional), $7=review_gate_mode_dest_var (optional)
#######################################
_handle_changes_requested_review_gate() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_review="$3"
	local linked_issue="$4"
	local pr_labels="${5:-}"
	local dismissed_dest_var="${6:-}"
	local review_gate_mode_dest_var="${7:-}"
	local _cr_pr_labels=""
	local _changes_requested="${PULSE_REVIEW_DECISION_CHANGES_REQUESTED:-CHANGES_REQUESTED}"
	local _ci_repair_only="${PULSE_REVIEW_GATE_MODE_CI_REPAIR_ONLY:-ci-repair-only}"
	local _route_after_converged_body_review=0

	if [[ -n "$dismissed_dest_var" && "$dismissed_dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		printf -v "$dismissed_dest_var" '%s' "0"
	fi
	if [[ -n "$review_gate_mode_dest_var" && "$review_gate_mode_dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		printf -v "$review_gate_mode_dest_var" '%s' "merge"
	fi

	[[ "$pr_review" == "$_changes_requested" ]] || return 0

	# Fetch labels once — reused by both the nits-ok check and the
	# worker-routing block below.
	_cr_pr_labels="$pr_labels"
	if [[ -z "$_cr_pr_labels" ]]; then
		if ! _cr_pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null); then
			echo "[pulse-wrapper] Merge pass: skipping review routing for PR #${pr_number} in ${repo_slug} — current PR labels unavailable" >>"$LOGFILE"
			return 1
		fi
	fi

	# t2179: coderabbit-nits-ok path.
	if [[ ",${_cr_pr_labels}," == *",coderabbit-nits-ok,"* ]]; then
		if _pulse_merge_dismiss_coderabbit_nits "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — auto-dismissed CodeRabbit-only CHANGES_REQUESTED reviews (coderabbit-nits-ok label) (t2179)" >>"$LOGFILE"
			if [[ -n "$dismissed_dest_var" && "$dismissed_dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
				printf -v "$dismissed_dest_var" '%s' "1"
			fi
			return 0
		fi

		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — coderabbit-nits-ok label present but human reviewer also blocking (t2179)" >>"$LOGFILE"
		return 1
	fi

	local _cr_label_list=",${_cr_pr_labels},"
	# Optional policy override (GH#26535): by default CHANGES_REQUESTED worker
	# PRs keep the historical fast-routing behaviour below. Operators who prefer
	# preserving the PR/review context can opt in to a remediation-first cycle.
	if _pulse_merge_changes_requested_thread_remediation_first_enabled \
		&& [[ ( -n "${_OW_LABEL_PAT:-}" && "$_cr_label_list" == *"${_OW_LABEL_PAT:-}"* ) \
			|| "$_cr_label_list" == *",origin:worker-takeover,"* ]] \
		&& [[ "$_cr_label_list" != *",external-contributor,"* ]] \
		&& [[ "$_cr_label_list" != *",no-takeover,"* ]] \
		&& [[ "$_cr_label_list" != *",review-routed-to-issue,"* ]] \
		&& _pulse_merge_dispatch_review_thread_remediation "$pr_number" "$repo_slug" "after CHANGES_REQUESTED review gate"; then
		if [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "deferred" ]]; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED; response remediation already active/deferred, preserving PR" >>"$LOGFILE"
		elif [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "converged" ]]; then
			if declare -F _review_feedback_has_trusted_body_change_request >/dev/null 2>&1 \
				&& _review_feedback_has_trusted_body_change_request "$pr_number" "$repo_slug"; then
				_route_after_converged_body_review=1
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — review-thread remediation converged while a trusted human top-level CHANGES_REQUESTED body remains; applying the existing trust-gated fix-worker route" >>"$LOGFILE"
			else
				if [[ -n "$review_gate_mode_dest_var" && "$review_gate_mode_dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
					printf -v "$review_gate_mode_dest_var" '%s' "$_ci_repair_only"
				fi
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED; no matching unresolved thread or trusted human top-level review body remained after refresh, preserving the review block while allowing trust-gated CI repair evaluation" >>"$LOGFILE"
			fi
		elif [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "maintainer_attention" ]]; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED; terminal review-thread maintainer attention pending, preserving PR" >>"$LOGFILE"
		elif [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "$PULSE_REVIEW_REMEDIATION_REPEAT_EXHAUSTED" ]]; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — same unresolved thread fingerprint exhausted bounded response remediation; applying the existing trust-gated fix-worker route" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED; review-thread remediation queued" >>"$LOGFILE"
		fi
		[[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "$PULSE_REVIEW_REMEDIATION_REPEAT_EXHAUSTED" \
			|| "$_route_after_converged_body_review" -eq 1 ]] || return 1
	fi

	# If remediation is unavailable or fails to dispatch, route worker-authored
	# PRs for fix dispatch and skip the merge (t2203: consolidated in helper).
	local review_route_rc=0
	_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "review" "$_cr_pr_labels" || review_route_rc=$?
	if [[ "$review_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" ]]; then
		echo "[pulse-wrapper] Merge pass: review feedback finalization deferred for PR #${pr_number} in ${repo_slug}; preserving retryable route state" >>"$LOGFILE"
	elif [[ "$review_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
		echo "[pulse-wrapper] Merge pass: review feedback finalization for PR #${pr_number} in ${repo_slug} requires maintainer review" >>"$LOGFILE"
	fi
	echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED" >>"$LOGFILE"
	return 1
}

#######################################
# Run all merge-eligibility or repair-authority gate checks for a single PR.
# Returns 0 if all gates for the requested mode pass. Only merge mode permits
# the caller to proceed toward merge; repair-only modes must return after repair.
# Returns 1 if any gate fails (PR should be skipped).
# Args: $1=pr_number, $2=repo_slug, $3=pr_author, $4=pr_review, $5=linked_issue,
#       $6=pr_labels (optional), $7=expected_head_sha (optional),
#       $8=review_gate_mode (optional: merge|ci-rebase-only|ci-repair-only)
#######################################
_pm_gate_review_mode() {
	local pr_number="$1" repo_slug="$2" pr_review="$3" linked_issue="$4" pr_labels="$5"
	local review_gate_mode="$6" changes_requested="$7" ci_rebase_only="$8" ci_repair_only="$9"
	case "$review_gate_mode" in
	merge)
		_handle_changes_requested_review_gate "$pr_number" "$repo_slug" "$pr_review" "$linked_issue" "$pr_labels" || return 1
		;;
	"$ci_rebase_only" | "$ci_repair_only")
		if [[ "$pr_review" != "$changes_requested" ]]; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — ${review_gate_mode} review mode requires CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
		;;
	*)
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — unknown review gate mode ${review_gate_mode}" >>"$LOGFILE"
		return 1
		;;
	esac
	return 0
}

_pm_gate_author_trust() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" expected_head_sha="$4"
	local trusted_dest="$5" permission_dest="$6" author_collab_rc=0 permission="" trusted=0
	if [[ "$pr_author" == "app/github-actions" || "$pr_author" == "github-actions[bot]" ]] &&
		_pulse_is_trusted_issue_sync_pr "$pr_number" "$repo_slug" "$expected_head_sha"; then
		trusted=1
		permission="write"
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — author ${pr_author} is trusted repository-generated Issue Sync automation, proceeding" >>"$LOGFILE"
	else
		_is_collaborator_author "$pr_author" "$repo_slug"
		author_collab_rc=$?
		permission="${_PULSE_AUTHOR_PERMISSION_VALUE:-}"
	fi
	printf -v "$trusted_dest" '%s' "$trusted"
	printf -v "$permission_dest" '%s' "$permission"
	if [[ "$trusted" -eq 0 && "$author_collab_rc" -eq 2 ]]; then
		[[ "${DRY_RUN:-0}" == "1" ]] || check_permission_failure_pr "$pr_number" "$repo_slug" "$pr_author" "${_PULSE_AUTHOR_PERMISSION_HTTP:-unknown}" || true
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — permission check failed for author ${pr_author} (HTTP ${_PULSE_AUTHOR_PERMISSION_HTTP:-unknown})" >>"$LOGFILE"
		return 1
	fi
	if [[ "$trusted" -eq 0 && "$author_collab_rc" -ne 0 ]]; then
		if _is_trusted_dependabot_update_pr "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha"; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — author ${pr_author} is trusted Dependabot with allowlisted dependency update, proceeding (GH#24473)" >>"$LOGFILE"
		elif _has_maintainer_crypto_approval "$pr_number" "$repo_slug" "$expected_head_sha"; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator but has maintainer crypto-approval, proceeding (t3063)" >>"$LOGFILE"
		else
			_pm_gate_route_ineligible_author "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha"
			return 1
		fi
	fi
	return 0
}

_pm_gate_route_ineligible_author() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" expected_head_sha="$4" intake_rc=0
	_pulse_route_dependabot_pr_to_worker_issue "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha" "policy-ineligible" || intake_rc=$?
	case "$intake_rc" in
	0) echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — authentic Dependabot PR is outside automatic merge policy; routed to worker intake (GH#30351)" >>"$LOGFILE" ;;
	3) echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — authentic Dependabot PR has an explicit maintainer-review hold; preserving it without worker intake (GH#30389)" >>"$LOGFILE" ;;
	4)
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — would close superseded Dependabot source after verified replacement PR #${_PULSE_DEPENDABOT_SUPERSEDING_PR:-unknown} (GH#30478)" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Merge pass: closed superseded Dependabot source PR #${pr_number} in ${repo_slug} after verified replacement PR #${_PULSE_DEPENDABOT_SUPERSEDING_PR:-unknown} (GH#30478)" >>"$LOGFILE"
		fi
		;;
	*) echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator" >>"$LOGFILE" ;;
	esac
	return 0
}

_pm_gate_repository_and_issue() {
	local pr_number="$1" repo_slug="$2" linked_issue="$3" expected_head_sha="$4" trusted_issue_sync="$5"
	local issue_labels="" pr_labels_for_ext="" ext_linked_for_log="" li_api=""
	if check_pr_modifies_workflows "$pr_number" "$repo_slug" 2>/dev/null && ! check_gh_workflow_scope 2>/dev/null; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — modifies workflow files but token lacks workflow scope" >>"$LOGFILE"
		return 1
	fi
	if [[ -n "$linked_issue" ]]; then
		li_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
		issue_labels=$(gh api "$li_api" --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
		if [[ "$issue_labels" == *"needs-maintainer-review"* ]]; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has needs-maintainer-review" >>"$LOGFILE"
			return 1
		fi
	fi
	pr_labels_for_ext=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels_for_ext=""
	if [[ "$trusted_issue_sync" -eq 0 && "$pr_labels_for_ext" == *"external-contributor"* ]]; then
		_external_pr_has_linked_issue "$pr_number" "$repo_slug" || {
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR has no linked issue (t1958)" >>"$LOGFILE"
			return 1
		}
		if ! _external_pr_linked_issue_crypto_approved "$pr_number" "$repo_slug"; then
			ext_linked_for_log=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || ext_linked_for_log="unknown"
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR linked issue #${ext_linked_for_log} lacks crypto approval (t1958)" >>"$LOGFILE"
			return 1
		fi
		_external_pr_current_head_crypto_approved "$pr_number" "$repo_slug" "$expected_head_sha" || {
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR lacks V2 crypto approval for current head" >>"$LOGFILE"
			return 1
		}
	fi
	return 0
}

_pm_gate_origin_authority() {
	local pr_number="$1" repo_slug="$2" linked_issue="$3" pr_author="$4"
	local trusted_issue_sync="$5" author_permission="$6" info_json="" labels_str="" is_draft="false"
	info_json=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels,isDraft 2>/dev/null) || info_json=""
	labels_str=$(printf '%s' "$info_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || labels_str=""
	is_draft=$(printf '%s' "$info_json" | jq -r '.isDraft // false' 2>/dev/null) || is_draft="false"
	if [[ "$labels_str" == *"origin:interactive"* ]]; then
		_check_interactive_pr_gates "$pr_number" "$repo_slug" "$labels_str" "$is_draft" || return 1
	fi
	if [[ -n "${_OW_LABEL_PAT:-}" && ",${labels_str}," == *"${_OW_LABEL_PAT:-}"* && "$trusted_issue_sync" -eq 0 ]]; then
		_attempt_worker_briefed_auto_merge "$pr_number" "$repo_slug" "$labels_str" "$is_draft" "$linked_issue" "$author_permission" "$pr_author" || return 1
	elif [[ "$trusted_issue_sync" -eq 1 ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — exact-head Issue Sync trust satisfies worker authority without a linked issue" >>"$LOGFILE"
	fi
	return 0
}

_pm_gate_review_bot() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" expected_head_sha="$4"
	local rbg_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/review-bot-gate-helper.sh"
	local rbg_observed_at="" rbg_result="" rbg_status=""
	[[ -f "$rbg_helper" ]] || return 0
	if _is_trusted_dependabot_update_pr "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha"; then
		rbg_observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		_PULSE_REVIEW_GATE_EVIDENCE=$(jq -nc --arg schema "$PULSE_REVIEW_EVIDENCE_SCHEMA" --arg repo "$repo_slug" --arg pr "$pr_number" --arg head "$expected_head_sha" --arg author "$pr_author" --arg observed_at "$rbg_observed_at" \
			'{schema:$schema,repo:$repo,pr:$pr,head_sha:$head,status:"SKIP_TRUSTED_DEPENDABOT",author:{login:$author,association:"BOT",class:"trusted-bot"},permitted:true,reason:"trusted_dependabot_policy",state:"pass",merge_gate:"clear",exit_code:0,observed_at:$observed_at}')
		echo "[pulse-wrapper] Review bot gate: SKIP for trusted Dependabot dependency update PR #${pr_number} in ${repo_slug} (GH#24473)" >>"$LOGFILE"
		return 0
	fi
	rbg_result=$(bash "$rbg_helper" status-json "$pr_number" "$repo_slug" 2>/dev/null) || rbg_result=""
	rbg_status=$(jq -r --arg unknown "$PULSE_UNKNOWN_STATE" '.status // $unknown' <<<"$rbg_result" 2>/dev/null) || rbg_status="$PULSE_UNKNOWN_STATE"
	# #aidevops:trust-boundary — only exact-head permitted evidence can pass.
	if jq -e --arg schema "$PULSE_REVIEW_EVIDENCE_SCHEMA" --arg repo "$repo_slug" --arg pr "$pr_number" --arg head "$expected_head_sha" '
		.schema == $schema and .repo == $repo and (.pr | tostring) == $pr
		and .head_sha == $head and .permitted == true
		and .state == "pass" and .merge_gate == "clear"
	' <<<"$rbg_result" >/dev/null 2>&1; then
		rbg_observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
		_PULSE_REVIEW_GATE_EVIDENCE=$(jq -cS --arg observed_at "$rbg_observed_at" '.observed_at = $observed_at' <<<"$rbg_result") || return 1
		echo "[pulse-wrapper] Review bot gate: ${rbg_status} for PR #${pr_number} in ${repo_slug} (typed current-head evidence)" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] Review bot gate: ${rbg_status:-${PULSE_UNKNOWN_STATE}} for PR #${pr_number} in ${repo_slug} — missing or unpermitted current-head evidence; skipping merge" >>"$LOGFILE"
	return 1
}

_check_pr_merge_gates() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" pr_review="$4" linked_issue="$5"
	local pr_labels="${6:-}" expected_head_sha="${7:-}" review_gate_mode="${8:-merge}"
	local changes_requested="${PULSE_REVIEW_DECISION_CHANGES_REQUESTED:-CHANGES_REQUESTED}"
	local ci_rebase_only="${PULSE_REVIEW_GATE_MODE_CI_REBASE_ONLY:-ci-rebase-only}"
	local ci_repair_only="${PULSE_REVIEW_GATE_MODE_CI_REPAIR_ONLY:-ci-repair-only}"
	local trusted_issue_sync=0 author_permission=""
	_PULSE_REVIEW_GATE_EVIDENCE=""
	if [[ -n "$linked_issue" ]] && _interactive_claim_fence_blocks_merge "$linked_issue" "$repo_slug" "$expected_head_sha"; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has a live interactive owner with different unmerged work (GH#30274)" >>"$LOGFILE"
		return 1
	fi
	_pm_gate_review_mode "$pr_number" "$repo_slug" "$pr_review" "$linked_issue" "$pr_labels" \
		"$review_gate_mode" "$changes_requested" "$ci_rebase_only" "$ci_repair_only" || return 1
	_pm_gate_author_trust "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha" \
		trusted_issue_sync author_permission || return 1
	_pm_gate_repository_and_issue "$pr_number" "$repo_slug" "$linked_issue" "$expected_head_sha" "$trusted_issue_sync" || return 1
	_pm_gate_origin_authority "$pr_number" "$repo_slug" "$linked_issue" "$pr_author" \
		"$trusted_issue_sync" "$author_permission" || return 1
	if [[ "$review_gate_mode" == "$ci_rebase_only" ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} passed non-review trust gates for ${review_gate_mode} evaluation; CHANGES_REQUESTED remains blocking" >>"$LOGFILE"
		return 0
	fi
	[[ "$review_gate_mode" != "$ci_repair_only" ]] || echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} passed non-review trust gates for ${review_gate_mode} evaluation; requiring current-head review-bot evidence before CI repair" >>"$LOGFILE"
	_pm_gate_review_bot "$pr_number" "$repo_slug" "$pr_author" "$expected_head_sha"
	return $?
}

#######################################
# Refresh typed review evidence at the final merge boundary.
#
# #aidevops:trust-boundary — evidence captured by the upstream gate can become
# stale while Pulse posts reviews, updates branches, or attempts another merge
# path. Re-run the read-only helper for the exact current head before each merge
# call. Trusted Dependabot uses its dedicated live policy verifier instead.
# Args: $1=PR number, $2=repo slug, $3=expected head SHA
# Returns: 0=current evidence refreshed (or status-only fallback), 1=blocked
#######################################
_pulse_merge_refresh_review_gate_evidence() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"
	local current_evidence="${_PULSE_REVIEW_GATE_EVIDENCE:-}"
	local rbg_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/review-bot-gate-helper.sh"
	local refreshed_evidence="" evidence_status="" dependabot_author="" evidence_observed_at=""

	if jq -e --arg schema "$PULSE_REVIEW_EVIDENCE_SCHEMA" --arg repo "$repo_slug" --arg pr "$pr_number" --arg head "$expected_head_sha" '
		.schema == $schema
		and .repo == $repo and (.pr | tostring) == $pr and .head_sha == $head
		and .status == "SKIP_TRUSTED_DEPENDABOT" and .permitted == true
	' <<<"$current_evidence" >/dev/null 2>&1; then
		dependabot_author=$(jq -r '.author.login // ""' <<<"$current_evidence" 2>/dev/null) || dependabot_author=""
		if [[ -n "$dependabot_author" ]] && _is_trusted_dependabot_update_pr "$pr_number" "$repo_slug" "$dependabot_author" "$expected_head_sha"; then
			evidence_observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
			_PULSE_REVIEW_GATE_EVIDENCE=$(jq -cS --arg observed_at "$evidence_observed_at" '.observed_at = $observed_at' <<<"$current_evidence") || return 1
			return 0
		fi
		_PULSE_REVIEW_GATE_EVIDENCE=""
		return 1
	fi

	_PULSE_REVIEW_GATE_EVIDENCE=""
	if [[ ! -f "$rbg_helper" ]]; then
		return 0
	fi
	refreshed_evidence=$(bash "$rbg_helper" status-json "$pr_number" "$repo_slug" 2>/dev/null) || refreshed_evidence=""
	if ! _pmrc_review_evidence_permits_advisory "$refreshed_evidence" "$repo_slug" "$pr_number" "$expected_head_sha"; then
		evidence_status=$(jq -r --arg unknown "$PULSE_UNKNOWN_STATE" '.status // $unknown' <<<"$refreshed_evidence" 2>/dev/null) || evidence_status="$PULSE_UNKNOWN_STATE"
		echo "[pulse-merge] final trust gate: current-head review evidence is ${evidence_status:-${PULSE_UNKNOWN_STATE}} or unpermitted for PR #${pr_number} in ${repo_slug} — merge blocked" >>"$LOGFILE"
		return 1
	fi
	evidence_observed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
	_PULSE_REVIEW_GATE_EVIDENCE=$(jq -cS --arg observed_at "$evidence_observed_at" '.observed_at = $observed_at' <<<"$refreshed_evidence") || {
		_PULSE_REVIEW_GATE_EVIDENCE=""
		return 1
	}
	return 0
}

#######################################
# Revalidate all final merge authority and current-head evidence.
#
# #aidevops:trust-boundary — invoke this immediately before every native,
# admin, or direct merge call. Preparatory writes and failed merge attempts can
# race with external content/head changes; cached gate state is not authority.
# Args: $1=PR number, $2=repo slug, $3=expected head SHA
# Returns: 0=final snapshot authorized, 1=blocked
#######################################
_pulse_merge_final_trust_gate() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="$3"

	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""
	if ! _pulse_merge_admin_safety_check "$pr_number" "$repo_slug" "$expected_head_sha"; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_MERGE_AUTHORITY"
		return 1
	fi
	if ! _pulse_merge_refresh_review_gate_evidence "$pr_number" "$repo_slug" "$expected_head_sha"; then
		_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REVIEW_GATE"
		return 1
	fi
	_pulse_merge_preflight_snapshot_gate "$repo_slug" "$pr_number" "$expected_head_sha" || return 1
	return 0
}

#######################################
# Build provider-neutral routing feedback for a merged issue.
# Args: $1=repo slug, $2=linked issue
# Stdout: markdown section or empty
# Returns: 0 always
#######################################
_pm_routing_feedback() {
	local repo_slug="$1"
	local linked_issue="$2"
	[[ -n "$linked_issue" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0
	local module_dir="${BASH_SOURCE[0]%/*}"
	local feedback_helper="${AIDEVOPS_ROUTING_FEEDBACK_HELPER:-${module_dir}/routing-feedback.mjs}"
	[[ -r "$feedback_helper" ]] || return 0
	node "$feedback_helper" --repo "$repo_slug" --issue "$linked_issue" \
		--format markdown --heading-level 3 2>/dev/null || true
	return 0
}

#######################################
# Build the closing comment body for a merged PR (with signature footer).
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=merge_summary, $5=pr_base_ref_name (optional)
# Stdout: closing comment body
# Returns: 0 always
#######################################
_pm_build_closing_comment() {
	local pr_number="$1" repo_slug="$2" linked_issue="$3" merge_summary="$4"
	local pr_base_ref_name="${5:-main}"
	local body
	if [[ -n "$merge_summary" ]]; then
		body="${merge_summary}

---
Merged via PR #${pr_number} to ${pr_base_ref_name}.
_Merged by deterministic merge pass (pulse-wrapper.sh)._"
	else
		body="Completed via PR #${pr_number}, merged to ${pr_base_ref_name}.

_Merged by deterministic merge pass (pulse-wrapper.sh). Neither MERGE_SUMMARY comment nor PR body text was available._"
	fi
	local routing_feedback=""
	routing_feedback=$(_pm_routing_feedback "$repo_slug" "$linked_issue")
	if [[ -n "$routing_feedback" ]]; then
		body="${body}

${routing_feedback}"
	fi

	local elapsed issue_ref="" footer
	elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	[[ -n "$linked_issue" ]] && issue_ref="${repo_slug}#${linked_issue}"
	local sig_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/gh-signature-helper.sh"
	footer=$("$sig_helper" footer \
		--body "$body" --no-session --tokens 0 \
		--time "$elapsed" --session-type routine \
		${issue_ref:+--issue "$issue_ref"} --solved 2>/dev/null || true)
	printf '%s%s' "$body" "$footer"
	return 0
}

#######################################
# Return the preferred comment ID for a PR merge closeout upsert.
#
# Prefer an existing deterministic closeout marker. Otherwise reuse the
# worker's canonical MERGE_SUMMARY comment so post-merge handling transforms
# that singleton instead of appending a second completion summary.
#
# Args: $1=comments JSON (gh --paginate --slurp shape), $2=PR number
# Stdout: comment ID, or empty
# Returns: 0 always
#######################################
_pm_select_pr_closeout_comment_id() {
	local comments_json="$1"
	local pr_number="$2"
	local closeout_marker="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->"
	local legacy_merge_text="Merged via PR #${pr_number} to"
	local legacy_generic_text="Completed via PR #${pr_number}, merged to"

	printf '%s' "$comments_json" | jq -r \
		--arg array_type 'array' \
		--arg closeout_marker "$closeout_marker" \
		--arg legacy_generic_text "$legacy_generic_text" \
		--arg legacy_merge_text "$legacy_merge_text" \
		--arg merge_attribution 'Merged by deterministic merge pass (pulse-wrapper.sh).' \
		--arg summary_marker '<!-- MERGE_SUMMARY -->' '
		(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
		elif type == $array_type then .
		else [] end)
		| [ .[]
			| select(
				((.body // "") | contains($closeout_marker)) or
				((.body // "") | contains($summary_marker)) or
				(
					((.body // "") | contains($legacy_merge_text)) and
					((.body // "") | contains($merge_attribution))
				) or
				(
					((.body // "") | contains($legacy_generic_text)) and
					((.body // "") | contains($merge_attribution))
				)
			)
			| {
				id: .id,
				created_at: (.created_at // "")
			} ]
		| sort_by(.created_at, .id)
		| first
		| .id // empty
	' 2>/dev/null || true
	return 0
}

#######################################
# Converge deterministic PR closeout comments to one marker-bearing comment.
#
# Each concurrent runner performs reconciliation after its own write. The
# later writer therefore observes the earlier candidate, updates the same
# deterministic oldest winner, and removes every newer duplicate.
#
# Args: $1=PR number, $2=repo slug, $3=desired marked comment body
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_reconcile_pr_closeout_comments() {
	local pr_number="$1"
	local repo_slug="$2"
	local marked_comment="$3"
	local comments_json="" closeout_ids="" keep_id="" previous_singleton_id="" comment_id=""
	local candidate_count=0 stable_observations=0 attempt=0 max_attempts=4
	local closeout_marker="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->"
	local legacy_merge_text="Merged via PR #${pr_number} to"
	local legacy_generic_text="Completed via PR #${pr_number}, merged to"

	while ((attempt < max_attempts)); do
		attempt=$((attempt + 1))
		comments_json=$(_gh_with_timeout read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
			--paginate --slurp 2>/dev/null) || comments_json=""
		if [[ -z "$comments_json" ]]; then
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		closeout_ids=$(printf '%s' "$comments_json" | jq -r \
			--arg array_type 'array' \
			--arg closeout_marker "$closeout_marker" \
			--arg legacy_generic_text "$legacy_generic_text" \
			--arg legacy_merge_text "$legacy_merge_text" \
			--arg merge_attribution 'Merged by deterministic merge pass (pulse-wrapper.sh).' \
			--arg summary_marker '<!-- MERGE_SUMMARY -->' '
			(if type == $array_type and (.[0]? | type) == $array_type then [.[][]]
			elif type == $array_type then .
			else [] end)
			| [ .[]
				| select(
					((.body // "") | contains($closeout_marker)) or
					((.body // "") | contains($summary_marker)) or
					(
						((.body // "") | contains($legacy_merge_text)) and
						((.body // "") | contains($merge_attribution))
					) or
					(
						((.body // "") | contains($legacy_generic_text)) and
						((.body // "") | contains($merge_attribution))
					)
				)
				| {id: .id, created_at: (.created_at // "")} ]
			| sort_by(.created_at, .id)
			| .[].id
		' 2>/dev/null) || closeout_ids=""
		candidate_count=$(printf '%s\n' "$closeout_ids" | grep -c '.') || candidate_count=0
		if [[ "$candidate_count" -eq 0 ]]; then
			stable_observations=0
			previous_singleton_id=""
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		keep_id=$(printf '%s\n' "$closeout_ids" | sed -n '1p')
		if gh api "repos/${repo_slug}/issues/comments/${keep_id}" \
			--method PATCH --field body="$marked_comment" >/dev/null 2>&1; then
			:
		else
			echo "[pulse-wrapper] Deterministic merge: failed to refresh canonical PR closeout comment ${keep_id} for ${repo_slug}#${pr_number} (attempt ${attempt}/${max_attempts}, GH#27502)" >>"$LOGFILE"
			stable_observations=0
			previous_singleton_id=""
			((attempt < max_attempts)) && sleep 1
			continue
		fi

		if [[ "$candidate_count" -eq 1 ]]; then
			if [[ "$keep_id" == "$previous_singleton_id" ]]; then
				stable_observations=$((stable_observations + 1))
			else
				stable_observations=1
				previous_singleton_id="$keep_id"
			fi
			if [[ "$stable_observations" -ge 2 ]]; then
				return 0
			fi
			((attempt < max_attempts)) && sleep 1
			continue
		fi
		stable_observations=0
		previous_singleton_id=""

		while IFS= read -r comment_id; do
			[[ -n "$comment_id" && "$comment_id" != "$keep_id" ]] || continue
			if gh api "repos/${repo_slug}/issues/comments/${comment_id}" \
				--method DELETE >/dev/null 2>&1; then
				echo "[pulse-wrapper] Deterministic merge: removed duplicate PR closeout comment ${comment_id} for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
			else
				if [[ "$attempt" -lt "$max_attempts" ]]; then
					echo "[pulse-wrapper] Deterministic merge: failed to remove duplicate PR closeout comment ${comment_id} for ${repo_slug}#${pr_number}; retrying reconciliation (attempt ${attempt}/${max_attempts}, GH#27502)" >>"$LOGFILE"
				else
					echo "[pulse-wrapper] Deterministic merge: duplicate PR closeout comment ${comment_id} remains after ${max_attempts} reconciliation attempts for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
				fi
			fi
		done <<<"$closeout_ids"
		((attempt < max_attempts)) && sleep 1
	done
	echo "[pulse-wrapper] Deterministic merge: PR closeout reconciliation did not reach two stable singleton observations for ${repo_slug}#${pr_number} after ${max_attempts} attempts (GH#27502)" >>"$LOGFILE"
	return 0
}

#######################################
# Upsert the deterministic PR merge closeout without duplicate summaries.
#
# The normal path patches the existing MERGE_SUMMARY comment. The fallback
# posts one marker-bearing comment, then reconciles concurrent fallback writes.
# This is cross-runner safe; local pulse locks only coordinate one machine.
#
# Args: $1=PR number, $2=repo slug, $3=closing comment body
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_upsert_pr_closing_comment() {
	local pr_number="$1"
	local repo_slug="$2"
	local closing_comment="$3"
	local comments_json="" existing_comment_id="" created_comment_id="" marked_comment=""

	marked_comment="<!-- PULSE_MERGE_CLOSEOUT:PR#${pr_number} -->
${closing_comment}"
	comments_json=$(_gh_with_timeout read gh api "repos/${repo_slug}/issues/${pr_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || comments_json=""
	if [[ -n "$comments_json" ]]; then
		existing_comment_id=$(_pm_select_pr_closeout_comment_id "$comments_json" "$pr_number")
	fi

	if [[ -n "$existing_comment_id" ]] && gh api \
		"repos/${repo_slug}/issues/comments/${existing_comment_id}" \
		--method PATCH --field body="$marked_comment" >/dev/null 2>&1; then
		echo "[pulse-wrapper] Deterministic merge: upserted PR closeout comment ${existing_comment_id} for ${repo_slug}#${pr_number} (GH#27502)" >>"$LOGFILE"
		_pm_reconcile_pr_closeout_comments "$pr_number" "$repo_slug" "$marked_comment"
		return 0
	fi

	created_comment_id=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--method POST --field body="$marked_comment" --jq '.id // empty' 2>/dev/null) || created_comment_id=""
	if [[ -z "$created_comment_id" ]]; then
		echo "[pulse-wrapper] Deterministic merge: failed to create PR closeout for merged ${repo_slug}#${pr_number}; post-merge publication ended without a canonical PR comment (GH#27502)" >>"$LOGFILE"
		return 0
	fi
	_pm_reconcile_pr_closeout_comments "$pr_number" "$repo_slug" "$marked_comment"
	return 0
}

#######################################
# Resolve the original issue behind a superseded PR reference.
#
# When PR B resolves PR A, GitHub treats PR A as an issue number. The normal
# linked-issue extractor therefore returns PR A's number, not the issue that PR A
# originally resolved. If PR A is actually a pull request, inspect PR A and return
# its own linked issue so deterministic merge can close the original task too.
#
# Args: $1=merged_pr_number, $2=repo_slug, $3=candidate_issue_number
# Stdout: original issue number, or empty when candidate is not a PR chain
# Returns: 0 always
#######################################
_pm_resolve_superseded_original_issue() {
	local merged_pr_number="$1" repo_slug="$2" candidate_issue="$3"
	local original_issue

	[[ -z "$candidate_issue" ]] && return 0
	if ! gh api "repos/${repo_slug}/pulls/${candidate_issue}" >/dev/null 2>&1; then
		return 0
	fi

	original_issue=$(_extract_linked_issue "$candidate_issue" "$repo_slug" 2>/dev/null) || original_issue=""
	if [[ -z "$original_issue" || "$original_issue" == "$candidate_issue" || "$original_issue" == "$merged_pr_number" ]]; then
		return 0
	fi

	printf '%s' "$original_issue"
	return 0
}

#######################################
# Extract a non-closing parent/umbrella reference from a PR body.
#
# Args: $1=pr_number, $2=repo_slug
# Stdout: issue number from the first `For #NNN` / `Ref #NNN` reference
# Returns: 0 always
#######################################
_pm_extract_partial_parent_reference() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_body="" parent_issue=""

	pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""
	parent_issue=$(printf '%s' "$pr_body" | grep -ioE '(^|[[:space:]])(for|ref)[[:space:]]+#[0-9]+' | head -1 | grep -oE '[0-9]+') || parent_issue=""
	printf '%s' "$parent_issue"
	return 0
}

#######################################
# Decide whether an issue is broad enough to require partial closeout hygiene.
#
# Args: $1=issue body, $2=comma-separated label names
# Returns: 0=broad parent/umbrella issue, 1=normal leaf issue
#######################################
_pm_issue_needs_partial_closeout() {
	local issue_body="$1"
	local issue_labels="$2"
	local checklist_count

	if [[ ",${issue_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
		return 0
	fi

	if printf '%s' "$issue_body" | grep -qiE '\b(parent|umbrella|roadmap|lifecycle|incident|acceptance criteria)\b'; then
		return 0
	fi

	checklist_count=$(printf '%s' "$issue_body" | grep -cE '^[[:space:]]*[-*+][[:space:]]*\[[ xX]\]' || true)
	[[ "$checklist_count" =~ ^[0-9]+$ ]] || checklist_count=0
	if [[ "$checklist_count" -ge 2 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Extract unchecked acceptance criteria as a Markdown bullet list.
#
# Args: $1=issue body
# Stdout: bullet list (or a conservative fallback)
# Returns: 0 always
#######################################
_pm_unmet_acceptance_criteria() {
	local issue_body="$1"
	local criteria

	criteria=$(printf '%s' "$issue_body" | sed -nE 's/^[[:space:]]*[-*+][[:space:]]*\[[[:space:]]\][[:space:]]*/- /p' | head -20) || criteria=""
	if [[ -z "$criteria" ]]; then
		criteria="- Review the parent issue acceptance criteria and file worker-ready child issues for remaining scope."
	fi
	printf '%s' "$criteria"
	return 0
}

#######################################
# Post partial parent/umbrella closeout when a For/Ref PR merges.
#
# Non-closing references intentionally do not flow through the normal linked
# issue close path. This helper keeps the parent open but leaves an explicit
# closeout trail naming delivered work and follow-ups so broad parents are not
# left ambiguous after a leaf PR merge (GH#23937).
#
# Args: $1=pr_number, $2=repo_slug, $3=merge_summary, $4=linked_issue (optional)
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_handle_partial_parent_closeout() {
	local pr_number="$1"
	local repo_slug="$2"
	local merge_summary="$3"
	local linked_issue="${4:-}"
	local parent_issue="" issue_api="" issue_json="" issue_body="" issue_labels="" dedup_count="" followups="" delivered_body=""

	parent_issue=$(_pm_extract_partial_parent_reference "$pr_number" "$repo_slug") || parent_issue=""
	[[ -n "$parent_issue" ]] || return 0
	[[ "$parent_issue" != "$linked_issue" ]] || return 0

	issue_api=$(_pm_issue_api "$repo_slug" "$parent_issue")
	issue_json=$(gh api "$issue_api" 2>/dev/null) || issue_json=""
	if [[ -z "$issue_json" ]]; then
		return 0
	fi
	local _RS=$'\x1e'
	IFS="$_RS" read -r -d '' issue_body issue_labels < <(
		printf '%s' "$issue_json" | jq -j --arg rs "$_RS" \
			'(.body // ""), $rs, ([.labels[]?.name] | join(",")), "\u0000"'
	) || true

	if ! _pm_issue_needs_partial_closeout "$issue_body" "$issue_labels"; then
		return 0
	fi

	dedup_count=$(gh api "${issue_api}/comments" 2>/dev/null | jq --arg marker "PARTIAL_PARENT_CLOSEOUT:PR#${pr_number}" '[.[] | select(.body | contains($marker))] | length' 2>/dev/null) || dedup_count=0
	[[ "$dedup_count" =~ ^[0-9]+$ ]] || dedup_count=0
	if [[ "$dedup_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: skipped duplicate partial parent closeout on #${parent_issue} for PR #${pr_number} (GH#23937)" >>"$LOGFILE"
		return 0
	fi

	followups=$(_pm_unmet_acceptance_criteria "$issue_body")
	delivered_body="${merge_summary:-PR #${pr_number} merged as a leaf delivery.}"

	local partial_comment
	partial_comment="<!-- PARTIAL_PARENT_CLOSEOUT:PR#${pr_number} -->
## Partial Parent Closeout

PR #${pr_number} merged against this broad parent using a non-closing \`For #${parent_issue}\` / \`Ref #${parent_issue}\` reference, so the parent remains open.

### Delivered

${delivered_body}

### Follow-ups still requiring closure or child issues

${followups}

### Closeout rule

Do not close this parent until the remaining acceptance criteria are covered by merged release evidence or an explicit maintainer/operator closeout decision is posted."

	gh_issue_comment "$parent_issue" --repo "$repo_slug" --body "$partial_comment" 2>/dev/null || true
	echo "[pulse-wrapper] Deterministic merge: posted partial parent closeout on issue #${parent_issue} for PR #${pr_number} (GH#23937)" >>"$LOGFILE"
	return 0
}

_pm_close_primary_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local closing_comment="$4"
	local labels_supplied="$5"

		# t2099 / GH#19032: parent-task close guard. Parent roadmap issues must
		# stay open until ALL phase children merge (t2046). The PR-body keyword
		# guard prevents workers from writing Closes/Resolves/Fixes against a
		# parent, and they instead use "For #NNN" / "Ref #NNN". Keep this
		# independent metadata guard as defence in depth in case a parent PR body
		# accidentally contains a native closing clause.
		#
		# Behaviour:
		#   - Still post the closing comment (it doubles as a phase-merged
		#     status update on the parent).
		#   - SKIP the `gh issue close` call.
		#   - SKIP fast_fail_reset and unlock (both tied to closing).
		_parent_task_guard=0
		local _pm_li_api
		_pm_li_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
		_linked_labels=$(gh api "${_pm_li_api}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || _linked_labels=""
		if [[ ",${_linked_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
			_parent_task_guard=1
			echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task issue #${linked_issue} (PR #${pr_number} is a phase child; parent stays open until all phases merge) — t2099/GH#19032" >>"$LOGFILE"
		fi

		# Dedup guard: skip if closing comment for this PR already exists (GH#18098).
		local _dedup_count
		_dedup_count=$(gh api "${_pm_li_api}/comments" \
			2>/dev/null | jq --arg prnum "PR #${pr_number}" \
			'[.[] | select(.body | contains($prnum))] | length' 2>/dev/null) || _dedup_count=0
		[[ "$_dedup_count" =~ ^[0-9]+$ ]] || _dedup_count=0
		if [[ "$_dedup_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Deterministic merge: skipped duplicate closing comment on #${linked_issue} — PR #${pr_number} already referenced in existing comment (GH#18098)" >>"$LOGFILE"
		else
			gh_issue_comment "$linked_issue" --repo "$repo_slug" \
				--body "$closing_comment" 2>/dev/null || true
		fi

		if [[ "$_parent_task_guard" -eq 0 ]]; then
			if [[ "$labels_supplied" -eq 0 ]]; then
				pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
					--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
			fi
			local _solved_actor=""
			_solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || _solved_actor=""
			[[ -n "$_solved_actor" ]] && set_solved_label "$linked_issue" "$repo_slug" "$_solved_actor" || true
			clear_terminal_issue_dispatch_labels "$linked_issue" "$repo_slug" "post-merge-pr-${pr_number}" || true
			if _gh_with_timeout write gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null; then
				# Closing is not a status transition in GitHub's label model. Converge
				# explicitly so a merged issue cannot remain dashboard-visible as
				# available, queued, claimed, in-progress, or in-review.
				set_issue_status "$linked_issue" "$repo_slug" "done" || true
				reconcile_dependants_after_verified_closure "$repo_slug" "$linked_issue" || true
			fi
			# Reset fast-fail counter now that the issue is resolved (GH#2076)
			fast_fail_reset "$linked_issue" "$repo_slug" || true
			# t1934: Unlock the issue (locked at dispatch time)
			unlock_issue_after_worker "$linked_issue" "$repo_slug"
		fi
	return 0
}

_pm_close_superseded_original_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local closing_comment="$4"
	local _superseded_original_issue
	_superseded_original_issue=$(_pm_resolve_superseded_original_issue \
		"$pr_number" "$repo_slug" "$linked_issue") || _superseded_original_issue=""
	if [[ -n "$_superseded_original_issue" ]]; then
			local _sup_api _sup_labels _sup_parent_guard=0 _sup_dedup_count
			_sup_api=$(_pm_issue_api "$repo_slug" "$_superseded_original_issue")
			_sup_labels=$(gh api "${_sup_api}" \
				--jq '[.labels[].name] | join(",")' 2>/dev/null) || _sup_labels=""
			if [[ ",${_sup_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
				_sup_parent_guard=1
				echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task original issue #${_superseded_original_issue} via superseded PR #${linked_issue} (merged PR #${pr_number}) — GH#22964" >>"$LOGFILE"
			fi

			_sup_dedup_count=$(gh api "${_sup_api}/comments" \
				2>/dev/null | jq --arg prnum "PR #${pr_number}" \
				'[.[] | select(.body | contains($prnum))] | length' 2>/dev/null) || _sup_dedup_count=0
			[[ "$_sup_dedup_count" =~ ^[0-9]+$ ]] || _sup_dedup_count=0
			if [[ "$_sup_dedup_count" -gt 0 ]]; then
				echo "[pulse-wrapper] Deterministic merge: skipped duplicate closing comment on original issue #${_superseded_original_issue} via superseded PR #${linked_issue} — PR #${pr_number} already referenced (GH#22964)" >>"$LOGFILE"
			else
				gh_issue_comment "$_superseded_original_issue" --repo "$repo_slug" \
					--body "$closing_comment" 2>/dev/null || true
			fi

			if [[ "$_sup_parent_guard" -eq 0 ]]; then
				local _sup_solved_actor=""
				_sup_solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || _sup_solved_actor=""
				[[ -n "$_sup_solved_actor" ]] && set_solved_label "$_superseded_original_issue" "$repo_slug" "$_sup_solved_actor" || true
				clear_terminal_issue_dispatch_labels "$_superseded_original_issue" "$repo_slug" "post-merge-superseded-pr-${pr_number}" || true
				if _gh_with_timeout write gh issue close "$_superseded_original_issue" --repo "$repo_slug" 2>/dev/null; then
					set_issue_status "$_superseded_original_issue" "$repo_slug" "done" || true
					reconcile_dependants_after_verified_closure "$repo_slug" "$_superseded_original_issue" || true
				fi
				fast_fail_reset "$_superseded_original_issue" "$repo_slug" || true
				unlock_issue_after_worker "$_superseded_original_issue" "$repo_slug"
			fi
	fi
	return 0
}

_handle_post_merge_actions() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local merge_summary="$4"
	local pr_labels="${5:-}"
	local pr_base_ref_name="${6:-main}"
	local labels_supplied=0
	local _parent_task_guard=0 _linked_labels=""
	[[ $# -ge 5 ]] && labels_supplied=1

	local closing_comment
	closing_comment=$(_pm_build_closing_comment "$pr_number" "$repo_slug" \
		"$linked_issue" "$merge_summary" "$pr_base_ref_name")

	# Upsert one canonical PR closeout across concurrent runner accounts. Linked
	# PR conversation locks are not owned by worker lifecycle cleanup (GH#30280).
	_pm_upsert_pr_closing_comment "$pr_number" "$repo_slug" "$closing_comment"

	if [[ -n "$linked_issue" ]]; then
		_pm_close_primary_linked_issue "$pr_number" "$repo_slug" "$linked_issue" \
			"$closing_comment" "$labels_supplied"
		# GH#22964: close the original issue resolved by a superseded worker PR.
		_pm_close_superseded_original_issue "$pr_number" "$repo_slug" "$linked_issue" \
			"$closing_comment"
	fi

	# Post partial parent closeout if a For/Ref reference exists (GH#23937).
	_pm_handle_partial_parent_closeout "$pr_number" "$repo_slug" "$merge_summary" "$linked_issue"

	# Auto-release interactive claim if one exists for this issue (t2413).
	# Handles the "when a PR they opened merges" release trigger from AGENTS.md
	# so the agent does not have to remember to call release after every merge.
	_release_interactive_claim_on_merge "$pr_number" "$repo_slug" "$linked_issue"

	# Sequential phase auto-filing (t2740 — Gap C): when a phase child PR
	# merges and its linked child issue is closed, inspect the parent-task
	# issue's ## Phases section and auto-file the next phase. Only fires
	# when AIDEVOPS_SEQUENTIAL_PHASE_AUTOFILE=1. Best-effort — failures
	# are logged but do not block the merge completion path.
	if [[ -n "$linked_issue" && "${_parent_task_guard:-0}" -eq 0 ]]; then
		auto_file_next_phase "$linked_issue" "$repo_slug" || true
	fi

	_unblock_circuit_breaker_meta_pr "$linked_issue" "$repo_slug" "${_linked_labels:-}"

	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "${linked_issue:-}" || true
	return 0
}

#######################################
# Circuit-breaker meta-PR cleanup hook (t3076). When the merged PR's
# linked issue carries `circuit-breaker-meta`, delegate to the filer's
# unblock-on-merge subcommand: remove blocked-by:#<meta> from the
# original, clear NMR if no other breaker markers remain, post an
# unblock comment. Idempotent. Best-effort — failures never block
# the merge completion path.
#
# Args: $1=linked_issue, $2=repo_slug, $3=comma-padded labels CSV
# Returns: 0 always
#######################################
_unblock_circuit_breaker_meta_pr() {
	local linked_issue="$1"
	local repo_slug="$2"
	local labels_csv="$3"

	[[ -z "$linked_issue" ]] && return 0
	[[ ",${labels_csv}," == *",circuit-breaker-meta,"* ]] || return 0

	local filer="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/circuit-breaker-meta-filer.sh"
	[[ -x "$filer" ]] || return 0

	"$filer" unblock-on-merge \
		--meta "$linked_issue" --repo "$repo_slug" >>"$LOGFILE" 2>&1 || true
	return 0
}

_pm_pr_labels_mark_intentional_followup() {
	local pr_labels_csv="$1"
	local labels_padded=",${pr_labels_csv},"

	case "$labels_padded" in
	*,intentional-follow-up,* | *,follow-up,* | *,do-not-close,* | *,hold-for-review,* | *,no-auto-dispatch,* | *,needs-maintainer-review,*)
		return 0
		;;
	esac
	return 1
}

_pm_close_superseded_duplicate_pr_if_issue_solved() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_labels_csv="$4"

	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 1
	case ",${pr_labels_csv}," in
	*,origin:worker,* | *,origin:worker-takeover,*) ;;
	*) return 1 ;;
	esac
	if _pm_pr_labels_mark_intentional_followup "$pr_labels_csv"; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} links closed issue #${linked_issue} but has intentional-follow-up/protection label; not closing as duplicate (GH#24399)" >>"$LOGFILE"
		return 1
	fi

	local superseding_pr
	superseding_pr=$(_psh_find_merged_closer_for_closed_issue "$repo_slug" "$linked_issue" "$pr_number" 2>/dev/null) || superseding_pr=""
	[[ "$superseding_pr" =~ ^[0-9]+$ ]] || return 1

	if _gh_with_timeout write gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "Closing as superseded: linked issue #${linked_issue} is already closed by merged PR #${superseding_pr}. This worker PR uses a closing keyword for the same issue, so merging it would duplicate an already-terminal fix.

Intentional follow-ups should use For #${linked_issue} / Ref #${linked_issue} or an explicit follow-up/protection label instead of a closing keyword.

_Closed by deterministic merge pass (GH#24399)._" 2>/dev/null; then
		if declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1; then
			_pulse_merge_invalidate_pr_list_cache "$repo_slug" "closed superseded duplicate PR #${pr_number}"
		fi
	fi
	echo "[pulse-wrapper] Merge pass: closed superseded duplicate PR #${pr_number} in ${repo_slug} — issue #${linked_issue} already closed by merged PR #${superseding_pr} (GH#24399)" >>"$LOGFILE"
	return 0
}

#######################################
# Invalidate repository-scoped PR-list caches after a confirmed terminal PR
# mutation. Invalidation is best-effort and never changes merge/close outcomes.
# Args: $1 = repository slug, $2 = audit reason
#######################################
_pulse_merge_invalidate_pr_list_cache() {
	local repo_slug="$1"
	local reason="$2"
	declare -F pulse_pr_list_cache_invalidate_repo >/dev/null 2>&1 || return 0
	if pulse_pr_list_cache_invalidate_repo "$repo_slug"; then
		echo "[pulse-wrapper] PR-list cache invalidated for ${repo_slug} after ${reason} (GH#28280)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] PR-list cache invalidation failed for ${repo_slug} after ${reason}; fresh terminal-state guards remain active (GH#28280)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Re-read PR state without wrapper caches after a merge failure. A definitive
# CLOSED/MERGED result proves that the cached open-list entry is stale, so evict
# the repository cache and suppress failure remediation for terminal work.
# Args: $1 = PR number, $2 = repository slug
# Returns: 0 when terminal, 1 when OPEN/unknown/read failure
#######################################
_pulse_merge_failure_is_terminal() {
	local pr_number="$1"
	local repo_slug="$2"
	local current_state=""
	current_state=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo_slug" \
		--json state --jq '.state // ""' 2>/dev/null) || current_state=""
	case "$current_state" in
	CLOSED | closed | MERGED | merged)
		_pulse_merge_invalidate_pr_list_cache "$repo_slug" "fresh terminal state ${current_state} for PR #${pr_number}"
		echo "[pulse-wrapper] Deterministic merge: suppressing failed merge remediation for PR #${pr_number} in ${repo_slug} — fresh state=${current_state} is terminal (GH#28280)" >>"$LOGFILE"
		return 0
		;;
	esac
	return 1
}

#######################################
# Process a single PR end-to-end: gate checks, merge attempt,
# conflict detection, and closing comment posting.
#
# Extracted from _merge_ready_prs_for_repo (t2002 / GH#18450, Phase 12).
# Decomposed into focused helpers (GH#18682): _resolve_pr_mergeable_status,
# _check_pr_merge_gates, _handle_post_merge_actions.
# Enables per-PR debugging and unit testing in isolation.
#
# Args:
#   $1 - repo slug
#   $2 - PR JSON object (single element from gh pr list --json output)
# Returns:
#   0 = merged successfully
#   1 = skipped (gate failure or non-mergeable)
#   2 = closed conflicting
#   3 = merge failed
#   4 = native auto-merge requested/deferred; no merge completed this cycle
#######################################
_pmp_stage_parse_and_validate() {
	local record_separator=$'\x1e'
	IFS="$record_separator" read -r pr_number pr_state pr_mergeable pr_review pr_author pr_title pr_updated_at pr_head_ref_oid pr_head_ref_name pr_base_ref_name pr_labels pr_is_draft < <(
		printf '%s' "$pr_obj" | jq -r --arg unknown "$PULSE_UNKNOWN_STATE" \
			'"\(.number // "")\u001e\(.state // "")\u001e\(.mergeable // $unknown)\u001e\(if ((has("reviewDecision") | not) or .reviewDecision == null or (.reviewDecision | tostring | length) == 0) then $unknown else .reviewDecision end)\u001e\(.author.login // "unknown")\u001e\(.title // "")\u001e\(.updatedAt // "")\u001e\(.headRefOid // "")\u001e\(.headRefName // "")\u001e\(.baseRefName // "")\u001e\([(.labels // [])[].name] | join(","))\u001e\(.isDraft // false | tostring)"'
	)
	_pmp_normalize_pr_lifecycle_state_into pr_state "$pr_state"
	_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"
	_pmp_normalize_review_decision_into pr_review "$pr_review"
	[[ -n "$timing_prefix" ]] && _mergeability_start=$(_pmp_now_epoch)
	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
	if [[ "$pr_state" != "OPEN" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — state=${pr_state:-missing} is not OPEN (GH#28279)" >>"$LOGFILE"
		return 1
	fi
	if [[ "$pr_is_draft" == "$PULSE_MERGE_BOOL_TRUE" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible for auto-merge (GH#23525)" >>"$LOGFILE"
		return 1
	fi
	if _pmp_is_protected_release_pr "$pr_head_ref_name" "$pr_labels"; then
		echo "[pulse-wrapper] Merge pass: deferring protected release PR #${pr_number} in ${repo_slug} to provenance-preserving exact-merge reconciliation" >>"$LOGFILE"
		return 4
	fi
	if [[ "$repo_slug" == "${AIDEVOPS_RELEASE_LANE_COORDINATED_REPO:-marcusquinn/aidevops}" ]] \
		&& ! release_lane_merge_guard "$repo_slug" "$pr_number" "$pr_base_ref_name" "$pr_head_ref_name"; then
		echo "[pulse-wrapper] Merge pass: deferring PR #${pr_number} in ${repo_slug} for active exact-tip release lane" >>"$LOGFILE"
		return 1
	fi
	# GH#24634: refresh REST-first UNKNOWN state before conflict handling.
	[[ "$pr_mergeable" != UNKNOWN && -n "$pr_mergeable" ]] || _pmp_refresh_unknown_mergeable_state_into pr_mergeable "$pr_number" "$repo_slug" "$pr_mergeable"
	_pmp_review_decision_is_unknown "$pr_review" && _pmp_refresh_unknown_review_decision_into pr_review "$pr_number" "$repo_slug" "$pr_review"
	return 10
}

_pmp_stage_handle_conflict() {
	local conflict_linked_issue="" conflict_issue_labels="" refetched_mergeable="" conflict_route_rc=0
	[[ "$pr_mergeable" == "CONFLICTING" && "$PULSE_MERGE_CLOSE_CONFLICTING" == "$PULSE_MERGE_BOOL_TRUE" ]] || return 10
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] DRY-RUN: PR #${pr_number} in ${repo_slug} is CONFLICTING; would evaluate rebase, repair routing, or protected close" >>"$LOGFILE"
		return 2
	fi
	conflict_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
	if [[ -n "$conflict_linked_issue" ]]; then
		conflict_issue_labels=$(gh api "repos/${repo_slug}/issues/${conflict_linked_issue}" --jq '[.labels[].name] | join(",")' 2>/dev/null) || conflict_issue_labels=""
		if [[ "$conflict_issue_labels" == *"needs-maintainer-review"* ]]; then
			echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — linked issue #${conflict_linked_issue} has needs-maintainer-review (t2116)" >>"$LOGFILE"
			_post_rebase_nudge_on_worker_conflicting "$pr_number" "$repo_slug" "" "" 2>/dev/null || true
			[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
			return 1
		fi
	fi
	if _attempt_pr_update_branch "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
		refetched_mergeable=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json mergeable --jq ".mergeable // \"${PULSE_UNKNOWN_STATE}\"" 2>/dev/null) || refetched_mergeable="$PULSE_UNKNOWN_STATE"
		pr_mergeable="$refetched_mergeable"
		_pmp_normalize_mergeable_state_into pr_mergeable "$pr_mergeable"
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded, refetched mergeable=${pr_mergeable} (t2116)" >>"$LOGFILE"
	fi
	[[ "$pr_mergeable" == "CONFLICTING" ]] || return 10
	_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$conflict_linked_issue" "conflict" "$pr_labels" "$pr_title" "$pr_updated_at" "$pr_head_ref_oid" || conflict_route_rc=$?
	if [[ "$conflict_route_rc" -eq 0 ]]; then
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
		return 2
	fi
	if [[ "$conflict_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" || "$conflict_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
		return 1
	fi
	if _pulse_route_dependabot_pr_to_worker_issue "$pr_number" "$repo_slug" "$pr_author" "$pr_head_ref_oid" "merge-conflict"; then
		echo "[pulse-wrapper] Merge pass: preserving authentic Dependabot PR #${pr_number} in ${repo_slug} after routing its merge conflict to worker intake (GH#30351)" >>"$LOGFILE"
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
		return 1
	fi
	if _close_conflicting_pr_skip_protected_precheck "$pr_number" "$repo_slug" "$pr_obj"; then
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
		return 1
	fi
	_close_conflicting_pr "$pr_number" "$repo_slug" "$pr_title"
	[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
	return 2
}

_pmp_stage_review_and_gates() {
	local early_linked_issue="" early_dismissed="0"
	if [[ "$pr_review" == "$_changes_requested" ]]; then
		if [[ "${DRY_RUN:-0}" == "1" ]]; then
			echo "[pulse-wrapper] DRY-RUN: PR #${pr_number} in ${repo_slug} has CHANGES_REQUESTED; would evaluate review remediation or repair routing" >>"$LOGFILE"
			return 1
		fi
		early_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || early_linked_issue=""
		if ! _handle_changes_requested_review_gate "$pr_number" "$repo_slug" "$pr_review" "$early_linked_issue" "$pr_labels" early_dismissed _review_gate_mode; then
			if [[ "$_review_gate_mode" != "$_ci_rebase_only" && "$_review_gate_mode" != "$_ci_repair_only" ]]; then
				[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
				return 1
			fi
		fi
		[[ "$early_dismissed" != "1" ]] || pr_review="NONE"
	fi
	if _pmp_review_decision_is_unknown "$pr_review"; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision unavailable after refresh (GH#26218)" >>"$LOGFILE"
		return 1
	fi
	if ! _resolve_pr_mergeable_status "$pr_number" "$repo_slug" "$pr_mergeable"; then
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
		return 1
	fi
	[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}mergeability_s" "$_mergeability_start"
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
	_check_pr_merge_gates "$pr_number" "$repo_slug" "$pr_author" "$pr_review" "$linked_issue" "$pr_labels" "$pr_head_ref_oid" "$_review_gate_mode" || return 1
	if [[ "$_review_gate_mode" != "$_ci_rebase_only" && "$_review_gate_mode" != "$_ci_repair_only" ]] \
		&& [[ "${DRY_RUN:-0}" != "1" ]] \
		&& declare -F _pm_close_superseded_duplicate_pr_if_issue_solved >/dev/null 2>&1 \
		&& _pm_close_superseded_duplicate_pr_if_issue_solved "$pr_number" "$repo_slug" "$linked_issue" "$pr_labels"; then
		return 1
	fi
	if [[ "$_review_gate_mode" == "$_ci_rebase_only" || "$_review_gate_mode" == "$_ci_repair_only" ]]; then
		[[ -n "$timing_prefix" ]] && _branch_protection_start=$(_pmp_now_epoch)
		_handle_review_blocked_ci_repair "$pr_number" "$repo_slug" "$pr_base_ref_name" "$pr_head_ref_oid" "$linked_issue" "$pr_labels" "$pr_updated_at" "$_review_gate_mode" || true
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}branch_protection_s" "$_branch_protection_start"
		return 1
	fi
	return 10
}

_pmp_stage_required_checks() {
	local required_labels="$pr_labels" ci_route_rc=0
	[[ -n "$timing_prefix" ]] && _branch_protection_start=$(_pmp_now_epoch)
	if ! _pr_required_checks_pass "$pr_number" "$repo_slug"; then
		if _is_trusted_dependabot_update_pr "$pr_number" "$repo_slug" "$pr_author" "$pr_head_ref_oid" \
			&& _trusted_dependabot_non_review_checks_green "$pr_number" "$repo_slug" "$pr_obj"; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: _pr_required_checks_pass bypassed for trusted Dependabot — all non-review-bot checks are green (GH#24477)" >>"$LOGFILE"
		elif [[ -n "${_OW_LABEL_PAT:-}" && ",${required_labels}," == *"${_OW_LABEL_PAT:-}"* ]] \
			&& _check_required_checks_passing "$repo_slug" "$pr_number"; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: _pr_required_checks_pass bypassed for origin:worker — branch-protection required contexts all pass (t2922)" >>"$LOGFILE"
		else
			if [[ "${DRY_RUN:-0}" == "1" ]]; then
				echo "[pulse-wrapper] DRY-RUN: PR #${pr_number} in ${repo_slug} has non-passing required checks; would evaluate CI-drift rebase or repair routing" >>"$LOGFILE"
				return 1
			fi
			if _attempt_pr_ci_rebase_retry "$pr_number" "$repo_slug" "$pr_base_ref_name" "$pr_head_ref_oid"; then
				[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}branch_protection_s" "$_branch_protection_start"
				return 1
			fi
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "ci" "$pr_labels" "" "$pr_updated_at" "$pr_head_ref_oid" || ci_route_rc=$?
			if [[ "$ci_route_rc" -eq 1 ]] && _pulse_route_dependabot_pr_to_worker_issue "$pr_number" "$repo_slug" "$pr_author" "$pr_head_ref_oid" "terminal-ci-failure"; then
				echo "[pulse-wrapper] Merge pass: authentic Dependabot PR #${pr_number} in ${repo_slug} has terminal CI failures; routed to worker intake (GH#30351)" >>"$LOGFILE"
			fi
			if [[ "$ci_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" || "$ci_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
				echo "[pulse-wrapper] Merge pass: CI feedback route for PR #${pr_number} in ${repo_slug} remains partial; preserving the PR for retry or maintainer review" >>"$LOGFILE"
			fi
			[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}branch_protection_s" "$_branch_protection_start"
			return 1
		fi
	fi
	[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}branch_protection_s" "$_branch_protection_start"
	return 10
}

_pmp_stage_pre_merge() {
	local preflight_route_rc=0 native_auto_rc=0
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		_pulse_merge_preflight_snapshot_gate "$repo_slug" "$pr_number" "$pr_head_ref_oid" || return 1
		echo "[pulse-wrapper] DRY-RUN: would merge PR #${pr_number} in ${repo_slug} (linked_issue=#${linked_issue:-none})" >>"$LOGFILE"
		return 0
	fi
	_attempt_existing_auto_merge_behind_update_branch "$pr_number" "$repo_slug" && return 1
	_attempt_green_behind_update_branch "$pr_number" "$repo_slug" && return 1
	approve_collaborator_pr "$pr_number" "$repo_slug" "$pr_author" "$pr_head_ref_oid" 2>/dev/null || true
	[[ -n "$timing_prefix" ]] && _ruleset_start=$(_pmp_now_epoch)
	if ! _check_ruleset_required_reviews_passing "$repo_slug" "$pr_number" "$pr_author" "$pr_head_ref_oid"; then
		[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}ruleset_s" "$_ruleset_start"
		return 1
	fi
	[[ -n "$timing_prefix" ]] && _pmp_add_elapsed_seconds "${timing_prefix}ruleset_s" "$_ruleset_start"
	merge_summary=$(_extract_merge_summary "$pr_number" "$repo_slug")
	_retarget_stacked_children "$pr_number" "$repo_slug" "$pr_head_ref_name"
	# #aidevops:trust-boundary — revalidate exact-head authority before mutation.
	if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
		_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
		if [[ "${_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON:-[]}" != "[]" ]]; then
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "ci" "$pr_labels" "" "$pr_updated_at" "$pr_head_ref_oid" "$_PULSE_MERGE_PREFLIGHT_BLOCKING_CHECKS_JSON" || preflight_route_rc=$?
			if [[ "$preflight_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" || "$preflight_route_rc" -eq "${PULSE_FEEDBACK_ROUTE_MAINTAINER_RC:-76}" ]]; then
				echo "[pulse-wrapper] Merge pass: preflight feedback route for PR #${pr_number} in ${repo_slug} remains partial" >>"$LOGFILE"
			fi
		fi
		return 1
	fi
	_set_native_auto_merge_or_skip "$pr_number" "$repo_slug" "${_PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE:-0}" "$pr_review" "$pr_head_ref_oid" || native_auto_rc=$?
	case "$native_auto_rc" in 0) return 4 ;; 2 | 3) return 1 ;; esac
	if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
		_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
		return 1
	fi
	return 10
}

_pmp_stage_admin_merge() {
	local original_output="" missing_output="" missing_exit=0
	merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --admin --match-head-commit "$pr_head_ref_oid" 2>&1)
	_merge_exit=$?
	if [[ $_merge_exit -ne 0 ]] && gh_merge_remediate_stale_auth_cache "$merge_output" "pulse merge PR #${pr_number} in ${repo_slug}" "$LOGFILE"; then
		original_output="$merge_output"
		if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
			_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
			return 1
		fi
		merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --admin --match-head-commit "$pr_head_ref_oid" 2>&1)
		_merge_exit=$?
		[[ $_merge_exit -eq 0 ]] || merge_output="${original_output}

[retry after stale gh cache remediation]
${merge_output}"
	fi
	[[ $_merge_exit -eq 0 ]] || merge_failure_context="[admin merge]
${merge_output}"
	if [[ $_merge_exit -ne 0 && "$merge_output" == *"Required status check"* \
		&& ( "$merge_output" == *" is expected"* || "$merge_output" == *" is pending"* ) ]]; then
		missing_output=$(_pmp_update_branch_rest "$pr_number" "$repo_slug" "$pr_head_ref_oid" 2>&1)
		missing_exit=$?
		if [[ $missing_exit -eq 0 ]]; then
			echo "[pulse-wrapper] Deterministic merge: admin merge reported an expected/pending required status check for PR #${pr_number} in ${repo_slug}; update-branch requested and merge deferred (GH#26899): ${merge_output}" >>"$LOGFILE"
			return 4
		fi
		merge_failure_context="${merge_failure_context}

[missing required-check update-branch fallback]
${missing_output}"
	fi
	return 10
}

_pmp_stage_ruleset_fallback() {
	local auto_output="" auto_exit=0 direct_original=""
	[[ $_merge_exit -ne 0 && "$merge_output" == *"Repository rule violations found"* ]] || return 10
	echo "[pulse-wrapper] Deterministic merge: admin merge hit repository rulesets for PR #${pr_number} in ${repo_slug}; evaluating protection-respecting fallbacks (GH#24438): ${merge_output}" >>"$LOGFILE"
	if [[ "${_PULSE_FINAL_REQUIRES_SYNCHRONOUS_MERGE:-0}" == "1" ]]; then
		auto_output="native auto-merge skipped: mutable external approval state requires synchronous final revalidation"
		auto_exit=1
	elif ! _repo_allows_auto_merge "$repo_slug"; then
		auto_output="native auto-merge skipped: repository does not allow auto-merge (GH#27879)"
		auto_exit=1
	else
		if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
			_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
			return 1
		fi
		auto_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --auto --squash --match-head-commit "$pr_head_ref_oid" 2>&1)
		auto_exit=$?
	fi
	if [[ $auto_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: enabled native auto-merge for PR #${pr_number} in ${repo_slug} after ruleset blocked admin bypass (GH#24438)" >>"$LOGFILE"
		return 0
	fi
	merge_failure_context="${merge_failure_context}

[native auto-merge fallback]
${auto_output}"
	echo "[pulse-wrapper] Deterministic merge: native auto-merge fallback unavailable or failed for PR #${pr_number} in ${repo_slug}; retrying direct merge without --admin (GH#23087): ${auto_output}" >>"$LOGFILE"
	if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
		_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
		return 1
	fi
	merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --match-head-commit "$pr_head_ref_oid" 2>&1)
	_merge_exit=$?
	if [[ $_merge_exit -ne 0 ]] && gh_merge_remediate_stale_auth_cache "$merge_output" "pulse direct merge PR #${pr_number} in ${repo_slug}" "$LOGFILE"; then
		direct_original="$merge_output"
		if ! _pulse_merge_final_trust_gate "$pr_number" "$repo_slug" "$pr_head_ref_oid"; then
			_pulse_merge_maybe_dispatch_preflight_remediation "$pr_number" "$repo_slug"
			return 1
		fi
		merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --match-head-commit "$pr_head_ref_oid" 2>&1)
		_merge_exit=$?
		[[ $_merge_exit -eq 0 ]] || merge_output="${direct_original}

[retry after stale gh cache remediation]
${merge_output}"
	fi
	[[ $_merge_exit -eq 0 ]] || merge_failure_context="${merge_failure_context}

[direct merge fallback]
${merge_output}"
	return 10
}

_pmp_stage_finalize_merge() {
	local labels="$pr_labels" role="collaborator" final_output="$merge_output"
	if [[ $_merge_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: merged PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		declare -F _pulse_merge_invalidate_pr_list_cache >/dev/null 2>&1 && _pulse_merge_invalidate_pr_list_cache "$repo_slug" "merged PR #${pr_number}"
		_pmp_record_deterministic_progress_now 1 0
	fi
	sleep 1
	if [[ $_merge_exit -eq 0 ]]; then
		if [[ "$labels" == *"origin:interactive"* ]]; then
			_is_owner_or_member_author "$pr_author" "$repo_slug" && role="owner-or-member" || true
			echo "[pulse-merge] auto-merged origin:interactive PR #${pr_number} (author=${pr_author}, role=${role})" >>"$LOGFILE"
		fi
		if [[ -n "${_OW_LABEL_PAT:-}" && ",${labels}," == *"${_OW_LABEL_PAT:-}"* ]]; then
			echo "[pulse-merge] auto-merged origin:worker (worker-briefed) PR #${pr_number} (author=${pr_author}, linked_issue=#${linked_issue:-unknown})" >>"$LOGFILE"
		fi
		_handle_post_merge_actions "$pr_number" "$repo_slug" "$linked_issue" "$merge_summary" "$labels" "$pr_base_ref_name"
		return 0
	fi
	if [[ "$merge_output" == *"Merge already in progress"* ]]; then
		echo "[pulse-wrapper] Deterministic merge: PR #${pr_number} in ${repo_slug} already has a merge in progress; counting as merge progress (GH#24383): ${merge_output}" >>"$LOGFILE"
		_handle_post_merge_actions "$pr_number" "$repo_slug" "$linked_issue" "$merge_summary" "$labels" "$pr_base_ref_name"
		return $?
	fi
	if declare -F _pulse_merge_failure_is_terminal >/dev/null 2>&1 && _pulse_merge_failure_is_terminal "$pr_number" "$repo_slug"; then
		return 1
	fi
	[[ -z "$merge_failure_context" ]] || final_output="$merge_failure_context"
	echo "[pulse-wrapper] Deterministic merge: FAILED PR #${pr_number} in ${repo_slug}: ${final_output}" >>"$LOGFILE"
	_pulse_merge_maybe_dispatch_review_thread_remediation "$pr_number" "$repo_slug" "$final_output"
	return 3
}

_process_single_ready_pr() {
	local repo_slug="$1" pr_obj="$2" timing_prefix="${3:-}" stage_rc=0
	local queue_parent_context="${_PULSE_MERGE_QUEUE_CONTEXT:-}"
	local _PULSE_MERGE_QUEUE_CONTEXT="" _PULSE_MERGE_QUEUE_OWNED=0 _PULSE_MERGE_QUEUE_DIRTY=0
	if declare -F _pulse_merge_queue_begin_object >/dev/null 2>&1; then
		_pulse_merge_queue_begin_object "$repo_slug" "$pr_obj" "$queue_parent_context" || return 4
		if [[ "$_PULSE_MERGE_QUEUE_DIRTY" -eq 1 && "${4:-0}" != 1 ]]; then
			_pulse_merge_queue_refresh_object "$repo_slug" pr_obj || { _pulse_merge_queue_finish 1; return 1; }
		fi
	fi
	local pr_number="" pr_state="" pr_mergeable="" pr_review="" pr_author="" pr_title="" pr_updated_at=""
	local pr_head_ref_oid="" pr_head_ref_name="" pr_base_ref_name="" pr_labels="" pr_is_draft="false"
	local _mergeability_start="" _branch_protection_start="" _ruleset_start=""
	local _review_gate_mode="merge" _changes_requested="${PULSE_REVIEW_DECISION_CHANGES_REQUESTED:-CHANGES_REQUESTED}"
	local _ci_rebase_only="${PULSE_REVIEW_GATE_MODE_CI_REBASE_ONLY:-ci-rebase-only}"
	local _ci_repair_only="${PULSE_REVIEW_GATE_MODE_CI_REPAIR_ONLY:-ci-repair-only}"
	local linked_issue="" merge_summary="" merge_output="" merge_failure_context="" _merge_exit=0
	local stage=""
	for stage in _pmp_stage_parse_and_validate _pmp_stage_handle_conflict \
		_pmp_stage_review_and_gates _pmp_stage_required_checks _pmp_stage_pre_merge \
		_pmp_stage_admin_merge _pmp_stage_ruleset_fallback; do
		stage_rc=0
		"$stage" || stage_rc=$?
		if [[ "$stage_rc" -ne 10 ]]; then
			declare -F _pulse_merge_queue_finish >/dev/null 2>&1 && _pulse_merge_queue_finish "$stage_rc"
			return "$stage_rc"
		fi
	done
	stage_rc=0
	_pmp_stage_finalize_merge || stage_rc=$?
	declare -F _pulse_merge_queue_finish >/dev/null 2>&1 && _pulse_merge_queue_finish "$stage_rc"
	return "$stage_rc"
}

#######################################
# Process a single PR by (slug, pr_number) tuple. Webhook entry point (t3038).
#
# Fetches the PR JSON for the given (slug, pr_number) and delegates to
# _process_single_ready_pr. Used by pulse-merge-webhook-receiver.sh to
# fire merge attempts immediately on GitHub webhook events
# (check_suite.completed, pull_request_review.submitted, pull_request.labeled)
# instead of waiting for the next pulse-merge-routine cycle.
#
# The 120s polling loop in pulse-merge-routine.sh remains as backstop —
# webhook-driven merges are an optimization, not a replacement.
#
# Args:
#   $1 - repo slug (owner/repo)
#   $2 - PR number
# Returns:
#   0 = merged successfully
#   1 = skipped (gate failure, non-mergeable, or PR not found)
#   2 = closed conflicting
#   3 = merge failed
#   4 = native auto-merge requested/deferred; no merge completed this cycle
#######################################
process_pr() {
	local repo_slug="$1"
	local pr_number="$2"

	if [[ -z "$repo_slug" || -z "$pr_number" ]]; then
		echo "[pulse-merge] process_pr: missing slug or PR number (slug='${repo_slug}', pr='${pr_number}')" >>"$LOGFILE"
		return 1
	fi
	if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
		echo "[pulse-merge] process_pr: invalid PR number '${pr_number}' for ${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	local queue_parent_context="${_PULSE_MERGE_QUEUE_CONTEXT:-}"
	local _PULSE_MERGE_QUEUE_CONTEXT="" _PULSE_MERGE_QUEUE_OWNED=0 _PULSE_MERGE_QUEUE_DIRTY=0
	if declare -F _pulse_merge_queue_begin >/dev/null 2>&1; then
		_pulse_merge_queue_begin "$repo_slug" "$pr_number" event "$queue_parent_context" || return 4
	fi

	# Fetch the PR JSON in the same shape _merge_ready_prs_for_repo uses and
	# synthesize a single-PR object. _process_single_ready_pr expects a compact
	# JSON object with metadata used by draft, label, stale, and repair-routing
	# gates.
	local pr_obj
	pr_obj=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 AIDEVOPS_GH_REST_FIRST_READS=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json "$(_pulse_merge_ready_pr_json_fields)" 2>/dev/null) || pr_obj=""

	if [[ -z "$pr_obj" || "$pr_obj" == "null" ]]; then
		echo "[pulse-merge] process_pr: gh pr view failed for ${repo_slug}#${pr_number}" >>"$LOGFILE"
		declare -F _pulse_merge_queue_finish >/dev/null 2>&1 && _pulse_merge_queue_finish 1
		return 1
	fi

	# Verify state is OPEN — closed/merged PRs should not be re-processed.
	local pr_state
	pr_state=$(printf '%s' "$pr_obj" | jq -r '.state // ""' 2>/dev/null) || pr_state=""
	_pmp_normalize_pr_lifecycle_state_into pr_state "$pr_state"
	if [[ "$pr_state" != "OPEN" ]]; then
		echo "[pulse-merge] process_pr: PR ${repo_slug}#${pr_number} is not OPEN (state=${pr_state}) — skipping" >>"$LOGFILE"
		local queue_result=1
		case "$pr_state" in CLOSED|MERGED) queue_result=2 ;; esac
		declare -F _pulse_merge_queue_finish >/dev/null 2>&1 && _pulse_merge_queue_finish "$queue_result"
		return 1
	fi

	echo "[pulse-merge] process_pr: webhook-triggered merge attempt for ${repo_slug}#${pr_number} (t3038)" >>"$LOGFILE"
	local process_result=0
	_process_single_ready_pr "$repo_slug" "$pr_obj" "" 1 || process_result=$?
	declare -F _pulse_merge_queue_finish >/dev/null 2>&1 && _pulse_merge_queue_finish "$process_result"
	return "$process_result"
}

#######################################
# Extract linked issue number from a same-repository GitHub-native closing clause
# in the PR body. PR title metadata is not issue identity.
#
# Close keyword matching (GH#18098): only GitHub-native keywords trigger auto-close —
# bare GH#NNN references in "Related" sections do NOT.  GitHub's full keyword list:
# close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved (case-insensitive).
# Cross-repository references use owner/repo#NNN and do not match the local #NNN
# shape below.
#
# Args: $1=PR number, $2=repo slug
# Returns: issue number on stdout, or empty if none found
#######################################
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_body=""
	if ! pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null); then
		echo "[pulse-wrapper] _extract_linked_issue: PR #${pr_number} in ${repo_slug} body metadata unavailable — no routing target" >>"$LOGFILE"
		return 1
	fi

	# Match GitHub-native close keywords in the PR body only (case-insensitive).
	# Matches: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved.
	# Does NOT match bare GH#NNN, "Related #NNN", "For #NNN", "Ref #NNN", or other
	# non-closing references. (GH#18098 + t2108)
	#
	# The body keyword is AUTHORITATIVE. A project-specific GH#NNN title prefix
	# must not override or contradict a single native closing target. (t2108)
	local body_issues="" body_issue=""
	body_issues=$(printf '%s' "$pr_body" \
		| grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u) || body_issues=""

	# No closing keyword in the body → return empty. The PR is intentionally
	# not closing any issue (planning-only PR, multi-PR roadmap, "For #NNN"
	# reference, etc.). _handle_post_merge_actions will skip the close path
	# when this returns empty. (t2108)
	if [[ -z "$body_issues" ]]; then
		return 0
	fi
	if [[ "$body_issues" == *$'\n'* ]]; then
		echo "[pulse-wrapper] _extract_linked_issue: PR #${pr_number} in ${repo_slug} has ambiguous closing issue identities — no routing target" >>"$LOGFILE"
		return 1
	fi
	body_issue="$body_issues"

	printf '%s' "$body_issue"
	return 0
}

#######################################
# Extract the worker's merge summary from PR comments.
#
# Workers post a structured comment tagged with <!-- MERGE_SUMMARY -->
# on the PR at creation time (full-loop.md step 4.2.1). This function
# finds the most recent such comment and returns its body (without the
# HTML tag) for use in closing comments.
#
# Args: $1=PR number, $2=repo slug
# Output: merge summary text on stdout (empty if none found)
#######################################
_extract_merge_summary() {
	local pr_number="$1"
	local repo_slug="$2"

	# Strategy 1: Look for explicit MERGE_SUMMARY tagged comment (richest content)
	local summary
	summary=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | last | .body // empty' \
		2>/dev/null) || summary=""

	if [[ -n "$summary" ]]; then
		# Strip the HTML marker tag
		summary=$(printf '%s' "$summary" | sed 's/<!-- MERGE_SUMMARY -->//')
		# Strip the worker's "written at PR creation time" note if present
		summary=$(printf '%s' "$summary" | sed '/written by the worker at PR creation time/d')
		printf '%s' "$summary"
		return 0
	fi

	# Strategy 2: Extract from PR body (always present, created atomically with PR).
	# Workers skip the MERGE_SUMMARY comment ~65% of the time, but the PR body
	# always contains a useful description of what was done (GH#17503).
	local pr_body
	pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	if [[ -z "$pr_body" ]]; then
		return 0
	fi

	# Strip auto-generated bot content (CodeRabbit, SonarCloud, Codacy, etc.)
	# These start with <!-- This is an auto-generated comment or similar markers
	pr_body=$(printf '%s\n' "$pr_body" | sed '/<!-- This is an auto-generated comment/,$d')

	# Strip Closes/Fixes/Resolves #NNN (the closing comment adds its own PR reference)
	pr_body=$(printf '%s\n' "$pr_body" | sed -E 's/(Closes|Fixes|Resolves) #[0-9]+[[:space:]]*//')

	# Trim leading/trailing blank lines (BSD sed compatible)
	pr_body=$(printf '%s\n' "$pr_body" | sed '/./,$!d' | sed -E '/^[[:space:]]*$/{ N; }' | sed -E '/^[[:space:]]*$/d')

	# Only use if there's meaningful content left (more than just whitespace)
	if [[ -n "$pr_body" ]] && [[ "$(printf '%s' "$pr_body" | tr -d '[:space:]')" != "" ]]; then
		printf '%s' "$pr_body"
	fi

	return 0
}
