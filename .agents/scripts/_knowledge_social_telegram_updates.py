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
    canonical_json,
    canonical_user_id,
    coverage_record,
    finalize_archive,
    message_text,
    normalized_time,
    read_bounded_path,
    require_list,
    require_object,
    stable_id,
)
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError

MESSAGE_UPDATES = {
    "message",
    "edited_message",
    "channel_post",
    "edited_channel_post",
}
ACTIVITY_UPDATES = {
    "deleted_business_messages",
    "message_reaction",
    "message_reaction_count",
    "my_chat_member",
    "chat_member",
    "chat_join_request",
}


def _read_updates(request: TelegramRequest) -> tuple[dict[str, Any], bytes]:
    path = request.path
    payload = read_bounded_path(path, request.max_bytes, "update fan-out")
    try:
        root = require_object(json.loads(payload.decode("utf-8")), "update envelope")
    except (UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("Telegram update fan-out is not valid UTF-8 JSON") from error
    allowed_fields = {
        "schema",
        "delivery",
        "authenticity_verified",
        "owner_id",
        "observed_at",
        "privacy_mode",
        "installed_at",
        "chat_authority",
        "allowed_updates",
        "bot",
        "updates",
    }
    if set(root) - allowed_fields:
        raise SocialStoreError("Telegram update fan-out contains unscoped envelope data")
    reject_credentials(root)
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


def _sender(
    message: dict[str, Any],
    observed_at: str,
    update_id: int,
    fanout_sequence: int,
) -> dict[str, Any] | None:
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
        "provider_json": {
            "source": "telegram_bot_api_update",
            "update_id": update_id,
            "fanout_sequence": fanout_sequence,
        },
    }


def _message_media(
    message: dict[str, Any], object_id: str, fanout_sequence: int
) -> list[dict[str, Any]]:
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
                "remote_id": f"attachment:{object_id}:bot-file:{unique}",
                "object_remote_id": object_id,
                "content_sha256": None,
                "mime_type": value.get("mime_type") if isinstance(value.get("mime_type"), str) else None,
                "byte_size": value.get("file_size") if isinstance(value.get("file_size"), int) else None,
                "blob_ref": None,
                "hydration_state": "remote_only",
                "_fanout_sequence": fanout_sequence,
            }
        )
    return records


