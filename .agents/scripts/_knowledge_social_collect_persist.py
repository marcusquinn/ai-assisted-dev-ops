#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic provider-neutral social page and checkpoint persistence."""

from __future__ import annotations

import hashlib
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_collect import (
    CollectionContext,
    CollectionProgress,
    SuccessfulPage,
    TerminalDecision,
    collection_result,
)
from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    _assert_run_lease_at,
    _update_run_receipt_at,
    social_now,
)
from knowledge_social_import import (
    canonical_json,
    import_accounts,
    import_activities,
    import_coverage,
    import_media,
    import_objects,
    reject_credentials,
    upsert_connection,
)
from knowledge_social_store import (
    RawEvidenceTransaction,
    SocialStoreError,
    connect,
    migrate,
    raw_evidence_transaction,
)


@dataclass(frozen=True)
class RawBatch:
    """Immutable response-envelope metadata used by fetch_batches."""

    batch_id: str
    blob_ref: str
    request_hash: str
    response_hash: str
    observed_at: str


@dataclass(frozen=True)
class FetchRecord:
    """Fetch-batch values independent of success or failure handling."""

    raw: RawBatch
    terminal_status: str
    resource_count: int
    budget_units: int


def _provider(context: CollectionContext) -> str:
    if not context.provider:
        raise SocialStoreError("social collection context has no provider")
    return context.provider


def _run_lease(context: CollectionContext) -> RunLease:
    if context.lease is None:
        raise SocialStoreError("social persistence requires a collector lease")
    return context.lease


def _assert_connection_binding(
    database: sqlite3.Connection, context: CollectionContext
) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (context.connection_id,),
    ).fetchone()
    if row and (
        row["provider"] != _provider(context)
        or row["remote_account_id"] != context.account["id"]
    ):
        raise SocialStoreError(
            "stored connection does not match the verified social account"
        )


def _connection_archive(context: CollectionContext) -> dict[str, Any]:
    return {
        "remote_account_id": context.account["id"],
        "enabled_streams": list(context.config.enabled_streams),
        "policy": context.config.policy,
    }


def _raw_batch(
    transaction: RawEvidenceTransaction,
    context: CollectionContext,
    payload: dict[str, Any],
    request: str,
    observed_at: str,
) -> RawBatch:
    provider = _provider(context)
    response = canonical_json(payload).encode("utf-8")
    request_hash = hashlib.sha256(request.encode("utf-8")).hexdigest()
    response_hash = hashlib.sha256(response).hexdigest()
    envelope = canonical_json(
        {
            "provider": provider,
            "connection_id": context.connection_id,
            "stream": context.stream,
            "observed_at": observed_at,
            "request_hash": request_hash,
            "response_sha256": response_hash,
            "response": payload,
        }
    ).encode("utf-8")
    batch_id, blob_ref = transaction.write(provider, context.connection_id, envelope)
    return RawBatch(
        batch_id,
        blob_ref,
        request_hash,
        response_hash,
        observed_at,
    )


