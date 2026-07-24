#!/usr/bin/env bash
# shellcheck disable=SC2218  # Functions defined via dynamic source
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-precreation-failure-skip.sh — t2981 / GH#21353 regression guard.
#
# Asserts that worktree pre-creation failures are observable:
#   1. _dlw_precreate_worktree returns 1 when path extraction fails
#   2. _dlw_precreate_worktree marks fresh worktree creation as non-reused
#   3. _dlw_precreate_worktree marks existing issue worktree reuse
#   4. _dlw_check_worker_branch_orphan_loop skips fresh branches
#   5. _dlw_check_worker_branch_orphan_loop still checks reused branches
#   6. _dispatch_launch_worker skips dispatch (no setsid) when pre-creation fails
#   7. worktree_precreation_failed_count counter is incremented on failure
#   8. --dir argument no longer contains repo_path fallback
#
# Stub strategy: stub worktree-helper.sh, git, and dependent functions
# to isolate _dlw_precreate_worktree and _dispatch_launch_worker.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# =============================================================================
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2981.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export LOGFILE="${TMP}/test-pulse.log"
export SCRIPT_DIR="$TMP"
export PULSE_STATS_FILE="${TMP}/pulse-stats.json"

# Seed pulse-stats.json with minimal valid structure
printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

# Create a fake repo_path directory
FAKE_REPO="${TMP}/fake-repo"
mkdir -p "$FAKE_REPO"

# =============================================================================
# Stub: worktree-helper.sh that emits configurable output
# =============================================================================
STUB_WT_HELPER="${TMP}/worktree-helper.sh"
cat >"$STUB_WT_HELPER" <<'STUB_EOF'
#!/usr/bin/env bash
# Stub worktree-helper.sh — output depends on STUB_WT_MODE
case "${STUB_WT_MODE:-fail}" in
	fail)
		echo "Error: something went wrong, no path here"
		exit 1
		;;
	success)
		# Emit output with a parseable path. Tests intentionally use both
		# /Git/ and non-/Git/ paths to guard path-root assumptions.
		echo "Created worktree at ${STUB_WT_SUCCESS_PATH}"
		exit 0
		;;
esac
STUB_EOF
chmod +x "$STUB_WT_HELPER"

# =============================================================================
# Stub: git (for worktree list — returns empty by default)
# =============================================================================
git() {
	# For worktree list, return configured worktrees or nothing.
	if [[ "${1:-}" == "-C" && "${3:-}" == "worktree" && "${4:-}" == "list" ]]; then
		if [[ "${5:-}" == "--porcelain" && -n "${STUB_PORCELAIN_WORKTREE_PATH:-}" && -n "${STUB_PORCELAIN_WORKTREE_BRANCH:-}" ]]; then
			printf 'worktree %s\n' "$STUB_PORCELAIN_WORKTREE_PATH"
			printf 'HEAD abcdef0123456789\n'
			printf 'branch refs/heads/%s\n' "$STUB_PORCELAIN_WORKTREE_BRANCH"
			return 0
		fi
		if [[ -n "${STUB_EXISTING_WORKTREE_LINE:-}" ]]; then
			printf '%s\n' "$STUB_EXISTING_WORKTREE_LINE"
		fi
		return 0
	fi
	# For symbolic-ref, return main
	if [[ "${1:-}" == "-C" && "${3:-}" == "symbolic-ref" ]]; then
		echo "refs/remotes/origin/main"
		return 0
	fi
	# Fallback: bypass the policy shim for disposable repositories under $TMP.
	command -p git "$@"
	return $?
}
export -f git

# =============================================================================
# Stub dependent functions that _dlw_precreate_worktree calls
# =============================================================================
_dlw_restore_worktree_deps() { return 0; }
REGISTERED_WORKTREE_ARGS=""

# =============================================================================
# Source pulse-stats-helper.sh for pulse_stats_increment
# =============================================================================
# shellcheck source=../pulse-stats-helper.sh
source "${SCRIPTS_DIR}/pulse-stats-helper.sh"

# Disable errexit — sourced modules may set -e; we check return codes explicitly
set +e

# =============================================================================
# Source the module under test
# =============================================================================
# Unset the load guard so we can source it.
unset _PULSE_DISPATCH_WORKER_LAUNCH_LOADED

