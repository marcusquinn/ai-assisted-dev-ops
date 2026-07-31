#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and page a local spool of official Discord Gateway dispatches."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from _knowledge_social_discord_contract import (
    DiscordReadProviderError,
    integer,
    object_value,
    snowflake,
    text,
)
from knowledge_social_import import reject_credentials

MAX_SPOOL_BYTES = 32 * 1024 * 1024
EVENTS = {
    "MESSAGE_CREATE",
    "MESSAGE_UPDATE",
    "MESSAGE_DELETE",
    "MESSAGE_DELETE_BULK",
    "MESSAGE_REACTION_ADD",
    "MESSAGE_REACTION_REMOVE",
    "MESSAGE_REACTION_REMOVE_ALL",
    "MESSAGE_REACTION_REMOVE_EMOJI",
    "CHANNEL_CREATE",
    "CHANNEL_UPDATE",
    "CHANNEL_DELETE",
    "THREAD_CREATE",
    "THREAD_UPDATE",
    "THREAD_DELETE",
    "THREAD_LIST_SYNC",
    "THREAD_MEMBERS_UPDATE",
    "GUILD_MEMBER_ADD",
    "GUILD_MEMBER_UPDATE",
    "GUILD_MEMBER_REMOVE",
    "GUILD_ROLE_CREATE",
    "GUILD_ROLE_UPDATE",
    "GUILD_ROLE_DELETE",
}


def _allowed_dispatch(data: dict[str, Any], config: dict[str, Any]) -> bool:
    guild_id = data.get("guild_id")
    channel_id = data.get("channel_id") or data.get("id")
    if guild_id is not None and guild_id != config["guild_id"]:
        return False
    if channel_id is None:
        return guild_id == config["guild_id"]
    allowed = {
        *config["channel_ids"],
        *config["thread_ids"],
        *config["dm_channel_ids"],
    }
    return channel_id in allowed


def _spool_path(path_value: str | None) -> Path:
    if not path_value:
        raise DiscordReadProviderError("Discord gateway event spool is unavailable")
    path = Path(path_value).expanduser()
    valid = not path.is_symlink() and path.is_file()
    if valid:
        valid = path.stat().st_size <= MAX_SPOOL_BYTES
    if not valid:
        raise DiscordReadProviderError("Discord gateway event spool is unavailable")
    return path


def _after_sequence(cursor: dict[str, Any] | None) -> int:
    if cursor is None:
        return 0
    if set(cursor) != {"sequence"}:
        raise DiscordReadProviderError("Discord gateway cursor is invalid")
    return integer(cursor.get("sequence"), "gateway sequence")


def _decode_dispatch(line: str) -> tuple[int, str, dict[str, Any]] | None:
    if not line.strip():
        return None
    event = object_value(json.loads(line), "gateway event")
    reject_credentials(event)
    if event.get("op") != 0:
        return None
    return (
        integer(event.get("s"), "gateway sequence"),
        text(event.get("t"), "gateway event name") or "",
        object_value(event.get("d"), "gateway event data"),
    )


def _event_record(
    sequence: int, event_name: str, data: dict[str, Any], guild_id: str
) -> dict[str, Any]:
    return {
        "kind": "gateway_event",
        "remote_id": f"{guild_id}:{sequence}",
        "sequence": sequence,
        "event_name": event_name,
        "data": data,
    }


def page_gateway_events(
    path_value: str | None,
    config: dict[str, Any],
    cursor: dict[str, Any] | None,
    limit: int,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None, dict[str, Any]]:
    """Return dispatches after the durable sequence without opening a Gateway."""
    path = _spool_path(path_value)
    after = _after_sequence(cursor)
    accepted: list[dict[str, Any]] = []
    last_sequence = after
    try:
        with path.open(encoding="utf-8") as source:
            for line in source:
                dispatch = _decode_dispatch(line)
                if dispatch is None:
                    continue
                sequence, event_name, data = dispatch
                if sequence <= after or event_name not in EVENTS:
                    continue
                last_sequence = max(last_sequence, sequence)
                if not _allowed_dispatch(data, config):
                    continue
                accepted.append(_event_record(sequence, event_name, data, config["guild_id"]))
                if len(accepted) >= limit:
                    return accepted, {"sequence": last_sequence}, {"sequence": last_sequence}
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DiscordReadProviderError("Discord gateway event spool is invalid") from error
    watermark = {"sequence": last_sequence}
    return accepted, None, watermark
