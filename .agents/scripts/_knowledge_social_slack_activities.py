#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize sanitized Slack records into canonical activities."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from _knowledge_social_slack import SlackAdapterError
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_fields import optional, required
from knowledge_social_import import canonical_json


@dataclass(frozen=True)
class ActivitySpec:
    activity_type: str
    remote_id: str
    actor: str
    target: str | None
    occurred_at: str | None
    state: str
    extra: dict[str, Any] | None = None


def _activity_id(*values: str) -> str:
    digest = hashlib.sha256(canonical_json(values).encode("utf-8")).hexdigest()
    return f"slack_activity_{digest}"


def _base_activity(
    spec: ActivitySpec, observed_at: str, source: str
) -> dict[str, Any]:
    provider_json = {"source": source, **(spec.extra or {})}
    reject_slack_credentials(provider_json)
    return {
        "activity_type": spec.activity_type,
        "remote_id": spec.remote_id,
        "actor_remote_id": spec.actor,
        "object_remote_id": spec.target,
        "occurred_at": spec.occurred_at,
        "observed_at": observed_at,
        "state": spec.state,
        "provider_json": provider_json,
    }


def _message_activities(
    record: dict[str, Any], observed_at: str, source: str
) -> list[dict[str, Any]]:
    remote_id = required(record, "remote_id")
    actor = required(record, "actor_remote_id")
    state = required(record, "state")
    thread = optional(record, "thread_remote_id")
    activity_type = "thread_reply" if thread and thread != remote_id else "message"
    initial = ActivitySpec(
        activity_type,
        _activity_id(activity_type, remote_id),
        actor,
        remote_id,
        optional(record, "created_at"),
        state,
        {"conversation_remote_id": record.get("conversation_remote_id")},
    )
    activities = [_base_activity(initial, observed_at, source)]
    if state in {"edited", "deleted"}:
        change_type = "message_edit" if state == "edited" else "message_delete"
        changed_at = optional(record, "edited_at")
        change = ActivitySpec(
            change_type,
            _activity_id(change_type, remote_id, changed_at or observed_at),
            optional(record, "editor_remote_id") or actor,
            remote_id,
            changed_at,
            state,
        )
        activities.append(_base_activity(change, observed_at, source))
    reactions = record.get("reactions", [])
    if not isinstance(reactions, list):
        raise SlackAdapterError("Slack message reactions must be an array")
    for reaction in reactions:
        activities.extend(_reaction_activities(reaction, remote_id, observed_at, source))
    if record.get("is_starred") is True:
        saved = ActivitySpec(
            "saved_message",
            _activity_id("saved_message", remote_id, actor),
            actor,
            remote_id,
            None,
            "active",
        )
        activities.append(_base_activity(saved, observed_at, source))
    return activities


def _reaction_activities(
    reaction: Any, message_id: str, observed_at: str, source: str
) -> list[dict[str, Any]]:
    if not isinstance(reaction, dict):
        raise SlackAdapterError("Slack message reaction must be an object")
    name = required(reaction, "name")
    actors = reaction.get("actor_remote_ids", [])
    if not isinstance(actors, list) or any(not isinstance(value, str) for value in actors):
        raise SlackAdapterError("Slack reaction actors must be an array")
    extra = {
        "name": name,
        "reported_count": reaction.get("count"),
        "actors_truncated": reaction.get("actors_truncated"),
    }
    return [
        _base_activity(
            ActivitySpec(
                "reaction",
                _activity_id("reaction", message_id, name, actor),
                actor,
                message_id,
                None,
                "active",
                extra,
            ),
            observed_at,
            source,
        )
        for actor in actors
    ]


def record_activities(
    record: dict[str, Any], selected_id: str, observed_at: str, source: str
) -> list[dict[str, Any]]:
    """Expand one sanitized provider record into canonical activities."""
    kind = required(record, "kind")
    if kind == "message":
        return _message_activities(record, observed_at, source)
    if kind == "membership":
        spec = ActivitySpec(
            "conversation_membership",
            required(record, "remote_id"),
            required(record, "actor_remote_id"),
            required(record, "conversation_remote_id"),
            None,
            "active",
        )
        return [_base_activity(spec, observed_at, source)]
    if kind in {"bookmark", "pin", "file"}:
        target = required(record, "remote_id")
        actor = optional(record, "actor_remote_id") or selected_id
        state = (
            "deleted"
            if kind == "file" and record.get("is_tombstoned") is True
            else "active"
        )
        activity_type = {
            "bookmark": "bookmark",
            "pin": "pin",
            "file": "file_share",
        }[kind]
        spec = ActivitySpec(
            activity_type,
            _activity_id(activity_type, target, actor),
            actor,
            target,
            optional(record, "created_at"),
            state,
        )
        return [_base_activity(spec, observed_at, source)]
    if kind == "user":
        actor = required(record, "remote_id")
        state = "deleted" if record.get("deleted") is True else "active"
        spec = ActivitySpec(
            "workspace_member",
            _activity_id("workspace_member", actor),
            actor,
            None,
            None,
            state,
        )
        return [_base_activity(spec, observed_at, source)]
    return []
