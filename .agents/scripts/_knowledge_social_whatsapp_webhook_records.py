#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize typed records from verified WhatsApp Business webhooks."""

from __future__ import annotations

import base64
import binascii
import hashlib
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_whatsapp_contract import account_record, digest_id
from knowledge_social_store import SocialStoreError

MEDIA_TYPES = {"image", "audio", "video", "document", "sticker"}


@dataclass
class WebhookRecords:
    objects: list[dict[str, Any]] = field(default_factory=list)
    activities: list[dict[str, Any]] = field(default_factory=list)
    media: list[dict[str, Any]] = field(default_factory=list)
    accounts: dict[str, dict[str, Any]] = field(default_factory=dict)

    def extend(self, other: "WebhookRecords") -> None:
        self.objects.extend(other.objects)
        self.activities.extend(other.activities)
        self.media.extend(other.media)
        self.accounts.update(other.accounts)


def identity(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 255:
        raise SocialStoreError(f"WhatsApp webhook {field_name} is invalid")
    return value


def _text(record: dict[str, Any], message_type: str) -> str | None:
    value = record.get(message_type)
    if not isinstance(value, dict):
        return None
    for key in ("body", "caption", "emoji", "name"):
        candidate = value.get(key)
        if isinstance(candidate, str):
            return candidate
    return None


def _event_time(value: Any) -> str:
    if not isinstance(value, str) or not value.isdigit():
        raise SocialStoreError("WhatsApp webhook event timestamp is invalid")
    try:
        return datetime.fromtimestamp(int(value), UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise SocialStoreError("WhatsApp webhook event timestamp is invalid") from error


def _provider_digest(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise SocialStoreError("WhatsApp webhook media digest is invalid")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise SocialStoreError("WhatsApp webhook media digest is invalid") from error
    if len(decoded) != hashlib.sha256().digest_size:
        raise SocialStoreError("WhatsApp webhook media digest is invalid")
    return value


def _context_id(message: dict[str, Any]) -> str | None:
    value = message.get("context")
    if value is None:
        return None
    if not isinstance(value, dict):
        raise SocialStoreError("WhatsApp webhook reply context is invalid")
    candidate = value.get("id", value.get("message_id"))
    return identity(candidate, "reply context") if candidate is not None else None


def _typed_body(message: dict[str, Any], message_type: str) -> dict[str, Any] | None:
    typed = message.get(message_type)
    if message_type in MEDIA_TYPES and not isinstance(typed, dict):
        raise SocialStoreError("WhatsApp webhook media body is invalid")
    if message_type == "reaction" and not isinstance(typed, dict):
        raise SocialStoreError("WhatsApp webhook reaction body is invalid")
    return typed if isinstance(typed, dict) else None


def _media_record(
    typed: dict[str, Any], message_id: str, provider_json: dict[str, Any]
) -> dict[str, Any]:
    media_id = identity(typed.get("id"), "media id")
    provider_json["media_remote_id"] = media_id
    provider_digest = _provider_digest(typed.get("sha256"))
    if provider_digest is not None:
        provider_json["provider_media_sha256_b64"] = provider_digest
    mime_type = typed.get("mime_type")
    if mime_type is not None and not isinstance(mime_type, str):
        raise SocialStoreError("WhatsApp webhook media MIME type is invalid")
    return {
        "remote_id": media_id, "object_remote_id": message_id,
        "content_sha256": None, "mime_type": mime_type, "byte_size": None,
        "blob_ref": None, "hydration_state": "metadata_only_provider_digest_unverified",
    }


def _reaction_record(
    typed: dict[str, Any], message_id: str, sender: str, occurred_at: str, observed_at: str
) -> dict[str, Any]:
    target = identity(typed.get("message_id"), "reaction target")
    emoji = typed.get("emoji")
    if not isinstance(emoji, str):
        raise SocialStoreError("WhatsApp webhook reaction emoji is invalid")
    return {
        "activity_type": "reaction",
        "remote_id": digest_id("reaction", message_id, target, emoji),
        "actor_remote_id": sender, "object_remote_id": target,
        "occurred_at": occurred_at, "observed_at": observed_at,
        "state": "removed" if emoji == "" else "active",
        "provider_json": {"source_message_id": message_id},
    }


def message_records(messages: list[dict[str, Any]], observed_at: str) -> WebhookRecords:
    records = WebhookRecords()
    for message in messages:
        message_id = identity(message.get("id"), "message id")
        sender = digest_id("business-contact", identity(message.get("from"), "sender identity"))
        records.accounts[sender] = account_record(sender, None, observed_at, "business_contact")
        message_type = identity(message.get("type"), "message type")
        occurred_at = _event_time(message.get("timestamp"))
        context_id = _context_id(message)
        provider_json: dict[str, Any] = {"message_type": message_type, "source": "verified_business_webhook"}
        if context_id:
            provider_json["reply_to_message_id"] = context_id
        typed = _typed_body(message, message_type)
        if message_type in MEDIA_TYPES and typed is not None:
            records.media.append(_media_record(typed, message_id, provider_json))
        records.objects.append({
            "object_type": "business_message", "remote_id": message_id,
            "account_remote_id": sender, "text": _text(message, message_type),
            "created_at": occurred_at, "observed_at": observed_at,
            "evidence_class": "authored", "provider_json": provider_json,
        })
        if message_type == "reaction" and typed is not None:
            records.activities.append(_reaction_record(typed, message_id, sender, occurred_at, observed_at))
    return records


def status_records(
    statuses: list[dict[str, Any]], observed_at: str, actor_id: str
) -> list[dict[str, Any]]:
    activities: list[dict[str, Any]] = []
    for status in statuses:
        message_id = identity(status.get("id"), "status message id")
        state = identity(status.get("status"), "message status")
        occurred_at = _event_time(status.get("timestamp"))
        activities.append({
            "activity_type": "message_status",
            "remote_id": digest_id("message-status", message_id, state, occurred_at),
            "actor_remote_id": actor_id, "object_remote_id": message_id,
            "occurred_at": occurred_at, "observed_at": observed_at, "state": state,
            "provider_json": {"source": "verified_business_webhook"},
        })
    return activities