def _message_object(
    fanout_sequence: int,
    update_id: int,
    update_type: str,
    message: dict[str, Any],
    observed_at: str,
    accounts: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    chat_id = _chat_id(message)
    message_id = stable_id(message.get("message_id"), "message ID")
    if message_id == "0" or any(
        field in message
        for field in (
            "business_connection_id",
            "guest_query_id",
            "ephemeral_message_id",
        )
    ):
        raise SocialStoreError(
            "Telegram contextual message identity is unsupported without collision-free scope"
        )
    object_id = f"chat:{chat_id}:message:{message_id}"
    account = _sender(message, observed_at, update_id, fanout_sequence)
    sender_id = None
    if account is not None:
        sender_id = account["remote_id"]
        accounts[sender_id] = account
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
    reply = message.get("reply_to_message")
    if isinstance(reply, dict) and reply.get("message_id") is not None:
        selected["reply_to_message_id"] = stable_id(
            reply["message_id"], "reply message ID"
        )
    quote = message.get("quote")
    if isinstance(quote, dict):
        selected["quote"] = {
            "text": quote.get("text") if isinstance(quote.get("text"), str) else None,
            "position": quote.get("position")
            if isinstance(quote.get("position"), int)
            else None,
        }
    poll = message.get("poll")
    if isinstance(poll, dict):
        selected["poll"] = {
            "id": poll.get("id"),
            "question": poll.get("question"),
            "is_closed": poll.get("is_closed"),
        }
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
    return record, _message_media(message, object_id, fanout_sequence)


def _activity_records(
    update_type: str,
    payload: dict[str, Any],
    update_id: int,
    fanout_sequence: int,
    observed_at: str,
) -> tuple[list[dict[str, Any]], str]:
    chat = payload.get("chat")
    chat_id = stable_id(chat.get("id"), "chat ID") if isinstance(chat, dict) else None
    if chat_id is None:
        raise SocialStoreError("Telegram update cannot be bound to an allowlisted chat")
    actor = payload.get("user") or payload.get("from")
    actor_chat = payload.get("actor_chat")
    if isinstance(actor, dict) and actor.get("id") is not None:
        actor_id = canonical_user_id(actor["id"])
    elif isinstance(actor_chat, dict) and actor_chat.get("id") is not None:
        actor_id = f"actor_chat:{stable_id(actor_chat['id'], 'actor chat ID')}"
    else:
        actor_id = "telegram_system"
    common: dict[str, Any] = {
        "source": "telegram_bot_api_update",
        "update_id": update_id,
        "fanout_sequence": fanout_sequence,
    }
    if isinstance(actor_chat, dict) and actor_chat.get("id") is not None:
        common["actor_chat_id"] = stable_id(actor_chat["id"], "actor chat ID")
    if update_type in ("message_reaction", "message_reaction_count"):
        common["old_reaction"] = payload.get("old_reaction", [])
        common["new_reaction"] = payload.get("new_reaction", payload.get("reactions", []))
    if update_type in ("chat_member", "my_chat_member"):
        for field in ("old_chat_member", "new_chat_member"):
            member = payload.get(field)
            if isinstance(member, dict):
                affected = member.get("user")
                common[field] = {
                    "status": member.get("status"),
                    "user_id": canonical_user_id(affected["id"])
                    if isinstance(affected, dict) and affected.get("id") is not None
                    else None,
                }
    message_ids = payload.get("message_ids") if update_type == "deleted_business_messages" else None
    if message_ids is not None:
        values = require_list(message_ids, "deleted business message IDs")
        business_id = stable_id(
            payload.get("business_connection_id"), "business connection ID"
        )
        records = []
        for value in values:
            message_id = stable_id(value, "deleted message ID")
            records.append(
                {
                    "activity_type": update_type,
                    "remote_id": f"update:{update_id}:{update_type}:{message_id}",
                    "actor_remote_id": actor_id,
                    "object_remote_id": f"business:{business_id}:chat:{chat_id}:message:{message_id}",
                    "occurred_at": None,
                    "observed_at": observed_at,
                    "state": "deleted",
                    "provider_json": common,
                }
            )
        return records, chat_id
    message_id = payload.get("message_id")
    object_id = (
        f"chat:{chat_id}:message:{stable_id(message_id, 'message ID')}"
        if message_id is not None
        else None
    )
    return (
        [
            {
                "activity_type": update_type,
                "remote_id": f"update:{update_id}:{update_type}",
                "actor_remote_id": actor_id,
                "object_remote_id": object_id,
                "occurred_at": normalized_time(
                    None, payload.get("date"), "activity date"
                )
                if payload.get("date") is not None
                else None,
                "observed_at": observed_at,
                "state": "observed",
                "provider_json": common,
            }
        ],
        chat_id,
    )


def parse_telegram_updates(request: TelegramRequest) -> ParsedTelegramBatch:
    """Validate one existing owner's append-only update fan-out without API access."""
    root, payload = _read_updates(request)
    observed_at = normalized_time(root.get("observed_at") or request.observed_at, None, "observation time")
    bot = require_object(root.get("bot"), "bot identity")
    if bot.get("is_bot") is not True:
        raise SocialStoreError("Telegram selected Bot API identity is not a bot")
    raw_bot_id = stable_id(bot.get("id"), "bot ID")
    if raw_bot_id != stable_id(request.expected_identity, "expected bot ID"):
        raise SocialStoreError("Telegram bot identity does not match selection")
    owner = stable_id(root.get("owner_id"), "update owner ID")
    if request.expected_owner is None or owner != stable_id(request.expected_owner, "expected owner ID"):
        raise SocialStoreError("Telegram update owner does not match selection")
    privacy_mode = root.get("privacy_mode")
    if privacy_mode not in ("enabled", "disabled", "unknown"):
        raise SocialStoreError("Telegram privacy mode must be explicit")
    installed_at = normalized_time(root.get("installed_at"), None, "bot installation time")
    authority = require_object(root.get("chat_authority"), "chat authority")
    if set(authority) != request.allowed_chats:
        raise SocialStoreError("Telegram chat authority must exactly match the allowlist")
    normalized_authority: dict[str, dict[str, Any]] = {}
    for chat_id, raw_authority in authority.items():
        record = require_object(raw_authority, "chat authority record")
        status = record.get("member_status")
        if status not in ("member", "administrator", "creator", "unknown"):
            raise SocialStoreError("Telegram chat membership authority is invalid")
        normalized_authority[chat_id] = {
            "member_status": status,
            "can_read_all_group_messages": record.get("can_read_all_group_messages")
            if isinstance(record.get("can_read_all_group_messages"), bool)
            else None,
            "history_visible": record.get("history_visible")
            if isinstance(record.get("history_visible"), bool)
            else None,
        }
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
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    media: list[dict[str, Any]] = []
    updates_by_sequence: dict[int, dict[str, Any]] = {}
    updates_by_id: dict[int, dict[str, Any]] = {}
    update_types: set[str] = set()
    for raw_update in require_list(root.get("updates"), "updates"):
        update = require_object(raw_update, "update")
        update_id = update.get("update_id")
        if isinstance(update_id, bool) or not isinstance(update_id, int) or update_id < 0:
            raise SocialStoreError("Telegram update ID is invalid")
        fanout_sequence = update.get("fanout_sequence")
        if (
            isinstance(fanout_sequence, bool)
            or not isinstance(fanout_sequence, int)
            or fanout_sequence < 1
        ):
            raise SocialStoreError("Telegram fan-out sequence is invalid")
        previous_id = updates_by_id.get(update_id)
        if previous_id is not None:
            if canonical_json(previous_id) != canonical_json(update):
                raise SocialStoreError(
                    "Telegram update ID has conflicting duplicate payloads or sequences"
                )
            continue
        previous = updates_by_sequence.get(fanout_sequence)
        if previous is not None:
            if canonical_json(previous) != canonical_json(update):
                raise SocialStoreError(
                    "Telegram fan-out sequence has conflicting duplicate payloads"
                )
            continue
        updates_by_sequence[fanout_sequence] = update
        updates_by_id[update_id] = update
    for fanout_sequence in sorted(updates_by_sequence):
        update = updates_by_sequence[fanout_sequence]
        update_id = int(update["update_id"])
        kinds = [
            key for key in update if key not in ("update_id", "fanout_sequence")
        ]
        if len(kinds) != 1:
            raise SocialStoreError("Telegram update must contain exactly one update type")
        update_type = kinds[0]
        update_types.add(update_type)
        value = require_object(update[update_type], f"{update_type} update")
        if update_type in MESSAGE_UPDATES:
            chat_id = _chat_id(value)
            _assert_allowed(chat_id, request.allowed_chats)
            record, found_media = _message_object(
                fanout_sequence,
                update_id,
                update_type,
                value,
                observed_at,
                accounts,
            )
            objects.append(record)
            media.extend(found_media)
        elif update_type in ACTIVITY_UPDATES:
            records, chat_id = _activity_records(
                update_type, value, update_id, fanout_sequence, observed_at
            )
            _assert_allowed(chat_id, request.allowed_chats)
            activities.extend(records)
        else:
            raise SocialStoreError(
                f"Telegram update type {update_type} has no chat-scoped read-only route"
            )
    subscribed = root.get("allowed_updates")
    if not isinstance(subscribed, list) or any(not isinstance(item, str) for item in subscribed):
        raise SocialStoreError("Telegram allowed_updates must be an explicit array")
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
        coverage_record("polls", "partial", observed_at,
                        "embedded_message_polls_only_chatless_poll_updates_are_rejected"),
        coverage_record("business_guest_ephemeral_messages", "unavailable", observed_at,
                        "contextual_identity_not_enabled_until_collision_free_scoping_exists"),
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
    archive = {
        "provider": PROVIDER,
        "connection_id": request.connection_id,
        "remote_account_id": bot_id,
        "exported_at": observed_at,
        "enabled_streams": ["bot_updates"],
        "policy": {
            "authenticity_verified": True,
            "delivery": "append_only_fanout",
            "network_requests": 0,
            "owner_id": owner,
            "privacy_mode": privacy_mode,
            "installed_at": installed_at,
            "chat_authority": normalized_authority,
            "schema": UPDATE_SCHEMA,
            "allowed_updates": sorted(set(subscribed)),
        },
        "accounts": sorted(accounts.values(), key=lambda row: row["remote_id"]),
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": coverage,
    }
    count = finalize_archive(archive, request.max_items)
    update_ids = tuple(sorted(updates_by_sequence))
    next_offset = None
    if update_ids:
        next_offset = update_ids[0]
        for update_id in update_ids:
            if update_id != next_offset:
                break
            next_offset += 1
    return ParsedTelegramBatch(
        archive,
        payload,
        hashlib.sha256(payload).hexdigest(),
        "bot_updates",
        next_offset,
        update_ids,
        (),
        count,
    )
