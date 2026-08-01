#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
INSTALL_DIR="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
AGENTS_DIR="${INSTALL_DIR}/.agents"
CLOUDRON_CALLER_FRAMEWORK_REF="22a6b4b29087ce2fcf3857596a40ff7b2c436482"
TEST_ROOT=""
PASSED=0
FAILED=0

print_info() { return 0; }
print_success() { return 0; }
print_warning() { return 0; }
print_error() { return 0; }

# shellcheck source=../aidevops-cli/aidevops-repos-lib.sh
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh"
# shellcheck source=../aidevops-cli/aidevops-init-lib.sh
source "${INSTALL_DIR}/.agents/scripts/aidevops-cli/aidevops-init-lib.sh"

cleanup() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

assert_equal() {
	local expected="$1"
	local actual="$2"
	local description="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf 'PASS %s\n' "$description"
		PASSED=$((PASSED + 1))
		return 0
	fi
	printf 'FAIL %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual" >&2
	FAILED=$((FAILED + 1))
	return 0
}

test_cloudron_workflow_scaffolding() {
	local repo_dir="${TEST_ROOT}/cloudron"
	mkdir -p "$repo_dir"
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	_init_scaffold_cloudron_release_workflow "$repo_dir"
	local workflow="${repo_dir}/.github/workflows/cloudron-package-release.yml"
	assert_equal true "$([[ -f "$workflow" ]] && printf true || printf false)" "Cloudron caller scaffolded"
	assert_equal "$(cksum "${AGENTS_DIR}/templates/workflows/cloudron-package-release-caller.yml" | awk '{ print $1, $2 }')" "$(cksum "$workflow" | awk '{ print $1, $2 }')" "caller matches managed template"
	assert_equal true "$(grep -Fq "cloudron-package-release-reusable.yml@${CLOUDRON_CALLER_FRAMEWORK_REF}" "$workflow" && printf true || printf false)" "caller pins reusable workflow commit"
	assert_equal true "$(grep -Fq "aidevops_ref: ${CLOUDRON_CALLER_FRAMEWORK_REF}" "$workflow" && printf true || printf false)" "caller pins validator commit"
	assert_equal false "$(grep -Eq '@main|aidevops_ref:[[:space:]]+main' "$workflow" && printf true || printf false)" "caller contains no mutable main ref"
	assert_equal true "$(git -C "$INSTALL_DIR" cat-file -e "${CLOUDRON_CALLER_FRAMEWORK_REF}:.github/workflows/cloudron-package-release-reusable.yml" 2>/dev/null && printf true || printf false)" "pinned commit contains reusable workflow"
	assert_equal true "$(git -C "$INSTALL_DIR" cat-file -e "${CLOUDRON_CALLER_FRAMEWORK_REF}:.agents/scripts/cloudron-package-helper.sh" 2>/dev/null && printf true || printf false)" "pinned commit contains release validator"
	local before=""
	before=$(cksum "$workflow")
	_init_scaffold_cloudron_release_workflow "$repo_dir"
	assert_equal "$before" "$(cksum "$workflow")" "Cloudron caller scaffolding is idempotent"

	local generic_dir="${TEST_ROOT}/generic"
	mkdir -p "$generic_dir"
	_init_scaffold_cloudron_release_workflow "$generic_dir"
	assert_equal false "$([[ -e "${generic_dir}/.github/workflows/cloudron-package-release.yml" ]] && printf true || printf false)" "non-Cloudron repo receives no caller"

	local existing_dir="${TEST_ROOT}/existing"
	mkdir -p "${existing_dir}/.github/workflows"
	printf '{}\n' >"${existing_dir}/CloudronManifest.json"
	printf 'custom\n' >"${existing_dir}/.github/workflows/cloudron-package-release.yml"
	_init_scaffold_cloudron_release_workflow "$existing_dir"
	assert_equal custom "$(tr -d '\n' <"${existing_dir}/.github/workflows/cloudron-package-release.yml")" "existing caller is never overwritten"
	return 0
}

test_cloudron_registration_metadata() {
	local home_dir="${TEST_ROOT}/home"
	local repo_dir="${TEST_ROOT}/registered"
	CONFIG_DIR="${home_dir}/.config/aidevops"
	REPOS_FILE="${CONFIG_DIR}/repos.json"
	mkdir -p "$CONFIG_DIR" "$repo_dir"
	git -C "$repo_dir" init --quiet
	cat >>"${repo_dir}/.git/config" <<'GITCONFIG'
[remote "origin"]
    url = https://github.com/exampleorg/registered-package.git
    fetch = +refs/heads/*:refs/remotes/origin/*
GITCONFIG
	printf '{}\n' >"${repo_dir}/CloudronManifest.json"
	_repo_registration_maintainer() {
		printf '%s\n' examplemaintainer
		return 0
	}
	register_repo "$repo_dir" 9.9.9 planning
	assert_equal cloudron-package "$(jq -r '.initialized_repos[0].app_type' "$REPOS_FILE")" "registration records Cloudron app_type"
	assert_equal CloudronManifest.json "$(jq -r '.initialized_repos[0].cloudron_package.manifest' "$REPOS_FILE")" "registration records manifest path"
	assert_equal true "$(jq -r '.initialized_repos[0].cloudron_package.monitor_compatibility' "$REPOS_FILE")" "compatibility monitoring defaults on"
	assert_equal '["v",""]' "$(jq -c '.initialized_repos[0].cloudron_package.upstream_tag_prefixes' "$REPOS_FILE")" "registration defaults to v-prefixed and bare upstream tags"
	jq '.initialized_repos[0].cloudron_package += {"upstream_slug":"exampleorg/upstream","monitor_compatibility":false,"upstream_tag_prefixes":["desktop-v"]}' "$REPOS_FILE" >"${REPOS_FILE}.tmp"
	mv "${REPOS_FILE}.tmp" "$REPOS_FILE"
	register_repo "$repo_dir" 9.9.10 planning
	assert_equal exampleorg/upstream "$(jq -r '.initialized_repos[0].cloudron_package.upstream_slug' "$REPOS_FILE")" "explicit upstream metadata preserved"
	assert_equal false "$(jq -r '.initialized_repos[0].cloudron_package.monitor_compatibility' "$REPOS_FILE")" "explicit monitoring preference preserved"
	assert_equal '["desktop-v"]' "$(jq -c '.initialized_repos[0].cloudron_package.upstream_tag_prefixes' "$REPOS_FILE")" "explicit upstream tag stream preserved"
	return 0
}

test_cloudron_publishing_command_syntax() {
	local publishing_skill="${AGENTS_DIR}/tools/deployment/cloudron-app-publishing-skill.md"
	assert_equal true "$(grep -Fq 'cloudron versions update --version=1.0.0 --state=published' "$publishing_skill" && printf true || printf false)" "publishing guidance uses equals-form options"
	assert_equal false "$(grep -Fq 'cloudron versions update --version ' "$publishing_skill" && printf true || printf false)" "publishing guidance avoids global version flag collision"
	return 0
}

main() {
	TEST_ROOT=$(mktemp -d)
	trap cleanup EXIT
	test_cloudron_workflow_scaffolding
	test_cloudron_registration_metadata
	test_cloudron_publishing_command_syntax
	printf '\nRan %d tests, %d failed.\n' "$((PASSED + FAILED))" "$FAILED"
	[[ "$FAILED" -eq 0 ]] || return 1
	return 0
}

main "$@"
