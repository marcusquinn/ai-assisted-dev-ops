#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private catalog schema and workspace state for social sharing."""

from __future__ import annotations

import re
import sqlite3
import uuid
from dataclasses import dataclass
from pathlib import Path

from _knowledge_social_share_crypto import (
    PrivateIdentity,
    PublicIdentity,
    ShareError,
    b64e,
)
from knowledge_corpus_catalog import CAPABILITIES, SCHEMA_VERSION, _connect_catalog
from knowledge_corpus_context import (
    CatalogError,
    load_principal,
    prepare_base,
    prepare_private_directory,
    safe_location,
    validate_directory,
    validate_private_file,
)

SHARE_SCHEMA_VERSION = "1"
WORKSPACE_ALIAS = re.compile(r"^workspace:[A-Za-z0-9][A-Za-z0-9_-]{1,63}$")


@dataclass(frozen=True)
class WorkspaceState:
    alias: str
    root: Path
    workspace_id: str
    corpus_id: str
    owner_principal_id: str
    owner_device_id: str
    key_generation: int
    export_sequence: int
    import_sequence: int


def validate_alias(alias: str) -> str:
    if not WORKSPACE_ALIAS.fullmatch(alias):
        raise ShareError(
            "SOCIAL_SHARE_INVALID", "shared workspace alias must use workspace:<opaque>", 3
        )
    return alias


def current_principal(base: Path) -> str:
    resolved = prepare_base(base, create=False)
    config = validate_directory(resolved / "_config", "config directory", repair=False)
    return load_principal(config / "principal.json")


def _create_share_schema(connection: sqlite3.Connection) -> None:
    statements = (
        """CREATE TABLE IF NOT EXISTS principal_devices (
            device_id TEXT PRIMARY KEY,
            principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            signing_public_key TEXT NOT NULL,
            encryption_public_key TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','revoked'))
        )""",
        """CREATE TABLE IF NOT EXISTS workspace_device_grants (
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
            principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            device_id TEXT NOT NULL REFERENCES principal_devices(device_id),
            status TEXT NOT NULL CHECK(status IN ('active','revoked')),
            PRIMARY KEY(workspace_id,principal_id,device_id)
        )""",
        """CREATE TABLE IF NOT EXISTS workspace_share_state (
            workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
            corpus_id TEXT NOT NULL UNIQUE REFERENCES corpora(corpus_id),
            owner_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            owner_device_id TEXT NOT NULL REFERENCES principal_devices(device_id),
            key_generation INTEGER NOT NULL CHECK(key_generation > 0),
            export_sequence INTEGER NOT NULL DEFAULT 0 CHECK(export_sequence >= 0),
            import_sequence INTEGER NOT NULL DEFAULT 0 CHECK(import_sequence >= 0)
        )""",
        """CREATE TABLE IF NOT EXISTS workspace_share_events (
            event_id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
            corpus_id TEXT NOT NULL REFERENCES corpora(corpus_id),
            event_kind TEXT NOT NULL CHECK(event_kind IN ('grant','revocation','import')),
            principal_id TEXT NOT NULL,
            key_generation INTEGER NOT NULL,
            sequence INTEGER,
            created_at INTEGER NOT NULL
        )""",
        """CREATE INDEX IF NOT EXISTS idx_workspace_devices_active
            ON workspace_device_grants(workspace_id,principal_id,status)""",
    )
    for statement in statements:
        connection.execute(statement)
    row = connection.execute(
        "SELECT value FROM schema_meta WHERE key='social_share_schema_version'"
    ).fetchone()
    if row is not None and str(row["value"]) != SHARE_SCHEMA_VERSION:
        raise CatalogError("unsupported social sharing catalog schema version")
    connection.execute(
        "INSERT OR IGNORE INTO schema_meta(key,value) VALUES"
        "('social_share_schema_version',?)",
        (SHARE_SCHEMA_VERSION,),
    )


def _open_mutable(base: Path) -> tuple[Path, str, sqlite3.Connection]:
    resolved = prepare_base(base, create=False)
    config = validate_directory(resolved / "_config", "config directory", repair=False)
    principal_id = load_principal(config / "principal.json")
    catalog_path = resolved / "catalog.db"
    validate_private_file(catalog_path, "catalog", repair=False)
    connection = _connect_catalog(catalog_path, read_only=False)
    try:
        row = connection.execute(
            "SELECT value FROM schema_meta WHERE key='schema_version'"
        ).fetchone()
        if row is None or str(row["value"]) != SCHEMA_VERSION:
            raise CatalogError("unsupported or missing catalog schema version")
        connection.execute("BEGIN IMMEDIATE")
        _create_share_schema(connection)
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        connection.close()
        raise
    return resolved, principal_id, connection


def _upsert_principal(connection: sqlite3.Connection, principal_id: str) -> None:
    connection.execute(
        "INSERT OR IGNORE INTO principals(principal_id,kind,status) VALUES(?,?,?)",
        (principal_id, "human", "active"),
    )
    row = connection.execute(
        "SELECT kind,status FROM principals WHERE principal_id=?", (principal_id,)
    ).fetchone()
    if row is None or str(row["kind"]) != "human":
        raise ShareError("SOCIAL_SHARE_CONFLICT", "sharing principal conflicts with catalog", 4)
    if str(row["status"]) != "active":
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "sharing principal is inactive", 5)


