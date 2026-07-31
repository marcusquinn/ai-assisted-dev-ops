#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced missing-first reconciliation for social corpus snapshots."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import stat
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    _assert_run_lease_at,
    _update_run_receipt_at,
    social_now,
)
from knowledge_social_import import canonical_json, reject_credentials, required_text
from knowledge_social_store import SocialStoreError, connect, migrate, write_raw_batch


@dataclass(frozen=True)
class ReconciliationSnapshot:
    """Validated complete or partial provider reconciliation evidence."""

    provider: str
    observed_at: str
    complete: bool
    objects: frozenset[tuple[str, str]]
    activities: frozenset[tuple[str, str]]
    payload: bytes
    request_hash: str
    observed_epoch: float


def _records(
    payload: dict[str, Any], key: str, type_key: str
) -> frozenset[tuple[str, str]]:
    value = payload.get(key, [])
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise SocialStoreError(f"reconciliation {key} must be an array of objects")
    records = {
        (required_text(record, type_key), required_text(record, "remote_id"))
        for record in value
    }
    if len(records) != len(value):
        raise SocialStoreError(f"reconciliation {key} contains duplicate identities")
    return frozenset(records)


def _snapshot_stat(path: Path) -> os.stat_result:
    try:
        before = path.lstat()
    except OSError as error:
        raise SocialStoreError("reconciliation snapshot is unavailable") from error
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise SocialStoreError("reconciliation snapshot must be a regular file")
    if hasattr(os, "getuid") and before.st_uid != os.getuid():
        raise SocialStoreError("reconciliation snapshot owner must be the current user")
    if stat.S_IMODE(before.st_mode) != 0o600:
        raise SocialStoreError("reconciliation snapshot permissions must be 0600")
    return before


def _open_snapshot(path: Path) -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        return os.open(path, flags)
    except OSError as error:
        raise SocialStoreError("reconciliation snapshot replacement detected") from error


def _load_snapshot_json(
    descriptor: int, before: os.stat_result
) -> dict[str, Any]:
    try:
        with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
            after = os.fstat(handle.fileno())
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                raise SocialStoreError("reconciliation snapshot replacement detected")
            parsed = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("reconciliation snapshot is not valid UTF-8 JSON") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError("reconciliation snapshot root must be an object")
    return parsed


def _read_private_snapshot(path: Path) -> dict[str, Any]:
    before = _snapshot_stat(path)
    return _load_snapshot_json(_open_snapshot(path), before)


def _observed_epoch(value: str) -> float:
    try:
        observed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SocialStoreError("reconciliation observed_at is invalid") from error
    if observed.tzinfo is None:
        raise SocialStoreError("reconciliation observed_at requires a timezone")
    return observed.timestamp()


def load_reconciliation_snapshot(path: Path) -> ReconciliationSnapshot:
    """Read private evidence and reject credential-shaped material."""
    parsed = _read_private_snapshot(path)
    reject_credentials(parsed)
    complete = parsed.get("complete")
    if not isinstance(complete, bool):
        raise SocialStoreError("reconciliation complete must be boolean")
    observed_at = required_text(parsed, "observed_at")
    payload = canonical_json(parsed).encode("utf-8")
    return ReconciliationSnapshot(
        required_text(parsed, "provider"),
        observed_at,
        complete,
        _records(parsed, "objects", "object_type"),
        _records(parsed, "activities", "activity_type"),
        payload,
        hashlib.sha256(payload).hexdigest(),
        _observed_epoch(observed_at),
    )


