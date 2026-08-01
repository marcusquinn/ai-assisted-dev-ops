#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Sanitize Slack messages, reactions, and file metadata."""

from __future__ import annotations

import re
from decimal import Decimal
from typing import Any

from _knowledge_social_slack import conversation_id, namespaced_id, slack_timestamp
from _knowledge_social_slack_contract import (
    SlackReadProviderError,
    non_negative_integer,
    object_list,
    object_value,
    optional_boolean,
    optional_text,
    required_text,
)
from _knowledge_social_slack_record_contract import (
    ACTOR_ID,
    FILE_ID,
    actor_id,
    epoch_iso,
    stable_id,
    timestamp_iso,
)

REACTION_NAME = re.compile(r"^[A-Za-z0-9_+\-]{1,128}$")
MAX_REACTIONS = 100
MAX_REACTION_USERS = 1000
MAX_REACTION_ACTORS_PER_MESSAGE = 100
MAX_FILES_PER_MESSAGE = 100
MAX_FILE_CONVERSATIONS = 1000


def _file_record(
    payload: Any, workspace: str, object_remote_id: str | None = None
) -> dict[str, Any]:
    item = object_value(payload, "file")
    native_id = stable_id(item.get("id"), "file ID", FILE_ID)
    return {
        "kind": "file",
        "remote_id": namespaced_id(workspace, "file", native_id),
        "file_id": native_id,
        "object_remote_id": object_remote_id,
        "actor_remote_id": actor_id(item.get("user"), workspace),
        "name": optional_text(item.get("name"), "file name", limit=4096),
        "title": optional_text(item.get("title"), "file title", limit=4096),
        "mimetype": optional_text(item.get("mimetype"), "file MIME type", limit=255),
        "size": non_negative_integer(item.get("size"), "file size", optional=True),
        "created_at": epoch_iso(item.get("timestamp"), "file timestamp"),
        "is_tombstoned": optional_boolean(
            item.get("is_tombstoned"), "file tombstone flag"
        ) or False,
    }


def file_records(
    values: Any, workspace: str, limit: int, object_remote_id: str | None = None
) -> list[dict[str, Any]]:
    return [
        _file_record(item, workspace, object_remote_id)
        for item in object_list(values, "files", limit=limit)
    ]


def _file_conversation_ids(payload: dict[str, Any]) -> frozenset[str]:
    visible_in: set[str] = set()
    for field in ("channels", "groups", "ims"):
        values = payload.get(field, [])
        if not isinstance(values, list) or len(values) > MAX_FILE_CONVERSATIONS:
            raise SlackReadProviderError(
                "Slack file conversations exceed the item limit"
            )
        visible_in.update(conversation_id(value) for value in values)
    return frozenset(visible_in)


def file_records_for_conversation(
    values: Any, workspace: str, limit: int, expected_conversation: str
) -> list[dict[str, Any]]:
    """Keep only files that explicitly attest the requested conversation."""
    expected = conversation_id(expected_conversation)
    return [
        _file_record(value, workspace)
        for value in object_list(values, "files", limit=limit)
        if expected in _file_conversation_ids(value)
    ]


def _reactions(values: Any, workspace: str) -> list[dict[str, Any]]:
    if values is None:
        return []
    source = object_list(values, "message reactions", limit=MAX_REACTIONS)
    records: list[dict[str, Any]] = []
    actor_count = 0
    seen_names: set[str] = set()
    for reaction in source:
        name = stable_id(reaction.get("name"), "reaction name", REACTION_NAME)
        if name in seen_names:
            raise SlackReadProviderError("Slack message reaction names are duplicated")
        seen_names.add(name)
        count = non_negative_integer(reaction.get("count"), "reaction count")
        users = reaction.get("users", [])
        if not isinstance(users, list) or len(users) > MAX_REACTION_USERS:
            raise SlackReadProviderError("Slack reaction users exceed the item limit")
        actor_count += len(users)
        if actor_count > MAX_REACTION_ACTORS_PER_MESSAGE:
            raise SlackReadProviderError(
                "Slack message reaction actors exceed the item limit"
            )
        actors = [
            actor_id(stable_id(value, "reaction user ID", ACTOR_ID), workspace)
            for value in users
        ]
        if len(set(actors)) != len(actors):
            raise SlackReadProviderError("Slack message reaction actors are inconsistent")
        if count is not None and count < len(actors):
            raise SlackReadProviderError("Slack message reaction actors are inconsistent")
        records.append(
            {
                "name": name,
                "count": count,
                "actor_remote_ids": actors,
                "actors_truncated": count is not None and count > len(actors),
            }
        )
    return records


