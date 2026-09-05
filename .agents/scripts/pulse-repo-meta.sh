#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-repo-meta.sh — Repo metadata accessors and dispatchable issue candidate lists.
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - get_repo_path_by_slug
#   - get_repo_owner_by_slug
#   - get_repo_maintainer_by_slug
#   - get_repo_priority_by_slug
#   - get_repo_role_by_slug (t2145)
#   - repo_allows_pulse_write_actions (t3596)
#   - list_dispatchable_issue_candidates_json
#   - list_dispatchable_issue_candidates

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_REPO_META_LOADED:-}" ]] && return 0
_PULSE_REPO_META_LOADED=1

_PULSE_REPO_ROLE_MAINTAINER="maintainer"
_PULSE_REPO_ROLE_CONTRIBUTOR="contributor"

# shellcheck source=./infrastructure-advisory-lib.sh
# shellcheck disable=SC1091  # sibling library resolved by the orchestrator
source "${SCRIPT_DIR}/infrastructure-advisory-lib.sh"

#######################################
# Resolve managed repo path from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: path via stdout (empty if not found)
#######################################
get_repo_path_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .path // ""' "$REPOS_JSON" 2>/dev/null | head -n 1)
	echo "$repo_path"
	return 0
}

#######################################
# Resolve repo owner login from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: owner login via stdout (empty if invalid)
#######################################
get_repo_owner_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ "$repo_slug" != */* ]]; then
		echo ""
		return 0
	fi

	echo "${repo_slug%%/*}"
	return 0
}

#######################################
# Resolve repo maintainer login from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: maintainer login via stdout (empty if missing)
#######################################
get_repo_maintainer_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .maintainer // ""' "$REPOS_JSON" 2>/dev/null) || maintainer=""
	printf '%s\n' "$maintainer"
	return 0
}

#######################################
# Resolve repo priority class from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: priority via stdout (product/tooling/profile, default tooling)
#######################################
get_repo_priority_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo "tooling"
		return 0
	fi

	local repo_priority
	repo_priority=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .priority // "tooling"' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ -z "$repo_priority" ]]; then
		repo_priority="tooling"
	fi
	printf '%s\n' "$repo_priority"
	return 0
}

#######################################
# Resolve repo role from repos.json
#
# Returns "maintainer" or "contributor". Resolution order:
#   1. Explicit "role" field in repos.json entry
#   2. Configured maintainer or slug owner matches current gh user → maintainer
#   3. Default: contributor (safe default — gates scanners rather than
#      allowing them on repos we don't own)
#
# The role controls which pulse scanners run against the repo:
#   - maintainer: all scanners (review-followup, quality-debt,
#     file-size-debt, function-complexity-debt, complexity scans)
#   - contributor: session-miner and memory-miner only (data only the
#     contributor has). Scanners that operate on repo data the maintainer
#     already has are blocked to avoid NMR noise (t2145, GH#19341).
#
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: role via stdout ("maintainer" or "contributor")
#######################################
get_repo_role_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]]; then
		echo "$_PULSE_REPO_ROLE_CONTRIBUTOR"
		return 0
	fi

	# 1. Explicit role field in repos.json
	local configured_maintainer=""
	if [[ -f "$REPOS_JSON" ]]; then
		local explicit_role
		explicit_role=$(jq -r --arg slug "$repo_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .role // ""' \
			"$REPOS_JSON" 2>/dev/null | head -n 1) || explicit_role=""
		if [[ "$explicit_role" == "$_PULSE_REPO_ROLE_MAINTAINER" || "$explicit_role" == "$_PULSE_REPO_ROLE_CONTRIBUTOR" ]]; then
			printf '%s\n' "$explicit_role"
			return 0
		fi
		configured_maintainer=$(jq -r --arg slug "$repo_slug" \
			'.initialized_repos[] | select(.slug == $slug) | .maintainer // ""' \
			"$REPOS_JSON" 2>/dev/null | head -n 1) || configured_maintainer=""
	fi

	# 2. Auto-detect from configured maintainer or slug owner vs current gh user.
	# Cache the gh user for the process lifetime to avoid repeated API calls.
	if [[ -z "${_CACHED_GH_USER:-}" ]]; then
		_CACHED_GH_USER=$(gh api user --jq '.login' 2>/dev/null) || _CACHED_GH_USER=""
	fi
	local slug_owner="${repo_slug%%/*}"
	if [[ -n "$_CACHED_GH_USER" && ( "$configured_maintainer" == "$_CACHED_GH_USER" || "$slug_owner" == "$_CACHED_GH_USER" ) ]]; then
		echo "$_PULSE_REPO_ROLE_MAINTAINER"
		return 0
	fi

	# 3. Default: contributor (safe — blocks scanners on repos we don't own)
	echo "$_PULSE_REPO_ROLE_CONTRIBUTOR"
	return 0
}

#######################################
# Return success only for repos where pulse may write to GitHub PR/issue state.
# Contributor/read-only repos stay noise-free: session and memory mining remain
# allowed, but merge/stuck/dirty sweeps must not post, label, close, or rebase.
# The live GitHub collaborator permission check is authoritative because public
# issue comments can otherwise succeed for users with no repo relationship.
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: 0 when current runner has admin/maintain/write, 1 otherwise
#######################################
repo_allows_pulse_write_actions() {
	local repo_slug="$1"
	local repo_role=""
	repo_role=$(get_repo_role_by_slug "$repo_slug") || return 1
	[[ "$repo_role" == "$_PULSE_REPO_ROLE_MAINTAINER" ]] || return 1

	# #aidevops:trust-boundary — never rely on repos.json role or successful
	# public comments as authority. Require the authenticated runner to be an
	# admin, maintainer, or write collaborator on the target repo.
	if ! declare -F _gh_current_user_allows_repo_write >/dev/null 2>&1; then
		return 1
	fi
	_gh_current_user_allows_repo_write "$repo_slug"
	return $?
}

#######################################
# Return dispatchable issue candidates as JSON for one repo.
#
# Design: this function is intentionally permissive — it returns all
# open issues that are not in a hard-blocked terminal state. It does NOT
# filter by assignee or active-claim status label. Both are included in
# the output JSON (.assignees and .labels arrays) for use by downstream
# dispatch logic.
#
# The combined "label AND assignee" dedup gate (t1996 canonical rule) is
# enforced downstream by dispatch_with_dedup() → check_dispatch_dedup()
# Layer 6 (dispatch-dedup-helper.sh is-assigned). Applying it here would
# require per-issue API calls on a batch response, which is expensive.
#
# The jq filter excludes only deterministic blockers:
#   - status:blocked (explicit hold)
#   - needs-* (waiting for maintainer action)
#   - supervisor/persistent/routine-tracking (non-work telemetry)
#   - infrastructure + source:ci-failure-miner (operational advisories)
#   - parent-task (decomposition tracker, never directly dispatchable; t2924)
#   - no-auto-dispatch (explicit dispatch opt-out; t2924)
#   - status:in-progress, status:in-review, status:claimed without auto-dispatch
#     (active claims that the dispatcher would otherwise block; t2924)
#   - status:done (completed work, never dispatchable)
# Everything else passes through for the downstream dedup layers to decide.
#
# t2924 rationale: filtering these at candidate-build time (instead of dispatch
# time) avoids re-evaluating the same blocked candidates on every pulse cycle
# (~10s interval). With 200+ candidates and parent-task issues frequently
# appearing in the top of the ranked list, this saves measurable GraphQL+CPU
# per cycle. The dispatch-time check (dispatch-dedup-helper.sh::is-assigned)
# remains as defense-in-depth for the race window between candidate build and
# dispatch.
#
# Auto-dispatch is an explicit worker handoff, so active status labels must not
# hide those issues from stale-assignment recovery. They stay in the candidate
# stream and Layer 6 decides whether the claim is live, stale, or safe to take.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
#   $3 - optional private file for the exact raw open-issue snapshot
#   $4 - optional private file receiving 1 when the snapshot fetch succeeded
#   $5 - dependency normalization mode (optional: normalize or skip; default normalize)
# Returns: JSON array of issue objects (number, title, url, createdAt, updatedAt, labels, assignees)
#######################################
_pulse_issue_snapshot_is_valid() {
	local issue_json="$1"
	[[ -n "$issue_json" && "$issue_json" != "null" ]] || return 1
	printf '%s' "$issue_json" | jq -e --arg array_type array --arg object_type object --arg string_type string '
		type == $array_type and all(.[];
			type == $object_type and
			((.number // .issueNumber // null) as $number |
				if ($number | type) == "number" then
					$number >= 1 and $number <= 9007199254740991 and ($number | floor) == $number
				else false end) and
			(.labels | type) == $array_type and all(.labels[];
				type == $string_type or (type == $object_type and (.name | type) == $string_type and (.name | length) > 0 and (.name | length) <= 100)) and
			(.assignees | type) == $array_type and all(.assignees[];
				type == $string_type or (type == $object_type and (.login | type) == $string_type and (.login | test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$"))))
		)
	' >/dev/null 2>&1 || return 1
	return 0
}

list_dispatchable_issue_candidates_json() {
	local repo_slug="$1"
	local limit="${2:-100}"
	local raw_snapshot_file="${3:-}"
	local snapshot_status_file="${4:-}"
	local dependency_normalization_mode="${5:-normalize}"
	local completeness_file="${6:-}"
	local snapshot_succeeded=1
	[[ -z "$completeness_file" ]] || printf '0\n' >"$completeness_file"

	if [[ -z "$repo_slug" ]]; then
		printf '[]\n'
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	local issue_json issue_dispatch_err gh_exit_code
	issue_dispatch_err=$(mktemp)
	gh_exit_code=0
	issue_json=$(gh_issue_list --repo "$repo_slug" --state open --json number,title,url,assignees,labels,createdAt,updatedAt --limit "$limit" 2>"$issue_dispatch_err") || gh_exit_code=$?
	if [[ "$gh_exit_code" -ne 0 ]] || ! _pulse_issue_snapshot_is_valid "$issue_json"; then
		snapshot_succeeded=0
		local _issue_dispatch_err_msg
		_issue_dispatch_err_msg=$(<"$issue_dispatch_err") || _issue_dispatch_err_msg="unknown error"
		if [[ "$gh_exit_code" -eq 75 || "$_issue_dispatch_err_msg" == *"secondary-rate-limit active=true skip=read"* ]]; then
			printf '[pulse-wrapper] list_dispatchable_issue_candidates: gh_issue_list cooldown skip for %s (exit %s): %s\n' \
				"$repo_slug" "$gh_exit_code" "$_issue_dispatch_err_msg" >>"$LOGFILE"
		else
			printf '[pulse-wrapper] list_dispatchable_issue_candidates: gh_issue_list FAILED for %s (exit %s): %s\n' \
				"$repo_slug" "$gh_exit_code" "$_issue_dispatch_err_msg" >>"$LOGFILE"
		fi
		issue_json="[]"
	fi
	rm -f "$issue_dispatch_err"

	# GH#30180: auto-dispatch is the worker-authorization boundary, not the
	# later spawn boundary. Reconcile from the complete raw open-issue snapshot
	# so queued and dependency-blocked issues are frozen too.
	if [[ "$snapshot_succeeded" -eq 1 ]] && declare -F reconcile_auto_dispatch_issue_locks >/dev/null 2>&1; then
		reconcile_auto_dispatch_issue_locks "$repo_slug" "$issue_json" || {
			printf '[pulse-wrapper] auto-dispatch lock reconciliation failed for %s; affected dispatches remain fail-closed\n' \
				"$repo_slug" >>"$LOGFILE"
		}
	fi

	local candidates_json=""
	candidates_json=$(_filter_dispatchable_issue_candidates_json "$issue_json") || snapshot_succeeded=0

	# Dependency-blocked children are filtered before ranking, so they cannot
	# reach the dispatch-time readiness guard. Normalize once per bounded TTL
	# whenever the fetched snapshot contains blocked work; this also covers a
	# roadmap alongside unrelated runnable candidates.
	if [[ "$dependency_normalization_mode" != "skip" ]] &&
		printf '%s' "$issue_json" | jq -e 'any(.[]; any(.labels[]?; .name == "status:blocked"))' >/dev/null 2>&1 &&
		declare -F normalize_repo_dependency_readiness_if_due >/dev/null 2>&1; then
		normalize_repo_dependency_readiness_if_due "$repo_slug" >/dev/null 2>&1 || true
		local refreshed_issue_json=""
		if ! refreshed_issue_json=$(gh_issue_list --repo "$repo_slug" --state open --json number,title,url,assignees,labels,createdAt,updatedAt --limit "$limit" 2>/dev/null) ||
			! _pulse_issue_snapshot_is_valid "$refreshed_issue_json"; then
			issue_json='[]'
			snapshot_succeeded=0
		else
			issue_json="$refreshed_issue_json"
		fi
		candidates_json=$(_filter_dispatchable_issue_candidates_json "$issue_json") || snapshot_succeeded=0
	fi

	if [[ -n "$raw_snapshot_file" ]]; then
		(
			umask 077
			printf '%s\n' "$issue_json" >"$raw_snapshot_file"
		) || {
			printf '[pulse-wrapper] list_dispatchable_issue_candidates: unable to persist campaign snapshot for %s\n' \
				"$repo_slug" >>"$LOGFILE"
		}
	fi
	if [[ -n "$snapshot_status_file" ]]; then
		(
			umask 077
			printf '%s\n' "$snapshot_succeeded" >"$snapshot_status_file"
		) || true
	fi
	# A successful bounded read is not necessarily complete. Never lend a
	# reserved class's slots based on a failed, malformed or truncated snapshot.
	if [[ -n "$completeness_file" && "$snapshot_succeeded" == 1 ]] &&
		jq -e --argjson limit "$limit" 'length < $limit' <<<"$issue_json" >/dev/null 2>&1; then
		printf '1\n' >"$completeness_file"
	fi

	printf '%s\n' "$candidates_json"
	return 0
}

_filter_dispatchable_issue_candidates_json() {
	local issue_json="$1"
	local infrastructure_advisory_jq="" jq_program=""
	infrastructure_advisory_jq=$(infrastructure_advisory_jq_definition) || {
		printf '[]\n'
		return 1
	}
	# shellcheck disable=SC2016  # jq variables are literal program syntax
	jq_program="${infrastructure_advisory_jq}"$'\n''
		[
			.[] |
			(.labels | map(.name? // .)) as $labels |
			(.assignees | map(.login? // .)) as $assignees |
			# GH#23442: REST /repos/{owner}/{repo}/issues can include pull
			# requests. Keep dispatch candidate enumeration issue-only when
			# gh_issue_list falls back to REST or a wrapper returns mixed results.
			select((.pullRequest // .pull_request // null) == null) |
			select((((.url // "") | tostring | contains("/pull/"))) | not) |
			select(($labels | index("status:blocked")) == null) |
			select(([$labels[] | select(startswith("needs-"))] | length) == 0) |
			select(($labels | index("supervisor")) == null) |
			select(($labels | index("persistent")) == null) |
			select(($labels | index("routine-tracking")) == null) |
			# GH#24152/GH#30928: only CI failure-miner infrastructure advisories are
			# operational alerts. A generic infrastructure label may describe valid
			# implementation work and must remain dispatchable.
			select(($labels | aidevops_infrastructure_advisory) | not) |
			# t2924: filter non-dispatchable management labels at candidate-build
			# time, not dispatch time. Reduces wasted GraphQL+CPU on every pulse cycle
			# re-evaluating issues the dispatcher would always block.
			# The dispatch-time check (dispatch-dedup-helper.sh) remains as
			# defense-in-depth for race conditions where labels are added between
			# candidate build and dispatch.
			select(($labels | index("parent-task")) == null) |
			select(($labels | index("no-auto-dispatch")) == null) |
			(($labels | index($auto_dispatch_label)) != null) as $has_auto_dispatch |
			select((($labels | index("status:in-progress")) == null) or $has_auto_dispatch) |
			select((($labels | index("status:in-review")) == null) or $has_auto_dispatch) |
			select((($labels | index("status:claimed")) == null) or $has_auto_dispatch) |
			select(($labels | index("status:done")) == null) |
			{
				number,
				title,
				url,
				createdAt,
				updatedAt,
				labels: $labels,
				assignees: $assignees
			}
		]
	'
	printf '%s' "$issue_json" | jq -c --arg auto_dispatch_label 'auto-dispatch' \
		"$jq_program" 2>/dev/null || { printf '[]\n'; return 1; }
	return 0
}

#######################################
# List inactive backlog issues that are eligible for dispatch evaluation
# in a single repo.
#
# Candidate rules:
# - open and not blocked
# - exclude any issue carrying a needs-* label (e.g. needs-maintainer-review)
# - include queued/in-progress/in-review states (status labels are not blockers)
# - include assigned issues (assignment state is resolved by dedup/claim checks)
# - exclude supervisor/persistent telemetry issues
#
# Active PR/worker overlap is handled later by deterministic dedup guards.
# This helper only answers: "should the pulse look at this issue at all?"
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
# Returns: pipe-delimited rows number|title|labels|updatedAt
#######################################
list_dispatchable_issue_candidates() {
	local repo_slug="$1"
	local limit="${2:-100}"

	if [[ -z "$repo_slug" ]]; then
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	list_dispatchable_issue_candidates_json "$repo_slug" "$limit" | jq -r '.[] | "\(.number)|\(.title)|\(.labels | join(","))|\(.updatedAt // "")"' 2>/dev/null || true
	return 0
}
