#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for the GH#29331 permission-domain extraction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORCHESTRATOR="${SCRIPT_DIR}/approval-helper.sh"
PERMISSIONS_MODULE="${SCRIPT_DIR}/approval-helper-permissions.sh"

assert_function_available() {
	local function_name="$1"
	if ! declare -F "$function_name" >/dev/null; then
		printf 'missing permission function after sourcing orchestrator: %s\n' "$function_name" >&2
		return 1
	fi
	return 0
}

# Existing callers source only the orchestrator; it must transparently load the
# focused module without executing main().
# shellcheck source=../approval-helper.sh
source "$ORCHESTRATOR"

[[ "${_APPROVAL_HELPER_PERMISSIONS_LOADED:-}" == "1" ]]
assert_function_available cmd_permissions
assert_function_available cmd_verify_permissions
assert_function_available _validate_permission_request_json
assert_function_available _validate_permission_grant_payload

# shellcheck disable=SC2016  # Assert the literal runtime-expanded source line.
grep -Fq 'source "${SCRIPT_DIR}/approval-helper-permissions.sh"' "$ORCHESTRATOR"
grep -Fq 'permissions) cmd_permissions "$@" ;;' "$ORCHESTRATOR"
grep -Fq 'verify-permissions) cmd_verify_permissions "$@" ;;' "$ORCHESTRATOR"

if grep -Eq '^(cmd_permissions|cmd_verify_permissions)\(\)' "$ORCHESTRATOR"; then
	printf 'permission command implementation remains in orchestrator\n' >&2
	exit 1
fi
grep -Eq '^cmd_permissions\(\)' "$PERMISSIONS_MODULE"
grep -Eq '^cmd_verify_permissions\(\)' "$PERMISSIONS_MODULE"

printf 'approval permission module boundary tests passed\n'
