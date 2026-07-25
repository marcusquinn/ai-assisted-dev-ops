#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""SQLite catalog bootstrap and default-deny corpus authorization."""

from __future__ import annotations

import os
import sqlite3
import uuid
from pathlib import Path
from typing import Iterable

from knowledge_corpus_context import (
    CatalogError,
    load_principal,
    prepare_base,
    prepare_catalog_file,
    prepare_private_directory,
    safe_location,
    validate_directory,
    validate_private_file,
    write_context_atomic,
)

SCHEMA_VERSION = "1"
DEFAULT_ALIAS = "personal:default"
DEFAULT_CAPABILITY = "knowledge.read"
CAPABILITIES = ("knowledge.read", "knowledge.write", "knowledge.manage")


def _opaque_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _connect_catalog(catalog_path: Path, *, read_only: bool) -> sqlite3.Connection:
    if read_only:
        connection = sqlite3.connect(
            f"{catalog_path.as_uri()}?mode=ro",
            uri=True,
            isolation_level=None,
            timeout=5.0,
        )
    else:
        connection = sqlite3.connect(
            str(catalog_path), isolation_level=None, timeout=5.0
        )
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=5000")
    connection.execute("PRAGMA foreign_keys=ON")
    if read_only:
        connection.execute("PRAGMA query_only=ON")
    else:
        mode = connection.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        if str(mode).lower() != "wal":
            connection.close()
            raise CatalogError("catalog could not enable WAL mode")
        connection.execute("PRAGMA synchronous=FULL")
    return connection


def _create_schema(connection: sqlite3.Connection) -> None:
    statements = (
        """CREATE TABLE IF NOT EXISTS schema_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )""",
        """CREATE TABLE IF NOT EXISTS principals (
            principal_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','inactive'))
        )""",
        """CREATE TABLE IF NOT EXISTS workspaces (
            workspace_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','inactive'))
        )""",
        """CREATE TABLE IF NOT EXISTS workspace_memberships (
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
            principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            role TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','inactive')),
            PRIMARY KEY(workspace_id, principal_id)
        )""",
        """CREATE TABLE IF NOT EXISTS corpora (
            corpus_id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
            location_ref TEXT NOT NULL,
            sensitivity TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','inactive'))
        )""",
        """CREATE TABLE IF NOT EXISTS corpus_aliases (
            alias TEXT PRIMARY KEY,
            corpus_id TEXT NOT NULL UNIQUE REFERENCES corpora(corpus_id)
        )""",
        """CREATE TABLE IF NOT EXISTS corpus_grants (
            corpus_id TEXT NOT NULL REFERENCES corpora(corpus_id),
            principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            role TEXT NOT NULL,
            capability TEXT NOT NULL,
            scope TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('active','inactive')),
            PRIMARY KEY(corpus_id, principal_id, capability, scope)
        )""",
        """CREATE TABLE IF NOT EXISTS collector_assignments (
            connection_id TEXT PRIMARY KEY,
            collector_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
            runner_ref TEXT NOT NULL
        )""",
        """CREATE INDEX IF NOT EXISTS idx_memberships_principal
            ON workspace_memberships(principal_id, status)""",
        """CREATE INDEX IF NOT EXISTS idx_corpora_workspace
            ON corpora(workspace_id, status)""",
        """CREATE INDEX IF NOT EXISTS idx_grants_principal_capability
            ON corpus_grants(principal_id, capability, status)""",
    )
    for statement in statements:
        connection.execute(statement)
    row = connection.execute(
        "SELECT value FROM schema_meta WHERE key='schema_version'"
    ).fetchone()
    if row is not None and row["value"] != SCHEMA_VERSION:
        raise CatalogError(f"unsupported catalog schema version: {row['value']}")
    connection.execute(
        "INSERT OR IGNORE INTO schema_meta(key,value) VALUES('schema_version',?)",
        (SCHEMA_VERSION,),
    )
    connection.execute(f"PRAGMA user_version={SCHEMA_VERSION}")


