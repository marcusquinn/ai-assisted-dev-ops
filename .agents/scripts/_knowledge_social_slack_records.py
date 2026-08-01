#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Sanitize Slack API and export records into one convergent provider shape."""

from __future__ import annotations

from typing import Any

from _knowledge_social_slack import (
    CONVERSATION_KINDS,
    SlackAdapterError,
    account_id,
    conversation_id,
    namespaced_id,
    team_id,
)
from _knowledge_social_slack_contract import (
    SlackReadProviderError,
    object_value,
    optional_boolean,
    optional_text,
)
# Same-name imports define the stable record facade used by route modules.
from _knowledge_social_slack_message_records import (  # pylint: disable=unused-import
    file_records as file_records,
    file_records_for_conversation as file_records_for_conversation,
    message_record as message_record,
    newest_message_ts as newest_message_ts,
    reaction_item_records as reaction_item_records,
)
from _knowledge_social_slack_record_contract import ACTOR_ID, epoch_iso, stable_id
from _knowledge_social_slack_snapshot_records import (  # pylint: disable=unused-import
    bookmark_record as bookmark_record,
    pin_record as pin_record,
)


def workspace_record(payload: Any, workspace: str) -> dict[str, Any]:
    team = object_value(payload, "workspace")
    native_id = team_id(team.get("id"))
    if native_id != team_id(workspace):
        raise SlackReadProviderError("Slack workspace metadata was rebound")
    return {
        "kind": "workspace",
        "remote_id": namespaced_id(workspace, "workspace", native_id),
        "workspace_id": native_id,
        "name": optional_text(team.get("name"), "workspace name"),
        "domain": optional_text(team.get("domain"), "workspace domain", limit=255),
        "email_domain": optional_text(
            team.get("email_domain"), "workspace email domain", limit=255
        ),
    }


def user_record(payload: Any, workspace: str) -> dict[str, Any]:
    user = object_value(payload, "user")
    native_id = stable_id(user.get("id"), "user ID", ACTOR_ID)
    if native_id.startswith("B"):
        raise SlackReadProviderError("Slack workspace member cannot use a bot ID")
    profile_value = user.get("profile", {})
    profile = object_value(profile_value, "user profile")
    display = optional_text(profile.get("display_name"), "display name")
    real = optional_text(profile.get("real_name"), "real name")
    return {
        "kind": "user",
        "remote_id": account_id(workspace, native_id),
        "user_id": native_id,
        "handle": optional_text(user.get("name"), "user handle", limit=255),
        "display_name": display or real,
        "deleted": optional_boolean(user.get("deleted"), "deleted flag") or False,
        "is_bot": optional_boolean(user.get("is_bot"), "bot flag") or False,
        "is_restricted": optional_boolean(
            user.get("is_restricted"), "restricted flag"
        ) or False,
    }


def _conversation_flags(kind: str) -> dict[str, bool]:
    if kind not in CONVERSATION_KINDS:
        raise SlackReadProviderError("Slack conversation kind is unsupported")
    return {
        "is_channel": kind == "public_channel",
        "is_group": kind == "private_channel",
        "is_im": kind == "im",
        "is_mpim": kind == "mpim",
    }


def _topic_value(payload: dict[str, Any], field: str) -> str | None:
    value = payload.get(field)
    if value is None:
        return None
    detail = object_value(value, f"conversation {field}")
    return optional_text(detail.get("value"), f"conversation {field}")


def conversation_record(
    payload: Any, workspace: str, expected_id: str, kind: str
) -> dict[str, Any]:
    conversation = object_value(payload, "conversation")
    native_id = conversation_id(conversation.get("id"))
    if native_id != conversation_id(expected_id):
        raise SlackReadProviderError("Slack conversation metadata was rebound")
    expected_flags = _conversation_flags(kind)
    for field, expected in expected_flags.items():
        value = conversation.get(field)
        if value is not None and optional_boolean(value, field) is not expected:
            raise SlackReadProviderError("Slack conversation kind was rebound")
    created = conversation.get("created")
    return {
        "kind": "conversation",
        "remote_id": namespaced_id(workspace, "conversation", native_id),
        "conversation_id": native_id,
        "conversation_kind": kind,
        "name": optional_text(conversation.get("name"), "conversation name"),
        "topic": _topic_value(conversation, "topic"),
        "purpose": _topic_value(conversation, "purpose"),
        "created_at": epoch_iso(created, "conversation created time"),
        "is_archived": optional_boolean(
            conversation.get("is_archived"), "conversation archived flag"
        ) or False,
        "is_member": optional_boolean(
            conversation.get("is_member"), "conversation membership flag"
        ),
    }


def membership_records(
    values: Any, workspace: str, native_conversation: str, limit: int
) -> list[dict[str, Any]]:
    if not isinstance(values, list) or len(values) > limit:
        raise SlackReadProviderError("Slack conversation members exceed the item limit")
    records: list[dict[str, Any]] = []
    target = namespaced_id(workspace, "conversation", conversation_id(native_conversation))
    for value in values:
        native_user = stable_id(value, "member user ID", ACTOR_ID)
        if native_user.startswith("B"):
            actor = namespaced_id(workspace, "bot", native_user)
        else:
            actor = account_id(workspace, native_user)
        records.append(
            {
                "kind": "membership",
                "remote_id": namespaced_id(
                    workspace, "membership", f"{native_conversation}:{native_user}"
                ),
                "conversation_remote_id": target,
                "actor_remote_id": actor,
            }
        )
    return records


def validate_record(record: dict[str, Any]) -> dict[str, Any]:
    """Fail closed if a shared API/export record lacks canonical identity."""
    if not isinstance(record.get("kind"), str) or not isinstance(
        record.get("remote_id"), str
    ):
        raise SlackAdapterError("Slack normalized record identity is incomplete")
    return record
