#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-commit-and-pr-partial-success.sh — t2767 regression guard.
#
# Verifies that _create_pr() and _post_merge_summary() in full-loop-helper.sh
# handle partial-success failures correctly:
#
#   1. PR creation partial-success recovery:
#      When gh_create_pr returns non-zero but a PR already exists for the
#      current branch (e.g. GitHub created the PR but a follow-up GraphQL
#      mutation failed), _create_pr() must recover and return 0 with the
#      correct PR number — not bail with exit 1.
#
#   2. PR creation hard failure:
#      When gh_create_pr returns non-zero AND no PR exists for the branch,
#      _create_pr() must return 1 with an error message.
#
#   3. Merge-summary idempotency:
#      When _post_merge_summary() is called a second time and a canonical
#      <!-- MERGE_SUMMARY --> comment already exists on the PR, it must skip
#      posting and return 0 (no duplicate comment).
#
#   4. Merge-summary first post:
#      When no MERGE_SUMMARY comment exists, _post_merge_summary() must
#      post the comment and return 0.
#
# Stub strategy: define gh, gh_create_pr, _gh_recover_pr_if_exists,
# gh_pr_comment, and git as shell functions AFTER extracting the tested
# functions. Shell functions take precedence over PATH binaries. The
# _SOURCING_FOR_TEST guard prevents full-loop-helper.sh's main entrypoint
# from running during extraction.
#
# Cross-reference: GH#20634 / t2767 (fix), PR #20616 (original failure).

