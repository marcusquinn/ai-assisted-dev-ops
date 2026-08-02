#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted NodeBB records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_account_archive import AccountArchivePolicy, AccountPageNormalizer
from _knowledge_social_nodebb import (
    ACCOUNT_AUTH_MODE,
    PROVIDER,
    RETENTION_LIMIT,
    NodeBBAdapterError,
    instance_id,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "nodebb_core_http_api"
GAPS = (
    ("exact_nodebb_version", "admin_only_version_route_not_enabled"),
    ("plugin_inventory", "admin_only_plugin_inventory_not_enabled"),
    ("plugin_lists", "no_public_core_plugin_manifest"),
    ("chat_message_bodies", "room_message_collection_not_enabled"),
    ("account_exports", "preexisting_sensitive_exports_not_enabled"),
    ("complete_vote_history", "current_accessible_vote_sets_only"),
    ("deleted_or_purged_content", "not_available_through_current_account_reads"),
    ("installation_retention", "no_generic_public_retention_route"),
)
OBJECT_TYPES = frozenset(
    {
        "installation_capability",
        "topic",
        "post",
        "category",
        "user",
        "group",
        "notification",
        "chat_room",
    }
)
ACTIVITY_TYPES = dict(
    (
        ("capabilities", "installation_capability"),
        ("authored_topics", "authored_topic"),
        ("authored_posts", "authored_post"),
        ("upvoted", "upvote"),
        ("downvoted", "downvote"),
        ("bookmarks", "bookmark"),
        ("watched_topics", "watch"),
        ("category_state", "category_state"),
        ("following", "following"),
        ("followers", "follower"),
        ("groups", "group_membership"),
        ("notifications", "notification"),
        ("chat_rooms", "chat_participation"),
    )
)
ARCHIVE_POLICY = AccountArchivePolicy(
    PROVIDER,
    PROVENANCE,
    "userslug",
    "nodebb_instance_id",
    (
        ("nodebb_token_type", ACCOUNT_AUTH_MODE),
        ("nodebb_transport", "stdlib_urllib_get_only"),
        ("nodebb_redirects", "rejected"),
        ("nodebb_plugin_routes", "disabled"),
    ),
)


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
        raise NodeBBAdapterError(f"NodeBB record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise NodeBBAdapterError(f"NodeBB record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise NodeBBAdapterError("NodeBB page observed_at must be text")
    return value


def _text(record: dict[str, Any]) -> str | None:
    values = [
        value
        for key in ("title", "excerpt", "text", "name", "description")
        if (value := _optional_text(record, key))
    ]
    return "\n\n".join(values) or None


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


def _item_kind(item: dict[str, Any]) -> str:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise NodeBBAdapterError("NodeBB page contains an unsupported item kind")
    return kind


def _created_at(item: dict[str, Any]) -> str | None:
    return _optional_text(item, "created_at")


def _object_row(
    item: dict[str, Any], context: PageContext, observed_at: str, installation: str
) -> dict[str, Any]:
    kind = _item_kind(item)
    remote_id = _required_text(item, "remote_id")
    authored = context.stream in ("authored_topics", "authored_posts")
    provider_json = {
        "source": PROVENANCE,
        "instance_id": installation,
        "stream": context.stream,
        "record": item,
    }
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if authored else None,
        "text": _text(item),
        "created_at": _created_at(item),
        "observed_at": observed_at,
        "evidence_class": "authored" if authored else "observed",
        "provider_json": provider_json,
    }


def _activity_row(
    item: dict[str, Any], context: PageContext, observed_at: str, installation: str
) -> dict[str, Any]:
    account_id = _required_text(context.account, "id")
    remote_id = _required_text(item, "remote_id")
    activity_type = ACTIVITY_TYPES[context.stream]
    return {
        "activity_type": activity_type,
        "remote_id": f"{account_id}_{activity_type}_{remote_id}",
        "actor_remote_id": account_id,
        "object_remote_id": remote_id,
        "occurred_at": _created_at(item),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {
            "source": PROVENANCE,
            "instance_id": installation,
            "stream": context.stream,
        },
    }


NORMALIZER = AccountPageNormalizer(
    ARCHIVE_POLICY,
    _observed_at,
    instance_id,
    page_data,
    _object_row,
    _activity_row,
    _coverage,
)


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows and explicit installation-specific gaps."""
    return NORMALIZER.normalize(payload, context)
