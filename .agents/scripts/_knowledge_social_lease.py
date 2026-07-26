#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic social collector leases, fencing, and run receipts."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from knowledge_social_store import SocialStoreError, connect, migrate, validate_opaque

RUN_KINDS = ("sync", "reconcile")
TERMINAL_RUN_STATES = (
    "complete",
    "failed",
    "paused",
    "unavailable",
    "abandoned",
)


class SocialLeaseBusyError(SocialStoreError):
    """Raised when another collector owns an unexpired connection lease."""


class SocialLeaseLostError(SocialStoreError):
    """Raised when a stale collector attempts a fenced write."""


@dataclass(frozen=True)
class RunLease:
    """One collector's time-bounded authority for a connection."""

    connection_id: str
    stream: str
    run_kind: str
    collector_id: str
    fencing_token: int
    run_id: str
    acquired_at: int
    expires_at: int


@dataclass(frozen=True)
class RunLeaseRequest:
    """Validated inputs for acquiring one connection-scoped run lease."""

    connection_id: str
    stream: str
    collector_id: str
    run_kind: str
    lease_seconds: int
    request_hash: str | None = None


@dataclass(frozen=True)
class RunReceiptUpdate:
    """Privacy-safe state transition for one fenced run receipt."""

    status: str
    resource_delta: int = 0
    failure_class: str | None = None
    retry_after: str | None = None
    terminal: bool = False


def _clock_value(explicit: int | None) -> Any:
    """Select the real clock or an authorized deterministic test value."""
    override = os.environ.get("AIDEVOPS_SOCIAL_NOW_EPOCH")
    if explicit is None and override is None:
        return int(datetime.now(UTC).timestamp())
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise SocialStoreError("social clock override is test-only")
    return explicit if explicit is not None else override


def social_now(explicit: int | None = None) -> int:
    """Return one validated clock value, with a deterministic test seam."""
    value = _clock_value(explicit)
    if isinstance(value, bool):
        raise SocialStoreError("social clock must be a non-negative integer")
    try:
        epoch = int(value)
    except (TypeError, ValueError) as error:
        raise SocialStoreError("social clock must be a non-negative integer") from error
    if epoch < 0 or str(value).strip() != str(epoch):
        raise SocialStoreError("social clock must be a non-negative integer")
    return epoch


def _validate_run_request(request: RunLeaseRequest) -> RunLeaseRequest:
    connection = validate_opaque(request.connection_id, "connection_id")
    collector = validate_opaque(request.collector_id, "collector_id")
    if (
        not isinstance(request.stream, str)
        or not request.stream
        or len(request.stream) > 127
    ):
        raise SocialStoreError("stream must be non-empty text")
    if request.run_kind not in RUN_KINDS:
        raise SocialStoreError("run_kind must be sync or reconcile")
    if (
        isinstance(request.lease_seconds, bool)
        or not isinstance(request.lease_seconds, int)
        or not 1 <= request.lease_seconds <= 86_400
    ):
        raise SocialStoreError("lease_seconds must be between 1 and 86400")
    return replace(request, connection_id=connection, collector_id=collector)


