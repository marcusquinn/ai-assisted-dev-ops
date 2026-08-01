#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh shim API guards library
# =============================================================================
# GraphQL page bounds and REST content-write parsing/signature helpers.
# Usage: source "${_SHIM_DIR}/gh-api-guards-lib.sh"

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_GH_API_GUARDS_LIB_LOADED:-}" ]] && return 0
_GH_API_GUARDS_LIB_LOADED=1

if [[ -z "${_SHIM_DIR:-}" ]]; then
	_gh_api_guards_path="${BASH_SOURCE[0]%/*}"
	[[ "$_gh_api_guards_path" == "${BASH_SOURCE[0]}" ]] && _gh_api_guards_path="."
	_SHIM_DIR="$(cd "$_gh_api_guards_path" && pwd)"
	unset _gh_api_guards_path
fi

_shim_graphql_check_literal_query() {
	local query="$1"
	local matches=""
	local match=""
	local requested=""
	local normalized=""
	local dynamic_pattern='(first|last)[[:space:]]*:[[:space:]]*([^0-9[:space:]]|$)'

	matches=$(printf '%s\n' "$query" | LC_ALL=C grep -Eo '(first|last)[[:space:]]*:[[:space:]]*[0-9]+' 2>/dev/null || true)
	while IFS= read -r match; do
		[[ -n "$match" ]] || continue
		requested="${match##*:}"
		requested="${requested//[[:space:]]/}"
		normalized="$requested"
		while [[ "$normalized" == 0* && ${#normalized} -gt 1 ]]; do
			normalized="${normalized#0}"
		done
		if [[ ${#normalized} -gt 3 || ( ${#normalized} -eq 3 && "$normalized" -gt 100 ) ]]; then
			printf 'GRAPHQL_PAGE_BOUND_EXCEEDED requested=%s maximum=100\n' "$normalized" >&2
			printf 'Use: github-graphql-page-helper.sh --query-file QUERY.graphql --connection-jq '\''.data.<connection>'\'' --total N --max-pages N\n' >&2
			return 1
		fi
	done <<<"$matches"

	if printf '%s\n' "$query" | LC_ALL=C grep -Eq "$dynamic_pattern" 2>/dev/null; then
		printf 'GRAPHQL_PAGE_BOUND_UNVERIFIED dynamic first/last argument passed unchanged; use github-graphql-page-helper.sh for bounded framework pagination\n' >&2
	fi
	return 0
}

_shim_graphql_guard_literal_fields() {
	local args=("$@")
	local i=2
	local arg=""
	local value=""

	while [[ $i -lt ${#args[@]} ]]; do
		arg="${args[$i]}"
		value=""
		case "$arg" in
		-f | -F | --raw-field | --field)
			i=$((i + 1))
			[[ $i -lt ${#args[@]} ]] && value="${args[$i]}"
			;;
		-fquery=* | -Fquery=*) value="${arg#??}" ;;
		--raw-field=query=*) value="${arg#--raw-field=}" ;;
		--field=query=*) value="${arg#--field=}" ;;
		esac
		if [[ "$value" == query=* ]]; then
			_shim_graphql_check_literal_query "${value#query=}" || return 1
		fi
		i=$((i + 1))
	done
	return 0
}

_shim_api_is_write_endpoint() {
	local method="" path="" i a
	i=0
	while [[ $i -lt ${#_modified_args[@]} ]]; do
		a="${_modified_args[$i]}"
		case "$a" in
		-X)
			method="${_modified_args[i + 1]:-}"
			i=$((i + 2))
			continue
			;;
		-X*) method="${a#-X}" ;;
		--method)
			method="${_modified_args[i + 1]:-}"
			i=$((i + 2))
			continue
			;;
		--method=*) method="${a#--method=}" ;;
		-f | --field | -F | --raw-field | --jq | -q | -H | --header | --input | --template | -t | --cache | --hostname | --preview | -p)
			i=$((i + 2))
			continue
			;;
		api) ;;
		/repos/* | repos/*) [[ -z "$path" ]] && path="$a" ;;
		-*) ;;
		esac
		i=$((i + 1))
	done
	[[ "$method" != "POST" && "$method" != "PATCH" ]] && return 1
	local npath="${path#/}"
	[[ "$npath" =~ ^repos/[^/]+/[^/]+/issues(/[0-9]+)?(\?.*)?$ ]] && return 0
	[[ "$npath" =~ ^repos/[^/]+/[^/]+/issues(/[0-9]+/comments|/comments/[0-9]+)(\?.*)?$ ]] && return 0
	[[ "$npath" =~ ^repos/[^/]+/[^/]+/pulls(/[0-9]+)?(\?.*)?$ ]] && return 0
	[[ "$npath" =~ ^repos/[^/]+/[^/]+/pulls(/[0-9]+/(comments|reviews)|/[0-9]+/reviews/[0-9]+)(\?.*)?$ ]] && return 0
	[[ "$npath" =~ ^repos/[^/]+/[^/]+/pulls/comments/[0-9]+(\?.*)?$ ]] && return 0
	return 1
}

_shim_api_target_from_path() {
	local path=""
	local i=0
	local a=""
	while [[ $i -lt ${#_modified_args[@]} ]]; do
		a="${_modified_args[$i]}"
		case "$a" in
		-f | --field | -F | --raw-field | --jq | -q | -H | --header | --input | --template | -t | --cache | --hostname | --preview | -p | -X | --method)
			i=$((i + 2))
			continue
			;;
		api) ;;
		/repos/* | repos/*) [[ -z "$path" ]] && path="$a" ;;
		-*) ;;
		esac
		i=$((i + 1))
	done
	local npath="${path#/}"
	if [[ "$npath" =~ ^repos/([^/]+/[^/]+)(/|$|\?) ]]; then
		printf 'https://github.com/%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

_shim_body_is_ops_audit() {
	local body="$1"
	case "$body" in
	*'<!-- ops:start'* | *'Dispatching worker (deterministic)'* | *'<!-- routine-description'* | *'<!-- dispatch-infrastructure-failure -->'*) return 0 ;;
	esac
	return 1
}

_shim_sig_footer_for_body() {
	local body="${1:-}"
	if _shim_body_is_ops_audit "$body"; then
		"$SIG_HELPER" footer --body "$body" --no-session 2>/dev/null
	else
		"$SIG_HELPER" footer --body "$body" 2>/dev/null
	fi
	return $?
}

_shim_api_inject_body_sig() {
	local i=0 a _next _kv _bfile _bval _footer
	while [[ $i -lt ${#_modified_args[@]} ]]; do
		a="${_modified_args[$i]}"
		case "$a" in
		-f | -F | --field | --raw-field)
			_next="${_modified_args[i + 1]:-}"
			case "$_next" in
			body=@*)
				_bfile="${_next#body=@}"
				if [[ -f "$_bfile" ]] && ! grep -q "<!-- aidevops:sig -->" "$_bfile" 2>/dev/null; then
					_bval=$(<"$_bfile") || _bval=""
					_footer=$(_shim_sig_footer_for_body "$_bval") || true
					[[ -n "$_footer" ]] && printf '%s' "$_footer" >>"$_bfile" || true
				fi
				;;
			body=*)
				_bval="${_next#body=}"
				if [[ "$_bval" != *"<!-- aidevops:sig -->"* ]]; then
					_footer=$(_shim_sig_footer_for_body "$_bval") || {
						i=$((i + 2))
						continue
					}
					[[ -n "$_footer" ]] && _modified_args[i + 1]="body=${_bval}${_footer}"
				fi
				;;
			esac
			i=$((i + 2))
			continue
			;;
		-f* | -F* | --field=* | --raw-field=*)
			case "$a" in
			-f*)           _kv="${a#-f}" ;;
			-F*)           _kv="${a#-F}" ;;
			--field=*)     _kv="${a#--field=}" ;;
			--raw-field=*) _kv="${a#--raw-field=}" ;;
			esac
			case "$_kv" in
			body=@*)
				_bfile="${_kv#body=@}"
				if [[ -f "$_bfile" ]] && ! grep -q "<!-- aidevops:sig -->" "$_bfile" 2>/dev/null; then
					_bval=$(<"$_bfile") || _bval=""
					_footer=$(_shim_sig_footer_for_body "$_bval") || true
					[[ -n "$_footer" ]] && printf '%s' "$_footer" >>"$_bfile" || true
				fi
				;;
			body=*)
				_bval="${_kv#body=}"
				if [[ "$_bval" != *"<!-- aidevops:sig -->"* ]]; then
					_footer=$(_shim_sig_footer_for_body "$_bval") || {
						i=$((i + 1))
						continue
					}
					if [[ -n "$_footer" ]]; then
						case "$a" in
						-f*)           _modified_args[$i]="-fbody=${_bval}${_footer}" ;;
						-F*)           _modified_args[$i]="-Fbody=${_bval}${_footer}" ;;
						--field=*)     _modified_args[$i]="--field=body=${_bval}${_footer}" ;;
						--raw-field=*) _modified_args[$i]="--raw-field=body=${_bval}${_footer}" ;;
						esac
					fi
				fi
				;;
			esac
			;;
		esac
		i=$((i + 1))
	done
	return 0
}
