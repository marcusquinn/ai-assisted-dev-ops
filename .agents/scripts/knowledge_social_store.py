#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private per-corpus social schema and immutable raw-batch storage.

Every production fetch-batch writer commits through ``raw_evidence_transaction``:
the matching immutable raw file and its parent entry become durable before the
SQLite row, while stale unreferenced evidence is reclaimed only after a lease
boundary. This ordering is the store's cross-filesystem crash invariant.
"""

from __future__ import annotations

import os
import sqlite3
from pathlib import Path

from _knowledge_social_store_migration import (
    migrate_fetch_batches_v6 as _migrate_fetch_batches_v6,
    recover_orphaned_fetch_batches_v6 as _recover_orphaned_fetch_batches_v6,
)
from _knowledge_social_store_schema import (
    add_outbound_v4_columns as _add_outbound_v4_columns,
    add_source_v5_columns as _add_source_v5_columns,
    add_sync_run_v2_columns as _add_sync_run_v2_columns,
)
from _knowledge_social_store_raw_write import (
    RawEvidenceTransaction,
    private_directory,
    raw_evidence_transaction,
    validate_opaque,
    write_raw_batch,
)
from _knowledge_social_store_raw_recovery import recover_raw_evidence
from _knowledge_social_store_support import (
    SocialStoreError,
)
from knowledge_corpus_context import (
    CatalogError,
    validate_directory,
    validate_private_file,
)

SCHEMA_VERSION = 6
SCHEMA_VERSION_SQL = "PRAGMA user_version=6"
SQLITE_MUTABLE_SIDECARS = ("-journal", "-shm", "-wal")


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
        """CREATE TABLE IF NOT EXISTS corpus_contract (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            corpus_id TEXT NOT NULL UNIQUE, contract_version INTEGER NOT NULL CHECK(contract_version=1))""",
        """CREATE TABLE IF NOT EXISTS evidence_sources (
            evidence_id TEXT PRIMARY KEY, corpus_id TEXT NOT NULL,
            connector_id TEXT NOT NULL, content_sha256 TEXT NOT NULL,
            authority TEXT NOT NULL CHECK(authority='raw'), raw_ref TEXT NOT NULL,
            observed_at TEXT NOT NULL, provenance_json TEXT NOT NULL DEFAULT '{}',
            UNIQUE(corpus_id,connector_id,content_sha256))""",
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
            stream TEXT NOT NULL, request_hash TEXT, response_hash TEXT NOT NULL,
            blob_ref TEXT NOT NULL, resource_count INTEGER NOT NULL, budget_units INTEGER NOT NULL DEFAULT 0,
            started_at TEXT, completed_at TEXT NOT NULL, terminal_status TEXT NOT NULL,
            evidence_id TEXT REFERENCES evidence_sources(evidence_id))""",
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


def _migrate_source_contract(connection: sqlite3.Connection) -> None:
    connection.execute(
        "INSERT OR IGNORE INTO corpus_contract(singleton,corpus_id,contract_version) "
        "VALUES(1,'cor_' || lower(hex(randomblob(16))),1)"
    )
    connection.execute(
        """INSERT OR IGNORE INTO evidence_sources(
               evidence_id,corpus_id,connector_id,content_sha256,authority,
               raw_ref,observed_at,provenance_json)
           SELECT 'ev1:' || c.corpus_id || ':' || f.connection_id || ':sha256:' ||
                   f.batch_id,
                   c.corpus_id,f.connection_id,f.batch_id,'raw',f.blob_ref,
                   f.completed_at,json_object('provider',f.provider,'stream',f.stream)
              FROM fetch_batches f CROSS JOIN corpus_contract c"""
    )
    connection.execute(
        """UPDATE fetch_batches
              SET evidence_id='ev1:' || (SELECT corpus_id FROM corpus_contract WHERE singleton=1)
                              || ':' || connection_id || ':sha256:' || batch_id
            WHERE evidence_id IS NULL"""
    )
    connection.execute(
        """DELETE FROM evidence_sources
             WHERE NOT EXISTS (
                   SELECT 1 FROM fetch_batches f
                    WHERE f.evidence_id=evidence_sources.evidence_id)"""
    )
    connection.execute(
        """CREATE TRIGGER IF NOT EXISTS fetch_batch_evidence_ai
           AFTER INSERT ON fetch_batches WHEN NEW.evidence_id IS NULL
           BEGIN
             INSERT OR IGNORE INTO evidence_sources(
               evidence_id,corpus_id,connector_id,content_sha256,authority,
               raw_ref,observed_at,provenance_json)
              SELECT 'ev1:' || corpus_id || ':' || NEW.connection_id || ':sha256:' ||
                     NEW.batch_id,
                     corpus_id,NEW.connection_id,NEW.batch_id,'raw',NEW.blob_ref,
                     NEW.completed_at,json_object('provider',NEW.provider,'stream',NEW.stream)
               FROM corpus_contract WHERE singleton=1;
             UPDATE fetch_batches
                SET evidence_id='ev1:' ||
                     (SELECT corpus_id FROM corpus_contract WHERE singleton=1) || ':' ||
                     NEW.connection_id || ':sha256:' || NEW.batch_id
               WHERE batch_id=NEW.batch_id;
           END"""
    )
    connection.execute("DROP VIEW IF EXISTS canonical_evidence_projections")
    connection.execute(
        """CREATE VIEW canonical_evidence_projections AS
           SELECT 'object' AS projection_kind,
                  'pr1:' || f.evidence_id || ':object:' || o.object_type || ':' || o.remote_id
                    AS projection_id,
                  f.evidence_id,o.batch_id,o.provider,o.remote_id
             FROM objects o JOIN fetch_batches f ON f.batch_id=o.batch_id
           UNION ALL
           SELECT 'activity',
                  'pr1:' || f.evidence_id || ':activity:' || a.activity_type || ':' || a.remote_id,
                  f.evidence_id,a.batch_id,a.provider,a.remote_id
             FROM activities a JOIN fetch_batches f ON f.batch_id=a.batch_id
           UNION ALL
           SELECT 'media','pr1:' || f.evidence_id || ':media:' || m.remote_id,
                  f.evidence_id,m.batch_id,m.provider,m.remote_id
             FROM media m JOIN fetch_batches f ON f.batch_id=m.batch_id"""
    )


def migrate(connection: sqlite3.Connection) -> None:
    current = connection.execute("PRAGMA user_version").fetchone()[0]
    if current not in range(SCHEMA_VERSION + 1):
        raise SocialStoreError(f"unsupported social schema version: {current}")
    connection.execute("BEGIN IMMEDIATE")
    try:
        _add_source_v5_columns(connection)
        for statement in _tables():
            connection.execute(statement)
        _add_sync_run_v2_columns(connection)
        _add_outbound_v4_columns(connection)
        if current in range(1, SCHEMA_VERSION):
            _migrate_fetch_batches_v6(connection)
            _recover_orphaned_fetch_batches_v6(connection)
        _migrate_source_contract(connection)
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
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    recover_raw_evidence(connection, verify_referenced=False)


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
