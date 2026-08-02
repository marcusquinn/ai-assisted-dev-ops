#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Stack Exchange records into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_stack_exchange import (
    PROVIDER,
    RETENTION_LIMIT,
    StackExchangeAdapterError,
    page_data,
)
from _knowledge_social_stack_exchange_identity import api_site_parameter
from knowledge_social_import import reject_credentials

PROVENANCE = "stack_exchange_api_v2_3"
GAPS = (
    ("votes", "complete_vote_history_not_available"),
    ("follows", "not_available_through_verified_account_reads"),
    ("subscriptions", "not_available_through_verified_account_reads"),
    ("lists", "not_available_through_verified_account_reads"),
    ("projects", "not_available_through_verified_account_reads"),
    ("account_archive", "no_verified_complete_account_archive"),
    ("inaccessible_site_history", "site_visibility_and_retention_bound"),
)
OBJECT_TYPES = frozenset(
    {"post", "question", "answer", "comment", "inbox_item", "notification", "account"}
)


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
        raise StackExchangeAdapterError(f"Stack Exchange record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise StackExchangeAdapterError(f"Stack Exchange record {key} must be text")
    return value


def _timestamp(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise StackExchangeAdapterError(f"Stack Exchange {field} is invalid")
    return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise StackExchangeAdapterError("Stack Exchange page observed_at must be text")
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
        raise StackExchangeAdapterError(
            "Stack Exchange page contains an unsupported item kind"
        )
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value
        for key in ("title", "body", "site_name")
        if (value := _optional_text(item, key))
    ) or None
    authored = context.stream in {"posts", "questions", "answers", "comments"}
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if authored else None,
        "text": text,
        "created_at": _timestamp(item.get("created_at"), "creation timestamp"),
        "observed_at": observed_at,
        "evidence_class": "authored" if authored else "observed",
        "provider_json": provider_json,
    }


def _activity_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    selected = _required_text(context.account, "id")
    remote_id = _required_text(item, "remote_id")
    activity_type = context.stream.removesuffix("s")
    return {
        "activity_type": activity_type,
        "remote_id": f"{selected}_{activity_type}_{remote_id}",
        "actor_remote_id": selected,
        "object_remote_id": remote_id,
        "occurred_at": _timestamp(item.get("created_at"), "activity timestamp"),
        "observed_at": observed_at,
        "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    site = api_site_parameter(context.account.get("api_site_parameter"))
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "stack_exchange_identity": "network_account_plus_site_parameter_plus_site_user",
            "stack_exchange_pagination": "page_until_has_more_false",
            "stack_exchange_backoff": "terminal_before_persistence",
            "stack_exchange_transport": "stdlib_urllib_get_only",
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
                "handle": context.account.get("display_name"),
                "display_name": context.account.get("display_name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "network_account_id": context.account.get("network_account_id"),
                    "site_user_id": context.account.get("site_user_id"),
                    "api_site_parameter": site,
                    "link": context.account.get("link"),
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