# Stub functions that the module depends on but we don't test here
lock_issue_for_worker() { return 0; }
_dlw_assign_and_label() { return 0; }
_dlw_setup_worker_log() { echo "${TMP}/worker.log"; return 0; }
_dlw_resolve_tier_and_model() {
	_DLW_DISPATCH_TIER="standard"
	_DLW_DISPATCH_MODEL_TIER="standard"
	_DLW_SELECTED_MODEL=""
	return 0
}
_dlw_prewarm_opencode_db() { _DLW_PREWARM_DIR=""; return 0; }
_dlw_exec_detached() {
	# Record that setsid would have been called
	echo "SETSID_CALLED" >>"${TMP}/setsid-calls.txt"
	printf '%s\n' "$@" >"${TMP}/launch-args.txt"
	echo "12345"  # fake PID
	return 0
}
_dlw_post_launch_hooks() { return 0; }
HEADLESS_RUNTIME_HELPER="${TMP}/fake-headless-runtime"

# shellcheck source=../pulse-dispatch-worker-launch.sh
source "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh"

# Restore SCRIPT_DIR to point to our stub directory (sourced modules may
# overwrite it). _dlw_precreate_worktree uses SCRIPT_DIR to find
# worktree-helper.sh.
SCRIPT_DIR="$TMP"

# Re-stub register_worktree after sourcing; shared helper libraries may define
# the real registry function, but this test only needs to assert transferable
# ownership metadata passed by _dlw_precreate_worktree.
register_worktree() {
	local wt_path="$1"
	local branch="$2"
	shift 2
	local task="" session=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task="${2:-}"
			shift 2
			;;
		--session)
			session="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	REGISTERED_WORKTREE_ARGS="${wt_path}|${branch}|${task}|${session}"
	return 0
}
STUB_OWNER_INFO=""
check_worktree_owner() {
	local wt_path="$1"
	[[ -n "$wt_path" && -n "$STUB_OWNER_INFO" ]] || return 1
	printf '%s\n' "$STUB_OWNER_INFO"
	return 0
}
CLAIMED_WORKTREE_ARGS=""
STUB_CLAIM_WORKTREE_RC=0
claim_worktree_ownership() {
	local wt_path="$1"
	local branch="$2"
	shift 2
	local task="" session=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)
			task="${2:-}"
			shift 2
			;;
		--session)
			session="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done
	CLAIMED_WORKTREE_ARGS="${wt_path}|${branch}|${task}|${session}"
	[[ "$STUB_CLAIM_WORKTREE_RC" -eq 0 ]] || return 1
	return 0
}

# Re-stub launch-orchestrator dependencies after sourcing; the module defines
# real implementations when loaded, but this test isolates precreation failure.
_ds_now_ns() { printf '0\n'; return 0; }
_ds_record() { return 0; }
_dlw_resolve_tier_and_model() {
	_DLW_DISPATCH_TIER="standard"
	_DLW_DISPATCH_MODEL_TIER="standard"
	_DLW_SELECTED_MODEL=""
	return 0
}
_dlw_canary_preflight() { return 0; }
_dlw_prebootstrap_gates() { return 0; }
_dlw_assign_and_label() { return 0; }
_dlw_prepare_opencode_db() { _DLW_PREWARM_DIR=""; return 0; }
_dlw_min_worker_floor_active() { return 1; }
_dlw_bundle_agent_name() { return 1; }
_worker_attempt_start_marker() { printf '123\n'; return 0; }
_dlw_exec_detached() {
	[[ -z "${ORCHESTRATOR_CALLS_FILE:-}" ]] || printf 'spawn\n' >>"$ORCHESTRATOR_CALLS_FILE"
	echo "SETSID_CALLED" >>"${TMP}/setsid-calls.txt"
	printf '%s\n' "$@" >"${TMP}/launch-args.txt"
	echo "12345"
	return 0
}
STUB_REFRESH_STATE="OPEN"

gh() {
	if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
		printf '%s\n' "$STUB_REFRESH_STATE"
		return 0
	fi

	return 0
}
CLAIM_LOCK_CALLS_FILE="${TMP}/claim-lock-calls.txt"
_dedup_layer7_claim_lock() {
	printf '%s\n' "${1:-}" >>"$CLAIM_LOCK_CALLS_FILE"
	return "${STUB_CLAIM_LOCK_RC:-1}"
}

printf '\n%s\n' "=== t2981: worktree pre-creation failure observability ==="

# Stub dispatch-dedup-helper.sh used by _dlw_check_worker_branch_orphan_loop.
STUB_DEDUP_HELPER="${TMP}/dispatch-dedup-helper.sh"
cat >"$STUB_DEDUP_HELPER" <<'STUB_DEDUP_EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >>"${STUB_DEDUP_CALLS_FILE:?}"
printf 'orphan-loop-detected\n'
exit 0
STUB_DEDUP_EOF
chmod +x "$STUB_DEDUP_HELPER"
export STUB_DEDUP_CALLS_FILE="${TMP}/dedup-helper-calls.txt"