def _connection_provider(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> str:
    row = database.execute(
        "SELECT provider,enabled_streams FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        raise SocialStoreError("reconciliation connection is not configured")
    try:
        streams = json.loads(row["enabled_streams"])
    except json.JSONDecodeError as error:
        raise SocialStoreError("stored social streams are invalid") from error
    if not isinstance(streams, list) or stream not in streams:
        raise SocialStoreError("reconciliation stream is not enabled")
    return str(row["provider"])


def _validate_snapshot_order(
    database: sqlite3.Connection,
    lease: RunLease,
    snapshot: ReconciliationSnapshot,
) -> None:
    rows = database.execute(
        "SELECT completed_at,request_hash FROM fetch_batches WHERE connection_id=? "
        "AND stream=? AND terminal_status='reconciliation'",
        (lease.connection_id, f"reconcile:{lease.stream}"),
    ).fetchall()
    for row in rows:
        previous_epoch = _observed_epoch(str(row["completed_at"]))
        if previous_epoch > snapshot.observed_epoch:
            raise SocialStoreError("reconciliation snapshot is older than stored evidence")
        if (
            previous_epoch == snapshot.observed_epoch
            and row["request_hash"] != snapshot.request_hash
        ):
            raise SocialStoreError("reconciliation snapshot conflicts at observed_at")


def _inventory(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> set[tuple[str, str, str]]:
    inventory = {
        ("object", str(row["object_type"]), str(row["remote_id"]))
        for row in database.execute(
            """SELECT o.object_type,o.remote_id FROM objects o
               JOIN fetch_batches b ON b.batch_id=o.batch_id
               WHERE b.connection_id=? AND b.stream=? UNION
               SELECT o.object_type,o.remote_id FROM objects o
               JOIN activities a ON a.provider=o.provider
                 AND a.object_remote_id=o.remote_id
               JOIN fetch_batches b ON b.batch_id=a.batch_id
               WHERE b.connection_id=? AND b.stream=?""",
            (connection_id, stream, connection_id, stream),
        ).fetchall()
    }
    inventory.update(
        {
            ("activity", str(row["activity_type"]), str(row["remote_id"]))
            for row in database.execute(
                """SELECT DISTINCT a.activity_type,a.remote_id FROM activities a
                   JOIN fetch_batches b ON b.batch_id=a.batch_id
                   WHERE b.connection_id=? AND b.stream=?""",
                (connection_id, stream),
            ).fetchall()
        }
    )
    return inventory


def _previous_missing_at(
    database: sqlite3.Connection,
    provider: str,
    lease: RunLease,
    item: tuple[str, str, str],
) -> str | None:
    row = database.execute(
        "SELECT first_missing_at FROM reconciliation_items WHERE provider=? "
        "AND connection_id=? AND stream=? AND item_kind=? AND item_type=? "
        "AND remote_id=?",
        (provider, lease.connection_id, lease.stream, *item),
    ).fetchone()
    if row and row["first_missing_at"]:
        return str(row["first_missing_at"])
    return None


def _upsert_state(
    database: sqlite3.Connection,
    lease: RunLease,
    snapshot: ReconciliationSnapshot,
    item: tuple[str, str, str],
    status: str,
) -> None:
    first_missing = None
    if status == "missing":
        first_missing = _previous_missing_at(
            database, snapshot.provider, lease, item
        )
        first_missing = first_missing or snapshot.observed_at
    database.execute(
        "INSERT INTO reconciliation_items(provider,connection_id,stream,item_kind,"
        "item_type,remote_id,status,first_missing_at,last_observed_at,run_id) "
        "VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream,"
        "item_kind,item_type,remote_id) DO UPDATE SET status=excluded.status,"
        "first_missing_at=excluded.first_missing_at,"
        "last_observed_at=excluded.last_observed_at,run_id=excluded.run_id",
        (
            snapshot.provider,
            lease.connection_id,
            lease.stream,
            *item,
            status,
            first_missing,
            snapshot.observed_at,
            lease.run_id,
        ),
    )
    if item[0] == "activity":
        database.execute(
            "UPDATE activities SET state=?,observed_at=? WHERE provider=? "
            "AND activity_type=? AND remote_id=?",
            (
                "active" if status == "present" else "missing",
                snapshot.observed_at,
                snapshot.provider,
                item[1],
                item[2],
            ),
        )


def _evidence_payload(
    lease: RunLease, snapshot: ReconciliationSnapshot
) -> bytes:
    return canonical_json(
        {
            "provider": snapshot.provider,
            "connection_id": lease.connection_id,
            "stream": lease.stream,
            "snapshot": json.loads(snapshot.payload),
        }
    ).encode("utf-8")


def _insert_evidence_batch(
    database: sqlite3.Connection,
    root: Path,
    lease: RunLease,
    snapshot: ReconciliationSnapshot,
) -> None:
    batch_id, blob_ref = write_raw_batch(
        root,
        snapshot.provider,
        lease.connection_id,
        _evidence_payload(lease, snapshot),
    )
    database.execute(
        "INSERT INTO fetch_batches(batch_id,provider,connection_id,stream,"
        "request_hash,response_hash,blob_ref,resource_count,budget_units,"
        "started_at,completed_at,terminal_status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
        "ON CONFLICT(batch_id) DO NOTHING",
        (
            batch_id,
            snapshot.provider,
            lease.connection_id,
            f"reconcile:{lease.stream}",
            snapshot.request_hash,
            batch_id,
            blob_ref,
            len(snapshot.objects) + len(snapshot.activities),
            0,
            snapshot.observed_at,
            snapshot.observed_at,
            "reconciliation",
        ),
    )


def _present_items(
    snapshot: ReconciliationSnapshot,
) -> set[tuple[str, str, str]]:
    present = {
        ("object", item_type, remote_id)
        for item_type, remote_id in snapshot.objects
    }
    present.update(
        {
            ("activity", item_type, remote_id)
            for item_type, remote_id in snapshot.activities
        }
    )
    return present


def _apply_states(
    database: sqlite3.Connection,
    lease: RunLease,
    snapshot: ReconciliationSnapshot,
    inventory: set[tuple[str, str, str]],
) -> tuple[int, int, int]:
    present = _present_items(snapshot)
    present_count = 0
    missing_count = 0
    for item in sorted(inventory):
        if item in present:
            _upsert_state(database, lease, snapshot, item, "present")
            present_count += 1
        elif snapshot.complete:
            _upsert_state(database, lease, snapshot, item, "missing")
            missing_count += 1
    return present_count, missing_count, len(present - inventory)


def reconcile_snapshot(
    root: Path,
    lease: RunLease,
    snapshot: ReconciliationSnapshot,
    *,
    now_epoch: int | None = None,
) -> dict[str, Any]:
    """Commit missing-first state and its receipt under one fence."""
    now = social_now(now_epoch)
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        _assert_run_lease_at(database, lease, now)
        provider = _connection_provider(
            database, lease.connection_id, lease.stream
        )
        if provider != snapshot.provider:
            raise SocialStoreError("reconciliation provider does not match connection")
        _validate_snapshot_order(database, lease, snapshot)
        _insert_evidence_batch(database, root, lease, snapshot)
        inventory = _inventory(database, lease.connection_id, lease.stream)
        present_count, missing_count, unknown_count = _apply_states(
            database, lease, snapshot, inventory
        )
        _update_run_receipt_at(
            database,
            lease,
            RunReceiptUpdate(
                "complete", resource_delta=len(inventory), terminal=True
            ),
            social_now(now_epoch),
        )
        database.execute("COMMIT")
        return {
            "status": "complete",
            "run_id": lease.run_id,
            "present": present_count,
            "missing": missing_count,
            "unknown": unknown_count,
            "complete_snapshot": snapshot.complete,
        }
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
