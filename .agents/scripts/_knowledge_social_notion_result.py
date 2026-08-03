#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Build bounded provider responses from validated Notion API results."""

from __future__ import annotations

from typing import Any

from _knowledge_social_notion import PageRequest, Task
from _knowledge_social_notion_contract import (
    ApiResult,
    NotionReadProviderError,
    list_value,
    object_value,
    observed_at,
    optional_text,
)
from _knowledge_social_notion_records import (
    block_record,
    comment_record,
    database_record,
    page_discoveries,
    record_page,
    row_record,
)


def _list_response(
    result: ApiResult, request: PageRequest
) -> tuple[list[dict[str, Any]], str | None, str]:
    payload = object_value(result.payload, "list response")
    if payload.get("object") != "list":
        raise NotionReadProviderError("Notion paginated response is not a list")
    records = list_value(payload.get("results"), "paginated results", request.page_size)
    has_more = payload.get("has_more")
    if not isinstance(has_more, bool):
        raise NotionReadProviderError("Notion pagination flag is invalid")
    next_cursor = payload.get("next_cursor")
    if has_more:
        next_cursor = optional_text(next_cursor, "next cursor", maximum=4096)
        if not next_cursor:
            raise NotionReadProviderError("Notion pagination cursor is missing")
    elif next_cursor is not None:
        raise NotionReadProviderError("Notion terminal page unexpectedly returned a cursor")
    status = object_value(payload.get("request_status", {"type": "complete"}), "request status")
    status_type = status.get("type")
    if status_type not in {"complete", "incomplete"}:
        raise NotionReadProviderError("Notion request status is invalid")
    return records, next_cursor, status_type


def _block_result(result: ApiResult, request: PageRequest) -> tuple[Any, ...]:
    raw_records, next_cursor, request_status = _list_response(result, request)
    records = []
    discoveries: list[Task] = []
    limit_reason = None
    for raw in raw_records:
        record, found, current_limit = block_record(raw, request)
        records.append(record)
        discoveries.extend(found)
        limit_reason = limit_reason or current_limit
    return records, discoveries, next_cursor, request_status, limit_reason, 0, len(records)


def _row_result(result: ApiResult, request: PageRequest) -> tuple[Any, ...]:
    raw_records, next_cursor, request_status = _list_response(result, request)
    records = []
    discoveries: list[Task] = []
    for raw in raw_records:
        record, found = row_record(raw, request)
        records.append(record)
        discoveries.extend(found)
    return records, discoveries, next_cursor, request_status, None, len(records), 0


def _comment_result(result: ApiResult, request: PageRequest) -> tuple[Any, ...]:
    raw_records, next_cursor, request_status = _list_response(result, request)
    records = [comment_record(raw, request) for raw in raw_records]
    return records, [], next_cursor, request_status, None, 0, 0


def _result_parts(result: ApiResult, request: PageRequest) -> tuple[Any, ...]:
    task = request.task
    if task.kind == "page":
        raw = object_value(result.payload, "page response")
        return [record_page(raw, request)], page_discoveries(request), None, "complete", None, 1, 0
    if task.kind == "blocks":
        return _block_result(result, request)
    if task.kind == "database":
        raw = object_value(result.payload, "database response")
        record, discoveries = database_record(raw, request)
        return [record], discoveries, None, "complete", None, 0, 0
    if task.kind == "data_source":
        return _row_result(result, request)
    return _comment_result(result, request)


def _handle_result(result: ApiResult, request: PageRequest) -> dict[str, Any]:
    records, discoveries, next_cursor, request_status, limit_reason, pages, blocks = (
        _result_parts(result, request)
    )
    if pages > request.limits.max_pages:
        limit_reason = "pages"
    if blocks > request.limits.max_blocks:
        limit_reason = "blocks"
    return {
        "data": records,
        "meta": {
            "block_count": blocks,
            "discoveries": [task.payload() for task in discoveries],
            "limit_reason": limit_reason,
            "next_cursor": next_cursor,
            "page_count": pages,
            "request_sha256": request.digest(),
            "request_status": request_status,
            "response_bytes": result.response_bytes,
            "task": request.task.payload(),
        },
        "observed_at": observed_at(),
        "status": 200,
    }
