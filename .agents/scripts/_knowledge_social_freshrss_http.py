#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin bounded FreshRSS login and GET-only data transport."""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_freshrss_contract import (
    ApiResult,
    FreshRSSReadProviderError,
    decode_json,
    login_token,
)
from _knowledge_social_freshrss_identity import canonical_base_url
from _knowledge_social_freshrss_routes import allowlisted_path, query_keys_for_path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_LOGIN_BYTES = 64 * 1024
HTTP_TIMEOUT_SECONDS = 60
API_PREFIX = "/api/greader.php"
LOGIN_PATH = "/accounts/ClientLogin"


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
    username: str
    api_password: str
    origin_key: str
    installation_id: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise FreshRSSReadProviderError("Python urllib HTTP exports are unavailable")
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


def _api_root(config: ProfileConfig) -> str:
    return f"{canonical_base_url(config.base_url)}{API_PREFIX}"


def _target_url(config: ProfileConfig, path: str, params: dict[str, str]) -> str:
    if not allowlisted_path(path) or set(params) - query_keys_for_path(path):
        raise FreshRSSReadProviderError("FreshRSS API route is not allowlisted")
    if any(
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode()) > 16 * 1024
        for value in params.values()
    ):
        raise FreshRSSReadProviderError("FreshRSS API query is invalid")
    for key in ("n", "ot"):
        value = params.get(key)
        if value is not None and not value.isdigit():
            raise FreshRSSReadProviderError("FreshRSS paging query is invalid")
    query = urlencode(params)
    return f"{_api_root(config)}{path}" + (f"?{query}" if query else "")


def _status(response: Response) -> int:
    status = getattr(response, "status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise FreshRSSReadProviderError("FreshRSS HTTP status is invalid")
    return status


def login(config: ProfileConfig, opener: Opener) -> ApiResult:
    """Execute the sole allowlisted POST: non-mutating ClientLogin."""
    form = urlencode({"Email": config.username, "Passwd": config.api_password}).encode()
    request = Request(
        f"{_api_root(config)}{LOGIN_PATH}",
        data=form,
        headers={
            "Accept": "text/plain",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "aidevops-freshrss-knowledge/1",
        },
        method="POST",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            payload = response.read(MAX_LOGIN_BYTES + 1)
            if not isinstance(payload, bytes) or len(payload) > MAX_LOGIN_BYTES:
                raise FreshRSSReadProviderError(
                    "FreshRSS login response exceeds the safety limit"
                )
            return ApiResult(_status(response), login_token(payload, MAX_LOGIN_BYTES))
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, None, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise FreshRSSReadProviderError("FreshRSS read provider request failed") from error


def api(
    config: ProfileConfig,
    opener: Opener,
    auth: str,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only data request."""
    if not isinstance(auth, str) or not auth or "\x00" in auth:
        raise FreshRSSReadProviderError("FreshRSS authorization is invalid")
    request = Request(
        _target_url(config, path, params),
        headers={
            "Accept": (
                "application/xml"
                if path == "/reader/api/0/subscription/export"
                else "application/json"
            ),
            "Authorization": f"GoogleLogin auth={auth}",
            "User-Agent": "aidevops-freshrss-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes) or len(payload) > MAX_RESPONSE_BYTES:
                raise FreshRSSReadProviderError(
                    "FreshRSS read response exceeds the safety limit"
                )
            if path == "/reader/api/0/subscription/export":
                try:
                    decoded: Any = payload.decode("utf-8")
                except UnicodeDecodeError as error:
                    raise FreshRSSReadProviderError(
                        "FreshRSS OPML response is invalid"
                    ) from error
            else:
                decoded = decode_json(payload, MAX_RESPONSE_BYTES)
            return ApiResult(_status(response), decoded)
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise FreshRSSReadProviderError("FreshRSS read provider request failed") from error
