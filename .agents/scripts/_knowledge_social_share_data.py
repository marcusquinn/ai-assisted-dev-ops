#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Export signed-batch content and rebuild a local social projection."""

from __future__ import annotations

import gzip
import hashlib
import os
import stat
from pathlib import Path
from typing import Any, NamedTuple

from _knowledge_social_share_crypto import (
    ShareError,
    b64d,
    b64e,
    validate_opaque,
)
from _knowledge_social_share_envelope import SNAPSHOT_KIND
from knowledge_social_store import (
    SocialStoreError,
    connect,
    connect_read_only,
    create_fts,
    migrate,
    require_schema,
    validate_opaque as validate_store_opaque,
    write_raw_batch,
)

SNAPSHOT_VERSION = 1
MAX_RAW_BATCH_BYTES = 64 * 1024 * 1024
MAX_BATCHES = 10_000
MAX_TABLE_ROWS = 1_000_000
TABLE_COLUMNS: dict[str, tuple[str, ...]] = {
    "connections": (
        "connection_id",
        "provider",
        "remote_account_id",
        "enabled_streams",
        "policy_json",
    ),
    "accounts": (
        "provider",
        "remote_id",
        "handle",
        "display_name",
        "observed_at",
        "provider_json",
    ),
    "objects": (
        "provider",
        "object_type",
        "remote_id",
        "account_remote_id",
        "text_content",
        "created_at",
        "observed_at",
        "evidence_class",
        "provider_json",
        "batch_id",
    ),
    "activities": (
        "provider",
        "activity_type",
        "remote_id",
        "actor_remote_id",
        "object_remote_id",
        "occurred_at",
        "observed_at",
        "state",
        "provider_json",
        "batch_id",
    ),
    "media": (
        "provider",
        "remote_id",
        "object_remote_id",
        "content_sha256",
        "mime_type",
        "byte_size",
        "hydration_state",
        "batch_id",
    ),
    "fetch_batches": (
        "batch_id",
        "provider",
        "connection_id",
        "stream",
        "request_hash",
        "response_hash",
        "resource_count",
        "budget_units",
        "started_at",
        "completed_at",
        "terminal_status",
    ),
    "sync_cursors": (
        "connection_id",
        "stream",
        "cursor",
        "watermark",
        "last_success_at",
        "backfill_complete",
    ),
    "reconciliation_items": (
        "provider",
        "connection_id",
        "stream",
        "item_kind",
        "item_type",
        "remote_id",
        "status",
        "first_missing_at",
        "last_observed_at",
        "run_id",
    ),
    "tombstones": (
        "provider",
        "object_type",
        "remote_id",
        "observed_at",
        "reason",
        "retention_action",
        "batch_id",
    ),
    "coverage_records": (
        "provider",
        "connection_id",
        "stream",
        "earliest_at",
        "latest_at",
        "cursor_exhausted",
        "retention_limit",
        "unavailable_reason",
        "status",
        "batch_id",
        "observed_at",
    ),
}


class TableStatements(NamedTuple):
    select: str
    insert: str


