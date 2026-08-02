#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Forem records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_forem import (
    ACCOUNT_AUTH_MODE,
    PROVIDER,
    RETENTION_LIMIT,
    ForemAdapterError,
    instance_id,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "forem_api_v1"
GAPS = (
    ("authored_comments", "no_complete_selected_account_comment_route"),
    ("reactions", "no_complete_selected_account_reaction_route"),
    ("following", "no_outbound_user_follow_route"),
    ("organizations", "no_selected_account_membership_route"),
    ("notifications", "no_official_account_notification_route"),
    ("messages", "no_official_account_message_route"),
    ("account_exports", "no_stable_validated_export_schema"),
    ("deleted_or_purged_content", "not_available_through_current_account_reads"),
    ("installation_retention", "no_generic_public_retention_route"),
)
OBJECT_TYPES = frozenset({"article", "tag", "user"})
ACTIVITY_TYPES = {
    "authored_articles": "authored_article",
    "reading_list": "reading_list_item",
    "followed_tags": "followed_tag",
    "followers": "follower",
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
        raise ForemAdapterError(f"Forem record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise ForemAdapterError(f"Forem record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise ForemAdapterError("Forem page observed_at must be text")
    return value


def _text(record: dict[str, Any]) -> str | None:
    values = [
        value
        for key in ("title", "description", "name")
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
        raise ForemAdapterError("Forem page contains an unsupported item kind")
    return kind


def _occurred_at(item: dict[str, Any]) -> str | None:
    return _optional_text(item, "published_at") or _optional_text(item, "created_at")


def _object_row(
    item: dict[str, Any], context: PageContext, observed_at: str, installation: str
) -> dict[str, Any]:
    kind = _item_kind(item)
    remote_id = _required_text(item, "remote_id")
    authored = context.stream == "authored_articles"
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
        "created_at": _occurred_at(item),
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
    actor_id, object_id = account_id, remote_id
    if context.stream == "followers":
        actor_id, object_id = remote_id, account_id
    return {
        "activity_type": activity_type,
        "remote_id": f"{account_id}_{activity_type}_{remote_id}",
        "actor_remote_id": actor_id,
        "object_remote_id": object_id,
        "occurred_at": _occurred_at(item),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {
            "source": PROVENANCE,
            "instance_id": installation,
            "stream": context.stream,
        },
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows and explicit installation-specific gaps."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    installation = instance_id(context.account.get("instance_id"))
    objects = [
        _object_row(item, context, observed_at, installation)
        for item in page_data(payload)
    ]
    activities = [
        _activity_row(item, context, observed_at, installation)
        for item in page_data(payload)
    ]
    policy = dict(context.policy)
    policy.update(
        {
            "forem_auth_mode": ACCOUNT_AUTH_MODE,
            "forem_instance_id": installation,
            "forem_transport": "stdlib_urllib_get_only",
            "forem_redirects": "rejected",
            "forem_admin_and_browser_routes": "disabled",
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
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "instance_id": installation,
                    "provider_account_id": context.account.get("provider_account_id"),
                },
            }
        ],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
