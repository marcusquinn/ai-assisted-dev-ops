#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#25329: gh-failure-miner CodeFactor clusters must
# render worker-ready guidance instead of generic workflow/toolchain advice.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected to find: %s\n' "$(printf '%q' "$needle")"
		printf '  in output:        %s\n' "$(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_equals() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n' "$(printf '%q' "$expected")"
		printf '  actual:   %s\n' "$(printf '%q' "$actual")"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="$SCRIPT_DIR/gh-failure-miner-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf '%sFATAL%s: %s not found\n' "$TEST_RED" "$TEST_NC" "$HELPER" >&2
	exit 1
fi

# Source with a harmless command so helper functions remain available without
# making live GitHub API calls.
set -- help
# shellcheck source=/dev/null
source "$HELPER" >/dev/null

gh() {
	local _api="${1:-}" _paginate="${2:-}" _endpoint="${3:-}" _jq_flag="${4:-}" _jq_expr="${5:-}"
	if [[ "${GH_MODE:-success}" == "fail" ]]; then
		printf '%s\n' "simulated gh api failure" >&2
		return 1
	fi
	if [[ "$_api" == "api" && "$_paginate" == "--paginate" && "$_endpoint" == "repos/marcusquinn/aidevops/pulls/25324/files?per_page=100" && "$_jq_flag" == "--jq" && "$_jq_expr" == ".[].filename" ]]; then
		printf '%s\n' ".agents/scripts/vault-helper.sh" ".agents/scripts/vault-crypto-helper.py" ".agents/scripts/vault-helper.sh"
		return 0
	fi
	if [[ "$_api" == "api" && "$_paginate" == "--paginate" && "$_endpoint" == "repos/marcusquinn/aidevops/check-runs/123/annotations?per_page=100" && "$_jq_flag" == "--jq" ]]; then
		printf '%s\n' '{"path":".agents/scripts/vault-crypto-helper.py","start_line":119,"annotation_level":"warning","title":"Bandit B603","message":"subprocess call: check for execution of untrusted input"}'
		return 0
	fi
	if [[ "$_api" == "api" && "$_paginate" == "repos/marcusquinn/aidevops/pulls/25324" ]]; then
		printf '%s\n' '{"state":"open","head":{"sha":"abc123"}}'
		return 0
	fi
	if [[ "$_api" == "api" && "$_paginate" == "repos/marcusquinn/aidevops/pulls/25319" ]]; then
		printf '%s\n' '{"state":"closed","head":{"sha":"def456"}}'
		return 0
	fi
	return 1
}

cluster_json=$(
	cat <<'JSON'
{
  "repo": "marcusquinn/aidevops",
  "check_name": "CodeFactor",
  "signature": "failure:codefactor.io",
  "count": 3,
  "is_infra": false,
  "sources": ["pr:#25324", "pr:#25319", "pr:#25305"],
  "examples": [
    {
      "source_kind": "pr",
      "source_ref": "#25324",
      "source_url": "https://github.com/marcusquinn/aidevops/pull/25324",
      "run_url": "https://github.com/marcusquinn/aidevops/runs/82536587204",
      "details_url": "https://www.codefactor.io/repository/github/marcusquinn/aidevops/pull/25324",
      "affected_paths": [".agents/scripts/vault-crypto-helper.py", ".agents/scripts/vault-helper.sh"],
      "annotations": [{"path":".agents/scripts/vault-crypto-helper.py","start_line":119,"title":"Bandit B603","message":"subprocess call: check for execution of untrusted input"}],
      "conclusion": "failure"
    }
  ]
}
JSON
)

qlty_empty_sarif_cluster_json='{
  "repo": "marcusquinn/aidevops",
  "check_name": "Qlty Smell Threshold",
  "signature": "Failed to run qlty smells (empty SARIF output)",
  "count": 2,
  "is_infra": false,
  "sources": ["pr:#26016", "pr:#26015"],
  "examples": [
    {
      "source_kind": "pr",
      "source_ref": "#26016",
      "source_url": "https://github.com/marcusquinn/aidevops/pull/26016",
      "run_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
      "details_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
      "affected_paths": [],
      "annotations": [],
      "conclusion": "failure"
    }
  ]
}'

