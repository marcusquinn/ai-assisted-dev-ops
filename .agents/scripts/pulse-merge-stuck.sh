#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-merge-stuck.sh — Stuck-merge detector + escalation router (t3193, GH#21895).
#
# This module classifies APPROVED + MERGEABLE PRs that have been sitting
# unmerged past a threshold and either:
#   (a) escalates them with a one-shot worker-ready comment on the linked
#       issue (per-PR; dedup'd by HTML marker), or
#   (b) files an investigation meta-issue when ≥N stuck PRs in the same repo
#       share an identical failure fingerprint (broken-base outage signal),
#       dedup'd by fingerprint hash.
#
# Sourced by pulse-wrapper.sh AFTER pulse-merge.sh, mirroring the
# pulse-merge-conflict.sh / pulse-merge-feedback.sh pattern. Bash's lazy
# function name resolution lets us call _extract_linked_issue (defined in
# pulse-merge.sh) and _gh_idempotent_comment (defined in pulse-triage-cache.sh)
# at runtime without source-time ordering constraints.
#
# Module entry point (called once per pulse cycle, per repo):
#   pulse_merge_stuck_run_pass <repo_slug>
#     Iterates open PRs, increments per-PR/per-cycle counters, fires
#     individual escalations, and detects pattern outages.
#
# Module-internal classifier (returns one of seven string outcomes):
#   _classify_stuck_pr <pr_number> <repo_slug> [is_saturated]
#     STUCK_RUNNER_QUEUE_SATURATION   — required check sits QUEUED while the
#                                       repo's GitHub Actions runner pool is
#                                       saturated (queued > N AND queued/
#                                       in_progress > M); detected only when
#                                       caller passes is_saturated=1 (t3211)
#     STUCK_CHECKS_FAILING            — ≥1 FAILURE in rollup, no conflict
#     STUCK_CONFLICT_NO_NUDGE_LABEL   — CONFLICTING + no origin:interactive
#                                       and no origin:worker (gap in existing
#                                       rebase-nudge family)
#     STUCK_BRANCHPROTECT_404         — default branch unprotected; the
#                                       _check_required_checks_passing
#                                       fail-closed path mis-fires
#     STUCK_BRANCHPROTECT_API_ERROR   — transient 401/5xx from protection API
#     STUCK_AUTH                      — gh auth-failed signature
#     STUCK_OTHER                     — mergeable + approved + idle but no
#                                       distinct signal
#
# Background (t3193):
#   The pulse had rich deterministic merge gates and two narrow stuck-state
#   nudges (pulse-merge-conflict.sh::_post_rebase_nudge_on_*) but no general
#   detector. Operational evidence (managed private webapp repo, 2026-04-30
#   ~14:00Z) showed 8 PRs stuck 9-29h: 6 sharing identical Setup-step CI
#   failures (broken-base signal), 2 docs/migration with mergeStateStatus=DIRTY
#   and no nudge label. No pulse-stats counter trips, no investigation issue
#   filed, no worker dispatched. This module fills that gap.

# Include guard
[[ -n "${_PULSE_MERGE_STUCK_LOADED:-}" ]] && return 0
_PULSE_MERGE_STUCK_LOADED=1

# Module-level variable defaults (set -u guards). When sourced standalone
# (test harness, pulse-merge-routine.sh) the pulse-wrapper.sh bootstrap has
# NOT run; guard each bare var so set -u does not abort.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# Source the pulse-stats helper for gauge/counter writes.
_PULSE_MERGE_STUCK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./pulse-stats-helper.sh
# shellcheck disable=SC1091
source "${_PULSE_MERGE_STUCK_DIR}/pulse-stats-helper.sh"

# Load the exact-output PR-list provider cache for the stuck-merge hot paths.
# pulse-wrapper.sh sources this earlier in normal operation; the include guard
# keeps direct module tests and wrapper sourcing idempotent.
if [[ -f "${_PULSE_MERGE_STUCK_DIR}/pulse-pr-list-cache.sh" ]]; then
	# shellcheck source=./pulse-pr-list-cache.sh
	# shellcheck disable=SC1091
	source "${_PULSE_MERGE_STUCK_DIR}/pulse-pr-list-cache.sh"
fi

# Source the rate-limit / Actions-queue helper for _check_actions_queue_saturation
# (t3211, GH#21942). Defined alongside the GraphQL circuit breaker because both
# concern GitHub-side resource exhaustion. The source is best-effort — if the
# file is missing (e.g. partial deploy), the saturation detection short-circuits
# to disabled and the module degrades to its pre-t3211 behaviour.
if [[ -f "${_PULSE_MERGE_STUCK_DIR}/pulse-rate-limit-circuit-breaker.sh" ]]; then
	# shellcheck source=./pulse-rate-limit-circuit-breaker.sh
	# shellcheck disable=SC1091
	source "${_PULSE_MERGE_STUCK_DIR}/pulse-rate-limit-circuit-breaker.sh"
fi

# Source REST check helpers (GH#21799) so stuck-merge classification does not
# burn GraphQL on statusCheckRollup polling.
if [[ -f "${_PULSE_MERGE_STUCK_DIR}/shared-gh-wrappers-checks.sh" ]]; then
	# shellcheck source=./shared-gh-wrappers-checks.sh
	# shellcheck disable=SC1091
	source "${_PULSE_MERGE_STUCK_DIR}/shared-gh-wrappers-checks.sh"
fi

# Load thresholds from the canonical config file (env vars take precedence).
# The conf file lives at .agents/configs/pulse-merge-stuck.conf; we resolve
# from _PULSE_MERGE_STUCK_DIR (../configs/pulse-merge-stuck.conf).
_PULSE_MERGE_STUCK_CONF="${_PULSE_MERGE_STUCK_DIR}/../configs/pulse-merge-stuck.conf"
if [[ -f "$_PULSE_MERGE_STUCK_CONF" ]]; then
	# Only source values for vars that aren't already set by the env.
	# shellcheck source=/dev/null
	[[ -z "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:-}" ]] &&
		AIDEVOPS_MERGE_STUCK_AGE_MINUTES=$(grep -E '^AIDEVOPS_MERGE_STUCK_AGE_MINUTES=' "$_PULSE_MERGE_STUCK_CONF" 2>/dev/null | tail -1 | cut -d= -f2)
	[[ -z "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-}" ]] &&
		AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=$(grep -E '^AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=' "$_PULSE_MERGE_STUCK_CONF" 2>/dev/null | tail -1 | cut -d= -f2)
	[[ -z "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:-}" ]] &&
		AIDEVOPS_MERGE_PATTERN_MIN_PRS=$(grep -E '^AIDEVOPS_MERGE_PATTERN_MIN_PRS=' "$_PULSE_MERGE_STUCK_CONF" 2>/dev/null | tail -1 | cut -d= -f2)
	[[ -z "${AIDEVOPS_MERGE_STUCK_ENABLED:-}" ]] &&
		AIDEVOPS_MERGE_STUCK_ENABLED=$(grep -E '^AIDEVOPS_MERGE_STUCK_ENABLED=' "$_PULSE_MERGE_STUCK_CONF" 2>/dev/null | tail -1 | cut -d= -f2)
fi

# Hard defaults for any value the conf didn't supply. Validated as positive
# integers downstream — non-numeric here would silently break arithmetic.
: "${AIDEVOPS_MERGE_STUCK_AGE_MINUTES:=240}"
: "${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:=5}"
: "${AIDEVOPS_MERGE_PATTERN_MIN_PRS:=3}"
: "${AIDEVOPS_MERGE_STUCK_ENABLED:=1}"
: "${AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS:=3600}"

# ── Constants (literal-dedup) ────────────────────────────────────────────────
# Counter and gauge names that would otherwise repeat 3+ times in the body
# and trip the pre-commit string-literal ratchet.
readonly _PMS_COUNTER_ESCALATIONS_FILED="pulse_merge_stuck_escalations_filed"
readonly _PMS_COUNTER_QUEUE_SATURATION_EVENTS="pulse_actions_queue_saturation_events"
readonly _PMS_GAUGE_ZERO_PROGRESS_CYCLES='pulse_merge_zero_progress_cycles'
readonly _PMS_GAUGE_ZERO_PROGRESS_RECOVERY_CHECK_TS='pulse_merge_zero_progress_recovery_check_ts'
readonly _PMS_JQ_NULL_GUARD="null"
readonly _PMS_ISSUE_STATE_OPEN="OPEN"

#######################################
# Shared open-PR field shape for stuck-merge list scans.
#
# Keeps the zero-progress counter and stuck detector on one REST-safe provider
# cache key. Exact mergeability and observed active review state are enriched
# per PR before either consumer classifies eligibility.
#######################################
_pms_pr_list_json_fields() {
	printf '%s' 'number,isDraft,labels,author,updatedAt,headRefOid'
	return 0
}

_pms_enrich_pr_state() {
	local repo_slug="$1"
	local pr_json="$2"

	if ! declare -F _pmp_enrich_prs_with_mergeability >/dev/null 2>&1 ||
		! declare -F _pmp_enrich_prs_with_review_decisions >/dev/null 2>&1; then
		printf '%s' "$pr_json"
		return 0
	fi
	pr_json=$(_pmp_enrich_prs_with_mergeability "$repo_slug" "$pr_json")
	pr_json=$(_pmp_enrich_prs_with_review_decisions "$repo_slug" "$pr_json")
	printf '%s' "$pr_json"
	return 0
}

_pms_head_sha_from_pr_json() {
	local pr_json="$1"
	printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null || true
	return 0
}

_pms_head_sha_for_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	gh_pr_view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid // empty' 2>/dev/null || true
	return 0
}
readonly _PMS_RUNNER_SATURATION_MARKER_TEXT="merge-stuck:runner-queue-saturation"
# jq filter snippet that selects normalized REST check entries with a failing
# conclusion/state. Extracted so the upcase predicate is defined exactly once
# and reused across classification, fingerprinting, and escalation guidance.
readonly _PMS_JQ_REST_FAILURE_SELECTOR='def _ueq(f;v): (f // "" | ascii_upcase) == v; select(_ueq(.conclusion; "FAILURE") or _ueq(.conclusion; "TIMED_OUT") or _ueq(.conclusion; "CANCELLED") or _ueq(.state; "FAILURE") or _ueq(.state; "ERROR") or _ueq(.status; "FAILURE"))'

# ── Helpers ──────────────────────────────────────────────────────────────────

# Convert ISO 8601 timestamp to epoch seconds. Bash 3.2 portable; uses GNU
# date if available, falls back to BSD `date -j`. Echoes "0" on failure.
_pms_iso_to_epoch() {
	local iso="$1"
	local result
	result=$(date -d "$iso" +%s 2>/dev/null) ||
		result=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null) ||
		result=0
	[[ "$result" =~ ^[0-9]+$ ]] || result=0
	printf '%s' "$result"
	return 0
}

