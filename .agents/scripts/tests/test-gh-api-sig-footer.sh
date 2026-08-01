#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-api-sig-footer.sh — t2707 / GH#20350 regression guard.
#
# Asserts that the signature-footer gate (t2685) extends to `gh api` raw REST
# calls so that every GitHub write — regardless of whether it goes through the
# high-level wrappers or a direct `gh api` call — carries the canonical
# <!-- aidevops:sig --> audit marker.
#
# Two layers are tested:
#   Layer 1 — REST fallback translators in shared-gh-wrappers-rest-fallback.sh
#   Layer 2 — `gh` PATH shim logic (_shim_api_is_write_endpoint / _shim_api_inject_body_sig)
#
# Tests:
#   1. REST fallback translator injects sig on _rest_issue_create
#   2. REST fallback translator injects sig on _rest_issue_comment
#   3. REST fallback translator injects sig on _rest_pr_create
#   4. PATH shim injects sig on gh api -X POST /repos/X/Y/issues -f body=@file
#   5. PATH shim injects sig on gh api -X POST /repos/X/Y/issues/N/comments -f body=@file
#   6. PATH shim leaves gh api /rate_limit (GET, no -X) untouched
#
# Stub strategy for Layer 1 tests: define `gh` as a shell function that
# captures calls and injects a mock sig line (since the real gh-signature-helper
# is unavailable in unit-test context). The sig injection in translators is
# validated by checking that _rest_append_sig was called and appended
# the marker to the temp body file BEFORE the api call.
#
# Strategy for Layer 2 tests: source the shim helper functions directly into
# this test process and call them with synthetic _modified_args arrays. A
# stub SIG_HELPER writes the canonical marker to validate injection.

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
# Sandbox
# =============================================================================
TMP=$(mktemp -d -t t2707.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

GH_CALLS="${TMP}/gh_calls.log"

# =============================================================================
# Layer 1 setup: source shared libraries with stubbed `gh` and sig helper
# =============================================================================

# Stub sig helper — writes the canonical marker so translators can append it.
_STUB_SIG_HELPER="${TMP}/gh-signature-helper.sh"
cat >"$_STUB_SIG_HELPER" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "footer" ]]; then
	printf '\n\n<!-- aidevops:sig -->\n---\nTest signature footer.\n'
fi
exit 0
STUB
chmod +x "$_STUB_SIG_HELPER"

# Ensure our stub helper is discoverable by _rest_append_sig via BASH_SOURCE.
# The function searches HOME/.aidevops/agents/scripts/ and dirname(BASH_SOURCE[0]).
# Override HOME-based path since we can't write there in tests.
# We inject via a wrapper: temporarily place the stub on PATH as gh-signature-helper.sh.
mkdir -p "${TMP}/bin"
cp "$_STUB_SIG_HELPER" "${TMP}/bin/gh-signature-helper.sh"
export PATH="${TMP}/bin:${PATH}"

# Stub `gh` — captures calls, always succeeds for API calls.
# shellcheck disable=SC2317
gh() {
	printf '%s\n' "$*" >>"${GH_CALLS}"
	if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
		printf '5000\n'
		return 0
	fi
	if [[ "$1" == "api" ]]; then
		printf 'https://github.com/owner/repo/issues/9999\n'
		return 0
	fi
	return 0
}
export -f gh

# Silence print_* functions from shared-constants.
# shellcheck disable=SC2317
print_info() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }
print_success() { return 0; }
log_verbose() { return 0; }
export -f print_info print_warning print_error print_success log_verbose

export AIDEVOPS_SESSION_ORIGIN=worker
export AIDEVOPS_SESSION_USER=testworker

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || true
print_info() { return 0; }
export -f print_info

# Source the REST fallback module under test.
# _rest_append_sig will call the stub via PATH lookup.
# shellcheck source=../shared-gh-wrappers-rest-fallback.sh
source "${SCRIPTS_DIR}/shared-gh-wrappers-rest-fallback.sh" || {
	printf 'FATAL: could not source shared-gh-wrappers-rest-fallback.sh\n' >&2
	exit 1
}

