#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Version, account, and room identity fences for Nextcloud Talk OCS."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Callable

from _knowledge_social_nextcloud_talk import private_fingerprint
from _knowledge_social_nextcloud_talk_contract import (
    ApiResult,
    NextcloudTalkReadProviderError,
    boolean,
    non_negative,
    object_list,
    object_value,
    ocs_data,
    optional_text,
    required_text,
)
from _knowledge_social_nextcloud_talk_http import ProfileConfig

Api = Callable[[str, dict[str, str]], ApiResult]
REQUIRED_FEATURES = frozenset({"chat-v2", "conversation-v4"})
RECORDED_FEATURES = frozenset(
    {
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
    versions_match = (
        server_major == config.expected_server_major,
        talk_major == config.expected_talk_major,
    )
    if not all(versions_match):
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk server or app version changed from the configured profile"
        )
    if not REQUIRED_FEATURES.issubset(features):
        raise NextcloudTalkReadProviderError("Nextcloud Talk required read APIs are unavailable")
    return {
        "server_major": server_major,
        "server_version": server_version,
        "talk_major": talk_major,
        "talk_version": talk_version,
        "features": sorted(features & RECORDED_FEATURES),
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
