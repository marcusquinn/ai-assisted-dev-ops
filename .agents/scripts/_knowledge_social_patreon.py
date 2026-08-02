#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Patreon creator identity, stream policy, and opaque cursor checkpoints."""

from __future__ import annotations

import base64
import hashlib
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "patreon"
CURSOR_PREFIX = "patreon-v2:"
RETENTION_LIMIT = "current_api_visibility_and_creator_privacy_purpose"
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,159}$")
CAMPAIGN_ID = re.compile(r"^[1-9][0-9]{0,31}$")
MAX_CURSOR_BYTES = 4096
MAX_CURSOR_HISTORY = 256


class PatreonAdapterError(RuntimeError):
    """Raised when Patreon evidence violates the local collector contract."""


class PatreonProviderUnavailableError(PatreonAdapterError):
    """Raised when the isolated Patreon reader cannot run safely."""


ADAPTER_ERROR = PatreonAdapterError
PROVIDER_UNAVAILABLE_ERROR = PatreonProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Patreon stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 3


STREAMS = {
    "account": StreamSpec("creator_account", "selected_account", "snapshot", False, RETENTION_LIMIT),
    "campaigns": StreamSpec("campaign", "creator_campaign", "campaign_sequence", False, RETENTION_LIMIT),
    "posts": StreamSpec("post", "creator_post", "cursor", False, RETENTION_LIMIT),
    "memberships": StreamSpec("membership", "current_entitlement", "cursor", False, RETENTION_LIMIT),
    "benefits": StreamSpec("benefit", "campaign_benefit", "campaign_sequence", False, RETENTION_LIMIT),
}


def provider_id(value: Any, field: str = "ID") -> str:
    """Validate one opaque Patreon identifier without exposing it in errors."""
    if not isinstance(value, str) or OPAQUE_ID.fullmatch(value) is None:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def campaign_id(value: Any, field: str = "campaign ID") -> str:
    """Validate one documented numeric Patreon campaign identifier."""
    if not isinstance(value, str) or CAMPAIGN_ID.fullmatch(value) is None:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def selected_campaign_ids(value: Any) -> tuple[str, ...]:
    """Validate the explicit creator-owned campaign allowlist."""
    if not isinstance(value, (list, tuple)) or not 1 <= len(value) <= 20:
        raise PatreonAdapterError("Patreon selected campaigns must contain 1-20 IDs")
    selected = tuple(campaign_id(item, "selected campaign ID") for item in value)
    if len(selected) != len(set(selected)):
        raise PatreonAdapterError("Patreon selected campaigns contain duplicates")
    return tuple(sorted(selected, key=int))


