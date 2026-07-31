#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider contract and deterministic identities for WhatsApp evidence."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta, timezone
from typing import Any

from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

PROVIDER = "whatsapp"
EXPORT_SCHEMA = "whatsapp-chat-export-v1"
WEBHOOK_SCHEMA = "whatsapp-business-webhook-v1"
EXPORT_RETENTION = "manual_export_may_contain_only_the_latest_40000_messages_or_10000_with_media"
WEBHOOK_RETENTION = "prospective_events_only_no_general_message_history_endpoint"
TIMEZONE_OFFSET = re.compile(r"^(?P<sign>[+-])(?P<hours>\d{2}):(?P<minutes>\d{2})$")


@dataclass(frozen=True)
class ParsedWhatsAppBatch:
    """One fully validated source batch and its immutable original bytes."""

    archive: dict[str, Any]
    raw_sha256: str
    manifest_sha256: str
    stream: str
    normalized_items: int


def digest_id(prefix: str, *values: str) -> str:
    material = "\0".join((prefix, *values)).encode("utf-8")
    return f"{prefix}:{hashlib.sha256(material).hexdigest()}"


def alias_id(value: str, conversation_id: str) -> str:
    normalized = " ".join(value.split()).casefold()
    if not normalized:
        raise SocialStoreError("WhatsApp participant alias cannot be empty")
    return digest_id("alias", conversation_id, normalized)


def normalized_observed_at(value: str) -> str:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SocialStoreError("WhatsApp observation time must be ISO-8601") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise SocialStoreError("WhatsApp observation time requires a timezone")
    return parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")


def fixed_timezone(value: str) -> timezone:
    if value in {"UTC", "Z", "+00:00", "-00:00"}:
        return timezone.utc
    match = TIMEZONE_OFFSET.fullmatch(value)
    if match is None:
        raise SocialStoreError("WhatsApp timezone must be UTC or an explicit +/-HH:MM offset")
    hours = int(match["hours"])
    minutes = int(match["minutes"])
    offset_minutes = hours * 60 + minutes
    if minutes > 59 or offset_minutes > 14 * 60:
        raise SocialStoreError("WhatsApp timezone offset is out of range")
    delta = timedelta(minutes=offset_minutes)
    return timezone(delta if match["sign"] == "+" else -delta)


def account_record(remote_id: str, alias: str | None, observed_at: str, role: str) -> dict[str, Any]:
    return {
        "remote_id": remote_id,
        "handle": None,
        "display_name": alias,
        "observed_at": observed_at,
        "provider_json": {"identity_kind": "private_alias", "role": role},
    }


def coverage_record(
    stream: str,
    observed_at: str,
    retention: str,
    status: str,
    **details: Any,
) -> dict[str, Any]:
    unexpected = set(details) - {"reason", "exhausted", "earliest_at", "latest_at"}
    if unexpected or not isinstance(details.get("exhausted"), bool):
        raise SocialStoreError("WhatsApp coverage details are invalid")
    return {
        "stream": stream,
        "earliest_at": details.get("earliest_at"),
        "latest_at": details.get("latest_at"),
        "cursor_exhausted": details["exhausted"],
        "retention_limit": retention,
        "unavailable_reason": details.get("reason"),
        "status": status,
        "observed_at": observed_at,
    }


def _manifest_value(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _manifest_value(item)
            for key, item in value.items()
            if key not in {"exported_at", "observed_at"}
        }
    if isinstance(value, list):
        return [_manifest_value(item) for item in value]
    return value


def finish_batch(**parts: Any) -> ParsedWhatsAppBatch:
    required = {
        "connection_id", "remote_account_id", "observed_at", "raw_sha256",
        "stream", "schema", "accounts", "objects", "activities", "media",
        "coverage", "policy",
    }
    if set(parts) != required:
        raise SocialStoreError("WhatsApp normalized batch fields are invalid")
    connection_id = parts["connection_id"]
    remote_account_id = parts["remote_account_id"]
    validate_opaque(connection_id, "connection_id")
    if not remote_account_id or len(remote_account_id) > 255:
        raise SocialStoreError("WhatsApp remote account identity is invalid")
    archive = {
        "provider": PROVIDER,
        "connection_id": connection_id,
        "remote_account_id": remote_account_id,
        "exported_at": normalized_observed_at(parts["observed_at"]),
        "enabled_streams": sorted({record["stream"] for record in parts["coverage"]}),
        "policy": {
            "schema": parts["schema"],
            "raw_sha256": parts["raw_sha256"],
            "network_requests": 0,
            "read_only": True,
            **parts["policy"],
        },
        "accounts": sorted(parts["accounts"], key=lambda row: row["remote_id"]),
        "objects": sorted(parts["objects"], key=lambda row: (row["object_type"], row["remote_id"])),
        "activities": sorted(parts["activities"], key=lambda row: (row["activity_type"], row["remote_id"])),
        "media": sorted(parts["media"], key=lambda row: row["remote_id"]),
        "coverage": sorted(parts["coverage"], key=lambda row: row["stream"]),
    }
    reject_credentials(archive)
    manifest = canonical_json(_manifest_value(archive)).encode("utf-8")
    manifest_sha256 = hashlib.sha256(manifest).hexdigest()
    normalized_items = sum(len(archive[key]) for key in ("accounts", "objects", "activities", "media"))
    return ParsedWhatsAppBatch(
        archive, parts["raw_sha256"], manifest_sha256, parts["stream"], normalized_items
    )
