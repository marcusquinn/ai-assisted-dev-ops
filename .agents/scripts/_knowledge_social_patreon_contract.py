#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict JSON:API validation and privacy-minimized Patreon records."""

from __future__ import annotations

import hashlib
import hmac
from typing import Any

from _knowledge_social_patreon_cursor import next_cursor
from _knowledge_social_patreon_relationships import relationship_ids as _relationship_ids
from _knowledge_social_patreon_types import (
    PatreonAdapterError,
    campaign_id,
    provider_id,
)
from knowledge_social_import import reject_credentials

DOCUMENT_KEYS = frozenset({"data", "included", "links", "meta", "jsonapi"})
RESOURCE_KEYS = frozenset({"attributes", "id", "links", "relationships", "type"})

CAMPAIGN_ATTRIBUTES = frozenset(
    {
        "created_at",
        "creation_name",
        "currency",
        "is_monthly",
        "is_nsfw",
        "name",
        "patron_count",
        "published_at",
        "summary",
        "url",
    }
)
POST_ATTRIBUTES = frozenset(
    {"content", "is_paid", "is_public", "published_at", "title", "url"}
)
BENEFIT_ATTRIBUTES = frozenset(
    {
        "benefit_type",
        "created_at",
        "description",
        "is_deleted",
        "is_ended",
        "is_published",
        "title",
    }
)
TIER_ATTRIBUTES = frozenset(
    {
        "amount_cents",
        "created_at",
        "description",
        "edited_at",
        "published",
        "published_at",
        "requires_shipping",
        "title",
        "url",
    }
)
MEMBER_ATTRIBUTES = frozenset(
    {
        "currently_entitled_amount_cents",
        "is_free_trial",
        "is_gifted",
        "patron_status",
        "pledge_cadence",
    }
)


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PatreonAdapterError(f"Patreon {field} must be an object")
    return value


def array_value(value: Any, field: str, limit: int = 1000) -> list[Any]:
    if not isinstance(value, list) or len(value) > limit:
        raise PatreonAdapterError(f"Patreon {field} must be a bounded array")
    return value


def _document(payload: Any) -> dict[str, Any]:
    root = object_value(payload, "response")
    reject_credentials(root)
    if not set(root).issubset(DOCUMENT_KEYS) or "data" not in root:
        raise PatreonAdapterError("Patreon response has an unsupported JSON:API shape")
    return root


def _attributes(resource: dict[str, Any], allowed: frozenset[str]) -> dict[str, Any]:
    attributes = resource.get("attributes", {})
    if not isinstance(attributes, dict) or not set(attributes).issubset(allowed):
        raise PatreonAdapterError("Patreon resource contains unrequested attributes")
    reject_credentials(attributes)
    return attributes


