#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Verify and normalize official WhatsApp Business Platform webhook evidence."""

from __future__ import annotations

import hashlib
import hmac
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_whatsapp_contract import (
    WEBHOOK_RETENTION,
    WEBHOOK_SCHEMA,
    ParsedWhatsAppBatch,
    account_record,
    coverage_record,
    digest_id,
    finish_batch,
    normalized_observed_at,
)
from _knowledge_social_whatsapp_webhook_records import (
    WebhookRecords,
    identity,
    message_records,
    status_records,
)
from knowledge_social_store import SocialStoreError

MAX_WEBHOOK_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class WebhookRequest:
    payload: bytes
    signature: str
    app_secret: bytes
    connection_id: str
    expected_waba_id: str
    expected_phone_number_id: str
    observed_at: str


def _verify_signature(payload: bytes, signature: str, app_secret: bytes) -> None:
    if not app_secret:
        raise SocialStoreError("WhatsApp webhook app secret is unavailable")
    if not signature.startswith("sha256=") or len(signature) != 71:
        raise SocialStoreError("WhatsApp webhook signature is malformed")
    expected = "sha256=" + hmac.new(app_secret, payload, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, signature.casefold()):
        raise SocialStoreError("WhatsApp webhook signature verification failed")


def _records(value: Any, field_name: str) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise SocialStoreError(f"WhatsApp webhook {field_name} must be an array of objects")
    return value


def _verify_change_value(change: dict[str, Any], expected_phone: str) -> dict[str, Any]:
    if change.get("field") != "messages" or not isinstance(change.get("value"), dict):
        raise SocialStoreError("WhatsApp webhook contains an unsupported change field")
    value = change["value"]
    if value.get("messaging_product") != "whatsapp":
        raise SocialStoreError("WhatsApp webhook messaging product is invalid")
    metadata = value.get("metadata")
    if not isinstance(metadata, dict):
        raise SocialStoreError("WhatsApp webhook phone identity does not match the connection")
    phone_id = identity(metadata.get("phone_number_id"), "phone identity")
    if phone_id != expected_phone:
        raise SocialStoreError("WhatsApp webhook phone identity does not match the connection")
    return value


def _verified_values(
    root: dict[str, Any], expected_waba: str, expected_phone: str
) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    for entry in _records(root.get("entry"), "entry"):
        if identity(entry.get("id"), "WABA identity") != expected_waba:
            raise SocialStoreError("WhatsApp webhook WABA identity does not match the connection")
        for change in _records(entry.get("changes"), "changes"):
            values.append(_verify_change_value(change, expected_phone))
    if not values:
        raise SocialStoreError("WhatsApp webhook contains no authorized message changes")
    return values


def _webhook_coverage(observed_at: str) -> list[dict[str, Any]]:
    states = (
        ("business_messages", "partial", "prospective_events_received_after_subscription_only"),
        ("message_statuses", "partial", "only_status_events_delivered_to_this_subscription"),
        ("history_before_connection", "unavailable", "no_general_business_message_history_endpoint"),
        ("template_lifecycle", "unavailable", "this_collector_accepts_only_identity_bound_messages_webhooks"),
        ("personal_and_existing_group_history", "unavailable", "business_webhooks_do_not_authorize_personal_or_preexisting_group_history"),
        ("edits_and_deletions", "unavailable", "no_complete_retrospective_edit_or_delete_audit_is_documented"),
    )
    return [
        coverage_record(stream, observed_at, WEBHOOK_RETENTION, status, reason=reason, exhausted=False)
        for stream, status, reason in states
    ]


def parse_business_webhook(request: WebhookRequest) -> ParsedWhatsAppBatch:
    if not 0 < len(request.payload) <= MAX_WEBHOOK_BYTES:
        raise SocialStoreError("WhatsApp webhook exceeds the byte budget")
    _verify_signature(request.payload, request.signature, request.app_secret)
    try:
        root = json.loads(request.payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("WhatsApp webhook is not valid UTF-8 JSON") from error
    if not isinstance(root, dict) or root.get("object") != "whatsapp_business_account":
        raise SocialStoreError("WhatsApp webhook object type is invalid")
    observed = normalized_observed_at(request.observed_at)
    expected_waba = identity(request.expected_waba_id, "configured WABA identity")
    expected_phone = identity(request.expected_phone_number_id, "configured phone identity")
    business_id = digest_id("business", expected_waba, expected_phone)
    records = WebhookRecords(
        accounts={business_id: account_record(business_id, None, observed, "business_phone")}
    )
    for value in _verified_values(root, expected_waba, expected_phone):
        records.extend(message_records(_records(value.get("messages"), "messages"), observed))
        records.activities.extend(
            status_records(_records(value.get("statuses"), "statuses"), observed, business_id)
        )
    return finish_batch(
        connection_id=request.connection_id,
        remote_account_id=business_id,
        observed_at=observed,
        raw_sha256=hashlib.sha256(request.payload).hexdigest(),
        stream="business_webhook",
        schema=WEBHOOK_SCHEMA,
        accounts=list(records.accounts.values()),
        objects=records.objects,
        activities=records.activities,
        media=records.media,
        coverage=_webhook_coverage(observed),
        policy={"identity_verified": True, "signature": "hmac_sha256_raw_body", "source": "official_business_platform_webhook"},
    )
