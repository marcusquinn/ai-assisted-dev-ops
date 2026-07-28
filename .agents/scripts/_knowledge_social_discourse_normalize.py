#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Discourse records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_discourse import (
    PROVIDER,
    RETENTION_LIMIT,
    DiscourseAdapterError,
    instance_id,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "discourse_http_api"
GAPS = (
    ("account_archive", "manual_archive_schema_not_validated"),
    ("followers", "discourse_follow_plugin_not_verified"),
    ("following", "discourse_follow_plugin_not_verified"),
    ("watched_topics", "search_side_effects_not_validated"),
    ("tracked_topics", "search_side_effects_not_validated"),
    ("private_message_bodies", "message_body_and_attachment_reads_not_enabled"),
    ("complete_reading_history", "current_topic_state_not_event_history"),
)
OBJECT_TYPES = frozenset(
    {
        "topic",
        "post",
        "bookmark",
        "notification",
        "private_message_topic",
        "topic_state",
        "group",
        "category",
    }
)
ACTIVITY_TYPES = {
    "authored_topics": "authored_topic",
    "authored_posts": "authored_post",
    "likes": "like",
    "bookmarks": "bookmark",
    "notifications": "notification",
    "private_messages": "private_message_received",
    "sent_messages": "private_message_sent",
    "reading_state": "reading_state",
    "groups": "group_membership",
    "category_preferences": "category_preference",
}


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one Discourse page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise DiscourseAdapterError(f"Discourse record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (
        not isinstance(value, str) or "\x00" in value
    ):
        raise DiscourseAdapterError(f"Discourse record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise DiscourseAdapterError("Discourse page observed_at must be text")
    return value


def _text(record: dict[str, Any]) -> str | None:
    values = [
        value
        for key in ("title", "excerpt", "name", "description")
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


@dataclass(frozen=True)
class NormalizationState:
    """Validated values shared by every row from one provider page."""

    observed_at: str
    account_id: str
    installation: str
    activity_type: str
    authored: bool


def _normalization_state(
    payload: dict[str, Any], context: PageContext
) -> NormalizationState:
    return NormalizationState(
        _observed_at(payload),
        _required_text(context.account, "id"),
        instance_id(context.account.get("instance_id")),
        ACTIVITY_TYPES[context.stream],
        context.stream in ("authored_topics", "authored_posts"),
    )


def _item_kind(item: dict[str, Any]) -> str:
    kind = item.get("kind")
    if not isinstance(kind, str):
        raise DiscourseAdapterError("Discourse page contains an unsupported item kind")
    if kind not in OBJECT_TYPES:
        raise DiscourseAdapterError("Discourse page contains an unsupported item kind")
    return kind


def _created_at(item: dict[str, Any]) -> str | None:
    return (
        _optional_text(item, "created_at")
        or _optional_text(item, "last_posted_at")
        or _optional_text(item, "last_visited_at")
    )


def _object_row(
    item: dict[str, Any], context: PageContext, state: NormalizationState
) -> dict[str, Any]:
    kind = _item_kind(item)
    remote_id = _required_text(item, "remote_id")
    provider_json = {
        "source": PROVENANCE,
        "instance_id": state.installation,
        "stream": context.stream,
        "record": item,
    }
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": state.account_id if state.authored else None,
        "text": _text(item),
        "created_at": _created_at(item),
        "observed_at": state.observed_at,
        "evidence_class": "authored" if state.authored else "observed",
        "provider_json": provider_json,
    }


def _has_activity(item: dict[str, Any], stream: str) -> bool:
    if stream != "category_preferences":
        return True
    levels = item.get("preference_levels")
    if not isinstance(levels, list):
        raise DiscourseAdapterError(
            "Discourse category preference levels are invalid"
        )
    if any(not isinstance(level, str) for level in levels):
        raise DiscourseAdapterError(
            "Discourse category preference levels are invalid"
        )
    return bool(levels)


def _activity_row(
    item: dict[str, Any], context: PageContext, state: NormalizationState
) -> dict[str, Any] | None:
    if not _has_activity(item, context.stream):
        return None
    remote_id = _required_text(item, "remote_id")
    return {
        "activity_type": state.activity_type,
        "remote_id": f"{state.account_id}_{state.activity_type}_{remote_id}",
        "actor_remote_id": state.account_id,
        "object_remote_id": remote_id,
        "occurred_at": _created_at(item),
        "observed_at": state.observed_at,
        "state": "active",
        "provider_json": {
            "source": PROVENANCE,
            "instance_id": state.installation,
            "stream": context.stream,
        },
    }


def _normalized_rows(
    payload: dict[str, Any], context: PageContext, state: NormalizationState
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for item in page_data(payload):
        objects.append(_object_row(item, context, state))
        activity = _activity_row(item, context, state)
        if activity is not None:
            activities.append(activity)
    return objects, activities


def _archive_policy(context: PageContext, installation: str) -> dict[str, Any]:
    policy = dict(context.policy)
    policy.update(
        {
            "discourse_auth_scope": "read",
            "discourse_instance_id": installation,
            "discourse_transport": "stdlib_urllib_get_only",
            "discourse_redirects": "rejected",
        }
    )
    return policy


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows and explicit installation-specific gaps."""
    reject_credentials(payload)
    state = _normalization_state(payload, context)
    objects, activities = _normalized_rows(payload, context, state)
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": state.account_id,
        "exported_at": state.observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": _archive_policy(context, state.installation),
        "accounts": [
            {
                "remote_id": state.account_id,
                "handle": context.account.get("username"),
                "display_name": context.account.get("name"),
                "observed_at": state.observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "instance_id": state.installation,
                    "provider_account_id": context.account.get(
                        "provider_account_id"
                    ),
                },
            }
        ],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _coverage(state.observed_at),
    }
    reject_credentials(archive)
    return archive
