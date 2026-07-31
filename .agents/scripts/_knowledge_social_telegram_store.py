#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced persistence for immutable Telegram raw batches and projections."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RunLease, RunReceiptUpdate, assert_run_lease, update_run_receipt
from _knowledge_social_telegram_contract import (
    PROVIDER,
    ParsedTelegramBatch,
    read_bounded_path,
)
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


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_media(
    root: Path, parsed: ParsedTelegramBatch
) -> tuple[dict[str, str], list[Path]]:
    refs: dict[str, str] = {}
    created: list[Path] = []
    if not parsed.media_payloads:
        return refs, created
    directory = private_directory(
        root, Path("sources") / "social" / "media" / PROVIDER / parsed.archive["connection_id"]
    )
    try:
        for media in parsed.media_payloads:
            digest = hashlib.sha256(media.payload).hexdigest()
            path = directory / digest
            relative = path.relative_to(root).as_posix()
            if path.exists():
                existing = read_bounded_path(
                    path, len(media.payload), "stored media blob"
                )
                if hashlib.sha256(existing).hexdigest() != digest:
                    raise SocialStoreError(
                        "Telegram immutable media blob conflicts with stored bytes"
                    )
            else:
                descriptor, temporary_name = tempfile.mkstemp(
                    prefix=".telegram-media-", dir=directory
                )
                temporary = Path(temporary_name)
                try:
                    with os.fdopen(descriptor, "wb") as target:
                        descriptor = -1
                        target.write(media.payload)
                        target.flush()
                        os.fsync(target.fileno())
                    try:
                        os.link(temporary, path)
                        created.append(path)
                        _fsync_directory(directory)
                    except FileExistsError:
                        existing = read_bounded_path(
                            path, len(media.payload), "stored media blob"
                        )
                        if hashlib.sha256(existing).hexdigest() != digest:
                            raise SocialStoreError(
                                "Telegram immutable media blob conflicts with stored bytes"
                            )
                finally:
                    if descriptor >= 0:
                        os.close(descriptor)
                    temporary.unlink(missing_ok=True)
            refs[media.remote_id] = relative
        return refs, created
    except Exception:
        _remove_created(created)
        raise


def _remove_created(paths: list[Path]) -> None:
    for path in reversed(paths):
        try:
            path.unlink(missing_ok=True)
            _fsync_directory(path.parent)
        except OSError:
            continue


def _previous_offset(
    database: sqlite3.Connection, parsed: ParsedTelegramBatch
) -> int:
    if parsed.stream != "bot_updates":
        return 0
    previous = database.execute(
        "SELECT cursor FROM sync_cursors WHERE connection_id=? AND stream=?",
        (parsed.archive["connection_id"], parsed.stream),
    ).fetchone()
    return int(previous["cursor"]) if previous and previous["cursor"] else 0


def _validate_and_filter_updates(
    database: sqlite3.Connection, parsed: ParsedTelegramBatch
) -> tuple[int, int, bool]:
    """Require contiguous owner sequences and remove stale projections."""
    if parsed.stream != "bot_updates":
        return 0, parsed.normalized_items, True
    previous = _previous_offset(database, parsed)
    update_ids = parsed.update_ids
    future = [value for value in update_ids if value >= previous]
    if future:
        expected = previous if previous else future[0]
        for value in future:
            if value != expected:
                raise SocialStoreError(
                    "Telegram fan-out sequence has a gap; prior cursor was preserved"
                )
            expected += 1
    advances_projection = previous == 0 or bool(future)
    retained_ids = set(future) if previous else set(update_ids)
    parsed.archive["accounts"] = [
        record
        for record in parsed.archive["accounts"]
        if (
            advances_projection
            and record.get("provider_json", {}).get("source")
            == "telegram_bot_api_identity"
        )
        or record.get("provider_json", {}).get("fanout_sequence") in retained_ids
    ]
    retained_objects = []
    for record in parsed.archive["objects"]:
        fanout_sequence = record.get("provider_json", {}).get("fanout_sequence")
        if fanout_sequence in retained_ids:
            retained_objects.append(record)
    retained_activities = []
    for record in parsed.archive["activities"]:
        fanout_sequence = record.get("provider_json", {}).get("fanout_sequence")
        if fanout_sequence in retained_ids:
            retained_activities.append(record)
    parsed.archive["objects"] = retained_objects
    parsed.archive["activities"] = retained_activities
    parsed.archive["media"] = [
        record
        for record in parsed.archive["media"]
        if record.get("_fanout_sequence") in retained_ids
    ]
    effective_count = sum(
        len(parsed.archive[key])
        for key in ("accounts", "objects", "activities", "media")
    )
    next_offset = max(previous, (future[-1] + 1) if future else previous)
    return next_offset, effective_count, advances_projection


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
    created_paths: list[Path] = []
    raw_path = (
        root
        / "sources"
        / "social"
        / "raw"
        / PROVIDER
        / parsed.archive["connection_id"]
        / f"{parsed.raw_sha256}.json.gz"
    )
    raw_existed = raw_path.exists() or raw_path.is_symlink()
    database = connect(root)
    committed = False
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        assert_run_lease(database, lease)
        _assert_binding(database, parsed)
        media_refs, created_media = _write_media(root, parsed)
        created_paths.extend(created_media)
        for record in parsed.archive["media"]:
            if record["remote_id"] in media_refs:
                record["blob_ref"] = media_refs[record["remote_id"]]
                record["hydration_state"] = "local"
        batch_id, blob_ref = write_raw_batch(
            root, PROVIDER, parsed.archive["connection_id"], parsed.raw_payload
        )
        if not raw_existed:
            created_paths.append(raw_path)
            _fsync_directory(raw_path.parent)
        if batch_id != parsed.raw_sha256:
            raise SocialStoreError("Telegram raw evidence hash changed")
        existing = database.execute(
            "SELECT provider,connection_id,stream,response_hash,blob_ref,resource_count "
            "FROM fetch_batches WHERE batch_id=?",
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
            resource_count = int(existing["resource_count"])
            update_run_receipt(
                database, lease, RunReceiptUpdate("complete", terminal=True)
            )
            database.execute("COMMIT")
            committed = True
            return {
                "batch_id": batch_id,
                "normalized_items": resource_count,
                "replayed": True,
                "status": "complete",
                "stream": parsed.stream,
            }
        next_offset, effective_count, advances_projection = _validate_and_filter_updates(
            database, parsed
        )
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
        if advances_projection:
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
                cursor = str(next_offset)
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
                "complete", resource_delta=effective_count, terminal=True
            ),
        )
        database.execute("COMMIT")
        committed = True
        return {
            "batch_id": batch_id,
            "normalized_items": effective_count,
            "next_offset": next_offset if parsed.stream == "bot_updates" else None,
            "replayed": False,
            "status": "complete",
            "stream": parsed.stream,
        }
    except Exception:
        if not committed:
            _remove_created(created_paths)
            if database.in_transaction:
                database.execute("ROLLBACK")
        raise
    finally:
        database.close()
