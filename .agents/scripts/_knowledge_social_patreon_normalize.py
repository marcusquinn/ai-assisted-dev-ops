#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize creator-owned, privacy-minimized Patreon records."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_patreon import (
    PROVIDER,
    RETENTION_LIMIT,
    PatreonAdapterError,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "patreon_api_v2_get"
GAPS = (
    ("patron_memberships", "identity_memberships_scope_and_patron_role_are_not_collected"),
    ("member_identity", "member_names_users_emails_addresses_and_notes_are_excluded"),
    ("pledge_history", "pledge_history_include_is_not_requested"),
    ("member_deliverables", "benefit_fulfilment_records_are_not_requested"),
    ("comments_reactions", "no_verified_creator_account_history_route"),
    ("messages_community", "no_verified_creator_account_history_route"),
    ("lives", "early_access_and_write_capable_surface_is_excluded"),
    ("webhooks", "webhook_write_scope_and_mutation_routes_are_excluded"),
    ("creator_csv", "dashboard_export_has_no_published_versioned_schema"),
    ("post_export", "no_documented_creator_post_export_contract"),
    ("deleted_resources", "only_records_retained_by_the_current_api_are_visible"),
    ("provider_retention", "no_documented_api_history_retention_guarantee"),
)
EXPECTED_KINDS = {
    "account": frozenset({"creator_account"}),
    "campaigns": frozenset({"campaign"}),
    "posts": frozenset({"post"}),
    "memberships": frozenset({"membership"}),
    "benefits": frozenset({"benefit", "tier"}),
}
ACTIVITY_TYPES = {
    "account": "creator_profile",
    "campaigns": "campaign_state",
    "posts": "creator_post",
    "memberships": "membership_state",
    "benefits": "benefit_state",
}


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PatreonAdapterError(f"Patreon record requires {field}")
    return value


def _optional_text(value: Any, field: str) -> str | None:
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise PatreonAdapterError(f"Patreon record {field} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    return _required_text(payload.get("observed_at"), "observed_at")


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


def _text(item: dict[str, Any]) -> str | None:
    kind = item.get("kind")
    fields = {
        "creator_account": (),
        "campaign": ("name", "creation_name", "summary"),
        "post": ("title", "content"),
        "membership": (),
        "benefit": ("title", "description"),
        "tier": ("title", "description"),
    }[kind]
    values = [_optional_text(item.get(field), field) for field in fields]
    return "\n\n".join(value for value in values if value) or None


def _object(
    item: dict[str, Any], context: PageContext, observed_at: str
) -> dict[str, Any]:
    kind = _required_text(item.get("kind"), "kind")
    if kind not in EXPECTED_KINDS[context.stream]:
        raise PatreonAdapterError("Patreon page contains an unsupported item kind")
    remote_id = _required_text(item.get("remote_id"), "remote_id")
    protected = context.stream == "memberships"
    provider_json = {
        "source": PROVENANCE,
        "stream": context.stream,
        "classification": "protected_business" if protected else "creator_owned",
        "record": item,
    }
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id"),
        "text": _text(item),
        "created_at": _optional_text(
            item.get("created_at") or item.get("published_at"), "record time"
        ),
        "observed_at": observed_at,
        "evidence_class": "protected_business" if protected else "authored",
        "provider_json": provider_json,
    }


def _activities(
    items: list[dict[str, Any]],
    context: PageContext,
    account_id: str,
    observed_at: str,
) -> list[dict[str, Any]]:
    return [
        {
            "activity_type": ACTIVITY_TYPES[context.stream],
            "remote_id": f"{account_id}_{context.stream}_{item['remote_id']}",
            "actor_remote_id": account_id,
            "object_remote_id": item["remote_id"],
            "occurred_at": _optional_text(
                item.get("published_at") or item.get("created_at"), "activity time"
            ),
            "observed_at": observed_at,
            "state": "active",
            "provider_json": {"source": PROVENANCE, "stream": context.stream},
        }
        for item in items
    ]


def _policy(context: PageContext) -> dict[str, Any]:
    policy = dict(context.policy)
    policy.update(
        {
            "patreon_api_version": "v2",
            "patreon_transport": "stdlib_urllib_get_only",
            "patreon_identity": "creator_user_plus_explicit_owned_campaigns",
            "patreon_scopes": "identity campaigns plus stream-specific read scope",
            "patreon_member_pii": "excluded_and_member_ids_keyed_hmac_sha256",
            "patreon_member_purpose": "membership_services_gate",
            "patreon_oauth_redirects": "outside_collector_and_not_followed",
            "patreon_exports": "documented_csv_unwired",
            "patreon_webhooks_and_lives": "disabled",
        }
    )
    return policy


def _account_record(
    account_id: str, campaigns: list[Any], observed_at: str
) -> dict[str, Any]:
    return {
        "remote_id": account_id,
        "handle": None,
        "display_name": None,
        "observed_at": observed_at,
        "provider_json": {
            "source": PROVENANCE,
            "role": "creator",
            "campaign_ids": campaigns,
        },
    }


def _archive(
    context: PageContext,
    account_id: str,
    campaigns: list[Any],
    observed_at: str,
    items: list[dict[str, Any]],
) -> dict[str, Any]:
    return {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": _policy(context),
        "accounts": [_account_record(account_id, campaigns, observed_at)],
        "objects": [_object(item, context, observed_at) for item in items],
        "activities": _activities(items, context, account_id, observed_at),
        "media": [],
        "coverage": _coverage(observed_at),
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build corpus rows while excluding direct member identity and credentials."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    account_id = _required_text(context.account.get("id"), "selected account ID")
    items = page_data(payload)
    campaigns = context.account.get("campaign_ids")
    if not isinstance(campaigns, list):
        raise PatreonAdapterError("Patreon selected campaign identity is invalid")
    archive = _archive(context, account_id, campaigns, observed_at, items)
    reject_credentials(archive)
    return archive