# =============================================================================
# Test 1: _dlw_precreate_worktree returns 1 when path extraction fails
# =============================================================================
export STUB_WT_MODE="fail"
: >"$LOGFILE"
_dlw_precreate_worktree "99999" "$FAKE_REPO"
rc=$?
if [[ $rc -eq 1 ]]; then
	pass "precreate returns 1 on path-extraction failure"
else
	fail "precreate returns 1 on path-extraction failure" "got rc=$rc, expected 1"
fi

# Verify the warning message was logged
if grep -q "pre-creation failed for #99999" "$LOGFILE" 2>/dev/null; then
	pass "failure log message includes issue number"
else
	fail "failure log message includes issue number" "LOGFILE: $(cat "$LOGFILE")"
fi

# Verify _DLW_WORKTREE_PATH is empty on failure
if [[ -z "$_DLW_WORKTREE_PATH" ]]; then
	pass "worktree path is empty on failure"
else
	fail "worktree path is empty on failure" "got: $_DLW_WORKTREE_PATH"
fi

# =============================================================================
# Test 2: _dlw_precreate_worktree returns 0 when creation succeeds
# =============================================================================
export STUB_WT_MODE="success"
STUB_WT_SUCCESS_PATH="${TMP}/projects/fake-repo-feature"
export STUB_WT_SUCCESS_PATH
mkdir -p "$STUB_WT_SUCCESS_PATH"
: >"$LOGFILE"
REGISTERED_WORKTREE_ARGS=""
CLAIMED_WORKTREE_ARGS=""
_dlw_precreate_worktree "88888" "$FAKE_REPO"
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "precreate returns 0 on success"
else
	fail "precreate returns 0 on success" "got rc=$rc, expected 0"
fi

if [[ "$_DLW_WORKTREE_PATH" == "$STUB_WT_SUCCESS_PATH" ]]; then
	pass "worktree path is set on success"
else
	fail "worktree path is set on success" "got: '$_DLW_WORKTREE_PATH', expected: '$STUB_WT_SUCCESS_PATH'"
fi

if [[ "${_DLW_WORKTREE_REUSED:-unset}" == "0" ]]; then
	pass "freshly-created worktree is marked non-reused"
else
	fail "freshly-created worktree is marked non-reused" "got: '${_DLW_WORKTREE_REUSED:-unset}', expected: '0'"
fi

if [[ "$REGISTERED_WORKTREE_ARGS" == "${STUB_WT_SUCCESS_PATH}|${_DLW_WORKTREE_BRANCH}|88888|dispatch-precreate-88888" ]]; then
	pass "fresh precreated worktree is registered as transferable"
else
	fail "fresh precreated worktree is registered as transferable" "got: '$REGISTERED_WORKTREE_ARGS'"
fi

if [[ -z "$CLAIMED_WORKTREE_ARGS" ]]; then
	pass "fresh precreated worktree does not use the reuse claim path"
else
	fail "fresh precreated worktree does not use the reuse claim path" "got: '$CLAIMED_WORKTREE_ARGS'"
fi

# =============================================================================
# Test 2b: _dlw_precreate_worktree prefers git porcelain path resolution
# =============================================================================
export STUB_WT_MODE="success"
STUB_WT_SUCCESS_PATH="${TMP}/helper-output-should-not-win"
STUB_PORCELAIN_WORKTREE_PATH="${TMP}/projects/fake-repo-porcelain"
STUB_PORCELAIN_WORKTREE_BRANCH="feature/auto-$(date +%Y%m%d-%H%M%S)-gh77777"
export STUB_WT_SUCCESS_PATH STUB_PORCELAIN_WORKTREE_PATH STUB_PORCELAIN_WORKTREE_BRANCH
mkdir -p "$STUB_WT_SUCCESS_PATH" "$STUB_PORCELAIN_WORKTREE_PATH"
: >"$LOGFILE"
_dlw_precreate_worktree "77777" "$FAKE_REPO"
rc=$?
unset STUB_PORCELAIN_WORKTREE_PATH STUB_PORCELAIN_WORKTREE_BRANCH

if [[ $rc -eq 0 && "$_DLW_WORKTREE_PATH" == "${TMP}/projects/fake-repo-porcelain" ]]; then
	pass "precreate resolves non-/Git/ path from git porcelain"
else
	fail "precreate resolves non-/Git/ path from git porcelain" "rc=$rc path='$_DLW_WORKTREE_PATH'"
fi

