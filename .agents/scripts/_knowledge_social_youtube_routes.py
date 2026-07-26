#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted YouTube Data API v3 read routes and page construction."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from _knowledge_social_youtube_contract import (
    ApiResult,
    YouTubeReadProviderError,
    exact_keys,
    listed_records,
    next_page_token,
    observed_at,
    optional_text,
    response_items,
    serialize_activity,
    serialize_comment,
    serialize_comment_thread,
    serialize_playlist,
    serialize_playlist_item,
    serialize_subscription,
    serialize_uploaded_video,
    serialize_video,
    stable_id,
    terminal_payload,
)

ApiCall = Callable[[str, dict[str, str]], ApiResult]
READ_ENDPOINTS = {
    "activities",
    "channels",
    "comments",
    "commentThreads",
    "playlistItems",
    "playlists",
    "subscriptions",
    "videos",
}
STREAMS = {
    "authored_videos",
    "channel_activity",
    "owned_playlists",
    "subscriptions",
    "comments",
    "liked_videos",
}


@dataclass(frozen=True)
class ProviderPageRequest:
    """Validated request fields for one bounded provider page."""

    stream: str
    account_id: str
    uploads_playlist_id: str
    cursor: dict[str, Any] | None
    stop_at: str | None
    limit: int


@dataclass(frozen=True)
class SimplePageRoute:
    """One allowlisted list route with its serializer and cursor policy."""

    endpoint: str
    params: dict[str, str]
    serializer: Callable[[dict[str, Any]], dict[str, Any]]
    incremental: bool


def page_request(request: dict[str, Any]) -> ProviderPageRequest:
    """Validate the complete parent-to-child page request."""
    exact_keys(
        request,
        {
            "action",
            "stream",
            "account_id",
            "uploads_playlist_id",
            "cursor",
            "stop_at",
            "limit",
        },
    )
    stream = request.get("stream")
    cursor = request.get("cursor")
    limit = request.get("limit")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise YouTubeReadProviderError("YouTube read stream is unsupported")
    if cursor is not None and not isinstance(cursor, dict):
        raise YouTubeReadProviderError("YouTube read cursor must be an object")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise YouTubeReadProviderError(
            "YouTube read limit must be between 1 and 50"
        )
    return ProviderPageRequest(
        stream,
        stable_id(request.get("account_id"), "account ID"),
        stable_id(request.get("uploads_playlist_id"), "uploads playlist ID"),
        cursor,
        stable_id(request["stop_at"], "watermark")
        if request.get("stop_at") is not None
        else None,
        limit,
    )


def _token(cursor: dict[str, Any] | None) -> str | None:
    if cursor is None:
        return None
    if set(cursor) != {"page_token"}:
        raise YouTubeReadProviderError("YouTube page cursor has an invalid shape")
    token = optional_text(cursor.get("page_token"), "page token")
    if not token:
        raise YouTubeReadProviderError("YouTube page cursor is empty")
    return token


def _params(**values: str | int | None) -> dict[str, str]:
    return {key: str(value) for key, value in values.items() if value is not None}


def _meta(
    next_cursor: dict[str, Any] | None,
    newest_id: str | None,
    reached: bool,
    *,
    snapshot: bool,
) -> dict[str, Any]:
    return {
        "next_cursor": next_cursor,
        "newest_id": newest_id,
        "reached_watermark": reached,
        "complete": reached or next_cursor is None,
        "snapshot": snapshot,
    }


def _success(
    data: list[dict[str, Any]], meta: dict[str, Any]
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": data,
        "meta": meta,
    }


def _simple_page(
    api: ApiCall,
    request: ProviderPageRequest,
    route: SimplePageRoute,
) -> dict[str, Any]:
    params = dict(route.params)
    page_token = _token(request.cursor)
    if page_token is not None:
        params["pageToken"] = page_token
    result = api(route.endpoint, params)
    if result.status != 200:
        return terminal_payload(result)
    records = [route.serializer(item) for item in response_items(result.payload)]
    records, newest, reached = listed_records(
        records, request.stop_at if route.incremental else None
    )
    provider_next = next_page_token(result.payload)
    next_cursor = (
        {"page_token": provider_next}
        if provider_next is not None and not reached
        else None
    )
    return _success(
        records,
        _meta(next_cursor, newest, reached, snapshot=not route.incremental),
    )


