#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize sanitized Business Profile pages into social evidence rows."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_google_business_profile import (
    API_RETENTION,
    PROVIDER,
    GoogleBusinessProfileAdapterError,
    page_data,
)
from knowledge_social_import import reject_credentials


@dataclass(frozen=True)
class PageContext:
    """Validated location policy needed to normalize one page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _text(value: Any, field: str, *, required: bool = False) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or (required and not value):
        raise GoogleBusinessProfileAdapterError(
            f"Google Business Profile record {field} must be text"
        )
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = _text(payload.get("observed_at"), "observed_at", required=True)
    if value is None:
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile page requires observed_at"
        )
    return value


def _object(record: dict[str, Any], account_id: str, observed_at: str) -> dict[str, Any]:
    kind = _text(record.get("kind"), "kind", required=True)
    remote_id = _text(record.get("remote_id"), "remote_id", required=True)
    provider_json = record.get("provider_json", {})
    if not isinstance(provider_json, dict):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile provider_json must be an object"
        )
    reject_credentials(provider_json)
    if record.get("protected") is True:
        provider_json = {**provider_json, "protected_customer_content": True}
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": account_id,
        "text": _text(record.get("text"), "text"),
        "created_at": _text(record.get("created_at"), "created_at"),
        "observed_at": observed_at,
        "evidence_class": "authored"
        if kind in {"local_post", "owner_reply"}
        else "observed",
        "provider_json": provider_json,
    }


def _activity(
    record: dict[str, Any], account_id: str, observed_at: str
) -> dict[str, Any]:
    remote_id = _text(record.get("remote_id"), "remote_id", required=True)
    kind = _text(record.get("kind"), "kind", required=True)
    return {
        "activity_type": f"business_profile_{kind}",
        "remote_id": f"{account_id}-{kind}-{remote_id}",
        "actor_remote_id": account_id,
        "object_remote_id": remote_id,
        "occurred_at": _text(record.get("updated_at"), "updated_at")
        or _text(record.get("created_at"), "created_at"),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {},
    }


def _gap_coverage(observed_at: str) -> list[dict[str, Any]]:
    gaps = {
        "questions_answers": "current_business_profile_apis_expose_no_questions_answers_read_route",
        "call_records": "call_click_metrics_do_not_expose_caller_or_call_history",
        "bookings": "business_profile_owner_api_exposes_no_booking_history_route",
        "messages": "business_profile_messaging_history_is_not_available",
        "followers": "business_profile_follower_roster_is_not_available",
        "products": "product_catalog_has_no_current_general_owner_read_route",
        "historical_deleted": "deleted_or_complete_historical_resources_are_not_available",
        "owner_export": "no_versioned_official_business_profile_owner_export_schema_is_selected",
    }
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": API_RETENTION,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in gaps.items()
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Validate one page and build canonical provider-neutral projections."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    account_id = context.account.get("id")
    if not isinstance(account_id, str) or not account_id:
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile selected location requires an ID"
        )
    account = {
        "remote_id": account_id,
        "handle": None,
        "display_name": context.account.get("title"),
        "observed_at": observed_at,
        "provider_json": {
            "business_account_id": context.account.get("business_account_id"),
            "organization_id": context.account.get("organization_id"),
            "identity_scope": "google_subject_account_organization_location",
        },
    }
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for record in page_data(payload):
        reject_credentials(record)
        objects.append(_object(record, account_id, observed_at))
        activities.append(_activity(record, account_id, observed_at))
    return {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": context.policy,
        "accounts": [account],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _gap_coverage(observed_at),
    }