printf '%sRunning gh api sig-footer injection tests (t2707 / GH#20350)%s\n' \
	"$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 0: REST fallback dedup requires a standalone canonical marker line
# =============================================================================
_BODY0="${TMP}/body0.md"
printf 'Documentation mentions <!-- aidevops:sig --> inline.\n' >"$_BODY0"
_rest_append_sig "$_BODY0"
marker_count=$(grep -Fxc '<!-- aidevops:sig -->' "$_BODY0" 2>/dev/null || true)
if [[ "$marker_count" -eq 1 ]]; then
	pass "REST fallback signs a body containing an inline marker mention"
else
	fail "REST fallback signs a body containing an inline marker mention" \
		"standalone marker count was ${marker_count}, expected 1"
fi

# =============================================================================
# Test 1: _rest_issue_create injects sig into body file
# Use --body-file with a user-owned file so the translator doesn't clean it up
# (tmp_body_owned=0 when body_file is provided). We can then check the file
# contents after the call to confirm the sig was appended before the API call.
# =============================================================================
: >"$GH_CALLS"
_BODY1="${TMP}/body1.md"
printf 'Issue body for sig test.\n' >"$_BODY1"

_rest_issue_create \
	--repo "owner/repo" \
	--title "t2707: sig injection test" \
	--body-file "$_BODY1" >/dev/null 2>&1 || true

if grep -q "<!-- aidevops:sig -->" "$_BODY1" 2>/dev/null; then
	pass "_rest_issue_create injects <!-- aidevops:sig --> into body file"
else
	fail "_rest_issue_create injects <!-- aidevops:sig --> into body file" \
		"marker absent; file tail: $(tail -3 "$_BODY1" 2>/dev/null)"
fi

# =============================================================================
# Test 2: _rest_issue_comment injects sig into body file
# =============================================================================
: >"$GH_CALLS"
_BODY2="${TMP}/body2.md"
printf 'Comment body for sig test.\n' >"$_BODY2"

_rest_issue_comment 99 \
	--repo "owner/repo" \
	--body-file "$_BODY2" >/dev/null 2>&1 || true

if grep -q "<!-- aidevops:sig -->" "$_BODY2" 2>/dev/null; then
	pass "_rest_issue_comment injects <!-- aidevops:sig --> into body file"
else
	fail "_rest_issue_comment injects <!-- aidevops:sig --> into body file" \
		"marker absent; file tail: $(tail -3 "$_BODY2" 2>/dev/null)"
fi

# =============================================================================
# Test 3: _rest_pr_create injects sig into body file
# =============================================================================
: >"$GH_CALLS"
_BODY3="${TMP}/body3.md"
printf 'PR body for sig test.\n' >"$_BODY3"

_rest_pr_create \
	--repo "owner/repo" \
	--title "t2707: PR sig test" \
	--head "feature/t2707-test" \
	--base "main" \
	--body-file "$_BODY3" >/dev/null 2>&1 || true

if grep -q "<!-- aidevops:sig -->" "$_BODY3" 2>/dev/null; then
	pass "_rest_pr_create injects <!-- aidevops:sig --> into body file"
else
	fail "_rest_pr_create injects <!-- aidevops:sig --> into body file" \
		"marker absent; file tail: $(tail -3 "$_BODY3" 2>/dev/null)"
fi

# =============================================================================
# Layer 2 setup: source only the shim helper functions for direct unit tests.
# We cannot source the full `gh` shim script (it would exec), so we extract
# the functions via a wrapper that defines the required environment variables.
# =============================================================================

# Set up a stub SIG_HELPER variable (normally set by the shim at init time).
SIG_HELPER="$_STUB_SIG_HELPER"

# Source only the function definitions from the shim API guard library.
# The shim delegates these helpers to this adjacent module.
_SHIM_SCRIPT="${SCRIPTS_DIR}/gh-api-guards-lib.sh"

