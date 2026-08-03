#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-https-ssh-fallback.sh — Regression test for GH#21904
#
# Verifies the HTTPS-timeout + SSH-fallback path added in GH#21904 to
# `claim-task-id-counter.sh`:
#
#   1. _derive_ssh_url_from_https converts GitHub HTTPS URLs to SSH form
#      and rejects (rc=1, empty stdout) non-GitHub or already-SSH inputs.
#   2. _run_git_with_ssh_fallback wraps a git command with timeout_sec and
#      returns 124 transparently when the command times out.
#   3. CAS_HTTPS_TIMEOUT_S / CAS_HOOK_TIMEOUT_S / CAS_SSH_FALLBACK_ENABLED
#      constants exist and are referenced in the counter sub-library.
#   4. The CAS push and fetch call sites in claim-task-id-counter.sh route
#      through _run_git_with_ssh_fallback (no more raw `git push`/`git fetch`
#      against $REMOTE_NAME).
#   5. CAS_SSH_FALLBACK_ENABLED=0 short-circuits the fallback (returns 124
#      without attempting an SSH retry).
#
# Memory: mem_20260430054453_5f0d112e — HTTPS push hung; SSH workaround
# verified to complete in <10s on the same network.
#
# Requires: bash 4+, git, timeout_sec from shared-constants.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
COUNTER_LIB="${SCRIPT_DIR}/../claim-task-id-counter.sh"
CLAIM_SCRIPT="${SCRIPT_DIR}/../claim-task-id.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}
  - ${name}: ${detail}"
	return 0
}

# ---------------------------------------------------------------------------
# Source the counter sub-library in a fresh subshell so we can call the
# helpers directly. shared-constants.sh is required by the sub-library, so
# source it first.
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/../shared-constants.sh"
# Set REMOTE_NAME and COUNTER_BRANCH expected by the sub-library
REMOTE_NAME="${REMOTE_NAME:-origin}"
COUNTER_BRANCH="${COUNTER_BRANCH:-main}"
COUNTER_FILE="${COUNTER_FILE:-.task-counter}"
# shellcheck disable=SC1090
source "$COUNTER_LIB"

