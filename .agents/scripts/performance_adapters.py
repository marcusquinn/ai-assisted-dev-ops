#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded file adapters for provider-neutral marketing performance events."""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, localcontext
from pathlib import Path
from typing import Any, Callable

from performance_contract import (
    PerformanceContractError,
    contains_direct_identifier,
    parse_timestamp,
    require_alias,
)
from performance_legacy import normalize_phase1_results

MAX_INPUT_BYTES = 20 * 1024 * 1024
FIXTURE_ONLY_ADAPTERS = {"social", "analytics", "crm", "commerce", "outreach"}
ADAPTERS = {"normalized", "campaign", "phase1", *FIXTURE_ONLY_ADAPTERS}


class PerformanceAdapterError(PerformanceContractError):
    """Raised when a source fixture cannot be mapped safely."""


@dataclass(frozen=True)
class AdapterResult:
    """Normalized batch plus content-free per-record adapter failures."""

    batch: dict[str, Any]
    errors: list[dict[str, Any]]
    raw_bytes: bytes
    suffix: str


def read_input(path: Path) -> bytes:
    """Read one bounded regular file without following a directory contract."""
    if path.is_symlink():
        raise PerformanceAdapterError("input must be a regular non-symlink file")
    descriptor = -1
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        )
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PerformanceAdapterError("input must be a regular non-symlink file")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise PerformanceAdapterError("input exceeds the 20 MiB safety limit")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            data = handle.read(MAX_INPUT_BYTES + 1)
        if len(data) > MAX_INPUT_BYTES:
            raise PerformanceAdapterError("input exceeds the 20 MiB safety limit")
        return data
    except OSError as exc:
        raise PerformanceAdapterError(
            "input must be a readable regular non-symlink file"
        ) from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _load_json(raw_bytes: bytes) -> dict[str, Any]:
    try:
        document = json.loads(raw_bytes.decode("utf-8"), parse_float=Decimal)
    except (UnicodeDecodeError, json.JSONDecodeError, InvalidOperation, ValueError) as exc:
        raise PerformanceAdapterError("input must be valid UTF-8 JSON") from exc
    if not isinstance(document, dict):
        raise PerformanceAdapterError("input JSON must be an object")
    return document


def _fixture_header(
    adapter: str,
    document: dict[str, Any],
    account_override: str | None,
) -> dict[str, Any]:
    if document.get("fixture_schema_version") != 1:
        raise PerformanceAdapterError("fixture_schema_version must be 1")
    source = document.get("source", adapter)
    if source != adapter:
        raise PerformanceAdapterError("fixture source does not match the selected adapter")
    records = document.get("records")
    if not isinstance(records, list):
        raise PerformanceAdapterError("fixture records must be an array")
    missing_scopes = document.get("missing_scopes", [])
    if not isinstance(missing_scopes, list):
        raise PerformanceAdapterError("fixture missing_scopes must be an array")
    return {
        "source": adapter,
        "account_ref": account_override or document.get("account_ref"),
        "cursor": document.get("cursor"),
        "observed_at": document.get("observed_at"),
        "coverage": document.get("coverage", "complete"),
        "missing_scopes": list(missing_scopes),
        "events": [],
        "_records": records,
    }


def _subject(record: dict[str, Any], default_kind: str) -> dict[str, Any]:
    candidates = record.get("candidate_subject_refs", [])
    if candidates:
        return {
            "kind": record.get("subject_kind", default_kind),
            "identity_state": "ambiguous",
            "source_ref": None,
            "candidate_refs": candidates,
        }
    source_ref = record.get("subject_ref")
    if source_ref is None:
        return {
            "kind": "aggregate",
            "identity_state": "not_applicable",
            "source_ref": None,
            "candidate_refs": [],
        }
    return {
        "kind": record.get("subject_kind", default_kind),
        "identity_state": record.get("identity_state", "isolated"),
        "source_ref": source_ref,
        "candidate_refs": [],
    }


def _scope(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "campaign_id": record.get("campaign_id"),
        "channel": record.get("channel"),
        "creative_id": record.get("creative_id"),
        "touchpoint_id": record.get("touchpoint_id"),
        "outcome_id": record.get("outcome_id"),
        "dimensions": record.get("dimensions", {}),
    }


def _quality(adapter: str, record: dict[str, Any]) -> dict[str, Any]:
    return {
        "confidence": record.get("confidence", "high"),
        "completeness": record.get("completeness", "complete"),
        "source_type": "fixture",
        "collected_by": f"performance-fixture-{adapter}",
        "verified_by": record.get("verified_by"),
    }


