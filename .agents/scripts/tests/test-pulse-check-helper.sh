#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-check-helper.sh — offline tests for pulse-check-helper.sh.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_contains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected to find: %s\n' "$needle"
	fi
	return 0
}

assert_not_contains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  did not expect to find: %s\n' "$needle"
	else
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	fi
	return 0
}

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual"
	fi
	return 0
}

assert_precedes() {
	local label="$1"
	local first="$2"
	local second="$3"
	local haystack="$4"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" == *"$first"*"$second"* ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '  expected %s before %s\n' "$first" "$second"
	fi
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${SCRIPT_DIR}/pulse-check-helper.sh"
CORE_ROUTINES="${SCRIPT_DIR}/routines/core-routines.sh"

if [[ ! -x "$HELPER" ]]; then
	printf '%sFATAL%s: helper not executable: %s\n' "$TEST_RED" "$TEST_NC" "$HELPER"
	exit 1
fi

TEST_ROOT="$(mktemp -d -t pulse-check-test-XXXXXX)"
BIN_DIR="${TEST_ROOT}/bin"
mkdir -p "$BIN_DIR"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

cat >"${TEST_ROOT}/repos.json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "private/repo-one", "pulse": true, "local_only": false},
    {"slug": "public/repo-two", "pulse": true, "local_only": false},
    {"slug": "ignored/local", "pulse": true, "local_only": true}
  ]
}
JSON

cat >"${TEST_ROOT}/current-state.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 12,
  "active_worker_processes": 0,
  "current_state_guardrails": {"available_slots_last": 6},
  "pulse_gauges": {"dispatch_capacity_final_max_workers": 6},
  "worker_outcomes": {"spawned": 4},
  "worker_terminal_events": 0,
  "canonical_reconciliation": {"refusal_count": 2, "classification": "dirty_or_uncommitted", "canonical_recovery_advisory_observed": true},
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state.sh"

cat >"${TEST_ROOT}/worker-activity.sh" <<'SH'
#!/usr/bin/env bash
cmd="${1:-}"
shift || true
if [[ "$cmd" == "providers" ]]; then
  cat <<'JSON'
{"provider_diagnostics":{"provider_model_usage":[],"recent_events":[],"account_pool":[{"provider":"openai","total":1,"available":1,"capacity_slots":24,"active_idle":1,"rate_limited":0,"auth_errors":0}]}}
JSON
  exit 0
fi
if [[ "${PULSE_CHECK_BLOCKER_FIXTURE:-}" == "retained" ]]; then
  cat <<'JSON'
{"window":{"since":"7d"},"metrics":{"total":0,"terminal_session_total":0,"runtime_handoffs":0,"succeeded":null,"result_counts":{},"diagnostic_focus":{},"timing_ms":{"samples":0,"avg":0,"max":0},"recent_examples":[],"failure_groups":[],"failure_families":[]},"pulse_stats":{},"progress_blockers":{"scope":"global","event_total":13,"active_total":0,"retained_unverified_total":13,"retained_supervisor_permission_total":12,"active_blockers":[],"retained_unverified":[{"reason":"permission_required","source":"opencode-permission-broker","session_key":"supervisor-pulse","repo_slug":"private/repo-one","detail":"/private/path"},{"reason":"permission_required","source":"opencode-permission-broker","session_key":"supervisor-pulse-retry","repo_slug":"private/repo-two","detail":"private title"},{"reason":"permission_required","source":"opencode-permission-broker","session_key":"manual-cli","repo_slug":"private/repo-three"}]},"delivery_stages":{"pr_opened":null,"pr_merged":null,"issue_solved":null,"delivered_successes":null,"check_state":"skipped"}}
JSON
  exit 0
