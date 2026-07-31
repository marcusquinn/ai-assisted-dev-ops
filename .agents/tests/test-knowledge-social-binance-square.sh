#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-binance-square.sh — Binance Square no-route isolation contract

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
BROWSER="${SCRIPTS_DIR}/knowledge_social_browser.py"
DOC="${REPO_ROOT}/.agents/content/social-binance-square.md"
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

printf 'Binance Square read-ingestion no-route contract\n'

assert_contains "$DOC" \
	'https://github.com/binance/binance-skills-hub/blob/3bf89edb7eea313c36688d21cd4512f9f501b57d/skills/binance/square-post/SKILL.md' \
	'official pinned Square scope evidence is recorded'
assert_contains "$DOC" \
	'The official surfaces and local runtime were checked on 2026-07-31.' \
	'disposition has a dated evidence boundary'
assert_contains "$DOC" \
	'No importer, API reader, export parser, event receiver, or browser route is' \
	'documentation states every disabled route explicitly'
assert_contains "$DOC" \
	'current evidence of a mutation-only' \
	'publishing authority is not treated as read authority'
assert_contains "$DOC" \
	'exchange or financial credentials must fail before any network' \
	'financial credentials fail closed before network access'
assert_contains "$DOC" \
	'official export generation limit, delivery time, schema version' \
	'unknown export and retention contracts are explicit'

for category in \
	'Account and creator profile' \
	'Authored posts and articles' \
	'Revisions, deletion history, and drafts' \
	'Comments, replies, and mentions' \
	'Likes and reactions' \
	'Bookmarks and saved state' \
	'Follows, subscriptions, lists, topics, and feeds' \
	'Notifications and messages' \
	'Media, live, and audio metadata' \
	'Campaigns, rewards, and monetization' \
	'Private state and account history' \
	'Public Square pages'; do
	if grep -F "| ${category} |" "$DOC" | grep -Fq '| **No** |'; then
		record_pass "${category} remains an explicit no-route gap"
	else
		record_fail "${category} remains an explicit no-route gap"
	fi
done

if [[ -e "${SCRIPTS_DIR}/knowledge_social_binance_square.py" ]]; then
	record_fail 'no Binance Square provider entry point exists'
else
	record_pass 'no Binance Square provider entry point exists'
fi
shopt -s nullglob
square_modules=("${SCRIPTS_DIR}"/_knowledge_social_binance_square*.py)
shopt -u nullglob
if [[ "${#square_modules[@]}" -eq 0 ]]; then
	record_pass 'no placeholder Binance Square support modules exist'
else
	record_fail 'no placeholder Binance Square support modules exist'
fi

if grep -Eiq 'BINANCE_SQUARE|import-binance-square|sync-binance-square|collect-binance-square|publish-binance-square' "$HELPER"; then
	record_fail 'social helper exposes no Binance Square or publishing route'
else
	record_pass 'social helper exposes no Binance Square or publishing route'
fi
if grep -Eiq 'binance([_-]square|[[:space:]]+square)' "$BROWSER"; then
	record_fail 'browser collector exposes no Binance Square selector'
else
	record_pass 'browser collector exposes no Binance Square selector'
fi

if BINANCE_SQUARE_OPENAPI_KEY='synthetic_not_a_secret' \
	BINANCE_API_KEY='synthetic_not_a_secret' \
	"$HELPER" sync-binance-square \
	--connection-id conn_binance_square_test \
	--account-id account_binance_square_test >/dev/null 2>&1; then
	record_fail 'mutation-capable credentials cannot activate Square ingestion'
else
	record_pass 'mutation-capable credentials cannot activate Square ingestion'
fi

if "$HELPER" import-binance-square-export \
	--export "${SCRIPT_DIR}/fixtures/untrusted-binance-square-export.zip" \
	--connection-id conn_binance_square_test \
	--account-id account_binance_square_test >/dev/null 2>&1; then
	record_fail 'export-shaped input cannot reach persistence'
else
	record_pass 'export-shaped input cannot reach persistence'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