# =============================================================================
# Test 3: _dlw_precreate_worktree marks existing issue worktree reuse
# =============================================================================
export STUB_WT_MODE="fail"
STUB_EXISTING_PATH="${TMP}/Git/fake-repo-existing"
STUB_EXISTING_BRANCH="feature/auto-20260502-000000-gh66666"
mkdir -p "$STUB_EXISTING_PATH"
export STUB_EXISTING_WORKTREE_LINE="${STUB_EXISTING_PATH} abcdef [${STUB_EXISTING_BRANCH}]"
: >"$LOGFILE"
REGISTERED_WORKTREE_ARGS=""
CLAIMED_WORKTREE_ARGS=""
STUB_OWNER_INFO="12345|generation-7|batch-7|66666|2026-07-18T00:00:00Z"
_dlw_precreate_worktree "66666" "$FAKE_REPO"
rc=$?
unset STUB_EXISTING_WORKTREE_LINE

if [[ $rc -eq 0 && "$_DLW_WORKTREE_PATH" == "$STUB_EXISTING_PATH" && "$_DLW_WORKTREE_BRANCH" == "$STUB_EXISTING_BRANCH" ]]; then
	pass "existing issue worktree is reused"
else
	fail "existing issue worktree is reused" "rc=$rc path='$_DLW_WORKTREE_PATH' branch='$_DLW_WORKTREE_BRANCH'"
fi

if [[ "${_DLW_WORKTREE_REUSED:-unset}" == "1" ]]; then
	pass "reused worktree is marked reused"
else
	fail "reused worktree is marked reused" "got: '${_DLW_WORKTREE_REUSED:-unset}', expected: '1'"
fi

if [[ -z "$REGISTERED_WORKTREE_ARGS" ]]; then
	pass "reused worktree does not replace its live registry owner"
else
	fail "reused worktree does not replace its live registry owner" "got registration: '$REGISTERED_WORKTREE_ARGS'"
fi

if [[ -z "$CLAIMED_WORKTREE_ARGS" ]]; then
	pass "reused worktree with a captured owner does not use the unowned claim path"
else
	fail "reused worktree with a captured owner does not use the unowned claim path" "got: '$CLAIMED_WORKTREE_ARGS'"
fi

if [[ "${_DLW_WORKTREE_TRANSFER_MODE:-}" == "continuation" &&
	"${_DLW_WORKTREE_EXPECTED_OWNER_PID:-}" == "12345" &&
	"${_DLW_WORKTREE_EXPECTED_OWNER_SESSION:-}" == "generation-7" &&
	"${_DLW_WORKTREE_EXPECTED_OWNER_BATCH:-}" == "batch-7" &&
	"${_DLW_WORKTREE_EXPECTED_OWNER_TASK:-}" == "66666" &&
	"${_DLW_WORKTREE_EXPECTED_OWNER_CREATED_AT:-}" == "2026-07-18T00:00:00Z" ]]; then
	pass "reused worktree captures exact continuation owner identity"
else
	fail "reused worktree captures exact continuation owner identity" \
		"mode=${_DLW_WORKTREE_TRANSFER_MODE:-unset} pid=${_DLW_WORKTREE_EXPECTED_OWNER_PID:-unset} session=${_DLW_WORKTREE_EXPECTED_OWNER_SESSION:-unset} task=${_DLW_WORKTREE_EXPECTED_OWNER_TASK:-unset}"
fi
STUB_OWNER_INFO=""

if grep -Fq "Preserving reused worktree until its expected continuation owner transfers" "$LOGFILE"; then
	pass "dispatch does not mutate a reused worktree before owner transfer"
else
	fail "dispatch does not mutate a reused worktree before owner transfer" "missing preservation log"
fi

# =============================================================================
# Test 3b: an unowned reused worktree is claimed atomically before preparation
# =============================================================================
export STUB_EXISTING_WORKTREE_LINE="${STUB_EXISTING_PATH} abcdef [${STUB_EXISTING_BRANCH}]"
REGISTERED_WORKTREE_ARGS=""
CLAIMED_WORKTREE_ARGS=""
STUB_CLAIM_WORKTREE_RC=0
: >"$LOGFILE"
_dlw_precreate_worktree "66666" "$FAKE_REPO"
rc=$?
expected_claim="${STUB_EXISTING_PATH}|${STUB_EXISTING_BRANCH}|66666|dispatch-precreate-66666"
if [[ "$rc" -eq 0 && "$CLAIMED_WORKTREE_ARGS" == "$expected_claim" && -z "$REGISTERED_WORKTREE_ARGS" ]]; then
	pass "unowned reused worktree uses an atomic ownership claim"
else
	fail "unowned reused worktree uses an atomic ownership claim" \
		"rc=$rc claim='$CLAIMED_WORKTREE_ARGS' registration='$REGISTERED_WORKTREE_ARGS'"
fi

REGISTERED_WORKTREE_ARGS=""
CLAIMED_WORKTREE_ARGS=""
STUB_CLAIM_WORKTREE_RC=1
if _dlw_precreate_worktree "66666" "$FAKE_REPO"; then
	rc=0
