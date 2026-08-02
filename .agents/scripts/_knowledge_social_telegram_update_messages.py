#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Message projections for Telegram Bot API update fan-out."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_telegram_contract import (
    canonical_user_id,
    message_text,
    normalized_time,
    require_object,
    stable_id,
)
from knowledge_social_store import SocialStoreError


SERVICE_EVENT_FIELDS = frozenset(
    (
        "boost_added channel_chat_created chat_background_set delete_chat_photo "
        "forum_topic_closed forum_topic_created forum_topic_edited "
        "forum_topic_reopened general_forum_topic_hidden "
        "general_forum_topic_unhidden group_chat_created left_chat_member "
        "message_auto_delete_timer_changed migrate_from_chat_id "
        "migrate_to_chat_id new_chat_members new_chat_photo new_chat_title "
        "pinned_message proximity_alert_triggered supergroup_chat_created "
        "video_chat_ended video_chat_participants_invited "
        "video_chat_scheduled video_chat_started"
    ).split()
)
SERVICE_TOPIC_FIELDS = ("forum_topic_created", "forum_topic_edited")


@dataclass
class UpdateMessageContext:
    observed_at: str
    accounts: dict[str, dict[str, Any]]


def chat_id(message: dict[str, Any]) -> str:
    chat = require_object(message.get("chat"), "message chat")
    return stable_id(chat.get("id"), "chat ID")


def assert_allowed(selected_chat: str, allowed: frozenset[str]) -> None:
    if not allowed or selected_chat not in allowed:
        raise SocialStoreError("Telegram update chat is not explicitly allowlisted")