def _insert_fetch_batch(
    database: sqlite3.Connection,
    context: CollectionContext,
    record: FetchRecord,
) -> str:
    existing = database.execute(
        "SELECT batch_id,provider,connection_id,stream,request_hash,response_hash,"
        "blob_ref,resource_count,budget_units,started_at,completed_at,terminal_status "
        "FROM fetch_batches WHERE batch_id=?",
        (record.raw.batch_id,),
    ).fetchone()
    if existing is not None:
        identity = (
            _provider(context),
            context.connection_id,
            context.stream,
            record.raw.request_hash,
            record.raw.response_hash,
            record.raw.blob_ref,
            record.raw.observed_at,
            record.raw.observed_at,
        )
        stored_identity = tuple(
            existing[key]
            for key in (
                "provider",
                "connection_id",
                "stream",
                "request_hash",
                "response_hash",
                "blob_ref",
                "started_at",
                "completed_at",
            )
        )
        if stored_identity != identity:
            raise SocialStoreError("social fetch replay metadata conflicts")
        if existing["terminal_status"] == "legacy_recovered":
            database.execute(
                "UPDATE fetch_batches SET resource_count=?,budget_units=?,"
                "terminal_status=? WHERE batch_id=?",
                (
                    record.resource_count,
                    record.budget_units,
                    record.terminal_status,
                    record.raw.batch_id,
                ),
            )
            return record.raw.batch_id
        stored_result = (
            existing["resource_count"],
            existing["budget_units"],
            existing["terminal_status"],
        )
        expected_result = (
            record.resource_count,
            record.budget_units,
            record.terminal_status,
        )
        if stored_result != expected_result:
            raise SocialStoreError("social fetch replay result metadata conflicts")
        return str(existing["batch_id"])
    database.execute(
        """INSERT INTO fetch_batches(
           batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
           resource_count,budget_units,started_at,completed_at,terminal_status)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            record.raw.batch_id,
            _provider(context),
            context.connection_id,
            context.stream,
            record.raw.request_hash,
            record.raw.response_hash,
            record.raw.blob_ref,
            record.resource_count,
            record.budget_units,
            record.raw.observed_at,
            record.raw.observed_at,
            record.terminal_status,
        ),
    )
    return record.raw.batch_id


def _refresh_fts(
    database: sqlite3.Connection,
    provider: str,
    archive: dict[str, Any],
) -> None:
    for record in archive["objects"]:
        identity = (provider, record["object_type"], record["remote_id"])
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
           backfill_complete=MAX(
             sync_cursors.backfill_complete,excluded.backfill_complete)""",
        (
            context.connection_id,
            context.stream,
            page.checkpoint.next_cursor,
            page.checkpoint.watermark,
            page.archive["exported_at"],
            int(page.complete),
        ),
    )


def _page_time_bounds(archive: dict[str, Any]) -> tuple[str | None, str | None]:
    sources = (
        (archive["objects"], "created_at"),
        (archive["activities"], "occurred_at"),
    )
    timestamps = [
        value
        for rows, key in sources
        for record in rows
        if isinstance((value := record.get(key)), str) and value
    ]
    if not timestamps:
        return None, None
    return min(timestamps), max(timestamps)


