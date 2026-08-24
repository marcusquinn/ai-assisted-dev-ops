#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test: backfill-status-available must collapse multiple JSON
# documents from gh issue list before using jq length in arithmetic [[ ]].

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
BACKFILL_SCRIPT="${SCRIPT_DIR}/../backfill-status-available.sh"

TEST_ROOT=""

cleanup() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

fail() {
	local message="$1"
	printf 'FAIL %s\n' "$message" >&2
	return 1
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"

	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '[{"number":1,"title":"ordinary candidate","author":{"login":"reporter"},"labels":[{"name":"auto-dispatch"}]},{"number":2,"title":"Dependency Dashboard","author":{"login":"renovate[bot]"},"labels":[{"name":"auto-dispatch"}]},{"number":3,"title":"chore(deps): update jq","author":{"login":"renovate[bot]"},"labels":[{"name":"auto-dispatch"}]},{"number":4,"title":"Dependency Dashboard help","author":{"login":"reporter"},"labels":[{"name":"auto-dispatch"}]}]\n[]\n'
	exit 0
fi

exit 1
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

main() {
	trap cleanup EXIT
	setup_test_env

	local output
	output=$("$BACKFILL_SCRIPT" --dry-run --repo owner/repo 2>&1)

	if [[ "$output" == *"syntax error in expression"* ]]; then
		fail "arithmetic syntax error leaked for multi-document gh output"
	fi
	if [[ "$output" != *"Dry-run summary: 3 candidate(s) found"* ]]; then
		printf '%s\n' "$output" >&2
		fail "expected dashboard exclusion and three dispatchable candidates"
	fi
	if [[ "$output" == *"owner/repo#2"* ]]; then
		fail "expected Renovate Dependency Dashboard to be excluded"
	fi
	if [[ "$output" != *"owner/repo#1"* || "$output" != *"owner/repo#3"* || "$output" != *"owner/repo#4"* ]]; then
		printf '%s\n' "$output" >&2
		fail "expected ordinary, actionable Renovate, and non-bot dashboard-title issues"
	fi

	printf 'PASS backfill-status-available normalizes gh output\n'
	return 0
}

main "$@"
