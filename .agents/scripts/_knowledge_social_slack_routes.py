#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted Slack read routes, pagination, and response serialization."""

from __future__ import annotations

from typing import Any

from _knowledge_social_slack import PageRequest
from _knowledge_social_slack_conversation_routes import conversation_page
from _knowledge_social_slack_contract import (
    object_list,
    object_value,
)
from _knowledge_social_slack_records import (
    newest_message_ts,
    reaction_item_records,
    user_record,
    workspace_record,
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


def _workspace(api: Api, request: PageRequest, identity: dict[str, Any]) -> PageResult:
    require_scope(identity, "team:read")
    result = verified_result(api("team.info", {}), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, "workspace response")
    return page_payload(
        request, [workspace_record(root.get("team"), request.workspace_id)], None
    )


def _users(api: Api, request: PageRequest, identity: dict[str, Any]) -> PageResult:
    require_scope(identity, "users:read")
    params = {"limit": str(request.limit)}
    if request.cursor:
        params["cursor"] = request.cursor
    result = verified_result(api("users.list", params), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, "users response")
    members = object_list(root.get("members"), "workspace members", limit=request.limit)
    records = [user_record(member, request.workspace_id) for member in members]
    return page_payload(request, records, next_cursor(root))


def _reactions(
    api: Api,
    request: PageRequest,
    identity: dict[str, Any],
    conversations: dict[str, ConversationTarget],
) -> PageResult:
    require_scope(identity, "reactions:read")
    params = {"limit": str(request.limit), "full": "true"}
    if request.cursor:
        params["cursor"] = request.cursor
    result = verified_result(api("reactions.list", params), identity)
    if result.status != 200:
        return result
    root = object_value(result.payload, "reactions response")
    items = object_list(root.get("items"), "reaction items", limit=request.limit)
    allowed = frozenset(target.conversation_id for target in conversations.values())
    records = [
        record
        for item in items
        for record in reaction_item_records(item, request.workspace_id, allowed)
    ]
    return page_payload(
        request, records, next_cursor(root), newest_message_ts(records)
    )


def page(
    api: Api,
    request: PageRequest,
    identity: dict[str, Any],
    conversations: dict[str, ConversationTarget],
) -> PageResult:
    """Execute one reviewed read for an identity-bound Slack stream."""
    if request.selector == "workspace":
        result = _workspace(api, request, identity)
    elif request.selector == "users":
        result = _users(api, request, identity)
    elif request.selector == "reactions":
        result = _reactions(api, request, identity, conversations)
    else:
        result = conversation_page(api, request, identity, conversations)
    return result
