#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# tests/test-knowledge-provisioning.sh — Unit tests for knowledge-helper.sh
#
# Tests: fresh init, idempotent update, personal mode, off mode no-op,
# gitignore correctness, knowledge.json content.
#
# Usage: bash tests/test-knowledge-provisioning.sh

set -euo pipefail

HELPER="${HELPER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.agents/scripts/knowledge-helper.sh}"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Assert helpers
# ---------------------------------------------------------------------------

pass() {
	local _desc="$1"
	PASS=$((PASS + 1))
	printf "  PASS  %s\n" "$_desc"
	return 0
}

fail() {
	local _desc="$1"
	local _reason="${2:-}"
	FAIL=$((FAIL + 1))
	printf "  FAIL  %s\n" "$_desc"
	[[ -n "$_reason" ]] && printf "        %s\n" "$_reason"
	return 0
}

assert_dir() {
	local _path="$1"
	local _desc="$2"
	if [[ -d "$_path" ]]; then
		pass "$_desc"
	else
		fail "$_desc" "Expected directory: $_path"
	fi
	return 0
}

assert_file() {
	local _path="$1"
	local _desc="$2"
	if [[ -f "$_path" ]]; then
		pass "$_desc"
	else
		fail "$_desc" "Expected file: $_path"
	fi
	return 0
}

assert_file_contains() {
	local _path="$1"
	local _pattern="$2"
	local _desc="$3"
	if [[ -f "$_path" ]] && grep -q "$_pattern" "$_path" 2>/dev/null; then
		pass "$_desc"
	else
		fail "$_desc" "Expected '$_pattern' in $_path"
	fi
	return 0
}

