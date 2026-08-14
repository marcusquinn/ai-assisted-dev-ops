#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixture adapters for normalized marketing performance events."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from _performance_adapter_common import PerformanceAdapterError
from performance_contract import PerformanceContractError


@dataclass(frozen=True)
class EventSpec:
    """Stable measurement identity used to construct one adapter event."""

    event_type: str
    metric_id: str
    unit: str
    subject_kind: str = "anonymous"
    event_id_suffix: str = ""
    aggregation: str = "sum"


def _fixture_header(adapter: str, document: dict[str, Any], account_override: str | None) -> dict[str, Any]:
    if document.get("fixture_schema_version") != 1:
        raise PerformanceAdapterError("fixture_schema_version must be 1")
    if document.get("source", adapter) != adapter:
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
        return {"kind": record.get("subject_kind", default_kind), "identity_state": "ambiguous", "source_ref": None, "candidate_refs": candidates}
    source_ref = record.get("subject_ref")
    if source_ref is None:
        return {"kind": "aggregate", "identity_state": "not_applicable", "source_ref": None, "candidate_refs": []}
    return {"kind": record.get("subject_kind", default_kind), "identity_state": record.get("identity_state", "isolated"), "source_ref": source_ref, "candidate_refs": []}


def _scope(record: dict[str, Any]) -> dict[str, Any]:
    return {
        "campaign_id": record.get("campaign_id"),
        "channel": record.get("channel"),
        "creative_id": record.get("creative_id"),
        "touchpoint_id": record.get("touchpoint_id"),
        "outcome_id": record.get("outcome_id"),
        "dimensions": record.get("dimensions", {}),
    }


def _governance(record: dict[str, Any]) -> dict[str, Any]:
    consent = record.get("consent", [])
    suppression = record.get("suppression")
    if not isinstance(consent, list):
        raise PerformanceAdapterError("record consent must be an array")
    if suppression is not None and not isinstance(suppression, dict):
        raise PerformanceAdapterError("record suppression must be an object")
    return {"consent": consent, "suppression": suppression}


def build_event(adapter: str, record: dict[str, Any], spec: EventSpec, value: Any, currency: str | None = None) -> dict[str, Any]:
    """Build one event from immutable metric identity and record context."""
    event_id = record.get("id")
    if not isinstance(event_id, str) or not event_id:
        raise PerformanceAdapterError("record id is required")
    if spec.event_id_suffix:
        event_id = f"{event_id}:{spec.event_id_suffix}"
    return {
        "source_event_id": event_id,
        "revision": record.get("revision", 1),
        "event_type": spec.event_type,
        "occurred_at": record.get("occurred_at"),
        "correction_of": record.get("correction_of"),
        "subject": _subject(record, spec.subject_kind),
        "scope": _scope(record),
        "measurement": {
            "metric_id": spec.metric_id,
            "value": value,
            "unit": spec.unit,
            "aggregation": spec.aggregation,
            "currency": currency,
            "period_start": record.get("period_start"),
            "period_end": record.get("period_end"),
        },
        "quality": {
            "confidence": record.get("confidence", "high"),
            "completeness": record.get("completeness", "complete"),
            "source_type": "fixture",
            "collected_by": f"performance-fixture-{adapter}",
            "verified_by": record.get("verified_by"),
        },
        "governance": _governance(record),
    }


SOCIAL = {
    "receipt": EventSpec("social_receipt", "marketing.social.receipts.succeeded", "receipt"),
    "impression": EventSpec("impression", "marketing.impressions.total", "impression"),
    "engagement": EventSpec("engagement", "marketing.engagement.total", "engagement"),
    "follower": EventSpec("follower", "marketing.followers.total", "follower"),
    "subscriber": EventSpec("subscriber", "marketing.subscribers.total", "subscriber"),
}
ANALYTICS = {
    "visit": EventSpec("visit", "marketing.visits.total", "visit"),
    "conversion": EventSpec("conversion", "marketing.conversions.total", "conversion"),
}
OUTREACH = {
    "sent": EventSpec("outreach_sent", "marketing.outreach.sent", "message", "contact"),
    "reply": EventSpec("outreach_reply", "marketing.outreach.replies", "reply", "contact"),
    "bounce": EventSpec("outreach_bounce", "marketing.outreach.bounces", "bounce", "contact"),
    "unsubscribe": EventSpec("unsubscribe", "marketing.outreach.unsubscribes", "unsubscribe", "contact"),
}


