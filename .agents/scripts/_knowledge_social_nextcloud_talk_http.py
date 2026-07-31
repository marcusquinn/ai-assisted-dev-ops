#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free, GET-only transport for Nextcloud Talk OCS."""

from __future__ import annotations

import base64
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

from _knowledge_social_nextcloud_talk_contract import (
    ApiResult,
    NextcloudTalkReadProviderError,
)

MAX_RESPONSE_BYTES = 16 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60


class Response(Protocol):
    status: int
    headers: Any

    def __enter__(self) -> Response: ...

    def __exit__(self, *args: Any) -> None: ...

    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


@dataclass(frozen=True)
class ProfileConfig:
    """Validated private profile for one exact Nextcloud installation."""

    base_url: str
    username: str
    app_password: str
    origin_key: str
    instance_id: str
    allowed_rooms: tuple[str, ...]
    expected_server_major: int
    expected_talk_major: int


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk profile base URL is invalid"
        ) from error
    return parsed, port


def _canonical_path(path: str) -> str:
    result = path.rstrip("/")
    if any(marker in result for marker in ("\\", "%", "//")):
        raise NextcloudTalkReadProviderError("Nextcloud Talk profile base URL is invalid")
    if any(part in (".", "..") for part in result.split("/") if part):
        raise NextcloudTalkReadProviderError("Nextcloud Talk profile base URL is invalid")
    return result


def canonical_base_url(value: str) -> str:
    """Canonicalize one HTTPS installation without exposing it in errors."""
    parsed, port = _parsed_url(value)
    safe_origin = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        not parsed.query,
        not parsed.fragment,
    )
    if not all(safe_origin):
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk profile base URL must be exact HTTPS"
        )
    host = parsed.hostname.lower()
    rendered = f"[{host}]" if ":" in host else host
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{_canonical_path(parsed.path)}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    key = origin_key.encode("utf-8")
    if len(key) < 32:
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk profile origin key must be at least 32 bytes"
        )
    canonical = canonical_base_url(base_url)
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def http_opener() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise NextcloudTalkReadProviderError("Python urllib HTTP exports are unavailable")
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


def _headers(value: Any) -> dict[str, str]:
    if value is None or not hasattr(value, "items"):
        return {}
    return {str(key).lower(): str(item) for key, item in value.items()}


def _decode(payload: bytes, status: int) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise NextcloudTalkReadProviderError("Nextcloud Talk response exceeds the safety limit")
    if status == 304 and not payload:
        return {}
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, dict):
        raise NextcloudTalkReadProviderError("Nextcloud Talk OCS root must be an object")
    return decoded


def _allowed_path(config: ProfileConfig, path: str) -> bool:
    exact = {
        "/ocs/v2.php/cloud/capabilities",
        "/ocs/v2.php/cloud/user",
        "/ocs/v2.php/apps/spreed/api/v4/room",
    }
    if path in exact:
        return True
    return any(
        path
        in {
            f"/ocs/v2.php/apps/spreed/api/v4/room/{token}",
            f"/ocs/v2.php/apps/spreed/api/v4/room/{token}/participants",
            f"/ocs/v2.php/apps/spreed/api/v1/chat/{token}",
        }
        for token in config.allowed_rooms
    )


def _query_keys(path: str) -> frozenset[str]:
    if path == "/ocs/v2.php/apps/spreed/api/v4/room":
        return frozenset({"includeStatus", "noStatusUpdate"})
    if "/api/v1/chat/" in path:
        return frozenset(
            {
                "includeLastKnown",
                "lastKnownMessageId",
                "limit",
                "lookIntoFuture",
                "markNotificationsAsRead",
                "noStatusUpdate",
                "setReadMarker",
            }
        )
    return frozenset()


def _request(config: ProfileConfig, path: str, params: dict[str, str]) -> Request:
    if not _allowed_path(config, path) or set(params) != _query_keys(path):
        raise NextcloudTalkReadProviderError("Nextcloud Talk OCS route is not allowlisted")
    if any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or "\x00" in key
        or "\x00" in value
        for key, value in params.items()
    ):
        raise NextcloudTalkReadProviderError("Nextcloud Talk OCS query is invalid")
    query = {**params, "format": "json"}
    encoded = base64.b64encode(
        f"{config.username}:{config.app_password}".encode("utf-8")
    ).decode("ascii")
    return Request(
        f"{config.base_url}{path}?{urlencode(query)}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Basic {encoded}",
            "OCS-APIRequest": "true",
            "User-Agent": "aidevops-nextcloud-talk-knowledge/1",
        },
        method="GET",
    )


def api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only OCS request."""
    request = _request(config, path, params)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise NextcloudTalkReadProviderError("Nextcloud Talk HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise NextcloudTalkReadProviderError("Nextcloud Talk HTTP response is invalid")
            return ApiResult(status, _decode(payload, status), _headers(response.headers))
    except HTTPError as error:
        headers = _headers(error.headers)
        return ApiResult(error.code, {}, headers, _retry_epoch(headers.get("retry-after")))
    except (TimeoutError, URLError, OSError) as error:
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk provider request failed"
        ) from error
