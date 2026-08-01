#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize append-only Telegram Bot API update fan-out evidence."""

from __future__ import annotations

import hashlib
import json
from typing import Any

from _knowledge_social_telegram_contract import (
    PROVIDER,
    UPDATE_SCHEMA,
    ParsedTelegramBatch,
    TelegramRequest,
    canonical_user_id,
    coverage_record,
    finalize_archive,
    message_text,
    normalized_time,
    require_list,
    require_object,
    stable_id,
)
from knowledge_social_store import SocialStoreError

MESSAGE_UPDATES = {
    "message",
    "edited_message",
    "channel_post",
    "edited_channel_post",
    "business_message",
    "edited_business_message",
    "guest_message",
}
ACTIVITY_UPDATES = {
    "deleted_business_messages",
    "message_reaction",
    "message_reaction_count",
    "poll_answer",
    "my_chat_member",
    "chat_member",
    "chat_join_request",
}


def _read_updates(request: TelegramRequest) -> tuple[dict[str, Any], bytes]:
    path = request.path
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("Telegram update fan-out must be a regular non-symlink file")
    if path.stat().st_size > request.max_bytes:
        raise SocialStoreError("Telegram update fan-out exceeds the byte budget")
    payload = path.read_bytes()
    try:
        root = require_object(json.loads(payload.decode("utf-8")), "update envelope")
    except (UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("Telegram update fan-out is not valid UTF-8 JSON") from error
    if root.get("schema") != UPDATE_SCHEMA:
        raise SocialStoreError("Telegram update fan-out schema is unsupported")
    if root.get("delivery") != "append_only_fanout":
        raise SocialStoreError("Telegram updates require an existing append-only owner fan-out")
    if root.get("authenticity_verified") is not True:
        raise SocialStoreError("Telegram update fan-out authenticity was not verified upstream")
    return root, payload


def _chat_id(message: dict[str, Any]) -> str:
    chat = require_object(message.get("chat"), "message chat")
    return stable_id(chat.get("id"), "chat ID")


def _assert_allowed(chat_id: str, allowed: frozenset[str]) -> None:
    if not allowed or chat_id not in allowed:
        raise SocialStoreError("Telegram update chat is not explicitly allowlisted")


def _sender(message: dict[str, Any], observed_at: str) -> dict[str, Any] | None:
    raw = message.get("from")
    if not isinstance(raw, dict) or raw.get("id") is None:
        return None
    user_id = canonical_user_id(raw["id"])
    first = raw.get("first_name") if isinstance(raw.get("first_name"), str) else ""
    last = raw.get("last_name") if isinstance(raw.get("last_name"), str) else ""
    return {
        "remote_id": user_id,
        "handle": raw.get("username") if isinstance(raw.get("username"), str) else None,
        "display_name": " ".join(part for part in (first, last) if part) or None,
        "observed_at": observed_at,
        "provider_json": {"source": "telegram_bot_api_update"},
    }


def _message_media(message: dict[str, Any], object_id: str) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    values: list[dict[str, Any]] = []
    for key in ("animation", "audio", "document", "sticker", "video", "video_note", "voice"):
        value = message.get(key)
        if isinstance(value, dict):
            values.append(value)
    photos = message.get("photo")
    if isinstance(photos, list) and photos:
        largest = photos[-1]
        if isinstance(largest, dict):
            values.append(largest)
    for value in values:
        unique = value.get("file_unique_id")
        if not isinstance(unique, str) or not unique:
            continue
        records.append(
            {
                "remote_id": f"bot-file:{unique}",
                "object_remote_id": object_id,
                "content_sha256": None,
                "mime_type": value.get("mime_type") if isinstance(value.get("mime_type"), str) else None,
                "byte_size": value.get("file_size") if isinstance(value.get("file_size"), int) else None,
                "blob_ref": None,
                "hydration_state": "remote_only",
            }
        )
    return records


def _message_object(
    update_type: str,
    message: dict[str, Any],
    observed_at: str,
    accounts: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    chat_id = _chat_id(message)
    message_id = stable_id(message.get("message_id"), "message ID")
    object_id = f"chat:{chat_id}:message:{message_id}"
    account = _sender(message, observed_at)
    sender_id = None
    if account is not None:
        sender_id = account["remote_id"]
        accounts[sender_id] = account
    selected = {
        "source": "telegram_bot_api_update",
        "update_type": update_type,
        "chat_type": require_object(message.get("chat"), "message chat").get("type"),
    }
    for key in (
        "message_thread_id",
        "is_topic_message",
        "edit_date",
        "reply_to_message",
        "external_reply",
        "quote",
        "poll",
    ):
        if key in message:
            selected[key] = message[key]
    created_at = normalized_time(None, message.get("date"), "message date")
    record = {
        "object_type": "message",
        "remote_id": object_id,
        "account_remote_id": sender_id,
        "text": message_text(message.get("text")) or message_text(message.get("caption")),
        "created_at": created_at,
        "observed_at": observed_at,
        "evidence_class": "authored" if sender_id else "observed",
        "provider_json": selected,
    }
    return record, _message_media(message, object_id)


def _activity(
    update_type: str, payload: dict[str, Any], update_id: int, observed_at: str
) -> tuple[dict[str, Any], str | None]:
    chat = payload.get("chat")
    chat_id = stable_id(chat.get("id"), "chat ID") if isinstance(chat, dict) else None
    if chat_id is None and payload.get("chat_id") is not None:
        chat_id = stable_id(payload["chat_id"], "chat ID")
    actor = payload.get("user") or payload.get("from")
    actor_id = (
        canonical_user_id(actor["id"])
        if isinstance(actor, dict) and actor.get("id") is not None
        else "telegram_system"
    )
    message_id = payload.get("message_id")
    object_id = (
        f"chat:{chat_id}:message:{stable_id(message_id, 'message ID')}"
        if chat_id is not None and message_id is not None
        else None
    )
    return (
        {
            "activity_type": update_type,
            "remote_id": f"update:{update_id}:{update_type}",
            "actor_remote_id": actor_id,
            "object_remote_id": object_id,
            "occurred_at": normalized_time(None, payload.get("date"), "activity date")
            if payload.get("date") is not None
            else None,
            "observed_at": observed_at,
            "state": "observed",
            "provider_json": {"source": "telegram_bot_api_update"},
        },
        chat_id,
    )


def _validated_update(raw_update: Any) -> tuple[dict[str, Any], int]:
    update = require_object(raw_update, "update")
    update_id = update.get("update_id")
    if isinstance(update_id, bool) or not isinstance(update_id, int) or update_id < 0:
        raise SocialStoreError("Telegram update ID is invalid")
    return update, update_id


def _parse_update(
    update: dict[str, Any],
    update_id: int,
    observed_at: str,
    allowed_chats: frozenset[str],
    accounts: dict[str, dict[str, Any]],
) -> tuple[str, list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    kinds = [key for key in update if key != "update_id"]
    if len(kinds) != 1:
        raise SocialStoreError("Telegram update must contain exactly one update type")
    update_type = kinds[0]
    value = require_object(update[update_type], f"{update_type} update")
    if update_type in MESSAGE_UPDATES:
        chat_id = _chat_id(value)
        _assert_allowed(chat_id, allowed_chats)
        record, found_media = _message_object(update_type, value, observed_at, accounts)
        return update_type, [record], [], found_media
    if update_type == "poll":
        return update_type, [
            {
                "object_type": "poll",
                "remote_id": f"poll:{stable_id(value.get('id'), 'poll ID')}",
                "account_remote_id": None,
                "text": value.get("question") if isinstance(value.get("question"), str) else None,
                "created_at": None,
                "observed_at": observed_at,
                "evidence_class": "observed",
                "provider_json": {
                    "source": "telegram_bot_api_update",
                    "is_closed": value.get("is_closed"),
                },
            }
        ], [], []
    if update_type in ACTIVITY_UPDATES:
        record, chat_id = _activity(update_type, value, update_id, observed_at)
        if chat_id is not None:
            _assert_allowed(chat_id, allowed_chats)
        return update_type, [], [record], []
    return update_type, [], [
        {
            "activity_type": "unsupported_update_observation",
            "remote_id": f"update:{update_id}:unsupported",
            "actor_remote_id": "telegram_system",
            "object_remote_id": None,
            "occurred_at": None,
            "observed_at": observed_at,
            "state": "observed",
            "provider_json": {
                "source": "telegram_bot_api_update",
                "update_type": update_type,
            },
        }
    ], []


def _parse_updates(
    raw_updates: list[Any],
    observed_at: str,
    allowed_chats: frozenset[str],
    accounts: dict[str, dict[str, Any]],
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[dict[str, Any]],
    set[int],
    set[str],
]:
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    media: list[dict[str, Any]] = []
    update_ids: set[int] = set()
    update_types: set[str] = set()
    for raw_update in raw_updates:
        update, update_id = _validated_update(raw_update)
        if update_id in update_ids:
            raise SocialStoreError("Telegram update fan-out contains a duplicate update ID")
        update_ids.add(update_id)
        update_type, found_objects, found_activities, found_media = _parse_update(
            update, update_id, observed_at, allowed_chats, accounts
        )
        update_types.add(update_type)
        objects.extend(found_objects)
        activities.extend(found_activities)
        media.extend(found_media)
    return objects, activities, media, update_ids, update_types


def _coverage_records(
    subscribed: list[str], update_types: set[str], observed_at: str
) -> list[dict[str, Any]]:
    coverage = [
        coverage_record("bot_updates", "partial", observed_at,
                        "prospective_updates_are_retained_by_telegram_for_at_most_24_hours"),
        coverage_record("pre_install_history", "unavailable", observed_at,
                        "bot_api_has_no_arbitrary_history_route"),
        coverage_record("normal_message_deletions", "unavailable", observed_at,
                        "bot_api_only_exposes_business_message_deletion_updates"),
        coverage_record("secret_chats", "unavailable", observed_at,
                        "bots_cannot_access_secret_chats"),
        coverage_record("stories", "unavailable", observed_at,
                        "bot_api_has_no_general_story_update_stream"),
        coverage_record("participants", "partial", observed_at,
                        "membership_updates_require_admin_rights_and_explicit_subscription"),
        coverage_record("media_bytes", "partial", observed_at,
                        "fanout_preserves_file_metadata_but_performs_no_tokenized_download"),
    ]
    for kind in sorted(set(subscribed) | update_types):
        coverage.append(
            coverage_record(
                f"update_type:{kind}",
                "partial" if kind in subscribed else "observed",
                observed_at,
                "delivery_depends_on_bot_membership_privacy_admin_and_installation_time",
            )
        )
    return coverage


def _observed_at(root: dict[str, Any], request: TelegramRequest) -> str:
    return normalized_time(
        root.get("observed_at") or request.observed_at,
        None,
        "observation time",
    )


def _bot_context(
    root: dict[str, Any], request: TelegramRequest, observed_at: str
) -> tuple[str, str, dict[str, dict[str, Any]]]:
    bot = require_object(root.get("bot"), "bot identity")
    raw_bot_id = stable_id(bot.get("id"), "bot ID")
    if raw_bot_id != stable_id(request.expected_identity, "expected bot ID"):
        raise SocialStoreError("Telegram bot identity does not match selection")
    owner = stable_id(root.get("owner_id"), "update owner ID")
    if request.expected_owner is None or owner != stable_id(request.expected_owner, "expected owner ID"):
        raise SocialStoreError("Telegram update owner does not match selection")
    bot_id = canonical_user_id(f"bot{raw_bot_id}", "bot ID")
    accounts: dict[str, dict[str, Any]] = {
        bot_id: {
            "remote_id": bot_id,
            "handle": bot.get("username") if isinstance(bot.get("username"), str) else None,
            "display_name": bot.get("first_name") if isinstance(bot.get("first_name"), str) else None,
            "observed_at": observed_at,
            "provider_json": {"source": "telegram_bot_api_identity", "is_bot": True},
        }
    }
    return bot_id, owner, accounts


def _allowed_updates(root: dict[str, Any]) -> list[str]:
    subscribed = root.get("allowed_updates")
    if not isinstance(subscribed, list) or any(not isinstance(item, str) for item in subscribed):
        raise SocialStoreError("Telegram allowed_updates must be an explicit array")
    return subscribed


def _policy(
    root: dict[str, Any], owner: str, subscribed: list[str]
) -> dict[str, Any]:
    return {
        "authenticity_verified": True,
        "delivery": "append_only_fanout",
        "network_requests": 0,
        "owner_id": owner,
        "privacy_mode": root.get("privacy_mode")
        if root.get("privacy_mode") in ("enabled", "disabled", "unknown")
        else "unknown",
        "schema": UPDATE_SCHEMA,
        "allowed_updates": sorted(set(subscribed)),
    }


def parse_telegram_updates(request: TelegramRequest) -> ParsedTelegramBatch:
    """Validate one existing owner's append-only update fan-out without API access."""
    root, payload = _read_updates(request)
    observed_at = _observed_at(root, request)
    bot_id, owner, accounts = _bot_context(root, request, observed_at)
    subscribed = _allowed_updates(root)
    objects, activities, media, update_ids, update_types = _parse_updates(
        require_list(root.get("updates"), "updates"),
        observed_at,
        request.allowed_chats,
        accounts,
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": request.connection_id,
        "remote_account_id": bot_id,
        "exported_at": observed_at,
        "enabled_streams": ["bot_updates"],
        "policy": _policy(root, owner, subscribed),
        "accounts": sorted(accounts.values(), key=lambda row: row["remote_id"]),
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": _coverage_records(subscribed, update_types, observed_at),
    }
    count = finalize_archive(archive, request.max_items)
    return ParsedTelegramBatch(
        archive,
        payload,
        hashlib.sha256(payload).hexdigest(),
        "bot_updates",
        max(update_ids) + 1 if update_ids else None,
        (),
        count,
    )