def _message_source(payload: dict[str, Any]) -> tuple[dict[str, Any], str, str]:
    subtype = optional_text(payload.get("subtype"), "message subtype", limit=128)
    subtype = subtype or "message"
    if subtype == "message_changed" and isinstance(payload.get("message"), dict):
        source = object_value(payload["message"], "changed message")
        native_ts = slack_timestamp(source.get("ts"), "changed message timestamp")
        return source, native_ts, "edited"
    if subtype in {"message_changed", "message_deleted"}:
        original = payload.get("original_ts", payload.get("deleted_ts"))
        native_ts = slack_timestamp(original, "original message timestamp")
        state = "deleted" if subtype == "message_deleted" else "edited"
        return payload, native_ts, state
    native_ts = slack_timestamp(payload.get("ts"), "message timestamp")
    state = "edited" if isinstance(payload.get("edited"), dict) else "active"
    return payload, native_ts, state


def message_record(
    payload: Any, workspace: str, native_conversation: str
) -> list[dict[str, Any]]:
    outer = object_value(payload, "message")
    source, native_ts, state = _message_source(outer)
    conversation = conversation_id(native_conversation)
    remote_id = namespaced_id(workspace, "message", f"{conversation}:{native_ts}")
    subtype = optional_text(outer.get("subtype"), "message subtype", limit=128)
    text = None if state == "deleted" else optional_text(source.get("text"), "message text")
    thread_ts = source.get("thread_ts", outer.get("thread_ts"))
    thread_remote_id = None
    if thread_ts is not None:
        thread_remote_id = namespaced_id(
            workspace,
            "message",
            f"{conversation}:{slack_timestamp(thread_ts, 'thread timestamp')}",
        )
    edited = source.get("edited")
    edited_ts = None
    editor_value = None
    if isinstance(edited, dict):
        edited_ts = timestamp_iso(edited.get("ts"), "edited timestamp")
        editor_value = edited.get("user")
    elif state in {"edited", "deleted"}:
        edited_ts = timestamp_iso(outer.get("ts"), "change timestamp")
        editor_value = outer.get("editor_id", outer.get("user"))
    actor_value = source.get(
        "user", outer.get("user", outer.get("editor_id", source.get("bot_id")))
    )
    message = {
        "kind": "message",
        "remote_id": remote_id,
        "conversation_remote_id": namespaced_id(
            workspace, "conversation", conversation
        ),
        "message_ts": native_ts,
        "thread_remote_id": thread_remote_id,
        "actor_remote_id": actor_id(actor_value, workspace),
        "editor_remote_id": (
            actor_id(editor_value, workspace) if editor_value is not None else None
        ),
        "text": text,
        "subtype": subtype,
        "state": state,
        "created_at": timestamp_iso(native_ts, "message timestamp"),
        "edited_at": edited_ts,
        "reactions": _reactions(source.get("reactions"), workspace),
        "is_starred": optional_boolean(source.get("is_starred"), "starred flag")
        or False,
    }
    files = file_records(
        source.get("files", []), workspace, MAX_FILES_PER_MESSAGE, remote_id
    )
    return [message, *files]


def reaction_item_records(
    payload: Any, workspace: str, allowed_conversations: frozenset[str]
) -> list[dict[str, Any]]:
    item = object_value(payload, "reaction item")
    item_type = required_text(item.get("type"), "reaction item type", limit=64)
    channel = item.get("channel")
    if item_type == "message":
        native_channel = conversation_id(channel)
        if native_channel not in allowed_conversations:
            return []
        return message_record(item.get("message"), workspace, native_channel)
    if item_type == "file":
        file_value = object_value(item.get("file"), "reaction file")
        if allowed_conversations.isdisjoint(_file_conversation_ids(file_value)):
            return []
        return [_file_record(file_value, workspace)]
    return []


def newest_message_ts(records: list[dict[str, Any]]) -> str | None:
    timestamps = [
        item["message_ts"]
        for item in records
        if item.get("kind") == "message" and isinstance(item.get("message_ts"), str)
    ]
    return max(timestamps, key=Decimal) if timestamps else None
