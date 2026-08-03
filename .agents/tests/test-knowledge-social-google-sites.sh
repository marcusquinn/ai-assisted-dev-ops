#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-google-sites.sh — Google Sites no-route contract tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
BROWSER="${SCRIPTS_DIR}/knowledge_social_browser.py"
REGISTRY="${SCRIPTS_DIR}/knowledge_social_registry.py"
OPERATIONS="${REPO_ROOT}/.agents/aidevops/knowledge-plane/05-social-operations.md"
MATRIX="${REPO_ROOT}/.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md"
DOC="${REPO_ROOT}/.agents/content/social-google-sites.md"
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

printf 'Google Sites account knowledge no-route contract\n'

assert_contains "$DOC" 'https://developers.google.com/workspace/sites' \
	'classic-only deprecated Sites API evidence is recorded'
assert_contains "$DOC" \
	'https://developers.google.com/workspace/drive/api/guides/mime-types' \
	'Drive Sites MIME metadata evidence is recorded'
assert_contains "$DOC" \
	'https://developers.google.com/workspace/drive/api/guides/ref-export-formats' \
	'Drive export-format omission is recorded'
assert_contains "$DOC" 'https://support.google.com/docs/answer/9759608' \
	'official Takeout Sites coverage is recorded'
assert_contains "$DOC" \
	'https://developers.google.com/data-portability/user-guide/scopes' \
	'Data Portability product-scope boundary is recorded'
assert_contains "$DOC" 'https://support.google.com/a/answer/100458' \
	'Workspace administrator export gate is recorded'
assert_contains "$DOC" \
	'No API client, metadata collector, export importer, or browser route is enabled.' \
	'documentation states every disabled route explicitly'
assert_contains "$OPERATIONS" 'Google Sites has no enabled collection route.' \
	'operations guide records the disabled route'

google_sites_row=$(grep -F '| Google Sites |' "$MATRIX" || true)
if [[ -z "$google_sites_row" ]]; then
	record_fail 'capability matrix contains a Google Sites row'
else
	record_pass 'capability matrix contains a Google Sites row'
fi
if [[ "$google_sites_row" == *'**Live'* ]]; then
	record_fail 'capability matrix keeps Google Sites non-Live'
else
	record_pass 'capability matrix keeps Google Sites non-Live'
fi
if [[ "$google_sites_row" == *'**Export/No** modern site content; **No** classic live API'* &&
	"$google_sites_row" == *'**API/No** owner/editor metadata; **No** subscriptions'* &&
	"$google_sites_row" == *'schema-free **Export/No**'* &&
	"$google_sites_row" == *'organization export is **Gate/No**'* ]]; then
	record_pass 'modern, classic, metadata, export, and admin gates remain explicit'
else
	record_fail 'modern, classic, metadata, export, and admin gates remain explicit'
fi

if [[ -e "${SCRIPTS_DIR}/knowledge_social_google_sites.py" ]]; then
	record_fail 'no Google Sites provider entry point exists'
else
	record_pass 'no Google Sites provider entry point exists'
fi
shopt -s nullglob
google_sites_modules=("${SCRIPTS_DIR}"/_knowledge_social_google_sites*.py)
shopt -u nullglob
if [[ "${#google_sites_modules[@]}" -eq 0 ]]; then
	record_pass 'no placeholder Google Sites support modules exist'
else
	record_fail 'no placeholder Google Sites support modules exist'
fi

if grep -Eiq 'GOOGLE_SITES_HELPER|import-google-sites|sync-google-sites|collect-google-sites' "$HELPER"; then
	record_fail 'social helper exposes no Google Sites route'
else
	record_pass 'social helper exposes no Google Sites route'
fi
if grep -Eiq 'google[-_]sites' "$BROWSER"; then
	record_fail 'browser collector exposes no Google Sites selector'
else
	record_pass 'browser collector exposes no Google Sites selector'
fi
if grep -Eiq 'google[-_]sites' "$REGISTRY"; then
	record_fail 'provider registry exposes no Google Sites route'
else
	record_pass 'provider registry exposes no Google Sites route'
fi

if "$HELPER" import-google-sites-export \
	--archive "${SCRIPT_DIR}/fixtures/untrusted-google-sites-export.zip" \
	--connection-id conn_google_sites_test --account-id account_google_sites_test \
	>/dev/null 2>&1; then
	record_fail 'export-shaped input cannot reach persistence'
else
	record_pass 'export-shaped input cannot reach persistence'
fi
if "$HELPER" sync-google-sites --site-id site_google_sites_test \
	--connection-id conn_google_sites_test --account-id account_google_sites_test \
	>/dev/null 2>&1; then
	record_fail 'site-shaped input cannot reach a Drive metadata route'
else
	record_pass 'site-shaped input cannot reach a Drive metadata route'
fi
if "$HELPER" provider-run --provider google-sites --mode no-route \
	>/dev/null 2>&1; then
	record_fail 'provider dispatch cannot execute a Google Sites placeholder'
else
	record_pass 'provider dispatch cannot execute a Google Sites placeholder'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