fi
since="24h"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) since="${2:-24h}"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$since" == "1h" ]]; then
  cat <<'JSON'
{"window":{"since":"1h"},"metrics":{"total":0,"runtime_handoffs":0,"succeeded":null,"result_counts":{},"diagnostic_focus":{},"timing_ms":{"samples":0,"avg":0,"max":0},"recent_examples":[{"repo_slug":"private/repo-one"}],"failure_groups":[],"failure_families":[]},"pulse_stats":{},"delivery_stages":{"pr_opened":null,"pr_merged":null,"issue_solved":null,"delivered_successes":null,"check_state":"skipped"}}
JSON
else
  cat <<'JSON'
{"window":{"since":"24h"},"metrics":{"total":20,"terminal_session_total":10,"runtime_handoffs":9,"succeeded":null,"result_counts":{"success":9,"blocked":1},"diagnostic_focus":{},"timing_ms":{"samples":10,"avg":1000,"max":2000},"recent_examples":[{"repo_slug":"private/repo-one"}],"failure_groups":[],"failure_families":[]},"pulse_stats":{},"delivery_stages":{"pr_opened":null,"pr_merged":null,"issue_solved":null,"delivered_successes":null,"check_state":"skipped"}}
JSON
fi
SH
chmod +x "${TEST_ROOT}/worker-activity.sh"

cat >"${TEST_ROOT}/runner-health.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"finding":"HEALTHY"}
JSON
SH
chmod +x "${TEST_ROOT}/runner-health.sh"

cat >"${TEST_ROOT}/pulse-diagnose.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{"graphql_circuit_breaker_trips":0,"reserve_mode_cycles":0,"deferred_optional_stages":0,"secondary_cooldown_state":"active=no","cadence_api_risk":"risk=ok"}
JSON
SH
chmod +x "${TEST_ROOT}/pulse-diagnose.sh"

cat >"${BIN_DIR}/gh" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" repo view "* ]]; then
  printf 'owner/aidevops\n'
  exit 0
fi
if [[ " $* " == *" api graphql "* ]]; then
  printf '%s\n' '{"data":{"repository":{"issue":{"blockedBy":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}}}'
  exit 0
fi
if [[ " $* " == *" api "*"/labels?per_page=100"* ]]; then
  printf '%s\n' "${PULSE_CHECK_EXISTING_LABELS_JSON:-[]}"
  exit "${PULSE_CHECK_LABEL_LIST_EXIT:-0}"
fi
if [[ " $* " == *" api repos/"*"/contents/.agents/scripts/"* ]]; then
  if [[ " $* " == *"repos/owner/aidevops/contents/"* ]]; then
    printf 'file\n'
    exit 0
  fi
  printf 'not found\n' >&2
  exit 1
fi
if [[ " $* " == *" label create "* ]]; then
  label_name="${3:-}"
  printf 'label-create=%s\n' "$label_name" >>"${PULSE_CHECK_CAPTURE}"
  if [[ "$label_name" == "${PULSE_CHECK_FAIL_LABEL:-}" ]]; then
    printf 'simulated label creation failure\n' >&2
    exit 1
  fi
  exit 0
fi
if [[ " $* " == *" --search "* ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${PULSE_CHECK_QUEUE_FIXTURE:-}" == "scan-error" && " $* " == *"public/repo-two"* ]]; then
  printf 'simulated queue scan failure\n' >&2
  exit 1
fi
if [[ "${PULSE_CHECK_QUEUE_FIXTURE:-}" == "malformed" ]]; then
  if [[ " $* " == *"private/repo-one"* ]]; then
    cat <<'JSON'
[
  {"number":21,"title":"private malformed one","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]},
  {"number":22,"title":"private malformed two","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]},
  {"number":23,"title":"private malformed three","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}
]
JSON
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ "${PULSE_CHECK_QUEUE_FIXTURE:-}" == "shortfall" || "${PULSE_CHECK_QUEUE_FIXTURE:-}" == "scan-error" || "${PULSE_CHECK_QUEUE_FIXTURE:-}" == "truncation" ]]; then
  if [[ " $* " == *"private/repo-one"* ]]; then
    cat <<'JSON'
[
  {"number":11,"title":"private eligible","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"}]},
  {"number":12,"title":"private assigned","updatedAt":"2000-01-01T00:00:00Z","assignees":[{"login":"worker"}],"labels":[{"name":"auto-dispatch"},{"name":"status:queued"},{"name":"tier:standard"}]},
  {"number":13,"title":"private nmr","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:thinking"},{"name":"needs-maintainer-review"}]},
  {"number":14,"title":"private malformed","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}
]
JSON
  else
    printf '[]\n'
  fi
  exit 0
