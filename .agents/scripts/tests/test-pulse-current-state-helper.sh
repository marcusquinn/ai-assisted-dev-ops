#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/../pulse-current-state-helper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

python3 - "$TMP_DIR" <<'PY'
import json, os, sys, time
root = sys.argv[1]
now = time.time()
iso = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))
open(os.path.join(root, 'dispatch-stages.tsv'), 'w').write(
    f'{iso}\t#1\tmarcusquinn/aidevops\tworker_launch_total\t123\n'
    f'{iso}\t#1\tmarcusquinn/aidevops\tceremony_total\t456\n'
)
open(os.path.join(root, 'headless-runtime-metrics.jsonl'), 'w').write(
    json.dumps({'ts': now, 'result': 'success', 'exit_code': 0, 'duration_ms': 1000, 'load_1min': 1.5, 'load_per_cpu': 0.2}) + '\n' +
    json.dumps({'ts': now, 'result': 'watchdog_stall_killed', 'exit_code': 79, 'duration_ms': 2000}) + '\n' +
    json.dumps({'ts': now, 'result': 'rate_limit_fast', 'exit_code': 80, 'failure_reason': 'rate_limit_fast'}) + '\n' +
    json.dumps({'ts': now, 'result': 'worker_noop', 'exit_code': 2}) + '\n'
)
json.dump({
    'counters': {
        'dispatch_backoff_skipped': [now],
        'worker_canary_preflight_failed_count': [now],
        'pulse_cycle_skipped_graphql_low': [now],
        'pulse_graphql_budget_reserve_mode': [now],
        'pulse_graphql_budget_stage_deferred': [now, now],
        'pulse_graphql_budget_stage_deferred_dashboard_freshness_check': [now],
        'pulse_graphql_budget_stage_deferred_evaluate_routines': [now],
        'dispatch_load_blocked': [now],
        'pulse_graphql_low_force_rest_reads': [now],
        'dispatch_candidate_failed': [now, now, now, now],
        'dispatch_candidate_failed_reason_cost_budget_exceeded': [now, now],
        'dispatch_candidate_failed_reason_dedup_active_claim': [now],
        'dispatch_candidate_failed_reason_graphql_circuit_breaker': [now],
    },
    'gauges': {'graphql_remaining': {'value': 1234, 'ts': now}},
}, open(os.path.join(root, 'pulse-stats.json'), 'w'))
json.dump({
    '_meta': {'total_calls': 42},
    'by_caller': {
        'gh_issue_list': {'graphql_calls': 7, 'rest_calls': 3, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 10},
        'gh_pr_view': {'graphql_calls': 2, 'rest_calls': 0, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 2},
        '_rest_pr_list': {'graphql_calls': 0, 'rest_calls': 5, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 5},
        'pulse-batch-prefetch-helper.sh': {'graphql_calls': 0, 'rest_calls': 0, 'search_graphql_calls': 11, 'search_rest_calls': 4, 'other_calls': 0, 'total': 15},
        'gh_api_graphql': {'graphql_calls': 10, 'rest_calls': 0, 'search_graphql_calls': 0, 'search_rest_calls': 0, 'other_calls': 0, 'total': 10},
    }
}, open(os.path.join(root, 'gh-api-calls-by-stage.json'), 'w'))
json.dump({
    'batch_cache_hits': 5,
    'prefetch_conditional_304': 3,
    'prefetch_conditional_refreshes': 2,
    'prefetch_conditional_misses': 1,
    'cycle_state': {
        'schema': 'aidevops.pulse-cycle-state/v1',
        'cycle_id': '20260101T000000Z-123',
        'phase': 'completed',
        'outcome': 'progressed',
        'heartbeat_at': iso,
        'progress': {
            'last_at': iso,
            'kinds': ['worker-dispatched'],
            'consecutive_no_progress_cycles': 0,
        },
        'blocker': {
            'kind': 'none',
            'fingerprint': None,
            'consecutive_same_cycles': 0,
        },
    },
}, open(os.path.join(root, 'pulse-health.json'), 'w'))
json.dump({
    'objectives': [
        {
            'repo': 'owner/repo', 'number': 41, 'objective_state': 'actionable',
            'evidence_timestamp': int(now) - 7200, 'assumption_expires_at': int(now) - 3600,
            'assumption_expired': True, 'next_action': 'dispatch_objective',
            'trigger_at': int(now) - 3600, 'responsible_component': 'pulse-dispatch',
        },
        {
            'repo': 'owner/repo', 'number': 42, 'objective_state': 'actionable',
            'evidence_timestamp': int(now), 'assumption_expires_at': int(now) + 3600,
            'assumption_expired': False, 'next_action': '', 'trigger_at': None,
            'responsible_component': '',
        },
    ]
}, open(os.path.join(root, 'objective-reconciliation.json'), 'w'))
open(os.path.join(root, 'pulse-wrapper.log'), 'w').write(
    '[pulse] useful activity\n'
    'ERROR Refusing reconciliation: HEAD is not exact origin/develop SHA private-sha\n'
    '[pulse-canonical-recovery] diagnostic-only canonical state: /private/path (state=uncommitted)\n'
    '[pulse-canonical-recovery] advisory filed locally: /private/path/canonical-recovery-repo.advisory\n'
    'PR opened #2\nPR merged #2\nissue closed #1\nInstance lock acquired\n'
)
state_dir = os.path.join(root, 'review-thread-state')
os.makedirs(state_dir, exist_ok=True)
open(os.path.join(state_dir, 'owner-repo-12.state'), 'w').write(
    'fingerprint=THREAD1\n'
    'thread_count=1\n'
    'attempt_count=3\n'
    'analysis_complete=true\n'
    'maintainer_attention=true\n'
    'blocked_by=maintainer\n'
    'attention_reason=same_unresolved_thread_fingerprint\n'
    'blocker_reason=same_unresolved_thread_fingerprint\n'
    f'completed_at={int(now)}\n'
)
PY