def _governance(record: dict[str, Any]) -> dict[str, Any]:
    consent = record.get("consent", [])
    suppression = record.get("suppression")
    if not isinstance(consent, list):
        raise PerformanceAdapterError("record consent must be an array")
    if suppression is not None and not isinstance(suppression, dict):
        raise PerformanceAdapterError("record suppression must be an object")
    return {"consent": consent, "suppression": suppression}


def _event(
    adapter: str,
    record: dict[str, Any],
    *,
    event_type: str,
    metric_id: str,
    value: Any,
    unit: str,
    subject_kind: str = "anonymous",
    event_id_suffix: str = "",
    currency: str | None = None,
    aggregation: str = "sum",
) -> dict[str, Any]:
    event_id = record.get("id")
    if not isinstance(event_id, str) or not event_id:
        raise PerformanceAdapterError("record id is required")
    if event_id_suffix:
        event_id = f"{event_id}:{event_id_suffix}"
    return {
        "source_event_id": event_id,
        "revision": record.get("revision", 1),
        "event_type": event_type,
        "occurred_at": record.get("occurred_at"),
        "correction_of": record.get("correction_of"),
        "subject": _subject(record, subject_kind),
        "scope": _scope(record),
        "measurement": {
            "metric_id": metric_id,
            "value": value,
            "unit": unit,
            "aggregation": aggregation,
            "currency": currency,
            "period_start": record.get("period_start"),
            "period_end": record.get("period_end"),
        },
        "quality": _quality(adapter, record),
        "governance": _governance(record),
    }


def _social_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    mapping = {
        "receipt": ("social_receipt", "marketing.social.receipts.succeeded", "receipt"),
        "impression": ("impression", "marketing.impressions.total", "impression"),
        "engagement": ("engagement", "marketing.engagement.total", "engagement"),
        "follower": ("follower", "marketing.followers.total", "follower"),
        "subscriber": ("subscriber", "marketing.subscribers.total", "subscriber"),
    }
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in mapping:
        raise PerformanceAdapterError("social record kind is unsupported")
    event_type, metric_id, unit = mapping[kind]
    return [_event("social", record, event_type=event_type, metric_id=metric_id, value=record.get("value", 1), unit=unit)]


def _analytics_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    mapping = {
        "visit": ("visit", "marketing.visits.total", "visit"),
        "conversion": ("conversion", "marketing.conversions.total", "conversion"),
    }
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in mapping:
        raise PerformanceAdapterError("analytics record kind is unsupported")
    event_type, metric_id, unit = mapping[kind]
    return [_event("analytics", record, event_type=event_type, metric_id=metric_id, value=record.get("value", 1), unit=unit)]


def _crm_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    kind = record.get("kind")
    if kind == "lead_created":
        return [_event("crm", record, event_type="lead_created", metric_id="marketing.leads.created", value=1, unit="lead", subject_kind="lead")]
    if kind == "lead_stage":
        stage = record.get("stage")
        if stage != "qualified":
            raise PerformanceAdapterError("only the qualified CRM stage is normalized in v1")
        return [_event("crm", record, event_type="lead_stage", metric_id="marketing.leads.qualified", value=1, unit="lead", subject_kind="lead")]
    raise PerformanceAdapterError("CRM record kind is unsupported")


def _commerce_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    kind = record.get("kind")
    currency = record.get("currency")
    if kind == "sale":
        return [
            _event("commerce", record, event_type="sale", metric_id="marketing.sales.total", value=1, unit="sale", subject_kind="contact", event_id_suffix="sale"),
            _event("commerce", record, event_type="revenue", metric_id="marketing.revenue.gross", value=record.get("amount"), unit="currency", currency=currency, subject_kind="contact", event_id_suffix="revenue"),
        ]
    if kind == "refund":
        return [
            _event("commerce", record, event_type="refund", metric_id="marketing.refunds.total", value=1, unit="refund", subject_kind="contact", event_id_suffix="refund"),
            _event("commerce", record, event_type="refund", metric_id="marketing.revenue.refunded", value=record.get("amount"), unit="currency", currency=currency, subject_kind="contact", event_id_suffix="refunded-revenue"),
        ]
    raise PerformanceAdapterError("commerce record kind is unsupported")