fi
if [[ " $* " == *"private/repo-one"* ]]; then
  cat <<'JSON'
[
  {"number":1,"title":"secret one","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"}]},
  {"number":2,"title":"secret two","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"}]},
  {"number":3,"title":"secret three","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"}]},
  {"number":4,"title":"secret four","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"},{"name":"infrastructure"}]}
]
JSON
  exit 0
fi
cat <<'JSON'
[
  {"number":5,"title":"public five","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"},{"name":"tier:standard"}]},
  {"number":6,"title":"public six","updatedAt":"2000-01-01T00:00:00Z","assignees":[],"labels":[{"name":"auto-dispatch"},{"name":"status:available"}]}
]
JSON
SH
chmod +x "${BIN_DIR}/gh"

cat >"${TEST_ROOT}/wrappers.sh" <<'SH'
#!/usr/bin/env bash
gh_create_issue() {
  local repo=""
  local title=""
  local body_file=""
  local labels=""
  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "$arg" in
      --repo) repo="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --label) labels="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'repo=%s\ntitle=%s\nlabels=%s\nbody_file=%s\n' "$repo" "$title" "$labels" "$body_file" >>"${PULSE_CHECK_CAPTURE}"
  cp "$body_file" "${PULSE_CHECK_CAPTURE}.body"
  printf 'created-issue-1\n'
  return 0
}
SH

COMMON_ENV=(
	"PATH=${BIN_DIR}:$PATH"
	"PULSE_CHECK_REPOS_JSON=${TEST_ROOT}/repos.json"
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state.sh"
	"PULSE_CHECK_WORKER_ACTIVITY_HELPER=${TEST_ROOT}/worker-activity.sh"
	"PULSE_CHECK_RUNNER_HEALTH_HELPER=${TEST_ROOT}/runner-health.sh"
	"PULSE_CHECK_PULSE_DIAGNOSE_HELPER=${TEST_ROOT}/pulse-diagnose.sh"
	"PULSE_CHECK_GH_WRAPPERS=${TEST_ROOT}/wrappers.sh"
	"PULSE_CHECK_CAPTURE=${TEST_ROOT}/capture.txt"
	"PULSE_CHECK_PULSE_HEALTH_FILE=${TEST_ROOT}/missing-pulse-health.json"
)

printf '%s=== pulse-check-helper.sh tests ===%s\n' "$TEST_BLUE" "$TEST_NC"

OUT=$(env "${COMMON_ENV[@]}" "$HELPER" report 2>&1)
assert_contains "text report shows empty active capacity" "Active workers: 0 / 6" "$OUT"
assert_contains "text report distinguishes eligible work" "Auto-dispatch queue: 5 available (4 eligible) / 6 open" "$OUT"
assert_contains "underfilled finding appears" "pulse-underfilled-auto-dispatch-queue" "$OUT"
assert_contains "launch accounting finding appears" "pulse-launch-accounting-gap" "$OUT"
assert_contains "canonical reconciliation finding appears" "pulse-canonical-reconciliation-stops" "$OUT"
assert_not_contains "text report omits private slug" "private/repo-one" "$OUT"
assert_not_contains "text report omits issue titles" "secret one" "$OUT"
assert_not_contains "text report omits canonical branch detail" "origin/develop" "$OUT"

