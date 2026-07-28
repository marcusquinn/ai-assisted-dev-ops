#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact GET route allowlist and serializers for Discourse account reads."""

from __future__ import annotations

import re
from typing import Any, Callable
from urllib.parse import quote

from _knowledge_social_discourse import (
    MAX_MESSAGE_PAGE_ITEMS,
    MAX_SNAPSHOT_ITEMS,
    PageRequest,
    STREAMS,
)
from _knowledge_social_discourse_contract import (
    ApiResult,
    DiscourseReadProviderError,
    non_negative_integer,
    object_list,
    object_value,
    observed_at,
    optional_boolean,
    optional_text,
    positive_id,
    required_text,
    resource_id,
)

Api = Callable[[str, dict[str, str]], ApiResult]

EXACT_READ_PATHS = frozenset(
    {
        "/session/current.json",
        "/user_actions.json",
        "/notifications.json",
        "/categories.json",
    }
)
PARAMETERIZED_READ_PATHS = (
    re.compile(r"^/u/[A-Za-z0-9_.-]+/bookmarks\.json$"),
    re.compile(r"^/u/[A-Za-z0-9_.-]+/topic-tracking-state\.json$"),
    re.compile(r"^/topics/private-messages/[A-Za-z0-9_.-]+\.json$"),
    re.compile(r"^/topics/private-messages-sent/[A-Za-z0-9_.-]+\.json$"),
)


def allowlisted_path(path: str) -> bool:
    """Return whether a path is one of the reviewed account-visible GET routes."""
    return path in EXACT_READ_PATHS or any(
        pattern.fullmatch(path) for pattern in PARAMETERIZED_READ_PATHS
    )


def _user_path(handle: str, suffix: str) -> str:
    encoded = quote(handle, safe="")
    path = f"/u/{encoded}/{suffix}.json"
    if not allowlisted_path(path):
        raise DiscourseReadProviderError("Discourse API path is not allowlisted")
    return path


def _message_path(handle: str, sent: bool) -> str:
    encoded = quote(handle, safe="")
    direction = "private-messages-sent" if sent else "private-messages"
    path = f"/topics/{direction}/{encoded}.json"
    if not allowlisted_path(path):
        raise DiscourseReadProviderError("Discourse API path is not allowlisted")
    return path


def _action_record(
    item: dict[str, Any], request: PageRequest, kind: str
) -> dict[str, Any]:
    object_field = "topic_id" if kind == "topic" else "post_id"
    local_id = positive_id(item.get(object_field), f"{kind} ID")
    if local_id is None:
        raise DiscourseReadProviderError(f"Discourse {kind} ID is required")
    action_type = non_negative_integer(item.get("action_type"), "action type")
    expected_action = 4 if kind == "topic" else 5 if request.stream == "authored_posts" else 1
    if action_type != expected_action:
        raise DiscourseReadProviderError(
            "Discourse user action does not match the selected stream"
        )
    return {
        "kind": kind,
        "remote_id": resource_id(
            request.instance_id, kind, item.get(object_field), f"{kind} ID"
        ),
        "topic_id": positive_id(item.get("topic_id"), "topic ID", optional=True),
        "post_id": positive_id(item.get("post_id"), "post ID", optional=True),
        "action_type": action_type,
        "title": optional_text(item.get("title"), "action title"),
        "excerpt": optional_text(item.get("excerpt"), "action excerpt"),
        "created_at": optional_text(item.get("created_at"), "action timestamp"),
    }


