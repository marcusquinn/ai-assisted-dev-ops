#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""LinkedIn Member Snapshot stream policy and durable checkpoints."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "linkedin"
API_VERSION = "202312"
CURSOR_PREFIX = "linkedin-snapshot-v1:"
MEMBER_ID = re.compile(r"^[A-Za-z0-9_-]{3,128}$")
PORTABILITY_RETENTION = (
    "member_consent_and_delete_on_request_or_linked_account_closure"
)


class LinkedInAdapterError(SocialStoreError):
    """Raised when guarded LinkedIn collection cannot continue safely."""


class LinkedInProviderUnavailableError(LinkedInAdapterError):
    """Raised when the bounded LinkedIn OAuth child cannot complete a read."""


ADAPTER_ERROR = LinkedInAdapterError
PROVIDER_UNAVAILABLE_ERROR = LinkedInProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static policy for one documented Member Snapshot domain."""

    snapshot_domain: str
    resource_kind: str
    activity_mode: str
    retention_limit: str | None = PORTABILITY_RETENTION
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


STREAMS = {
    "authored_posts": StreamSpec("MEMBER_SHARE_INFO", "post", "content_author"),
    "authored_articles": StreamSpec("ARTICLES", "article", "content_author"),
    "comments": StreamSpec("ALL_COMMENTS", "comment", "content_author"),
    "reactions": StreamSpec("ALL_LIKES", "reaction", "selected_account"),
    "saved_items": StreamSpec("ACTOR_SAVE_ITEM", "saved_item", "selected_account"),
    "messages": StreamSpec("INBOX", "message", "selected_account"),
    "following": StreamSpec("MEMBER_FOLLOWING", "member_follow", "selected_account"),
    "connections": StreamSpec("CONNECTIONS", "connection", "selected_account"),
    "company_follows": StreamSpec(
        "COMPANY_FOLLOWS", "company_follow", "selected_account"
    ),
    "groups": StreamSpec("GROUPS", "group_membership", "selected_account"),
}


@dataclass(frozen=True)
class PageRequest:
    """One allowlisted, bounded Member Snapshot request."""

    stream: str
    account_id: str
    domain: str
    start: int
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "domain": self.domain,
            "start": self.start,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def member_id(value: Any, field: str) -> str:
    """Validate the opaque token portion of a LinkedIn member URN."""
    if not isinstance(value, str) or MEMBER_ID.fullmatch(value) is None:
        raise LinkedInAdapterError(f"LinkedIn {field} must be a stable member ID")
    return value


def _decode_cursor(cursor: str) -> int:
    if not cursor.startswith(CURSOR_PREFIX):
        raise LinkedInAdapterError("stored LinkedIn cursor has an unsupported version")
    value = cursor.removeprefix(CURSOR_PREFIX)
    if not value.isascii() or not value.isdigit():
        raise LinkedInAdapterError("stored LinkedIn cursor is invalid")
    start = int(value)
    if start <= 0 or start > 1_000_000_000:
        raise LinkedInAdapterError("stored LinkedIn cursor is outside the safety limit")
    return start


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one snapshot request from durable per-stream state."""
    spec = STREAMS[stream]
    account_id = member_id(account.get("id"), "account ID")
    start = _decode_cursor(state.cursor) if state.cursor else 0
    return PageRequest(stream, account_id, spec.snapshot_domain, start, limit)


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a LinkedIn response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise LinkedInAdapterError("LinkedIn response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated Member Snapshot record array."""
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise LinkedInAdapterError("LinkedIn snapshot data must be an array of objects")
    reject_credentials(data)
    return data


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate the next resumable Member Snapshot page."""
    del state
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise LinkedInAdapterError("LinkedIn page metadata must be an object")
    reject_credentials(meta)
    if meta.get("domain") != request.domain or meta.get("snapshot") is not True:
        raise LinkedInAdapterError("LinkedIn page domain metadata is invalid")
    complete = meta.get("complete")
    next_start = meta.get("next_start")
    if not isinstance(complete, bool):
        raise LinkedInAdapterError("LinkedIn page completion metadata is invalid")
    if next_start is not None:
        if isinstance(next_start, bool) or not isinstance(next_start, int):
            raise LinkedInAdapterError("LinkedIn next page is invalid")
        if next_start <= request.start or next_start > 1_000_000_000:
            raise LinkedInAdapterError("LinkedIn next page is invalid")
    if complete == (next_start is not None):
        message = (
            "complete LinkedIn page cannot have a next cursor"
            if complete
            else "partial LinkedIn page requires a next cursor"
        )
        raise LinkedInAdapterError(message)
    cursor = f"{CURSOR_PREFIX}{next_start}" if next_start is not None else None
    return PageCheckpoint(cursor, None), complete