else
	rc=$?
fi
if [[ "$rc" -eq 1 && "$CLAIMED_WORKTREE_ARGS" == "$expected_claim" && -z "$REGISTERED_WORKTREE_ARGS" ]] && \
	grep -Fq "Atomic owner claim rejected for reused worktree #66666" "$LOGFILE"; then
	pass "reused worktree fails closed when its atomic ownership claim is rejected"
else
	fail "reused worktree fails closed when its atomic ownership claim is rejected" \
		"rc=$rc claim='$CLAIMED_WORKTREE_ARGS' registration='$REGISTERED_WORKTREE_ARGS'"
fi
STUB_CLAIM_WORKTREE_RC=0
unset STUB_EXISTING_WORKTREE_LINE

# =============================================================================
# Test 4: a clean ahead worktree preserves continuation commits
# =============================================================================
AHEAD_WORKTREE="${TMP}/ahead-worktree"
mkdir -p "$AHEAD_WORKTREE"
git -C "$AHEAD_WORKTREE" init -q
git -C "$AHEAD_WORKTREE" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
	-c commit.gpgsign=false \
	commit --allow-empty -q -m "initial"
git -C "$AHEAD_WORKTREE" update-ref refs/remotes/origin/main HEAD
git -C "$AHEAD_WORKTREE" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null
git -C "$AHEAD_WORKTREE" -c user.name="aidevops-test" -c user.email="aidevops-test@example.invalid" \
	-c commit.gpgsign=false \
	commit --allow-empty -q -m "continuation checkpoint"
ahead_head_before=$(git -C "$AHEAD_WORKTREE" rev-parse HEAD)
_dlw_prepare_existing_worktree "$AHEAD_WORKTREE" "$AHEAD_WORKTREE"
ahead_head_after=$(git -C "$AHEAD_WORKTREE" rev-parse HEAD)
ahead_count=$(git -C "$AHEAD_WORKTREE" rev-list --count origin/main..HEAD)
if [[ "$ahead_head_after" == "$ahead_head_before" && "$ahead_count" == "1" ]]; then
	pass "clean ahead continuation preserves local commits"
else
	fail "clean ahead continuation preserves local commits" \
		"before=$ahead_head_before after=$ahead_head_after ahead=$ahead_count"
fi

# =============================================================================
# Test 5: continuation owner identity is passed through the worker launch env
# =============================================================================
self_login="testuser"
: >"${TMP}/launch-args.txt"
_DLW_WORKTREE_TRANSFER_MODE="continuation"
_DLW_WORKTREE_EXPECTED_OWNER_PID="12345"
_DLW_WORKTREE_EXPECTED_OWNER_SESSION="generation-7"
_DLW_WORKTREE_EXPECTED_OWNER_BATCH="batch-7"
_DLW_WORKTREE_EXPECTED_OWNER_TASK="66666"
_DLW_WORKTREE_EXPECTED_OWNER_CREATED_AT="2026-07-18T00:00:00Z"
launch_rc=0
_dlw_nohup_launch "66666" "owner/repo" "Dispatch" "Issue" "issue-66666" \
	"${TMP}/worker.log" "/full-loop test" "$FAKE_REPO" "standard" "" \
	"$STUB_EXISTING_PATH" "$STUB_EXISTING_BRANCH" "attempt-test" "123" \
	>/dev/null || launch_rc=$?
transfer_env_ok=1
for expected_arg in \
	"AIDEVOPS_WORKTREE_OWNER_TRANSFER_MODE=continuation" \
	"AIDEVOPS_WORKTREE_EXPECTED_OWNER_PID=12345" \
	"AIDEVOPS_WORKTREE_EXPECTED_OWNER_SESSION=generation-7" \
	"AIDEVOPS_WORKTREE_EXPECTED_OWNER_BATCH=batch-7" \
	"AIDEVOPS_WORKTREE_EXPECTED_OWNER_TASK=66666" \
	"AIDEVOPS_WORKTREE_EXPECTED_OWNER_CREATED_AT=2026-07-18T00:00:00Z"; do
	grep -Fqx "$expected_arg" "${TMP}/launch-args.txt" || transfer_env_ok=0
done
if [[ "$launch_rc" -eq 0 && "$transfer_env_ok" -eq 1 ]] && \
	! grep -Fq "AIDEVOPS_ALLOW_WORKER_WORKTREE_OWNER_TRANSFER" "${TMP}/launch-args.txt"; then
	pass "worker launch carries exact continuation transfer contract"
else
	fail "worker launch carries exact continuation transfer contract" \
		"rc=$launch_rc args=$(tr '\n' ' ' <"${TMP}/launch-args.txt")"
