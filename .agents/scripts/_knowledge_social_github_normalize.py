#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted GitHub records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_github import PROVIDER, RETENTION_LIMIT, GitHubAdapterError, page_data
from _knowledge_social_github_identity import INSTANCE_ID
from knowledge_social_import import reject_credentials

PROVENANCE = "github_official_rest_and_graphql_apis"
GAPS = (
    ("reactions", "no_complete_account_centric_history_route"),
    ("migration_archives", "operator_initiated_and_expire_after_seven_days"),
    ("deleted_resources", "not_available_through_current_account_reads"),
    ("private_resources", "token_capability_and_current_visibility_bound"),
    ("organization_audit_logs", "organization_authority_and_separate_consent_required"),
)
OBJECT_TYPES = frozenset(
    {"account", "contribution", "notification", "organization", "project", "repository", "user_list"}
)
ACTIVITY_TYPES = {
    "contributions": "contribution",
    "repositories": "repository_access",
    "stars": "star",
    "notifications": "notification",
    "followers": "follower",
    "following": "following",
    "organizations": "organization_membership",
    "subscriptions": "subscription",
    "user_lists": "user_list",
    "projects_v2": "project_membership",
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
        raise GitHubAdapterError(f"GitHub record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise GitHubAdapterError(f"GitHub record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise GitHubAdapterError("GitHub page observed_at must be text")
    return value


def _coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in GAPS
    ]


def _object_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise GitHubAdapterError("GitHub page contains an unsupported item kind")
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value
        for key in ("title", "description", "name", "full_name", "login", "reason")
        if (value := _optional_text(item, key))
    ) or None
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if context.stream == "contributions" else None,
        "text": text,
        "created_at": _optional_text(item, "created_at") or _optional_text(item, "date"),
        "observed_at": observed_at,
        "evidence_class": "authored" if context.stream == "contributions" else "observed",
        "provider_json": provider_json,
    }


def _activity_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    selected = _required_text(context.account, "id")
    remote_id = _required_text(item, "remote_id")
    activity_type = ACTIVITY_TYPES[context.stream]
    actor, target = selected, remote_id
    if context.stream == "followers":
        actor, target = remote_id, selected
    return {
        "activity_type": activity_type,
        "remote_id": f"{selected}_{activity_type}_{remote_id}",
        "actor_remote_id": actor,
        "object_remote_id": target,
        "occurred_at": _optional_text(item, "updated_at") or _optional_text(item, "date"),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    if context.account.get("instance_id") != INSTANCE_ID:
        raise GitHubAdapterError("GitHub account installation identity is invalid")
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "github_identity": "rest_numeric_id_plus_graphql_node_id",
            "github_pagination": "opaque_rest_link_or_graphql_page_info_cursor",
            "github_transport": "stdlib_urllib_rest_get_and_fixed_graphql_query_only",
            "github_mutations": "unreachable",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"),
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": context.account.get("id"),
                "handle": context.account.get("login"),
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "provider_account_id": context.account.get("provider_account_id"),
                    "node_id": context.account.get("node_id"),
                    "bio": context.account.get("bio"),
                },
            }
        ],
        "objects": [_object_row(item, context, observed_at) for item in items],
        "activities": [_activity_row(item, context, observed_at) for item in items],
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
