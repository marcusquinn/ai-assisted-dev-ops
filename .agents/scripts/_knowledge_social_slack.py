#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Slack stream policy, workspace identity, selectors, and checkpoints."""

from __future__ import annotations

import base64
import json
import re
from collections.abc import Iterator, Mapping
from dataclasses import asdict, dataclass
from decimal import Decimal, InvalidOperation
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
# Same-name imports define the stable Slack policy facade for provider modules.
from _knowledge_social_slack_identity import (  # pylint: disable=unused-import
    ALIAS as ALIAS,
    CONVERSATION_KINDS as CONVERSATION_KINDS,
    TOKEN_TYPES as TOKEN_TYPES,
    SlackAdapterError as SlackAdapterError,
    SlackProviderUnavailableError as SlackProviderUnavailableError,
    account_id as account_id,
    conversation_binding_sha256 as conversation_binding_sha256,
    conversation_id as conversation_id,
    enterprise_id as enterprise_id,
    namespaced_id as namespaced_id,
    parse_account_id as parse_account_id,
    slack_timestamp as slack_timestamp,
    team_id as team_id,
    token_type as token_type,
    user_id as user_id,
)
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from knowledge_social_import import canonical_json

PROVIDER = "slack"
CURSOR_PREFIX = "slack-v1:"
RETENTION_LIMIT = "workspace_plan_retention_membership_and_token_visibility"
HISTORY_OVERLAP_SECONDS = Decimal(7 * 24 * 60 * 60)
MAX_CURSOR_BYTES = 4096
MAX_SNAPSHOT_ITEMS = 100
MAX_EXPANDED_RECORDS_PER_ITEM = 101
CONVERSATION_STREAM = re.compile(
    r"^conversation/([a-z0-9][a-z0-9_-]{0,31})/"
    r"(info|members|history|pins|bookmarks|files)$"
)
THREAD_STREAM = re.compile(
    r"^conversation/([a-z0-9][a-z0-9_-]{0,31})/thread/"
    r"([0-9]{1,16}\.[0-9]{6})$"
)


ADAPTER_ERROR = SlackAdapterError
PROVIDER_UNAVAILABLE_ERROR = SlackProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one logical Slack stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


@dataclass(frozen=True)
class StreamSelector:
    """Validated provider selector encoded by one durable stream key."""

    kind: str
    alias: str | None = None
    thread_ts: str | None = None


STATIC_SPECS = {
    "workspace": StreamSpec("workspace", "workspace_metadata", "snapshot", False),
    "users": StreamSpec(
        "user", "workspace_member", "cursor", False, coverage_status="partial",
        unavailable_reason="profile_fields_and_guests_depend_on_token_visibility",
    ),
    "reactions": StreamSpec(
        "reaction", "selected_account", "cursor", False,
        coverage_status="partial",
        unavailable_reason=(
            "selected_account_reactions_truncated_actor_lists_and_unreconciled_removals_only"
        ),
    ),
}

DYNAMIC_SPECS = {
    "info": StreamSpec("conversation", "conversation_metadata", "snapshot", False),
    "members": StreamSpec(
        "membership", "conversation_member", "cursor", False,
        coverage_status="partial",
        unavailable_reason=(
            "membership_is_token_visible_and_removed_members_are_not_reconciled"
        ),
    ),
    "history": StreamSpec(
        "message", "message", "cursor", True, coverage_status="partial",
        unavailable_reason="retention_and_seven_day_edit_overlap_bound_history",
    ),
    "thread": StreamSpec(
        "message", "thread_reply", "cursor", True, coverage_status="partial",
        unavailable_reason="retention_token_type_and_edit_overlap_bound_replies",
    ),
    "pins": StreamSpec(
        "pin", "pin", "snapshot", False, coverage_status="partial",
        unavailable_reason="snapshot_is_capped_at_100_items_and_removals_are_not_reconciled",
    ),
    "bookmarks": StreamSpec(
        "bookmark", "bookmark", "snapshot", False, coverage_status="partial",
        unavailable_reason="snapshot_is_capped_at_100_items_and_removals_are_not_reconciled",
    ),
    "files": StreamSpec(
        "file", "file_share", "page", False, coverage_status="partial",
        unavailable_reason=(
            "file_metadata_only_binary_hydration_disabled_and_removals_are_not_reconciled"
        ),
    ),
}