def _upsert_device(connection: sqlite3.Connection, identity: PublicIdentity) -> None:
    values = (
        identity.device_id,
        identity.principal_id,
        b64e(identity.signing_public_key),
        b64e(identity.encryption_public_key),
    )
    row = connection.execute(
        "SELECT principal_id,signing_public_key,encryption_public_key,status "
        "FROM principal_devices WHERE device_id=?",
        (identity.device_id,),
    ).fetchone()
    if row is not None and tuple(row)[:3] != values[1:]:
        raise ShareError("SOCIAL_SHARE_CONFLICT", "sharing device identity conflicts with catalog", 4)
    if row is not None and str(row["status"]) != "active":
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "sharing device identity is revoked", 5)
    connection.execute(
        "INSERT INTO principal_devices(device_id,principal_id,signing_public_key,"
        "encryption_public_key,status) VALUES(?,?,?,?, 'active') "
        "ON CONFLICT(device_id) DO NOTHING",
        values,
    )


def _state_row(connection: sqlite3.Connection, alias: str) -> sqlite3.Row:
    row = connection.execute(
        """SELECT a.alias,c.location_ref,c.corpus_id,c.workspace_id,
                  s.owner_principal_id,s.owner_device_id,s.key_generation,
                  s.export_sequence,s.import_sequence
             FROM corpus_aliases a
             JOIN corpora c ON c.corpus_id=a.corpus_id
             JOIN workspaces w ON w.workspace_id=c.workspace_id
             JOIN workspace_share_state s ON s.workspace_id=w.workspace_id
            WHERE a.alias=? AND w.kind='workspace' AND w.status='active'
              AND c.status='active'""",
        (validate_alias(alias),),
    ).fetchone()
    if row is None:
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "shared workspace is unavailable", 5)
    return row


def _state(resolved: Path, row: sqlite3.Row) -> WorkspaceState:
    return WorkspaceState(
        str(row["alias"]),
        safe_location(resolved, str(row["location_ref"])),
        str(row["workspace_id"]),
        str(row["corpus_id"]),
        str(row["owner_principal_id"]),
        str(row["owner_device_id"]),
        int(row["key_generation"]),
        int(row["export_sequence"]),
        int(row["import_sequence"]),
    )


def _require_capability(
    connection: sqlite3.Connection,
    state: WorkspaceState,
    principal_id: str,
    capability: str,
) -> None:
    row = connection.execute(
        """SELECT 1 FROM principals p
             JOIN workspace_memberships m ON m.principal_id=p.principal_id
             JOIN corpus_grants g ON g.principal_id=p.principal_id
            WHERE p.principal_id=? AND p.status='active'
              AND m.workspace_id=? AND m.status='active'
              AND g.corpus_id=? AND g.capability=? AND g.scope='corpus'
              AND g.status='active'""",
        (principal_id, state.workspace_id, state.corpus_id, capability),
    ).fetchone()
    if row is None:
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "shared workspace grant is inactive", 5)


def _require_owner(state: WorkspaceState, identity: PrivateIdentity, principal_id: str) -> None:
    if (
        identity.public.principal_id != principal_id
        or state.owner_principal_id != principal_id
        or state.owner_device_id != identity.public.device_id
    ):
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "workspace owner identity is required", 5)


def create_workspace(base: Path, alias: str, owner: PrivateIdentity) -> WorkspaceState:
    resolved, principal_id, connection = _open_mutable(base)
    validate_alias(alias)
    if owner.public.principal_id != principal_id:
        connection.close()
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "Vault identity does not match this principal", 5)
    workspace_id = f"wsp_{uuid.uuid4().hex}"
    corpus_id = f"cor_{uuid.uuid4().hex}"
    root = prepare_private_directory(resolved / "_workspaces", "shared workspace root")
    root = prepare_private_directory(root / workspace_id, "shared workspace directory")
    root = prepare_private_directory(root / corpus_id, "shared corpus directory")
    try:
        connection.execute("BEGIN IMMEDIATE")
        if connection.execute(
            "SELECT 1 FROM corpus_aliases WHERE alias=?", (alias,)
        ).fetchone():
            raise ShareError("SOCIAL_SHARE_CONFLICT", "shared workspace alias already exists", 4)
        _upsert_principal(connection, principal_id)
        _upsert_device(connection, owner.public)
        connection.execute(
            "INSERT INTO workspaces(workspace_id,kind,status) VALUES(?,'workspace','active')",
            (workspace_id,),
        )
        connection.execute(
            "INSERT INTO workspace_memberships(workspace_id,principal_id,role,status) "
            "VALUES(?,?,'owner','active')",
            (workspace_id, principal_id),
        )
        connection.execute(
            "INSERT INTO corpora(corpus_id,workspace_id,location_ref,sensitivity,status) "
            "VALUES(?,?,?,'internal','active')",
            (corpus_id, workspace_id, str(root)),
        )
        connection.execute(
            "INSERT INTO corpus_aliases(alias,corpus_id) VALUES(?,?)", (alias, corpus_id)
        )
        for capability in CAPABILITIES:
            connection.execute(
                "INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) "
                "VALUES(?,?,'owner',?,'corpus','active')",
                (corpus_id, principal_id, capability),
            )
        connection.execute(
            "INSERT INTO workspace_device_grants(workspace_id,principal_id,device_id,status) "
            "VALUES(?,?,?,'active')",
            (workspace_id, principal_id, owner.public.device_id),
        )
        connection.execute(
            "INSERT INTO workspace_share_state(workspace_id,corpus_id,owner_principal_id,"
            "owner_device_id,key_generation) VALUES(?,?,?,?,1)",
            (workspace_id, corpus_id, principal_id, owner.public.device_id),
        )
        connection.execute("COMMIT")
        return WorkspaceState(
            alias, root, workspace_id, corpus_id, principal_id, owner.public.device_id, 1, 0, 0
        )
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