def _recover_principal(connection: sqlite3.Connection) -> str | None:
    rows = connection.execute(
        """
        SELECT DISTINCT p.principal_id
          FROM principals p
          JOIN workspace_memberships m ON m.principal_id=p.principal_id
          JOIN workspaces w ON w.workspace_id=m.workspace_id
          JOIN corpora c ON c.workspace_id=w.workspace_id
          JOIN corpus_aliases a ON a.corpus_id=c.corpus_id
         WHERE a.alias=? AND p.kind='human' AND w.kind='personal'
           AND m.role='owner'
        """,
        (DEFAULT_ALIAS,),
    ).fetchall()
    if len(rows) == 1:
        return str(rows[0]["principal_id"])
    if len(rows) > 1:
        raise CatalogError("cannot recover authentication context unambiguously")
    return None


def _existing_workspace(
    connection: sqlite3.Connection, principal_id: str
) -> str | None:
    rows = connection.execute(
        """
        SELECT w.workspace_id
          FROM workspaces w
          JOIN workspace_memberships m ON m.workspace_id=w.workspace_id
         WHERE m.principal_id=? AND w.kind='personal' AND m.role='owner'
        """,
        (principal_id,),
    ).fetchall()
    if len(rows) > 1:
        raise CatalogError("principal has multiple personal owner workspaces")
    return str(rows[0]["workspace_id"]) if rows else None


def _bootstrap_graph(
    connection: sqlite3.Connection, principal_id: str, legacy_root: Path
) -> None:
    connection.execute(
        "INSERT OR IGNORE INTO principals(principal_id,kind,status) VALUES(?,?,?)",
        (principal_id, "human", "active"),
    )
    principal = connection.execute(
        "SELECT kind FROM principals WHERE principal_id=?", (principal_id,)
    ).fetchone()
    if principal is None or principal["kind"] != "human":
        raise CatalogError("authentication context conflicts with catalog principal")

    workspace_id = _existing_workspace(connection, principal_id)
    if workspace_id is None:
        workspace_id = _opaque_id("wsp")
        connection.execute(
            "INSERT INTO workspaces(workspace_id,kind,status) VALUES(?,?,?)",
            (workspace_id, "personal", "active"),
        )
        connection.execute(
            "INSERT INTO workspace_memberships"
            "(workspace_id,principal_id,role,status) VALUES(?,?,?,?)",
            (workspace_id, principal_id, "owner", "active"),
        )

    corpus = connection.execute(
        """SELECT c.corpus_id,c.workspace_id,c.location_ref
             FROM corpus_aliases a
             JOIN corpora c ON c.corpus_id=a.corpus_id
            WHERE a.alias=?""",
        (DEFAULT_ALIAS,),
    ).fetchone()
    if corpus is None:
        corpus_id = _opaque_id("cor")
        connection.execute(
            "INSERT INTO corpora"
            "(corpus_id,workspace_id,location_ref,sensitivity,status) "
            "VALUES(?,?,?,?,?)",
            (corpus_id, workspace_id, str(legacy_root), "internal", "active"),
        )
        connection.execute(
            "INSERT INTO corpus_aliases(alias,corpus_id) VALUES(?,?)",
            (DEFAULT_ALIAS, corpus_id),
        )
    else:
        corpus_id = str(corpus["corpus_id"])
        if corpus["workspace_id"] != workspace_id:
            raise CatalogError("personal alias conflicts with another workspace")
        if corpus["location_ref"] != str(legacy_root):
            raise CatalogError("personal alias conflicts with the legacy path")

    for capability in CAPABILITIES:
        connection.execute(
            "INSERT OR IGNORE INTO corpus_grants"
            "(corpus_id,principal_id,role,capability,scope,status) "
            "VALUES(?,?,?,?,?,?)",
            (corpus_id, principal_id, "owner", capability, "corpus", "active"),
        )


