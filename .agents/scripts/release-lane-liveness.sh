#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by release-lane-helper.sh; no scheduler or publication authority.

_release_lane_executor_capture() {
	python3 -I "${_AIDEVOPS_RELEASE_LANE_LIB_DIR}/release-lane-owner.py" capture "$$"
	return $?
}

_release_lane_executor_observe() {
	local state_json="$1"
	local executor=""
	executor=$(jq -c '.executor // null' <<<"$state_json") || return 1
	python3 -I "${_AIDEVOPS_RELEASE_LANE_LIB_DIR}/release-lane-owner.py" observe <<<"$executor"
	return $?
}

release_lane_liveness_report() {
	local state_json="$1"
	local observation=""
	local source_pr=""
	if jq -e '.active == false' <<<"$state_json" >/dev/null; then
		printf 'RELEASE_EXECUTOR={"state":"not-required","reason":"inactive-lane"}\n'
		return 0
	fi
	observation=$(_release_lane_executor_observe "$state_json") || observation='{"state":"unknown","reason":"observation-unavailable"}'
	printf 'RELEASE_EXECUTOR=%s\n' "$observation"
	source_pr=$(jq -r '.source_pr' <<<"$state_json") || return 1
	if jq -e '.active == true and .phase == "reserved" and .tag == null' <<<"$state_json" >/dev/null; then
		printf 'Reservation has no recorded tag; tag-based reconcile alone may not resume it.\n'
		if _release_lane_abandoned_reservation "$state_json"; then
			printf 'Recover without publication: aidevops release recover-reservation %s\n' "$source_pr"
		else
			printf 'Release owner: resume with existing publication authority using aidevops release patch %s (or the originally authorized increment).\n' "$source_pr"
			printf 'Live, recent, legacy, or foreign ownership cannot be automatically released; unknown is not an active executor.\n'
		fi
	else
		printf 'Inspect/resume publication: aidevops release reconcile %s\n' "$source_pr"
	fi
	return 0
}

#aidevops:trust-boundary
# Only modern untouched reservations have the enforced preparing-before-publish
# contract. Never infer that contract for legacy, adopted or recovery state.
_release_lane_abandoned_reservation() {
	local state_json="$1"
	local observation=""
	local grace="${AIDEVOPS_RELEASE_LANE_STALE_SECONDS:-300}"
	[[ "$grace" =~ ^[0-9]+$ && ${#grace} -le 8 ]] || return 1
	[[ "$grace" -ge 300 ]] || grace=300
	jq -e '
        .active == true and .phase == "reserved" and .tag == null
        and .reservation_contract == "fenced-prepublication/v1"
        and .terminal_receipt == null and .prepublication_recovery == null
        and .aggregate_recovery == null and .aggregate_successor == null
        and .reserved_authorization_refresh == null
    ' <<<"$state_json" >/dev/null || return 1
	AIDEVOPS_RELEASE_LANE_STALE_SECONDS="$grace" _release_lane_stale_prepublication "$state_json" || return 1
	observation=$(_release_lane_executor_observe "$state_json") || return 1
	[[ "$(jq -r '.state' <<<"$observation")" == "dead" ]]
	return $?
}

#aidevops:trust-boundary
release_lane_recover_reservation() {
	local repo="$1"
	local source_pr="$2"
	local expected_head="${3:-}"
	local snapshot=""
	local permission=""
	local state_json=""
	[[ "$source_pr" =~ ^[0-9]+$ ]] || return 1
	release_lane_read "$repo" || return 1
	[[ -z "$expected_head" || "$expected_head" == "$_AIDEVOPS_RELEASE_LANE_HEAD" ]] || return 75
	snapshot="$_AIDEVOPS_RELEASE_LANE_HEAD"
	jq -e --argjson pr "$source_pr" '.source_pr == $pr' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null || return 75
	if jq -e '.active == false and .terminal_receipt == "abandoned-prepublication"' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null; then
		return 0
	fi
	_release_lane_abandoned_reservation "$_AIDEVOPS_RELEASE_LANE_JSON" || {
		printf 'Reservation recovery refused: live, unknown, legacy, or possible publication state\n' >&2
		return 75
	}
	permission=$(gh api "repos/${repo}" --jq '.permissions.push == true or .permissions.maintain == true or .permissions.admin == true' 2>/dev/null) || return 1
	[[ "$permission" == "true" ]] || return 75
	state_json=$(jq -c --arg snapshot "$snapshot" --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
        .active=false | .phase="terminal" | .terminal_receipt="abandoned-prepublication"
        | .updated_at=$now | .reservation_recovery={observed_head:$snapshot,reason:"verified-dead-executor",at:$now}
    ' <<<"$_AIDEVOPS_RELEASE_LANE_JSON") || return 1
	# A concurrent preparing/adoption write wins the CAS and refuses this unlock.
	_release_lane_write "$repo" "$state_json" "$snapshot" || return $?
	printf 'RELEASE_RESERVATION_RECOVERED source_pr=%s receipt=abandoned-prepublication\n' "$source_pr"
	return 0
}
