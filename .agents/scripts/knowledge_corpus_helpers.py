#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private knowledge-corpus catalog and default-deny path resolver."""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import stat
import sys
import uuid
from pathlib import Path
from typing import Iterable

SCHEMA_VERSION = "1"
DEFAULT_ALIAS = "personal:default"
DEFAULT_CAPABILITY = "knowledge.read"
CAPABILITIES = ("knowledge.read", "knowledge.write", "knowledge.manage")
PRINCIPAL_PATTERN = re.compile(r"^prn_[0-9a-f]{32}$")
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600


class CatalogError(RuntimeError):
    """A fail-closed catalog or authorization error."""


def _opaque_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _default_base() -> Path:
    configured = (
        os.environ.get("KNOWLEDGE_CORPUS_BASE")
        or os.environ.get("PERSONAL_PLANE_BASE")
    )
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"


def _absolute_path(path: Path) -> Path:
    expanded = path.expanduser()
    if not expanded.is_absolute():
        expanded = Path.cwd() / expanded
    return expanded


def _lstat(path: Path, label: str) -> os.stat_result:
    try:
        return path.lstat()
    except FileNotFoundError as exc:
        raise CatalogError(f"{label} missing: {path}") from exc
    except OSError as exc:
        raise CatalogError(f"cannot inspect {label}: {path}") from exc


def _validate_owner(file_stat: os.stat_result, label: str) -> None:
    if hasattr(os, "getuid") and file_stat.st_uid != os.getuid():
        raise CatalogError(f"{label} owner does not match the current user")


def _validate_directory(path: Path, label: str, *, repair: bool) -> Path:
    file_stat = _lstat(path, label)
    if stat.S_ISLNK(file_stat.st_mode):
        raise CatalogError(f"{label} symlink is not allowed")
    if not stat.S_ISDIR(file_stat.st_mode):
        raise CatalogError(f"{label} is not a directory: {path}")
    _validate_owner(file_stat, label)
    mode = stat.S_IMODE(file_stat.st_mode)
    if mode != PRIVATE_DIRECTORY_MODE:
        if not repair:
            raise CatalogError(f"{label} permissions must be 0700")
        os.chmod(path, PRIVATE_DIRECTORY_MODE)
    return path.resolve(strict=True)


def _prepare_base(base: Path, *, create: bool) -> Path:
    absolute = _absolute_path(base)
    if create:
        absolute.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    return _validate_directory(absolute, "knowledge base", repair=create)


def _prepare_private_directory(path: Path, label: str) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    return _validate_directory(path, label, repair=True)


def _validate_private_file(path: Path, label: str, *, repair: bool) -> None:
    file_stat = _lstat(path, label)
    if stat.S_ISLNK(file_stat.st_mode):
        raise CatalogError(f"{label} symlink is not allowed")
    if not stat.S_ISREG(file_stat.st_mode):
        raise CatalogError(f"{label} is not a regular file: {path}")
    _validate_owner(file_stat, label)
    mode = stat.S_IMODE(file_stat.st_mode)
    if mode != PRIVATE_FILE_MODE:
        if not repair:
            raise CatalogError(f"{label} permissions must be 0600")
        os.chmod(path, PRIVATE_FILE_MODE)


def _prepare_catalog_file(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, PRIVATE_FILE_MODE)
        os.close(descriptor)
    _validate_private_file(path, "catalog", repair=True)


def _safe_location(base: Path, location_ref: str) -> Path:
    candidate = Path(location_ref)
    if not candidate.is_absolute():
        raise CatalogError("unsafe path: catalog location must be absolute")
    try:
        resolved = candidate.resolve(strict=True)
    except (FileNotFoundError, OSError) as exc:
        raise CatalogError("unsafe path: catalog location is unavailable") from exc
    if candidate != resolved:
        raise CatalogError("unsafe path: symlinks or non-canonical components are forbidden")
    try:
        resolved.relative_to(base)
    except ValueError as exc:
        raise CatalogError("unsafe path: catalog location escapes the knowledge base") from exc
    file_stat = _lstat(resolved, "corpus location")
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISDIR(file_stat.st_mode):
        raise CatalogError("unsafe path: corpus location must be a real directory")
    _validate_owner(file_stat, "corpus location")
    return resolved


def _context_payload(principal_id: str) -> dict[str, object]:
    return {"version": 1, "principal_id": principal_id}