def _upsert_success_coverage(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
    batch_id: str,
) -> None:
    earliest, latest = _page_time_bounds(page.archive)
    status = page.coverage_status or ("complete" if page.complete else "partial")
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
           retention_limit=excluded.retention_limit,
           unavailable_reason=excluded.unavailable_reason,status=excluded.status,
           batch_id=excluded.batch_id,observed_at=excluded.observed_at""",
        (
            _provider(context),
            context.connection_id,
            context.stream,
            earliest,
            latest,
            int(page.complete),
            page.retention_limit,
            page.unavailable_reason,
            status,
            batch_id,
            page.archive["exported_at"],
        ),
    )


def persist_page(context: CollectionContext, page: SuccessfulPage) -> int:
    """Atomically commit normalized rows, projection, coverage, and cursor."""
    provider = _provider(context)
    database = connect(context.root)
    try:
        migrate(database)
        with raw_evidence_transaction(database, context.root) as transaction:
            lease = _run_lease(context)
            _assert_run_lease_at(database, lease, social_now())
            _assert_connection_binding(database, context)
            raw = _raw_batch(
                transaction,
                context,
                page.payload,
                page.request,
                page.archive["exported_at"],
            )
            resource_count = sum(
                len(page.archive[key])
                for key in ("accounts", "objects", "activities", "media")
            )
            fetch_batch_id = _insert_fetch_batch(
                database,
                context,
                FetchRecord(raw, "success", resource_count, page.budget_units),
            )
            upsert_connection(
                database, page.archive, provider, context.connection_id
            )
            import_accounts(database, page.archive, provider)
            import_objects(database, page.archive, provider, fetch_batch_id)
            import_activities(database, page.archive, provider, fetch_batch_id)
            import_media(database, page.archive, provider, fetch_batch_id)
            import_coverage(
                database,
                page.archive,
                provider,
                context.connection_id,
                fetch_batch_id,
            )
            _refresh_fts(database, provider, page.archive)
            _update_cursor(database, context, page)
            _upsert_success_coverage(database, context, page, fetch_batch_id)
            _update_run_receipt_at(
                database,
                lease,
                RunReceiptUpdate(
                    "complete" if page.complete else "running",
                    resource_delta=resource_count,
                    terminal=page.complete,
                ),
                social_now(),
            )
        return resource_count
    finally:
        database.close()


def _observation_time(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise SocialStoreError("social response observed_at must be text")
    return value


def _retry_after(payload: dict[str, Any]) -> int | str | None:
    value = payload.get("retry_after")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise SocialStoreError("social retry_after must be text or an integer")
    return value


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
    fetch_batch_id: str,
    decision: TerminalDecision,
) -> None:
    retention_limit = getattr(context.spec, "retention_limit", None)
    database.execute(
        """INSERT INTO coverage_records(
           provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
           retention_limit,unavailable_reason,status,batch_id,observed_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream) DO UPDATE SET
           retention_limit=excluded.retention_limit,
           unavailable_reason=excluded.unavailable_reason,status=excluded.status,
           batch_id=excluded.batch_id,observed_at=excluded.observed_at""",
        (
            _provider(context),
            context.connection_id,
            context.stream,
            None,
            None,
            int(context.state.backfill_complete),
            retention_limit,
            decision.failure_class,
            _terminal_coverage_status(decision),
            fetch_batch_id,
            raw.observed_at,
        ),
    )


def record_terminal(
    context: CollectionContext,
    payload: dict[str, Any],
    request: str,
    decision: TerminalDecision,
) -> int | str | None:
    """Persist a credential-filtered terminal response without cursor advance."""
    reject_credentials(payload)
    observed_at = _observation_time(payload)
    retry_after = _retry_after(payload)
    database = connect(context.root)
    try:
        migrate(database)
        with raw_evidence_transaction(database, context.root) as transaction:
            lease = _run_lease(context)
            _assert_run_lease_at(database, lease, social_now())
            _assert_connection_binding(database, context)
            raw = _raw_batch(transaction, context, payload, request, observed_at)
            upsert_connection(
                database,
                _connection_archive(context),
                _provider(context),
                context.connection_id,
            )
            fetch_batch_id = _insert_fetch_batch(
                database,
                context,
                FetchRecord(raw, decision.failure_class, 0, context.spec.cost_units),
            )
            _upsert_terminal_coverage(
                database, context, raw, fetch_batch_id, decision
            )
            _update_run_receipt_at(
                database,
                lease,
                RunReceiptUpdate(
                    decision.run_status,
                    failure_class=decision.failure_class,
                    retry_after=retry_after,
                    terminal=True,
                ),
                social_now(),
            )
        return retry_after
    finally:
        database.close()


def record_terminal_result(
    context: CollectionContext,
    payload: dict[str, Any],
    request: str,
    decision: TerminalDecision,
    progress: CollectionProgress,
) -> dict[str, Any]:
    """Persist one terminal page and return sanitized invocation counters."""
    retry_after = record_terminal(context, payload, request, decision)
    stopped = CollectionProgress(
        progress.pages,
        progress.resources,
        progress.budget_units + context.spec.cost_units,
    )
    return collection_result(
        decision.output_status,
        stopped,
        failure_class=decision.failure_class,
        retry_after=retry_after,
        run_id=context.lease.run_id if context.lease else None,
    )


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
        _assert_run_lease_at(database, lease, now)
        _assert_connection_binding(database, context)
        updated = database.execute(
            "UPDATE coverage_records SET status=?,unavailable_reason=?,observed_at=? "
            "WHERE provider=? AND connection_id=? AND stream=?",
            (
                status,
                failure,
                observed_at,
                _provider(context),
                context.connection_id,
                context.stream,
            ),
        ).rowcount
        if updated != 1:
            raise SocialStoreError("social stop has no durable coverage checkpoint")
        _update_run_receipt_at(
            database,
            lease,
            RunReceiptUpdate(status, failure_class=failure, terminal=True),
            social_now(),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
