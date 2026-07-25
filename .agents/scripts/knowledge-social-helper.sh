#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# knowledge-social-helper.sh — Provider-neutral social corpus storage CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/knowledge_social_import.py"

usage() {
	cat <<'EOF'
Usage:
  knowledge-social-helper.sh provision [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh import-archive [--base PATH] [--alias ALIAS] --archive FILE
  knowledge-social-helper.sh rebuild [--base PATH] [--alias ALIAS]
  knowledge-social-helper.sh coverage [--base PATH] [--alias ALIAS]

The authenticated corpus catalog resolves ALIAS with knowledge.write for
mutating operations or knowledge.read for coverage. Physical corpus paths are
not accepted from callers.

Archive format:
  A UTF-8 JSON object with provider, connection_id, and arrays named accounts,
  objects, activities, media, and coverage. IDs must be provider-stable IDs;
  connection_id must be an opaque local ID. Unknown provider fields belong in
  provider_json objects. The original canonical payload is stored immutably.
EOF
	return 0
}

require_runtime() {
	if ! command -v python3 >/dev/null 2>&1; then
		printf 'ERROR: python3 is required for social corpus storage\n' >&2
		return 1
	fi
	if [[ ! -r "$PYTHON_HELPER" ]]; then
		printf 'ERROR: social corpus implementation missing: %s\n' "$PYTHON_HELPER" >&2
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
	provision | import-archive | rebuild | coverage)
		require_runtime || return 1
		python3 "$PYTHON_HELPER" "$subcommand" "$@" || return 1
		;;
	help | -h | --help)
		usage
		;;
	*)
		printf 'ERROR: unknown social corpus subcommand: %s\n' "$subcommand" >&2
		usage >&2
		return 1
		;;
	esac
	return 0
}

main "$@"
