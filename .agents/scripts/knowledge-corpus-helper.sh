#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-corpus-helper.sh — Private corpus catalog and authorization CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/knowledge_corpus_helpers.py"

usage() {
	cat <<'EOF'
Usage:
  knowledge-corpus-helper.sh provision [--base PATH]
  knowledge-corpus-helper.sh resolve [--base PATH] [--alias ALIAS] [--capability CAPABILITY]
  knowledge-corpus-helper.sh list [--base PATH] [--capability CAPABILITY]

Environment:
  KNOWLEDGE_CORPUS_BASE  Override the personal corpus catalog base.
  PERSONAL_PLANE_BASE    Compatibility fallback for the personal knowledge base.

Resolution derives the principal from the owner-only local context. Callers
cannot supply a principal ID or physical corpus ID.
EOF
	return 0
}

require_runtime() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ERROR: python3 is required for the corpus catalog\n' >&2
		return 1
	fi
	if [[ ! -r "$PYTHON_HELPER" ]]; then
		printf 'ERROR: corpus catalog implementation missing or unreadable: %s\n' "$PYTHON_HELPER" >&2
		return 1
	fi
	return 0
}

main() {
	local subcommand="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$subcommand" in
	provision | resolve | list)
		require_runtime || return 1
		python3 "$PYTHON_HELPER" "$subcommand" "$@" || return 1
		;;
	help | -h | --help)
		usage
		;;
	*)
		printf 'ERROR: unknown corpus subcommand: %s\n' "$subcommand" >&2
		usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
