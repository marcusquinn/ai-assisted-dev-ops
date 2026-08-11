#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Meta-test for tests/lib/test-helpers.sh (t2431)
# =============================================================================
# Verifies:
#  1. `_test_discover_shared_deps` finds every sibling file sourced by
#     shared-constants.sh (auto-stays-in-sync when new siblings are added).
#  2. `_test_copy_shared_deps` copies all discovered deps into a fresh tmpdir
#     AND returns a non-zero exit + clear error when a dep is missing from
#     the source tree (so future splits cannot introduce the "silent green"
#     regression class).
#  3. `_test_source_shared_deps` loads the copied orchestrator and the
#     wrapper functions (`gh_create_pr`, `gh_create_issue`, `gh_issue_comment`,
#     `gh_pr_comment`, `_gh_wrapper_auto_sig`) are callable after setup.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

# shellcheck source=./lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

PASS=0
FAIL=0

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

assert_nonzero() {
	local test_name="$1"
	local actual="$2"
	if [[ "$actual" -ne 0 ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name — expected non-zero exit"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_func_defined() {
	local test_name="$1"
	local func="$2"
	if declare -F "$func" >/dev/null 2>&1; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name — function $func not defined after setup"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== tests/lib/test-helpers.sh meta-test (t2431) ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: discovery returns at least one sibling (parser is not silently empty)
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: _test_discover_shared_deps returns sibling file list"
deps_output=$(_test_discover_shared_deps "$PARENT_DIR")
dep_count=0
if [[ -n "$deps_output" ]]; then
	dep_count=$(printf '%s\n' "$deps_output" | wc -l | tr -d ' ')
fi
if [[ "$dep_count" -ge 1 ]]; then
	echo "  PASS: at least one sibling discovered ($dep_count found)"
	PASS=$((PASS + 1))
else
	echo "  FAIL: _test_discover_shared_deps returned no siblings — parser broken?"
	FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: every discovered sibling exists on disk
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: every discovered sibling exists on disk"
missing=0
while IFS= read -r sibling; do
	[[ -z "$sibling" ]] && continue
	if [[ ! -f "${PARENT_DIR}/${sibling}" ]]; then
		echo "  FAIL: sibling $sibling cited in shared-constants.sh but missing"
		missing=$((missing + 1))
	fi
done <<<"$deps_output"

assert_eq "all discovered siblings exist on disk" "0" "$missing"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: copy succeeds and all discovered files land in dest
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: _test_copy_shared_deps copies orchestrator + every sibling"
tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t helpertest)
# shellcheck disable=SC2064  # expand at trap-set time; we want $tmpdir captured now
trap "rm -rf '$tmpdir'" EXIT

if _test_copy_shared_deps "$PARENT_DIR" "$tmpdir"; then
	echo "  PASS: _test_copy_shared_deps returned 0"
	PASS=$((PASS + 1))
else
	echo "  FAIL: _test_copy_shared_deps returned non-zero"
	FAIL=$((FAIL + 1))
fi

# Verify shared-constants.sh landed
if [[ -f "${tmpdir}/shared-constants.sh" ]]; then
	echo "  PASS: shared-constants.sh landed in tmpdir"
	PASS=$((PASS + 1))
else
	echo "  FAIL: shared-constants.sh missing from tmpdir"
	FAIL=$((FAIL + 1))
fi

# Verify each discovered sibling landed
while IFS= read -r sibling; do
	[[ -z "$sibling" ]] && continue
	if [[ -f "${tmpdir}/${sibling}" ]]; then
		echo "  PASS: $sibling landed in tmpdir"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $sibling missing from tmpdir"
		FAIL=$((FAIL + 1))
	fi
done <<<"$deps_output"

if [[ -f "${tmpdir}/privacy-guard-helper.sh" ]]; then
	echo "  PASS: privacy-guard-helper.sh landed in tmpdir"
	PASS=$((PASS + 1))
else
	echo "  FAIL: privacy-guard-helper.sh missing from tmpdir"
	FAIL=$((FAIL + 1))
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: sourcing the copy succeeds and wrappers are callable
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: _test_source_shared_deps loads orchestrator + wrappers are defined"
if _test_source_shared_deps "$tmpdir"; then
	echo "  PASS: _test_source_shared_deps returned 0"
	PASS=$((PASS + 1))
else
	echo "  FAIL: _test_source_shared_deps returned non-zero"
	FAIL=$((FAIL + 1))
fi

assert_func_defined "gh_create_pr defined after source" "gh_create_pr"
assert_func_defined "gh_create_issue defined after source" "gh_create_issue"
assert_func_defined "gh_issue_comment defined after source" "gh_issue_comment"
assert_func_defined "gh_pr_comment defined after source" "gh_pr_comment"
assert_func_defined "_gh_wrapper_auto_sig defined after source" "_gh_wrapper_auto_sig"
assert_func_defined "privacy_guard_public_write defined after source" "privacy_guard_public_write"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: copy fails loudly when a dep is missing (simulate future split with
#         incomplete sync).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: _test_copy_shared_deps fails when a dep is missing from src_dir"

# Build a synthetic src_dir with shared-constants.sh that cites a phantom file.
fake_src=$(mktemp -d 2>/dev/null || mktemp -d -t fakesrc)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir' '$fake_src'" EXIT

cat >"${fake_src}/shared-constants.sh" <<'EOF'
#!/usr/bin/env bash
_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
source "${_SC_SELF%/*}/phantom-sibling.sh"
EOF

fake_dest=$(mktemp -d 2>/dev/null || mktemp -d -t fakedest)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir' '$fake_src' '$fake_dest'" EXIT

rc=0
_test_copy_shared_deps "$fake_src" "$fake_dest" 2>/dev/null || rc=$?
assert_nonzero "copy rejects phantom dep" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: discover returns empty (not an error) when shared-constants.sh has
#         no sibling sources — required so the contract is "presence of deps
#         is data, not truth-of-existence".
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: discovery returns empty list for shared-constants.sh with no siblings"
empty_src=$(mktemp -d 2>/dev/null || mktemp -d -t emptysrc)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir' '$fake_src' '$fake_dest' '$empty_src'" EXIT
cat >"${empty_src}/shared-constants.sh" <<'EOF'
#!/usr/bin/env bash
# Hypothetical orchestrator with no sub-library sources.
echo "hello"
EOF

out=$(_test_discover_shared_deps "$empty_src")
assert_eq "no deps discovered for simple orchestrator" "" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: discover ignores conditional sources (guarded by [[ -r ... ]])
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: conditional sources are ignored (not reported as deps)"
cond_src=$(mktemp -d 2>/dev/null || mktemp -d -t condsrc)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir' '$fake_src' '$fake_dest' '$empty_src' '$cond_src'" EXIT
cat >"${cond_src}/shared-constants.sh" <<'EOF'
#!/usr/bin/env bash
_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# Unconditional source — SHOULD be discovered
source "${_SC_SELF%/*}/real-sibling.sh"
# Conditional source — should NOT be discovered
_MAYBE="${_SC_SELF%/*}/optional-sibling.sh"
if [[ -r "$_MAYBE" ]]; then
	source "$_MAYBE"
fi
EOF
out=$(_test_discover_shared_deps "$cond_src")
assert_eq "only unconditional source discovered" "real-sibling.sh" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: discover tolerates trailing comments with URL/path slashes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: trailing comments with URL/path slashes do not corrupt basename parsing"
comment_src=$(mktemp -d 2>/dev/null || mktemp -d -t commentsrc)
# shellcheck disable=SC2064
trap "rm -rf '$tmpdir' '$fake_src' '$fake_dest' '$empty_src' '$cond_src' '$comment_src'" EXIT
cat >"${comment_src}/shared-constants.sh" <<'EOF'
#!/usr/bin/env bash
_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
source "${_SC_SELF%/*}/real-sibling.sh" # fallback/retry docs/path
_source_shared_module_with_retry "${_SC_SELF%/*}/retry-sibling.sh" # https://example.invalid/fallback/retry
EOF

out=$(_test_discover_shared_deps "$comment_src")
assert_eq "comments with URL/path slashes do not affect discovered basenames" $'real-sibling.sh\nretry-sibling.sh' "$out"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
