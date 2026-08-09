#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SH="${SCRIPT_DIR}/../report-token-use-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local _test_name="$1"
	local _passed="$2"
	local _message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$_test_name"
		return 0
	fi
	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$_test_name"
	if [[ -n "$_message" ]]; then
		printf '       %s\n' "$_message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

create_fixture_dbs() {
	local _opencode_db="${TEST_ROOT}/opencode.db"
	local _obs_db="${TEST_ROOT}/llm-requests.db"
	rm -f "$_opencode_db" "$_obs_db"
	sqlite3 "$_opencode_db" <<'SQL'
CREATE TABLE session (
  id text PRIMARY KEY,
  parent_id text,
  title text NOT NULL,
  model text,
  tokens_input integer DEFAULT 0,
  tokens_output integer DEFAULT 0,
  tokens_reasoning integer DEFAULT 0,
  tokens_cache_read integer DEFAULT 0,
  tokens_cache_write integer DEFAULT 0,
  cost real DEFAULT 0,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  time_compacting integer,
  directory text,
  path text,
  agent text
);
CREATE TABLE session_message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  type text NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
INSERT INTO session VALUES ('ses_root', NULL, 'Root Session', '{"id":"gpt-5.5","providerID":"openai","variant":"high"}', 100, 20, 5, 30, 7, 0.25, 1700000000000, 1700000100000, NULL, '/repo', '/repo', 'Build+');
INSERT INTO session VALUES ('ses_child', 'ses_root', 'Compacted Child', '{"id":"claude-sonnet-4-6","providerID":"anthropic"}', 50, 10, 0, 5, 0, 0.10, 1700000100000, 1700000200000, NULL, '/repo', '/repo', 'Build+');
INSERT INTO session_message VALUES ('msg1', 'ses_root', 'model-switched', 1700000000000, 1700000000000, '{"model":{"id":"gpt-5.5","providerID":"openai","variant":"high"}}');
SQL
	sqlite3 "$_obs_db" <<'SQL'
CREATE TABLE llm_requests (session_id text, model_id text);
CREATE TABLE tool_calls (session_id text, tool_name text);
INSERT INTO llm_requests VALUES ('ses_root', 'gpt-5.5');
INSERT INTO llm_requests VALUES ('ses_child', 'claude-sonnet-4-6');
INSERT INTO tool_calls VALUES ('ses_root', 'context7_lookup');
SQL
	cat >"${TEST_ROOT}/opencode.json" <<'JSON'
{"mcp":{"context7":{"enabled":true}}}
JSON
	return 0
}

assert_json_field() {
	local _json_file="$1"
	local _expr="$2"
	local _expected="$3"
	local _label="$4"
	local _actual
	_actual=$(
		python3 - "$_json_file" "$_expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
for part in expr.split('.'):
    if part.endswith(']'):
        name, index = part[:-1].split('[')
        if name:
            value = value[name]
        value = value[int(index)]
    else:
        value = value[part]
print(value)
PY
	)
	if [[ "$_actual" == "$_expected" ]]; then
		print_result "$_label" 0
		return 0
	fi
	print_result "$_label" 1 "expected '${_expected}', got '${_actual}'"
	return 0
}

assert_session_field() {
	local _json_file="$1"
	local _session_id="$2"
	local _field="$3"
	local _expected="$4"
	local _label="$5"
	local _actual
	_actual=$(
		python3 - "$_json_file" "$_session_id" "$_field" <<'PY'
import json
import sys

path, session_id, field = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    sessions = json.load(handle)["sessions"]
for session in sessions:
    if session["session_id"] == session_id:
        print(session[field])
        break
else:
    raise SystemExit(f"session {session_id!r} not found")
PY
	)
	if [[ "$_actual" == "$_expected" ]]; then
		print_result "$_label" 0
		return 0
	fi
	print_result "$_label" 1 "expected '${_expected}', got '${_actual}'"
	return 0
}

