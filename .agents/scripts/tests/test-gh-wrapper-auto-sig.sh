#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for _gh_wrapper_auto_sig (t2115) in shared-constants.sh
# =============================================================================
# Validates that the gh_create_issue/gh_create_pr wrappers auto-append
# signature footers to --body/--body-file when missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

# Pull in _test_copy_shared_deps / _test_source_shared_deps (t2431).
# Without this, copying only shared-constants.sh into a tmpdir causes the
# transitive `source "${_SC_SELF%/*}/shared-gh-wrappers.sh"` directive to
# fail, leaving every assertion below silently skipped.
# shellcheck source=./lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

PASS=0
FAIL=0

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== _gh_wrapper_auto_sig tests (t2115) ==="
echo ""

# Set up a temp dir with a stubbed gh-signature-helper.sh so we control output
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d -t autosig)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Create a stub gh-signature-helper.sh that returns a predictable footer
cat >"${TMPDIR_TEST}/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
# Stub signature helper for testing
cmd="$1"; shift
if [[ "$cmd" == "footer" ]]; then
    # Skip --body arg parsing for the stub — just emit the footer
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --body) shift ;; # skip body value
        *) ;;
        esac
        shift
    done
    printf '\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) v0.0.0-test stub footer.\n'
fi
exit 0
STUB
chmod +x "${TMPDIR_TEST}/gh-signature-helper.sh"

# Copy shared-constants.sh AND every sub-library it sources (shared-gh-wrappers.sh,
# shared-feature-toggles.sh, ...) to the temp dir. BASH_SOURCE in the copy then
# resolves the stub gh-signature-helper.sh AND every chained `source` directive.
# Use _test_copy_shared_deps rather than a bare `cp shared-constants.sh` (t2431).
_test_copy_shared_deps "$PARENT_DIR" "$TMPDIR_TEST" || exit 1
_test_source_shared_deps "$TMPDIR_TEST" || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: --body without signature gets footer appended
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: --body without signature gets footer appended"
_gh_wrapper_auto_sig --repo "owner/repo" --title "test" --body "Hello world" --label "bug"
result="${_GH_WRAPPER_SIG_MODIFIED_ARGS[*]}"
assert_contains "body now has signature marker" "<!-- aidevops:sig -->" "$result"

# Extract the actual body value (it's the arg after --body)
body_val=""
for ((i = 0; i < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}; i++)); do
	if [[ "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" == "--body" ]]; then
		body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]}"
		break
	fi
done
assert_contains "body starts with original content" "Hello world" "$body_val"
assert_contains "body has footer" "stub footer" "$body_val"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: --body with existing signature is NOT modified
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: --body with existing signature is NOT modified"
original_body="Hello world
<!-- aidevops:sig -->
---
existing signature"
_gh_wrapper_auto_sig --repo "owner/repo" --title "test" --body "$original_body"
body_val=""
for ((i = 0; i < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}; i++)); do
	if [[ "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" == "--body" ]]; then
		body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]}"
		break
	fi
done
assert_eq "body unchanged when already signed" "$original_body" "$body_val"
assert_not_contains "no stub footer appended" "stub footer" "$body_val"

# Inline documentation of the marker is not a completed footer.
inline_marker_body="Documentation mentions <!-- aidevops:sig --> inline"
_gh_wrapper_auto_sig --repo "owner/repo" --title "test" --body "$inline_marker_body"
body_val=""
for ((i = 0; i < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}; i++)); do
	if [[ "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" == "--body" ]]; then
		body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]}"
		break
	fi
done
marker_count=$(grep -Fxc '<!-- aidevops:sig -->' <<<"$body_val" || true)
assert_eq "inline marker prose receives one standalone marker" "1" "$marker_count"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: --body=VALUE form (equals syntax)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: --body=VALUE form gets footer appended"
_gh_wrapper_auto_sig --repo "owner/repo" --body="No signature here"
body_val=""
for ((i = 0; i < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}; i++)); do
	case "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" in
	--body=*)
		body_val="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]#--body=}"
		break
		;;
	esac
