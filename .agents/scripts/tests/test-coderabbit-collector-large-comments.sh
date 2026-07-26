#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="${TEST_DIR}/.."
TEST_ROOT=$(mktemp -d)
SQL_STATE="${TEST_ROOT}/sql-state"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

export HOME="$TEST_ROOT"
export AIDEVOPS_TEST_MODE=1
# shellcheck source=../coderabbit-collector-helper.sh
source "${SCRIPTS_DIR}/coderabbit-collector-helper.sh" help >/dev/null 2>&1

gh() {
	local command="$1"
	local endpoint="$2"
	[[ "$command" == "api" ]] || return 1
	if [[ "$endpoint" == repos/*/pulls/*/comments ]]; then
		python3 - <<'PY'
import json

print(json.dumps([{
    "id": 101,
    "pull_request_review_id": 201,
    "path": "large.sh",
    "line": 10,
    "side": "RIGHT",
    "body": "x" * 2_200_000,
    "created_at": "2026-07-26T20:00:00Z",
}]))
PY
		return 0
	fi
	if [[ "$endpoint" == repos/*/issues/*/comments ]]; then
		printf '%s\n' '[{"id":102,"body":"CodeRabbit summary","created_at":"2026-07-26T20:01:00Z"}]'
		return 0
	fi
	return 1
}

db() {
	local _database="$1"
	shift
	: "$_database"
	if [[ "$#" -eq 0 ]]; then
		local sql=""
		sql=$(</dev/stdin)
		if [[ "$sql" == *"101"* && "$sql" == *"-102"* && "$sql" == *"large.sh"* ]]; then
			printf 'ok\n' >"$SQL_STATE"
		fi
		return 0
	fi
	if [[ -f "$SQL_STATE" ]]; then
		printf '2\n'
	else
		printf '0\n'
	fi
	return 0
}

output=$(collect_comments owner/repo 42 7)
if [[ "$output" != "2" ]]; then
	printf 'FAIL oversized CodeRabbit comments were not merged: %s\n' "$output" >&2
	exit 1
fi
if grep -Fq -- '--argjson pr_comments' "${SCRIPTS_DIR}/coderabbit-collector-helper.sh"; then
	printf 'FAIL CodeRabbit PR comments still enter jq argv\n' >&2
	exit 1
fi
if grep -Fq -- '--argjson issue_comments' "${SCRIPTS_DIR}/coderabbit-collector-helper.sh"; then
	printf 'FAIL CodeRabbit issue comments still enter jq argv\n' >&2
	exit 1
fi

printf 'PASS oversized CodeRabbit comment payloads avoid argv transport\n'
exit 0