def _outreach_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    mapping = {
        "sent": ("outreach_sent", "marketing.outreach.sent", "message"),
        "reply": ("outreach_reply", "marketing.outreach.replies", "reply"),
        "bounce": ("outreach_bounce", "marketing.outreach.bounces", "bounce"),
        "unsubscribe": ("unsubscribe", "marketing.outreach.unsubscribes", "unsubscribe"),
    }
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in mapping:
        raise PerformanceAdapterError("outreach record kind is unsupported")
    if kind == "unsubscribe":
        record = dict(record)
        suppression = record.get("suppression")
        if suppression is not None and (
            not isinstance(suppression, dict) or suppression.get("state") != "suppressed"
        ):
            raise PerformanceAdapterError(
                "unsubscribe records cannot clear or omit active suppression semantics"
            )
        if suppression is None:
            record["suppression"] = {
                "state": "suppressed",
                "reason": "unsubscribe",
                "effective_at": record.get("occurred_at"),
            }
        consent_raw = record.get("consent", [])
        if not isinstance(consent_raw, list):
            raise PerformanceAdapterError("record consent must be an array")
        consent = list(consent_raw)
        consent.append(
            {
                "purpose": "audience",
                "state": "denied",
                "lawful_basis": None,
                "effective_at": record.get("occurred_at"),
            }
        )
        record["consent"] = consent
    event_type, metric_id, unit = mapping[kind]
    return [_event("outreach", record, event_type=event_type, metric_id=metric_id, value=1, unit=unit, subject_kind="contact")]


FIXTURE_NORMALIZERS: dict[str, Callable[[dict[str, Any]], list[dict[str, Any]]]] = {
    "social": _social_record,
    "analytics": _analytics_record,
    "crm": _crm_record,
    "commerce": _commerce_record,
    "outreach": _outreach_record,
}


