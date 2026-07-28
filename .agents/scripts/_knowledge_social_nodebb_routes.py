#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact GET route allowlist, pagination, and serializers for NodeBB reads."""

from __future__ import annotations

import re
from typing import Any, Callable
from urllib.parse import quote

from _knowledge_social_nodebb import (
    MAX_LEGACY_PAGE_ITEMS,
    PageRequest,
    STREAMS,
    namespaced_id,
)
from _knowledge_social_nodebb_contract import (
    ApiResult,
    NodeBBReadProviderError,
    non_negative_integer,
    object_list,
    object_value,
    observed_at,
    optional_boolean,
    optional_text,
    positive_id,
    required_text,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

EXACT_READ_PATHS = frozenset(
    {"/api/self", "/api/config", "/api/v3/ping", "/api/notifications", "/api/v3/chats"}
)
PARAMETERIZED_READ_PATHS = (
    re.compile(
        r"^/api/user/[A-Za-z0-9_.~-]+/(topics|posts|upvoted|downvoted|bookmarks|watched|categories|following|followers|groups)$"
    ),
)

STREAM_SUFFIX = {
    "authored_topics": "topics",
    "authored_posts": "posts",
    "upvoted": "upvoted",
    "downvoted": "downvoted",
    "bookmarks": "bookmarks",
    "watched_topics": "watched",
    "category_state": "categories",
    "following": "following",
    "followers": "followers",
    "groups": "groups",
}


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS or any(
        pattern.fullmatch(path) for pattern in PARAMETERIZED_READ_PATHS
    )


def user_path(slug: str, suffix: str) -> str:
    path = f"/api/user/{quote(slug, safe='')}/{suffix}"
    if not allowlisted_path(path):
        raise NodeBBReadProviderError("NodeBB API path is not allowlisted")
    return path


def _resource_id(request: PageRequest, kind: str, value: Any, field: str) -> str:
    if isinstance(value, int) and not isinstance(value, bool):
        text = str(value)
    else:
        text = value
    if not isinstance(text, str) or not text or "\x00" in text:
        raise NodeBBReadProviderError(f"NodeBB {field} is required")
    try:
        return namespaced_id(request.instance_id, kind, text)
    except RuntimeError as error:
        raise NodeBBReadProviderError(str(error)) from error


def _response_root(payload: Any, field: str) -> dict[str, Any]:
    root = object_value(payload, field)
    response = root.get("response")
    return object_value(response, field) if response is not None else root


def _source(root: dict[str, Any], fields: tuple[str, ...], limit: int) -> list[dict[str, Any]]:
    for field in fields:
        if field in root:
            return object_list(root[field], field, limit=limit)
    if "users" in root:
        return object_list(root["users"], "users", limit=limit)
    raise NodeBBReadProviderError("NodeBB response contains no allowlisted collection")


def _next_page(root: dict[str, Any], request: PageRequest) -> int | None:
    pagination = root.get("pagination")
    if pagination is None:
        return None
    page_data = object_value(pagination, "pagination")
    next_data = object_value(page_data.get("next", {}), "next pagination")
    active = optional_boolean(next_data.get("active"), "next-page active flag")
    if not active:
        return None
    page = non_negative_integer(next_data.get("page"), "next page")
    if page is None or page <= request.position:
        raise NodeBBReadProviderError("NodeBB pagination did not advance")
    return page


def _accepted(
    request: PageRequest, records: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], bool]:
    if request.stop_at is None:
        return records, False
    for index, record in enumerate(records):
        if record.get("remote_id") == request.stop_at:
            return records[:index], True
    return records, False


def _payload(
    request: PageRequest,
    records: list[dict[str, Any]],
    next_position: int | None,
) -> dict[str, Any]:
    accepted, reached = _accepted(request, records)
    if reached:
        next_position = None
    snapshot = STREAMS[request.stream].pagination == "snapshot"
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": accepted,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "next_position": next_position,
            "newest_id": records[0].get("remote_id") if records else None,
            "reached_watermark": reached,
            "complete": reached or next_position is None,
            "snapshot": snapshot,
        },
    }


