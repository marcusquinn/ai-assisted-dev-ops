#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-substack.sh — Substack collection no-route contract tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
BROWSER="${SCRIPTS_DIR}/knowledge_social_browser.py"
REGISTRY="${SCRIPTS_DIR}/knowledge_social_registry.py"
MATRIX="${REPO_ROOT}/.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md"
DOC="${REPO_ROOT}/.agents/content/social-substack.md"
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

printf 'Substack account knowledge no-route contract\n'

assert_contains "$DOC" \
	'https://support.substack.com/hc/en-us/articles/50834026608916' \
	'official read-only MCP gate evidence is recorded'
assert_contains "$DOC" \
	'https://support.substack.com/hc/en-us/articles/360037466012-How-do-I-export-my-posts' \
	'official publication export evidence is recorded'
assert_contains "$DOC" \
	'https://support.substack.com/hc/en-us/articles/6314498343700-How-do-I-export-my-email-list-on-Substack' \
	'official subscriber CSV evidence is recorded'
assert_contains "$DOC" \
	'https://support.substack.com/hc/en-us/articles/360038239391-Is-there-an-RSS-feed-for-my-publication' \
	'official public RSS evidence is recorded'
assert_contains "$DOC" 'It must never be represented as complete authenticated account history.' \
	'public RSS completeness boundary is explicit'
assert_contains "$DOC" \
	'No importer, API client, MCP connector, RSS collector, or browser route is' \
	'documentation states every disabled route explicitly'

substack_row=$(grep -F '| Substack |' "$MATRIX" || true)
if [[ -z "$substack_row" ]]; then
	record_fail 'capability matrix contains a Substack row'
else
	record_pass 'capability matrix contains a Substack row'
fi
if [[ "$substack_row" == *'**Live'* ]]; then
	record_fail 'capability matrix keeps Substack non-Live'
else
	record_pass 'capability matrix keeps Substack non-Live'
fi
if [[ "$substack_row" == *'**Export/No** publication posts; **No** Notes'* &&
	"$substack_row" == *'**No** comments, likes, restacks, or saved Notes'* &&
	"$substack_row" == *'**No** reader subscriptions or publication memberships'* &&
	"$substack_row" == *'**Gate/No** bestseller analytics'* ]]; then
	record_pass 'requested Substack categories remain explicit'
else
	record_fail 'requested Substack categories remain explicit'
fi

if [[ -e "${SCRIPTS_DIR}/knowledge_social_substack.py" ]]; then
	record_fail 'no Substack provider entry point exists'
else
	record_pass 'no Substack provider entry point exists'
fi
shopt -s nullglob
substack_modules=("${SCRIPTS_DIR}"/_knowledge_social_substack*.py)
shopt -u nullglob
if [[ "${#substack_modules[@]}" -eq 0 ]]; then
	record_pass 'no placeholder Substack support modules exist'
else
	record_fail 'no placeholder Substack support modules exist'
fi

if grep -Eiq 'SUBSTACK_HELPER|import-substack|sync-substack|collect-substack' "$HELPER"; then
	record_fail 'social helper exposes no Substack route'
else
	record_pass 'social helper exposes no Substack route'
fi
if grep -Eiq 'substack' "$BROWSER"; then
	record_fail 'browser collector exposes no Substack selector'
else
	record_pass 'browser collector exposes no Substack selector'
fi
if grep -Eiq 'substack' "$REGISTRY"; then
	record_fail 'provider registry exposes no Substack route'
else
	record_pass 'provider registry exposes no Substack route'
fi

if "$HELPER" import-substack-export \
	--archive "${SCRIPT_DIR}/fixtures/untrusted-substack-export.zip" \
	--connection-id conn_substack_test --account-id account_substack_test \
	>/dev/null 2>&1; then
	record_fail 'export-shaped input cannot reach persistence'
else
	record_pass 'export-shaped input cannot reach persistence'
fi
if "$HELPER" provider-run --provider substack --mode no-route \
	>/dev/null 2>&1; then
	record_fail 'provider dispatch cannot execute a Substack no-route placeholder'
else
	record_pass 'provider dispatch cannot execute a Substack no-route placeholder'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
