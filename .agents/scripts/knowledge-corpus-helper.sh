#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-corpus-helper.sh — Private corpus catalog and authorization wrapper

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/knowledge_corpus_helpers.py"

usage() {
	cat <<'EOF'
Usage:
  knowledge-corpus-helper.sh provision [--base <path>]
  knowledge-corpus-helper.sh resolve [--base <path>] [--alias <name>] [--capability <capability>]
  knowledge-corpus-helper.sh list [--base <path>] [--capability <capability>]

The authenticated principal is always derived from <base>/_config/principal.json.
EOF
	return 0
}

main() {
	local command="${1:-help}"
	if [[ $# -gt 0 ]]; then
		shift
	fi
	case "$command" in
	provision | resolve | list)
		python3 "$PYTHON_HELPER" "$command" "$@"
		;;
	help | --help | -h)
		usage
		;;
	*)
		printf 'knowledge-corpus: unknown command: %s\n' "$command" >&2
		usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