def parse_stream(value: Any) -> StreamSelector:
    """Parse one static or allowlisted conversation-scoped stream key."""
    if value in STATIC_SPECS:
        return StreamSelector(str(value))
    if not isinstance(value, str) or len(value) > 127 or "\x00" in value:
        raise SlackAdapterError("Slack stream is unsupported")
    match = CONVERSATION_STREAM.fullmatch(value)
    if match is not None:
        return StreamSelector(match.group(2), match.group(1))
    match = THREAD_STREAM.fullmatch(value)
    if match is not None:
        return StreamSelector("thread", match.group(1), match.group(2))
    raise SlackAdapterError("Slack stream is unsupported")


class SlackStreamRegistry(Mapping[str, StreamSpec]):
    """Resolve dynamic conversation selectors without widening shared contracts."""

    def __getitem__(self, key: str) -> StreamSpec:
        selector = parse_stream(key)
        if selector.kind in STATIC_SPECS:
            return STATIC_SPECS[selector.kind]
        return DYNAMIC_SPECS[selector.kind]

    def __iter__(self) -> Iterator[str]:
        return iter(STATIC_SPECS)

    def __len__(self) -> int:
        return len(STATIC_SPECS)

    def __contains__(self, key: object) -> bool:
        try:
            parse_stream(key)
        except SlackAdapterError:
            return False
        return True


STREAMS: Mapping[str, StreamSpec] = SlackStreamRegistry()


def _cursor_text(value: Any, field: str, *, optional: bool = True) -> str | None:
    if value is None and optional:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode("utf-8")) > MAX_CURSOR_BYTES
    ):
        raise SlackAdapterError(f"Slack {field} is invalid")
    return value


