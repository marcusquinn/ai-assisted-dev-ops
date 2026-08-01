#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomically persist timestamp-ordered Slack API and export evidence."""

from __future__ import annotations

import gzip
import hashlib
import os
import sqlite3
import stat
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_social_collect import CollectionContext, SuccessfulPage
from _knowledge_social_collect_persist import (
    FetchRecord,
    _assert_connection_binding,
    _insert_fetch_batch,
    _raw_batch,
    _run_lease,
)
from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    _assert_run_lease_at,
    _update_run_receipt_at,
    assert_run_lease,
    social_now,
    update_run_receipt,
)
from _knowledge_social_slack import PROVIDER
from _knowledge_social_slack_archive import ParsedSlackArchive
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_store import (
    merge_connection_state,
    store_ordered_records,
    update_page_state,
)
from knowledge_social_import import canonical_json
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    raw_evidence_transaction,
)


@dataclass(frozen=True)
class ObservationSlot:
    """Metadata that must uniquely identify one Slack observation timestamp."""

    connection_id: str
    stream: str
    request_hash: str
    response_hash: str
    completed_at: str
    batch_id: str


def _assert_observation_slot(
    database: sqlite3.Connection, expected: ObservationSlot
) -> None:
    rows = database.execute(
        "SELECT stream,request_hash,response_hash FROM fetch_batches "
        "WHERE provider=? AND connection_id=? AND completed_at=?",
        (PROVIDER, expected.connection_id, expected.completed_at),
    ).fetchall()
    identity = (expected.stream, expected.request_hash, expected.response_hash)
    if any(tuple(row) != identity for row in rows):
        raise SocialStoreError(
            "Slack evidence timestamp conflicts with an existing batch"
        )


