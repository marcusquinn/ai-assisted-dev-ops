#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Lemmy v3 GET routes, numeric pages, and response serializers."""

from __future__ import annotations

from typing import Any, Callable

from _knowledge_social_lemmy import PageRequest
from _knowledge_social_lemmy_contract import (
    ApiResult,
    LemmyReadProviderError,
    object_list,
    object_value,
    page_payload,
)
from _knowledge_social_lemmy_records import (
    comment_record,
    community_record,
    pagination_watermark,
    post_record,
    split_inbox_record,
)
from _knowledge_social_lemmy_streams import STREAMS, V3_STREAMS

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

QUERY_KEYS = {
    "/api/v3/user": frozenset({"person_id", "sort", "page", "limit"}),
    "/api/v3/post/list": frozenset(
        {"type_", "sort", "page", "limit", "saved_only", "liked_only"}
    ),
    "/api/v3/comment/list": frozenset(
        {"type_", "sort", "page", "limit", "saved_only", "liked_only"}
    ),
    "/api/v3/user/replies": frozenset({"sort", "page", "limit", "unread_only"}),
    "/api/v3/user/mention": frozenset({"sort", "page", "limit", "unread_only"}),
    "/api/v3/community/list": frozenset({"type_", "sort", "page", "limit"}),
}


def route(request: PageRequest) -> tuple[str, dict[str, str], str]:
    if request.api_family != "v3" or request.stream not in V3_STREAMS:
        raise LemmyReadProviderError("Lemmy v3 route does not support the selected stream")
    page_value = str(request.position)
    if request.page_cursor is not None and request.page_cursor != page_value:
        raise LemmyReadProviderError("Lemmy v3 page cursor is invalid")
    params = {"sort": "New", "page": page_value, "limit": str(request.limit)}
    if request.stream.startswith("authored_"):
        path = "/api/v3/user"
        params["person_id"] = request.provider_account_id
        envelope = "posts" if request.stream.endswith("posts") else "comments"
    elif request.stream.endswith("posts"):
        path, envelope = "/api/v3/post/list", "posts"
        params["type_"] = "All"
        params["saved_only" if request.stream.startswith("saved_") else "liked_only"] = "true"
    elif request.stream.endswith("comments"):
        path, envelope = "/api/v3/comment/list", "comments"
        params["type_"] = "All"
        params["saved_only" if request.stream.startswith("saved_") else "liked_only"] = "true"
    elif request.stream == "replies":
        path, envelope = "/api/v3/user/replies", "replies"
        params["unread_only"] = "false"
    elif request.stream == "mentions":
        path, envelope = "/api/v3/user/mention", "mentions"
        params["unread_only"] = "false"
    else:
        path, envelope = "/api/v3/community/list", "communities"
        params["type_"] = "Subscribed"
    return path, params, envelope


def _serialize(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    if request.stream.endswith("posts"):
        return post_record(item, request, v4=False)
    if request.stream.endswith("comments"):
        return comment_record(item, request, v4=False)
    if request.stream == "replies":
        return split_inbox_record(item, request, mention=False)
    if request.stream == "mentions":
        return split_inbox_record(item, request, mention=True)
    return community_record(item, request, v4=False)


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute one exact v3 page/limit route without v4 cursor semantics."""
    path, params, envelope = route(request)
    result = api(path, params)
    if result.status != 200:
        return result
    payload = object_value(result.payload, f"{request.stream} response")
    source = object_list(payload.get(envelope), envelope, limit=request.limit)
    records = [_serialize(item, request) for item in source]
    watermark, crossed = (
        pagination_watermark(
            records,
            request.watermark,
            overlap_cutoff=request.overlap_cutoff,
        )
        if STREAMS[request.stream].incremental
        else (request.watermark, False)
    )
    complete = crossed or len(source) < request.limit
    next_page = None if complete else request.position + 1
    return page_payload(
        request=request,
        records=records,
        next_page=next_page,
        complete=complete,
        watermark=watermark,
    )
