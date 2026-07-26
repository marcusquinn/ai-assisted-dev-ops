#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Load and validate provider-neutral social collection state."""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Mapping

from _knowledge_social_collect import (
    CollectionContext,
    CollectionStreamSpec,
    ConnectionConfig,
    ContextRequest,
    CursorState,
)
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, connect, migrate, validate_opaque


def _json_array(value: str, field: str) -> list[str]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {field} is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise SocialStoreError(f"stored social {field} must be an array of text")
    return parsed


def _json_object(value: str, field: str) -> dict[str, Any]:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored social {field} is invalid") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError(f"stored social {field} must be an object")
    reject_credentials(parsed)
    return parsed


def _connection_config(
    database: sqlite3.Connection,
    request: ContextRequest,
    account_id: str,
) -> ConnectionConfig:
    row = database.execute(
        "SELECT provider,remote_account_id,enabled_streams,policy_json "
        "FROM connections WHERE connection_id=?",
        (request.connection_id,),
    ).fetchone()
    if row is None:
        return ConnectionConfig(
            (request.stream,), {"media_hydration": request.media_policy}
        )
    if row["provider"] != request.provider or row["remote_account_id"] != account_id:
        raise SocialStoreError(
            "stored connection does not match the verified social account"
        )
    enabled = _json_array(row["enabled_streams"], "enabled_streams")
    if request.stream not in enabled:
        enabled.append(request.stream)
    policy = dict(_json_object(row["policy_json"], "policy"))
    policy["media_hydration"] = request.media_policy
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
    request: ContextRequest,
    streams: Mapping[str, CollectionStreamSpec],
) -> CollectionContext:
    """Read one provider connection policy and selected stream checkpoint."""
    provider = validate_opaque(request.provider, "provider")
    if request.stream not in streams:
        raise SocialStoreError("social stream is not allowlisted")
    account_id = request.account.get("id")
    if not isinstance(account_id, str) or not account_id:
        raise SocialStoreError("verified social account requires an ID")
    database = connect(root)
    try:
        migrate(database)
        config = _connection_config(database, request, account_id)
        state = _cursor_state(database, request.connection_id, request.stream)
    finally:
        database.close()
    return CollectionContext(
        root,
        request.connection_id,
        request.account,
        request.stream,
        request.media_policy,
        config,
        state,
        streams[request.stream],
        provider=provider,
    )
