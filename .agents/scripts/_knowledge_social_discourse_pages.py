#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded pagination and stream dispatch for Discourse account reads."""

from __future__ import annotations

from functools import partial
from typing import Any, Callable

from _knowledge_social_discourse import (
    MAX_MESSAGE_PAGE_ITEMS,
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
)
from _knowledge_social_discourse_routes import (
    _action_record,
    _bookmark_record,
    _category_records,
    _group_records,
    _message_path,
    _message_record,
    _notification_record,
    _tracking_records,
    _user_path,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]
PageHandler = Callable[[Api, PageRequest, dict[str, Any]], PageResult]


def _snapshot_mode(request: PageRequest, snapshot: bool | None) -> bool:
    expected = STREAMS[request.stream].pagination == "snapshot"
    if snapshot is None:
        return expected
    if snapshot != expected:
        raise DiscourseReadProviderError(
            "Discourse response snapshot mode is invalid"
        )
    return snapshot


def _accepted_records(
    request: PageRequest, records: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], bool]:
    if request.stop_at is None:
        return records, False
    for index, record in enumerate(records):
        if record.get("remote_id") == request.stop_at:
            return records[:index], True
    return records, False


def _listing_payload(
    request: PageRequest,
    records: list[dict[str, Any]],
    next_position: int | None,
    *,
    snapshot: bool | None = None,
) -> dict[str, Any]:
    accepted, reached = _accepted_records(request, records)
    if reached:
        next_position = None
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
            "snapshot": _snapshot_mode(request, snapshot),
        },
    }


def _user_actions(
    api: Api, request: PageRequest, _identity: dict[str, Any]
) -> PageResult:
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
    next_position = None
    if len(source) >= request.limit:
        next_position = request.position + len(source)
    return _listing_payload(request, records, next_position)


def _more_pages(
    container: dict[str, Any], field: str, fallback: bool, message: str
) -> bool:
    value = container.get(field)
    if value is not None and not isinstance(value, str):
        raise DiscourseReadProviderError(message)
    if field in container:
        return bool(value)
    return fallback


def _bookmarks(
    api: Api, request: PageRequest, _identity: dict[str, Any]
) -> PageResult:
    result = api(
        _user_path(request.username, "bookmarks"),
        {"page": str(request.position), "limit": str(request.limit)},
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "bookmark response")
    listing = object_value(root.get("user_bookmark_list", root), "bookmark list")
    source = object_list(listing.get("bookmarks", []), "bookmarks", limit=request.limit)
    records = [_bookmark_record(item, request) for item in source]
    has_more = _more_pages(
        listing,
        "more_bookmarks_url",
        len(source) >= request.limit,
        "Discourse bookmark pagination is invalid",
    )
    next_position = request.position + 1 if has_more else None
    return _listing_payload(request, records, next_position)


def _notification_next(
    root: dict[str, Any], request: PageRequest, item_count: int
) -> int | None:
    total = non_negative_integer(
        root.get("total_rows_notifications"),
        "notification total",
        optional=False,
    )
    consumed = request.position + item_count
    if total is None or consumed > total:
        raise DiscourseReadProviderError(
            "Discourse notification pagination did not advance"
        )
    if item_count == 0 and request.position < total:
        raise DiscourseReadProviderError(
            "Discourse notification pagination did not advance"
        )
    return consumed if consumed < total else None


def _notifications(
    api: Api, request: PageRequest, _identity: dict[str, Any]
) -> PageResult:
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
    return _listing_payload(
        request,
        records,
        _notification_next(root, request, len(source)),
    )


def _messages(
    api: Api,
    request: PageRequest,
    _identity: dict[str, Any],
    *,
    sent: bool,
) -> PageResult:
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
    per_page = non_negative_integer(
        listing.get("per_page"), "private-message page size", optional=True
    )
    has_more = _more_pages(
        listing,
        "more_topics_url",
        len(source) >= (per_page or request.limit),
        "Discourse private-message pagination is invalid",
    )
    next_position = request.position + 1 if has_more else None
    return _listing_payload(request, records, next_position, snapshot=True)


def _reading_state(
    api: Api, request: PageRequest, _identity: dict[str, Any]
) -> PageResult:
    result = api(_user_path(request.username, "topic-tracking-state"), {})
    if result.status != 200:
        return result
    records = _tracking_records(result.payload, request)
    return _listing_payload(request, records, None, snapshot=True)


def _groups(
    _api: Api, request: PageRequest, identity: dict[str, Any]
) -> PageResult:
    records = _group_records(identity, request)
    return _listing_payload(request, records, None, snapshot=True)


def _category_preferences(
    api: Api, request: PageRequest, identity: dict[str, Any]
) -> PageResult:
    result = api("/categories.json", {})
    if result.status != 200:
        return result
    records = _category_records(result.payload, identity, request)
    return _listing_payload(request, records, None, snapshot=True)


PAGE_HANDLERS: dict[str, PageHandler] = {
    "authored_topics": _user_actions,
    "authored_posts": _user_actions,
    "likes": _user_actions,
    "bookmarks": _bookmarks,
    "notifications": _notifications,
    "private_messages": partial(_messages, sent=False),
    "sent_messages": partial(_messages, sent=True),
    "reading_state": _reading_state,
    "groups": _groups,
    "category_preferences": _category_preferences,
}


def page(
    api: Api, request: PageRequest, identity: dict[str, Any]
) -> PageResult:
    """Execute exactly one reviewed GET route for the selected stream."""
    handler = PAGE_HANDLERS.get(request.stream)
    if handler is None:
        raise DiscourseReadProviderError("Discourse stream is unsupported")
    return handler(api, request, identity)
