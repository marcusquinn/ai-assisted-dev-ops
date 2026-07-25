#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize guarded X API pages into provider-neutral social archives."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from knowledge_social_import import reject_credentials
from knowledge_social_x_contract import PROVIDER, TWEET_STREAMS


class XNormalizeError(ValueError):
    """Raised when an X page cannot be normalized safely."""


def account_record(user: dict[str, Any], observed_at: str) -> dict[str, Any]:
    return {
        "remote_id": user["id"],
        "handle": user.get("username"),
        "display_name": user.get("name"),
        "observed_at": observed_at,
        "provider_json": {
            key: value
            for key, value in user.items()
            if key not in {"id", "username", "name"}
        },
    }


def page_accounts(
    account: dict[str, Any],
    includes: dict[str, Any],
    data: list[dict[str, Any]],
    stream: str,
    observed_at: str,
) -> list[dict[str, Any]]:
    accounts = [account_record(account, observed_at)]
    for user in includes.get("users", []):
        if isinstance(user, dict) and isinstance(user.get("id"), str):
            accounts.append(account_record(user, observed_at))
    if stream not in TWEET_STREAMS:
        for user in data:
            if isinstance(user.get("id"), str):
                accounts.append(account_record(user, observed_at))
    return accounts


def evidence_class(stream: str) -> str:
    if stream == "authored":
        return "authored"
    if stream in {"likes", "bookmarks"}:
        return "weak_signal"
    return "observed"


def page_resources(
    data: list[dict[str, Any]],
    account_id: str,
    stream: str,
    observed_at: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for item in data:
        remote_id = item.get("id")
        if not isinstance(remote_id, str) or not remote_id:
            raise XNormalizeError("X resource requires an ID")
        actor = item.get("author_id", account_id)
        if not isinstance(actor, str):
            raise XNormalizeError("X resource author_id must be text")
        object_id: str | None = None
        if stream in TWEET_STREAMS:
            object_id = remote_id
            objects.append(
                {
                    "object_type": "post",
                    "remote_id": remote_id,
                    "account_remote_id": actor,
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
            )
        activities.append(
            {
                "activity_type": stream,
                "remote_id": f"{stream}-{remote_id}",
                "actor_remote_id": account_id,
                "object_remote_id": object_id,
                "occurred_at": item.get("created_at"),
                "observed_at": observed_at,
                "state": "active",
            }
        )
    return objects, activities


def page_media(includes: dict[str, Any], media_policy: str) -> list[dict[str, Any]]:
    media: list[dict[str, Any]] = []
    if media_policy != "metadata":
        return media
    for item in includes.get("media", []):
        if isinstance(item, dict) and isinstance(item.get("media_key"), str):
            media.append(
                {
                    "remote_id": item["media_key"],
                    "object_remote_id": None,
                    "mime_type": item.get("type"),
                    "hydration_state": "metadata_only",
                }
            )
    return media


def page_archive(
    payload: dict[str, Any],
    connection_id: str,
    account: dict[str, Any],
    stream: str,
    media_policy: str,
) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", [])
    if data is None:
        data = []
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise XNormalizeError("X page data must be an array")
    observed_at = payload.get("observed_at")
    if observed_at is None:
        observed_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    if not isinstance(observed_at, str) or not observed_at:
        raise XNormalizeError("X page observed_at must be text")
    includes = payload.get("includes", {})
    if not isinstance(includes, dict):
        raise XNormalizeError("X page includes must be an object")

    accounts = page_accounts(account, includes, data, stream, observed_at)
    objects, activities = page_resources(data, account["id"], stream, observed_at)
    media = page_media(includes, media_policy)
    return {
        "provider": PROVIDER,
        "connection_id": connection_id,
        "remote_account_id": account["id"],
        "exported_at": observed_at,
        "enabled_streams": [stream],
        "policy": {"media_hydration": media_policy},
        "accounts": accounts,
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": [],
    }
