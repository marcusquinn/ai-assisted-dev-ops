#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verify and sanitize optional Nextcloud Talk webhook freshness evidence."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from typing import Any, Mapping

from _knowledge_social_nextcloud_talk import (
    NextcloudTalkAdapterError,
    instance_id,
    namespaced_id,
    private_fingerprint,
)
from _knowledge_social_nextcloud_talk_http import canonical_base_url

SIGNATURE = re.compile(r"^[0-9a-f]{64}$")
RANDOM = re.compile(r"^[A-Za-z0-9+/=_-]{32,128}$")
MAX_WEBHOOK_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class WebhookPolicy:
    secret: str
    expected_backend: str
    origin_key: str
    installation: str
    allowed_rooms: Mapping[str, str]


def _header(headers: Mapping[str, str], name: str) -> str:
    values = {str(key).lower(): str(value) for key, value in headers.items()}
    value = values.get(name.lower(), "")
    if not value or "\x00" in value:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook header is missing")
    return value


def verify_webhook(
    body: bytes,
    headers: Mapping[str, str],
    *,
    secret: str,
    expected_backend: str,
) -> None:
    """Verify backend identity and HMAC(random || body) before parsing content."""
    if not isinstance(body, bytes) or len(body) > MAX_WEBHOOK_BYTES:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook body exceeds the limit")
    if len(secret.encode("utf-8")) < 32:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook secret is invalid")
    random_value = _header(headers, "X-Nextcloud-Talk-Random")
    signature = _header(headers, "X-Nextcloud-Talk-Signature").lower()
    backend = _header(headers, "X-Nextcloud-Talk-Backend")
    if RANDOM.fullmatch(random_value) is None or SIGNATURE.fullmatch(signature) is None:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook signature is malformed")
    if canonical_base_url(backend) != canonical_base_url(expected_backend):
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook backend identity changed")
    expected = hmac.new(
        secret.encode("utf-8"), random_value.encode("ascii") + body, hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook signature is invalid")


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NextcloudTalkAdapterError(f"Nextcloud Talk webhook {field} is invalid")
    return value


def _text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode("utf-8")) > 256 * 1024
    ):
        raise NextcloudTalkAdapterError(f"Nextcloud Talk webhook {field} is invalid")
    return value


def normalize_webhook(
    body: bytes,
    *,
    origin_key: str,
    installation: str,
    allowed_rooms: Mapping[str, str],
) -> dict[str, Any]:
    """Return replay-stable opaque metadata for later OCS reconciliation."""
    installation = instance_id(installation)
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook is not valid JSON") from error
    root = _object(payload, "root")
    event_type = _text(root.get("type"), "event type")
    if event_type not in {"Create", "Like", "Undo", "Join", "Leave"}:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook event is unsupported")
    target = _object(root.get("target", root.get("object")), "target")
    token = _text(target.get("id"), "room token")
    expected_room = allowed_rooms.get(str(token))
    derived = (
        f"nct_{installation}_room_"
        f"{private_fingerprint(origin_key, installation, 'room', str(token))}"
    )
    if expected_room != derived:
        raise NextcloudTalkAdapterError("Nextcloud Talk webhook room is not allowlisted")
    event_object = root.get("object")
    while isinstance(event_object, dict) and event_object.get("type") == "Like":
        event_object = event_object.get("object")
    note = event_object if isinstance(event_object, dict) else {}
    native_message = _text(note.get("id"), "message ID", optional=True)
    message_id = (
        namespaced_id(installation, "message", f"{derived}:{native_message}")
        if native_message
        else None
    )
    digest = hashlib.sha256(body).hexdigest()
    return {
        "event_id": namespaced_id(installation, "webhook", digest),
        "event_type": event_type,
        "room_id": derived,
        "message_id": message_id,
        "content_sha256": digest,
        "requires_ocs_reconciliation": True,
    }


def verify_and_normalize_webhook(
    body: bytes,
    headers: Mapping[str, str],
    policy: WebhookPolicy,
) -> dict[str, Any]:
    verify_webhook(
        body,
        headers,
        secret=policy.secret,
        expected_backend=policy.expected_backend,
    )
    return normalize_webhook(
        body,
        origin_key=policy.origin_key,
        installation=policy.installation,
        allowed_rooms=policy.allowed_rooms,
    )
