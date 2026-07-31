#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Identity checks and allowlisted serializers for Nextcloud Talk OCS reads."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Callable

from _knowledge_social_nextcloud_talk import (
    PageRequest,
    namespaced_id,
    private_fingerprint,
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

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]
REQUIRED_FEATURES = frozenset({"chat-v2", "conversation-v4"})


def _timestamp(value: Any, field: str) -> str | None:
    seconds = non_negative(value, field, optional=True)
    if seconds is None:
        return None
    return datetime.fromtimestamp(seconds, UTC).isoformat().replace("+00:00", "Z")


def room_id(config: ProfileConfig, token: str) -> str:
    digest = private_fingerprint(config.origin_key, config.instance_id, "room", token)
    return f"nct_{config.instance_id}_room_{digest}"


def _account_id(config: ProfileConfig, username: str) -> str:
    digest = private_fingerprint(config.origin_key, config.instance_id, "user", username)
    return f"nct_{config.instance_id}_user_{digest}"


def _version_major(value: Any, field: str) -> tuple[int, str]:
    if isinstance(value, dict):
        major = non_negative(value.get("major"), f"{field} major")
        rendered = optional_text(value.get("string"), f"{field} version", limit=64)
        if major is None:
            raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} version is missing")
        return major, rendered or str(major)
    rendered = required_text(value, f"{field} version", limit=64)
    try:
        major = int(rendered.split(".", 1)[0])
    except ValueError as error:
        raise NextcloudTalkReadProviderError(
            f"Nextcloud Talk {field} version is invalid"
        ) from error
    return major, rendered


def _capabilities(api: Api, config: ProfileConfig) -> dict[str, Any] | ApiResult:
    result = api("/ocs/v2.php/cloud/capabilities", {})
    if result.status != 200:
        return result
    data = object_value(ocs_data(result.payload, "capabilities"), "capabilities data")
    server_major, server_version = _version_major(data.get("version"), "server")
    capabilities = object_value(data.get("capabilities"), "capabilities map")
    talk = object_value(capabilities.get("spreed"), "Talk capabilities")
    talk_major, talk_version = _version_major(talk.get("version"), "app")
    features_value = talk.get("features")
    if not isinstance(features_value, list) or any(
        not isinstance(feature, str) for feature in features_value
    ):
        raise NextcloudTalkReadProviderError("Nextcloud Talk features are invalid")
    features = frozenset(features_value)
    if server_major != config.expected_server_major or talk_major != config.expected_talk_major:
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk server or app version changed from the configured profile"
        )
    if not REQUIRED_FEATURES.issubset(features):
        raise NextcloudTalkReadProviderError("Nextcloud Talk required read APIs are unavailable")
    allowed_features = sorted(
        features
        & {
            "bots-v1",
            "chat-get-context",
            "chat-keep-notifications",
            "chat-replies",
            "conversation-v4",
            "edit-messages",
            "federation-v1",
            "markdown-messages",
            "message-expiration",
            "reactions",
            "rich-object-list-media",
            "system-messages",
            "talk-polls",
            "threads",
        }
    )
    return {
        "server_major": server_major,
        "server_version": server_version,
        "talk_major": talk_major,
        "talk_version": talk_version,
        "features": allowed_features,
    }


def _selected_user(api: Api, config: ProfileConfig, expected_selector: str) -> dict[str, Any] | ApiResult:
    result = api("/ocs/v2.php/cloud/user", {})
    if result.status != 200:
        return result
    data = object_value(ocs_data(result.payload, "current user"), "current user data")
    username = required_text(data.get("id"), "current user ID", limit=191)
    if expected_selector.removeprefix("user_") != username:
        raise NextcloudTalkReadProviderError(
            "selected Nextcloud Talk account does not match the profile"
        )
    return {
        "id": _account_id(config, username),
        "provider_account_id": private_fingerprint(
            config.origin_key, config.instance_id, "account", username
        ),
        "display_name": optional_text(data.get("display-name"), "display name"),
    }


