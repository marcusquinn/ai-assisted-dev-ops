#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted conversation-specific Slack API routes."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from _knowledge_social_slack import PageRequest, slack_timestamp
from _knowledge_social_slack_contract import (
    SlackReadProviderError,
    non_negative_integer,
    object_list,
    object_value,
)
from _knowledge_social_slack_records import (
    bookmark_record,
    conversation_record,
    file_records_for_conversation,
    membership_records,
    message_record,
    newest_message_ts,
    pin_record,
)
from _knowledge_social_slack_route_types import (
    Api,
    ConversationTarget,
    PageResult,
    next_cursor,
    page_payload,
    require_scope,
    verified_result,
)

KIND_READ_SCOPE = {
    "public_channel": "channels:read",
    "private_channel": "groups:read",
    "im": "im:read",
    "mpim": "mpim:read",
}
KIND_HISTORY_SCOPE = {
    "public_channel": "channels:history",
    "private_channel": "groups:history",
    "im": "im:history",
    "mpim": "mpim:history",
}
SnapshotRecord = Callable[[dict[str, Any], str, str], dict[str, Any]]


@dataclass(frozen=True)
class SnapshotRoute:
    scope: str
    endpoint: str
    channel_key: str
    response_key: str
    label: str
    record: SnapshotRecord


SNAPSHOT_ROUTES = {
    "pins": SnapshotRoute("pins:read", "pins.list", "channel", "items", "pins", pin_record),
    "bookmarks": SnapshotRoute(
        "bookmarks:read",
        "bookmarks.list",
        "channel_id",
        "bookmarks",
        "bookmarks",
        bookmark_record,
    ),
}


def _target(
    request: PageRequest, conversations: dict[str, ConversationTarget]
) -> ConversationTarget:
    alias = request.conversation_alias
    if alias is None or alias not in conversations:
        raise SlackReadProviderError("Slack conversation is not allowlisted")
    target = conversations[alias]
    if target.alias != alias:
        raise SlackReadProviderError("Slack conversation alias was rebound")
    return target


def _conversation_info(
    api: Api, request: PageRequest, identity: dict[str, Any], target: ConversationTarget
) -> PageResult:
    require_scope(identity, KIND_READ_SCOPE[target.kind])
    result = verified_result(
        api("conversations.info", {"channel": target.conversation_id}), identity
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "conversation response")
    record = conversation_record(
        root.get("channel"), request.workspace_id, target.conversation_id, target.kind
    )
    return page_payload(request, [record], None)


def _members(
    api: Api, request: PageRequest, identity: dict[str, Any], target: ConversationTarget
) -> PageResult:
    require_scope(identity, KIND_READ_SCOPE[target.kind])
    params = {"channel": target.conversation_id, "limit": str(request.limit)}
    if request.cursor:
        params["cursor"] = request.cursor
    result = verified_result(api("conversations.members", params), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, "conversation members response")
    records = membership_records(
        root.get("members"), request.workspace_id, target.conversation_id, request.limit
    )
    return page_payload(request, records, next_cursor(root))


def _message_request(
    request: PageRequest, target: ConversationTarget
) -> tuple[str, dict[str, str]]:
    endpoint = "conversations.history"
    params = {"channel": target.conversation_id, "limit": str(request.limit)}
    if request.selector == "thread":
        endpoint = "conversations.replies"
        if request.thread_ts is None:
            raise SlackReadProviderError("Slack thread timestamp is missing")
        params["ts"] = request.thread_ts
    if request.cursor:
        params["cursor"] = request.cursor
    if request.oldest:
        params.update({"oldest": request.oldest, "inclusive": "true"})
    return endpoint, params


def _validate_thread_message(message: dict[str, Any], expected: str) -> None:
    message_ts = slack_timestamp(message.get("ts"), "thread message timestamp")
    thread_value = message.get("thread_ts")
    if message_ts == expected:
        if thread_value is None:
            return
        if slack_timestamp(thread_value, "thread timestamp") != expected:
            raise SlackReadProviderError(
                "Slack thread response contains a rebound root"
            )
        return
    if thread_value is None:
        raise SlackReadProviderError(
            "Slack thread response contains an unrelated message"
        )
    if slack_timestamp(thread_value, "thread timestamp") != expected:
        raise SlackReadProviderError(
            "Slack thread response contains an unrelated message"
        )


