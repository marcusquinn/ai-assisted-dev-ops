#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic scope selection for optimization snapshots."""

from __future__ import annotations

from typing import Any

from marketing_optimization_contract import parse_datetime


def event_order_key(event: dict[str, Any]) -> tuple[Any, str]:
    """Return a chronological event key with a stable record tie-break."""
    occurred = parse_datetime(event["event"]["occurred_at"], "event occurred_at")
    return occurred, str(event["record_ref"])


def filter_events(
    events: list[dict[str, Any]],
    as_of: str,
    source: str | None,
    account_ref: str | None,
    campaign_id: str | None,
) -> list[dict[str, Any]]:
    """Apply deterministic time and scope filters."""
    boundary = parse_datetime(as_of, "snapshot as_of")
    filtered: list[dict[str, Any]] = []
    for event in events:
        occurred = parse_datetime(event["event"]["occurred_at"], "event occurred_at")
        recorded = parse_datetime(event["source"]["recorded_at"], "source recorded_at")
        kind_matches = source is None or event["source"]["kind"] == source
        source_matches = account_ref is None or event["source"]["account_ref"] == account_ref
        campaign_matches = campaign_id is None or event["scope"]["campaign_id"] == campaign_id
        if max(occurred, recorded) <= boundary and kind_matches and source_matches and campaign_matches:
            filtered.append(event)
    return sorted(filtered, key=event_order_key)


def filter_sources(
    sources: list[dict[str, Any]],
    source: str | None,
    account_ref: str | None,
) -> list[dict[str, Any]]:
    """Keep source quality summaries inside the explicitly requested scope."""
    return [
        item
        for item in sources
        if (source is None or item["source"] == source)
        and (account_ref is None or item["account_ref"] == account_ref)
    ]
