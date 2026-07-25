#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse merge REST state helpers: exact mergeability, review history, and
# update-branch transport without native gh GraphQL reads.

[[ -n "${_PULSE_MERGE_REST_STATE_LOADED:-}" ]] && return 0
_PULSE_MERGE_REST_STATE_LOADED=1

_pmrs_gh_call() {
	local operation="$1"
	shift
	local rc=0

	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout "$operation" "$@" || rc=$?
	else
		"$@" || rc=$?
	fi
	return "$rc"
}

_pmrs_review_max_pages() {
	local max_pages="${AIDEVOPS_PULSE_REVIEW_MAX_PAGES:-10}"
	[[ "$max_pages" =~ ^[0-9]+$ ]] || max_pages=10
	[[ "$max_pages" -ge 1 ]] || max_pages=1
	[[ "$max_pages" -le 100 ]] || max_pages=100
	printf '%s' "$max_pages"
	return 0
}

#######################################
# Normalize PR mergeable values from mixed GitHub API paths.
# Args: $1=raw mergeable value
# Stdout: normalized mergeable enum
#######################################
_pmp_normalize_mergeable_state() {
	local raw_state="$1"
	local normalized_state=""
	case "$raw_state" in
	MERGEABLE|mergeable|true|TRUE) normalized_state="MERGEABLE" ;;
	CONFLICTING|conflicting|false|FALSE) normalized_state="CONFLICTING" ;;
	UNKNOWN|unknown|''|null|NULL) normalized_state="UNKNOWN" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf '%s' "$normalized_state"
	return 0
}

#######################################
# Normalize PR mergeable values into a caller variable.
# Args: $1=destination variable name, $2=raw mergeable value
#######################################
_pmp_normalize_mergeable_state_into() {
	local dest_var="$1"
	local raw_state="$2"
	local normalized_state=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_state" in
	MERGEABLE|mergeable|true|TRUE) normalized_state="MERGEABLE" ;;
	CONFLICTING|conflicting|false|FALSE) normalized_state="CONFLICTING" ;;
	UNKNOWN|unknown|''|null|NULL) normalized_state="UNKNOWN" ;;
	*) normalized_state="$raw_state" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_state"
	return 0
}

#######################################
# Refresh empty/UNKNOWN mergeability through the exact single-PR REST route.
# Args: $1=destination var, $2=PR number, $3=repo slug, $4=current state
#######################################
_pmp_refresh_unknown_mergeable_state_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local current_mergeable="$4"
	local refreshed_mergeable=""
	local refresh_exit=0

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_mergeable_state_into refreshed_mergeable "$current_mergeable"

	if [[ "$refreshed_mergeable" == "UNKNOWN" || -z "$refreshed_mergeable" ]]; then
		refreshed_mergeable=$(AIDEVOPS_GH_REST_FIRST_READS=1 AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 \
			gh_pr_view "$pr_number" --repo "$repo_slug" --json mergeable --jq '.mergeable // ""')
		refresh_exit=$?
		[[ $refresh_exit -eq 0 && -n "$refreshed_mergeable" ]] || refreshed_mergeable="UNKNOWN"
		_pmp_normalize_mergeable_state_into refreshed_mergeable "$refreshed_mergeable"
	fi

	printf -v "$dest_var" '%s' "$refreshed_mergeable"
	return 0
}

#######################################
# Add exact single-PR REST mergeability to every unknown list item.
# Args: $1=repo slug, $2=PR JSON array
#######################################
_pmp_enrich_prs_with_mergeability() {
	local repo_slug="$1"
	local pr_json="$2"
	local enriched_json="$pr_json"
	local rows=""
	local _US=$'\x1f'
	local index="" number="" mergeable=""

	if [[ -z "$repo_slug" ]]; then
		printf '%s' "$pr_json"
		return 0
	fi
	rows=$(printf '%s' "$pr_json" | jq -r '
		if type != "array" then error("expected PR array")
		else to_entries[] | [
			(.key | tostring),
			(if ((.value | has("number") | not) or .value.number == null) then "" else (.value.number | tostring) end),
			(if ((.value | has("mergeable") | not) or .value.mergeable == null or (.value.mergeable | tostring | length) == 0)
			 then "UNKNOWN" else (.value.mergeable | tostring) end)
		] | join("\u001f")
		end' 2>/dev/null) || {
		printf '%s' "$pr_json"
		return 0
	}

	while IFS="$_US" read -r index number mergeable; do
		[[ -n "$index" ]] || continue
		_pmp_normalize_mergeable_state_into mergeable "$mergeable"
		if [[ "$number" =~ ^[0-9]+$ && "$mergeable" == "UNKNOWN" ]]; then
			_pmp_refresh_unknown_mergeable_state_into mergeable "$number" "$repo_slug" "$mergeable"
			enriched_json=$(printf '%s' "$enriched_json" | jq --argjson index "$index" --arg mergeable "$mergeable" '.[$index].mergeable = $mergeable' 2>/dev/null) || {
				printf '%s' "$pr_json"
				return 0
			}
		fi
	done <<<"$rows"

	printf '%s' "$enriched_json"
	return 0
}

