#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Meta product records into the shared social schema."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_meta import (
    RETENTION_LIMIT,
    MetaAdapterError,
    account_id,
    graph_id,
    page_data,
    product_spec,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "meta_graph_api"


@dataclass(frozen=True)
class PageContext:
    """Validated product and connection policy for one Graph page."""

    product: str
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _observation_time(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise MetaAdapterError("Meta page observed_at must be text")
    return value


def _optional_text(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


def _coverage(context: PageContext, observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": gap.stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": gap.reason,
            "status": gap.status,
            "observed_at": observed_at,
        }
        for gap in product_spec(context.product).gaps
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows and explicit product coverage evidence."""
    reject_credentials(payload)
    observed_at = _observation_time(payload)
    remote_account_id = account_id(context.account.get("id"), "account ID")
    spec = product_spec(context.product)
    if context.stream not in spec.streams:
        raise MetaAdapterError("Meta stream is unsupported for the selected product")
    stream = spec.streams[context.stream]
    meta = payload.get("meta")
    if (
        not isinstance(meta, dict)
        or meta.get("product") != context.product
        or meta.get("stream") != context.stream
    ):
        raise MetaAdapterError("Meta page provenance is invalid")

    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for item in page_data(payload):
        remote_id = graph_id(item.get("id"), "object ID")
        provider_json = {
            "source": PROVENANCE,
            "product": context.product,
            "stream": context.stream,
            "item": item,
        }
        objects.append(
            {
                "object_type": stream.resource_kind,
                "remote_id": remote_id,
                "account_remote_id": (
                    remote_account_id if stream.evidence_class == "authored" else None
                ),
                "text": _optional_text(
                    item.get("message", item.get("caption", item.get("text")))
                ),
                "created_at": _optional_text(
                    item.get("created_time", item.get("timestamp"))
                ),
                "observed_at": observed_at,
                "evidence_class": stream.evidence_class,
                "provider_json": provider_json,
            }
        )
        if stream.evidence_class == "authored":
            activities.append(
                {
                    "activity_type": stream.activity_type,
                    "remote_id": f"{remote_account_id}:{context.stream}:{remote_id}",
                    "actor_remote_id": remote_account_id,
                    "object_remote_id": remote_id,
                    "occurred_at": _optional_text(
                        item.get("created_time", item.get("timestamp"))
                    ),
                    "observed_at": observed_at,
                    "state": "active",
                    "provider_json": {
                        "source": PROVENANCE,
                        "product": context.product,
                        "stream": context.stream,
                    },
                }
            )

    policy = dict(context.policy)
    policy.update(
        {
            "meta_product": context.product,
            "meta_api_version": spec.api_version,
            "meta_account_gate": spec.account_gate,
            "meta_authorization_scopes": list(spec.authorization_scopes),
            "meta_stream_scopes": list(stream.required_scopes),
            "meta_provenance": PROVENANCE,
        }
    )
    account_handle = context.account.get("username")
    display_name = context.account.get("name")
    archive = {
        "provider": context.product,
        "connection_id": context.connection_id,
        "remote_account_id": remote_account_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": remote_account_id,
                "handle": account_handle if isinstance(account_handle, str) else None,
                "display_name": display_name if isinstance(display_name, str) else None,
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "product": context.product,
                },
            }
        ],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _coverage(context, observed_at),
    }
    reject_credentials(archive)
    return archive
