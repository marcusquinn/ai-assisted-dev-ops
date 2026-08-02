#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Miniflux GET routes and bounded response serializers."""

from __future__ import annotations

import hashlib
import time
from datetime import datetime
from typing import Any, Callable
from xml.etree import ElementTree

from _knowledge_social_miniflux import ENTRY_STREAMS, PageRequest
from _knowledge_social_miniflux_contract import (
    ApiResult,
    MinifluxReadProviderError,
    object_list,
    object_value,
    observed_at,
    optional_text,
)
from _knowledge_social_miniflux_identity import resource_id, user_id

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]
EXACT_READ_PATHS = frozenset({"/v1/me", "/v1/entries", "/v1/feeds", "/v1/categories", "/v1/export"})
STREAM_PATHS = {
    "entries": "/v1/entries", "read": "/v1/entries",
    "removed": "/v1/entries", "starred": "/v1/entries",
    "tags": "/v1/entries", "feeds": "/v1/feeds",
    "categories": "/v1/categories", "opml": "/v1/export",
}


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path == "/v1/entries":
        return frozenset({"status", "starred", "order", "direction", "limit", "after_entry_id", "changed_after"})
    if path == "/v1/categories":
        return frozenset({"counts"})
    return frozenset()


def _integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise MinifluxReadProviderError(f"Miniflux {field} is invalid")
    return value


def _entry(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    entry_id = _integer(item.get("id"), "entry ID")
    if user_id(item.get("user_id")) != request.user_id:
        raise MinifluxReadProviderError("Miniflux entry belongs to another account")
    tags = item.get("tags", [])
    if tags is None:
        tags = []
    if not isinstance(tags, list) or any(not isinstance(tag, str) or not tag for tag in tags):
        raise MinifluxReadProviderError("Miniflux entry tags are invalid")
    return {
        "kind": "entry",
        "remote_id": resource_id(request.installation_id, "entry", entry_id),
        "entry_id": entry_id,
        "title": optional_text(item.get("title"), "entry title"),
        "body": optional_text(item.get("content"), "entry content"),
        "url": optional_text(item.get("url"), "entry URL"),
        "author": optional_text(item.get("author"), "entry author"),
        "published_at": optional_text(item.get("published_at"), "published timestamp"),
        "created_at": optional_text(item.get("created_at"), "created timestamp"),
        "changed_at": optional_text(item.get("changed_at"), "changed timestamp"),
        "status": optional_text(item.get("status"), "entry status"),
        "starred": item.get("starred") if isinstance(item.get("starred"), bool) else None,
        "tags": tags,
    }


def _entry_records(items: list[dict[str, Any]], request: PageRequest) -> list[dict[str, Any]]:
    entries = [_entry(item, request) for item in items]
    if request.stream != "tags":
        return entries
    records: dict[str, dict[str, Any]] = {}
    for entry in entries:
        for tag in entry["tags"]:
            remote = resource_id(request.installation_id, "tag", tag.casefold())
            records[remote] = {
                "kind": "tag", "remote_id": remote, "title": tag,
                "changed_at": entry.get("changed_at"), "entry_remote_id": entry["remote_id"],
            }
    return list(records.values())


def _snapshot_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    items = object_list(payload, f"{request.stream} response", limit=request.limit)
    records = []
    for item in items:
        remote_numeric = _integer(item.get("id"), f"{request.stream} ID")
        if user_id(item.get("user_id")) != request.user_id:
            raise MinifluxReadProviderError(f"Miniflux {request.stream} item belongs to another account")
        kind = "feed" if request.stream == "feeds" else "category"
        records.append({
            "kind": kind,
            "remote_id": resource_id(request.installation_id, kind, remote_numeric),
            "title": optional_text(item.get("title"), f"{kind} title"),
            "url": optional_text(item.get("feed_url"), "feed URL") if kind == "feed" else None,
        })
    return records


def _opml_records(payload: Any, request: PageRequest) -> list[dict[str, Any]]:
    if not isinstance(payload, str) or len(payload.encode()) > 8 * 1024 * 1024:
        raise MinifluxReadProviderError("Miniflux OPML response is invalid")
    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError as error:
        raise MinifluxReadProviderError("Miniflux OPML response is invalid") from error
    outlines = [node for node in root.iter("outline") if node.attrib.get("xmlUrl")]
    if len(outlines) > request.limit:
        raise MinifluxReadProviderError("Miniflux OPML response exceeds the item safety limit")
    return [
        {
            "kind": "feed",
            "remote_id": resource_id(
                request.installation_id, "opml_feed",
                hashlib.sha256(node.attrib["xmlUrl"].encode()).hexdigest(),
            ),
            "title": optional_text(node.attrib.get("title", node.attrib.get("text")), "OPML title"),
            "url": optional_text(node.attrib.get("xmlUrl"), "OPML feed URL"),
            "category": optional_text(node.attrib.get("category"), "OPML category"),
        }
        for node in outlines
    ]


def _changed_epoch(items: list[dict[str, Any]]) -> int | None:
    values = []
    for item in items:
        value = item.get("changed_at")
        if value is not None:
            try:
                values.append(int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()))
            except (AttributeError, ValueError) as error:
                raise MinifluxReadProviderError("Miniflux changed timestamp is invalid") from error
    return max(values) if values else None


def page(api: Api, request: PageRequest) -> PageResult:
    path = STREAM_PATHS[request.stream]
    params: dict[str, str] = {}
    if request.stream in ENTRY_STREAMS:
        params = {
            "order": "id", "direction": "asc", "limit": str(request.limit),
            "after_entry_id": str(request.after_entry_id),
        }
        if request.changed_after is not None:
            params["changed_after"] = str(request.changed_after)
        if request.stream in {"read", "removed"}:
            params["status"] = request.stream
        elif request.stream == "starred":
            params["starred"] = "true"
    elif request.stream == "categories":
        params = {"counts": "true"}
    result = api(path, params)
    if result.status != 200:
        return result
    if request.stream in ENTRY_STREAMS:
        root = object_value(result.payload, "entries response")
        items = object_list(root.get("entries"), "entries", limit=request.limit)
        entries = [_entry(item, request) for item in items]
        entry_ids = [item["entry_id"] for item in entries]
        if entry_ids != sorted(entry_ids) or any(
            entry_id <= request.after_entry_id for entry_id in entry_ids
        ):
            raise MinifluxReadProviderError("Miniflux entry IDs are not ascending")
        records = _entry_records(items, request)
        next_id = max((item["entry_id"] for item in entries), default=request.after_entry_id)
        has_more = len(items) == request.limit and next_id > request.after_entry_id
        watermark = _changed_epoch(entries) or int(time.time())
    elif request.stream == "opml":
        records = _opml_records(result.payload, request)
        next_id, has_more, watermark = 0, False, None
    else:
        records = _snapshot_records(result.payload, request)
        next_id, has_more, watermark = 0, False, None
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "has_more": has_more,
            "next_after_entry_id": next_id,
            "watermark": watermark,
            "snapshot": request.stream not in ENTRY_STREAMS,
        },
    }
