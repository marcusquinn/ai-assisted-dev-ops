#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provisioning and SQLite schema for the marketing performance plane."""

from __future__ import annotations

import json
import os
import secrets
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from performance_contract import PerformanceContractError

STORE_SCHEMA_VERSION = 2
CONFIG_SCHEMA = "aidevops.marketing-performance-config/v1"
PERFORMANCE_GITIGNORE = """# Private/local performance-plane state
raw/
exports/
index/
quarantine/
marketing/raw/
marketing/exports/
marketing/index/
marketing/quarantine/
marketing/leases/

# Explicit public-safe projections and configuration remain versionable
!marketing/summaries/
!marketing/summaries/**
!marketing/_config/
!marketing/_config/**
"""
MARKETING_README = """# Marketing performance

Provisioned normalized marketing outcome plane. Raw evidence, the local index,
quarantine references, and explicit exports are gitignored. Only generated
campaign summaries and non-secret configuration are versionable.

Use `aidevops performance status --json` for source coverage and freshness.
"""


@dataclass(frozen=True)
class PlanePaths:
    """Resolved performance plane paths for one repository."""

    repo: Path
    plane: Path
    marketing: Path
    config_dir: Path
    config: Path
    raw: Path
    index: Path
    exports: Path
    quarantine: Path
    summaries: Path
    database: Path


def resolve_paths(repo: Path) -> PlanePaths:
    """Resolve but do not provision one repository-local plane."""
    resolved = repo.expanduser().resolve()
    if not resolved.is_dir():
        raise PerformanceContractError("repository path must be an existing directory")
    plane = resolved / "_performance"
    marketing = plane / "marketing"
    return PlanePaths(
        repo=resolved,
        plane=plane,
        marketing=marketing,
        config_dir=marketing / "_config",
        config=marketing / "_config" / "plane.json",
        raw=marketing / "raw",
        index=marketing / "index",
        exports=marketing / "exports",
        quarantine=marketing / "quarantine",
        summaries=marketing / "summaries",
        database=marketing / "index" / "performance.sqlite",
    )


def _write_new(path: Path, content: bytes, mode: int) -> None:
    """Create one file atomically without replacing user-owned state."""
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise PerformanceContractError(f"performance plane file is unsafe: {path.name}")
    if path.exists():
        return
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise PerformanceContractError(f"performance plane file is unsafe: {path.name}")
        if path.exists():
            temporary.unlink()
            return
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _ensure_directory(path: Path, mode: int | None = None) -> None:
    """Create one repository-local directory without following a symlink."""
    if path.is_symlink():
        raise PerformanceContractError(f"performance plane directory is unsafe: {path.name}")
    path.mkdir(parents=False, exist_ok=True, mode=mode or 0o777)
    if path.is_symlink() or not path.is_dir():
        raise PerformanceContractError(f"performance plane directory is unsafe: {path.name}")
    if mode is not None:
        os.chmod(path, mode)


def _reject_symlink_components(*paths: Path) -> None:
    """Reject symlinks at each repository-local plane component."""
    if any(path.is_symlink() for path in paths):
        raise PerformanceContractError("performance plane path contains a symlink")


