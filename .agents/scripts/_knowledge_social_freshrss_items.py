#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded FreshRSS Google Reader item response handling."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from _knowledge_social_freshrss import PageRequest
from _knowledge_social_freshrss_contract import (
    FreshRSSReadProviderError,
    object_list,
    object_value,
    optional_text,
    required_text,
    safe_url,
)
from _knowledge_social_freshrss_identity import resource_id

READ_STATE = "user/-/state/com.google/read"
STARRED_STATE = "user/-/state/com.google/starred"
LABEL_PREFIX = "user/-/label/"


def nonnegative_int(value: Any, field: str) -> int:
    if isinstance(value, bool):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    try:
        number = int(value)
    except (TypeError, ValueError) as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error
    if number < 0 or str(number) != str(value):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    return number


def _timestamp(value: Any, field: str, *, microseconds: bool = False) -> str | None:
    if value is None:
        return None
    epoch = nonnegative_int(value, field)
    seconds = epoch / 1_000_000 if microseconds else epoch
    try:
        return datetime.fromtimestamp(seconds, UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error


def _string_list(value: Any, field: str, *, limit: int = 1000) -> list[str]:
    if not isinstance(value, list) or len(value) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    return [required_text(item, field, limit=4096) for item in value]


def _first_link(value: Any, field: str) -> str | None:
    if value is None:
        return None
    for link in object_list(value, field, limit=16):
        href = link.get("href")
        if href is not None:
            return safe_url(href, f"{field} URL")
    return None


def _summary(item: dict[str, Any]) -> str | None:
    value = item.get("summary")
    if value is None:
        return None
    summary = object_value(value, "entry summary")
    return optional_text(summary.get("content"), "entry summary content")


def _entry_state(categories: list[str], stream: str) -> tuple[bool, bool]:
    is_read = READ_STATE in categories
    is_starred = STARRED_STATE in categories
    if stream == "unread" and is_read:
        raise FreshRSSReadProviderError("FreshRSS unread stream contains a read item")
    if stream == "starred" and not is_starred:
        raise FreshRSSReadProviderError("FreshRSS starred stream contains an unstarred item")
    return is_read, is_starred


def _labels(categories: list[str]) -> list[str]:
    return [
        value.removeprefix(LABEL_PREFIX)
        for value in categories
        if value.startswith(LABEL_PREFIX)
    ]


def _entry(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    native = required_text(item.get("id"), "entry ID", limit=16 * 1024)
    categories = _string_list(item.get("categories", []), "entry categories")
    is_read, is_starred = _entry_state(categories, request.stream)
    origin = object_value(item.get("origin", {}), "entry origin")
    canonical = _first_link(item.get("canonical"), "entry canonical links")
    alternate = _first_link(item.get("alternate"), "entry alternate links")
    return {
        "kind": "entry",
        "remote_id": resource_id(request.installation_id, "entry", native),
        "native_id": native,
        "title": optional_text(item.get("title"), "entry title"),
        "body": _summary(item),
        "author": optional_text(item.get("author"), "entry author", limit=64 * 1024),
        "url": canonical or alternate,
        "published_at": _timestamp(item.get("published"), "entry published timestamp"),
        "created_at": _timestamp(
            item.get("timestampUsec"), "entry timestamp", microseconds=True
        ),
        "crawl_time_msec": (
            nonnegative_int(item.get("crawlTimeMsec"), "entry crawl timestamp")
            if item.get("crawlTimeMsec") is not None
            else None
        ),
        "read": is_read,
        "starred": is_starred,
        "labels": _labels(categories),
        "origin_id": optional_text(origin.get("streamId"), "entry origin ID", limit=4096),
        "origin_title": optional_text(origin.get("title"), "entry origin title"),
        "origin_url": safe_url(origin.get("htmlUrl"), "entry origin URL"),
    }


def item_params(request: PageRequest) -> dict[str, str]:
    params = {"output": "json", "n": str(request.limit), "r": "o"}
    if request.continuation is not None:
        params["c"] = request.continuation
    if request.newer_than is not None:
        params["ot"] = str(request.newer_than)
    if request.stream == "unread":
        params["xt"] = READ_STATE
    return params


def item_page(
    payload: Any, request: PageRequest
) -> tuple[list[dict[str, Any]], str | None, int]:
    root = object_value(payload, "item response")
    values = object_list(root.get("items"), "items", limit=request.limit)
    records = [_entry(item, request) for item in values]
    raw_continuation = root.get("continuation")
    continuation = optional_text(raw_continuation, "continuation", limit=16 * 1024)
    if continuation is not None and not continuation:
        raise FreshRSSReadProviderError("FreshRSS continuation is invalid")
    if continuation is not None and not values:
        raise FreshRSSReadProviderError("FreshRSS empty item page retained a continuation")
    watermark = nonnegative_int(root.get("updated"), "item response watermark")
    return records, continuation, watermark
