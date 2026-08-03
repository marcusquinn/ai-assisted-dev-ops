#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hashnode stream policy and opaque GraphQL connection checkpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_hashnode_identity import (
    HashnodeAdapterError,
    HashnodeProviderUnavailableError,
    instance_id,
    provider_account_id,
    username,
)
from _knowledge_social_oauth_request import OAuthPageRequest, OAuthRequestCodec
from knowledge_social_import import reject_credentials

PROVIDER = "hashnode"
CURSOR_PREFIX = "hashnode-page-v1:"
RETENTION_LIMIT = "account_active_or_provider_visibility_and_pro_plan_bound"
MAX_PAGE_ITEMS = 50

ADAPTER_ERROR = HashnodeAdapterError
PROVIDER_UNAVAILABLE_ERROR = HashnodeProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    transport: str = "graphql"
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "current_api_visibility_and_plan_bound"
    cost_units: int = 2


STREAMS = {
    "profile": StreamSpec("profile", "selected_account"),
    "publications": StreamSpec("publication", "publication_owner"),
    "posts": StreamSpec("post", "content_author"),
    "drafts": StreamSpec("draft", "content_author"),
    "comments": StreamSpec("comment", "comment_received"),
    "reactions": StreamSpec("reaction", "reaction_received"),
    "followers": StreamSpec("account", "follower"),
    "following": StreamSpec("account", "following"),
}


class PageRequest(OAuthPageRequest):
    HANDLE_KEY = "username"

    @property
    def username(self) -> str:
        return self.handle


REQUEST_CODEC = OAuthRequestCodec(
    display_name="Hashnode",
    cursor_prefix=CURSOR_PREFIX,
    cursor_key="state",
    handle_key=PageRequest.HANDLE_KEY,
    max_page_size=MAX_PAGE_ITEMS,
    max_text_bytes=64 * 1024,
    streams=frozenset(STREAMS),
    request_type=PageRequest,
    error_type=HashnodeAdapterError,
    account_validator=provider_account_id,
    handle_validator=username,
    instance_validator=instance_id,
)
PAGE_REQUEST_KEYS = REQUEST_CODEC.request_keys


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    request = REQUEST_CODEC.collection_request(stream, account, state.cursor, limit)
    if not isinstance(request, PageRequest):
        raise HashnodeAdapterError("Hashnode request codec returned an invalid type")
    return request


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    request = REQUEST_CODEC.provider_request(payload)
    if not isinstance(request, PageRequest):
        raise HashnodeAdapterError("Hashnode request codec returned an invalid type")
    return request


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise HashnodeAdapterError("Hashnode response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise HashnodeAdapterError("Hashnode page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise HashnodeAdapterError("Hashnode page metadata must be an object")
    reject_credentials(meta)
    if (
        meta.get("stream") != request.stream
        or instance_id(meta.get("instance_id")) != request.instance_id
        or meta.get("transport") != "graphql"
        or meta.get("snapshot") is not True
    ):
        raise HashnodeAdapterError("Hashnode page provenance is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise HashnodeAdapterError("Hashnode page exceeds the item safety limit")
    next_state = REQUEST_CODEC.text(
        meta.get("next_cursor"), "next cursor", optional=True
    )
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_state is not None):
        raise HashnodeAdapterError("Hashnode page completion cursor is invalid")
    cursor = (
        REQUEST_CODEC.encode_cursor(request.position + 1, next_state)
        if next_state
        else None
    )
    return PageCheckpoint(cursor, state.watermark), complete
