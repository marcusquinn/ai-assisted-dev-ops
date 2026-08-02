#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict JSON:API relationship identifiers for Patreon responses."""

from __future__ import annotations

from typing import Any

from _knowledge_social_patreon_types import PatreonAdapterError, provider_id

IDENTIFIER_KEYS = frozenset({"id", "meta", "type"})


def _object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PatreonAdapterError(f"Patreon {field} must be an object")
    return value


def _identifier(value: Any, resource_type: str) -> str:
    identifier = _object_value(value, f"{resource_type} relationship identifier")
    if not set(identifier).issubset(IDENTIFIER_KEYS) or identifier.get(
        "type"
    ) != resource_type:
        raise PatreonAdapterError(
            f"Patreon {resource_type} relationship identifier is invalid"
        )
    return provider_id(identifier.get("id"), f"{resource_type} relationship ID")


def _relationship_values(relation: Any, name: str) -> list[Any]:
    relation_object = _object_value(relation, f"{name} relationship")
    if not set(relation_object).issubset({"data", "links", "meta"}):
        raise PatreonAdapterError(f"Patreon {name} relationship has an invalid shape")
    if "data" not in relation_object:
        raise PatreonAdapterError(f"Patreon {name} relationship has an invalid shape")
    data = relation_object["data"]
    if isinstance(data, list):
        return data
    return [] if data is None else [data]


def relationship_ids(
    relationships: dict[str, Any],
    name: str,
    resource_type: str,
    *,
    required: bool = False,
) -> tuple[str, ...]:
    """Return unique relationship IDs after exact JSON:API shape validation."""
    relation = relationships.get(name)
    if relation is None:
        if required:
            raise PatreonAdapterError(f"Patreon {name} relationship is missing")
        return ()
    identifiers = tuple(
        _identifier(item, resource_type)
        for item in _relationship_values(relation, name)
    )
    if len(identifiers) != len(set(identifiers)):
        raise PatreonAdapterError(f"Patreon {name} relationship contains duplicates")
    return identifiers
