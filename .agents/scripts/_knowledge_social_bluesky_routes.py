#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Bluesky XRPC query parameters and bounded response projection."""

from __future__ import annotations

from typing import Any

from _knowledge_social_bluesky import BlueskyAdapterError, PageRequest
from _knowledge_social_bluesky_http import (
    ApiResult,
    Profile,
    api,
    observed_at,
    service_id,
    terminal_payload,
)

RESULT_KEYS = {
    "com.atproto.repo.listRecords": "records",
    "com.atproto.sync.listBlobs": "cids",
    "app.bsky.feed.getAuthorFeed": "feed",
    "app.bsky.notification.listNotifications": "notifications",
    "app.bsky.actor.getPreferences": "preferences",
    "app.bsky.bookmark.getBookmarks": "bookmarks",
    "app.bsky.graph.getMutes": "mutes",
    "app.bsky.graph.getLists": "lists",
    "app.bsky.graph.getActorStarterPacks": "starterPacks",
    "com.atproto.label.queryLabels": "labels",
    "chat.bsky.convo.listConvos": "convos",
    "chat.bsky.convo.getLog": "logs",
}


def _base_params(request: PageRequest) -> dict[str, str]:
    endpoint = request.endpoint
    if endpoint == "com.atproto.repo.listRecords":
        params = {
            "repo": request.account_id,
            "collection": request.collection or "",
            "limit": str(request.limit),
        }
    elif endpoint in ("com.atproto.sync.getRepoStatus", "com.atproto.sync.listBlobs"):
        params = {"did": request.account_id}
    elif endpoint == "app.bsky.feed.getAuthorFeed":
        params = {
            "actor": request.account_id,
            "filter": "posts_with_replies",
            "limit": str(request.limit),
        }
    elif endpoint in ("app.bsky.graph.getLists", "app.bsky.graph.getActorStarterPacks"):
        params = {"actor": request.account_id, "limit": str(request.limit)}
    elif endpoint == "com.atproto.label.queryLabels":
        params = {"uriPatterns": f"at://{request.account_id}/*", "limit": str(request.limit)}
    elif endpoint == "app.bsky.actor.getPreferences":
        params = {}
    elif endpoint == "chat.bsky.convo.getLog":
        params = {}
    else:
        params = {"limit": str(request.limit)}
    return params


def params_for(request: PageRequest) -> dict[str, str]:
    params = _base_params(request)
    if request.endpoint == "com.atproto.sync.listBlobs":
        params["limit"] = str(request.limit)
    if request.cursor:
        params["cursor"] = request.cursor
    return params


def items_from(payload: dict[str, Any], request: PageRequest) -> list[dict[str, Any]]:
    if request.endpoint == "com.atproto.sync.getRepoStatus":
        return [payload]
    key = RESULT_KEYS.get(request.endpoint)
    value = payload.get(key, []) if key else []
    if not isinstance(value, list):
        raise BlueskyAdapterError("Bluesky query result is not an array")
    if request.endpoint == "com.atproto.sync.listBlobs":
        return [{"cid": item} for item in value if isinstance(item, str)]
    if any(not isinstance(item, dict) for item in value):
        raise BlueskyAdapterError("Bluesky query result contains an invalid item")
    return value


def _proxy_service(profile: Profile, request: PageRequest) -> str | None:
    if request.authority == "chat":
        return profile.chat if profile.chat_enabled else None
    return profile.appview if request.authority == "appview" else ""


def _query(profile: Profile, request: PageRequest) -> tuple[ApiResult, list[dict[str, Any]]] | None:
    proxy = _proxy_service(profile, request)
    if proxy is None:
        return None
    identity = profile.pds if proxy == "" else proxy
    if service_id(identity) != request.service_id:
        raise BlueskyAdapterError("Bluesky service changed during collection")
    result = api(
        profile,
        profile.pds,
        request.endpoint,
        params_for(request),
        proxy or None,
    )
    return result, items_from(result.payload, request) if result.status == 200 else []


def _first_text(values: list[dict[str, Any]], keys: tuple[str, ...]) -> str | None:
    if not values:
        return None
    for key in keys:
        candidate = values[0].get(key)
        if isinstance(candidate, str) and candidate:
            return candidate
    return None


def _watermark(result: ApiResult, items: list[dict[str, Any]]) -> str | None:
    direct = _first_text([result.payload], ("rev", "cid", "uri", "id"))
    return direct or _first_text(items, ("uri", "cid", "id", "convoId", "messageId"))


def _success(request: PageRequest, result: ApiResult, items: list[dict[str, Any]]) -> dict[str, Any]:
    cursor = result.payload.get("cursor")
    if cursor is not None and (not isinstance(cursor, str) or not cursor):
        raise BlueskyAdapterError("Bluesky query cursor is invalid")
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": items,
        "meta": {
            "stream": request.stream,
            "did": request.account_id,
            "service_id": request.service_id,
            "next_cursor": cursor,
            "complete": cursor is None,
            "watermark": _watermark(result, items),
        },
    }


def page(profile: Profile, request: PageRequest) -> dict[str, Any]:
    """Read and project one service-fenced page."""
    if request.endpoint == "unavailable":
        return _success(request, ApiResult(200, {}), [])
    queried = _query(profile, request)
    if queried is None:
        return {"status": 403, "observed_at": observed_at()}
    result, items = queried
    if result.status != 200:
        return terminal_payload(result)
    return _success(request, result, items)
