#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ "${BASH_SOURCE[0]}" == "$0" ]] && set -euo pipefail

release_authorization_intent_json() {
	local sources="$1"
	jq -cen --arg sources "$sources" '
		($sources | gsub("[[:space:]]+"; ",") | split(",") | map(select(length > 0))) as $tokens
		| if ($tokens | length) == 0 then error("release authorization set is empty") else . end
		| [$tokens[]
			| if test("^[0-9]+(@[0-9a-f]{40})?$")
				then capture("^(?<pr>[0-9]+)(@(?<merge>[0-9a-f]{40}))?$")
				else error("release authorization source is malformed")
			  end
			| {pr:(.pr | tonumber), merge:(.merge // null)}] as $entries
		| if ($entries | group_by(.pr) | any(length != 1))
			then error("release authorization set repeats a PR")
			else ($entries | sort_by(.pr))
		end
	' 2>/dev/null
	return $?
}

release_authorization_manifest_json() {
	local sources="$1"
	local entries=""
	entries=$(release_authorization_intent_json "$sources") || return 1
	jq -ce '
		if all(.[]; (.merge | type) == "string") then .
		else error("release authorization manifest requires merge SHAs")
		end
	' <<<"$entries" 2>/dev/null
	return $?
}

release_authorization_manifest_string() {
	local sources="$1"
	local entries=""
	entries=$(release_authorization_manifest_json "$sources") || return 1
	jq -r 'map("\(.pr)@\(.merge)") | join(",")' <<<"$entries"
	return $?
}

release_authorization_observed_sources_json() {
	local expected_json="$1"
	local source_json="$2"
	jq -ce --argjson expected "$expected_json" '
		($expected | sort_by(.pr)) as $normalized_expected
		| ([{pr:.source_pr,merge:.source_merge}] | sort_by(.pr)) as $direct_source
		| if (($normalized_expected == $direct_source) or ((.aggregated_sources // []) | length == 0))
			then $direct_source
			else (.aggregated_sources | sort_by(.pr))
		  end
		| if all(.[]; ((.pr | type) == "number") and (.merge | test("^[0-9a-f]{40}$")))
			then .
			else error("observed release source manifest is malformed")
		  end
	' <<<"$source_json" 2>/dev/null
	return $?
}

release_authorization_compare() {
	local expected="$1"
	local observed="$2"
	local expected_json=""
	local observed_json=""
	expected_json=$(release_authorization_manifest_json "$expected") || return 1
	observed_json=$(release_authorization_manifest_json "$observed") || return 1
	[[ "$expected_json" == "$observed_json" ]]
	return $?
}

release_authorization_subset() {
	local subset="$1"
	local complete="$2"
	local subset_json=""
	local complete_json=""
	subset_json=$(release_authorization_manifest_json "$subset") || return 1
	complete_json=$(release_authorization_manifest_json "$complete") || return 1
	jq -e --argjson subset "$subset_json" --argjson complete "$complete_json" '
		all($subset[]; . as $entry | any($complete[]; . == $entry))
	' <<<"$complete_json" >/dev/null
	return $?
}

_release_authorization_usage() {
	printf '%s\n' 'Usage: release-authorization-manifest-helper.sh normalize MANIFEST'
	return 0
}

main() {
	local command="${1:-}"
	local sources="${2:-}"
	case "$command" in
	normalize)
		release_authorization_manifest_string "$sources"
		return $?
		;;
	*)
		_release_authorization_usage >&2
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
