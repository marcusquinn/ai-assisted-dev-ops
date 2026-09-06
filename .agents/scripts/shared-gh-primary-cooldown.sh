#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Resource-scoped primary exhaustion; sourced by the secondary cooldown owner.

_gh_primary_request_resource() {
	local command_name="${1:-}"
	[[ "${command_name##*/}" != gh ]] || shift
	[[ "${GH_HOST:-github.com}" == github.com ]] || return 1
	case "${1:-}" in
	search)
		if [[ "${2:-}" == code ]]; then
			printf 'code_search\n'
		else
			printf 'search\n'
		fi
		return 0
		;;
	api) shift ;;
	*) return 1 ;;
	esac
	local endpoint="" arg=""
	while [[ "$#" -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--hostname)
			[[ "${1:-}" == github.com ]] || return 1
			shift
			;;
		--hostname=*) [[ "$arg" == --hostname=github.com ]] || return 1 ;;
		-X | --method | -H | --header | -F | --field | -f | --raw-field | --input | -q | --jq | -p | --preview | -t | --template | --cache)
			[[ "$#" -gt 0 ]] || return 1
			shift
			;;
		-*) ;;
		*)
			[[ -z "$endpoint" ]] || return 1
			endpoint="${arg#/}"
			;;
		esac
	done
	case "${endpoint%%\?*}" in
	rate_limit | "" | *:*) return 1 ;;
	graphql) printf 'graphql\n' ;;
	search/code) printf 'code_search\n' ;;
	search/*) printf 'search\n' ;;
	*) printf 'core\n' ;;
	esac
	return 0
}

_gh_primary_cooldown_preflight() {
	local resource=""
	resource=$(_gh_primary_request_resource "$@") || return 0
	local AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-${resource}"
	if _gh_secondary_cooldown_active; then
		printf '[gh-cooldown] primary-%s active=true retry_at=%s; unrelated API resources remain available\n' \
			"$resource" "$(_gh_secondary_cooldown_expires_at)" >&2
		return 75
	fi
	return 0
}

_gh_primary_cooldown_response() {
	local response="$1"
	shift
	local status="" remaining="" resource="" reset="" now=""
	status=$(_gh_secondary_cooldown_status "$response")
	case "$status" in 200 | 201 | 204 | 304 | 403 | 429) ;; *) return 1 ;; esac
	remaining=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-remaining")
	resource=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-resource")
	[[ "$remaining" == 0 ]] || return 1
	case "$resource" in core | search | code_search | graphql) ;; *) return 1 ;; esac
	# Retry-After or an abuse message can represent a cross-resource secondary
	# limit even when the primary counter is also zero. Preserve the global guard.
	[[ -z "$(_gh_secondary_cooldown_header_value "$response" "retry-after")" ]] || return 1
	_gh_secondary_cooldown_detect "$response" && return 1
	reset=$(_gh_secondary_cooldown_header_value "$response" "x-ratelimit-reset")
	now=$(_gh_secondary_cooldown_now)
	[[ "$reset" =~ ^[0-9]{1,10}$ && "$reset" -le $((now + 86400)) ]] || return 1
	[[ "$reset" -gt "$now" ]] || return 0
	local AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="${AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE}.primary-${resource}"
	_gh_secondary_cooldown_write_until "github-${resource}-primary-exhausted" "$response" "$reset" \
		"primary-${resource}" "$_GH_SECONDARY_COOLDOWN_ACTION_CREATED" "$@"
	return $?
}