BLOCKER_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_BLOCKER_FIXTURE=retained" "$HELPER" report --since 7d 2>&1)
assert_contains "healthy idle report exposes retained supervisor blocker advisory" "retained-supervisor-permission-blockers" "$BLOCKER_OUT"
assert_contains "retained blocker report preserves healthy runner state" "Runner health: HEALTHY" "$BLOCKER_OUT"
assert_contains "retained blocker report shows zero active workers" "Active workers: 0 / 6" "$BLOCKER_OUT"
assert_contains "retained blocker report gives no-source worker count command" "worker-activity-helper.sh live-workers" "$BLOCKER_OUT"
assert_contains "retained blocker report gives audited reconciliation guidance" "worker-blocker-cli.mjs resolve-session" "$BLOCKER_OUT"
assert_not_contains "retained blocker report omits private blocker slug" "private/repo-one" "$BLOCKER_OUT"
assert_not_contains "retained blocker report omits private blocker path" "/private/path" "$BLOCKER_OUT"
BLOCKER_JSON=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_BLOCKER_FIXTURE=retained" "$HELPER" json --since 7d 2>&1)
assert_eq "json uses uncapped retained supervisor permission aggregate" "12" "$(printf '%s' "$BLOCKER_JSON" | jq -r '.summary.retained_supervisor_permission_blockers')"
assert_not_contains "retained blocker JSON omits private blocker title" "private title" "$BLOCKER_JSON"

JSON_OUT=$(env "${COMMON_ENV[@]}" "$HELPER" json 2>&1)
IDS=$(printf '%s' "$JSON_OUT" | jq -r '[.findings[].id] | sort | join(",")')
assert_eq "json finding IDs" "auto-dispatch-missing-tier-labels,pulse-canonical-reconciliation-stops,pulse-launch-accounting-gap,pulse-underfilled-auto-dispatch-queue" "$IDS"
JSON_PRIVATE_COUNT=$(printf '%s' "$JSON_OUT" | grep -c "private/repo-one" 2>/dev/null || true)
assert_eq "json output removes raw worker examples" "0" "$JSON_PRIVATE_COUNT"
ACTIVE_SOURCE=$(printf '%s' "$JSON_OUT" | jq -r '.summary.active_workers_source')
assert_eq "json uses process scan when available" "process_scan" "$ACTIVE_SOURCE"
HANDOFF_RATE=$(printf '%s' "$JSON_OUT" | jq -r '.summary.historical_runtime_handoff_rate')
assert_eq "json runtime handoff rate uses terminal session denominator" "90" "$HANDOFF_RATE"
SUCCESS_RATE=$(printf '%s' "$JSON_OUT" | jq -r '.summary.historical_success_rate')
assert_eq "json delivered success rate is unknown without GitHub delivery check" "null" "$SUCCESS_RATE"
assert_eq "json reports canonical reconciliation refusal aggregate" "2" "$(printf '%s' "$JSON_OUT" | jq -r '.current_state.canonical_reconciliation.refusal_count')"
assert_eq "json reports canonical reconciliation classification" "dirty_or_uncommitted" "$(printf '%s' "$JSON_OUT" | jq -r '.current_state.canonical_reconciliation.classification')"
assert_not_contains "json omits canonical branch detail" "origin/develop" "$JSON_OUT"

MALFORMED_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_QUEUE_FIXTURE=malformed" "$HELPER" json 2>&1)
assert_contains "malformed queue emits normalization shortfall" "pulse-eligible-queue-under-target" "$MALFORMED_OUT"
assert_contains "malformed queue reports missing tiers" "auto-dispatch-missing-tier-labels" "$MALFORMED_OUT"
assert_not_contains "malformed queue cannot trigger worker-retention underfill" "pulse-underfilled-auto-dispatch-queue" "$MALFORMED_OUT"

