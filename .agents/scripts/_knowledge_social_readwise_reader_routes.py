#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact Reader GET routes and stream serializers."""

from __future__ import annotations

from datetime import datetime
from typing import Any, Callable

from _knowledge_social_readwise_reader import PageRequest
from _knowledge_social_readwise_reader_contract import (
    ApiResult,
    ReadwiseReaderProviderError,
    object_list,
    object_value,
    observed_at,
    optional_text,
)
from _knowledge_social_readwise_reader_identity import resource_id

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]
EXACT_READ_PATHS = frozenset({"/api/v2/auth/", "/api/v3/list/", "/api/v3/tags/"})


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path == "/api/v3/list/":
        return frozenset({"pageCursor", "updatedAfter", "category", "limit", "withHtmlContent"})
    if path == "/api/v3/tags/":
        return frozenset({"pageCursor"})
    return frozenset()


def _required_text(value: Any, field: str) -> str:
    result = optional_text(value, field)
    if not result:
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} is required")
    return result


def _number(value: Any, field: str) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} is invalid")
    return value


def _tags(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, dict):
        values = list(value)
    elif isinstance(value, list):
        values = value
    else:
        raise ReadwiseReaderProviderError("Readwise Reader document tags are invalid")
    if any(not isinstance(item, str) or not item or "\x00" in item for item in values):
        raise ReadwiseReaderProviderError("Readwise Reader document tags are invalid")
    return values


def _document(item: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    remote = resource_id("document", _required_text(item.get("id"), "document ID"))
    base = {
        "kind": "document", "remote_id": remote,
        "title": optional_text(item.get("title"), "document title"),
        "body": optional_text(item.get("summary"), "document summary"),
        "notes": optional_text(item.get("notes"), "document notes"),
        "html": optional_text(item.get("html_content"), "document HTML") if request.stream == "html" else None,
        "author": optional_text(item.get("author"), "document author"),
        "url": optional_text(item.get("url"), "document URL"),
        "created_at": optional_text(item.get("created_at"), "created timestamp"),
        "updated_at": optional_text(item.get("updated_at"), "updated timestamp"),
        "saved_at": optional_text(item.get("saved_at"), "saved timestamp"),
        "location": optional_text(item.get("location"), "document location"),
        "category": optional_text(item.get("category"), "document category"),
        "reading_progress": _number(item.get("reading_progress"), "reading progress"),
        "tags": _tags(item.get("tags")),
        "parent_remote_id": resource_id("document", item["parent_id"]) if item.get("parent_id") else None,
    }
    if request.stream == "notes":
        base["kind"] = "note"
    elif request.stream == "state":
        base["kind"] = "document_state"
    elif request.stream == "progress":
        base["kind"] = "reading_progress"
    elif request.stream == "locations":
        base["kind"] = "location"
    return base


def _tag(item: dict[str, Any]) -> dict[str, Any]:
    key = _required_text(item.get("key"), "tag key")
    return {
        "kind": "tag", "remote_id": resource_id("tag", key),
        "title": optional_text(item.get("name"), "tag name") or key,
    }


def _watermark(items: list[dict[str, Any]]) -> str | None:
    values = []
    for item in items:
        value = optional_text(item.get("updated_at"), "updated timestamp")
        if value:
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError as error:
                raise ReadwiseReaderProviderError("Readwise Reader updated timestamp is invalid") from error
            values.append((parsed, value))
    return max(values)[1] if values else None


def page(api: Api, request: PageRequest) -> PageResult:
    path = "/api/v3/tags/" if request.stream == "tags" else "/api/v3/list/"
    params: dict[str, str] = {}
    if request.page_cursor:
        params["pageCursor"] = request.page_cursor
    if request.stream != "tags":
        params["limit"] = str(request.limit)
        if request.updated_after:
            params["updatedAfter"] = request.updated_after
        if request.stream == "notes":
            params["category"] = "note"
        if request.stream == "html":
            params["withHtmlContent"] = "true"
    result = api(path, params)
    if result.status != 200:
        return result
    root = object_value(result.payload, "list response")
    items = object_list(root.get("results"), "results", request.limit)
    records = [_tag(item) for item in items] if request.stream == "tags" else [
        _document(item, request) for item in items
    ]
    cursor = optional_text(root.get("nextPageCursor"), "next page cursor")
    return {
        "status": 200, "observed_at": observed_at(), "data": records,
        "meta": {
            "stream": request.stream, "next_page_cursor": cursor,
            "watermark": _watermark(items) if request.stream != "tags" else None,
        },
    }