qlty_empty_sarif_events_json='[
  {
    "repo": "marcusquinn/aidevops",
    "source_kind": "pr",
    "source_ref": "#26016",
    "source_url": "https://github.com/marcusquinn/aidevops/pull/26016",
    "check_name": "Qlty Smell Threshold",
    "signature": "Failed to run qlty smells (empty SARIF output)",
    "run_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
    "details_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
    "affected_paths": [],
    "annotations": [],
    "conclusion": "failure"
  },
  {
    "repo": "marcusquinn/aidevops",
    "source_kind": "pr",
    "source_ref": "#26015",
    "source_url": "https://github.com/marcusquinn/aidevops/pull/26015",
    "check_name": "Qlty Smell Threshold",
    "signature": "Failed to run qlty smells (empty SARIF output)",
    "run_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
    "details_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
    "affected_paths": [],
    "annotations": [],
    "conclusion": "failure"
  }
]'

qlty_decorated_empty_sarif_cluster_json='{
  "repo": "marcusquinn/aidevops",
  "check_name": "Qlty Smell Threshold",
  "signature": "Qlty Smell Threshold Qlty smell threshold check 2026-06-30T10:13:09.8159029Z echo ::error::Failed to run qlty smells (empty SARIF output)",
  "count": 2,
  "is_infra": false,
  "sources": ["pr:#26016", "pr:#26015"],
  "examples": [
    {
      "source_kind": "pr",
      "source_ref": "#26016",
      "source_url": "https://github.com/marcusquinn/aidevops/pull/26016",
      "run_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
      "details_url": "https://github.com/marcusquinn/aidevops/actions/runs/28436868573/job/84264809560",
      "affected_paths": [],
      "annotations": [],
      "conclusion": "failure"
    }
  ]
}'

empty_evidence_cluster_json=$(
	cat <<'JSON'
{
  "repo": "marcusquinn/aidevops",
  "check_name": "ShellCheck",
  "signature": "failure:shellcheck",
  "count": 2,
  "is_infra": false,
  "sources": [],
  "examples": []
}
JSON
)

events_json=$(
	cat <<'JSON'
[
  {
    "repo": "marcusquinn/aidevops",
    "source_kind": "pr",
    "source_ref": "#25324",
    "source_url": "https://github.com/marcusquinn/aidevops/pull/25324",
    "check_name": "CodeFactor",
    "signature": "failure:codefactor.io",
    "run_url": "https://github.com/marcusquinn/aidevops/runs/82536587204",
    "details_url": "https://www.codefactor.io/repository/github/marcusquinn/aidevops/pull/25324",
    "affected_paths": [".agents/scripts/vault-crypto-helper.py", ".agents/scripts/vault-helper.sh"],
    "annotations": [{"path":".agents/scripts/vault-crypto-helper.py","start_line":119,"title":"Bandit B603","message":"subprocess call: check for execution of untrusted input"}],
    "conclusion": "failure"
  }
]
JSON
)

body=$(build_issue_body "$cluster_json" "46250abc5695" "2" "false")
qlty_body=$(build_issue_body "$qlty_empty_sarif_cluster_json" "d627959fbedf" "2" "false")
qlty_decorated_body=$(build_issue_body "$qlty_decorated_empty_sarif_cluster_json" "595a224919c1" "2" "false")
legacy_body=$(render_issue_body_markdown "$events_json" "2")
legacy_qlty_body=$(render_issue_body_markdown "[$qlty_decorated_empty_sarif_cluster_json]" "2")
qlty_skip_output=$(create_systemic_issues "$qlty_empty_sarif_events_json" "2" "3" "true" "auto-dispatch" 2>&1)
if empty_evidence_output=$(create_or_preview_issue "$empty_evidence_cluster_json" "abc123" "2" "true" "false" 2>&1); then
	empty_evidence_status=0
else
	empty_evidence_status=$?
