#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize public Hacker News item observations into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_hacker_news import (
    PROVIDER,
    RETENTION_LIMIT,
    HackerNewsAdapterError,
    page_data,
)
from _knowledge_social_hacker_news_identity import item_id, selector_id, username
from knowledge_social_import import reject_credentials

PROVENANCE = "hacker_news_firebase_v0_public_api"
IDENTITY_BOUNDARY = "public_mutable_case_sensitive_username_selector"
GAPS = (
    ("votes", "private_vote_state_not_available"),
    ("favourites", "private_saved_state_not_available"),
    ("inbox", "private_inbox_not_available"),
    ("notifications", "private_notifications_not_available"),
    ("relationships", "relationships_not_available"),
    ("subscriptions", "subscriptions_not_available"),
    ("lists", "custom_lists_not_available"),
    ("deleted_dead_content", "provider_tombstones_do_not_expose_removed_content"),
    ("private_state", "authenticated_private_state_not_available"),
)
ITEM_STATES = frozenset({"live", "missing", "deleted", "dead"})


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise HackerNewsAdapterError(f"Hacker News {field} must be text")
    return value


def _timestamp(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise HackerNewsAdapterError(f"Hacker News {field} is invalid")
    try:
        return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise HackerNewsAdapterError(f"Hacker News {field} is invalid") from error


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise HackerNewsAdapterError("Hacker News page observed_at must be text")
    return value


def _base_coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in GAPS
    ]


def _availability_coverage(
    account: dict[str, Any], records: list[dict[str, Any]], observed_at: str
) -> list[dict[str, Any]]:
    coverage: list[dict[str, Any]] = []
    if account.get("availability") == "missing":
        coverage.append(
            {
                "stream": "public_selector",
                "earliest_at": None,
                "latest_at": None,
                "cursor_exhausted": True,
                "retention_limit": RETENTION_LIMIT,
                "unavailable_reason": "public_username_not_found",
                "status": "unavailable",
                "observed_at": observed_at,
            }
        )
    for record in records:
        state = record.get("state")
        if state not in ITEM_STATES:
            raise HackerNewsAdapterError("Hacker News normalized item state is invalid")
        if state != "live":
            current_id = item_id(record.get("item_id"))
            coverage.append(
                {
                    "stream": f"submitted_item_{current_id}",
                    "earliest_at": None,
                    "latest_at": None,
                    "cursor_exhausted": True,
                    "retention_limit": RETENTION_LIMIT,
                    "unavailable_reason": f"public_item_{state}",
                    "status": "unavailable",
                    "observed_at": observed_at,
                }
            )
    return coverage


def _remote_id(record: dict[str, Any]) -> str:
    return f"hn_item_{item_id(record.get('item_id'))}"


def _object_row(
    record: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    item_type = record.get("type")
    if item_type not in {"job", "story", "comment", "poll", "pollopt"}:
        raise HackerNewsAdapterError("Hacker News normalized item type is invalid")
    text = "\n\n".join(
        current
        for key in ("title", "text", "url")
        if (current := _optional_text(record.get(key), f"item {key}"))
    ) or None
    provider_json = {
        "source": PROVENANCE,
        "identity_boundary": IDENTITY_BOUNDARY,
        "public_username": username(context.account.get("username")),
        "record": record,
    }
    reject_credentials(provider_json)
    return {
        "object_type": item_type,
        "remote_id": _remote_id(record),
        "account_remote_id": selector_id(context.account.get("username")),
        "text": text,
        "created_at": _timestamp(record.get("time"), "item creation timestamp"),
        "observed_at": observed_at,
        "evidence_class": "public_attributed",
        "provider_json": provider_json,
    }


def _activity_row(
    record: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    selected_id = selector_id(context.account.get("username"))
    remote_id = _remote_id(record)
    return {
        "activity_type": "public_submission",
        "remote_id": f"{selected_id}_submitted_{record['item_id']}",
        "actor_remote_id": selected_id,
        "object_remote_id": remote_id,
        "occurred_at": _timestamp(record.get("time"), "item creation timestamp"),
        "observed_at": observed_at,
        "state": "observed",
        "provider_json": {
            "source": PROVENANCE,
            "identity_boundary": IDENTITY_BOUNDARY,
        },
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    selected = username(context.account.get("username"))
    selected_id = selector_id(selected)
    if context.account.get("id") != selected_id:
        raise HackerNewsAdapterError("Hacker News public selector binding is invalid")
    records = page_data(payload)
    live = [record for record in records if record.get("state") == "live"]
    policy = dict(context.policy)
    policy.update(
        {
            "hacker_news_identity": IDENTITY_BOUNDARY,
            "hacker_news_pagination": "content_addressed_submitted_id_slice",
            "hacker_news_transport": "stdlib_urllib_public_get_only",
            "hacker_news_private_state": "unavailable_not_empty",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": selected_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": selected_id,
                "handle": selected,
                "display_name": None,
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "identity_boundary": IDENTITY_BOUNDARY,
                    "availability": context.account.get("availability"),
                    "created": context.account.get("created"),
                    "karma": context.account.get("karma"),
                    "about": context.account.get("about"),
                },
            }
        ],
        "objects": [_object_row(record, context, observed_at) for record in live],
        "activities": [
            _activity_row(record, context, observed_at) for record in live
        ],
        "media": [],
        "coverage": [
            *_base_coverage(observed_at),
            *_availability_coverage(context.account, records, observed_at),
        ],
    }
    reject_credentials(archive)
    return archive