def _resource(
    value: Any,
    resource_type: str,
    allowed_attributes: frozenset[str],
    allowed_relationships: frozenset[str] = frozenset(),
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    resource = object_value(value, f"{resource_type} resource")
    if not set(resource).issubset(RESOURCE_KEYS) or resource.get("type") != resource_type:
        raise PatreonAdapterError(f"Patreon {resource_type} resource has an invalid shape")
    remote_id = provider_id(resource.get("id"), f"{resource_type} ID")
    attributes = _attributes(resource, allowed_attributes)
    relationships = resource.get("relationships", {})
    if not isinstance(relationships, dict) or not set(relationships).issubset(
        allowed_relationships
    ):
        raise PatreonAdapterError(
            f"Patreon {resource_type} resource contains unrequested relationships"
        )
    return remote_id, attributes, relationships


def _optional_text(value: Any, field: str, maximum: int = 64 * 1024) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > maximum:
        raise PatreonAdapterError(f"Patreon {field} must be bounded text")
    return value


def _optional_integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise PatreonAdapterError(f"Patreon {field} must be an integer")
    return value


def _optional_boolean(value: Any, field: str) -> bool | None:
    if value is not None and not isinstance(value, bool):
        raise PatreonAdapterError(f"Patreon {field} must be a boolean")
    return value


def identity_record(payload: Any, expected_id: str) -> dict[str, Any]:
    """Validate the minimal identity response and require an active creator role."""
    root = _document(payload)
    remote_id, attributes, relationships = _resource(
        root.get("data"), "user", frozenset({"is_creator"})
    )
    if relationships:
        raise PatreonAdapterError("Patreon identity returned unrequested relationships")
    if remote_id != provider_id(expected_id, "selected account ID"):
        raise PatreonAdapterError(
            "selected Patreon account does not match the configured connection"
        )
    if attributes.get("is_creator") is not True:
        raise PatreonAdapterError("selected Patreon account is not an active creator")
    if root.get("included") not in (None, []):
        raise PatreonAdapterError("Patreon identity returned unrequested includes")
    return {
        "kind": "creator_account",
        "remote_id": f"creator_account_{remote_id}",
        "is_creator": True,
    }


def owned_campaign_ids(payload: Any) -> tuple[tuple[str, ...], str | None]:
    """Validate the bounded list of campaigns owned by the authorized user."""
    root = _document(payload)
    data = array_value(root.get("data"), "campaign ownership data", 1000)
    identifiers = []
    for value in data:
        remote_id, attributes, relationships = _resource(
            value, "campaign", frozenset()
        )
        if attributes or relationships:
            raise PatreonAdapterError(
                "Patreon campaign ownership response was not identity-minimized"
            )
        identifiers.append(campaign_id(remote_id))
    if len(identifiers) != len(set(identifiers)):
        raise PatreonAdapterError("Patreon campaign ownership response contains duplicates")
    if root.get("included") not in (None, []):
        raise PatreonAdapterError("Patreon campaign ownership returned unrequested includes")
    return tuple(identifiers), next_cursor(root)


def _campaign_values(attributes: dict[str, Any]) -> dict[str, Any]:
    return {
        "created_at": _optional_text(attributes.get("created_at"), "campaign created_at"),
        "creation_name": _optional_text(attributes.get("creation_name"), "campaign creation_name"),
        "currency": _optional_text(attributes.get("currency"), "campaign currency", 32),
        "is_monthly": _optional_boolean(attributes.get("is_monthly"), "campaign is_monthly"),
        "is_nsfw": _optional_boolean(attributes.get("is_nsfw"), "campaign is_nsfw"),
        "name": _optional_text(attributes.get("name"), "campaign name"),
        "patron_count": _optional_integer(attributes.get("patron_count"), "campaign patron_count"),
        "published_at": _optional_text(attributes.get("published_at"), "campaign published_at"),
        "summary": _optional_text(attributes.get("summary"), "campaign summary", 2 * 1024 * 1024),
        "url": _optional_text(attributes.get("url"), "campaign URL"),
    }


def campaign_record(payload: Any, expected_campaign_id: str) -> dict[str, Any]:
    """Validate one selected creator-owned campaign detail response."""
    root = _document(payload)
    remote_id, attributes, relationships = _resource(
        root.get("data"), "campaign", CAMPAIGN_ATTRIBUTES
    )
    expected = campaign_id(expected_campaign_id)
    if remote_id != expected or relationships:
        raise PatreonAdapterError("Patreon campaign detail does not match the selected campaign")
    if root.get("included") not in (None, []):
        raise PatreonAdapterError("Patreon campaign detail returned unrequested includes")
    return {"kind": "campaign", "remote_id": f"campaign_{remote_id}", "campaign_id": remote_id, **_campaign_values(attributes)}


def _campaign_relationship(
    relationships: dict[str, Any], expected_campaign_id: str
) -> None:
    if "campaign" not in relationships:
        return
    identifiers = _relationship_ids(relationships, "campaign", "campaign", required=True)
    if identifiers != (campaign_id(expected_campaign_id),):
        raise PatreonAdapterError("Patreon resource belongs to an unselected campaign")


def post_records(payload: Any, expected_campaign_id: str) -> tuple[list[dict[str, Any]], str | None]:
    """Validate a creator post page without requesting author/member identity."""
    root = _document(payload)
    campaign = campaign_id(expected_campaign_id)
    records = []
    for value in array_value(root.get("data"), "post data"):
        remote_id, attributes, relationships = _resource(
            value, "post", POST_ATTRIBUTES, frozenset({"campaign"})
        )
        _campaign_relationship(relationships, campaign)
        records.append(
            {
                "kind": "post",
                "remote_id": f"post_{remote_id}",
                "campaign_id": campaign,
                "content": _optional_text(attributes.get("content"), "post content", 2 * 1024 * 1024),
                "is_paid": _optional_boolean(attributes.get("is_paid"), "post is_paid"),
                "is_public": _optional_boolean(attributes.get("is_public"), "post is_public"),
                "published_at": _optional_text(attributes.get("published_at"), "post published_at"),
                "title": _optional_text(attributes.get("title"), "post title"),
                "url": _optional_text(attributes.get("url"), "post URL"),
            }
        )
    if root.get("included") not in (None, []):
        raise PatreonAdapterError("Patreon posts returned unrequested includes")
    return records, next_cursor(root)


def _included_resources(
    root: dict[str, Any], allowed: dict[str, frozenset[str]]
) -> dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]]:
    included = root.get("included", [])
    values = array_value(included, "included resources")
    resources: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]] = {}
    relationships_by_type = {
        "benefit": frozenset({"campaign", "tiers"}),
        "tier": frozenset({"benefits", "campaign"}),
    }
    for value in values:
        item = object_value(value, "included resource")
        resource_type = item.get("type")
        if not isinstance(resource_type, str) or resource_type not in allowed:
            raise PatreonAdapterError("Patreon response contains an unrequested include type")
        remote_id, attributes, relationships = _resource(
            item,
            resource_type,
            allowed[resource_type],
            relationships_by_type.get(resource_type, frozenset()),
        )
        key = (resource_type, remote_id)
        if key in resources:
            raise PatreonAdapterError("Patreon included resources contain duplicates")
        resources[key] = (attributes, relationships)
    return resources


