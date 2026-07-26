#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private per-corpus social schema and immutable raw-batch storage."""

from __future__ import annotations

import gzip
import hashlib
import os
import re
import sqlite3
from pathlib import Path

from knowledge_corpus_context import (
    CatalogError,
    validate_directory,
    validate_private_file,
)

SCHEMA_VERSION = 4
SCHEMA_VERSION_SQL = "PRAGMA user_version=4"
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
SQLITE_MUTABLE_SIDECARS = ("-journal", "-shm", "-wal")


class SocialStoreError(RuntimeError):
    """Raised when private social storage cannot be used safely."""


def private_directory(root: Path, relative: Path) -> Path:
    directory = root
    for component in relative.parts:
        directory /= component
        directory.mkdir(mode=0o700, exist_ok=True)
        try:
            validate_directory(directory, "social store directory", repair=True)
        except CatalogError as error:
            raise SocialStoreError(str(error)) from error
    return directory


def validate_root(root: Path) -> Path:
    try:
        return validate_directory(root, "social corpus root", repair=False)
    except CatalogError as error:
        raise SocialStoreError(str(error)) from error


def database_path(root: Path) -> Path:
    return root / "index" / "social.db"


def require_checkpointed_database(path: Path) -> None:
    for suffix in SQLITE_MUTABLE_SIDECARS:
        sidecar = path.with_name(f"{path.name}{suffix}")
        if sidecar.exists() or sidecar.is_symlink():
            raise SocialStoreError(
                "social database has active or uncheckpointed journal state"
            )


