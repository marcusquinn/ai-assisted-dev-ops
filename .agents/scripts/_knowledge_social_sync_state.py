#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced lease, run receipt, and due-state primitives for social sync."""

from __future__ import annotations

import argparse
import os
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from knowledge_social_import import canonical_json


class SyncError(RuntimeError):
    """Raised when deterministic synchronization cannot proceed safely."""


@dataclass(frozen=True)
class LeaseRequest:
    """One bounded collector lease request."""

    connection_id: str
    holder_id: str
    now: datetime
    lease_seconds: int


@dataclass(frozen=True)
class RunStart:
    """Values required to create a running receipt."""

    connection_id: str
    stream: str
    run_type: str
    token: int
    started_at: str


@dataclass(frozen=True)
class RunFinish:
    """Values required to finalize a running receipt."""

    run_id: str
    status: str
    completed_at: str
    resource_count: int = 0
    failure_class: str | None = None
    retry_after: str | None = None
    diagnostics: dict[str, Any] | None = None


def utc_text(value: datetime) -> str:
    """Return a canonical UTC timestamp."""
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    """Parse a canonical provider or local timestamp."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SyncError("timestamp must be ISO-8601") from error
    if parsed.tzinfo is None:
        raise SyncError("timestamp must include a timezone")
    return parsed.astimezone(UTC)


def now_for_args(args: argparse.Namespace) -> datetime:
    """Resolve the clock, allowing deterministic clocks only in tests."""
    if not args.now:
        return datetime.now(UTC)
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise SyncError("--now is available only in the test harness")
    return parse_time(args.now)


def _lease_generation(row: sqlite3.Row | None, request: LeaseRequest) -> int | None:
    if row is None or parse_time(row["lease_until"]) <= request.now:
        return 1 if row is None else int(row["fencing_token"]) + 1
    if row["holder_id"] == request.holder_id:
        return int(row["fencing_token"])
    return None


def acquire_lease(database: sqlite3.Connection, request: LeaseRequest) -> int | None:
    """Acquire or renew one connection lease and return its fencing token."""
    current_text = utc_text(request.now)
    lease_until = utc_text(request.now + timedelta(seconds=request.lease_seconds))
    database.execute("BEGIN IMMEDIATE")
    try:
        row = database.execute(
            "SELECT holder_id,fencing_token,lease_until FROM collector_leases "
            "WHERE connection_id=?",
            (request.connection_id,),
        ).fetchone()
        token = _lease_generation(row, request)
        if token is None:
            database.execute("ROLLBACK")
            return None
        if row is None or token != int(row["fencing_token"]):
            database.execute(
                """UPDATE sync_runs SET status='failed',failure_class='interrupted',
                   completed_at=? WHERE connection_id=? AND status='running'""",
                (current_text, request.connection_id),
            )
        database.execute(
            """INSERT INTO collector_leases(
               connection_id,holder_id,fencing_token,lease_until,acquired_at,updated_at)
               VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id) DO UPDATE SET
               holder_id=excluded.holder_id,fencing_token=excluded.fencing_token,
               lease_until=excluded.lease_until,acquired_at=excluded.acquired_at,
               updated_at=excluded.updated_at""",
            (
                request.connection_id,
                request.holder_id,
                token,
                lease_until,
                current_text,
                current_text,
            ),
        )
        database.execute("COMMIT")
        return token
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def release_lease(
    database: sqlite3.Connection, connection_id: str, holder_id: str, token: int
) -> bool:
    """Release only the exact lease generation owned by this collector."""
    deleted = database.execute(
        "DELETE FROM collector_leases WHERE connection_id=? AND holder_id=? "
        "AND fencing_token=?",
        (connection_id, holder_id, token),
    ).rowcount
    return deleted == 1


def begin_run(database: sqlite3.Connection, receipt: RunStart) -> str:
    """Persist a running receipt before external work begins."""
    run_id = uuid.uuid4().hex
    database.execute(
        """INSERT INTO sync_runs(
           run_id,connection_id,status,fencing_token,diagnostics,stream,run_type,started_at)
           VALUES(?,?,?,?,?,?,?,?)""",
        (
            run_id,
            receipt.connection_id,
            "running",
            str(receipt.token),
            canonical_json({"stream": receipt.stream}),
            receipt.stream,
            receipt.run_type,
            receipt.started_at,
        ),
    )
    return run_id


def finish_run(database: sqlite3.Connection, receipt: RunFinish) -> None:
    """Finalize a durable privacy-safe run receipt."""
    updated = database.execute(
        """UPDATE sync_runs SET status=?,resource_count=?,failure_class=?,retry_after=?,
           diagnostics=?,completed_at=? WHERE run_id=? AND status='running'""",
        (
            receipt.status,
            receipt.resource_count,
            receipt.failure_class,
            receipt.retry_after,
            canonical_json(receipt.diagnostics or {}),
            receipt.completed_at,
            receipt.run_id,
        ),
    ).rowcount
    if updated != 1:
        raise SyncError("run receipt is not in the running state")


def due_connections(
    database: sqlite3.Connection, now: datetime, interval_seconds: int
) -> tuple[list[sqlite3.Row], str]:
    """Return connections in stable order with the successful-run cutoff."""
    cutoff = utc_text(now - timedelta(seconds=interval_seconds))
    rows = database.execute(
        """SELECT connection_id,remote_account_id,enabled_streams
           FROM connections ORDER BY connection_id"""
    ).fetchall()
    return rows, cutoff


def last_success(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> str | None:
    """Return the last terminal successful routine receipt."""
    row = database.execute(
        """SELECT completed_at FROM sync_runs
           WHERE connection_id=? AND stream=? AND status='complete'
             AND completed_at IS NOT NULL ORDER BY completed_at DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()
    return None if row is None else str(row["completed_at"])


def retry_is_blocked(
    database: sqlite3.Connection,
    connection_id: str,
    stream: str,
    now: datetime,
) -> bool:
    """Honor the latest provider reset instead of creating a retry storm."""
    row = database.execute(
        """SELECT retry_after FROM sync_runs
           WHERE connection_id=? AND stream=? AND retry_after IS NOT NULL
           ORDER BY completed_at DESC,rowid DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()
    if row is None:
        return False
    value = str(row["retry_after"])
    try:
        reset = datetime.fromtimestamp(int(value), UTC)
    except ValueError:
        reset = parse_time(value)
    return reset > now
