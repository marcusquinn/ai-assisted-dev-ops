#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Test suite for gh-status-helper.sh — verifies status and component subcommands
# (check, check-actions, incidents, correlate), all exit-code branches (operational,
# degraded, outage), the 60s response cache, and network-failure handling.
#
# The helper supports a mock interface via AIDEVOPS_GH_STATUS_MOCK_DIR — when
# set, _fetch reads canned API responses from that directory instead of
# calling curl. This test file owns three mock fixtures:
#   - operational:  status.json (none indicator) + empty incidents
#   - degraded:     status.json (major) + 1 incident
#   - outage:       status.json (critical) + 2 incidents
# Each fixture lives in its own subdir under MOCK_BASE so a test can
# point AIDEVOPS_GH_STATUS_MOCK_DIR at a specific scenario.
#
# Run: bash .agents/scripts/tests/test-gh-status-helper.sh
# Expected: all assertions pass; exit 0.

set -uo pipefail # NOT set -e — failed assertions print and continue

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../gh-status-helper.sh"

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		TESTS_PASSED=$((TESTS_PASSED + 1))
		printf '%bPASS%b %s\n' "$GREEN" "$NC" "$name"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%bFAIL%b %s — %s\n' "$RED" "$NC" "$name" "$detail"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Mock fixtures — minimal subset of the real Statuspage API schema
# ---------------------------------------------------------------------------

MOCK_BASE=$(mktemp -d -t gh-status-test.XXXXXX)
trap 'rm -rf "$MOCK_BASE"' EXIT

# operational fixture — what githubstatus.com returns on a healthy day
mkdir -p "$MOCK_BASE/operational"
cat >"$MOCK_BASE/operational/status.json" <<'EOF'
{
  "page": {"id": "kctbh9vrtdwd", "name": "GitHub", "url": "https://www.githubstatus.com"},
  "status": {"indicator": "none", "description": "All Systems Operational"}
}
EOF

mkdir -p "$MOCK_BASE/malformed-incidents" "$MOCK_BASE/malformed-components"
printf '%s\n' '{"incidents":{"bad":{"components":[{"name":"Actions"}]}}}' >"$MOCK_BASE/malformed-incidents/unresolved.json"
printf '%s\n' '{"incidents":[{"name":"Bad schema","components":{"bad":{"name":"Actions"}}}]}' >"$MOCK_BASE/malformed-components/unresolved.json"
cat >"$MOCK_BASE/operational/unresolved.json" <<'EOF'
{"page": {"id": "kctbh9vrtdwd"}, "incidents": []}
EOF

# degraded fixture — single major-impact incident on Issues + Pull Requests
mkdir -p "$MOCK_BASE/degraded"
cat >"$MOCK_BASE/degraded/status.json" <<'EOF'
{
  "page": {"id": "kctbh9vrtdwd", "name": "GitHub"},
  "status": {"indicator": "major", "description": "Partial System Outage"}
}
EOF
cat >"$MOCK_BASE/degraded/unresolved.json" <<'EOF'
{
  "page": {"id": "kctbh9vrtdwd"},
  "incidents": [
    {
      "id": "abc123",
      "name": "Disruption with GitHub Search",
      "impact": "major",
      "started_at": "2026-04-27T20:00:00Z",
      "components": [
        {"id": "c1", "name": "Issues"},
        {"id": "c2", "name": "Pull Requests"}
      ],
      "incident_updates": [
        {"id": "u1", "body": "Investigating elevated latency on search backends.", "created_at": "2026-04-27T20:05:00Z"}
      ]
    }
  ]
}
EOF

