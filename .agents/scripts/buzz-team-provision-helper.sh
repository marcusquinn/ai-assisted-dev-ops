#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Queue canonical aidevops team snapshots through Buzz Desktop owner review.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

GENERATOR="${SCRIPT_DIR}/team-interface-buzz-team-snapshot.py"
LM_STUDIO_HELPER="${SCRIPT_DIR}/team-interface-buzz-lm-studio.py"
RUNTIME_HELPER="${SCRIPT_DIR}/team-interface-buzz-runtime.py"
PYTHON_BIN="${AIDEVOPS_PYTHON_BIN:-python3}"

usage() {
	printf '%s\n' \
		'Usage:' \
		'  buzz-team-provision-helper.sh status' \
		'  buzz-team-provision-helper.sh generate [--agents-dir DIR] [--host-slug NAME] [--output FILE|--stdout]' \
		'  buzz-team-provision-helper.sh submit [--agents-dir DIR] [--host-slug NAME]' \
		'  buzz-team-provision-helper.sh lm-studio-status [--require]' \
		'  buzz-team-provision-helper.sh runtime-manifest --project-root DIR [--output FILE]' \
		'  buzz-team-provision-helper.sh runtime-install --project-root DIR [--app-data-dir DIR] [--replace]' \
		'  Add --runtime interactive or --runtime lm-studio for snapshot runtimes.' \
		'' \
		'generate defaults to ~/Downloads/aidevops.team.json; use --stdout for pipelines.' \
		'runtime-manifest is local-only. submit queues one deterministic' \
		'draft for explicit review. runtime-install requires Buzz to be stopped.'
	return 0
}

generate_snapshot() {
	local has_destination="false"
	local argument=""
	for argument in "$@"; do
		case "$argument" in
		--output | --stdout | --downloads)
			has_destination="true"
			;;
		esac
	done
	if [[ "$has_destination" == "true" ]]; then
		"$PYTHON_BIN" "$GENERATOR" generate "$@"
		return $?
	fi
	"$PYTHON_BIN" "$GENERATOR" generate "$@" --downloads
	return $?
}

main() {
	if (($# == 0)); then
		usage
		return 0
	fi
	local command="$1"
	shift
	case "$command" in
	status | submit)
		"$PYTHON_BIN" "$GENERATOR" "$command" "$@"
		return $?
		;;
	generate)
		generate_snapshot "$@"
		return $?
		;;
	lm-studio-status)
		"$PYTHON_BIN" "$LM_STUDIO_HELPER" status "$@"
		return $?
		;;
	runtime-manifest)
		"$PYTHON_BIN" "$RUNTIME_HELPER" manifest "$@"
		return $?
		;;
	runtime-install)
		"$PYTHON_BIN" "$RUNTIME_HELPER" install "$@"
		return $?
		;;
	help | --help | -h)
		usage
		return 0
		;;
	*)
		print_error "Unknown Buzz team provisioning command: ${command}"
		usage >&2
		return 2
		;;
	esac
}

main "$@"
