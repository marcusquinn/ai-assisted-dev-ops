#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Load and validate durable connection and cursor state for X collection."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_social_lease import RunLease
from _knowledge_social_x import PROVIDER, STREAMS, CursorState, StreamSpec, XAdapterError
from knowledge_social_import import reject_credentials
from knowledge_social_store import connect, migrate


@dataclass(frozen=True)
class ConnectionConfig:
    """Merged non-secret policy for an existing or new connection."""

    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class CollectionContext:
    """Validated state shared by one bounded collection invocation."""

    root: Path
    connection_id: str
    account: dict[str, Any]
    stream: str
    media_policy: str
    config: ConnectionConfig
    state: CursorState
    spec: StreamSpec
    lease: RunLease | None = None


def _json_array(value: str, field: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise XAdapterError(f"stored X {field} is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise XAdapterError(f"stored X {field} must be an array of text")
    return parsed


def _json_object(value: str, field: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise XAdapterError(f"stored X {field} is invalid") from error
    if not isinstance(parsed, dict):
        raise XAdapterError(f"stored X {field} must be an object")
    reject_credentials(parsed)
    return parsed


def _connection_config(
    database: sqlite3.Connection,
    connection_id: str,
    account_id: str,
    stream: str,
    media_policy: str,
) -> ConnectionConfig:
    row = database.execute(
        "SELECT provider,remote_account_id,enabled_streams,policy_json "
        "FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        return ConnectionConfig((stream,), {"media_hydration": media_policy})
    if row["provider"] != PROVIDER or row["remote_account_id"] != account_id:
        raise XAdapterError("stored connection does not match the verified X account")
    enabled = _json_array(row["enabled_streams"], "enabled_streams")
    if stream not in enabled:
        enabled.append(stream)
    policy = dict(_json_object(row["policy_json"], "policy"))
    policy["media_hydration"] = media_policy
    return ConnectionConfig(tuple(enabled), policy)


def _cursor_state(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> CursorState:
    row = database.execute(
        "SELECT cursor,watermark,backfill_complete FROM sync_cursors "
        "WHERE connection_id=? AND stream=?",
        (connection_id, stream),
    ).fetchone()
    if row is None:
        return CursorState(None, None, False)
    return CursorState(row["cursor"], row["watermark"], bool(row["backfill_complete"]))


def load_context(
    root: Path,
    connection_id: str,
    account: dict[str, Any],
    stream: str,
    media_policy: str,
) -> CollectionContext:
    """Read the connection policy and selected stream checkpoint."""
    database = connect(root)
    try:
        migrate(database)
        config = _connection_config(
            database, connection_id, account["id"], stream, media_policy
        )
        state = _cursor_state(database, connection_id, stream)
    finally:
        database.close()
    return CollectionContext(
        root,
        connection_id,
        account,
        stream,
        media_policy,
        config,
        state,
        STREAMS[stream],
    )
