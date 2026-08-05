#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" || exit
MEMORY_HELPER="$REPO_ROOT/.agents/scripts/memory-helper.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	return 1
}

assert_json() {
	local json="$1"
	local expression="$2"
	local message="$3"
	printf '%s' "$json" | jq -e "$expression" >/dev/null || fail "$message"
	return 0
}

run_memory() {
	AIDEVOPS_MEMORY_DIR="$TEST_DIR" "$MEMORY_HELPER" "$@" || return 1
	return 0
}

recall_json() {
	local output
	output=$(run_memory recall "$@" --json) || return $?
	printf '%s' "${output##*$'\n'}"
	return 0
}

run_memory stats >/dev/null

sqlite3 "$TEST_DIR/memory.db" <<'EOF'
INSERT INTO learnings (id, session_id, content, type, tags, confidence, created_at, event_date, project_path, source)
VALUES ('mem_fixture_exact', 'session_fixture', 'Exact fixture phrase', 'WORKING_SOLUTION', 'fixture', 'high', '2026-08-05T12:00:00Z', '2026-08-05T12:00:00Z', '/fixture', 'manual');
INSERT INTO observations (observation_id, kind, session_id, framework_scope, state, statement, confidence, sensitivity, consent, destination, status, created_at)
VALUES ('obs_learning_mem_fixture_exact', 'working_solution', 'session_fixture', 'aidevops', 'explicit', 'Exact fixture phrase', 'high', 'internal', 'unspecified', 'memory', 'active', '2026-08-05T12:00:00Z');
INSERT INTO observations (observation_id, kind, session_id, framework_scope, state, statement, confidence, sensitivity, consent, destination, status, created_at)
VALUES ('obs_fixture_exact', 'decision', 'session_fixture', 'aidevops', 'explicit', 'Observation statement fixture', 'medium', 'internal', 'unspecified', 'memory', 'active', '2026-08-05T12:01:00Z');
INSERT INTO entities (id, name, type) VALUES ('ent_fixture', 'Fixture', 'agent');
INSERT INTO interactions (id, entity_id, channel, content, created_at)
VALUES ('mem_interaction_fixture', 'ent_fixture', 'cli', 'Interaction fixture', '2026-08-05T12:02:00Z');
INSERT INTO conversations (id, entity_id, channel, status) VALUES ('conv_fixture', 'ent_fixture', 'cli', 'closed');
INSERT INTO conversation_summaries (id, conversation_id, summary, source_range_start, source_range_end, created_at)
VALUES ('mem_summary_fixture', 'conv_fixture', 'Summary fixture', 'mem_interaction_fixture', 'mem_interaction_fixture', '2026-08-05T12:03:00Z');
EOF

learning_json=$(recall_json --query mem_fixture_exact)
assert_json "$learning_json" 'length == 1 and .[0].id == "mem_fixture_exact" and .[0].record_kind == "learning"' "exact learning ID was not returned"

observation_json=$(recall_json --query obs_fixture_exact)
assert_json "$observation_json" 'length == 1 and .[0].observation_id == "obs_fixture_exact" and .[0].statement == "Observation statement fixture" and .[0].content == .[0].statement' "exact observation ID did not include its statement"

interaction_json=$(recall_json --query mem_interaction_fixture)
assert_json "$interaction_json" 'length == 1 and .[0].record_kind == "interaction" and .[0].content == "Interaction fixture"' "exact interaction ID was not normalized"

summary_json=$(recall_json --query mem_summary_fixture)
assert_json "$summary_json" 'length == 1 and .[0].record_kind == "conversation_summary" and .[0].content == "Summary fixture"' "exact conversation summary ID was not normalized"

missing_json=$(recall_json --query mem_missing_fixture)
assert_json "${missing_json:-[]}" 'length == 0' "missing exact ID fell through to full-text search"

fts_json=$(recall_json --query "Exact fixture phrase")
assert_json "$fts_json" 'length == 1 and .[0].id == "mem_fixture_exact"' "non-ID recall no longer uses full-text search"

printf 'PASS: exact memory, observation, interaction, and summary ID recall\n'
