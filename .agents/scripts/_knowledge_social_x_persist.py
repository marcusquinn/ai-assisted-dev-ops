#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic raw evidence, normalized rows, coverage, and cursor persistence."""

from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    assert_run_lease,
    social_now,
    update_run_receipt,
)
from _knowledge_social_x import PROVIDER, PageCheckpoint, XAdapterError
from _knowledge_social_x_normalize import observation_time, page_time_bounds
from _knowledge_social_x_state import CollectionContext
from knowledge_social_import import (
    canonical_json,
    import_accounts,
    import_activities,
    import_media,
    import_objects,
    reject_credentials,
    upsert_connection,
)
from knowledge_social_store import connect, migrate, write_raw_batch


@dataclass(frozen=True)
class SuccessfulPage:
    """Validated page plus its next durable checkpoint."""

    payload: dict[str, Any]
    endpoint: str
    archive: dict[str, Any]
    checkpoint: PageCheckpoint
    complete: bool
    budget_units: int


@dataclass(frozen=True)
class RawBatch:
    """Immutable response-envelope metadata used by fetch_batches."""

    batch_id: str
    blob_ref: str
    request_hash: str
    observed_at: str


@dataclass(frozen=True)
class FetchRecord:
    """Fetch-batch values independent of success or failure handling."""

    raw: RawBatch
    terminal_status: str
    resource_count: int
    budget_units: int


@dataclass(frozen=True)
class TerminalDecision:
    """Sanitized handling policy for one terminal provider response."""

    output_status: str
    run_status: str
    failure_class: str


def _run_lease(context: CollectionContext) -> RunLease:
    if context.lease is None:
        raise XAdapterError("X persistence requires a collector lease")
    return context.lease


def _assert_connection_binding(
    database: sqlite3.Connection, context: CollectionContext
) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (context.connection_id,),
    ).fetchone()
    if row and (
        row["provider"] != PROVIDER
        or row["remote_account_id"] != context.account["id"]
    ):
        raise XAdapterError("stored connection does not match the verified X account")


def _connection_archive(context: CollectionContext) -> dict[str, Any]:
    return {
        "remote_account_id": context.account["id"],
        "enabled_streams": list(context.config.enabled_streams),
        "policy": context.config.policy,
    }


def _raw_batch(
    context: CollectionContext,
    payload: dict[str, Any],
    endpoint: str,
    observed_at: str,
) -> RawBatch:
    response = canonical_json(payload).encode("utf-8")
    request_hash = hashlib.sha256(endpoint.encode("utf-8")).hexdigest()
    envelope = canonical_json(
        {
            "provider": PROVIDER,
            "connection_id": context.connection_id,
            "stream": context.stream,
            "observed_at": observed_at,
            "request_hash": request_hash,
            "response_sha256": hashlib.sha256(response).hexdigest(),
            "response": payload,
        }
    ).encode("utf-8")
    batch_id, blob_ref = write_raw_batch(
        context.root, PROVIDER, context.connection_id, envelope
    )
    return RawBatch(batch_id, blob_ref, request_hash, observed_at)


def _insert_fetch_batch(
    database: sqlite3.Connection,
    context: CollectionContext,
    record: FetchRecord,
) -> None:
    database.execute(
        """INSERT INTO fetch_batches(
           batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
           resource_count,budget_units,started_at,completed_at,terminal_status)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(batch_id) DO NOTHING""",
        (
            record.raw.batch_id,
            PROVIDER,
            context.connection_id,
            context.stream,
            record.raw.request_hash,
            record.raw.batch_id,
            record.raw.blob_ref,
            record.resource_count,
            record.budget_units,
            record.raw.observed_at,
            record.raw.observed_at,
            record.terminal_status,
        ),
    )


def _refresh_fts(database: sqlite3.Connection, archive: dict[str, Any]) -> None:
    for record in archive["objects"]:
        identity = (PROVIDER, record["object_type"], record["remote_id"])
        database.execute(
            "DELETE FROM objects_fts WHERE provider=? AND object_type=? AND remote_id=?",
            identity,
        )
        database.execute(
            """INSERT INTO objects_fts(
               provider,object_type,remote_id,account_remote_id,text_content,evidence_class)
               SELECT provider,object_type,remote_id,account_remote_id,text_content,evidence_class
                 FROM objects WHERE provider=? AND object_type=? AND remote_id=?""",
            identity,
        )


def _update_cursor(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
) -> None:
    database.execute(
        """INSERT INTO sync_cursors(
           connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
           VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
           cursor=excluded.cursor,watermark=excluded.watermark,
           last_success_at=excluded.last_success_at,
           backfill_complete=excluded.backfill_complete""",
        (
            context.connection_id,
            context.stream,
            page.checkpoint.next_cursor,
            page.checkpoint.watermark,
            page.archive["exported_at"],
            int(page.complete),
        ),
    )


