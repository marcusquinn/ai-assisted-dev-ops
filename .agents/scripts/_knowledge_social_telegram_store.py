#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced persistence for immutable Telegram raw batches and projections."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RunLease, RunReceiptUpdate, assert_run_lease, update_run_receipt
from _knowledge_social_telegram_contract import PROVIDER, ParsedTelegramBatch
from knowledge_social_import import (
    import_accounts,
    import_activities,
    import_coverage,
    import_media,
    import_objects,
    upsert_connection,
)
from knowledge_social_store import SocialStoreError, connect, migrate, private_directory, write_raw_batch


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


def _write_media(root: Path, parsed: ParsedTelegramBatch) -> dict[str, str]:
    refs: dict[str, str] = {}
    if not parsed.media_payloads:
        return refs
    directory = private_directory(
        root, Path("sources") / "social" / "media" / PROVIDER / parsed.archive["connection_id"]
    )
    for media in parsed.media_payloads:
        digest = hashlib.sha256(media.payload).hexdigest()
        path = directory / digest
        relative = path.relative_to(root).as_posix()
        if path.exists():
            if path.is_symlink() or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                raise SocialStoreError("Telegram immutable media blob conflicts with stored bytes")
        else:
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            try:
                with os.fdopen(descriptor, "wb") as target:
                    descriptor = -1
                    target.write(media.payload)
                    target.flush()
                    os.fsync(target.fileno())
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        refs[media.remote_id] = relative
    return refs


def _refresh_fts(database: sqlite3.Connection, parsed: ParsedTelegramBatch) -> None:
    for record in parsed.archive["objects"]:
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


def persist_telegram_batch(
    root: Path, parsed: ParsedTelegramBatch, lease: RunLease
) -> dict[str, Any]:
    """Commit raw evidence, projections, coverage, and cursor under one fence."""
    if hashlib.sha256(parsed.raw_payload).hexdigest() != parsed.raw_sha256:
        raise SocialStoreError("Telegram raw evidence changed after validation")
    media_refs = _write_media(root, parsed)
    for record in parsed.archive["media"]:
        if record["remote_id"] in media_refs:
            record["blob_ref"] = media_refs[record["remote_id"]]
            record["hydration_state"] = "local"
    batch_id, blob_ref = write_raw_batch(
        root, PROVIDER, parsed.archive["connection_id"], parsed.raw_payload
    )
    if batch_id != parsed.raw_sha256:
        raise SocialStoreError("Telegram raw evidence hash changed")
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        assert_run_lease(database, lease)
        _assert_binding(database, parsed)
        existing = database.execute(
            "SELECT provider,connection_id,stream,response_hash,blob_ref FROM fetch_batches WHERE batch_id=?",
            (batch_id,),
        ).fetchone()
        if existing is not None:
            if (
                existing["provider"] != PROVIDER
                or existing["connection_id"] != parsed.archive["connection_id"]
                or existing["stream"] != parsed.stream
                or existing["response_hash"] != batch_id
                or existing["blob_ref"] != blob_ref
            ):
                raise SocialStoreError("Telegram raw replay conflicts with its stored batch")
            update_run_receipt(
                database, lease, RunReceiptUpdate("complete", terminal=True)
            )
            database.execute("COMMIT")
            return {
                "batch_id": batch_id,
                "normalized_items": int(
                    database.execute(
                        "SELECT resource_count FROM fetch_batches WHERE batch_id=?", (batch_id,)
                    ).fetchone()[0]
                ),
                "replayed": True,
                "status": "complete",
                "stream": parsed.stream,
            }
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
                parsed.normalized_items,
                0,
                parsed.archive["exported_at"],
                parsed.archive["exported_at"],
                "success",
            ),
        )
        upsert_connection(
            database, parsed.archive, PROVIDER, parsed.archive["connection_id"]
        )
        import_accounts(database, parsed.archive, PROVIDER)
        import_objects(database, parsed.archive, PROVIDER, batch_id)
        import_activities(database, parsed.archive, PROVIDER, batch_id)
        import_media(database, parsed.archive, PROVIDER, batch_id)
        import_coverage(
            database,
            parsed.archive,
            PROVIDER,
            parsed.archive["connection_id"],
            batch_id,
        )
        _refresh_fts(database, parsed)
        if parsed.stream == "archive":
            cursor = None
            backfill_complete = 1
        else:
            previous = database.execute(
                "SELECT cursor FROM sync_cursors WHERE connection_id=? AND stream=?",
                (parsed.archive["connection_id"], parsed.stream),
            ).fetchone()
            previous_offset = int(previous["cursor"]) if previous and previous["cursor"] else 0
            cursor = str(max(previous_offset, parsed.next_offset or previous_offset))
            backfill_complete = 0
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
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(
                "complete", resource_delta=parsed.normalized_items, terminal=True
            ),
        )
        database.execute("COMMIT")
        return {
            "batch_id": batch_id,
            "normalized_items": parsed.normalized_items,
            "next_offset": parsed.next_offset,
            "replayed": False,
            "status": "complete",
            "stream": parsed.stream,
        }
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