fi
paths_json=$(fetch_pr_changed_paths_json "marcusquinn/aidevops" "25324")
annotations_json=$(fetch_check_run_annotations_summary_json "marcusquinn/aidevops" "123")
mixed_annotation_signature=$(codefactor_signature_from_annotations '[{"annotation_level":"notice","message":"Starting a process with a partial executable path (B607)"},{"annotation_level":"warning","message":"subprocess call - check for execution of untrusted input. (B603)"}]')
GH_MODE=fail
failed_paths_json=$(fetch_pr_changed_paths_json "marcusquinn/aidevops" "25324")
failed_annotations_json=$(fetch_check_run_annotations_summary_json "marcusquinn/aidevops" "123")
GH_MODE=success
open_source=$(resolve_source_from_subject "https://api.github.com/repos/marcusquinn/aidevops/pulls/25324" "marcusquinn/aidevops" "false")
if closed_source=$(resolve_source_from_subject "https://api.github.com/repos/marcusquinn/aidevops/pulls/25319" "marcusquinn/aidevops" "false"); then
	closed_source_status=0
else
	closed_source_status=$?
fi

failed_runs_json=$(
	cat <<'JSON'
[
  {
    "name": "CodeFactor",
    "id": 123,
    "conclusion": "failure",
    "details_url": "https://www.codefactor.io/repository/github/marcusquinn/aidevops/pull/25324",
    "html_url": "https://github.com/marcusquinn/aidevops/runs/82536587204",
    "completed_at": "2026-06-26T07:00:00Z",
    "app": {"name": "codefactor.io"}
  },
  {
    "name": "ShellCheck",
    "conclusion": "failure",
    "details_url": "https://github.com/marcusquinn/aidevops/actions/runs/82536587205/job/1",
    "html_url": "https://github.com/marcusquinn/aidevops/runs/82536587205",
    "completed_at": "2026-06-26T07:01:00Z",
    "app": {"name": "GitHub Actions"}
  }
]
JSON
)
checks_json=$(
	cat <<'JSON'
{"check_runs":[]}
JSON
)
event_file=$(mktemp)
process_failed_runs "$failed_runs_json" "marcusquinn/aidevops" "pr" "#25324" "https://github.com/marcusquinn/aidevops/pull/25324" \
	"25324" "46250abc5695" "2026-06-26T07:02:00Z" "false" "0" "0" "$event_file" "$checks_json" >/dev/null
mined_events_json=$(jq -s '.' "$event_file")
codefactor_paths_json=$(printf '%s\n' "$mined_events_json" | jq -c '.[0].affected_paths')
codefactor_annotations_json=$(printf '%s\n' "$mined_events_json" | jq -c '.[0].annotations')
shellcheck_paths_json=$(printf '%s\n' "$mined_events_json" | jq -c '.[1].affected_paths')
rm -f "$event_file"