# outage fixture — critical impact, 2 active incidents
mkdir -p "$MOCK_BASE/outage"
cat >"$MOCK_BASE/outage/status.json" <<'EOF'
{
  "page": {"id": "kctbh9vrtdwd", "name": "GitHub"},
  "status": {"indicator": "critical", "description": "Major Service Outage"}
}
EOF
cat >"$MOCK_BASE/outage/unresolved.json" <<'EOF'
{
  "page": {"id": "kctbh9vrtdwd"},
  "incidents": [
    {
      "id": "abc123",
      "name": "API Outage",
      "impact": "critical",
      "started_at": "2026-04-27T22:00:00Z",
      "components": [{"id": "c1", "name": "API Requests"}],
      "incident_updates": [{"id": "u1", "body": "API returning 5xx for all callers.", "created_at": "2026-04-27T22:01:00Z"}]
    },
    {
      "id": "def456",
      "name": "Webhooks Delayed",
      "impact": "major",
      "started_at": "2026-04-27T22:10:00Z",
      "components": [{"id": "c2", "name": "Webhooks"}, {"id": "c3", "name": "Actions"}],
      "incident_updates": [{"id": "u2", "body": "Webhook delivery queue backed up.", "created_at": "2026-04-27T22:12:00Z"}]
    }
  ]
}
EOF

# Each test sets its own cache dir so 60s TTL doesn't cross-contaminate.
_isolated_run() {
	local fixture="$1"
	shift
	local cache_dir
	cache_dir=$(mktemp -d -t gh-status-cache.XXXXXX)
	AIDEVOPS_GH_STATUS_MOCK_DIR="$MOCK_BASE/$fixture" \
		AIDEVOPS_GH_STATUS_CACHE_DIR="$cache_dir" \
		bash "$HELPER" "$@"
	local rc=$?
	rm -rf "$cache_dir"
	return "$rc"
}

# ---------------------------------------------------------------------------
# check subcommand — exit codes and labels
# ---------------------------------------------------------------------------

test_check_operational_returns_0() {
	local out rc
	out=$(_isolated_run operational check 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "check operational → exit 0" 1 "got rc=$rc"
		return 0
	fi
	print_result "check operational → exit 0" 0
	if [[ "$out" != *"operational"* ]]; then
		print_result "check operational summary contains 'operational'" 1 "got: $out"
		return 0
	fi
	print_result "check operational summary contains 'operational'" 0
	return 0
}

test_check_degraded_returns_1() {
	local out rc
	out=$(_isolated_run degraded check 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 1 ]]; then
		print_result "check degraded → exit 1" 1 "got rc=$rc"
		return 0
	fi
	print_result "check degraded → exit 1" 0
	if [[ "$out" != *"degraded"* ]]; then
		print_result "check degraded summary contains 'degraded'" 1 "got: $out"
		return 0
	fi
	print_result "check degraded summary contains 'degraded'" 0
	return 0
}

test_check_outage_returns_2() {
	local out rc
	out=$(_isolated_run outage check 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 2 ]]; then
		print_result "check outage → exit 2" 1 "got rc=$rc"
		return 0
	fi
	print_result "check outage → exit 2" 0
	if [[ "$out" != *"outage"* ]]; then
		print_result "check outage summary contains 'outage'" 1 "got: $out"
		return 0
	fi
	print_result "check outage summary contains 'outage'" 0
	return 0
}

test_check_json_output() {
	local out
	out=$(_isolated_run operational check --json 2>/dev/null)
	# Must be valid JSON
	if ! printf '%s' "$out" | jq empty 2>/dev/null; then
		print_result "check --json emits valid JSON" 1 "got: $out"
		return 0
	fi
	print_result "check --json emits valid JSON" 0
	# Must have status field
	local status
	status=$(printf '%s' "$out" | jq -r '.status')
	if [[ "$status" != "operational" ]]; then
		print_result "check --json status='operational'" 1 "got: $status"
		return 0
	fi
	print_result "check --json status='operational'" 0
	return 0
}

