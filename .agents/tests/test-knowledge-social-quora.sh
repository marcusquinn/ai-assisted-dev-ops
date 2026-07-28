#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-quora.sh — Quora export no-route contract tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/.agents/scripts"
HELPER="${SCRIPTS_DIR}/knowledge-social-helper.sh"
MATRIX="${REPO_ROOT}/.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md"
DOC="${REPO_ROOT}/.agents/content/social-quora.md"
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

printf 'Quora account export no-route contract\n'

assert_contains "$DOC" \
	'https://help.quora.com/hc/en-us/articles/360000839503-Can-I-get-a-copy-of-my-data' \
	'official owner-export evidence is recorded'
assert_contains "$DOC" 'No importer or CLI route is enabled.' \
	'documentation states the disabled route explicitly'
assert_contains "$DOC" 'public content-archive samples contain no authoritative owner' \
	'identity gap is explicit'
assert_contains "$DOC" 'No current official export expiry or retention period was' \
	'unknown export retention is not inferred'

quora_row=$(grep -F '| Quora |' "$MATRIX" || true)
if [[ -z "$quora_row" ]]; then
	record_fail 'capability matrix contains a Quora row'
else
	record_pass 'capability matrix contains a Quora row'
fi
if [[ "$quora_row" == *'**Live'* ]]; then
	record_fail 'capability matrix keeps Quora non-Live'
else
	record_pass 'capability matrix keeps Quora non-Live'
fi
if [[ "$quora_row" == *'**Export/No** answers, questions, posts, and comments'* &&
	"$quora_row" == *'**No** upvotes and other curation'* &&
	"$quora_row" == *'**No** followed topics or Spaces'* ]]; then
	record_pass 'unsupported Quora categories remain explicit'
else
	record_fail 'unsupported Quora categories remain explicit'
fi

if [[ -e "${SCRIPTS_DIR}/knowledge_social_quora.py" ]]; then
	record_fail 'no Quora provider entry point exists'
else
	record_pass 'no Quora provider entry point exists'
fi
shopt -s nullglob
quora_modules=("${SCRIPTS_DIR}"/_knowledge_social_quora*.py)
shopt -u nullglob
if [[ "${#quora_modules[@]}" -eq 0 ]]; then
	record_pass 'no placeholder Quora support modules exist'
else
	record_fail 'no placeholder Quora support modules exist'
fi

if grep -Eq 'QUORA_HELPER|import-quora-archive|sync-quora' "$HELPER"; then
	record_fail 'social helper exposes no Quora route'
else
	record_pass 'social helper exposes no Quora route'
fi

if "$HELPER" import-quora-archive \
	--archive "${SCRIPT_DIR}/fixtures/untrusted-quora-export.zip" \
	--connection-id conn_quora_test --account-id account_quora_test \
	>/dev/null 2>&1; then
	record_fail 'archive-shaped input cannot reach persistence'
else
	record_pass 'archive-shaped input cannot reach persistence'
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
