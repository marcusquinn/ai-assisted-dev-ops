#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GitHub stream policy, durable identity, and opaque mixed-API checkpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_github_identity import (
    GitHubAdapterError,
    GitHubProviderUnavailableError,
    instance_id,
    login,
    provider_account_id,
)
from _knowledge_social_oauth_request import OAuthPageRequest, OAuthRequestCodec
from knowledge_social_import import reject_credentials

PROVIDER = "github"
CURSOR_PREFIX = "github-page-v1:"
RETENTION_LIMIT = "token_capability_and_current_resource_visibility"
MAX_PAGE_ITEMS = 100

ADAPTER_ERROR = GitHubAdapterError
PROVIDER_UNAVAILABLE_ERROR = GitHubProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    transport: str
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "token_capability_and_visibility_bound"
    cost_units: int = 3


STREAMS = {
    "contributions": StreamSpec("contribution", "content_author", "graphql"),
    "repositories": StreamSpec("repository", "selected_account", "rest"),
    "stars": StreamSpec("repository", "selected_account", "rest"),
    "notifications": StreamSpec("notification", "selected_account", "rest"),
    "followers": StreamSpec("account", "relationship", "rest"),
    "following": StreamSpec("account", "relationship", "rest"),
    "organizations": StreamSpec("organization", "membership", "rest"),
    "subscriptions": StreamSpec("repository", "selected_account", "rest"),
    "user_lists": StreamSpec("user_list", "selected_account", "graphql"),
    "projects_v2": StreamSpec("project", "selected_account", "graphql"),
}


class PageRequest(OAuthPageRequest):
    HANDLE_KEY = "login"

    @property
    def login(self) -> str:
        return self.handle


REQUEST_CODEC = OAuthRequestCodec(
    display_name="GitHub",
    cursor_prefix=CURSOR_PREFIX,
    cursor_key="cursor",
    handle_key=PageRequest.HANDLE_KEY,
    max_page_size=MAX_PAGE_ITEMS,
    max_text_bytes=16 * 1024,
    streams=frozenset(STREAMS),
    request_type=PageRequest,
    error_type=GitHubAdapterError,
    account_validator=provider_account_id,
    handle_validator=login,
    instance_validator=instance_id,
)
PAGE_REQUEST_KEYS = REQUEST_CODEC.request_keys


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    request = REQUEST_CODEC.collection_request(stream, account, state.cursor, limit)
    if not isinstance(request, PageRequest):
        raise GitHubAdapterError("GitHub request codec returned an invalid type")
    return request


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    request = REQUEST_CODEC.provider_request(payload)
    if not isinstance(request, PageRequest):
        raise GitHubAdapterError("GitHub request codec returned an invalid type")
    return request


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise GitHubAdapterError("GitHub response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise GitHubAdapterError("GitHub page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise GitHubAdapterError("GitHub page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or instance_id(meta.get("instance_id")) != request.instance_id:
        raise GitHubAdapterError("GitHub page provenance is invalid")
    if meta.get("snapshot") is not True or meta.get("transport") != STREAMS[request.stream].transport:
        raise GitHubAdapterError("GitHub page pagination metadata is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise GitHubAdapterError("GitHub page exceeds the item safety limit")
    next_cursor = REQUEST_CODEC.text(
        meta.get("next_cursor"), "next cursor", optional=True
    )
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_cursor is not None):
        raise GitHubAdapterError("GitHub page completion cursor is invalid")
    cursor = (
        REQUEST_CODEC.encode_cursor(request.position + 1, next_cursor)
        if next_cursor
        else None
    )
    return PageCheckpoint(cursor, state.watermark), complete
