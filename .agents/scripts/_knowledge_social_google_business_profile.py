#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Google Business Profile stream capabilities and checkpoint policy."""

from __future__ import annotations

import base64
import json
import re
import sys
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "google_business_profile"
CURSOR_PREFIX = "google-business-profile-v1:"
RESOURCE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
API_RETENTION = "current_api_window_and_provider_retention_apply"


class GoogleBusinessProfileAdapterError(SocialStoreError):
    """Raised when guarded Business Profile collection cannot continue safely."""


class GoogleBusinessProfileProviderUnavailableError(
    GoogleBusinessProfileAdapterError
):
    """Raised when the bounded OAuth subprocess cannot complete a read."""


ADAPTER_ERROR = GoogleBusinessProfileAdapterError
PROVIDER_UNAVAILABLE_ERROR = GoogleBusinessProfileProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one location stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


STREAMS = {
    "location_profile": StreamSpec("location_profile", "observed", "snapshot", False, None),
    "attributes": StreamSpec("attribute", "observed", "snapshot", False, None),
    "media": StreamSpec("media", "observed", "snapshot", False, API_RETENTION),
    "local_posts": StreamSpec("local_post", "authored", "snapshot", False, API_RETENTION),
    "reviews": StreamSpec("review", "observed", "snapshot", False, API_RETENTION),
    "verification_state": StreamSpec(
        "verification_state",
        "observed",
        "snapshot",
        False,
        None,
        "partial",
        "voice_of_merchant_state_only",
    ),
    "performance": StreamSpec("performance_metric", "observed", "snapshot", False, API_RETENTION),
    "search_keywords": StreamSpec("search_keyword", "observed", "snapshot", False, API_RETENTION),
}


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted bounded request passed to the OAuth subprocess."""

    stream: str
    location_id: str
    business_account_id: str
    organization_id: str | None
    cursor: dict[str, Any] | None
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "location_id": self.location_id,
            "business_account_id": self.business_account_id,
            "organization_id": self.organization_id,
            "cursor": self.cursor,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def resource_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    """Validate one selector ID without accepting a resource path."""
    if value is None and optional:
        return None
    if not isinstance(value, str) or RESOURCE_ID.fullmatch(value) is None:
        raise GoogleBusinessProfileAdapterError(
            f"Google Business Profile {field} must be a stable ID"
        )
    return value


def _encode_cursor(cursor: dict[str, Any]) -> str:
    reject_credentials(cursor)
    payload = canonical_json(cursor).encode("utf-8")
    if len(payload) > 4096:
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile checkpoint exceeds the safety limit"
        )
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> dict[str, Any]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise GoogleBusinessProfileAdapterError(
            "stored Google Business Profile cursor has an unsupported version"
        )
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        padding = "=" * (-len(encoded) % 4)
        parsed = json.loads(base64.urlsafe_b64decode(encoded + padding))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise GoogleBusinessProfileAdapterError(
            "stored Google Business Profile cursor is invalid"
        ) from error
    if not isinstance(parsed, dict):
        raise GoogleBusinessProfileAdapterError(
            "stored Google Business Profile cursor has an invalid shape"
        )
    reject_credentials(parsed)
    return parsed


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    """Build one hierarchy-bound request from durable stream state."""
    if stream not in STREAMS:
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile stream is unsupported"
        )
    location_id = resource_id(account.get("id"), "location ID")
    business_account_id = resource_id(
        account.get("business_account_id"), "business account ID"
    )
    organization_id = resource_id(
        account.get("organization_id"), "organization ID", optional=True
    )
    if location_id is None or business_account_id is None:
        raise GoogleBusinessProfileAdapterError(
            "verified Google Business Profile hierarchy is incomplete"
        )
    return PageRequest(
        stream,
        location_id,
        business_account_id,
        organization_id,
        _decode_cursor(state.cursor) if state.cursor else None,
        None,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a provider response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile response status must be an integer"
        )
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated sanitized record array."""
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile page data must be an array"
        )
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Calculate one resumable opaque page-token checkpoint."""
    del request
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile page meta must be an object"
        )
    reject_credentials(meta)
    next_cursor = meta.get("next_cursor")
    complete = meta.get("complete")
    snapshot = meta.get("snapshot")
    if next_cursor is not None and not isinstance(next_cursor, dict):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile next cursor must be an object"
        )
    if not isinstance(complete, bool) or snapshot is not True:
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile page completion metadata is invalid"
        )
    if complete == (next_cursor is not None):
        raise GoogleBusinessProfileAdapterError(
            "Google Business Profile cursor and completion state conflict"
        )
    encoded = _encode_cursor(next_cursor) if next_cursor is not None else None
    return PageCheckpoint(encoded, state.watermark), complete


def run_collector(description: str) -> int:
    """Load provider callbacks lazily and execute the shared OAuth loop."""
    from pathlib import Path

    from _knowledge_social_google_business_profile_normalize import (
        PageContext,
        normalize_page,
    )
    from _knowledge_social_google_business_profile_reader import (
        FixtureGoogleBusinessProfile,
        GuardedGoogleBusinessProfileOAuth,
        verified_identity,
    )
    from _knowledge_social_oauth_collector import (
        OAuthCollectorPolicy,
        run_oauth_collector,
    )

    policy = OAuthCollectorPolicy(
        display_name="Google Business Profile",
        provider_module=sys.modules[__name__],
        helper=Path(__file__).with_name(
            "_knowledge_social_google_business_profile_provider.py"
        ),
        fixture_reader=FixtureGoogleBusinessProfile,
        live_reader=GuardedGoogleBusinessProfileOAuth,
        page_context=PageContext,
        normalize_page=normalize_page,
        verified_identity=verified_identity,
        budget_unit="bounded collection",
        default_budget=11,
        min_budget=3,
        max_page_size=100,
    )
    return run_oauth_collector(policy, description)
