#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted FreshRSS records into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_freshrss import (
    PROVIDER,
    RETENTION_LIMIT,
    FreshRSSAdapterError,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "freshrss_google_reader_api"
GAPS = (
    ("retained_history", "operator_retention_can_remove_history"),
    ("deleted_subscriptions", "partial_snapshots_do_not_prove_deletion"),
    ("complete_account_archive", "opml_covers_subscriptions_not_complete_account_state"),
    ("fever_live_fallback", "fever_reads_require_a_second_post_route_disallowed_by_policy"),
)
OBJECT_TYPES = frozenset({"entry", "feed", "folder", "tag"})
ACTIVITY_TYPES = {
    "items": "content_observed",
    "unread": "unread",
    "starred": "starred",
    "subscriptions": "subscribed",
    "folders": "folder_membership",
    "tags": "tagged",
    "opml": "subscription_exported",
}


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise FreshRSSAdapterError(f"FreshRSS record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise FreshRSSAdapterError(f"FreshRSS record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise FreshRSSAdapterError("FreshRSS page observed_at must be text")
    return value


def _coverage(observed_at: str) -> list[dict[str, Any]]:
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


def _object_row(
    item: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise FreshRSSAdapterError("FreshRSS page contains an unsupported item kind")
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value
        for key in ("title", "body", "author", "description", "category")
        if (value := _optional_text(item, key))
    ) or None
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id"),
        "text": text,
        "created_at": _optional_text(item, "created_at")
        or _optional_text(item, "published_at"),
        "observed_at": observed_at,
        "evidence_class": "observed",
        "provider_json": provider_json,
    }


def _activity_row(
    item: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    selected = _required_text(context.account, "id")
    remote = _required_text(item, "remote_id")
    activity_type = ACTIVITY_TYPES[context.stream]
    return {
        "activity_type": activity_type,
        "remote_id": f"{selected}_{activity_type}_{remote}",
        "actor_remote_id": selected,
        "object_remote_id": remote,
        "occurred_at": _optional_text(item, "created_at")
        or _optional_text(item, "published_at")
        or observed_at,
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "freshrss_identity": "installation_fingerprint_plus_current_greader_user",
            "freshrss_pagination": "opaque_continuation_with_one_second_item_overlap",
            "freshrss_transport": "exact_clientlogin_post_then_allowlisted_get_only",
            "freshrss_deletion": "never_inferred_from_partial_snapshots",
            "freshrss_fever": "fallback_not_live_because_authenticated_reads_require_post",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"),
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": context.account.get("id"),
                "handle": context.account.get("username"),
                "display_name": context.account.get("username"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "installation_id": context.account.get("installation_id"),
                    "user_id": context.account.get("user_id"),
                },
            }
        ],
        "objects": [_object_row(item, context, observed_at) for item in items],
        "activities": [_activity_row(item, context, observed_at) for item in items],
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
