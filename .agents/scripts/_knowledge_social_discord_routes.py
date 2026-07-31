#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted Discord REST and local replay routes."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from _knowledge_social_discord_contract import (
    ApiResult,
    DiscordReadProviderError,
    array_value,
    boolean,
    exact_keys,
    integer,
    object_value,
    observed_at,
    serialize_channel,
    serialize_member,
    serialize_message,
    serialize_role,
    snowflake,
    terminal_payload,
)
from _knowledge_social_discord_export import page_account_export
from _knowledge_social_discord_gateway import page_gateway_events

ApiCall = Callable[[str, dict[str, str]], ApiResult]
STREAMS = {"messages", "metadata", "members", "gateway_events", "account_export"}


@dataclass(frozen=True)
class ProviderPageRequest:
    """Validated parent-to-child page request."""

    stream: str
    config: dict[str, Any]
    cursor: dict[str, Any] | None
    watermark: dict[str, Any] | None
    limit: int


@dataclass(frozen=True)
class SuccessMeta:
    watermark: dict[str, Any] | None
    snapshot: bool
    gaps: list[str] | None = None


def page_request(request: dict[str, Any]) -> ProviderPageRequest:
    exact_keys(
        request,
        {
            "action",
            "stream",
            "bot_id",
            "application_id",
            "guild_id",
            "channel_ids",
            "thread_ids",
            "dm_channel_ids",
            "message_content_intent",
            "guild_members_intent",
            "export_user_id",
            "cursor",
            "watermark",
            "limit",
        },
    )
    stream = request.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise DiscordReadProviderError("Discord read stream is unsupported")
    cursor = request.get("cursor")
    watermark = request.get("watermark")
    if cursor is not None and not isinstance(cursor, dict):
        raise DiscordReadProviderError("Discord read cursor must be an object")
    if watermark is not None and not isinstance(watermark, dict):
        raise DiscordReadProviderError("Discord read watermark must be an object")
    limit = integer(request.get("limit"), "read limit", minimum=1)
    if limit > 100:
        raise DiscordReadProviderError("Discord read limit exceeds 100")

    def ids(field: str) -> tuple[str, ...]:
        value = request.get(field)
        if not isinstance(value, list):
            raise DiscordReadProviderError(f"Discord {field} must be an array")
        result = tuple(snowflake(item, field) or "" for item in value)
        if len(result) != len(set(result)):
            raise DiscordReadProviderError(f"Discord {field} contains duplicates")
        return result

    config = {
        "bot_id": snowflake(request.get("bot_id"), "bot user ID"),
        "application_id": snowflake(request.get("application_id"), "application ID"),
        "guild_id": snowflake(request.get("guild_id"), "guild ID"),
        "channel_ids": ids("channel_ids"),
        "thread_ids": ids("thread_ids"),
        "dm_channel_ids": ids("dm_channel_ids"),
        "message_content_intent": boolean(
            request.get("message_content_intent"), "message-content intent"
        ),
        "guild_members_intent": boolean(
            request.get("guild_members_intent"), "guild-members intent"
        ),
        "export_user_id": snowflake(
            request.get("export_user_id"), "export user ID", optional=True
        ),
    }
    return ProviderPageRequest(stream, config, cursor, watermark, limit)


def _success(
    data: list[dict[str, Any]],
    next_cursor: dict[str, Any] | None,
    meta: SuccessMeta,
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": data,
        "meta": {
            "next_cursor": next_cursor,
            "watermark": meta.watermark,
            "complete": next_cursor is None,
            "snapshot": meta.snapshot,
            "gaps": meta.gaps or [],
        },
    }


def _message_channels(request: ProviderPageRequest) -> tuple[str, ...]:
    return (
        *request.config["channel_ids"],
        *request.config["thread_ids"],
        *request.config["dm_channel_ids"],
    )


def _message_state(
    request: ProviderPageRequest, channels: tuple[str, ...]
) -> tuple[int, str | None, dict[str, str], dict[str, str]]:
    cursor = request.cursor or {"index": 0, "before": None, "newest": {}}
    if set(cursor) != {"index", "before", "newest"}:
        raise DiscordReadProviderError("Discord message cursor is invalid")
    index = integer(cursor.get("index"), "message channel index")
    before = snowflake(cursor.get("before"), "message before cursor", optional=True)
    newest = cursor.get("newest")
    if not isinstance(newest, dict):
        raise DiscordReadProviderError("Discord message watermark is invalid")
    return index, before, newest, _message_watermark(request, channels)


def _message_watermark(
    request: ProviderPageRequest, channels: tuple[str, ...]
) -> dict[str, str]:
    prior = request.watermark or {}
    for key, value in prior.items():
        if key not in channels or not isinstance(value, str) or not value.isdigit():
            raise DiscordReadProviderError("Discord message watermark is invalid")
    return prior


def _bounded_messages(
    records: list[dict[str, Any]], stop_at: str | None
) -> tuple[list[dict[str, Any]], bool]:
    if stop_at is None:
        return records, False
    for index, record in enumerate(records):
        if record["remote_id"] == stop_at:
            return records[:index], True
    return records, False


