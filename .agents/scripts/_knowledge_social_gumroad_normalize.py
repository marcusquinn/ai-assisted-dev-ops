#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize minimized Gumroad seller records into canonical evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_gumroad import PROVIDER, RETENTION_LIMIT, GumroadAdapterError, page_data
from knowledge_social_import import reject_credentials

PROVENANCE = "gumroad_v2_get_api"
PROTECTED_STREAMS = frozenset({"sales", "payouts"})
GAPS = (
    ("offers", "product_scoped_offer_code_fanout_not_enabled"),
    ("complete_subscribers", "product_scoped_subscriber_fanout_not_enabled"),
    ("license_secrets", "license_values_are_intentionally_not_persisted"),
    ("affiliate_directory", "no_verified_seller_read_route"),
    ("balance", "no_verified_balance_read_route"),
    ("posts_updates", "no_verified_seller_read_route"),
    ("workflows_emails", "no_verified_seller_read_route"),
    ("community_messages", "no_verified_seller_read_route"),
    ("digital_files", "signed_file_downloads_and_contents_not_collected"),
    ("seller_exports", "dashboard_generation_and_unpublished_schema_not_enabled"),
    ("webhook_events", "subscription_mutation_and_no_documented_signature"),
    ("deleted_resources", "only_records_retained_by_current_api_are_visible"),
    ("provider_retention", "no_documented_api_retention_guarantee"),
    ("rate_limit", "no_documented_read_rate_limit_contract"),
)
ACTIVITY_TYPES = {"profile": "seller_profile", "products": "product_state", "sales": "sale", "payouts": "payout_state"}


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise GumroadAdapterError(f"Gumroad record requires {field}")
    return value


def _optional_text(value: Any, field: str) -> str | None:
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise GumroadAdapterError(f"Gumroad record {field} must be text")
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


def _text(item: dict[str, Any], stream: str) -> str | None:
    if stream == "products":
        values = [_optional_text(item.get("name"), "name"), _optional_text(item.get("description"), "description")]
    elif stream == "profile":
        values = [_optional_text(item.get("name"), "name")]
    else:
        values = [_optional_text(item.get("product_name"), "product name")]
    return "\n\n".join(value for value in values if value) or None


def _object(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = _required_text(item.get("kind"), "kind")
    expected_kind = context.stream.removesuffix("s") if context.stream != "profile" else "seller_profile"
    if kind != expected_kind:
        raise GumroadAdapterError("Gumroad page contains an unsupported item kind")
    remote_id = _required_text(item.get("remote_id"), "remote_id")
    protected = context.stream in PROTECTED_STREAMS
    provider_json = {
        "source": PROVENANCE,
        "stream": context.stream,
        "classification": "protected_business" if protected else "business",
        "record": item,
    }
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id"),
        "text": _text(item, context.stream),
        "created_at": _optional_text(item.get("created_at"), "created_at"),
        "observed_at": observed_at,
        "evidence_class": "protected_business" if protected else "authored",
        "provider_json": provider_json,
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build corpus rows while keeping direct customer/payment identifiers out."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    account_id = _required_text(context.account.get("id"), "selected account ID")
    objects = [_object(item, context, observed_at) for item in page_data(payload)]
    activities = [
        {
            "activity_type": ACTIVITY_TYPES[context.stream],
            "remote_id": f"{account_id}_{ACTIVITY_TYPES[context.stream]}_{item['remote_id']}",
            "actor_remote_id": account_id,
            "object_remote_id": item["remote_id"],
            "occurred_at": _optional_text(item.get("created_at"), "activity time"),
            "observed_at": observed_at,
            "state": "active",
            "provider_json": {"source": PROVENANCE, "stream": context.stream},
        }
        for item in page_data(payload)
    ]
    policy = dict(context.policy)
    policy.update({
        "gumroad_transport": "stdlib_urllib_get_only",
        "gumroad_api_version": "v2",
        "gumroad_direct_pii": "discarded",
        "gumroad_customer_aliases": "profile_keyed_hmac_sha256",
        "gumroad_financial_classification": "protected_business",
        "gumroad_exports": "disabled",
        "gumroad_events": "untrusted_and_disabled",
    })
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [{
            "remote_id": account_id,
            "handle": context.account.get("username"),
            "display_name": context.account.get("name"),
            "observed_at": observed_at,
            "provider_json": {"source": PROVENANCE},
        }],
        "objects": objects,
        "activities": activities,
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
