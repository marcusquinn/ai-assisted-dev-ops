#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free HTTP transport for Discourse account reads."""

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

from _knowledge_social_discourse_contract import (
    ApiResult,
    DiscourseReadProviderError,
)
from _knowledge_social_discourse_routes import allowlisted_path

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
    user_api_key: str
    scope: str
    instance_id: str


class _RejectRedirect(HTTPRedirectHandler):
    """Convert every redirect into a terminal response without following it."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise DiscourseReadProviderError(
            "Discourse profile base URL is invalid"
        ) from error
    return parsed, port


def _validate_origin(parsed: SplitResult) -> None:
    if parsed.scheme.lower() != "https":
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    if parsed.hostname is None:
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    if parsed.username is not None:
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    if parsed.password is not None:
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    if parsed.query:
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    if parsed.fragment:
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")


def _invalid_path_syntax(path: str) -> bool:
    return any(marker in path for marker in ("\\", "%", "//"))


def _canonical_path(value: str) -> str:
    path = value.rstrip("/")
    if _invalid_path_syntax(path):
        raise DiscourseReadProviderError("Discourse profile base URL is invalid")
    parts = (part for part in path.split("/") if part)
    if any(part in (".", "..") for part in parts):
        raise DiscourseReadProviderError("Discourse profile base URL is invalid")
    if path.lower().startswith("/admin"):
        raise DiscourseReadProviderError("Discourse profile base URL is invalid")
    return path


def _canonical_base_url(value: str) -> str:
    """Canonicalize one HTTPS installation base without leaking it in errors."""
    parsed, port = _parsed_url(value)
    _validate_origin(parsed)
    host = parsed.hostname or ""
    rendered_host = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered_host = f"{rendered_host}:{port}"
    return f"https://{rendered_host}{_canonical_path(parsed.path)}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    """Return a corpus-local keyed installation namespace."""
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode("utf-8")
    if len(key) < 32:
        raise DiscourseReadProviderError(
            "Discourse profile origin key must be at least 32 bytes"
        )
    return hmac.new(key, canonical.encode("utf-8"), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    """Verify and return the installed standard-library HTTP surface."""
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise DiscourseReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _retry_epoch(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds):
        return None
    if seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _decode_response(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise DiscourseReadProviderError(
            "Discourse read response exceeds the safety limit"
        )
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscourseReadProviderError(
            "Discourse read provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, (dict, list)):
        raise DiscourseReadProviderError(
            "Discourse API response root must be an object or array"
        )
    return decoded


def _query_keys(path: str) -> frozenset[str]:
    exact = {
        "/user_actions.json": frozenset({"username", "filter", "offset", "limit"}),
        "/notifications.json": frozenset({"username", "offset", "limit"}),
    }
    if path in exact:
        return exact[path]
    if path.endswith("/bookmarks.json"):
        return frozenset({"page", "limit"})
    if path.startswith("/topics/private-messages"):
        return frozenset({"page"})
    return frozenset()


def _valid_query_item(item: tuple[str, str]) -> bool:
    key, value = item
    if not isinstance(key, str) or not isinstance(value, str):
        return False
    if "\x00" in key:
        return False
    if "\x00" in value:
        return False
    return True


def _validate_api_request(path: str, params: dict[str, str]) -> None:
    if not allowlisted_path(path):
        raise DiscourseReadProviderError("Discourse API route is not allowlisted")
    if set(params) != _query_keys(path):
        raise DiscourseReadProviderError("Discourse API route is not allowlisted")
    if "recent" in params:
        raise DiscourseReadProviderError("Discourse API query is invalid")
    if not all(_valid_query_item(item) for item in params.items()):
        raise DiscourseReadProviderError("Discourse API query is invalid")


def _http_status(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise DiscourseReadProviderError("Discourse HTTP status is invalid")
    return value


def _request_for(config: ProfileConfig, path: str, params: dict[str, str]) -> Request:
    query = f"?{urlencode(params)}" if params else ""
    return Request(
        f"{config.base_url}{path}{query}",
        headers={
            "Accept": "application/json",
            "User-Api-Key": config.user_api_key,
            "User-Agent": "aidevops-discourse-knowledge/1",
        },
        method="GET",
    )


def _api(
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
                raise DiscourseReadProviderError("Discourse HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        status = _http_status(error.code)
        retry_header = None
        if error.headers is not None:
            retry_header = error.headers.get("Retry-After")
        return ApiResult(status, {}, _retry_epoch(retry_header))
    except (TimeoutError, URLError, OSError) as error:
        raise DiscourseReadProviderError(
            "Discourse read provider request failed"
        ) from error
