#!/usr/bin/env python3
"""Private SQLite corpus catalog and authenticated authorization resolver."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import stat
import sys
import tempfile
import uuid
from pathlib import Path

SCHEMA_VERSION = "1"
DEFAULT_ALIAS = "personal:default"
CAPABILITIES = ("knowledge.read", "knowledge.write", "knowledge.manage")
DEFAULT_BASE = Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"

SCHEMA_STATEMENTS = (
    "CREATE TABLE IF NOT EXISTS schema_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    """CREATE TABLE IF NOT EXISTS principals (
        principal_id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS workspaces (
        workspace_id TEXT PRIMARY KEY, kind TEXT NOT NULL, status TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS workspace_memberships (
        workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
        principal_id TEXT NOT NULL REFERENCES principals(principal_id),
        role TEXT NOT NULL, status TEXT NOT NULL,
        PRIMARY KEY (workspace_id, principal_id)
    )""",
    """CREATE TABLE IF NOT EXISTS corpora (
        corpus_id TEXT PRIMARY KEY,
        workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
        location_ref TEXT NOT NULL, sensitivity TEXT NOT NULL, status TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS corpus_aliases (
        alias TEXT PRIMARY KEY,
        corpus_id TEXT NOT NULL UNIQUE REFERENCES corpora(corpus_id)
    )""",
    """CREATE TABLE IF NOT EXISTS corpus_grants (
        corpus_id TEXT NOT NULL REFERENCES corpora(corpus_id),
        principal_id TEXT NOT NULL REFERENCES principals(principal_id),
        role TEXT NOT NULL, capability TEXT NOT NULL, scope TEXT NOT NULL,
        status TEXT NOT NULL,
        PRIMARY KEY (corpus_id, principal_id, capability, scope)
    )""",
    """CREATE TABLE IF NOT EXISTS collector_assignments (
        connection_id TEXT PRIMARY KEY,
        collector_principal_id TEXT NOT NULL REFERENCES principals(principal_id),
        runner_ref TEXT NOT NULL
    )""",
)


class CorpusError(RuntimeError):
    """A fail-closed catalog or authentication error."""


def opaque_id(prefix: str) -> str:
    """Return an opaque local identifier."""
    return f"{prefix}_{uuid.uuid4().hex}"


def ensure_private_directory(path: Path) -> None:
    """Create a private directory and reject symlinked/non-directory paths."""
    if path.exists() or path.is_symlink():
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise CorpusError(f"unsafe directory: {path}")
        if info.st_uid != os.getuid():
            raise CorpusError(f"directory owner mismatch: {path}")
    else:
        path.mkdir(parents=True, mode=0o700)
    path.chmod(0o700)


def validate_private_file(path: Path, label: str) -> os.stat_result:
    """Require an owner-only, regular, non-symlink local file."""
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise CorpusError(f"missing {label}: {path}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise CorpusError(f"unsafe {label}: must be a regular non-symlink file")
    if info.st_uid != os.getuid():
        raise CorpusError(f"unsafe {label}: owner mismatch")
    if stat.S_IMODE(info.st_mode) & 0o077:
        raise CorpusError(f"unsafe {label}: context permissions must be owner-only")
    return info


def validate_private_directory(path: Path, label: str) -> os.stat_result:
    """Require an owner-only, real directory without repairing it."""
    try:
        info = path.lstat()
    except FileNotFoundError as exc:
        raise CorpusError(f"missing {label}: {path}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise CorpusError(f"unsafe {label}: must be a real directory")
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise CorpusError(f"unsafe {label}: directory must be owner-only")
    return info


def atomic_write_json(path: Path, value: dict[str, object]) -> None:
    """Write JSON using fsync and atomic replacement in a private directory."""
    ensure_private_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temporary)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, separators=(",", ":"), sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temp_path.unlink(missing_ok=True)


def load_principal(context_path: Path) -> str:
    """Derive the local principal exclusively from validated authentication context."""
    validate_private_directory(context_path.parent, "authentication context directory")
    validate_private_file(context_path, "authentication context")
    try:
        document = json.loads(context_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CorpusError("malformed authentication context") from exc
    if not isinstance(document, dict) or document.get("version") != 1:
        raise CorpusError("malformed authentication context")
    principal_id = document.get("principal_id")
    if not isinstance(principal_id, str) or not principal_id.startswith("prn_"):
        raise CorpusError("malformed authentication context")
    return principal_id


def checked_location(base: Path, location: Path, *, require_exists: bool = True) -> Path:
    """Resolve a catalog location and prove it remains within the configured base."""
    resolved_base = base.resolve(strict=True)
    if not location.is_absolute():
        raise CorpusError("unsafe path: corpus location must be absolute")
    try:
        resolved_location = location.resolve(strict=require_exists)
        inside = os.path.commonpath((resolved_base, resolved_location)) == str(resolved_base)
    except (FileNotFoundError, ValueError) as exc:
        raise CorpusError("unsafe path: corpus location is unavailable") from exc
    if not inside:
        raise CorpusError("unsafe path: corpus location escapes the knowledge base")
    return resolved_location


def validate_catalog_file(path: Path) -> None:
    """Reject an unsafe existing catalog before SQLite opens it."""
    if not path.exists() and not path.is_symlink():
        return
    validate_private_file(path, "catalog")


def connect_catalog(path: Path, *, read_only: bool = False) -> sqlite3.Connection:
    """Open a catalog with the required durability and concurrency settings."""
    if read_only and not path.exists():
        raise CorpusError("invalid or unavailable corpus catalog")
    validate_catalog_file(path)
    if read_only:
        uri = f"{path.resolve(strict=True).as_uri()}?mode=ro"
        connection = sqlite3.connect(
            uri, timeout=5.0, isolation_level=None, uri=True
        )
    else:
        connection = sqlite3.connect(path, timeout=5.0, isolation_level=None)
        path.chmod(0o600)
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    if read_only:
        connection.execute("PRAGMA query_only = ON")
    else:
        connection.execute("PRAGMA journal_mode = WAL")
    return connection


def bootstrap(base: Path) -> Path:
    """Create schema v1 and the idempotent legacy personal-corpus graph."""
    ensure_private_directory(base)
    config_dir = base / "_config"
    ensure_private_directory(config_dir)
    legacy_root = base / "_knowledge"
    ensure_private_directory(legacy_root)
    context_path = config_dir / "principal.json"
    if context_path.exists() or context_path.is_symlink():
        principal_id = load_principal(context_path)
    else:
        principal_id = opaque_id("prn")
        atomic_write_json(context_path, {"version": 1, "principal_id": principal_id})

    catalog_path = base / "catalog.db"
    connection = connect_catalog(catalog_path)
    workspace_id = opaque_id("wsp")
    corpus_id = opaque_id("crp")
    try:
        connection.execute("BEGIN IMMEDIATE")
        for statement in SCHEMA_STATEMENTS:
            connection.execute(statement)
        version = connection.execute(
            "SELECT value FROM schema_meta WHERE key = 'schema_version'"
        ).fetchone()
        if version and version[0] != SCHEMA_VERSION:
            raise CorpusError(f"unsupported catalog schema version: {version[0]}")
        connection.execute(
            "INSERT OR IGNORE INTO schema_meta(key, value) VALUES('schema_version', ?)",
            (SCHEMA_VERSION,),
        )
        existing = connection.execute(
            """SELECT a.corpus_id, c.workspace_id, c.location_ref
               FROM corpus_aliases a JOIN corpora c ON c.corpus_id = a.corpus_id
               WHERE a.alias = ?""",
            (DEFAULT_ALIAS,),
        ).fetchone()
        if existing:
            corpus_id, workspace_id, stored_location = existing
            if checked_location(base, Path(stored_location)) != legacy_root.resolve():
                raise CorpusError("conflicting personal:default alias")
        connection.execute(
            "INSERT OR IGNORE INTO principals VALUES (?, 'human', 'active')",
            (principal_id,),
        )
        if existing is None:
            connection.execute(
                "INSERT INTO workspaces VALUES (?, 'personal', 'active')", (workspace_id,)
            )
            connection.execute(
                "INSERT INTO corpora VALUES (?, ?, ?, 'personal', 'active')",
                (corpus_id, workspace_id, str(legacy_root.resolve())),
            )
            connection.execute(
                "INSERT INTO corpus_aliases VALUES (?, ?)", (DEFAULT_ALIAS, corpus_id)
            )
        connection.execute(
            "INSERT OR IGNORE INTO workspace_memberships VALUES (?, ?, 'owner', 'active')",
            (workspace_id, principal_id),
        )
        for capability in CAPABILITIES:
            connection.execute(
                """INSERT OR IGNORE INTO corpus_grants
                   VALUES (?, ?, 'owner', ?, '*', 'active')""",
                (corpus_id, principal_id, capability),
            )
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()
    return legacy_root.resolve()


def authorized_rows(base: Path, capability: str, alias: str | None = None) -> list[sqlite3.Row]:
    """Return only active corpora reachable through every authorization edge."""
    if capability not in CAPABILITIES:
        raise CorpusError(f"unsupported capability: {capability}")
    principal_id = load_principal(base / "_config" / "principal.json")
    connection = connect_catalog(base / "catalog.db", read_only=True)
    connection.row_factory = sqlite3.Row
    query = """
        SELECT a.alias, c.corpus_id, c.workspace_id, c.location_ref, g.capability
        FROM principals p
        JOIN workspace_memberships m ON m.principal_id = p.principal_id
        JOIN workspaces w ON w.workspace_id = m.workspace_id
        JOIN corpora c ON c.workspace_id = w.workspace_id
        JOIN corpus_aliases a ON a.corpus_id = c.corpus_id
        JOIN corpus_grants g ON g.corpus_id = c.corpus_id
            AND g.principal_id = p.principal_id
        WHERE p.principal_id = ? AND p.status = 'active'
          AND m.status = 'active' AND w.status = 'active' AND c.status = 'active'
          AND g.status = 'active' AND g.capability = ? AND g.scope = '*'
    """
    parameters: list[str] = [principal_id, capability]
    if alias is not None:
        query += " AND a.alias = ?"
        parameters.append(alias)
    query += " ORDER BY a.alias"
    try:
        rows = connection.execute(query, parameters).fetchall()
    except sqlite3.DatabaseError as exc:
        raise CorpusError("invalid or unavailable corpus catalog") from exc
    finally:
        connection.close()
    return rows


def resolve_alias(base: Path, alias: str, capability: str) -> Path:
    """Resolve one authorized logical alias to its validated physical path."""
    rows = authorized_rows(base, capability, alias)
    if len(rows) != 1:
        raise CorpusError(f"access denied: alias {alias!r} is not authorized")
    return checked_location(base, Path(rows[0]["location_ref"]))


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the deliberately narrow command surface."""
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    provision = subparsers.add_parser("provision")
    provision.add_argument("--base", type=Path, default=DEFAULT_BASE)
    resolve = subparsers.add_parser("resolve")
    resolve.add_argument("--base", type=Path, default=DEFAULT_BASE)
    resolve.add_argument("--alias", default=DEFAULT_ALIAS)
    resolve.add_argument("--capability", choices=CAPABILITIES, default="knowledge.read")
    listing = subparsers.add_parser("list")
    listing.add_argument("--base", type=Path, default=DEFAULT_BASE)
    listing.add_argument("--capability", choices=CAPABILITIES, default="knowledge.read")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Run a corpus catalog command."""
    os.umask(0o077)
    args = parse_args(argv if argv is not None else sys.argv[1:])
    try:
        base = args.base.expanduser().absolute()
        if args.command == "provision":
            print(bootstrap(base))
        elif args.command == "resolve":
            print(resolve_alias(base, args.alias, args.capability))
        else:
            for row in authorized_rows(base, args.capability):
                location = checked_location(base, Path(row["location_ref"]))
                print(json.dumps({"alias": row["alias"], "path": str(location)}))
    except (CorpusError, OSError, sqlite3.DatabaseError) as exc:
        print(f"knowledge-corpus: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