SQL_STATEMENTS: dict[str, TableStatements] = {
    "connections": TableStatements(
        "SELECT connection_id,provider,remote_account_id,enabled_streams,policy_json "
        "FROM connections ORDER BY connection_id,provider,remote_account_id",
        "INSERT INTO connections(connection_id,provider,remote_account_id,auth_profile_ref,"
        "enabled_streams,policy_json) VALUES(?,?,?,?,?,?)",
    ),
    "accounts": TableStatements(
        "SELECT provider,remote_id,handle,display_name,observed_at,provider_json "
        "FROM accounts ORDER BY provider,remote_id,handle",
        "INSERT INTO accounts(provider,remote_id,handle,display_name,observed_at,provider_json) "
        "VALUES(?,?,?,?,?,?)",
    ),
    "objects": TableStatements(
        "SELECT provider,object_type,remote_id,account_remote_id,text_content,created_at,"
        "observed_at,evidence_class,provider_json,batch_id FROM objects "
        "ORDER BY provider,object_type,remote_id",
        "INSERT INTO objects(provider,object_type,remote_id,account_remote_id,text_content,"
        "created_at,observed_at,evidence_class,provider_json,batch_id) "
        "VALUES(?,?,?,?,?,?,?,?,?,?)",
    ),
    "activities": TableStatements(
        "SELECT provider,activity_type,remote_id,actor_remote_id,object_remote_id,occurred_at,"
        "observed_at,state,provider_json,batch_id FROM activities "
        "ORDER BY provider,activity_type,remote_id",
        "INSERT INTO activities(provider,activity_type,remote_id,actor_remote_id,object_remote_id,"
        "occurred_at,observed_at,state,provider_json,batch_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
    ),
    "media": TableStatements(
        "SELECT provider,remote_id,object_remote_id,content_sha256,mime_type,byte_size,"
        "hydration_state,batch_id FROM media ORDER BY provider,remote_id,object_remote_id",
        "INSERT INTO media(provider,remote_id,object_remote_id,content_sha256,mime_type,"
        "byte_size,blob_ref,hydration_state,batch_id) VALUES(?,?,?,?,?,?,?,?,?)",
    ),
    "fetch_batches": TableStatements(
        "SELECT batch_id,provider,connection_id,stream,request_hash,response_hash,resource_count,"
        "budget_units,started_at,completed_at,terminal_status FROM fetch_batches "
        "ORDER BY batch_id,provider,connection_id",
        "INSERT INTO fetch_batches(batch_id,provider,connection_id,stream,request_hash,"
        "response_hash,blob_ref,resource_count,budget_units,started_at,completed_at,"
        "terminal_status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
    ),
    "sync_cursors": TableStatements(
        "SELECT connection_id,stream,cursor,watermark,last_success_at,backfill_complete "
        "FROM sync_cursors ORDER BY connection_id,stream,cursor",
        "INSERT INTO sync_cursors(connection_id,stream,cursor,watermark,last_success_at,"
        "backfill_complete) VALUES(?,?,?,?,?,?)",
    ),
    "reconciliation_items": TableStatements(
        "SELECT provider,connection_id,stream,item_kind,item_type,remote_id,status,"
        "first_missing_at,last_observed_at,run_id FROM reconciliation_items "
        "ORDER BY provider,connection_id,stream",
        "INSERT INTO reconciliation_items(provider,connection_id,stream,item_kind,item_type,"
        "remote_id,status,first_missing_at,last_observed_at,run_id) VALUES(?,?,?,?,?,?,?,?,?,?)",
    ),
    "tombstones": TableStatements(
        "SELECT provider,object_type,remote_id,observed_at,reason,retention_action,batch_id "
        "FROM tombstones ORDER BY provider,object_type,remote_id",
        "INSERT INTO tombstones(provider,object_type,remote_id,observed_at,reason,"
        "retention_action,batch_id) VALUES(?,?,?,?,?,?,?)",
    ),
    "coverage_records": TableStatements(
        "SELECT provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,"
        "retention_limit,unavailable_reason,status,batch_id,observed_at FROM coverage_records "
        "ORDER BY provider,connection_id,stream",
        "INSERT INTO coverage_records(provider,connection_id,stream,earliest_at,latest_at,"
        "cursor_exhausted,retention_limit,unavailable_reason,status,batch_id,observed_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
    ),
}
RESTORE_COLUMNS: dict[str, tuple[str, ...]] = {
    **TABLE_COLUMNS,
    "connections": (
        "connection_id",
        "provider",
        "remote_account_id",
        "auth_profile_ref",
        "enabled_streams",
        "policy_json",
    ),
    "media": TABLE_COLUMNS["media"][:-2] + ("blob_ref",) + TABLE_COLUMNS["media"][-2:],
    "fetch_batches": TABLE_COLUMNS["fetch_batches"][:6]
    + ("blob_ref",)
    + TABLE_COLUMNS["fetch_batches"][6:],
}
DELETE_STATEMENTS = (
    "DELETE FROM collector_leases",
    "DELETE FROM collector_lease_generations",
    "DELETE FROM sync_runs",
    "DELETE FROM reconciliation_items",
    "DELETE FROM tombstones",
    "DELETE FROM coverage_records",
    "DELETE FROM sync_cursors",
    "DELETE FROM media",
    "DELETE FROM activities",
    "DELETE FROM objects",
    "DELETE FROM fetch_batches",
    "DELETE FROM accounts",
    "DELETE FROM connections",
)


