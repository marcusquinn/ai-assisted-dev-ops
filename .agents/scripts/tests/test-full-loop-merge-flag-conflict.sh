#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-full-loop-merge-flag-conflict.sh — Regression test for t2141 (GH#19310)
#
# `gh pr merge` rejects --admin and --auto together with:
#   "specify only one of `--auto`, `--disable-auto`, or `--admin`"
#
# `cmd_merge` in full-loop-helper.sh must detect this combination and resolve
# in favour of --admin (drop --auto with informational message), rather than
# passing both through and surfacing the opaque CLI error.
#
# Strategy: stub `gh` to log invocations, source full-loop-helper.sh with main
# stripped, call cmd_merge with --admin --auto, assert:
#   1. gh pr merge was called with --admin (not --auto)
#   2. The informational "Resolving in favour of --admin" message appeared
#   3. cmd_merge exit code is 0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
HELPER_SCRIPT="${SCRIPT_DIR}/../full-loop-helper.sh"

if [[ ! -f "$HELPER_SCRIPT" ]]; then
	echo "ERROR: helper not found at ${HELPER_SCRIPT}" >&2
	exit 2
fi

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	# Stub gh — logs every invocation, returns success for `pr merge`,
	# returns canned values for the few read-only calls cmd_merge makes.
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"${TEST_ROOT:?}/gh.log"
case "$1 $2" in
"pr merge")
	# Simulate successful merge — print success line.
	echo "Merged pull request"
	exit 0
	;;
"repo view")
	# cmd_merge may resolve repo via this; return slug when --json nameWithOwner.
	if [[ "$*" == *"nameWithOwner"* ]]; then
		echo "testorg/testrepo"
	fi
	exit 0
	;;
"pr view")
	# Used by review-bot-gate / dependency lookups — emit empty JSON.
	echo "{}"
	exit 0
	;;
"api")
	# Used by review-bot-gate to enumerate comments — empty list.
	echo "[]"
	exit 0
	;;
*)
	# Unknown subcommand — emit empty stdout, exit 0.
	exit 0
	;;
esac
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	export TEST_ROOT
	return 0
}

cleanup_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Source helper with main invocation stripped so functions are callable.
# Important: the helper resolves SCRIPT_DIR relative to BASH_SOURCE and sources
# shared-constants.sh from there, so the temp file MUST live in the same
# directory as the original (the scripts/ folder) for those resolutions to
# succeed.
load_helper_functions() {
	local helper_dir
	helper_dir=$(dirname "$HELPER_SCRIPT")
	local tmpfile="${helper_dir}/.test-t2141-helper-$$.sh"
	# Strip last `main "$@"` line
	sed '$d' "$HELPER_SCRIPT" >"$tmpfile"
	# shellcheck disable=SC1090
	source "$tmpfile"
	rm -f "$tmpfile"
	return 0
}

# Stub the helpers that would otherwise hit network / cause unrelated work.
stub_gates() {
	# Make pre-merge-gate always pass.
	cmd_pre_merge_gate() { return 0; }
	# Keep this flag-focused test independent from the exact-head, post-merge
	# evidence, canonical-sync, and lifecycle finalization contracts.
	_retarget_stacked_children_interactive() { return 0; }
	_merge_guard_admin_merge_maintainer_review() { return 0; }
	_merge_resolve_match_head() {
		printf '%s\n' "fixture-head-sha"
		return 0
	}
	_merge_resolve_subject_for_method() {
		local pr_number="$1"
		local repo="$2"
		local merge_method="$3"
		[[ -n "$pr_number" && -n "$repo" && -n "$merge_method" ]] || return 1
		printf '%s\n' "GH#19310: test merge flag conflict"
		return 0
	}
	_merge_review_state_still_clear() {
		local pr_number="$1"
		local repo="$2"
		local expected_head="$3"
		[[ -n "$pr_number" && -n "$repo" && -n "$expected_head" ]]
		return $?
	}
	_merge_guard_prospective_todo() {
		local pr_number="$1"
		local repo="$2"
		[[ -n "$pr_number" && -n "$repo" ]]
		return $?
	}
	_merge_verify_completed_state() {
		FULL_LOOP_MERGE_SHA="fixture-merge-sha"
		return 0
	}
	_merge_report_canonical_sync_state() { return 0; }
	_merge_finalize_post_merge() { return 0; }
	# Make resource unlock a no-op.
	_merge_unlock_resources() { return 0; }
	# Resolve repo unconditionally to the test slug.
	_merge_resolve_repo() {
		printf '%s' "${1:-testorg/testrepo}"
		return 0
	}
}

# ---------- Tests ----------

