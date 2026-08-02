#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, bounded GET transport for Readwise Reader."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_readwise_reader_contract import (
    ApiResult,
    ReadwiseReaderProviderError,
    decode_json,
)
from _knowledge_social_readwise_reader_routes import allowlisted_path, query_keys_for_path

API_ORIGIN = "https://readwise.io"
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
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
    binding_account_id: str
    binding_key: str
    expected_token_binding: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise ReadwiseReaderProviderError("Python urllib HTTP exports are unavailable")
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


def _target_url(path: str, params: dict[str, str]) -> str:
    if not allowlisted_path(path) or set(params) - query_keys_for_path(path):
        raise ReadwiseReaderProviderError("Readwise Reader API route is not allowlisted")
    if any(not isinstance(value, str) or "\x00" in value or len(value.encode()) > 4096 for value in params.values()):
        raise ReadwiseReaderProviderError("Readwise Reader API query is invalid")
    if "limit" in params and (not params["limit"].isdigit() or not 1 <= int(params["limit"]) <= 100):
        raise ReadwiseReaderProviderError("Readwise Reader page size is invalid")
    query = urlencode(params)
    return f"{API_ORIGIN}{path}" + (f"?{query}" if query else "")


def api(config: ProfileConfig, opener: Opener, path: str, params: dict[str, str]) -> ApiResult:
    request = Request(
        _target_url(path, params),
        headers={
            "Accept": "application/json",
            "Authorization": f"Token {config.access_token}",
            "User-Agent": "aidevops-readwise-reader-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise ReadwiseReaderProviderError("Readwise Reader HTTP status is invalid")
            if path == "/api/v2/auth/" and status == 204:
                return ApiResult(status, {})
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise ReadwiseReaderProviderError("Readwise Reader HTTP response is invalid")
            return ApiResult(status, decode_json(payload, MAX_RESPONSE_BYTES))
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise ReadwiseReaderProviderError("Readwise Reader request failed") from error