assert_contains "build_issue_body includes Worker Guidance" "## Worker Guidance" "$body"
assert_contains "build_issue_body directs workers to CodeFactor details" "Open the CodeFactor details URL from Evidence first" "$body"
assert_contains "build_issue_body includes affected file fallback" "affected files: .agents/scripts/vault-crypto-helper.py, .agents/scripts/vault-helper.sh" "$body"
assert_contains "build_issue_body includes CodeFactor annotations" "reported findings: .agents/scripts/vault-crypto-helper.py:119 — Bandit B603" "$body"
assert_contains "build_issue_body handles unavailable details" "If CodeFactor details are unavailable" "$body"
assert_contains "build_issue_body preserves failure signature context" "failure:codefactor.io" "$body"
assert_contains "build_issue_body asks for focused regression guard" "focused regression guard" "$body"
assert_contains "build_issue_body includes Qlty Worker Guidance" "## Worker Guidance" "$qlty_body"
assert_contains "build_issue_body classifies qlty empty SARIF as shared tooling" "empty-SARIF failures are shared tooling failures" "$qlty_body"
assert_contains "build_issue_body points qlty workers at helper" ".agents/scripts/qlty-smell-threshold-helper.sh" "$qlty_body"
assert_contains "build_issue_body preserves qlty ratchet semantics" "Keep valid SARIF output blocking" "$qlty_body"
assert_contains "build_issue_body classifies decorated qlty empty SARIF signature" "empty-SARIF failures are shared tooling failures" "$qlty_decorated_body"
assert_contains "build_issue_body decorated qlty points at helper" ".agents/scripts/qlty-smell-threshold-helper.sh" "$qlty_decorated_body"
assert_equals "create_or_preview_issue rejects no-evidence clusters" "1" "$empty_evidence_status"
assert_contains "create_or_preview_issue explains no-evidence skip" "no evidence examples" "$empty_evidence_output"
assert_contains "render_issue_body_markdown includes Worker Guidance" "## Worker Guidance" "$legacy_body"
assert_contains "render_issue_body_markdown directs workers to provider details" "details URL" "$legacy_body"
assert_contains "render_issue_body_markdown includes affected file fallback" "affected files: .agents/scripts/vault-crypto-helper.py, .agents/scripts/vault-helper.sh" "$legacy_body"
assert_contains "render_issue_body_markdown classifies decorated qlty empty SARIF" "empty-SARIF failures are shared tooling failures" "$legacy_qlty_body"
assert_contains "render_issue_body_markdown qlty guidance points at helper" ".agents/scripts/qlty-smell-threshold-helper.sh" "$legacy_qlty_body"
assert_contains "create_systemic_issues skips remediated qlty empty SARIF clusters" "empty SARIF failure signature is already handled" "$qlty_skip_output"
assert_contains "create_systemic_issues reports zero created for remediated qlty empty SARIF" "Processed 0 systemic cluster(s)" "$qlty_skip_output"
assert_contains "fetch_pr_changed_paths_json returns unique sorted paths" '[".agents/scripts/vault-crypto-helper.py",".agents/scripts/vault-helper.sh"]' "$paths_json"
assert_equals "fetch_pr_changed_paths_json emits one JSON array on gh failure" '[]' "$failed_paths_json"
assert_equals "fetch_check_run_annotations_summary_json returns provider annotations" '[{"path":".agents/scripts/vault-crypto-helper.py","start_line":119,"annotation_level":"warning","title":"Bandit B603","message":"subprocess call: check for execution of untrusted input"}]' "$annotations_json"
assert_equals "fetch_check_run_annotations_summary_json emits one JSON array on gh failure" '[]' "$failed_annotations_json"
assert_equals "CodeFactor signature selects the highest-severity finding" 'failure:codefactor.io:subprocess call - check for execution of untrusted input. (B603)' "$mixed_annotation_signature"
assert_equals "resolve_source_from_subject retains open PR failures" 'pr|#25324|https://github.com/marcusquinn/aidevops/pull/25324|25324||abc123' "$open_source"
assert_equals "resolve_source_from_subject rejects stale closed PR failures" "1" "$closed_source_status"
assert_equals "process_failed_runs attaches paths to CodeFactor failure" '[".agents/scripts/vault-crypto-helper.py",".agents/scripts/vault-helper.sh"]' "$codefactor_paths_json"
assert_equals "process_failed_runs attaches annotations to CodeFactor failure" '[{"path":".agents/scripts/vault-crypto-helper.py","start_line":119,"annotation_level":"warning","title":"Bandit B603","message":"subprocess call: check for execution of untrusted input"}]' "$codefactor_annotations_json"
assert_equals "process_failed_runs fingerprints CodeFactor findings" 'failure:codefactor.io:subprocess call: check for execution of untrusted input' "$(printf '%s\n' "$mined_events_json" | jq -r '.[0].signature')"
assert_equals "process_failed_runs does not leak CodeFactor paths to later checks" '[]' "$shellcheck_paths_json"

printf '\nTests run: %s\n' "$TESTS_RUN"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	printf 'Tests failed: %s\n' "$TESTS_FAILED" >&2
	exit 1
fi

printf '%sAll tests passed%s\n' "$TEST_GREEN" "$TEST_NC"
exit 0
