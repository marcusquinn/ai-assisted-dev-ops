#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for retired review-provider configuration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../review-gate-config-helper.sh"
TEST_ROOT="$(mktemp -d -t review-gate-config-retired.XXXXXX)"
REPOS_JSON="${TEST_ROOT}/repos.json"
STDOUT_FILE="${TEST_ROOT}/stdout"
STDERR_FILE="${TEST_ROOT}/stderr"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

printf '%s\n' '{"initialized_repos":[{"slug":"testorg/testrepo","path":"/tmp/testrepo"}]}' >"$REPOS_JSON"

if AIDEVOPS_REPOS_JSON="$REPOS_JSON" "$HELPER" testorg/testrepo \
	--tool gemini-code-assist --completion strict >"$STDOUT_FILE" 2>"$STDERR_FILE"; then
	printf 'FAIL retired bot accepted a new strict override\n' >&2
	exit 1
fi
if ! grep -Fq "is retired; only 'unset' is accepted" "$STDERR_FILE"; then
	printf 'FAIL retired bot rejection did not explain the cleanup-only policy\n' >&2
	exit 1
fi
if jq -e '.initialized_repos[0].review_gate.tools["gemini-code-assist"] // false' "$REPOS_JSON" >/dev/null; then
	printf 'FAIL rejected retired bot override mutated repos.json\n' >&2
	exit 1
fi
printf 'PASS retired bot rejects new strict configuration\n'

jq '.initialized_repos[0].review_gate.tools["gemini-code-assist"] = {
	"rate_limit_behavior": "wait",
	"completion_behavior": "strict"
}' "$REPOS_JSON" >"${REPOS_JSON}.new"
mv "${REPOS_JSON}.new" "$REPOS_JSON"

AIDEVOPS_REPOS_JSON="$REPOS_JSON" "$HELPER" testorg/testrepo \
	--tool gemini-code-assist --completion unset >"$STDOUT_FILE" 2>"$STDERR_FILE"
AIDEVOPS_REPOS_JSON="$REPOS_JSON" "$HELPER" testorg/testrepo \
	--tool gemini-code-assist unset >"$STDOUT_FILE" 2>"$STDERR_FILE"

if jq -e '.initialized_repos[0].review_gate.tools["gemini-code-assist"] // false' "$REPOS_JSON" >/dev/null; then
	printf 'FAIL retired bot cleanup left a per-tool override\n' >&2
	exit 1
fi
printf 'PASS retired bot accepts cleanup via unset\n'

exit 0
