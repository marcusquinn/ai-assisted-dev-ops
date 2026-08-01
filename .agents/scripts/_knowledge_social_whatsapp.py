#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomically persist validated WhatsApp export or webhook evidence."""

from __future__ import annotations

import gzip
import hashlib
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RunLease, RunReceiptUpdate, assert_run_lease, update_run_receipt
from _knowledge_social_whatsapp_contract import PROVIDER, ParsedWhatsAppBatch
from knowledge_social_import import import_accounts, import_activities, import_coverage, import_media, import_objects, reject_credentials, upsert_connection
from knowledge_social_store import SocialStoreError, connect, migrate, write_raw_batch


def _assert_binding(database: sqlite3.Connection, connection_id: str, account_id: str) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is not None and (row["provider"] != PROVIDER or row["remote_account_id"] != account_id):
        raise SocialStoreError("WhatsApp connection is already bound to another source")


def _raw_path(root: Path, connection_id: str, digest: str) -> Path:
    return root / "sources" / "social" / "raw" / PROVIDER / connection_id / f"{digest}.json.gz"


def _raw_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("WhatsApp raw evidence is missing or unsafe")
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise SocialStoreError("WhatsApp raw evidence could not be verified") from error
    return digest.hexdigest()


def _refresh_fts(database: sqlite3.Connection, archive: dict[str, Any]) -> None:
    for record in archive["objects"]:
        identity = (PROVIDER, record["object_type"], record["remote_id"])
        database.execute("DELETE FROM objects_fts WHERE provider=? AND object_type=? AND remote_id=?", identity)
        database.execute(
            """INSERT INTO objects_fts(provider,object_type,remote_id,account_remote_id,text_content,evidence_class)
               SELECT provider,object_type,remote_id,account_remote_id,text_content,evidence_class
                 FROM objects WHERE provider=? AND object_type=? AND remote_id=?""",
            identity,
        )


def _replay_result(parsed: ParsedWhatsAppBatch, blob_ref: str) -> dict[str, Any]:
    return {
        "batch_id": parsed.manifest_sha256,
        "blob_ref": blob_ref,
        "normalized_items": parsed.normalized_items,
        "replayed": True,
        "status": "complete",
        "stream": parsed.stream,
    }


def _replay_metadata_matches(
    existing: sqlite3.Row,
    parsed: ParsedWhatsAppBatch,
    connection_id: str,
    expected_ref: str,
) -> bool:
    return all((
        existing["provider"] == PROVIDER,
        existing["connection_id"] == connection_id,
        existing["stream"] == parsed.stream,
        existing["request_hash"] == parsed.manifest_sha256,
        existing["response_hash"] == parsed.manifest_sha256,
        existing["blob_ref"] == expected_ref,
    ))


def _existing_replay(
    database: sqlite3.Connection,
    root: Path,
    parsed: ParsedWhatsAppBatch,
    connection_id: str,
    raw_path: Path,
) -> str | None:
    existing = database.execute(
        "SELECT provider,connection_id,stream,request_hash,response_hash,blob_ref,resource_count FROM fetch_batches WHERE batch_id=?",
        (parsed.manifest_sha256,),
    ).fetchone()
    if existing is None:
        return None
    expected_ref = raw_path.relative_to(root).as_posix()
    if not _replay_metadata_matches(existing, parsed, connection_id, expected_ref):
        raise SocialStoreError("WhatsApp replay metadata conflicts with stored evidence")
    if _raw_digest(raw_path) != parsed.raw_sha256:
        raise SocialStoreError("WhatsApp replay metadata conflicts with stored evidence")
    return str(existing["blob_ref"])


