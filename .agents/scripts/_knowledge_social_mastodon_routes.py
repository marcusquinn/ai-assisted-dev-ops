#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact GET route allowlist, opaque pagination, and Mastodon serializers."""

from __future__ import annotations

import re
from typing import Any, Callable
from urllib.parse import quote, urlsplit

from _knowledge_social_mastodon import PageRequest, namespaced_id
from _knowledge_social_mastodon_contract import (
    ApiResult,
    MastodonReadProviderError,
    object_list,
    object_value,
    observed_at,
    optional_boolean,
    optional_text,
    required_text,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]

EXACT_READ_PATHS = frozenset(
    {
        "/api/v1/accounts/verify_credentials",
        "/api/v1/favourites",
        "/api/v1/bookmarks",
        "/api/v1/notifications",
        "/api/v1/followed_tags",
        "/api/v1/lists",
    }
)
ACCOUNT_PATH = re.compile(r"^/api/v1/accounts/[A-Za-z0-9._~%-]+/(statuses|followers|following)$")
LIST_ACCOUNTS_PATH = re.compile(r"^/api/v1/lists/[A-Za-z0-9._~%-]+/accounts$")

STREAM_PATHS = {
    "favourites": "/api/v1/favourites",
    "bookmarks": "/api/v1/bookmarks",
    "notifications": "/api/v1/notifications",
    "followed_tags": "/api/v1/followed_tags",
    "lists": "/api/v1/lists",
}
STREAM_LIMITS = {
    "authored_statuses": 40,
    "favourites": 40,
    "bookmarks": 40,
    "notifications": 80,
    "followers": 80,
    "following": 80,
    "followed_tags": 100,
    "lists": 100,
}


def allowlisted_path(path: str) -> bool:
    return (
        path in EXACT_READ_PATHS
        or ACCOUNT_PATH.fullmatch(path) is not None
        or LIST_ACCOUNTS_PATH.fullmatch(path) is not None
    )


def query_keys_for_path(path: str) -> frozenset[str]:
    if path in ("/api/v1/accounts/verify_credentials", "/api/v1/lists"):
        return frozenset()
    return frozenset({"limit", "max_id", "min_id", "since_id"})


def page_limit_for_path(path: str) -> int:
    if path in ("/api/v1/favourites", "/api/v1/bookmarks") or path.endswith("/statuses"):
        return 40
    if path == "/api/v1/notifications" or path.endswith(("/followers", "/following", "/accounts")):
        return 80
    return 100


def _resource_id(request: PageRequest, kind: str, value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MastodonReadProviderError(f"Mastodon {field} is required")
    try:
        return namespaced_id(request.instance_id, kind, value)
    except RuntimeError as error:
        raise MastodonReadProviderError(str(error)) from error


def _account(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    account_id = required_text(item.get("id"), "account ID")
    return {
        "kind": "account",
        "remote_id": _resource_id(request, "account", account_id, "account ID"),
        "provider_account_id": account_id,
        "username": required_text(item.get("username"), "account username"),
        "acct": required_text(item.get("acct"), "account acct"),
        "name": optional_text(item.get("display_name"), "account display name"),
    }


def _status(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    status_id = required_text(item.get("id"), "status ID")
    author = object_value(item.get("account"), "status account")
    author_id = required_text(author.get("id"), "status account ID")
    if request.stream == "authored_statuses" and author_id != request.provider_account_id:
        raise MastodonReadProviderError(
            "Mastodon authored status does not belong to the selected account"
        )
    return {
        "kind": "status",
        "remote_id": _resource_id(request, "status", status_id, "status ID"),
        "status_id": status_id,
        "author_remote_id": _resource_id(request, "account", author_id, "status account ID"),
        "content": optional_text(item.get("content"), "status content"),
        "spoiler_text": optional_text(item.get("spoiler_text"), "status spoiler text"),
        "created_at": optional_text(item.get("created_at"), "status timestamp"),
        "visibility": optional_text(item.get("visibility"), "status visibility"),
        "sensitive": optional_boolean(item.get("sensitive"), "status sensitive flag"),
    }


def _notification(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    notification_id = required_text(item.get("id"), "notification ID")
    actor = object_value(item.get("account"), "notification account")
    actor_id = required_text(actor.get("id"), "notification account ID")
    status = item.get("status")
    status_id = None
    if status is not None:
        status_id = required_text(object_value(status, "notification status").get("id"), "status ID")
    return {
        "kind": "notification",
        "remote_id": _resource_id(request, "notification", notification_id, "notification ID"),
        "notification_id": notification_id,
        "notification_type": required_text(item.get("type"), "notification type"),
        "actor_remote_id": _resource_id(request, "account", actor_id, "notification account ID"),
        "status_remote_id": (
            _resource_id(request, "status", status_id, "status ID") if status_id else None
        ),
        "created_at": optional_text(item.get("created_at"), "notification timestamp"),
    }


def _tag(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    name = required_text(item.get("name"), "tag name")
    return {
        "kind": "tag",
        "remote_id": _resource_id(request, "tag", name, "tag name"),
        "name": name,
    }


def _list(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    list_id = required_text(item.get("id"), "list ID")
    return {
        "kind": "list",
        "remote_id": _resource_id(request, "list", list_id, "list ID"),
        "list_id": list_id,
        "title": required_text(item.get("title"), "list title"),
        "replies_policy": optional_text(item.get("replies_policy"), "list replies policy"),
        "exclusive": optional_boolean(item.get("exclusive"), "list exclusive flag"),
    }


SERIALIZERS = {
    "authored_statuses": _status,
    "favourites": _status,
    "bookmarks": _status,
    "notifications": _notification,
    "followers": _account,
    "following": _account,
    "followed_tags": _tag,
    "lists": _list,
}


def _initial_path(request: PageRequest) -> tuple[str, dict[str, str]]:
    if request.stream == "authored_statuses":
        path = f"/api/v1/accounts/{quote(request.provider_account_id, safe='')}/statuses"
    elif request.stream in ("followers", "following"):
        path = f"/api/v1/accounts/{quote(request.provider_account_id, safe='')}/{request.stream}"
    else:
        path = STREAM_PATHS[request.stream]
    bounded_limit = min(request.limit, STREAM_LIMITS[request.stream])
    params = {} if request.stream == "lists" else {"limit": str(bounded_limit)}
    return path, params


def page(api: Api, request: PageRequest, _identity: dict[str, Any]) -> PageResult:
    """Execute one initial route or the validated opaque next Link unchanged."""
    initial_path, initial_params = _initial_path(request)
    if request.stop_at is None:
        target, params = initial_path, initial_params
    else:
        parsed = urlsplit(request.stop_at)
        if parsed.scheme.lower() != "https" or not parsed.netloc or parsed.path != initial_path:
            raise MastodonReadProviderError(
                "Mastodon pagination link does not match the selected stream"
            )
        target, params = request.stop_at, {}
    result = api(target, params)
    if result.status != 200:
        return result
    source = object_list(
        result.payload,
        f"{request.stream} response",
        limit=STREAM_LIMITS[request.stream],
    )
    records = [SERIALIZERS[request.stream](item, request) for item in source]
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "next_url": result.next_url,
            "complete": result.next_url is None,
            "snapshot": True,
        },
    }
