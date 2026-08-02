#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, bounded GET transport for Stack Exchange API v2.3."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_stack_exchange_contract import (
    ApiResult,
    StackExchangeReadProviderError,
    decode_json,
)
from _knowledge_social_stack_exchange_routes import allowlisted_path, query_keys_for_path

API_ORIGIN = "https://api.stackexchange.com"
API_PREFIX = "/2.3"
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
    access_token: str
    api_site_parameter: str
    scopes: frozenset[str]


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise StackExchangeReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _target_url(path: str, params: dict[str, str]) -> str:
    if not allowlisted_path(path) or set(params) - query_keys_for_path(path):
        raise StackExchangeReadProviderError("Stack Exchange API route is not allowlisted")
    if any(not isinstance(value, str) or not value or "\x00" in value for value in params.values()):
        raise StackExchangeReadProviderError("Stack Exchange API query is invalid")
    for key in ("page", "pagesize"):
        value = params.get(key)
        if value is not None and not value.isdigit():
            raise StackExchangeReadProviderError("Stack Exchange paging query is invalid")
    if "page" in params and not 1 <= int(params["page"]) <= 100000:
        raise StackExchangeReadProviderError("Stack Exchange page is invalid")
    if "pagesize" in params and not 1 <= int(params["pagesize"]) <= 100:
        raise StackExchangeReadProviderError("Stack Exchange page size is invalid")
    query = urlencode(params)
    return f"{API_ORIGIN}{API_PREFIX}{path}" + (f"?{query}" if query else "")


def _decode_response(payload: bytes) -> dict[str, Any]:
    decoded = decode_json(payload, MAX_RESPONSE_BYTES)
    if not isinstance(decoded, dict):
        raise StackExchangeReadProviderError(
            "Stack Exchange API response root must be an object"
        )
    return decoded


def api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only API request."""
    request = Request(
        _target_url(path, params),
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config.access_token}",
            "User-Agent": "aidevops-stack-exchange-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise StackExchangeReadProviderError("Stack Exchange HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise StackExchangeReadProviderError("Stack Exchange HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        return ApiResult(error.code, {})
    except (TimeoutError, URLError, OSError) as error:
        raise StackExchangeReadProviderError(
            "Stack Exchange read provider request failed"
        ) from error