def provision(base: Path) -> None:
    resolved_base = prepare_base(base, create=True)
    legacy_root = resolved_base / "_knowledge"
    if not legacy_root.exists():
        raise CatalogError(f"legacy knowledge root missing: {legacy_root}")
    validate_directory(legacy_root, "legacy knowledge root", repair=True)
    config_dir = prepare_private_directory(resolved_base / "_config", "config directory")
    context_path = config_dir / "principal.json"
    catalog_path = resolved_base / "catalog.db"
    prepare_catalog_file(catalog_path)

    old_umask = os.umask(0o077)
    connection: sqlite3.Connection | None = None
    try:
        connection = _connect_catalog(catalog_path, read_only=False)
        connection.execute("BEGIN IMMEDIATE")
        _create_schema(connection)
        if context_path.exists() or context_path.is_symlink():
            principal_id = load_principal(context_path)
        else:
            principal_id = _recover_principal(connection) or _opaque_id("prn")
            write_context_atomic(context_path, principal_id)
        _bootstrap_graph(connection, principal_id, legacy_root)
        connection.commit()
    except Exception:
        if connection is not None:
            connection.rollback()
        raise
    finally:
        if connection is not None:
            connection.close()
        os.umask(old_umask)
    validate_private_file(catalog_path, "catalog", repair=True)


def _open_authorized_catalog(base: Path) -> tuple[Path, str, sqlite3.Connection]:
    resolved_base = prepare_base(base, create=False)
    config_dir = validate_directory(
        resolved_base / "_config", "config directory", repair=False
    )
    principal_id = load_principal(config_dir / "principal.json")
    catalog_path = resolved_base / "catalog.db"
    validate_private_file(catalog_path, "catalog", repair=False)
    connection = _connect_catalog(catalog_path, read_only=True)
    try:
        row = connection.execute(
            "SELECT value FROM schema_meta WHERE key='schema_version'"
        ).fetchone()
    except Exception:
        connection.close()
        raise
    if row is None or row["value"] != SCHEMA_VERSION:
        connection.close()
        raise CatalogError("unsupported or missing catalog schema version")
    return resolved_base, principal_id, connection


def _authorized_rows(
    connection: sqlite3.Connection,
    principal_id: str,
    capability: str,
    alias: str | None,
) -> list[sqlite3.Row]:
    if capability not in CAPABILITIES:
        raise CatalogError(f"access denied: unsupported capability {capability}")
    query = """
        SELECT a.alias,c.location_ref,c.corpus_id,c.workspace_id
          FROM principals p
          JOIN workspace_memberships m ON m.principal_id=p.principal_id
          JOIN workspaces w ON w.workspace_id=m.workspace_id
          JOIN corpora c ON c.workspace_id=w.workspace_id
          JOIN corpus_aliases a ON a.corpus_id=c.corpus_id
          JOIN corpus_grants g ON g.corpus_id=c.corpus_id
                               AND g.principal_id=p.principal_id
         WHERE p.principal_id=?
           AND p.status='active'
           AND m.status='active'
           AND w.status='active'
           AND c.status='active'
           AND g.status='active'
           AND g.capability=?
           AND g.scope='corpus'
    """
    parameters: list[str] = [principal_id, capability]
    if alias is not None:
        query += " AND a.alias=?"
        parameters.append(alias)
    query += " ORDER BY a.alias,c.corpus_id"
    return list(connection.execute(query, parameters).fetchall())


def authorized_scope(
    base: Path, capability: str, alias: str | None = None
) -> tuple[str, list[tuple[str, Path]]]:
    resolved_base, principal_id, connection = _open_authorized_catalog(base)
    try:
        rows = _authorized_rows(connection, principal_id, capability, alias)
        if alias is not None and len(rows) != 1:
            raise CatalogError(
                f"access denied: alias {alias} is unavailable or ambiguous"
            )
        corpora = [
            (
                str(row["alias"]),
                safe_location(resolved_base, str(row["location_ref"])),
            )
            for row in rows
        ]
        return principal_id, corpora
    finally:
        connection.close()


def resolve(base: Path, alias: str, capability: str) -> Path:
    _, corpora = authorized_scope(base, capability, alias)
    return corpora[0][1]


def list_authorized(base: Path, capability: str) -> Iterable[tuple[str, Path]]:
    _, corpora = authorized_scope(base, capability)
    return corpora