def _rows(connection: Any, table: str) -> list[dict[str, Any]]:
    return [
        dict(row)
        for row in connection.execute(SQL_STATEMENTS[table].select).fetchall()
    ]


def _raw_payload(root: Path, relative: str, batch_id: str) -> bytes:
    path = Path(relative)
    if path.is_absolute():
        raise SocialStoreError("shared raw batch path must be relative")
    candidate = root / path
    try:
        resolved = candidate.resolve(strict=True)
        candidate_stat = candidate.lstat()
    except OSError as error:
        raise SocialStoreError("shared raw batch is unavailable") from error
    if resolved != Path(os.path.abspath(candidate)):
        raise SocialStoreError("shared raw batch path contains a symlink")
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise SocialStoreError("shared raw batch escapes the corpus") from error
    if (
        not stat.S_ISREG(candidate_stat.st_mode)
        or candidate_stat.st_uid != os.getuid()
        or stat.S_IMODE(candidate_stat.st_mode) & 0o077
    ):
        raise SocialStoreError("shared raw batch is not an owner-only regular file")
    try:
        with gzip.open(resolved, "rb") as handle:
            payload = handle.read(MAX_RAW_BATCH_BYTES + 1)
    except (OSError, EOFError) as error:
        raise SocialStoreError("shared raw batch is not valid gzip data") from error
    if len(payload) > MAX_RAW_BATCH_BYTES:
        raise SocialStoreError("shared raw batch exceeds the size limit")
    if hashlib.sha256(payload).hexdigest() != batch_id:
        raise SocialStoreError("shared raw batch hash mismatch")
    return payload


def build_snapshot(root: Path, workspace_id: str, corpus_id: str) -> dict[str, Any]:
    workspace_id = validate_opaque(workspace_id, "workspace_id")
    corpus_id = validate_opaque(corpus_id, "corpus_id")
    connection = connect_read_only(root)
    try:
        require_schema(connection)
        if connection.execute("SELECT count(*) FROM annotations").fetchone()[0]:
            raise SocialStoreError("private annotations cannot enter a shared snapshot")
        tables = {
            table: _rows(connection, table)
            for table in TABLE_COLUMNS
        }
        batch_rows = connection.execute(
            "SELECT batch_id,blob_ref FROM fetch_batches ORDER BY batch_id"
        ).fetchall()
        if len(batch_rows) > MAX_BATCHES:
            raise SocialStoreError("shared snapshot contains too many raw batches")
        raw_batches = [
            {
                "batch_id": str(row["batch_id"]),
                "payload": b64e(
                    _raw_payload(root, str(row["blob_ref"]), str(row["batch_id"]))
                ),
            }
            for row in batch_rows
        ]
    finally:
        connection.close()
    return {
        "schema_version": SNAPSHOT_VERSION,
        "kind": SNAPSHOT_KIND,
        "workspace_id": workspace_id,
        "corpus_id": corpus_id,
        "tables": tables,
        "raw_batches": raw_batches,
    }