# Extract and define the helper plus its direct signature dependencies.
# This avoids executing the shim's main body which calls exec.
_SHIM_FUNCS=$(awk '
	/^_shim_api_is_write_endpoint\(\)/ { printing=1; depth=0 }
	/^_shim_body_is_ops_audit\(\)/      { printing=1; depth=0 }
	/^_shim_sig_footer_for_body\(\)/    { printing=1; depth=0 }
	/^_shim_api_inject_body_sig\(\)/   { printing=1; depth=0 }
	printing {
		print
		for(i=1;i<=length($0);i++) {
			c=substr($0,i,1)
			if(c=="{") depth++
			if(c=="}") depth--
		}
		if(depth==0 && printing) printing=0
	}
' "$_SHIM_SCRIPT") || true

if [[ -n "$_SHIM_FUNCS" ]]; then
	eval "$_SHIM_FUNCS" || true
fi

# Verify functions are defined before running shim tests.
if ! declare -f _shim_api_is_write_endpoint >/dev/null 2>&1; then
	printf '  %sWARN%s Shim helper functions not loadable — skipping Layer 2 tests\n' \
		"$TEST_RED" "$TEST_NC"
	# Count tests 4-6 as failures to ensure we notice if they can't run.
	TESTS_RUN=$((TESTS_RUN + 3))
	TESTS_FAILED=$((TESTS_FAILED + 3))
else

# =============================================================================
# Test 4: PATH shim injects sig on gh api -X POST /repos/X/Y/issues -f body=@file
# =============================================================================
_BODY4="${TMP}/body4.md"
printf 'Issue body without sig.\n' >"$_BODY4"

_modified_args=(api -X POST /repos/owner/repo/issues -f title=foo -f "body=@${_BODY4}")

if _shim_api_is_write_endpoint; then
	_shim_api_inject_body_sig
	if grep -q "<!-- aidevops:sig -->" "$_BODY4" 2>/dev/null; then
		pass "PATH shim injects sig on gh api -X POST /repos/X/Y/issues -f body=@file"
	else
		fail "PATH shim injects sig on gh api -X POST /repos/X/Y/issues -f body=@file" \
			"marker absent in body file after inject"
	fi
else
	fail "PATH shim injects sig on gh api -X POST /repos/X/Y/issues -f body=@file" \
		"_shim_api_is_write_endpoint returned false — endpoint not recognised"
fi

# =============================================================================
# Test 5: PATH shim injects sig on gh api -X POST /repos/X/Y/issues/N/comments -f body=@file
# =============================================================================
_BODY5="${TMP}/body5.md"
printf 'Comment body without sig.\n' >"$_BODY5"

_modified_args=(api -X POST /repos/owner/repo/issues/42/comments -f "body=@${_BODY5}")

if _shim_api_is_write_endpoint; then
	_shim_api_inject_body_sig
	if grep -q "<!-- aidevops:sig -->" "$_BODY5" 2>/dev/null; then
		pass "PATH shim injects sig on gh api -X POST /repos/X/Y/issues/N/comments -f body=@file"
	else
		fail "PATH shim injects sig on gh api -X POST /repos/X/Y/issues/N/comments -f body=@file" \
			"marker absent in body file after inject"
	fi
else
	fail "PATH shim injects sig on gh api -X POST /repos/X/Y/issues/N/comments -f body=@file" \
		"_shim_api_is_write_endpoint returned false"
fi

# =============================================================================
# Test 6: PATH shim leaves gh api /rate_limit (GET, no -X) untouched
# _shim_api_is_write_endpoint must return non-zero for a plain GET call.
# =============================================================================
_modified_args=(api rate_limit --jq .resources.graphql.remaining)

if ! _shim_api_is_write_endpoint; then
	pass "PATH shim leaves gh api /rate_limit (GET) untouched — is_write_endpoint returns false"
else
	fail "PATH shim leaves gh api /rate_limit (GET) untouched — is_write_endpoint returns false" \
		"_shim_api_is_write_endpoint returned true for a GET call — would incorrectly intercept"
fi

fi  # end of "if declare -f _shim_api_is_write_endpoint" block

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%s%d/%d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