def _validate_thread_response(
    request: PageRequest, messages: list[dict[str, Any]]
) -> None:
    if request.selector != "thread":
        return
    expected = slack_timestamp(request.thread_ts, "requested thread timestamp")
    for message in messages:
        _validate_thread_message(message, expected)


def _messages(
    api: Api, request: PageRequest, identity: dict[str, Any], target: ConversationTarget
) -> PageResult:
    require_scope(identity, KIND_HISTORY_SCOPE[target.kind])
    endpoint, params = _message_request(request, target)
    result = verified_result(api(endpoint, params), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, "conversation messages response")
    messages = object_list(root.get("messages"), "messages", limit=request.limit)
    _validate_thread_response(request, messages)
    records = [
        record
        for message in messages
        for record in message_record(message, request.workspace_id, target.conversation_id)
    ]
    return page_payload(request, records, next_cursor(root), newest_message_ts(records))


def _snapshot(
    api: Api,
    request: PageRequest,
    identity: dict[str, Any],
    target: ConversationTarget,
    route: SnapshotRoute,
) -> PageResult:
    require_scope(identity, route.scope)
    params = {route.channel_key: target.conversation_id}
    result = verified_result(api(route.endpoint, params), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, f"{route.label} response")
    items = object_list(root.get(route.response_key), route.label, limit=100)
    records = [
        route.record(item, request.workspace_id, target.conversation_id)
        for item in items
    ]
    return page_payload(request, records, None)


def _file_page(cursor: str | None) -> int:
    if cursor is None:
        return 1
    if not cursor.startswith("page:") or not cursor[5:].isdigit():
        raise SlackReadProviderError("Slack file page cursor is invalid")
    page_number = int(cursor[5:])
    if not 1 <= page_number <= 1_000_000:
        raise SlackReadProviderError("Slack file page cursor is outside the safety limit")
    return page_number


def _next_file_cursor(root: dict[str, Any], page_number: int) -> str | None:
    paging = object_value(root.get("paging", {}), "file paging")
    pages = non_negative_integer(paging.get("pages", 1), "file page count") or 1
    current = non_negative_integer(paging.get("page", page_number), "file page") or 1
    if current != page_number or pages > 1_000_000:
        raise SlackReadProviderError("Slack file paging metadata is invalid")
    return f"page:{current + 1}" if current < pages else None


def _files(
    api: Api, request: PageRequest, identity: dict[str, Any], target: ConversationTarget
) -> PageResult:
    require_scope(identity, "files:read")
    page_number = _file_page(request.cursor)
    result = verified_result(
        api(
            "files.list",
            {
                "channel": target.conversation_id,
                "count": str(request.limit),
                "page": str(page_number),
                "show_files_hidden_by_limit": "false",
            },
        ),
        identity,
    )
    if result.status != 200:
        return result
    root = object_value(result.payload, "files response")
    records = file_records_for_conversation(
        root.get("files"),
        request.workspace_id,
        request.limit,
        target.conversation_id,
    )
    return page_payload(request, records, _next_file_cursor(root, page_number))


TargetRoute = Callable[[Api, PageRequest, dict[str, Any], ConversationTarget], PageResult]
TARGET_ROUTES: dict[str, TargetRoute] = {
    "info": _conversation_info,
    "members": _members,
    "history": _messages,
    "thread": _messages,
    "files": _files,
}


def conversation_page(
    api: Api,
    request: PageRequest,
    identity: dict[str, Any],
    conversations: dict[str, ConversationTarget],
) -> PageResult:
    """Execute one route scoped to a profile-approved conversation."""
    target = _target(request, conversations)
    snapshot = SNAPSHOT_ROUTES.get(request.selector)
    if snapshot is not None:
        return _snapshot(api, request, identity, target, snapshot)
    handler = TARGET_ROUTES.get(request.selector)
    if handler is None:
        raise SlackReadProviderError("Slack stream is unsupported")
    return handler(api, request, identity, target)
