#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Mastodon records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_mastodon import (
    ACCOUNT_AUTH_MODE,
    PROVIDER,
    RETENTION_LIMIT,
    MastodonAdapterError,
    instance_id,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "mastodon_official_rest_api"
GAPS = (
    ("conversations", "separate_private_data_consent_required"),
    ("list_members", "nested_list_member_pagination_not_enabled"),
    ("account_exports", "operator_initiated_export_not_imported"),
    ("federated_history", "home_instance_visibility_is_not_federation_completeness"),
    ("moderation_history", "moderation_state_is_not_complete_account_history"),
    ("deleted_or_purged_content", "not_available_through_current_account_reads"),
    ("instance_retention", "instance_specific_retention_is_not_discoverable_here"),
)
OBJECT_TYPES = frozenset({"status", "notification", "account", "tag", "list"})
ACTIVITY_TYPES = {
    "authored_statuses": "authored_status",
    "favourites": "favourite",
    "bookmarks": "bookmark",
    "notifications": "notification",
    "followers": "follower",
    "following": "following",
    "followed_tags": "followed_tag",
    "lists": "list_membership",
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
        raise MastodonAdapterError(f"Mastodon record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise MastodonAdapterError(f"Mastodon record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise MastodonAdapterError("Mastodon page observed_at must be text")
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


def _object_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise MastodonAdapterError("Mastodon page contains an unsupported item kind")
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value
        for key in ("title", "content", "spoiler_text", "name")
        if (value := _optional_text(item, key))
    ) or None
    authored = context.stream == "authored_statuses"
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if authored else None,
        "text": text,
        "created_at": _optional_text(item, "created_at"),
        "observed_at": observed_at,
        "evidence_class": "authored" if authored else "observed",
        "provider_json": provider_json,
    }


def _activity_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    selected = _required_text(context.account, "id")
    remote_id = _required_text(item, "remote_id")
    activity_type = ACTIVITY_TYPES[context.stream]
    actor, target = selected, remote_id
    if context.stream == "followers":
        actor, target = remote_id, selected
    elif context.stream == "notifications":
        actor = _required_text(item, "actor_remote_id")
    return {
        "activity_type": activity_type,
        "remote_id": f"{selected}_{activity_type}_{remote_id}",
        "actor_remote_id": actor,
        "object_remote_id": target,
        "occurred_at": _optional_text(item, "created_at"),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    installation = instance_id(context.account.get("instance_id"))
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "mastodon_auth_mode": ACCOUNT_AUTH_MODE,
            "mastodon_instance_id": installation,
            "mastodon_pagination": "opaque_rfc_link_next",
            "mastodon_transport": "stdlib_urllib_get_only",
            "mastodon_redirects": "rejected",
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
                "handle": context.account.get("acct"),
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "instance_id": installation,
                    "provider_account_id": context.account.get("provider_account_id"),
                    "uri": context.account.get("uri"),
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
