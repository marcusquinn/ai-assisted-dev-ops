#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stored evidence readers for content-free social provider health."""

from __future__ import annotations

import json
import sqlite3
from typing import Any, Iterable

from knowledge_social_store import SocialStoreError

QUEUE_STATES = (
    "draft", "approved", "claimed", "succeeded", "failed", "unknown", "cancelled"
)


def json_object(value: str, label: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {label} is invalid") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError(f"stored social {label} must be an object")
    return parsed


def json_array(value: str, label: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {label} is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise SocialStoreError(f"stored social {label} must be an array of text")
    return sorted(set(parsed))


def stale_seconds(row: sqlite3.Row, fallback: int) -> int:
    policy = json_object(str(row["policy_json"]), "health policy")
    value = policy.get("health_stale_seconds", fallback)
    if isinstance(value, bool) or not isinstance(value, int) or value < 60:
        raise SocialStoreError(
            "stored social health_stale_seconds must be an integer of at least 60"
        )
    return value


def connections(database: sqlite3.Connection) -> list[sqlite3.Row]:
    return database.execute(
        "SELECT connection_id,provider,auth_profile_ref,enabled_streams,policy_json "
        "FROM connections ORDER BY provider,connection_id"
    ).fetchall()


def latest_sync(
    database: sqlite3.Connection, connection_id: str
) -> sqlite3.Row | None:
    return database.execute(
        """SELECT status,failure_class,retry_after,started_at,completed_at
             FROM sync_runs WHERE connection_id=?
             ORDER BY COALESCE(completed_at,started_at,0) DESC,rowid DESC LIMIT 1""",
        (connection_id,),
    ).fetchone()


def latest_stream_sync(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> sqlite3.Row | None:
    return database.execute(
        """SELECT status,failure_class,retry_after,started_at,completed_at
             FROM sync_runs WHERE connection_id=? AND stream=?
             ORDER BY COALESCE(completed_at,started_at,0) DESC,rowid DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()


def queue(rows: list[dict[str, Any]], now: int) -> dict[str, int]:
    result = {state: 0 for state in QUEUE_STATES}
    for row in rows:
        state = str(row["state"])
        if state in result:
            result[state] += 1
    result["due"] = sum(
        row["state"] == "approved"
        and int(row["scheduled_at"]) <= now
        and bool(row["has_current_approval"])
        for row in rows
    )
    result["leased"] = sum(row["state"] == "claimed" for row in rows)
    result["total"] = len(rows)
    return result


def _optional_event(
    observed_at: int, status: object, failure: object, reached: bool
) -> tuple[int, str, str | None, bool] | None:
    if status is None or not observed_at:
        return None
    return observed_at, str(status), failure, reached


def _optional_failure(observed_at: int, failure: object) -> tuple[int, str] | None:
    if failure is None or not observed_at:
        return None
    return observed_at, str(failure)


def _optional_success(observed_at: int, successful: bool) -> list[int]:
    if not successful or not observed_at:
        return []
    return [observed_at]


def _sync_events(
    sync: sqlite3.Row | None,
) -> tuple[list[tuple[int, str, str | None, bool]], list[int], list[tuple[int, str]]]:
    if sync is None:
        return [], [], []
    observed_at = int(sync["completed_at"] or sync["started_at"] or 0)
    status = str(sync["status"])
    failure = sync["failure_class"]
    reached = status in ("complete", "partial") or failure == "rate_limit"
    event = _optional_event(observed_at, status, failure, reached)
    failed = _optional_failure(observed_at, failure)
    events = [event] if event is not None else []
    successes = _optional_success(observed_at, status in ("complete", "partial"))
    failures = [failed] if failed is not None else []
    return events, successes, failures


def _row_event(
    row: dict[str, Any],
) -> tuple[tuple[int, str, str | None, bool] | None, int | None, tuple[int, str] | None]:
    observed_at = int(row["finished_at"] or 0)
    status = row["attempt_status"]
    failure = row["failure_class"]
    reached = status == "succeeded" or (
        failure == "rate_limit" and row["provider_started_at"] is not None
    )
    event = _optional_event(observed_at, status, failure, reached)
    successes = _optional_success(observed_at, status == "succeeded")
    success = successes[0] if successes else None
    failed = _optional_failure(observed_at, failure)
    return event, success, failed


def _operation_events(
    rows: Iterable[dict[str, Any]],
) -> tuple[list[tuple[int, str, str | None, bool]], list[int], list[tuple[int, str]]]:
    events: list[tuple[int, str, str | None, bool]] = []
    successes: list[int] = []
    failures: list[tuple[int, str]] = []
    for row in rows:
        event, success, failed = _row_event(row)
        if event is not None:
            events.append(event)
        if success is not None:
            successes.append(success)
        if failed is not None:
            failures.append(failed)
    return events, successes, failures


def evidence(
    sync: sqlite3.Row | None, rows: list[dict[str, Any]]
) -> dict[str, Any]:
    events, successes, failures = _sync_events(sync)
    row_events, row_successes, row_failures = _operation_events(rows)
    events.extend(row_events)
    successes.extend(row_successes)
    failures.extend(row_failures)
    latest = max(events, default=None, key=lambda event: event[0])
    latest_failure = max(failures, default=None, key=lambda event: event[0])
    return {
        "evidence_at": latest[0] if latest else None,
        "latest_status": latest[1] if latest else None,
        "latest_failure": latest[2] if latest else None,
        "latest_reached": latest[3] if latest else None,
        "last_success_at": max(successes, default=None),
        "last_failure_class": latest_failure[1] if latest_failure else None,
    }


def authentication(
    configured: bool, stored_evidence: dict[str, Any]
) -> tuple[bool | None, bool | None]:
    if not configured:
        return False, None
    failure = stored_evidence["latest_failure"]
    if failure in ("authorization", "identity"):
        return False, None
    if stored_evidence["latest_reached"] is True:
        return True, True
    if failure == "provider_unavailable":
        return None, False
    return None, None


def freshness(
    stored_evidence: dict[str, Any], now: int, stale_after: int
) -> tuple[dict[str, int | bool | None], bool]:
    evidence_at = stored_evidence["evidence_at"]
    lag = max(0, now - evidence_at) if evidence_at is not None else None
    stale = lag is not None and lag > stale_after
    return (
        {
            "evidence_at": evidence_at,
            "lag_seconds": lag,
            "stale_after_seconds": stale_after,
            "stale": stale,
        },
        stale,
    )
