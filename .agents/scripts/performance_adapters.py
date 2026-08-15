#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Compatibility facade for bounded marketing performance adapters."""

from __future__ import annotations

from pathlib import Path

from _performance_adapter_campaign import normalize_campaign
from _performance_adapter_common import (
    ADAPTERS,
    FIXTURE_ONLY_ADAPTERS,
    MAX_INPUT_BYTES as MAX_INPUT_BYTES,
    AdapterResult,
    PerformanceAdapterError,
    load_json,
    read_input,
)
from _performance_adapter_fixture import normalize_fixture
from performance_legacy import normalize_phase1_results


def load_adapter(
    adapter: str,
    path: Path,
    *,
    account_override: str | None = None,
    campaign_id: str | None = None,
) -> AdapterResult:
    """Load one normalized/campaign/fixture adapter input."""
    if adapter not in ADAPTERS:
        raise PerformanceAdapterError("adapter is unsupported")
    raw_bytes = read_input(path)
    if adapter == "campaign":
        batch, errors = normalize_campaign(raw_bytes, path, account_override, campaign_id)
        return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".md")
    if adapter == "phase1":
        batch, errors = normalize_phase1_results(raw_bytes, path, account_override)
        return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".jsonl")
    document = load_json(raw_bytes)
    if adapter == "normalized":
        if document.get("source") != "normalized":
            raise PerformanceAdapterError("normalized adapter input must declare source=normalized")
        batch = dict(document)
        if account_override is not None:
            batch["account_ref"] = account_override
        return AdapterResult(batch=batch, errors=[], raw_bytes=raw_bytes, suffix=".json")
    batch, errors = normalize_fixture(adapter, document, account_override)
    return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".json")


def adapter_status() -> list[dict[str, object]]:
    """Return truthful local adapter availability without probing providers."""
    return [
        {
            "adapter": adapter,
            "availability": "fixture_only" if adapter in FIXTURE_ONLY_ADAPTERS else "available",
            "live_provider_calls": False,
        }
        for adapter in sorted(ADAPTERS)
    ]
