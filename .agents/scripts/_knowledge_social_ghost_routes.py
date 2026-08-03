#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact GET routes, pagination, and serializers for Ghost Content API reads."""

from __future__ import annotations

from typing import Any, Callable

from _knowledge_social_ghost import PageRequest, namespaced_id
from _knowledge_social_ghost_contract import (
    ApiResult,
    GhostReadProviderError,
    non_negative_integer,
    object_list,
    object_value,
    observed_at,
    optional_text,
    positive_integer,
    required_text,
)
from knowledge_social_import import reject_credentials

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

SITE_PATH = "/ghost/api/admin/site/"
STREAM_PATHS = {
    "posts": "/ghost/api/content/posts/",
    "pages": "/ghost/api/content/pages/",
    "tags": "/ghost/api/content/tags/",
    "authors": "/ghost/api/content/authors/",
}
EXACT_READ_PATHS = frozenset({SITE_PATH, *STREAM_PATHS.values()})


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def _resource_id(request: PageRequest, kind: str, value: Any, field: str) -> str:
    text = required_text(value, field)
    try:
        return namespaced_id(request.instance_id, kind, text)
    except RuntimeError as error:
        raise GhostReadProviderError(str(error)) from error


def _content(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    kind = "post" if request.stream == "posts" else "page"
    local_id = required_text(item.get("id"), f"{kind} ID")
    return {
        "kind": kind,
        "remote_id": _resource_id(request, kind, local_id, f"{kind} ID"),
        "resource_id": local_id,
        "uuid": optional_text(item.get("uuid"), f"{kind} UUID"),
        "title": required_text(item.get("title"), f"{kind} title"),
        "slug": required_text(item.get("slug"), f"{kind} slug"),
        "html": optional_text(item.get("html"), f"{kind} HTML"),
        "plaintext": optional_text(item.get("plaintext"), f"{kind} plaintext"),
        "excerpt": optional_text(item.get("excerpt"), f"{kind} excerpt"),
        "custom_excerpt": optional_text(
            item.get("custom_excerpt"), f"{kind} custom excerpt"
        ),
        "created_at": optional_text(item.get("created_at"), f"{kind} created timestamp"),
        "updated_at": optional_text(item.get("updated_at"), f"{kind} updated timestamp"),
        "published_at": optional_text(
            item.get("published_at"), f"{kind} published timestamp"
        ),
    }


def _count_posts(item: dict[str, Any], field: str) -> int | None:
    count = item.get("count")
    if count is None:
        return None
    value = object_value(count, f"{field} count").get("posts")
    return non_negative_integer(value, f"{field} post count")


def _tag(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    if item.get("visibility") != "public":
        raise GhostReadProviderError("Ghost Content API returned a non-public tag")
    local_id = required_text(item.get("id"), "tag ID")
    return {
        "kind": "tag",
        "remote_id": _resource_id(request, "tag", local_id, "tag ID"),
        "resource_id": local_id,
        "name": required_text(item.get("name"), "tag name"),
        "slug": required_text(item.get("slug"), "tag slug"),
        "description": optional_text(item.get("description"), "tag description"),
        "post_count": _count_posts(item, "tag"),
    }


def _author(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    local_id = required_text(item.get("id"), "author ID")
    return {
        "kind": "author",
        "remote_id": _resource_id(request, "author", local_id, "author ID"),
        "resource_id": local_id,
        "name": required_text(item.get("name"), "author name"),
        "slug": required_text(item.get("slug"), "author slug"),
        "bio": optional_text(item.get("bio"), "author bio"),
        "post_count": _count_posts(item, "author"),
    }


SERIALIZERS = {
    "posts": _content,
    "pages": _content,
    "tags": _tag,
    "authors": _author,
}


def _pagination(
    payload: dict[str, Any], request: PageRequest
) -> tuple[int | None, bool]:
    meta = object_value(payload.get("meta"), "pagination metadata")
    pagination = object_value(meta.get("pagination"), "pagination")
    page_number = positive_integer(pagination.get("page"), "pagination page")
    page_limit = positive_integer(pagination.get("limit"), "pagination limit")
    pages = positive_integer(pagination.get("pages"), "pagination pages")
    total = non_negative_integer(pagination.get("total"), "pagination total")
    if page_number != request.position or page_limit != request.limit or page_number > pages:
        raise GhostReadProviderError("Ghost pagination does not match the request")
    next_value = pagination.get("next")
    next_position = (
        None if next_value is None else positive_integer(next_value, "next page")
    )
    previous = pagination.get("prev")
    if previous is not None:
        previous = positive_integer(previous, "previous page")
    expected_previous = None if page_number == 1 else page_number - 1
    if previous != expected_previous:
        raise GhostReadProviderError("Ghost previous-page metadata is invalid")
    if next_position is None:
        if page_number != pages:
            raise GhostReadProviderError("Ghost pagination ended before the final page")
    elif next_position != page_number + 1 or next_position > pages:
        raise GhostReadProviderError("Ghost next-page metadata is invalid")
    if total == 0 and (page_number != 1 or pages != 1):
        raise GhostReadProviderError("Ghost empty pagination metadata is invalid")
    return next_position, next_position is None


def _params(request: PageRequest) -> dict[str, str]:
    params = {"page": str(request.position), "limit": str(request.limit)}
    if request.stream in ("posts", "pages"):
        params["formats"] = "html,plaintext"
    elif request.stream == "tags":
        params["filter"] = "visibility:public"
        params["include"] = "count.posts"
    else:
        params["include"] = "count.posts"
    return params


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute only reviewed official GET routes for one public stream."""
    result = api(STREAM_PATHS[request.stream], _params(request))
    if result.status != 200:
        return result
    payload = object_value(result.payload, f"{request.stream} response")
    reject_credentials(payload)
    source = object_list(
        payload.get(request.stream), f"{request.stream} response", limit=request.limit
    )
    next_position, complete = _pagination(payload, request)
    records = [SERIALIZERS[request.stream](item, request) for item in source]
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "next_position": next_position,
            "newest_id": records[0].get("remote_id") if records else None,
            "complete": complete,
            "snapshot": True,
        },
    }
