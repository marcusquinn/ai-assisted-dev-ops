#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Count bounded canonical row expansion for Slack export records."""

from __future__ import annotations

from typing import Any

from _knowledge_social_slack import namespaced_id

OBJECT_KINDS = frozenset(
    {"workspace", "conversation", "message", "bookmark", "pin", "file"}
)
ACTIVITY_KINDS = frozenset({"membership", "bookmark", "pin", "file", "user"})


def _reaction_actors(record: dict[str, Any]) -> list[str]:
    values: list[str] = []
    reactions = record.get("reactions", [])
    if not isinstance(reactions, list):
        return values
    for reaction in reactions:
        if not isinstance(reaction, dict):
            continue
        actors = reaction.get("actor_remote_ids", [])
        if isinstance(actors, list):
            values.extend(actor for actor in actors if isinstance(actor, str))
    return values


def _account_ids(record: dict[str, Any]) -> set[str]:
    values = {
        value
        for value in (
            record.get("actor_remote_id"),
            record.get("editor_remote_id"),
        )
        if isinstance(value, str)
    }
    if record.get("kind") == "user" and isinstance(record.get("remote_id"), str):
        values.add(record["remote_id"])
    values.update(_reaction_actors(record))
    return values


def _activity_count(record: dict[str, Any]) -> int:
    kind = record.get("kind")
    if kind in ACTIVITY_KINDS:
        return 1
    if kind != "message":
        return 0
    count = 1 + len(_reaction_actors(record))
    if record.get("state") in {"edited", "deleted"}:
        count += 1
    if record.get("is_starred") is True:
        count += 1
    return count


def normalized_item_count(
    records: list[dict[str, Any]], account: dict[str, Any]
) -> int:
    """Count canonical row expansion before allocating normalized collections."""
    workspace = account["workspace_id"]
    accounts = {
        account["id"],
        namespaced_id(workspace, "workspace_actor", workspace),
    }
    objects = 0
    activities = 0
    media = 0
    for record in records:
        kind = record.get("kind")
        accounts.update(_account_ids(record))
        objects += int(kind in OBJECT_KINDS)
        activities += _activity_count(record)
        media += int(kind == "file")
    return len(accounts) + objects + activities + media
