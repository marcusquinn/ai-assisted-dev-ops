#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free HTTP transport for NodeBB account reads."""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_nodebb_contract import ApiResult, NodeBBReadProviderError
from _knowledge_social_nodebb_routes import allowlisted_path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
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
    """Validated secret profile and privacy-safe installation identity."""

    base_url: str
    bearer_token: str
    token_type: str
    instance_id: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise NodeBBReadProviderError("NodeBB profile base URL is invalid") from error
    return parsed, port


def _validate_origin(parsed: SplitResult) -> None:
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        not parsed.query,
        not parsed.fragment,
    )
    if not all(checks):
        raise NodeBBReadProviderError("NodeBB profile base URL must be HTTPS")


def _canonical_path(path: str) -> str:
    result = path.rstrip("/")
    if any(marker in result for marker in ("\\", "%", "//")):
        raise NodeBBReadProviderError("NodeBB profile base URL is invalid")
    if any(part in (".", "..") for part in result.split("/") if part):
        raise NodeBBReadProviderError("NodeBB profile base URL is invalid")
    if result.lower().startswith("/admin"):
        raise NodeBBReadProviderError("NodeBB profile base URL is invalid")
    return result


def _canonical_base_url(value: str) -> str:
    """Canonicalize one HTTPS installation base without leaking it in errors."""
    parsed, port = _parsed_url(value)
    _validate_origin(parsed)
    host = parsed.hostname or ""
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{_canonical_path(parsed.path)}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode()
    if len(key) < 32:
        raise NodeBBReadProviderError(
            "NodeBB profile origin key must be at least 32 bytes"
        )
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise NodeBBReadProviderError("Python urllib HTTP exports are unavailable")
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


def _parse_json(payload: bytes) -> Any:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NodeBBReadProviderError(
            "NodeBB read provider returned no valid JSON"
        ) from error


def _decode_response(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise NodeBBReadProviderError("NodeBB read response exceeds the safety limit")
    decoded = _parse_json(payload)
    if not isinstance(decoded, (dict, list)):
        raise NodeBBReadProviderError(
            "NodeBB API response root must be an object or array"
        )
    return decoded


def _query_keys(path: str) -> frozenset[str]:
    if path == "/api/notifications":
        return frozenset({"page"})
    if path == "/api/v3/chats":
        return frozenset({"start", "perPage"})
    if path.startswith("/api/user/") and not path.endswith("/groups"):
        return frozenset({"page"})
    return frozenset()


def _validate_api_request(path: str, params: dict[str, str]) -> None:
    if not allowlisted_path(path) or set(params) != _query_keys(path):
        raise NodeBBReadProviderError("NodeBB API route is not allowlisted")
    for key, value in params.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise NodeBBReadProviderError("NodeBB API query is invalid")
        if "\x00" in key or "\x00" in value:
            raise NodeBBReadProviderError("NodeBB API query is invalid")


def _http_status(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise NodeBBReadProviderError("NodeBB HTTP status is invalid")
    return value


def _request_for(config: ProfileConfig, path: str, params: dict[str, str]) -> Request:
    query = f"?{urlencode(params)}" if params else ""
    return Request(
        f"{config.base_url}{path}{query}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config.bearer_token}",
            "User-Agent": "aidevops-nodebb-knowledge/1",
        },
        method="GET",
    )


def api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    _validate_api_request(path, params)
    request = _request_for(config, path, params)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = _http_status(getattr(response, "status", 200))
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise NodeBBReadProviderError("NodeBB HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(_http_status(error.code), {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise NodeBBReadProviderError("NodeBB read provider request failed") from error