assert_not_dir() {
	local _path="$1"
	local _desc="$2"
	if [[ ! -d "$_path" ]]; then
		pass "$_desc"
	else
		fail "$_desc" "Expected no directory at: $_path"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

setup_fake_repos_json() {
	local tmp_dir="$1"
	local mode="$2"
	local resolved_dir
	resolved_dir="$(cd "$tmp_dir" && pwd)"
	local repos_file="${resolved_dir}/repos.json"
	mkdir -p "$resolved_dir"
	cat >"$repos_file" <<EOF
{
  "initialized_repos": [
    {
      "path": "${resolved_dir}/repo",
      "slug": "test/repo",
      "knowledge": "$mode"
    }
  ],
  "git_parent_dirs": []
}
EOF
	echo "$repos_file"
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: Fresh init — repo mode
# ---------------------------------------------------------------------------

test_fresh_init_repo_mode() {
	echo "Test 1: fresh init repo mode"
	local tmp_dir repos_file
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	assert_dir "${tmp_dir}/repo/_knowledge" "1.1 _knowledge root created"
	assert_dir "${tmp_dir}/repo/_knowledge/inbox" "1.2 inbox/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/staging" "1.3 staging/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/sources" "1.4 sources/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/index" "1.5 index/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/collections" "1.6 collections/ created"
	assert_dir "${tmp_dir}/repo/_knowledge/_config" "1.7 _config/ created"
	assert_file "${tmp_dir}/repo/_knowledge/_config/knowledge.json" "1.8 knowledge.json created"
	assert_file "${tmp_dir}/repo/_knowledge/.gitignore" "1.9 .gitignore created"
	assert_file_contains "${tmp_dir}/repo/_knowledge/.gitignore" "inbox/" "1.10 .gitignore has inbox/"
	assert_file_contains "${tmp_dir}/repo/_knowledge/.gitignore" "staging/" "1.11 .gitignore has staging/"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: Idempotent — provision twice without error
# ---------------------------------------------------------------------------

test_idempotent_provision() {
	echo "Test 2: idempotent provision"
	local tmp_dir repos_file
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	local result=$?
	if [[ $result -eq 0 ]]; then
		pass "2.1 second provision exits 0"
	else
		fail "2.1 second provision exits 0" "Got exit $result"
	fi
	assert_dir "${tmp_dir}/repo/_knowledge/inbox" "2.2 inbox still present after re-provision"
	assert_file "${tmp_dir}/repo/_knowledge/_config/knowledge.json" "2.3 knowledge.json still present"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: Personal mode — provisions at personal plane base
# ---------------------------------------------------------------------------

test_personal_mode() {
	echo "Test 3: personal mode"
	local tmp_dir repos_file personal_base
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	personal_base="${tmp_dir}/personal-plane"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "personal")
	REPOS_FILE="$repos_file" PERSONAL_PLANE_BASE="$personal_base" bash "$HELPER" provision "${tmp_dir}/repo"
	assert_dir "${personal_base}/_knowledge" "3.1 personal _knowledge root created"
	assert_dir "${personal_base}/_knowledge/inbox" "3.2 personal inbox/ created"
	assert_file "${personal_base}/catalog.db" "3.3 personal catalog.db created"
	assert_file "${personal_base}/_config/principal.json" "3.4 principal context created"
	assert_not_dir "${tmp_dir}/repo/_knowledge" "3.5 no in-repo _knowledge in personal mode"
	local marker_file="${personal_base}/_knowledge/sources/legacy-marker.txt"
	printf 'preserved\n' >"$marker_file"
	REPOS_FILE="$repos_file" PERSONAL_PLANE_BASE="$personal_base" bash "$HELPER" provision "${tmp_dir}/repo"
	assert_file "$marker_file" "3.6 repeated provision preserves legacy personal content"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: Off mode — no-op
# ---------------------------------------------------------------------------

test_off_mode_noop() {
	echo "Test 4: off mode no-op"
	local tmp_dir repos_file
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "off")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	assert_not_dir "${tmp_dir}/repo/_knowledge" "4.1 no _knowledge created in off mode"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: Repo .gitignore patched
# ---------------------------------------------------------------------------

test_gitignore_patched() {
	echo "Test 5: repo .gitignore patched"
	local tmp_dir repos_file
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	echo "node_modules/" >"${tmp_dir}/repo/.gitignore"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	assert_file_contains "${tmp_dir}/repo/.gitignore" "_knowledge/inbox/" "5.1 repo .gitignore has _knowledge/inbox/"
	assert_file_contains "${tmp_dir}/repo/.gitignore" "_knowledge/staging/" "5.2 repo .gitignore has _knowledge/staging/"
	assert_file_contains "${tmp_dir}/repo/.gitignore" "knowledge-plane-rules" "5.3 repo .gitignore has marker"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: knowledge.json contains required fields
# ---------------------------------------------------------------------------

test_config_json_content() {
	echo "Test 6: knowledge.json required fields"
	local tmp_dir repos_file config_file
	tmp_dir=$(mktemp -d)
	tmp_dir="$(cd "$tmp_dir" && pwd)"
	# shellcheck disable=SC2064
	trap "rm -rf '$tmp_dir'" EXIT
	mkdir -p "${tmp_dir}/repo"
	repos_file=$(setup_fake_repos_json "$tmp_dir" "repo")
	REPOS_FILE="$repos_file" bash "$HELPER" provision "${tmp_dir}/repo"
	config_file="${tmp_dir}/repo/_knowledge/_config/knowledge.json"
	assert_file_contains "$config_file" '"version"' "6.1 knowledge.json has version key"
	assert_file_contains "$config_file" '"sensitivity_default"' "6.2 has sensitivity_default"
	assert_file_contains "$config_file" '"trust_default"' "6.3 has trust_default"
	rm -rf "$tmp_dir"
	trap - EXIT
	return 0
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

echo "Running knowledge plane provisioning tests..."
echo ""

test_fresh_init_repo_mode
test_idempotent_provision
test_personal_mode
test_off_mode_noop
test_gitignore_patched
test_config_json_content

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
