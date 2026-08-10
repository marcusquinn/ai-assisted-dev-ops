#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for t2393: marker-dedup survives wrapper signature-footer append
# =============================================================================
# _gh_idempotent_comment (pulse-triage.sh) and several other pulse callers
# embed an HTML marker at the TOP of a comment body, then grep for that
# marker on subsequent runs to decide whether the comment is already posted
# (idempotency). After t2393 wraps all comments through gh_{issue,pr}_comment,
# the wrapper appends a signature footer to the END of the body. This test
# proves the marker-dedup readers still match because:
#
#   - The marker lives at the top.
#   - `grep -qF "$marker"` does a substring match anywhere in the body.
#   - A footer appended at the end does not affect a top-anchored substring.
#
# Covers both --body and --body-file wrapper paths.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

# Pull in _test_copy_shared_deps / _test_source_shared_deps (t2431). See
# lib/test-helpers.sh for the "copy shared-constants.sh + siblings" rationale.
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

assert_grep_finds() {
	local test_name="$1"
	local marker="$2"
	local body="$3"
	if printf '%s' "$body" | grep -qF "$marker"; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected grep -qF to match marker: $marker"
		echo "    in body: $body"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== comment-wrapper marker-dedup regression (t2393) ==="
echo ""

# Setup: a test harness that stubs gh-signature-helper.sh to emit a
# predictable footer, and stubs `gh` to capture argv.
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d -t cmtdedup)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cat >"${TMPDIR_TEST}/gh-signature-helper.sh" <<'STUB'
#!/usr/bin/env bash
cmd="$1"; shift
if [[ "$cmd" == "footer" ]]; then
    # Skip --body parsing; always emit a predictable footer
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --body) shift ;;
        *) ;;
        esac
        shift
    done
    printf '\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) v0.0.0-test footer.\n'
fi
exit 0
STUB
chmod +x "${TMPDIR_TEST}/gh-signature-helper.sh"

# Copy shared-constants.sh AND every sibling it sources (shared-gh-wrappers.sh,
# shared-feature-toggles.sh, ...) — see .agents/scripts/tests/lib/test-helpers.sh.
_test_copy_shared_deps "$PARENT_DIR" "$TMPDIR_TEST" || exit 1

STUB_DIR="${TMPDIR_TEST}/stub-bin"
mkdir -p "$STUB_DIR"
cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
# Capture the final body the wrapper hands to gh.
# Walk argv looking for --body/--body-file and dump the value.
while [[ $# -gt 0 ]]; do
    case "$1" in
    --body)
        printf '%s' "${2:-}" >"${GH_STUB_BODY_FILE:-/dev/null}"
        shift 2
        ;;
    --body=*)
        printf '%s' "${1#--body=}" >"${GH_STUB_BODY_FILE:-/dev/null}"
        shift
        ;;
    --body-file)
        # Dump the file contents for assertions
        cat "${2:-/dev/null}" >"${GH_STUB_BODY_FILE:-/dev/null}" 2>/dev/null || true
        shift 2
        ;;
    --body-file=*)
        cat "${1#--body-file=}" >"${GH_STUB_BODY_FILE:-/dev/null}" 2>/dev/null || true
        shift
        ;;
    *) shift ;;
    esac
done
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
export PATH="${STUB_DIR}:$PATH"
export GH_STUB_BODY_FILE="${TMPDIR_TEST}/gh-body.txt"

_test_source_shared_deps "$TMPDIR_TEST" || exit 1

# This unit test isolates signature marker preservation. Public transport
# de-identification is covered by test-gh-wrapper-public-deidentification.sh.
privacy_guard_public_write() { return 0; }

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1: marker at the top of --body, wrapper appends sig, grep still finds
# ─────────────────────────────────────────────────────────────────────────────
echo "Scenario 1: top-marker + --body survives wrapper sig-append"
marker="<!-- pulse-consolidation-gate -->"
comment_body="${marker}
## Issue Consolidation Needed

Body content here."
: >"$GH_STUB_BODY_FILE"
gh_issue_comment 19951 --repo "owner/repo" --body "$comment_body"
captured_body=$(<"$GH_STUB_BODY_FILE")
assert_contains "sig footer appended" "<!-- aidevops:sig -->" "$captured_body"
assert_contains "original body preserved" "## Issue Consolidation Needed" "$captured_body"
assert_grep_finds "marker still found by grep -qF" "$marker" "$captured_body"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2: marker at the top of --body-file, wrapper signs a temp copy;
# grep on both original and submitted contents still finds marker
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 2: top-marker + --body-file survives wrapper sig-append"
bf="${TMPDIR_TEST}/gate-body.md"
marker2="<!-- pulse-large-file-gate -->"
cat >"$bf" <<EOF
${marker2}
## Large File Gate

Acting on a PR that added a >500 line file.
EOF
: >"$GH_STUB_BODY_FILE"
gh_pr_comment 19999 --repo "owner/repo" --body-file "$bf"
file_content=$(<"$bf")
captured_body=$(<"$GH_STUB_BODY_FILE")
assert_not_contains "original file was not mutated" "<!-- aidevops:sig -->" "$file_content"
assert_contains "original file content preserved" "## Large File Gate" "$file_content"
assert_grep_finds "marker still found in file via grep -qF" "$marker2" "$file_content"
assert_contains "sig footer appended to gh body" "<!-- aidevops:sig -->" "$captured_body"
assert_grep_finds "marker still found in body gh received" "$marker2" "$captured_body"

# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3: already-signed body (idempotent second call) — no double sig,
# marker still findable
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Scenario 3: pre-signed body is not double-signed, marker survives"
marker3="<!-- pulse-terminal-blocker -->"
pre_signed="${marker3}
## Terminal blocker detected

Body content.

<!-- aidevops:sig -->
---
pre-existing sig"
: >"$GH_STUB_BODY_FILE"
gh_issue_comment 19951 --repo "owner/repo" --body "$pre_signed"
captured_body=$(<"$GH_STUB_BODY_FILE")
sig_count=$(grep -c 'aidevops:sig' <<<"$captured_body" || true)
if [[ "$sig_count" == "1" ]]; then
	echo "  PASS: marker appears exactly once — no double-sign"
	PASS=$((PASS + 1))
else
	echo "  FAIL: expected exactly 1 aidevops:sig marker, got $sig_count"
	echo "    body: $captured_body"
	FAIL=$((FAIL + 1))
fi
assert_grep_finds "consumer marker still findable" "$marker3" "$captured_body"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