def _import_new_batch(
    database: sqlite3.Connection,
    archive: dict[str, Any],
    parsed: ParsedWhatsAppBatch,
    connection_id: str,
    blob_ref: str,
) -> None:
    batch_id = parsed.manifest_sha256
    upsert_connection(database, archive, PROVIDER, connection_id)
    import_accounts(database, archive, PROVIDER)
    import_objects(database, archive, PROVIDER, batch_id)
    import_activities(database, archive, PROVIDER, batch_id)
    import_media(database, archive, PROVIDER, batch_id)
    import_coverage(database, archive, PROVIDER, connection_id, batch_id)
    _refresh_fts(database, archive)
    database.execute(
        """INSERT INTO fetch_batches(batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
           resource_count,budget_units,started_at,completed_at,terminal_status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
        (batch_id, PROVIDER, connection_id, parsed.stream, batch_id, batch_id, blob_ref,
         parsed.normalized_items, 0, archive["exported_at"], archive["exported_at"], "success"),
    )
    database.execute(
        """INSERT INTO sync_cursors(connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
           VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
           cursor=NULL,watermark=excluded.watermark,last_success_at=excluded.last_success_at,
           backfill_complete=excluded.backfill_complete""",
        (connection_id, parsed.stream, None, batch_id, archive["exported_at"], int(parsed.stream == "export")),
    )


def _remove_uncommitted_raw(raw_path: Path, parsed: ParsedWhatsAppBatch) -> None:
    try:
        if _raw_digest(raw_path) == parsed.raw_sha256:
            raw_path.unlink()
    except (OSError, SocialStoreError):
        return


@dataclass
class _PersistState:
    raw_path: Path
    raw_existed: bool
    created_raw: bool = False
    committed: bool = False


@dataclass(frozen=True)
class _PersistRequest:
    root: Path
    archive: dict[str, Any]
    parsed: ParsedWhatsAppBatch
    payload: bytes
    lease: RunLease


def _validate_persist_request(
    parsed: ParsedWhatsAppBatch, payload: bytes, lease: RunLease
) -> tuple[dict[str, Any], str]:
    archive = parsed.archive
    reject_credentials(archive)
    if hashlib.sha256(payload).hexdigest() != parsed.raw_sha256:
        raise SocialStoreError("WhatsApp evidence changed after validation")
    connection_id = archive["connection_id"]
    if lease.connection_id != connection_id or lease.stream != parsed.stream:
        raise SocialStoreError("WhatsApp lease does not authorize this source stream")
    return archive, connection_id


def _commit_batch(
    database: sqlite3.Connection,
    request: _PersistRequest,
    state: _PersistState,
) -> dict[str, Any]:
    archive = request.archive
    parsed = request.parsed
    connection_id = archive["connection_id"]
    migrate(database)
    database.execute("BEGIN IMMEDIATE")
    assert_run_lease(database, request.lease)
    _assert_binding(database, connection_id, archive["remote_account_id"])
    existing_ref = _existing_replay(database, request.root, parsed, connection_id, state.raw_path)
    if existing_ref is not None:
        update_run_receipt(database, request.lease, RunReceiptUpdate("complete", terminal=True))
        database.execute("COMMIT")
        state.committed = True
        return _replay_result(parsed, existing_ref)
    raw_digest, blob_ref = write_raw_batch(request.root, PROVIDER, connection_id, request.payload)
    state.created_raw = not state.raw_existed
    if raw_digest != parsed.raw_sha256:
        raise SocialStoreError("WhatsApp raw evidence hash changed")
    _import_new_batch(database, archive, parsed, connection_id, blob_ref)
    update_run_receipt(
        database,
        request.lease,
        RunReceiptUpdate("complete", resource_delta=parsed.normalized_items, terminal=True),
    )
    database.execute("COMMIT")
    state.committed = True
    return {**_replay_result(parsed, blob_ref), "replayed": False}


def persist_batch(root: Path, parsed: ParsedWhatsAppBatch, payload: bytes, lease: RunLease) -> dict[str, Any]:
    archive, connection_id = _validate_persist_request(parsed, payload, lease)
    raw_path = _raw_path(root, connection_id, parsed.raw_sha256)
    state = _PersistState(raw_path, raw_path.exists() or raw_path.is_symlink())
    request = _PersistRequest(root, archive, parsed, payload, lease)
    database = connect(root)
    try:
        return _commit_batch(database, request, state)
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        if state.created_raw and not state.committed:
            _remove_uncommitted_raw(state.raw_path, parsed)
        raise
    finally:
        database.close()