def _validated_tables(payload: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    tables = payload.get("tables")
    if not isinstance(tables, dict) or set(tables) != set(TABLE_COLUMNS):
        raise ShareError("SOCIAL_SHARE_INVALID", "shared snapshot tables are invalid", 3)
    validated: dict[str, list[dict[str, Any]]] = {}
    for table, columns in TABLE_COLUMNS.items():
        rows = tables.get(table)
        if (
            not isinstance(rows, list)
            or len(rows) > MAX_TABLE_ROWS
            or any(not isinstance(row, dict) or set(row) != set(columns) for row in rows)
        ):
            raise ShareError("SOCIAL_SHARE_INVALID", f"shared snapshot {table} rows are invalid", 3)
        validated[table] = rows
    return validated


def validate_snapshot(
    payload: dict[str, Any], workspace_id: str, corpus_id: str
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, bytes]]:
    if set(payload) != {
        "schema_version",
        "kind",
        "workspace_id",
        "corpus_id",
        "tables",
        "raw_batches",
    }:
        raise ShareError("SOCIAL_SHARE_INVALID", "shared snapshot fields are invalid", 3)
    if (
        payload.get("schema_version") != SNAPSHOT_VERSION
        or payload.get("kind") != SNAPSHOT_KIND
        or payload.get("workspace_id") != workspace_id
        or payload.get("corpus_id") != corpus_id
    ):
        raise ShareError("SOCIAL_SHARE_INVALID", "shared snapshot scope is invalid", 3)
    tables = _validated_tables(payload)
    raw_values = payload.get("raw_batches")
    if not isinstance(raw_values, list) or len(raw_values) > MAX_BATCHES:
        raise ShareError("SOCIAL_SHARE_INVALID", "shared raw batch list is invalid", 3)
    raw_batches: dict[str, bytes] = {}
    for value in raw_values:
        if not isinstance(value, dict) or set(value) != {"batch_id", "payload"}:
            raise ShareError("SOCIAL_SHARE_INVALID", "shared raw batch fields are invalid", 3)
        batch_id = value.get("batch_id")
        if not isinstance(batch_id, str) or batch_id in raw_batches:
            raise ShareError("SOCIAL_SHARE_INVALID", "shared raw batch id is invalid", 3)
        raw = b64d(str(value.get("payload", "")), "raw batch")
        if len(raw) > MAX_RAW_BATCH_BYTES or hashlib.sha256(raw).hexdigest() != batch_id:
            raise ShareError("SOCIAL_SHARE_INVALID", "shared raw batch hash is invalid", 3)
        raw_batches[batch_id] = raw
    expected = {str(row["batch_id"]) for row in tables["fetch_batches"]}
    if expected != set(raw_batches):
        raise ShareError("SOCIAL_SHARE_INVALID", "shared raw batch inventory is incomplete", 3)
    return tables, raw_batches


def _insert_rows(
    connection: Any,
    table: str,
    rows: list[dict[str, Any]],
) -> None:
    columns = RESTORE_COLUMNS[table]
    connection.executemany(
        SQL_STATEMENTS[table].insert,
        [tuple(row[column] for column in columns) for row in rows],
    )


def restore_snapshot(
    root: Path, payload: dict[str, Any], workspace_id: str, corpus_id: str
) -> dict[str, int]:
    tables, raw_batches = validate_snapshot(payload, workspace_id, corpus_id)
    fetch_rows = {str(row["batch_id"]): row for row in tables["fetch_batches"]}
    blob_refs: dict[str, str] = {}
    for batch_id, raw in raw_batches.items():
        row = fetch_rows[batch_id]
        provider = validate_store_opaque(str(row["provider"]), "provider")
        connection_id = validate_store_opaque(
            str(row["connection_id"]), "connection_id"
        )
        written_id, blob_ref = write_raw_batch(root, provider, connection_id, raw)
        if written_id != batch_id:
            raise SocialStoreError("restored raw batch hash changed")
        blob_refs[batch_id] = blob_ref
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        if database.execute("SELECT count(*) FROM annotations").fetchone()[0]:
            raise SocialStoreError("shared restore refuses to remove private annotations")
        for statement in DELETE_STATEMENTS:
            database.execute(statement)
        connection_rows = [
            {**row, "auth_profile_ref": None} for row in tables["connections"]
        ]
        _insert_rows(
            database,
            "connections",
            connection_rows,
        )
        for table in ("accounts", "objects", "activities"):
            _insert_rows(database, table, tables[table])
        media_rows = [{**row, "blob_ref": None} for row in tables["media"]]
        _insert_rows(
            database,
            "media",
            media_rows,
        )
        fetch_with_refs = [
            {**row, "blob_ref": blob_refs[str(row["batch_id"])]}
            for row in tables["fetch_batches"]
        ]
        _insert_rows(
            database,
            "fetch_batches",
            fetch_with_refs,
        )
        for table in (
            "sync_cursors",
            "reconciliation_items",
            "tombstones",
            "coverage_records",
        ):
            _insert_rows(database, table, tables[table])
        database.execute("DROP TABLE IF EXISTS objects_fts")
        create_fts(database)
        database.execute(
            """INSERT INTO objects_fts(
                provider,object_type,remote_id,account_remote_id,text_content,evidence_class)
               SELECT provider,object_type,remote_id,account_remote_id,text_content,evidence_class
                 FROM objects ORDER BY object_id"""
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()
    return {
        "raw_batches": len(raw_batches),
        "objects": len(tables["objects"]),
        "activities": len(tables["activities"]),
    }
