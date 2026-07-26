#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# xurl-helper.sh - Guarded aidevops wrapper for the official xurl X API CLI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

WRITE_COMMANDS="post:reply:quote:delete:like:unlike:repost:unrepost:bookmark:unbookmark:follow:unfollow:block:unblock:mute:unmute:dm:media"
FORBIDDEN_FLAGS="--verbose -v --bearer-token --consumer-key --consumer-secret --access-token --token-secret --client-id --client-secret"
APP_NAME=""
USERNAME=""
LIMIT=""
CONFIRM_WRITE="false"
ARGS=()

show_help() {
	printf '%s\n' "xurl-helper.sh - guarded xurl wrapper"
	printf '\n%s\n' "Usage: xurl-helper.sh <command> [options]"
	printf '\n%s\n' "Read commands: status, whoami, read, search, user, timeline, mentions, bookmarks, likes, followers, following, dms, run"
	printf '%s\n' "Write commands: post, reply, quote, delete, like, unlike, repost, unrepost, bookmark, unbookmark, follow, unfollow, block, unblock, mute, unmute, dm, media"
	printf '\n%s\n' "Options: --app NAME, --username NAME, --limit N, --confirm-write, -- --raw xurl args"
	printf '%s\n' "Secrets and verbose flags are rejected. Write commands require --confirm-write."
	return 0
}

check_dependencies() {
	if ! command -v xurl >/dev/null 2>&1; then
		print_error "xurl is not installed or not on PATH"
		printf '%s\n' "Install xurl outside the agent session, then run: xurl auth status"
		return 1
	fi
	return 0
}

reject_forbidden_args() {
	local arg
	local flag

	for arg in "$@"; do
		for flag in ${FORBIDDEN_FLAGS}; do
			if [[ "${arg}" == "${flag}" || "${arg}" == "${flag}="* ]]; then
				print_error "Forbidden xurl flag in agent session: ${flag}"
				return 1
			fi
		done
	done

	return 0
}

run_xurl() {
	local command_name="$1"
	shift || true

	reject_forbidden_args "$@" || return 1
	check_dependencies || return 1
	xurl "$@"
	return 0
}

raw_args_are_mutating() {
	local previous=""
	local arg

	for arg in "$@"; do
		if [[ "${previous}" == "-X" || "${previous}" == "--request" ]]; then
			case "${arg}" in
			POST | post | PUT | put | PATCH | patch | DELETE | delete)
				return 0
				;;
			esac
		fi
		case "${arg}" in
		-XPOST | -Xpost | -XPUT | -Xput | -XPATCH | -Xpatch | -XDELETE | -Xdelete | --request=POST | --request=post | --request=PUT | --request=put | --request=PATCH | --request=patch | --request=DELETE | --request=delete)
			return 0
			;;
		-d | -d?* | --data | --data=* | -F | -F?* | --file | --file=*)
			# xurl v1.3.1 treats request data as POST and files as multipart writes.
			return 0
			;;
		esac
		previous="${arg}"
	done

	return 1
}

require_write_confirmation() {
	local command_name="$1"
	local confirmed="$2"

	if [[ ":${WRITE_COMMANDS}:" == *":${command_name}:"* ]] && [[ "${confirmed}" != "true" ]]; then
		print_error "Write action '${command_name}' requires explicit user approval and --confirm-write"
		return 1
	fi

	return 0
}

parse_options() {
	local current=""
	local value=""

	APP_NAME=""
	USERNAME=""
	LIMIT=""
	CONFIRM_WRITE="false"
	ARGS=()

	while [[ $# -gt 0 ]]; do
		current="${1:-}"
		case "${current}" in
		--app)
			if [[ $# -lt 2 ]]; then
				print_error "--app requires a value"
				return 1
			fi
			value="${2:-}"
			APP_NAME="${value}"
			shift 2
			;;
		--username)
			if [[ $# -lt 2 ]]; then
				print_error "--username requires a value"
				return 1
			fi
			value="${2:-}"
			USERNAME="${value}"
			shift 2
			;;
		--limit | -n)
			if [[ $# -lt 2 ]]; then
				print_error "--limit requires a value"
				return 1
			fi
			value="${2:-}"
			LIMIT="${value}"
			shift 2
			;;
		--confirm-write)
			CONFIRM_WRITE="true"
			shift
			;;
		--)
			shift
			while [[ $# -gt 0 ]]; do
				current="${1:-}"
				ARGS+=("${current}")
				shift
			done
			;;
		*)
			ARGS+=("${current}")
			shift
			;;
		esac
	done

	return 0
}

parse_and_execute() {
	local first_arg="${1:-help}"
	local command_name="${first_arg}"
	shift || true

	parse_options "$@" || return 1

	require_write_confirmation "${command_name}" "${CONFIRM_WRITE}" || return 1

	local xurl_args=()
	if [[ -n "${APP_NAME}" ]]; then
		xurl_args+=("--app" "${APP_NAME}")
	fi
	if [[ -n "${USERNAME}" ]]; then
		xurl_args+=("--username" "${USERNAME}")
	fi

	case "${command_name}" in
	help | -h | --help)
		show_help
		return 0
		;;
	status)
		run_xurl "${command_name}" auth status
		return 0
		;;
	whoami)
		run_xurl "${command_name}" "${xurl_args[@]}" whoami
		return 0
		;;
	search | timeline | mentions | bookmarks | likes | followers | following | dms)
		xurl_args+=("${command_name}")
		xurl_args+=("${ARGS[@]}")
		if [[ -n "${LIMIT}" ]]; then
			xurl_args+=("-n" "${LIMIT}")
		fi
		run_xurl "${command_name}" "${xurl_args[@]}"
		return 0
		;;
	read | user | post | reply | quote | delete | like | unlike | repost | unrepost | bookmark | unbookmark | follow | unfollow | block | unblock | mute | unmute | dm | media)
		xurl_args+=("${command_name}")
		xurl_args+=("${ARGS[@]}")
		run_xurl "${command_name}" "${xurl_args[@]}"
		return 0
		;;
	run)
		if [[ ${#ARGS[@]} -eq 0 ]]; then
			print_error "run requires raw xurl arguments after --"
			return 1
		fi
		if raw_args_are_mutating "${ARGS[@]}" && [[ "${CONFIRM_WRITE}" != "true" ]]; then
			print_error "Raw mutating API calls require explicit user approval and --confirm-write"
			return 1
		fi
		xurl_args+=("${ARGS[@]}")
		run_xurl "${command_name}" "${xurl_args[@]}"
		return 0
		;;
	*)
		print_error "Unknown command: ${command_name}"
		show_help
		return 1
		;;
	esac
}

main() {
	parse_and_execute "$@"
	return $?
}

main "$@"
