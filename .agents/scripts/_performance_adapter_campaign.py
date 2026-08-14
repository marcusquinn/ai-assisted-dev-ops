#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Campaign-results adapter for the marketing performance plane."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, localcontext
from pathlib import Path
from typing import Any

from _performance_adapter_common import PerformanceAdapterError
from _performance_adapter_fixture import EventSpec, build_event
from performance_contract import (
    PerformanceContractError, contains_direct_identifier, parse_timestamp,
    require_alias,
)

CAMPAIGN_METRICS: dict[str, tuple[EventSpec, str]] = {
    "impressions": (EventSpec("impression", "marketing.impressions.total", "impression"), "number"),
    "clicks": (EventSpec("engagement", "marketing.clicks.total", "engagement"), "number"),
    "ctr (%)": (EventSpec("engagement", "marketing.clicks.rate", "ratio", aggregation="average"), "percent"),
    "conversions": (EventSpec("conversion", "marketing.conversions.total", "conversion"), "number"),
    "cost": (EventSpec("cost", "marketing.cost.amount", "currency"), "currency"),
    "revenue / value": (EventSpec("revenue", "marketing.revenue.gross", "currency"), "currency"),
    "roi": (EventSpec("engagement", "marketing.return_on_investment.ratio", "ratio", aggregation="average"), "percent"),
}
CURRENCY_SYMBOLS = {"£": "GBP", "$": "USD", "€": "EUR"}


@dataclass(frozen=True)
class CampaignContext:
    """Shared identity and output state for campaign metric projection."""

    batch: dict[str, Any]
    errors: list[dict[str, Any]]
    campaign_id: str
    revision: int
    observed_at: str


def _metadata(text: str, name: str) -> str | None:
    match = re.search(rf"^\*\*{re.escape(name)}:\*\*\s*(.*?)\s*$", text, re.MULTILINE | re.IGNORECASE)
    return match.group(1).strip() if match else None


def _timestamp(text: str, path: Path) -> str:
    observed = _metadata(text, "Observed")
    if observed:
        return parse_timestamp(observed, "campaign.Observed")
    launched = _metadata(text, "Launched")
    if launched and re.fullmatch(r"\d{4}-\d{2}-\d{2}", launched):
        return f"{launched}T23:59:59Z"
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _number(raw_value: str, mode: str) -> tuple[Any, str | None]:
    compact = raw_value.strip().replace(",", "")
    if len(compact) > 256:
        raise PerformanceAdapterError("campaign numeric value exceeds the safety limit")
    if mode == "currency":
        match = re.fullmatch(r"(?:([A-Z]{3})|([£$€]))\s*(-?\d+(?:\.\d+)?)", compact, re.IGNORECASE)
        if not match:
            raise PerformanceAdapterError("campaign currency values require an ISO code or supported symbol")
        return match.group(3), (match.group(1) or CURRENCY_SYMBOLS[match.group(2)]).upper()
    if mode == "percent":
        match = re.fullmatch(r"(-?\d+(?:\.\d+)?)\s*%?", compact)
        if not match:
            raise PerformanceAdapterError("campaign ratio must be numeric")
        number = Decimal(match.group(1))
        with localcontext() as context:
            context.prec = max(28, len(number.as_tuple().digits) + 2)
            return format(number / Decimal(100), "f"), None
    if not re.fullmatch(r"-?\d+(?:\.\d+)?", compact):
        raise PerformanceAdapterError("campaign metric must be numeric")
    return compact, None


def _campaign_identity(text: str, requested: str | None) -> str:
    title = re.search(r"^# Campaign Results:\s*(\S+)\s*$", text, re.MULTILINE)
    title_campaign = title.group(1) if title else None
    if requested and title_campaign and requested != title_campaign:
        raise PerformanceAdapterError("campaign results title does not match the requested campaign id")
    resolved = requested or title_campaign
    if not resolved:
        raise PerformanceAdapterError("campaign id is required")
    return require_alias(resolved, "campaign id")


def _revision(text: str) -> int:
    raw = _metadata(text, "Revision") or "1"
    if not raw.isdigit() or int(raw) < 1:
        raise PerformanceAdapterError("campaign Revision must be a positive integer")
    return int(raw)


def _rows(text: str, campaign_id: str) -> tuple[dict[str, str], list[dict[str, Any]]]:
    rows: dict[str, str] = {}
    duplicates: set[str] = set()
    errors: list[dict[str, Any]] = []
    for metric, value in re.findall(r"^\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|\s*$", text, re.MULTILINE):
        key = metric.strip().lower()
        if key not in CAMPAIGN_METRICS:
            continue
        if key in rows or key in duplicates:
            duplicates.add(key)
            rows.pop(key, None)
            errors.append({"index": key, "reason": "campaign metric row is duplicated", "source_event_id": f"{campaign_id}:{key}"})
        else:
            rows[key] = value.strip()
    return rows, errors


def _append_metric(context: CampaignContext, key: str, raw: str, spec: EventSpec, mode: str) -> None:
    source_event_id = f"{context.campaign_id}:{key.replace(' ', '-')}"
    if not raw:
        context.batch["missing_scopes"].append(re.sub(r"[^a-z0-9]+", "_", key).strip("_"))
        return
    try:
        value, currency = _number(raw, mode)
        record = {"id": source_event_id, "revision": context.revision, "occurred_at": context.observed_at, "campaign_id": context.campaign_id, "confidence": "medium", "completeness": "complete"}
        event = build_event("campaign", record, spec, value, currency)
        event["quality"]["source_type"] = "manual"
        event["quality"]["collected_by"] = "campaign-results-import"
        context.batch["events"].append(event)
    except (PerformanceAdapterError, PerformanceContractError) as exc:
        context.errors.append({"index": key, "reason": str(exc), "source_event_id": source_event_id})


def normalize_campaign(raw_bytes: bytes, path: Path, account_override: str | None, campaign_id: str | None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Normalize one bounded campaign-results Markdown document."""
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PerformanceAdapterError("campaign results must be UTF-8 Markdown") from exc
    resolved = _campaign_identity(text, campaign_id)
    if contains_direct_identifier(text):
        raise PerformanceAdapterError("campaign results prose cannot contain contact destinations")
    observed_at = _timestamp(text, path)
    revision = _revision(text)
    rows, errors = _rows(text, resolved)
    batch: dict[str, Any] = {
        "source": "campaign", "account_ref": account_override or resolved,
        "cursor": "sha256:" + hashlib.sha256(raw_bytes).hexdigest(),
        "observed_at": observed_at, "coverage": "complete",
        "missing_scopes": [], "events": [],
    }
    context = CampaignContext(batch, errors, resolved, revision, observed_at)
    for key, (spec, mode) in CAMPAIGN_METRICS.items():
        _append_metric(context, key, rows.get(key, ""), spec, mode)
    if errors or batch["missing_scopes"]:
        batch["coverage"] = "partial"
    batch["missing_scopes"] = sorted(set(batch["missing_scopes"]))
    return batch, errors
