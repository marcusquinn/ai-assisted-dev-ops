#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-gh-wrappers.sh
source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
trap '_run_cleanups' EXIT
trap '_run_cleanups; exit 130' HUP INT TERM

usage() {
	printf 'Usage: gh-write-helper.sh {issue|pr} edit <number-or-url> [gh edit options]\n'
	printf 'Bodies may use --body-file - to read stdin once through the safe wrapper.\n'
	return 0
}

main() {
	local resource="${1:-}"
	local action="${2:-}"
	if [[ "$resource" == "help" || "$resource" == "--help" || "$resource" == "-h" ]]; then
		usage
		return 0
	fi
	if [[ "$action" != "edit" ]]; then
		usage >&2
		return 2
	fi
	shift 2
	case "$resource" in
	issue) gh_issue_edit_safe "$@" ;;
	pr) gh_pr_edit_safe "$@" ;;
	*)
		usage >&2
		return 2
		;;
	esac
	return $?
}

main "$@"
