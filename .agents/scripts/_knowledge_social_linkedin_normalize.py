#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize LinkedIn snapshots without guessing undocumented field mappings."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from _knowledge_social_linkedin import (
    API_VERSION,
    PROVIDER,
    STREAMS,
    LinkedInAdapterError,
    page_data,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVENANCE = "linkedin_member_snapshot_api"


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one snapshot page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _observation_time(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise LinkedInAdapterError("LinkedIn page observed_at must be text")
    return value


def _record_id(
    account_id: str, domain: str, record: dict[str, Any]
) -> tuple[str, str]:
    reject_credentials(record)
    record_digest = hashlib.sha256(canonical_json(record).encode("utf-8")).hexdigest()
    identity_digest = hashlib.sha256(
        f"{account_id}\x00{domain}\x00{record_digest}".encode("utf-8")
    ).hexdigest()
    return f"li_snapshot_{identity_digest}", record_digest


def _gap_coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": "newsletter_subscriptions",
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": None,
            "unavailable_reason": (
                "linkedin_member_snapshot_domains_do_not_list_newsletter_subscriptions"
            ),
            "status": "unavailable",
            "observed_at": observed_at,
        }
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows plus immutable raw snapshot evidence."""
    reject_credentials(payload)
    observed_at = _observation_time(payload)
    account_id = context.account.get("id")
    if not isinstance(account_id, str) or not account_id:
        raise LinkedInAdapterError("LinkedIn selected account requires an ID")
    spec = STREAMS[context.stream]
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("domain") != spec.snapshot_domain:
        raise LinkedInAdapterError("LinkedIn snapshot provenance is invalid")
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for record in page_data(payload):
        remote_id, digest = _record_id(account_id, spec.snapshot_domain, record)
        evidence_class = (
            "authored" if spec.activity_mode == "content_author" else "observed"
        )
        provenance = {
            "snapshot_domain": spec.snapshot_domain,
            "record_sha256": digest,
            "source": PROVENANCE,
        }
        objects.append(
            {
                "object_type": spec.resource_kind,
                "remote_id": remote_id,
                "account_remote_id": account_id,
                "text": None,
                "created_at": None,
                "observed_at": observed_at,
                "evidence_class": evidence_class,
                "provider_json": provenance,
            }
        )
        activities.append(
            {
                "activity_type": context.stream,
                "remote_id": f"{account_id}-{context.stream}-{digest}",
                "actor_remote_id": account_id,
                "object_remote_id": remote_id,
                "occurred_at": None,
                "observed_at": observed_at,
                "state": "active",
                "provider_json": provenance,
            }
        )
    policy = dict(context.policy)
    policy.update(
        {
            "linkedin_api_version": API_VERSION,
            "linkedin_provenance": PROVENANCE,
        }
    )
    return {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": account_id,
                "handle": None,
                "display_name": None,
                "observed_at": observed_at,
                "provider_json": {"source": PROVENANCE},
            }
        ],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _gap_coverage(observed_at),
    }