# Check whether a PR is "merge-eligible but stuck" — APPROVED + MERGEABLE
# (or CONFLICTING with a nudge label gap), not draft, no hold-for-review.
# Echoes "1" if eligible-stuck, "0" otherwise.
#
# Args: $1 = compact PR JSON object (number, mergeable, reviewDecision,
#             isDraft, labels, updatedAt)
_pms_is_eligible_stuck() {
	local pr_obj="$1"
	local mergeable="" review_decision="" is_draft="" labels=""
	mergeable=$(printf '%s' "$pr_obj" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null)
	review_decision=$(printf '%s' "$pr_obj" | jq -r '.reviewDecision // ""' 2>/dev/null)
	is_draft=$(printf '%s' "$pr_obj" | jq -r '.isDraft // false' 2>/dev/null)
	labels=$(printf '%s' "$pr_obj" | jq -r '[.labels[].name] | join(",")' 2>/dev/null)

	# Skip drafts unconditionally
	[[ "$is_draft" == "true" ]] && {
		printf '0'
		return 0
	}
	# Skip hold-for-review opt-out
	[[ "$labels" == *"hold-for-review"* ]] && {
		printf '0'
		return 0
	}
	# CHANGES_REQUESTED is a real review block, not a stuck state
	[[ "$review_decision" == "CHANGES_REQUESTED" ]] && {
		printf '0'
		return 0
	}

	# MERGEABLE + APPROVED is the canonical eligible-stuck path; CONFLICTING
	# without a nudge-eligible label is the gap case we still want to detect.
	if [[ "$mergeable" == "MERGEABLE" && "$review_decision" == "APPROVED" ]]; then
		printf '1'
		return 0
	fi
	if [[ "$mergeable" == "CONFLICTING" ]]; then
		# If neither origin:interactive (handled by existing nudge) nor
		# origin:worker (handled by fix-worker dispatch) is present, this
		# is the no-nudge-label gap.
		if [[ "$labels" != *"origin:interactive"* && "$labels" != *"origin:worker"* ]]; then
			printf '1'
			return 0
		fi
	fi
	printf '0'
	return 0
}

#######################################
# Fetch the effective normalized check set for a PR head SHA.
# Args: $1 = repo_slug, $2 = head SHA
# Stdout: JSON array, [] on missing helper/API failure
#######################################
_pms_check_runs_for_head() {
	local repo_slug="$1"
	local head_sha="$2"
	local runs=""
	local fetch_succeeded=0
	if [[ -n "$repo_slug" && -n "$head_sha" ]] &&
		declare -F _pmp_same_pass_check_evidence_get >/dev/null 2>&1 &&
		runs=$(_pmp_same_pass_check_evidence_get "$repo_slug" "$head_sha" 2>/dev/null); then
		printf '%s' "$runs"
		return 0
	fi
	# The merge preflight snapshot collapses superseded runs and logical aliases
	# to their effective current-head result. Prefer it so an old cancelled or
	# failed run cannot make a subsequently successful PR look broken forever.
	# pulse-merge.sh is sourced before this module in production; the REST helper
	# remains the standalone/test fallback.
	if [[ -n "$repo_slug" && -n "$head_sha" ]] && declare -F _pmrc_snapshot_checks_json >/dev/null 2>&1; then
		if runs=$(_pmrc_snapshot_checks_json "$repo_slug" "$head_sha" 2>/dev/null); then fetch_succeeded=1; fi
	elif [[ -n "$repo_slug" && -n "$head_sha" ]] && declare -F gh_pr_check_runs_rest >/dev/null 2>&1; then
		if runs=$(gh_pr_check_runs_rest "$repo_slug" "$head_sha" 2>/dev/null); then fetch_succeeded=1; fi
	fi
	if [[ -z "$runs" || "$runs" == "null" ]]; then
		runs="[]"
		fetch_succeeded=0
	fi
	if [[ "$fetch_succeeded" -eq 1 ]] && declare -F _pmp_record_same_pass_check_evidence >/dev/null 2>&1; then
		_pmp_record_same_pass_check_evidence "$repo_slug" "$head_sha" "$runs" 2>/dev/null || true
	fi
	printf '%s' "$runs"
	return 0
}

_pms_diagnostic_budget_exhausted() {
	if declare -F _pmp_merge_diagnostics_budget_exhausted >/dev/null 2>&1; then
		_pmp_merge_diagnostics_budget_exhausted
		return $?
	fi
	return 1
}

