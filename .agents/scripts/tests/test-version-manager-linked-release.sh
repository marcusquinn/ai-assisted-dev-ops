#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
REMOTE="${ROOT}/remote.git"
REPO="${ROOT}/repo"
LINKED="${ROOT}/release-linked"

git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$REPO"
git -C "$REPO" switch -q -c main
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config commit.gpgsign false
printf 'seed\n' >"${REPO}/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m seed
git -C "$REPO" push -q -u origin main
git -C "$REPO" remote set-head origin main
git -C "$REPO" worktree add -q --detach "$LINKED" origin/main

print_error() { return 0; }
print_info() { return 0; }
print_warning() { return 0; }
print_success() { return 0; }
export SCRIPT_DIR REPO_ROOT="$REPO"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/version-manager-git.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/version-manager-preflight.sh"

force_flag=1
if assert_release_linked_worktree >/dev/null 2>&1; then
	printf 'FAIL canonical release context was bypassed by force\n'
	exit 1
fi
printf 'PASS canonical release context cannot be bypassed by force\n'

if verify_remote_sync main >/dev/null 2>&1; then
	printf 'FAIL canonical release execution was allowed\n'
	exit 1
fi
printf 'PASS canonical release execution is refused\n'

REPO_ROOT="$LINKED"
if verify_remote_sync main >/dev/null 2>&1; then
	printf 'PASS detached linked release worktree is accepted\n'
else
	printf 'FAIL detached linked release worktree was refused\n'
	exit 1
fi

PRE_EDIT="${SCRIPT_DIR}/pre-edit-check.sh"
if (cd "$LINKED" && PRE_EDIT_OWNER_PID="$$" bash "$PRE_EDIT" >/dev/null 2>&1); then
	printf 'PASS pre-edit accepts detached linked release worktree\n'
else
	printf 'FAIL pre-edit rejected detached linked release worktree\n'
	exit 1
fi

SHELLCHECK_LOG="${ROOT}/shellcheck.log"
shellcheck() {
	printf '%s\n' "$*" >>"$SHELLCHECK_LOG"
	return 0
}
printf '#!/usr/bin/env bash\n' >"${LINKED}/current.sh"
if (cd "$LINKED" && _run_shellcheck_on_changed_files v1.0.0 $'current.sh\ndeleted.sh\nREADME.md'); then
	if grep -qx -- '--severity=warning current.sh' "$SHELLCHECK_LOG" &&
		! grep -q 'deleted.sh' "$SHELLCHECK_LOG"; then
		printf 'PASS release preflight excludes deleted shell files from ShellCheck\n'
	else
		printf 'FAIL release preflight passed an unexpected changed file to ShellCheck\n'
		exit 1
	fi
else
	printf 'FAIL release preflight rejected a changed-file list containing a deletion\n'
	exit 1
fi
