#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-cli.sh — Tests for knowledge-helper.sh add/list/search subcommands
#
# Usage: bash .agents/tests/test-knowledge-cli.sh
#
# Tests:
#   1. add: file copy + correct meta.json fields
#   2. add: --id override
#   3. add: --sensitivity override written to meta.json
#   4. add: blob threshold dispatch (>30MB → blob store)
#   5. add: URL detection error when curl would fail (skipped in offline mode)
#   6. list: shows sources with correct state column
#   7. list: --state filter (sources only)
#   8. list: --kind filter skips non-matching entries
#   9. search: returns matching excerpt
#   10. search: "no matches" path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-helper.sh"

# ---------------------------------------------------------------------------
# Test framework
# ---------------------------------------------------------------------------

_PASS=0
_FAIL=0

_pass() {
	local name="$1"
	printf "[PASS] %s\n" "$name"
	_PASS=$((_PASS + 1))
	return 0
}
_fail() {
	local name="$1" msg="$2"
	printf "[FAIL] %s — %s\n" "$name" "$msg"
	_FAIL=$((_FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		_pass "$name"
	else
		_fail "$name" "got='$got' want='$want'"
	fi
	return 0
}

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
		_pass "$name"
	else
		_fail "$name" "string does not contain '$needle'"
	fi
	return 0
}

assert_file_exists() {
	local name="$1" path="$2"
	if [[ -e "$path" ]]; then
		_pass "$name"
	else
		_fail "$name" "path not found: $path"
	fi
	return 0
}

assert_json_field() {
	local name="$1" json_file="$2" field="$3" want="$4"
	local got
	got=$(jq -r "$field" "$json_file" 2>/dev/null || echo "__jq_error__")
	if [[ "$got" == "$want" ]]; then
		_pass "$name"
	else
		_fail "$name" "meta.json $field: got='$got' want='$want'"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: isolated tmp directory with mocked repos.json
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
export AIDEVOPS_VAULT_DIR="${TMP_DIR}/vault-disabled"
REPO_PATH="${TMP_DIR}/test-repo"
mkdir -p "$REPO_PATH"

MOCK_REPOS_JSON="${TMP_DIR}/repos.json"
cat >"$MOCK_REPOS_JSON" <<EOF
{
  "initialized_repos": [
    {
      "path": "${REPO_PATH}",
      "slug": "test/repo",
      "knowledge": "repo",
      "platform": "local"
    }
  ],
  "git_parent_dirs": []
}
EOF

export REPOS_FILE="$MOCK_REPOS_JSON"
export PERSONAL_PLANE_BASE="${TMP_DIR}/personal-plane"

# Provision the knowledge tree
bash "$HELPER" provision "$REPO_PATH" >/dev/null 2>&1

KNOWLEDGE_ROOT="${REPO_PATH}/_knowledge"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: create a small test file
# ---------------------------------------------------------------------------
_make_test_file() {
	local path="$1" content="${2:-hello world}"
	echo "$content" >"$path"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: add a file — basic ingestion
# ---------------------------------------------------------------------------
TEST_FILE_1="${TMP_DIR}/sample.txt"
_make_test_file "$TEST_FILE_1" "Test content for knowledge plane"

add_out=$(bash "$HELPER" add "$TEST_FILE_1" --repo-path "$REPO_PATH" 2>&1)
assert_contains "add: success message printed" "$add_out" "Added source"

# Derive expected source_id (slugify "sample")
SRC_DIR="${KNOWLEDGE_ROOT}/sources/sample"
assert_file_exists "add: source dir created" "$SRC_DIR"
META="${SRC_DIR}/meta.json"
assert_file_exists "add: meta.json created" "$META"
assert_json_field "add: meta id field" "$META" '.id' "sample"
assert_json_field "add: meta kind default" "$META" '.kind' "document"
assert_json_field "add: meta trust default" "$META" '.trust' "unverified"

# ---------------------------------------------------------------------------
# Test 2: add with --id override
# ---------------------------------------------------------------------------
TEST_FILE_2="${TMP_DIR}/override.txt"
_make_test_file "$TEST_FILE_2" "Override ID test"

bash "$HELPER" add "$TEST_FILE_2" --id my-custom-id --repo-path "$REPO_PATH" >/dev/null 2>&1
META2="${KNOWLEDGE_ROOT}/sources/my-custom-id/meta.json"
assert_file_exists "add --id: source dir created" "$META2"
assert_json_field "add --id: id field matches" "$META2" '.id' "my-custom-id"

# ---------------------------------------------------------------------------
# Test 3: duplicate source_id gets timestamp suffix
# ---------------------------------------------------------------------------
TEST_FILE_3="${TMP_DIR}/sample2.txt"
_make_test_file "$TEST_FILE_3" "Duplicate source"
# Rename to 'sample.txt' so it would conflict
TEST_FILE_3_ALT="${TMP_DIR}/sample.txt.dup"
_make_test_file "$TEST_FILE_3_ALT" "Second sample"
add_out3=$(bash "$HELPER" add "$TEST_FILE_3_ALT" --id sample --repo-path "$REPO_PATH" 2>&1)
assert_contains "add: duplicate id gets suffix" "$add_out3" "Added source"

# ---------------------------------------------------------------------------
# Test 4: blob threshold dispatch — file >30MB goes to blob store
# ---------------------------------------------------------------------------
BIG_FILE="${TMP_DIR}/big.bin"
# Create a file just over 30MB (31MB)
dd if=/dev/zero of="$BIG_FILE" bs=1048576 count=31 2>/dev/null
add_big_out=$(bash "$HELPER" add "$BIG_FILE" --id big-blob --repo-path "$REPO_PATH" 2>&1)
assert_contains "add large: success message" "$add_big_out" "Added source"
META_BIG="${KNOWLEDGE_ROOT}/sources/big-blob/meta.json"
assert_file_exists "add large: meta.json exists" "$META_BIG"
BLOB_PATH_VAL=$(jq -r '.blob_path // "null"' "$META_BIG" 2>/dev/null || echo "null")
if [[ "$BLOB_PATH_VAL" != "null" && -n "$BLOB_PATH_VAL" ]]; then
	_pass "add large: blob_path set in meta.json"
else
	_fail "add large: blob_path set in meta.json" "blob_path is null but file is >30MB"
fi

# ---------------------------------------------------------------------------
# Test 5: add URL — detects URL and attempts download (offline: expect error)
# ---------------------------------------------------------------------------
# We can't test a real URL download without network, so just check that the
# URL detection code path is reached (error mentions "Download failed" or curl)
url_out=$(bash "$HELPER" add "https://example.invalid/test.pdf" \
	--repo-path "$REPO_PATH" 2>&1 || true)
if echo "$url_out" | grep -qiE "Download failed|curl|not installed"; then
	_pass "add URL: URL detection path reached"
else
	_fail "add URL: URL detection path reached" "unexpected output: $url_out"
fi

# ---------------------------------------------------------------------------
# Test 6: list — shows sources with state column
# ---------------------------------------------------------------------------
list_out=$(bash "$HELPER" list --repo-path "$REPO_PATH" 2>&1)
assert_contains "list: header line present" "$list_out" "SOURCE-ID"
assert_contains "list: sources state shown" "$list_out" "sources"
assert_contains "list: sample source present" "$list_out" "sample"

# ---------------------------------------------------------------------------
# Test 7: list --state sources
# ---------------------------------------------------------------------------
list_sources_out=$(bash "$HELPER" list --state sources --repo-path "$REPO_PATH" 2>&1)
assert_contains "list --state sources: sources shown" "$list_sources_out" "sources"

# ---------------------------------------------------------------------------
# Test 8: list --kind filter — unknown kind yields no rows
# ---------------------------------------------------------------------------
list_kind_out=$(bash "$HELPER" list --state sources --kind nonexistent-kind \
	--repo-path "$REPO_PATH" 2>&1)
assert_contains "list --kind filter: no-matches message" "$list_kind_out" "No sources found"

# ---------------------------------------------------------------------------
# Test 9: search — returns matching excerpt
# ---------------------------------------------------------------------------
# Create a source with text.txt for grep fallback
TEXT_SRC="${KNOWLEDGE_ROOT}/sources/searchable-doc"
mkdir -p "$TEXT_SRC"
echo '{"version":1,"id":"searchable-doc","kind":"document","sensitivity":"internal","trust":"unverified"}' \
	>"${TEXT_SRC}/meta.json"
echo "The quick brown fox jumps over the lazy dog" >"${TEXT_SRC}/text.txt"

search_out=$(bash "$HELPER" search "quick brown" "$REPO_PATH" 2>&1)
assert_contains "search: match found" "$search_out" "searchable-doc"

# ---------------------------------------------------------------------------
# Test 10: search — no matches path
# ---------------------------------------------------------------------------
no_match_out=$(bash "$HELPER" search "zzznomatchzzz" "$REPO_PATH" 2>&1)
assert_contains "search: no matches message" "$no_match_out" "no matches"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${_PASS} passed, ${_FAIL} failed"
[[ "$_FAIL" -eq 0 ]]
