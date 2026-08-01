#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Select and sanitize allowlisted evidence from one Slack export index."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_slack import parse_account_id
from _knowledge_social_slack_archive_identity import (
    REFERENCE_FILES,
    conversation_member_names as _conversation_member_names,
    identity as _identity,
    object_list as _object_list,
    reference_record as _reference_record,
    users as _users,
)
from _knowledge_social_slack_archive_count import normalized_item_count
from _knowledge_social_slack_archive_types import SlackArchiveRequest
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_records import (
    conversation_record,
    membership_records,
    message_record,
    user_record,
    workspace_record,
)
from _knowledge_social_slack_route_types import ConversationTarget
from _knowledge_social_slack_zip import SlackArchiveIndex
from knowledge_social_store import SocialStoreError

@dataclass(frozen=True)
class ArchiveSelection:
    account: dict[str, Any]
    records: list[dict[str, Any]]
    selected_members: frozenset[str]
    present: dict[str, int]


@dataclass(frozen=True)
class SelectionContext:
    index: SlackArchiveIndex
    workspace: str
    max_items: int


def _message_file_records(
    context: SelectionContext,
    name: str,
    target: ConversationTarget,
    remaining: int,
) -> list[dict[str, Any]]:
    messages = _object_list(
        context.index.json_value(name), "conversation messages", context.max_items
    )
    records: list[dict[str, Any]] = []
    for message in messages:
        reject_slack_credentials(message)
        expanded = message_record(message, context.workspace, target.conversation_id)
        if len(records) + len(expanded) > remaining:
            raise SocialStoreError("Slack export exceeds the normalized item budget")
        records.extend(expanded)
    return records


def _conversation_records(
    context: SelectionContext, target: ConversationTarget, remaining: int
) -> tuple[list[dict[str, Any]], set[str], int, str]:
    reference, folder, member_count = _reference_record(
        context.index, target, context.max_items
    )
    records = [
        conversation_record(
            reference, context.workspace, target.conversation_id, target.kind
        )
    ]
    records.extend(
        membership_records(
            reference.get("members", []),
            context.workspace,
            target.conversation_id,
            min(context.max_items, max(member_count, 1)),
        )
    )
    if len(records) > remaining:
        raise SocialStoreError("Slack export exceeds the normalized item budget")
    names = _conversation_member_names(context.index, folder)
    for name in names:
        records.extend(
            _message_file_records(context, name, target, remaining - len(records))
        )
    return records, set(names), len(names), folder


def _bind_folder(
    bindings: dict[str, str], folder: str, conversation: str
) -> None:
    key = folder.casefold()
    previous = bindings.get(key)
    if previous is not None and previous != conversation:
        raise SocialStoreError(
            "Slack export conversation folder is bound to multiple IDs"
        )
    bindings[key] = conversation


def _collect_conversations(
    request: SlackArchiveRequest,
    context: SelectionContext,
    initial_count: int,
) -> tuple[list[dict[str, Any]], set[str], dict[str, int]]:
    records: list[dict[str, Any]] = []
    members: set[str] = set()
    present: dict[str, int] = {}
    folders: dict[str, str] = {}
    for alias, target in sorted(request.profile.conversations.items()):
        remaining = request.max_items - initial_count - len(records)
        selected, names, count, folder = _conversation_records(
            context, target, remaining
        )
        _bind_folder(folders, folder, target.conversation_id)
        records.extend(selected)
        members.add(REFERENCE_FILES[target.kind])
        members.update(names)
        present[alias] = count
    return records, members, present


def _raw_user_ids(records: list[dict[str, Any]], selected: str) -> set[str]:
    ids = {selected}
    for record in records:
        values = [record.get("actor_remote_id"), record.get("editor_remote_id")]
        reactions = record.get("reactions", [])
        if isinstance(reactions, list):
            values.extend(
                actor
                for reaction in reactions
                if isinstance(reaction, dict)
                for actor in reaction.get("actor_remote_ids", [])
                if isinstance(actor, str)
            )
        for value in values:
            if not isinstance(value, str):
                continue
            try:
                _workspace, native_user = parse_account_id(value)
            except SocialStoreError:
                continue
            ids.add(native_user)
    return ids


def _append_selected_users(
    records: list[dict[str, Any]],
    users: list[dict[str, Any]],
    account: dict[str, Any],
    max_items: int,
) -> None:
    _workspace, selected_user = parse_account_id(account["id"])
    wanted = _raw_user_ids(records, selected_user)
    for item in users:
        if item.get("id") not in wanted:
            continue
        reject_slack_credentials(item)
        if len(records) >= max_items:
            raise SocialStoreError("Slack export exceeds the normalized item budget")
        records.append(user_record(item, account["workspace_id"]))


def select_archive_records(
    request: SlackArchiveRequest, index: SlackArchiveIndex
) -> ArchiveSelection:
    """Select allowlisted records while enforcing raw and normalized row budgets."""
    users, users_member = _users(index, request.max_items)
    account, workspace_value = _identity(request, index, users)
    records = [workspace_record(workspace_value, account["workspace_id"])]
    selected_members = {users_member}
    if "team_info.json" in index.members:
        selected_members.add("team_info.json")
    context = SelectionContext(index, account["workspace_id"], request.max_items)
    conversation_rows, conversation_members, present = _collect_conversations(
        request, context, len(records)
    )
    records.extend(conversation_rows)
    selected_members.update(conversation_members)
    _append_selected_users(records, users, account, request.max_items)
    if normalized_item_count(records, account) > request.max_items:
        raise SocialStoreError("Slack export exceeds the normalized item budget")
    return ArchiveSelection(account, records, frozenset(selected_members), present)
