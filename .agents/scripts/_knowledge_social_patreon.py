#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Patreon creator identity, stream policy, and opaque cursor checkpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_patreon_cursor import (
    cursor_digest,
    decode_cursor,
    encode_cursor,
    optional_cursor,
    validate_cursor_history,
)
from _knowledge_social_patreon_types import (
    MAX_CURSOR_HISTORY,
    PROVIDER,
    RETENTION_LIMIT,
    PatreonAdapterError,
    PatreonProviderUnavailableError,
    campaign_id,
    provider_id,
    selected_campaign_ids,
)
from knowledge_social_import import canonical_json, reject_credentials


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
    selected, cursor, seen = decode_cursor(state.cursor)
    if selected not in campaigns:
        raise PatreonAdapterError("stored Patreon cursor targets an unselected campaign")
    return selected, cursor, seen


def _account_binding(account: dict[str, Any]) -> tuple[str, tuple[str, ...]]:
    account_id = provider_id(account.get("id"), "selected account ID")
    remote_id = provider_id(account.get("provider_account_id"), "provider account ID")
    if account_id != remote_id:
        raise PatreonAdapterError("selected Patreon account does not match the configured connection")
    return account_id, selected_campaign_ids(account.get("campaign_ids"))


def _page_limit(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 100:
        raise PatreonAdapterError("Patreon page safety limit is invalid")
    return value


def _member_authorization(stream: str, value: Any) -> bool:
    if not isinstance(value, bool):
        raise PatreonAdapterError("Patreon member-data authorization is invalid")
    if stream == "memberships" and not value:
        raise PatreonAdapterError("Patreon memberships require the membership-services purpose gate")
    return value


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    """Build one request from an independent per-stream checkpoint."""
    if stream not in STREAMS:
        raise PatreonAdapterError("Patreon stream is unsupported")
    account_id, campaigns = _account_binding(account)
    authorized = _member_authorization(stream, account.get("member_data_authorized"))
    page_limit = _page_limit(limit)
    selected, cursor, seen = _request_campaign(stream, campaigns, state)
    return PageRequest(stream, account_id, campaigns, selected, cursor, seen, page_limit, authorized)


def _request_target(
    stream: str, payload: dict[str, Any], campaigns: tuple[str, ...]
) -> str | None:
    selected = payload.get("campaign_id")
    if stream == "account":
        if selected is not None:
            raise PatreonAdapterError("Patreon account request cannot select a campaign")
        return None
    selected_id = campaign_id(selected, "request campaign ID")
    if selected_id not in campaigns:
        raise PatreonAdapterError("Patreon read request targets an unselected campaign")
    return selected_id


def _request_history(payload: dict[str, Any], cursor: str | None) -> tuple[str, ...]:
    return validate_cursor_history(
        payload.get("seen_cursors"), cursor, "request cursor history"
    )


def _request_stream(payload: dict[str, Any]) -> str:
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise PatreonAdapterError("Patreon stream is unsupported")
    return stream


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    expected = {
        "action", "stream", "account_id", "campaign_ids", "campaign_id",
        "cursor", "seen_cursors", "limit", "member_data_authorized",
    }
    if set(payload) != expected or payload.get("action") != "page":
        raise PatreonAdapterError("Patreon read request has an invalid action shape")
    stream = _request_stream(payload)
    account = provider_id(payload.get("account_id"), "selected account ID")
    campaigns = selected_campaign_ids(payload.get("campaign_ids"))
    selected = _request_target(stream, payload, campaigns)
    cursor = optional_cursor(payload.get("cursor"), "request cursor")
    seen = _request_history(payload, cursor)
    limit = _page_limit(payload.get("limit"))
    authorized = _member_authorization(stream, payload.get("member_data_authorized"))
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


def _checkpoint_meta(
    payload: dict[str, Any], request: PageRequest
) -> tuple[bool, str | None, str | None]:
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
    next_cursor = optional_cursor(meta.get("next_cursor"), "next cursor")
    next_campaign_value = meta.get("next_campaign_id")
    next_campaign = (
        campaign_id(next_campaign_value, "next campaign ID")
        if next_campaign_value is not None
        else None
    )
    return complete, next_cursor, next_campaign


def _advancing_checkpoint(
    request: PageRequest,
    state: CursorState,
    next_cursor: str | None,
    next_campaign: str | None,
) -> PageCheckpoint:
    if (next_cursor is None) == (next_campaign is None):
        raise PatreonAdapterError("Patreon page requires exactly one advancing cursor")
    if next_campaign is not None:
        if next_campaign != _next_campaign(request):
            raise PatreonAdapterError("Patreon page did not advance to the next selected campaign")
        return PageCheckpoint(encode_cursor(next_campaign, None, ()), state.watermark)
    if next_cursor is None or request.campaign_id is None:
        raise PatreonAdapterError("Patreon page cursor lost its selected campaign")
    digest = cursor_digest(next_cursor)
    if digest in request.seen_cursors:
        raise PatreonAdapterError("Patreon pagination cursor loop was detected")
    if len(request.seen_cursors) >= MAX_CURSOR_HISTORY:
        raise PatreonAdapterError("Patreon pagination exceeds the cursor history safety limit")
    seen = (*request.seen_cursors, digest)
    return PageCheckpoint(
        encode_cursor(request.campaign_id, next_cursor, seen), state.watermark
    )


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Validate cursor progress before an atomic evidence/checkpoint commit."""
    if len(page_data(payload)) > request.limit:
        raise PatreonAdapterError("Patreon page exceeds the item safety limit")
    complete, next_cursor, next_campaign = _checkpoint_meta(payload, request)
    if complete:
        if next_cursor is not None or next_campaign is not None:
            raise PatreonAdapterError("completed Patreon page cannot retain a cursor")
        return PageCheckpoint(None, state.watermark), True
    return _advancing_checkpoint(request, state, next_cursor, next_campaign), False