def _mapped_record(adapter: str, record: dict[str, Any], mapping: dict[str, EventSpec]) -> list[dict[str, Any]]:
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in mapping:
        raise PerformanceAdapterError(f"{adapter} record kind is unsupported")
    return [build_event(adapter, record, mapping[kind], record.get("value", 1))]


def _crm_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    kind = record.get("kind")
    if kind == "lead_created":
        spec = EventSpec("lead_created", "marketing.leads.created", "lead", "lead")
    elif kind == "lead_stage":
        if record.get("stage") != "qualified":
            raise PerformanceAdapterError("only the qualified CRM stage is normalized in v1")
        spec = EventSpec("lead_stage", "marketing.leads.qualified", "lead", "lead")
    else:
        raise PerformanceAdapterError("CRM record kind is unsupported")
    return [build_event("crm", record, spec, 1)]


def _commerce_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    kind, currency = record.get("kind"), record.get("currency")
    if kind == "sale":
        specs = (
            (EventSpec("sale", "marketing.sales.total", "sale", "contact", "sale"), 1),
            (EventSpec("revenue", "marketing.revenue.gross", "currency", "contact", "revenue"), record.get("amount")),
        )
    elif kind == "refund":
        specs = (
            (EventSpec("refund", "marketing.refunds.total", "refund", "contact", "refund"), 1),
            (EventSpec("refund", "marketing.revenue.refunded", "currency", "contact", "refunded-revenue"), record.get("amount")),
        )
    else:
        raise PerformanceAdapterError("commerce record kind is unsupported")
    return [build_event("commerce", record, spec, value, currency if spec.unit == "currency" else None) for spec, value in specs]


def _outreach_record(record: dict[str, Any]) -> list[dict[str, Any]]:
    kind = record.get("kind")
    if not isinstance(kind, str) or kind not in OUTREACH:
        raise PerformanceAdapterError("outreach record kind is unsupported")
    if kind == "unsubscribe":
        record = _unsubscribe_record(record)
    return [build_event("outreach", record, OUTREACH[kind], 1)]


def _unsubscribe_record(record: dict[str, Any]) -> dict[str, Any]:
    updated = dict(record)
    suppression = updated.get("suppression")
    invalid_suppression = suppression is not None and (
        not isinstance(suppression, dict) or suppression.get("state") != "suppressed"
    )
    if invalid_suppression:
        raise PerformanceAdapterError("unsubscribe records cannot clear or omit active suppression semantics")
    if suppression is None:
        updated["suppression"] = {"state": "suppressed", "reason": "unsubscribe", "effective_at": updated.get("occurred_at")}
    consent = updated.get("consent", [])
    if not isinstance(consent, list):
        raise PerformanceAdapterError("record consent must be an array")
    updated["consent"] = [*consent, {"purpose": "audience", "state": "denied", "lawful_basis": None, "effective_at": updated.get("occurred_at")}]
    return updated


FIXTURE_NORMALIZERS: dict[str, Callable[[dict[str, Any]], list[dict[str, Any]]]] = {
    "social": lambda record: _mapped_record("social", record, SOCIAL),
    "analytics": lambda record: _mapped_record("analytics", record, ANALYTICS),
    "crm": _crm_record,
    "commerce": _commerce_record,
    "outreach": _outreach_record,
}


def normalize_fixture(adapter: str, document: dict[str, Any], account_override: str | None) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    """Normalize fixture records while retaining content-free failures."""
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
            errors.append({"index": index, "reason": str(exc), "source_event_id": str(record.get("id", f"record-{index}"))})
    if errors:
        header["coverage"] = "partial"
        header["missing_scopes"] = sorted({*header["missing_scopes"], "adapter_record_errors"})
    return header, errors
