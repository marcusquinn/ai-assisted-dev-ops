#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Thin entrypoint for the worktree-removal audit regression suite.

set -euo pipefail

if [[ -n "${_TEST_WORKTREE_REMOVAL_AUDIT_LOADED:-}" ]]; then
	return 0 2>/dev/null || exit 0
fi
_TEST_WORKTREE_REMOVAL_AUDIT_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_test_script_path="${BASH_SOURCE[0]%/*}"
	[[ "$_test_script_path" == "${BASH_SOURCE[0]}" ]] && _test_script_path="."
	SCRIPT_DIR="$(cd "$_test_script_path" && pwd)"
	unset _test_script_path
fi

# shellcheck source=./test-worktree-removal-audit-lib.sh
# shellcheck disable=SC1091  # test library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/test-worktree-removal-audit-lib.sh"
