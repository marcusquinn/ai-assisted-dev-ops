#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

"""Project recent worker health through durable attempt outcomes."""

import json
import math
import sys
import time
from collections import defaultdict, deque


KNOWN_OUTCOMES = {'success', 'failed', 'deferred', 'escalated'}
NOOP_RESULTS = {'worker_noop', 'no_work', 'noop'}
RATE_LIMIT_RESULTS = {'rate_limit', 'rate_limit_fast'}
PROVIDER_5XX = {'500', '502', '503', '504'}


def recent_json_rows(path, limit):
    """Read a bounded JSONL tail, skipping malformed or unavailable rows."""
    rows = []
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as handle:
            raw_rows = deque(handle, maxlen=limit)
    except OSError:
        return rows
    for raw in raw_rows:
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if isinstance(item, dict):
            rows.append(item)
    return rows


def numeric_timestamp(item):
    """Return a valid durable evidence timestamp, or None."""
    try:
        timestamp = float(item.get('evidence_timestamp'))
    except (TypeError, ValueError):
        return None
    return timestamp if math.isfinite(timestamp) and timestamp > 0 else None


def issue_identity(value):
    """Normalize a positive issue number used in an exact identity tuple."""
    try:
        number = int(value)
    except (TypeError, ValueError):
        return None
    return number if number > 0 else None


def outcome_index(path, limit):
    """Index bounded durable attempt outcomes by stable attempt identity."""
    outcomes = defaultdict(list)
    for item in recent_json_rows(path, limit):
        attempt_id = str(item.get('attempt_id') or '')
        effective = str(item.get('effective_outcome') or '')
        timestamp = numeric_timestamp(item)
        if item.get('record_type') != 'attempt_outcome' or not attempt_id or effective not in KNOWN_OUTCOMES or timestamp is None:
            continue
        outcomes[attempt_id].append(item)
    return outcomes


def matching_outcome(metric, outcomes):
    """Return the latest exact outcome compatible with metric scope."""
    attempt_id = str(metric.get('attempt_id') or '')
    repo_slug = str(metric.get('repo_slug') or '')
    issue_number = issue_identity(metric.get('issue_number'))
    if not attempt_id or not repo_slug or issue_number is None:
        return None
    matches = []
    for outcome in outcomes.get(attempt_id, []):
        if str(outcome.get('repo') or '') != repo_slug:
            continue
        if issue_identity(outcome.get('issue_number')) != issue_number:
            continue
        matches.append(outcome)
    return sorted(matches, key=numeric_timestamp)[-1] if matches else None


def provider_signals(item, result):
    """Return raw provider and progress safety signals for one metric."""
    failure_reason = str(item.get('failure_reason') or '')
    provider_type = str(item.get('provider_error_type') or '')
    provider_status = str(item.get('provider_status') or '')
    rate_limited = (
        result in RATE_LIMIT_RESULTS
        or provider_type == 'rate_limit'
        or provider_status == '429'
        or 'rate_limit' in failure_reason
    )
    progressing = (
        result in {'watchdog_stall_continue', 'service_interruption_continue'}
        or str(item.get('activity_detected') or '0') == '1'
    )
    return (
        int(rate_limited),
        int(result == 'service_interruption_exhausted'),
        int(provider_type == 'server_error' or provider_status in PROVIDER_5XX),
        int(progressing),
    )


def terminal_counts(item, outcomes, result):
    """Return reconciled generic success and failure counts."""
    outcome = matching_outcome(item, outcomes)
    effective = str(outcome.get('effective_outcome') or '') if outcome else ''
    if effective == 'success':
        return 1, 0
    if effective == 'failed':
        return 0, 1
    if effective in {'deferred', 'escalated'}:
        return 0, 0
    raw_success = result == 'success' and item.get('exit_code') == 0
    raw_failure = not raw_success and result not in NOOP_RESULTS
    return int(raw_success), int(raw_failure)


def project_health(metrics_path, evidence_path, window_seconds, evidence_limit):
    """Return terminal success/failure and raw provider-health counters."""
    since = time.time() - window_seconds
    outcomes = outcome_index(evidence_path, evidence_limit)
    totals = [0, 0, 0, 0, 0, 0]
    for item in recent_json_rows(metrics_path, 2000):
        try:
            timestamp = float(item.get('ts') or 0)
        except (TypeError, ValueError):
            timestamp = 0
        if timestamp < since or str(item.get('role') or '') != 'worker':
            continue
        result = str(item.get('result') or '')
        rate_limits, service_interruptions, provider_5xx, progress = provider_signals(item, result)
        totals[5] += progress
        if result.endswith('_continue') or result == 'brief_recovery':
            continue
        successes, failures = terminal_counts(item, outcomes, result)
        totals[0] += successes
        totals[1] += failures
        totals[2] += rate_limits
        totals[3] += service_interruptions
        totals[4] += provider_5xx
    return tuple(totals)


def main():
    """Print stable space-delimited counters for shell consumers."""
    if len(sys.argv) != 5:
        print('0 0 0 0 0 0')
        return 2
    metrics_path, evidence_path = sys.argv[1], sys.argv[2]
    try:
        window_seconds = int(sys.argv[3])
        evidence_limit = int(sys.argv[4])
    except ValueError:
        print('0 0 0 0 0 0')
        return 2
    print(*project_health(metrics_path, evidence_path, window_seconds, evidence_limit))
    return 0


if __name__ == '__main__':
    sys.exit(main())
