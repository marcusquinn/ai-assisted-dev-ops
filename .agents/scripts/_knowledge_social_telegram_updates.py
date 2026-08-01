#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize append-only Telegram Bot API update fan-out evidence."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_telegram_contract import (
    CoverageDetail,
    PROVIDER,
    UPDATE_SCHEMA,
    ParsedTelegramBatch,
    TelegramRequest,
    canonical_json,
    canonical_user_id,
    coverage_record,
    finalize_archive,
    normalized_time,
    read_bounded_path,
    require_list,
    require_object,
    stable_id,
)
from _knowledge_social_telegram_update_activities import activity_records
from _knowledge_social_telegram_update_messages import (
    UpdateMessageContext,
    assert_allowed,
    chat_id,
    message_object,
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


@dataclass
class _UpdateEnvelope:
    observed_at: str
    bot_id: str
    owner: str
    privacy_mode: str
    installed_at: str
    authority: dict[str, dict[str, Any]]
    accounts: dict[str, dict[str, Any]]


def _optional_bool(value: Any) -> bool | None:
    return value if isinstance(value, bool) else None


def _chat_authority(
    request: TelegramRequest, root: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    if not request.allowed_chats:
        raise SocialStoreError("Telegram updates require an explicit chat allowlist")
    authority = require_object(root.get("chat_authority"), "chat authority")
    if set(authority) != request.allowed_chats:
        raise SocialStoreError("Telegram chat authority must exactly match the allowlist")
    normalized = {}
    for selected_chat, raw_authority in authority.items():
        record = require_object(raw_authority, "chat authority record")
        status = record.get("member_status")
        if status not in ("member", "administrator", "creator", "unknown"):
            raise SocialStoreError("Telegram chat membership authority is invalid")
        normalized[selected_chat] = {
            "member_status": status,
            "can_read_all_group_messages": _optional_bool(
                record.get("can_read_all_group_messages")
            ),
            "history_visible": _optional_bool(record.get("history_visible")),
        }
    return normalized


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    return value if isinstance(value, str) else None


def _bot_account(
    bot: dict[str, Any], bot_id: str, observed_at: str
) -> dict[str, Any]:
    return {
        "remote_id": bot_id,
        "handle": _optional_text(bot, "username"),
        "display_name": _optional_text(bot, "first_name"),
        "observed_at": observed_at,
        "provider_json": {"source": "telegram_bot_api_identity", "is_bot": True},
    }


def _update_envelope(request: TelegramRequest, root: dict[str, Any]) -> _UpdateEnvelope:
    observed_at = normalized_time(
        root.get("observed_at") or request.observed_at, None, "observation time"
    )
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
    bot_id = canonical_user_id(f"bot{raw_bot_id}", "bot ID")
    account = _bot_account(bot, bot_id, observed_at)
    return _UpdateEnvelope(
        observed_at,
        bot_id,
        owner,
        privacy_mode,
        installed_at,
        _chat_authority(request, root),
        {bot_id: account},
    )


def _update_number(update: dict[str, Any], key: str, minimum: int) -> int:
    value = update.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        label = "update ID" if key == "update_id" else "fan-out sequence"
        raise SocialStoreError(f"Telegram {label} is invalid")
    return value


def _deduplicated_updates(root: dict[str, Any]) -> dict[int, dict[str, Any]]:
    by_sequence: dict[int, dict[str, Any]] = {}
    by_id: dict[int, dict[str, Any]] = {}
    for raw_update in require_list(root.get("updates"), "updates"):
        update = require_object(raw_update, "update")
        update_id = _update_number(update, "update_id", 0)
        sequence = _update_number(update, "fanout_sequence", 1)
        previous_id = by_id.get(update_id)
        if previous_id is not None:
            if canonical_json(previous_id) != canonical_json(update):
                raise SocialStoreError(
                    "Telegram update ID has conflicting duplicate payloads or sequences"
                )
            continue
        previous_sequence = by_sequence.get(sequence)
        if previous_sequence is not None:
            if canonical_json(previous_sequence) != canonical_json(update):
                raise SocialStoreError(
                    "Telegram fan-out sequence has conflicting duplicate payloads"
                )
            continue
        by_sequence[sequence] = update
        by_id[update_id] = update
    return by_sequence


def _update_kind(update: dict[str, Any]) -> str:
    kinds = [key for key in update if key not in ("update_id", "fanout_sequence")]
    if len(kinds) != 1:
        raise SocialStoreError("Telegram update must contain exactly one update type")
    return kinds[0]


def _collect_updates(
    request: TelegramRequest,
    updates: dict[int, dict[str, Any]],
    envelope: _UpdateEnvelope,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], set[str]]:
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    media: list[dict[str, Any]] = []
    update_types: set[str] = set()
    context = UpdateMessageContext(envelope.observed_at, envelope.accounts)
    for sequence in sorted(updates):
        update = updates[sequence]
        update_id = int(update["update_id"])
        update_type = _update_kind(update)
        update_types.add(update_type)
        value = require_object(update[update_type], f"{update_type} update")
        if update_type in MESSAGE_UPDATES:
            assert_allowed(chat_id(value), request.allowed_chats)
            record, found_media = message_object(
                sequence, update_id, update_type, value, context
            )
            objects.append(record)
            media.extend(found_media)
        elif update_type in ACTIVITY_UPDATES:
            records, selected_chat = activity_records(
                update_type, value, update_id, sequence, envelope.observed_at
            )
            assert_allowed(selected_chat, request.allowed_chats)
            activities.extend(records)
        else:
            raise SocialStoreError(
                f"Telegram update type {update_type} has no chat-scoped read-only route"
            )
    return objects, activities, media, update_types


def _update_coverage(
    observed_at: str, subscribed: list[str], observed_types: set[str]
) -> list[dict[str, Any]]:
    static = [
        ("bot_updates", "partial", "prospective_updates_are_retained_by_telegram_for_at_most_24_hours"),
        ("pre_install_history", "unavailable", "bot_api_has_no_arbitrary_history_route"),
        ("normal_message_deletions", "unavailable", "bot_api_only_exposes_business_message_deletion_updates"),
        ("secret_chats", "unavailable", "bots_cannot_access_secret_chats"),
        ("stories", "unavailable", "bot_api_has_no_general_story_update_stream"),
        ("participants", "partial", "membership_updates_require_admin_rights_and_explicit_subscription"),
        ("media_bytes", "partial", "fanout_preserves_file_metadata_but_performs_no_tokenized_download"),
        ("polls", "partial", "embedded_message_polls_only_chatless_poll_updates_are_rejected"),
        ("business_guest_ephemeral_messages", "unavailable", "contextual_identity_not_enabled_until_collision_free_scoping_exists"),
    ]
    coverage = [
        coverage_record(stream, status, observed_at, CoverageDetail(reason))
        for stream, status, reason in static
    ]
    reason = "delivery_depends_on_bot_membership_privacy_admin_and_installation_time"
    for kind in sorted(set(subscribed) | observed_types):
        status = "partial" if kind in subscribed else "observed"
        coverage.append(
            coverage_record(
                f"update_type:{kind}", status, observed_at, CoverageDetail(reason)
            )
        )
    return coverage


def _subscribed_updates(root: dict[str, Any]) -> list[str]:
    subscribed = root.get("allowed_updates")
    if not isinstance(subscribed, list) or any(not isinstance(item, str) for item in subscribed):
        raise SocialStoreError("Telegram allowed_updates must be an explicit array")
    return subscribed


def _next_offset(sequences: tuple[int, ...]) -> int | None:
    if not sequences:
        return None
    next_offset = sequences[0]
    for sequence in sequences:
        if sequence != next_offset:
            break
        next_offset += 1
    return next_offset


def parse_telegram_updates(request: TelegramRequest) -> ParsedTelegramBatch:
    """Validate one existing owner's append-only update fan-out without API access."""
    root, payload = _read_updates(request)
    envelope = _update_envelope(request, root)
    updates = _deduplicated_updates(root)
    objects, activities, media, observed_types = _collect_updates(
        request, updates, envelope
    )
    subscribed = _subscribed_updates(root)
    archive = {
        "provider": PROVIDER,
        "connection_id": request.connection_id,
        "remote_account_id": envelope.bot_id,
        "exported_at": envelope.observed_at,
        "enabled_streams": ["bot_updates"],
        "policy": {
            "authenticity_verified": True,
            "delivery": "append_only_fanout",
            "network_requests": 0,
            "owner_id": envelope.owner,
            "privacy_mode": envelope.privacy_mode,
            "installed_at": envelope.installed_at,
            "chat_authority": envelope.authority,
            "schema": UPDATE_SCHEMA,
            "allowed_updates": sorted(set(subscribed)),
        },
        "accounts": sorted(envelope.accounts.values(), key=lambda row: row["remote_id"]),
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": _update_coverage(envelope.observed_at, subscribed, observed_types),
    }
    count = finalize_archive(archive, request.max_items)
    sequences = tuple(sorted(updates))
    return ParsedTelegramBatch(
        archive,
        payload,
        hashlib.sha256(payload).hexdigest(),
        "bot_updates",
        _next_offset(sequences),
        sequences,
        (),
        count,
    )
