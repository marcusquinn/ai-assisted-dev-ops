#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for bounded Discord provider reads."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

MAX_TEXT_BYTES = 256 * 1024


class DiscordReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Discord provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: Any
    retry_after: int | None = None
    rate_limit: dict[str, str] | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise DiscordReadProviderError("Discord read request has an invalid shape")


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DiscordReadProviderError(f"Discord {field} must be an object")
    return value


def array_value(value: Any, field: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise DiscordReadProviderError(f"Discord {field} must be an array")
    return value


def text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise DiscordReadProviderError(f"Discord {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise DiscordReadProviderError(f"Discord {field} exceeds the safety limit")
    return value


def snowflake(value: Any, field: str, *, optional: bool = False) -> str | None:
    value = text(value, field, optional=optional)
    if value is None:
        return None
    if not value.isascii() or not value.isdigit() or not 5 <= len(value) <= 24:
        raise DiscordReadProviderError(f"Discord {field} must be a snowflake")
    return value


def boolean(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise DiscordReadProviderError(f"Discord {field} must be boolean")
    return value


def integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise DiscordReadProviderError(f"Discord {field} must be an integer")
    return value


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _application_flags(payload: dict[str, Any]) -> int:
    value = payload.get("flags_new", payload.get("flags", 0))
    if isinstance(value, str) and value.isascii() and value.isdigit():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise DiscordReadProviderError("Discord application flags are invalid")
    return value


def _verify_intent_flags(application_payload: dict[str, Any], config: dict[str, Any]) -> None:
    flags = _application_flags(application_payload)
    intent_bits = {
        "message_content_intent": (1 << 18) | (1 << 19),
        "guild_members_intent": (1 << 14) | (1 << 15),
    }
    missing = [field for field, bits in intent_bits.items() if config[field] and not flags & bits]
    if missing:
        raise DiscordReadProviderError(
            "Discord identity does not match the configured connection"
        )


def identity_value(
    user_payload: dict[str, Any],
    application_payload: dict[str, Any],
    guild_payload: dict[str, Any],
    config: dict[str, Any],
    expected_bot_id: str,
) -> dict[str, Any]:
    """Verify bot, application, and guild before exposing sanitized identity."""
    bot_id = snowflake(user_payload.get("id"), "bot user ID")
    application_id = snowflake(application_payload.get("id"), "application ID")
    guild_id = snowflake(guild_payload.get("id"), "guild ID")
    app_bot = application_payload.get("bot")
    if bot_id != expected_bot_id:
        raise DiscordReadProviderError(
            "Discord identity does not match the configured connection"
        )
    if application_id != config["application_id"] or guild_id != config["guild_id"]:
        raise DiscordReadProviderError(
            "Discord identity does not match the configured connection"
        )
    if isinstance(app_bot, dict) and app_bot.get("id") != bot_id:
        raise DiscordReadProviderError(
            "Discord identity does not match the configured connection"
        )
    _verify_intent_flags(application_payload, config)
    return {
        "id": bot_id,
        "application_id": application_id,
        "guild_id": guild_id,
        "channel_ids": list(config["channel_ids"]),
        "thread_ids": list(config["thread_ids"]),
        "dm_channel_ids": list(config["dm_channel_ids"]),
        "message_content_intent": config["message_content_intent"],
        "guild_members_intent": config["guild_members_intent"],
        "export_user_id": config["export_user_id"],
    }


def _user(value: Any, field: str) -> dict[str, Any]:
    user = object_value(value, field)
    return {
        "id": snowflake(user.get("id"), f"{field} ID"),
        "username": text(user.get("username"), f"{field} username", optional=True),
        "global_name": text(
            user.get("global_name"), f"{field} global name", optional=True
        ),
        "bot": bool(user.get("bot", False)),
    }


def serialize_message(item: dict[str, Any], expected_channel: str) -> dict[str, Any]:
    """Reduce a Discord message to stable evidence and transport-safe metadata."""
    message_id = snowflake(item.get("id"), "message ID")
    channel_id = snowflake(item.get("channel_id"), "message channel ID")
    if channel_id != expected_channel:
        raise DiscordReadProviderError("Discord message crossed the channel fence")
    author = _user(item.get("author"), "message author")
    mentions = [_user(value, "mention") for value in item.get("mentions", [])]
    attachments = []
    for value in item.get("attachments", []):
        attachment = object_value(value, "attachment")
        attachments.append(
            {
                "id": snowflake(attachment.get("id"), "attachment ID"),
                "filename": text(attachment.get("filename"), "attachment filename"),
                "content_type": text(
                    attachment.get("content_type"), "attachment content type", optional=True
                ),
                "size": integer(attachment.get("size", 0), "attachment size"),
                "ephemeral": bool(attachment.get("ephemeral", False)),
            }
        )
    reactions = []
    for value in item.get("reactions", []):
        reaction = object_value(value, "reaction")
        emoji = object_value(reaction.get("emoji"), "reaction emoji")
        reactions.append(
            {
                "emoji_id": snowflake(emoji.get("id"), "emoji ID", optional=True),
                "emoji_name": text(emoji.get("name"), "emoji name", optional=True),
                "count": integer(reaction.get("count", 0), "reaction count"),
            }
        )
    return {
        "kind": "message",
        "remote_id": message_id,
        "channel_id": channel_id,
        "guild_id": snowflake(item.get("guild_id"), "message guild ID", optional=True),
        "author": author,
        "content": text(item.get("content", ""), "message content"),
        "timestamp": text(item.get("timestamp"), "message timestamp"),
        "edited_timestamp": text(
            item.get("edited_timestamp"), "message edit timestamp", optional=True
        ),
        "type": integer(item.get("type", 0), "message type"),
        "mentions": mentions,
        "attachments": attachments,
        "embeds": item.get("embeds", []),
        "reactions": reactions,
        "reference_message_id": snowflake(
            object_value(item.get("message_reference", {}), "message reference").get(
                "message_id"
            ),
            "referenced message ID",
            optional=True,
        ),
    }


def serialize_channel(item: dict[str, Any], guild_id: str) -> dict[str, Any]:
    item_guild = snowflake(item.get("guild_id", guild_id), "channel guild ID")
    if item_guild != guild_id:
        raise DiscordReadProviderError("Discord channel crossed the guild fence")
    return {
        "kind": "channel",
        "remote_id": snowflake(item.get("id"), "channel ID"),
        "guild_id": item_guild,
        "channel_type": integer(item.get("type"), "channel type"),
        "name": text(item.get("name"), "channel name", optional=True),
        "topic": text(item.get("topic"), "channel topic", optional=True),
        "parent_id": snowflake(item.get("parent_id"), "parent channel ID", optional=True),
        "archived": bool(object_value(item.get("thread_metadata", {}), "thread metadata").get("archived", False)),
        "applied_tags": [snowflake(value, "forum tag ID") for value in item.get("applied_tags", [])],
    }


def serialize_role(item: dict[str, Any], guild_id: str) -> dict[str, Any]:
    return {
        "kind": "role",
        "remote_id": snowflake(item.get("id"), "role ID"),
        "guild_id": guild_id,
        "name": text(item.get("name"), "role name"),
        "permissions": text(item.get("permissions", "0"), "role permissions"),
        "managed": bool(item.get("managed", False)),
    }


def serialize_member(item: dict[str, Any], guild_id: str) -> dict[str, Any]:
    user = _user(item.get("user"), "member user")
    return {
        "kind": "member",
        "remote_id": user["id"],
        "guild_id": guild_id,
        "user": user,
        "nick": text(item.get("nick"), "member nickname", optional=True),
        "roles": [snowflake(value, "member role ID") for value in item.get("roles", [])],
        "joined_at": text(item.get("joined_at"), "member joined timestamp", optional=True),
    }
