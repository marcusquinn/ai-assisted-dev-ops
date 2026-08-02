#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Lemmy v4 GET routes, opaque cursors, and response serializers."""

from __future__ import annotations

from typing import Any, Callable

from _knowledge_social_lemmy import PageRequest
from _knowledge_social_lemmy_contract import (
    ApiResult,
    LemmyReadProviderError,
    object_list,
    object_value,
    optional_text,
    page_payload,
)
from _knowledge_social_lemmy_records import (
    comment_record,
    community_record,
    multicommunity_record,
    notification_record,
    pagination_watermark,
    post_record,
)
from _knowledge_social_lemmy_streams import STREAMS, V4_STREAMS

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

QUERY_KEYS = {
    "/api/v4/person/content": frozenset({"person_id", "type_", "page_cursor", "limit"}),
    "/api/v4/account/saved": frozenset({"type_", "page_cursor", "limit"}),
    "/api/v4/account/liked": frozenset(
        {"type_", "like_type", "page_cursor", "limit"}
    ),
    "/api/v4/account/notification/list": frozenset(
        {"type_", "unread_only", "page_cursor", "limit"}
    ),
    "/api/v4/community/list": frozenset({"type_", "page_cursor", "limit"}),
    "/api/v4/multi_community/list": frozenset({"type_", "page_cursor", "limit"}),
}


def route(request: PageRequest) -> tuple[str, dict[str, str]]:
    if request.api_family != "v4" or request.stream not in V4_STREAMS:
        raise LemmyReadProviderError("Lemmy v4 route does not support the selected stream")
    kind = "posts" if request.stream.endswith("posts") else "comments"
    if request.stream.startswith("authored_"):
        path = "/api/v4/person/content"
        params = {"person_id": request.provider_account_id, "type_": kind}
    elif request.stream.startswith("saved_"):
        path = "/api/v4/account/saved"
        params = {"type_": kind}
    elif request.stream.startswith("liked_"):
        path = "/api/v4/account/liked"
        params = {"type_": kind, "like_type": "liked_only"}
    elif request.stream == "notifications":
        path = "/api/v4/account/notification/list"
        params = {"type_": "all", "unread_only": "false"}
    elif request.stream == "subscriptions":
        path = "/api/v4/community/list"
        params = {"type_": "subscribed"}
    else:
        path = "/api/v4/multi_community/list"
        params = {"type_": "subscribed"}
    params["limit"] = str(request.limit)
    if request.page_cursor is not None:
        params["page_cursor"] = request.page_cursor
    return path, params


def _combined(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expected = "post" if request.stream.endswith("posts") else "comment"
    if item.get("type_") != expected:
        raise LemmyReadProviderError("Lemmy v4 combined content type is invalid")
    if expected == "post":
        return post_record(item, request, v4=True)
    return comment_record(item, request, v4=True)


def _serialize(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    if request.stream in {
        "authored_posts", "authored_comments", "saved_posts", "saved_comments",
        "liked_posts", "liked_comments",
    }:
        return _combined(item, request)
    if request.stream == "notifications":
        return notification_record(item, request)
    if request.stream == "subscriptions":
        return community_record(item, request, v4=True)
    return multicommunity_record(item, request)


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute one exact v4 route while retaining page_cursor opaquely."""
    path, params = route(request)
    result = api(path, params)
    if result.status != 200:
        return result
    payload = object_value(result.payload, f"{request.stream} response")
    source = object_list(payload.get("items"), f"{request.stream} items", limit=request.limit)
    records = [_serialize(item, request) for item in source]
    next_page = optional_text(payload.get("next_page"), "v4 next page cursor")
    if next_page is not None and next_page == request.page_cursor:
        raise LemmyReadProviderError("Lemmy v4 page cursor did not advance")
    watermark, crossed = (
        pagination_watermark(
            records,
            request.watermark,
            overlap_cutoff=request.overlap_cutoff,
        )
        if STREAMS[request.stream].incremental
        else (request.watermark, False)
    )
    if crossed:
        next_page = None
    complete = next_page is None
    return page_payload(
        request=request,
        records=records,
        next_page=next_page,
        complete=complete,
        watermark=watermark,
    )
