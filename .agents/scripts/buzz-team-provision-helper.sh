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
RUNTIME_HELPER="${SCRIPT_DIR}/team-interface-buzz-runtime.py"
PYTHON_BIN="${AIDEVOPS_PYTHON_BIN:-python3}"

usage() {
	printf '%s\n' \
		'Usage:' \
		'  buzz-team-provision-helper.sh status' \
		'  buzz-team-provision-helper.sh generate [--agents-dir DIR] [--host-slug NAME] [--output FILE]' \
		'  buzz-team-provision-helper.sh submit [--agents-dir DIR] [--host-slug NAME]' \
		'  buzz-team-provision-helper.sh runtime-manifest --project-root DIR [--output FILE]' \
		'  buzz-team-provision-helper.sh runtime-install --project-root DIR [--app-data-dir DIR] [--replace]' \
		'  Add --runtime interactive for the full OpenCode runtime used by team snapshots.' \
		'' \
		'generate and runtime-manifest are local-only. submit queues one deterministic' \
		'draft for explicit review. runtime-install requires Buzz to be stopped.'
	return 0
}

main() {
	if (($# == 0)); then
		usage
		return 0
	fi
	local command="$1"
	shift
	case "$command" in
	status | generate | submit)
		"$PYTHON_BIN" "$GENERATOR" "$command" "$@"
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