# NOT using set -e — negative assertions rely on non-zero exits
set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
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
# Sandbox setup
# =============================================================================
TMP=$(mktemp -d -t t2767.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

STUB_LOG="${TMP}/stub_calls.log"
GH_API_RESPONSE="${TMP}/gh_api_response.txt"
: >"$STUB_LOG"
printf '0\n' >"$GH_API_RESPONSE" # default: 0 existing MERGE_SUMMARY comments

# =============================================================================
# Minimal stubs for shared-constants.sh symbols required by full-loop-helper.sh
# =============================================================================
if [[ -z "${NC+x}" ]]; then
	NC=$'\033[0m'
	RED=$'\033[0;31m'
	GREEN=$'\033[0;32m'
	YELLOW=$'\033[0;33m'
	BLUE=$'\033[0;34m'
	PURPLE=$'\033[0;35m'
	CYAN=$'\033[0;36m'
	WHITE=$'\033[0;37m'
	BOLD=$'\033[1m'
fi

# Quiet print stubs — capture to log for assertions
print_info() {
	printf '[INFO] %s\n' "$*" >>"$STUB_LOG"
	return 0
}
print_error() {
	printf '[ERROR] %s\n' "$*" >>"$STUB_LOG"
	return 0
}
print_warning() {
	printf '[WARN] %s\n' "$*" >>"$STUB_LOG"
	return 0
}
print_success() {
	printf '[OK] %s\n' "$*" >>"$STUB_LOG"
	return 0
}

# =============================================================================
# Extract the functions under test directly from the helper.
# Extraction uses sed to pull from function declaration to closing brace.
# The _SOURCING_FOR_TEST sentinel prevents main entrypoint execution.
# =============================================================================
_SOURCING_FOR_TEST=1

# Extract _create_pr
# shellcheck disable=SC2312
eval "$(sed -n '/^_create_pr() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# shellcheck disable=SC2312
eval "$(sed -n '/^_reconcile_recovered_pr_metadata() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# Extract origin reconciliation helpers used by _create_pr
# shellcheck disable=SC2312
eval "$(sed -n '/^_verify_pr_origin_label() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# shellcheck disable=SC2312
eval "$(sed -n '/^_reconcile_pr_origin_label() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# shellcheck disable=SC2312
eval "$(sed -n '/^_reconcile_existing_merge_summary() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# Extract _post_merge_summary
# shellcheck disable=SC2312
eval "$(sed -n '/^_post_merge_summary() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# Extract default-branch and recovery helpers used by _rebase_and_push
# shellcheck disable=SC2312
eval "$(sed -n '/^_resolve_remote_default_branch() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# shellcheck disable=SC2312
eval "$(sed -n '/^_ensure_no_in_progress_integration() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# Extract the split rebase and push stages used by the compatibility wrapper.
# shellcheck disable=SC2312
eval "$(sed -n '/^_rebase_for_push() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# shellcheck disable=SC2312
eval "$(sed -n '/^_push_branch() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# Extract _rebase_and_push
# shellcheck disable=SC2312
eval "$(sed -n '/^_rebase_and_push() {/,/^}/p' "${SCRIPTS_DIR}/full-loop-helper-commit.sh")"

# =============================================================================
# Post-extraction stubs (override PATH binaries and define missing deps).
# Defined after eval so they take precedence over any stubs extracted from helper.
# =============================================================================

# Stub: git branch --show-current → always returns "feature/t2767-test"
git() {
	printf 'git %s\n' "$*" >>"$STUB_LOG"
	if [[ "${1:-}" == "branch" && "${2:-}" == "--show-current" ]]; then
		printf 'feature/t2767-test\n'
		return 0
	fi
	if [[ "${1:-}" == "symbolic-ref" && "${2:-}" == "--short" && "${3:-}" == "refs/remotes/origin/HEAD" ]]; then
		printf '%s\n' "${TEST_REMOTE_HEAD:-origin/main}"
		return 0
	fi
	if [[ "${1:-}" == "rev-list" && "${2:-}" == "--count" ]]; then
		printf '1\n'
		return 0
	fi
	if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--git-dir" ]]; then
		printf '%s/.git\n' "$TMP"
		return 0
	fi
	if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--git-path" ]]; then
		printf '%s/.git/%s\n' "$TMP" "${3:-}"
		return 0
	fi
	if [[ "${1:-}" == "fetch" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "rebase" ]]; then
		return 0
	fi
	if [[ "${1:-}" == "push" ]]; then
		printf "branch 'feature/t2767-test' set up to track 'origin/feature/t2767-test'.\n"
		return 0
	fi
	if [[ "${1:-}" == "show" ]]; then
		return 1
	fi
	command git "$@"
	return $?
}
export -f git

_check_and_handle_shallow_clone() { return 0; }

timeout() {
	local _duration="${1:-}"
	: "$_duration"
	shift || return 1
	"$@"
	return $?
}

# Control variable: set to 1 to simulate gh_create_pr partial success
GH_CREATE_PR_FAIL=0
# Control variable: the URL to return from gh_create_pr on success
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/999"
# Control variable: optional stderr emitted by gh_create_pr on success
GH_CREATE_PR_STDERR_LOG=""

# Stub: gh_create_pr — honours GH_CREATE_PR_FAIL
# On failure, outputs an error message (like real gh does) and returns 1.
gh_create_pr() {
	printf 'gh_create_pr %s\n' "$*" >>"$STUB_LOG"
	if [[ "$GH_CREATE_PR_FAIL" -eq 1 ]]; then
		printf 'pull request update failed: GraphQL: Something went wrong\n' >&2
		return 1
	fi
	if [[ -n "$GH_CREATE_PR_STDERR_LOG" ]]; then
		printf '%s\n' "$GH_CREATE_PR_STDERR_LOG" >&2
	fi
	printf '%s\n' "$GH_CREATE_PR_URL"
	return 0
}
export -f gh_create_pr

# Control variable: PR URL to return from _gh_recover_pr_if_exists
GH_RECOVER_PR_URL=""
# Remote recovered-PR metadata. The edit stub replaces these values so the
# partial-success test can prove a retry repairs stale title/body metadata.
REMOTE_PR_TITLE="stale title"
REMOTE_PR_BODY="stale body"

# Stub: _gh_recover_pr_if_exists — honours GH_RECOVER_PR_URL
# Returns the URL if set (simulating PR exists), empty string otherwise.
_gh_recover_pr_if_exists() {
	printf '_gh_recover_pr_if_exists branch=%s repo=%s\n' "${1:-}" "${2:-}" >>"$STUB_LOG"
	printf '%s\n' "${GH_RECOVER_PR_URL:-}"
	return 0
}
export -f _gh_recover_pr_if_exists

# Control variable: set to non-empty to simulate canonical MERGE_SUMMARY already existing
GH_EXISTING_MERGE_SUMMARY_COUNT=0
# Control variable: set to 1 to simulate only malformed plain-text MERGE_SUMMARY existing
GH_MALFORMED_MERGE_SUMMARY_ONLY=0
# Control variables for direct origin-label readback tests.
ORIGIN_API_FAIL=0
ORIGIN_API_LABELS='["origin:worker"]'

# Stub: gh — handles the gh api call for MERGE_SUMMARY check, plus pr comment
gh() {
	printf 'gh %s\n' "$*" >>"$STUB_LOG"
	# Handle: gh api repos/.../issues/.../comments --jq '...'
	if [[ "${1:-}" == "api" ]]; then
		if [[ "$*" == *"repos/owner/repo/pulls/999"* ]]; then
			if [[ "$*" == *".title // empty"* ]]; then
				printf '%s\n' "$REMOTE_PR_TITLE"
			else
				printf '%s\n' "$REMOTE_PR_BODY"
			fi
			return 0
		fi
		if [[ "$*" == *"repos/owner/repo/issues/comments/77"* && "$*" == *"--method PATCH"* ]]; then
			local arg
			for arg in "$@"; do
				case "$arg" in
				body=*) GH_EXISTING_MERGE_SUMMARY_BODY="${arg#body=}" ;;
				esac
			done
			return 0
		fi
		if [[ "$*" == *'startswith("origin:")'* ]]; then
			[[ "$ORIGIN_API_FAIL" -eq 0 ]] || return 1
			printf '%s\n' "$ORIGIN_API_LABELS"
			return 0
		fi
		if [[ "$*" == *'<!-- MERGE_SUMMARY -->'* ]]; then
			if [[ "$*" == *'@tsv'* ]]; then
				printf '77\t%s\n' "$GH_EXISTING_MERGE_SUMMARY_BODY"
				return 0
			fi
			printf '%s\n' "$GH_EXISTING_MERGE_SUMMARY_COUNT"
			return 0
		fi
		if [[ "$GH_MALFORMED_MERGE_SUMMARY_ONLY" -eq 1 ]]; then
			printf '1\n'
			return 0
		fi
		printf '%s\n' "$GH_EXISTING_MERGE_SUMMARY_COUNT"
		return 0
	fi
	# Handle: gh pr comment ... (simulated via gh_pr_comment stub below)
	return 0
}
export -f gh

