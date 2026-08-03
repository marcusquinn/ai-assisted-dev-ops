#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, bounded GET transport for the beehiiv API v2."""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_beehiiv import BeehiivProviderError, publication_id

API_ORIGIN = "https://api.beehiiv.com/v2"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
POST_PATH = re.compile(r"^/publications/(pub_[A-Za-z0-9_-]{1,123})/posts$")


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
    publication_id: str
    publication_name: str
    organization_name: str
    creator_owned_publication_id: str


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def http_opener() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise BeehiivProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def allowlisted_path(path: str) -> bool:
    return path == "/publications" or POST_PATH.fullmatch(path) is not None


def query_keys_for_path(path: str) -> frozenset[str]:
    if path == "/publications":
        return frozenset({"limit", "page"})
    if POST_PATH.fullmatch(path):
        return frozenset({"expand", "limit", "page", "status", "order_by", "direction"})
    return frozenset()


def _validate_query(path: str, params: dict[str, str]) -> None:
    if not allowlisted_path(path) or set(params) - query_keys_for_path(path):
        raise BeehiivProviderError("beehiiv API route is not allowlisted")
    if any(
        not isinstance(value, str) or "\x00" in value or len(value.encode()) > 4096
        for value in params.values()
    ):
        raise BeehiivProviderError("beehiiv API query is invalid")
    if "limit" in params and (
        not params["limit"].isdigit() or not 1 <= int(params["limit"]) <= 100
    ):
        raise BeehiivProviderError("beehiiv page size is invalid")
    if "page" in params and (
        not params["page"].isdigit() or not 1 <= int(params["page"]) <= 100
    ):
        raise BeehiivProviderError("beehiiv page number is invalid")
    expected = {
        "expand": "free_web_content",
        "status": "confirmed",
        "order_by": "created",
        "direction": "asc",
    }
    if any(key in params and params[key] != value for key, value in expected.items()):
        raise BeehiivProviderError("beehiiv post query exceeds the read policy")


def target_url(path: str, params: dict[str, str]) -> str:
    _validate_query(path, params)
    match = POST_PATH.fullmatch(path)
    if match:
        publication_id(match.group(1))
    query = urlencode(params)
    return f"{API_ORIGIN}{path}" + (f"?{query}" if query else "")


def _decode_json(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise BeehiivProviderError("beehiiv JSON exceeds the safety limit")
    try:
        import json

        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BeehiivProviderError("beehiiv JSON is invalid") from error


def _absolute_reset(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        reset = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(reset) or reset < 0:
        return None
    return math.ceil(reset)


def _retry_seconds(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _retry_epoch(headers: Headers | None) -> int | None:
    if headers is None:
        return None
    return _absolute_reset(headers.get("RateLimit-Reset")) or _retry_seconds(
        headers.get("Retry-After")
    )


def api(
    config: ProfileConfig, opener: Opener, path: str, params: dict[str, str]
) -> ApiResult:
    request = Request(
        target_url(path, params),
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config.access_token}",
            "User-Agent": "aidevops-beehiiv-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise BeehiivProviderError("beehiiv HTTP status is invalid")
            if status != 200:
                return ApiResult(status, {}, _retry_epoch(response.headers))
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise BeehiivProviderError("beehiiv HTTP response is invalid")
            return ApiResult(status, _decode_json(payload))
    except HTTPError as error:
        return ApiResult(error.code, {}, _retry_epoch(error.headers))
    except (TimeoutError, URLError, OSError) as error:
        raise BeehiivProviderError("beehiiv request failed") from error
