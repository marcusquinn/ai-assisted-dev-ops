#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-collector-routine.sh — Deterministic private-source freshness runner

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEDULER="${SCRIPT_DIR}/knowledge_collector_schedule.py"

usage() {
	cat <<'EOF'
Usage: knowledge-collector-routine.sh plan|run|health [options]

Options:
  --config FILE   Private mode-0600 source policy registry
  --state FILE    Private content-free receipt/health state
  --dry-run       Plan run work without executing collectors or writing state

The routine executes only built-in folder, inbox-watch, mailbox, and social
collector entry points. It never evaluates config as shell code. Installation-
specific paths, account selectors, provider arguments, and schedules stay in
private config; public TODO.md contains only the disabled routine definition.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$command" in
	plan | run | health)
		if [[ ! -r "$SCHEDULER" ]] || ! command -v python3 >/dev/null 2>&1; then
			printf 'ERROR: knowledge collector scheduler is unavailable\n' >&2
			return 1
		fi
		python3 "$SCHEDULER" "$command" "$@" || return 1
		;;
	help | -h | --help) usage ;;
	*)
		printf 'ERROR: unknown knowledge collector routine command: %s\n' "$command" >&2
		usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