cat >"${TEST_ROOT}/current-state-active.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 12,
  "active_worker_processes": 2,
  "current_state_guardrails": {"available_slots_last": 6},
  "pulse_gauges": {"dispatch_capacity_final_max_workers": 6},
  "worker_outcomes": {"spawned": 0},
  "worker_terminal_events": 0,
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state-active.sh"
JSON_ACTIVE_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-active.sh" "$HELPER" json 2>&1)
ACTIVE_COUNT=$(printf '%s' "$JSON_ACTIVE_OUT" | jq -r '.summary.active_workers')
ACTIVE_AVAILABLE=$(printf '%s' "$JSON_ACTIVE_OUT" | jq -r '.summary.available_slots')
ACTIVE_IDS=$(printf '%s' "$JSON_ACTIVE_OUT" | jq -r '[.findings[].id] | sort | join(",")')
assert_eq "json reports process-scan active workers" "2" "$ACTIVE_COUNT"
assert_eq "json recomputes available slots from process count" "4" "$ACTIVE_AVAILABLE"
assert_eq "process-scan active workers suppress underfill finding" "auto-dispatch-missing-tier-labels" "$ACTIVE_IDS"

cat >"${TEST_ROOT}/current-state-active-no-gauge.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 12,
  "active_worker_processes": 2,
  "current_state_guardrails": {},
  "pulse_gauges": {},
  "worker_outcomes": {"spawned": 0},
  "worker_terminal_events": 0,
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state-active-no-gauge.sh"
JSON_ACTIVE_NO_GAUGE_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-active-no-gauge.sh" "$HELPER" json 2>&1)
assert_eq "json falls back to process count when capacity gauge is absent" "2" "$(printf '%s' "$JSON_ACTIVE_NO_GAUGE_OUT" | jq -r '.summary.max_workers')"
assert_eq "json absent capacity gauge avoids impossible active over max report" "Active workers: 2 / 2" "$(env "${COMMON_ENV[@]}" "PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-active-no-gauge.sh" "$HELPER" report 2>&1 | grep -o 'Active workers: [0-9] / [0-9]')"

cat >"${TEST_ROOT}/pulse-health.json" <<'JSON'
{"workers_active":1,"workers_max":2}
JSON
cat >"${TEST_ROOT}/current-state-active-health-only.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 12,
  "pulse_gauges": {},
  "current_state_guardrails": {},
  "worker_outcomes": {"spawned": 0},
  "worker_terminal_events": 1,
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state-active-health-only.sh"
JSON_ACTIVE_HEALTH_OUT=$(env "${COMMON_ENV[@]}" \
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-active-health-only.sh" \
	"PULSE_CHECK_PULSE_HEALTH_FILE=${TEST_ROOT}/pulse-health.json" "$HELPER" json 2>&1)
assert_eq "json falls back to pulse health max when capacity gauge is absent" "2" "$(printf '%s' "$JSON_ACTIVE_HEALTH_OUT" | jq -r '.summary.max_workers')"
assert_eq "json derives available slots from pulse health when gauge is absent" "1" "$(printf '%s' "$JSON_ACTIVE_HEALTH_OUT" | jq -r '.summary.available_slots')"

cat >"${TEST_ROOT}/current-state-shortfall.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 2,
  "active_worker_processes": 2,
  "current_state_guardrails": {"available_slots_last": 22},
  "pulse_gauges": {"dispatch_capacity_final_max_workers": 24},
  "worker_outcomes": {"spawned": 0},
  "worker_terminal_events": 0,
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state-shortfall.sh"
SHORTFALL_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_QUEUE_FIXTURE=shortfall" \
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-shortfall.sh" "$HELPER" json 2>&1)
SHORTFALL_IDS=$(printf '%s' "$SHORTFALL_OUT" | jq -r '[.findings[].id] | sort | join(",")')
assert_eq "active workers do not hide eligible queue shortfall" "auto-dispatch-missing-tier-labels,pulse-eligible-queue-under-target,pulse-inactive-nmr-holds" "$SHORTFALL_IDS"
assert_eq "shortfall fixture has one eligible issue" "1" "$(printf '%s' "$SHORTFALL_OUT" | jq -r '.queue.eligible_available_unassigned')"
assert_eq "shortfall fixture distinguishes assigned work" "1" "$(printf '%s' "$SHORTFALL_OUT" | jq -r '.queue.assigned_in_flight')"
assert_eq "shortfall fixture distinguishes held work" "1" "$(printf '%s' "$SHORTFALL_OUT" | jq -r '.queue.blocked_explicit_hold')"
assert_contains "NMR advisory names updatedAt inactivity basis" "issue_updatedAt_not_label_application_time" "$SHORTFALL_OUT"
assert_not_contains "shortfall JSON omits private issue title" "private nmr" "$SHORTFALL_OUT"