gh_pr_edit_safe() {
	local title=""
	local body_file=""
	printf 'gh_pr_edit_safe %s\n' "$*" >>"$STUB_LOG"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			title="${2:-}"
			shift 2 || return 1
			;;
		--body-file)
			body_file="${2:-}"
			shift 2 || return 1
			;;
		*) shift ;;
		esac
	done
	[[ -n "$title" ]] && REMOTE_PR_TITLE="$title"
	if [[ -n "$body_file" && -r "$body_file" ]]; then
		REMOTE_PR_BODY=$(<"$body_file")
	fi
	return 0
}
export -f gh_pr_edit_safe

_gh_with_timeout() {
	local op_class="$1"
	shift
	printf '_gh_with_timeout class=%s command=%s\n' "$op_class" "$*" >>"$STUB_LOG"
	"$@"
	return $?
}
export -f _gh_with_timeout

# The production readback must use the bounded GitHub wrapper and normalize a
# transient read failure to an empty result before enforcing the postcondition.
: >"$STUB_LOG"
ORIGIN_API_FAIL=0
if _verify_pr_origin_label 999 "owner/repo" worker &&
	grep -q '_gh_with_timeout class=read command=gh api repos/owner/repo/issues/999' "$STUB_LOG"; then
	pass "origin readback: uses bounded GitHub wrapper"
else
	fail "origin readback: uses bounded GitHub wrapper" "stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

: >"$STUB_LOG"
ORIGIN_API_FAIL=1
origin_readback_rc=0
_verify_pr_origin_label 999 "owner/repo" worker || origin_readback_rc=$?
if [[ "$origin_readback_rc" -eq 2 ]]; then
	pass "origin readback: transient API failure becomes unavailable postcondition"
else
	fail "origin readback: transient API failure becomes unavailable postcondition" \
		"expected exit 2, got ${origin_readback_rc}"
fi
ORIGIN_API_FAIL=0

