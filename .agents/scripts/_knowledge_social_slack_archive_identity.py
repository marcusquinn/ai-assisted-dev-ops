#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Resolve Slack export identities and allowlisted reference members."""

from __future__ import annotations

import re
from pathlib import PurePosixPath
from typing import Any

from _knowledge_social_slack import account_id, enterprise_id, parse_account_id, team_id
from _knowledge_social_slack_archive_types import SlackArchiveRequest
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_route_types import ConversationTarget
from _knowledge_social_slack_zip import SlackArchiveIndex
from knowledge_social_store import SocialStoreError

DATE_MEMBER = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.json$")
REFERENCE_FILES = {
    "public_channel": "channels.json",
    "private_channel": "groups.json",
    "im": "dms.json",
    "mpim": "mpims.json",
}


def object_list(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise SocialStoreError(f"Slack export {field} must be an array of objects")
    if len(value) > limit:
        raise SocialStoreError(f"Slack export {field} exceeds the item budget")
    return value


def _single_member(index: SlackArchiveIndex, names: tuple[str, ...]) -> str:
    present = [name for name in names if name in index.members]
    if len(present) != 1:
        raise SocialStoreError("Slack export requires exactly one user reference file")
    return present[0]


def users(
    index: SlackArchiveIndex, max_items: int
) -> tuple[list[dict[str, Any]], str]:
    member = _single_member(index, ("users.json", "org_users.json"))
    return object_list(index.json_value(member), "users", max_items), member


def _selected_user(
    values: list[dict[str, Any]], selected_user_id: str
) -> dict[str, Any]:
    matches = [item for item in values if item.get("id") == selected_user_id]
    if len(matches) != 1:
        raise SocialStoreError("Slack export does not contain the selected account")
    return matches[0]


def _team_metadata(index: SlackArchiveIndex) -> dict[str, Any] | None:
    if "team_info.json" not in index.members:
        return None
    value = index.json_value("team_info.json")
    if not isinstance(value, dict):
        raise SocialStoreError("Slack export team_info.json must be an object")
    team = value.get("team", value)
    if not isinstance(team, dict):
        raise SocialStoreError("Slack export workspace metadata must be an object")
    return team


def identity(
    request: SlackArchiveRequest,
    index: SlackArchiveIndex,
    user_records: list[dict[str, Any]],
) -> tuple[dict[str, Any], dict[str, Any]]:
    expected_workspace, expected_user = parse_account_id(request.expected_account_id)
    binding = request.profile.binding
    if expected_workspace != binding.workspace_id:
        raise SocialStoreError("Slack export workspace does not match the profile")
    selected = _selected_user(user_records, expected_user)
    team = _team_metadata(index)
    reject_slack_credentials(selected)
    if team is not None:
        reject_slack_credentials(team)
    selected_workspace = selected.get("team_id")
    team_workspace = team.get("id") if team is not None else None
    if selected_workspace is not None and team_workspace is not None:
        if team_id(selected_workspace) != team_id(team_workspace):
            raise SocialStoreError("Slack export workspace identity conflicts")
    observed_workspace = team_workspace or selected_workspace
    if team_id(observed_workspace) != expected_workspace:
        raise SocialStoreError("Slack export workspace identity does not match")
    selected_enterprise = enterprise_id(selected.get("enterprise_id"))
    team_enterprise = enterprise_id(
        team.get("enterprise_id") if team is not None else None
    )
    if selected_enterprise is not None and team_enterprise is not None:
        if selected_enterprise != team_enterprise:
            raise SocialStoreError("Slack export enterprise identity conflicts")
    observed_enterprise = team_enterprise or selected_enterprise
    if enterprise_id(observed_enterprise) != binding.enterprise_id:
        raise SocialStoreError("Slack export enterprise identity does not match")
    account = {
        "id": account_id(expected_workspace, expected_user),
        "provider_account_id": expected_user,
        "workspace_id": expected_workspace,
        "enterprise_id": binding.enterprise_id,
        "token_type": binding.token_type,
        "scopes": [],
        "conversation_binding_sha256": request.profile.conversation_binding_sha256,
        "username": selected.get("name"),
        "workspace_name": team.get("name") if team else None,
    }
    return account, team or {"id": expected_workspace}


def _folder_name(record: dict[str, Any], target: ConversationTarget) -> str:
    folder = record.get("name") or target.conversation_id
    if not isinstance(folder, str) or not folder:
        raise SocialStoreError("Slack export conversation folder is invalid")
    if folder in {".", ".."} or "\\" in folder or "\x00" in folder:
        raise SocialStoreError("Slack export conversation folder is invalid")
    if PurePosixPath(folder).name != folder:
        raise SocialStoreError("Slack export conversation folder is invalid")
    return folder


def reference_record(
    index: SlackArchiveIndex, target: ConversationTarget, max_items: int
) -> tuple[dict[str, Any], str, int]:
    reference_name = REFERENCE_FILES[target.kind]
    if reference_name not in index.members:
        raise SocialStoreError("Slack export lacks an allowlisted conversation class")
    values = object_list(index.json_value(reference_name), reference_name, max_items)
    matches = [item for item in values if item.get("id") == target.conversation_id]
    if len(matches) != 1:
        raise SocialStoreError("Slack export lacks an allowlisted conversation")
    record = matches[0]
    reject_slack_credentials(record)
    members = record.get("members", [])
    if not isinstance(members, list):
        raise SocialStoreError("Slack export conversation members must be an array")
    return record, _folder_name(record, target), len(members)


def _is_message_member(name: str, prefix: str) -> bool:
    if not name.startswith(prefix):
        return False
    path = PurePosixPath(name)
    if len(path.parts) != 2:
        return False
    return DATE_MEMBER.fullmatch(path.name) is not None


def conversation_member_names(index: SlackArchiveIndex, folder: str) -> list[str]:
    prefix = f"{folder}/"
    return sorted(name for name in index.members if _is_message_member(name, prefix))
