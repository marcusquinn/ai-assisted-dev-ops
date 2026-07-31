#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private per-corpus social schema and immutable raw-batch storage."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import sqlite3
from pathlib import Path

from knowledge_corpus_context import (
    CatalogError,
    validate_directory,
    validate_private_file,
)

SCHEMA_VERSION = 6
SCHEMA_VERSION_SQL = "PRAGMA user_version=6"
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
SQLITE_MUTABLE_SIDECARS = ("-journal", "-shm", "-wal")
MAX_RAW_BATCH_BYTES = 64 * 1024 * 1024
COLLECTOR_ENVELOPE_FIELDS = frozenset(
    {
        "provider",
        "connection_id",
        "stream",
        "observed_at",
        "request_hash",
        "response_sha256",
        "response",
    }
)
INVALID_RAW_PATH = "legacy social raw evidence path is invalid"
INVALID_RAW_METADATA = "legacy social raw evidence metadata is invalid"


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


def _add_source_v5_columns(connection: sqlite3.Connection) -> None:
    table = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fetch_batches'"
    ).fetchone()
    if table is None:
        return
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(fetch_batches)").fetchall()
    }
    if "evidence_id" not in columns:
        connection.execute(
            "ALTER TABLE fetch_batches ADD COLUMN evidence_id TEXT "
            "REFERENCES evidence_sources(evidence_id)"
        )


def _store_root(connection: sqlite3.Connection) -> Path:
    database_rows = connection.execute("PRAGMA database_list").fetchall()
    database_file = next(
        (str(row["file"]) for row in database_rows if row["name"] == "main"), ""
    )
    if not database_file:
        raise SocialStoreError("legacy social data requires a file-backed store")
    return Path(database_file).resolve(strict=True).parent.parent


def _validated_raw_ref(blob_ref: str) -> tuple[Path, str, str, str]:
    relative = Path(blob_ref)
    if relative.is_absolute():
        raise SocialStoreError(INVALID_RAW_PATH)
    if len(relative.parts) != 6:
        raise SocialStoreError(INVALID_RAW_PATH)
    prefix, provider, connection_id, filename = (
        relative.parts[:3],
        relative.parts[3],
        relative.parts[4],
        relative.parts[5],
    )
    if prefix != ("sources", "social", "raw"):
        raise SocialStoreError(INVALID_RAW_PATH)
    if OPAQUE_ID.fullmatch(provider) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    if OPAQUE_ID.fullmatch(connection_id) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    if re.fullmatch(r"[0-9a-f]{64}\.json\.gz", filename) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    return relative, provider, connection_id, filename


def _read_private_raw_file(root: Path, relative: Path) -> bytes:
    raw_root = root / "sources" / "social" / "raw"
    path = root / relative
    try:
        resolved = path.resolve(strict=True)
        if resolved != Path(os.path.abspath(path)):
            raise SocialStoreError("legacy social raw evidence contains a symlink")
        resolved.relative_to(raw_root.resolve(strict=True))
        validate_directory(path.parent.parent, "social provider directory", repair=False)
        validate_directory(path.parent, "social connection directory", repair=False)
        validate_private_file(path, "legacy social raw evidence", repair=False)
        with gzip.open(path, "rb") as source:
            payload = source.read(MAX_RAW_BATCH_BYTES + 1)
    except (CatalogError, OSError, EOFError, ValueError) as error:
        raise SocialStoreError("legacy social raw evidence is unsafe") from error
    if len(payload) > MAX_RAW_BATCH_BYTES:
        raise SocialStoreError("legacy social raw evidence exceeds the size limit")
    return payload


def _read_raw_payload(
    connection: sqlite3.Connection, blob_ref: str
) -> tuple[bytes, str, str, str]:
    relative, provider, connection_id, filename = _validated_raw_ref(blob_ref)
    payload = _read_private_raw_file(_store_root(connection), relative)
    digest = hashlib.sha256(payload).hexdigest()
    if filename != f"{digest}.json.gz":
        raise SocialStoreError("legacy social raw evidence hash does not match")
    return payload, digest, provider, connection_id


def _decoded_collector_envelope(payload: bytes) -> dict[str, object] | None:
    try:
        envelope = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(envelope, dict):
        return None
    if set(envelope) != COLLECTOR_ENVELOPE_FIELDS:
        return None
    return envelope


