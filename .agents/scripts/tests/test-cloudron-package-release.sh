#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../cloudron-package-helper.sh"
TEST_ROOT=""
PASSED=0
FAILED=0
PINNED_BASE='cloudron/base:5.1.0@sha256:1c0666c9abe9e2090d33686826d4e97769b799124573118d41e0d7485135748e'

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

pass() {
	local description="$1"
	printf 'PASS %s\n' "$description"
	PASSED=$((PASSED + 1))
	return 0
}

fail() {
	local description="$1"
	printf 'FAIL %s\n' "$description" >&2
	FAILED=$((FAILED + 1))
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	[[ "$expected" == "$actual" ]] && pass "$description" || fail "$description (expected=$expected actual=$actual)"
	return 0
}

make_fixture() {
	local repo_dir="$1"
	mkdir -p "$repo_dir"
	cat >"${repo_dir}/CloudronManifest.json" <<'JSON'
{
  "id": "com.example.package",
  "title": "Example Package",
  "version": "1.0.0",
  "upstreamVersion": "4.0.0",
  "healthCheckPath": "/",
  "httpPort": 8000,
  "manifestVersion": 2,
  "addons": {"localstorage": {}}
}
JSON
	printf 'FROM %s\nCMD ["/app/code/start.sh"]\n' "$PINNED_BASE" >"${repo_dir}/Dockerfile"
	cat >"${repo_dir}/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [1.0.0] - 2026-01-01

- Initial package.
CHANGELOG
	printf '%s\n' '- Package upstream 4.5.6 and refresh compatibility checks.' >"${repo_dir}/release-notes.md"
	return 0
}

run_helper() {
	local repo_dir="$1"
	shift
	(cd "$repo_dir" && bash "$HELPER" "$@")
	return $?
}

test_prepare_and_validate_release() {
	local repo_dir="${TEST_ROOT}/valid"
	make_fixture "$repo_dir"
	if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 release-notes.md >/dev/null; then
		pass "valid release preparation succeeds"
	else
		fail "valid release preparation succeeds"
	fi
	assert_equal 1.2.0 "$(jq -r '.version' "${repo_dir}/CloudronManifest.json")" "package version updated"
	assert_equal 4.5.6 "$(jq -r '.upstreamVersion' "${repo_dir}/CloudronManifest.json")" "upstream version updated"
	grep -Fq '## [1.2.0]' "${repo_dir}/CHANGELOG.md" && pass "changelog release heading added" || fail "changelog release heading added"
	grep -Fq 'Package upstream 4.5.6' "${repo_dir}/CHANGELOG.md" && pass "non-empty release notes added" || fail "non-empty release notes added"
	run_helper "$repo_dir" check-release v1.2.0 >/dev/null && pass "matching tag validates" || fail "matching tag validates"
	if run_helper "$repo_dir" check-release v1.2.1 >/dev/null 2>&1; then
		fail "mismatched tag rejected"
	else
		pass "mismatched tag rejected"
	fi
	return 0
}

test_invalid_prepare_is_non_mutating() {
	local repo_dir="${TEST_ROOT}/invalid"
	make_fixture "$repo_dir"
	local manifest_before=""
	local changelog_before=""
	manifest_before=$(cksum "${repo_dir}/CloudronManifest.json")
	changelog_before=$(cksum "${repo_dir}/CHANGELOG.md")
	if run_helper "$repo_dir" prepare-release invalid 4.5.6 release-notes.md >/dev/null 2>&1; then
		fail "malformed package version rejected"
	else
		pass "malformed package version rejected"
	fi
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "invalid preparation preserves manifest"
	assert_equal "$changelog_before" "$(cksum "${repo_dir}/CHANGELOG.md")" "invalid preparation preserves changelog"
	: >"${repo_dir}/empty-notes.md"
	if run_helper "$repo_dir" prepare-release 1.2.0 4.5.6 empty-notes.md >/dev/null 2>&1; then
		fail "empty release notes rejected"
	else
		pass "empty release notes rejected"
	fi
	assert_equal "$manifest_before" "$(cksum "${repo_dir}/CloudronManifest.json")" "empty notes preserve manifest"
	return 0
}

test_release_gate_rejects_package_defects() {
	local repo_dir="${TEST_ROOT}/defects"
	make_fixture "$repo_dir"
	printf 'FROM cloudron/base:5.1.0\n' >"${repo_dir}/Dockerfile"
	if run_helper "$repo_dir" check-release v1.0.0 >/dev/null 2>&1; then
		fail "unpinned final Cloudron base rejected"
	else
		pass "unpinned final Cloudron base rejected"
	fi
	printf '{invalid\n' >"${repo_dir}/CloudronManifest.json"
	if run_helper "$repo_dir" check-release v1.0.0 >/dev/null 2>&1; then
		fail "invalid manifest rejected"
	else
		pass "invalid manifest rejected"
	fi
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_prepare_and_validate_release
	test_invalid_prepare_is_non_mutating
	test_release_gate_rejects_package_defects
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
