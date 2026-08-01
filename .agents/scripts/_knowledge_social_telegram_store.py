#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced persistence for immutable Telegram raw batches and projections."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RunLease, RunReceiptUpdate, assert_run_lease, update_run_receipt
from _knowledge_social_telegram_contract import (
    PROVIDER,
    ParsedTelegramBatch,
)
from _knowledge_social_telegram_store_media import (
    fsync_directory,
    remove_created,
    write_media,
)
from _knowledge_social_telegram_store_projection import (
    refresh_fts,
    validate_and_filter_updates,
)
from knowledge_social_import import (
    import_accounts,
    import_activities,
    import_coverage,
    import_media,
    import_objects,
    upsert_connection,
)
from knowledge_social_store import SocialStoreError, connect, migrate, write_raw_batch


def _assert_binding(
    database: sqlite3.Connection, parsed: ParsedTelegramBatch
) -> None:
    connection_id = parsed.archive["connection_id"]
    row = database.execute(
        "SELECT provider,remote_account_id,policy_json FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        return
    if row["provider"] != PROVIDER or row["remote_account_id"] != parsed.archive["remote_account_id"]:
        raise SocialStoreError("Telegram connection is already bound to another identity")
    previous = json.loads(row["policy_json"])
    candidate = parsed.archive["policy"]
    if parsed.stream == "bot_updates" and previous.get("owner_id") != candidate.get("owner_id"):
        raise SocialStoreError("Telegram bot update stream already has another durable owner")


def _raw_path(root: Path, parsed: ParsedTelegramBatch) -> Path:
    return (
        root
        / "sources"
        / "social"
        / "raw"
        / PROVIDER
        / parsed.archive["connection_id"]
        / f"{parsed.raw_sha256}.json.gz"
    )


def _write_evidence(
    root: Path, parsed: ParsedTelegramBatch, created_paths: list[Path]
) -> tuple[str, str]:
    media_refs, created_media = write_media(root, parsed)
    created_paths.extend(created_media)
    for record in parsed.archive["media"]:
        remote_id = record["remote_id"]
        if remote_id in media_refs:
            record["blob_ref"] = media_refs[remote_id]
            record["hydration_state"] = "local"
    raw_path = _raw_path(root, parsed)
    raw_existed = raw_path.exists() or raw_path.is_symlink()
    batch_id, blob_ref = write_raw_batch(
        root, PROVIDER, parsed.archive["connection_id"], parsed.raw_payload
    )
    if not raw_existed:
        created_paths.append(raw_path)
        fsync_directory(raw_path.parent)
    if batch_id != parsed.raw_sha256:
        raise SocialStoreError("Telegram raw evidence hash changed")
    return batch_id, blob_ref


def _replay_result(
    database: sqlite3.Connection,
    parsed: ParsedTelegramBatch,
    batch_id: str,
    blob_ref: str,
) -> dict[str, Any] | None:
    existing = database.execute(
        "SELECT provider,connection_id,stream,response_hash,blob_ref,resource_count "
        "FROM fetch_batches WHERE batch_id=?",
        (batch_id,),
    ).fetchone()
    if existing is None:
        return None
    expected = {
        "provider": PROVIDER,
        "connection_id": parsed.archive["connection_id"],
        "stream": parsed.stream,
        "response_hash": batch_id,
        "blob_ref": blob_ref,
    }
    if any(existing[key] != value for key, value in expected.items()):
        raise SocialStoreError("Telegram raw replay conflicts with its stored batch")
    return {
        "batch_id": batch_id,
        "normalized_items": int(existing["resource_count"]),
        "replayed": True,
        "status": "complete",
        "stream": parsed.stream,
    }


def _insert_fetch_batch(
    database: sqlite3.Connection,
    parsed: ParsedTelegramBatch,
    batch_id: str,
    blob_ref: str,
    effective_count: int,
) -> None:
    database.execute(
        """INSERT INTO fetch_batches(
           batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
           resource_count,budget_units,started_at,completed_at,terminal_status)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            batch_id,
            PROVIDER,
            parsed.archive["connection_id"],
            parsed.stream,
            batch_id,
            batch_id,
            blob_ref,
            effective_count,
            0,
            parsed.archive["exported_at"],
            parsed.archive["exported_at"],
            "success",
        ),
    )


def _upsert_cursor(
    database: sqlite3.Connection,
    parsed: ParsedTelegramBatch,
    batch_id: str,
    next_offset: int,
) -> None:
    cursor = None if parsed.stream == "archive" else str(next_offset)
    backfill_complete = 1 if parsed.stream == "archive" else 0
    database.execute(
        """INSERT INTO sync_cursors(
           connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
           VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
           cursor=excluded.cursor,watermark=excluded.watermark,
           last_success_at=excluded.last_success_at,
           backfill_complete=excluded.backfill_complete""",
        (
            parsed.archive["connection_id"],
            parsed.stream,
            cursor,
            batch_id,
            parsed.archive["exported_at"],
            backfill_complete,
        ),
    )


def _import_projection(
    database: sqlite3.Connection,
    parsed: ParsedTelegramBatch,
    batch_id: str,
    next_offset: int,
) -> None:
    connection_id = parsed.archive["connection_id"]
    upsert_connection(database, parsed.archive, PROVIDER, connection_id)
    import_accounts(database, parsed.archive, PROVIDER)
    import_objects(database, parsed.archive, PROVIDER, batch_id)
    import_activities(database, parsed.archive, PROVIDER, batch_id)
    import_media(database, parsed.archive, PROVIDER, batch_id)
    import_coverage(database, parsed.archive, PROVIDER, connection_id, batch_id)
    refresh_fts(database, parsed)
    _upsert_cursor(database, parsed, batch_id, next_offset)


def _persist_transaction(
    root: Path,
    parsed: ParsedTelegramBatch,
    lease: RunLease,
    database: sqlite3.Connection,
    created_paths: list[Path],
) -> dict[str, Any]:
    assert_run_lease(database, lease)
    _assert_binding(database, parsed)
    batch_id, blob_ref = _write_evidence(root, parsed, created_paths)
    replay = _replay_result(database, parsed, batch_id, blob_ref)
    if replay is not None:
        update_run_receipt(database, lease, RunReceiptUpdate("complete", terminal=True))
        return replay
    next_offset, effective_count, advances = validate_and_filter_updates(database, parsed)
    _insert_fetch_batch(database, parsed, batch_id, blob_ref, effective_count)
    if advances:
        _import_projection(database, parsed, batch_id, next_offset)
    update_run_receipt(
        database,
        lease,
        RunReceiptUpdate("complete", resource_delta=effective_count, terminal=True),
    )
    return {
        "batch_id": batch_id,
        "normalized_items": effective_count,
        "next_offset": next_offset if parsed.stream == "bot_updates" else None,
        "replayed": False,
        "status": "complete",
        "stream": parsed.stream,
    }


def persist_telegram_batch(
    root: Path, parsed: ParsedTelegramBatch, lease: RunLease
) -> dict[str, Any]:
    """Commit raw evidence, projections, coverage, and cursor under one fence."""
    if hashlib.sha256(parsed.raw_payload).hexdigest() != parsed.raw_sha256:
        raise SocialStoreError("Telegram raw evidence changed after validation")
    created_paths: list[Path] = []
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        result = _persist_transaction(root, parsed, lease, database, created_paths)
        database.execute("COMMIT")
        return result
    except Exception:
        remove_created(created_paths)
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
