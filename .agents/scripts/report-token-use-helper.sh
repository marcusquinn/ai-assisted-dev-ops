#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# report-token-use-helper.sh — generate local token-use reports per AI session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

PY_HELPER="${SCRIPT_DIR}/report-token-use-helper.py"

cmd_report() {
	python3 "$PY_HELPER" report "$@"
	return 0
}

cmd_data() {
	python3 "$PY_HELPER" data "$@"
	return 0
}

cmd_efficiency() {
	python3 "${SCRIPT_DIR}/report_token_efficiency.py" "$@"
	return 0
}

cmd_help() {
	cat <<'EOF'
report-token-use-helper.sh — local token-use reporting for AI sessions

USAGE:
  report-token-use-helper.sh report [--limit N] [--session ID] [--since 7d] [--runtime auto|opencode|claude] [--json] [--open]
  report-token-use-helper.sh data --json [--limit N] [--session ID] [--since 7d] [--runtime auto|opencode|claude]
  report-token-use-helper.sh efficiency [--since 30d] [--limit N] [--json]
  report-token-use-helper.sh help

OUTPUT:
  Writes report.md, report.json, and report.html under:
  ~/.aidevops/_reports/token-use/<UTC-run-id>/

ENVIRONMENT OVERRIDES:
  AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB  Override OpenCode SQLite DB path
  AIDEVOPS_REPORT_TOKEN_USE_OBS_DB       Override aidevops observability SQLite DB path
  AIDEVOPS_REPORT_TOKEN_USE_ROOT         Override report output root
EOF
	return 0
}

main() {
	local cmd="${1:-report}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$cmd" in
	report) cmd_report "$@" ;;
	data) cmd_data "$@" ;;
	efficiency) cmd_efficiency "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "unknown command: ${cmd}"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