def _topic(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    topic_id = positive_id(item.get("tid"), "topic ID")
    if topic_id is None:
        raise NodeBBReadProviderError("NodeBB topic has no stable ID")
    return {
        "kind": "topic",
        "remote_id": _resource_id(request, "topic", topic_id, "topic ID"),
        "topic_id": topic_id,
        "title": optional_text(item.get("title"), "topic title"),
        "excerpt": optional_text(item.get("teaser", item.get("content")), "topic excerpt"),
        "created_at": optional_text(item.get("timestampISO"), "topic timestamp"),
        "post_count": non_negative_integer(item.get("postcount"), "topic post count", optional=True),
    }


def _post(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    post_id = positive_id(item.get("pid"), "post ID")
    if post_id is None:
        raise NodeBBReadProviderError("NodeBB post has no stable ID")
    return {
        "kind": "post",
        "remote_id": _resource_id(request, "post", post_id, "post ID"),
        "post_id": post_id,
        "topic_id": positive_id(item.get("tid"), "post topic ID", optional=True),
        "title": optional_text(item.get("title"), "post title"),
        "excerpt": optional_text(item.get("content"), "post content"),
        "created_at": optional_text(item.get("timestampISO"), "post timestamp"),
        "vote_count": non_negative_integer(item.get("votes"), "post vote count", optional=True),
    }


def _user(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    uid = positive_id(item.get("uid"), "user ID")
    if uid is None:
        raise NodeBBReadProviderError("NodeBB relationship user has no stable ID")
    return {
        "kind": "user",
        "remote_id": _resource_id(request, "user", uid, "user ID"),
        "user_id": uid,
        "userslug": optional_text(item.get("userslug"), "relationship userslug"),
        "name": optional_text(item.get("displayname", item.get("username")), "user name"),
    }


def _category(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    cid = positive_id(item.get("cid"), "category ID")
    if cid is None:
        raise NodeBBReadProviderError("NodeBB category has no stable ID")
    return {
        "kind": "category",
        "remote_id": _resource_id(request, "category", cid, "category ID"),
        "category_id": cid,
        "name": required_text(item.get("name"), "category name"),
        "description": optional_text(item.get("description"), "category description"),
        "state": optional_text(
            item.get("watchState", item.get("subscription")), "category state"
        ),
    }


def _group(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    source_id = item.get("slug", item.get("name"))
    group_id = _resource_id(request, "group", source_id, "group ID")
    return {
        "kind": "group",
        "remote_id": group_id,
        "name": required_text(item.get("name"), "group name"),
        "slug": optional_text(item.get("slug"), "group slug"),
        "hidden": optional_boolean(item.get("hidden"), "group hidden flag"),
        "private": optional_boolean(item.get("private"), "group private flag"),
    }


def _notification(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    nid = positive_id(item.get("nid"), "notification ID")
    if nid is None:
        raise NodeBBReadProviderError("NodeBB notification has no stable ID")
    return {
        "kind": "notification",
        "remote_id": _resource_id(request, "notification", nid, "notification ID"),
        "notification_id": nid,
        "notification_type": optional_text(item.get("type"), "notification type"),
        "read": optional_boolean(item.get("read"), "notification read flag"),
        "topic_id": positive_id(item.get("tid"), "notification topic ID", optional=True),
        "post_id": positive_id(item.get("pid"), "notification post ID", optional=True),
        "created_at": optional_text(item.get("datetimeISO"), "notification timestamp"),
        "text": optional_text(item.get("bodyShort"), "notification text"),
    }


def _chat_room(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    room_id = positive_id(item.get("roomId"), "chat room ID")
    if room_id is None:
        raise NodeBBReadProviderError("NodeBB chat room has no stable ID")
    return {
        "kind": "chat_room",
        "remote_id": _resource_id(request, "chat", room_id, "chat room ID"),
        "room_id": room_id,
        "name": optional_text(item.get("roomName"), "chat room name"),
        "unread": optional_boolean(item.get("unread"), "chat unread flag"),
        "created_at": optional_text(item.get("lastUserActivityAt"), "chat activity timestamp"),
    }


SERIALIZERS = {
    "authored_topics": _topic,
    "watched_topics": _topic,
    "authored_posts": _post,
    "upvoted": _post,
    "downvoted": _post,
    "bookmarks": _post,
    "category_state": _category,
    "following": _user,
    "followers": _user,
    "groups": _group,
    "notifications": _notification,
}


def _legacy_page(api: Api, request: PageRequest) -> PageResult:
    suffix = STREAM_SUFFIX[request.stream]
    params = {} if request.stream == "groups" else {"page": str(request.position)}
    result = api(user_path(request.userslug, suffix), params)
    if result.status != 200:
        return result
    root = _response_root(result.payload, f"{request.stream} response")
    fields = {
        "authored_topics": ("topics",),
        "watched_topics": ("topics",),
        "authored_posts": ("posts",),
        "upvoted": ("posts",),
        "downvoted": ("posts",),
        "bookmarks": ("posts", "bookmarks"),
        "category_state": ("categories",),
        "following": ("following", "users"),
        "followers": ("followers", "users"),
        "groups": ("groups",),
    }[request.stream]
    source = _source(root, fields, MAX_LEGACY_PAGE_ITEMS)
    serializer = SERIALIZERS[request.stream]
    records = [serializer(item, request) for item in source]
    next_position = None if request.stream == "groups" else _next_page(root, request)
    return _payload(request, records, next_position)


def _notifications(api: Api, request: PageRequest) -> PageResult:
    result = api("/api/notifications", {"page": str(request.position)})
    if result.status != 200:
        return result
    root = _response_root(result.payload, "notification response")
    source = _source(root, ("notifications",), MAX_LEGACY_PAGE_ITEMS)
    records = [_notification(item, request) for item in source]
    return _payload(request, records, _next_page(root, request))


def _chats(api: Api, request: PageRequest) -> PageResult:
    result = api(
        "/api/v3/chats",
        {"start": str(request.position), "perPage": str(request.limit)},
    )
    if result.status != 200:
        return result
    root = _response_root(result.payload, "chat response")
    source = _source(root, ("rooms", "chats"), request.limit)
    records = [_chat_room(item, request) for item in source]
    next_value = root.get("nextStart")
    next_position = None
    if next_value is not None:
        next_position = non_negative_integer(next_value, "next chat position")
        if next_position is not None and next_position <= request.position:
            raise NodeBBReadProviderError("NodeBB chat pagination did not advance")
    return _payload(request, records, next_position)


def _capabilities(api: Api, request: PageRequest) -> PageResult:
    ping = api("/api/v3/ping", {})
    if ping.status != 200:
        return ping
    config = api("/api/config", {})
    if config.status != 200:
        return config
    ping_root = object_value(ping.payload, "ping response")
    ping_status = object_value(ping_root.get("status", {}), "ping status")
    response = object_value(ping_root.get("response", {}), "ping payload")
    if ping_status.get("code") != "ok" or response.get("pong") is not True:
        raise NodeBBReadProviderError("NodeBB v3 core capability check failed")
    config_root = object_value(config.payload, "config response")
    record = {
        "kind": "installation_capability",
        "remote_id": _resource_id(request, "capability", "core", "capability ID"),
        "v3_ping": True,
        "logged_in": optional_boolean(config_root.get("loggedIn"), "logged-in flag"),
        "uid": positive_id(config_root.get("uid"), "config account ID", optional=True),
        "pagination": optional_boolean(config_root.get("usePagination"), "pagination flag"),
        "chat_disabled": optional_boolean(config_root.get("disableChat"), "chat flag"),
    }
    if record["uid"] not in (None, request.provider_account_id):
        raise NodeBBReadProviderError(
            "selected NodeBB account does not match the configured connection"
        )
    return _payload(request, [record], None)


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute only reviewed core GET routes for the selected stream."""
    if request.stream == "capabilities":
        return _capabilities(api, request)
    if request.stream == "notifications":
        return _notifications(api, request)
    if request.stream == "chat_rooms":
        return _chats(api, request)
    if request.stream in STREAM_SUFFIX:
        return _legacy_page(api, request)
    raise NodeBBReadProviderError("NodeBB stream is unsupported")
