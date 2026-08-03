#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free, GET-only transport for Lemmy account reads."""

from __future__ import annotations

import hashlib
import hmac
import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_lemmy_contract import ApiResult, LemmyReadProviderError, decode_json
from _knowledge_social_lemmy_v3 import QUERY_KEYS as V3_QUERY_KEYS
from _knowledge_social_lemmy_v4 import QUERY_KEYS as V4_QUERY_KEYS

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
DISCOVERY_PATH = "/api/v3/site"
QUERY_KEYS = {DISCOVERY_PATH: frozenset(), **V3_QUERY_KEYS, **V4_QUERY_KEYS}


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
    access_token: str
    auth_mode: str
    instance_id: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise LemmyReadProviderError("Lemmy profile base URL is invalid") from error
    return parsed, port


def _require_https_origin(parsed: SplitResult) -> None:
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        parsed.path in ("", "/"),
        not parsed.query,
        not parsed.fragment,
    )
    if not all(checks):
        raise LemmyReadProviderError("Lemmy profile base URL must be an HTTPS origin")


def _render_origin(parsed: SplitResult, port: int | None) -> str:
    host = parsed.hostname or ""
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}"


def _canonical_base_url(value: str) -> str:
    parsed, port = _parsed_url(value)
    _require_https_origin(parsed)
    return _render_origin(parsed, port)


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode()
    if len(key) < 32:
        raise LemmyReadProviderError("Lemmy profile origin key must be at least 32 bytes")
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise LemmyReadProviderError("Python urllib HTTP exports are unavailable")
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


def _decode_response(payload: bytes) -> dict[str, Any]:
    decoded = decode_json(payload, MAX_RESPONSE_BYTES)
    if not isinstance(decoded, dict):
        raise LemmyReadProviderError("Lemmy API response root must be an object")
    return decoded


def _validate_params(path: str, params: dict[str, str]) -> None:
    allowed = QUERY_KEYS.get(path)
    if allowed is None or set(params) - allowed:
        raise LemmyReadProviderError("Lemmy API route is not allowlisted")
    for key, value in params.items():
        if not isinstance(value, str) or not value or "\x00" in value:
            raise LemmyReadProviderError("Lemmy API query is invalid")
        if len(value.encode("utf-8")) > 8192:
            raise LemmyReadProviderError("Lemmy API query exceeds the safety limit")
        if key == "limit" and (not value.isdigit() or not 1 <= int(value) <= 50):
            raise LemmyReadProviderError("Lemmy API page size is invalid")
        if key in ("page", "person_id") and (not value.isdigit() or int(value) < 1):
            raise LemmyReadProviderError("Lemmy API numeric query is invalid")


def _target_url(config: ProfileConfig, target: str, params: dict[str, str]) -> str:
    if not target.startswith("/") or "?" in target or "#" in target:
        raise LemmyReadProviderError("Lemmy API route is not allowlisted")
    _validate_params(target, params)
    query = urlencode(params)
    return f"{config.base_url}{target}" + (f"?{query}" if query else "")


def _request_for(config: ProfileConfig, url: str) -> Request:
    return Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config.access_token}",
            "User-Agent": "aidevops-lemmy-knowledge/1",
        },
        method="GET",
    )


def api(
    config: ProfileConfig,
    opener: Opener,
    target: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    url = _target_url(config, target, params)
    request = _request_for(config, url)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise LemmyReadProviderError("Lemmy HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise LemmyReadProviderError("Lemmy HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, {}, retry_after=_retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise LemmyReadProviderError("Lemmy read provider request failed") from error