def _normalize_fixture(
    adapter: str,
    document: dict[str, Any],
    account_override: str | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    header = _fixture_header(adapter, document, account_override)
    records = header.pop("_records")
    errors: list[dict[str, Any]] = []
    normalizer = FIXTURE_NORMALIZERS[adapter]
    for index, record in enumerate(records):
        if not isinstance(record, dict):
            errors.append({"index": index, "reason": "record must be an object", "source_event_id": f"record-{index}"})
            continue
        try:
            header["events"].extend(normalizer(record))
        except (PerformanceAdapterError, PerformanceContractError) as exc:
            errors.append(
                {
                    "index": index,
                    "reason": str(exc),
                    "source_event_id": str(record.get("id", f"record-{index}")),
                }
            )
    if errors:
        header["coverage"] = "partial"
        header["missing_scopes"] = sorted({*header["missing_scopes"], "adapter_record_errors"})
    return header, errors


CAMPAIGN_METRICS: dict[str, tuple[str, str, str, str]] = {
    "impressions": ("impression", "marketing.impressions.total", "impression", "number"),
    "clicks": ("engagement", "marketing.clicks.total", "engagement", "number"),
    "ctr (%)": ("engagement", "marketing.clicks.rate", "ratio", "percent"),
    "conversions": ("conversion", "marketing.conversions.total", "conversion", "number"),
    "cost": ("cost", "marketing.cost.amount", "currency", "currency"),
    "revenue / value": ("revenue", "marketing.revenue.gross", "currency", "currency"),
    "roi": ("engagement", "marketing.return_on_investment.ratio", "ratio", "percent"),
}
CURRENCY_SYMBOLS = {"£": "GBP", "$": "USD", "€": "EUR"}


def _campaign_metadata(text: str, name: str) -> str | None:
    match = re.search(rf"^\*\*{re.escape(name)}:\*\*\s*(.*?)\s*$", text, re.MULTILINE | re.IGNORECASE)
    return match.group(1).strip() if match else None


def _campaign_timestamp(text: str, path: Path) -> str:
    observed = _campaign_metadata(text, "Observed")
    if observed:
        return parse_timestamp(observed, "campaign.Observed")
    launched = _campaign_metadata(text, "Launched")
    if launched and re.fullmatch(r"\d{4}-\d{2}-\d{2}", launched):
        return f"{launched}T23:59:59Z"
    return datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _campaign_number(raw_value: str, mode: str) -> tuple[Any, str | None]:
    compact = raw_value.strip().replace(",", "")
    if len(compact) > 256:
        raise PerformanceAdapterError("campaign numeric value exceeds the safety limit")
    if mode == "currency":
        match = re.fullmatch(r"(?:([A-Z]{3})|([£$€]))\s*(-?\d+(?:\.\d+)?)", compact, re.IGNORECASE)
        if not match:
            raise PerformanceAdapterError("campaign currency values require an ISO code or supported symbol")
        currency = (match.group(1) or CURRENCY_SYMBOLS[match.group(2)]).upper()
        return match.group(3), currency
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


def _normalize_campaign(
    raw_bytes: bytes,
    path: Path,
    account_override: str | None,
    campaign_id: str | None,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        text = raw_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise PerformanceAdapterError("campaign results must be UTF-8 Markdown") from exc
    title_match = re.search(r"^# Campaign Results:\s*(\S+)\s*$", text, re.MULTILINE)
    title_campaign = title_match.group(1) if title_match else None
    if campaign_id and title_campaign and campaign_id != title_campaign:
        raise PerformanceAdapterError(
            "campaign results title does not match the requested campaign id"
        )
    resolved_campaign = campaign_id or title_campaign
    if not resolved_campaign:
        raise PerformanceAdapterError("campaign id is required")
    resolved_campaign = require_alias(resolved_campaign, "campaign id")
    if contains_direct_identifier(text):
        raise PerformanceAdapterError(
            "campaign results prose cannot contain contact destinations"
        )
    observed_at = _campaign_timestamp(text, path)
    revision_raw = _campaign_metadata(text, "Revision") or "1"
    if not revision_raw.isdigit() or int(revision_raw) < 1:
        raise PerformanceAdapterError("campaign Revision must be a positive integer")
    revision = int(revision_raw)
    rows: dict[str, str] = {}
    duplicate_rows: set[str] = set()
    errors: list[dict[str, Any]] = []
    for metric, value in re.findall(r"^\|\s*([^|]+?)\s*\|\s*([^|]*?)\s*\|\s*$", text, re.MULTILINE):
        key = metric.strip().lower()
        if key in CAMPAIGN_METRICS:
            if key in rows or key in duplicate_rows:
                duplicate_rows.add(key)
                rows.pop(key, None)
                errors.append(
                    {
                        "index": key,
                        "reason": "campaign metric row is duplicated",
                        "source_event_id": f"{resolved_campaign}:{key}",
                    }
                )
            else:
                rows[key] = value.strip()
    batch: dict[str, Any] = {
        "source": "campaign",
        "account_ref": account_override or resolved_campaign,
        "cursor": "sha256:" + hashlib.sha256(raw_bytes).hexdigest(),
        "observed_at": observed_at,
        "coverage": "complete",
        "missing_scopes": [],
        "events": [],
    }
    for key, (event_type, metric_id, unit, mode) in CAMPAIGN_METRICS.items():
        raw_value = rows.get(key, "")
        source_event_id = f"{resolved_campaign}:{key.replace(' ', '-')}"
        if not raw_value:
            safe_scope = re.sub(r"[^a-z0-9]+", "_", key).strip("_")
            batch["missing_scopes"].append(safe_scope)
            continue
        try:
            value, currency = _campaign_number(raw_value, mode)
            record = {
                "id": source_event_id,
                "revision": revision,
                "occurred_at": observed_at,
                "campaign_id": resolved_campaign,
                "confidence": "medium",
                "completeness": "complete",
            }
            event = _event(
                "campaign",
                record,
                event_type=event_type,
                metric_id=metric_id,
                value=value,
                unit=unit,
                currency=currency,
                aggregation="average" if unit == "ratio" else "sum",
            )
            event["quality"]["source_type"] = "manual"
            event["quality"]["collected_by"] = "campaign-results-import"
            batch["events"].append(event)
        except (PerformanceAdapterError, PerformanceContractError) as exc:
            errors.append({"index": key, "reason": str(exc), "source_event_id": source_event_id})
    if errors or batch["missing_scopes"]:
        batch["coverage"] = "partial"
    batch["missing_scopes"] = sorted(set(batch["missing_scopes"]))
    return batch, errors


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
        batch, errors = _normalize_campaign(raw_bytes, path, account_override, campaign_id)
        return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".md")
    if adapter == "phase1":
        batch, errors = normalize_phase1_results(raw_bytes, path, account_override)
        return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".jsonl")
    document = _load_json(raw_bytes)
    if adapter == "normalized":
        if document.get("source") != "normalized":
            raise PerformanceAdapterError(
                "normalized adapter input must declare source=normalized"
            )
        batch = dict(document)
        if account_override is not None:
            batch["account_ref"] = account_override
        return AdapterResult(batch=batch, errors=[], raw_bytes=raw_bytes, suffix=".json")
    batch, errors = _normalize_fixture(adapter, document, account_override)
    return AdapterResult(batch=batch, errors=errors, raw_bytes=raw_bytes, suffix=".json")


def adapter_status() -> list[dict[str, Any]]:
    """Return truthful local adapter availability without probing providers."""
    return [
        {
            "adapter": adapter,
            "availability": "fixture_only" if adapter in FIXTURE_ONLY_ADAPTERS else "available",
            "live_provider_calls": False,
        }
        for adapter in sorted(ADAPTERS)
    ]