def _write_context_atomic(context_path: Path, principal_id: str) -> None:
    temporary = context_path.with_name(
        f".{context_path.name}.{uuid.uuid4().hex}.tmp"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, PRIVATE_FILE_MODE)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(_context_payload(principal_id), handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, context_path)
        os.chmod(context_path, PRIVATE_FILE_MODE)
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory_fd = os.open(context_path.parent, directory_flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary.exists():
            temporary.unlink()


def _read_context_file(context_path: Path) -> dict[str, object]:
    before = _lstat(context_path, "authentication context")
    if stat.S_ISLNK(before.st_mode):
        raise CatalogError("context symlink is not allowed")
    if not stat.S_ISREG(before.st_mode):
        raise CatalogError("malformed context: expected a regular file")
    _validate_owner(before, "authentication context")
    if stat.S_IMODE(before.st_mode) != PRIVATE_FILE_MODE:
        raise CatalogError("context permissions must be 0600")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(context_path, flags)
    except OSError as exc:
        raise CatalogError("context symlink or replacement detected") from exc
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        after = os.fstat(handle.fileno())
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise CatalogError("context replacement detected")
        try:
            payload = json.load(handle)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise CatalogError("malformed context: invalid JSON") from exc
    if not isinstance(payload, dict):
        raise CatalogError("malformed context: expected an object")
    return payload


def _load_principal(context_path: Path) -> str:
    payload = _read_context_file(context_path)
    if set(payload) != {"version", "principal_id"} or payload.get("version") != 1:
        raise CatalogError("malformed context: unsupported fields or version")
    principal_id = payload.get("principal_id")
    if not isinstance(principal_id, str) or not PRINCIPAL_PATTERN.fullmatch(
        principal_id
    ):
        raise CatalogError("malformed context: invalid principal ID")
    return principal_id


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
            (
                corpus_id,
                workspace_id,
                str(legacy_root),
                "internal",
                "active",
            ),
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
    resolved_base = _prepare_base(base, create=True)
    legacy_root = resolved_base / "_knowledge"
    if not legacy_root.exists():
        raise CatalogError(f"legacy knowledge root missing: {legacy_root}")
    _validate_directory(legacy_root, "legacy knowledge root", repair=True)
    config_dir = _prepare_private_directory(resolved_base / "_config", "config directory")
    context_path = config_dir / "principal.json"
    catalog_path = resolved_base / "catalog.db"
    _prepare_catalog_file(catalog_path)

    old_umask = os.umask(0o077)
    connection: sqlite3.Connection | None = None
    try:
        connection = _connect_catalog(catalog_path, read_only=False)
        connection.execute("BEGIN IMMEDIATE")
        _create_schema(connection)
        if context_path.exists() or context_path.is_symlink():
            principal_id = _load_principal(context_path)
        else:
            principal_id = _recover_principal(connection) or _opaque_id("prn")
            _write_context_atomic(context_path, principal_id)
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
    _validate_private_file(catalog_path, "catalog", repair=True)


def _open_authorized_catalog(base: Path) -> tuple[Path, str, sqlite3.Connection]:
    resolved_base = _prepare_base(base, create=False)
    config_dir = _validate_directory(
        resolved_base / "_config", "config directory", repair=False
    )
    context_path = config_dir / "principal.json"
    principal_id = _load_principal(context_path)
    catalog_path = resolved_base / "catalog.db"
    _validate_private_file(catalog_path, "catalog", repair=False)
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


def resolve(base: Path, alias: str, capability: str) -> Path:
    resolved_base, principal_id, connection = _open_authorized_catalog(base)
    try:
        rows = _authorized_rows(connection, principal_id, capability, alias)
        if len(rows) != 1:
            raise CatalogError(
                f"access denied: alias {alias} is unavailable or ambiguous"
            )
        return _safe_location(resolved_base, str(rows[0]["location_ref"]))
    finally:
        connection.close()


def list_authorized(base: Path, capability: str) -> Iterable[tuple[str, Path]]:
    resolved_base, principal_id, connection = _open_authorized_catalog(base)
    try:
        rows = _authorized_rows(connection, principal_id, capability, None)
        return [
            (str(row["alias"]), _safe_location(resolved_base, row["location_ref"]))
            for row in rows
        ]
    finally:
        connection.close()


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage the private knowledge corpus catalog"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    provision_parser = subparsers.add_parser("provision")
    provision_parser.add_argument("--base", type=Path, default=_default_base())

    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("--base", type=Path, default=_default_base())
    resolve_parser.add_argument("--alias", default=DEFAULT_ALIAS)
    resolve_parser.add_argument("--capability", default=DEFAULT_CAPABILITY)

    list_parser = subparsers.add_parser("list")
    list_parser.add_argument("--base", type=Path, default=_default_base())
    list_parser.add_argument("--capability", default=DEFAULT_CAPABILITY)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "provision":
            provision(arguments.base)
            return 0
        if arguments.command == "resolve":
            print(resolve(arguments.base, arguments.alias, arguments.capability))
            return 0
        if arguments.command == "list":
            for alias, location in list_authorized(
                arguments.base, arguments.capability
            ):
                print(f"{alias}\t{location}")
            return 0
    except (CatalogError, sqlite3.Error, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
