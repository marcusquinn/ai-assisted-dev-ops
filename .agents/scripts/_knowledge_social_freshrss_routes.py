#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact FreshRSS GReader GET routes and bounded response serializers."""

from __future__ import annotations

from typing import Any, Callable

from _knowledge_social_freshrss import ITEM_STREAMS, PageRequest
from _knowledge_social_freshrss_contract import (
    ApiResult,
    FreshRSSReadProviderError,
    object_list,
    object_value,
    observed_at,
    optional_text,
    required_text,
    safe_url,
)
from _knowledge_social_freshrss_identity import resource_id
from _knowledge_social_freshrss_items import (
    LABEL_PREFIX,
    READ_STATE,
    item_page,
    item_params,
    nonnegative_int,
)
from _knowledge_social_freshrss_opml import parse_opml

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]
IDENTITY_PATH = "/reader/api/0/user-info"
SUBSCRIPTIONS_PATH = "/reader/api/0/subscription/list"
TAGS_PATH = "/reader/api/0/tag/list"
ITEMS_PATH = "/reader/api/0/stream/contents/reading-list"
STARRED_PATH = "/reader/api/0/stream/contents/user/-/state/com.google/starred"
OPML_PATH = "/reader/api/0/subscription/export"
EXACT_READ_PATHS = frozenset(
    {IDENTITY_PATH, SUBSCRIPTIONS_PATH, TAGS_PATH, ITEMS_PATH, STARRED_PATH, OPML_PATH}
)
STREAM_PATHS = {
    "items": ITEMS_PATH,
    "unread": ITEMS_PATH,
    "starred": STARRED_PATH,
    "subscriptions": SUBSCRIPTIONS_PATH,
    "folders": TAGS_PATH,
    "tags": TAGS_PATH,
    "opml": OPML_PATH,
}


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path in {SUBSCRIPTIONS_PATH, TAGS_PATH}:
        return frozenset({"output"})
    if path == ITEMS_PATH:
        return frozenset({"output", "n", "c", "r", "ot", "xt"})
    if path == STARRED_PATH:
        return frozenset({"output", "n", "c", "r"})
    return frozenset()


def query_matches_path(path: str, params: dict[str, str]) -> bool:
    keys_allowed = not set(params).difference(query_keys_for_path(path))
    if path in {IDENTITY_PATH, OPML_PATH}:
        values_allowed = not params
    elif path in {SUBSCRIPTIONS_PATH, TAGS_PATH}:
        values_allowed = params == {"output": "json"}
    elif path in {ITEMS_PATH, STARRED_PATH}:
        values_allowed = (
            params.get("output") == "json"
            and params.get("r") == "o"
            and "n" in params
            and (
                path == STARRED_PATH
                or "xt" not in params
                or params["xt"] == READ_STATE
            )
        )
    else:
        values_allowed = False
    return keys_allowed and values_allowed


def _subscription(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    native = required_text(item.get("id"), "subscription ID", limit=16 * 1024)
    if not native.startswith("feed/"):
        raise FreshRSSReadProviderError("FreshRSS subscription ID is invalid")
    categories = object_list(item.get("categories", []), "subscription categories", limit=100)
    folders = []
    for category in categories:
        category_id = required_text(category.get("id"), "subscription category ID")
        if not category_id.startswith(LABEL_PREFIX):
            raise FreshRSSReadProviderError("FreshRSS subscription category is invalid")
        folders.append(
            optional_text(category.get("label"), "subscription category label", limit=4096)
            or category_id.removeprefix(LABEL_PREFIX)
        )
    return {
        "kind": "feed",
        "remote_id": resource_id(request.installation_id, "feed", native),
        "native_id": native,
        "title": optional_text(item.get("title"), "subscription title"),
        "url": safe_url(item.get("url"), "subscription feed URL"),
        "html_url": safe_url(item.get("htmlUrl"), "subscription site URL"),
        "folders": folders,
    }


def _tag_record(item: dict[str, Any], request: PageRequest) -> dict[str, Any] | None:
    kind = item.get("type")
    if kind not in {"folder", "tag"}:
        return None
    if kind != request.stream.removesuffix("s"):
        return None
    native = required_text(item.get("id"), f"{kind} ID")
    if not native.startswith(LABEL_PREFIX):
        raise FreshRSSReadProviderError(f"FreshRSS {kind} ID is invalid")
    label = item.get("label")
    title = optional_text(label, f"{kind} label", limit=4096)
    unread = item.get("unread_count")
    return {
        "kind": kind,
        "remote_id": resource_id(request.installation_id, kind, native),
        "native_id": native,
        "title": title or native.removeprefix(LABEL_PREFIX),
        "unread_count": (
            nonnegative_int(unread, f"{kind} unread count") if unread is not None else None
        ),
    }


def _tag_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    root = object_value(payload, "tag response")
    values = object_list(root.get("tags"), "tags", limit=request.limit)
    records = [record for item in values if (record := _tag_record(item, request))]
    if len(records) > request.limit:
        raise FreshRSSReadProviderError("FreshRSS tag response exceeds the item safety limit")
    return records


def _subscription_page(
    payload: Any, request: PageRequest
) -> tuple[list[dict[str, Any]], None, None]:
    root = object_value(payload, "subscription response")
    values = object_list(root.get("subscriptions"), "subscriptions", limit=request.limit)
    return [_subscription(item, request) for item in values], None, None


def _tag_page(
    payload: Any, request: PageRequest
) -> tuple[list[dict[str, Any]], None, None]:
    return _tag_records(payload, request), None, None


def _opml_page(
    payload: Any, request: PageRequest
) -> tuple[list[dict[str, Any]], None, None]:
    return parse_opml(payload, request.installation_id, request.limit), None, None


SnapshotSerializer = Callable[
    [Any, PageRequest], tuple[list[dict[str, Any]], None, None]
]
SNAPSHOT_SERIALIZERS: dict[str, SnapshotSerializer] = {
    "subscriptions": _subscription_page,
    "folders": _tag_page,
    "tags": _tag_page,
    "opml": _opml_page,
}


def _request_params(request: PageRequest) -> dict[str, str]:
    if request.stream in ITEM_STREAMS:
        return item_params(request)
    if request.stream in {"subscriptions", "folders", "tags"}:
        return {"output": "json"}
    return {}


def _page_records(
    payload: Any, request: PageRequest
) -> tuple[list[dict[str, Any]], str | None, int | None]:
    if request.stream in ITEM_STREAMS:
        return item_page(payload, request)
    return SNAPSHOT_SERIALIZERS[request.stream](payload, request)


def page(api: Api, request: PageRequest) -> PageResult:
    path = STREAM_PATHS[request.stream]
    result = api(path, _request_params(request))
    if result.status != 200:
        return result
    records, continuation, watermark = _page_records(result.payload, request)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "has_more": continuation is not None,
            "next_continuation": continuation,
            "watermark": watermark,
            "snapshot": request.stream not in ITEM_STREAMS,
        },
    }
