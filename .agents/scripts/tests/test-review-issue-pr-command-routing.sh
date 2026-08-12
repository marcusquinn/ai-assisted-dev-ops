#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for unified /review discovery and legacy
# parent-session /review-issue-pr routing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
COMMAND_LIB="${SCRIPT_DIR}/../generate-runtime-config-commands.sh"
LEGACY_LIB="${SCRIPT_DIR}/../generate-opencode-commands-quality.sh"
REVIEW_COMMAND_SOURCE="${SCRIPT_DIR}/../commands/review.md"
FULL_LOOP_SOURCE="${SCRIPT_DIR}/../../workflows/full-loop.md"
TMP_DIR=$(mktemp -d -t aidevops-review-command.XXXXXX) || exit 1
COMMAND_DIR="${TMP_DIR}/commands"
CALL_LOG="${TMP_DIR}/legacy-calls"

cleanup() {
	local tmp_dir="$TMP_DIR"
	local tmp_base="${tmp_dir##*/}"
	[[ "$tmp_base" == aidevops-review-command.* ]] || return 1
	rm -rf "$tmp_dir"
	return 0
}
trap cleanup EXIT

mkdir -p "$COMMAND_DIR" || exit 1

grep -Fq 'agent: Build+' "$REVIEW_COMMAND_SOURCE" || {
	printf 'FAIL unified review command does not target Build+\n' >&2
	exit 1
}
grep -Fq 'workflows/review.md' "$REVIEW_COMMAND_SOURCE" || {
	printf 'FAIL unified review command does not load the canonical workflow\n' >&2
	exit 1
}
grep -Fq 'reference/review-core.md' "$FULL_LOOP_SOURCE" || {
	printf 'FAIL full-loop does not load the shared review policy\n' >&2
	exit 1
}

# shellcheck source=../generate-runtime-config-commands.sh
source "$COMMAND_LIB"

# A previous generator left this command permanently routed to a child session.
printf '%s\n' '---' 'agent: Build+' 'subtask: true' '---' 'stale body' >"${COMMAND_DIR}/review-issue-pr.md"

_generate_hardcoded_quality_commands "opencode" "$COMMAND_DIR"
[[ "$_GENERATED_HARDCODED_COMMAND_COUNT" -eq 4 ]] || {
	printf 'FAIL expected four generated quality commands, got %s\n' "$_GENERATED_HARDCODED_COMMAND_COUNT" >&2
	exit 1
}
grep -Fq 'agent: Build+' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not target Build+\n' >&2
	exit 1
}
if grep -Fq 'subtask: true' "${COMMAND_DIR}/review-issue-pr.md"; then
	printf 'FAIL review command still forces a child session\n' >&2
	exit 1
fi
grep -Fq 'workflows/review-issue-pr.md' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL stale review command body was not refreshed\n' >&2
	exit 1
}
grep -Fq 'workflows/review.md' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not load the shared review policy\n' >&2
	exit 1
}
grep -Fq 'End every completed review with the exact ready-to-run approval command' "${COMMAND_DIR}/review-issue-pr.md" || {
	printf 'FAIL review command does not require approval command output\n' >&2
	exit 1
}
grep -Fq 'subtask: true' "${COMMAND_DIR}/agent-review.md" || {
	printf 'FAIL unrelated subtask routing was removed\n' >&2
	exit 1
}

_generate_hardcoded_commands "opencode" "$COMMAND_DIR" || {
	printf 'FAIL successful hardcoded generation returned nonzero\n' >&2
	exit 1
}
[[ "$_GENERATED_HARDCODED_COMMAND_COUNT" -eq 7 ]] || {
	printf 'FAIL expected seven total hardcoded commands, got %s\n' "$_GENERATED_HARDCODED_COMMAND_COUNT" >&2
	exit 1
}

# The one-release fallback generator must preserve the same routing contract.
create_command() {
	local name="$1"
	local description="$2"
	local agent="$3"
	local subtask="$4"
	local body
	body=$(cat)
	printf '%s|%s|%s|%s|%s\n' "$name" "$description" "$agent" "$subtask" "$body" >>"$CALL_LOG"
	return 0
}
AGENT_BUILD="Build+"
# shellcheck source=../generate-opencode-commands-quality.sh
source "$LEGACY_LIB"
define_review_commands

grep -Fq 'review-issue-pr|Review external issue or PR - validate problem and evaluate solution|Build+||' "$CALL_LOG" || {
	printf 'FAIL fallback generator still marks review-issue-pr as a subtask\n' >&2
	exit 1
}
grep -Fq 'workflows/review.md' "$CALL_LOG" || {
	printf 'FAIL fallback generator does not load the shared review policy\n' >&2
	exit 1
}
grep -Fq 'End every completed review with the exact ready-to-run approval command' "$CALL_LOG" || {
	printf 'FAIL fallback generator does not require approval command output\n' >&2
	exit 1
}
grep -Fq 'agent-review|Systematic review and improvement of agent instructions|Build+|true|' "$CALL_LOG" || {
	printf 'FAIL fallback generator changed unrelated subtask routing\n' >&2
	exit 1
}

printf 'PASS review-issue-pr command routing stays in the parent session\n'
exit 0