# Stub: gh_pr_comment — records body-file use and can simulate policy failure.
GH_PR_COMMENT_FAIL=0
gh_pr_comment() {
	local pr_number="${1:-}"
	local body_file=""
	shift || return 1
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body-file)
			body_file="${2:-}"
			shift 2 || return 1
			;;
		--body-file=*)
			body_file="${1#--body-file=}"
			shift
			;;
		*) shift ;;
		esac
	done
	printf 'gh_pr_comment pr=%s body_file=%s\n' "$pr_number" "$body_file" >>"$STUB_LOG"
	if [[ "$GH_PR_COMMENT_FAIL" -eq 1 ]]; then
		printf 'signature gate: comments require --body-file\n' >&2
		return 1
	fi
	if [[ -z "$body_file" || ! -r "$body_file" ]]; then
		printf 'missing readable merge summary body file\n' >&2
		return 1
	fi
	if ! grep -q '<!-- MERGE_SUMMARY -->' "$body_file"; then
		printf 'missing canonical merge summary marker\n' >&2
		return 1
	fi
	GH_EXISTING_MERGE_SUMMARY_COUNT=1
	return 0
}
export -f gh_pr_comment

# Control variable: set to 1 to simulate post-create origin reconciliation failure.
SET_ORIGIN_LABEL_FAIL=0
# Control variables for the required readback postcondition.
ORIGIN_READBACK_FAIL=0
ORIGIN_READBACK_LABELS='["origin:worker"]'

set_origin_label() {
	local issue_num="${1:-}"
	local repo_slug="${2:-}"
	local new_origin="${3:-}"
	shift 3 || return 1
	printf 'set_origin_label num=%s repo=%s origin=%s flags=%s\n' \
		"$issue_num" "$repo_slug" "$new_origin" "$*" >>"$STUB_LOG"
	if [[ "$SET_ORIGIN_LABEL_FAIL" -eq 1 ]]; then
		printf 'GraphQL: Resource not accessible by integration\n' >&2
		return 1
	fi
	printf 'https://github.com/%s/pull/%s\n' "$repo_slug" "$issue_num"
	return 0
}
export -f set_origin_label

_verify_pr_origin_label() {
	local pr_number="${1:-}"
	local repo_slug="${2:-}"
	local expected_origin="${3:-}"
	printf '_verify_pr_origin_label num=%s repo=%s origin=%s labels=%s\n' \
		"$pr_number" "$repo_slug" "$expected_origin" "$ORIGIN_READBACK_LABELS" >>"$STUB_LOG"
	[[ "$ORIGIN_READBACK_FAIL" -eq 0 ]] || return 1
	if printf '%s' "$ORIGIN_READBACK_LABELS" |
		jq -e --arg expected "origin:${expected_origin}" \
			'length == 1 and .[0] == $expected' >/dev/null 2>&1; then
		return 0
	fi
	return 2
}
export -f _verify_pr_origin_label

# =============================================================================
# Test 1: _create_pr partial-success recovery
# gh_create_pr returns non-zero, but _gh_recover_pr_if_exists finds the PR.
# Expected: _create_pr returns 0 and outputs the correct PR number (999).
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=1
GH_RECOVER_PR_URL="https://github.com/owner/repo/pull/999"
REMOTE_PR_TITLE="stale title"
REMOTE_PR_BODY="stale body"

actual_pr_number=""
actual_rc=0
actual_pr_number=$(_create_pr "owner/repo" "t2767: test" "body text" "origin:worker") || actual_rc=$?

if [[ "$actual_rc" -eq 0 ]]; then
	pass "partial-success recovery: _create_pr returns 0 when PR exists after create failure"
else
	fail "partial-success recovery: _create_pr returns 0 when PR exists after create failure" \
		"got exit $actual_rc; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if [[ "$actual_pr_number" == "999" ]]; then
	pass "partial-success recovery: _create_pr outputs correct PR number (999)"
else
	fail "partial-success recovery: _create_pr outputs correct PR number (999)" \
		"got '${actual_pr_number}'; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "recovering (t2767)" "$STUB_LOG" 2>/dev/null; then
	pass "partial-success recovery: recovery log message emitted"
else
	fail "partial-success recovery: recovery log message emitted" \
		"expected '[INFO] ... recovering (t2767)' in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "set_origin_label num=999 repo=owner/repo origin=worker flags=--pr" "$STUB_LOG" 2>/dev/null; then
	pass "partial-success recovery: origin label reconciled on recovered PR"
else
	fail "partial-success recovery: origin label reconciled on recovered PR" \
		"expected set_origin_label for PR 999; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "gh_pr_edit_safe 999 --repo owner/repo --title t2767: test --body-file" "$STUB_LOG" 2>/dev/null; then
	pass "partial-success recovery: stale PR title/body reconciled to retry metadata"
