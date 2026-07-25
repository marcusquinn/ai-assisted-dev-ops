#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mutable notification workflow projected from immutable social evidence."""

from __future__ import annotations

import hashlib
import json
import sqlite3
from typing import Any

from knowledge_social_store import SocialStoreError, validate_opaque

NOTIFICATION_STATUSES = (
    "unread",
    "seen",
    "action-required",
    "responded",
    "dismissed",
)
SOURCE_ACTIVITY_TYPES = ("mentions", "reply", "replies")
ALLOWED_TRANSITIONS: dict[str, tuple[str, ...]] = {
    "unread": ("seen", "action-required", "responded", "dismissed"),
    "seen": ("unread", "action-required", "responded", "dismissed"),
    "action-required": ("seen", "responded", "dismissed"),
    "responded": ("action-required", "dismissed"),
    "dismissed": ("unread", "action-required"),
}
SOURCE_ACTIVITIES_SQL = """SELECT a.provider,a.activity_type,a.remote_id,a.actor_remote_id,
                    a.object_remote_id,a.observed_at,o.provider_json,b.connection_id
               FROM activities a
               JOIN fetch_batches b ON b.batch_id=a.batch_id
               JOIN connections c ON c.connection_id=b.connection_id
               LEFT JOIN objects o ON o.provider=a.provider
                                  AND o.object_type='post'
                                  AND o.remote_id=a.object_remote_id
              WHERE a.state='active' AND a.activity_type IN (?,?,?)
                AND a.actor_remote_id<>c.remote_account_id
              ORDER BY a.observed_at,a.provider,a.activity_type,a.remote_id"""
INSERT_NOTIFICATION_SQL = """INSERT OR IGNORE INTO notification_state(
                    notification_id,principal_id,provider,connection_id,
                    activity_type,activity_remote_id,object_remote_id,actor_remote_id,
                    kind,status,observed_at,created_at,updated_at)
                   VALUES(?,?,?,?,?,?,?,?,?,'unread',?,?,?)"""
UPDATE_NOTIFICATION_SOURCE_SQL = """UPDATE notification_state
                          SET connection_id=?,object_remote_id=?,actor_remote_id=?,
                              kind=?,observed_at=?
                        WHERE notification_id=? AND principal_id=?"""
LIST_NOTIFICATIONS_SQL = """SELECT notification_id,kind,status,observed_at,updated_at
               FROM notification_state WHERE principal_id=?
              ORDER BY observed_at DESC,notification_id LIMIT ?"""
LIST_NOTIFICATIONS_BY_STATUS_SQL = """SELECT notification_id,kind,status,observed_at,updated_at
               FROM notification_state WHERE principal_id=? AND status=?
              ORDER BY observed_at DESC,notification_id LIMIT ?"""


def _notification_id(
    principal_id: str, provider: str, activity_type: str, activity_remote_id: str
) -> str:
    source = "\x00".join(
        (principal_id, provider, activity_type, activity_remote_id)
    ).encode("utf-8")
    return f"ntf_{hashlib.sha256(source).hexdigest()}"


def _provider_references(provider_json: str | None) -> list[Any]:
    try:
        provider = json.loads(provider_json or "{}")
    except json.JSONDecodeError:
        return []
    if not isinstance(provider, dict):
        return []
    references = provider.get("referenced_tweets", [])
    return references if isinstance(references, list) else []


def _notification_kind(activity_type: str, provider_json: str | None) -> str:
    if activity_type in ("reply", "replies"):
        return "reply"
    if any(
        isinstance(reference, dict) and reference.get("type") == "replied_to"
        for reference in _provider_references(provider_json)
    ):
        return "reply"
    return "mention"


def _upsert_notification(
    database: sqlite3.Connection,
    principal_id: str,
    row: sqlite3.Row,
    projected_at: int,
) -> int:
    notification_id = _notification_id(
        principal_id,
        str(row["provider"]),
        str(row["activity_type"]),
        str(row["remote_id"]),
    )
    kind = _notification_kind(str(row["activity_type"]), row["provider_json"])
    changed = database.execute(
        INSERT_NOTIFICATION_SQL,
        (
            notification_id,
            principal_id,
            row["provider"],
            row["connection_id"],
            row["activity_type"],
            row["remote_id"],
            row["object_remote_id"],
            row["actor_remote_id"],
            kind,
            row["observed_at"],
            projected_at,
            projected_at,
        ),
    ).rowcount
    if changed == 0:
        database.execute(
            UPDATE_NOTIFICATION_SOURCE_SQL,
            (
                row["connection_id"],
                row["object_remote_id"],
                row["actor_remote_id"],
                kind,
                row["observed_at"],
                notification_id,
                principal_id,
            ),
        )
    return changed


def project_notifications(
    database: sqlite3.Connection,
    principal_id: str,
    *,
    projected_at: int,
) -> dict[str, int]:
    """Idempotently project mention/reply evidence without resetting workflow state."""
    principal_id = validate_opaque(principal_id, "principal_id")
    rows = database.execute(
        SOURCE_ACTIVITIES_SQL,
        SOURCE_ACTIVITY_TYPES,
    ).fetchall()
    inserted = 0
    database.execute("BEGIN IMMEDIATE")
    try:
        for row in rows:
            inserted += _upsert_notification(
                database, principal_id, row, projected_at
            )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {"projected": len(rows), "inserted": inserted}


def list_notifications(
    database: sqlite3.Connection,
    principal_id: str,
    status: str | None,
    limit: int,
) -> list[dict[str, Any]]:
    """Return bounded workflow metadata without content, handles, or raw provider IDs."""
    principal_id = validate_opaque(principal_id, "principal_id")
    if status is not None and status not in NOTIFICATION_STATUSES:
        raise SocialStoreError("unsupported notification status")
    if limit < 1 or limit > 1000:
        raise SocialStoreError("notification list limit must be between 1 and 1000")
    if status is None:
        rows = database.execute(
            LIST_NOTIFICATIONS_SQL, (principal_id, limit)
        ).fetchall()
    else:
        rows = database.execute(
            LIST_NOTIFICATIONS_BY_STATUS_SQL, (principal_id, status, limit)
        ).fetchall()
    return [dict(row) for row in rows]


def set_notification_status(
    database: sqlite3.Connection,
    principal_id: str,
    notification_id: str,
    status: str,
    updated_at: int,
) -> dict[str, Any]:
    """Apply one explicit, authorized notification workflow transition."""
    principal_id = validate_opaque(principal_id, "principal_id")
    notification_id = validate_opaque(notification_id, "notification_id")
    if status not in NOTIFICATION_STATUSES:
        raise SocialStoreError("unsupported notification status")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = database.execute(
            """SELECT status FROM notification_state
                 WHERE notification_id=? AND principal_id=?""",
            (notification_id, principal_id),
        ).fetchone()
        if row is None:
            raise SocialStoreError("notification is unavailable")
        previous = str(row["status"])
        if status != previous and status not in ALLOWED_TRANSITIONS[previous]:
            raise SocialStoreError("notification workflow transition is not allowed")
        if status != previous:
            database.execute(
                """UPDATE notification_state SET status=?,updated_at=?
                     WHERE notification_id=? AND principal_id=?""",
                (status, updated_at, notification_id, principal_id),
            )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "notification_id": notification_id,
        "previous_status": previous,
        "status": status,
    }
