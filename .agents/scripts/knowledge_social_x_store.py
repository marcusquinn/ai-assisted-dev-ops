#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Transactional checkpoint persistence for the read-only X adapter."""

from __future__ import annotations

import hashlib
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from knowledge_social_import import (
    canonical_json,
    import_accounts,
    import_activities,
    import_media,
    import_objects,
    upsert_connection,
)
from knowledge_social_store import connect, migrate, write_raw_batch
from knowledge_social_x_contract import PROVIDER


@dataclass(frozen=True)
class PageCheckpoint:
    """Cursor state committed atomically with one fetched page."""

    stream: str
    cursor: str | None
    watermark: str | None
    complete: bool


def current_cursor(
    database: Any, connection_id: str, stream: str
) -> tuple[str | None, str | None, bool]:
    row = database.execute(
        "SELECT cursor,watermark,backfill_complete FROM sync_cursors WHERE connection_id=? AND stream=?",
        (connection_id, stream),
    ).fetchone()
    if row is None:
        return None, None, False
    return row["cursor"], row["watermark"], bool(row["backfill_complete"])


def persist_page(
    root: Path,
    archive: dict[str, Any],
    payload: dict[str, Any],
    checkpoint: PageCheckpoint,
) -> int:
    raw = canonical_json(payload).encode("utf-8")
    connection_id = archive["connection_id"]
    database = connect(root)
    try:
        migrate(database)
        batch_id, blob_ref = write_raw_batch(root, PROVIDER, connection_id, raw)
        database.execute("BEGIN IMMEDIATE")
        upsert_connection(database, archive, PROVIDER, connection_id)
        import_accounts(database, archive, PROVIDER)
        import_objects(database, archive, PROVIDER, batch_id)
        import_activities(database, archive, PROVIDER, batch_id)
        import_media(database, archive, PROVIDER, batch_id)
        count = sum(
            len(archive[key]) for key in ("accounts", "objects", "activities", "media")
        )
        database.execute(
            """INSERT OR IGNORE INTO fetch_batches(
               batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
               resource_count,budget_units,completed_at,terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (
                batch_id,
                PROVIDER,
                connection_id,
                checkpoint.stream,
                hashlib.sha256(checkpoint.stream.encode()).hexdigest(),
                batch_id,
                blob_ref,
                count,
                1,
                archive["exported_at"],
                "success",
            ),
        )
        database.execute(
            """INSERT INTO sync_cursors(
               connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
               VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
               cursor=excluded.cursor,watermark=excluded.watermark,
               last_success_at=excluded.last_success_at,
               backfill_complete=excluded.backfill_complete""",
            (
                connection_id,
                checkpoint.stream,
                checkpoint.cursor,
                checkpoint.watermark,
                archive["exported_at"],
                int(checkpoint.complete),
            ),
        )
        database.execute("COMMIT")
        return count
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def record_stop(
    root: Path,
    connection_id: str,
    status: str,
    failure: str,
    retry_after: str | None,
) -> None:
    database = connect(root)
    try:
        migrate(database)
        database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,retry_after,diagnostics) VALUES(?,?,?,?,?,?)",
            (uuid.uuid4().hex, connection_id, status, failure, retry_after, "sanitized"),
        )
    finally:
        database.close()


def load_stream_state(
    root: Path, connection_id: str, stream: str
) -> tuple[str | None, str | None, bool]:
    database = connect(root)
    try:
        migrate(database)
        return current_cursor(database, connection_id, stream)
    finally:
        database.close()