def connect(root: Path) -> sqlite3.Connection:
    private_directory(root, Path("index"))
    path = database_path(root)
    if path.is_symlink():
        raise SocialStoreError("social database cannot be a symlink")
    connection = sqlite3.connect(str(path), isolation_level=None, timeout=5.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("PRAGMA foreign_keys=ON")
    mode = connection.execute("PRAGMA journal_mode=WAL").fetchone()[0]
    if str(mode).lower() != "wal":
        connection.close()
        raise SocialStoreError("social database could not enable WAL mode")
    connection.execute("PRAGMA synchronous=FULL")
    os.chmod(path, 0o600)
    return connection


def connect_read_only(root: Path) -> sqlite3.Connection:
    try:
        validate_directory(root / "index", "social index directory", repair=False)
        path = database_path(root)
        validate_private_file(path, "social database", repair=False)
    except CatalogError as error:
        raise SocialStoreError(str(error)) from error
    require_checkpointed_database(path)
    connection = sqlite3.connect(
        f"{path.as_uri()}?mode=ro&immutable=1",
        uri=True,
        isolation_level=None,
        timeout=5.0,
    )
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA query_only=ON")
    return connection


def require_schema(connection: sqlite3.Connection) -> None:
    current = connection.execute("PRAGMA user_version").fetchone()[0]
    if current != SCHEMA_VERSION:
        raise SocialStoreError(f"unsupported social schema version: {current}")


def _tables() -> tuple[str, ...]:
    return (
        "CREATE TABLE IF NOT EXISTS schema_meta (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)",
        """CREATE TABLE IF NOT EXISTS connections (
            connection_id TEXT PRIMARY KEY, provider TEXT NOT NULL,
            remote_account_id TEXT NOT NULL, auth_profile_ref TEXT,
            enabled_streams TEXT NOT NULL DEFAULT '[]', policy_json TEXT NOT NULL DEFAULT '{}')""",
        """CREATE TABLE IF NOT EXISTS accounts (
            provider TEXT NOT NULL, remote_id TEXT NOT NULL, handle TEXT,
            display_name TEXT, observed_at TEXT NOT NULL, provider_json TEXT NOT NULL DEFAULT '{}',
            PRIMARY KEY(provider, remote_id))""",
        """CREATE TABLE IF NOT EXISTS objects (
            object_id INTEGER PRIMARY KEY, provider TEXT NOT NULL, object_type TEXT NOT NULL,
            remote_id TEXT NOT NULL, account_remote_id TEXT, text_content TEXT,
            created_at TEXT, observed_at TEXT NOT NULL, evidence_class TEXT NOT NULL,
            provider_json TEXT NOT NULL DEFAULT '{}', batch_id TEXT NOT NULL,
            UNIQUE(provider, object_type, remote_id))""",
        """CREATE TABLE IF NOT EXISTS activities (
            provider TEXT NOT NULL, activity_type TEXT NOT NULL, remote_id TEXT NOT NULL,
            actor_remote_id TEXT NOT NULL, object_remote_id TEXT, occurred_at TEXT,
            observed_at TEXT NOT NULL, state TEXT NOT NULL, provider_json TEXT NOT NULL DEFAULT '{}',
            batch_id TEXT NOT NULL, PRIMARY KEY(provider, activity_type, remote_id))""",
        """CREATE TABLE IF NOT EXISTS media (
            provider TEXT NOT NULL, remote_id TEXT NOT NULL, object_remote_id TEXT,
            content_sha256 TEXT, mime_type TEXT, byte_size INTEGER, blob_ref TEXT,
            hydration_state TEXT NOT NULL, batch_id TEXT NOT NULL,
            PRIMARY KEY(provider, remote_id))""",
        """CREATE TABLE IF NOT EXISTS fetch_batches (
            batch_id TEXT PRIMARY KEY, provider TEXT NOT NULL, connection_id TEXT NOT NULL,
            stream TEXT NOT NULL, request_hash TEXT, response_hash TEXT NOT NULL UNIQUE,
            blob_ref TEXT NOT NULL, resource_count INTEGER NOT NULL, budget_units INTEGER NOT NULL DEFAULT 0,
            started_at TEXT, completed_at TEXT NOT NULL, terminal_status TEXT NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS sync_cursors (
            connection_id TEXT NOT NULL, stream TEXT NOT NULL, cursor TEXT, watermark TEXT,
            last_success_at TEXT, backfill_complete INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(connection_id, stream))""",
        """CREATE TABLE IF NOT EXISTS sync_runs (
            run_id TEXT PRIMARY KEY, connection_id TEXT NOT NULL, status TEXT NOT NULL,
            resource_count INTEGER NOT NULL DEFAULT 0, failure_class TEXT, retry_after TEXT,
            fencing_token INTEGER, diagnostics TEXT, stream TEXT NOT NULL DEFAULT '',
            run_kind TEXT NOT NULL DEFAULT 'sync', collector_id TEXT,
            started_at INTEGER, completed_at INTEGER, request_hash TEXT)""",
        """CREATE TABLE IF NOT EXISTS collector_lease_generations (
            connection_id TEXT PRIMARY KEY, last_token INTEGER NOT NULL
        )""",
        """CREATE TABLE IF NOT EXISTS collector_leases (
            connection_id TEXT PRIMARY KEY, collector_id TEXT NOT NULL,
            fencing_token INTEGER NOT NULL, run_id TEXT NOT NULL,
            acquired_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
        )""",
        """CREATE TABLE IF NOT EXISTS reconciliation_items (
            provider TEXT NOT NULL, connection_id TEXT NOT NULL, stream TEXT NOT NULL,
            item_kind TEXT NOT NULL CHECK(item_kind IN ('object','activity')),
            item_type TEXT NOT NULL, remote_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('present','missing')),
            first_missing_at TEXT, last_observed_at TEXT NOT NULL, run_id TEXT NOT NULL,
            PRIMARY KEY(provider,connection_id,stream,item_kind,item_type,remote_id)
        )""",
        """CREATE TABLE IF NOT EXISTS tombstones (
            provider TEXT NOT NULL, object_type TEXT NOT NULL, remote_id TEXT NOT NULL,
            observed_at TEXT NOT NULL, reason TEXT NOT NULL, retention_action TEXT NOT NULL,
            batch_id TEXT NOT NULL, PRIMARY KEY(provider, object_type, remote_id))""",
        """CREATE TABLE IF NOT EXISTS annotations (
            annotation_id TEXT PRIMARY KEY, object_id INTEGER NOT NULL REFERENCES objects(object_id),
            principal_id TEXT NOT NULL, visibility TEXT NOT NULL, body TEXT NOT NULL,
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
        """CREATE TABLE IF NOT EXISTS coverage_records (
            provider TEXT NOT NULL, connection_id TEXT NOT NULL, stream TEXT NOT NULL,
            earliest_at TEXT, latest_at TEXT, cursor_exhausted INTEGER NOT NULL DEFAULT 0,
            retention_limit TEXT, unavailable_reason TEXT, status TEXT NOT NULL,
            batch_id TEXT NOT NULL, observed_at TEXT NOT NULL,
            PRIMARY KEY(provider, connection_id, stream))""",
        """CREATE TABLE IF NOT EXISTS outbound_operations (
            operation_id TEXT PRIMARY KEY, provider TEXT NOT NULL,
            connection_id TEXT NOT NULL, remote_account_id TEXT NOT NULL,
            action TEXT NOT NULL CHECK(action IN ('post','reply','like','bookmark')),
            target_remote_id TEXT, destination_remote_id TEXT,
            payload TEXT, payload_sha256 TEXT NOT NULL,
            subject TEXT, subject_sha256 TEXT,
            intent_version INTEGER NOT NULL DEFAULT 2 CHECK(intent_version IN (1,2)),
            intent_sha256 TEXT NOT NULL UNIQUE, app_profile TEXT, username TEXT,
            scheduled_at INTEGER NOT NULL, state TEXT NOT NULL
                CHECK(state IN ('draft','approved','claimed','succeeded','failed','unknown','cancelled')),
            created_by TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            claim_token INTEGER NOT NULL DEFAULT 0, claimed_by TEXT, claim_expires_at INTEGER,
            last_attempt_id TEXT,
            CHECK(
                (action='post' AND payload IS NOT NULL AND target_remote_id IS NULL) OR
                (action='reply' AND payload IS NOT NULL AND target_remote_id IS NOT NULL) OR
                (action IN ('like','bookmark') AND payload IS NULL AND target_remote_id IS NOT NULL)
            ))""",
        """CREATE TABLE IF NOT EXISTS outbound_approvals (
            approval_id TEXT PRIMARY KEY,
            operation_id TEXT NOT NULL REFERENCES outbound_operations(operation_id),
            principal_id TEXT NOT NULL, intent_sha256 TEXT NOT NULL,
            approved_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
            revoked_at INTEGER,
            CHECK(expires_at>approved_at),
            CHECK(revoked_at IS NULL OR revoked_at>=approved_at),
            UNIQUE(operation_id, approval_id))""",
        """CREATE TABLE IF NOT EXISTS outbound_attempts (
            attempt_id TEXT PRIMARY KEY,
            operation_id TEXT NOT NULL REFERENCES outbound_operations(operation_id),
            claim_token INTEGER NOT NULL, executor_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('running','succeeded','failed','unknown')),
            started_at INTEGER NOT NULL, provider_started_at INTEGER, finished_at INTEGER,
            provider_remote_id TEXT, failure_class TEXT, diagnostics TEXT,
            CHECK(provider_started_at IS NULL OR provider_started_at>=started_at),
            CHECK((status='running' AND finished_at IS NULL) OR
                  (status!='running' AND finished_at IS NOT NULL)),
            UNIQUE(operation_id, claim_token))""",
        """CREATE TABLE IF NOT EXISTS notification_state (
            notification_id TEXT PRIMARY KEY, principal_id TEXT NOT NULL,
            provider TEXT NOT NULL, connection_id TEXT NOT NULL,
            activity_type TEXT NOT NULL, activity_remote_id TEXT NOT NULL,
            object_remote_id TEXT, actor_remote_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('mention','reply')),
            status TEXT NOT NULL
                CHECK(status IN ('unread','seen','action-required','responded','dismissed')),
            observed_at TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            UNIQUE(principal_id, provider, activity_type, activity_remote_id))""",
        "CREATE INDEX IF NOT EXISTS idx_objects_account ON objects(provider, account_remote_id, created_at)",
        "CREATE INDEX IF NOT EXISTS idx_activities_actor ON activities(provider, actor_remote_id, occurred_at)",
        "CREATE INDEX IF NOT EXISTS idx_coverage_connection ON coverage_records(connection_id, stream)",
        "CREATE INDEX IF NOT EXISTS idx_reconciliation_status ON reconciliation_items(connection_id, stream, status)",
        "CREATE INDEX IF NOT EXISTS idx_outbound_due ON outbound_operations(state,scheduled_at,operation_id)",
        "CREATE INDEX IF NOT EXISTS idx_outbound_approvals ON outbound_approvals(operation_id,expires_at,revoked_at)",
        "CREATE INDEX IF NOT EXISTS idx_notification_status ON notification_state(principal_id,status,updated_at)",
    )


def create_fts(connection: sqlite3.Connection) -> None:
    try:
        connection.execute(
            """CREATE VIRTUAL TABLE IF NOT EXISTS objects_fts USING fts5(
                provider UNINDEXED, object_type UNINDEXED, remote_id UNINDEXED,
                account_remote_id UNINDEXED, text_content, evidence_class UNINDEXED,
                tokenize='unicode61')"""
        )
    except sqlite3.OperationalError as error:
        raise SocialStoreError("SQLite runtime does not provide required FTS5") from error


def _add_sync_run_v2_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(sync_runs)").fetchall()
    }
    if "stream" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN stream TEXT NOT NULL DEFAULT ''"
        )
    if "run_kind" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'sync'"
        )
    if "collector_id" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN collector_id TEXT")
    if "started_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN started_at INTEGER")
    if "completed_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN completed_at INTEGER")
    if "request_hash" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN request_hash TEXT")


def _add_outbound_v4_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(outbound_operations)").fetchall()
    }
    additions = (
        (
            "destination_remote_id",
            "ALTER TABLE outbound_operations ADD COLUMN destination_remote_id TEXT",
        ),
        ("subject", "ALTER TABLE outbound_operations ADD COLUMN subject TEXT"),
        (
            "subject_sha256",
            "ALTER TABLE outbound_operations ADD COLUMN subject_sha256 TEXT",
        ),
        (
            "intent_version",
            "ALTER TABLE outbound_operations ADD COLUMN "
            "intent_version INTEGER NOT NULL DEFAULT 1",
        ),
    )
    for column, statement in additions:
        if column not in columns:
            connection.execute(statement)


def migrate(connection: sqlite3.Connection) -> None:
    current = connection.execute("PRAGMA user_version").fetchone()[0]
    if current < 0 or current > SCHEMA_VERSION:
        raise SocialStoreError(f"unsupported social schema version: {current}")
    connection.execute("BEGIN IMMEDIATE")
    try:
        for statement in _tables():
            connection.execute(statement)
        if current < 2:
            _add_sync_run_v2_columns(connection)
        if current < 4:
            _add_outbound_v4_columns(connection)
        connection.execute(
            "CREATE INDEX IF NOT EXISTS idx_sync_runs_connection "
            "ON sync_runs(connection_id,stream,run_kind,started_at)"
        )
        create_fts(connection)
        for version in range(1, SCHEMA_VERSION + 1):
            connection.execute(
                "INSERT OR IGNORE INTO schema_meta(version,applied_at) "
                "VALUES(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
                (version,),
            )
        connection.execute(SCHEMA_VERSION_SQL)
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise


def rebuild_fts(connection: sqlite3.Connection) -> None:
    connection.execute("BEGIN IMMEDIATE")
    try:
        connection.execute("DROP TABLE IF EXISTS objects_fts")
        create_fts(connection)
        connection.execute(
            """INSERT INTO objects_fts(
                provider,object_type,remote_id,account_remote_id,text_content,evidence_class)
               SELECT provider,object_type,remote_id,account_remote_id,text_content,evidence_class
                 FROM objects ORDER BY object_id"""
        )
        connection.execute("COMMIT")
    except Exception:
        connection.execute("ROLLBACK")
        raise


def validate_opaque(value: str, field: str) -> str:
    if not OPAQUE_ID.fullmatch(value):
        raise SocialStoreError(f"{field} must be an opaque identifier")
    return value


def write_raw_batch(root: Path, provider: str, connection_id: str, payload: bytes) -> tuple[str, str]:
    provider = validate_opaque(provider, "provider")
    connection_id = validate_opaque(connection_id, "connection_id")
    digest = hashlib.sha256(payload).hexdigest()
    directory = private_directory(
        root, Path("sources") / "social" / "raw" / provider / connection_id
    )
    path = directory / f"{digest}.json.gz"
    relative = path.relative_to(root).as_posix()
    if path.exists():
        if path.is_symlink():
            raise SocialStoreError("raw batch cannot be a symlink")
        with gzip.open(path, "rb") as existing:
            if hashlib.sha256(existing.read()).hexdigest() != digest:
                raise SocialStoreError("immutable raw batch hash mismatch")
        return digest, relative
    compressed = gzip.compress(payload, compresslevel=9, mtime=0)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        target = os.fdopen(descriptor, "wb")
        descriptor = -1
        with target:
            target.write(compressed)
            target.flush()
            os.fsync(target.fileno())
    except Exception:
        path.unlink(missing_ok=True)
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest, relative
