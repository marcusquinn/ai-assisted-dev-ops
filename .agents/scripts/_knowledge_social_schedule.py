#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-safe deterministic social due plans and receipt reads."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RUN_KINDS, social_now
from knowledge_social_store import (
    SocialStoreError,
    connect_read_only,
    require_schema,
    validate_opaque,
)

DEFAULT_SYNC_INTERVAL = 86_400
DEFAULT_RECONCILE_INTERVAL = 604_800


def _parse_json_object(value: str, field: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {field} is invalid") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError(f"stored social {field} must be an object")
    return parsed


def _parse_json_array(value: str, field: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {field} is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise SocialStoreError(f"stored social {field} must be an array of text")
    return parsed


def _interval(policy: dict[str, Any], key: str, fallback: int) -> int:
    value = policy.get(key, fallback)
    if isinstance(value, bool) or not isinstance(value, int) or value < 60:
        raise SocialStoreError(f"stored social {key} must be an integer of at least 60")
    return value


def _iso_epoch(value: str | None) -> int | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SocialStoreError("stored social timestamp is invalid") from error
    if parsed.tzinfo is None:
        raise SocialStoreError("stored social timestamp requires a timezone")
    return int(parsed.timestamp())


def _last_run(
    database: sqlite3.Connection, connection_id: str, stream: str, run_kind: str
) -> sqlite3.Row | None:
    return database.execute(
        "SELECT status,failure_class,completed_at,retry_after FROM sync_runs "
        "WHERE connection_id=? AND stream=? AND run_kind=? "
        "ORDER BY started_at DESC,rowid DESC LIMIT 1",
        (connection_id, stream, run_kind),
    ).fetchone()


def _running_due_at(database: sqlite3.Connection, connection_id: str) -> int:
    row = database.execute(
        "SELECT expires_at FROM collector_leases WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    return int(row["expires_at"]) if row else 0


def _cursor_due_at(
    database: sqlite3.Connection,
    connection_id: str,
    stream: str,
    interval: int,
) -> int:
    cursor = database.execute(
        "SELECT last_success_at FROM sync_cursors WHERE connection_id=? AND stream=?",
        (connection_id, stream),
    ).fetchone()
    last_success = _iso_epoch(cursor["last_success_at"]) if cursor else None
    return last_success + interval if last_success is not None else 0


def _rate_limit_due_at(run: sqlite3.Row) -> int | None:
    if run["status"] != "paused" or run["failure_class"] != "rate_limit":
        return None
    retry_after = str(run["retry_after"] or "")
    return int(retry_after) if retry_after.isdigit() else None


def _due_at(
    database: sqlite3.Connection,
    connection_id: str,
    stream: str,
    run_kind: str,
    interval: int,
) -> int:
    run = _last_run(database, connection_id, stream, run_kind)
    if run is None:
        return _cursor_due_at(database, connection_id, stream, interval) if run_kind == "sync" else 0
    if run["status"] == "running":
        return _running_due_at(database, connection_id)
    if run["completed_at"] is not None:
        due_at = int(run["completed_at"]) + interval
        rate_limit_due = _rate_limit_due_at(run)
        return rate_limit_due if rate_limit_due is not None else due_at
    if run_kind == "sync":
        return _cursor_due_at(database, connection_id, stream, interval)
    return 0


def _validate_due_inputs(run_kind: str, interval_seconds: int | None) -> None:
    if run_kind not in RUN_KINDS:
        raise SocialStoreError("run_kind must be sync or reconcile")
    if interval_seconds is not None and (
        isinstance(interval_seconds, bool) or interval_seconds < 60
    ):
        raise SocialStoreError("interval_seconds must be at least 60")


def _schedule_settings(run_kind: str) -> tuple[str, int]:
    if run_kind == "sync":
        return "sync_interval_seconds", DEFAULT_SYNC_INTERVAL
    return "reconcile_interval_seconds", DEFAULT_RECONCILE_INTERVAL


def _connection_due_plan(
    database: sqlite3.Connection,
    row: sqlite3.Row,
    run_kind: str,
    now_epoch: int,
    interval_seconds: int | None,
) -> list[dict[str, Any]]:
    key, fallback = _schedule_settings(run_kind)
    policy = _parse_json_object(row["policy_json"], "policy")
    interval = (
        interval_seconds
        if interval_seconds is not None
        else _interval(policy, key, fallback)
    )
    streams = sorted(set(_parse_json_array(row["enabled_streams"], "streams")))
    due: list[dict[str, Any]] = []
    for stream in streams:
        due_at = _due_at(
            database, row["connection_id"], stream, run_kind, interval
        )
        if due_at <= now_epoch:
            due.append(
                {
                    "connection_id": row["connection_id"],
                    "stream": stream,
                    "run_kind": run_kind,
                    "due_at": due_at,
                }
            )
    return due


def due_plan(
    root: Path,
    run_kind: str,
    *,
    now_epoch: int | None = None,
    interval_seconds: int | None = None,
) -> list[dict[str, Any]]:
    """Return a stable list of due opaque connection streams."""
    _validate_due_inputs(run_kind, interval_seconds)
    now = social_now(now_epoch)
    database = connect_read_only(root)
    try:
        require_schema(database)
        rows = database.execute(
            "SELECT connection_id,enabled_streams,policy_json FROM connections "
            "ORDER BY connection_id"
        ).fetchall()
        due: list[dict[str, Any]] = []
        for row in rows:
            due.extend(
                _connection_due_plan(
                    database, row, run_kind, now, interval_seconds
                )
            )
        return due
    finally:
        database.close()


def run_receipts(
    root: Path, connection_id: str | None = None, *, limit: int = 100
) -> list[dict[str, Any]]:
    """Return bounded privacy-safe receipts in deterministic order."""
    if isinstance(limit, bool) or not 1 <= limit <= 1000:
        raise SocialStoreError("receipt limit must be between 1 and 1000")
    if connection_id is not None:
        connection_id = validate_opaque(connection_id, "connection_id")
    database = connect_read_only(root)
    try:
        require_schema(database)
        if connection_id is not None:
            rows = database.execute(
                """SELECT run_id,connection_id,stream,run_kind,status,resource_count,
                   failure_class,retry_after,fencing_token,collector_id,started_at,
                   completed_at,request_hash FROM sync_runs WHERE connection_id=?
                   ORDER BY started_at DESC,rowid DESC LIMIT ?""",
                (connection_id, limit),
            ).fetchall()
        else:
            rows = database.execute(
                """SELECT run_id,connection_id,stream,run_kind,status,resource_count,
                   failure_class,retry_after,fencing_token,collector_id,started_at,
                   completed_at,request_hash FROM sync_runs
                   ORDER BY started_at DESC,rowid DESC LIMIT ?""",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]
    finally:
        database.close()