def _bookmark_record(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    bookmark_id = positive_id(item.get("id"), "bookmark ID")
    post_id = positive_id(item.get("post_id"), "bookmark post ID", optional=True)
    source_id = post_id or bookmark_id
    if source_id is None or bookmark_id is None:
        raise DiscourseReadProviderError("Discourse bookmark has no stable ID")
    return {
        "kind": "post" if post_id else "bookmark",
        "remote_id": resource_id(
            request.instance_id,
            "post" if post_id else "bookmark",
            int(source_id),
            "bookmark object ID",
        ),
        "bookmark_id": bookmark_id,
        "topic_id": positive_id(item.get("topic_id"), "bookmark topic ID", optional=True),
        "post_id": post_id,
        "title": optional_text(item.get("title"), "bookmark title"),
        "excerpt": optional_text(item.get("excerpt"), "bookmark excerpt"),
        "created_at": optional_text(item.get("created_at"), "bookmark timestamp"),
    }


def _notification_record(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    notification_id = positive_id(item.get("id"), "notification ID")
    if notification_id is None:
        raise DiscourseReadProviderError("Discourse notification has no stable ID")
    return {
        "kind": "notification",
        "remote_id": resource_id(
            request.instance_id,
            "notification",
            int(notification_id),
            "notification ID",
        ),
        "notification_type": non_negative_integer(
            item.get("notification_type"), "notification type"
        ),
        "read": optional_boolean(item.get("read"), "notification read flag"),
        "topic_id": positive_id(item.get("topic_id"), "notification topic ID", optional=True),
        "post_number": non_negative_integer(
            item.get("post_number"), "notification post number", optional=True
        ),
        "created_at": optional_text(
            item.get("created_at"), "notification timestamp"
        ),
    }


def _message_record(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    topic_id = positive_id(item.get("id"), "private-message topic ID")
    if topic_id is None:
        raise DiscourseReadProviderError(
            "Discourse private-message topic has no stable ID"
        )
    archetype = item.get("archetype")
    if archetype not in (None, "private_message"):
        raise DiscourseReadProviderError(
            "Discourse private-message listing returned a public topic"
        )
    return {
        "kind": "private_message_topic",
        "remote_id": resource_id(
            request.instance_id,
            "message",
            int(topic_id),
            "private-message topic ID",
        ),
        "topic_id": topic_id,
        "title": optional_text(item.get("title"), "private-message title"),
        "created_at": optional_text(
            item.get("created_at"), "private-message timestamp"
        ),
        "last_posted_at": optional_text(
            item.get("last_posted_at"), "private-message last-post timestamp"
        ),
        "posts_count": non_negative_integer(
            item.get("posts_count"), "private-message post count", optional=True
        ),
        "reply_count": non_negative_integer(
            item.get("reply_count"), "private-message reply count", optional=True
        ),
        "highest_post_number": non_negative_integer(
            item.get("highest_post_number"),
            "private-message highest post number",
            optional=True,
        ),
        "last_read_post_number": non_negative_integer(
            item.get("last_read_post_number"),
            "private-message last read post number",
            optional=True,
        ),
        "unread_posts": non_negative_integer(
            item.get("unread_posts"), "private-message unread count", optional=True
        ),
    }


def _tracking_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        source = object_list(
            payload, "topic tracking state", limit=MAX_SNAPSHOT_ITEMS
        )
    else:
        root = object_value(payload, "topic tracking response")
        candidate = root.get("topic_tracking_state", root.get("topic_tracking_states", []))
        source = object_list(
            candidate, "topic tracking state", limit=MAX_SNAPSHOT_ITEMS
        )
    records: list[dict[str, Any]] = []
    for item in source:
        topic_id = positive_id(item.get("topic_id"), "tracked topic ID")
        if topic_id is None:
            raise DiscourseReadProviderError("Discourse topic state has no stable ID")
        records.append(
            {
                "kind": "topic_state",
                "remote_id": resource_id(
                    request.instance_id,
                    "topic_state",
                    int(topic_id),
                    "tracked topic ID",
                ),
                "topic_id": topic_id,
                "highest_post_number": non_negative_integer(
                    item.get("highest_post_number"),
                    "highest post number",
                    optional=True,
                ),
                "last_read_post_number": non_negative_integer(
                    item.get("last_read_post_number"),
                    "last read post number",
                    optional=True,
                ),
                "notification_level": non_negative_integer(
                    item.get("notification_level"),
                    "topic notification level",
                    optional=True,
                ),
                "last_visited_at": optional_text(
                    item.get("last_visited_at"), "topic visit timestamp"
                ),
            }
        )
    return records


def _group_records(identity: dict[str, Any], request: PageRequest) -> list[dict[str, Any]]:
    groups = object_list(
        identity.get("groups", []), "identity groups", limit=MAX_SNAPSHOT_ITEMS
    )
    return [
        {
            "kind": "group",
            "remote_id": resource_id(
                request.instance_id, "group", int(required_text(group.get("id"), "group ID")), "group ID"
            ),
            "group_id": required_text(group.get("id"), "group ID"),
            "name": required_text(group.get("name"), "group name"),
            "has_messages": optional_boolean(
                group.get("has_messages"), "group message flag"
            ),
            "owner": optional_boolean(group.get("owner"), "group owner flag"),
        }
        for group in groups
    ]


def _category_source(payload: Any) -> list[dict[str, Any]]:
    root = object_value(payload, "category response")
    category_list = object_value(root.get("category_list"), "category list")
    return object_list(
        category_list.get("categories", []),
        "categories",
        limit=MAX_SNAPSHOT_ITEMS,
    )


def _preference_values(level: Any, values: Any) -> tuple[str, list[str]]:
    if not isinstance(level, str):
        raise DiscourseReadProviderError("Discourse category preferences are invalid")
    if not isinstance(values, list):
        raise DiscourseReadProviderError("Discourse category preferences are invalid")
    return level, [required_text(value, "category preference ID") for value in values]


def _preference_map(identity: dict[str, Any]) -> dict[str, list[str]]:
    preferences = object_value(
        identity.get("category_preferences", {}), "category preferences"
    )
    by_id: dict[str, list[str]] = {}
    for level, values in preferences.items():
        label, local_ids = _preference_values(level, values)
        for local_id in local_ids:
            by_id.setdefault(local_id, []).append(label)
    return by_id


def _resolved_category(
    item: dict[str, Any], by_id: dict[str, list[str]], request: PageRequest
) -> dict[str, Any]:
    local_id = positive_id(item.get("id"), "category ID")
    if local_id is None:
        raise DiscourseReadProviderError("Discourse category has no stable ID")
    return {
        "kind": "category",
        "remote_id": resource_id(
            request.instance_id,
            "category",
            int(local_id),
            "category ID",
        ),
        "category_id": local_id,
        "name": required_text(item.get("name"), "category name"),
        "slug": optional_text(item.get("slug"), "category slug"),
        "description": optional_text(
            item.get("description_text"), "category description"
        ),
        "preference_levels": sorted(by_id.get(local_id, [])),
        "resolved": True,
    }


def _unresolved_category(
    local_id: str, levels: list[str], request: PageRequest
) -> dict[str, Any]:
    return {
        "kind": "category",
        "remote_id": resource_id(
            request.instance_id,
            "category",
            int(local_id),
            "category preference ID",
        ),
        "category_id": local_id,
        "name": None,
        "slug": None,
        "description": None,
        "preference_levels": sorted(levels),
        "resolved": False,
    }


def _category_records(
    payload: Any, identity: dict[str, Any], request: PageRequest
) -> list[dict[str, Any]]:
    by_id = _preference_map(identity)
    records = [
        _resolved_category(item, by_id, request) for item in _category_source(payload)
    ]
    observed_ids = {record["category_id"] for record in records}
    records.extend(
        _unresolved_category(local_id, by_id[local_id], request)
        for local_id in sorted(set(by_id) - observed_ids)
    )
    return records


def page(
    api: Api, request: PageRequest, identity: dict[str, Any]
) -> ApiResult | dict[str, Any]:
    """Execute exactly one reviewed GET route for the selected stream."""
    from _knowledge_social_discourse_pages import page as execute_page

    return execute_page(api, request, identity)
