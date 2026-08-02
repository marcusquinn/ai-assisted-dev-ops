#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Lemmy records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_lemmy import (
    ACCOUNT_AUTH_MODE,
    PROVIDER,
    LemmyAdapterError,
    api_family,
    instance_id,
    page_data,
)
from _knowledge_social_lemmy_streams import RETENTION_LIMIT
from knowledge_social_import import reject_credentials

PROVENANCE = "lemmy_official_versioned_rest_api"
BASE_GAPS = (
    ("federated_history", "home_instance_visibility_is_not_federation_completeness"),
    ("operator_retention", "instance_retention_policy_is_not_exposed_per_item"),
    ("settings_export_completeness", "settings_backup_is_not_complete_account_history"),
    ("private_message_bodies", "private_message_content_collection_is_not_enabled"),
    ("complete_vote_history", "current_liked_state_is_not_immutable_vote_history"),
    ("deleted_or_purged_content", "not_available_through_current_account_reads"),
)
OBJECT_TYPES = frozenset(
    {"post", "comment", "notification", "reply", "mention", "community", "multicommunity"}
)
ACTIVITY_TYPES = {
    "authored_posts": "authored_post",
    "authored_comments": "authored_comment",
    "saved_posts": "saved_post",
    "saved_comments": "saved_comment",
    "liked_posts": "liked_post",
    "liked_comments": "liked_comment",
    "notifications": "notification",
    "replies": "reply",
    "mentions": "mention",
    "subscriptions": "community_subscription",
    "multicommunities": "multicommunity_subscription",
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
        raise LemmyAdapterError(f"Lemmy record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise LemmyAdapterError(f"Lemmy record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise LemmyAdapterError("Lemmy page observed_at must be text")
    return value


def _coverage(observed_at: str, family: str) -> list[dict[str, Any]]:
    version_gap = (
        ("v3_split_inbox", "v3_routes_are_not_sent_to_v4_instances")
        if family == "v4"
        else ("v4_notifications_and_multicommunities", "v4_routes_are_not_sent_to_v3_instances")
    )
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
        for stream, reason in (*BASE_GAPS, version_gap)
    ]


def _object_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise LemmyAdapterError("Lemmy page contains an unsupported item kind")
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value
        for key in ("title", "content", "name")
        if (value := _optional_text(item, key))
    ) or None
    authored = context.stream.startswith("authored_")
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
    actor = _optional_text(item, "actor_remote_id") or selected
    target = _optional_text(item, "object_remote_id") or remote_id
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
    family = context.account.get("api_family")
    version = context.account.get("exact_version")
    if family not in ("v3", "v4") or api_family(version) != family:
        raise LemmyAdapterError("Lemmy normalized identity has an invalid version")
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "lemmy_auth_mode": ACCOUNT_AUTH_MODE,
            "lemmy_instance_id": installation,
            "lemmy_api_family": family,
            "lemmy_exact_version": version,
            "lemmy_pagination": "opaque_page_cursor" if family == "v4" else "numeric_page",
            "lemmy_overlap": "one_second_after_completed_backfill",
            "lemmy_transport": "stdlib_urllib_get_only",
            "lemmy_redirects": "rejected",
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
                    "ap_id": context.account.get("ap_id"),
                    "api_family": family,
                    "exact_version": version,
                },
            }
        ],
        "objects": [_object_row(item, context, observed_at) for item in items],
        "activities": [_activity_row(item, context, observed_at) for item in items],
        "media": [],
        "coverage": _coverage(observed_at, family),
    }
    reject_credentials(archive)
    return archive