SCAN_ERROR_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_QUEUE_FIXTURE=scan-error" \
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-shortfall.sh" "$HELPER" json 2>&1)
assert_contains "partial scan reports GitHub error" "pulse-check-gh-scan-errors" "$SCAN_ERROR_OUT"
assert_not_contains "partial scan suppresses queue shortfall" "pulse-eligible-queue-under-target" "$SCAN_ERROR_OUT"
assert_not_contains "partial scan suppresses NMR inactivity" "pulse-inactive-nmr-holds" "$SCAN_ERROR_OUT"

TRUNCATED_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_QUEUE_FIXTURE=truncation" \
	"PULSE_CHECK_MAX_ISSUES_PER_REPO=3" \
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-shortfall.sh" "$HELPER" json 2>&1)
assert_contains "saturated scan reports bounded incompleteness" "pulse-check-gh-scan-errors" "$TRUNCATED_OUT"
assert_not_contains "saturated scan suppresses queue shortfall" "pulse-eligible-queue-under-target" "$TRUNCATED_OUT"
assert_not_contains "saturated scan suppresses NMR inactivity" "pulse-inactive-nmr-holds" "$TRUNCATED_OUT"

cat >"${TEST_ROOT}/repos-invalid.json" <<'JSON'
{"initialized_repos":"not-an-array"}
JSON
INVALID_REPOS_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_REPOS_JSON=${TEST_ROOT}/repos-invalid.json" \
	"PULSE_CHECK_CURRENT_STATE_HELPER=${TEST_ROOT}/current-state-shortfall.sh" "$HELPER" json 2>&1)
assert_contains "malformed repos schema reports incomplete scan" "pulse-check-queue-scan-skipped" "$INVALID_REPOS_OUT"
assert_not_contains "malformed repos schema suppresses queue shortfall" "pulse-eligible-queue-under-target" "$INVALID_REPOS_OUT"
assert_not_contains "malformed repos schema suppresses NMR inactivity" "pulse-inactive-nmr-holds" "$INVALID_REPOS_OUT"

cat >"${TEST_ROOT}/current-state.sh" <<'SH'
#!/usr/bin/env bash
cat <<'JSON'
{
  "dispatch_alive": true,
  "dispatch_stage_events": 12,
  "current_state_guardrails": {"available_slots_last": 6},
  "pulse_gauges": {"dispatch_capacity_final_max_workers": 6},
  "worker_outcomes": {"spawned": 4, "launch_validation_failed": 4},
  "worker_terminal_events": 0,
  "graphql_budget_status": "OK fixture"
}
JSON
SH
chmod +x "${TEST_ROOT}/current-state.sh"
CLASSIFIED_JSON_OUT=$(env "${COMMON_ENV[@]}" "$HELPER" json 2>&1)
CLASSIFIED_IDS=$(printf '%s' "$CLASSIFIED_JSON_OUT" | jq -r '[.findings[].id] | sort | join(",")')
assert_eq "classified launch failures suppress launch accounting gap" "auto-dispatch-missing-tier-labels,pulse-underfilled-auto-dispatch-queue" "$CLASSIFIED_IDS"

