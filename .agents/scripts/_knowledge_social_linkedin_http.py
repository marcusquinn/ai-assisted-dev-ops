#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded LinkedIn HTTP response decoding and terminal metadata."""

from __future__ import annotations

import json
import math
import time
from typing import Any
from urllib.error import HTTPError

from _knowledge_social_linkedin_contract import ApiResult, LinkedInReadProviderError

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
NO_DATA_MESSAGE = "No data found for this memberId"


def retry_epoch(value: str | None) -> int | None:
    """Convert a bounded Retry-After duration to an absolute epoch."""
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def decode_response(payload: bytes) -> dict[str, Any]:
    """Decode one bounded LinkedIn JSON response object."""
    if len(payload) > MAX_RESPONSE_BYTES:
        raise LinkedInReadProviderError("LinkedIn read response exceeds the safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LinkedInReadProviderError(
            "LinkedIn read provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, dict):
        raise LinkedInReadProviderError("LinkedIn API response root must be an object")
    return decoded


def _contains_no_data(value: Any) -> bool:
    if isinstance(value, str):
        return NO_DATA_MESSAGE in value
    if isinstance(value, dict):
        return any(_contains_no_data(child) for child in value.values())
    if isinstance(value, list):
        return any(_contains_no_data(child) for child in value)
    return False


def _no_data_body(body: Any) -> bool:
    if not isinstance(body, bytes):
        return False
    if len(body) > MAX_RESPONSE_BYTES:
        return False
    try:
        return _contains_no_data(decode_response(body))
    except LinkedInReadProviderError:
        return False


def http_error_result(error: HTTPError) -> ApiResult:
    """Return sanitized metadata for one bounded HTTP error response."""
    status = error.code
    if isinstance(status, bool) or not isinstance(status, int):
        raise LinkedInReadProviderError("LinkedIn HTTP status is invalid") from error
    body = error.read(MAX_RESPONSE_BYTES + 1)
    no_data = _no_data_body(body) if status == 404 else False
    headers = error.headers
    retry_after = retry_epoch(headers.get("Retry-After")) if headers else None
    return ApiResult(status, {}, retry_after, no_data)