def _optional_cursor(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode()) > MAX_CURSOR_BYTES
    ):
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def _cursor_digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _encode_cursor(campaign: str, cursor: str | None, seen: tuple[str, ...]) -> str:
    payload = {"campaign_id": campaign, "cursor": cursor, "seen": list(seen)}
    encoded = base64.urlsafe_b64encode(canonical_json(payload).encode()).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(value: str) -> tuple[str, str | None, tuple[str, ...]]:
    if not value.startswith(CURSOR_PREFIX) or len(value.encode()) > 32 * 1024:
        raise PatreonAdapterError("stored Patreon cursor has an unsupported version")
    encoded = value.removeprefix(CURSOR_PREFIX)
    try:
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise PatreonAdapterError("stored Patreon cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"campaign_id", "cursor", "seen"}:
        raise PatreonAdapterError("stored Patreon cursor has an invalid shape")
    reject_credentials(payload)
    campaign = campaign_id(payload.get("campaign_id"), "cursor campaign ID")
    cursor = _optional_cursor(payload.get("cursor"), "cursor value")
    seen_value = payload.get("seen")
    if (
        not isinstance(seen_value, list)
        or len(seen_value) > MAX_CURSOR_HISTORY
        or any(not isinstance(item, str) or not re.fullmatch(r"[0-9a-f]{64}", item) for item in seen_value)
        or len(seen_value) != len(set(seen_value))
    ):
        raise PatreonAdapterError("stored Patreon cursor history is invalid")
    seen = tuple(seen_value)
    if cursor is None and seen:
        raise PatreonAdapterError("stored Patreon campaign cursor history is inconsistent")
    if cursor is not None and _cursor_digest(cursor) not in seen:
        raise PatreonAdapterError("stored Patreon cursor history is incomplete")
    return campaign, cursor, seen


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted request passed to the isolated Patreon HTTP child."""

    stream: str
    account_id: str
    campaign_ids: tuple[str, ...]
    campaign_id: str | None
    cursor: str | None
    seen_cursors: tuple[str, ...]
    limit: int
    member_data_authorized: bool

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "campaign_ids": list(self.campaign_ids),
            "campaign_id": self.campaign_id,
            "cursor": self.cursor,
            "seen_cursors": list(self.seen_cursors),
            "limit": self.limit,
            "member_data_authorized": self.member_data_authorized,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def _request_campaign(
    stream: str, campaigns: tuple[str, ...], state: CursorState
) -> tuple[str | None, str | None, tuple[str, ...]]:
    if stream == "account":
        if state.cursor is not None:
            raise PatreonAdapterError("Patreon account stream cannot use a campaign cursor")
        return None, None, ()
    if state.cursor is None:
        return campaigns[0], None, ()
    selected, cursor, seen = _decode_cursor(state.cursor)
    if selected not in campaigns:
        raise PatreonAdapterError("stored Patreon cursor targets an unselected campaign")
    return selected, cursor, seen


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    """Build one request from an independent per-stream checkpoint."""
    if stream not in STREAMS:
        raise PatreonAdapterError("Patreon stream is unsupported")
    account_id = provider_id(account.get("id"), "selected account ID")
    remote_id = provider_id(account.get("provider_account_id"), "provider account ID")
    if account_id != remote_id:
        raise PatreonAdapterError("selected Patreon account does not match the configured connection")
    campaigns = selected_campaign_ids(account.get("campaign_ids"))
    authorized = account.get("member_data_authorized")
    if not isinstance(authorized, bool):
        raise PatreonAdapterError("Patreon member-data authorization is invalid")
    if stream == "memberships" and not authorized:
        raise PatreonAdapterError("Patreon memberships require the membership-services purpose gate")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise PatreonAdapterError("Patreon page safety limit is invalid")
    selected, cursor, seen = _request_campaign(stream, campaigns, state)
    return PageRequest(stream, account_id, campaigns, selected, cursor, seen, limit, authorized)


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    expected = {
        "action", "stream", "account_id", "campaign_ids", "campaign_id",
        "cursor", "seen_cursors", "limit", "member_data_authorized",
    }
    if set(payload) != expected or payload.get("action") != "page":
        raise PatreonAdapterError("Patreon read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise PatreonAdapterError("Patreon stream is unsupported")
    account = provider_id(payload.get("account_id"), "selected account ID")
    campaigns = selected_campaign_ids(payload.get("campaign_ids"))
    selected = payload.get("campaign_id")
    if stream == "account":
        if selected is not None:
            raise PatreonAdapterError("Patreon account request cannot select a campaign")
    else:
        selected = campaign_id(selected, "request campaign ID")
        if selected not in campaigns:
            raise PatreonAdapterError("Patreon read request targets an unselected campaign")
    cursor = _optional_cursor(payload.get("cursor"), "request cursor")
    seen_value = payload.get("seen_cursors")
    if not isinstance(seen_value, list):
        raise PatreonAdapterError("Patreon request cursor history must be an array")
    seen = tuple(seen_value)
    if len(seen) > MAX_CURSOR_HISTORY or len(seen) != len(set(seen)):
        raise PatreonAdapterError("Patreon request cursor history is invalid")
    if any(not isinstance(item, str) or not re.fullmatch(r"[0-9a-f]{64}", item) for item in seen):
        raise PatreonAdapterError("Patreon request cursor history is invalid")
    if cursor is None and seen:
        raise PatreonAdapterError("Patreon request cursor history is inconsistent")
    if cursor is not None and _cursor_digest(cursor) not in seen:
        raise PatreonAdapterError("Patreon request cursor history is incomplete")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise PatreonAdapterError("Patreon page safety limit is invalid")
    authorized = payload.get("member_data_authorized")
    if not isinstance(authorized, bool) or (stream == "memberships" and not authorized):
        raise PatreonAdapterError("Patreon member-data authorization is invalid")
    return PageRequest(stream, account, campaigns, selected, cursor, seen, limit, authorized)


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise PatreonAdapterError("Patreon response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise PatreonAdapterError("Patreon page data must be an array")
    return data


def _next_campaign(request: PageRequest) -> str | None:
    if request.campaign_id is None:
        return None
    index = request.campaign_ids.index(request.campaign_id)
    return request.campaign_ids[index + 1] if index + 1 < len(request.campaign_ids) else None


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Validate cursor progress before an atomic evidence/checkpoint commit."""
    data = page_data(payload)
    if len(data) > request.limit:
        raise PatreonAdapterError("Patreon page exceeds the item safety limit")
    meta = payload.get("meta")
    expected = {"stream", "campaign_id", "next_cursor", "next_campaign_id", "complete"}
    if not isinstance(meta, dict) or set(meta) != expected or meta.get("stream") != request.stream:
        raise PatreonAdapterError("Patreon page provenance is invalid")
    reject_credentials(meta)
    if meta.get("campaign_id") != request.campaign_id:
        raise PatreonAdapterError("Patreon page campaign does not match the selected campaign")
    complete = meta.get("complete")
    if not isinstance(complete, bool):
        raise PatreonAdapterError("Patreon page completion metadata is invalid")
    next_cursor = _optional_cursor(meta.get("next_cursor"), "next cursor")
    next_campaign_value = meta.get("next_campaign_id")
    next_campaign = (
        campaign_id(next_campaign_value, "next campaign ID")
        if next_campaign_value is not None
        else None
    )
    if complete:
        if next_cursor is not None or next_campaign is not None:
            raise PatreonAdapterError("completed Patreon page cannot retain a cursor")
        return PageCheckpoint(None, state.watermark), True
    if (next_cursor is None) == (next_campaign is None):
        raise PatreonAdapterError("Patreon page requires exactly one advancing cursor")
    if next_campaign is not None:
        if next_campaign != _next_campaign(request):
            raise PatreonAdapterError("Patreon page did not advance to the next selected campaign")
        return PageCheckpoint(_encode_cursor(next_campaign, None, ()), state.watermark), False
    assert next_cursor is not None
    digest = _cursor_digest(next_cursor)
    if digest in request.seen_cursors:
        raise PatreonAdapterError("Patreon pagination cursor loop was detected")
    if len(request.seen_cursors) >= MAX_CURSOR_HISTORY:
        raise PatreonAdapterError("Patreon pagination exceeds the cursor history safety limit")
    seen = (*request.seen_cursors, digest)
    assert request.campaign_id is not None
    return PageCheckpoint(
        _encode_cursor(request.campaign_id, next_cursor, seen), state.watermark
    ), False
