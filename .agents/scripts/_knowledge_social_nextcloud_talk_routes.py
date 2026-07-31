#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted participant and message serializers for Nextcloud Talk OCS."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Callable

from _knowledge_social_nextcloud_talk import (
    PageRequest,
    namespaced_id,
)
from _knowledge_social_nextcloud_talk_contract import (
    ApiResult,
    NextcloudTalkReadProviderError,
    boolean,
    non_negative,
    object_list,
    object_value,
    observed_at,
    ocs_data,
    optional_text,
    required_text,
)
from _knowledge_social_nextcloud_talk_http import ProfileConfig
from _knowledge_social_nextcloud_talk_identity import room_id

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]


def _timestamp(value: Any, field: str) -> str | None:
    seconds = non_negative(value, field, optional=True)
    if seconds is None:
        return None
    return datetime.fromtimestamp(seconds, UTC).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class PageAdvance:
    next_room_index: int
    next_position: int
    complete: bool
    final_room: bool = False


def _meta(
    request: PageRequest,
    records: list[dict[str, Any]],
    advance: PageAdvance,
) -> dict[str, Any]:
    accepted = records
    reached = False
    if request.stop_at is not None:
        for index, record in enumerate(records):
            if record.get("remote_id") == request.stop_at:
                accepted = records[:index]
                reached = True
                break
    if reached:
        advance = PageAdvance(
            request.room_index + 1,
            0,
            advance.complete,
            advance.final_room,
        )
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": accepted,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "room_id": request.room_id,
            "next_room_index": advance.next_room_index,
            "next_position": advance.next_position,
            "newest_id": records[0].get("remote_id") if records else None,
            "reached_watermark": reached,
            "complete": advance.complete or (reached and advance.final_room),
        },
    }


def _room_token(config: ProfileConfig, request: PageRequest) -> str:
    if request.room_index >= len(config.allowed_rooms):
        raise NextcloudTalkReadProviderError("Nextcloud Talk room index is invalid")
    token = config.allowed_rooms[request.room_index]
    if request.room_id != room_id(config, token):
        raise NextcloudTalkReadProviderError("Nextcloud Talk room identity was rebound")
    return token


