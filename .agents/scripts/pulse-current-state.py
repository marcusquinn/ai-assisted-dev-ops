#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

"""Current pulse productivity snapshot implementation."""

import datetime
import json
import os
import sys
import time
from collections import Counter, defaultdict, deque

log_dir, repo_path, window_s, as_json, script_dir, review_thread_state_dir = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4] == '1', sys.argv[5], sys.argv[6]
now = time.time()
since = now - window_s
CYCLE_STATE_SCHEMA = 'aidevops.pulse-cycle-state/v1'
CYCLE_STATE_PHASES = {'admitted', 'preflight', 'deterministic', 'supervising', 'completed'}
CYCLE_STATE_OUTCOMES = {'running', 'progressed', 'idle', 'blocked', 'interrupted'}
CYCLE_STATE_PROGRESS_KINDS = {'pr-merged', 'pr-closed-conflicting', 'worker-dispatched'}
CYCLE_STATE_BLOCKER_KINDS = {
    'none', 'session-gate', 'dedup', 'preflight-failed', 'stop-requested',
    'dispatch-no-work-rate', 'runner-health', 'merge-authority', 'review-gate',
    'review-bot-threads', 'required-review-threads', 'checks-active',
    'checks-failed', 'quiet-period', 'snapshot-unavailable', 'head-changed',
    'interrupted', 'rest-core-quota',
}


def recent_lines(path, limit=2000):
    if not os.path.exists(path):
        return []
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        lines = deque(handle, maxlen=limit)
    return [line.rstrip('\n') for line in lines]


def parse_time(value):
    value = str(value).strip()
    if not value:
        return 0.0
    try:
        return float(value)
    except ValueError:
        pass
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except ValueError:
        return 0.0


def unavailable_cycle_state(availability, reason=None):
    state = {
        'availability': availability,
        'schema': None,
        'cycle_id': None,
        'phase': None,
        'outcome': None,
        'heartbeat_at': None,
        'progress': None,
        'blocker': None,
    }
    if reason:
        state['reason'] = reason
    return state


def valid_cycle_fingerprint(value):
    if not isinstance(value, str):
        return False
    if value.startswith('sha256:'):
        digest = value[len('sha256:'):]
        return len(digest) == 64 and all(char in '0123456789abcdef' for char in digest)
    if value.startswith('cksum:'):
        return value[len('cksum:'):].isdigit()
    return False


