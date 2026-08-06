#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2016 # source assertions intentionally match literal shell expressions

set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="${script_dir}/pulse-issue-reconcile-actions.sh"
failures=0

assert_source() {
	local description="$1"
	local pattern="$2"
	if grep -qF "$pattern" "$target"; then
		printf 'PASS: %s\n' "$description"
	else
		printf 'FAIL: %s\n' "$description"
		failures=$((failures + 1))
	fi
	return 0
}

assert_source "trusted roadmap comment extractor exists" '_fetch_children_from_trusted_roadmap_comments()'
assert_source "extractor requires an explicit roadmap heading" 'Dispatch roadmap|Children|Child issues|Sub-tasks'
assert_source "extractor restricts comments to trusted associations" '.author_association == "OWNER"'
assert_source "reconciler includes trusted comment children" 'comment_nums=$(_fetch_children_from_trusted_roadmap_comments'
assert_source "unavailable comment evidence fails the union closed" 'comment_nums=$(_fetch_children_from_trusted_roadmap_comments "$slug" "$issue_num") || return 1'
assert_source "comment children participate in the union" '"$prose_nums" "$comment_nums"'

if [[ "$failures" -gt 0 ]]; then
	exit 1
fi
exit 0
