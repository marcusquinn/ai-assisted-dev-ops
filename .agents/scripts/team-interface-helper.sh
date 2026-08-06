#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

CORE_SCRIPT="${SCRIPT_DIR}/team-interface-core.mjs"

check_dependencies() {
	command -v node >/dev/null 2>&1 || {
		print_error "node is required for the team-interface runtime"
		return 1
	}
	[[ -f "$CORE_SCRIPT" ]] || {
		print_error "team-interface runtime core is unavailable"
		return 1
	}
	return 0
}

show_help() {
	cat <<'EOF'
team-interface-helper.sh — read-only provider runtime and deterministic planner

USAGE:
  team-interface-helper.sh providers [--config PATH]
  team-interface-helper.sh detect [--config PATH] [--state-dir PATH]
  team-interface-helper.sh status [--config PATH] [--state-dir PATH]
  team-interface-helper.sh doctor [--config PATH] [--state-dir PATH]
  team-interface-helper.sh plan --request PATH [--config PATH]

The initial runtime exposes no provider create, update, delete, apply, send, or
invite command. Output is JSON.
EOF
	return 0
}

run_core() {
	local command_name="${1:-}"
	shift || true
	check_dependencies || return 1
	if node "$CORE_SCRIPT" "$command_name" "$@"; then
		return 0
	fi
	return 1
}

main() {
	local command_name="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$command_name" in
	providers | detect | status | doctor | plan)
		run_core "$command_name" "$@"
		return $?
		;;
	help | -h | --help)
		show_help
		return 0
		;;
	*)
		print_error "unsupported read-only team-interface command: ${command_name}"
		show_help
		return 1
		;;
	esac
}

main "$@"