# ---------------------------------------------------------------------------
# Test 1: source check — new constants exist
# ---------------------------------------------------------------------------
test_constants_exist() {
	local name="source check: CAS transport, hook, and SSH fallback settings defined"
	if ! grep -q 'CAS_HTTPS_TIMEOUT_S=' "$CLAIM_SCRIPT"; then
		fail "$name" "CAS_HTTPS_TIMEOUT_S not found in claim-task-id.sh"
		return 0
	fi
	if ! grep -q 'CAS_HOOK_TIMEOUT_S=' "$CLAIM_SCRIPT"; then
		fail "$name" "CAS_HOOK_TIMEOUT_S not found in claim-task-id.sh"
		return 0
	fi
	if ! grep -q 'CAS_SSH_FALLBACK_ENABLED=' "$CLAIM_SCRIPT"; then
		fail "$name" "CAS_SSH_FALLBACK_ENABLED not found in claim-task-id.sh"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: source check — _run_git_with_ssh_fallback exists in counter lib
# ---------------------------------------------------------------------------
test_helper_function_exists() {
	local name="source check: _run_git_with_ssh_fallback + _derive_ssh_url_from_https defined"
	if ! grep -q '_run_git_with_ssh_fallback()' "$COUNTER_LIB"; then
		fail "$name" "_run_git_with_ssh_fallback() not defined in counter sub-library"
		return 0
	fi
	if ! grep -q '_derive_ssh_url_from_https()' "$COUNTER_LIB"; then
		fail "$name" "_derive_ssh_url_from_https() not defined in counter sub-library"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: URL conversion — happy path (https github → ssh github)
# ---------------------------------------------------------------------------
test_ssh_url_conversion_happy() {
	local name="URL conversion: https://github.com/owner/repo.git → git@github.com:owner/repo.git"
	local got
	got=$(_derive_ssh_url_from_https "https://github.com/owner/repo.git" 2>/dev/null) || got=""
	local want="git@github.com:owner/repo.git"
	if [[ "$got" != "$want" ]]; then
		fail "$name" "got '${got}', want '${want}'"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: URL conversion — without .git suffix
# ---------------------------------------------------------------------------
test_ssh_url_conversion_no_git_suffix() {
	local name="URL conversion: https://github.com/owner/repo (no .git) → git@github.com:owner/repo"
	local got
	got=$(_derive_ssh_url_from_https "https://github.com/owner/repo" 2>/dev/null) || got=""
	local want="git@github.com:owner/repo"
	if [[ "$got" != "$want" ]]; then
		fail "$name" "got '${got}', want '${want}'"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: URL conversion — already SSH returns rc=1, empty stdout
# ---------------------------------------------------------------------------
test_ssh_url_conversion_already_ssh() {
	local name="URL conversion: git@github.com:owner/repo.git (already SSH) → empty + rc=1"
	local got rc=0
	got=$(_derive_ssh_url_from_https "git@github.com:owner/repo.git") || rc=$?
	if [[ -n "$got" ]]; then
		fail "$name" "expected empty stdout, got '${got}'"
		return 0
	fi
	if [[ $rc -ne 1 ]]; then
		fail "$name" "expected rc=1 for already-SSH input, got rc=${rc}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: URL conversion — non-GitHub HTTPS returns rc=1, empty stdout
# ---------------------------------------------------------------------------
test_ssh_url_conversion_non_github() {
	local name="URL conversion: https://gitlab.com/owner/repo.git (non-GitHub) → empty + rc=1"
	local got rc=0
	got=$(_derive_ssh_url_from_https "https://gitlab.com/owner/repo.git") || rc=$?
	if [[ -n "$got" ]]; then
		fail "$name" "expected empty stdout for non-GitHub, got '${got}'"
		return 0
	fi
	if [[ $rc -ne 1 ]]; then
		fail "$name" "expected rc=1 for non-GitHub input, got rc=${rc}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: URL conversion — empty input returns rc=1, empty stdout
# ---------------------------------------------------------------------------
test_ssh_url_conversion_empty() {
	local name="URL conversion: empty input → empty + rc=1"
	local got rc=0
	got=$(_derive_ssh_url_from_https "") || rc=$?
	if [[ -n "$got" ]] || [[ $rc -ne 1 ]]; then
		fail "$name" "expected empty + rc=1, got '${got}' rc=${rc}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 8: timeout passthrough — fast command returns its own rc, not 124
# ---------------------------------------------------------------------------
test_run_git_passthrough_no_timeout() {
	local name='_run_git_with_ssh_fallback: fast "git version" returns 0, not 124'
	local rc=0
	# 5s timeout; version returns immediately. Suppress stdout to keep the
	# test output clean.
	_run_git_with_ssh_fallback 5 version >/dev/null 2>&1 || rc=$?
	if [[ $rc -ne 0 ]]; then
		fail "$name" "expected rc=0, got rc=${rc}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 9: fallback disabled — CAS_SSH_FALLBACK_ENABLED=0 prevents retry
# Mocks `git` so the first call sleeps past the timeout. The fallback
# branch must NOT run a second git invocation; we assert that by counting
# attempts via a sentinel file.
# ---------------------------------------------------------------------------
test_fallback_disabled_short_circuits() {
	local name="_run_git_with_ssh_fallback: CAS_SSH_FALLBACK_ENABLED=0 short-circuits at 124"
	local tmpdir
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN

	# Build a `git` shim that sleeps 5s on every call and increments a counter.
	cat >"${tmpdir}/git" <<'SHIM_EOF'
#!/usr/bin/env bash
echo "called" >>"${TEST_GIT_CALL_LOG}"
sleep 5
SHIM_EOF
	chmod +x "${tmpdir}/git"

	# Run with fallback disabled, 1s timeout. Expected: rc=124, exactly 1 call.
	local rc=0
	(
		export TEST_GIT_CALL_LOG="${tmpdir}/calls.log"
		: >"$TEST_GIT_CALL_LOG"
		export PATH="${tmpdir}:$PATH"
		export CAS_SSH_FALLBACK_ENABLED=0
		_run_git_with_ssh_fallback 1 fetch origin main >/dev/null 2>&1
	) || rc=$?

	if [[ $rc -ne 124 ]]; then
		fail "$name" "expected rc=124 from timeout, got rc=${rc}"
		return 0
	fi
	local call_count
	call_count=$(wc -l <"${tmpdir}/calls.log" 2>/dev/null | tr -d '[:space:]')
	# Expected: exactly 1 call (no SSH retry attempted)
	if [[ "$call_count" != "1" ]]; then
		fail "$name" "expected 1 git call (no SSH retry), got ${call_count}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 10: non-timeout HTTPS failure — fallback retries via SSH and succeeds
# Mocks `git` so the first remote operation fails quickly (like
# GIT_ASKPASS=/bin/false), `git remote get-url origin` returns a GitHub HTTPS
# URL, and the retry with `-c url.<ssh>.insteadOf=<https>` succeeds.
# ---------------------------------------------------------------------------
test_non_timeout_failure_falls_back_to_ssh() {
	local name="_run_git_with_ssh_fallback: non-timeout HTTPS failure retries via SSH"
	local tmpdir
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN

	cat >"${tmpdir}/git" <<'SHIM_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_GIT_CALL_LOG}"
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
	printf '%s\n' "https://github.com/owner/repo.git"
	exit 0
fi
if [[ "${1:-}" == "-c" ]]; then
	exit 0
fi
exit 1
SHIM_EOF
	chmod +x "${tmpdir}/git"

	local rc=0
	(
		export TEST_GIT_CALL_LOG="${tmpdir}/calls.log"
		: >"$TEST_GIT_CALL_LOG"
		export PATH="${tmpdir}:$PATH"
		export CAS_SSH_FALLBACK_ENABLED=1
		REMOTE_NAME="origin"
		_run_git_with_ssh_fallback 5 fetch origin main >/dev/null 2>&1
	) || rc=$?

	if [[ $rc -ne 0 ]]; then
		fail "$name" "expected SSH fallback rc=0, got rc=${rc}"
		return 0
	fi
	if ! grep -q 'remote get-url origin' "${tmpdir}/calls.log"; then
		fail "$name" "expected helper to inspect remote URL before fallback"
		return 0
	fi
	if ! grep -q 'url.git@github.com:owner/repo.git.insteadOf=https://github.com/owner/repo.git' "${tmpdir}/calls.log"; then
		fail "$name" "expected fallback git call to rewrite HTTPS remote to SSH via insteadOf"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 11: HTTPS timeout — fallback retries via SSH and succeeds
# Mocks `git` so the first remote operation hangs past the timeout, remote URL
# lookup returns a GitHub HTTPS URL, and the SSH-rewritten retry succeeds.
# ---------------------------------------------------------------------------
test_timeout_falls_back_to_ssh() {
	local name="_run_git_with_ssh_fallback: HTTPS timeout retries via SSH"
	local tmpdir
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN

	cat >"${tmpdir}/git" <<'SHIM_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TEST_GIT_CALL_LOG}"
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
	printf '%s\n' "https://github.com/owner/repo.git"
	exit 0
fi
if [[ "${1:-}" == "-c" ]]; then
	exit 0
fi
sleep 5
SHIM_EOF
	chmod +x "${tmpdir}/git"

	local rc=0
	(
		export TEST_GIT_CALL_LOG="${tmpdir}/calls.log"
		: >"$TEST_GIT_CALL_LOG"
		export PATH="${tmpdir}:$PATH"
		export CAS_SSH_FALLBACK_ENABLED=1
		REMOTE_NAME="origin"
		_run_git_with_ssh_fallback 1 fetch origin main >/dev/null 2>&1
	) || rc=$?

	if [[ $rc -ne 0 ]]; then
		fail "$name" "expected SSH fallback rc=0 after timeout, got rc=${rc}"
		return 0
	fi
	if ! grep -q 'url.git@github.com:owner/repo.git.insteadOf=https://github.com/owner/repo.git' "${tmpdir}/calls.log"; then
		fail "$name" "expected timeout path to rewrite HTTPS remote to SSH via insteadOf"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 12: pre-push validation has an independent timeout and receives Git's
# hook protocol. A hook that outlives the transport budget must still pass when
# it completes inside CAS_HOOK_TIMEOUT_S.
# ---------------------------------------------------------------------------
test_pre_push_hook_uses_independent_budget() {
	local name="CAS push: pre-push hook uses an independent validation budget"
	local tmpdir=""
	local output=""
	local rc=0
	local input=""
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN

	cat >"${tmpdir}/git" <<'SHIM_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
	printf '%s\n' 'https://github.com/owner/repo.git'
	exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--git-path" ]]; then
	printf '%s\n' "$TEST_HOOK_PATH"
	exit 0
fi
exit 1
SHIM_EOF
	cat >"${tmpdir}/pre-push" <<'HOOK_EOF'
#!/usr/bin/env bash
IFS= read -r line
printf '%s\n' "$line" >"$TEST_HOOK_INPUT"
sleep 1
exit 0
HOOK_EOF
	chmod +x "${tmpdir}/git" "${tmpdir}/pre-push"

	output=$(
		export PATH="${tmpdir}:$PATH"
		export TEST_HOOK_PATH="${tmpdir}/pre-push"
		export TEST_HOOK_INPUT="${tmpdir}/hook-input"
		CAS_HTTPS_TIMEOUT_S=0.1 CAS_HOOK_TIMEOUT_S=3 \
			_cas_run_pre_push_hook "local-sha" "remote-sha" 2>&1
	) || rc=$?
	input=$(<"${tmpdir}/hook-input")

	if [[ $rc -ne 0 ]]; then
		fail "$name" "expected hook success, got rc=${rc}: ${output}"
		return 0
	fi
	if [[ "$input" != "local-sha local-sha refs/heads/${COUNTER_BRANCH} remote-sha" ]]; then
		fail "$name" "unexpected hook protocol input: ${input}"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'Pre-push hook completed in'; then
		fail "$name" "missing hook phase timing: ${output}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 13: hook timeouts and failures are blocking and explicitly diagnosed.
# ---------------------------------------------------------------------------
test_pre_push_hook_failures_are_blocking() {
	local name="CAS push: hook timeout and failure are blocking with phase diagnostics"
	local tmpdir=""
	local output=""
	local rc=0
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN

	cat >"${tmpdir}/git" <<'SHIM_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
	printf '%s\n' 'https://github.com/owner/repo.git'
	exit 0
fi
if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--git-path" ]]; then
	printf '%s\n' "$TEST_HOOK_PATH"
	exit 0
fi
exit 1
SHIM_EOF
	cat >"${tmpdir}/pre-push" <<'HOOK_EOF'
#!/usr/bin/env bash
sleep 5
HOOK_EOF
	chmod +x "${tmpdir}/git" "${tmpdir}/pre-push"

	output=$(
		export PATH="${tmpdir}:$PATH"
		export TEST_HOOK_PATH="${tmpdir}/pre-push"
		CAS_HOOK_TIMEOUT_S=1 _cas_run_pre_push_hook "local-sha" "remote-sha" 2>&1
	) || rc=$?
	if [[ $rc -ne 1 ]] || ! printf '%s\n' "$output" | grep -q 'Pre-push hook timed out.*remote push was not attempted'; then
		fail "$name" "timeout was not blocking/diagnosed: rc=${rc}: ${output}"
		return 0
	fi

	cat >"${tmpdir}/pre-push" <<'HOOK_EOF'
#!/usr/bin/env bash
exit 7
HOOK_EOF
	chmod +x "${tmpdir}/pre-push"
	rc=0
	output=$(
		export PATH="${tmpdir}:$PATH"
		export TEST_HOOK_PATH="${tmpdir}/pre-push"
		CAS_HOOK_TIMEOUT_S=3 _cas_run_pre_push_hook "local-sha" "remote-sha" 2>&1
	) || rc=$?
	if [[ $rc -ne 1 ]] || ! printf '%s\n' "$output" | grep -q 'Pre-push hook failed.*rc=7.*remote push was not attempted'; then
		fail "$name" "hook failure was not blocking/diagnosed: rc=${rc}: ${output}"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 14: an actual CAS push succeeds when its pre-push hook outlives the
# transport timeout, because validation and remote I/O have separate budgets.
# ---------------------------------------------------------------------------
test_slow_hook_does_not_consume_transport_budget() {
	local name="CAS push: slow valid hook does not consume transport timeout"
	local tmpdir=""
	local bare_dir=""
	local work_dir=""
	local hook_path=""
	local pinned_sha=""
	local output=""
	local rc=0
	local remote_counter=""
	local hook_calls=""
	tmpdir=$(mktemp -d 2>/dev/null) || {
		fail "$name" "could not create tmpdir"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir' 2>/dev/null || true" RETURN
	bare_dir="${tmpdir}/remote.git"
	work_dir="${tmpdir}/work"

	git init --bare --initial-branch=main "$bare_dir" >/dev/null 2>&1 || {
		fail "$name" "could not initialize bare remote"
		return 0
	}
	git clone "$bare_dir" "$work_dir" >/dev/null 2>&1 || {
		fail "$name" "could not clone fixture"
		return 0
	}
	git -C "$work_dir" config user.email "test@test.local"
	git -C "$work_dir" config user.name "Test"
	git -C "$work_dir" config commit.gpgsign false
	printf '1000\n' >"${work_dir}/.task-counter"
	printf '# Tasks\n' >"${work_dir}/TODO.md"
	git -C "$work_dir" add .task-counter TODO.md
	git -C "$work_dir" commit -m "chore: seed CAS fixture" >/dev/null 2>&1 || {
		fail "$name" "could not commit fixture"
		return 0
	}
	git -C "$work_dir" push origin main >/dev/null 2>&1 || {
		fail "$name" "could not seed remote"
		return 0
	}
	pinned_sha=$(git -C "$work_dir" rev-parse HEAD) || {
		fail "$name" "could not resolve fixture HEAD"
		return 0
	}
	hook_path=$(git -C "$work_dir" rev-parse --git-path hooks/pre-push) || {
		fail "$name" "could not resolve fixture hook path"
		return 0
	}
	[[ "$hook_path" == /* ]] || hook_path="${work_dir}/${hook_path}"
	cat >"$hook_path" <<'HOOK_EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$TEST_HOOK_CALL_LOG"
sleep 2
exit 0
HOOK_EOF
	chmod +x "$hook_path"

	output=$(
		cd "$work_dir" || exit 1
		export TEST_HOOK_CALL_LOG="${tmpdir}/hook-calls"
		REMOTE_NAME=origin
		COUNTER_BRANCH=main
		COUNTER_FILE=.task-counter
		CAS_GIT_CMD_TIMEOUT_S=1
		CAS_HTTPS_TIMEOUT_S=1
		CAS_HOOK_TIMEOUT_S=5
		CAS_SSH_FALLBACK_ENABLED=0
		_cas_build_and_push "$pinned_sha" 1001 "chore: claim integration test" 2>&1
	) || rc=$?
	remote_counter=$(git --git-dir="$bare_dir" show main:.task-counter 2>/dev/null | tr -d '[:space:]')
	if [[ -f "${tmpdir}/hook-calls" ]]; then
		hook_calls=$(wc -l <"${tmpdir}/hook-calls" 2>/dev/null | tr -d '[:space:]')
	else
		hook_calls="0"
	fi

	if [[ $rc -ne 0 ]]; then
		fail "$name" "expected CAS push success, got rc=${rc}: ${output}"
		return 0
	fi
	if [[ "$remote_counter" != "1001" ]]; then
		fail "$name" "expected remote counter 1001, got ${remote_counter:-<empty>}"
		return 0
	fi
	if [[ "$hook_calls" != "1" ]]; then
		fail "$name" "expected hook to run once, got ${hook_calls:-0}"
		return 0
	fi
	if ! printf '%s\n' "$output" | grep -q 'Pre-push hook completed in'; then
		fail "$name" "missing hook timing diagnostic: ${output}"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 15: only genuine non-fast-forward failures are retriable, while auth is
# separately classified. The actual push must skip the already-run hook.
# ---------------------------------------------------------------------------
test_push_failure_classifiers() {
	local name="CAS push: conflict and authentication diagnostics are distinct"
	if ! _cas_push_rejection_is_non_fast_forward ' ! [rejected] abc -> main (non-fast-forward)'; then
		fail "$name" "non-fast-forward rejection was not classified as contention"
		return 0
	fi
	if _cas_push_rejection_is_non_fast_forward 'fatal: Authentication failed for repository'; then
		fail "$name" "authentication failure was classified as contention"
		return 0
	fi
	if ! _cas_push_rejection_is_auth_failure 'fatal: Authentication failed for repository'; then
		fail "$name" "authentication failure was not classified"
		return 0
	fi
	if ! grep -q 'push --no-verify -q' "$COUNTER_LIB"; then
		fail "$name" "transport push does not skip duplicate pre-push hook execution"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 16: source check — CAS push/fetch call sites use the helper
# Verifies _cas_fetch_and_pin, _cas_build_and_push, read_remote_counter and
# bootstrap_remote_counter all route via _run_git_with_ssh_fallback. A future
# regression that inserts a raw `git push` or `git fetch` against $REMOTE_NAME
# will fail this check.
# ---------------------------------------------------------------------------
test_call_sites_use_helper() {
	local name="source check: CAS push/fetch routes through _run_git_with_ssh_fallback"

	# Each call site must reference the helper at least once.
	# Count how many times _run_git_with_ssh_fallback is referenced — should be
	# at least 6: 2 in _cas_fetch_and_pin (initial fetch + bootstrap retry),
	# 3 in _cas_build_and_push (push + post-conflict fetch + post-success fetch),
	# 1 in read_remote_counter, 2 in bootstrap_remote_counter (push + post-fetch).
	local helper_uses
	helper_uses=$(grep -c '_run_git_with_ssh_fallback' "$COUNTER_LIB" 2>/dev/null | tr -d '[:space:]')
	if [[ -z "$helper_uses" ]] || ! [[ "$helper_uses" =~ ^[0-9]+$ ]]; then
		helper_uses=0
	fi
	# Threshold: 7 (1 definition + 6 use sites). The test is intentionally
	# lower than the actual count so non-essential refactors don't break it.
	if [[ $helper_uses -lt 7 ]]; then
		fail "$name" "expected >=7 references to _run_git_with_ssh_fallback (1 definition + >=6 call sites), got ${helper_uses}"
		return 0
	fi

	# No raw `git push "$REMOTE_NAME"` or `git fetch "$REMOTE_NAME"` should
	# remain — they would bypass the timeout.
	# shellcheck disable=SC2016  # grep regex literal — $REMOTE_NAME must NOT expand
	if grep -qE 'git[[:space:]].*push[[:space:]]+"\$REMOTE_NAME"' "$COUNTER_LIB"; then
		fail "$name" "raw 'git push \$REMOTE_NAME' still present in counter sub-library"
		return 0
	fi
	# shellcheck disable=SC2016  # grep regex literal — $REMOTE_NAME must NOT expand
	if grep -qE '^[^#]*git[[:space:]].*fetch[[:space:]]+(-q[[:space:]])?"\$REMOTE_NAME"' "$COUNTER_LIB"; then
		fail "$name" "raw 'git fetch \$REMOTE_NAME' still present in counter sub-library"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
	test_constants_exist
	test_helper_function_exists
	test_ssh_url_conversion_happy
	test_ssh_url_conversion_no_git_suffix
	test_ssh_url_conversion_already_ssh
	test_ssh_url_conversion_non_github
	test_ssh_url_conversion_empty
	test_run_git_passthrough_no_timeout
	test_fallback_disabled_short_circuits
	test_non_timeout_failure_falls_back_to_ssh
	test_timeout_falls_back_to_ssh
	test_pre_push_hook_uses_independent_budget
	test_pre_push_hook_failures_are_blocking
	test_slow_hook_does_not_consume_transport_budget
	test_push_failure_classifiers
	test_call_sites_use_helper

	printf '\n'
	printf '%s\n' "================================================================"
	printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
	printf '%s\n' "================================================================"
	if [[ $FAIL -gt 0 ]]; then
		printf '%bErrors:%s%b\n' "$RED" "$ERRORS" "$NC"
		return 1
	fi
	return 0
}

main "$@"
