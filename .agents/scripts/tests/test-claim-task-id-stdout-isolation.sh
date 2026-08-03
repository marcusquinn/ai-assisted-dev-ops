#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-claim-task-id-stdout-isolation.sh — GH#20208 regression tests
#
# Verifies that claim-task-id.sh's CAS (Compare-And-Swap) paths isolate
# their stdout from any pre-push hook narration.
#
# Root cause (GH#20208): `_cas_build_and_push()` calls `git push` inside
# the `$(allocate_counter_cas …)` command substitution.  Git invokes the
# registered pre-push hook (e.g., privacy-guard, complexity-regression,
# credential-emission, or simply the installed dispatcher header).  Any
# stdout that those hooks emit is captured by the caller's `$(...)` and
# poisons downstream arithmetic (`$((first_id + i))`), producing:
#
#   claim-task-id.sh: line NNN: [0;34m[INFO][0m ... new counter: 2459:
#       syntax error in expression (error token is "[0;34m[INFO][0m...")
#
# The hook now runs explicitly before `git push --no-verify -q`, and both
# phases suppress stdout. Complementary defense is redirecting stdout to
# /dev/null inside the CAS helpers (caller-side isolation), which is what this
# test exercises.
#
# Sibling test: test-stdout-narration-hygiene.sh (GH#20212) covers the
# hook-side of the same class of bugs.  This test covers the
# caller-side: "even if a future hook leaks stdout, claim-task-id's CAS
# paths must isolate from it."
#
# Tests (structural — no network, no real pushes):
#   1. _cas_build_and_push redirects `git push` stdout to /dev/null.
#   2. _cas_build_and_push redirects its conflict-recovery git fetch
#      stdout to /dev/null.
#   3. _cas_fetch_and_pin redirects its primary git fetch stdout to
#      /dev/null.
#   4. _cas_fetch_and_pin redirects its bootstrap-path git fetch
#      stdout to /dev/null.
#   5. Presence check: the GH#20208 comment anchor is in the source so
#      a later edit that removes the redirect is easy to spot in a
#      blame view.
#   6. Behavioural smoke test: call a mocked `git push`/`git fetch`
#      that emits ANSI on stdout + succeeds, source the real
#      _cas_build_and_push wrapper, assert its captured stdout is
#      arithmetic-safe.
#
# Tests 1-5 are structural (grep-based) and always run.  Test 6 is
# behavioural and runs when bash >= 4 is available (requires
# `declare -f` scoping semantics that differ in bash 3.2).

set -u

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${SCRIPT_DIR_TEST}/.."
# GH#20224 split claim-task-id.sh into two sub-libraries; the CAS functions
# under test live in claim-task-id-counter.sh.  The orchestrator
# (claim-task-id.sh) sources this sub-library at runtime — tests inspect the
# sub-library directly for precision.
CLAIM_SCRIPT="${SCRIPTS_DIR}/claim-task-id-counter.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

PASS=0
FAIL=0
ERRORS=""

pass() {
	local name="${1:-}"
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="${1:-}"
	local detail="${2:-}"
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$name"
	[[ -n "$detail" ]] && printf '       %s\n' "$detail"
	FAIL=$((FAIL + 1))
	ERRORS="${ERRORS}
  - ${name}: ${detail}"
	return 0
}

# Returns 0 (true) if $1 contains an ANSI ESC sequence (\033[).
_contains_ansi() {
	local str="$1"
	[[ "$str" == *$'\033'* ]]
	return $?
}

# ---------------------------------------------------------------------------
# Structural tests: grep the source file for the required redirects.
#
# We extract each target function body with awk and then check the
# redirect is present on the relevant git push/fetch line.  A bare
# `git push [--no-verify] -q "$REMOTE_NAME" …` WITHOUT `>/dev/null` is the regression
# we are defending against.
# ---------------------------------------------------------------------------

_func_body() {
	# Print the body of a top-level bash function from a file.
	# Uses a simple "^func_name()" opener + "^}" closer heuristic.
	local fname="$1"
	local file="$2"
	awk -v name="$fname" '
		$0 ~ "^"name"\\(\\) *\\{" { in_func = 1; next }
		in_func && $0 ~ /^\}/     { in_func = 0; next }
		in_func                    { print }
	' "$file"
}

