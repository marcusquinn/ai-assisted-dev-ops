#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Stack Exchange GET routes, wrapper policy, and serializers."""

from __future__ import annotations

import time
from typing import Any, Callable

from _knowledge_social_stack_exchange import PageRequest
from _knowledge_social_stack_exchange_contract import (
    ApiResult,
    StackExchangeReadProviderError,
    observed_at,
    optional_text,
    required_text,
    wrapper,
)
from _knowledge_social_stack_exchange_identity import (
    associated_account_id,
    namespaced_id,
    network_account_id,
    site_user_id,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

EXACT_READ_PATHS = frozenset(
    {
        "/me",
        "/me/posts",
        "/me/questions",
        "/me/answers",
        "/me/comments",
        "/me/favorites",
        "/me/inbox",
        "/me/notifications",
        "/me/associated",
    }
)
STREAM_PATHS = {
    "posts": "/me/posts",
    "questions": "/me/questions",
    "answers": "/me/answers",
    "comments": "/me/comments",
    "favorites": "/me/favorites",
    "inbox": "/me/inbox",
    "notifications": "/me/notifications",
    "associated_accounts": "/me/associated",
}


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path == "/me":
        return frozenset({"site", "filter"})
    if path == "/me/associated":
        return frozenset({"page", "pagesize", "filter"})
    return frozenset({"site", "page", "pagesize", "filter"})


def _integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise StackExchangeReadProviderError(f"Stack Exchange {field} is invalid")
    return value


def _signed_integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise StackExchangeReadProviderError(f"Stack Exchange {field} is invalid")
    return value


def _resource(request: PageRequest, kind: str, value: Any) -> str:
    try:
        return namespaced_id(request.api_site_parameter, kind, value)
    except RuntimeError as error:
        raise StackExchangeReadProviderError(str(error)) from error


def _post(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    post_id = item.get("post_id", item.get("question_id", item.get("answer_id")))
    kind = item.get("post_type", "post")
    if kind not in ("question", "answer"):
        kind = "post"
    return {
        "kind": kind,
        "remote_id": _resource(request, kind, post_id),
        "title": optional_text(item.get("title"), "post title"),
        "body": optional_text(item.get("body_markdown", item.get("body")), "post body"),
        "created_at": _integer(item.get("creation_date"), "post creation timestamp"),
        "updated_at": _integer(item.get("last_activity_date"), "post update timestamp"),
        "score": _signed_integer(item.get("score"), "post score"),
    }


def _question(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    item = dict(item)
    item["post_type"] = "question"
    return _post(item, request)


def _answer(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    item = dict(item)
    item["post_type"] = "answer"
    return _post(item, request)


def _comment(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    comment_id = _integer(item.get("comment_id"), "comment ID")
    if comment_id is None:
        raise StackExchangeReadProviderError("Stack Exchange comment ID is required")
    return {
        "kind": "comment",
        "remote_id": _resource(request, "comment", comment_id),
        "body": optional_text(item.get("body_markdown", item.get("body")), "comment body"),
        "created_at": _integer(item.get("creation_date"), "comment creation timestamp"),
        "post_remote_id": _resource(request, "post", item.get("post_id")),
        "score": _signed_integer(item.get("score"), "comment score"),
    }


def _inbox(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    item_type = required_text(item.get("item_type"), "inbox item type")
    identity = item.get("comment_id", item.get("answer_id", item.get("question_id")))
    return {
        "kind": "inbox_item",
        "remote_id": _resource(request, "inbox_item", f"{item_type}:{identity}"),
        "item_type": item_type,
        "title": optional_text(item.get("title"), "inbox title"),
        "created_at": _integer(item.get("creation_date"), "inbox timestamp"),
        "is_unread": item.get("is_unread") if isinstance(item.get("is_unread"), bool) else None,
    }


def _notification(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    notification_type = required_text(item.get("notification_type"), "notification type")
    created = _integer(item.get("creation_date"), "notification timestamp")
    identity = f"{notification_type}:{created}:{item.get('post_id', '')}"
    return {
        "kind": "notification",
        "remote_id": _resource(request, "notification", identity),
        "notification_type": notification_type,
        "body": optional_text(item.get("body"), "notification body"),
        "created_at": created,
    }


def _associated(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    network = network_account_id(item.get("account_id"))
    if network != request.network_account_id:
        raise StackExchangeReadProviderError(
            "Stack Exchange association belongs to another network account"
        )
    local = site_user_id(item.get("user_id"))
    site_url = required_text(item.get("site_url"), "associated site URL")
    return {
        "kind": "account",
        "remote_id": associated_account_id(network, site_url, local),
        "network_account_id": network,
        "site_user_id": local,
        "site_url": site_url,
        "site_name": optional_text(item.get("site_name"), "associated site name"),
        "reputation": _integer(item.get("reputation"), "associated reputation"),
    }


SERIALIZERS = {
    "posts": _post,
    "questions": _question,
    "answers": _answer,
    "comments": _comment,
    "favorites": _question,
    "inbox": _inbox,
    "notifications": _notification,
    "associated_accounts": _associated,
}


def page(api: Api, request: PageRequest) -> PageResult:
    path = STREAM_PATHS[request.stream]
    params = {
        "page": str(request.page),
        "pagesize": str(min(request.limit, 100)),
        "filter": "withbody",
    }
    if request.stream != "associated_accounts":
        params["site"] = request.api_site_parameter
    result = api(path, params)
    if result.status != 200:
        return result
    items, has_more, backoff, quota = wrapper(result.payload, limit=100)
    if backoff is not None:
        return ApiResult(429, {}, int(time.time()) + backoff)
    if quota == 0:
        return ApiResult(429, {})
    records = [SERIALIZERS[request.stream](item, request) for item in items]
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "api_site_parameter": request.api_site_parameter,
            "has_more": has_more,
            "quota_remaining": quota,
            "snapshot": True,
        },
    }
