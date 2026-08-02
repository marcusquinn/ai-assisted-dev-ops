#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Hashnode records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_hashnode import (
    PROVIDER,
    RETENTION_LIMIT,
    HashnodeAdapterError,
    page_data,
)
from _knowledge_social_hashnode_identity import INSTANCE_ID, account_id, namespaced_id
from knowledge_social_import import reject_credentials

PROVENANCE = "hashnode_official_gql_beta_fixed_queries"
GAPS = (
    ("authored_comments_elsewhere", "no_account_centric_comment_history_query", "unavailable"),
    ("reaction_history", "no_account_centric_reaction_history_query", "unavailable"),
    ("comment_replies", "nested_reply_pages_are_not_collected", "partial"),
    ("messages", "no_official_account_message_query", "unavailable"),
    ("notifications", "no_official_account_notification_query", "unavailable"),
    ("account_export", "published_json_schema_and_identity_contract_unavailable", "unavailable"),
)
OBJECT_TYPES = {
    "profile": "profile",
    "publication": "publication",
    "post": "post",
    "draft": "draft",
    "comment": "comment",
    "reaction": "reaction",
    "account": "account",
}
ACTIVITY_TYPES = {
    "profile": "profile_observed",
    "publication": "publication_owner",
    "post": "content_author",
    "draft": "draft_author",
    "comment": "comment_received",
    "reaction": "like_received",
    "account": "relationship",
}


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise HashnodeAdapterError(f"Hashnode record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise HashnodeAdapterError(f"Hashnode record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise HashnodeAdapterError("Hashnode page observed_at must be text")
    return value


def _selected_account(context: PageContext, observed_at: str) -> dict[str, Any]:
    return {
        "remote_id": _required_text(context.account, "id"),
        "handle": _required_text(context.account, "username"),
        "display_name": _optional_text(context.account, "name"),
        "observed_at": observed_at,
        "provider_json": {
            "source": PROVENANCE,
            "provider_account_id": context.account.get("provider_account_id"),
            "bio": context.account.get("bio"),
            "tagline": context.account.get("tagline"),
            "location": context.account.get("location"),
            "date_joined": context.account.get("date_joined"),
        },
    }


def _record_account(value: Any, observed_at: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HashnodeAdapterError("Hashnode record account must be an object")
    remote = _required_text(value, "provider_account_id")
    return {
        "remote_id": account_id(remote),
        "handle": _required_text(value, "username"),
        "display_name": _optional_text(value, "name"),
        "observed_at": observed_at,
        "provider_json": {"source": PROVENANCE, "provider_account_id": remote},
    }


def _accounts(
    items: list[dict[str, Any]], context: PageContext, observed_at: str
) -> list[dict[str, Any]]:
    accounts = {_required_text(context.account, "id"): _selected_account(context, observed_at)}
    for item in items:
        values = []
        for key in ("author", "actor"):
            if item.get(key) is not None:
                values.append(item[key])
        if item.get("kind") == "account":
            values.append(item)
        for value in values:
            account = _record_account(value, observed_at)
            accounts[account["remote_id"]] = account
    return list(accounts.values())


def _record_text(item: dict[str, Any]) -> str | None:
    values = []
    for key in ("title", "subtitle", "name", "tagline", "about", "bio", "text", "markdown"):
        value = _optional_text(item, key)
        if value and value not in values:
            values.append(value)
    return "\n\n".join(values) or None


def _record_author(item: dict[str, Any], selected: str) -> str:
    account = item.get("author", item.get("actor"))
    if item.get("kind") == "account":
        account = item
    if account is None:
        return selected
    return _record_account(account, "unused")["remote_id"]


def _object_row(
    item: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise HashnodeAdapterError("Hashnode page contains an unsupported item kind")
    selected = _required_text(context.account, "id")
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    created_at = None
    for key in ("published_at", "date_added", "updated_at", "date_joined"):
        if (created_at := _optional_text(item, key)) is not None:
            break
    return {
        "object_type": OBJECT_TYPES[kind],
        "remote_id": _required_text(item, "remote_id"),
        "account_remote_id": _record_author(item, selected),
        "text": _record_text(item),
        "created_at": created_at,
        "observed_at": observed_at,
        "evidence_class": "authored" if kind in {"post", "draft"} else "observed",
        "provider_json": provider_json,
    }


def _activity_row(
    item: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    kind = _required_text(item, "kind")
    selected = _required_text(context.account, "id")
    remote = _required_text(item, "remote_id")
    actor = _record_author(item, selected)
    target = remote
    activity_type = ACTIVITY_TYPES[kind]
    if kind == "comment":
        target = _required_text(item["post"], "remote_id")
    elif kind == "reaction":
        target = _required_text(item["post"], "remote_id")
    elif kind == "account":
        relation = _required_text(item, "relation")
        activity_type = relation
        external = account_id(_required_text(item, "provider_account_id"))
        actor, target = (external, selected) if relation == "followers" else (selected, external)
    occurred_at = None
    for key in ("published_at", "date_added", "updated_at", "date_joined"):
        if (occurred_at := _optional_text(item, key)) is not None:
            break
    return {
        "activity_type": activity_type,
        "remote_id": namespaced_id("activity", f"{activity_type}:{remote}"),
        "actor_remote_id": actor,
        "object_remote_id": target,
        "occurred_at": occurred_at,
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def _coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": status,
            "observed_at": observed_at,
        }
        for stream, reason, status in GAPS
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    if context.account.get("instance_id") != INSTANCE_ID:
        raise HashnodeAdapterError("Hashnode account API identity is invalid")
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "hashnode_identity": "authenticated_viewer_id_and_username",
            "hashnode_ownership": "publication_and_authored_content_owner_rechecked",
            "hashnode_pagination": "opaque_independent_connection_cursors",
            "hashnode_transport": "stdlib_urllib_fixed_graphql_queries_only",
            "hashnode_mutations": "unreachable",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"),
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": _accounts(items, context, observed_at),
        "objects": [_object_row(item, context, observed_at) for item in items],
        "activities": [_activity_row(item, context, observed_at) for item in items],
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
