#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "$SCRIPT_DIR/shared-constants.sh"

NPM_CACHE_WARN_BYTES="${AIDEVOPS_NPM_CACHE_WARN_BYTES:-10737418240}"
NPM_CACHE_SIZE_TIMEOUT_TENTHS="${AIDEVOPS_NPM_CACHE_SIZE_TIMEOUT_TENTHS:-300}"
NPM_CACHE_DU_COMMAND="${AIDEVOPS_NPM_CACHE_DU_COMMAND:-du}"
NPM_CACHE_CONFIRM_TOKEN="clean-npm-cache"

_npm_cache_usage() {
	cat <<'USAGE'
Usage: npm-cache-helper.sh [status|json|verify|clean] [options]

Monitor and maintain npm's externally owned cache through npm itself.

Commands:
  status              Measure cache size and print threshold guidance
  json                Emit the read-only status as JSON
  verify              Run `npm cache verify` (integrity check and npm-owned GC)
  clean               Dry run; show the explicit full-clean command
  clean --apply --confirm clean-npm-cache
                      Run `npm cache clean --force` through npm

Environment:
  AIDEVOPS_NPM_CACHE_DIR                  Override the measured cache path
  AIDEVOPS_NPM_CACHE_WARN_BYTES           Warning threshold (default: 10 GiB)
  AIDEVOPS_NPM_CACHE_SIZE_TIMEOUT_TENTHS  Size timeout in tenths (default: 300)

No cleanup is automatic. The clean command requires explicit apply and confirm
arguments and never removes files directly.
USAGE
	return 0
}

_npm_cache_is_nonnegative_integer() {
	local value="$1"
	case "$value" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}

_npm_cache_warn_bytes() {
	if _npm_cache_is_nonnegative_integer "$NPM_CACHE_WARN_BYTES"; then
		printf '%s' "$NPM_CACHE_WARN_BYTES"
	else
		printf '10737418240'
	fi
	return 0
}