_pmp_normalize_review_decision_into() {
	local dest_var="$1"
	local raw_decision="$2"
	local normalized_decision=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	case "$raw_decision" in
	CHANGES_REQUESTED|APPROVED|OBSERVED_APPROVED|REVIEW_REQUIRED|NONE) normalized_decision="$raw_decision" ;;
	changes_requested) normalized_decision="CHANGES_REQUESTED" ;;
	approved) normalized_decision="APPROVED" ;;
	observed_approved) normalized_decision="OBSERVED_APPROVED" ;;
	review_required) normalized_decision="REVIEW_REQUIRED" ;;
	none) normalized_decision="NONE" ;;
	''|null|NULL|UNKNOWN|unknown) normalized_decision="UNKNOWN" ;;
	*) normalized_decision="$raw_decision" ;;
	esac
	printf -v "$dest_var" '%s' "$normalized_decision"
	return 0
}

_pmp_review_decision_is_unknown() {
	local raw_decision="$1"
	local checked_decision=""
	_pmp_normalize_review_decision_into checked_decision "$raw_decision"
	[[ "$checked_decision" == "UNKNOWN" ]]
	return $?
}

#######################################
# Fetch review history in explicit, bounded REST pages. Every transport has a
# concrete page number; a full final page at the bound fails closed.
# Args: $1=PR number, $2=repo slug
# Stdout: one flattened JSON review array
#######################################
_pmp_rest_reviews_json() {
	local pr_number="$1"
	local repo_slug="$2"
	local page=1
	local max_pages=10
	local endpoint="" page_json="" page_count=0 reviews_json='[]'

	max_pages=$(_pmrs_review_max_pages)
	while [[ "$page" -le "$max_pages" ]]; do
		endpoint="repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100&page=${page}"
		page_json=$(AIDEVOPS_GH_PAGE_NUMBER="$page" \
			AIDEVOPS_GH_ROUTE_DECISION="pulse-review-explicit-page" \
			_pmrs_gh_call read gh api "$endpoint" 2>/dev/null) || return 1
		printf '%s' "$page_json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
		page_count=$(printf '%s' "$page_json" | jq 'length' 2>/dev/null) || return 1
		[[ "$page_count" =~ ^[0-9]+$ ]] || return 1
		reviews_json=$(printf '%s\n%s\n' "$reviews_json" "$page_json" | jq -cs '.[0] + .[1]' 2>/dev/null) || return 1
		if [[ "$page_count" -lt 100 ]]; then
			printf '%s' "$reviews_json"
			return 0
		fi
		page=$((page + 1))
	done
	return 1
}

