#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${TEST_DIR}/../codegraph-worktree-init-helper.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

wait_for_file() {
	local file_path="$1"
	local attempts="${2:-50}"
	local attempt=0
	while [[ ! -f "$file_path" && "$attempt" -lt "$attempts" ]]; do
		sleep 0.1
		attempt=$((attempt + 1))
	done
	[[ -f "$file_path" ]]
}

wait_for_count() {
	local file_path="$1"
	local expected_count="$2"
	local attempts="${3:-50}"
	local attempt=0
	local actual_count=0
	while [[ "$attempt" -lt "$attempts" ]]; do
		actual_count=0
		if [[ -f "$file_path" ]]; then
			actual_count=$(wc -l <"$file_path" | tr -d ' ')
		fi
		[[ "$actual_count" -ge "$expected_count" ]] && return 0
		sleep 0.1
		attempt=$((attempt + 1))
	done
	return 1
}

create_linked_worktree() {
	local name="$1"
	local canonical="${TEST_ROOT}/${name}-canonical"
	local linked="${TEST_ROOT}/${name}-linked"
	mkdir -p "$canonical"
	git -C "$canonical" init -q
	git -C "$canonical" config user.email test@example.invalid
	git -C "$canonical" config user.name Test
	printf 'fixture\n' >"${canonical}/README.md"
	git -C "$canonical" add README.md
	git -C "$canonical" commit -qm init
	git -C "$canonical" worktree add -q -b "feature/${name}" "$linked"
	(cd "$linked" && pwd -P)
	return 0
}

FAKE_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_BIN"
FAKE_CODEGRAPH="${FAKE_BIN}/codegraph"
cat >"$FAKE_CODEGRAPH" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if ! mkdir "${CODEGRAPH_ACTIVE_DIR}" 2>/dev/null; then
	printf 'overlap\n' >>"${CODEGRAPH_OVERLAP_FILE}"
	exit 9
fi
trap 'rmdir "${CODEGRAPH_ACTIVE_DIR}" 2>/dev/null || true' EXIT
printf '%s\t%s\t%s\n' "$1" "$2" "$PWD" >>"${CODEGRAPH_CALLS_FILE}"
sleep "${CODEGRAPH_FAKE_SLEEP:-0}"
if [[ "${CODEGRAPH_FAKE_FAIL:-0}" == "1" ]]; then
	exit 7
fi
mkdir -p "$2/.codegraph"
printf 'ready\n' >"$2/.codegraph/codegraph.db"
FAKE
chmod +x "$FAKE_CODEGRAPH" "$HELPER"

export AIDEVOPS_CODEGRAPH_BIN="$FAKE_CODEGRAPH"
export AIDEVOPS_CODEGRAPH_FORCE_NO_SYSTEMD=1
export AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS=5
export AIDEVOPS_CODEGRAPH_INIT_QUEUE_TIMEOUT_SECONDS=5
export AIDEVOPS_CODEGRAPH_INIT_LOCK_STALE_SECONDS=10
export AIDEVOPS_MIN_WORKTREE_FREE_KB=1
export AIDEVOPS_MIN_WORKTREE_FREE_PERCENT=0
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/state"
export AIDEVOPS_LOG_DIR="${TEST_ROOT}/logs"
export AIDEVOPS_CODEGRAPH_LOG_FILE="${AIDEVOPS_LOG_DIR}/codegraph.log"
export CODEGRAPH_CALLS_FILE="${TEST_ROOT}/calls.log"
export CODEGRAPH_ACTIVE_DIR="${TEST_ROOT}/codegraph-active.lock"
export CODEGRAPH_OVERLAP_FILE="${TEST_ROOT}/overlap.log"

LINKED_ONE=$(create_linked_worktree one)
export CODEGRAPH_FAKE_SLEEP=2
"$HELPER" launch "$LINKED_ONE" 30661
[[ ! -e "${LINKED_ONE}/.codegraph/codegraph.db" ]] || fail "launch waited for CodeGraph initialization"
wait_for_file "${LINKED_ONE}/.codegraph/codegraph.db" || fail "asynchronous init did not create the worktree index"
first_call=$(sed -n '1p' "$CODEGRAPH_CALLS_FILE")
[[ "$first_call" == $'init\t'"${LINKED_ONE}"$'\t'"${LINKED_ONE}" ]] || fail "CodeGraph received the wrong command, path, or cwd"

rm -f "${LINKED_ONE}/.codegraph/codegraph.db"
export CODEGRAPH_FAKE_SLEEP=1
"$HELPER" launch "$LINKED_ONE" 30661
"$HELPER" launch "$LINKED_ONE" 30661
wait_for_file "${LINKED_ONE}/.codegraph/codegraph.db" || fail "reused worktree did not converge"
sleep 0.2
call_count=$(wc -l <"$CODEGRAPH_CALLS_FILE" | tr -d ' ')
[[ "$call_count" -eq 2 ]] || fail "duplicate launch bypassed per-worktree singleflight"

LINKED_TWO=$(create_linked_worktree two)
LINKED_THREE=$(create_linked_worktree three)
export CODEGRAPH_FAKE_SLEEP=1
"$HELPER" launch "$LINKED_TWO" 2
"$HELPER" launch "$LINKED_THREE" 3
wait_for_count "$CODEGRAPH_CALLS_FILE" 4 80 || fail "globally queued worktree init did not complete"
two_line=$(grep -n "${LINKED_TWO}" "$CODEGRAPH_CALLS_FILE" | cut -d: -f1)
three_line=$(grep -n "${LINKED_THREE}" "$CODEGRAPH_CALLS_FILE" | cut -d: -f1)
[[ "$two_line" -ne "$three_line" ]] || fail "distinct worktrees were not initialized"
[[ ! -e "$CODEGRAPH_OVERLAP_FILE" ]] || fail "global concurrency lock allowed overlapping CodeGraph processes"

LINKED_FOUR=$(create_linked_worktree four)
export AIDEVOPS_CODEGRAPH_BIN="${TEST_ROOT}/missing-codegraph"
"$HELPER" launch "$LINKED_FOUR" 4
sleep 0.2
[[ ! -e "${LINKED_FOUR}/.codegraph/codegraph.db" ]] || fail "missing CodeGraph binary changed the worktree"

export AIDEVOPS_CODEGRAPH_BIN="$FAKE_CODEGRAPH"
export AIDEVOPS_CODEGRAPH_INIT_TIMEOUT_SECONDS=1
export CODEGRAPH_FAKE_SLEEP=3
"$HELPER" launch "$LINKED_FOUR" 4
sleep 2
[[ ! -e "${LINKED_FOUR}/.codegraph/codegraph.db" ]] || fail "timed-out CodeGraph init wrote a completed index"
grep -q 'status=failed rc=124 issue=4' "$AIDEVOPS_CODEGRAPH_LOG_FILE" || fail "timeout was not recorded as a bounded failure"

printf 'PASS: CodeGraph worktree init is asynchronous, local, singleflight, queued, optional, and bounded\n'
