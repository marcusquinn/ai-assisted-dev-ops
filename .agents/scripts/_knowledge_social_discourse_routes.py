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


def _category_records(
    payload: Any, identity: dict[str, Any], request: PageRequest
) -> list[dict[str, Any]]:
    root = object_value(payload, "category response")
    category_list = object_value(root.get("category_list"), "category list")
    categories = object_list(
        category_list.get("categories", []),
        "categories",
        limit=MAX_SNAPSHOT_ITEMS,
    )
    preferences = object_value(
        identity.get("category_preferences", {}), "category preferences"
    )
    by_id: dict[str, list[str]] = {}
    for level, values in preferences.items():
        if not isinstance(level, str) or not isinstance(values, list):
            raise DiscourseReadProviderError(
                "Discourse category preferences are invalid"
            )
        for value in values:
            local_id = required_text(value, "category preference ID")
            by_id.setdefault(local_id, []).append(level)
    records: list[dict[str, Any]] = []
    observed_ids: set[str] = set()
    for item in categories:
        local_id = positive_id(item.get("id"), "category ID")
        if local_id is None:
            raise DiscourseReadProviderError("Discourse category has no stable ID")
        observed_ids.add(local_id)
        records.append(
            {
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
        )
    for local_id, levels in sorted(by_id.items()):
        if local_id in observed_ids:
            continue
        records.append(
            {
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
        )
    return records


def _listing_payload(
    request: PageRequest,
    records: list[dict[str, Any]],
    next_position: int | None,
    *,
    snapshot: bool | None = None,
) -> dict[str, Any]:
    expected_snapshot = STREAMS[request.stream].pagination == "snapshot"
    if snapshot is not None and snapshot != expected_snapshot:
        raise DiscourseReadProviderError(
            "Discourse response snapshot mode is invalid"
        )
    is_snapshot = expected_snapshot if snapshot is None else snapshot
    newest = records[0].get("remote_id") if records else None
    accepted: list[dict[str, Any]] = []
    reached = False
    for record in records:
        if request.stop_at is not None and record.get("remote_id") == request.stop_at:
            reached = True
            break
        accepted.append(record)
    if reached:
        next_position = None
    complete = reached or next_position is None
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": accepted,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "next_position": next_position,
            "newest_id": newest,
            "reached_watermark": reached,
            "complete": complete,
            "snapshot": is_snapshot,
        },
    }


def _user_actions(api: Api, request: PageRequest) -> ApiResult | dict[str, Any]:
    action_filter = {
        "authored_topics": "4",
        "authored_posts": "5",
        "likes": "1",
    }[request.stream]
    result = api(
        "/user_actions.json",
        {
            "username": request.username,
            "filter": action_filter,
            "offset": str(request.position),
            "limit": str(request.limit),
        },
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "user action response")
    source = object_list(
        root.get("user_actions", []), "user actions", limit=request.limit
    )
    kind = "topic" if request.stream == "authored_topics" else "post"
    records = [_action_record(item, request, kind) for item in source]
    next_position = (
        request.position + len(source) if len(source) >= request.limit else None
    )
    return _listing_payload(request, records, next_position)


def _bookmarks(api: Api, request: PageRequest) -> ApiResult | dict[str, Any]:
    result = api(
        _user_path(request.username, "bookmarks"),
        {"page": str(request.position), "limit": str(request.limit)},
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "bookmark response")
    listing = root.get("user_bookmark_list", root)
    listing_object = object_value(listing, "bookmark list")
    source = object_list(
        listing_object.get("bookmarks", []), "bookmarks", limit=request.limit
    )
    records = [_bookmark_record(item, request) for item in source]
    more = listing_object.get("more_bookmarks_url")
    if more is not None and not isinstance(more, str):
        raise DiscourseReadProviderError("Discourse bookmark pagination is invalid")
    has_more = bool(more) if "more_bookmarks_url" in listing_object else len(source) >= request.limit
    return _listing_payload(
        request, records, request.position + 1 if has_more else None
    )


def _notifications(api: Api, request: PageRequest) -> ApiResult | dict[str, Any]:
    result = api(
        "/notifications.json",
        {
            "username": request.username,
            "offset": str(request.position),
            "limit": str(request.limit),
        },
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "notification response")
    source = object_list(
        root.get("notifications", []), "notifications", limit=request.limit
    )
    records = [_notification_record(item, request) for item in source]
    total = non_negative_integer(
        root.get("total_rows_notifications"),
        "notification total",
        optional=False,
    )
    consumed = request.position + len(source)
    if total is None or consumed > total or (not source and request.position < total):
        raise DiscourseReadProviderError(
            "Discourse notification pagination did not advance"
        )
    return _listing_payload(request, records, consumed if consumed < total else None)


def _messages(
    api: Api, request: PageRequest, *, sent: bool
) -> ApiResult | dict[str, Any]:
    result = api(
        _message_path(request.username, sent), {"page": str(request.position)}
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "private-message response")
    listing = object_value(root.get("topic_list"), "private-message topic list")
    source = object_list(
        listing.get("topics", []),
        "private-message topics",
        limit=MAX_MESSAGE_PAGE_ITEMS,
    )
    records = [_message_record(item, request) for item in source]
    more = listing.get("more_topics_url")
    if more is not None and not isinstance(more, str):
        raise DiscourseReadProviderError(
            "Discourse private-message pagination is invalid"
        )
    per_page = non_negative_integer(
        listing.get("per_page"), "private-message page size", optional=True
    )
    has_more = bool(more) if "more_topics_url" in listing else len(source) >= (per_page or request.limit)
    return _listing_payload(
        request,
        records,
        request.position + 1 if has_more else None,
        snapshot=True,
    )


def page(
    api: Api, request: PageRequest, identity: dict[str, Any]
) -> ApiResult | dict[str, Any]:
    """Execute exactly one reviewed GET route for the selected stream."""
    if request.stream not in STREAMS:
        raise DiscourseReadProviderError("Discourse stream is unsupported")
    if request.stream in ("authored_topics", "authored_posts", "likes"):
        return _user_actions(api, request)
    if request.stream == "bookmarks":
        return _bookmarks(api, request)
    if request.stream == "notifications":
        return _notifications(api, request)
    if request.stream == "private_messages":
        return _messages(api, request, sent=False)
    if request.stream == "sent_messages":
        return _messages(api, request, sent=True)
    if request.stream == "reading_state":
        result = api(_user_path(request.username, "topic-tracking-state"), {})
        if result.status != 200:
            return result
        return _listing_payload(
            request, _tracking_records(result.payload, request), None, snapshot=True
        )
    if request.stream == "groups":
        return _listing_payload(
            request, _group_records(identity, request), None, snapshot=True
        )
    if request.stream == "category_preferences":
        result = api("/categories.json", {})
        if result.status != 200:
            return result
        return _listing_payload(
            request,
            _category_records(result.payload, identity, request),
            None,
            snapshot=True,
        )
    raise DiscourseReadProviderError("Discourse stream is unsupported")
