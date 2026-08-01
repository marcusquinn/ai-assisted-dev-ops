#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only transport for Google Business Profile service families."""

from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
API_BASES = frozenset(
    {
        "https://www.googleapis.com/oauth2/v3",
        "https://mybusinessaccountmanagement.googleapis.com/v1",
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        "https://mybusiness.googleapis.com/v4",
        "https://mybusinessverifications.googleapis.com/v1",
        "https://businessprofileperformance.googleapis.com/v1",
    }
)
RATE_LIMIT_REASONS = frozenset(
    {"dailyLimitExceeded", "quotaExceeded", "rateLimitExceeded", "userRateLimitExceeded"}
)
UrlOpen = Callable[..., Any]


class ProviderError(RuntimeError):
    """Raised for a privacy-safe local provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: dict[str, Any]
    retry_after: int | None = None


def http_exports() -> UrlOpen:
    """Return the standard-library opener after checking required exports."""
    if not callable(Request) or not callable(urlopen) or not callable(urlencode):
        raise ProviderError("Python urllib HTTP exports are unavailable")
    return urlopen


def _decode_response(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProviderError("Google Business Profile response exceeds the safety limit")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderError("Google Business Profile returned no valid JSON") from error
    if not isinstance(value, dict):
        raise ProviderError("Google Business Profile response root must be an object")
    return value


def _retry_epoch(value: str | None) -> int | None:
    try:
        seconds = float(value) if value is not None else -1
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _terminal_status(error: HTTPError) -> int:
    if error.code != 403:
        return error.code
    try:
        body = _decode_response(error.read(MAX_RESPONSE_BYTES + 1))
    except (OSError, ProviderError):
        return error.code
    envelope = body.get("error")
    details = envelope.get("errors") if isinstance(envelope, dict) else None
    reasons = {
        entry.get("reason")
        for entry in details or []
        if isinstance(entry, dict) and isinstance(entry.get("reason"), str)
    }
    return 429 if reasons.intersection(RATE_LIMIT_REASONS) else error.code


def api_request(
    token: str,
    opener: UrlOpen,
    base: str,
    path: str,
    params: dict[str, Any] | None = None,
) -> ApiResult:
    """Execute one allowlisted GET and return a sanitized bounded result."""
    if base not in API_BASES or not path.startswith("/") or ".." in path:
        raise ProviderError("Google Business Profile API route is not allowlisted")
    filtered = {
        key: value for key, value in (params or {}).items() if value is not None
    }
    query = urlencode(filtered, doseq=True)
    url = f"{base}{path}{'?' + query if query else ''}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aidevops-google-business-profile-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise ProviderError("Google Business Profile HTTP response is invalid")
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise ProviderError("Google Business Profile HTTP status is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        return ApiResult(
            _terminal_status(error), {}, _retry_epoch(error.headers.get("Retry-After"))
        )
    except (TimeoutError, URLError, OSError) as error:
        raise ProviderError("Google Business Profile read provider request failed") from error
