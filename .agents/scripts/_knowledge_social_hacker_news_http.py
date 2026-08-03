#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, bounded GET transport for the Hacker News Firebase API."""

from __future__ import annotations

import time
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_hacker_news_contract import (
    ApiResult,
    HackerNewsReadProviderError,
    MAX_ITEM_RESPONSE_BYTES,
    MAX_USER_RESPONSE_BYTES,
    decode_json,
)
from _knowledge_social_hacker_news_identity import item_id, username

API_ORIGIN = "https://hacker-news.firebaseio.com"
API_PREFIX = "/v0"
HTTP_TIMEOUT_SECONDS = 60


class Headers(Protocol):
    def get(self, key: str, default: str | None = None) -> str | None: ...


class Response(Protocol):
    status: int
    headers: Headers

    def __enter__(self) -> Response: ...
    def __exit__(self, *args: Any) -> None: ...
    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, quote, HTTPRedirectHandler)
    if not all(callable(current) for current in exports):
        raise HackerNewsReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def allowlisted_route(kind: str) -> bool:
    return kind in {"user", "item"}


def _target_url(kind: str, selector: str | int) -> tuple[str, int]:
    if kind == "user":
        selected = username(selector)
        path_selector = quote(selected, safe="")
        limit = MAX_USER_RESPONSE_BYTES
    elif kind == "item":
        path_selector = str(item_id(selector))
        limit = MAX_ITEM_RESPONSE_BYTES
    else:
        raise HackerNewsReadProviderError("Hacker News API route is not allowlisted")
    return f"{API_ORIGIN}{API_PREFIX}/{kind}/{path_selector}.json", limit


def _retry_after(headers: Headers) -> int | None:
    value = headers.get("Retry-After")
    if value is None:
        return None
    if not value.isdigit() or not 1 <= int(value) <= 86400:
        return None
    return int(time.time()) + int(value)


def api(opener: Opener, kind: str, selector: str | int) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only Firebase request."""
    target, limit = _target_url(kind, selector)
    request = Request(
        target,
        headers={
            "Accept": "application/json",
            "User-Agent": "aidevops-hacker-news-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise HackerNewsReadProviderError("Hacker News HTTP status is invalid")
            payload = response.read(limit + 1)
            if not isinstance(payload, bytes):
                raise HackerNewsReadProviderError("Hacker News HTTP response is invalid")
            return ApiResult(
                status,
                decode_json(payload, limit),
                len(payload),
                _retry_after(response.headers),
            )
    except HTTPError as error:
        return ApiResult(error.code, None, retry_after=_retry_after(error.headers))
    except (TimeoutError, URLError, OSError) as error:
        raise HackerNewsReadProviderError(
            "Hacker News public read provider request failed"
        ) from error