test_check_actions_component_status() {
	local out rc
	out=$(_isolated_run operational check-actions --json 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 0 || "$(printf '%s' "$out" | jq -r '.status')" != "operational" ]]; then
		print_result "check-actions healthy component → operational" 1 "rc=$rc out=$out"
	else
		print_result "check-actions healthy component → operational" 0
	fi

	out=$(_isolated_run degraded check-actions --json 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 0 || "$(printf '%s' "$out" | jq -r '.status')" != "operational" ]]; then
		print_result "check-actions ignores unrelated incidents" 1 "rc=$rc out=$out"
	else
		print_result "check-actions ignores unrelated incidents" 0
	fi

	out=$(_isolated_run outage check-actions --json 2>/dev/null)
	rc=$?
	if [[ "$rc" -ne 1 || "$(printf '%s' "$out" | jq -r '.status')" != "incident" ]]; then
		print_result "check-actions active incident → exit 1" 1 "rc=$rc out=$out"
	else
		print_result "check-actions active incident → exit 1" 0
	fi
	return 0
}

test_check_actions_malformed_schema_fails_open() {
	local fixture out rc
	for fixture in malformed-incidents malformed-components; do
		out=$(_isolated_run "$fixture" check-actions --json 2>/dev/null)
		rc=$?
		if [[ "$rc" -ne 3 ]]; then
			print_result "check-actions malformed ${fixture} schema → exit 3" 1 "rc=$rc out=$out"
		else
			print_result "check-actions malformed ${fixture} schema → exit 3" 0
		fi
	done
	return 0
}

# ---------------------------------------------------------------------------
# incidents subcommand
# ---------------------------------------------------------------------------

test_incidents_empty_when_operational() {
	local out
	out=$(_isolated_run operational incidents 2>/dev/null)
	if [[ "$out" != *"No active incidents"* ]]; then
		print_result "incidents (operational) shows empty marker" 1 "got: $out"
		return 0
	fi
	print_result "incidents (operational) shows empty marker" 0
	return 0
}

test_incidents_lists_when_degraded() {
	local out
	out=$(_isolated_run degraded incidents 2>/dev/null)
	if [[ "$out" != *"Disruption with GitHub Search"* ]]; then
		print_result "incidents (degraded) shows incident name" 1 "got: $out"
		return 0
	fi
	print_result "incidents (degraded) shows incident name" 0
	if [[ "$out" != *"Issues"* ]] || [[ "$out" != *"Pull Requests"* ]]; then
		print_result "incidents (degraded) lists components" 1 "got: $out"
		return 0
	fi
	print_result "incidents (degraded) lists components" 0
	return 0
}

test_incidents_json_array() {
	local out count
	out=$(_isolated_run outage incidents --json 2>/dev/null)
	if ! printf '%s' "$out" | jq empty 2>/dev/null; then
		print_result "incidents --json emits valid JSON" 1 "got: $out"
		return 0
	fi
	print_result "incidents --json emits valid JSON" 0
	count=$(printf '%s' "$out" | jq '.incidents | length')
	if [[ "$count" != "2" ]]; then
		print_result "incidents --json (outage) count=2" 1 "got: $count"
		return 0
	fi
	print_result "incidents --json (outage) count=2" 0
	return 0
}

# ---------------------------------------------------------------------------
# correlate subcommand
# ---------------------------------------------------------------------------

test_correlate_emits_marker() {
	local out
	out=$(_isolated_run degraded correlate 2>/dev/null)
	if [[ "$out" != *"<!-- aidevops:gh-status-correlation -->"* ]]; then
		print_result "correlate emits HTML marker" 1 "got: $out"
		return 0
	fi
	print_result "correlate emits HTML marker" 0
	if [[ "$out" != *"Disruption with GitHub Search"* ]]; then
		print_result "correlate includes incident name" 1 "got: $out"
		return 0
	fi
	print_result "correlate includes incident name" 0
	return 0
}