fi

# =============================================================================
# Test 6: _dlw_check_worker_branch_orphan_loop skips fresh branches
# =============================================================================
: >"$STUB_DEDUP_CALLS_FILE"
if _dlw_check_worker_branch_orphan_loop "55555" "owner/repo" "feature/auto-gh55555" "0"; then
	fail "fresh branch orphan-loop check is skipped" "check returned hold for a non-reused branch"
else
	if [[ ! -s "$STUB_DEDUP_CALLS_FILE" ]]; then
		pass "fresh branch orphan-loop check is skipped"
	else
		fail "fresh branch orphan-loop check is skipped" "dedup helper was called"
	fi
fi

# =============================================================================
# Test 7: _dlw_check_worker_branch_orphan_loop still checks reused branches
# =============================================================================
: >"$STUB_DEDUP_CALLS_FILE"
if _dlw_check_worker_branch_orphan_loop "44444" "owner/repo" "feature/auto-gh44444" "1"; then
	if grep -q '^check-orphan-loop$' "$STUB_DEDUP_CALLS_FILE" 2>/dev/null; then
		pass "reused branch orphan-loop check calls dedup helper"
	else
		fail "reused branch orphan-loop check calls dedup helper" "helper call log missing check-orphan-loop"
	fi
else
	fail "reused branch orphan-loop check calls dedup helper" "check did not return hold from stub helper"
fi

# =============================================================================
# Test 6: _dispatch_launch_worker skips dispatch before claim when canary fails
# =============================================================================

_dlw_canary_preflight() { return 1; }

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"

launch_rc=0
_dispatch_launch_worker "77777" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-1" "" "{}" || launch_rc=$?

if [[ "$launch_rc" -eq 2 ]]; then
	pass "canary failure returns explicit no-op rc=2"
else
	fail "canary failure returns explicit no-op rc=2" "got rc=$launch_rc"
fi

if [[ ! -s "$CLAIM_LOCK_CALLS_FILE" ]]; then
	pass "canary failure does not post dispatch claim"
else
	fail "canary failure does not post dispatch claim" "claim lock calls: $(cat "$CLAIM_LOCK_CALLS_FILE")"
fi

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "canary failure does not spawn worker"
else
	fail "canary failure does not spawn worker" "setsid was called"
fi

# =============================================================================
# Test 7: _dispatch_launch_worker refreshes state before claim
# =============================================================================
_dlw_canary_preflight() { return 0; }
STUB_REFRESH_STATE="CLOSED"

: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"

launch_rc=0
_dispatch_launch_worker "77778" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-closed" "" \
	'{"state":"OPEN","body":""}' || launch_rc=$?

if [[ "$launch_rc" -eq 2 ]]; then
	pass "closed pre-claim refresh returns explicit no-op rc=2"
else
	fail "closed pre-claim refresh returns explicit no-op rc=2" "got rc=$launch_rc"
fi

if [[ ! -s "$CLAIM_LOCK_CALLS_FILE" ]]; then
	pass "closed pre-claim refresh does not post dispatch claim"
else
	fail "closed pre-claim refresh does not post dispatch claim" "claim lock calls: $(cat "$CLAIM_LOCK_CALLS_FILE")"
fi

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "closed pre-claim refresh does not spawn worker"
else
	fail "closed pre-claim refresh does not spawn worker" "setsid was called"
fi

if grep -q "refreshed issue state before claim is CLOSED" "$LOGFILE" 2>/dev/null; then
	pass "closed pre-claim refresh logs blocked state"
else
	fail "closed pre-claim refresh logs blocked state" "LOGFILE: $(cat "$LOGFILE")"
fi

STUB_REFRESH_STATE="OPEN"

# =============================================================================
# Tests 8-12: queued ownership starts only at the final runtime boundary
# =============================================================================
ORCHESTRATOR_CALLS_FILE="${TMP}/orchestrator-calls.txt"
ORCHESTRATOR_WORKTREE="${TMP}/orchestrator-worktree"
mkdir -p "$ORCHESTRATOR_WORKTREE"
STUB_HOLD_RC=1
STUB_PRECREATE_RC=0
STUB_FINAL_GATES_RC=0
STUB_ASSIGN_RC=0

