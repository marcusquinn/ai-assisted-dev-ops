#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free, bounded GET transport for Miniflux."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_miniflux_contract import (
    ApiResult,
    MinifluxReadProviderError,
    decode_json,
)
from _knowledge_social_miniflux_identity import canonical_base_url
from _knowledge_social_miniflux_routes import allowlisted_path, query_keys_for_path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
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


@dataclass(frozen=True)
class ProfileConfig:
    base_url: str
    api_token: str
    origin_key: str
    installation_id: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise MinifluxReadProviderError("Python urllib HTTP exports are unavailable")
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


def _target_url(config: ProfileConfig, path: str, params: dict[str, str]) -> str:
    if not allowlisted_path(path) or set(params) - query_keys_for_path(path):
        raise MinifluxReadProviderError("Miniflux API route is not allowlisted")
    if any(not isinstance(value, str) or not value or "\x00" in value for value in params.values()):
        raise MinifluxReadProviderError("Miniflux API query is invalid")
    for key in ("limit", "after_entry_id", "changed_after"):
        value = params.get(key)
        if value is not None and not value.isdigit():
            raise MinifluxReadProviderError("Miniflux paging query is invalid")
    query = urlencode(params)
    return f"{canonical_base_url(config.base_url)}{path}" + (f"?{query}" if query else "")


def api(
    config: ProfileConfig, opener: Opener, path: str, params: dict[str, str]
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only request."""
    request = Request(
        _target_url(config, path, params),
        headers={
            "Accept": "application/xml" if path == "/v1/export" else "application/json",
            "X-Auth-Token": config.api_token,
            "User-Agent": "aidevops-miniflux-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise MinifluxReadProviderError("Miniflux HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes) or len(payload) > MAX_RESPONSE_BYTES:
                raise MinifluxReadProviderError("Miniflux read response exceeds the safety limit")
            if path == "/v1/export":
                try:
                    decoded: Any = payload.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise MinifluxReadProviderError("Miniflux OPML response is invalid") from error
            else:
                decoded = decode_json(payload, MAX_RESPONSE_BYTES)
            return ApiResult(status, decoded)
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise MinifluxReadProviderError("Miniflux read provider request failed") from error