def _page_observation(
    context: CollectionContext, page: SuccessfulPage, observed_at: str
) -> ObservationSlot:
    request_hash = hashlib.sha256(page.request.encode("utf-8")).hexdigest()
    response = canonical_json(page.payload).encode("utf-8")
    response_hash = hashlib.sha256(response).hexdigest()
    envelope = canonical_json(
        {
            "provider": PROVIDER,
            "connection_id": context.connection_id,
            "stream": context.stream,
            "observed_at": observed_at,
            "request_hash": request_hash,
            "response_sha256": response_hash,
            "response": page.payload,
        }
    ).encode("utf-8")
    return ObservationSlot(
        context.connection_id,
        context.stream,
        request_hash,
        response_hash,
        observed_at,
        hashlib.sha256(envelope).hexdigest(),
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
    descriptor = -1
    digest = hashlib.sha256()
    try:
        before = path.lstat()
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise SocialStoreError("Slack raw evidence is missing or unsafe")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as raw:
            descriptor = -1
            opened = os.fstat(raw.fileno())
            if (
                not stat.S_ISREG(opened.st_mode)
                or (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino)
            ):
                raise SocialStoreError("Slack raw evidence changed while opening")
            with gzip.GzipFile(fileobj=raw, mode="rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
    except SocialStoreError:
        raise
    except (EOFError, OSError) as error:
        raise SocialStoreError("Slack raw evidence could not be verified") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _validate_replay_blob(
    root: Path, connection_id: str, digest: str, blob_ref: str
) -> None:
    path = _raw_path(root, connection_id, digest)
    if blob_ref != path.relative_to(root).as_posix() or _gzip_payload_digest(path) != digest:
        raise SocialStoreError("Slack raw replay evidence does not match its batch")


def _result(
    parsed: ParsedSlackArchive, blob_ref: str, replayed: bool
) -> dict[str, Any]:
    return {
        "status": "complete",
        "source_sha256": parsed.source_sha256,
        "evidence_sha256": parsed.evidence_sha256,
        "blob_ref": blob_ref,
        "normalized_items": parsed.normalized_items,
        "selected_members": parsed.selected_members,
        "conversation_streams": len(parsed.conversation_streams),
        "replayed": replayed,
    }


def _insert_cursors(
    database: sqlite3.Connection,
    parsed: ParsedSlackArchive,
    connection_id: str,
    completed_at: str,
) -> None:
    streams = ("archive", *parsed.conversation_streams)
    database.executemany(
        """INSERT INTO sync_cursors(
           connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
           VALUES(?,?,NULL,?,?,1) ON CONFLICT(connection_id,stream) DO UPDATE SET
           cursor=NULL,watermark=excluded.watermark,
           last_success_at=excluded.last_success_at,backfill_complete=1
           WHERE excluded.last_success_at >= sync_cursors.last_success_at""",
        [
            (connection_id, stream, parsed.source_sha256, completed_at)
            for stream in streams
        ],
    )


def persist_slack_page(
    context: CollectionContext, page: SuccessfulPage
) -> int:
    """Persist one API page without letting older evidence regress Slack state."""
    if context.provider != PROVIDER:
        raise SocialStoreError("Slack page persistence requires the Slack provider")
    reject_slack_credentials(page.payload)
    reject_slack_credentials(page.archive)
    database = connect(context.root)
    try:
        migrate(database)
        with raw_evidence_transaction(database, context.root) as transaction:
            lease = _run_lease(context)
            _assert_run_lease_at(database, lease, social_now())
            _assert_connection_binding(database, context)
            archive = merge_connection_state(database, page.archive)
            observation = _page_observation(context, page, archive["exported_at"])
            _assert_observation_slot(database, observation)
            raw = _raw_batch(
                transaction,
                context,
                page.payload,
                page.request,
                archive["exported_at"],
            )
            if raw.batch_id != observation.batch_id:
                raise SocialStoreError("Slack API evidence hash changed")
            resource_count = sum(
                len(archive[key])
                for key in ("accounts", "objects", "activities", "media")
            )
            batch_id = _insert_fetch_batch(
                database,
                context,
                FetchRecord(raw, "success", resource_count, page.budget_units),
            )
            store_ordered_records(
                database, archive, batch_id, context.connection_id
            )
            update_page_state(database, context, page, archive, batch_id)
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


def persist_slack_archive(
    root: Path, parsed: ParsedSlackArchive, lease: RunLease
) -> dict[str, Any]:
    """Commit filtered raw evidence, rows, coverage, cursors, and receipt atomically."""
    archive = parsed.archive
    reject_slack_credentials(archive)
    if hashlib.sha256(parsed.evidence).hexdigest() != parsed.evidence_sha256:
        raise SocialStoreError("Slack filtered evidence changed after validation")
    connection_id = archive["connection_id"]
    database = connect(root)
    try:
        migrate(database)
        with raw_evidence_transaction(database, root) as transaction:
            assert_run_lease(database, lease)
            _assert_observation_slot(
                database,
                ObservationSlot(
                    connection_id,
                    "archive",
                    parsed.evidence_sha256,
                    parsed.source_sha256,
                    archive["exported_at"],
                    parsed.evidence_sha256,
                ),
            )
            archive = merge_connection_state(database, archive)
            existing = database.execute(
                "SELECT provider,connection_id,stream,request_hash,response_hash,blob_ref,"
                "resource_count,budget_units,started_at,completed_at,terminal_status "
                "FROM fetch_batches WHERE batch_id=?",
                (parsed.evidence_sha256,),
            ).fetchone()
            if existing is not None:
                observed = (
                    existing["provider"],
                    existing["connection_id"],
                    existing["stream"],
                    existing["request_hash"],
                    existing["response_hash"],
                    existing["resource_count"],
                    existing["budget_units"],
                    existing["started_at"],
                    existing["completed_at"],
                    existing["terminal_status"],
                )
                expected = (
                    PROVIDER,
                    connection_id,
                    "archive",
                    parsed.evidence_sha256,
                    parsed.source_sha256,
                    parsed.normalized_items,
                    0,
                    archive["exported_at"],
                    archive["exported_at"],
                    "success",
                )
                if observed != expected:
                    raise SocialStoreError("Slack export replay metadata conflicts")
                _validate_replay_blob(
                    root,
                    connection_id,
                    parsed.evidence_sha256,
                    str(existing["blob_ref"]),
                )
                update_run_receipt(
                    database,
                    lease,
                    RunReceiptUpdate("complete", resource_delta=0, terminal=True),
                )
                return _result(parsed, str(existing["blob_ref"]), True)
            batch_id, blob_ref = transaction.write(
                PROVIDER, connection_id, parsed.evidence
            )
            if batch_id != parsed.evidence_sha256:
                raise SocialStoreError("Slack filtered evidence hash changed")
            store_ordered_records(database, archive, batch_id, connection_id)
            database.execute(
                """INSERT INTO fetch_batches(
                   batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
                   resource_count,budget_units,started_at,completed_at,terminal_status)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    batch_id,
                    PROVIDER,
                    connection_id,
                    "archive",
                    parsed.evidence_sha256,
                    parsed.source_sha256,
                    blob_ref,
                    parsed.normalized_items,
                    0,
                    archive["exported_at"],
                    archive["exported_at"],
                    "success",
                ),
            )
            _insert_cursors(database, parsed, connection_id, archive["exported_at"])
            update_run_receipt(
                database,
                lease,
                RunReceiptUpdate(
                    "complete", resource_delta=parsed.normalized_items, terminal=True
                ),
            )
            return _result(parsed, blob_ref, False)
    finally:
        database.close()
