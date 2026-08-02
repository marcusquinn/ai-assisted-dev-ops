#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact FreshRSS GReader GET routes and bounded response serializers."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any, Callable
from xml.etree import ElementTree

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
READ_STATE = "user/-/state/com.google/read"
STARRED_STATE = "user/-/state/com.google/starred"
LABEL_PREFIX = "user/-/label/"


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path in {SUBSCRIPTIONS_PATH, TAGS_PATH}:
        return frozenset({"output"})
    if path in {ITEMS_PATH, STARRED_PATH}:
        return frozenset({"output", "n", "c", "r", "ot", "xt", "it"})
    return frozenset()


def _opaque(value: Any, field: str, *, limit: int = 16 * 1024) -> str:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    rendered = str(value)
    if not rendered or "\x00" in rendered or len(rendered.encode()) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    return rendered


def _epoch(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    try:
        epoch = int(value)
    except (TypeError, ValueError) as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error
    if epoch < 0 or str(epoch) != str(value):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    return epoch


def _timestamp(value: Any, field: str, *, microseconds: bool = False) -> str | None:
    if value is None:
        return None
    epoch = _epoch(value, field)
    seconds = epoch / 1_000_000 if microseconds else epoch
    try:
        return datetime.fromtimestamp(seconds, UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error


def _string_list(value: Any, field: str, *, limit: int = 1000) -> list[str]:
    if not isinstance(value, list) or len(value) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    result = []
    for item in value:
        result.append(required_text(item, field, limit=4096))
    return result


def _first_link(value: Any, field: str) -> str | None:
    if value is None:
        return None
    links = object_list(value, field, limit=16)
    for link in links:
        href = link.get("href")
        if href is not None:
            return safe_url(href, f"{field} URL")
    return None


def _subscription(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    native = _opaque(item.get("id"), "subscription ID")
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


def _tag_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    root = object_value(payload, "tag response")
    values = object_list(root.get("tags"), "tags", limit=request.limit)
    records = []
    for item in values:
        kind = item.get("type")
        if kind not in {"folder", "tag"}:
            continue
        if kind != request.stream.removesuffix("s"):
            continue
        native = required_text(item.get("id"), f"{kind} ID")
        if not native.startswith(LABEL_PREFIX):
            raise FreshRSSReadProviderError(f"FreshRSS {kind} ID is invalid")
        records.append(
            {
                "kind": kind,
                "remote_id": resource_id(request.installation_id, kind, native),
                "native_id": native,
                "title": optional_text(item.get("label"), f"{kind} label", limit=4096)
                or native.removeprefix(LABEL_PREFIX),
                "unread_count": (
                    _epoch(item.get("unread_count"), f"{kind} unread count")
                    if item.get("unread_count") is not None
                    else None
                ),
            }
        )
    if len(records) > request.limit:
        raise FreshRSSReadProviderError("FreshRSS tag response exceeds the item safety limit")
    return records


def _summary(item: dict[str, Any]) -> str | None:
    value = item.get("summary")
    if value is None:
        return None
    summary = object_value(value, "entry summary")
    return optional_text(summary.get("content"), "entry summary content")


def _entry(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    native = _opaque(item.get("id"), "entry ID")
    categories = _string_list(item.get("categories", []), "entry categories")
    is_read = READ_STATE in categories
    is_starred = STARRED_STATE in categories
    if request.stream == "unread" and is_read:
        raise FreshRSSReadProviderError("FreshRSS unread stream contains a read item")
    if request.stream == "starred" and not is_starred:
        raise FreshRSSReadProviderError("FreshRSS starred stream contains an unstarred item")
    origin = object_value(item.get("origin", {}), "entry origin")
    origin_id = optional_text(origin.get("streamId"), "entry origin ID", limit=4096)
    return {
        "kind": "entry",
        "remote_id": resource_id(request.installation_id, "entry", native),
        "native_id": native,
        "title": optional_text(item.get("title"), "entry title"),
        "body": _summary(item),
        "author": optional_text(item.get("author"), "entry author", limit=64 * 1024),
        "url": _first_link(item.get("canonical"), "entry canonical links")
        or _first_link(item.get("alternate"), "entry alternate links"),
        "published_at": _timestamp(item.get("published"), "entry published timestamp"),
        "created_at": _timestamp(
            item.get("timestampUsec"), "entry timestamp", microseconds=True
        ),
        "crawl_time_msec": (
            _epoch(item.get("crawlTimeMsec"), "entry crawl timestamp")
            if item.get("crawlTimeMsec") is not None
            else None
        ),
        "read": is_read,
        "starred": is_starred,
        "labels": [value.removeprefix(LABEL_PREFIX) for value in categories if value.startswith(LABEL_PREFIX)],
        "origin_id": origin_id,
        "origin_title": optional_text(origin.get("title"), "entry origin title"),
        "origin_url": safe_url(origin.get("htmlUrl"), "entry origin URL"),
    }


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _opml_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    if not isinstance(payload, str) or len(payload.encode()) > 8 * 1024 * 1024:
        raise FreshRSSReadProviderError("FreshRSS OPML response is invalid")
    upper = payload.upper()
    if "<!DOCTYPE" in upper or "<!ENTITY" in upper:
        raise FreshRSSReadProviderError("FreshRSS OPML response is invalid")
    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError as error:
        raise FreshRSSReadProviderError("FreshRSS OPML response is invalid") from error
    records: list[dict[str, Any]] = []

    def visit(node: ElementTree.Element, folders: tuple[str, ...]) -> None:
        for child in node:
            if _local_name(child.tag) != "outline":
                visit(child, folders)
                continue
            feed_url = child.attrib.get("xmlUrl")
            title = optional_text(
                child.attrib.get("title", child.attrib.get("text")), "OPML title", limit=4096
            )
            if feed_url is None:
                visit(child, (*folders, title) if title else folders)
                continue
            safe_feed_url = safe_url(feed_url, "OPML feed URL")
            records.append(
                {
                    "kind": "feed",
                    "remote_id": resource_id(
                        request.installation_id, "opml_feed", safe_feed_url
                    ),
                    "title": title,
                    "url": safe_feed_url,
                    "html_url": safe_url(child.attrib.get("htmlUrl"), "OPML site URL"),
                    "description": optional_text(
                        child.attrib.get("description"), "OPML description"
                    ),
                    "feed_type": optional_text(
                        child.attrib.get("type"), "OPML feed type", limit=4096
                    ),
                    "category": "/".join(folders) or None,
                }
            )
            if len(records) > request.limit:
                raise FreshRSSReadProviderError(
                    "FreshRSS OPML response exceeds the item safety limit"
                )

    visit(root, ())
    return records


def _item_page(payload: Any, request: PageRequest) -> tuple[list[dict[str, Any]], str | None, int]:
    root = object_value(payload, "item response")
    values = object_list(root.get("items"), "items", limit=request.limit)
    records = [_entry(item, request) for item in values]
    raw_continuation = root.get("continuation")
    continuation = (
        _opaque(raw_continuation, "continuation")
        if raw_continuation is not None
        else None
    )
    if continuation is not None and not values:
        raise FreshRSSReadProviderError("FreshRSS empty item page retained a continuation")
    watermark = _epoch(root.get("updated"), "item response watermark")
    return records, continuation, watermark


def page(api: Api, request: PageRequest) -> PageResult:
    path = STREAM_PATHS[request.stream]
    params: dict[str, str] = {}
    if request.stream in ITEM_STREAMS:
        params = {"output": "json", "n": str(request.limit), "r": "o"}
        if request.continuation is not None:
            params["c"] = request.continuation
        if request.newer_than is not None:
            params["ot"] = str(request.newer_than)
        if request.stream == "unread":
            params["xt"] = READ_STATE
    elif request.stream in {"subscriptions", "folders", "tags"}:
        params = {"output": "json"}
    result = api(path, params)
    if result.status != 200:
        return result
    if request.stream in ITEM_STREAMS:
        records, continuation, watermark = _item_page(result.payload, request)
        has_more = continuation is not None
    elif request.stream == "subscriptions":
        root = object_value(result.payload, "subscription response")
        values = object_list(root.get("subscriptions"), "subscriptions", limit=request.limit)
        records = [_subscription(item, request) for item in values]
        continuation, has_more, watermark = None, False, None
    elif request.stream in {"folders", "tags"}:
        records = _tag_records(result.payload, request)
        continuation, has_more, watermark = None, False, None
    else:
        records = _opml_records(result.payload, request)
        continuation, has_more, watermark = None, False, None
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "has_more": has_more,
            "next_continuation": continuation,
            "watermark": watermark,
            "snapshot": request.stream not in ITEM_STREAMS,
        },
    }
