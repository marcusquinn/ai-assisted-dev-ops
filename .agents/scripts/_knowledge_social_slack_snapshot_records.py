#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Sanitize Slack bookmark and pin snapshots."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from _knowledge_social_slack import conversation_id, namespaced_id, slack_timestamp
from _knowledge_social_slack_contract import (
    SlackReadProviderError,
    non_negative_integer,
    object_value,
    optional_text,
    required_text,
)
from _knowledge_social_slack_record_contract import (
    FILE_ID,
    actor_id,
    epoch_iso,
    stable_id,
)
from knowledge_social_import import canonical_json

BOOKMARK_ID = re.compile(r"^Bk[A-Za-z0-9]{2,62}$")


def bookmark_record(
    payload: Any, workspace: str, expected_channel: str
) -> dict[str, Any]:
    bookmark = object_value(payload, "bookmark")
    native_id = stable_id(bookmark.get("id"), "bookmark ID", BOOKMARK_ID)
    channel = conversation_id(bookmark.get("channel_id"))
    if channel != conversation_id(expected_channel):
        raise SlackReadProviderError("Slack bookmark conversation was rebound")
    return {
        "kind": "bookmark",
        "remote_id": namespaced_id(workspace, "bookmark", native_id),
        "conversation_remote_id": namespaced_id(workspace, "conversation", channel),
        "actor_remote_id": actor_id(
            bookmark.get("last_updated_by_user_id"), workspace
        ),
        "title": optional_text(bookmark.get("title"), "bookmark title"),
        "bookmark_type": optional_text(
            bookmark.get("type"), "bookmark type", limit=128
        ),
        "entity_id": optional_text(bookmark.get("entity_id"), "bookmark entity ID"),
        "created_at": epoch_iso(bookmark.get("date_created"), "bookmark created time"),
        "updated_at": epoch_iso(bookmark.get("date_updated"), "bookmark updated time"),
    }


def pin_record(payload: Any, workspace: str, expected_channel: str) -> dict[str, Any]:
    pin = object_value(payload, "pin")
    channel = conversation_id(pin.get("channel", expected_channel))
    if channel != conversation_id(expected_channel):
        raise SlackReadProviderError("Slack pin conversation was rebound")
    item_type = required_text(pin.get("type"), "pin type", limit=64)
    target: str
    text: str | None = None
    if item_type == "message":
        message = object_value(pin.get("message"), "pinned message")
        timestamp = slack_timestamp(message.get("ts"), "pinned message timestamp")
        target = namespaced_id(workspace, "message", f"{channel}:{timestamp}")
        text = optional_text(message.get("text"), "pinned message text")
    elif item_type == "file":
        file_value = object_value(pin.get("file"), "pinned file")
        native_file = stable_id(file_value.get("id"), "pinned file ID", FILE_ID)
        target = namespaced_id(workspace, "file", native_file)
        text = optional_text(file_value.get("title"), "pinned file title")
    else:
        raise SlackReadProviderError("Slack pin type is unsupported")
    created = non_negative_integer(pin.get("created"), "pin created time", optional=True)
    material = canonical_json([channel, item_type, target, created])
    digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    return {
        "kind": "pin",
        "remote_id": namespaced_id(workspace, "pin", digest),
        "conversation_remote_id": namespaced_id(workspace, "conversation", channel),
        "target_remote_id": target,
        "actor_remote_id": actor_id(pin.get("created_by"), workspace),
        "text": text,
        "created_at": epoch_iso(created, "pin created time"),
    }