def _room_record(config: ProfileConfig, value: dict[str, Any]) -> dict[str, Any]:
    token = required_text(value.get("token"), "room token", limit=64)
    if token not in config.allowed_rooms:
        raise NextcloudTalkReadProviderError("Nextcloud Talk returned a non-allowlisted room")
    return {
        "kind": "conversation",
        "remote_id": room_id(config, token),
        "name": optional_text(
            value.get("displayName", value.get("name")), "room name", limit=512
        ),
        "room_type": non_negative(value.get("type"), "room type", optional=True),
        "participant_type": non_negative(
            value.get("participantType"), "participant type", optional=True
        ),
        "read_only": non_negative(value.get("readOnly"), "room read-only", optional=True),
        "message_expiration": non_negative(
            value.get("messageExpiration"), "message expiration", optional=True
        ),
        "last_activity": _timestamp(value.get("lastActivity"), "room last activity"),
        "has_call": boolean(value.get("hasCall"), "room call state", optional=True),
        "unread_messages": non_negative(
            value.get("unreadMessages"), "unread message count", optional=True
        ),
        "federated": value.get("remoteServer") is not None,
    }


def _rooms(api: Api, config: ProfileConfig) -> list[dict[str, Any]] | ApiResult:
    result = api(
        "/ocs/v2.php/apps/spreed/api/v4/room",
        {"includeStatus": "false", "noStatusUpdate": "1"},
    )
    if result.status != 200:
        return result
    source = object_list(ocs_data(result.payload, "room list"), "room list", limit=500)
    by_token = {
        required_text(item.get("token"), "room token", limit=64): item for item in source
    }
    if any(token not in by_token for token in config.allowed_rooms):
        raise NextcloudTalkReadProviderError(
            "configured Nextcloud Talk room is unavailable to the selected account"
        )
    return [_room_record(config, by_token[token]) for token in config.allowed_rooms]


def identity(api: Api, config: ProfileConfig, expected_selector: str) -> dict[str, Any] | ApiResult:
    """Verify versions, account, and complete room allowlist before collection."""
    capabilities = _capabilities(api, config)
    if isinstance(capabilities, ApiResult):
        return capabilities
    account = _selected_user(api, config, expected_selector)
    if isinstance(account, ApiResult):
        return account
    rooms = _rooms(api, config)
    if isinstance(rooms, ApiResult):
        return rooms
    return {
        **account,
        "instance_id": config.instance_id,
        "room_ids": [room["remote_id"] for room in rooms],
        "rooms": rooms,
        **capabilities,
    }


def _meta(
    request: PageRequest,
    records: list[dict[str, Any]],
    *,
    next_room_index: int,
    next_position: int,
    complete: bool,
    final_room: bool = False,
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
        next_room_index = request.room_index + 1
        next_position = 0
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": accepted,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "room_id": request.room_id,
            "next_room_index": next_room_index,
            "next_position": next_position,
            "newest_id": records[0].get("remote_id") if records else None,
            "reached_watermark": reached,
            "complete": complete or (reached and final_room),
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
        next_room_index=next_room,
        next_position=0,
        complete=complete,
        final_room=complete,
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
    reactions = value.get("reactions", {})
    if not isinstance(reactions, dict) or any(
        not isinstance(key, str)
        or isinstance(count, bool)
        or not isinstance(count, int)
        or count < 0
        for key, count in reactions.items()
    ):
        raise NextcloudTalkReadProviderError("Nextcloud Talk reaction summary is invalid")
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
        "reactions": dict(sorted(reactions.items())),
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
            next_room_index=next_room,
            next_position=0,
            complete=complete,
            final_room=complete,
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
        next_room_index=request.room_index,
        next_position=next_position,
        complete=False,
        final_room=request.room_index + 1 >= len(config.allowed_rooms),
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
        return _meta(request, [record], next_room_index=0, next_position=0, complete=True)
    if request.stream == "rooms":
        return _meta(
            request,
            list(verified["rooms"]),
            next_room_index=0,
            next_position=0,
            complete=True,
        )
    if request.stream == "participants":
        return _participants(api, config, request)
    return _messages(api, config, request)
