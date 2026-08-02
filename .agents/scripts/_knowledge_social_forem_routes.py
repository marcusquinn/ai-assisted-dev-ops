#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact GET route allowlist, pagination, and serializers for Forem reads."""

from __future__ import annotations

from typing import Any, Callable

from _knowledge_social_forem import PageRequest, namespaced_id
from _knowledge_social_forem_contract import (
    ApiResult,
    ForemReadProviderError,
    finite_number,
    object_list,
    object_value,
    observed_at,
    optional_text,
    positive_id,
    required_text,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

EXACT_READ_PATHS = frozenset(
    {
        "/api/users/me",
        "/api/articles/me/all",
        "/api/readinglist",
        "/api/follows/tags",
        "/api/followers/users",
    }
)

STREAM_PATHS = {
    "authored_articles": "/api/articles/me/all",
    "reading_list": "/api/readinglist",
    "followed_tags": "/api/follows/tags",
    "followers": "/api/followers/users",
}


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def _resource_id(request: PageRequest, kind: str, value: Any, field: str) -> str:
    text = str(value) if isinstance(value, int) and not isinstance(value, bool) else value
    if not isinstance(text, str) or not text or "\x00" in text:
        raise ForemReadProviderError(f"Forem {field} is required")
    try:
        return namespaced_id(request.instance_id, kind, text)
    except RuntimeError as error:
        raise ForemReadProviderError(str(error)) from error


def _article(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    article_id = positive_id(item.get("id"), "article ID")
    if article_id is None:
        raise ForemReadProviderError("Forem article has no stable ID")
    if request.stream == "authored_articles":
        author = object_value(item.get("user"), "article author")
        author_id = positive_id(author.get("user_id", author.get("id")), "article author ID")
        if author_id != request.provider_account_id:
            raise ForemReadProviderError(
                "Forem authored article does not belong to the selected account"
            )
    return {
        "kind": "article",
        "remote_id": _resource_id(request, "article", article_id, "article ID"),
        "article_id": article_id,
        "title": required_text(item.get("title"), "article title"),
        "description": optional_text(item.get("description"), "article description"),
        "slug": optional_text(item.get("slug"), "article slug"),
        "created_at": optional_text(item.get("created_at"), "article created timestamp"),
        "published_at": optional_text(
            item.get("published_at", item.get("published_timestamp")),
            "article published timestamp",
        ),
    }


def _tag(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    tag_id = positive_id(item.get("id"), "tag ID")
    if tag_id is None:
        raise ForemReadProviderError("Forem followed tag has no stable ID")
    return {
        "kind": "tag",
        "remote_id": _resource_id(request, "tag", tag_id, "tag ID"),
        "tag_id": tag_id,
        "name": required_text(item.get("name"), "tag name"),
        "points": finite_number(item.get("points"), "tag points"),
    }


def _follower(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    user_id = positive_id(item.get("user_id"), "follower user ID")
    if user_id is None:
        raise ForemReadProviderError("Forem follower has no stable user ID")
    return {
        "kind": "user",
        "remote_id": _resource_id(request, "user", user_id, "follower user ID"),
        "user_id": user_id,
        "relationship_id": positive_id(
            item.get("id"), "follower relationship ID", optional=True
        ),
        "name": optional_text(item.get("name"), "follower name"),
    }


SERIALIZERS = {
    "authored_articles": _article,
    "reading_list": _article,
    "followed_tags": _tag,
    "followers": _follower,
}


def _payload(
    request: PageRequest,
    records: list[dict[str, Any]],
    next_position: int | None,
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "next_position": next_position,
            "newest_id": records[0].get("remote_id") if records else None,
            "complete": next_position is None,
            "snapshot": True,
        },
    }


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute only reviewed official GET routes for the selected stream."""
    path = STREAM_PATHS[request.stream]
    params: dict[str, str] = {}
    if request.stream != "followed_tags":
        params = {"page": str(request.position), "per_page": str(request.limit)}
        if request.stream == "followers":
            params["sort"] = "-created_at"
    elif request.position != 1:
        raise ForemReadProviderError("Forem followed tags do not support pagination")
    result = api(path, params)
    if result.status != 200:
        return result
    source = object_list(result.payload, f"{request.stream} response", limit=request.limit)
    records = [SERIALIZERS[request.stream](item, request) for item in source]
    next_position = None
    if request.stream != "followed_tags" and len(source) == request.limit:
        next_position = request.position + 1
    return _payload(request, records, next_position)
