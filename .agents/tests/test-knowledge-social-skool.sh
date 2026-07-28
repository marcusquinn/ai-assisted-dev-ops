#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-skool.sh — Skool export no-route contract tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
BROWSER="${SCRIPTS_DIR}/knowledge_social_browser.py"
MATRIX="${REPO_ROOT}/.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md"
DOC="${REPO_ROOT}/.agents/content/social-skool.md"
PASS=0
FAIL=0

record_pass() {
	local description="$1"
	PASS=$((PASS + 1))
	printf '  PASS  %s\n' "$description"
	return 0
}

record_fail() {
	local description="$1"
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$description"
	return 0
}

assert_contains() {
	local file="$1"
	local expected="$2"
	local description="$3"
	if grep -Fq -- "$expected" "$file"; then
		record_pass "$description"
	else
		record_fail "$description"
	fi
	return 0
}

printf 'Skool account and community export no-route contract\n'

assert_contains "$DOC" \
	'https://help.skool.com/search?query=API' \
	'official API-search evidence is recorded'
assert_contains "$DOC" \
	'https://help.skool.com/article/148-where-can-i-find-members-answers-to-membership-questions' \
	'narrow admin export evidence is recorded'
assert_contains "$DOC" \
	'https://www.skool.com/legal?t=terms' \
	'provider terms evidence is recorded'
assert_contains "$DOC" \
	'No importer, API client, Zapier receiver, or browser route is enabled.' \
	'documentation states the disabled routes explicitly'
assert_contains "$DOC" \
	'does not publish an archive format, included categories, delivery time' \
	'privacy access is not inferred to be a stable export'

skool_row=$(grep -F '| Skool |' "$MATRIX" || true)
if [[ -z "$skool_row" ]]; then
	record_fail 'capability matrix contains a Skool row'
else
	record_pass 'capability matrix contains a Skool row'
fi
if [[ "$skool_row" == *'**Live'* ]]; then
	record_fail 'capability matrix keeps Skool non-Live'
else
	record_pass 'capability matrix keeps Skool non-Live'
fi
if [[ "$skool_row" == *'**No** posts, comments, and course content'* &&
	"$skool_row" == *'**No** reactions and saved state'* &&
	"$skool_row" == *'**No** notifications and messages'* &&
	"$skool_row" == *'**No** memberships, follows, and groups'* &&
	"$skool_row" == *'**No** courses and calendar feeds'* &&
	"$skool_row" == *'**Export/No** admin membership-question answers only'* ]]; then
	record_pass 'unsupported Skool categories remain explicit'
else
	record_fail 'unsupported Skool categories remain explicit'
fi

if [[ -e "${SCRIPTS_DIR}/knowledge_social_skool.py" ]]; then
	record_fail 'no Skool provider entry point exists'
else
	record_pass 'no Skool provider entry point exists'
fi
shopt -s nullglob
skool_modules=("${SCRIPTS_DIR}"/_knowledge_social_skool*.py)
shopt -u nullglob
if [[ "${#skool_modules[@]}" -eq 0 ]]; then
	record_pass 'no placeholder Skool support modules exist'
else
	record_fail 'no placeholder Skool support modules exist'
fi

if grep -Eiq 'SKOOL_HELPER|import-skool|sync-skool|collect-skool' "$HELPER"; then
	record_fail 'social helper exposes no Skool route'
else
	record_pass 'social helper exposes no Skool route'
fi
if grep -Eiq 'skool' "$BROWSER"; then
	record_fail 'browser collector exposes no Skool selector'
else
	record_pass 'browser collector exposes no Skool selector'
fi

if "$HELPER" import-skool-export \
	--export "${SCRIPT_DIR}/fixtures/untrusted-skool-export.zip" \
	--connection-id conn_skool_test --account-id account_skool_test \
	>/dev/null 2>&1; then
	record_fail 'export-shaped input cannot reach persistence'
else
	record_pass 'export-shaped input cannot reach persistence'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
