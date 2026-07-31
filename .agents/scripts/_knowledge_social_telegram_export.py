#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict bounded reader for official Telegram Desktop JSON exports."""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import stat
from errno import ENOENT
from pathlib import Path
from typing import Any

from _knowledge_social_telegram_contract import (
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
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError


def _read_descriptor(descriptor: int, max_bytes: int, field: str) -> bytes:
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        raise SocialStoreError(f"Telegram {field} must be a regular file")
    chunks: list[bytes] = []
    remaining = max_bytes + 1
    while remaining > 0:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    payload = b"".join(chunks)
    if len(payload) > max_bytes or os.read(descriptor, 1):
        raise SocialStoreError(f"Telegram {field} exceeds the byte budget")
    return payload


def _read_export(path: Path, max_bytes: int) -> tuple[dict[str, Any], bytes, int]:
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        directory = os.open(path.parent, directory_flags | nofollow)
    except OSError as error:
        raise SocialStoreError("Telegram export directory is unsafe") from error
    try:
        descriptor = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=directory)
        try:
            payload = _read_descriptor(descriptor, max_bytes, "export")
        finally:
            os.close(descriptor)
        try:
            parsed = json.loads(payload.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise SocialStoreError("Telegram export is not valid UTF-8 JSON") from error
        root = require_object(parsed, "export root")
        reject_credentials(root)
        about = root.get("about")
        if not isinstance(about, str) or "Telegram Desktop" not in about:
            raise SocialStoreError("Telegram export provenance marker is missing")
        return root, payload, directory
    except Exception:
        os.close(directory)
        raise


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


def _read_relative_media(
    export_directory: int, value: Any, max_bytes: int
) -> tuple[bytes, str] | None:
    if not isinstance(value, str) or not value or value.startswith("("):
        return None
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise SocialStoreError("Telegram export media path escapes the export directory")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    descriptors: list[int] = []
    try:
        current = os.dup(export_directory)
        descriptors.append(current)
        for component in relative.parts[:-1]:
            current = os.open(
                component,
                directory_flags | nofollow,
                dir_fd=current,
            )
            descriptors.append(current)
        descriptor = os.open(
            relative.parts[-1], os.O_RDONLY | nofollow, dir_fd=current
        )
        descriptors.append(descriptor)
        payload = _read_descriptor(descriptor, max_bytes, "export media")
        return payload, relative.name
    except OSError as error:
        if error.errno == ENOENT:
            return None
        raise SocialStoreError("Telegram export media path is unsafe") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _message_media(
    export_directory: int,
    message: dict[str, Any],
    object_id: str,
    used_bytes: int,
    max_media_bytes: int,
) -> tuple[list[dict[str, Any]], list[TelegramMediaPayload], int, bool]:
    records: list[dict[str, Any]] = []
    payloads: list[TelegramMediaPayload] = []
    missing = False
    candidates = (("file", message.get("file")), ("photo", message.get("photo")))
    for _kind, raw_path in candidates:
        if raw_path is None:
            continue
        result = _read_relative_media(
            export_directory, raw_path, max_media_bytes - used_bytes
        )
        if result is None:
            missing = True
            continue
        payload, filename = result
        used_bytes += len(payload)
        digest = hashlib.sha256(payload).hexdigest()
        remote_id = f"attachment:{object_id}:sha256:{digest}"
        mime_type = message.get("mime_type")
        if not isinstance(mime_type, str):
            mime_type = mimetypes.guess_type(filename)[0]
        records.append(
            {
                "remote_id": remote_id,
                "object_remote_id": object_id,
                "content_sha256": digest,
                "mime_type": mime_type,
                "byte_size": len(payload),
                "blob_ref": None,
                "hydration_state": "staged",
            }
        )
        payloads.append(TelegramMediaPayload(remote_id, object_id, mime_type, payload))
    return records, payloads, used_bytes, missing


def _selected_fields(message: dict[str, Any], chat_type: str) -> dict[str, Any]:
    selected: dict[str, Any] = {
        "source": "telegram_desktop_export",
        "chat_type": chat_type,
        "message_type": message.get("type", "message"),
    }
    for key in (
        "reply_to_message_id",
        "message_thread_id",
        "edited",
        "edited_unixtime",
        "forwarded_from",
        "via_bot",
        "poll",
        "reactions",
        "action",
    ):
        if key in message:
            selected[key] = message[key]
    return selected


def _parse_chat(
    request: TelegramRequest,
    export_directory: int,
    chat: dict[str, Any],
    observed_at: str,
    accounts: dict[str, dict[str, Any]],
    used_media_bytes: int,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]], list[TelegramMediaPayload], int, bool]:
    chat_id = stable_id(chat.get("id"), "chat ID")
    if request.allowed_chats and chat_id not in request.allowed_chats:
        return [], [], [], [], used_media_bytes, False
    chat_type = str(chat.get("type", "unknown"))
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    media: list[dict[str, Any]] = []
    media_payloads: list[TelegramMediaPayload] = []
    missing_media = False
    for raw_message in require_list(chat.get("messages", []), "chat messages"):
        message = require_object(raw_message, "message")
        message_id = stable_id(message.get("id"), "message ID")
        object_id = f"chat:{chat_id}:message:{message_id}"
        created_at = normalized_time(
            message.get("date"), message.get("date_unixtime"), "message date"
        )
        sender_id: str | None = None
        if message.get("from_id") is not None:
            sender_id = canonical_user_id(message["from_id"], "message sender ID")
            accounts.setdefault(
                sender_id,
                {
                    "remote_id": sender_id,
                    "handle": None,
                    "display_name": message.get("from") if isinstance(message.get("from"), str) else None,
                    "observed_at": observed_at,
                    "provider_json": {"source": "telegram_desktop_export_message"},
                },
            )
        objects.append(
            {
                "object_type": "message",
                "remote_id": object_id,
                "account_remote_id": sender_id,
                "text": message_text(message.get("text")) or message_text(message.get("caption")),
                "created_at": created_at,
                "observed_at": observed_at,
                "evidence_class": "authored" if sender_id else "observed",
                "provider_json": _selected_fields(message, chat_type),
            }
        )
        if message.get("edited") is not None or message.get("edited_unixtime") is not None:
            activities.append(
                {
                    "activity_type": "message_edit_observation",
                    "remote_id": f"{object_id}:edit",
                    "actor_remote_id": sender_id or "telegram_system",
                    "object_remote_id": object_id,
                    "occurred_at": normalized_time(
                        message.get("edited"), message.get("edited_unixtime"), "edit date"
                    ),
                    "observed_at": observed_at,
                    "state": "observed",
                    "provider_json": {"source": "telegram_desktop_export"},
                }
            )
        found, payloads, used_media_bytes, missing = _message_media(
            export_directory,
            message,
            object_id,
            used_media_bytes,
            request.max_media_bytes,
        )
        media.extend(found)
        media_payloads.extend(payloads)
        missing_media = missing_media or missing
    return objects, activities, media, media_payloads, used_media_bytes, missing_media