def _encode_cursor(cursor: str, oldest: str | None) -> str:
    payload = canonical_json({"cursor": cursor, "oldest": oldest}).encode("utf-8")
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(value: str) -> tuple[str, str | None]:
    if not value.startswith(CURSOR_PREFIX):
        raise SlackAdapterError("stored Slack cursor has an unsupported version")
    encoded = value.removeprefix(CURSOR_PREFIX)
    try:
        parsed = json.loads(
            base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        )
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise SlackAdapterError("stored Slack cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"cursor", "oldest"}:
        raise SlackAdapterError("stored Slack cursor has an invalid shape")
    reject_slack_credentials(parsed)
    return (
        _cursor_text(parsed["cursor"], "cursor", optional=False) or "",
        (
            slack_timestamp(parsed["oldest"], "cursor oldest timestamp")
            if parsed["oldest"] is not None
            else None
        ),
    )


def _overlap_oldest(watermark: str | None) -> str | None:
    if watermark is None:
        return None
    timestamp = slack_timestamp(watermark, "watermark")
    try:
        value = max(Decimal(timestamp) - HISTORY_OVERLAP_SECONDS, Decimal(0))
    except InvalidOperation as error:
        raise SlackAdapterError("stored Slack watermark is invalid") from error
    return f"{value:.6f}"


@dataclass(frozen=True)
class PageRequest:
    """One allowlisted request passed to the isolated Slack reader."""

    stream: str
    account_id: str
    provider_account_id: str
    workspace_id: str
    enterprise_id: str | None
    selector: str
    conversation_alias: str | None
    thread_ts: str | None
    cursor: str | None
    oldest: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {"action": "page", **asdict(self)}

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = set(PageRequest.__dataclass_fields__) | {"action"}


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    """Build one request from a durable workspace/conversation stream state."""
    selector = parse_stream(stream)
    selected_id = account.get("id")
    if not isinstance(selected_id, str):
        raise SlackAdapterError("verified Slack identity is incomplete")
    workspace, selected_user = parse_account_id(selected_id)
    if workspace != team_id(account.get("workspace_id")):
        raise SlackAdapterError("verified Slack workspace identity is inconsistent")
    if selected_user != user_id(account.get("provider_account_id")):
        raise SlackAdapterError("verified Slack account identity is inconsistent")
    cursor: str | None = None
    oldest: str | None = None
    if state.cursor:
        cursor, oldest = _decode_cursor(state.cursor)
    elif STREAMS[stream].incremental and state.backfill_complete:
        oldest = _overlap_oldest(state.watermark)
    return PageRequest(
        stream,
        selected_id,
        selected_user,
        workspace,
        enterprise_id(account.get("enterprise_id")),
        selector.kind,
        selector.alias,
        selector.thread_ts,
        cursor,
        oldest,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise SlackAdapterError("Slack read request has an invalid action shape")
    stream = payload.get("stream")
    selector = parse_stream(stream)
    if payload.get("selector") != selector.kind:
        raise SlackAdapterError("Slack stream selector is inconsistent")
    if payload.get("conversation_alias") != selector.alias:
        raise SlackAdapterError("Slack conversation selector is inconsistent")
    if payload.get("thread_ts") != selector.thread_ts:
        raise SlackAdapterError("Slack thread selector is inconsistent")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 15:
        raise SlackAdapterError("Slack page size must be between 1 and 15")
    selected = payload.get("account_id")
    workspace, selected_user = parse_account_id(selected)
    if team_id(payload.get("workspace_id")) != workspace:
        raise SlackAdapterError("Slack request workspace identity is inconsistent")
    if user_id(payload.get("provider_account_id")) != selected_user:
        raise SlackAdapterError("Slack request account identity is inconsistent")
    cursor = _cursor_text(payload.get("cursor"), "cursor")
    oldest = payload.get("oldest")
    if oldest is not None:
        oldest = slack_timestamp(oldest, "oldest timestamp")
    return PageRequest(
        str(stream),
        str(selected),
        selected_user,
        workspace,
        enterprise_id(payload.get("enterprise_id")),
        selector.kind,
        selector.alias,
        selector.thread_ts,
        cursor,
        oldest,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise SlackAdapterError("Slack response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise SlackAdapterError("Slack page data must be an array of objects")
    reject_slack_credentials(data)
    return data


def _metadata(payload: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise SlackAdapterError("Slack page metadata must be an object")
    reject_slack_credentials(meta)
    expected = {
        "stream",
        "selector",
        "workspace_id",
        "next_cursor",
        "newest_ts",
        "complete",
        "source",
    }
    if set(meta) != expected:
        raise SlackAdapterError("Slack page metadata has an invalid shape")
    if (
        meta.get("stream") != request.stream
        or meta.get("selector") != request.selector
        or team_id(meta.get("workspace_id")) != request.workspace_id
        or meta.get("source") != "slack_web_api"
    ):
        raise SlackAdapterError("Slack page provenance is invalid")
    return meta


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic per-workspace, per-conversation stream checkpoint."""
    meta = _metadata(payload, request)
    next_cursor = _cursor_text(meta.get("next_cursor"), "next cursor")
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete != (next_cursor is None):
        raise SlackAdapterError("Slack page completion cursor is invalid")
    if next_cursor is not None and next_cursor == request.cursor:
        raise SlackAdapterError("Slack page cursor did not advance")
    item_limit = request.limit
    if request.selector in {"pins", "bookmarks"}:
        item_limit = MAX_SNAPSHOT_ITEMS
    elif request.selector in {"workspace", "info"}:
        item_limit = 1
    elif request.selector in {"history", "thread", "reactions"}:
        item_limit = request.limit * MAX_EXPANDED_RECORDS_PER_ITEM
    if len(page_data(payload)) > item_limit:
        raise SlackAdapterError("Slack page exceeds the item safety limit")
    newest = meta.get("newest_ts")
    if newest is not None:
        newest = slack_timestamp(newest, "newest timestamp")
    watermark = state.watermark
    if newest is not None and (watermark is None or Decimal(newest) > Decimal(watermark)):
        watermark = newest
    encoded = _encode_cursor(next_cursor, request.oldest) if next_cursor else None
    return PageCheckpoint(encoded, watermark), complete
