#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)" || exit 1
RELEASE_WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
PACKAGE_WORKFLOW="${REPO_ROOT}/.github/workflows/publish-packages.yml"

assert_contains() {
	local name="$1"
	local pattern="$2"
	local file="$3"
	if ! grep -qF -- "$pattern" "$file"; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_absent() {
	local name="$1"
	local pattern="$2"
	local file="$3"
	if grep -qF -- "$pattern" "$file"; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_order() {
	local name="$1"
	local first_pattern="$2"
	local second_pattern="$3"
	local file="$4"
	local first_line=""
	local second_line=""

	first_line=$(grep -nF -- "$first_pattern" "$file" | cut -d: -f1 | head -1)
	second_line=$(grep -nF -- "$second_pattern" "$file" | cut -d: -f1 | head -1)
	if [[ ! "$first_line" =~ ^[0-9]+$ || ! "$second_line" =~ ^[0-9]+$ || "$first_line" -ge "$second_line" ]]; then
		printf 'FAIL %s\n' "$name"
		return 1
	fi
	printf 'PASS %s\n' "$name"
	return 0
}

assert_absent "manual arbitrary-version publication is removed" "workflow_dispatch:" "$PACKAGE_WORKFLOW"
assert_absent "package metadata is not rewritten before publish" "--no-git-tag-version" "$PACKAGE_WORKFLOW"
assert_contains "release workflow verifies provenance" "release-provenance-helper.sh verify" "$RELEASE_WORKFLOW"
# shellcheck disable=SC2016 # Intentional literal GitHub Actions expression.
assert_contains "package workflow checks out release tag" 'ref: ${{ github.event.release.tag_name }}' "$PACKAGE_WORKFLOW"
assert_contains "Homebrew job has read-only repository permission" "contents: read" "$PACKAGE_WORKFLOW"
assert_order "release provenance precedes release creation" \
	"release-provenance-helper.sh verify" "github-release-helper.sh create" "$RELEASE_WORKFLOW"
assert_order "package provenance precedes npm publication" \
	"release-provenance-helper.sh verify" "npm publish --provenance" "$PACKAGE_WORKFLOW"

verification_count=$(grep -cF 'release-provenance-helper.sh verify' "$PACKAGE_WORKFLOW" || true)
if [[ "$verification_count" -ne 2 ]]; then
	printf 'FAIL npm and Homebrew jobs must each verify provenance\n'
	exit 1
fi
printf 'PASS npm and Homebrew jobs each verify provenance\n'

exit 0