def valid_nonnegative_int(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def valid_optional_cycle_time(value):
    if value is None:
        return True
    return parse_time(value) > 0


def valid_cycle_progress(progress):
    if not isinstance(progress, dict):
        return False
    kinds = progress.get('kinds')
    if not isinstance(kinds, list):
        return False
    return all((
        all(kind in CYCLE_STATE_PROGRESS_KINDS for kind in kinds),
        valid_nonnegative_int(progress.get('consecutive_no_progress_cycles')),
        valid_optional_cycle_time(progress.get('last_at')),
    ))


def valid_cycle_blocker(blocker):
    if not isinstance(blocker, dict):
        return False
    kind = blocker.get('kind')
    streak = blocker.get('consecutive_same_cycles')
    fingerprint = blocker.get('fingerprint')
    if kind not in CYCLE_STATE_BLOCKER_KINDS or not valid_nonnegative_int(streak):
        return False
    if kind == 'none':
        return fingerprint is None and streak == 0
    return valid_cycle_fingerprint(fingerprint)


def valid_terminal_cycle_state(state, progress, blocker):
    if state.get('phase') != 'completed':
        return False
    outcome = state.get('outcome')
    no_progress = progress['consecutive_no_progress_cycles']
    if outcome == 'progressed':
        return all((
            progress['kinds'], progress['last_at'], no_progress == 0,
            blocker['kind'] == 'none',
        ))
    if no_progress < 1:
        return False
    if outcome in {'blocked', 'interrupted'}:
        return blocker['kind'] != 'none' and blocker['consecutive_same_cycles'] >= 1
    return outcome == 'idle' and blocker['kind'] == 'none'


def valid_cycle_state_contract(state):
    progress = state.get('progress')
    blocker = state.get('blocker')
    cycle_id = state.get('cycle_id')
    if not all((
        state.get('schema') == CYCLE_STATE_SCHEMA,
        isinstance(cycle_id, str),
        bool(cycle_id),
        state.get('phase') in CYCLE_STATE_PHASES,
        state.get('outcome') in CYCLE_STATE_OUTCOMES,
        parse_time(state.get('heartbeat_at')) > 0,
        valid_cycle_progress(progress),
        valid_cycle_blocker(blocker),
    )):
        return False
    if state.get('outcome') == 'running':
        return state.get('phase') != 'completed'
    return valid_terminal_cycle_state(state, progress, blocker)


def build_cycle_state(path):
    try:
        with open(path, encoding='utf-8') as handle:
            health = json.load(handle)
    except FileNotFoundError:
        health = {}
    except (OSError, json.JSONDecodeError, TypeError):
        return unavailable_cycle_state('malformed', 'health-json')
    if not isinstance(health, dict):
        return unavailable_cycle_state('malformed', 'health-object')
    state = health.get('cycle_state')
    if state is None:
        return unavailable_cycle_state('unavailable')
    if not isinstance(state, dict) or not valid_cycle_state_contract(state):
        reason = 'cycle-state-object' if not isinstance(state, dict) else 'cycle-state-contract'
        return unavailable_cycle_state('malformed', reason)
    progress = state['progress']
    blocker = state['blocker']
    return {
        'availability': 'available',
        'schema': state['schema'],
        'cycle_id': state['cycle_id'],
        'phase': state['phase'],
        'outcome': state['outcome'],
        'heartbeat_at': state['heartbeat_at'],
        'progress': {
            'last_at': progress['last_at'],
            'kinds': progress['kinds'],
            'consecutive_no_progress_cycles': progress['consecutive_no_progress_cycles'],
        },
        'blocker': {
            'kind': blocker['kind'],
            'fingerprint': blocker['fingerprint'],
            'consecutive_same_cycles': blocker['consecutive_same_cycles'],
        },
    }


def parse_stage(line):
    parts = line.split('\t')
    if not parts:
        return None
    ts = parse_time(parts[0])
    if ts < since:
        return None
    return {
        'ts': ts,
        'issue': parts[1] if len(parts) > 1 else '',
        'repo': parts[2] if len(parts) > 2 else '',
        'stage': parts[3] if len(parts) > 3 else 'unknown',
        'duration_ms': int(parts[4]) if len(parts) > 4 and str(parts[4]).isdigit() else 0,
    }


def classify_metric(item):
    result = str(item.get('result') or 'unknown')
    failure_reason = str(item.get('failure_reason') or '')
    exit_code = item.get('exit_code')
    if result == 'success' and exit_code == 0:
        return 'success'
    if result in {'watchdog_stall_killed', 'watchdog_stall_continue'}:
        return result
    if result in {'rate_limit', 'rate_limit_fast'} or 'rate_limit' in failure_reason:
        return 'rate_limit'
    if result in {'worker_noop', 'no_work', 'noop'}:
        return 'worker_noop'
    return result


def line_count(patterns, lines):
    count = 0
    examples = []
    for line in lines:
        lower = line.lower()
        if any(pattern in lower for pattern in patterns):
            count += 1
            if len(examples) < 3:
                examples.append(line[-180:])
    return count, examples


def read_state_file(path):
    state = {}
    try:
        with open(path, encoding='utf-8', errors='replace') as handle:
            for raw_line in handle:
                line = raw_line.rstrip('\n')
                if '=' not in line:
                    continue
                key, value = line.split('=', 1)
                state[key] = value
    except OSError:
        return {}
    return state


def build_objective_reconciliation(path):
    objectives = []
    try:
        with open(path, encoding='utf-8') as handle:
            payload = json.load(handle)
        objectives = payload.get('objectives', [])
        if not isinstance(objectives, list):
            objectives = []
    except (OSError, json.JSONDecodeError, TypeError):
        objectives = []
    terminal = {'completed', 'cancelled', 'impossible'}
    nonterminal = [item for item in objectives if item.get('objective_state') not in terminal]
    missing_action = [
        item for item in nonterminal
        if not item.get('next_action') or item.get('next_action') == 'none' or item.get('trigger_at') is None
    ]
    expired = [item for item in nonterminal if item.get('assumption_expired') is True]
    oldest = min(expired, key=lambda item: item.get('evidence_timestamp', float('inf')), default=None)
    oldest_projection = None
    if oldest:
        oldest_projection = {
            'number': oldest.get('number'),
            'objective_state': oldest.get('objective_state', ''),
            'evidence_timestamp': oldest.get('evidence_timestamp'),
            'assumption_expires_at': oldest.get('assumption_expires_at'),
            'next_action': oldest.get('next_action', ''),
            'responsible_component': oldest.get('responsible_component', ''),
        }
    return {
        'total': len(objectives),
        'nonterminal': len(nonterminal),
        'objectives_without_next_action': len(missing_action),
        'expired_assumptions': len(expired),
        'oldest_unverified_assumption': oldest_projection,
    }


def graphql_pressure_seen(graphql_budget, pre_launch_blockers):
    if graphql_budget['skipped_low_count'] > 0:
        return True
    if graphql_budget['circuit_broken_count'] > 0:
        return True
    return pre_launch_blockers.get('graphql_circuit_breaker', 0) > 0


def dispatch_blocked_by_graphql_budget(graphql_budget_status, graphql_budget, pre_launch_blockers):
    if graphql_budget_status.startswith('TRIPPED:'):
        return True
    if graphql_budget_status.startswith('OK:'):
        return False
    return graphql_pressure_seen(graphql_budget, pre_launch_blockers)


def build_pre_launch_blockers(counter_hits):
    blockers = {}
    prefix = 'dispatch_candidate_failed_reason_'
    for key, count in counter_hits.items():
        if key.startswith(prefix):
            reason = key[len(prefix):]
            blockers[reason] = blockers.get(reason, 0) + count
    breaker_counters = {
        'graphql_circuit_breaker': 'dispatch_graphql_circuit_blocked',
        'runner_health_circuit_breaker': 'pulse_dispatch_runner_health_breaker_tripped',
    }
    for reason, counter_name in breaker_counters.items():
        count = counter_hits.get(counter_name, 0)
        if count:
            blockers[reason] = max(blockers.get(reason, 0), count)
    guardrail_reasons = (
        'provider_rate_limit_pressure',
        'repeated_failure_pressure',
        'healthy_pr_backlog',
        'no_dispatchable_evidence',
    )
    for guardrail_reason in guardrail_reasons:
        counter_name = f'dispatch_candidate_failed_reason_{guardrail_reason}'
        count = counter_hits.get(counter_name, 0)
        if count:
            blockers[guardrail_reason] = max(blockers.get(guardrail_reason, 0), count)
    return blockers


def top_blockers(blockers):
    return [
        {'reason': reason, 'count': count}
        for reason, count in sorted(blockers.items(), key=lambda item: (-item[1], item[0]))
    ]


def worker_worktree_placeholders():
    worker_worktree_count = os.environ.get('AIDEVOPS_WORKER_WORKTREE_COUNT', '0')
    if worker_worktree_count.isdigit():
        return [None] * int(worker_worktree_count)
    return []


def active_worker_process_count():
    active_worker_output = os.environ.get('AIDEVOPS_ACTIVE_WORKER_PROCESSES', '')
    if active_worker_output.isdigit():
        return int(active_worker_output)
    return None


def graphql_budget_status_from_env():
    return os.environ.get('AIDEVOPS_GRAPHQL_BUDGET_STATUS') or 'UNKNOWN: no cached status'


def graphql_deferred_stages(counter_hits):
    prefix = 'pulse_graphql_budget_stage_deferred_'
    return {
        key[len(prefix):]: count
        for key, count in sorted(counter_hits.items())
        if key.startswith(prefix)
    }


def graphql_related_gauges(gauge_values):
    return {
        key: value
        for key, value in gauge_values.items()
        if any(token in key.lower() for token in ('graphql', 'budget', 'rate'))
    }


def build_graphql_budget(counter_hits, gauge_values):
    return {
        'skipped_low_count': counter_hits.get('pulse_cycle_skipped_graphql_low', 0),
        'circuit_broken_count': counter_hits.get('pulse_dispatch_circuit_broken', 0),
        'prefetch_throttled_count': counter_hits.get('pulse_prefetch_budget_throttled', 0),
        'force_rest_reads_count': counter_hits.get('pulse_graphql_low_force_rest_reads', 0),
        'reserve_mode_count': counter_hits.get('pulse_graphql_budget_reserve_mode', 0),
        'deferred_stage_count': counter_hits.get('pulse_graphql_budget_stage_deferred', 0),
        'deferred_stages': graphql_deferred_stages(counter_hits),
        'gauges': graphql_related_gauges(gauge_values),
    }


def build_current_state_guardrails(counter_hits, pre_launch_blockers, gauge_values):
    reasons = (
        'provider_rate_limit_pressure',
        'repeated_failure_pressure',
        'healthy_pr_backlog',
        'no_dispatchable_evidence',
    )
    return {
        'applied_count': counter_hits.get('pulse_dispatch_current_state_guardrail_applied', 0),
        'available_slots_last': gauge_values.get('pulse_dispatch_guardrail_available_slots'),
        'reasons': {
            reason: pre_launch_blockers.get(reason, 0)
            for reason in reasons
            if pre_launch_blockers.get(reason, 0)
        },
    }


stage_records = []
for line in recent_lines(os.path.join(log_dir, 'dispatch-stages.tsv')):
    record = parse_stage(line)
    if record:
        stage_records.append(record)
metrics = []
for line in recent_lines(os.path.join(log_dir, 'headless-runtime-metrics.jsonl')):
    try:
        item = json.loads(line)
    except json.JSONDecodeError:
        continue
    if float(item.get('ts', 0)) >= since:
        metrics.append(item)

counter_hits = {}
gauge_values = {}
stats_path = os.path.join(log_dir, 'pulse-stats.json')
if os.path.exists(stats_path):
    try:
        with open(stats_path, encoding='utf-8') as stats_file:
            stats = json.load(stats_file)
        for key, values in (stats.get('counters') or {}).items():
            if isinstance(values, list):
                hits = [v for v in values if isinstance(v, (int, float)) and v >= since]
                if hits:
                    counter_hits[key] = len(hits)
        for key, item in (stats.get('gauges') or {}).items():
            if isinstance(item, dict) and float(item.get('ts', 0)) >= since:
                gauge_values[key] = item.get('value')
    except (OSError, json.JSONDecodeError):
        counter_hits = {}
        gauge_values = {}

wrapper_log_lines = recent_lines(os.path.join(log_dir, 'pulse-wrapper.log'), 400)
wrapper_activity = []
for line in wrapper_log_lines:
    if 'Instance lock acquired' in line or 'detector-loop' in line:
        continue
    if line.strip():
        wrapper_activity.append(line)
wrapper_activity = wrapper_activity[-10:]

canonical_reconciliation_refusal_count = sum(
    1 for line in wrapper_log_lines
    if 'Refusing reconciliation: HEAD is not exact origin/' in line
)
canonical_recovery_advisory_observed = any(
    'diagnostic-only canonical state:' in line or 'advisory filed locally:' in line
    for line in wrapper_log_lines
)
canonical_reconciliation_classification = 'none'
if canonical_reconciliation_refusal_count:
    canonical_reconciliation_classification = (
        'dirty_or_uncommitted'
        if canonical_recovery_advisory_observed
        else 'upstream_or_default_branch_mismatch'
    )

metric_class_counts = Counter(classify_metric(item) for item in metrics)
stage_counts = Counter(record['stage'] for record in stage_records)
stage_timing = defaultdict(lambda: {'count': 0, 'sum_ms': 0, 'max_ms': 0})
for record in stage_records:
    item = stage_timing[record['stage']]
    item['count'] += 1
    item['sum_ms'] += record['duration_ms']
    item['max_ms'] = max(item['max_ms'], record['duration_ms'])
stage_timing_summary = {
    key: {
        'count': value['count'],
        'avg_ms': int(value['sum_ms'] / value['count']) if value['count'] else 0,
        'max_ms': value['max_ms'],
    }
    for key, value in stage_timing.items()
}

worker_spawn_count = stage_counts.get('worker_launch_total', 0) + sum(
    1 for line in wrapper_activity if 'worker_start' in line or 'worker_started' in line
)
canary_fail_count = counter_hits.get('worker_canary_preflight_failed_count', 0) + sum(
    1 for line in wrapper_activity if 'canary failed' in line.lower()
)
load_blocked_count = counter_hits.get('dispatch_load_blocked', 0) + sum(
    1 for line in wrapper_activity if 'system overloaded' in line.lower() or 'load-blocked' in line.lower()
)
rate_limit_count = metric_class_counts.get('rate_limit', 0)
watchdog_kill_count = metric_class_counts.get('watchdog_stall_killed', 0)
noop_count = metric_class_counts.get('worker_noop', 0)
launch_validation_failure_count = counter_hits.get('dispatch_worker_launch_failed', 0)
pr_opened_count, pr_opened_examples = line_count(['pr opened', 'opened pr', 'pull request'], wrapper_activity)
pr_merged_count, pr_merged_examples = line_count(['pr merged', 'merged pr', 'squash merged'], wrapper_activity)
issue_closed_count, issue_closed_examples = line_count(['issue closed', 'closed issue', 'status:done'], wrapper_activity)
graphql_budget = build_graphql_budget(counter_hits, gauge_values)
dispatch_pacing = {
    'inter_launch_staggered_count': counter_hits.get('dispatch_inter_launch_staggered', 0),
    'last_inter_launch_delay_seconds': gauge_values.get('dispatch_inter_launch_delay_seconds'),
}
pre_launch_blockers = build_pre_launch_blockers(counter_hits)
top_pre_launch_blockers = top_blockers(pre_launch_blockers)
worktrees = worker_worktree_placeholders()
active_worker_processes = active_worker_process_count()
graphql_budget_status = graphql_budget_status_from_env()
dispatch_api_blocked = dispatch_blocked_by_graphql_budget(
    graphql_budget_status,
    graphql_budget,
    pre_launch_blockers,
)
current_state_guardrails = build_current_state_guardrails(counter_hits, pre_launch_blockers, gauge_values)

api_consumers = []
api_pressure = {
    'graphql_read_calls': 0,
    'rest_read_calls': 0,
    'graphql_search_calls': 0,
    'rest_search_calls': 0,
    'graphql_other_calls': 0,
    'read_rest_ratio': None,
    'top_read_graphql_callers': [],
    'shadow_mode': 'gh shim records operation-specific read/list callers; REST rows are before/after counter for fallback routing',
}
api_report = os.path.join(log_dir, 'gh-api-calls-by-stage.json')
if os.path.exists(api_report):
    try:
        with open(api_report, encoding='utf-8') as api_report_file:
            report = json.load(api_report_file)
        read_graphql_callers = []
        read_caller_names = {'gh_issue_list', 'gh_pr_list', 'gh_issue_view', 'gh_pr_view'}
        rest_read_caller_names = {'_rest_issue_list', '_rest_pr_list', '_rest_issue_view', '_rest_pr_view'}
        for caller, data in (report.get('by_caller') or {}).items():
            if not isinstance(data, dict):
                continue
            gql = int(data.get('graphql_calls') or 0) + int(data.get('search_graphql_calls') or 0)
            if gql > 0:
                api_consumers.append({'caller': caller, 'graphql_calls': gql})
            graphql_calls = int(data.get('graphql_calls') or 0)
            rest_calls = int(data.get('rest_calls') or 0)
            search_graphql_calls = int(data.get('search_graphql_calls') or 0)
            search_rest_calls = int(data.get('search_rest_calls') or 0)
            if caller in read_caller_names:
                api_pressure['graphql_read_calls'] += graphql_calls
                api_pressure['rest_read_calls'] += rest_calls
                if graphql_calls > 0:
                    read_graphql_callers.append({'caller': caller, 'graphql_calls': graphql_calls})
            elif caller in rest_read_caller_names:
                api_pressure['rest_read_calls'] += rest_calls
            else:
                api_pressure['graphql_other_calls'] += graphql_calls
            api_pressure['graphql_search_calls'] += search_graphql_calls
            api_pressure['rest_search_calls'] += search_rest_calls
        api_consumers = sorted(api_consumers, key=lambda item: item['graphql_calls'], reverse=True)[:5]
        read_total = api_pressure['graphql_read_calls'] + api_pressure['rest_read_calls']
        if read_total > 0:
            api_pressure['read_rest_ratio'] = round(api_pressure['rest_read_calls'] / read_total, 4)
        api_pressure['top_read_graphql_callers'] = sorted(
            read_graphql_callers, key=lambda item: item['graphql_calls'], reverse=True
        )[:5]
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        api_consumers = []
        api_pressure = {
            'graphql_read_calls': 0,
            'rest_read_calls': 0,
            'graphql_search_calls': 0,
            'rest_search_calls': 0,
            'graphql_other_calls': 0,
            'read_rest_ratio': None,
            'top_read_graphql_callers': [],
            'shadow_mode': 'unavailable: failed to parse gh-api report',
        }

prefetch_cache = {
    'batch_cache_hits': 0,
    'conditional_304': 0,
    'conditional_refreshes': 0,
    'conditional_misses': 0,
}
health_path = os.path.join(log_dir, 'pulse-health.json')
cycle_state = build_cycle_state(health_path)
if os.path.exists(health_path):
    try:
        with open(health_path, encoding='utf-8') as health_file:
            health = json.load(health_file)
        prefetch_cache = {
            'batch_cache_hits': int(health.get('batch_cache_hits') or 0),
            'conditional_304': int(health.get('prefetch_conditional_304') or 0),
            'conditional_refreshes': int(health.get('prefetch_conditional_refreshes') or 0),
            'conditional_misses': int(health.get('prefetch_conditional_misses') or 0),
        }
    except (OSError, json.JSONDecodeError, TypeError, ValueError):
        pass

review_thread_attention = []
if os.path.isdir(review_thread_state_dir):
    try:
        for name in sorted(os.listdir(review_thread_state_dir)):
            if not name.endswith('.state') or name.endswith('-cursor.state'):
                continue
            state = read_state_file(os.path.join(review_thread_state_dir, name))
            if state.get('analysis_complete') == 'true' and state.get('maintainer_attention') == 'true':
                stem = name[:-len('.state')]
                repo_key, _, pr_text = stem.rpartition('-')
                pr_number = int(pr_text) if pr_text.isdigit() else None
                review_thread_attention.append({
                    'state_file': name,
                    'repo_key': repo_key,
                    'pr_number': pr_number,
                    'blocked_by': state.get('blocked_by') or 'decision',
                    'reason': state.get('blocker_reason') or state.get('attention_reason') or '',
                    'details': state.get('blocker_details') or '',
                    'thread_count': int(state.get('thread_count') or 0) if str(state.get('thread_count') or '').isdigit() else 0,
                    'attempt_count': int(state.get('attempt_count') or 0) if str(state.get('attempt_count') or '').isdigit() else 0,
                    'completed_at': int(state.get('completed_at') or 0) if str(state.get('completed_at') or '').isdigit() else 0,
                })
    except OSError:
        review_thread_attention = []

objective_reconciliation = build_objective_reconciliation(
    os.environ.get('AIDEVOPS_OBJECTIVE_STATE_FILE', '')
)

result = {
    'window_seconds': window_s,
    'dispatch_stage_events': len(stage_records),
    'dispatch_stage_counts': dict(stage_counts),
    'dispatch_stage_timing_ms': stage_timing_summary,
    'worker_terminal_events': len(metrics),
    'worker_result_counts': dict(metric_class_counts),
    'worker_successes': metric_class_counts.get('success', 0),
    'worker_failures_or_stalls': sum(count for key, count in metric_class_counts.items() if key != 'success'),
    'worker_outcomes': {
        'spawned': worker_spawn_count,
        'canary_failed': canary_fail_count,
        'watchdog_killed': watchdog_kill_count,
        'rate_limited': rate_limit_count,
        'no_op': noop_count,
        'launch_validation_failed': launch_validation_failure_count,
        'pr_opened': pr_opened_count,
        'pr_merged': pr_merged_count,
        'issue_closed': issue_closed_count,
    },
    'worker_outcome_examples': {
        'pr_opened': pr_opened_examples,
        'pr_merged': pr_merged_examples,
        'issue_closed': issue_closed_examples,
    },
    'resource_context': {
        'load_1min_last': next((item.get('load_1min') for item in reversed(metrics) if item.get('load_1min') is not None), None),
        'load_per_cpu_last': next((item.get('load_per_cpu') for item in reversed(metrics) if item.get('load_per_cpu') is not None), None),
        'load_blocked_count': load_blocked_count,
    },
    'graphql_budget': graphql_budget,
    'dispatch_pacing': dispatch_pacing,
    'current_state_guardrails': current_state_guardrails,
    'pre_launch_blockers': pre_launch_blockers,
    'top_pre_launch_blockers': top_pre_launch_blockers[:5],
    'pulse_counter_hits': counter_hits,
    'pulse_gauges': gauge_values,
    'canonical_reconciliation': {
        'refusal_count': canonical_reconciliation_refusal_count,
        'classification': canonical_reconciliation_classification,
        'canonical_recovery_advisory_observed': canonical_recovery_advisory_observed,
    },
    'wrapper_activity_lines': len(wrapper_activity),
    'active_worker_processes': active_worker_processes,
    'worker_worktrees': len(worktrees),
    'dispatch_alive': bool(stage_records or metrics or counter_hits or worktrees),
    'graphql_budget_status': graphql_budget_status,
    'dispatch_api_blocked': dispatch_api_blocked,
    'top_graphql_consumers': api_consumers,
    'api_call_pressure': api_pressure,
    'prefetch_cache': prefetch_cache,
    'cycle_state': cycle_state,
    'review_thread_attention': review_thread_attention,
    'objective_reconciliation': objective_reconciliation,
}

runtime_state = {
    'active_worker_processes': active_worker_processes,
    'api_call_pressure': {
        'graphql_other_calls': api_pressure['graphql_other_calls'],
        'graphql_read_calls': api_pressure['graphql_read_calls'],
        'graphql_search_calls': api_pressure['graphql_search_calls'],
        'read_rest_ratio': api_pressure['read_rest_ratio'],
        'rest_read_calls': api_pressure['rest_read_calls'],
        'rest_search_calls': api_pressure['rest_search_calls'],
    },
    'current_state_guardrails': current_state_guardrails,
    'canonical_reconciliation': result['canonical_reconciliation'],
    'dispatch_alive': result['dispatch_alive'],
    'dispatch_api_blocked': dispatch_api_blocked,
    'dispatch_pacing': dispatch_pacing,
    'dispatch_stage_counts': dict(stage_counts),
    'graphql_budget': graphql_budget,
    'prefetch_cache': prefetch_cache,
    'cycle_state': cycle_state,
    'pre_launch_blockers': pre_launch_blockers,
    'pulse_counter_hits': counter_hits,
    'pulse_gauges': gauge_values,
    'resource_context': result['resource_context'],
    'review_thread_attention_count': len(review_thread_attention),
    'objective_reconciliation': objective_reconciliation,
    'window_seconds': window_s,
    'worker_outcomes': result['worker_outcomes'],
    'worker_result_counts': dict(metric_class_counts),
    'worker_worktrees': len(worktrees),
}
runtime_state_output = os.environ.get('AIDEVOPS_RUNTIME_STATE_OUTPUT', '')
if runtime_state_output:
    try:
        with open(runtime_state_output, 'w', encoding='utf-8') as runtime_state_file:
            json.dump(runtime_state, runtime_state_file, separators=(',', ':'), sort_keys=True)
    except OSError:
        pass

if as_json:
    print(json.dumps(result, indent=2, sort_keys=True))
else:
    print('Pulse current-state snapshot')
    print(f'- Window: {window_s}s')
    print(f'- Dispatch alive: {str(result["dispatch_alive"]).lower()}')
    print(f'- Dispatch stage events: {result["dispatch_stage_events"]}')
    print(f'- Dispatch stage counts: {json.dumps(result["dispatch_stage_counts"], sort_keys=True)}')
    print(f'- Worker terminal events: {result["worker_terminal_events"]} ({result["worker_successes"]} success, {result["worker_failures_or_stalls"]} non-success)')
    print(f'- Worker outcomes: {json.dumps(result["worker_outcomes"], sort_keys=True)}')
    print(f'- Resource context: {json.dumps(result["resource_context"], sort_keys=True)}')
    print(f'- GraphQL budget: {json.dumps(result["graphql_budget"], sort_keys=True)}')
    print(f'- Dispatch pacing: {json.dumps(result["dispatch_pacing"], sort_keys=True)}')
    print(f'- Current-state guardrails: {json.dumps(result["current_state_guardrails"], sort_keys=True)}')
    print(f'- Top pre-launch blockers: {json.dumps(result["top_pre_launch_blockers"], sort_keys=True)}')
    print(f'- Pulse counter hits: {json.dumps(counter_hits, sort_keys=True)}')
    print(f'- GraphQL budget: {graphql_budget_status}')
    print(f'- Prefetch cache: {json.dumps(prefetch_cache, sort_keys=True)}')
    print(f'- Cycle state: {json.dumps(cycle_state, sort_keys=True)}')
    print(f'- Dispatch API blocked by GraphQL: {str(dispatch_api_blocked).lower()}')
    print(f'- Active worker processes: {active_worker_processes if active_worker_processes is not None else "unknown"}')
    if api_consumers:
        print(f'- Top GraphQL consumers: {json.dumps(api_consumers)}')
    print(f'- API call pressure: {json.dumps(api_pressure, sort_keys=True)}')
    print(f'- Review-thread maintainer attention: {json.dumps(review_thread_attention, sort_keys=True)}')
    print(f'- Objectives without next action: {objective_reconciliation["objectives_without_next_action"]}')
    print(f'- Oldest unverified assumption: {json.dumps(objective_reconciliation["oldest_unverified_assumption"], sort_keys=True)}')
    print(f'- Worker worktrees: {result["worker_worktrees"]}')
    if wrapper_activity:
        print('- Recent wrapper activity:')
        for line in wrapper_activity[-3:]:
            print(f'  - {line[-180:]}')