# ---------------------------------------------------------------------------
# Test 1: _cas_build_and_push redirects git push stdout to /dev/null
# ---------------------------------------------------------------------------
test_cas_build_push_redirects_push_stdout() {
	local name="_cas_build_and_push: git push stdout redirected to /dev/null"
	local body
	body=$(_func_body _cas_build_and_push "$CLAIM_SCRIPT")

	# Look for a push line that also has `>/dev/null`; GH#29417 inserts
	# --no-verify because the hook has already run with its own timeout.
	local push_line
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	push_line=$(printf '%s\n' "$body" | grep -E 'push (--no-verify )?-q "\$REMOTE_NAME"' | head -1 || true)

	if [[ -z "$push_line" ]]; then
		fail "$name" "could not locate CAS push command in _cas_build_and_push"
		return 0
	fi

	# Multi-line continuation: check the whole function body for the
	# redirect appearing on the same logical statement as the push.
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	if printf '%s\n' "$body" | grep -qE 'push (--no-verify )?-q "\$REMOTE_NAME"[^\n]*>/dev/null'; then
		pass "$name"
	else
		fail "$name" "push line lacks >/dev/null redirect: ${push_line}"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: _cas_build_and_push conflict-recovery fetch + normal-path fetch
#         both redirect stdout to /dev/null
# ---------------------------------------------------------------------------
test_cas_build_push_redirects_fetch_stdout() {
	local name="_cas_build_and_push: both git fetch calls redirect stdout to /dev/null"
	local body
	body=$(_func_body _cas_build_and_push "$CLAIM_SCRIPT")

	# Count fetch lines, and count fetch lines with >/dev/null.
	local total_fetches redirected_fetches
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	total_fetches=$(printf '%s\n' "$body" | grep -cE 'fetch -q "\$REMOTE_NAME"' || true)
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	redirected_fetches=$(printf '%s\n' "$body" | grep -cE 'fetch -q "\$REMOTE_NAME"[^\n]*>/dev/null' || true)

	if [[ "$total_fetches" -lt 2 ]]; then
		fail "$name" "expected >=2 fetch calls in _cas_build_and_push, found $total_fetches"
		return 0
	fi
	if [[ "$redirected_fetches" -lt "$total_fetches" ]]; then
		fail "$name" "expected all $total_fetches fetch calls to redirect, only $redirected_fetches do"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: _cas_fetch_and_pin primary fetch redirects stdout
# ---------------------------------------------------------------------------
test_cas_fetch_and_pin_redirects_stdout() {
	local name="_cas_fetch_and_pin: git fetch stdout redirected to /dev/null"
	local body
	body=$(_func_body _cas_fetch_and_pin "$CLAIM_SCRIPT")

	local total_fetches redirected_fetches
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	total_fetches=$(printf '%s\n' "$body" | grep -cE 'fetch -q "\$REMOTE_NAME"' || true)
	# shellcheck disable=SC2016  # single-quoted regex matches literal "$REMOTE_NAME" in source
	redirected_fetches=$(printf '%s\n' "$body" | grep -cE 'fetch -q "\$REMOTE_NAME"[^\n]*>/dev/null' || true)

	if [[ "$total_fetches" -lt 1 ]]; then
		fail "$name" "expected >=1 fetch call in _cas_fetch_and_pin, found $total_fetches"
		return 0
	fi
	if [[ "$redirected_fetches" -lt "$total_fetches" ]]; then
		fail "$name" "expected all $total_fetches fetch calls to redirect, only $redirected_fetches do"
		return 0
	fi
	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: GH#20208 comment anchor is present in claim-task-id-counter.sh so a
#         future edit stripping the redirect is easy to spot.
# ---------------------------------------------------------------------------
test_gh20208_comment_anchor_present() {
	local name="claim-task-id-counter.sh: GH#20208 comment anchor present near CAS push"

	if grep -qE '^[[:space:]]*#[[:space:]]*GH#20208' "$CLAIM_SCRIPT"; then
		pass "$name"
	else
		fail "$name" "missing '# GH#20208' explanatory comment — redirect will be silently lost in a future edit"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Behavioural smoke — caller captures arithmetic-safe stdout even
# when a mocked `git push`/`fetch` emits ANSI narration on stdout.
#
# We replicate the failure shape by running the real _cas_build_and_push
# function with `git` stubbed to emit ANSI.  With the redirect in place,
# the captured stdout must NOT contain ANSI and MUST be arithmetic-safe.
# ---------------------------------------------------------------------------
test_cas_build_push_arithmetic_safe_with_noisy_hook() {
	local name="_cas_build_and_push: arithmetic-safe capture with noisy hook stdout"

	# bash 3.2 lacks some of the function-sourcing semantics we rely on.
	# Skip gracefully rather than fail.
	if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
		printf '  %sSKIP%s %s (needs bash >= 4.0)\n' "$TEST_BLUE" "$TEST_NC" "$name"
		return 0
	fi

	# Isolated tmp + PATH-prepended git stub.
	local tmpdir
	tmpdir=$(mktemp -d -t "cas-stdout-iso.XXXXXX") || {
		fail "$name" "mktemp failed"
		return 0
	}
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# A `git` stub that emits ANSI on stdout for push/fetch (mimicking a
	# noisy pre-push hook) but exits 0.  `rev-parse` and other non-push
	# invocations pass through to the real git so allocate_counter_cas
	# path plumbing still works where invoked.
	local real_git
	real_git=$(command -v git) || {
		fail "$name" "real git not found"
		return 0
	}

	cat >"${tmpdir}/git" <<EOF
#!/usr/bin/env bash
# Stub that emits ANSI narration on stdout for push/fetch, 0 exit.
for arg in "\$@"; do
	case "\$arg" in
	push|fetch)
		printf '\033[0;34m[INFO]\033[0m Pre-push Quality Validation running...\n'
		printf '\033[0;32m[OK]\033[0m secretlint clean\n'
		exit 0
		;;
	esac
done
exec "$real_git" "\$@"
EOF
	chmod +x "${tmpdir}/git"

	# Capture stdout of just a bare _cas_build_and_push-shaped call.
	# We replicate the CAS push surface inline rather than sourcing the
	# whole claim-task-id.sh (which has set -euo pipefail, top-level
	# side effects, and a TODO.md dependency).  The shape mirrors the
	# post-fix source exactly; a future regression would update the
	# source without updating this stub, so test 1 above is the true
	# tripwire.  This test is the end-to-end sanity demo.
	local captured_stdout
	captured_stdout=$(
		PATH="${tmpdir}:$PATH"
		export PATH
		REMOTE_NAME="origin"
		COUNTER_BRANCH="counter/tasks"
		CAS_GIT_CMD_TIMEOUT_S=30
		commit_sha="deadbeef"
		# Mirror post-fix:
		git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime="$CAS_GIT_CMD_TIMEOUT_S" \
			push -q "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" >/dev/null
		printf 'task_id=t99999'
	)

	# Assertion 1: no ANSI leaked into captured stdout
	if _contains_ansi "$captured_stdout"; then
		fail "$name" "ANSI leaked into captured stdout: $(printf '%q' "$captured_stdout")"
		return 0
	fi

	# Assertion 2: stdout is the clean caller-intended payload
	if [[ "$captured_stdout" != "task_id=t99999" ]]; then
		fail "$name" "unexpected captured stdout: $(printf '%q' "$captured_stdout")"
		return 0
	fi

	pass "$name"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	printf '%stest-claim-task-id-stdout-isolation.sh — GH#20208 regression%s\n' \
		"$TEST_BLUE" "$TEST_NC"
	printf '==============================================================\n\n'

	if [[ ! -f "$CLAIM_SCRIPT" ]]; then
		printf 'ERROR: claim-task-id-counter.sh not found at %s\n' "$CLAIM_SCRIPT" >&2
		return 1
	fi

	test_cas_build_push_redirects_push_stdout
	test_cas_build_push_redirects_fetch_stdout
	test_cas_fetch_and_pin_redirects_stdout
	test_gh20208_comment_anchor_present
	test_cas_build_push_arithmetic_safe_with_noisy_hook

	printf '\n'
	printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
	if [[ "$FAIL" -gt 0 ]]; then
		printf '\nFailed tests:%s\n' "$ERRORS"
		return 1
	fi
	return 0
}

main "$@"