output="$TMP_DIR/out.txt"
export AIDEVOPS_OBS_DB_OVERRIDE="$TMP_DIR/runtime-events.db"
export AIDEVOPS_PULSE_RATE_LIMIT_CACHE="$TMP_DIR/rate-limit-cache.json"
export AIDEVOPS_PULSE_RATE_LIMIT_CACHE_TTL=300
export AIDEVOPS_GH_REQUEST_STATE_AUTH_SCOPE="pulse-current-state-test"
export AIDEVOPS_GH_API_POOL="default"
export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="$TMP_DIR/review-thread-state"
export AIDEVOPS_OBJECTIVE_STATE_FILE="$TMP_DIR/objective-reconciliation.json"
# shellcheck source=../shared-gh-request-state.sh
source "${SCRIPT_DIR}/../shared-gh-request-state.sh"
rate_reset=$(($(date +%s) + 3600))
rate_fixture=$(jq -cn --argjson reset "$rate_reset" \
	'{resources:{graphql:{remaining:4980,limit:5000,reset:$reset}}}')
gh_request_state_rate_put "$rate_fixture"
cache_status=$("${SCRIPT_DIR}/../pulse-rate-limit-circuit-breaker.sh" status --cached)
if [[ "$cache_status" != OK:* ]]; then
	printf 'FAIL canonical rate-cache fixture is unreadable: %s\n' "$cache_status" >&2
	exit 1
fi
"$HELPER" --log-dir "$TMP_DIR" --repo-path "$PWD" --window 15m >"$output"

grep -q 'Dispatch alive: true' "$output"
grep -q 'Worker terminal events: 4' "$output"
grep -q 'dispatch_backoff_skipped' "$output"
grep -q 'GraphQL budget:' "$output"
grep -q 'Top pre-launch blockers:' "$output"
if ! grep -q 'Dispatch API blocked by GraphQL: false' "$output"; then
	printf 'FAIL expected unblocked GraphQL dispatch state:\n%s\n' "$(<"$output")" >&2
	exit 1
fi
grep -q 'API call pressure:' "$output"
grep -q 'Prefetch cache:' "$output"
grep -q 'Cycle state:' "$output"
grep -q 'Review-thread maintainer attention:' "$output"
grep -q 'same_unresolved_thread_fingerprint' "$output"
grep -q 'worker_launch_total' "$output"
grep -q 'watchdog_killed' "$output"
grep -q 'rate_limited' "$output"
grep -q 'canary_failed' "$output"
grep -q 'Objectives without next action: 1' "$output"
grep -q 'Oldest unverified assumption:' "$output"

