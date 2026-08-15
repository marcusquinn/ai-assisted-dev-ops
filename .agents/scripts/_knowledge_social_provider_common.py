#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared safety contracts for outbound social provider adapters."""

from __future__ import annotations

import math
import time
from email.utils import parsedate_to_datetime
from typing import Any, Protocol
from urllib.request import HTTPRedirectHandler, build_opener

from _knowledge_social_outbound import ClaimedOperation

WRITE_TIMEOUT_SECONDS = 120
MAX_PROVIDER_OUTPUT_BYTES = 1024 * 1024
MAX_PROVIDER_RETRY_SECONDS = 31 * 24 * 60 * 60
DEFAULT_PROVIDER_RETRY_SECONDS = 60


class ProviderAdapterError(RuntimeError):
    """Raised when an approved operation cannot be mapped to safe provider argv."""


class ProviderIdentityError(RuntimeError):
    """Raised when the selected provider account cannot be verified safely."""


class ProviderRateLimitError(RuntimeError):
    """Raised with bounded provider reset evidence after an HTTP rate limit."""

    def __init__(self, retry_after_seconds: int | None):
        super().__init__("provider rate limit")
        self.retry_after_seconds = retry_after_seconds


class PreparedProvider(Protocol):
    """One validated provider selection for an immutable claimed operation."""

    claimed: ClaimedOperation

    def verify_identity(self) -> None:
        """Verify the selected provider identity before the write boundary."""

    def invoke(self) -> tuple[str | None, str | None]:
        """Invoke one approved write and return only a safe receipt classification."""


def _retry_after_seconds(
    value: str, current_time: float | None
) -> tuple[float | None, bool]:
    try:
        return float(value), False
    except (TypeError, ValueError):
        try:
            parsed = parsedate_to_datetime(value)
        except (OverflowError, TypeError, ValueError):
            return None, True
        if parsed.utcoffset() is None:
            return None, True
        seconds = parsed.timestamp() - (
            time.time() if current_time is None else current_time
        )
        return seconds, True


def provider_retry_seconds(
    value: str | None, current_time: float | None = None
) -> int | None:
    """Parse one provider Retry-After duration or HTTP date into a bounded delay."""
    if value is None or not isinstance(value, str) or len(value) > 128:
        return None
    seconds, parsed_date = _retry_after_seconds(value, current_time)
    if seconds is None or not math.isfinite(seconds):
        return None
    if seconds < 0:
        return 0 if parsed_date else None
    return min(math.ceil(seconds), MAX_PROVIDER_RETRY_SECONDS)


def raise_for_provider_rate_limit(status: int, headers: Any) -> None:
    """Raise only when a provider response supplies an HTTP 429 classification."""
    if status == 429:
        retry_after = headers.get("Retry-After") if headers is not None else None
        raise ProviderRateLimitError(provider_retry_seconds(retry_after))


class RejectProviderRedirect(HTTPRedirectHandler):
    """Reject redirects before urllib can forward provider authorization headers."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def redirect_free_provider_open(request: Any, **kwargs: Any) -> Any:
    """Open one provider request without following any redirect."""
    return build_opener(RejectProviderRedirect()).open(request, **kwargs)