#######################################
# Count queued checks in normalized REST check-runs JSON.
# Args: $1 = check-runs JSON array
# Stdout: integer count
#######################################
_pms_queued_check_count() {
	local runs_json="$1"
	local count=""
	count=$(printf '%s' "$runs_json" | jq -r \
		'[.[]? | select(
			(.status // "" | ascii_upcase) == "QUEUED"
			and ((.app_slug // .app.slug // "") | IN("github-actions"))
		)] | length' \
		2>/dev/null) || count="0"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

_pms_should_file_runner_saturation_issue() {
	local is_saturated="$1"
	local provider_incident="$2"
	local blocked_count="$3"
	[[ "$blocked_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$is_saturated" == "1" && "$provider_incident" != "1" && "$blocked_count" -gt 0 ]]
	return $?
}

#######################################
# Count failing checks in normalized REST check-runs JSON.
# Args: $1 = check-runs JSON array
# Stdout: integer count
#######################################
_pms_failing_check_count() {
	local runs_json="$1"
	local count=""
	count=$(printf '%s' "$runs_json" | jq -r \
		"[.[]? | ${_PMS_JQ_REST_FAILURE_SELECTOR}] | length" \
		2>/dev/null) || count="0"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s' "$count"
	return 0
}

#######################################
# Format failing check names from normalized REST check-runs JSON.
# Args: $1 = check-runs JSON array
# Stdout: Markdown bullet list, empty if none
#######################################
_pms_failing_check_bullets() {
	local runs_json="$1"
	printf '%s' "$runs_json" | jq -r \
		"[.[]? | ${_PMS_JQ_REST_FAILURE_SELECTOR} | \"- \" + (.name // .context // \"unknown\")] | unique | join(\"\\n\")" \
		2>/dev/null
	return 0
}

# ── Classifier ───────────────────────────────────────────────────────────────

#######################################
# Classify why a stuck PR is stuck. Echoes one of:
#   STUCK_RUNNER_QUEUE_SATURATION  (only when caller passes is_saturated=1)
#   STUCK_CHECKS_FAILING
#   STUCK_CONFLICT_NO_NUDGE_LABEL
#   STUCK_BRANCHPROTECT_404
#   STUCK_BRANCHPROTECT_API_ERROR
#   STUCK_AUTH
#   STUCK_OTHER
#
# The is_saturated parameter is computed once per repo per cycle by the
# caller (pulse_merge_stuck_run_pass) — checking it per-PR would burn
# REST budget. When set to 1, any PR with a QUEUED check in the rollup
# is classified as STUCK_RUNNER_QUEUE_SATURATION (highest priority — the
# QUEUED check would otherwise mask the actual cause).
#
# Args: $1=pr_number, $2=repo_slug, $3=is_saturated, $4=optional PR metadata
# Returns: 0 (always; classification is the stdout)
#######################################
_classify_stuck_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local is_saturated="${3:-0}"

	# Cheap fast paths first. Fetch labels + mergeable + head SHA once. Check
	# state comes from REST check-runs below, not GraphQL statusCheckRollup.
	local pr_meta="${4:-}"
	if [[ -z "$pr_meta" ]]; then
		pr_meta=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json labels,mergeable,headRefOid 2>/dev/null) || pr_meta=""
	fi

	local mergeable="" labels="" head_sha="" check_runs=""
	mergeable=$(printf '%s' "$pr_meta" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null)
	labels=$(printf '%s' "$pr_meta" | jq -r '[.labels[].name] | join(",")' 2>/dev/null)
	head_sha=$(_pms_head_sha_from_pr_json "$pr_meta")
	check_runs=$(_pms_check_runs_for_head "$repo_slug" "$head_sha")

	# Runner queue saturation takes priority when the repo is saturated
	# AND this PR has a QUEUED check in its rollup. This must come BEFORE
	# the FAILURE check below, because checks that have not yet started
	# (.status=QUEUED, .conclusion=null) are not counted as failures by
	# the FAILURE selector but ARE the proximate cause of the stuck state
	# during a runner outage. (t3211)
	if [[ "$is_saturated" == "1" ]]; then
		local has_queued
		has_queued=$(_pms_queued_check_count "$check_runs")
		if [[ "$has_queued" -gt 0 ]]; then
			printf 'STUCK_RUNNER_QUEUE_SATURATION'
			return 0
		fi
	fi

	# Conflict + no nudge label → that gap.
	if [[ "$mergeable" == "CONFLICTING" &&
		"$labels" != *"origin:interactive"* &&
		"$labels" != *"origin:worker"* ]]; then
		printf 'STUCK_CONFLICT_NO_NUDGE_LABEL'
		return 0
	fi

	# Branch protection probe — distinguish 404 from API error.
	local default_branch
	default_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch=""
	if [[ -n "$default_branch" ]]; then
		local protection_resp="" protection_exit=0
		protection_resp=$(gh api \
			"repos/${repo_slug}/branches/${default_branch}/protection/required_status_checks" \
			2>&1)
		protection_exit=$?
		if [[ $protection_exit -ne 0 ]]; then
			# 404 = no classic protection. Org/repo rulesets can still enforce
			# required checks, so mirror pulse-merge-process.sh before treating the
			# branch as unprotected (GH#24935 / GH#23019).
			if grep -qi 'HTTP 404\|Not Found' <<<"$protection_resp"; then
				local ruleset_contexts_404=""
				if declare -F _required_contexts_from_rulesets_for_default_branch >/dev/null 2>&1; then
					local ruleset_contexts_rc=0
					ruleset_contexts_404=$(_required_contexts_from_rulesets_for_default_branch "$repo_slug" "$default_branch") || ruleset_contexts_rc=$?
					if [[ $ruleset_contexts_rc -ne 0 ]]; then
						printf 'STUCK_BRANCHPROTECT_API_ERROR'
						return "$ruleset_contexts_rc"
					fi
					if [[ -n "$ruleset_contexts_404" ]]; then
						echo "[pulse-merge-stuck] _classify_stuck_pr: no classic branch protection on ${repo_slug} (HTTP 404), but active rulesets require contexts; continuing rollup classification (GH#24935)" >>"$LOGFILE"
					else
						printf 'STUCK_BRANCHPROTECT_404'
						return 0
					fi
				else
					printf 'STUCK_BRANCHPROTECT_404'
					return 0
				fi
			else
				# 401 / 403 / 5xx etc — transient or auth break.
				if grep -qi 'HTTP 401\|authentication required\|bad credentials' <<<"$protection_resp"; then
					printf 'STUCK_AUTH'
					return 0
				fi
				printf 'STUCK_BRANCHPROTECT_API_ERROR'
				return 0
			fi
		fi
	fi

	# Rollup contains a FAILURE / FAILED conclusion? Use the shared
	# selector to keep the jq expression DRY across call sites.
	local has_failure
	has_failure=$(_pms_failing_check_count "$check_runs")
	if [[ "$has_failure" -gt 0 ]]; then
		printf 'STUCK_CHECKS_FAILING'
		return 0
	fi

	printf 'STUCK_OTHER'
	return 0
}

# Compute a deterministic failure fingerprint for a PR — sorted set of
# FAILURE check names joined by `|`. Used as the dedup key for the outage
# meta-issue so the same outage signature files exactly one investigation
# issue per cycle.
_pms_failure_fingerprint() {
	local pr_number="$1"
	local repo_slug="$2"
	local head_sha="${3:-}" runs_json=""
	if [[ -z "$head_sha" ]]; then
		head_sha=$(_pms_head_sha_for_pr "$pr_number" "$repo_slug")
	fi
	runs_json=$(_pms_check_runs_for_head "$repo_slug" "$head_sha")

	# Extract names of failing checks, normalize, sort, join. Uses the shared
	# REST failure selector to keep the predicate DRY.
	printf '%s' "$runs_json" | jq -r \
		"[ .[] | ${_PMS_JQ_REST_FAILURE_SELECTOR} | (.name // .context // \"unknown\") ] | sort | unique | join(\",\")" \
		2>/dev/null
}

# Hash a fingerprint string to a short hex digest for the dedup marker.
# Uses sha256sum if available, falls back to shasum or md5 — all produce a
# stable ASCII hex string suitable for an HTML comment.
_pms_hash_fingerprint() {
	local input="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | awk '{print substr($1, 1, 16)}'
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | awk '{print substr($1, 1, 16)}'
	else
		printf '%s' "$input" | md5 | awk '{print substr($1, 1, 16)}'
	fi
}

# Resolve a repository's default branch for worker-facing instructions.
# Falls back to main only when the API is unavailable so generated guidance
# remains usable offline while preferring repo-specific branches like develop.
_pms_default_branch() {
	local repo_slug="$1"
	local default_branch=""

	if [[ -n "$repo_slug" ]]; then
		default_branch=$(gh api "repos/${repo_slug}" --jq '.default_branch' 2>/dev/null) || default_branch=""
	fi
	default_branch="${default_branch:-main}"
	printf '%s' "$default_branch"
	return 0
}

# ── Per-PR escalation (Outcome 3 in brief) ──────────────────────────────────

#######################################
# Post a one-shot worker-ready escalation comment on the PR's linked issue
# describing the stuck classification and the failing checks (when any).
# Idempotent via the <!-- merge-stuck:individual --> marker.
#
# Pre-condition: caller has determined the PR is past the age threshold and
# the classification is STUCK_CHECKS_FAILING (or another individually-
# escalatable outcome); pattern-cluster outages are handled separately by
# _detect_pattern_outage.
#
# Args: $1=pr_number, $2=repo_slug, $3=classification, $4=linked_issue,
#       $5=optional current head SHA
#######################################
_escalate_individual_stuck_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local classification="$3"
	local linked_issue="$4"
	local head_sha="${5:-}"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	# Need either a linked issue (to comment on) OR fall back to the PR
	# itself — the marker prevents repeat fires either way.
	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _escalate_individual_stuck_pr: _gh_idempotent_comment not defined — skipping for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Fetch failing check names for the worker-ready guidance via REST check-runs
	# to avoid GraphQL statusCheckRollup polling in every pulse cycle.
	local failing_checks="" runs_json=""
	if [[ -z "$head_sha" ]]; then
		head_sha=$(_pms_head_sha_for_pr "$pr_number" "$repo_slug")
	fi
	runs_json=$(_pms_check_runs_for_head "$repo_slug" "$head_sha")
	failing_checks=$(_pms_failing_check_bullets "$runs_json")
	[[ -n "$failing_checks" ]] || failing_checks="- (no FAILURE entries in rollup; check rollup manually)"

	local marker="<!-- merge-stuck:individual -->"
	# Bash 3.2 cannot parse `body=$(cat <<EOF ... EOF)` (heredoc-in-subshell —
	# see reference/bash-compat.md). Use the read -r -d '' form instead — the
	# bash 3.2-portable way to slurp a heredoc into a variable. The trailing
	# `|| true` is required because read returns non-zero when no NUL is
	# encountered, which is always (the input is plain text). The variable
	# is still populated. Confirmed working in /bin/bash 3.2 on macOS.
	local body=""
	IFS='' read -r -d '' body <<EOF || true
${marker}
## Stuck-merge detector: PR has been merge-eligible but unmerged past the threshold

The pulse merge pass has classified PR #${pr_number} as \`${classification}\` and it has been sitting unmerged longer than \`AIDEVOPS_MERGE_STUCK_AGE_MINUTES\` (currently ${AIDEVOPS_MERGE_STUCK_AGE_MINUTES}m). The deterministic merge gates are evaluated every cycle (~120s) and this PR has consistently failed them.

### Failing checks on PR #${pr_number}

${failing_checks}

### Worker guidance for the next attempt

1. Read PR #${pr_number} body + the latest check run logs:
   \`\`\`bash
   gh pr checks ${pr_number} --repo ${repo_slug}
   \`\`\`
2. If the failing checks are environment/Setup-step (Format, Lint, Typecheck all FAIL at the same step), the canonical default branch likely has a broken lockfile or a CI infra change — fix at the base, not on this PR. Look for a sibling outage meta-issue in this repo (filed by the same detector) before forking off here.
3. If the failures are PR-specific (e.g. a Typecheck error introduced by this PR's code), rebase onto the latest default branch and address the diagnosed errors. Use \`full-loop-helper.sh start\` from the linked PR's worktree.
4. If the linked issue body lacks the worker-ready file paths and verification commands required by t1900, post a comment naming the missing context before dispatching another worker — the next attempt will burn tokens on exploration otherwise.

### Why you're seeing this

Every pulse cycle (~120s) the deterministic merge pass re-evaluates open PRs. PRs that pass APPROVED + MERGEABLE but fail required checks have historically been re-evaluated silently every cycle until a human noticed. The stuck-merge detector (t3193) surfaces them after \`AIDEVOPS_MERGE_STUCK_AGE_MINUTES\` minutes idle. This comment is posted exactly once per linked issue — repeated stuck cycles will NOT spam the thread. If the PR merges and the issue is reopened later with a fresh stuck PR, the marker will allow a second comment.

<sub>Posted automatically by \`pulse-merge-stuck.sh\` (t3193 / GH#21895). Threshold env: \`AIDEVOPS_MERGE_STUCK_AGE_MINUTES=${AIDEVOPS_MERGE_STUCK_AGE_MINUTES}\`.</sub>
EOF

	# Comment on the linked issue if available, else on the PR itself.
	local comment_target_kind="issue"
	local comment_target_num="$linked_issue"
	if [[ -z "$linked_issue" ]]; then
		comment_target_kind="pr"
		comment_target_num="$pr_number"
	fi

	_gh_idempotent_comment "$comment_target_num" "$repo_slug" "$marker" "$body" "$comment_target_kind" || true
	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	echo "[pulse-merge-stuck] _escalate_individual_stuck_pr: PR #${pr_number} ${classification} (${repo_slug}) — comment posted on ${comment_target_kind}#${comment_target_num}" >>"$LOGFILE"
	return 0
}

# ── Branch protection 404 handler ───────────────────────────────────────────

#######################################
# Increment the 404-skips counter when the detector classified a PR as
# STUCK_BRANCHPROTECT_404. The actual fix for the t2922 mis-fire lives in
# pulse-merge-process.sh::_check_required_checks_passing — this function
# only records the observation so operators can see the rate at which the
# 404 path is hit. Helpful for confirming the t2922 fix has fully landed.
#
# Args: $1=pr_number, $2=repo_slug
#######################################
_handle_stuck_branchprotect_404() {
	local pr_number="$1"
	local repo_slug="$2"
	pulse_stats_increment "pulse_merge_branchprotect_404_skips"
	echo "[pulse-merge-stuck] _handle_stuck_branchprotect_404: PR #${pr_number} in ${repo_slug} — default branch unprotected; counter incremented" >>"$LOGFILE"
	return 0
}

# ── Conflict + no-nudge-label handler ───────────────────────────────────────

#######################################
# Post a label-agnostic rebase nudge for any APPROVED + CONFLICTING PR idle
# past the threshold that lacks both origin:interactive and origin:worker.
# Reuses the existing <!-- pulse-rebase-nudge --> marker so it never double-
# fires alongside _post_rebase_nudge_on_interactive_conflicting.
#
# Args: $1=pr_number, $2=repo_slug
#######################################
_handle_stuck_conflict_no_nudge_label() {
	local pr_number="$1"
	local repo_slug="$2"

	[[ "$pr_number" =~ ^[0-9]+$ && -n "$repo_slug" ]] || return 0

	if ! declare -F _gh_idempotent_comment >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _handle_stuck_conflict_no_nudge_label: _gh_idempotent_comment not defined — skipping nudge for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	local head_branch
	head_branch=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefName --jq '.headRefName' 2>/dev/null) || head_branch="<branch>"
	[[ -n "$head_branch" ]] || head_branch="<branch>"
	local default_branch
	default_branch=$(_pms_default_branch "$repo_slug")

	# Reuse the existing rebase-nudge marker — _gh_idempotent_comment is
	# keyed on the marker string, so this nudge is mutually exclusive with
	# the per-label nudges. (If a label-bearing nudge fired earlier in the
	# PR's life and this label-agnostic nudge would be the second event,
	# the marker prevents the duplicate post.)
	local marker="<!-- pulse-rebase-nudge -->"
	local body
	body="${marker}
## Rebase needed — PR has merge conflicts and no \`origin:*\` label

This PR has merge conflicts against the default branch and lacks both \`origin:interactive\` and \`origin:worker\` labels. The pulse merge pass treats it as the label-agnostic stuck state (t3193) and surfaces it here with a one-shot rebase nudge.

### To resolve

\`\`\`bash
git fetch origin
git checkout ${head_branch}
git rebase origin/${default_branch}
# resolve any conflicts, then:
git push --force-with-lease
\`\`\`

Or use the GitHub web UI's *Update branch* button if the conflicts are trivial enough.

### Why this PR slipped through the existing nudges

The existing rebase-nudge family (\`_post_rebase_nudge_on_interactive_conflicting\`, \`_post_rebase_nudge_on_contributor_conflicting\`, \`_post_rebase_nudge_on_worker_conflicting\`) keys on the \`origin:*\` labels. PRs created without those labels — typically docs/migration commits made directly via the web UI or via a worker that didn't apply its origin label — were silently re-evaluated every cycle without surfacing.

<sub>Posted automatically by \`pulse-merge-stuck.sh\` (t3193 / GH#21895).</sub>"

	_gh_idempotent_comment "$pr_number" "$repo_slug" "$marker" "$body" "pr" || true
	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	echo "[pulse-merge-stuck] _handle_stuck_conflict_no_nudge_label: PR #${pr_number} in ${repo_slug} — label-agnostic nudge posted" >>"$LOGFILE"
	return 0
}

# ── Pattern-cluster outage detector ─────────────────────────────────────────

#######################################
# Format a comma-separated PR list as Markdown bullets. The explicit trailing
# newline ensures the final PR is consumed by read instead of disappearing at
# EOF when the input has no trailing comma.
# Args: $1=comma-separated PR numbers
#######################################
_pms_format_pr_markdown_list() {
	local prs="$1"
	local pr=""
	printf '%s\n' "$prs" | tr ',' '\n' | while IFS= read -r pr; do
		[[ "$pr" =~ ^[0-9]+$ ]] || continue
		printf -- '- #%s\n' "$pr"
	done
	return 0
}

#######################################
# Return success when every failed check in a fingerprint is a per-PR review,
# authority, or policy gate. Those failures need remediation on each PR and
# are not evidence that the shared base branch is broken. A mixed fingerprint
# containing any ordinary CI check remains eligible for outage detection.
# Args: $1=comma-separated failure fingerprint
#######################################
_pms_is_per_pr_gate_fingerprint() {
	local fingerprint="$1"
	local check_name="" normalized="" found=0

	while IFS= read -r check_name; do
		[[ -n "$check_name" ]] || continue
		found=1
		normalized=$(printf '%s' "$check_name" | tr '[:upper:]' '[:lower:]')
		case "$normalized" in
		*coderabbit* | *review-bot* | *"review bot"* | *"maintainer review"* | \
			*"assignee gate"* | *"approval gate"* | *"authority gate"* | \
			*"policy gate"* | *"cryptographic approval"* | *"crypto approval"*) ;;
		*) return 1 ;;
		esac
	done < <(printf '%s\n' "$fingerprint" | tr ',' '\n')

	[[ "$found" -eq 1 ]] || return 1
	return 0
}

#######################################
# Group all stuck PRs in the repo by failure fingerprint. If ≥ AIDEVOPS_MERGE_PATTERN_MIN_PRS
# share an identical fingerprint, file ONE investigation issue per outage signature.
# Dedup'd by the fingerprint hash so the same outage doesn't re-file every cycle.
#
# Args: $1=repo_slug, $2=newline-separated stuck PR numbers, $3=optional PR list
#######################################
_detect_pattern_outage() {
	local repo_slug="$1"
	local stuck_prs="$2"
	local pr_json="${3:-}"

	[[ -z "$stuck_prs" ]] && return 0

	# Build "fingerprint <TAB> pr_number" lines, then group by fingerprint.
	local tmp_lines="" tmp_groups=""
	tmp_lines=$(mktemp "${TMPDIR:-/tmp}/pms-fp-XXXXXX") || return 0
	tmp_groups=$(mktemp "${TMPDIR:-/tmp}/pms-grp-XXXXXX") || {
		rm -f "$tmp_lines"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -f '$tmp_lines' '$tmp_groups'" RETURN

	while IFS= read -r pr_num; do
		[[ -n "$pr_num" ]] || continue
		local fp head_sha=""
		if [[ -n "$pr_json" ]]; then
			head_sha=$(printf '%s' "$pr_json" | jq -r --argjson number "$pr_num" '.[] | select(.number == $number) | .headRefOid // empty' 2>/dev/null) || head_sha=""
		fi
		fp=$(_pms_failure_fingerprint "$pr_num" "$repo_slug" "$head_sha")
		# Skip PRs with no FAILURE entries — those aren't part of an outage cluster.
		[[ -n "$fp" ]] || continue
		if _pms_is_per_pr_gate_fingerprint "$fp"; then
			echo "[pulse-merge-stuck] _detect_pattern_outage: skipping per-PR review/policy fingerprint for PR #${pr_num} in ${repo_slug}: ${fp}" >>"$LOGFILE"
			continue
		fi
		printf '%s\t%s\n' "$fp" "$pr_num" >>"$tmp_lines"
	done <<<"$stuck_prs"

	# Group by fingerprint. Pure bash 3.2 (avoids multi-line awk so the
	# pre-commit positional-parameter validator does not false-positive
	# on awk's `$1`/`$2` field references).
	if [[ -s "$tmp_lines" ]]; then
		local _prev_fp="" _cur_count=0 _cur_prs="" _line_fp _line_pr
		while IFS=$'\t' read -r _line_fp _line_pr; do
			[[ -n "$_line_fp" ]] || continue
			if [[ "$_line_fp" == "$_prev_fp" ]]; then
				_cur_count=$((_cur_count + 1))
				_cur_prs="${_cur_prs},${_line_pr}"
			else
				if [[ -n "$_prev_fp" ]]; then
					printf '%d\t%s\t%s\n' "$_cur_count" "$_prev_fp" "$_cur_prs" >>"$tmp_groups"
				fi
				_prev_fp="$_line_fp"
				_cur_count=1
				_cur_prs="$_line_pr"
			fi
		done < <(sort -u "$tmp_lines")
		# Flush the final group.
		if [[ -n "$_prev_fp" ]]; then
			printf '%d\t%s\t%s\n' "$_cur_count" "$_prev_fp" "$_cur_prs" >>"$tmp_groups"
		fi
	fi

	# Process each group with count >= threshold.
	while IFS=$'\t' read -r count fingerprint prs; do
		[[ "$count" =~ ^[0-9]+$ ]] || continue
		[[ "$count" -ge "$AIDEVOPS_MERGE_PATTERN_MIN_PRS" ]] || continue
		_pms_file_outage_issue "$repo_slug" "$count" "$fingerprint" "$prs"
	done <"$tmp_groups"

	return 0
}

#######################################
# Return success when an open investigation or closed tombstone already owns
# the exact outage fingerprint marker. Open investigations retain the existing
# stale-resolution check; closed markers prevent deterministic re-file churn.
# Args: $1=repo_slug, $2=marker text, $3=fingerprint, $4=fingerprint hash
#######################################
_pms_outage_marker_exists() {
	local repo_slug="$1"
	local marker_text="$2"
	local fingerprint="$3"
	local fp_hash="$4"
	local existing="" existing_state="" existing_record=""

	existing_record=$(gh issue list --repo "$repo_slug" --state all --search "${marker_text}" \
		--limit 100 --json number,state \
		--jq "([.[] | select(.state == \"${_PMS_ISSUE_STATE_OPEN}\")][0] // .[0]) | [(.number // \"\"), (.state // \"\")] | @tsv" \
		2>/dev/null) || existing_record=""
	IFS=$'\t' read -r existing existing_state <<<"$existing_record"
	[[ -n "$existing" && "$existing" != "$_PMS_JQ_NULL_GUARD" ]] || return 1

	if [[ "$existing_state" == "$_PMS_ISSUE_STATE_OPEN" ]]; then
		_pms_maybe_close_resolved_outage_issue "$repo_slug" "$existing" "$fingerprint" || true
	fi
	echo "[pulse-merge-stuck] _pms_file_outage_issue: outage marker ${fp_hash} already exists as ${existing_state:-UNKNOWN} issue #${existing} in ${repo_slug} — skipping" >>"$LOGFILE"
	return 0
}

# Internal: file ONE outage investigation issue (or skip if dedup marker exists).
_pms_file_outage_issue() {
	local repo_slug="$1"
	local count="$2"
	local fingerprint="$3"
	local prs="$4"

	local fp_hash
	fp_hash=$(_pms_hash_fingerprint "$fingerprint")
	local marker_text="merge-stuck:pattern:${fp_hash}"
	local marker="<!-- ${marker_text} -->"
	local default_branch
	default_branch=$(_pms_default_branch "$repo_slug")

	# Dedup against open investigations and closed tombstones for exact hashes.
	if _pms_outage_marker_exists "$repo_slug" "$marker_text" "$fingerprint" "$fp_hash"; then
		return 0
	fi

	# Compose investigation issue body. Use the auto-dispatch + tier:thinking
	# combination (broken base / CI infra needs reasoning) and the
	# source:merge-stuck-detector label so workers can recognize the origin.
	local title="merge-stuck outage: ${count} PRs sharing failure fingerprint in ${repo_slug}"
	local body
	body="${marker}
## What

The pulse stuck-merge detector observed **${count} PRs** in this repo with an identical failure fingerprint:

\`${fingerprint}\`

This is a broken-base outage signal — multiple unrelated PRs failing the same checks at the same step typically means the canonical default branch shipped a regression (broken lockfile, CI infra change, dependency drift, env-var rename). The fix belongs at the base, not on each PR.

## Affected PRs

$(_pms_format_pr_markdown_list "$prs")

## Why

When ≥${AIDEVOPS_MERGE_PATTERN_MIN_PRS} PRs share an identical sorted set of FAILURE check names, the cause is overwhelmingly an upstream CI / base-branch break, not a coincidental cluster of PR-specific bugs. Workers re-dispatched against each PR will burn tokens fixing symptoms; this issue routes the diagnosis to the base.

## How

### Files Scope

Investigation only — no \`Files Scope\` declared. The fix file set will be determined by the diagnosis.

### Investigation steps

1. Reproduce the failing check on a fresh worktree off \`origin/${default_branch}\`:
   \`\`\`bash
   wt switch -c chore/diagnose-merge-stuck-${fp_hash:0:8}
   # Run the same command(s) the failing CI step runs
   \`\`\`
2. If the failure reproduces on a clean ${default_branch}, the base is broken — locate the most recent commit on ${default_branch} that introduced the regression (\`git log --since=24h --first-parent ${default_branch}\`) and either revert or fix forward.
3. If the failure does NOT reproduce on clean ${default_branch}, the cluster is a coincidence (rare) — close this issue with the rationale and let each PR be triaged individually.
4. Once the base is fixed and pushed, the affected PRs above should auto-merge on their next pulse cycle (or rebase via \`gh pr update-branch\`).

### Verification

- The failing check listed in the fingerprint passes on a fresh worktree off \`origin/${default_branch}\`.
- Each affected PR successfully merges or has its remaining failures triaged individually.
- This issue is closed with the resolution PR linked.

## Acceptance

- [ ] Root cause of the shared failure fingerprint is identified.
- [ ] Either: a base-fix PR is merged; or: the cluster is conclusively a coincidence and each PR is triaged individually.
- [ ] All ${count} affected PRs above are unblocked (merged, closed with cause, or have their own follow-up issues).

## Session Origin

Filed automatically by \`pulse-merge-stuck.sh\` (t3193) on detecting a pattern outage of ${count} PRs in ${repo_slug}.

<sub>Source: pulse-merge-stuck-detector. Fingerprint hash: ${fp_hash}. Threshold env: \`AIDEVOPS_MERGE_PATTERN_MIN_PRS=${AIDEVOPS_MERGE_PATTERN_MIN_PRS}\`.</sub>"

	# Use the gh wrapper (auto-injects signature + origin labels). Fail-open
	# on any error — instrumentation must never break the pulse.
	local labels="auto-dispatch,tier:thinking,bug,source:merge-stuck-detector"
	# Wrapper-only — raw `gh issue create` is forbidden by the pre-push
	# guard and would skip origin labelling + signature footer auto-injection.
	# If the wrapper is unavailable (sourcing race / smoke test), log and
	# skip rather than silently file an unlabelled issue.
	if ! declare -F gh_create_issue >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _pms_file_outage_issue: gh_create_issue wrapper unavailable, skipping outage issue for ${repo_slug} fingerprint=${fp_hash}" >>"$LOGFILE"
		return 0
	fi
	gh_create_issue --repo "$repo_slug" \
		--title "$title" \
		--body "$body" \
		--label "$labels" >/dev/null 2>&1 || true
	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	echo "[pulse-merge-stuck] _pms_file_outage_issue: filed outage issue for fingerprint ${fp_hash} (${count} PRs) in ${repo_slug}" >>"$LOGFILE"
	return 0
}

_pms_issue_prs_all_resolved_or_changed() {
	local repo_slug="$1"
	local issue_number="$2"
	local fingerprint="$3"
	local body="" prs="" pr="" unresolved=0

	body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || body=""
	prs=$(printf '%s\n' "$body" | grep -E '^- #[0-9]+' | grep -oE '[0-9]+' || true)
	[[ -n "$prs" ]] || return 1
	while IFS= read -r pr; do
		[[ "$pr" =~ ^[0-9]+$ ]] || continue
		local state="" current_fp="" state_rc=0
		state=$(gh pr view "$pr" --repo "$repo_slug" --json state --jq '.state // ""' 2>/dev/null) || state_rc=$?
		if [[ "$state_rc" -ne 0 || -z "$state" ]]; then
			return 1
		fi
		if [[ "$state" == "$_PMS_ISSUE_STATE_OPEN" ]]; then
			current_fp=$(_pms_failure_fingerprint "$pr" "$repo_slug") || current_fp=""
			[[ -n "$current_fp" ]] || return 1
			if [[ "$current_fp" == "$fingerprint" ]]; then
				unresolved=$((unresolved + 1))
			fi
		fi
	done <<<"$prs"
	[[ "$unresolved" -eq 0 ]] || return 1
	return 0
}

_pms_maybe_close_resolved_outage_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local fingerprint="$3"

	if ! _pms_issue_prs_all_resolved_or_changed "$repo_slug" "$issue_number" "$fingerprint"; then
		return 0
	fi
	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- merge-stuck:auto-close-resolved -->
Closing stale merge-stuck outage: affected PRs are merged/closed or no longer share the original failure fingerprint.

Original fingerprint: ${fingerprint}" >/dev/null 2>&1 || true
	gh issue close "$issue_number" --repo "$repo_slug" --reason completed >/dev/null 2>&1 || true
	echo "[pulse-merge-stuck] auto-closed resolved outage issue #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

# ── Runner queue saturation meta-issue (t3211, GH#21942) ────────────────────

#######################################
# File ONE meta-issue describing GitHub Actions runner queue saturation in the
# repo. Suppression: the caller (pulse_merge_stuck_run_pass) skips per-PR
# escalations for STUCK_RUNNER_QUEUE_SATURATION classifications when this
# function fires, so the meta-issue is the only escalation surface.
# Dedup'd by the fixed marker — saturation is a repo-level signal, not a
# per-fingerprint signal.
#
# Args:
#   $1 - repo_slug
#   $2 - queued (count of queued workflow runs at detection time)
#   $3 - in_progress (count of in-progress workflow runs at detection time)
#   $4 - ratio (integer queued/max(in_progress,1))
#   $5 - affected_prs (comma-separated PR numbers blocked by saturation)
#   $6 - count (length of affected_prs list)
#######################################
# Compose the meta-issue body for runner-saturation. Extracted from
# _pms_file_runner_saturation_issue to keep the caller under the 100-line
# function-complexity gate. The heredoc itself is the bulk of the work;
# isolating it here also makes the body easier to update without
# perturbing the dedup/file/metrics control flow above.
#
# Echoes the composed body to stdout. Caller captures via $().
_pms_compose_runner_saturation_body() {
	local marker="$1" repo_slug="$2" queued="$3" in_progress="$4"
	local ratio="$5" affected_prs="$6" count="$7"
	# read -r -d '' for bash 3.2 portability (heredoc-in-subshell unsupported).
	local body=""
	IFS='' read -r -d '' body <<EOF || true
${marker}
## What

The pulse stuck-merge detector observed **GitHub Actions runner queue saturation** in this repo, blocking **${count} PR(s)** with required checks stuck in QUEUED status:

- Queued workflow runs: **${queued}**
- In-progress workflow runs: **${in_progress}**
- Saturation ratio (queued / max(in_progress,1)): **${ratio}**

Detection thresholds: queued > \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\` AND ratio > \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN:-10}\`. Both conditions held in this cycle.

Per-PR escalation comments are SUPPRESSED for these PRs while saturation persists — the cause is shared (runner pool exhaustion), not per-PR (rebase, fix code). This single meta-issue replaces the N per-PR comments that would otherwise be filed.

## Affected PRs

$(_pms_format_pr_markdown_list "$affected_prs")

## Why

GitHub Actions accounts share a runner pool with rate-limited concurrency. When many workflow runs queue at once (CI cascade triggered by a merge train, bulk push, workflow_dispatch storm, recursive workflow_run trigger), runners are oversubscribed and PRs sit indefinitely with required checks in QUEUED state.

The deterministic merge gate (\`required_status_checks\`) reports these as not-yet-passing — they have not concluded — so PRs that would otherwise auto-merge are blocked. This is distinct from:

- **t2690** (GraphQL points circuit breaker) — GraphQL points and Actions runner-minutes are independent GitHub resource pools.
- **t2922** (fail-closed required-checks) — concerns API errors fetching protection rules, not runner availability.
- **t3193** (per-PR stuck classifications) — surfaces individual PRs with FAILURE checks; saturation is about CHECKS THAT NEVER STARTED.

## How

### Files Scope

Investigation only — the fix is operational (reduce runner load, upgrade plan, prune workflows), not code.

### Investigation steps

1. Confirm saturation persists (run a few minutes after this issue was filed):

\`\`\`bash
gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=1" --jq '.total_count'
gh api "repos/${repo_slug}/actions/runs?status=in_progress&per_page=1" --jq '.total_count'
\`\`\`

2. Identify the source of the queue burst:

\`\`\`bash
gh run list --repo ${repo_slug} --status queued --limit 30 \\
  --json workflowName,headBranch,createdAt
\`\`\`

Group by \`workflowName\` — if one workflow dominates, suspect a runaway loop (workflow_dispatch storm, schedule misfire, recursive \`workflow_run\` trigger, label-cascade — see t2229).

3. Cancel runaway runs if detected:

\`\`\`bash
gh run cancel <run-id> --repo ${repo_slug}
# or bulk:
gh run list --repo ${repo_slug} --status queued --limit 100 \\
  --json databaseId,workflowName --jq '.[] | select(.workflowName=="<runaway>") | .databaseId' \\
  | xargs -I{} gh run cancel {} --repo ${repo_slug}
\`\`\`

4. Check concurrency settings — every workflow that triggers on \`pull_request\` should have a \`concurrency\` block keyed by branch with \`cancel-in-progress: true\` (or \`false\` only when serial execution is required, e.g. Maintainer Gate). Workflows without \`concurrency\` multiply the queue under bursty conditions.

5. If saturation is sustained (recurring across multiple meta-issues), consider:

   - Upgrading the GitHub plan tier (increases runner pool size).
   - Migrating long-running jobs to self-hosted runners.
   - Pruning low-value workflows (e.g. duplicate Python lint jobs running in parallel with the same matrix).

### Verification

- \`gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=1" --jq '.total_count'\` returns ≤ \`${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\`.
- The next pulse cycle does NOT re-fire this meta-issue (saturation cleared).
- Affected PRs above either auto-merge or have their remaining issues triaged individually.

## Acceptance

- [ ] Source of the runner queue burst identified (specific workflow / event / cause).
- [ ] Saturation cleared (queue depth recovered below threshold).
- [ ] All ${count} affected PR(s) above are unblocked (auto-merged, manually merged, or have separate follow-up issues).

## Session Origin

Filed automatically by \`pulse-merge-stuck.sh\` (t3211 / GH#21942) on detecting Actions runner queue saturation in ${repo_slug}. The detector runs once per pulse cycle per repo via \`pulse_merge_stuck_run_pass\`.

<sub>Source: pulse-merge-stuck-detector. Threshold env: \`AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=${AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN:-50}\`, \`AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN=${AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN:-10}\`.</sub>
EOF
	printf '%s' "$body"
	return 0
}

_pms_file_runner_saturation_issue() {
	local repo_slug="$1"
	local queued="$2"
	local in_progress="$3"
	local ratio="$4"
	local affected_prs="$5"
	local count="$6"

	[[ -n "$repo_slug" ]] || return 0
	[[ "$queued" =~ ^[0-9]+$ ]] || queued=0
	[[ "$in_progress" =~ ^[0-9]+$ ]] || in_progress=0
	[[ "$ratio" =~ ^[0-9]+$ ]] || ratio=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0

	local marker_text="${_PMS_RUNNER_SATURATION_MARKER_TEXT}"
	local marker="<!-- ${marker_text} -->"

	# Dedup: search for an OPEN issue with this marker in the affected repo.
	# The same repo's saturation events may recur over hours but only one
	# meta-issue stays open at a time — operators close it after triaging.
	local existing
	existing=$(gh issue list --repo "$repo_slug" --state open --search "${marker_text}" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null)
	if [[ -n "$existing" && "$existing" != "$_PMS_JQ_NULL_GUARD" ]]; then
		echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: marker already filed as #${existing} in ${repo_slug} — skipping" >>"$LOGFILE"
		# Still increment the events counter — saturation IS happening, even
		# if the meta-issue dedup prevents a fresh filing. This way operators
		# can correlate counter spikes with saturation incidents even when
		# only one meta-issue exists.
		pulse_stats_increment "$_PMS_COUNTER_QUEUE_SATURATION_EVENTS"
		return 0
	fi

	# Compose the meta-issue body via the dedicated composer (extracted to
	# keep this function under the function-complexity gate).
	local title="merge-stuck: GitHub Actions runner queue saturated (${queued} queued / ${in_progress} in-progress) in ${repo_slug}"
	local body
	body=$(_pms_compose_runner_saturation_body "$marker" "$repo_slug" \
		"$queued" "$in_progress" "$ratio" "$affected_prs" "$count")

	# Wrapper-only — see _pms_file_outage_issue rationale above.
	if ! declare -F gh_create_issue >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: gh_create_issue wrapper unavailable, skipping for ${repo_slug} (queued=${queued})" >>"$LOGFILE"
		return 0
	fi

	# tier:thinking + bug + auto-dispatch matches the _pms_file_outage_issue
	# convention; source:merge-stuck-detector routes the issue to operators
	# familiar with the detector module.
	local labels="auto-dispatch,tier:thinking,bug,source:merge-stuck-detector"
	gh_create_issue --repo "$repo_slug" \
		--title "$title" \
		--body "$body" \
		--label "$labels" >/dev/null 2>&1 || true

	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	pulse_stats_increment "$_PMS_COUNTER_QUEUE_SATURATION_EVENTS"
	echo "[pulse-merge-stuck] _pms_file_runner_saturation_issue: filed saturation issue for ${repo_slug} (queued=${queued}, in_progress=${in_progress}, ratio=${ratio}, affected=${count})" >>"$LOGFILE"
	return 0
}

# ── Zero-progress meta-issue ────────────────────────────────────────────────

# File ONE meta-issue when consecutive zero-progress cycles cross the threshold.
# The caller invokes this on the crossing edge; open-issue dedupe is a safety net.
# Disabled while the GraphQL circuit-breaker is tripped — the breaker
# already names the root cause and a meta-issue would just be noise.
_pms_file_zero_progress_meta_issue() {
	local zero_cycles="$1"
	local stuck_summary="$2"

	# Skip if the GraphQL circuit-breaker is tripped — its own counter
	# (pulse_dispatch_circuit_broken) is the authoritative signal.
	local _cb_24h
	_cb_24h=$(pulse_stats_get_24h "pulse_dispatch_circuit_broken" 2>/dev/null) || _cb_24h=0
	[[ "$_cb_24h" =~ ^[0-9]+$ ]] || _cb_24h=0
	if [[ "$_cb_24h" -gt 0 ]]; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: skipped — circuit breaker tripped in last 24h" >>"$LOGFILE"
		return 0
	fi

	# Use the framework-routing helper if available — meta-issues belong in
	# the framework repo (marcusquinn/aidevops), not in the affected project.
	local meta_repo="marcusquinn/aidevops"
	local marker="<!-- merge-stuck:zero-progress -->"

	# Dedup: find an OPEN meta-issue with this marker (one is enough — the
	# meta-issue stays open for human triage). Reset cadence: when the
	# meta-issue closes (manually) and the underlying cause recurs, a fresh
	# meta-issue is filed.
	local existing
	existing=$(gh issue list --repo "$meta_repo" --state open --search "merge-stuck:zero-progress" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null)
	if [[ -n "$existing" && "$existing" != "$_PMS_JQ_NULL_GUARD" ]]; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: meta-issue already open as #${existing} — skipping" >>"$LOGFILE"
		return 0
	fi

	local title="merge-stuck: pulse merge throughput collapse (${zero_cycles} consecutive zero-progress cycles)"
	local body
	body="${marker}
## What

The pulse deterministic merge pass has had **${zero_cycles} consecutive cycles** with eligible-unmerged PRs but zero merges. The threshold is \`AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES}\`.

## Why

Eligible-unmerged means \`APPROVED + MERGEABLE + !draft + !hold-for-review\`. When this is non-zero AND the merge count is zero across multiple cycles, the merge pass is structurally blocked — gates failing closed (e.g. branch-protection 404 mis-fire), GraphQL exhaustion, repo-allowlist mismatch, or a regression in the merge gates themselves.

## How

### Files Scope

Investigation only — no \`Files Scope\` declared.

### Snapshot

\`\`\`
${stuck_summary}
\`\`\`

### Investigation steps

1. Read \`~/.aidevops/logs/pulse.log\` since the meta-issue was filed (\`grep 'Merge pass: skipping' \`) — the per-PR skip reason is logged for every cycle.
2. Cross-check \`pulse-stats.json\` for circuit-breaker fires and the \`pulse_merge_branchprotect_404_skips\` counter — if non-zero, the t2922 fail-closed path is mis-firing.
3. Reproduce the merge gate decision for one stuck PR via \`pulse-diagnose-helper.sh pr <N>\` — it explains what the pulse decided and why.
4. Apply the fix (often a one-line gate adjustment) and verify the next cycle drops zero-progress to 0.

## Acceptance

- [ ] Root cause of the throughput collapse identified.
- [ ] At least one of the stuck PRs successfully auto-merges.
- [ ] \`pulse_merge_zero_progress_cycles\` reads 0 in \`pulse-stats.json\`.

## Session Origin

Filed automatically by \`pulse-merge-stuck.sh\` (t3193). The detector resets the zero-progress counter on any successful merge — if the meta-issue is stale (cause already resolved), close it manually.

<sub>Source: pulse-merge-stuck-detector. Threshold env: \`AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES=${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES}\`.</sub>"

	local labels="auto-dispatch,tier:thinking,bug,source:merge-stuck-detector,framework"
	# Wrapper-only — see _pms_file_outage_issue rationale above.
	if ! declare -F gh_create_issue >/dev/null 2>&1; then
		echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: gh_create_issue wrapper unavailable, skipping meta-issue (${zero_cycles} cycles)" >>"$LOGFILE"
		return 0
	fi
	gh_create_issue --repo "$meta_repo" \
		--title "$title" \
		--body "$body" \
		--label "$labels" >/dev/null 2>&1 || true
	pulse_stats_increment "$_PMS_COUNTER_ESCALATIONS_FILED"
	echo "[pulse-merge-stuck] _pms_file_zero_progress_meta_issue: filed meta-issue (${zero_cycles} zero-progress cycles)" >>"$LOGFILE"
	return 0
}

_pms_close_zero_progress_meta_issue_if_recovered() {
	local reason="$1"
	local meta_repo="marcusquinn/aidevops"
	local marker_text="merge-stuck:zero-progress"
	[[ -n "$reason" ]] || reason="merge progress recovered"
	# #aidevops:trust-boundary — public issue comments can succeed for non-collaborators.
	if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 ||
		! repo_allows_pulse_write_actions "$meta_repo"; then
		echo "[pulse-merge-stuck] _pms_close_zero_progress_meta_issue_if_recovered: skipping recovery write in ${meta_repo} — runner lacks repo write permission" >>"$LOGFILE"
		return 0
	fi
	local existing
	existing=$(gh issue list --repo "$meta_repo" --state open --search "$marker_text" \
		--limit 1 --json number --jq '.[0].number' 2>/dev/null) || existing=""
	if [[ -z "$existing" || "$existing" == "$_PMS_JQ_NULL_GUARD" ]]; then
		return 0
	fi
	[[ "$existing" =~ ^[0-9]+$ ]] || return 0

	local body
	body="## Recovery detected

The pulse merge zero-progress detector recovered automatically: ${reason}.

Evidence:
- pulse_merge_zero_progress_cycles was reset to 0.
- A fresh issue is filed only if a new zero-progress streak crosses the threshold.

Closing this stale zero-progress meta-issue so auto-dispatch does not spend worker capacity on an already-recovered incident."

	gh_issue_comment "$existing" --repo "$meta_repo" --body "$body" >/dev/null 2>&1 || true
	gh_issue_close_safe "$existing" --repo "$meta_repo" --reason completed >/dev/null 2>&1 || true
	echo "[pulse-merge-stuck] _pms_close_zero_progress_meta_issue_if_recovered: closed #${existing} — ${reason}" >>"$LOGFILE"
	return 0
}
# Count PRs in $repo_slug that are eligible-but-unmerged this cycle —
# APPROVED + MERGEABLE + !draft + !hold-for-review, then narrowed to PRs
# that are not known to be blocked by the read-only merge gates (NOT age-gated).
# Used by pulse-merge.sh to feed the zero-progress signal across all repos.
#
# Distinct from pulse_merge_stuck_run_pass which adds the AIDEVOPS_MERGE_STUCK_AGE_MINUTES
# age gate — zero-progress detection wants the wider population (any cycle
# with eligible-unmerged > 0 + zero merges is a candidate, regardless of age).
# It must still exclude PRs that the merge pass already proved are not mergeable
# in this cycle (for example failing required checks, origin:interactive PRs
# held for manual merge, or origin:worker PRs with no linked issue), otherwise a
# legitimate skip becomes a false zero-progress structural-block signal.
#
# Args: $1 = repo_slug
# Stdout: integer count
#######################################
# Decide whether a basic eligible PR should contribute to the zero-progress
# denominator. This is intentionally read-only and narrower than the full
# _check_pr_merge_gates stack because that stack can route workers/comments.
#
# Args: $1=repo_slug, $2=pr_number, $3=labels_str (comma-separated), $4=pr_author
# Returns: 0=count it, 1=exclude it from the zero-progress signal
#######################################
_pms_pr_counts_for_zero_progress() {
	local repo_slug="$1"
	local pr_number="$2"
	local labels_str="$3"
	local pr_author="${4:-}"
	local head_sha="${5:-}"

	[[ -n "$repo_slug" && "$pr_number" =~ ^[0-9]+$ ]] || return 1
	local labels_tokenized=",${labels_str},"

	if declare -F _check_required_checks_passing >/dev/null 2>&1; then
		if ! _check_required_checks_passing "$repo_slug" "$pr_number" "$head_sha" >/dev/null 2>&1; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — required checks are not provably passing" >>"$LOGFILE"
			return 1
		fi
	fi

	if [[ "$labels_tokenized" == *",origin:interactive,"* ]]; then
		if ! declare -F _interactive_pr_auto_merge_allowed >/dev/null 2>&1 ||
			! _interactive_pr_auto_merge_allowed "$pr_number" "$repo_slug" "$labels_str" >/dev/null 2>&1; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — origin:interactive PR requires manual merge" >>"$LOGFILE"
			return 1
		fi
	fi

	# Keep parity with pulse-merge.sh::_check_pr_merge_gates external-contributor
	# defence-in-depth. These PRs are intentionally skipped unless a linked issue
	# carries maintainer crypto approval; counting them as eligible can produce a
	# false zero-progress collapse when the merge pass is correctly preserving the
	# trust boundary.
	if [[ "$labels_tokenized" == *",external-contributor,"* ]]; then
		local external_linked_issue=""
		if declare -F _extract_linked_issue >/dev/null 2>&1; then
			external_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || external_linked_issue=""
		fi
		if [[ -z "$external_linked_issue" ]]; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — external-contributor PR has no linked issue" >>"$LOGFILE"
			return 1
		fi
		if ! declare -F _has_maintainer_crypto_approval >/dev/null 2>&1 ||
			! _has_maintainer_crypto_approval "$pr_number" "$repo_slug"; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — external-contributor PR linked issue #${external_linked_issue} lacks crypto approval" >>"$LOGFILE"
			return 1
		fi
	fi

	# Keep the zero-progress denominator aligned with the deterministic merge
	# pass trust gate. A MERGEABLE+APPROVED PR authored by a non-collaborator is
	# intentionally skipped unless a maintainer crypto-approval exists; counting
	# it as eligible creates a false structural-stuck signal when every real merge
	# candidate is already drained.
	if declare -F _is_collaborator_author >/dev/null 2>&1; then
		if ! _is_collaborator_author "$pr_author" "$repo_slug"; then
			if ! declare -F _has_maintainer_crypto_approval >/dev/null 2>&1 ||
				! _has_maintainer_crypto_approval "$pr_number" "$repo_slug"; then
				echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator" >>"$LOGFILE"
				return 1
			fi
		fi
	fi

	if [[ "$labels_tokenized" == *",origin:worker,"* ]]; then
		local linked_issue=""
		if declare -F _extract_linked_issue >/dev/null 2>&1; then
			linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_issue=""
		fi
		if [[ -z "$linked_issue" ]]; then
			echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — origin:worker PR has no linked issue" >>"$LOGFILE"
			return 1
		fi
	fi

	# The shared PR-list snapshot can outlive a concurrent merge pass. Revalidate
	# the remaining candidate through an uncached REST-compatible read so an
	# already-merged PR cannot keep the denominator non-zero or overwrite recovery.
	# If that read is unavailable, retain the cached candidate: API degradation is
	# not evidence that the PR stopped being eligible, and hiding it would mask a
	# real zero-progress incident.
	local current_state=""
	if declare -F gh_pr_view >/dev/null 2>&1; then
		current_state=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh_pr_view "$pr_number" --repo "$repo_slug" \
			--json state --jq '.state // ""' 2>/dev/null) || current_state=""
	else
		current_state=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo_slug" \
			--json state --jq '.state // ""' 2>/dev/null) || current_state=""
	fi
	if [[ -z "$current_state" ]]; then
		echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: retaining PR #${pr_number} in ${repo_slug} — current state is unavailable" >>"$LOGFILE"
		return 0
	fi
	if [[ "$current_state" != "$_PMS_ISSUE_STATE_OPEN" ]]; then
		echo "[pulse-merge-stuck] _pms_count_eligible_unmerged_for_repo: excluding PR #${pr_number} in ${repo_slug} — current state is ${current_state}" >>"$LOGFILE"
		return 1
	fi

	return 0
}

_pms_count_eligible_unmerged_for_repo() {
	local repo_slug="$1"
	[[ -n "$repo_slug" ]] || {
		printf '0'
		return 0
	}
	local same_pass_count=""
	if declare -F _pmp_count_same_pass_eligible_unmerged >/dev/null 2>&1 &&
		same_pass_count=$(_pmp_count_same_pass_eligible_unmerged "$repo_slug" 2>/dev/null); then
		[[ "$same_pass_count" =~ ^[0-9]+$ ]] || return 2
		printf '%s' "$same_pass_count"
		return 0
	fi
	[[ "${AIDEVOPS_PULSE_REQUIRE_SAME_PASS_OUTCOME:-0}" == "1" ]] && return 2

	local pr_json
	pr_json=$(pulse_pr_list_get --repo "$repo_slug" --state open \
		--json "$(_pms_pr_list_json_fields)" \
		--limit 50 2>/dev/null) || pr_json="[]"
	[[ -n "$pr_json" && "$pr_json" != "$_PMS_JQ_NULL_GUARD" ]] || pr_json="[]"
	pr_json=$(_pms_enrich_pr_state "$repo_slug" "$pr_json")

	# Enumerate PRs matching the basic eligibility criteria via jq. .mergeable and
	# .mergeable and .reviewDecision are normalized to upper-case enums. Only a
	# policy-level APPROVED value qualifies; REST history's OBSERVED_APPROVED
	# cannot trigger stuck-PR escalation or sibling-affecting diagnostics.
	local candidates
	candidates=$(printf '%s' "$pr_json" | jq -r '
		[ .[]
		  | select(
			(.mergeable // "") == "MERGEABLE"
			and (.reviewDecision // "") == "APPROVED"
			and (.isDraft // false) == false
			and (([.labels[]?.name] | index("hold-for-review")) == null)
		  )
		  | "\(.number // "")\u001e\([.labels[]?.name] | join(","))\u001e\(.author.login? // "unknown")\u001e\(.headRefOid // "")"
		] | .[]' 2>/dev/null) || candidates=""

	local count=0
	local _RS=$'\x1e'
	local pr_number=""
	local labels_str=""
	local pr_author=""
	local head_sha=""
	while IFS="$_RS" read -r pr_number labels_str pr_author head_sha; do
		[[ -n "$pr_number" ]] || continue
		if _pms_pr_counts_for_zero_progress "$repo_slug" "$pr_number" "$labels_str" "$pr_author" "$head_sha"; then
			count=$((count + 1))
		fi
	done <<<"$candidates"

	printf '%s' "$count"
	return 0
}

#######################################
# Run the stuck-merge detector pass for one repo.
#
# Iterates open PRs, identifies eligible-stuck ones past the age threshold,
# classifies each, fires individual escalations / nudges, then runs the
# pattern-cluster outage detector across the full stuck set.
#
# Updates the gauge `pulse_merge_eligible_stuck_pr_count` to the count of
# eligible-stuck PRs observed in this cycle (across all classifications).
#
# Args: $1 = repo_slug
# Returns: 0 always (instrumentation must not break the pulse)
#######################################
#######################################
# Compute Actions runner-queue saturation state for ONE repo per cycle.
# Extracted from pulse_merge_stuck_run_pass (t3211 / GH#21942) to keep
# the caller under the function-complexity gate.
#
# Echoes 4 lines (KEY=VALUE) the caller parses with grep+cut:
#   queued=N
#   in_progress=N
#   ratio=N
#   saturated=0|1
#
# Fails open if the upstream helper is unavailable (partial deploy):
# echoes the safe defaults (all zeros, saturated=0) so the caller's
# downstream logic degrades to pre-t3211 behaviour.
#######################################
_pms_compute_saturation_state() {
	local repo_slug="$1"

	if ! declare -F _check_actions_queue_saturation >/dev/null 2>&1; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\n'
		return 0
	fi

	local saturation_output=""
	saturation_output=$(_check_actions_queue_saturation "$repo_slug" 2>/dev/null) || saturation_output=""
	if [[ -z "$saturation_output" ]]; then
		printf 'queued=0\nin_progress=0\nratio=0\nsaturated=0\n'
		return 0
	fi

	# Pass through the helper's output verbatim — it already emits the
	# canonical KEY=VALUE format and validates each value against the
	# integer range.
	printf '%s' "$saturation_output"
	return 0
}

#######################################
# Classify ONE eligible-stuck PR and dispatch the matching handler.
# Extracted from pulse_merge_stuck_run_pass (t3211 / GH#21942) to keep
# the caller under the function-complexity gate.
#
# Echoes a routing tag the caller uses to decide on aggregation:
#   SATURATED  — saturation-blocked; caller MUST increment its
#                saturation accumulator. No per-PR escalation was sent.
#   HANDLED    — non-saturation classification; per-PR handler was
#                already invoked. Caller takes no further action.
#
# Args: $1=pr_num  $2=repo_slug  $3=is_saturated (0|1)
#######################################
_pms_handle_classified_pr() {
	local pr_num="$1"
	local repo_slug="$2"
	local is_saturated="$3"
	local pr_meta="${4:-}"
	local head_sha=""
	head_sha=$(_pms_head_sha_from_pr_json "$pr_meta")

	# Pass is_saturated so the classifier can recognise QUEUED checks
	# during a runner outage.
	local classification
	classification=$(_classify_stuck_pr "$pr_num" "$repo_slug" "$is_saturated" "$pr_meta")

	# Fetch linked issue once for the escalation comment.
	local linked_issue=""
	if declare -F _extract_linked_issue >/dev/null 2>&1; then
		linked_issue=$(_extract_linked_issue "$pr_num" "$repo_slug" 2>/dev/null) || linked_issue=""
	fi

	case "$classification" in
	STUCK_RUNNER_QUEUE_SATURATION)
		# Suppress per-PR escalation — caller aggregates for meta-issue.
		echo "[pulse-merge-stuck] _pms_handle_classified_pr: PR #${pr_num} (${repo_slug}) classified STUCK_RUNNER_QUEUE_SATURATION — suppressing per-PR escalation, will aggregate to meta-issue" >>"$LOGFILE"
		printf 'SATURATED'
		;;
	STUCK_BRANCHPROTECT_404)
		_handle_stuck_branchprotect_404 "$pr_num" "$repo_slug"
		printf 'HANDLED'
		;;
	STUCK_CONFLICT_NO_NUDGE_LABEL)
		_handle_stuck_conflict_no_nudge_label "$pr_num" "$repo_slug"
		printf 'HANDLED'
		;;
	STUCK_CHECKS_FAILING | STUCK_BRANCHPROTECT_API_ERROR | STUCK_AUTH | STUCK_OTHER)
		_escalate_individual_stuck_pr "$pr_num" "$repo_slug" "$classification" "$linked_issue" "$head_sha"
		printf 'HANDLED'
		;;
	*)
		printf 'HANDLED'
		;;
	esac
	return 0
}

#######################################
# Classify the eligible-stuck subset while the separate diagnostic budget
# remains available. Partial results are returned for observability only; the
# caller suppresses aggregate writes unless the completion flag remains 1.
# Args: $1=repo, $2=PR JSON, $3=count, $4=now, $5=age threshold,
#       $6=saturated, $7-$11=eligible/stuck/saturation/count/complete vars
#######################################
_pms_classify_stuck_prs_within_budget() {
	local repo_slug="$1"
	local pr_json="$2"
	local pr_count="$3"
	local now_epoch="$4"
	local age_threshold_secs="$5"
	local is_saturated="$6"
	local eligible_var="$7"
	local stuck_numbers_var="$8"
	local saturation_prs_var="$9"
	local saturation_count_var="${10}"
	local complete_var="${11}"
	local output_var=""
	local _classified_eligible=0 _classified_saturation_count=0 _classified_complete=1
	local _classified_stuck_numbers="" _classified_saturation_prs=""
	local i=0

	for output_var in "$eligible_var" "$stuck_numbers_var" "$saturation_prs_var" "$saturation_count_var" "$complete_var"; do
		[[ "$output_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	done
	while [[ "$i" -lt "$pr_count" ]]; do
		if _pms_diagnostic_budget_exhausted; then
			_classified_complete=0
			break
		fi
		local pr_obj="" pr_num="" pr_updated="" pr_age_secs=0 is_stuck=""
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		i=$((i + 1))
		[[ -n "$pr_obj" ]] || continue
		pr_num=$(printf '%s' "$pr_obj" | jq -r '.number // empty' 2>/dev/null)
		[[ "$pr_num" =~ ^[0-9]+$ ]] || continue
		is_stuck=$(_pms_is_eligible_stuck "$pr_obj")
		[[ "$is_stuck" == "1" ]] || continue
		pr_updated=$(printf '%s' "$pr_obj" | jq -r '.updatedAt // empty' 2>/dev/null)
		[[ -n "$pr_updated" ]] || continue
		pr_age_secs=$((now_epoch - $(_pms_iso_to_epoch "$pr_updated")))
		[[ "$pr_age_secs" -ge "$age_threshold_secs" ]] || continue
		_classified_eligible=$((_classified_eligible + 1))
		_classified_stuck_numbers="${_classified_stuck_numbers}${pr_num}\n"
		local route=""
		route=$(_pms_handle_classified_pr "$pr_num" "$repo_slug" "$is_saturated" "$pr_obj")
		if [[ "$route" == "SATURATED" ]]; then
			_classified_saturation_prs="${_classified_saturation_prs}${pr_num},"
			_classified_saturation_count=$((_classified_saturation_count + 1))
		fi
	done
	if _pms_diagnostic_budget_exhausted; then _classified_complete=0; fi
	printf -v "$eligible_var" '%s' "$_classified_eligible"
	printf -v "$stuck_numbers_var" '%s' "$_classified_stuck_numbers"
	printf -v "$saturation_prs_var" '%s' "$_classified_saturation_prs"
	printf -v "$saturation_count_var" '%s' "$_classified_saturation_count"
	printf -v "$complete_var" '%s' "$_classified_complete"
	return 0
}

pulse_merge_stuck_run_pass() {
	local repo_slug="$1"
	local completion_var="${2:-}"
	local pass_complete=1
	if [[ -n "$completion_var" && "$completion_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		printf -v "$completion_var" '%s' '1'
	else
		completion_var=""
	fi

	[[ -n "$repo_slug" ]] || return 0
	[[ "$AIDEVOPS_MERGE_STUCK_ENABLED" == "1" ]] || return 0
	if _pms_diagnostic_budget_exhausted; then
		[[ -n "$completion_var" ]] && printf -v "$completion_var" '%s' '0'
		return 0
	fi

	# Fetch open PRs with the fields the detector needs.
	local pr_json
	pr_json=$(pulse_pr_list_get --repo "$repo_slug" --state open \
		--json "$(_pms_pr_list_json_fields)" \
		--limit 50 2>/dev/null) || pr_json="[]"
	[[ -n "$pr_json" && "$pr_json" != "$_PMS_JQ_NULL_GUARD" ]] || pr_json="[]"
	pr_json=$(_pms_enrich_pr_state "$repo_slug" "$pr_json")

	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -gt 0 ]] || return 0

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	local age_threshold_secs=$((AIDEVOPS_MERGE_STUCK_AGE_MINUTES * 60))

	# Compute Actions runner queue saturation ONCE per repo per cycle (t3211).
	local sat_queued=0 sat_in_progress=0 sat_ratio=0 is_saturated=0 provider_incident=0 saturation_state
	saturation_state=$(_pms_compute_saturation_state "$repo_slug")
	sat_queued=$(printf '%s\n' "$saturation_state" | grep -E '^queued=' | head -1 | cut -d= -f2)
	sat_in_progress=$(printf '%s\n' "$saturation_state" | grep -E '^in_progress=' | head -1 | cut -d= -f2)
	sat_ratio=$(printf '%s\n' "$saturation_state" | grep -E '^ratio=' | head -1 | cut -d= -f2)
	is_saturated=$(printf '%s\n' "$saturation_state" | grep -E '^saturated=' | head -1 | cut -d= -f2)
	provider_incident=$(printf '%s\n' "$saturation_state" | grep -E '^provider_incident=' | head -1 | cut -d= -f2) || provider_incident=0
	[[ "$sat_queued" =~ ^[0-9]+$ ]] || sat_queued=0
	[[ "$sat_in_progress" =~ ^[0-9]+$ ]] || sat_in_progress=0
	[[ "$sat_ratio" =~ ^[0-9]+$ ]] || sat_ratio=0
	[[ "$is_saturated" == "1" ]] || is_saturated=0
	[[ "$provider_incident" == "1" ]] || provider_incident=0
	if _pms_diagnostic_budget_exhausted; then
		[[ -n "$completion_var" ]] && printf -v "$completion_var" '%s' '0'
		return 0
	fi

	# Saturation-blocked PRs aggregated for the meta-issue body (t3211) —
	# per-PR escalation comments are SUPPRESSED for these.
	local eligible_stuck_count=0 saturation_blocked_count=0
	local stuck_pr_numbers="" saturation_blocked_prs=""

	_pms_classify_stuck_prs_within_budget "$repo_slug" "$pr_json" "$pr_count" "$now_epoch" \
		"$age_threshold_secs" "$is_saturated" eligible_stuck_count stuck_pr_numbers \
		saturation_blocked_prs saturation_blocked_count pass_complete || pass_complete=0
	if [[ "$pass_complete" -ne 1 ]]; then
		[[ -n "$completion_var" ]] && printf -v "$completion_var" '%s' '0'
		echo "[pulse-merge-stuck] pulse_merge_stuck_run_pass: ${repo_slug} — separate diagnostic budget exhausted; remaining classification deferred" >>"$LOGFILE"
		return 0
	fi

	# Update the gauge for this cycle's count.
	pulse_stats_set_gauge "pulse_merge_eligible_stuck_pr_count" "$eligible_stuck_count"

	# File the runner-queue-saturation meta-issue if measured saturation was detected
	# AND at least one stuck PR was classified into that bucket. The
	# saturated-but-no-affected-PRs and provider-incident cases are no-ops:
	# neither provides measured runner-pool counts for an actionable repair issue.
	if _pms_should_file_runner_saturation_issue "$is_saturated" "$provider_incident" "$saturation_blocked_count"; then
		# Strip trailing comma from the aggregated PR list.
		saturation_blocked_prs="${saturation_blocked_prs%,}"
		_pms_file_runner_saturation_issue "$repo_slug" \
			"$sat_queued" "$sat_in_progress" "$sat_ratio" \
			"$saturation_blocked_prs" "$saturation_blocked_count" || true
	fi

	# Pattern-cluster detector over the full stuck set.
	if [[ "$eligible_stuck_count" -ge "$AIDEVOPS_MERGE_PATTERN_MIN_PRS" ]]; then
		_detect_pattern_outage "$repo_slug" "$(printf '%b' "$stuck_pr_numbers")" "$pr_json" || true
	fi

	echo "[pulse-merge-stuck] pulse_merge_stuck_run_pass: ${repo_slug} — eligible_stuck=${eligible_stuck_count}, threshold=${AIDEVOPS_MERGE_STUCK_AGE_MINUTES}m, saturated=${is_saturated} (provider_incident=${provider_incident}, queued=${sat_queued}, in_progress=${sat_in_progress}, ratio=${sat_ratio}, blocked_by_saturation=${saturation_blocked_count})" >>"$LOGFILE"
	return 0
}

#######################################
# Close stale zero-progress meta-issues after recovery is already gauged 0.
#
# Covers pulse-stats.json loss/rotation: the next healthy cycle has cur_before=0,
# so the normal transition close path would miss an already-open meta-issue.
# Args: $1 - human-readable recovery reason
#######################################
_pms_close_zero_progress_meta_issue_if_recovered_due() {
	local reason="$1"
	local now_epoch
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0
	local interval="${AIDEVOPS_MERGE_ZERO_PROGRESS_RECOVERY_CHECK_SECONDS:-3600}"
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=3600
	local last_check
	last_check=$(pulse_stats_get_gauge "$_PMS_GAUGE_ZERO_PROGRESS_RECOVERY_CHECK_TS")
	[[ "$last_check" =~ ^[0-9]+$ ]] || last_check=0
	if [[ "$interval" -gt 0 && "$last_check" -gt 0 && $((now_epoch - last_check)) -lt "$interval" ]]; then
		return 0
	fi
	pulse_stats_set_gauge "$_PMS_GAUGE_ZERO_PROGRESS_RECOVERY_CHECK_TS" "$now_epoch"
	_pms_close_zero_progress_meta_issue_if_recovered "$reason"
	return 0
}

#######################################
# Increment the zero-progress counter for the current pulse cycle.
# Called by pulse-merge.sh::merge_ready_prs_all_repos at the END of the
# merge pass — see the wiring there.
#
# When the counter crosses AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES, files a
# meta-issue (dedup'd by marker) describing the throughput collapse.
#
# Reset by any deterministic merge-pass progress: a successful merge or a
# conflicting PR close/remediation action that drained work from the queue.
#
# Args:
#   $1 - count of PRs that were eligible-unmerged this cycle (>0 to count)
#   $2 - count of PRs successfully merged this cycle
#   $3 - count of non-merge deterministic progress actions this cycle
#######################################
pulse_merge_zero_progress_record() {
	local eligible_unmerged="${1:-0}"
	local merged_count="${2:-0}"
	local progress_count="${3:-0}"

	[[ "$eligible_unmerged" =~ ^[0-9]+$ ]] || eligible_unmerged=0
	[[ "$merged_count" =~ ^[0-9]+$ ]] || merged_count=0
	[[ "$progress_count" =~ ^[0-9]+$ ]] || progress_count=0

	local cur_before
	cur_before=$(pulse_stats_get_gauge "$_PMS_GAUGE_ZERO_PROGRESS_CYCLES")
	[[ "$cur_before" =~ ^[0-9]+$ ]] || cur_before=0

	# Any deterministic merge-pass progress resets the counter. Conflict close or
	# remediation progress drains stuck work even when no PR merged in that cycle;
	# keeping the streak alive would file false throughput-collapse meta-issues.
	if [[ "$merged_count" -gt 0 || "$progress_count" -gt 0 ]]; then
		pulse_stats_set_gauge "$_PMS_GAUGE_ZERO_PROGRESS_CYCLES" "0"
		local recovery_reason
		local recovery_suffix="after a ${cur_before}-cycle zero-progress streak"
		if [[ "$cur_before" -le 0 ]]; then
			recovery_suffix="while zero-progress gauge was already 0"
		fi

		if [[ "$merged_count" -gt 0 ]]; then
			recovery_reason="${merged_count} PR(s) merged ${recovery_suffix}"
		else
			recovery_reason="${progress_count} deterministic conflict/close progress action(s) ${recovery_suffix}"
		fi

		if [[ "$cur_before" -gt 0 ]]; then
			_pms_close_zero_progress_meta_issue_if_recovered "$recovery_reason"
		else
			_pms_close_zero_progress_meta_issue_if_recovered_due "$recovery_reason"
		fi
		return 0
	fi

	# No merges + nothing eligible = idle pulse, not a stuck pulse. Reset the
	# streak so the "consecutive zero-progress cycles" signal cannot bridge
	# idle cycles and file a stale throughput-collapse issue later.
	if [[ "$eligible_unmerged" -le 0 ]]; then
		pulse_stats_set_gauge "$_PMS_GAUGE_ZERO_PROGRESS_CYCLES" "0"
		if [[ "$cur_before" -gt 0 ]]; then
			_pms_close_zero_progress_meta_issue_if_recovered "eligible-unmerged dropped to 0 after a ${cur_before}-cycle zero-progress streak"
		else
			_pms_close_zero_progress_meta_issue_if_recovered_due "eligible-unmerged is 0 while zero-progress gauge was already 0"
		fi
		return 0
	fi

	local cur
	cur=$(pulse_stats_get_gauge "$_PMS_GAUGE_ZERO_PROGRESS_CYCLES")
	[[ "$cur" =~ ^[0-9]+$ ]] || cur=0
	cur=$((cur + 1))
	pulse_stats_set_gauge "$_PMS_GAUGE_ZERO_PROGRESS_CYCLES" "$cur"
	local threshold="${AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES:-}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=5
	echo "[pulse-merge-stuck] pulse_merge_zero_progress_record: zero_progress_cycles=${cur}/${threshold}, eligible_unmerged=${eligible_unmerged}" >>"$LOGFILE"

	# File only on the threshold-crossing edge to prevent post-close issue storms.
	if [[ "$cur_before" -lt "$threshold" &&
		"$cur" -ge "$threshold" ]]; then
		local stuck_summary
		stuck_summary=$(pulse_stats_get_gauge "pulse_merge_eligible_stuck_pr_count")
		stuck_summary="eligible_unmerged_this_cycle=${eligible_unmerged}, eligible_stuck_count=${stuck_summary}, zero_progress_cycles=${cur}"
		_pms_file_zero_progress_meta_issue "$cur" "$stuck_summary"
	fi
	return 0
}