def _run_id(
    connection_id: str, stream: str, run_kind: str, fencing_token: int
) -> str:
    material = (
        f"social-run-v1\0{connection_id}\0{stream}\0{run_kind}\0{fencing_token}"
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _next_fencing_token(database: sqlite3.Connection, connection_id: str) -> int:
    row = database.execute(
        "SELECT last_token FROM collector_lease_generations WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    token = int(row["last_token"]) + 1 if row else 1
    database.execute(
        "INSERT INTO collector_lease_generations(connection_id,last_token) VALUES(?,?) "
        "ON CONFLICT(connection_id) DO UPDATE SET last_token=excluded.last_token",
        (connection_id, token),
    )
    return token


def _abandon_expired_run(
    database: sqlite3.Connection, row: sqlite3.Row, now_epoch: int
) -> None:
    database.execute(
        "UPDATE sync_runs SET status='abandoned',failure_class='lease_expired',"
        "completed_at=? WHERE run_id=? AND status='running'",
        (now_epoch, row["run_id"]),
    )


def _prepare_connection_lease(
    database: sqlite3.Connection, connection_id: str, now_epoch: int
) -> None:
    current = database.execute(
        "SELECT * FROM collector_leases WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if current is None:
        return
    if int(current["expires_at"]) > now_epoch:
        raise SocialLeaseBusyError("social connection already has a live collector")
    _abandon_expired_run(database, current, now_epoch)


def _upsert_collector_lease(
    database: sqlite3.Connection, lease: RunLease
) -> None:
    database.execute(
        """INSERT INTO collector_leases(
           connection_id,collector_id,fencing_token,run_id,acquired_at,expires_at)
           VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id) DO UPDATE SET
           collector_id=excluded.collector_id,
           fencing_token=excluded.fencing_token,run_id=excluded.run_id,
           acquired_at=excluded.acquired_at,expires_at=excluded.expires_at""",
        (
            lease.connection_id,
            lease.collector_id,
            lease.fencing_token,
            lease.run_id,
            lease.acquired_at,
            lease.expires_at,
        ),
    )


def _insert_running_receipt(
    database: sqlite3.Connection,
    lease: RunLease,
    request_hash: str | None,
) -> None:
    database.execute(
        """INSERT INTO sync_runs(
           run_id,connection_id,status,fencing_token,diagnostics,stream,run_kind,
           collector_id,started_at,request_hash) VALUES(?,?,?,?,?,?,?,?,?,?)""",
        (
            lease.run_id,
            lease.connection_id,
            "running",
            lease.fencing_token,
            json.dumps({"stream": lease.stream}, separators=(",", ":")),
            lease.stream,
            lease.run_kind,
            lease.collector_id,
            lease.acquired_at,
            request_hash,
        ),
    )


def _create_run_lease(
    database: sqlite3.Connection, request: RunLeaseRequest, now_epoch: int
) -> RunLease:
    _prepare_connection_lease(database, request.connection_id, now_epoch)
    token = _next_fencing_token(database, request.connection_id)
    lease = RunLease(
        request.connection_id,
        request.stream,
        request.run_kind,
        request.collector_id,
        token,
        _run_id(request.connection_id, request.stream, request.run_kind, token),
        now_epoch,
        now_epoch + request.lease_seconds,
    )
    _upsert_collector_lease(database, lease)
    _insert_running_receipt(database, lease, request.request_hash)
    return lease


def acquire_run_lease(
    root: Path,
    request: RunLeaseRequest,
    *,
    now_epoch: int | None = None,
) -> RunLease:
    """Elect one collector and create its running receipt atomically."""
    request = _validate_run_request(request)
    now = social_now(now_epoch)
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        lease = _create_run_lease(database, request, now)
        database.execute("COMMIT")
        return lease
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def assert_run_lease(
    database: sqlite3.Connection,
    lease: RunLease,
    *,
    now_epoch: int | None = None,
) -> None:
    """Fence a write against the current lease inside its transaction."""
    now = social_now(now_epoch)
    row = database.execute(
        "SELECT collector_id,fencing_token,run_id,acquired_at,expires_at "
        "FROM collector_leases WHERE connection_id=?",
        (lease.connection_id,),
    ).fetchone()
    if row is None:
        raise SocialLeaseLostError("social collector lease is stale or expired")
    stored_identity = (
        row["collector_id"],
        int(row["fencing_token"]),
        row["run_id"],
    )
    expected_identity = (lease.collector_id, lease.fencing_token, lease.run_id)
    if stored_identity != expected_identity:
        raise SocialLeaseLostError("social collector lease is stale or expired")
    if int(row["acquired_at"]) > now or now >= int(row["expires_at"]):
        raise SocialLeaseLostError("social collector lease is stale or expired")


def renew_run_lease(
    root: Path,
    lease: RunLease,
    lease_seconds: int,
    *,
    now_epoch: int | None = None,
) -> RunLease:
    """Renew only the exact live lease; stale generations cannot revive."""
    _validate_run_request(
        RunLeaseRequest(
            lease.connection_id,
            lease.stream,
            lease.collector_id,
            lease.run_kind,
            lease_seconds,
        )
    )
    now = social_now(now_epoch)
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        assert_run_lease(database, lease, now_epoch=now)
        expires_at = now + lease_seconds
        database.execute(
            "UPDATE collector_leases SET expires_at=? WHERE connection_id=? "
            "AND collector_id=? AND fencing_token=? AND run_id=?",
            (
                expires_at,
                lease.connection_id,
                lease.collector_id,
                lease.fencing_token,
                lease.run_id,
            ),
        )
        database.execute("COMMIT")
        return replace(lease, expires_at=expires_at)
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def update_run_receipt(
    database: sqlite3.Connection,
    lease: RunLease,
    update: RunReceiptUpdate,
    *,
    now_epoch: int | None = None,
) -> None:
    """Update the receipt in the caller's content/cursor transaction."""
    if update.resource_delta < 0:
        raise SocialStoreError("receipt resource delta cannot be negative")
    if update.terminal and update.status not in TERMINAL_RUN_STATES:
        raise SocialStoreError("terminal receipt has an invalid status")
    now = social_now(now_epoch)
    assert_run_lease(database, lease, now_epoch=now)
    updated = database.execute(
        "UPDATE sync_runs SET status=?,resource_count=resource_count+?,"
        "failure_class=?,retry_after=?,completed_at=? WHERE run_id=? "
        "AND collector_id=? AND fencing_token=?",
        (
            update.status,
            update.resource_delta,
            update.failure_class,
            update.retry_after,
            now if update.terminal else None,
            lease.run_id,
            lease.collector_id,
            lease.fencing_token,
        ),
    ).rowcount
    if updated != 1:
        raise SocialLeaseLostError("social run receipt is missing or stale")


def finish_active_run(
    root: Path,
    lease: RunLease,
    update: RunReceiptUpdate,
    *,
    now_epoch: int | None = None,
) -> None:
    """Finish a run without binding or persisting unverified provider data."""
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        update_run_receipt(
            database,
            lease,
            replace(update, terminal=True),
            now_epoch=now_epoch,
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def fail_active_run(
    root: Path,
    lease: RunLease,
    failure_class: str,
    *,
    now_epoch: int | None = None,
) -> None:
    """Record a privacy-safe failure while the caller owns the lease."""
    finish_active_run(
        root,
        lease,
        RunReceiptUpdate("failed", failure_class=failure_class),
        now_epoch=now_epoch,
    )


def release_run_lease(root: Path, lease: RunLease) -> bool:
    """Release only the exact generation, never a successor's lease."""
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        removed = database.execute(
            "DELETE FROM collector_leases WHERE connection_id=? AND collector_id=? "
            "AND fencing_token=? AND run_id=?",
            (
                lease.connection_id,
                lease.collector_id,
                lease.fencing_token,
                lease.run_id,
            ),
        ).rowcount
        database.execute("COMMIT")
        return removed == 1
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
