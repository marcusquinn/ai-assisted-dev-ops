#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT=""
TESTS_RUN=0

# shellcheck source=../runtime-bundle-verifier.sh
source "$REPO_ROOT/.agents/scripts/runtime-bundle-verifier.sh"

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS: %s\n' "$message"
	return 0
}

write_manifest() {
	local manifest_file="$1"
	local bundle_id="$2"
	local git_sha="$3"
	printf 'schema=1\nstatus=validated\nbundle_id=%s\nframework_version=1.2.3\ngit_sha=%s\ncli_sha256=0123456789abcdef\n' \
		"$bundle_id" "$git_sha" >"$manifest_file"
	return 0
}

test_valid_manifest() {
	local active_root="$1"
	local expected_sha="$2"
	_runtime_bundle_verify_manifest "$active_root" "$expected_sha" || fail "valid single-value manifest was rejected"
	pass "runtime bundle verifier accepts a valid single-value manifest"
	return 0
}

test_duplicate_manifest_keys() {
	local active_root="$1"
	local expected_sha="$2"
	local manifest_file="$active_root/.bundle-manifest"
	local pristine_manifest="$TEST_ROOT/pristine-manifest"
	local duplicate_field=""
	local duplicate_value=""
	cp "$manifest_file" "$pristine_manifest"
	for duplicate_field in status bundle_id git_sha cli_sha256; do
		case "$duplicate_field" in
		status) duplicate_value="rejected" ;;
		bundle_id) duplicate_value="different-bundle" ;;
		git_sha) duplicate_value="ffffffffffffffffffffffffffffffffffffffff" ;;
		cli_sha256) duplicate_value="fedcba9876543210" ;;
		esac
		cp "$pristine_manifest" "$manifest_file"
		printf '%s=%s\n' "$duplicate_field" "$duplicate_value" >>"$manifest_file"
		if _runtime_bundle_verify_manifest "$active_root" "$expected_sha" >/dev/null 2>&1; then
			fail "duplicate $duplicate_field manifest key was accepted"
		fi
	done
	cp "$pristine_manifest" "$manifest_file"
	pass "runtime bundle verifier rejects duplicate trust and integrity keys"
	return 0
}

test_malformed_and_missing_manifest_fields() {
	local active_root="$1"
	local expected_sha="$2"
	local bundle_id="$3"
	local manifest_file="$active_root/.bundle-manifest"
	local pristine_manifest="$TEST_ROOT/pristine-required-manifest"
	cp "$manifest_file" "$pristine_manifest"
	printf '%s\n' 'malformed-line' >>"$manifest_file"
	if _runtime_bundle_verify_manifest "$active_root" "$expected_sha" >/dev/null 2>&1; then
		fail "malformed manifest line was accepted"
	fi
	printf 'status=validated\nbundle_id=%s\nframework_version=1.2.3\ngit_sha=%s\ncli_sha256=0123456789abcdef\n' \
		"$bundle_id" "$expected_sha" >"$manifest_file"
	if _runtime_bundle_verify_manifest "$active_root" "$expected_sha" >/dev/null 2>&1; then
		fail "manifest missing its schema was accepted"
	fi
	printf 'schema=1\nstatus=validated\nbundle_id=%s\nframework_version=1.2.3\ncli_sha256=0123456789abcdef\n' \
		"$bundle_id" >"$manifest_file"
	if _runtime_bundle_verify_manifest "$active_root" "$expected_sha" >/dev/null 2>&1; then
		fail "manifest missing its git SHA was accepted"
	fi
	cp "$pristine_manifest" "$manifest_file"
	pass "runtime bundle verifier rejects malformed and missing required fields"
	return 0
}

main() {
	local expected_sha="0123456789abcdef0123456789abcdef01234567"
	local bundle_id="release-0123456789ab-test"
	local active_root=""
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	active_root="$TEST_ROOT/$bundle_id/agents"
	mkdir -p "$active_root"
	write_manifest "$active_root/.bundle-manifest" "$bundle_id" "$expected_sha"
	test_valid_manifest "$active_root" "$expected_sha"
	test_duplicate_manifest_keys "$active_root" "$expected_sha"
	test_malformed_and_missing_manifest_fields "$active_root" "$expected_sha" "$bundle_id"
	printf 'Results: %s checks passed\n' "$TESTS_RUN"
	return 0
}

main "$@"
