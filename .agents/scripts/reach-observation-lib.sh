#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Reach search-observation command handlers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_REACH_OBSERVATION_LIB_LOADED:-}" ]] && return 0
_REACH_OBSERVATION_LIB_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=./shared-constants.sh
	# shellcheck disable=SC1091  # shared constants resolved at runtime via $SCRIPT_DIR
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

handle_observation_record() {
	local input_file=""
	local format="json"
	local arg=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
			--input) shift; input_file="${1:-}" ;;
			--format) shift; format="${1:-}" ;;
			*) log_error "Unknown observation record option"; return 1 ;;
		esac
		shift || true
	done
	require_json_format "$format" || return 1
	if [[ -z "$input_file" ]]; then
		log_error "observation record requires --input"
		return 1
	fi
	if [[ -L "$input_file" || ! -f "$input_file" ]]; then
		log_error "observation input must be a regular non-symlink file"
		return 1
	fi
	if ! command_available python3; then
		log_error "observation recording requires python3"
		return 1
	fi
	python3 "${SCRIPT_DIR}/reach-search-observation.py" record \
		--input "$input_file" \
		--workspace "$(reach_workspace_dir)"
	return $?
}

handle_observation() {
	local subcommand="${1:-}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
		record) handle_observation_record "$@"; return $? ;;
		*) log_error "observation requires record"; return 1 ;;
	esac
}
