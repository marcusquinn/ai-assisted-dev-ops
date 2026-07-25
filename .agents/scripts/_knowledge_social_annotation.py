#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-only private social annotation persistence and query overlays."""

from __future__ import annotations

import sqlite3
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_store import (
    SocialStoreError,
    connect,
    connect_read_only,
    database_path,
    require_schema,
)

MAX_ANNOTATION_CHARACTERS = 65_536
MAX_IDENTIFIER_CHARACTERS = 512


def _identifier(value: str, field: str) -> str:
    if not value or len(value) > MAX_IDENTIFIER_CHARACTERS or any(
        character.isspace() or ord(character) < 32 for character in value
    ):
        raise SocialStoreError(f"{field} must be a bounded stable identifier")
    return value


def read_private_body(path: Path) -> str:
    try:
        validate_private_file(path, "annotation body file", repair=False)
        body = path.read_text(encoding="utf-8")
    except (CatalogError, OSError, UnicodeError) as error:
        raise SocialStoreError("annotation body must be a private UTF-8 file") from error
    if not body.strip() or len(body) > MAX_ANNOTATION_CHARACTERS:
        raise SocialStoreError("annotation body must contain 1 to 65536 characters")
    return body


def _require_store(root: Path) -> None:
    path = database_path(root)
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("personal social store is unavailable")


def _object_id(
    connection: sqlite3.Connection, provider: str, object_type: str, remote_id: str
) -> int:
    row = connection.execute(
        """SELECT object_id FROM objects
            WHERE provider=? AND object_type=? AND remote_id=?""",
        (provider, object_type, remote_id),
    ).fetchone()
    if row is None:
        raise SocialStoreError("annotation target is absent from the personal corpus")
    return int(row["object_id"])


def _validate_existing_annotation(
    connection: sqlite3.Connection,
    annotation_id: str,
    principal_id: str,
    object_id: int,
) -> str | None:
    row = connection.execute(
        """SELECT principal_id,object_id,visibility,created_at
             FROM annotations WHERE annotation_id=?""",
        (annotation_id,),
    ).fetchone()
    if row is None:
        return None
    if (
        row["principal_id"] != principal_id
        or int(row["object_id"]) != object_id
        or row["visibility"] != "private"
    ):
        raise SocialStoreError("annotation ID conflicts with another private target")
    return str(row["created_at"])


def write_private_annotation(
    root: Path,
    principal_id: str,
    target: tuple[str, str, str],
    body: str,
    annotation_id: str | None,
) -> dict[str, Any]:
    provider, object_type, remote_id = (
        _identifier(target[0], "provider"),
        _identifier(target[1], "object_type"),
        _identifier(target[2], "remote_id"),
    )
    chosen_id = (
        _identifier(annotation_id, "annotation_id")
        if annotation_id
        else f"ann_{uuid.uuid4().hex}"
    )
    _require_store(root)
    connection = connect(root)
    try:
        require_schema(connection)
        connection.execute("BEGIN IMMEDIATE")
        object_id = _object_id(connection, provider, object_type, remote_id)
        created_at = _validate_existing_annotation(
            connection, chosen_id, principal_id, object_id
        )
        now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
        if created_at is None:
            connection.execute(
                """INSERT INTO annotations(
                    annotation_id,object_id,principal_id,visibility,body,created_at,updated_at)
                   VALUES(?,?,?,?,?,?,?)""",
                (chosen_id, object_id, principal_id, "private", body, now, now),
            )
            created_at = now
        else:
            connection.execute(
                "UPDATE annotations SET body=?,updated_at=? WHERE annotation_id=?",
                (body, now, chosen_id),
            )
        connection.execute("COMMIT")
        return {
            "annotation_id": chosen_id,
            "provider": provider,
            "object_type": object_type,
            "remote_id": remote_id,
            "visibility": "private",
            "created_at": created_at,
            "updated_at": now,
        }
    except (sqlite3.Error, SocialStoreError):
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


def load_private_annotations(
    root: Path, principal_id: str, keys: set[tuple[str, str, str]]
) -> dict[tuple[str, str, str], list[dict[str, Any]]]:
    if not keys:
        return {}
    if not database_path(root).exists() and not database_path(root).is_symlink():
        return {}
    connection = connect_read_only(root)
    try:
        require_schema(connection)
        rows = [
            row
            for provider, object_type, remote_id in sorted(keys)
            for row in connection.execute(
                """SELECT o.provider,o.object_type,o.remote_id,a.annotation_id,
                          a.body,a.created_at,a.updated_at
                     FROM annotations a JOIN objects o ON o.object_id=a.object_id
                    WHERE a.principal_id=? AND a.visibility='private'
                      AND o.provider=? AND o.object_type=? AND o.remote_id=?
                    ORDER BY a.annotation_id""",
                (principal_id, provider, object_type, remote_id),
            ).fetchall()
        ]
    except sqlite3.Error as error:
        raise SocialStoreError("private annotations could not be read safely") from error
    finally:
        connection.close()
    overlays: dict[tuple[str, str, str], list[dict[str, Any]]] = {}
    for row in rows:
        key = (str(row["provider"]), str(row["object_type"]), str(row["remote_id"]))
        overlays.setdefault(key, []).append(
            {
                "annotation_id": str(row["annotation_id"]),
                "body": str(row["body"]),
                "visibility": "private",
                "created_at": str(row["created_at"]),
                "updated_at": str(row["updated_at"]),
            }
        )
    return overlays