def _included_ids(
    included: dict[tuple[str, str], tuple[dict[str, Any], dict[str, Any]]],
    resource_type: str,
) -> set[str]:
    return {
        item_id
        for item_type, item_id in included
        if item_type == resource_type
    }


def _benefit_record(
    campaign: str,
    benefit: str,
    attributes: dict[str, Any],
) -> dict[str, Any]:
    return {
        "kind": "benefit",
        "remote_id": f"benefit_{campaign}_{benefit}",
        "campaign_id": campaign,
        "benefit_type": _optional_text(attributes.get("benefit_type"), "benefit type"),
        "created_at": _optional_text(attributes.get("created_at"), "benefit created_at"),
        "description": _optional_text(attributes.get("description"), "benefit description"),
        "is_deleted": _optional_boolean(attributes.get("is_deleted"), "benefit is_deleted"),
        "is_ended": _optional_boolean(attributes.get("is_ended"), "benefit is_ended"),
        "is_published": _optional_boolean(
            attributes.get("is_published"), "benefit is_published"
        ),
        "title": _optional_text(attributes.get("title"), "benefit title"),
    }


def _tier_record(
    campaign: str,
    tier: str,
    attributes: dict[str, Any],
) -> dict[str, Any]:
    return {
        "kind": "tier",
        "remote_id": f"tier_{campaign}_{tier}",
        "campaign_id": campaign,
        "amount_cents": _optional_integer(attributes.get("amount_cents"), "tier amount_cents"),
        "created_at": _optional_text(attributes.get("created_at"), "tier created_at"),
        "description": _optional_text(attributes.get("description"), "tier description"),
        "edited_at": _optional_text(attributes.get("edited_at"), "tier edited_at"),
        "published": _optional_boolean(attributes.get("published"), "tier published"),
        "published_at": _optional_text(attributes.get("published_at"), "tier published_at"),
        "requires_shipping": _optional_boolean(
            attributes.get("requires_shipping"), "tier requires_shipping"
        ),
        "title": _optional_text(attributes.get("title"), "tier title"),
        "url": _optional_text(attributes.get("url"), "tier URL"),
    }


