#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

usage() {
	cat <<'EOF'
Usage:
  aidevops repos migrate-layout plan --workspace PATH --output PLAN.json [options]
  aidevops repos migrate-layout apply --plan PLAN.json --confirm PLAN_SHA256
  aidevops repos migrate-layout rollback --receipt ID --confirm RECEIPT_SHA256
  aidevops repos migrate-layout status --receipt ID

Plan options:
  --include-registered-paths   Approve exact initialized_repos[].path retargets
  --repos-json PATH           Override ~/.config/aidevops/repos.json
  --tabby-config PATH         Include an existing Tabby config
  --opencode-db PATH          Include an existing OpenCode database
  --isolated-root PATH        Include isolated OpenCode databases below PATH
  --recovery-root PATH        Include schema-v1 recovery markers below PATH
  --state-dir PATH            Override the private receipt directory

The plan command never mutates repositories or consumers. Apply and rollback
require the exact SHA-256 printed by plan/status and fail closed on drift.
EOF
	return 0
}

main() {
	local command_name="${1:-}"
	local engine="${SCRIPT_DIR}/repo_layout_migrate.py"
	local discovery_lib="${SCRIPT_DIR}/aidevops-cli/repo-discovery-lib.sh"
	local status=0

	case "$command_name" in
	plan | apply | rollback | status)
		shift
		python3 "$engine" "$command_name" --discovery-lib "$discovery_lib" "$@" || status=$?
		return "$status"
		;;
	-h | --help | help | "")
		usage
		return 0
		;;
	*)
		printf 'Unknown migrate-layout command: %s\n' "$command_name" >&2
		usage >&2
		return 2
		;;
	esac
}

main "$@"