else
	fail "partial-success recovery: stale PR title/body reconciled to retry metadata" \
		"expected signed managed PR edit and in-child readback verification; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 2: _create_pr hard failure
# gh_create_pr returns non-zero AND _gh_recover_pr_if_exists finds nothing.
# Expected: _create_pr returns non-zero with an error.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=1
GH_RECOVER_PR_URL=""

hard_fail_rc=0
_create_pr "owner/repo" "t2767: test" "body text" "origin:worker" >/dev/null 2>&1 || hard_fail_rc=$?

if [[ "$hard_fail_rc" -ne 0 ]]; then
	pass "hard failure: _create_pr returns non-zero when no PR exists after failure"
else
	fail "hard failure: _create_pr returns non-zero when no PR exists after failure" \
		"expected non-zero exit, got 0; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "\[ERROR\] PR creation failed" "$STUB_LOG" 2>/dev/null; then
	pass "hard failure: error message emitted"
else
	fail "hard failure: error message emitted" \
		"expected '[ERROR] PR creation failed' in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 3: _create_pr success (no recovery needed)
# gh_create_pr succeeds. Expected: _create_pr returns 0, outputs PR number.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=0
GH_RECOVER_PR_URL=""
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/888"
GH_CREATE_PR_STDERR_LOG=""

success_pr_number=""
success_rc=0
success_pr_number=$(_create_pr "owner/repo" "t2767: test" "body text" "origin:worker") || success_rc=$?

if [[ "$success_rc" -eq 0 ]]; then
	pass "normal success: _create_pr returns 0 on clean create"
else
	fail "normal success: _create_pr returns 0 on clean create" \
		"got exit $success_rc"
fi

if [[ "$success_pr_number" == "888" ]]; then
	pass "normal success: _create_pr outputs correct PR number (888)"
else
	fail "normal success: _create_pr outputs correct PR number (888)" \
		"got '${success_pr_number}'"
fi

if grep -q "set_origin_label num=888 repo=owner/repo origin=worker flags=--pr" "$STUB_LOG" 2>/dev/null; then
	pass "normal success: origin label reconciled on created PR"
else
	fail "normal success: origin label reconciled on created PR" \
		"expected set_origin_label for PR 888; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 3a: _create_pr fails closed when origin label reconciliation fails
# Expected: PR creation does not report success when provenance cannot be verified.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=0
GH_RECOVER_PR_URL=""
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/889"
GH_CREATE_PR_STDERR_LOG=""
SET_ORIGIN_LABEL_FAIL=1

label_fail_rc=0
_create_pr "owner/repo" "t2767: test" "body text" "origin:worker" >/dev/null 2>&1 || label_fail_rc=$?

if [[ "$label_fail_rc" -ne 0 ]]; then
	pass "origin reconciliation failure: _create_pr fails closed"
else
	fail "origin reconciliation failure: _create_pr fails closed" \
		"expected non-zero exit; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "credential lacks PR label permission" "$STUB_LOG" 2>/dev/null; then
	pass "origin reconciliation failure: classified diagnostic emitted"
else
	fail "origin reconciliation failure: classified diagnostic emitted" \
		"expected permission classification in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

SET_ORIGIN_LABEL_FAIL=0

# =============================================================================
# Test 3a.1: mutation success is not enough when readback lacks exact origin.
# Expected: _create_pr fails closed for missing, wrong, or dual origin labels.
# =============================================================================
for readback_labels in '[]' '["origin:interactive"]' '["origin:worker","origin:interactive"]'; do
	: >"$STUB_LOG"
	ORIGIN_READBACK_LABELS="$readback_labels"
	readback_rc=0
	_create_pr "owner/repo" "t2767: test" "body text" "origin:worker" >/dev/null 2>&1 || readback_rc=$?
	if [[ "$readback_rc" -ne 0 ]] && grep -q "did not reach the exact origin:worker postcondition" "$STUB_LOG" 2>/dev/null; then
		pass "origin readback rejects non-exact postcondition: ${readback_labels}"
	else
		fail "origin readback rejects non-exact postcondition: ${readback_labels}" \
			"rc=${readback_rc}; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
	fi
done
ORIGIN_READBACK_LABELS='["origin:worker"]'

