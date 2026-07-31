#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Discord stream policy, allowlisted requests, and durable checkpoints."""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "discord"
CURSOR_PREFIX = "discord-v1:"
SNOWFLAKE = re.compile(r"^[0-9]{5,24}$")


class DiscordAdapterError(SocialStoreError):
    """Raised when bounded Discord collection cannot continue safely."""


class DiscordProviderUnavailableError(DiscordAdapterError):
    """Raised when the guarded Discord child cannot complete a read."""


ADAPTER_ERROR = DiscordAdapterError
PROVIDER_UNAVAILABLE_ERROR = DiscordProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Discord stream."""

    resource_kind: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


STREAMS = {
    "messages": StreamSpec(
        "message",
        True,
        "provider_retention_and_channel_visibility",
        "partial",
        "rest_history_excludes_deleted_messages_and_prior_revisions",
    ),
    "metadata": StreamSpec("guild_metadata", False, None),
    "members": StreamSpec(
        "member",
        False,
        None,
        "partial",
        "guild_members_intent_and_current_membership_required",
    ),
    "gateway_events": StreamSpec(
        "event",
        True,
        "local_gateway_spool_retention",
        "partial",
        "prospective_events_only_with_resume_and_spool_gaps_visible",
    ),
    "account_export": StreamSpec(
        "export_message",
        False,
        "operator_supplied_official_export_snapshot",
        "partial",
        "export_shape_and_requested_categories_are_not_api_contracts",
    ),
}


def snowflake(value: Any, field: str, *, optional: bool = False) -> str | None:
    """Validate one Discord snowflake without coercing numeric JSON values."""
    if value is None and optional:
        return None
    if not isinstance(value, str) or SNOWFLAKE.fullmatch(value) is None:
        raise DiscordAdapterError(f"Discord {field} must be a snowflake")
    return value


def _snowflakes(value: Any, field: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise DiscordAdapterError(f"Discord {field} must be an array")
    result = tuple(snowflake(item, field) or "" for item in value)
    if len(result) != len(set(result)):
        raise DiscordAdapterError(f"Discord {field} must not contain duplicates")
    return result


def _encode_state(value: dict[str, Any]) -> str:
    reject_credentials(value)
    payload = canonical_json(value).encode("utf-8")
    if len(payload) > 16384:
        raise DiscordAdapterError("Discord checkpoint exceeds the safety limit")
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_state(value: str | None, field: str) -> dict[str, Any] | None:
    if value is None:
        return None
    if not value.startswith(CURSOR_PREFIX):
        raise DiscordAdapterError(f"stored Discord {field} has an unsupported version")
    try:
        encoded = value.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise DiscordAdapterError(f"stored Discord {field} is invalid") from error
    if not isinstance(parsed, dict):
        raise DiscordAdapterError(f"stored Discord {field} has an invalid shape")
    reject_credentials(parsed)
    return parsed


@dataclass(frozen=True)
class PageRequest:
    """Complete identity and authority fence for one provider page."""

    stream: str
    bot_id: str
    application_id: str
    guild_id: str
    channel_ids: tuple[str, ...]
    thread_ids: tuple[str, ...]
    dm_channel_ids: tuple[str, ...]
    message_content_intent: bool
    guild_members_intent: bool
    export_user_id: str | None
    cursor: dict[str, Any] | None
    watermark: dict[str, Any] | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "bot_id": self.bot_id,
            "application_id": self.application_id,
            "guild_id": self.guild_id,
            "channel_ids": list(self.channel_ids),
            "thread_ids": list(self.thread_ids),
            "dm_channel_ids": list(self.dm_channel_ids),
            "message_content_intent": self.message_content_intent,
            "guild_members_intent": self.guild_members_intent,
            "export_user_id": self.export_user_id,
            "cursor": self.cursor,
            "watermark": self.watermark,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    """Build one child request from verified identity and durable state."""
    if stream not in STREAMS:
        raise DiscordAdapterError("Discord stream is not allowlisted")
    application_id = snowflake(account.get("application_id"), "application ID")
    guild_id = snowflake(account.get("guild_id"), "guild ID")
    bot_id = snowflake(account.get("id"), "bot user ID")
    if application_id is None or guild_id is None or bot_id is None:
        raise DiscordAdapterError("verified Discord identity is incomplete")
    return PageRequest(
        stream,
        bot_id,
        application_id,
        guild_id,
        _snowflakes(account.get("channel_ids"), "channel allowlist"),
        _snowflakes(account.get("thread_ids"), "thread allowlist"),
        _snowflakes(account.get("dm_channel_ids"), "DM allowlist"),
        bool(account.get("message_content_intent")),
        bool(account.get("guild_members_intent")),
        snowflake(account.get("export_user_id"), "export user ID", optional=True),
        _decode_state(state.cursor, "cursor"),
        _decode_state(state.watermark, "watermark"),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise DiscordAdapterError("Discord response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise DiscordAdapterError("Discord page data must be an array")
    return data


def _optional_mapping(meta: dict[str, Any], field: str) -> dict[str, Any] | None:
    value = meta.get(field)
    if value is not None and not isinstance(value, dict):
        raise DiscordAdapterError(f"Discord {field.replace('_', ' ')} must be an object")
    return value


def _checkpoint_meta(
    payload: dict[str, Any], request: PageRequest
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise DiscordAdapterError("Discord page meta must be an object")
    reject_credentials(meta)
    next_cursor = _optional_mapping(meta, "next_cursor")
    watermark = _optional_mapping(meta, "watermark")
    complete = meta.get("complete")
    snapshot = meta.get("snapshot")
    if not isinstance(complete, bool) or not isinstance(snapshot, bool):
        raise DiscordAdapterError("Discord completion metadata is invalid")
    if snapshot != (not STREAMS[request.stream].incremental):
        raise DiscordAdapterError("Discord snapshot metadata is invalid")
    if complete == (next_cursor is not None):
        raise DiscordAdapterError("Discord page cursor conflicts with completion")
    return next_cursor, watermark, complete


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Validate provider pagination and encode independent stream state."""
    next_cursor, watermark, complete = _checkpoint_meta(payload, request)
    next_value = _encode_state(next_cursor) if next_cursor is not None else None
    watermark_value = (
        _encode_state(watermark) if watermark is not None else state.watermark
    )
    return PageCheckpoint(next_value, watermark_value), complete