test_correlate_operational_no_incidents_block() {
	local out
	out=$(_isolated_run operational correlate 2>/dev/null)
	if [[ "$out" == *"Active incidents:"* ]]; then
		print_result "correlate (operational) omits 'Active incidents'" 1 "got: $out"
		return 0
	fi
	print_result "correlate (operational) omits 'Active incidents'" 0
	return 0
}

# ---------------------------------------------------------------------------
# Cache and network-failure behaviour
# ---------------------------------------------------------------------------

test_cache_writes_files() {
	local cache_dir
	cache_dir=$(mktemp -d -t gh-status-cache-write.XXXXXX)
	AIDEVOPS_GH_STATUS_MOCK_DIR="$MOCK_BASE/operational" \
		AIDEVOPS_GH_STATUS_CACHE_DIR="$cache_dir" \
		bash "$HELPER" check >/dev/null 2>&1 || true
	if [[ ! -f "$cache_dir/gh-status-status.json" ]]; then
		print_result "cache writes status.json" 1 "missing $cache_dir/gh-status-status.json"
		rm -rf "$cache_dir"
		return 0
	fi
	print_result "cache writes status.json" 0
	rm -rf "$cache_dir"
	return 0
}

test_network_failure_returns_3() {
	local empty_dir cache_dir rc out
	empty_dir=$(mktemp -d -t gh-status-mock-empty.XXXXXX)
	cache_dir=$(mktemp -d -t gh-status-cache-fail.XXXXXX)
	# Empty mock dir → _fetch returns 1 → cmd_check returns 3
	out=$(AIDEVOPS_GH_STATUS_MOCK_DIR="$empty_dir" \
		AIDEVOPS_GH_STATUS_CACHE_DIR="$cache_dir" \
		bash "$HELPER" check 2>&1)
	rc=$?
	rm -rf "$empty_dir" "$cache_dir"
	if [[ "$rc" -ne 3 ]]; then
		print_result "check on network failure → exit 3" 1 "got rc=$rc out=$out"
		return 0
	fi
	print_result "check on network failure → exit 3" 0
	return 0
}

# ---------------------------------------------------------------------------
# CLI argument handling
# ---------------------------------------------------------------------------

test_help_flag_returns_0() {
	local rc
	bash "$HELPER" --help >/dev/null 2>&1
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		print_result "--help → exit 0" 1 "got rc=$rc"
		return 0
	fi
	print_result "--help → exit 0" 0
	return 0
}

test_unknown_arg_returns_64() {
	local rc
	bash "$HELPER" --bogus-flag >/dev/null 2>&1
	rc=$?
	if [[ "$rc" -ne 64 ]]; then
		print_result "unknown flag → exit 64 (EX_USAGE)" 1 "got rc=$rc"
		return 0
	fi
	print_result "unknown flag → exit 64 (EX_USAGE)" 0
	return 0
}

test_no_subcommand_returns_64() {
	local rc
	bash "$HELPER" >/dev/null 2>&1
	rc=$?
	if [[ "$rc" -ne 64 ]]; then
		print_result "no subcommand → exit 64" 1 "got rc=$rc"
		return 0
	fi
	print_result "no subcommand → exit 64" 0
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

_run_tests() {
	test_check_operational_returns_0
	test_check_degraded_returns_1
	test_check_outage_returns_2
	test_check_json_output
	test_check_actions_component_status
	test_check_actions_malformed_schema_fails_open
	test_incidents_empty_when_operational
	test_incidents_lists_when_degraded
	test_incidents_json_array
	test_correlate_emits_marker
	test_correlate_operational_no_incidents_block
	test_cache_writes_files
	test_network_failure_returns_3
	test_help_flag_returns_0
	test_unknown_arg_returns_64
	test_no_subcommand_returns_64

	printf '\n======================================\n'
	printf 'Tests run:    %d\n' "$TESTS_RUN"
	printf 'Tests passed: %d\n' "$TESTS_PASSED"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	printf '======================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

_run_tests