def _authored_videos(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    return _simple_page(
        api,
        request,
        SimplePageRoute(
            "playlistItems",
            _params(
                part="snippet,contentDetails,status",
                playlistId=request.uploads_playlist_id,
                maxResults=request.limit,
            ),
            serialize_uploaded_video,
            True,
        ),
    )


def _channel_activity(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    return _simple_page(
        api,
        request,
        SimplePageRoute(
            "activities",
            _params(
                part="snippet,contentDetails", mine="true", maxResults=request.limit
            ),
            serialize_activity,
            True,
        ),
    )


def _subscriptions(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    return _simple_page(
        api,
        request,
        SimplePageRoute(
            "subscriptions",
            _params(
                part="snippet,contentDetails", mine="true", maxResults=request.limit
            ),
            serialize_subscription,
            False,
        ),
    )


def _liked_videos(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    return _simple_page(
        api,
        request,
        SimplePageRoute(
            "videos",
            _params(
                part="id,snippet,status", myRating="like", maxResults=request.limit
            ),
            serialize_video,
            False,
        ),
    )


def _phase(cursor: dict[str, Any], expected: set[str]) -> None:
    if set(cursor) != expected:
        raise YouTubeReadProviderError("YouTube compound cursor has an invalid shape")


def _owned_playlist_page(
    api: ApiCall,
    request: ProviderPageRequest,
    page_token: str | None,
) -> dict[str, Any]:
    result = api(
        "playlists",
        _params(
            part="id,snippet,contentDetails,status",
            mine="true",
            maxResults=1,
            pageToken=page_token,
        ),
    )
    if result.status != 200:
        return terminal_payload(result)
    items = response_items(result.payload)
    if not items:
        return _success([], _meta(None, None, False, snapshot=True))
    playlist = serialize_playlist(items[0])
    provider_next = next_page_token(result.payload)
    if playlist["item_count"] > 0:
        next_cursor = {
            "phase": "items",
            "playlist_id": playlist["remote_id"],
            "item_token": None,
            "playlists_token": provider_next,
        }
    elif provider_next is not None:
        next_cursor = {"phase": "playlists", "page_token": provider_next}
    else:
        next_cursor = None
    return _success([playlist], _meta(next_cursor, None, False, snapshot=True))


def _owned_playlist_items(
    api: ApiCall,
    request: ProviderPageRequest,
    cursor: dict[str, Any],
) -> dict[str, Any]:
    _phase(
        cursor,
        {"phase", "playlist_id", "item_token", "playlists_token"},
    )
    playlist_id = stable_id(cursor.get("playlist_id"), "playlist ID")
    item_token = optional_text(cursor.get("item_token"), "playlist item token")
    playlists_token = optional_text(
        cursor.get("playlists_token"), "playlists page token"
    )
    result = api(
        "playlistItems",
        _params(
            part="snippet,contentDetails,status",
            playlistId=playlist_id,
            maxResults=request.limit,
            pageToken=item_token,
        ),
    )
    if result.status != 200:
        return terminal_payload(result)
    records = [
        serialize_playlist_item(item, playlist_id)
        for item in response_items(result.payload)
    ]
    provider_next = next_page_token(result.payload)
    if provider_next is not None:
        next_cursor = {
            "phase": "items",
            "playlist_id": playlist_id,
            "item_token": provider_next,
            "playlists_token": playlists_token,
        }
    elif playlists_token is not None:
        next_cursor = {"phase": "playlists", "page_token": playlists_token}
    else:
        next_cursor = None
    return _success(records, _meta(next_cursor, None, False, snapshot=True))


def _owned_playlists(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    cursor = request.cursor
    if cursor is None:
        return _owned_playlist_page(api, request, None)
    phase = cursor.get("phase")
    if phase == "playlists":
        _phase(cursor, {"phase", "page_token"})
        token = optional_text(cursor.get("page_token"), "playlists page token")
        if not token:
            raise YouTubeReadProviderError("YouTube playlists cursor is empty")
        return _owned_playlist_page(api, request, token)
    if phase == "items":
        return _owned_playlist_items(api, request, cursor)
    raise YouTubeReadProviderError("YouTube playlists cursor phase is invalid")


def _comment_thread_page(
    api: ApiCall,
    request: ProviderPageRequest,
    page_token: str | None,
) -> dict[str, Any]:
    result = api(
        "commentThreads",
        _params(
            part="snippet",
            allThreadsRelatedToChannelId=request.account_id,
            maxResults=1,
            pageToken=page_token,
        ),
    )
    if result.status != 200:
        return terminal_payload(result)
    items = response_items(result.payload)
    if not items:
        return _success([], _meta(None, None, False, snapshot=False))
    comment, reply_count = serialize_comment_thread(items[0])
    newest = comment["remote_id"]
    if request.stop_at is not None and newest == request.stop_at:
        return _success([], _meta(None, newest, True, snapshot=False))
    threads_token = next_page_token(result.payload)
    if reply_count > 0:
        next_cursor = {
            "phase": "replies",
            "parent_id": newest,
            "reply_token": None,
            "threads_token": threads_token,
        }
    elif threads_token is not None:
        next_cursor = {"phase": "threads", "page_token": threads_token}
    else:
        next_cursor = None
    return _success([comment], _meta(next_cursor, newest, False, snapshot=False))


def _comment_replies(
    api: ApiCall,
    request: ProviderPageRequest,
    cursor: dict[str, Any],
) -> dict[str, Any]:
    _phase(cursor, {"phase", "parent_id", "reply_token", "threads_token"})
    parent_id = stable_id(cursor.get("parent_id"), "parent comment ID")
    reply_token = optional_text(cursor.get("reply_token"), "reply page token")
    threads_token = optional_text(cursor.get("threads_token"), "threads page token")
    result = api(
        "comments",
        _params(
            part="snippet",
            parentId=parent_id,
            maxResults=request.limit,
            pageToken=reply_token,
        ),
    )
    if result.status != 200:
        return terminal_payload(result)
    records = [
        serialize_comment(item, parent_id) for item in response_items(result.payload)
    ]
    provider_next = next_page_token(result.payload)
    if provider_next is not None:
        next_cursor = {
            "phase": "replies",
            "parent_id": parent_id,
            "reply_token": provider_next,
            "threads_token": threads_token,
        }
    elif threads_token is not None:
        next_cursor = {"phase": "threads", "page_token": threads_token}
    else:
        next_cursor = None
    return _success(records, _meta(next_cursor, None, False, snapshot=False))


def _comments(api: ApiCall, request: ProviderPageRequest) -> dict[str, Any]:
    cursor = request.cursor
    if cursor is None:
        return _comment_thread_page(api, request, None)
    phase = cursor.get("phase")
    if phase == "threads":
        _phase(cursor, {"phase", "page_token"})
        token = optional_text(cursor.get("page_token"), "threads page token")
        if not token:
            raise YouTubeReadProviderError("YouTube comments cursor is empty")
        return _comment_thread_page(api, request, token)
    if phase == "replies":
        return _comment_replies(api, request, cursor)
    raise YouTubeReadProviderError("YouTube comments cursor phase is invalid")


ROUTES: dict[
    str, Callable[[ApiCall, ProviderPageRequest], dict[str, Any]]
] = {
    "authored_videos": _authored_videos,
    "channel_activity": _channel_activity,
    "owned_playlists": _owned_playlists,
    "subscriptions": _subscriptions,
    "comments": _comments,
    "liked_videos": _liked_videos,
}


def page(
    api: ApiCall,
    request: ProviderPageRequest,
) -> dict[str, Any]:
    """Execute exactly one allowlisted YouTube list request."""
    route = ROUTES.get(request.stream)
    if route is None:
        raise YouTubeReadProviderError("YouTube read stream is unsupported")
    return route(api, request)