def _upsert_success_coverage(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
    batch_id: str,
) -> None:
    earliest, latest = page_time_bounds(page.archive)
    database.execute(
        """INSERT INTO coverage_records(
           provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
           retention_limit,unavailable_reason,status,batch_id,observed_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream) DO UPDATE SET
           earliest_at=CASE
             WHEN coverage_records.earliest_at IS NULL THEN excluded.earliest_at
             WHEN excluded.earliest_at IS NULL THEN coverage_records.earliest_at
             WHEN excluded.earliest_at < coverage_records.earliest_at THEN excluded.earliest_at
             ELSE coverage_records.earliest_at END,
           latest_at=CASE
             WHEN coverage_records.latest_at IS NULL THEN excluded.latest_at
             WHEN excluded.latest_at IS NULL THEN coverage_records.latest_at
             WHEN excluded.latest_at > coverage_records.latest_at THEN excluded.latest_at
             ELSE coverage_records.latest_at END,
           cursor_exhausted=excluded.cursor_exhausted,
           unavailable_reason=NULL,status=excluded.status,
           batch_id=excluded.batch_id,observed_at=excluded.observed_at""",
        (
            PROVIDER,
            context.connection_id,
            context.stream,
            earliest,
            latest,
            int(page.complete),
            None,
            None,
            "complete" if page.complete else "partial",
            batch_id,
            page.archive["exported_at"],
        ),
    )


def persist_page(context: CollectionContext, page: SuccessfulPage) -> int:
    """Atomically commit normalized rows, projection, coverage, and cursor."""
    database = connect(context.root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        lease = _run_lease(context)
        now = social_now()
        assert_run_lease(database, lease, now_epoch=now)
        _assert_connection_binding(database, context)
        raw = _raw_batch(
            context, page.payload, page.endpoint, page.archive["exported_at"]
        )
        upsert_connection(database, page.archive, PROVIDER, context.connection_id)
        import_accounts(database, page.archive, PROVIDER)
        import_objects(database, page.archive, PROVIDER, raw.batch_id)
        import_activities(database, page.archive, PROVIDER, raw.batch_id)
        import_media(database, page.archive, PROVIDER, raw.batch_id)
        _refresh_fts(database, page.archive)
        resource_count = sum(
            len(page.archive[key])
            for key in ("accounts", "objects", "activities", "media")
        )
        _insert_fetch_batch(
            database,
            context,
            FetchRecord(raw, "success", resource_count, page.budget_units),
        )
        _update_cursor(database, context, page)
        _upsert_success_coverage(database, context, page, raw.batch_id)
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(
                "complete" if page.complete else "running",
                resource_delta=resource_count,
                terminal=page.complete,
            ),
            now_epoch=now,
        )
        database.execute("COMMIT")
        return resource_count
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def _retry_after(payload: dict[str, Any]) -> str | None:
    value = payload.get("retry_after")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise XAdapterError("X retry_after must be text or an integer")
    return str(value)


def _terminal_coverage_status(decision: TerminalDecision) -> str:
    if decision.failure_class == "rate_limit":
        return "paused"
    if decision.failure_class == "unavailable":
        return "unavailable"
    return "failed"


def _upsert_terminal_coverage(
    database: sqlite3.Connection,
    context: CollectionContext,
    raw: RawBatch,
    decision: TerminalDecision,
) -> None:
    database.execute(
        """INSERT INTO coverage_records(
           provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
           retention_limit,unavailable_reason,status,batch_id,observed_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream) DO UPDATE SET
           unavailable_reason=excluded.unavailable_reason,status=excluded.status,
           batch_id=excluded.batch_id,observed_at=excluded.observed_at""",
        (
            PROVIDER,
            context.connection_id,
            context.stream,
            None,
            None,
            int(context.state.backfill_complete),
            None,
            decision.failure_class,
            _terminal_coverage_status(decision),
            raw.batch_id,
            raw.observed_at,
        ),
    )


def record_terminal(
    context: CollectionContext,
    payload: dict[str, Any],
    endpoint: str,
    decision: TerminalDecision,
) -> str | None:
    """Persist a credential-filtered terminal response without cursor advance."""
    reject_credentials(payload)
    observed_at = observation_time(payload)
    retry_after = _retry_after(payload)
    database = connect(context.root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        lease = _run_lease(context)
        now = social_now()
        assert_run_lease(database, lease, now_epoch=now)
        _assert_connection_binding(database, context)
        raw = _raw_batch(context, payload, endpoint, observed_at)
        upsert_connection(
            database,
            _connection_archive(context),
            PROVIDER,
            context.connection_id,
        )
        _insert_fetch_batch(
            database,
            context,
            FetchRecord(raw, decision.failure_class, 0, context.spec.cost_units),
        )
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(
                decision.run_status,
                failure_class=decision.failure_class,
                retry_after=retry_after,
                terminal=True,
            ),
            now_epoch=now,
        )
        _upsert_terminal_coverage(database, context, raw, decision)
        database.execute("COMMIT")
        return retry_after
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def record_bounded_stop(
    context: CollectionContext, status: str, failure: str
) -> None:
    """Record a budget or capability stop while preserving prior evidence."""
    now = social_now()
    observed_at = datetime.fromtimestamp(now, UTC).isoformat().replace("+00:00", "Z")
    database = connect(context.root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        lease = _run_lease(context)
        assert_run_lease(database, lease, now_epoch=now)
        _assert_connection_binding(database, context)
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(status, failure_class=failure, terminal=True),
            now_epoch=now,
        )
        updated = database.execute(
            "UPDATE coverage_records SET status=?,unavailable_reason=?,observed_at=? "
            "WHERE provider=? AND connection_id=? AND stream=?",
            (
                status,
                failure,
                observed_at,
                PROVIDER,
                context.connection_id,
                context.stream,
            ),
        ).rowcount
        if updated != 1:
            raise XAdapterError("X stop has no durable coverage checkpoint")
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