# Readback API failure is normalized to an unavailable postcondition.
: >"$STUB_LOG"
ORIGIN_READBACK_FAIL=1
readback_api_rc=0
_create_pr "owner/repo" "t2767: test" "body text" "origin:worker" >/dev/null 2>&1 || readback_api_rc=$?
if [[ "$readback_api_rc" -ne 0 ]] && grep -q "reconcile unavailable, missing, wrong, or dual origin labels" "$STUB_LOG" 2>/dev/null; then
	pass "origin readback API failure: unavailable postcondition diagnostic emitted"
else
	fail "origin readback API failure: unavailable postcondition diagnostic emitted" \
		"rc=${readback_api_rc}; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi
ORIGIN_READBACK_FAIL=0

# =============================================================================
# Test 3b: _create_pr REST fallback logs do not pollute machine stdout
# gh_create_pr succeeds via wrapper REST fallback but writes GraphQL/fallback
# diagnostics mentioning the issue number to stderr. Expected: _create_pr
# outputs only the actual PR number, so commit-and-pr posts MERGE_SUMMARY there.
# =============================================================================
: >"$STUB_LOG"
GH_CREATE_PR_FAIL=0
GH_RECOVER_PR_URL=""
GH_CREATE_PR_URL="https://github.com/owner/repo/pull/22459"
GH_CREATE_PR_STDERR_LOG=$'[INFO] gh-wrapper: GraphQL exhausted, falling back to REST for pr create\nhttps://github.com/owner/repo/issues/22437'

rest_fallback_pr_number=""
rest_fallback_rc=0
rest_fallback_pr_number=$(_create_pr "owner/repo" "t2767: test" "body text" "origin:worker") || rest_fallback_rc=$?

if [[ "$rest_fallback_rc" -eq 0 ]]; then
	pass "REST fallback success: _create_pr returns 0 when wrapper succeeds"
else
	fail "REST fallback success: _create_pr returns 0 when wrapper succeeds" \
		"got exit $rest_fallback_rc; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if [[ "$rest_fallback_pr_number" == "22459" ]]; then
	pass "REST fallback success: _create_pr outputs only actual PR number (22459)"
else
	fail "REST fallback success: _create_pr outputs only actual PR number (22459)" \
		"got '${rest_fallback_pr_number}'; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

GH_EXISTING_MERGE_SUMMARY_COUNT=0
_post_merge_summary "$rest_fallback_pr_number" "owner/repo" "22437" "impl" "file.sh" "shellcheck" "none" >/dev/null 2>&1

if grep -q "gh_pr_comment pr=22459" "$STUB_LOG" 2>/dev/null &&
	! grep -q "gh_pr_comment pr=22437" "$STUB_LOG" 2>/dev/null; then
	pass "REST fallback success: MERGE_SUMMARY targets the actual PR number"
else
	fail "REST fallback success: MERGE_SUMMARY targets the actual PR number" \
		"stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

GH_CREATE_PR_STDERR_LOG=""

# =============================================================================
# Test 3c: _rebase_and_push keeps git push setup noise off stdout
# git push -u may print "branch ... set up to track ..." on stdout. Expected:
# helper redirects that to stderr so commit-and-pr stdout remains only PR_NUMBER.
# =============================================================================
: >"$STUB_LOG"
rebase_push_output=""
rebase_push_rc=0
rebase_push_output=$(_rebase_and_push "feature/t2767-test" 0 2>/dev/null) || rebase_push_rc=$?

if [[ "$rebase_push_rc" -eq 0 ]]; then
	pass "push stdout hygiene: _rebase_and_push succeeds"
else
	fail "push stdout hygiene: _rebase_and_push succeeds" \
		"got exit $rebase_push_rc; output '${rebase_push_output}'"
fi

if [[ -z "$rebase_push_output" ]]; then
	pass "push stdout hygiene: _rebase_and_push emits no stdout"
else
	fail "push stdout hygiene: _rebase_and_push emits no stdout" \
		"got '${rebase_push_output}'"
fi

# =============================================================================
# Test 3d: _rebase_and_push uses the detected remote default branch
# Expected: non-main origin/HEAD causes fetch/rebase/diff safety checks to use develop.
# =============================================================================
: >"$STUB_LOG"
TEST_REMOTE_HEAD="origin/develop"
default_branch_rc=0
_rebase_and_push "feature/t2767-test" 0 >/dev/null 2>&1 || default_branch_rc=$?

