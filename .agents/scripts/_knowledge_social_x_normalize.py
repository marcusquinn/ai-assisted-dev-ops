#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize validated X pages into provider-neutral social records."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_x import PROVIDER, STREAMS, StreamSpec, XAdapterError, page_data
from _knowledge_social_x_media import page_media
from knowledge_social_import import reject_credentials


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one provider page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    media_policy: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def observation_time(payload: dict[str, Any]) -> str:
    observed_at = payload.get("observed_at")
    if observed_at is None:
        return datetime.now(UTC).isoformat().replace("+00:00", "Z")
    if not isinstance(observed_at, str) or not observed_at:
        raise XAdapterError("X page observed_at must be text")
    return observed_at


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and not isinstance(value, str):
        raise XAdapterError(f"X account {key} must be text")
    return value


def account_record(user: dict[str, Any], observed_at: str) -> dict[str, Any]:
    remote_id = user.get("id")
    if not isinstance(remote_id, str) or not remote_id:
        raise XAdapterError("X account requires an ID")
    return {
        "remote_id": remote_id,
        "handle": _optional_text(user, "username"),
        "display_name": _optional_text(user, "name"),
        "observed_at": observed_at,
        "provider_json": {
            key: value
            for key, value in user.items()
            if key not in {"id", "username", "name"}
        },
    }


def page_includes(payload: dict[str, Any]) -> dict[str, Any]:
    includes = payload.get("includes", {})
    if not isinstance(includes, dict):
        raise XAdapterError("X page includes must be an object")
    return includes


def _included_users(includes: dict[str, Any]) -> list[dict[str, Any]]:
    users = includes.get("users", [])
    if not isinstance(users, list) or any(not isinstance(item, dict) for item in users):
        raise XAdapterError("X included users must be an array")
    return users


def page_accounts(
    account: dict[str, Any],
    includes: dict[str, Any],
    data: list[dict[str, Any]],
    spec: StreamSpec,
    observed_at: str,
) -> list[dict[str, Any]]:
    users = [account, *_included_users(includes)]
    if spec.resource_kind == "account":
        users.extend(data)
    records = {
        record["remote_id"]: record
        for record in (account_record(user, observed_at) for user in users)
    }
    return list(records.values())


def evidence_class(stream: str) -> str:
    return {
        "authored": "authored",
        "likes": "weak_signal",
        "bookmarks": "weak_signal",
    }.get(stream, "observed")


def _tweet_object(
    item: dict[str, Any], remote_id: str, stream: str, observed_at: str
) -> dict[str, Any]:
    author_id = item.get("author_id")
    if not isinstance(author_id, str) or not author_id:
        raise XAdapterError("X post author_id must be text")
    return {
        "object_type": "post",
        "remote_id": remote_id,
        "account_remote_id": author_id,
        "text": item.get("text"),
        "created_at": item.get("created_at"),
        "observed_at": observed_at,
        "evidence_class": evidence_class(stream),
        "provider_json": {
            key: value
            for key, value in item.items()
            if key not in {"id", "author_id", "text", "created_at"}
        },
    }


def _activity_participants(
    spec: StreamSpec, item: dict[str, Any], account_id: str, remote_id: str
) -> tuple[str, str | None]:
    if spec.activity_mode == "content_author":
        author_id = item.get("author_id")
        if not isinstance(author_id, str) or not author_id:
            raise XAdapterError("X activity author_id must be text")
        return author_id, remote_id
    if spec.activity_mode == "remote_follows_selected":
        return remote_id, account_id
    if spec.activity_mode == "selected_follows_remote":
        return account_id, remote_id
    return account_id, remote_id


def page_resources(
    data: list[dict[str, Any]], account_id: str, stream: str, observed_at: str
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    spec = STREAMS[stream]
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for item in data:
        remote_id = item.get("id")
        if not isinstance(remote_id, str) or not remote_id:
            raise XAdapterError("X resource requires an ID")
        object_id = remote_id if spec.resource_kind == "tweet" else None
        if object_id:
            objects.append(_tweet_object(item, remote_id, stream, observed_at))
        actor_id, target_id = _activity_participants(
            spec, item, account_id, remote_id
        )
        activities.append(
            {
                "activity_type": stream,
                "remote_id": f"{account_id}-{stream}-{remote_id}",
                "actor_remote_id": actor_id,
                "object_remote_id": target_id,
                "occurred_at": item.get("created_at"),
                "observed_at": observed_at,
                "state": "active",
            }
        )
    return objects, activities


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Validate a successful X page and build provider-neutral import rows."""
    reject_credentials(payload)
    data = page_data(payload)
    includes = page_includes(payload)
    observed_at = observation_time(payload)
    spec = STREAMS[context.stream]
    objects, activities = page_resources(
        data, context.account["id"], context.stream, observed_at
    )
    return {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account["id"],
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": context.policy,
        "accounts": page_accounts(
            context.account, includes, data, spec, observed_at
        ),
        "objects": objects,
        "activities": activities,
        "media": page_media(includes, data, context.media_policy),
        "coverage": [],
    }


def page_time_bounds(archive: dict[str, Any]) -> tuple[str | None, str | None]:
    sources = (
        (archive["objects"], "created_at"),
        (archive["activities"], "occurred_at"),
    )
    timestamps = [
        value
        for rows, key in sources
        for record in rows
        if isinstance((value := record.get(key)), str) and value
    ]
    if not timestamps:
        return None, None
    return min(timestamps), max(timestamps)