json_output="$TMP_DIR/out.json"
"$HELPER" --log-dir "$TMP_DIR" --repo-path "$PWD" --window 15m --json >"$json_output"
jq -e '.worker_outcomes.spawned == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.watchdog_killed == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.rate_limited == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.no_op == 1' "$json_output" >/dev/null
jq -e '.worker_outcomes.canary_failed == 1' "$json_output" >/dev/null
jq -e '.graphql_budget.skipped_low_count == 1' "$json_output" >/dev/null
jq -e '.graphql_budget.force_rest_reads_count == 1' "$json_output" >/dev/null
jq -e '.dispatch_api_blocked == false' "$json_output" >/dev/null
jq -e '.graphql_budget.reserve_mode_count == 1' "$json_output" >/dev/null
jq -e '.graphql_budget.deferred_stage_count == 2' "$json_output" >/dev/null
jq -e '.graphql_budget.deferred_stages.dashboard_freshness_check == 1' "$json_output" >/dev/null
jq -e '.graphql_budget.deferred_stages.evaluate_routines == 1' "$json_output" >/dev/null
jq -e '.pre_launch_blockers.cost_budget_exceeded == 2' "$json_output" >/dev/null
jq -e '.pre_launch_blockers.dedup_active_claim == 1' "$json_output" >/dev/null
jq -e '.top_pre_launch_blockers[0].reason == "cost_budget_exceeded"' "$json_output" >/dev/null
jq -e '.dispatch_stage_timing_ms.worker_launch_total.avg_ms == 123' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_read_calls == 9' "$json_output" >/dev/null
jq -e '.api_call_pressure.rest_read_calls == 8' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_search_calls == 11' "$json_output" >/dev/null
jq -e '.api_call_pressure.rest_search_calls == 4' "$json_output" >/dev/null
jq -e '.api_call_pressure.graphql_other_calls == 10' "$json_output" >/dev/null
jq -e '.api_call_pressure.read_rest_ratio == 0.4706' "$json_output" >/dev/null
jq -e '.prefetch_cache.conditional_304 == 3' "$json_output" >/dev/null
jq -e '.prefetch_cache.conditional_refreshes == 2' "$json_output" >/dev/null
jq -e '.prefetch_cache.conditional_misses == 1' "$json_output" >/dev/null
jq -e '.cycle_state.availability == "available"' "$json_output" >/dev/null
jq -e '.cycle_state.outcome == "progressed"' "$json_output" >/dev/null
jq -e '.cycle_state.progress.kinds == ["worker-dispatched"]' "$json_output" >/dev/null
jq -e '.review_thread_attention[0].blocked_by == "maintainer"' "$json_output" >/dev/null
jq -e '.review_thread_attention[0].pr_number == 12' "$json_output" >/dev/null
jq -e '.review_thread_attention[0].reason == "same_unresolved_thread_fingerprint"' "$json_output" >/dev/null
jq -e '.review_thread_attention[0].attempt_count == 3' "$json_output" >/dev/null
jq -e '.objective_reconciliation.objectives_without_next_action == 1' "$json_output" >/dev/null
jq -e '.objective_reconciliation.expired_assumptions == 1' "$json_output" >/dev/null
jq -e '.objective_reconciliation.oldest_unverified_assumption.number == 41' "$json_output" >/dev/null
jq -e '.canonical_reconciliation.refusal_count == 1' "$json_output" >/dev/null
jq -e '.canonical_reconciliation.classification == "dirty_or_uncommitted"' "$json_output" >/dev/null
jq -e '.canonical_reconciliation.canonical_recovery_advisory_observed == true' "$json_output" >/dev/null
if grep -Eq '/private/path|develop SHA|private-sha' "$json_output"; then
	printf 'FAIL canonical reconciliation projection exposes raw diagnostic context\n' >&2
	exit 1
fi
sqlite3 "$AIDEVOPS_OBS_DB_OVERRIDE" "SELECT COUNT(*) FROM runtime_events WHERE subject_id='pulse:current' AND event_type IN ('state.snapshot','state.delta');" | grep -Eq '^[12]$'
sqlite3 "$AIDEVOPS_OBS_DB_OVERRIDE" "SELECT payload_json FROM runtime_events WHERE subject_id='pulse:current' ORDER BY id LIMIT 1;" | grep -q 'review_thread_attention_count'
if sqlite3 "$AIDEVOPS_OBS_DB_OVERRIDE" "SELECT payload_json FROM runtime_events WHERE subject_id='pulse:current';" | grep -Eq 'marcusquinn/aidevops|owner-repo|state_file|wrapper_activity'; then
	printf 'FAIL runtime state contains private or prose projection fields\n' >&2
	exit 1
