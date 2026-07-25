#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Complete-snapshot reconciliation for an authorized social corpus."""

from __future__ import annotations

import argparse
import json
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from _knowledge_social_sync_state import (
    LeaseRequest,
    RunFinish,
    RunStart,
    SyncError,
    acquire_lease,
    begin_run,
    finish_run,
    now_for_args,
    parse_time,
    release_lease,
    utc_text,
)
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import validate_opaque, write_raw_batch


@dataclass(frozen=True)
class Snapshot:
    """Validated complete provider snapshot."""

    provider: str
    observed_at: str
    object_type: str
    remote_ids: tuple[str, ...]
    payload: dict[str, Any]


@dataclass(frozen=True)
class ReconcileContext:
    """Stable identifiers shared by reconciliation writes."""

    connection_id: str
    stream: str
    snapshot: Snapshot


def read_snapshot(path: Path) -> Snapshot:
    """Read a complete private provider reconciliation snapshot."""
    try:
        validate_private_file(path, "reconciliation snapshot", repair=False)
    except CatalogError as error:
        raise SyncError(str(error)) from error
    payload = json.loads(path.read_text(encoding="utf-8"))
    reject_credentials(payload)
    if not isinstance(payload, dict) or payload.get("complete") is not True:
        raise SyncError("reconciliation requires an explicitly complete snapshot")
    provider = payload.get("provider")
    observed_at = payload.get("observed_at")
    object_type = payload.get("object_type", "post")
    remote_ids = payload.get("remote_ids")
    if not all(isinstance(value, str) for value in (provider, observed_at, object_type)):
        raise SyncError("snapshot metadata must be text")
    parse_time(observed_at)
    if not isinstance(remote_ids, list) or any(not isinstance(item, str) for item in remote_ids):
        raise SyncError("snapshot remote_ids must be an array of text")
    return Snapshot(provider, observed_at, object_type, tuple(sorted(set(remote_ids))), payload)


def _known_ids(
    database: sqlite3.Connection, connection_id: str, stream: str, snapshot: Snapshot
) -> set[str]:
    rows = database.execute(
        """SELECT DISTINCT o.remote_id FROM objects o
           JOIN fetch_batches b ON b.batch_id=o.batch_id
           WHERE b.connection_id=? AND b.stream=? AND o.provider=?
             AND o.object_type=?""",
        (connection_id, stream, snapshot.provider, snapshot.object_type),
    )
    return {str(row[0]) for row in rows}


def _write_snapshot_batch(
    database: sqlite3.Connection,
    root: Path,
    context: ReconcileContext,
) -> None:
    snapshot = context.snapshot
    evidence = canonical_json(
        {
            "provider": snapshot.provider,
            "connection_id": context.connection_id,
            "stream": context.stream,
            "observed_at": snapshot.observed_at,
            "snapshot": snapshot.payload,
        }
    ).encode("utf-8")
    batch_id, blob_ref = write_raw_batch(
        root, snapshot.provider, context.connection_id, evidence
    )
    database.execute(
        """INSERT INTO fetch_batches(
           batch_id,provider,connection_id,stream,response_hash,blob_ref,
           resource_count,budget_units,started_at,completed_at,terminal_status)
           VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(batch_id) DO NOTHING""",
        (
            batch_id,
            snapshot.provider,
            context.connection_id,
            context.stream,
            batch_id,
            blob_ref,
            len(snapshot.remote_ids),
            0,
            snapshot.observed_at,
            snapshot.observed_at,
            "reconciliation",
        ),
    )


def _write_observations(
    database: sqlite3.Connection,
    context: ReconcileContext,
    known: set[str],
    run_id: str,
) -> tuple[int, int]:
    snapshot = context.snapshot
    present = known.intersection(snapshot.remote_ids)
    for remote_id in sorted(known):
        database.execute(
            """INSERT INTO reconciliation_observations(
               provider,connection_id,stream,object_type,remote_id,state,observed_at,run_id)
               VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(
               provider,connection_id,stream,object_type,remote_id) DO UPDATE SET
               state=excluded.state,observed_at=excluded.observed_at,run_id=excluded.run_id""",
            (
                snapshot.provider,
                context.connection_id,
                context.stream,
                snapshot.object_type,
                remote_id,
                "present" if remote_id in present else "missing",
                snapshot.observed_at,
                run_id,
            ),
        )
    return len(present), len(known.difference(snapshot.remote_ids))


def command_reconcile(
    args: argparse.Namespace, root: Path, database: sqlite3.Connection
) -> dict[str, Any]:
    """Mark provider-confirmed presence or absence without destructive purge."""
    snapshot = read_snapshot(args.snapshot)
    connection_id = validate_opaque(args.connection_id, "connection_id")
    context = ReconcileContext(connection_id, args.stream, snapshot)
    lease = LeaseRequest(
        connection_id, args.collector_id, now_for_args(args), args.lease_seconds
    )
    token = acquire_lease(database, lease)
    if token is None:
        return {"status": "lease_held", "present": 0, "missing": 0}
    run_id = begin_run(
        database,
        RunStart(connection_id, args.stream, "reconcile", token, snapshot.observed_at),
    )
    try:
        known = _known_ids(database, connection_id, args.stream, snapshot)
        database.execute("BEGIN IMMEDIATE")
        _write_snapshot_batch(database, root, context)
        present, missing = _write_observations(database, context, known, run_id)
        finish_run(
            database,
            RunFinish(
                run_id,
                "complete",
                snapshot.observed_at,
                len(known),
                diagnostics={"missing": missing, "present": present, "stream": args.stream},
            ),
        )
        database.execute("COMMIT")
        return {"status": "complete", "present": present, "missing": missing}
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        finish_run(
            database,
            RunFinish(
                run_id,
                "failed",
                utc_text(datetime.now(UTC)),
                failure_class="reconciliation",
                diagnostics={"stream": args.stream},
            ),
        )
        raise
    finally:
        release_lease(database, connection_id, args.collector_id, token)