test_admin_and_auto_together_drops_auto() {
	: >"${TEST_ROOT}/gh.log"
	local out=""
	local rc=0
	# shellcheck disable=SC2034
	if out=$(cmd_merge 999 testorg/testrepo --squash --admin --auto 2>&1); then
		rc=0
	else
		rc=$?
	fi

	# 1. cmd_merge must exit 0 (the conflict was resolved, not a hard error)
	if [[ "$rc" -ne 0 ]]; then
		print_result "cmd_merge exits 0 with --admin --auto together" 1 \
			"rc=${rc}; output=${out}"
		return 0
	fi

	# 2. Informational message about resolution must be printed
	if ! printf '%s' "$out" | grep -q "Resolving in favour of --admin"; then
		print_result "informational resolution message printed" 1 \
			"output: ${out}"
		return 0
	fi

	# 3. gh pr merge must have been invoked with --admin and NOT --auto
	local merge_call=""
	merge_call=$(grep -F "gh pr merge" "${TEST_ROOT}/gh.log" || true)
	if [[ -z "$merge_call" ]]; then
		print_result "gh pr merge was invoked" 1 "log: $(cat "${TEST_ROOT}/gh.log")"
		return 0
	fi

	if ! printf '%s' "$merge_call" | grep -q -- "--admin"; then
		print_result "gh pr merge invoked with --admin" 1 "call: ${merge_call}"
		return 0
	fi

	if printf '%s' "$merge_call" | grep -q -- "--auto"; then
		print_result "gh pr merge does NOT include --auto when --admin wins" 1 \
			"call: ${merge_call}"
		return 0
	fi

	print_result "cmd_merge --admin --auto resolves in favour of --admin" 0
	return 0
}

test_auto_alone_still_passes_through() {
	: >"${TEST_ROOT}/gh.log"
	local out="" rc=0
	# shellcheck disable=SC2034
	if out=$(cmd_merge 999 testorg/testrepo --squash --auto 2>&1); then
		rc=0
	else
		rc=$?
	fi

	if [[ "$rc" -ne 0 ]]; then
		print_result "cmd_merge --auto alone exits 0" 1 \
			"rc=${rc}; output=${out}"
		return 0
	fi

	# Resolution message must NOT appear when only --auto was passed
	if printf '%s' "$out" | grep -q "Resolving in favour of --admin"; then
		print_result "resolution message NOT printed for --auto alone" 1
		return 0
	fi

	# gh pr merge should still have --auto (no resolution needed)
	local merge_call=""
	merge_call=$(grep -F "gh pr merge" "${TEST_ROOT}/gh.log" || true)
	if ! printf '%s' "$merge_call" | grep -q -- "--auto"; then
		print_result "gh pr merge --auto alone still includes --auto" 1 \
			"call: ${merge_call}"
		return 0
	fi

	if printf '%s' "$merge_call" | grep -q -- "--admin"; then
		print_result "gh pr merge --auto alone does NOT include --admin" 1 \
			"call: ${merge_call}"
		return 0
	fi

	print_result "cmd_merge --auto alone passes --auto through unchanged" 0
	return 0
}

test_admin_alone_still_passes_through() {
	: >"${TEST_ROOT}/gh.log"
	local out="" rc=0
	# shellcheck disable=SC2034
	if out=$(cmd_merge 999 testorg/testrepo --squash --admin 2>&1); then
		rc=0
	else
		rc=$?
	fi

	if [[ "$rc" -ne 0 ]]; then
		print_result "cmd_merge --admin alone exits 0" 1 \
			"rc=${rc}; output=${out}"
		return 0
	fi

	if printf '%s' "$out" | grep -q "Resolving in favour of --admin"; then
		print_result "resolution message NOT printed for --admin alone" 1
		return 0
	fi

	local merge_call=""
	merge_call=$(grep -F "gh pr merge" "${TEST_ROOT}/gh.log" || true)
	if ! printf '%s' "$merge_call" | grep -q -- "--admin"; then
		print_result "gh pr merge --admin alone includes --admin" 1 \
			"call: ${merge_call}"
		return 0
	fi

	if printf '%s' "$merge_call" | grep -q -- "--auto"; then
		print_result "gh pr merge --admin alone does NOT include --auto" 1 \
			"call: ${merge_call}"
		return 0
	fi

	print_result "cmd_merge --admin alone passes --admin through unchanged" 0
	return 0
}

# ---------- Run ----------

main() {
	setup_test_env
	trap cleanup_test_env EXIT

	load_helper_functions
	stub_gates

	echo "=== Flag-conflict resolution ==="
	test_admin_and_auto_together_drops_auto
	test_auto_alone_still_passes_through
	test_admin_alone_still_passes_through

	echo ""
	echo "Tests run: ${TESTS_RUN}, failed: ${TESTS_FAILED}"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
