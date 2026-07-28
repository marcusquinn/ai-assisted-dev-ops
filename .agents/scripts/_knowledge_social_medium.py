#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate, normalize, and atomically persist one Medium account export."""

from __future__ import annotations

import gzip
import hashlib
import sqlite3
from pathlib import Path
from typing import Any

from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    assert_run_lease,
    update_run_receipt,
)
from _knowledge_social_medium_archive import build_medium_archive
from _knowledge_social_medium_common import _normalized_url
from _knowledge_social_medium_types import (
    PROVIDER,
    MediumArchiveRequest,
    ParsedMediumArchive,
)
from knowledge_social_import import (
    import_accounts,
    import_activities,
    import_coverage,
    import_media,
    import_objects,
    reject_credentials,
    upsert_connection,
)
from knowledge_social_store import SocialStoreError, connect, migrate, write_raw_batch


def parse_medium_archive(*values: Any) -> tuple[ParsedMediumArchive, bytes]:
    """Preserve the positional parser API while using a typed request internally."""
    return build_medium_archive(MediumArchiveRequest(*values))


def _assert_connection_binding(
    database: sqlite3.Connection, connection_id: str, account_id: str
) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        return
    if row["provider"] != PROVIDER or row["remote_account_id"] != account_id:
        raise SocialStoreError("Medium connection is already bound to another account")


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


def _raw_path(root: Path, connection_id: str, digest: str) -> Path:
    return (
        root
        / "sources"
        / "social"
        / "raw"
        / PROVIDER
        / connection_id
        / f"{digest}.json.gz"
    )


def _gzip_payload_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("Medium raw evidence is missing or unsafe")
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise SocialStoreError("Medium raw evidence could not be verified") from error
    return digest.hexdigest()


def _validate_replay_blob(
    root: Path, connection_id: str, digest: str, blob_ref: str
) -> None:
    path = _raw_path(root, connection_id, digest)
    expected_ref = path.relative_to(root).as_posix()
    if blob_ref != expected_ref or _gzip_payload_digest(path) != digest:
        raise SocialStoreError("Medium raw replay evidence does not match its batch")


def _remove_created_raw(path: Path, digest: str) -> None:
    try:
        if _gzip_payload_digest(path) == digest:
            path.unlink()
    except (OSError, SocialStoreError):
        return


def _result(
    parsed: ParsedMediumArchive,
    blob_ref: str,
    normalized_items: int,
    replayed: bool,
) -> dict[str, Any]:
    return {
        "account_id": parsed.archive["remote_account_id"],
        "archive_sha256": parsed.raw_sha256,
        "blob_ref": blob_ref,
        "normalized_items": normalized_items,
        "recognized_members": parsed.recognized_members,
        "replayed": replayed,
        "status": "complete",
        "unrecognized_members": parsed.unrecognized_members,
    }


def persist_medium_archive(
    root: Path,
    parsed: ParsedMediumArchive,
    payload: bytes,
    lease: RunLease,
) -> dict[str, Any]:
    """Commit raw ZIP evidence, normalized rows, coverage, and replay marker atomically."""
    archive = parsed.archive
    reject_credentials(archive)
    if hashlib.sha256(payload).hexdigest() != parsed.raw_sha256:
        raise SocialStoreError("Medium archive changed after validation")
    connection_id = archive["connection_id"]
    account_id = archive["remote_account_id"]
    raw_path = _raw_path(root, connection_id, parsed.raw_sha256)
    raw_existed = raw_path.exists() or raw_path.is_symlink()
    created_raw = False
    committed = False
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        assert_run_lease(database, lease)
        _assert_connection_binding(database, connection_id, account_id)
        existing = database.execute(
            "SELECT provider,connection_id,stream,response_hash,blob_ref,"
            "resource_count,completed_at FROM fetch_batches WHERE batch_id=?",
            (parsed.raw_sha256,),
        ).fetchone()
        if existing is not None:
            if (
                existing["provider"] != PROVIDER
                or existing["connection_id"] != connection_id
            ):
                raise SocialStoreError(
                    "Medium archive digest is already bound to another connection"
                )
            if (
                existing["stream"] != "archive"
                or existing["response_hash"] != parsed.raw_sha256
                or existing["completed_at"] != archive["exported_at"]
            ):
                raise SocialStoreError(
                    "Medium archive replay metadata conflicts with the stored batch"
                )
            _validate_replay_blob(
                root,
                connection_id,
                parsed.raw_sha256,
                str(existing["blob_ref"]),
            )
            update_run_receipt(
                database,
                lease,
                RunReceiptUpdate("complete", resource_delta=0, terminal=True),
            )
            database.execute("COMMIT")
            committed = True
            return _result(
                parsed, str(existing["blob_ref"]), int(existing["resource_count"]), True
            )
        batch_id, blob_ref = write_raw_batch(
            root, PROVIDER, connection_id, payload
        )
        created_raw = not raw_existed
        if batch_id != parsed.raw_sha256:
            raise SocialStoreError("Medium raw evidence hash changed")
        upsert_connection(database, archive, PROVIDER, connection_id)
        import_accounts(database, archive, PROVIDER)
        import_objects(database, archive, PROVIDER, batch_id)
        import_activities(database, archive, PROVIDER, batch_id)
        import_media(database, archive, PROVIDER, batch_id)
        import_coverage(database, archive, PROVIDER, connection_id, batch_id)
        _refresh_fts(database, archive)
        database.execute(
            """INSERT INTO fetch_batches(
               batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
               resource_count,budget_units,started_at,completed_at,terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(batch_id) DO NOTHING""",
            (
                batch_id,
                PROVIDER,
                connection_id,
                "archive",
                batch_id,
                batch_id,
                blob_ref,
                parsed.normalized_items,
                0,
                archive["exported_at"],
                archive["exported_at"],
                "success",
            ),
        )
        database.execute(
            """INSERT INTO sync_cursors(
               connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
               VALUES(?,?,?,?,?,1) ON CONFLICT(connection_id,stream) DO UPDATE SET
               cursor=NULL,watermark=excluded.watermark,
               last_success_at=excluded.last_success_at,backfill_complete=1""",
            (connection_id, "archive", None, batch_id, archive["exported_at"]),
        )
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(
                "complete", resource_delta=parsed.normalized_items, terminal=True
            ),
        )
        database.execute("COMMIT")
        committed = True
        return _result(parsed, blob_ref, parsed.normalized_items, False)
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        if created_raw and not committed:
            _remove_created_raw(raw_path, parsed.raw_sha256)
        raise
    finally:
        database.close()
