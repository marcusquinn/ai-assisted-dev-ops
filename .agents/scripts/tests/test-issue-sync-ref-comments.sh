#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${TEST_SCRIPT_DIR}/../../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

LOGFILE="${TEST_ROOT}/sync.log"
export LOGFILE

log_verbose() { return 0; }

# shellcheck source=../issue-sync-lib.sh
unset SCRIPT_DIR
source "${REPO_ROOT}/.agents/scripts/issue-sync-lib.sh"

todo_file="${TEST_ROOT}/TODO.md"
cat >"$todo_file" <<'EOF'
# TODO

<!-- Format example:
- [ ] t3 Completed task example logged:2025-01-10
-->

- [ ] t3 Real task logged:2026-06-28
- [ ] t4 Child task blocked-by:t3 logged:2026-06-28
EOF

add_gh_ref_to_todo "t3" "3" "$todo_file"

if grep -q 'Completed task example.*ref:GH#3' "$todo_file"; then
	printf 'FAIL ref was added inside HTML comment example\n' >&2
	exit 1
fi

if ! grep -q '^- \[ \] t3 Real task ref:GH#3 logged:2026-06-28' "$todo_file"; then
	printf 'FAIL ref was not added to the real task line\n' >&2
	exit 1
fi

fix_gh_ref_in_todo "t3" "3" "30" "$todo_file"

if grep -q 'Completed task example.*ref:GH#30' "$todo_file"; then
	printf 'FAIL ref fix touched HTML comment example\n' >&2
	exit 1
fi

if ! grep -q '^- \[ \] t3 Real task ref:GH#30 logged:2026-06-28' "$todo_file"; then
	printf 'FAIL ref fix did not update the real task line\n' >&2
	exit 1
fi

printf 'PASS issue-sync refs ignore HTML comment examples\n'
