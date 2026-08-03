#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mastodon stream policy, instance identity, and opaque Link checkpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_mastodon_identity import (
    MastodonAdapterError,
    MastodonProviderUnavailableError,
    account_handle,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_oauth_request import OAuthPageRequest, OAuthRequestCodec
from knowledge_social_import import reject_credentials

PROVIDER = "mastodon"
CURSOR_PREFIX = "mastodon-link-v1:"
RETENTION_LIMIT = "instance_policy_federation_and_current_account_visibility"
MAX_PAGE_ITEMS = 100
ACCOUNT_AUTH_MODE = "user_token"

ADAPTER_ERROR = MastodonAdapterError
PROVIDER_UNAVAILABLE_ERROR = MastodonProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "instance_policy_and_federation_bound"
    cost_units: int = 2


STREAMS = {
    "authored_statuses": StreamSpec("status", "content_author"),
    "favourites": StreamSpec("status", "selected_account"),
    "bookmarks": StreamSpec("status", "selected_account"),
    "notifications": StreamSpec("notification", "selected_account"),
    "followers": StreamSpec("account", "relationship"),
    "following": StreamSpec("account", "relationship"),
    "followed_tags": StreamSpec("tag", "selected_account"),
    "lists": StreamSpec("list", "selected_account"),
}


class PageRequest(OAuthPageRequest):
    """Allowlisted request carrying an opaque next-link in stop_at."""

    HANDLE_KEY = "acct"

    @property
    def acct(self) -> str:
        return self.handle


REQUEST_CODEC = OAuthRequestCodec(
    display_name="Mastodon",
    cursor_prefix=CURSOR_PREFIX,
    cursor_key="next_url",
    handle_key=PageRequest.HANDLE_KEY,
    max_page_size=MAX_PAGE_ITEMS,
    max_text_bytes=8192,
    streams=frozenset(STREAMS),
    request_type=PageRequest,
    error_type=MastodonAdapterError,
    account_validator=provider_account_id,
    handle_validator=account_handle,
    instance_validator=instance_id,
)
PAGE_REQUEST_KEYS = REQUEST_CODEC.request_keys


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    request = REQUEST_CODEC.collection_request(stream, account, state.cursor, limit)
    if not isinstance(request, PageRequest):
        raise MastodonAdapterError("Mastodon request codec returned an invalid type")
    return request


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    request = REQUEST_CODEC.provider_request(payload)
    if not isinstance(request, PageRequest):
        raise MastodonAdapterError("Mastodon request codec returned an invalid type")
    return request


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise MastodonAdapterError("Mastodon response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise MastodonAdapterError("Mastodon page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise MastodonAdapterError("Mastodon page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or instance_id(meta.get("instance_id")) != request.instance_id:
        raise MastodonAdapterError("Mastodon page provenance is invalid")
    if meta.get("snapshot") is not True:
        raise MastodonAdapterError("Mastodon page pagination metadata is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise MastodonAdapterError("Mastodon page exceeds the item safety limit")
    next_url = REQUEST_CODEC.text(meta.get("next_url"), "next link", optional=True)
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_url is not None):
        raise MastodonAdapterError("Mastodon page completion cursor is invalid")
    cursor = (
        REQUEST_CODEC.encode_cursor(request.position + 1, next_url)
        if next_url
        else None
    )
    return PageCheckpoint(cursor, state.watermark), complete