def _parse_telegram_export(
    request: TelegramRequest,
    root: dict[str, Any],
    payload: bytes,
    export_directory: int,
) -> ParsedTelegramBatch:
    observed_at = normalized_time(request.observed_at, None, "observation time")
    personal = require_object(root.get("personal_information"), "personal information")
    raw_account_id = stable_id(personal.get("user_id"), "selected account ID")
    if raw_account_id != stable_id(request.expected_identity, "expected account ID"):
        raise SocialStoreError("Telegram export account identity does not match selection")
    account_id = canonical_user_id(raw_account_id)
    accounts = {account_id: _account(personal, observed_at)}
    contacts = root.get("contacts", {})
    if isinstance(contacts, dict):
        for raw_contact in require_list(contacts.get("list", []), "contacts"):
            contact = require_object(raw_contact, "contact")
            if contact.get("user_id") is not None:
                normalized = _account(contact, observed_at)
                accounts[normalized["remote_id"]] = normalized
    chats_root = require_object(root.get("chats"), "chats")
    if not request.allowed_chats:
        raise SocialStoreError("Telegram export requires an explicit chat allowlist")
    raw_chats = require_list(chats_root.get("list"), "chat list")
    exported_chat_ids = {
        stable_id(require_object(raw_chat, "chat").get("id"), "chat ID")
        for raw_chat in raw_chats
    }
    if exported_chat_ids != request.allowed_chats:
        raise SocialStoreError(
            "Telegram raw export chat scope must exactly match the allowlist"
        )
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    media: list[dict[str, Any]] = []
    media_payloads: list[TelegramMediaPayload] = []
    used_media_bytes = 0
    missing_media = False
    selected_chats = 0
    for raw_chat in raw_chats:
        chat = require_object(raw_chat, "chat")
        selected_chats += 1
        parsed = _parse_chat(
            request,
            export_directory,
            chat,
            observed_at,
            accounts,
            used_media_bytes,
        )
        chat_objects, chat_activities, chat_media, chat_payloads, used_media_bytes, missing = parsed
        objects.extend(chat_objects)
        activities.extend(chat_activities)
        media.extend(chat_media)
        media_payloads.extend(chat_payloads)
        missing_media = missing_media or missing
    chat_types = {
        str(require_object(raw_chat, "chat").get("type", "unknown"))
        for raw_chat in raw_chats
    }
    coverage = [
        coverage_record("messages", "complete", observed_at, exhausted=True),
        coverage_record("chats", "complete", observed_at, exhausted=True),
        coverage_record("contacts", "complete" if contacts else "unavailable", observed_at,
                        None if contacts else "category_not_present_in_export", exhausted=bool(contacts)),
        coverage_record("media_bytes", "partial" if missing_media else "complete", observed_at,
                        "export_references_missing_media" if missing_media else None,
                        exhausted=not missing_media),
        coverage_record("normal_message_deletions", "unavailable", observed_at,
                        "telegram_export_does_not_preserve_deleted_messages"),
        coverage_record("saved_messages", "complete" if "saved_messages" in chat_types else "unavailable",
                        observed_at, None if "saved_messages" in chat_types else "saved_messages_not_in_scoped_export",
                        exhausted="saved_messages" in chat_types),
        coverage_record("channel_subscriptions", "partial" if any("channel" in value for value in chat_types) else "unavailable",
                        observed_at, "scoped_export_is_not_an_account_wide_subscription_inventory"),
        coverage_record("participants", "partial", observed_at,
                        "message_senders_and_service_events_are_not_a_complete_member_roster"),
        coverage_record("stories", "unavailable", observed_at,
                        "telegram_desktop_story_schema_not_versioned_by_this_parser"),
        coverage_record("topics_replies_quotes_edits_reactions_polls_service_events", "partial", observed_at,
                        "normalized_only_when_present_in_scoped_export_messages"),
        coverage_record("secret_chats", "unavailable", observed_at,
                        "secret_chats_are_device_bound_and_not_in_standard_desktop_exports"),
        coverage_record("html_exports", "unavailable", observed_at,
                        "html_schema_not_enabled_until_versioned_fixtures_validate_it"),
        coverage_record("tdlib_account_route", "unavailable", observed_at,
                        "no_proven_read_only_session_and_no_write_guarantee"),
    ]
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
            "selected_chat_count": selected_chats,
        },
        "accounts": sorted(accounts.values(), key=lambda row: row["remote_id"]),
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": coverage,
    }
    count = finalize_archive(archive, request.max_items)
    return ParsedTelegramBatch(
        archive,
        payload,
        hashlib.sha256(payload).hexdigest(),
        "archive",
        None,
        (),
        tuple(media_payloads),
        count,
    )


def parse_telegram_export(request: TelegramRequest) -> ParsedTelegramBatch:
    """Validate and normalize one Telegram Desktop JSON export without writes."""
    root, payload, export_directory = _read_export(request.path, request.max_bytes)
    try:
        return _parse_telegram_export(request, root, payload, export_directory)
    finally:
        os.close(export_directory)
