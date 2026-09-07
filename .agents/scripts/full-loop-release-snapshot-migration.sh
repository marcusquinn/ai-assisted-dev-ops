#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Reserved snapshot authorization migration; sourced by the release entry point.

_full_loop_snapshot_retry_eligible() {
	local repo="$1"
	local source_pr="$2"
	release_lane_read "$repo" || return 1
	jq -e --argjson pr "$source_pr" '
		.active == true and .source_pr == $pr and .phase == "reserved"
		and .tag == null and .terminal_receipt == null
		and (.snapshot_sha | type == "string" and test("^[0-9a-f]{40}$"))
		and (.snapshot_base | type == "string" and test("^[0-9a-f]{40}$"))
		and .prepublication_recovery == null and .aggregate_recovery == null
		and .aggregate_successor == null and .reserved_authorization_refresh == null
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null
	return $?
}

_full_loop_snapshot_previous_matches_lane() {
	local previous="$1"
	local expected="$2"
	local intent=""
	local previous_json=""
	intent=$(release_authorization_intent_json "$(jq -r '.expected_sources' <<<"$_AIDEVOPS_RELEASE_LANE_JSON")") || return 1
	previous_json=$(release_authorization_manifest_json "$previous") || return 1
	jq -e --argjson intent "$intent" --argjson previous "$previous_json" --arg expected "$expected" '
		(.snapshot_manifest_bound == true and .expected_sources == $expected)
		or (.snapshot_manifest_bound != true
			and ($intent | map(.pr) | sort) == ($previous | map(.pr) | sort)
			and all($intent[]; . as $entry | any($previous[];
				.pr == $entry.pr and ($entry.merge == null or .merge == $entry.merge))))
	' <<<"$_AIDEVOPS_RELEASE_LANE_JSON" >/dev/null
	return $?
}

#aidevops:trust-boundary
# The caller already verifies the complete immutable snapshot and any explicit
# current CLI assertion. Widen only a compatible prior pre-publication record;
# CAS-bind the lane first and retain its pin across failed local persistence.
_full_loop_bind_snapshot_authorization() {
	local repo="$1"
	local source_pr="$2"
	local source_json="$3"
	local expected="$4"
	local previous=""
	local read_rc=0
	previous=$(_full_loop_read_release_authorization "$repo" "$source_pr") || read_rc=$?
	case "$read_rc" in 0 | 2) ;; *) return 1 ;; esac
	if [[ "$read_rc" -eq 0 && "$previous" != "$expected" ]]; then
		_full_loop_snapshot_retry_eligible "$repo" "$source_pr" || return 1
		release_authorization_subset "$previous" "$expected" || return 1
		_full_loop_snapshot_previous_matches_lane "$previous" "$expected" || return 1
		release_lane_bind_snapshot "$repo" "$source_pr" "$source_json" || return 1
		_full_loop_expand_release_authorization_for_aggregate "$repo" "$source_pr" "$previous" "$expected" || return 1
		printf 'Migrated compatible reserved authorization to the verified pinned snapshot for PR #%s\n' "$source_pr"
		return 0
	fi
	release_lane_bind_snapshot "$repo" "$source_pr" "$source_json"
	return $?
}
