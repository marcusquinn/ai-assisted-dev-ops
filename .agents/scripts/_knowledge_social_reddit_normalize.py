#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize sanitized Reddit pages into provider-neutral social records."""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_reddit import PROVIDER, RedditAdapterError, page_data
from knowledge_social_import import reject_credentials


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one Reddit page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def observation_time(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise RedditAdapterError("Reddit page observed_at must be text")
    return value


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        raise RedditAdapterError(f"Reddit record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and not isinstance(value, str):
        raise RedditAdapterError(f"Reddit record {key} must be text")
    return value


def _timestamp(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RedditAdapterError("Reddit timestamp must be numeric")
    if not math.isfinite(float(value)):
        raise RedditAdapterError("Reddit timestamp must be finite")
    try:
        parsed = datetime.fromtimestamp(value, UTC)
    except (OverflowError, OSError, ValueError) as error:
        raise RedditAdapterError("Reddit timestamp is out of range") from error
    return parsed.isoformat().replace("+00:00", "Z")


def _account_record(record: dict[str, Any], observed_at: str) -> dict[str, Any]:
    remote_id = _required_text(record, "remote_id")
    relationship_at = _timestamp(record.get("relationship_utc"))
    provider_json = {"relationship_at": relationship_at} if relationship_at else {}
    return {
        "remote_id": remote_id,
        "handle": _optional_text(record, "name"),
        "display_name": None,
        "observed_at": observed_at,
        "provider_json": provider_json,
    }


def _selected_account(account: dict[str, Any], observed_at: str) -> dict[str, Any]:
    remote_id = account.get("id")
    if not isinstance(remote_id, str) or not remote_id:
        raise RedditAdapterError("Reddit selected account requires an ID")
    username = account.get("username")
    if username is not None and not isinstance(username, str):
        raise RedditAdapterError("Reddit selected account name must be text")
    return {
        "remote_id": remote_id,
        "handle": username,
        "display_name": None,
        "observed_at": observed_at,
        "provider_json": {},
    }


def _author(
    item: dict[str, Any], accounts: dict[str, dict[str, Any]], observed_at: str
) -> str | None:
    author = item.get("author")
    if author is None:
        return None
    if not isinstance(author, dict):
        raise RedditAdapterError("Reddit content author must be an object")
    account = _account_record(author, observed_at)
    accounts[account["remote_id"]] = account
    return account["remote_id"]


def _provider_fields(item: dict[str, Any], excluded: set[str]) -> dict[str, Any]:
    provider_json = {key: value for key, value in item.items() if key not in excluded}
    reject_credentials(provider_json)
    return provider_json


def _community_object(record: dict[str, Any], observed_at: str) -> dict[str, Any]:
    remote_id = _required_text(record, "remote_id")
    display_name = _optional_text(record, "display_name")
    title = _optional_text(record, "title")
    text = " — ".join(value for value in (display_name, title) if value) or None
    return {
        "object_type": "community",
        "remote_id": remote_id,
        "account_remote_id": None,
        "text": text,
        "created_at": None,
        "observed_at": observed_at,
        "evidence_class": "observed",
        "provider_json": _provider_fields(
            record,
            {"kind", "fullname", "remote_id", "display_name", "title"},
        ),
    }


def _add_subreddit(
    item: dict[str, Any],
    objects: dict[tuple[str, str], dict[str, Any]],
    observed_at: str,
) -> None:
    subreddit = item.get("subreddit")
    if subreddit is None:
        return
    if not isinstance(subreddit, dict):
        raise RedditAdapterError("Reddit content subreddit must be an object")
    community = _community_object(subreddit, observed_at)
    objects[(community["object_type"], community["remote_id"])] = community


def _content_text(item: dict[str, Any], kind: str) -> str | None:
    if kind == "submission":
        values = (_optional_text(item, "title"), _optional_text(item, "selftext"))
    elif kind == "comment":
        values = (_optional_text(item, "body"),)
    else:
        values = (_optional_text(item, "subject"), _optional_text(item, "body"))
    return "\n\n".join(value for value in values if value) or None


def _evidence_class(stream: str) -> str:
    if stream.startswith("authored_") or stream == "sent_messages":
        return "authored"
    if stream in ("saved", "upvoted", "downvoted", "hidden"):
        return "weak_signal"
    return "observed"


def _content_object(
    item: dict[str, Any],
    kind: str,
    author_id: str | None,
    stream: str,
    observed_at: str,
) -> dict[str, Any]:
    remote_id = _required_text(item, "fullname")
    object_type = {"submission": "post", "comment": "comment", "message": "message"}[
        kind
    ]
    return {
        "object_type": object_type,
        "remote_id": remote_id,
        "account_remote_id": author_id,
        "text": _content_text(item, kind),
        "created_at": _timestamp(item.get("created_utc")),
        "observed_at": observed_at,
        "evidence_class": _evidence_class(stream),
        "provider_json": _provider_fields(
            item,
            {
                "kind",
                "fullname",
                "author",
                "subreddit",
                "title",
                "selftext",
                "body",
                "subject",
                "created_utc",
            },
        ),
    }


def _activity(
    stream: str,
    remote_id: str,
    actor_id: str,
    object_id: str | None,
    observed_at: str,
    occurred_at: str | None = None,
    provider_json: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "activity_type": stream,
        "remote_id": remote_id,
        "actor_remote_id": actor_id,
        "object_remote_id": object_id,
        "occurred_at": occurred_at,
        "observed_at": observed_at,
        "state": "active",
        "provider_json": provider_json or {},
    }


def _normalize_content(
    item: dict[str, Any],
    context: PageContext,
    observed_at: str,
    accounts: dict[str, dict[str, Any]],
    objects: dict[tuple[str, str], dict[str, Any]],
    activities: dict[tuple[str, str], dict[str, Any]],
) -> None:
    kind = item.get("kind")
    if kind not in ("submission", "comment", "message"):
        raise RedditAdapterError("Reddit content kind is unsupported")
    author_id = _author(item, accounts, observed_at)
    _add_subreddit(item, objects, observed_at)
    content = _content_object(item, kind, author_id, context.stream, observed_at)
    key = (content["object_type"], content["remote_id"])
    objects[key] = content
    selected_id = context.account["id"]
    actor_id = (
        author_id
        if context.stream not in ("saved", "upvoted", "downvoted", "hidden")
        else selected_id
    )
    actor_id = actor_id or selected_id
    remote_id = f"{selected_id}-{context.stream}-{content['remote_id']}"
    activity = _activity(
        context.stream,
        remote_id,
        actor_id,
        content["remote_id"],
        observed_at,
        content["created_at"],
    )
    activities[(activity["activity_type"], activity["remote_id"])] = activity


def _normalize_subreddit(
    item: dict[str, Any],
    context: PageContext,
    observed_at: str,
    objects: dict[tuple[str, str], dict[str, Any]],
    activities: dict[tuple[str, str], dict[str, Any]],
) -> None:
    community = _community_object(item, observed_at)
    objects[(community["object_type"], community["remote_id"])] = community
    remote_id = f"{context.account['id']}-{context.stream}-{community['remote_id']}"
    activity = _activity(
        context.stream,
        remote_id,
        context.account["id"],
        community["remote_id"],
        observed_at,
    )
    activities[(activity["activity_type"], activity["remote_id"])] = activity


def _normalize_redditor(
    item: dict[str, Any],
    context: PageContext,
    observed_at: str,
    accounts: dict[str, dict[str, Any]],
    activities: dict[tuple[str, str], dict[str, Any]],
) -> None:
    account = _account_record(item, observed_at)
    accounts[account["remote_id"]] = account
    remote_id = f"{context.account['id']}-{context.stream}-{account['remote_id']}"
    activity = _activity(
        context.stream,
        remote_id,
        context.account["id"],
        account["remote_id"],
        observed_at,
        account["provider_json"].get("relationship_at"),
    )
    activities[(activity["activity_type"], activity["remote_id"])] = activity


def _normalize_multireddit(
    item: dict[str, Any],
    context: PageContext,
    observed_at: str,
    objects: dict[tuple[str, str], dict[str, Any]],
    activities: dict[tuple[str, str], dict[str, Any]],
) -> None:
    remote_id = _required_text(item, "remote_id")
    display_name = _required_text(item, "display_name")
    members = item.get("subreddits")
    if not isinstance(members, list) or any(
        not isinstance(row, dict) for row in members
    ):
        raise RedditAdapterError("Reddit multireddit memberships must be an array")
    feed = {
        "object_type": "custom_feed",
        "remote_id": remote_id,
        "account_remote_id": context.account["id"],
        "text": "\n\n".join(
            value
            for value in (display_name, _optional_text(item, "description_md"))
            if value
        ),
        "created_at": None,
        "observed_at": observed_at,
        "evidence_class": "observed",
        "provider_json": _provider_fields(
            item,
            {"kind", "remote_id", "display_name", "description_md", "subreddits"},
        ),
    }
    objects[(feed["object_type"], remote_id)] = feed
    selected_activity = _activity(
        context.stream,
        f"{context.account['id']}-{context.stream}-{remote_id}",
        context.account["id"],
        remote_id,
        observed_at,
    )
    activities[
        (selected_activity["activity_type"], selected_activity["remote_id"])
    ] = selected_activity
    for member in members:
        community = _community_object(member, observed_at)
        objects[(community["object_type"], community["remote_id"])] = community
        membership = _activity(
            "multireddit_membership",
            f"{remote_id}-contains-{community['remote_id']}",
            remote_id,
            community["remote_id"],
            observed_at,
            provider_json={"stream": context.stream},
        )
        activities[(membership["activity_type"], membership["remote_id"])] = membership


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Validate one successful Reddit page and build provider-neutral rows."""
    reject_credentials(payload)
    observed_at = observation_time(payload)
    accounts: dict[str, dict[str, Any]] = {}
    selected = _selected_account(context.account, observed_at)
    accounts[selected["remote_id"]] = selected
    objects: dict[tuple[str, str], dict[str, Any]] = {}
    activities: dict[tuple[str, str], dict[str, Any]] = {}
    for item in page_data(payload):
        kind = item.get("kind")
        if kind in ("submission", "comment", "message"):
            _normalize_content(
                item, context, observed_at, accounts, objects, activities
            )
        elif kind == "subreddit":
            _normalize_subreddit(item, context, observed_at, objects, activities)
        elif kind == "redditor":
            _normalize_redditor(item, context, observed_at, accounts, activities)
        elif kind == "multireddit":
            _normalize_multireddit(item, context, observed_at, objects, activities)
        else:
            raise RedditAdapterError("Reddit page contains an unsupported item kind")
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account["id"],
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": context.policy,
        "accounts": list(accounts.values()),
        "objects": list(objects.values()),
        "activities": list(activities.values()),
        "media": [],
        "coverage": [],
    }
    reject_credentials(archive)
    return archive