fi
python3 - "$HELPER" "${SCRIPT_DIR}/../pulse-current-state.py" <<'PY'
import pathlib
import sys
helper_source = pathlib.Path(sys.argv[1]).read_text()
implementation_source = pathlib.Path(sys.argv[2]).read_text()
assert 'pulse-current-state.py' in helper_source
assert 'from collections import Counter, defaultdict, deque' in implementation_source
assert 'readlines()[-limit:]' not in implementation_source
assert 'deque(handle, maxlen=limit)' in implementation_source
assert 'AIDEVOPS_ACTIVE_WORKER_PROCESSES' in helper_source
assert 'AIDEVOPS_ACTIVE_WORKER_PROCESSES' in implementation_source
assert 'def build_pre_launch_blockers' in implementation_source
assert 'def build_graphql_budget' in implementation_source
assert 'def build_current_state_guardrails' in implementation_source
assert 'def build_objective_reconciliation' in implementation_source
assert 'def build_cycle_state' in implementation_source
assert "graphql_budget_status = (" not in implementation_source
assert 'import subprocess' not in implementation_source
assert 'subprocess.check_output' not in implementation_source
PY

missing_dir="$TMP_DIR/missing-cycle-state"
mkdir -p "$missing_dir"
missing_json="$TMP_DIR/missing-cycle-state.json"
"$HELPER" --log-dir "$missing_dir" --repo-path "$PWD" --window 15m --json >"$missing_json"
jq -e '.cycle_state.availability == "unavailable"' "$missing_json" >/dev/null

upstream_mismatch_dir="$TMP_DIR/upstream-mismatch"
mkdir -p "$upstream_mismatch_dir"
printf 'ERROR Refusing reconciliation: HEAD is not exact origin/main SHA private-sha\n' >"$upstream_mismatch_dir/pulse-wrapper.log"
upstream_mismatch_json="$TMP_DIR/upstream-mismatch.json"
"$HELPER" --log-dir "$upstream_mismatch_dir" --repo-path "$PWD" --window 15m --json >"$upstream_mismatch_json"
jq -e '.canonical_reconciliation.refusal_count == 1' "$upstream_mismatch_json" >/dev/null
jq -e '.canonical_reconciliation.classification == "upstream_or_default_branch_mismatch"' "$upstream_mismatch_json" >/dev/null
jq -e '.canonical_reconciliation.canonical_recovery_advisory_observed == false' "$upstream_mismatch_json" >/dev/null

printf '{malformed\n' >"$missing_dir/pulse-health.json"
malformed_health_json="$TMP_DIR/malformed-health-state.json"
"$HELPER" --log-dir "$missing_dir" --repo-path "$PWD" --window 15m --json >"$malformed_health_json"
jq -e '.cycle_state.availability == "malformed" and .cycle_state.reason == "health-json"' \
	"$malformed_health_json" >/dev/null

printf '{"cycle_state":{"schema":"wrong"}}\n' >"$missing_dir/pulse-health.json"
malformed_cycle_json="$TMP_DIR/malformed-cycle-state.json"
"$HELPER" --log-dir "$missing_dir" --repo-path "$PWD" --window 15m --json >"$malformed_cycle_json"
jq -e '.cycle_state.availability == "malformed" and .cycle_state.reason == "cycle-state-contract"' \
	"$malformed_cycle_json" >/dev/null

jq '.cycle_state.blocker = {
	kind: "review-gate",
	fingerprint: "cksum:123",
	consecutive_same_cycles: 1
}' "$TMP_DIR/pulse-health.json" >"$missing_dir/pulse-health.json"
inconsistent_cycle_json="$TMP_DIR/inconsistent-cycle-state.json"
"$HELPER" --log-dir "$missing_dir" --repo-path "$PWD" --window 15m --json >"$inconsistent_cycle_json"
jq -e '.cycle_state.availability == "malformed" and .cycle_state.reason == "cycle-state-contract"' \
	"$inconsistent_cycle_json" >/dev/null

printf 'PASS pulse-current-state-helper\n'