if [[ "$default_branch_rc" -eq 0 ]]; then
	pass "default branch: _rebase_and_push succeeds for non-main remote HEAD"
else
	fail "default branch: _rebase_and_push succeeds for non-main remote HEAD" \
		"got exit $default_branch_rc; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "git fetch origin develop --quiet" "$STUB_LOG" 2>/dev/null &&
	grep -q "git rebase origin/develop" "$STUB_LOG" 2>/dev/null &&
	! grep -q "git rebase origin/main" "$STUB_LOG" 2>/dev/null; then
	pass "default branch: rebase path uses origin/develop rather than origin/main"
else
	fail "default branch: rebase path uses origin/develop rather than origin/main" \
		"stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 3e: _rebase_and_push --no-rebase recovery keeps wrapper path pushable
# Expected: explicit recovery mode skips git rebase and still pushes after checks.
# =============================================================================
: >"$STUB_LOG"
TEST_REMOTE_HEAD="origin/develop"
no_rebase_rc=0
_rebase_and_push "feature/t2767-test" 0 1 >/dev/null 2>&1 || no_rebase_rc=$?

if [[ "$no_rebase_rc" -eq 0 ]]; then
	pass "no-rebase recovery: explicit mode succeeds with clean ahead branch"
else
	fail "no-rebase recovery: explicit mode succeeds with clean ahead branch" \
		"got exit $no_rebase_rc; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if ! grep -q "git rebase" "$STUB_LOG" 2>/dev/null &&
	grep -q "git rev-list --count origin/develop..HEAD" "$STUB_LOG" 2>/dev/null &&
	grep -q "git push -u origin feature/t2767-test --force-with-lease" "$STUB_LOG" 2>/dev/null; then
	pass "no-rebase recovery: skips rebase and pushes via wrapper path"
else
	fail "no-rebase recovery: skips rebase and pushes via wrapper path" \
		"stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

TEST_REMOTE_HEAD="origin/main"

# =============================================================================
# Test 4: _post_merge_summary idempotency — skip when canonical comment already exists
# GH_EXISTING_MERGE_SUMMARY_COUNT=1 simulates an existing <!-- MERGE_SUMMARY --> comment.
# Expected: gh_pr_comment NOT called, returns 0.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=1
GH_MALFORMED_MERGE_SUMMARY_ONLY=0
GH_EXISTING_MERGE_SUMMARY_BODY=$'<!-- MERGE_SUMMARY -->\n## Completion Summary\n\n- **What**: impl\n- **Issue**: #42\n- **Files changed**: file.sh\n- **Testing**: shellcheck\n- **Key decisions**: none'

idem_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" || idem_rc=$?

if [[ "$idem_rc" -eq 0 ]]; then
	pass "idempotency: _post_merge_summary returns 0 when comment already exists"
else
	fail "idempotency: _post_merge_summary returns 0 when comment already exists" \
		"got exit $idem_rc"
fi

if ! grep -q "gh_pr_comment" "$STUB_LOG" 2>/dev/null; then
	pass "idempotency: gh_pr_comment NOT called when MERGE_SUMMARY already exists"
else
	fail "idempotency: gh_pr_comment NOT called when MERGE_SUMMARY already exists" \
		"gh_pr_comment was called; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q "already matches PR #999" "$STUB_LOG" 2>/dev/null; then
	pass "idempotency: skip message logged"
else
	fail "idempotency: skip message logged" \
		"expected matching skip message in log; got: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 4b: _post_merge_summary updates a stale canonical comment in place.
# Changed files, testing, and decisions represent a force-pushed review repair.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=1
GH_EXISTING_MERGE_SUMMARY_BODY=$'<!-- MERGE_SUMMARY -->\n## Completion Summary\n\n- **What**: impl\n- **Issue**: #42\n- **Files changed**: old-file.sh\n- **Testing**: old test\n- **Key decisions**: old decision'

stale_update_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "new-file.sh" "new test" "new decision" || stale_update_rc=$?

if [[ "$stale_update_rc" -eq 0 ]] &&
	[[ "$GH_EXISTING_MERGE_SUMMARY_BODY" == *"new-file.sh"* ]] &&
	[[ "$GH_EXISTING_MERGE_SUMMARY_BODY" == *"new test"* ]] &&
	[[ "$GH_EXISTING_MERGE_SUMMARY_BODY" == *"new decision"* ]] &&
	grep -q "issues/comments/77 --method PATCH" "$STUB_LOG" 2>/dev/null; then
	pass "stale summary: canonical comment is updated in place with retry metadata"