def _next_message_cursor(
    index: int,
    channels: tuple[str, ...],
    records: list[dict[str, Any]],
    newest: dict[str, str],
    channel_complete: bool,
) -> dict[str, Any] | None:
    if channel_complete:
        next_index = index + 1
        if next_index >= len(channels):
            return None
        return {"index": next_index, "before": None, "newest": newest}
    if not records:
        raise DiscordReadProviderError("Discord message page cannot advance")
    return {"index": index, "before": records[-1]["remote_id"], "newest": newest}


def _message_response(
    api: ApiCall, channel_id: str, limit: int, before: str | None
) -> tuple[dict[str, Any] | None, list[Any], list[dict[str, Any]]]:
    params = {"limit": str(limit)}
    if before is not None:
        params["before"] = before
    result = api(f"/channels/{channel_id}/messages", params)
    if result.status != 200:
        return terminal_payload(result), [], []
    items = array_value(result.payload, "message response")
    records = [serialize_message(item, channel_id) for item in items]
    return None, items, records


def _update_newest(
    newest: dict[str, str],
    channel_id: str,
    before: str | None,
    records: list[dict[str, Any]],
) -> None:
    if before is None and records:
        newest[channel_id] = records[0]["remote_id"]


def _messages(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    channels = _message_channels(request)
    index, before, newest, prior = _message_state(request, channels)
    if index >= len(channels):
        return _success([], None, SuccessMeta({**prior, **newest}, False))
    channel_id = channels[index]
    failure, items, records = _message_response(
        api, channel_id, request.limit, before
    )
    if failure is not None:
        return failure
    _update_newest(newest, channel_id, before, records)
    accepted, reached = _bounded_messages(records, prior.get(channel_id))
    channel_complete = reached or len(items) < request.limit
    next_cursor = _next_message_cursor(
        index, channels, records, newest, channel_complete
    )
    return _success(
        accepted,
        next_cursor,
        SuccessMeta(
            {**prior, **newest} if next_cursor is None else None,
            False,
        ),
    )


def _append_missing_threads(
    api: ApiCall,
    thread_ids: tuple[str, ...],
    listed: set[str],
    guild_id: str,
    data: list[dict[str, Any]],
) -> dict[str, Any] | None:
    for thread_id in thread_ids:
        if thread_id in listed:
            continue
        thread = api(f"/channels/{thread_id}", {})
        if thread.status != 200:
            return terminal_payload(thread)
        data.append(serialize_channel(object_value(thread.payload, "thread"), guild_id))
    return None


def _metadata(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    guild_id = request.config["guild_id"]
    channels = api(f"/guilds/{guild_id}/channels", {})
    if channels.status != 200:
        return terminal_payload(channels)
    roles = api(f"/guilds/{guild_id}/roles", {})
    if roles.status != 200:
        return terminal_payload(roles)
    allowed_channels = {
        *request.config["channel_ids"],
        *request.config["thread_ids"],
    }
    data = [
        serialize_channel(item, guild_id)
        for item in array_value(channels.payload, "guild channels")
        if item.get("id") in allowed_channels
    ]
    listed = {item["remote_id"] for item in data}
    thread_failure = _append_missing_threads(
        api, request.config["thread_ids"], listed, guild_id, data
    )
    if thread_failure is not None:
        return thread_failure
    data.extend(
        serialize_role(item, guild_id)
        for item in array_value(roles.payload, "guild roles")
    )
    data.append({"kind": "guild", "remote_id": guild_id})
    return _success(data, None, SuccessMeta(None, True))


def _members(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    if not request.config["guild_members_intent"]:
        return _success(
            [],
            None,
            SuccessMeta(None, True, ["guild_members_intent_not_enabled"]),
        )
    cursor = request.cursor or {"after": None}
    if set(cursor) != {"after"}:
        raise DiscordReadProviderError("Discord member cursor is invalid")
    after = snowflake(cursor.get("after"), "member cursor", optional=True)
    params = {"limit": str(request.limit)}
    if after is not None:
        params["after"] = after
    result = api(f"/guilds/{request.config['guild_id']}/members", params)
    if result.status != 200:
        return terminal_payload(result)
    items = array_value(result.payload, "guild members")
    data = [serialize_member(item, request.config["guild_id"]) for item in items]
    next_cursor = {"after": data[-1]["remote_id"]} if len(items) == request.limit else None
    return _success(data, next_cursor, SuccessMeta(None, True))


def page(
    api: ApiCall,
    request: ProviderPageRequest,
    *,
    export_path: str | None,
    gateway_path: str | None,
) -> dict[str, Any]:
    """Dispatch one request through an explicit read-only route."""
    def gateway_events() -> dict[str, Any]:
        data, next_cursor, watermark = page_gateway_events(
            gateway_path,
            request.config,
            request.cursor or request.watermark,
            request.limit,
        )
        return _success(data, next_cursor, SuccessMeta(watermark, False))

    def account_export() -> dict[str, Any]:
        data, next_cursor = page_account_export(
            export_path, request.config, request.cursor, request.limit
        )
        return _success(data, next_cursor, SuccessMeta(None, True))

    handlers: dict[str, Callable[[], dict[str, Any]]] = {
        "messages": lambda: _messages(api, request),
        "metadata": lambda: _metadata(api, request),
        "members": lambda: _members(api, request),
        "gateway_events": gateway_events,
        "account_export": account_export,
    }
    handler = handlers.get(request.stream)
    if handler is None:
        raise DiscordReadProviderError("Discord read stream is unsupported")
    return handler()