_dlw_comment_bloat_metrics() { printf '0\t0\t0\t0\n'; return 0; }
_dlw_hold_repeated_zero_output() {
	printf 'hold\n' >>"$ORCHESTRATOR_CALLS_FILE"
	return "$STUB_HOLD_RC"
}
_dlw_precreate_worktree() {
	printf 'precreate\n' >>"$ORCHESTRATOR_CALLS_FILE"
	_DLW_WORKTREE_PATH=""
	_DLW_WORKTREE_BRANCH=""
	_DLW_WORKTREE_REUSED=0
	if [[ "$STUB_PRECREATE_RC" -ne 0 ]]; then
		return "$STUB_PRECREATE_RC"
	fi
	_DLW_WORKTREE_PATH="$ORCHESTRATOR_WORKTREE"
	_DLW_WORKTREE_BRANCH="feature/auto-test"
	return 0
}
_dlw_final_worker_spawn_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	printf 'final-gates\n' >>"$ORCHESTRATOR_CALLS_FILE"
	if [[ "$STUB_FINAL_GATES_RC" -ne 0 ]]; then
		_dlw_pre_runtime_failure "$issue_number" "$repo_slug" "final_dependency_recheck" "$STUB_FINAL_GATES_RC" || return $?
	fi
	return 0
}
_dlw_prepare_prompt_for_launch() {
	printf 'prompt\n' >>"$ORCHESTRATOR_CALLS_FILE"
	printf 'test prompt'
	return 0
}
_dlw_assign_and_label() {
	printf 'assign\n' >>"$ORCHESTRATOR_CALLS_FILE"
	return "$STUB_ASSIGN_RC"
}
lock_issue_for_worker() {
	printf 'lock\n' >>"$ORCHESTRATOR_CALLS_FILE"
	return 0
}
_dlw_post_launch_hooks() { return 0; }

# Assignment failure occurs after deterministic gates and prompt preparation,
# but still before the issue lock and runtime spawn.
: >"$ORCHESTRATOR_CALLS_FILE"
: >"${TMP}/setsid-calls.txt"
STUB_ASSIGN_RC=1

assignment_failure_rc=0
_dispatch_launch_worker "77779" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-assignment-failure" "" "{}" || assignment_failure_rc=$?
if [[ "$assignment_failure_rc" -eq 2 ]]; then
	pass "assignment failure returns explicit no-op rc=2"
else
	fail "assignment failure returns explicit no-op rc=2" "got rc=$assignment_failure_rc"