else
	fail "stale summary: canonical comment is updated in place with retry metadata" \
		"rc=${stale_update_rc}; body='${GH_EXISTING_MERGE_SUMMARY_BODY}'; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 4a: _post_merge_summary ignores malformed plain-text MERGE_SUMMARY comments
# GH_MALFORMED_MERGE_SUMMARY_ONLY=1 simulates a comment containing the loose
# MERGE_SUMMARY text but not the canonical <!-- MERGE_SUMMARY --> marker.
# Expected: gh_pr_comment IS called so a canonical comment is posted.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=0
GH_MALFORMED_MERGE_SUMMARY_ONLY=1

malformed_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" || malformed_rc=$?

if [[ "$malformed_rc" -eq 0 ]]; then
	pass "malformed marker: _post_merge_summary returns 0 when only plain-text MERGE_SUMMARY exists"
else
	fail "malformed marker: _post_merge_summary returns 0 when only plain-text MERGE_SUMMARY exists" \
		"got exit $malformed_rc"
fi

if grep -q "gh_pr_comment" "$STUB_LOG" 2>/dev/null; then
	pass "malformed marker: gh_pr_comment IS called to post canonical MERGE_SUMMARY"
else
	fail "malformed marker: gh_pr_comment IS called to post canonical MERGE_SUMMARY" \
		"gh_pr_comment was NOT called; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 5: _post_merge_summary first post — no existing comment
# GH_EXISTING_MERGE_SUMMARY_COUNT=0 simulates no existing MERGE_SUMMARY comment.
# Expected: gh_pr_comment IS called, returns 0.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=0
GH_MALFORMED_MERGE_SUMMARY_ONLY=0

first_post_rc=0
_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" || first_post_rc=$?

if [[ "$first_post_rc" -eq 0 ]]; then
	pass "first post: _post_merge_summary returns 0 on fresh PR"
else
	fail "first post: _post_merge_summary returns 0 on fresh PR" \
		"got exit $first_post_rc"
fi

if grep -q "gh_pr_comment" "$STUB_LOG" 2>/dev/null; then
	pass "first post: gh_pr_comment IS called when no MERGE_SUMMARY exists"
else
	fail "first post: gh_pr_comment IS called when no MERGE_SUMMARY exists" \
		"gh_pr_comment was NOT called; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

if grep -q 'gh_pr_comment pr=999 body_file=' "$STUB_LOG" 2>/dev/null; then
	pass "first post: canonical merge summary is posted through --body-file"
else
	fail "first post: canonical merge summary is posted through --body-file" \
		"body-file call missing; stub log: $(cat "$STUB_LOG" 2>/dev/null)"
fi

# =============================================================================
# Test 6: posting failure is a lifecycle failure with preserved diagnostics
# The signature gate rejects the write. Expected: _post_merge_summary returns 1,
# keeps the gate's stderr visible, and cmd_commit_and_pr propagates the failure.
# =============================================================================
: >"$STUB_LOG"
GH_EXISTING_MERGE_SUMMARY_COUNT=0
GH_PR_COMMENT_FAIL=1
post_failure_rc=0
post_failure_stderr=""
post_failure_stderr=$(_post_merge_summary "999" "owner/repo" "42" "impl" "file.sh" "shellcheck" "none" 2>&1) || post_failure_rc=$?

if [[ "$post_failure_rc" -eq 1 ]]; then
	pass "post failure: _post_merge_summary returns non-success"
else
	fail "post failure: _post_merge_summary returns non-success" "got exit ${post_failure_rc}"
fi

if [[ "$post_failure_stderr" == *"signature gate: comments require --body-file"* ]]; then
	pass "post failure: policy diagnostics remain visible"
else
	fail "post failure: policy diagnostics remain visible" "stderr: ${post_failure_stderr}"
fi

if grep -q '_post_merge_summary .* || return 1' "${SCRIPTS_DIR}/full-loop-helper.sh"; then
	pass "post failure: commit-and-pr propagates merge-summary failure"
else
	fail "post failure: commit-and-pr propagates merge-summary failure"
fi
GH_PR_COMMENT_FAIL=0

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
