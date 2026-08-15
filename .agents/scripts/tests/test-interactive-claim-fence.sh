#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Deterministic regression for the #30147 stale-recovery/duplicate-worker order.

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
TEST_ROOT=$(mktemp -d -t gh30274.XXXXXX)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
export CLAIM_STAMP_DIR="${TEST_ROOT}/claims"
mkdir -p "$CLAIM_STAMP_DIR" "${HOME}/.aidevops/.agent-workspace"

TESTS_RUN=0
TESTS_FAILED=0
pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf 'PASS %s\n' "$1"; return 0; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf 'FAIL %s\n' "$1"; return 0; }

# Source the production helper, then replace external probes with deterministic
# fixtures while retaining its stamp/worktree/head decision flow.
# shellcheck source=../interactive-claim-fence.sh
source "${SCRIPTS_DIR}/interactive-claim-fence.sh"
_is_process_alive_and_matches() { [[ "$1" == "4242" ]]; }
check_worktree_owner() { printf '4242|session-30147||30147|2026-08-14T19:54:06Z\n'; return 0; }

WORKTREE="${TEST_ROOT}/worktree"
REMOTE="${TEST_ROOT}/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1 || exit 1
git init "$WORKTREE" >/dev/null 2>&1 || exit 1
git -C "$WORKTREE" config user.email test@example.invalid
git -C "$WORKTREE" config user.name Test
git -C "$WORKTREE" remote add origin "https://github.com/owner/repo.git"
printf 'base\n' >"${WORKTREE}/fixture.txt"
git -C "$WORKTREE" add fixture.txt
git -C "$WORKTREE" commit -m base >/dev/null 2>&1
git -C "$WORKTREE" branch -M main
git -C "$WORKTREE" remote set-url --push origin "$REMOTE"
git -C "$WORKTREE" push -u origin main >/dev/null 2>&1
git -C "$WORKTREE" remote set-head origin main >/dev/null 2>&1

STAMP="${CLAIM_STAMP_DIR}/owner-repo-30147.json"
jq -n --arg worktree "$WORKTREE" --arg host "$(hostname 2>/dev/null || printf unknown)" \
	'{issue:30147,slug:"owner/repo",worktree_path:$worktree,pid:4242,hostname:$host,owner_argv_hash:"fixture"}' >"$STAMP"

if _interactive_claim_fence_blocks_dispatch 30147 owner/repo; then
	pass "live interactive owner blocks dispatch beyond GitHub age thresholds"
else
	fail "live interactive owner blocks dispatch beyond GitHub age thresholds"
fi

printf 'interactive work\n' >>"${WORKTREE}/fixture.txt"
git -C "$WORKTREE" add fixture.txt
git -C "$WORKTREE" commit -m "interactive work" >/dev/null 2>&1
WORKTREE_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
if _interactive_claim_fence_blocks_merge 30147 owner/repo deadbeef; then
	pass "different worker head cannot merge over unmerged interactive commits"
else
	fail "different worker head cannot merge over unmerged interactive commits"
fi
if _interactive_claim_fence_blocks_merge 30147 owner/repo "$WORKTREE_HEAD"; then
	fail "interactive owner's exact head remains merge eligible"
else
	pass "interactive owner's exact head remains merge eligible"
fi

# Lock the event ordering: stale recovery must consult the local ownership fence
# before comments, two-hour age, missing worker PID, or recovery mutation.
STALE_FETCH_CALLED=0
STALE_RECOVER_CALLED=0
_stale_assignment_fetch_comments_json() { STALE_FETCH_CALLED=1; printf '[]'; return 0; }
_recover_stale_assignment() { STALE_RECOVER_CALLED=1; return 0; }
# shellcheck source=../dispatch-dedup-stale.sh
source "${SCRIPTS_DIR}/dispatch-dedup-stale.sh"
if _is_stale_assignment 30147 owner/repo marcusquinn; then
	fail "#30147 ordering preserves live ownership before stale recovery"
elif [[ "$STALE_FETCH_CALLED" -eq 0 && "$STALE_RECOVER_CALLED" -eq 0 ]]; then
	pass "#30147 ordering preserves live ownership before stale recovery"
else
	fail "#30147 ordering preserves live ownership before stale recovery"
fi

_is_process_alive_and_matches() { return 1; }
if _interactive_claim_fence_blocks_dispatch 30147 owner/repo; then
	fail "proven-dead local interactive owner remains dispatch-blocking"
else
	pass "proven-dead local interactive owner remains recoverable"
fi

printf '\n%s tests, %s failures\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
