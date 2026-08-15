#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation for public marketing performance store configuration."""

from __future__ import annotations

from typing import Any

from performance_contract import PerformanceContractError

CONFIG_SCHEMA = "aidevops.marketing-performance-config/v1"


def _positive_integer(document: dict[str, Any], field: str) -> None:
    value = document.get(field)
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise PerformanceContractError(f"config {field} must be a positive integer")


def _validate_source_freshness(document: dict[str, Any]) -> None:
    stale = document.get("source_stale_after_seconds")
    if not isinstance(stale, dict):
        raise PerformanceContractError("config source_stale_after_seconds must be an object")
    for source, seconds in stale.items():
        valid_seconds = isinstance(seconds, int) and not isinstance(seconds, bool) and seconds >= 1
        if not isinstance(source, str) or not valid_seconds:
            raise PerformanceContractError("config source freshness entries are invalid")


def _validate_fixture_adapters(document: dict[str, Any]) -> None:
    fixtures = document.get("fixture_only_adapters")
    valid_fixtures = isinstance(fixtures, list) and all(isinstance(item, str) for item in fixtures)
    if not valid_fixtures:
        raise PerformanceContractError("config fixture_only_adapters must be an array")


def validate_config(document: Any) -> dict[str, Any]:
    """Validate bounded deterministic plane settings."""
    if not isinstance(document, dict) or document.get("schema") != CONFIG_SCHEMA:
        raise PerformanceContractError("unsupported marketing performance config schema")
    if document.get("schema_version") != 1:
        raise PerformanceContractError("unsupported marketing performance config version")
    for field in ("default_stale_after_seconds", "lease_seconds", "max_batch_events"):
        _positive_integer(document, field)
    _validate_source_freshness(document)
    _validate_fixture_adapters(document)
    return document