done
assert_contains "equals-form body has signature" "<!-- aidevops:sig -->" "$body_val"
assert_contains "equals-form body has original content" "No signature here" "$body_val"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: --body-file gets footer appended to temp copy
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: --body-file gets footer appended to temp copy"
body_file="${TMPDIR_TEST}/test-body.md"
printf 'Issue body from file' >"$body_file"
_gh_wrapper_auto_sig --repo "owner/repo" --title "test" --body-file "$body_file"
file_content=$(<"$body_file")
assert_not_contains "original file is not mutated" "<!-- aidevops:sig -->" "$file_content"
assert_contains "original file keeps original content" "Issue body from file" "$file_content"
signed_body_file=""
for ((i = 0; i < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]}; i++)); do
	if [[ "${_GH_WRAPPER_SIG_MODIFIED_ARGS[i]}" == "--body-file" ]]; then
		if ((i + 1 < ${#_GH_WRAPPER_SIG_MODIFIED_ARGS[@]})); then
			signed_body_file="${_GH_WRAPPER_SIG_MODIFIED_ARGS[i + 1]}"
		fi
		break
	fi
done
if [[ -z "$signed_body_file" ]]; then
	echo "  FAIL: --body-file flag not found in modified args"
	FAIL=$((FAIL + 1))
elif [[ "$signed_body_file" == "$body_file" ]]; then
	echo "  FAIL: wrapper used original file instead of temp copy"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: wrapper points gh at a temp body file"
	PASS=$((PASS + 1))
	signed_file_content=$(<"$signed_body_file")
	assert_contains "temp body has signature marker" "<!-- aidevops:sig -->" "$signed_file_content"
	assert_contains "temp body has original content" "Issue body from file" "$signed_file_content"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: --body-file with existing signature is NOT modified
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: --body-file with existing signature is NOT modified"
body_file2="${TMPDIR_TEST}/test-body-signed.md"
printf 'Already signed\n<!-- aidevops:sig -->\n---\nexisting' >"$body_file2"
original_size=$(wc -c <"$body_file2" | tr -d ' ')
_gh_wrapper_auto_sig --repo "owner/repo" --body-file "$body_file2"
new_size=$(wc -c <"$body_file2" | tr -d ' ')
assert_eq "file size unchanged when already signed" "$original_size" "$new_size"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: no --body or --body-file leaves args unchanged
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: no body args leaves everything unchanged"
_gh_wrapper_auto_sig --repo "owner/repo" --title "test" --label "bug"
result="${_GH_WRAPPER_SIG_MODIFIED_ARGS[*]}"
assert_not_contains "no signature injected without body" "aidevops:sig" "$result"
assert_contains "args preserved" "--repo owner/repo --title test --label bug" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: other args preserved after body modification
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: non-body args preserved"
_gh_wrapper_auto_sig --repo "owner/repo" --title "My Title" --body "content" --label "enhancement"
# Check that --repo, --title, --label are all still present
result="${_GH_WRAPPER_SIG_MODIFIED_ARGS[*]}"
assert_contains "repo preserved" "--repo owner/repo" "$result"
assert_contains "title preserved" "--title My Title" "$result"
assert_contains "label preserved" "--label enhancement" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8 (t2393): gh_issue_comment and gh_pr_comment wrappers exist
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: gh_issue_comment and gh_pr_comment wrappers are defined"
if declare -F gh_issue_comment >/dev/null 2>&1; then
	echo "  PASS: gh_issue_comment is defined"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh_issue_comment is not defined"
	FAIL=$((FAIL + 1))
fi
if declare -F gh_pr_comment >/dev/null 2>&1; then
	echo "  PASS: gh_pr_comment is defined"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh_pr_comment is not defined"
	FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 9 (t2393): stub gh and verify gh_issue_comment appends sig, delegates
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9 (t2393): gh_issue_comment appends sig and delegates to gh"
# Install a PATH-shadowing gh stub that records argv to a file.
STUB_DIR="${TMPDIR_TEST}/stub-bin"
mkdir -p "$STUB_DIR"
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Record "argv" to a captured-args file for assertions.
printf '%s\n' "$@" >"${GH_STUB_ARGS_FILE:-/dev/null}"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--body-file)
		if [[ -n "${2:-}" && -f "$2" && -n "${GH_STUB_BODY_FILE_CONTENT:-}" ]]; then
			cat "$2" >"$GH_STUB_BODY_FILE_CONTENT"
		fi
		shift 2
		;;
	*)
		shift
		;;
	esac
done
# Simulate success.
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
export PATH="${STUB_DIR}:$PATH"
export GH_STUB_ARGS_FILE="${TMPDIR_TEST}/gh-args.txt"
export GH_STUB_BODY_FILE_CONTENT="${TMPDIR_TEST}/gh-body-file-content.txt"

: >"$GH_STUB_ARGS_FILE"
gh_issue_comment 19951 --repo "owner/repo" --body "Issue comment body"
captured=$(<"$GH_STUB_ARGS_FILE")
assert_contains "gh received issue verb" "issue" "$captured"
assert_contains "gh received comment verb" "comment" "$captured"
assert_contains "gh received repo slug" "owner/repo" "$captured"
assert_contains "gh received body with signature" "<!-- aidevops:sig -->" "$captured"
assert_contains "gh received original content" "Issue comment body" "$captured"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10 (t2393): gh_pr_comment delegates and dedups when body already signed
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10 (t2393): gh_pr_comment dedups when body already signed"
pre_signed_body="PR comment body
<!-- aidevops:sig -->
---
already signed"
: >"$GH_STUB_ARGS_FILE"
gh_pr_comment 19999 --repo "owner/repo" --body "$pre_signed_body"
captured=$(<"$GH_STUB_ARGS_FILE")
assert_contains "gh received pr verb" "pr" "$captured"
assert_contains "gh received comment verb (pr)" "comment" "$captured"
# Count occurrences of the sig marker in the captured body
marker_count=$(grep -c 'aidevops:sig' <<<"$captured" || true)
assert_eq "marker appears exactly once (no double-sign)" "1" "$marker_count"

# ─────────────────────────────────────────────────────────────────────────────
# Test 11 (t2393): gh_issue_comment with --body-file signs temp copy
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 11 (t2393): gh_issue_comment --body-file signs temp copy"
bf="${TMPDIR_TEST}/issue-body.md"
printf 'Body from file cites aidevops.sh:1715' >"$bf"
: >"$GH_STUB_ARGS_FILE"
: >"$GH_STUB_BODY_FILE_CONTENT"
gh_issue_comment 19951 --repo "owner/repo" --body-file "$bf"
file_content=$(<"$bf")
assert_not_contains "original file did not get signature footer" "<!-- aidevops:sig -->" "$file_content"
assert_contains "original file still has root script reference" "aidevops.sh:1715" "$file_content"
captured=$(<"$GH_STUB_ARGS_FILE")
assert_contains "gh received --body-file flag" "--body-file" "$captured"
captured_body_file=""
while IFS= read -r arg; do
	if [[ "$captured_body_file" == "pending" ]]; then
		captured_body_file="$arg"
		break
	fi
	if [[ "$arg" == "--body-file" ]]; then
		captured_body_file="pending"
	fi
done <<<"$captured"

if [[ -z "$captured_body_file" || "$captured_body_file" == "pending" ]]; then
	echo "  FAIL: gh did not receive --body-file flag or value"
	FAIL=$((FAIL + 1))
elif [[ "$captured_body_file" == "$bf" ]]; then
	echo "  FAIL: gh received original body-file path instead of temp copy"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: gh received a different body-file path"
	PASS=$((PASS + 1))
	if [[ -e "$captured_body_file" ]]; then
		FAIL=$((FAIL + 1))
		echo "  FAIL: temp body-file cleaned up after gh returned"
	else
		PASS=$((PASS + 1))
		echo "  PASS: temp body-file cleaned up after gh returned"
	fi
	captured_file_content=$(<"$GH_STUB_BODY_FILE_CONTENT")
	assert_contains "gh received temp body-file with signature" "<!-- aidevops:sig -->" "$captured_file_content"
	assert_contains "gh received temp body-file with root script reference" "aidevops.sh:1715" "$captured_file_content"
	marker_count=$(grep -Fxc '<!-- aidevops:sig -->' <<<"$captured_file_content" || true)
	assert_eq "gh received exactly one standalone marker line" "1" "$marker_count"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 12 (t2393): exit code from gh is propagated through the wrapper
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 12 (t2393): wrapper propagates gh exit code"
# Replace the stub with one that exits 42
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${GH_STUB_ARGS_FILE:-/dev/null}"
exit 42
STUB
chmod +x "${STUB_DIR}/gh"

rc=0
gh_pr_comment 19999 --repo "owner/repo" --body "test" || rc=$?
assert_eq "exit code 42 propagated from gh through gh_pr_comment" "42" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