fi
actual_calls=$(tr '\n' ' ' <"$ORCHESTRATOR_CALLS_FILE")
if [[ "$actual_calls" == "hold precreate final-gates prompt assign " && ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "assignment failure occurs at final boundary before lock and spawn"
else
	fail "assignment failure occurs at final boundary before lock and spawn" "calls='$actual_calls'"
fi
STUB_ASSIGN_RC=0

# A repeated-zero-output hold must stop before worktree, ownership, lock, or spawn.
: >"$ORCHESTRATOR_CALLS_FILE"
: >"${TMP}/setsid-calls.txt"
STUB_HOLD_RC=0
hold_rc=0
_dispatch_launch_worker "77780" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-hold" "" "{}" || hold_rc=$?
actual_calls=$(tr '\n' ' ' <"$ORCHESTRATOR_CALLS_FILE")
if [[ "$hold_rc" -eq 2 && "$actual_calls" == "hold " && ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "repeated-zero-output hold stops before queued ownership"
else
	fail "repeated-zero-output hold stops before queued ownership" "rc=$hold_rc calls='$actual_calls'"
fi
STUB_HOLD_RC=1

# Worktree-precreation failure must retain only the cross-runner claim.
: >"$LOGFILE"
: >"${TMP}/setsid-calls.txt"
: >"$CLAIM_LOCK_CALLS_FILE"
: >"$ORCHESTRATOR_CALLS_FILE"
STUB_PRECREATE_RC=1
# Reset stats file
printf '{"counters":{}}\n' >"$PULSE_STATS_FILE"

launch_rc=0
_dispatch_launch_worker "77777" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-1" "" "{}" || launch_rc=$?

if [[ ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "dispatch skipped (no setsid) when pre-creation fails"
else
	fail "dispatch skipped (no setsid) when pre-creation fails" "setsid was called"
fi

if [[ "$launch_rc" -eq 2 ]]; then
	pass "dispatch skip returns explicit no-op rc=2"
else
	fail "dispatch skip returns explicit no-op rc=2" "got rc=$launch_rc"
fi

actual_calls=$(tr '\n' ' ' <"$ORCHESTRATOR_CALLS_FILE")
if [[ "$actual_calls" == "hold precreate " ]]; then
	pass "pre-creation failure stops before final gates and queued ownership"
else
	fail "pre-creation failure stops before final gates and queued ownership" "calls='$actual_calls'"
fi

if [[ "${_DLW_LAST_PRE_RUNTIME_FAILURE:-}" == "worktree_precreation_failed" ]] && \
	grep -q "PRE_RUNTIME_FAILURE issue=77777 repo=owner/repo reason=worktree_precreation_failed" "$LOGFILE" 2>/dev/null; then
	pass "pre-runtime failure records issue-correlated worktree reason"
else
	fail "pre-runtime failure records issue-correlated worktree reason" "reason=${_DLW_LAST_PRE_RUNTIME_FAILURE:-unset}; log=$(cat "$LOGFILE")"
fi

if grep -q '^77777$' "$CLAIM_LOCK_CALLS_FILE" 2>/dev/null; then
	pass "pre-creation failure happens after claim lock"
else
	fail "pre-creation failure happens after claim lock" "claim lock not called"
fi
STUB_PRECREATE_RC=0

# Final dependency/orphan gate failures likewise stop before queued ownership.
: >"$ORCHESTRATOR_CALLS_FILE"
: >"${TMP}/setsid-calls.txt"
STUB_FINAL_GATES_RC=2
final_gate_rc=0
_dispatch_launch_worker "77781" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-final-gate" "" "{}" || final_gate_rc=$?
actual_calls=$(tr '\n' ' ' <"$ORCHESTRATOR_CALLS_FILE")
if [[ "$final_gate_rc" -eq 2 && "$actual_calls" == "hold precreate final-gates " && ! -s "${TMP}/setsid-calls.txt" ]]; then
	pass "final spawn gate failure stops before queued ownership"
else
	fail "final spawn gate failure stops before queued ownership" "rc=$final_gate_rc calls='$actual_calls'"
fi
STUB_FINAL_GATES_RC=0

# The successful path publishes ownership and locks only immediately before spawn.
: >"$ORCHESTRATOR_CALLS_FILE"
: >"${TMP}/setsid-calls.txt"
success_rc=0
_dispatch_launch_worker "77782" "owner/repo" "test-dispatch" "Test Issue" \
	"testuser" "$FAKE_REPO" "test prompt" "session-key-success" "" "{}" || success_rc=$?
actual_calls=$(tr '\n' ' ' <"$ORCHESTRATOR_CALLS_FILE")
if [[ "$success_rc" -eq 0 && "$actual_calls" == "hold precreate final-gates prompt assign lock spawn " && -s "${TMP}/setsid-calls.txt" ]]; then
	pass "successful launch acquires queued ownership at final boundary"
else
	fail "successful launch acquires queued ownership at final boundary" "rc=$success_rc calls='$actual_calls'"
fi

# =============================================================================
# Worktree-precreation failure observability remains intact
# =============================================================================
local_count=""
if command -v jq &>/dev/null; then
	local_count=$(jq -r '.counters.worktree_precreation_failed_count | length' "$PULSE_STATS_FILE" 2>/dev/null) || local_count="0"
fi
if [[ "$local_count" == "1" ]]; then
	pass "worktree_precreation_failed_count incremented to 1"
else
	fail "worktree_precreation_failed_count incremented to 1" "got count=$local_count (jq available: $(command -v jq &>/dev/null && echo yes || echo no))"
fi

# Verify skip message in log
if grep -q "Skipping #77777.*pre-creation failed" "$LOGFILE" 2>/dev/null; then
	pass "skip-dispatch log message present"
else
	fail "skip-dispatch log message present" "LOGFILE: $(cat "$LOGFILE")"
fi

# =============================================================================
# Test 10: --dir argument no longer contains repo_path fallback
# =============================================================================
# Grep the source file for the old pattern (single quotes intentional — literal search)
# shellcheck disable=SC2016
if grep -q ':-\$repo_path' "${SCRIPTS_DIR}/pulse-dispatch-worker-launch.sh" 2>/dev/null; then
	fail "--dir fallback removed" "still found ':-\$repo_path' in source"
else
	pass "--dir fallback removed"
fi

# =============================================================================
# Test 11: a worktree deleted after precreation is rejected at launch boundary
# =============================================================================
: >"${TMP}/setsid-calls.txt"
missing_worktree="${TMP}/deleted-after-precreation"
_dlw_nohup_launch "88888" "owner/repo" "Dispatch" "Issue" "issue-88888" \
	"${TMP}/worker.log" "/full-loop test" "$FAKE_REPO" "standard" "" \
	"$missing_worktree" "feature/auto-88888"
launch_rc=$?
if [[ "$launch_rc" -eq 1 && ! -s "${TMP}/setsid-calls.txt" ]] && \
	grep -q "worktree unavailable for #88888" "$LOGFILE"; then
	pass "launch boundary rejects a missing worker worktree before setsid"
else
	fail "launch boundary rejects a missing worker worktree before setsid" "rc=$launch_rc"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s\n' "--- Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ---"
if [[ $TESTS_FAILED -gt 0 ]]; then
	exit 1
fi
exit 0