APPLY_OUT=$(env "${COMMON_ENV[@]}" "$HELPER" apply --repo owner/aidevops 2>&1)
assert_contains "apply reports issue filing" "pulse-check: filed" "$APPLY_OUT"
CAPTURE=$(<"${TEST_ROOT}/capture.txt")
for required_label in auto-dispatch tier:standard bug framework pulse self-improvement source:pulse-check; do
	assert_contains "apply provisions ${required_label}" "label-create=${required_label}" "$CAPTURE"
done
assert_precedes "apply provisions labels before issue creation" "label-create=source:pulse-check" "repo=owner/aidevops" "$CAPTURE"
assert_contains "apply passes complete label contract" "labels=auto-dispatch,tier:standard,bug,framework,pulse,self-improvement,source:pulse-check" "$CAPTURE"
BODY=$(<"${TEST_ROOT}/capture.txt.body")
assert_contains "apply body carries marker" "aidevops:generator=pulse-check finding=" "$BODY"
assert_contains "apply body carries verification" ".agents/scripts/tests/test-pulse-check-helper.sh" "$BODY"
assert_not_contains "apply body omits private slug" "private/repo-one" "$BODY"
assert_not_contains "apply body omits issue title" "secret one" "$BODY"

rm -f "${TEST_ROOT}/capture.txt" "${TEST_ROOT}/capture.txt.body"
EXISTING_LABELS='[{"name":"auto-dispatch"},{"name":"tier:standard"},{"name":"bug"},{"name":"framework"},{"name":"pulse"},{"name":"self-improvement"},{"name":"source:pulse-check"}]'
EXISTING_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_EXISTING_LABELS_JSON=${EXISTING_LABELS}" "$HELPER" apply --repo owner/aidevops 2>&1)
EXISTING_CAPTURE=$(<"${TEST_ROOT}/capture.txt")
assert_contains "existing labels still allow issue filing" "pulse-check: filed" "$EXISTING_OUT"
assert_not_contains "existing label metadata is not overwritten" "label-create=" "$EXISTING_CAPTURE"

rm -f "${TEST_ROOT}/capture.txt" "${TEST_ROOT}/capture.txt.body"
FAILED_LABEL_OUT=$(env "${COMMON_ENV[@]}" "PULSE_CHECK_FAIL_LABEL=source:pulse-check" "$HELPER" apply --repo owner/aidevops 2>&1)
FAILED_LABEL_CAPTURE=$(<"${TEST_ROOT}/capture.txt")
assert_contains "required label failure is reported" "failed to ensure label source:pulse-check" "$FAILED_LABEL_OUT"
assert_not_contains "required label failure prevents issue creation" "repo=owner/aidevops" "$FAILED_LABEL_CAPTURE"

rm -f "${TEST_ROOT}/capture.txt" "${TEST_ROOT}/capture.txt.body"
FOREIGN_REPO_OUT=$(env "${COMMON_ENV[@]}" "$HELPER" apply --repo owner/product 2>&1)
assert_contains "foreign repo is rejected before issue creation" "repository does not own .agents/scripts/pulse-check-queue-scan.py" "$FOREIGN_REPO_OUT"
assert_not_contains "foreign repo receives no remediation issue" "pulse-check: filed" "$FOREIGN_REPO_OUT"

# shellcheck source=../routines/core-routines.sh
CORE_OUTPUT=$(source "$CORE_ROUTINES" && get_core_routine_entries)
assert_contains "r915 registered as core routine" "r915|x|Pulse check" "$CORE_OUTPUT"
if (
	# shellcheck source=../routines/core-routines.sh
	source "$CORE_ROUTINES" && declare -F describe_r915 >/dev/null 2>&1
); then
	assert_eq "describe_r915 function exists" "0" "0"
else
	assert_eq "describe_r915 function exists" "0" "1"
fi

printf '\n%sTests run:%s %s | %sFailures:%s %s\n' "$TEST_BLUE" "$TEST_NC" "$TESTS_RUN" "$TEST_BLUE" "$TEST_NC" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
	exit 1
fi
exit 0
