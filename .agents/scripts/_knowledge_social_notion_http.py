#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixed-origin, redirect-free transport for allowlisted Notion reads."""

from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_notion import API_VERSION, PageRequest
from _knowledge_social_notion_contract import (
    ApiResult,
    MAX_RESPONSE_BYTES,
    NotionReadProviderError,
    decode_json,
)

API_ORIGIN = "https://api.notion.com"
HTTP_TIMEOUT_SECONDS = 60


class Response(Protocol):
    status: int

    def __enter__(self) -> Response: ...
    def __exit__(self, *args: Any) -> None: ...
    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


@dataclass(frozen=True)
class ProfileConfig:
    access_token: str
    workspace_id: str
    root_page_ids: tuple[str, ...]
    include_comments: bool
    max_depth: int
    max_pages: int
    max_blocks: int
    max_bytes: int


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def http_opener() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise NotionReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _retry_epoch(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _headers(config: ProfileConfig) -> dict[str, str]:
    return {
        "Accept": "application/json",
        "Authorization": f"Bearer {config.access_token}",
        "Notion-Version": API_VERSION,
        "User-Agent": "aidevops-notion-sites-knowledge/1",
    }


def _request(
    config: ProfileConfig,
    method: str,
    path: str,
    params: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> Request:
    query = f"?{urlencode(params)}" if params else ""
    data = None
    headers = _headers(config)
    if body is not None:
        data = json.dumps(body, sort_keys=True, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    return Request(f"{API_ORIGIN}{path}{query}", data=data, headers=headers, method=method)


def _read(response: Response) -> ApiResult:
    status = getattr(response, "status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise NotionReadProviderError("Notion HTTP status is invalid")
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if not isinstance(payload, bytes):
        raise NotionReadProviderError("Notion HTTP response is invalid")
    decoded = decode_json(payload)
    if not isinstance(decoded, (dict, list)):
        raise NotionReadProviderError("Notion API response root must be an object or array")
    return ApiResult(status, decoded, len(payload))


def _error(error: HTTPError) -> ApiResult:
    retry = error.headers.get("Retry-After") if error.headers is not None else None
    return ApiResult(error.code, {}, 0, _retry_epoch(retry))


def execute(config: ProfileConfig, opener: Opener, request: Request) -> ApiResult:
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return _read(response)
    except HTTPError as error:
        return _error(error)
    except (TimeoutError, URLError, OSError) as error:
        raise NotionReadProviderError("Notion read provider request failed") from error


def identity_api(config: ProfileConfig, opener: Opener) -> ApiResult:
    return execute(config, opener, _request(config, "GET", "/v1/users/me"))


def task_api(config: ProfileConfig, opener: Opener, request: PageRequest) -> ApiResult:
    """Execute only reviewed content-read routes; the sole POST is a query."""
    task = request.task
    cursor_params = {"page_size": str(request.page_size)}
    if task.cursor is not None:
        cursor_params["start_cursor"] = task.cursor
    if task.kind == "page":
        api_request = _request(config, "GET", f"/v1/pages/{task.resource_id}")
    elif task.kind == "blocks":
        api_request = _request(
            config,
            "GET",
            f"/v1/blocks/{task.resource_id}/children",
            cursor_params,
        )
    elif task.kind == "database":
        api_request = _request(config, "GET", f"/v1/databases/{task.resource_id}")
    elif task.kind == "comments":
        api_request = _request(
            config,
            "GET",
            "/v1/comments",
            {"block_id": task.resource_id, **cursor_params},
        )
    elif task.kind == "data_source":
        body: dict[str, Any] = {"page_size": request.page_size}
        if task.cursor is not None:
            body["start_cursor"] = task.cursor
        api_request = _request(
            config,
            "POST",
            f"/v1/data_sources/{task.resource_id}/query",
            body=body,
        )
    else:
        raise NotionReadProviderError("Notion API route is not allowlisted")
    return execute(config, opener, api_request)