def _validate_collector_scope(
    envelope: dict[str, object], payload: bytes, provider: str, connection_id: str
) -> None:
    canonical = json.dumps(
        envelope, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if canonical != payload:
        raise SocialStoreError(INVALID_RAW_METADATA)
    if envelope["provider"] != provider:
        raise SocialStoreError(INVALID_RAW_METADATA)
    if envelope["connection_id"] != connection_id:
        raise SocialStoreError(INVALID_RAW_METADATA)


def _validate_collector_fields(envelope: dict[str, object]) -> None:
    for field in ("stream", "observed_at"):
        value = envelope[field]
        if not isinstance(value, str) or not value:
            raise SocialStoreError(INVALID_RAW_METADATA)
    for field in ("request_hash", "response_sha256"):
        value = envelope[field]
        if not isinstance(value, str) or SHA256_HEX.fullmatch(value) is None:
            raise SocialStoreError(INVALID_RAW_METADATA)


def _validate_collector_response(envelope: dict[str, object]) -> None:
    response_hash = str(envelope["response_sha256"])
    response = json.dumps(
        envelope["response"], ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if hashlib.sha256(response).hexdigest() != response_hash:
        raise SocialStoreError("legacy social response hash does not match")


def _validate_collector_envelope(
    envelope: dict[str, object], payload: bytes, provider: str, connection_id: str
) -> None:
    _validate_collector_scope(envelope, payload, provider, connection_id)
    _validate_collector_fields(envelope)
    _validate_collector_response(envelope)


def _collector_envelope(
    payload: bytes, provider: str, connection_id: str, *, required: bool
) -> dict[str, object] | None:
    envelope = _decoded_collector_envelope(payload)
    if envelope is None:
        if not required:
            return None
        raise SocialStoreError(INVALID_RAW_METADATA)
    _validate_collector_envelope(envelope, payload, provider, connection_id)
    return envelope


def _canonical_fetch_identity_v6(
    connection: sqlite3.Connection, row: sqlite3.Row
) -> tuple[str, str]:
    payload, digest, provider, connection_id = _read_raw_payload(
        connection, str(row["blob_ref"])
    )
    envelope = _collector_envelope(
        payload, provider, connection_id, required=False
    )
    if envelope is None:
        if str(row["batch_id"]) != digest:
            raise SocialStoreError("legacy fetch batch raw identity cannot be migrated")
        return digest, str(row["response_hash"])
    stored_scope = (
        row["provider"],
        row["connection_id"],
        row["stream"],
        row["request_hash"],
        row["completed_at"],
    )
    raw_scope = (
        provider,
        connection_id,
        envelope["stream"],
        envelope["request_hash"],
        envelope["observed_at"],
    )
    if stored_scope != raw_scope:
        raise SocialStoreError("legacy fetch batch metadata conflicts with raw evidence")
    return digest, str(envelope["response_sha256"])


def _canonical_fetch_rows_v6(
    connection: sqlite3.Connection,
) -> list[tuple[sqlite3.Row, str, str]]:
    rows = connection.execute("SELECT * FROM fetch_batches ORDER BY batch_id").fetchall()
    return [
        (row, *_canonical_fetch_identity_v6(connection, row)) for row in rows
    ]


def _deduplicate_fetch_rows_v6(
    migrated: list[tuple[sqlite3.Row, str, str]],
) -> dict[str, tuple[sqlite3.Row, str]]:
    metadata_fields = (
        "provider",
        "connection_id",
        "stream",
        "request_hash",
        "blob_ref",
        "resource_count",
        "budget_units",
        "started_at",
        "completed_at",
        "terminal_status",
    )
    canonical: dict[str, tuple[sqlite3.Row, str]] = {}
    signatures: dict[str, tuple[object, ...]] = {}
    for row, batch_id, response_hash in migrated:
        metadata = tuple(row[field] for field in metadata_fields) + (response_hash,)
        existing = signatures.setdefault(batch_id, metadata)
        if existing != metadata:
            raise SocialStoreError("legacy fetch batch aliases have conflicting metadata")
        canonical.setdefault(batch_id, (row, response_hash))
    return canonical


def _create_fetch_batches_v6(
    connection: sqlite3.Connection,
    canonical: dict[str, tuple[sqlite3.Row, str]],
) -> None:
    connection.execute(
        """CREATE TABLE fetch_batches_v6 (
             batch_id TEXT PRIMARY KEY, provider TEXT NOT NULL,
             connection_id TEXT NOT NULL, stream TEXT NOT NULL,
             request_hash TEXT, response_hash TEXT NOT NULL, blob_ref TEXT NOT NULL,
             resource_count INTEGER NOT NULL, budget_units INTEGER NOT NULL DEFAULT 0,
             started_at TEXT, completed_at TEXT NOT NULL, terminal_status TEXT NOT NULL,
             evidence_id TEXT REFERENCES evidence_sources(evidence_id))"""
    )
    connection.executemany(
        """INSERT INTO fetch_batches_v6(
             batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
             resource_count,budget_units,started_at,completed_at,terminal_status,evidence_id)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)""",
        [
            (
                batch_id,
                row["provider"],
                row["connection_id"],
                row["stream"],
                row["request_hash"],
                response_hash,
                row["blob_ref"],
                row["resource_count"],
                row["budget_units"],
                row["started_at"],
                row["completed_at"],
                row["terminal_status"],
            )
            for batch_id, (row, response_hash) in sorted(canonical.items())
        ],
    )


def _rewrite_projection_aliases_v6(
    connection: sqlite3.Connection,
    migrated: list[tuple[sqlite3.Row, str, str]],
) -> None:
    aliases = [
        (batch_id, row["batch_id"])
        for row, batch_id, _ in migrated
        if row["batch_id"] != batch_id
    ]
    for statement in (
        "UPDATE objects SET batch_id=? WHERE batch_id=?",
        "UPDATE activities SET batch_id=? WHERE batch_id=?",
        "UPDATE media SET batch_id=? WHERE batch_id=?",
        "UPDATE coverage_records SET batch_id=? WHERE batch_id=?",
        "UPDATE tombstones SET batch_id=? WHERE batch_id=?",
    ):
        connection.executemany(statement, aliases)


def _migrate_fetch_batches_v6(connection: sqlite3.Connection) -> None:
    """Make raw-envelope hashes canonical batch IDs without body-hash uniqueness."""
    connection.execute("DROP TRIGGER IF EXISTS fetch_batch_evidence_ai")
    connection.execute("DROP VIEW IF EXISTS canonical_evidence_projections")
    migrated = _canonical_fetch_rows_v6(connection)
    _create_fetch_batches_v6(connection, _deduplicate_fetch_rows_v6(migrated))
    connection.execute("DROP TABLE fetch_batches")
    connection.execute("ALTER TABLE fetch_batches_v6 RENAME TO fetch_batches")
    _rewrite_projection_aliases_v6(connection, migrated)


def _orphan_projection_batch_ids(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        """SELECT p.batch_id FROM (
             SELECT batch_id FROM objects UNION SELECT batch_id FROM activities
             UNION SELECT batch_id FROM media UNION SELECT batch_id FROM coverage_records
             UNION SELECT batch_id FROM tombstones
           ) p LEFT JOIN fetch_batches f ON f.batch_id=p.batch_id
           WHERE f.batch_id IS NULL ORDER BY p.batch_id"""
    ).fetchall()
    return [str(row["batch_id"]) for row in rows]


def _raw_envelope_for_batch(
    connection: sqlite3.Connection, batch_id: str
) -> tuple[dict[str, object], str]:
    if re.fullmatch(r"[0-9a-f]{64}", batch_id) is None:
        raise SocialStoreError("legacy social projection has an invalid batch ID")
    root = _store_root(connection)
    raw_root = root / "sources" / "social" / "raw"
    candidates = list(raw_root.glob(f"*/*/{batch_id}.json.gz"))
    if len(candidates) != 1:
        raise SocialStoreError(
            "legacy social projection raw evidence is missing or ambiguous"
        )
    blob_ref = candidates[0].relative_to(root).as_posix()
    payload, digest, provider, connection_id = _read_raw_payload(
        connection, blob_ref
    )
    if digest != batch_id:
        raise SocialStoreError("legacy social raw evidence hash does not match")
    envelope = _collector_envelope(
        payload, provider, connection_id, required=True
    )
    if envelope is None:
        raise SocialStoreError("legacy social raw evidence envelope is invalid")
    return envelope, blob_ref


def _recover_orphaned_fetch_batches_v6(connection: sqlite3.Connection) -> None:
    for batch_id in _orphan_projection_batch_ids(connection):
        envelope, blob_ref = _raw_envelope_for_batch(connection, batch_id)
        resource_count = connection.execute(
            """SELECT (SELECT count(*) FROM objects WHERE batch_id=?) +
                      (SELECT count(*) FROM activities WHERE batch_id=?) +
                      (SELECT count(*) FROM media WHERE batch_id=?)""",
            (batch_id, batch_id, batch_id),
        ).fetchone()[0]
        connection.execute(
            """INSERT INTO fetch_batches(
                 batch_id,provider,connection_id,stream,request_hash,response_hash,
                 blob_ref,resource_count,budget_units,started_at,completed_at,
                 terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                batch_id,
                envelope["provider"],
                envelope["connection_id"],
                envelope["stream"],
                envelope["request_hash"],
                envelope["response_sha256"],
                blob_ref,
                resource_count,
                0,
                envelope["observed_at"],
                envelope["observed_at"],
                "legacy_recovered",
            ),
        )


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
    if current < 0 or current > SCHEMA_VERSION:
        raise SocialStoreError(f"unsupported social schema version: {current}")
    connection.execute("BEGIN IMMEDIATE")
    try:
        if current < 5:
            _add_source_v5_columns(connection)
        for statement in _tables():
            connection.execute(statement)
        if current < 2:
            _add_sync_run_v2_columns(connection)
        if current < 4:
            _add_outbound_v4_columns(connection)
        if 0 < current < 6:
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