_npm_cache_resolve_path() {
	local cache_path="${AIDEVOPS_NPM_CACHE_DIR:-}"

	if [[ -z "$cache_path" ]] && command -v npm >/dev/null 2>&1; then
		cache_path=$(npm config get cache 2>/dev/null) || cache_path=""
	fi
	if [[ -z "$cache_path" ]] && [[ -n "${HOME:-}" ]]; then
		cache_path="$HOME/.npm"
	fi
	case "$cache_path" in
	/*) printf '%s' "$cache_path" ;;
	*) return 1 ;;
	esac
	return 0
}

_npm_cache_display_path() {
	local cache_path="$1"
	if [[ -n "${HOME:-}" ]] && [[ "$cache_path" == "$HOME"/* ]]; then
		printf '%s/%s' '~' "${cache_path#"$HOME/"}"
	else
		printf '%s' "$cache_path"
	fi
	return 0
}

_npm_cache_measure() {
	local cache_path="$1"
	local output_file=""
	local pid=""
	local elapsed=0
	local kib=""
	local ignored=""
	local timeout_tenths="$NPM_CACHE_SIZE_TIMEOUT_TENTHS"

	if [[ ! -e "$cache_path" && ! -L "$cache_path" ]]; then
		printf '0|exact|missing'
		return 0
	fi
	if [[ -L "$cache_path" ]]; then
		printf 'null|unavailable|root-is-symlink'
		return 0
	fi
	if [[ ! -r "$cache_path" ]]; then
		printf 'null|unavailable|root-is-unreadable'
		return 0
	fi
	if ! command -v "$NPM_CACHE_DU_COMMAND" >/dev/null 2>&1; then
		printf 'null|unavailable|sizing-command-unavailable'
		return 0
	fi
	if ! _npm_cache_is_nonnegative_integer "$timeout_tenths"; then
		timeout_tenths=300
	fi

	output_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-npm-cache-size.XXXXXX") || {
		printf 'null|unavailable|temporary-file-unavailable'
		return 0
	}
	LC_ALL=C "$NPM_CACHE_DU_COMMAND" -sk "$cache_path" >"$output_file" 2>/dev/null &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		if [[ "$elapsed" -ge "$timeout_tenths" ]]; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
			rm -f "$output_file"
			printf 'null|unavailable|sizing-timeout'
			return 0
		fi
		sleep 0.1
		elapsed=$((elapsed + 1))
	done
	if ! wait "$pid"; then
		rm -f "$output_file"
		printf 'null|unavailable|sizing-failed'
		return 0
	fi
	IFS=$'\t ' read -r kib ignored <"$output_file" || kib=""
	rm -f "$output_file"
	case "$kib" in
	'' | *[!0-9]*) printf 'null|unavailable|invalid-size-output' ;;
	*) printf '%s|exact|' "$((kib * 1024))" ;;
	esac
	return 0
}

_npm_cache_json() {
	local cache_path=""
	local display_path="unavailable"
	local measured="null|unavailable|cache-path-unavailable"
	local total_bytes="null"
	local confidence="unavailable"
	local error="cache-path-unavailable"
	local warn_bytes=""
	local advisory="unavailable"

	warn_bytes=$(_npm_cache_warn_bytes)
	if cache_path=$(_npm_cache_resolve_path); then
		display_path=$(_npm_cache_display_path "$cache_path")
		measured=$(_npm_cache_measure "$cache_path")
		IFS='|' read -r total_bytes confidence error <<<"$measured"
	fi
	if [[ "$total_bytes" != "null" ]]; then
		if [[ "$total_bytes" -ge "$warn_bytes" ]]; then
			advisory="warning"
		else
			advisory="ok"
		fi
	fi

	jq -cn \
		--arg path "$display_path" \
		--arg advisory "$advisory" \
		--arg confidence "$confidence" \
		--arg error "$error" \
		--argjson total_bytes "$total_bytes" \
		--argjson warning_threshold_bytes "$warn_bytes" \
		'{schema:"aidevops.npm-cache-status/v1",owner:"external",read_only:true,path:$path,total_bytes:$total_bytes,warning_threshold_bytes:$warning_threshold_bytes,advisory:$advisory,sizing_confidence:$confidence,error:(if $error == "" or $error == "missing" then null else $error end)}'
	return 0
}

_npm_cache_format_bytes() {
	local bytes="$1"
	if [[ "$bytes" == "null" ]]; then
		printf 'unavailable'
	elif [[ "$bytes" -ge 1073741824 ]]; then
		printf '%s.%s GiB' "$((bytes / 1073741824))" "$(((bytes % 1073741824) * 10 / 1073741824))"
	elif [[ "$bytes" -ge 1048576 ]]; then
		printf '%s.%s MiB' "$((bytes / 1048576))" "$(((bytes % 1048576) * 10 / 1048576))"
	else
		printf '%s KiB' "$((bytes / 1024))"
	fi
	return 0
}

_npm_cache_status() {
	local report=""
	local cache_path=""
	local total_bytes=""
	local warn_bytes=""
	local advisory=""
	local error=""

	report=$(_npm_cache_json)
	cache_path=$(printf '%s' "$report" | jq -r '.path')
	total_bytes=$(printf '%s' "$report" | jq -r '.total_bytes | tostring')
	warn_bytes=$(printf '%s' "$report" | jq -r '.warning_threshold_bytes')
	advisory=$(printf '%s' "$report" | jq -r '.advisory')
	error=$(printf '%s' "$report" | jq -r '.error // ""')
	printf 'npm cache: %s (%s)\n' "$(_npm_cache_format_bytes "$total_bytes")" "$cache_path"
	case "$advisory" in
	warning)
		print_warning "npm cache exceeds the $(_npm_cache_format_bytes "$warn_bytes") advisory threshold"
		printf 'Safe first step: npm-cache-helper.sh verify\n'
		printf 'If it remains oversized, review: npm-cache-helper.sh clean\n'
		;;
	ok) print_success "npm cache is below the advisory threshold" ;;
	*) print_warning "npm cache size is unavailable${error:+ ($error)}" ;;
	esac
	printf 'No cleanup was performed. npm remains the cache owner.\n'
	return 0
}

_npm_cache_require_npm() {
	if command -v npm >/dev/null 2>&1; then
		return 0
	fi
	print_error "npm is not available"
	return 1
}

_npm_cache_verify() {
	local cache_path=""
	_npm_cache_require_npm || return 1
	cache_path=$(_npm_cache_resolve_path) || {
		print_error "npm cache path is unavailable"
		return 1
	}
	printf 'Running npm-owned integrity verification and garbage collection...\n'
	npm cache verify --cache "$cache_path"
	_npm_cache_status
	return 0
}

_npm_cache_clean() {
	local apply=0
	local confirm=""
	local arg=""
	local cache_path=""

	while [[ "$#" -gt 0 ]]; do
		arg="$1"
		shift
		case "$arg" in
		--apply) apply=1 ;;
		--confirm)
			[[ "$#" -gt 0 ]] || {
				print_error "--confirm requires a token"
				return 1
			}
			confirm="$1"
			shift
			;;
		*)
			print_error "Unknown clean option: $arg"
			return 1
			;;
		esac
	done

	_npm_cache_require_npm || return 1
	cache_path=$(_npm_cache_resolve_path) || {
		print_error "npm cache path is unavailable"
		return 1
	}
	_npm_cache_status
	if [[ "$apply" -ne 1 ]]; then
		printf 'Dry run only. This would ask npm to clear its cache at %s.\n' "$(_npm_cache_display_path "$cache_path")"
		printf 'After review, run: npm-cache-helper.sh clean --apply --confirm %s\n' "$NPM_CACHE_CONFIRM_TOKEN"
		return 0
	fi
	if [[ "$confirm" != "$NPM_CACHE_CONFIRM_TOKEN" ]]; then
		print_error "Confirmation mismatch; expected: $NPM_CACHE_CONFIRM_TOKEN"
		return 1
	fi
	printf 'Running npm cache clean --force for %s...\n' "$(_npm_cache_display_path "$cache_path")"
	npm cache clean --force --cache "$cache_path"
	_npm_cache_status
	return 0
}

main() {
	local command_name="${1:-status}"
	if [[ "$#" -gt 0 ]]; then
		shift
	fi
	case "$command_name" in
	status) _npm_cache_status ;;
	json) _npm_cache_json ;;
	verify) _npm_cache_verify ;;
	clean) _npm_cache_clean "$@" ;;
	help | --help | -h) _npm_cache_usage ;;
	*)
		_npm_cache_usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