def benefit_records(payload: Any, expected_campaign_id: str) -> list[dict[str, Any]]:
    """Validate campaign benefits and tiers with exact include linkage."""
    root = _document(payload)
    campaign = campaign_id(expected_campaign_id)
    remote_id, _attributes_value, relationships = _resource(
        root.get("data"),
        "campaign",
        frozenset({"name"}),
        frozenset({"benefits", "tiers"}),
    )
    if remote_id != campaign:
        raise PatreonAdapterError("Patreon benefits belong to an unselected campaign")
    benefit_ids = _relationship_ids(relationships, "benefits", "benefit", required=True)
    tier_ids = _relationship_ids(relationships, "tiers", "tier", required=True)
    included = _included_resources(
        root, {"benefit": BENEFIT_ATTRIBUTES, "tier": TIER_ATTRIBUTES}
    )
    if _included_ids(included, "benefit") != set(benefit_ids):
        raise PatreonAdapterError("Patreon benefit includes do not match campaign linkage")
    if _included_ids(included, "tier") != set(tier_ids):
        raise PatreonAdapterError("Patreon tier includes do not match campaign linkage")
    records = []
    for benefit in benefit_ids:
        attributes, item_relationships = included[("benefit", benefit)]
        _campaign_relationship(item_relationships, campaign)
        records.append(_benefit_record(campaign, benefit, attributes))
    for tier in tier_ids:
        attributes, item_relationships = included[("tier", tier)]
        _campaign_relationship(item_relationships, campaign)
        records.append(_tier_record(campaign, tier, attributes))
    return records


def _member_reference(pii_key: bytes, campaign: str, member_id: str) -> str:
    digest = hmac.new(
        pii_key, f"{campaign}:{member_id}".encode(), hashlib.sha256
    ).hexdigest()
    return f"member_{digest[:32]}"


def _member_rows(
    root: dict[str, Any], campaign: str
) -> tuple[list[tuple[str, dict[str, Any], tuple[str, ...]]], set[str]]:
    rows = []
    referenced_tiers: set[str] = set()
    for value in array_value(root.get("data"), "membership data"):
        remote_id, attributes, relationships = _resource(
            value,
            "member",
            MEMBER_ATTRIBUTES,
            frozenset({"campaign", "currently_entitled_tiers"}),
        )
        _campaign_relationship(relationships, campaign)
        tiers = _relationship_ids(
            relationships, "currently_entitled_tiers", "tier", required=True
        )
        referenced_tiers.update(tiers)
        rows.append((remote_id, attributes, tiers))
    return rows, referenced_tiers


def _membership_record(
    pii_key: bytes,
    campaign: str,
    remote_id: str,
    attributes: dict[str, Any],
    tiers: tuple[str, ...],
) -> dict[str, Any]:
    return {
        "kind": "membership",
        "remote_id": _member_reference(pii_key, campaign, remote_id),
        "campaign_id": campaign,
        "currently_entitled_amount_cents": _optional_integer(
            attributes.get("currently_entitled_amount_cents"),
            "membership currently_entitled_amount_cents",
        ),
        "is_free_trial": _optional_boolean(
            attributes.get("is_free_trial"), "membership is_free_trial"
        ),
        "is_gifted": _optional_boolean(
            attributes.get("is_gifted"), "membership is_gifted"
        ),
        "patron_status": _optional_text(
            attributes.get("patron_status"), "membership patron_status"
        ),
        "pledge_cadence": _optional_text(
            attributes.get("pledge_cadence"), "membership pledge_cadence"
        ),
        "tier_ids": [f"tier_{campaign}_{tier}" for tier in tiers],
    }


def membership_records(
    pii_key: bytes, payload: Any, expected_campaign_id: str
) -> tuple[list[dict[str, Any]], str | None]:
    """Minimize current member entitlements and discard direct member identity."""
    if len(pii_key) < 32:
        raise PatreonAdapterError("Patreon profile PII key must be at least 32 bytes")
    root = _document(payload)
    campaign = campaign_id(expected_campaign_id)
    raw_members, referenced_tiers = _member_rows(root, campaign)
    included = _included_resources(root, {"tier": TIER_ATTRIBUTES})
    if _included_ids(included, "tier") != referenced_tiers:
        raise PatreonAdapterError("Patreon membership tier includes do not match entitlement linkage")
    records = [
        _membership_record(pii_key, campaign, remote_id, attributes, tiers)
        for remote_id, attributes, tiers in raw_members
    ]
    return records, next_cursor(root)