#######################################
# Derive active review state from each reviewer's latest state-changing review.
# This preserves active blockers and exposes observed approvals without
# fabricating policy-level APPROVED/REVIEW_REQUIRED state that review history
# alone cannot prove.
#######################################
_pmp_rest_review_decision_from_reviews() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json=""

	reviews_json=$(_pmp_rest_reviews_json "$pr_number" "$repo_slug") || return 1
	printf '%s' "$reviews_json" | jq -r '
		def state_changing: .state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED";
		if type != "array" then error("expected review array")
		elif any(.[]?; state_changing and (
			(.user | type) != "object"
			or (.user.login | type) != "string"
			or (.user.login | length) == 0
			or (.submitted_at | type) != "string"
			or (.submitted_at | length) == 0
			or (.id | type) != "number"
		)) then error("malformed state-changing review")
		else map(select(state_changing))
		| group_by(.user.login)
		| map(max_by([.submitted_at // "", .id // 0]))
		| if any(.state == "CHANGES_REQUESTED") then "CHANGES_REQUESTED"
		  elif any(.state == "APPROVED") then "OBSERVED_APPROVED"
		  else "NONE" end end
	' 2>/dev/null || return 1
	return 0
}

_pmp_refresh_unknown_review_decision_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local current_review="$4"
	local refreshed_review=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_review_decision_into refreshed_review "$current_review"
	if [[ "$refreshed_review" == "UNKNOWN" ]]; then
		refreshed_review=$(_pmp_rest_review_decision_from_reviews "$pr_number" "$repo_slug" 2>/dev/null) || refreshed_review="UNKNOWN"
		_pmp_normalize_review_decision_into refreshed_review "$refreshed_review"
	fi
	printf -v "$dest_var" '%s' "$refreshed_review"
	return 0
}

#######################################
# Reconcile the already-gated review state with a fresh, bounded REST review
# history immediately before stale native-auto recovery. A new blocker is
# authoritative; unavailable or contradictory evidence fails closed.
# Args: $1=destination var, $2=PR number, $3=repo slug, $4=gated review state
#######################################
_pmp_refresh_native_auto_review_into() {
	local dest_var="$1"
	local pr_number="$2"
	local repo_slug="$3"
	local gated_review="$4"
	local fresh_review=""

	[[ "$dest_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	_pmp_normalize_review_decision_into gated_review "$gated_review"
	fresh_review=$(_pmp_rest_review_decision_from_reviews "$pr_number" "$repo_slug" 2>/dev/null) || {
		printf -v "$dest_var" '%s' UNKNOWN
		return 1
	}
	_pmp_normalize_review_decision_into fresh_review "$fresh_review"

	if [[ "$fresh_review" == "CHANGES_REQUESTED" ]]; then
		printf -v "$dest_var" '%s' "$fresh_review"
		return 0
	fi
	case "${gated_review}:${fresh_review}" in
	APPROVED:OBSERVED_APPROVED | OBSERVED_APPROVED:OBSERVED_APPROVED | NONE:OBSERVED_APPROVED | NONE:NONE)
		printf -v "$dest_var" '%s' "$fresh_review"
		return 0
		;;
	esac
	printf -v "$dest_var" '%s' UNKNOWN
	return 1
}

#######################################
# Resolve unknown review states once before backlog logging and sorting.
# Args: $1=repo slug, $2=PR JSON array
#######################################
_pmp_enrich_prs_with_review_decisions() {
	local repo_slug="$1"
	local pr_json="$2"
	local enriched_json="$pr_json"
	local pr_rows=""
	local _US=$'\x1f'
	local index="" number="" review_decision=""

	if [[ -z "$repo_slug" ]]; then
		printf '%s' "$pr_json"
		return 0
	fi
	pr_rows=$(printf '%s' "$pr_json" | jq -r '
		if type != "array" then error("expected PR array")
		else to_entries[] | [
			(.key | tostring),
			(if ((.value | has("number") | not) or .value.number == null or (.value.number | tostring | length) == 0)
			 then "" else (.value.number | tostring) end),
			(if ((.value | has("reviewDecision") | not) or .value.reviewDecision == null or (.value.reviewDecision | tostring | length) == 0)
			 then "UNKNOWN" else .value.reviewDecision end)
		] | join("\u001f")
		end' 2>/dev/null) || {
		printf '%s' "$pr_json"
		return 0
	}

	while IFS="$_US" read -r index number review_decision; do
		[[ -n "$index" ]] || continue
		_pmp_normalize_review_decision_into review_decision "$review_decision"
		if [[ "$number" =~ ^[0-9]+$ ]] && _pmp_review_decision_is_unknown "$review_decision"; then
			_pmp_refresh_unknown_review_decision_into review_decision "$number" "$repo_slug" "$review_decision"
			enriched_json=$(printf '%s' "$enriched_json" | jq --argjson index "$index" --arg review "$review_decision" '.[$index].reviewDecision = $review' 2>/dev/null) || {
				printf '%s' "$pr_json"
				return 0
			}
		fi
	done <<<"$pr_rows"

	printf '%s' "$enriched_json"
	return 0
}

#######################################
# Execute GitHub's update-a-pull-request-branch REST endpoint.
# Args: $1=PR number, $2=repo slug, $3=expected current head SHA
#######################################
_pmp_update_branch_rest() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head_sha="${3:-}"

	if [[ -z "$expected_head_sha" ]]; then
		printf 'update-branch refused: expected head SHA is required for PR #%s in %s\n' \
			"$pr_number" "$repo_slug" >&2
		return 2
	fi
	AIDEVOPS_GH_ROUTE_DECISION="pulse-update-branch-rest" \
		_pmrs_gh_call write gh api --method PUT "repos/${repo_slug}/pulls/${pr_number}/update-branch" \
			-f expected_head_sha="$expected_head_sha"
	return $?
}

#######################################
# Read auto-merge enablement time through a fixed-cost GraphQL query when the
# REST representation omits auto_merge.enabled_at. The operation reports its
# own cost and fails closed if GitHub changes the calibrated one-point shape.
# Args: $1=PR number, $2=repo slug
# Stdout: enabledAt timestamp, or empty when no request exists
#######################################
_pmrs_auto_merge_enabled_at_graphql() {
	local pr_number="$1"
	local repo_slug="$2"
	local owner="${repo_slug%%/*}"
	local name="${repo_slug##*/}"
	local response="" reported_cost="" enabled_at=""

	# shellcheck disable=SC2016
	response=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 AIDEVOPS_GH_ROUTE_DECISION="pulse-auto-merge-enabled-at-exact-cost" \
		_pmrs_gh_call read gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr_number" -f query='
		query($owner: String!, $name: String!, $pr: Int!) {
			repository(owner: $owner, name: $name) {
				pullRequest(number: $pr) { autoMergeRequest { enabledAt } }
			}
			rateLimit { cost }
		}
	') || return 1
	[[ -n "$response" ]] || return 1
	reported_cost=$(printf '%s' "$response" | jq -r '.data.rateLimit.cost // empty') || return 1
	if [[ "$reported_cost" != "1" ]]; then
		printf 'auto-merge enabledAt GraphQL cost contract changed for PR #%s in %s\n' \
			"$pr_number" "$repo_slug" >&2
		return 1
	fi
	enabled_at=$(printf '%s' "$response" \
		| jq -r '.data.repository.pullRequest.autoMergeRequest.enabledAt // empty') || return 1
	printf '%s' "$enabled_at"
	return 0
}

#######################################
# Fetch native-auto and merge-state metadata through REST. If REST omits the
# auto-merge timestamp, recover that one GraphQL-only field through a fixed,
# response-metered query; a failed recovery leaves the age unknown/fail-closed.
# Args: $1=PR number, $2=repo slug
#######################################
_pmp_rest_pr_merge_state() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_state="" enabled_at=""
	pr_state=$(AIDEVOPS_GH_ROUTE_DECISION="pulse-pr-merge-state-rest" \
		_pmrs_gh_call read gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '
		{
			autoMergeRequest: (if .auto_merge == null then null else {
				enabledAt: (.auto_merge.enabled_at // null),
				enabledBy: (.auto_merge.enabled_by // null)
			} end),
			mergeStateStatus: ((.mergeable_state // "unknown") | ascii_upcase),
			mergeable: (if .mergeable == true then "MERGEABLE"
				elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
			headRefOid: (.head.sha // "")
		}'
	) || return $?
	[[ -n "$pr_state" ]] || return 1
	if printf '%s' "$pr_state" | jq -e '.autoMergeRequest != null and .autoMergeRequest.enabledAt == null' >/dev/null 2>&1; then
		enabled_at=$(_pmrs_auto_merge_enabled_at_graphql "$pr_number" "$repo_slug" 2>/dev/null) || enabled_at=""
		if [[ -n "$enabled_at" ]]; then
			pr_state=$(printf '%s' "$pr_state" | jq -c --arg enabled_at "$enabled_at" \
				'.autoMergeRequest.enabledAt = $enabled_at') || return 1
		fi
	fi
	printf '%s' "$pr_state"
	return 0
}

#######################################
# Overlay the review state that already passed the current merge gate onto the
# exact-attribution REST/native-auto snapshot.
# Args: $1=PR number, $2=repo slug, $3=current review state
#######################################
_pmp_native_auto_merge_state() {
	local pr_number="$1"
	local repo_slug="$2"
	local current_review="$3"
	local pr_state=""

	pr_state=$(_pmp_rest_pr_merge_state "$pr_number" "$repo_slug") || return 1
	_pmp_normalize_review_decision_into current_review "$current_review"
	pr_state=$(printf '%s' "$pr_state" | jq -c --arg review "$current_review" \
		'.reviewDecision = $review' 2>/dev/null) || return 1
	printf '%s' "$pr_state"
	return 0
}

_pmp_extract_update_branch_state() {
	local auto_var="$1"
	local state_var="$2"
	local mergeable_var="$3"
	local pr_state="$4"
	local head_var="${5:-}"
	local existing_auto="" merge_state="" mergeable="" head_oid="" _RS=$'\x1e'

	IFS="$_RS" read -r existing_auto merge_state mergeable head_oid <<<"$(printf '%s' "$pr_state" \
		| jq -r '"\(if .autoMergeRequest then "present" else "" end)\u001e\(.mergeStateStatus // "")\u001e\(.mergeable // "")\u001e\(.headRefOid // "")"' \
		|| true)"
	_pmp_normalize_mergeable_state_into mergeable "$mergeable"
	printf -v "$auto_var" '%s' "$existing_auto"
	printf -v "$state_var" '%s' "$merge_state"
	printf -v "$mergeable_var" '%s' "$mergeable"
	if [[ -n "$head_var" ]]; then
		[[ "$head_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
		printf -v "$head_var" '%s' "$head_oid"
	fi
	return 0
}