def _participant(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    actor_type = required_text(value.get("actorType"), "participant actor type", limit=64)
    actor_id = required_text(value.get("actorId"), "participant actor ID", limit=512)
    remote_id = namespaced_id(request.instance_id, "participant", f"{actor_type}:{actor_id}")
    return {
        "kind": "participant",
        "remote_id": remote_id,
        "room_id": request.room_id,
        "actor_type": actor_type,
        "participant_type": non_negative(
            value.get("participantType"), "participant type", optional=True
        ),
        "permissions": non_negative(value.get("permissions"), "participant permissions", optional=True),
        "in_call": non_negative(value.get("inCall"), "participant call state", optional=True),
        "federated": actor_type in {"federated_users", "federated_user"},
        "guest": actor_type in {"guests", "emails"},
    }


def _participants(api: Api, config: ProfileConfig, request: PageRequest) -> PageResult:
    token = _room_token(config, request)
    result = api(f"/ocs/v2.php/apps/spreed/api/v4/room/{token}/participants", {})
    if result.status != 200:
        return result
    source = object_list(ocs_data(result.payload, "participants"), "participants", limit=500)
    records = [_participant(value, request) for value in source]
    next_room = request.room_index + 1
    complete = next_room >= len(config.allowed_rooms)
    return _meta(
        request,
        records,
        PageAdvance(next_room, 0, complete, complete),
    )


def _parameter_records(parameters: Any, request: PageRequest) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if parameters is None:
        return [], []
    values = object_value(parameters, "message parameters")
    if len(values) > 100:
        raise NextcloudTalkReadProviderError("Nextcloud Talk message parameters exceed the limit")
    mentions: list[dict[str, Any]] = []
    attachments: list[dict[str, Any]] = []
    for value in values.values():
        item = object_value(value, "message parameter")
        kind = optional_text(item.get("type"), "parameter type", limit=64)
        native_id = optional_text(item.get("id"), "parameter ID", limit=2048)
        if not kind or not native_id:
            continue
        if kind in {"user", "guest", "federated_user", "call"}:
            mentions.append(
                {
                    "kind": kind,
                    "remote_id": namespaced_id(request.instance_id, kind, native_id),
                }
            )
        if kind in {"file", "deck-card", "voice-message"}:
            size = non_negative(item.get("size"), "attachment size", optional=True)
            attachments.append(
                {
                    "remote_id": namespaced_id(request.instance_id, "attachment", native_id),
                    "mime_type": optional_text(item.get("mimetype"), "attachment MIME type", limit=255),
                    "byte_size": size,
                    "hydration_state": "metadata",
                }
            )
    return mentions, attachments


def _reaction_summary(value: Any) -> dict[str, int]:
    if not isinstance(value, dict):
        raise NextcloudTalkReadProviderError("Nextcloud Talk reaction summary is invalid")
    for key, count in value.items():
        valid_entry = (
            isinstance(key, str),
            isinstance(count, int),
            not isinstance(count, bool),
            isinstance(count, int) and count >= 0,
        )
        if not all(valid_entry):
            raise NextcloudTalkReadProviderError(
                "Nextcloud Talk reaction summary is invalid"
            )
    return dict(sorted(value.items()))


def _message(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    message_id = non_negative(value.get("id"), "message ID")
    if message_id is None:
        raise NextcloudTalkReadProviderError("Nextcloud Talk message ID is missing")
    remote_id = namespaced_id(request.instance_id, "message", f"{request.room_id}:{message_id}")
    parent_value = value.get("parent")
    parent_id = None
    if isinstance(parent_value, dict) and parent_value.get("id") is not None:
        parent_id = namespaced_id(
            request.instance_id,
            "message",
            f"{request.room_id}:{non_negative(parent_value.get('id'), 'parent message ID')}",
        )
    mentions, attachments = _parameter_records(value.get("messageParameters"), request)
    reactions = _reaction_summary(value.get("reactions", {}))
    return {
        "kind": "message",
        "remote_id": remote_id,
        "room_id": request.room_id,
        "actor_id": namespaced_id(
            request.instance_id,
            optional_text(value.get("actorType"), "message actor type", limit=64) or "unknown",
            optional_text(value.get("actorId"), "message actor ID", limit=512) or "unknown",
        ),
        "text": optional_text(value.get("message"), "message text"),
        "created_at": _timestamp(value.get("timestamp"), "message timestamp"),
        "message_type": optional_text(value.get("messageType"), "message type", limit=64),
        "system_message": optional_text(value.get("systemMessage"), "system message", limit=128),
        "parent_id": parent_id,
        "deleted": value.get("messageType") == "comment_deleted",
        "edited_at": _timestamp(value.get("lastEditTimestamp"), "message edit timestamp"),
        "expiration_at": _timestamp(value.get("expirationTimestamp"), "message expiration"),
        "reactions": reactions,
        "mentions": mentions,
        "attachments": attachments,
        "markdown": boolean(value.get("markdown"), "markdown flag", optional=True),
    }


def _messages(api: Api, config: ProfileConfig, request: PageRequest) -> PageResult:
    token = _room_token(config, request)
    params = {
        "includeLastKnown": "0",
        "lastKnownMessageId": str(request.position),
        "limit": str(request.limit),
        "lookIntoFuture": "0",
        "markNotificationsAsRead": "0",
        "noStatusUpdate": "1",
        "setReadMarker": "0",
    }
    result = api(f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}", params)
    if result.status == 304:
        records: list[dict[str, Any]] = []
    elif result.status != 200:
        return result
    else:
        source = object_list(ocs_data(result.payload, "chat history"), "chat history", limit=request.limit)
        records = [_message(value, request) for value in source]
    next_header = result.headers.get("x-chat-last-given")
    if not records or next_header is None:
        next_room = request.room_index + 1
        complete = next_room >= len(config.allowed_rooms)
        return _meta(
            request,
            records,
            PageAdvance(next_room, 0, complete, complete),
        )
    try:
        next_position = int(next_header)
    except ValueError as error:
        raise NextcloudTalkReadProviderError("Nextcloud Talk chat cursor is invalid") from error
    if next_position <= 0 or next_position == request.position:
        raise NextcloudTalkReadProviderError("Nextcloud Talk chat cursor did not advance")
    return _meta(
        request,
        records,
        PageAdvance(
            request.room_index,
            next_position,
            False,
            request.room_index + 1 >= len(config.allowed_rooms),
        ),
    )


def page(
    api: Api,
    config: ProfileConfig,
    request: PageRequest,
    verified: dict[str, Any],
) -> PageResult:
    """Execute one reviewed Talk GET route after identity and room revalidation."""
    if request.stream == "capabilities":
        record = {
            "kind": "installation_capability",
            "remote_id": namespaced_id(request.instance_id, "capability", "talk"),
            "server_major": verified["server_major"],
            "server_version": verified["server_version"],
            "talk_major": verified["talk_major"],
            "talk_version": verified["talk_version"],
            "features": verified["features"],
        }
        return _meta(request, [record], PageAdvance(0, 0, True))
    if request.stream == "rooms":
        return _meta(
            request,
            list(verified["rooms"]),
            PageAdvance(0, 0, True),
        )
    if request.stream == "participants":
        return _participants(api, config, request)
    return _messages(api, config, request)