test_report_aggregates_compacted_sessions() {
	create_fixture_dbs
	local _output
	_output=$(AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB="${TEST_ROOT}/opencode.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OBS_DB="${TEST_ROOT}/llm-requests.db" \
		AIDEVOPS_REPORT_TOKEN_USE_ROOT="${TEST_ROOT}/reports" \
		AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG="${TEST_ROOT}/opencode.json" \
		"$HELPER_SH" report --limit 5 --daily-days 2000 --json)
	local _json_path
	_json_path=$(
		python3 - <<PY
import json
data = json.loads('''${_output}''')
print(data['report_json'])
PY
	)
	assert_json_field "$_json_path" "session_count" "1" "Report groups root and compacted child"
	assert_json_field "$_json_path" "sessions[0].tokens_input" "150" "Report sums input tokens"
	assert_json_field "$_json_path" "sessions[0].tokens_output" "30" "Report sums output tokens"
	assert_json_field "$_json_path" "sessions[0].tokens_cache_read" "35" "Report sums cached-read tokens"
	assert_json_field "$_json_path" "sessions[0].raw_tokens_total" "227" "Report computes raw total"
	assert_json_field "$_json_path" "sessions[0].net_tokens_total" "192" "Report computes net total excluding cache reads"
	assert_json_field "$_json_path" "sessions[0].session_kind" "interactive" "Report classifies repo session as interactive"
	assert_json_field "$_json_path" "usage_by_session_kind[0].session_kind" "interactive" "Report summarizes interactive usage"
	assert_json_field "$_json_path" "sessions[0].compaction_count" "1" "Report counts child compaction"
	assert_json_field "$_json_path" "sessions[0].mcps_observed[0]" "context7" "Report infers observed MCP"
	assert_json_field "$_json_path" "sessions[0].cost_usd" "0.35" "Report retains session cost fallback without observability cost"
	assert_json_field "$_json_path" "sessions[0].cost_provenance" "opencode_session.cost" "Report identifies session cost fallback"
	assert_json_field "$_json_path" "daily_usage[0].date" "2023-11-14" "Report includes daily usage date"
	assert_json_field "$_json_path" "daily_usage[0].net_tokens_total" "192" "Report sums daily net tokens"
	assert_json_field "$_json_path" "daily_usage[0].interactive_net_tokens_total" "192" "Report sums daily interactive net tokens"
	assert_json_field "$_json_path" "daily_usage[0].headless_worker_net_tokens_total" "0" "Report defaults daily headless net tokens"
	return 0
}

test_report_summarizes_headless_workers() {
	create_fixture_dbs
	sqlite3 "${TEST_ROOT}/opencode.db" <<'SQL'
INSERT INTO session VALUES ('ses_worker', NULL, 'Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 10, 2, 1, 4, 1, 0.05, 1699999900000, 1699999950000, NULL, '/private/tmp/opencode', 'private/tmp/opencode', 'Build+');
INSERT INTO session VALUES ('ses_windows_worker', NULL, 'Windows Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 6, 2, 0, 3, 1, 0.03, 1699999800000, 1699999850000, NULL, 'C:\Users\Example\AppData\Local\Temp\OpenCode', 'C:\Users\Example\AppData\Local\Temp\OpenCode\session.json', 'Build+');
INSERT INTO session VALUES ('ses_split_windows_worker', NULL, 'Split Windows Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 3, 1, 0, 1, 1, 0.01, 1699999700000, 1699999750000, NULL, 'C:\Users\Example\AppData\Local\Temp', 'OpenCode\session.json', 'Build+');
INSERT INTO session VALUES ('ses_relative_worker', NULL, 'Relative Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 4, 1, 0, 1, 1, 0.02, 1699999600000, 1699999650000, NULL, '', 'tmp/opencode/session.json', 'Build+');
INSERT INTO session VALUES ('ses_split_unix_worker', NULL, 'Split Unix Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 5, 1, 0, 1, 1, 0.02, 1699999500000, 1699999550000, NULL, '/tmp', 'opencode/session.json', 'Build+');
INSERT INTO session VALUES ('ses_double_slash_worker', NULL, 'Double Slash Unix Worker Session', '{"id":"gpt-5.5","providerID":"openai"}', 2, 1, 0, 1, 1, 0.01, 1699999400000, 1699999450000, NULL, '/tmp/', '/opencode/session.json', 'Build+');
SQL
	local _json_path="${TEST_ROOT}/data.json"
	AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB="${TEST_ROOT}/opencode.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OBS_DB="${TEST_ROOT}/llm-requests.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG="${TEST_ROOT}/opencode.json" \
		"$HELPER_SH" data --limit 10 --daily-days 2000 --json >"$_json_path"
	assert_json_field "$_json_path" "usage_by_session_kind[1].session_kind" "headless_worker" "Report summarizes headless worker usage"
	assert_json_field "$_json_path" "usage_by_session_kind[1].net_tokens_total" "45" "Report sums headless worker net tokens"
	assert_json_field "$_json_path" "daily_usage[0].headless_worker_net_tokens_total" "45" "Report sums daily headless worker net tokens"
	assert_json_field "$_json_path" "daily_usage[0].net_tokens_total" "237" "Report sums daily total net tokens"
	assert_json_field "$_json_path" "sessions[1].session_kind" "headless_worker" "Report classifies temp workdir session as headless worker"
	assert_json_field "$_json_path" "sessions[2].session_kind" "headless_worker" "Report classifies Windows temp workdir session as headless worker"
	assert_json_field "$_json_path" "sessions[3].session_kind" "headless_worker" "Report classifies split Windows temp workdir session as headless worker"
	assert_json_field "$_json_path" "sessions[4].session_kind" "headless_worker" "Report classifies relative temp path session as headless worker"
	assert_json_field "$_json_path" "sessions[5].session_kind" "headless_worker" "Report classifies split Unix temp path session as headless worker"
	assert_json_field "$_json_path" "sessions[6].session_kind" "headless_worker" "Report classifies double-slash Unix temp path session as headless worker"
	return 0
}

test_report_uses_observability_cost_and_lineage() {
	create_fixture_dbs
	sqlite3 "${TEST_ROOT}/opencode.db" <<'SQL'
INSERT INTO session VALUES ('ses_obs_root', NULL, 'Observability Root', '', 10, 2, 0, 0, 0, 0, 1700000300000, 1700000400000, NULL, '/repo', '/repo', 'Build+');
INSERT INTO session VALUES ('ses_obs_child', NULL, 'Observability Child', '', 5, 1, 0, 0, 0, 0, 1700000400000, 1700000500000, NULL, '/repo', '/repo', 'Compaction');
SQL
	sqlite3 "${TEST_ROOT}/llm-requests.db" <<'SQL'
ALTER TABLE llm_requests ADD COLUMN cost real;
ALTER TABLE llm_requests ADD COLUMN parent_session_id text;
ALTER TABLE llm_requests ADD COLUMN agent text;
INSERT INTO llm_requests (session_id, model_id, cost, parent_session_id, agent) VALUES ('ses_obs_root', 'gpt-5.6', 0.4, NULL, 'Build+');
INSERT INTO llm_requests (session_id, model_id, cost, parent_session_id, agent) VALUES ('ses_obs_child', 'gpt-5.6', 0.2, 'ses_obs_root', 'Compaction agent');
SQL
	local _json_path="${TEST_ROOT}/data.json"
	AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_DB="${TEST_ROOT}/opencode.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OBS_DB="${TEST_ROOT}/llm-requests.db" \
		AIDEVOPS_REPORT_TOKEN_USE_OPENCODE_CONFIG="${TEST_ROOT}/opencode.json" \
		"$HELPER_SH" data --limit 10 --daily-days 2000 --json >"$_json_path"
	assert_session_field "$_json_path" "ses_obs_root" "child_session_count" "1" "Report uses observability child lineage"
	assert_session_field "$_json_path" "ses_obs_root" "compaction_count" "1" "Report counts observability compaction agent"
	assert_session_field "$_json_path" "ses_obs_root" "cost_usd" "0.6" "Report uses observability request costs"
	assert_session_field "$_json_path" "ses_obs_root" "cost_provenance" "observability: llm_requests.cost" "Report records observability cost provenance"
	assert_session_field "$_json_path" "ses_obs_root" "lineage_provenance" "observability: llm_requests.parent_session_id" "Report records observability lineage provenance"
	assert_session_field "$_json_path" "ses_obs_root" "compaction_provenance" "combined: opencode_session + llm_requests.agent" "Report records compaction provenance"
	return 0
}

test_session_report_defaults_source_ids() {
	local _helper_py="${SCRIPT_DIR}/../report-token-use-helper.py"
	if python3 - "$_helper_py" <<'PY'; then
import importlib.util
import sys
from pathlib import Path

helper_path = sys.argv[1]
sys.path.insert(0, str(Path(helper_path).parent))
spec = importlib.util.spec_from_file_location("report_token_use_helper", helper_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

report = module._make_session_report(
    session_id="session-default",
    session_name="Default Source IDs",
    runtime="opencode",
    session_kind="interactive",
    models_used=["gpt-5.5"],
    tokens_input=1,
    tokens_output=2,
    tokens_reasoning=0,
    tokens_cache_read=0,
    tokens_cache_write=0,
    raw_tokens_total=3,
    net_tokens_total=3,
    child_session_count=0,
    compaction_count=0,
    mcps_active=[],
    mcps_observed=[],
    started_at="2026-01-01T00:00:00Z",
    finished_at="2026-01-01T00:01:00Z",
    cost_usd=0.01,
    request_count=1,
    tool_call_count=0,
)

if report.source_session_ids != []:
    raise SystemExit(f"expected default list, got {report.source_session_ids!r}")
PY
		print_result "SessionReport initializes default source_session_ids" 0
		return 0
	fi
	print_result "SessionReport initializes default source_session_ids" 1
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_report_aggregates_compacted_sessions
	test_report_summarizes_headless_workers
	test_report_uses_observability_cost_and_lineage
	test_session_report_defaults_source_ids
	printf '\nTests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