def _optional_string(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _sender(
    message: dict[str, Any], update_id: int, fanout_sequence: int, observed_at: str
) -> dict[str, Any] | None:
    raw = message.get("from")
    if not isinstance(raw, dict) or raw.get("id") is None:
        return None
    user_id = canonical_user_id(raw["id"])
    names = [_optional_string(raw.get(key)) or "" for key in ("first_name", "last_name")]
    return {
        "remote_id": user_id,
        "handle": _optional_string(raw.get("username")),
        "display_name": " ".join(part for part in names if part) or None,
        "observed_at": observed_at,
        "provider_json": {
            "source": "telegram_bot_api_update",
            "update_id": update_id,
            "fanout_sequence": fanout_sequence,
        },
    }


def _media_values(message: dict[str, Any]) -> list[dict[str, Any]]:
    keys = ("animation", "audio", "document", "sticker", "video", "video_note", "voice")
    values = [message[key] for key in keys if isinstance(message.get(key), dict)]
    photos = message.get("photo")
    if isinstance(photos, list) and photos and isinstance(photos[-1], dict):
        values.append(photos[-1])
    return values


def _media_record(
    value: dict[str, Any], object_id: str, fanout_sequence: int
) -> dict[str, Any] | None:
    unique = value.get("file_unique_id")
    if not isinstance(unique, str) or not unique:
        return None
    return {
        "remote_id": f"attachment:{object_id}:bot-file:{unique}",
        "object_remote_id": object_id,
        "content_sha256": None,
        "mime_type": _optional_string(value.get("mime_type")),
        "byte_size": value.get("file_size") if isinstance(value.get("file_size"), int) else None,
        "blob_ref": None,
        "hydration_state": "remote_only",
        "_fanout_sequence": fanout_sequence,
    }


def _message_media(
    message: dict[str, Any], object_id: str, fanout_sequence: int
) -> list[dict[str, Any]]:
    records = [
        _media_record(value, object_id, fanout_sequence)
        for value in _media_values(message)
    ]
    return [record for record in records if record is not None]


def _message_metadata(
    message: dict[str, Any], update_type: str, update_id: int, fanout_sequence: int
) -> dict[str, Any]:
    selected = {
        "source": "telegram_bot_api_update",
        "update_type": update_type,
        "chat_type": require_object(message.get("chat"), "message chat").get("type"),
        "update_id": update_id,
        "fanout_sequence": fanout_sequence,
    }
    for key in ("message_thread_id", "is_topic_message", "edit_date"):
        if key in message:
            selected[key] = message[key]
    _add_reply_metadata(selected, message)
    _add_poll_metadata(selected, message)
    _add_service_metadata(selected, message)
    return selected


def _add_reply_metadata(selected: dict[str, Any], message: dict[str, Any]) -> None:
    reply = message.get("reply_to_message")
    if isinstance(reply, dict) and reply.get("message_id") is not None:
        selected["reply_to_message_id"] = stable_id(reply["message_id"], "reply message ID")
    quote = message.get("quote")
    if isinstance(quote, dict):
        selected["quote"] = {
            "text": _optional_string(quote.get("text")),
            "position": quote.get("position") if isinstance(quote.get("position"), int) else None,
        }


def _add_poll_metadata(selected: dict[str, Any], message: dict[str, Any]) -> None:
    poll = message.get("poll")
    if not isinstance(poll, dict):
        return
    selected["poll"] = {
        "id": poll.get("id"),
        "question": poll.get("question"),
        "is_closed": poll.get("is_closed"),
    }


def _service_member_ids(message: dict[str, Any]) -> list[str]:
    member_ids: list[str] = []
    joined = message.get("new_chat_members")
    if joined is not None:
        if not isinstance(joined, list):
            raise SocialStoreError("Telegram new chat members must be an array")
        for value in joined:
            member = require_object(value, "new chat member")
            member_ids.append(canonical_user_id(member.get("id")))
    departed = message.get("left_chat_member")
    if departed is not None:
        member = require_object(departed, "left chat member")
        member_ids.append(canonical_user_id(member.get("id")))
    return sorted(set(member_ids))


def _service_topic_names(message: dict[str, Any]) -> dict[str, str]:
    names: dict[str, str] = {}
    for field in SERVICE_TOPIC_FIELDS:
        if field not in message:
            continue
        topic = require_object(message[field], field.replace("_", " "))
        name = topic.get("name")
        if name is not None and not isinstance(name, str):
            raise SocialStoreError("Telegram forum topic name must be text")
        if name:
            names[field] = name
    return names


def _add_service_metadata(selected: dict[str, Any], message: dict[str, Any]) -> None:
    events = sorted(SERVICE_EVENT_FIELDS.intersection(message))
    if not events:
        return
    selected["service_events"] = events
    member_ids = _service_member_ids(message)
    if member_ids:
        selected["service_member_ids"] = member_ids
    topic_names = _service_topic_names(message)
    if topic_names:
        selected["service_topic_names"] = topic_names


def message_object(
    fanout_sequence: int,
    update_id: int,
    update_type: str,
    message: dict[str, Any],
    context: UpdateMessageContext,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    selected_chat = chat_id(message)
    message_id = stable_id(message.get("message_id"), "message ID")
    unsupported_context = any(
        field in message
        for field in ("business_connection_id", "guest_query_id", "ephemeral_message_id")
    )
    if message_id == "0" or unsupported_context:
        raise SocialStoreError(
            "Telegram contextual message identity is unsupported without collision-free scope"
        )
    object_id = f"chat:{selected_chat}:message:{message_id}"
    account = _sender(message, update_id, fanout_sequence, context.observed_at)
    sender_id = account["remote_id"] if account is not None else None
    if account is not None:
        context.accounts[sender_id] = account
    record = {
        "object_type": "message",
        "remote_id": object_id,
        "account_remote_id": sender_id,
        "text": message_text(message.get("text")) or message_text(message.get("caption")),
        "created_at": normalized_time(None, message.get("date"), "message date"),
        "observed_at": context.observed_at,
        "evidence_class": "authored" if sender_id else "observed",
        "provider_json": _message_metadata(
            message, update_type, update_id, fanout_sequence
        ),
    }
    return record, _message_media(message, object_id, fanout_sequence)