def _template_config() -> dict[str, Any]:
    template = Path(__file__).resolve().parent.parent / "configs" / "marketing-performance.json.txt"
    try:
        document = json.loads(template.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PerformanceContractError("marketing performance config template is unavailable") from exc
    return validate_config(document)


def validate_config(document: Any) -> dict[str, Any]:
    """Validate bounded deterministic plane settings."""
    if not isinstance(document, dict) or document.get("schema") != CONFIG_SCHEMA:
        raise PerformanceContractError("unsupported marketing performance config schema")
    if document.get("schema_version") != 1:
        raise PerformanceContractError("unsupported marketing performance config version")
    for field in ("default_stale_after_seconds", "lease_seconds", "max_batch_events"):
        value = document.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or value < 1:
            raise PerformanceContractError(f"config {field} must be a positive integer")
    stale = document.get("source_stale_after_seconds")
    if not isinstance(stale, dict):
        raise PerformanceContractError("config source_stale_after_seconds must be an object")
    for source, seconds in stale.items():
        if not isinstance(source, str) or not isinstance(seconds, int) or isinstance(seconds, bool) or seconds < 1:
            raise PerformanceContractError("config source freshness entries are invalid")
    fixtures = document.get("fixture_only_adapters")
    if not isinstance(fixtures, list) or not all(isinstance(item, str) for item in fixtures):
        raise PerformanceContractError("config fixture_only_adapters must be an array")
    return document


def provision_plane(paths: PlanePaths) -> dict[str, Any]:
    """Idempotently provision public and private marketing directories."""
    _ensure_directory(paths.plane)
    _ensure_directory(paths.marketing)
    _ensure_directory(paths.config_dir)
    _ensure_directory(paths.summaries)
    for private_dir in (paths.raw, paths.index, paths.exports, paths.quarantine):
        _ensure_directory(private_dir, 0o700)
    _write_new(paths.plane / ".gitignore", PERFORMANCE_GITIGNORE.encode("utf-8"), 0o644)
    _write_new(paths.marketing / "README.md", MARKETING_README.encode("utf-8"), 0o644)
    if not paths.config.exists():
        config = _template_config()
        payload = (json.dumps(config, indent=2, sort_keys=True) + "\n").encode("utf-8")
        _write_new(paths.config, payload, 0o644)
    return load_config(paths)


def load_config(paths: PlanePaths) -> dict[str, Any]:
    """Load the existing versioned plane config without implicit migration."""
    _reject_symlink_components(
        paths.plane,
        paths.marketing,
        paths.config_dir,
        paths.config,
    )
    if paths.config.is_symlink() or (paths.config.exists() and not paths.config.is_file()):
        raise PerformanceContractError("marketing performance config path is unsafe")
    try:
        document = json.loads(paths.config.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise PerformanceContractError("performance plane is not initialized") from exc
    except json.JSONDecodeError as exc:
        raise PerformanceContractError("marketing performance config is invalid JSON") from exc
    return validate_config(document)


def connect_database(
    paths: PlanePaths,
    *,
    create: bool = False,
) -> sqlite3.Connection:
    """Open and migrate one private projection database."""
    _reject_symlink_components(
        paths.plane,
        paths.marketing,
        paths.index,
        paths.database,
    )
    if not paths.index.exists() and not create:
        raise PerformanceContractError("marketing performance database is missing")
    _ensure_directory(paths.index, 0o700)
    if paths.database.is_symlink() or (
        paths.database.exists() and not paths.database.is_file()
    ):
        raise PerformanceContractError("marketing performance database path is unsafe")
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = paths.database.with_name(paths.database.name + suffix)
        if sidecar.is_symlink() or (sidecar.exists() and not sidecar.is_file()):
            raise PerformanceContractError(
                "marketing performance database sidecar path is unsafe"
            )
    database_exists = paths.database.exists()
    if not database_exists and not create:
        raise PerformanceContractError("marketing performance database is missing")
    connection = sqlite3.connect(paths.database, timeout=10)
    try:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=10000")
        integrity = connection.execute("PRAGMA quick_check").fetchone()
        if integrity is None or str(integrity[0]) != "ok":
            raise PerformanceContractError("marketing performance database is corrupt")
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("PRAGMA synchronous=FULL")
        initialize = create and not database_exists
        migrate(connection, initialize=initialize)
        salt = connection.execute(
            "SELECT 1 FROM metadata WHERE key='subject_hmac_salt'"
        ).fetchone()
        if salt is None and not initialize:
            raise PerformanceContractError(
                "performance store is missing pseudonymization metadata"
            )
        if salt is None:
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES('subject_hmac_salt',?)",
                (secrets.token_hex(32),),
            )
            connection.commit()
        os.chmod(paths.database, 0o600)
        return connection
    except Exception:
        connection.close()
        raise


def migrate(
    connection: sqlite3.Connection,
    *,
    initialize: bool = False,
) -> None:
    """Apply additive store migrations or reject future stores."""
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version > STORE_SCHEMA_VERSION:
        raise PerformanceContractError("performance store schema is newer than this runtime")
    if version == STORE_SCHEMA_VERSION:
        return
    if version == 1:
        connection.execute("BEGIN IMMEDIATE")
        try:
            columns = {
                str(row["name"])
                for row in connection.execute("PRAGMA table_info(events)")
            }
            if "period_start" not in columns:
                connection.execute("ALTER TABLE events ADD COLUMN period_start TEXT")
            if "period_end" not in columns:
                connection.execute("ALTER TABLE events ADD COLUMN period_end TEXT")
            if "dimensions_json" not in columns:
                connection.execute(
                    "ALTER TABLE events ADD COLUMN dimensions_json TEXT NOT NULL DEFAULT '{}'"
                )
            if "source_observed_at" not in columns:
                connection.execute(
                    "ALTER TABLE events ADD COLUMN source_observed_at TEXT"
                )
            if "source_recorded_at" not in columns:
                connection.execute(
                    "ALTER TABLE events ADD COLUMN source_recorded_at TEXT"
                )
            connection.execute("PRAGMA user_version=2")
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        return
    if version != 0:
        raise PerformanceContractError("unsupported performance store migration path")
    if not initialize:
        raise PerformanceContractError(
            "performance store schema is uninitialized or corrupt"
        )
    connection.executescript(
        """
        BEGIN IMMEDIATE;
        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE sources (
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            adapter TEXT NOT NULL,
            status TEXT NOT NULL,
            coverage TEXT NOT NULL,
            missing_scopes_json TEXT NOT NULL,
            cursor_ref TEXT,
            last_observed_at TEXT,
            last_success_at TEXT,
            last_evidence_ref TEXT,
            stale_after_seconds INTEGER NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY(source, account_ref)
        );
        CREATE TABLE leases (
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            token TEXT NOT NULL,
            acquired_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL,
            PRIMARY KEY(source, account_ref)
        );
        CREATE TABLE evidence (
            evidence_ref TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            recorded_at TEXT NOT NULL
        );
        CREATE TABLE events (
            record_ref TEXT PRIMARY KEY,
            event_ref TEXT NOT NULL,
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            revision INTEGER NOT NULL,
            correction_ref TEXT,
            event_type TEXT NOT NULL,
            occurred_at TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            recorded_at TEXT NOT NULL,
            source_observed_at TEXT,
            source_recorded_at TEXT,
            subject_id TEXT,
            subject_kind TEXT NOT NULL,
            identity_state TEXT NOT NULL,
            campaign_id TEXT,
            channel TEXT,
            creative_id TEXT,
            touchpoint_id TEXT,
            outcome_id TEXT,
            dimensions_json TEXT NOT NULL,
            metric_id TEXT NOT NULL,
            value_text TEXT NOT NULL,
            unit TEXT NOT NULL,
            aggregation TEXT NOT NULL,
            currency TEXT,
            period_start TEXT,
            period_end TEXT,
            confidence TEXT NOT NULL,
            completeness TEXT NOT NULL,
            source_type TEXT NOT NULL,
            collected_by TEXT NOT NULL,
            evidence_ref TEXT NOT NULL REFERENCES evidence(evidence_ref),
            payload_fingerprint TEXT NOT NULL,
            UNIQUE(source, account_ref, event_ref, revision)
        );
        CREATE INDEX events_source_account_idx ON events(source, account_ref, occurred_at);
        CREATE INDEX events_subject_idx ON events(subject_id, occurred_at);
        CREATE TABLE consent_ledger (
            ledger_ref TEXT PRIMARY KEY,
            subject_id TEXT NOT NULL,
            purpose TEXT NOT NULL,
            state TEXT NOT NULL,
            lawful_basis TEXT,
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            effective_at TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            evidence_ref TEXT NOT NULL REFERENCES evidence(evidence_ref)
        );
        CREATE INDEX consent_subject_idx ON consent_ledger(subject_id, purpose, effective_at);
        CREATE TABLE suppression_ledger (
            ledger_ref TEXT PRIMARY KEY,
            subject_id TEXT NOT NULL,
            state TEXT NOT NULL,
            reason TEXT,
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            effective_at TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            evidence_ref TEXT NOT NULL REFERENCES evidence(evidence_ref)
        );
        CREATE INDEX suppression_subject_idx ON suppression_ledger(subject_id, effective_at);
        CREATE TABLE quarantine (
            quarantine_ref TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            account_ref TEXT NOT NULL,
            source_event_ref TEXT NOT NULL,
            reason TEXT NOT NULL,
            evidence_ref TEXT NOT NULL REFERENCES evidence(evidence_ref),
            recorded_at TEXT NOT NULL,
            details_json TEXT NOT NULL
        );
        CREATE TABLE reconciliations (
            reconciliation_ref TEXT PRIMARY KEY,
            action TEXT NOT NULL,
            target_ref TEXT NOT NULL,
            resolution TEXT NOT NULL,
            evidence_ref TEXT NOT NULL,
            effective_at TEXT NOT NULL,
            recorded_at TEXT NOT NULL,
            payload_json TEXT NOT NULL
        );
        CREATE TABLE identity_links (
            link_ref TEXT PRIMARY KEY,
            action TEXT NOT NULL,
            canonical_subject_id TEXT NOT NULL,
            member_subject_id TEXT NOT NULL,
            evidence_ref TEXT NOT NULL,
            effective_at TEXT NOT NULL,
            recorded_at TEXT NOT NULL
        );
        CREATE INDEX identity_member_idx ON identity_links(member_subject_id, effective_at);
        CREATE TRIGGER evidence_no_update BEFORE UPDATE ON evidence BEGIN SELECT RAISE(ABORT, 'evidence is immutable'); END;
        CREATE TRIGGER evidence_no_delete BEFORE DELETE ON evidence BEGIN SELECT RAISE(ABORT, 'evidence is immutable'); END;
        CREATE TRIGGER events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'events are immutable'); END;
        CREATE TRIGGER events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'events are immutable'); END;
        CREATE TRIGGER consent_no_update BEFORE UPDATE ON consent_ledger BEGIN SELECT RAISE(ABORT, 'consent is immutable'); END;
        CREATE TRIGGER consent_no_delete BEFORE DELETE ON consent_ledger BEGIN SELECT RAISE(ABORT, 'consent is immutable'); END;
        CREATE TRIGGER suppression_no_update BEFORE UPDATE ON suppression_ledger BEGIN SELECT RAISE(ABORT, 'suppression is immutable'); END;
        CREATE TRIGGER suppression_no_delete BEFORE DELETE ON suppression_ledger BEGIN SELECT RAISE(ABORT, 'suppression is immutable'); END;
        CREATE TRIGGER quarantine_no_update BEFORE UPDATE ON quarantine BEGIN SELECT RAISE(ABORT, 'quarantine is immutable'); END;
        CREATE TRIGGER quarantine_no_delete BEFORE DELETE ON quarantine BEGIN SELECT RAISE(ABORT, 'quarantine is immutable'); END;
        CREATE TRIGGER reconciliation_no_update BEFORE UPDATE ON reconciliations BEGIN SELECT RAISE(ABORT, 'reconciliations are immutable'); END;
        CREATE TRIGGER reconciliation_no_delete BEFORE DELETE ON reconciliations BEGIN SELECT RAISE(ABORT, 'reconciliations are immutable'); END;
        CREATE TRIGGER identity_links_no_update BEFORE UPDATE ON identity_links BEGIN SELECT RAISE(ABORT, 'identity links are immutable'); END;
        CREATE TRIGGER identity_links_no_delete BEFORE DELETE ON identity_links BEGIN SELECT RAISE(ABORT, 'identity links are immutable'); END;
        PRAGMA user_version=2;
        COMMIT;
        """
    )
