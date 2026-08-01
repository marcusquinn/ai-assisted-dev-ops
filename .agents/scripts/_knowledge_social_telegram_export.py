#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict bounded reader for official Telegram Desktop JSON exports."""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field
from typing import Any

from _knowledge_social_telegram_contract import (
    CoverageDetail,
    EXPORT_SCHEMA,
    PROVIDER,
    ParsedTelegramBatch,
    TelegramMediaPayload,
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
from _knowledge_social_telegram_export_media import message_media, read_export
from knowledge_social_store import SocialStoreError


def _display_name(record: dict[str, Any]) -> str | None:
    parts = [record.get("first_name"), record.get("last_name")]
    value = " ".join(part.strip() for part in parts if isinstance(part, str) and part.strip())
    return value or None


def _account(record: dict[str, Any], observed_at: str) -> dict[str, Any]:
    user_id = canonical_user_id(record.get("user_id"), "account user ID")
    username = record.get("username")
    return {
        "remote_id": user_id,
        "handle": username if isinstance(username, str) and username else None,
        "display_name": _display_name(record),
        "observed_at": observed_at,
        "provider_json": {"source": "telegram_desktop_export"},
    }


def _selected_fields(message: dict[str, Any], chat_type: str) -> dict[str, Any]:
    selected: dict[str, Any] = {
        "source": "telegram_desktop_export",
        "chat_type": chat_type,
        "message_type": message.get("type", "message"),
    }
    for key in (
        "actor_id",
        "reply_to_message_id",
        "message_thread_id",
        "edited",
        "edited_unixtime",
        "forwarded_from",
        "via_bot",
        "poll",
        "reactions",
        "action",
        "members",
        "members_id",
        "title",
    ):
        if key in message:
            selected[key] = message[key]
    return selected


@dataclass
class _ExportState:
    request: TelegramRequest
    export_directory: int
    observed_at: str
    accounts: dict[str, dict[str, Any]]
    objects: list[dict[str, Any]] = field(default_factory=list)
    activities: list[dict[str, Any]] = field(default_factory=list)
    media: list[dict[str, Any]] = field(default_factory=list)
    media_payloads: list[TelegramMediaPayload] = field(default_factory=list)
    used_media_bytes: int = 0
    missing_media: bool = False


def _message_sender(state: _ExportState, message: dict[str, Any]) -> str | None:
    raw_sender = message.get("from_id")
    display_name = message.get("from")
    if raw_sender is None:
        raw_sender = message.get("actor_id")
        display_name = message.get("actor")
    if raw_sender is None:
        return None
    sender_id = canonical_user_id(raw_sender, "message sender ID")
    state.accounts.setdefault(
        sender_id,
        {
            "remote_id": sender_id,
            "handle": None,
            "display_name": display_name if isinstance(display_name, str) else None,
            "observed_at": state.observed_at,
            "provider_json": {"source": "telegram_desktop_export_message"},
        },
    )
    return sender_id


def _message_record(
    state: _ExportState, message: dict[str, Any], chat_id: str, chat_type: str
) -> tuple[dict[str, Any], str, str | None]:
    message_id = stable_id(message.get("id"), "message ID")
    object_id = f"chat:{chat_id}:message:{message_id}"
    sender_id = _message_sender(state, message)
    record = {
        "object_type": "message",
        "remote_id": object_id,
        "account_remote_id": sender_id,
        "text": message_text(message.get("text")) or message_text(message.get("caption")),
        "created_at": normalized_time(
            message.get("date"), message.get("date_unixtime"), "message date"
        ),
        "observed_at": state.observed_at,
        "evidence_class": "authored" if sender_id else "observed",
        "provider_json": _selected_fields(message, chat_type),
    }
    return record, object_id, sender_id


def _edit_activity(
    state: _ExportState, message: dict[str, Any], object_id: str, sender_id: str | None
) -> dict[str, Any] | None:
    if message.get("edited") is None and message.get("edited_unixtime") is None:
        return None
    return {
        "activity_type": "message_edit_observation",
        "remote_id": f"{object_id}:edit",
        "actor_remote_id": sender_id or "telegram_system",
        "object_remote_id": object_id,
        "occurred_at": normalized_time(
            message.get("edited"), message.get("edited_unixtime"), "edit date"
        ),
        "observed_at": state.observed_at,
        "state": "observed",
        "provider_json": {"source": "telegram_desktop_export"},
    }


def _parse_message(
    state: _ExportState, message: dict[str, Any], chat_id: str, chat_type: str
) -> None:
    record, object_id, sender_id = _message_record(state, message, chat_id, chat_type)
    state.objects.append(record)
    edit = _edit_activity(state, message, object_id, sender_id)
    if edit is not None:
        state.activities.append(edit)
    found, payloads, state.used_media_bytes, missing = message_media(
        state.export_directory,
        message,
        object_id,
        state.used_media_bytes,
        state.request.max_media_bytes,
    )
    state.media.extend(found)
    state.media_payloads.extend(payloads)
    state.missing_media = state.missing_media or missing


def _parse_chat(state: _ExportState, chat: dict[str, Any]) -> None:
    chat_id = stable_id(chat.get("id"), "chat ID")
    if chat_id not in state.request.allowed_chats:
        return
    chat_type = str(chat.get("type", "unknown"))
    for raw_message in require_list(chat.get("messages", []), "chat messages"):
        message = require_object(raw_message, "message")
        _parse_message(state, message, chat_id, chat_type)


def _export_accounts(
    request: TelegramRequest, root: dict[str, Any], observed_at: str
) -> tuple[str, dict[str, dict[str, Any]], bool]:
    personal = require_object(root.get("personal_information"), "personal information")
    raw_account_id = stable_id(personal.get("user_id"), "selected account ID")
    if raw_account_id != stable_id(request.expected_identity, "expected account ID"):
        raise SocialStoreError("Telegram export account identity does not match selection")
    account_id = canonical_user_id(raw_account_id)
    accounts = {account_id: _account(personal, observed_at)}
    raw_contacts = root.get("contacts")
    contacts_present = raw_contacts is not None
    if contacts_present:
        contacts = require_object(raw_contacts, "contacts")
        for raw_contact in require_list(contacts.get("list", []), "contacts"):
            contact = require_object(raw_contact, "contact")
            if contact.get("user_id") is not None:
                normalized = _account(contact, observed_at)
                accounts[normalized["remote_id"]] = normalized
    return account_id, accounts, contacts_present


def _export_chats(request: TelegramRequest, root: dict[str, Any]) -> list[Any]:
    if not request.allowed_chats:
        raise SocialStoreError("Telegram export requires an explicit chat allowlist")
    chats_root = require_object(root.get("chats"), "chats")
    raw_chats = require_list(chats_root.get("list"), "chat list")
    chat_ids = [
        stable_id(require_object(raw_chat, "chat").get("id"), "chat ID")
        for raw_chat in raw_chats
    ]
    exported = set(chat_ids)
    if len(exported) != len(chat_ids):
        raise SocialStoreError("Telegram export contains duplicate chat identities")
    if exported != request.allowed_chats:
        raise SocialStoreError("Telegram raw export chat scope must exactly match the allowlist")
    return raw_chats


CoverageSpec = tuple[str, str, str | None, bool]


def _select_coverage(
    present: bool, present_record: CoverageSpec, absent_record: CoverageSpec
) -> CoverageSpec:
    return present_record if present else absent_record


def _scoped_coverage(
    contacts_present: bool, missing_media: bool, chat_types: set[str]
) -> list[CoverageSpec]:
    saved = "saved_messages" in chat_types
    channels = any("channel" in value for value in chat_types)
    subscription_reason = "scoped_export_is_not_an_account_wide_subscription_inventory"
    return [
        _select_coverage(
            contacts_present,
            ("contacts", "complete", None, True),
            ("contacts", "unavailable", "category_not_present_in_export", False),
        ),
        _select_coverage(
            not missing_media,
            ("media_bytes", "complete", None, True),
            ("media_bytes", "partial", "export_references_missing_media", False),
        ),
        (
            "normal_message_deletions",
            "unavailable",
            "telegram_export_does_not_preserve_deleted_messages",
            False,
        ),
        _select_coverage(
            saved,
            ("saved_messages", "complete", None, True),
            (
                "saved_messages",
                "unavailable",
                "saved_messages_not_in_scoped_export",
                False,
            ),
        ),
        _select_coverage(
            channels,
            ("channel_subscriptions", "partial", subscription_reason, False),
            ("channel_subscriptions", "unavailable", subscription_reason, False),
        ),
    ]


def _export_coverage(
    observed_at: str, contacts_present: bool, missing_media: bool, chat_types: set[str]
) -> list[dict[str, Any]]:
    records = [
        ("messages", "complete", None, True),
        ("chats", "complete", None, True),
        *_scoped_coverage(contacts_present, missing_media, chat_types),
        ("participants", "partial", "message_senders_and_service_events_are_not_a_complete_member_roster", False),
        ("stories", "unavailable", "telegram_desktop_story_schema_not_versioned_by_this_parser", False),
        ("topics_replies_quotes_edits_reactions_polls_service_events", "partial", "normalized_only_when_present_in_scoped_export_messages", False),
        ("secret_chats", "unavailable", "secret_chats_are_device_bound_and_not_in_standard_desktop_exports", False),
        ("html_exports", "unavailable", "html_schema_not_enabled_until_versioned_fixtures_validate_it", False),
        ("tdlib_account_route", "unavailable", "no_proven_read_only_session_and_no_write_guarantee", False),
    ]
    return [
        coverage_record(stream, status, observed_at, CoverageDetail(reason, exhausted))
        for stream, status, reason, exhausted in records
    ]


def _parse_telegram_export(
    request: TelegramRequest,
    root: dict[str, Any],
    payload: bytes,
    export_directory: int,
) -> ParsedTelegramBatch:
    observed_at = normalized_time(request.observed_at, None, "observation time")
    account_id, accounts, contacts_present = _export_accounts(request, root, observed_at)
    raw_chats = _export_chats(request, root)
    state = _ExportState(request, export_directory, observed_at, accounts)
    for raw_chat in raw_chats:
        _parse_chat(state, require_object(raw_chat, "chat"))
    chat_types = {
        str(require_object(raw_chat, "chat").get("type", "unknown"))
        for raw_chat in raw_chats
    }
    archive = {
        "provider": PROVIDER,
        "connection_id": request.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": ["archive"],
        "policy": {
            "archive_schema": EXPORT_SCHEMA,
            "network_requests": 0,
            "route": "official_desktop_json_export",
            "selected_chat_count": len(raw_chats),
        },
        "accounts": sorted(state.accounts.values(), key=lambda row: row["remote_id"]),
        "objects": state.objects,
        "activities": state.activities,
        "media": state.media,
        "coverage": _export_coverage(
            observed_at, contacts_present, state.missing_media, chat_types
        ),
    }
    count = finalize_archive(archive, request.max_items)
    return ParsedTelegramBatch(
        archive,
        payload,
        hashlib.sha256(payload).hexdigest(),
        "archive",
        None,
        (),
        tuple(state.media_payloads),
        count,
    )


def parse_telegram_export(request: TelegramRequest) -> ParsedTelegramBatch:
    """Validate and normalize one Telegram Desktop JSON export without writes."""
    root, payload, export_directory = read_export(request.path, request.max_bytes)
    try:
        return _parse_telegram_export(request, root, payload, export_directory)
    finally:
        os.close(export_directory)
